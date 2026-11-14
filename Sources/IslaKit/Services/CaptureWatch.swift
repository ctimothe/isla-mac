import AppKit
import CoreAudio
import CoreMediaIO

/// What is using the microphone and the cameras right now, as the island's
/// Recording activity needs it (islandcn plan §S4).
struct CaptureState: Equatable {
    /// Bundle ids of other apps with microphone input running, sorted so the
    /// same set is always the same array (a `Set`'s order would make two equal
    /// readings compare unequal and be reported twice). Isla's own ids and
    /// processes that belong to no app are never in it.
    var microphoneApps: [String]
    var cameraInUse: Bool

    var isEmpty: Bool { microphoneApps.isEmpty && !cameraInUse }

    static let none = CaptureState(microphoneApps: [], cameraInUse: false)

    /// A raw reading made into a state: duplicates folded (an app with two
    /// helper processes on the microphone is one app), blanks and `excluding`
    /// dropped, the rest sorted. Pure, so the rules are a test.
    init(microphone: [String], camera: Bool, excluding: Set<String> = []) {
        microphoneApps = Array(Set(microphone.filter { !$0.isEmpty && !excluding.contains($0) })).sorted()
        cameraInUse = camera
    }

    init(microphoneApps: [String], cameraInUse: Bool) {
        self.microphoneApps = microphoneApps
        self.cameraInUse = cameraInUse
    }
}

/// Tells the island when another app records the microphone or a camera, the
/// way macOS's orange and green dots do. Both sources are notifications from
/// the system; nothing is polled.
///
/// Neither read asks for a permission. CoreAudio's process objects and
/// CoreMediaIO's `DeviceIsRunningSomewhere` are the metadata the menu bar
/// itself reads: they say that something is running, never what it hears or
/// sees, and the camera prompt belongs to opening a capture session, which
/// this never does. Nothing here needs an entitlement.
@MainActor
final class CaptureWatch {
    /// What the watch reads and how it waits: the system's sources in the app,
    /// and a scripted microphone, camera and clock in a test. The sequencing
    /// — a read that failed, a stop that lasted half a second, a stop while a
    /// read was in flight — is what the tests hold.
    struct Environment {
        /// Bundle ids of every app with microphone input running (each
        /// process named by its responsible app), unfiltered, or nil when
        /// CoreAudio could not say. Not an empty list:
        /// a failed read taken at its word would clear a recording that is
        /// still going and flash the island out and back in.
        var readMicrophoneApps: @Sendable () -> [String]?
        /// Whether any camera runs in any process, or nil when CoreMediaIO
        /// could not say.
        var readCameraInUse: @Sendable () -> Bool?
        /// Installs the system's listeners, which call `changed` — from any
        /// thread — when either answer may have changed, and returns the
        /// function that removes every one of them.
        var observe: @MainActor (_ changed: @escaping @Sendable () -> Void) -> (() -> Void)
        /// Runs a read away from the main thread (a CoreAudio property read
        /// can block on coreaudiod), and hands its answer back to it.
        var offMain: @Sendable (@escaping @Sendable () -> Void) -> Void
        var onMain: @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void
        /// Runs `work` on the main actor after `delay` seconds.
        var after: @MainActor (_ delay: TimeInterval, _ work: @escaping @MainActor @Sendable () -> Void) -> Void
        /// The bundle ids that are Isla itself and so never count.
        var ownBundleIDs: Set<String>

        static let live = Environment(
            readMicrophoneApps: { CaptureWatch.readMicrophoneApps() },
            readCameraInUse: { CaptureWatch.readCameraInUse() },
            observe: { changed in
                let observer = CaptureObserver(changed: changed)
                observer.start()
                return { observer.stop() }
            },
            offMain: { DispatchQueue.global(qos: .utility).async(execute: $0) },
            onMain: { work in DispatchQueue.main.async { MainActor.assumeIsolated { work() } } },
            after: { delay, work in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
            },
            // `com.ctimothe.isla` is named as well as the running bundle's id:
            // a `swift run` or test binary has none of its own, and the app's
            // helper processes carry the app's id.
            ownBundleIDs: Set([Bundle.main.bundleIdentifier, "com.ctimothe.isla"].compactMap { $0 })
        )
    }

