import AppKit
import CoreAudio

// MARK: - Whose volume

/// Whose volume the lyric stage's speaker moves (owner, 2026-10-26: "when the
/// lyrics screen is open we need a button to change the volume of the song").
///
/// Music and Spotify each keep a volume of their own (`sound volume` in their
/// scripting dictionaries, 0…100) under the Mac's output, so for them the
/// control is the song's volume and nothing else on the Mac gets quieter. No
/// other app's level is reachable from outside it — a per-app volume for a
/// browser would mean tapping its audio, which needs a recording permission
/// the owner ruled out — so for every other source it is the Mac's output,
/// and the label says so ("Volume", not "Safari volume").
enum PlayerVolumeTarget: Equatable {
    case app(PlayerApp)
    case system

    /// The player whose own volume the control moves for a session from
    /// `bundleID`, or the Mac's output for any other source and for none.
    static func forSource(bundleID: String?) -> PlayerVolumeTarget {
        guard let bundleID, let app = PlayerApp.allCases.first(where: { $0.bundleID == bundleID }) else {
            return .system
        }
        return .app(app)
    }

    /// What VoiceOver and the tooltip call the control: whose volume it is.
    var label: String {
        switch self {
        case .app(.music): return localized("Music volume")
        case .app(.spotify): return localized("Spotify volume")
        case .system: return localized("Volume")
        }
    }
}

// MARK: - The seams

/// The Apple Events half: Music's or Spotify's own volume. The live one is
/// `PlayerBridge`, whose one serial script queue keeps every event off the
/// main thread; completions arrive on the main actor with the event's outcome,
/// so a refusal (-1743) can be told from a player that only went quiet.
@MainActor
protocol PlayerVolumeScripting: AnyObject {
    func readVolume(of app: PlayerApp, completion: @escaping @MainActor @Sendable (_ percent: Int?, _ outcome: OSStatus) -> Void)
    func writeVolume(_ percent: Int, to app: PlayerApp, completion: @escaping @MainActor @Sendable (_ outcome: OSStatus) -> Void)
}

/// The Mac's output half, over the same `VolumeOutput` the volume keys'
/// writer uses (`SystemVolumeOutput`: the control resolved once per device,
/// a level stepped on one device never written to another).
@MainActor
protocol MacVolumeAccess: AnyObject {
    func read(completion: @escaping @MainActor @Sendable (VolumeState?) -> Void)
    /// Writes `target` to `from.device` only while that is still the default
    /// output; `.deviceChanged` says it is not (or is gone) and nothing was
    /// written.
    func write(_ target: VolumeState, from: VolumeState, completion: @escaping @MainActor @Sendable (VolumeWriteResult) -> Void)
}

/// `PlayerBridge`, as the scripting seam.
@MainActor
final class PlayerBridgeVolumeScripter: PlayerVolumeScripting {
    func readVolume(of app: PlayerApp, completion: @escaping @MainActor @Sendable (Int?, OSStatus) -> Void) {
        PlayerBridge.soundVolume(of: app, completion: completion)
    }

    func writeVolume(_ percent: Int, to app: PlayerApp, completion: @escaping @MainActor @Sendable (OSStatus) -> Void) {
        PlayerBridge.setSoundVolume(percent, of: app, completion: completion)
    }
}

/// The Mac's output through `VolumeOutput`, on a queue of its own: CoreAudio
/// while music plays can take milliseconds a call, and the drag that causes
/// these is drawn on the main thread.
///
/// **It follows the default output itself.** The control keeps the device it
/// last read and installs no listener while closed or open, and the shared
/// `SystemVolumeOutput.write` no longer re-checks the default (the volume
/// keys' applier re-aims on the CoreAudio default-output event instead). So
/// the check lives here, on this queue and ahead of the one writer: a write
/// whose `from.device` is not the default any more is not made and answers
/// `.deviceChanged`, which `PlayerVolume` turns into a re-read of the new
/// default and the same write onto it. Without it, after the output switched
/// from the speakers to AirPods (the speakers still present) every drag went
/// on changing the speakers and reported `.written`.
@MainActor
final class MacVolume: MacVolumeAccess {
    private let output: VolumeOutput
    private let currentDevice: @Sendable () -> AudioDeviceID?
    private let queue = DispatchQueue(label: "com.ctimothe.isla.player-volume.mac", qos: .userInitiated)

    init(output: VolumeOutput, currentDevice: @escaping @Sendable () -> AudioDeviceID? = { AudioOutputs.current() }) {
        self.output = output
        self.currentDevice = currentDevice
    }

