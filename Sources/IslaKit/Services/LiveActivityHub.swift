import AppKit
import Combine
import Foundation

/// The timer, the microphone and camera watch, and the Downloads watch, as
/// one source of the island's new live activities (plan
/// `2026-11-14-islandcn-activities`).
///
/// The controller listens to `live` and the two callbacks and nothing else,
/// so the services can change without the controller learning their names.
/// The two watches run only while their switch is on (both off by default,
/// spec §19.13 amended 2026-11-14): a switch turned off stops the listeners at
/// once rather than leaving them reading another app's state with nothing
/// drawn.
@MainActor
final class LiveActivityHub: ObservableObject {
    struct Environment {
        var defaults: UserDefaults
        var makeCapture: @MainActor () -> CaptureWatch
        var makeDownloads: @MainActor () -> DownloadWatch
        var timers: IslandTimerCenter
        var notificationCenter: NotificationCenter
        /// Mutes or unmutes the Mac's microphone input off the main thread
        /// (`MicrophoneMute`), then calls `done` on the main actor. A test's
        /// never touches a real device.
        var setMicrophoneMuted: @MainActor (_ muted: Bool, _ done: @escaping @MainActor @Sendable () -> Void) -> Void = {
            muted, done in
            DispatchQueue.global(qos: .userInitiated).async {
                MicrophoneMute.setMuted(muted)
                DispatchQueue.main.async { MainActor.assumeIsolated { done() } }
            }
        }

        @MainActor static var live: Environment {
            Environment(
                defaults: .standard,
                makeCapture: { CaptureWatch() },
                makeDownloads: {
                    let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
                    return DownloadWatch(environment: .live(folder: folder))
                },
                timers: IslandTimerCenter(),
                notificationCenter: .default
            )
        }
    }

    /// Where a running timer is kept across an update: Isla replaces itself
    /// to install one (`UpdateInstaller`), and a ten-minute timer started
    /// before Install should still be there after it.
    static let timersKey = "island.timers"

    @Published private(set) var live: [LiveActivity] = []
    /// A countdown reached zero, with the duration it was set for.
    var onTimerFinished: ((TimeInterval) -> Void)?
    /// A download finished or a file came by AirDrop.
    var onDownloadEvent: ((DownloadEvent) -> Void)?

    let timers: IslandTimerCenter
    private let environment: Environment
    private var capture: CaptureWatch?
    private var downloads: DownloadWatch?
    private var captureState: CaptureState = .none
    private var activeDownloads: [DownloadProgress] = []
    private var cancellables = Set<AnyCancellable>()
    private var defaultsObserver: NSObjectProtocol?
    private var lastDuration: TimeInterval = 0

    init(environment: Environment? = nil) {
        let environment = environment ?? .live
        self.environment = environment
        timers = environment.timers
    }

    func start() {
        guard defaultsObserver == nil else { return }
        if let data = environment.defaults.data(forKey: Self.timersKey),
           let snapshot = try? JSONDecoder().decode(IslandTimerCenter.Snapshot.self, from: data) {
            timers.restore(snapshot)
        }
        timers.onCountdownFinished = { [weak self] in
            guard let self else { return }
            self.onTimerFinished?(self.lastDuration)
        }
        timers.$countdown.combineLatest(timers.$stopwatch)
            .sink { [weak self] countdown, stopwatch in
                guard let self else { return }
                if case .countdown(let duration)? = countdown?.kind { self.lastDuration = duration }
                self.persist(countdown: countdown, stopwatch: stopwatch)
                self.publish(countdown: countdown, stopwatch: stopwatch)
            }
            .store(in: &cancellables)
        defaultsObserver = environment.notificationCenter.addObserver(
            forName: UserDefaults.didChangeNotification, object: environment.defaults, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.followSwitches() }
        }
        followSwitches()
    }

    func stop() {
        if let defaultsObserver { environment.notificationCenter.removeObserver(defaultsObserver) }
        defaultsObserver = nil
        cancellables.removeAll()
        capture?.stop()
        capture = nil
        downloads?.stop()
        downloads = nil
    }

    /// The island's Mute and Unmute. The watch hears the device change by
    /// itself; it is asked again once the change is made, so the island
    /// answers the press without waiting on the system's notice.
    func setMicrophoneMuted(_ muted: Bool) {
        environment.setMicrophoneMuted(muted) { [weak self] in self?.capture?.reread() }
    }

    /// Starts or stops each watch to match its switch. Called on every
    /// defaults change, so it does nothing unless a switch moved.
    func followSwitches() {
        let wantsCapture = SettingsRowID.recording.isOn(in: environment.defaults)
        if wantsCapture, capture == nil {
            let watch = environment.makeCapture()
            watch.onChange = { [weak self] state in
                self?.captureState = state
                self?.republish()
            }
            capture = watch
            watch.start()
        } else if !wantsCapture, let watch = capture {
            watch.stop()
            capture = nil
            captureState = .none
            republish()
        }
        let wantsDownloads = SettingsRowID.downloads.isOn(in: environment.defaults)
        if wantsDownloads, downloads == nil {
            let watch = environment.makeDownloads()
            watch.onActiveChange = { [weak self] active in
                self?.activeDownloads = active
                self?.republish()
            }
            watch.onEvent = { [weak self] event in self?.onDownloadEvent?(event) }
            downloads = watch
            watch.start()
        } else if !wantsDownloads, let watch = downloads {
            watch.stop()
            downloads = nil
            activeDownloads = []
            republish()
        }
    }

    private func republish() {
        publish(countdown: timers.countdown, stopwatch: timers.stopwatch)
    }

    private func publish(countdown: IslandTimerState?, stopwatch: IslandTimerState?) {
        let next = LiveActivity.standing(
            capture: captureState, countdown: countdown, stopwatch: stopwatch, downloads: activeDownloads
        )
        if next != live { live = next }
    }

    private func persist(countdown: IslandTimerState?, stopwatch: IslandTimerState?) {
        let snapshot = IslandTimerCenter.Snapshot(countdown: countdown, stopwatch: stopwatch)
        if snapshot.countdown == nil, snapshot.stopwatch == nil {
            environment.defaults.removeObject(forKey: Self.timersKey)
        } else if let data = try? JSONEncoder().encode(snapshot) {
            environment.defaults.set(data, forKey: Self.timersKey)
        }
    }

    /// The app a microphone or camera activity names: the first app with the
    /// microphone, mapped from a helper's bundle id to the app that owns it
    /// (`com.google.Chrome.helper` is Chrome's), so the icon and the click
    /// are the app's.
    nonisolated static func owningApp(of bundleID: String, installed: (String) -> Bool) -> String {
        var parts = bundleID.split(separator: ".").map(String.init)
        while parts.count > 2 {
            let candidate = parts.joined(separator: ".")
            if installed(candidate) { return candidate }
            parts.removeLast()
        }
        return bundleID
    }

    static func owningApp(of bundleID: String) -> String {
        owningApp(of: bundleID) { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    }
}