    /// How long recording must stay stopped before the island says so.
    /// Zoom and FaceTime switch the input off and on again when the user
    /// changes device, and the Recording activity must ride that out rather
    /// than flash. Starting is never delayed: the whole point is to be early.
    nonisolated static let stopDebounce: TimeInterval = 0.6

    private let environment: Environment

    init(environment: Environment = .live) {
        self.environment = environment
    }

    /// Called on the main actor with each real change, never with the state
    /// it already reported.
    var onChange: ((CaptureState) -> Void)?
    private(set) var state: CaptureState = .none

    private var started = false
    private var remove: (() -> Void)?
    /// Stamps every read, so one that lands after a newer read was asked for,
    /// or after `stop`, is dropped: reads run on a global queue and two in
    /// flight can finish in either order.
    private var readSequence = 0
    /// The last answer each source gave, which a failed read falls back on.
    private var lastMicrophone: [String] = []
    private var lastCamera = false
    /// The stop that is waiting out `stopDebounce`, if any.
    private var pendingStop: Int?
    private var stopSequence = 0

    func start() {
        guard !started else { return }
        started = true
        remove = environment.observe { [weak self, onMain = environment.onMain] in
            guard let self else { return }
            onMain { self.refresh() }
        }
        refresh()
    }

    func stop() {
        guard started else { return }
        started = false
        remove?()
        remove = nil
        readSequence &+= 1
        pendingStop = nil
        lastMicrophone = []
        lastCamera = false
        // Not debounced: the watch is off, so nothing is left to flicker back.
        if state != .none {
            state = .none
            onChange?(.none)
        }
    }

    private func refresh() {
        guard started else { return }
        readSequence &+= 1
        let sequence = readSequence
        let environment = self.environment
        environment.offMain { [weak self] in
            guard let self else { return }
            let microphone = environment.readMicrophoneApps()
            let camera = environment.readCameraInUse()
            environment.onMain { self.land(sequence, microphone, camera) }
        }
    }

    private func land(_ sequence: Int, _ microphone: [String]?, _ camera: Bool?) {
        guard started, sequence == readSequence else { return }
        // A source that failed keeps its last good answer. Read as "nothing is
        // recording" it would end a call's activity on one CoreAudio hiccup.
        if let microphone { lastMicrophone = microphone }
        if let camera { lastCamera = camera }
        propose(CaptureState(microphone: lastMicrophone, camera: lastCamera, excluding: environment.ownBundleIDs))
    }

    private func propose(_ candidate: CaptureState) {
        // Back to what is already shown: a stop that was waiting is cancelled.
        if candidate == state {
            pendingStop = nil
            return
        }
        guard candidate.isEmpty else {
            pendingStop = nil
            state = candidate
            onChange?(candidate)
            return
        }
        // Recording stopped. A second empty reading while one is already
        // waiting must not push the deadline back.
        guard pendingStop == nil else { return }
        stopSequence &+= 1
        let token = stopSequence
        pendingStop = token
        environment.after(Self.stopDebounce) { [weak self] in
            guard let self, self.started, self.pendingStop == token else { return }
            self.pendingStop = nil
            self.state = .none
            self.onChange?(.none)
        }
    }

    // MARK: - Live readers

    /// Bundle ids of the apps with microphone input running, or nil when the
    /// process list could not be read. A process that vanished between the
    /// list and its own read is skipped, not an error.
    ///
    /// CoreAudio's own bundle id is the wrong name to show: on 2026-11-14 the
    /// list held Siri's listener (`com.apple.CoreSpeech`, a daemon with no
    /// app, which macOS's indicator never shows), Granola's helper, and
    /// WebKit's GPU process recording for cmux — and none of the three has
    /// an icon. Each process is named by the app responsible for it instead,
    /// which is how the menu bar's indicator names Granola and cmux.
    nonisolated static func readMicrophoneApps() -> [String]? {
        guard let processes = CaptureObserver.audioObjectIDs(
            of: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyProcessObjectList
        ) else { return nil }
        let recording = processes.compactMap { process -> pid_t? in
            guard CaptureObserver.audioUInt32(of: process, selector: kAudioProcessPropertyIsRunningInput) == 1,
                  let pid = CaptureObserver.audioUInt32(of: process, selector: kAudioProcessPropertyPID)
            else { return nil }
            return pid_t(bitPattern: pid)
        }
        return appsRecording(recording, responsible: responsibleProcess, app: appBundleID)
    }