    func read(completion: @escaping @MainActor @Sendable (VolumeState?) -> Void) {
        let output = output
        queue.async {
            let state = output.read()
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(state) } }
        }
    }

    func write(_ target: VolumeState, from: VolumeState, completion: @escaping @MainActor @Sendable (VolumeWriteResult) -> Void) {
        let output = output
        let currentDevice = currentDevice
        queue.async {
            let result = currentDevice() == from.device
                ? output.write(level: target.level, muted: target.muted, from: from)
                : .deviceChanged
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }
}

/// The stand-ins a test process gets by default: they answer nothing and
/// write nothing, so no test can send a real Apple Event or move the Mac's
/// volume through a stage it happened to draw.
@MainActor
final class InertPlayerVolumeScripter: PlayerVolumeScripting {
    func readVolume(of app: PlayerApp, completion: @escaping @MainActor @Sendable (Int?, OSStatus) -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { completion(nil, OSStatus(noErr)) } }
    }

    func writeVolume(_ percent: Int, to app: PlayerApp, completion: @escaping @MainActor @Sendable (OSStatus) -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { completion(OSStatus(noErr)) } }
    }
}

@MainActor
final class InertMacVolume: MacVolumeAccess {
    func read(completion: @escaping @MainActor @Sendable (VolumeState?) -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { completion(nil) } }
    }

    func write(_ target: VolumeState, from: VolumeState, completion: @escaping @MainActor @Sendable (VolumeWriteResult) -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { completion(.failed) } }
    }
}

// MARK: - Newest wins

/// One write in flight and the newest value waiting: the volume keys' rule
/// (`SystemLevelApplier`), for writes that answer through a completion.
///
/// A drag delivers 60 to 120 events a second and an Apple Event to Spotify
/// can take tens of milliseconds — longer while the Automation prompt is up.
/// Sending one per event queued a backlog on `PlayerBridge`'s one script
/// queue, and the player went on stepping through levels the finger had left
/// long ago, with a play tap stuck behind them. Here a value that arrives
/// while one is in flight replaces whatever was waiting, so however slow the
/// player is, it gets the write in flight and then the newest level.
@MainActor
final class LatestWinsSender<Value> {
    private let send: (Value, @escaping @MainActor () -> Void) -> Void
    private(set) var inFlight = false
    private(set) var pending: Value?

    /// `send` must call its second argument exactly once, when the write is done.
    init(send: @escaping (Value, @escaping @MainActor () -> Void) -> Void) {
        self.send = send
    }

    func submit(_ value: Value) {
        if inFlight {
            pending = value
        } else {
            start(value)
        }
    }

    /// Forgets the waiting value: its target went away (a refusal).
    func dropPending() { pending = nil }

    private func start(_ value: Value) {
        inFlight = true
        send(value) { [weak self] in self?.finished() }
    }

    private func finished() {
        if let next = pending {
            pending = nil
            start(next)
        } else {
            inFlight = false
        }
    }
}

// MARK: - The control

/// The lyric stage's volume control (spec §19.6, amended 2026-10-26).
///
/// **Nothing runs while it is closed.** It reads only when the person opens
/// it, and again when the song's source changes under an open one — no timer,
/// no listener. So the one-time "Isla wants to control Spotify" prompt appears
/// when the speaker is first pressed for that player, never at launch or on
/// opening the stage. A player whose Automation is already known to be refused
/// is not asked at all.
///
/// **The drawn level is the intended one.** A drag sets `level` at once and
/// hands the value to a `LatestWinsSender`; the bar never waits for the player
/// or CoreAudio to agree, as the volume keys predict first (2026-10-25).
///
/// **A refusal falls back once.** An answer of -1743 (errAEEventNotPermitted)
/// moves the control to the Mac's volume, re-reads it, and sets `refused`,
/// which the stage shows as one line offering Automation settings — the one
/// failure surface for it. The finger's value is not replayed onto the Mac:
/// 40 % of Spotify is not 40 % of the speakers, and a jump there would be a
/// surprise.
@MainActor
final class PlayerVolume: ObservableObject {
    /// The one the stage uses. Built inert inside a test process.
    static var shared = PlayerVolume()

    /// How long an open control waits untouched before it folds back.
    static let idleTimeout: TimeInterval = 3

    /// Whose volume the source asks for (`PlayerVolumeTarget.forSource`).
    @Published private(set) var source: PlayerVolumeTarget = .system
    /// Whose volume a move actually changes: the source's, or the Mac's when
    /// that player's Automation is refused.
    @Published private(set) var target: PlayerVolumeTarget = .system
    /// 0…1 as drawn: the intended level, nil until a read or a move says.
    @Published private(set) var level: Double?
    /// The Mac's output is muted (the system target only).
    @Published private(set) var muted = false
    /// The player whose Automation was refused, while the control falls back
    /// to the Mac for it.
    @Published private(set) var refused: PlayerApp?
    @Published private(set) var isOpen = false
    @Published private(set) var isDragging = false