    /// The apps behind `processes`, in their order: each one counts as the
    /// app responsible for it, or as itself when nothing is said about that,
    /// and as nothing when neither is an app. Pure, so the rule is a test.
    nonisolated static func appsRecording(
        _ processes: [pid_t], responsible: (pid_t) -> pid_t?, app: (pid_t) -> String?
    ) -> [String] {
        processes.compactMap { pid in responsible(pid).flatMap(app) ?? app(pid) }
    }

    /// The process macOS holds responsible for `pid` (a helper's app, the app
    /// a WebKit process works for), from libsystem's
    /// `responsibility_get_pid_responsible_for_pid`. Private, so resolved with
    /// `dlsym`: a macOS without it falls back to the process itself.
    nonisolated private static let responsibleFor: (@convention(c) (pid_t) -> pid_t)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    nonisolated private static func responsibleProcess(_ pid: pid_t) -> pid_t? {
        guard let responsibleFor else { return nil }
        let owner = responsibleFor(pid)
        return owner > 0 ? owner : nil
    }

    /// The bundle id of the app running as `pid`, or nil when it is not an
    /// app (a daemon, a command-line tool). `NSRunningApplication` is safe to
    /// read off the main thread.
    nonisolated private static func appBundleID(_ pid: pid_t) -> String? {
        guard let app = NSRunningApplication(processIdentifier: pid),
              app.bundleURL?.pathExtension == "app",
              let bundleID = app.bundleIdentifier, !bundleID.isEmpty
        else { return nil }
        return bundleID
    }

    /// Whether any camera is running somewhere, or nil when the device list
    /// could not be read.
    nonisolated static func readCameraInUse() -> Bool? {
        guard let devices = CaptureObserver.cameraObjectIDs() else { return nil }
        return devices.contains {
            CaptureObserver.cameraUInt32(of: $0, selector: kCMIODevicePropertyDeviceIsRunningSomewhere) == 1
        }
    }
}