    private let scripter: PlayerVolumeScripting
    private let mac: MacVolumeAccess
    private let consent: @MainActor (PlayerApp) -> AutomationConsent
    private let schedule: MediaKeyHUD.Scheduler

    /// The Mac's output as last read or written: the `from` of the next write.
    private var macState: VolumeState?
    /// Bumped by every read and every move: a read's answer that comes back
    /// after a move, or after the source changed, is stale and is dropped.
    private var epoch = 0
    /// Bumped whenever the target is decided again (a new source, a fall
    /// back). A write's completion carries the value it was sent under, so an
    /// answer from a player the control has since left is told apart from one
    /// it is still waiting on.
    private var targetGeneration = 0
    private var cancelIdle: (() -> Void)?
    private lazy var sender = LatestWinsSender<Write> { [weak self] write, done in
        guard let self else { return done() }
        self.perform(write, done: done)
    }

    private struct Write {
        var target: PlayerVolumeTarget
        var level: Double
    }

    init(
        scripter: PlayerVolumeScripting? = nil,
        mac: MacVolumeAccess? = nil,
        consent: (@MainActor (PlayerApp) -> AutomationConsent)? = nil,
        schedule: MediaKeyHUD.Scheduler? = nil
    ) {
        let quiet = PlayerBridge.isRunningTests
        self.scripter = scripter ?? (quiet ? InertPlayerVolumeScripter() : PlayerBridgeVolumeScripter())
        self.mac = mac ?? (quiet ? InertMacVolume() : MacVolume(output: SystemVolumeOutput()))
        self.consent = consent ?? { AutomationAccess.shared.status($0) }
        self.schedule = schedule ?? MediaKeyHUD.mainQueueScheduler
    }

    // MARK: Reading the state

    /// The speaker's glyph for the level drawn: slashed at 0 or muted, then
    /// the system's own steps, as the menu bar's Sound item draws them.
    static func symbol(level: Double?, muted: Bool) -> String {
        guard let level else { return "speaker.wave.2.fill" }
        if muted || level <= 0 { return "speaker.slash.fill" }
        switch level {
        case ..<0.1: return "speaker.fill"
        case ..<0.4: return "speaker.wave.1.fill"
        case ..<0.7: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    var symbol: String { Self.symbol(level: level, muted: target == .system && muted) }

    /// VoiceOver's value: "40%", which it speaks as "40 percent"; "Muted"
    /// for a muted Mac; nothing before the first read.
    static func spokenValue(level: Double?, muted: Bool, locale: Locale = .current) -> String {
        if muted { return localized("Muted") }
        guard let level else { return "" }
        return min(max(level, 0), 1).formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }

    var spokenValue: String { Self.spokenValue(level: level, muted: target == .system && muted) }

    var label: String { target.label }

    // MARK: The source

    /// The song's source, by bundle id. An open control reads the new
    /// target's level; a closed one only forgets the old one, so the glyph
    /// does not claim Spotify's level over a browser.
    func sourceChanged(bundleID: String?) {
        let next = PlayerVolumeTarget.forSource(bundleID: bundleID)
        guard next != source else { return }
        source = next
        refused = nil
        targetGeneration += 1
        resolveTarget()
        level = nil
        muted = false
        epoch += 1
        if isOpen { read() }
    }

    private func resolveTarget() {
        if case let .app(app) = source, consent(app) == .denied {
            target = .system
            refused = app
        } else {
            target = source
        }
    }

    // MARK: Open and close

    func open() {
        guard !isOpen else { return armIdle() }
        isOpen = true
        // A refusal is kept across openings so the player is not sent an
        // event that only earns another -1743, but only while it still
        // stands. The fallback line offers Automation settings, and granting
        // access there used to change nothing until the song's source changed
        // or Isla restarted (Codex review, 2026-11-04). Only a definite
        // `.allowed` lifts it: an unknown answer keeps the Mac's volume.
        if let app = refused, consent(app) == .allowed {
            refused = nil
            targetGeneration += 1
            level = nil
        }
        if refused == nil { resolveTarget() }
        read()
        armIdle()
    }

    func close() {
        isOpen = false
        isDragging = false
        cancelIdle?()
        cancelIdle = nil
    }

    func toggle() { isOpen ? close() : open() }

    private func armIdle() {
        cancelIdle?()
        cancelIdle = schedule(Self.idleTimeout) { [weak self] in
            guard let self, !self.isDragging else { return }
            self.close()
        }
    }

    // MARK: Moving it

    func dragChanged(fraction: Double) {
        isDragging = true
        cancelIdle?()
        cancelIdle = nil
        set(fraction)
    }

    func dragEnded() {
        isDragging = false
        if isOpen { armIdle() }
    }

    /// VoiceOver's step, or any one discrete move. Before the first read
    /// there is nothing to step from, so the control opens and reads.
    func step(up: Bool) {
        guard let level else { return open() }
        set(level + (up ? SeekAccessibility.volumeStep : -SeekAccessibility.volumeStep))
        if isOpen { armIdle() }
    }

    /// Sets the drawn level now and hands the write to the sender.
    func set(_ fraction: Double) {
        let next = min(max(fraction, 0), 1)
        epoch += 1
        level = next
        if target == .system, muted, next > 0 { muted = false }
        sender.submit(Write(target: target, level: next))
    }

    // MARK: The machine

    private func read() {
        epoch += 1
        let asked = epoch
        switch target {
        case let .app(app):
            scripter.readVolume(of: app) { [weak self] percent, outcome in
                guard let self else { return }
                // Ownership first, for a refusal as for an answer: a Spotify
                // read still pending when the song moved to Music used to be
                // refused later (-1743) and replace Music's target with the
                // Mac's, under a Spotify refusal line the person never earned.
                guard asked == self.epoch, self.target == .app(app) else { return }
                if outcome == AutomationAccess.refused { return self.fallBack(from: app) }
                guard let percent else { return }
                self.level = Double(min(max(percent, 0), 100)) / 100
            }
        case .system:
            mac.read { [weak self] state in
                guard let self else { return }
                self.macState = state ?? self.macState
                guard asked == self.epoch, self.target == .system, let state else { return }
                self.level = Double(state.level)
                self.muted = state.muted
            }
        }
    }

    private func perform(_ write: Write, done: @escaping @MainActor () -> Void) {
        switch write.target {
        case let .app(app):
            guard target == .app(app) else { return done() }
            let percent = Int((write.level * 100).rounded())
            let owner = targetGeneration
            scripter.writeVolume(percent, to: app) { [weak self] outcome in
                // The same ownership rule as a read: a refusal from a player
                // the control has left (the source changed while the event was
                // in flight) is not about the target it holds now.
                if outcome == AutomationAccess.refused, let self,
                   owner == self.targetGeneration, self.target == .app(app) {
                    self.fallBack(from: app)
                }
                done()
            }
        case .system:
            guard target == .system else { return done() }
            if let from = macState {
                return writeMac(write.level, from: from, mayRetry: true, done: done)
            }
            // A click before the opening read has answered has no state to
            // write from. It used to be dropped here while the bar drew it,
            // and the read then came back stale behind the move, so 90 % stood
            // on the bar with nothing written (Codex review, 2026-11-04). The
            // write stays in flight through a read of its own instead, so a
            // newer move still waits behind it as the newest.
            mac.read { [weak self] state in
                guard let self else { return done() }
                self.macState = state ?? self.macState
                guard self.target == .system, let from = self.macState else { return done() }
                self.writeMac(write.level, from: from, mayRetry: true, done: done)
            }
        }
    }

    /// One write to the Mac's output, `from` the state last read.
    ///
    /// `.deviceChanged` means the default output is no longer the device the
    /// state came from. The control then reads the current default and, unless
    /// a newer value is already waiting (which will go to it), sends the same
    /// level there once: the finger is on the slider for whatever the Mac
    /// plays through now, and the read keeps the next write aimed at it.
    private func writeMac(_ fraction: Double, from: VolumeState, mayRetry: Bool, done: @escaping @MainActor () -> Void) {
        let level = Float(fraction)
        // Raising a muted Mac unmutes it, as the volume keys do; a drag to
        // the very bottom leaves the mute alone.
        let muted = from.muted && !SystemVolume.unmutes(muted: from.muted, newLevel: level)
        let next = VolumeState(device: from.device, level: level, muted: muted)
        mac.write(next, from: from) { [weak self] result in
            guard let self else { return done() }
            switch result {
            case .written:
                self.macState = next
                done()
            case .deviceChanged:
                self.mac.read { [weak self] state in
                    guard let self else { return done() }
                    self.macState = state ?? self.macState
                    guard mayRetry, self.target == .system, self.sender.pending == nil,
                          let state, state.device != from.device
                    else { return done() }
                    self.writeMac(fraction, from: state, mayRetry: false, done: done)
                }
            case .failed:
                done()
            }
        }
    }

    /// The player refused Automation: the control becomes the Mac's, once.
    private func fallBack(from app: PlayerApp) {
        guard refused != app || target != .system else { return }
        refused = app
        target = .system
        sender.dropPending()
        level = nil
        read()
    }

    /// System Settings › Privacy & Security › Automation, from the stage's
    /// fallback line.
    static func openAutomationSettings() {
        NSWorkspace.shared.open(SettingsPane.automationSettingsURL)
    }
}