/// The system listeners behind `CaptureWatch.Environment.live`.
///
/// Every mutation and every callback runs on one private serial queue, so the
/// listener tables need no lock. The lists change as apps open and close the
/// microphone (a process object appears when an app first touches audio, and
/// goes when it quits) and as cameras are plugged in, so each list listener
/// re-installs the per-object listeners that watch the `IsRunning` flag
/// itself. `stop` removes every one of them, waits for the queue to drain,
/// and from then on no callback gets through.
final class CaptureObserver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.ctimothe.isla.capture-watch")
    private let changed: @Sendable () -> Void
    private var stopped = false

    private var microphoneListListener: AudioObjectPropertyListenerBlock?
    private var microphoneListener: AudioObjectPropertyListenerBlock?
    private var microphoneObjects: Set<AudioObjectID> = []
    private var cameraListListener: CMIOObjectPropertyListenerBlock?
    private var cameraListener: CMIOObjectPropertyListenerBlock?
    private var cameraObjects: Set<CMIOObjectID> = []

    init(changed: @escaping @Sendable () -> Void) {
        self.changed = changed
    }

    func start() {
        queue.async { [self] in
            guard !stopped else { return }
            let microphoneList: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self, !self.stopped else { return }
                self.syncMicrophone()
                self.changed()
            }
            let microphone: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self, !self.stopped else { return }
                self.changed()
            }
            let cameraList: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self, !self.stopped else { return }
                self.syncCameras()
                self.changed()
            }
            let camera: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self, !self.stopped else { return }
                self.changed()
            }
            microphoneListListener = microphoneList
            microphoneListener = microphone
            cameraListListener = cameraList
            cameraListener = camera
            var micAddress = Self.audioAddress(kAudioHardwarePropertyProcessObjectList)
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &micAddress, queue, microphoneList
            )
            var camAddress = Self.cameraAddress(kCMIOHardwarePropertyDevices)
            CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &camAddress, queue, cameraList)
            syncMicrophone()
            syncCameras()
        }
    }

    func stop() {
        queue.sync { [self] in
            stopped = true
            var micAddress = Self.audioAddress(kAudioHardwarePropertyProcessObjectList)
            if let microphoneListListener {
                AudioObjectRemovePropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject), &micAddress, queue, microphoneListListener
                )
            }
            var runningAddress = Self.audioAddress(kAudioProcessPropertyIsRunningInput)
            if let microphoneListener {
                for object in microphoneObjects {
                    AudioObjectRemovePropertyListenerBlock(object, &runningAddress, queue, microphoneListener)
                }
            }
            var camAddress = Self.cameraAddress(kCMIOHardwarePropertyDevices)
            if let cameraListListener {
                CMIOObjectRemovePropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &camAddress, queue, cameraListListener)
            }
            var deviceAddress = Self.cameraAddress(kCMIODevicePropertyDeviceIsRunningSomewhere)
            if let cameraListener {
                for object in cameraObjects {
                    CMIOObjectRemovePropertyListenerBlock(object, &deviceAddress, queue, cameraListener)
                }
            }
            microphoneObjects = []
            cameraObjects = []
            microphoneListListener = nil
            microphoneListener = nil
            cameraListListener = nil
            cameraListener = nil
        }
    }

    /// Brings the per-process listeners in line with the process list. A list
    /// that could not be read leaves them as they are.
    private func syncMicrophone() {
        guard let listener = microphoneListener,
              let now = Self.audioObjectIDs(
                  of: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyProcessObjectList
              ).map(Set.init)
        else { return }
        var address = Self.audioAddress(kAudioProcessPropertyIsRunningInput)
        for object in now.subtracting(microphoneObjects) {
            AudioObjectAddPropertyListenerBlock(object, &address, queue, listener)
        }
        for object in microphoneObjects.subtracting(now) {
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, listener)
        }
        microphoneObjects = now
    }

    private func syncCameras() {
        guard let listener = cameraListener, let now = Self.cameraObjectIDs().map(Set.init) else { return }
        var address = Self.cameraAddress(kCMIODevicePropertyDeviceIsRunningSomewhere)
        for object in now.subtracting(cameraObjects) {
            CMIOObjectAddPropertyListenerBlock(object, &address, queue, listener)
        }
        for object in cameraObjects.subtracting(now) {
            CMIOObjectRemovePropertyListenerBlock(object, &address, queue, listener)
        }
        cameraObjects = now
    }

    // MARK: - Property reads

    private static func audioAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func cameraAddress(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
    }

    /// An array of object ids, or nil when either CoreAudio call failed.
    static func audioObjectIDs(of object: AudioObjectID, selector: AudioObjectPropertySelector) -> [AudioObjectID]? {
        var address = audioAddress(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard !ids.isEmpty else { return [] }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return nil }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func audioUInt32(of object: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = audioAddress(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func audioBundleID(of object: AudioObjectID) -> String? {
        var address = audioAddress(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue() as String?, !string.isEmpty
        else { return nil }
        return string
    }

    static func cameraObjectIDs() -> [CMIOObjectID]? {
        var address = cameraAddress(kCMIOHardwarePropertyDevices)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return nil }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        guard !ids.isEmpty else { return [] }
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size, &used, &ids
        ) == noErr else { return nil }
        return Array(ids.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }

    static func cameraUInt32(of object: CMIOObjectID, selector: Int) -> UInt32? {
        var address = cameraAddress(selector)
        var value: UInt32 = 0
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(
            object, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value
        ) == noErr else { return nil }
        return value
    }
}
