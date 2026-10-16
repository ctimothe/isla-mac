import Combine
import CoreAudio
import Foundation

/// The Mac's audio output devices, and which one is currently in use.
///
/// The lock card's device glyph is the one control on it that is not transport:
/// the reference cards put the output device there, and a glyph that names a
/// device but cannot change it is decoration. Switching the *system's* default
/// output is the honest reading of that button — no app's audio can be moved
/// individually from outside it, but every app follows the default, which is
/// what "play it on the speakers instead" means in practice.
enum AudioOutputs {
    struct Output: Identifiable, Equatable {
        let id: AudioDeviceID
        let name: String
        /// Transport as CoreAudio reports it, for choosing a glyph.
        let transport: UInt32
        /// What the device says it *is*, where it says so. Nil for everything
        /// that publishes no data source, which is most things on a wire.
        var dataSource: UInt32?

        var symbol: String {
            AudioOutputs.symbol(forTransport: transport, dataSource: dataSource, name: name)
        }
    }

    /// Every device that can actually play something.
    static func available() -> [Output] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }

        return ids.compactMap { output(id: $0) }
    }

    /// One device as the picker lists it, or nil when it is not an output the
    /// picker would show. The single-device half of `available()`: the volume
    /// pop-up needs one glyph and used to walk every device on the Mac to get it.
    static func output(id: AudioDeviceID) -> Output? {
        guard hasOutputStreams(id),
              isListable(canBeDefault: flag(kAudioDevicePropertyDeviceCanBeDefaultDevice,
                                            scope: kAudioDevicePropertyScopeOutput, of: id),
                         isHidden: flag(kAudioDevicePropertyIsHidden,
                                        scope: kAudioObjectPropertyScopeGlobal, of: id)),
              let name = name(of: id) else { return nil }
        return Output(id: id, name: name, transport: transport(of: id), dataSource: dataSource(of: id))
    }

    /// Whether a device belongs in the picker (K-009). A Teams or Loopback
    /// sub-device that says it cannot be the default output, or one CoreAudio
    /// marks hidden, used to sit in the list as a row that did nothing when
    /// tapped — `select` is refused for it. Nil is a device that does not
    /// publish the property, which is most real outputs, so an unanswered
    /// question lists the device rather than hiding a working one. Pure, so
    /// the rule is held by a test without a sound card.
    static func isListable(canBeDefault: Bool?, isHidden: Bool?) -> Bool {
        canBeDefault != false && isHidden != true
    }

    /// The device everything currently plays through.
    static func current() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        ) == noErr, id != 0 else { return nil }
        return id
    }

    /// Sends everything to a different device. Returns whether it took.
    @discardableResult
    static func select(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = device
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &id
        ) == noErr
    }

    /// The symbol that says what kind of thing is playing the music. Pure, so
    /// the mapping is testable without a sound card.
    /// Data-source codes CoreAudio publishes for the built-in device. Four
    /// characters, the same shape as a transport type.
    enum DataSource {
        static let internalSpeaker: UInt32 = 0x69737063  // 'ispk'
        static let headphones: UInt32 = 0x6864706E       // 'hdpn'
        static let externalSpeaker: UInt32 = 0x65737063  // 'espk'
    }

    /// The glyph for a device, preferring what it says it *is* over what it is
    /// plugged into.
    ///
    /// Transport alone gets the built-in Mac wrong the moment something is in
    /// the headphone jack: the transport is still `bltn`, and the card would
    /// keep drawing a laptop while the sound went to headphones. The data
    /// source is the field that knows, so it is asked first.
    static func symbol(
        forTransport transport: UInt32, dataSource: UInt32? = nil, name: String? = nil
    ) -> String {
        // The device's own name first, because it is the only thing that tells
        // AirPods Pro from AirPods Max: both arrive over Bluetooth, both publish
        // no data source, and CoreAudio has no notion of a product family. The
        // system's own output menu draws the same distinction, and these are the
        // symbols Apple ships for it — not lookalikes.
        //
        // Matching on a product name is a heuristic, and it is used only to pick
        // a *better* glyph: anything unrecognised falls through to the transport
        // below and is merely generic, never wrong. Product names are the same
        // in every language, which is what makes this survive a localised Mac.
        if let name = name?.lowercased() {
            if name.contains("airpods max") { return "airpods.max" }
            if name.contains("airpods pro") { return "airpods.pro" }
            if name.contains("airpods") { return "airpods" }
            if name.contains("beats") || name.contains("powerbeats") { return "beats.headphones" }
            if name.contains("homepod") { return "homepod" }
            if name.contains("apple tv") { return "appletv" }
            if name.contains("studio display") || name.contains("pro display") { return "display" }
            // Wired Apple headphones, and the generic word every third-party
            // headset puts in its name.
            if name.contains("earpods") || name.contains("headphone")
                || name.contains("headset") || name.contains("earbud") {
                return "headphones"
            }
        }
        switch dataSource {
        case DataSource.headphones: return "headphones"
        case DataSource.internalSpeaker: return "laptopcomputer"
        case DataSource.externalSpeaker: return "hifispeaker"
        default: break
        }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "tv"
        // Neutral on purpose. USB is a wire, not a kind of thing: USB-C EarPods
        // and a pair of studio monitors arrive identically, publish no data
        // source, and nothing else in CoreAudio distinguishes them. This used
        // to draw a floor-standing speaker, which is confidently wrong for the
        // commonest case of the two. A generic output glyph is merely vague.
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeFireWire: return "speaker.wave.2"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return "waveform"
        default: return "speaker.wave.2"
        }
    }

    /// The glyph for the device the sound goes to now, or `fallback` when the
    /// list does not hold it (nothing read yet, no default, a device that has
    /// just gone). The one place that turns "which device is current" into a
    /// symbol, so the lock card's foot rail and the island's Output button name
    /// the same device the same way; each passes the fallback that suits it —
    /// the card's AirPlay glyph, the island's plain speaker.
    static func symbol(outputs: [Output], current: AudioDeviceID?, fallback: String) -> String {
        guard let current, let device = outputs.first(where: { $0.id == current }) else { return fallback }
        return device.symbol
    }

    /// What the island's Output button draws before it knows where the sound
    /// goes: a speaker says "output" without naming a device it has not seen.
    static let outputFallbackSymbol = "speaker.wave.2"

    // MARK: - Output latency

    /// What CoreAudio says a device adds between a sample being handed to it
    /// and the sample leaving it, in frames, with the rate that turns frames
    /// into time.
    ///
    /// Reported, not measured: it is the device's own account of itself, and
    /// a Bluetooth headset's account covers the Mac's side of the radio link
    /// at best. The lyric lead logs it per route so the owner's live session
    /// can compare it with what an ear finds (`LyricLeadModel.outputLatency`).
    struct OutputLatency: Equatable, Sendable {
        let sampleRate: Double
        let deviceFrames: UInt32
        let safetyOffsetFrames: UInt32
        let bufferFrames: UInt32
        let streamFrames: UInt32

        /// The sum the lyric lab read for L7: device latency, safety offset,
        /// one IO buffer and the first output stream's own latency.
        var frames: Double {
            Double(deviceFrames) + Double(safetyOffsetFrames) + Double(bufferFrames) + Double(streamFrames)
        }

        /// Nil for a device that reports no nominal rate, which has no
        /// latency to give rather than an infinite one.
        var seconds: TimeInterval? {
            sampleRate > 0 ? frames / sampleRate : nil
        }
    }

    /// The output latency of one device, as CoreAudio reports it, or nil when
    /// the device cannot be read at all. A property the device does not
    /// publish counts as zero frames — most devices publish no stream
    /// latency, and that is not a reason to know nothing.
    static func outputLatency(of id: AudioDeviceID) -> OutputLatency? {
        // Two concrete readers rather than one generic one: CoreAudio writes
        // through a raw pointer, and the compiler rightly will not vouch for
        // an arbitrary `T` there (a generic reader warns on exactly this).
        // Every property read here is a UInt32 except the rate.
        func frames(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope,
                    of object: AudioObjectID) -> UInt32? {
            var result: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            var address = AudioObjectPropertyAddress(
                mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain
            )
            return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr ? result : nil
        }
        let output = kAudioDevicePropertyScopeOutput
        let global = kAudioObjectPropertyScopeGlobal
        var rate: Float64 = 0
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        var rateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate, mScope: global,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(id, &rateAddress, 0, nil, &rateSize, &rate) == noErr else {
            return nil
        }

        var stream: UInt32 = 0
        var streamsSize: UInt32 = 0
        var streamsAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams, mScope: output, mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyDataSize(id, &streamsAddress, 0, nil, &streamsSize) == noErr, streamsSize > 0 {
            var streams = [AudioStreamID](repeating: 0, count: Int(streamsSize) / MemoryLayout<AudioStreamID>.size)
            if AudioObjectGetPropertyData(id, &streamsAddress, 0, nil, &streamsSize, &streams) == noErr,
               let first = streams.first {
                stream = frames(kAudioStreamPropertyLatency, scope: global, of: first) ?? 0
            }
        }
        return OutputLatency(
            sampleRate: rate,
            deviceFrames: frames(kAudioDevicePropertyLatency, scope: output, of: id) ?? 0,
            safetyOffsetFrames: frames(kAudioDevicePropertySafetyOffset, scope: output, of: id) ?? 0,
            bufferFrames: frames(kAudioDevicePropertyBufferFrameSize, scope: global, of: id) ?? 0,
            streamFrames: stream
        )
    }

    // MARK: - One device

    /// What the device says it is, when it says so. Absent on most things that
    /// arrive over a wire, which is why it is optional rather than a default.
    private static func dataSource(of id: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    /// A UInt32 yes-or-no property, or nil when the device does not publish it.
    private static func flag(
        _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope, of id: AudioDeviceID
    ) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    private static func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr else { return false }
        let list = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }

    private static func name(of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // Unmanaged, because CoreAudio hands back a string the caller owns
        // (+1), written through a raw pointer Swift cannot see. Read into a
        // `CFString` variable, it balanced only by accident — the placeholder
        // overwritten without a release, and Swift's release at the end of the
        // scope happening to consume CoreAudio's — and the compiler said as
        // much. Taken retained, the ownership is stated rather than assumed.
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr,
              let name else { return nil }
        let string = name.takeRetainedValue() as String
        return string.isEmpty ? nil : string
    }

    static func transport(of id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport) == noErr else { return 0 }
        return transport
    }
}

/// Watches the system's default output device and its volume while held open.
///
/// The lock card needs what this publishes twice over: once for its first
/// frame, and then again whenever the machine moves underneath it. The second
/// half is the one the card never had — AirPods connecting mid-lock, or the
/// volume keys, changed the default output and its level behind the card's
/// back, leaving the picker highlighting a device that was no longer playing
/// and a bar that had drifted, until a pane switch happened to re-read. The
/// system's own lock-screen widgets follow these changes, and a card that
/// imitates them follows them too.
///
/// The machine is injected. `read`, `readVolume`, the two listener closures
/// and `debounce` default to the CoreAudio and main-queue implementations at
/// the foot of this class and are overridden by the tests, so every behaviour
/// of the watch is driven without a sound
/// card. The glue itself is the one deliberately untested layer in this file;
/// it stays thin — every decision is made by the tested code above it, and
/// what remains is only the translation of those decisions into
/// `AudioObjectAdd/RemovePropertyListenerBlock` calls, which is precisely the
/// part a test with no device could only rehearse.
@MainActor
final class AudioWatch: ObservableObject {
    @Published private(set) var outputs: [AudioOutputs.Output] = []
    @Published private(set) var current: AudioDeviceID? = nil
    @Published private(set) var volume: Float? = nil
    /// Whether the default output is muted (G-023). A muted Mac drew a
    /// live-looking bar on the card, because mute was never read.
    @Published private(set) var muted = false

    /// One reading of the machine: what can play, what does, how loud.
    typealias Read = () -> (outputs: [AudioOutputs.Output], current: AudioDeviceID?, volume: Float?)

    private let read: Read
    /// The level alone, for the volume listener (F-045). Every write the lock
    /// card's bar made fired that listener, and it used to run `read` — every
    /// device's streams, name, transport and data source — once per pointer
    /// event to learn one float.
    private let readVolume: () -> Float?
    /// The mute alone, read wherever the level is.
    private let readMuted: () -> Bool
    private var installListeners: () -> Void
    private var removeListeners: () -> Void
    /// Runs the device-list re-read once a burst of notifications has settled.
    private let debounce: (@escaping @Sendable () -> Void) -> Void

    /// The device the volume listener is attached to. The listener must follow
    /// the default, and this is what tells the watch when it has to move.
    private var listeningTo: AudioDeviceID?
    private var running = false
    /// A device-list re-read is scheduled and has not run yet.
    private var devicesReadPending = false

    /// How long a device-list burst is given to settle. One plug sends the
    /// list change several times as the device's streams come up, and a read
    /// in the middle of that can catch a device with no name yet.
    static let devicesSettle: TimeInterval = 0.15

    init(
        read: Read? = nil,
        readVolume: (() -> Float?)? = nil,
        readMuted: (() -> Bool)? = nil,
        installListeners: (() -> Void)? = nil,
        removeListeners: (() -> Void)? = nil,
        debounce: ((@escaping @Sendable () -> Void) -> Void)? = nil
    ) {
        self.read = read ?? { (AudioOutputs.available(), AudioOutputs.current(), SystemVolume.current()) }
        // An injected `read` answers for the volume too, unless the test says
        // otherwise: the card's render tests inject only `read`, and must
        // never reach the machine's own level through the default here.
        if let readVolume {
            self.readVolume = readVolume
        } else if let read {
            self.readVolume = { read().volume }
        } else {
            self.readVolume = { SystemVolume.current() }
        }
        // The same rule for the mute: a watch with any reading injected is a
        // test's, and is not muted unless the test says so.
        if let readMuted {
            self.readMuted = readMuted
        } else if read != nil || readVolume != nil {
            self.readMuted = { false }
        } else {
            self.readMuted = { SystemVolume.isMuted() }
        }
        self.debounce = debounce ?? { work in
            DispatchQueue.main.asyncAfter(deadline: .now() + AudioWatch.devicesSettle, execute: work)
        }
        self.installListeners = installListeners ?? {}
        self.removeListeners = removeListeners ?? {}
        // All stored properties are initialised, so the production defaults
        // may capture self now. Anything injected stays exactly as given. The
        // closures read the actor-owned state here — on the main actor, where
        // every caller runs — and hand the glue its devices as values, so the
        // untested layer holds no state of its own beyond the registrations.
        if installListeners == nil {
            self.installListeners = { [weak self] in
                guard let self else { return }
                self.installCoreAudioListeners(
                    attachingVolumeTo: self.current,
                    removingVolumeFrom: self.listeningTo
                )
            }
        }
        if removeListeners == nil {
            self.removeListeners = { [weak self] in
                guard let self else { return }
                self.removeCoreAudioListeners(removingVolumeFrom: self.listeningTo)
            }
        }
    }

    /// The full re-read: the entry the default-output listener calls, the
    /// tests drive in its place, and the card calls on a pane change. Every
    /// "the route may have moved" moment lands here and publishes only what
    /// actually moved. It enumerates every device, which is why the volume
    /// listener no longer comes here (see `volumeChanged`).
    func systemAudioChanged() {
        DebugTrail.note("audio watch: full read")
        refresh()
    }

    /// The volume listener's entry: the level and nothing else (F-045). A
    /// volume change cannot move the default or the device list — those have
    /// listeners of their own — so the full read it used to trigger answered
    /// questions nobody had asked, 60 to 120 times a second during a drag on
    /// the lock card's bar. Compared before it is assigned, like `apply`:
    /// one stereo write fires the wildcard listener once per channel.
    ///
    /// The mute key fires the same listener (it is registered for the mute
    /// as well), so the mute is read here too: one more property, not a
    /// device enumeration.
    func volumeChanged() {
        let fresh = readVolume()
        if volume != fresh { volume = fresh }
        readMute()
    }

    private func readMute() {
        let fresh = readMuted()
        if muted != fresh { muted = fresh }
    }

    /// The device-list listener's entry (K-009). Plugging in a DAC that macOS
    /// does not select changes the list and not the default, and the watch
    /// used to listen only to the default, so the picker never heard about
    /// it. One plug sends a burst of these, folded into one full read once it
    /// settles; a read that lands after `stop()` is dropped, because the card
    /// it would publish to has gone.
    func devicesChanged() {
        guard running, !devicesReadPending else { return }
        devicesReadPending = true
        debounce { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.devicesReadPending = false
                guard self.running else { return }
                self.systemAudioChanged()
            }
        }
    }

    /// Which device the volume listener belongs on, given the one it is
    /// attached to and the one that is now current. Nil is the one answer that
    /// means "stay put": the attachment already stands. Any other answer is the
    /// device the listener must be moved onto.
    ///
    /// Pure, so the follows-the-device rule is held by a test rather than by
    /// the untested glue that acts on it. Its one honest ambiguity: a re-read
    /// that finds *no* default at all also reads as "stay put", because a
    /// nil-able answer cannot say "drop" and "stand" at once. That is the
    /// cheaper mistake — a stale listener on a vanished device never fires
    /// again, the next real change reinstalls onto the new device, and `stop()`
    /// removes whatever is left.
    static func volumeListenerTarget(previous: AudioDeviceID?, now: AudioDeviceID?) -> AudioDeviceID? {
        now == previous ? nil : now
    }

    private func refresh() {
        apply(read())
        readMute()
        // Re-registration belongs to a running watch. An unstarted one only
        // publishes — the card's render tests drive `systemAudioChanged` on a
        // bare watch to fill their first frame, and must not reach the
        // machine's listener registry to do it.
        guard running else { return }
        guard let target = Self.volumeListenerTarget(previous: listeningTo, now: current) else { return }
        // The default moved, so the volume listener must follow it: the glue
        // drops the old device's listener and attaches the new device's. The
        // attachment is recorded only once the reinstall has been asked for,
        // so the glue reads the old device from `listeningTo` and the new one
        // from `current` — both of them decisions made here, in tested code.
        installListeners()
        listeningTo = target
    }

    /// Publishes a reading, assigned only when different. CoreAudio delivers a
    /// burst of notifications for one physical change and `@Published` never
    /// compares, so an unconditional write here republishes identical state —
    /// a body evaluation on the card for nothing, once per event in a storm.
    /// (The same rule `SystemAppearance.refresh` states.)
    private func apply(_ fresh: (outputs: [AudioOutputs.Output], current: AudioDeviceID?, volume: Float?)) {
        if outputs != fresh.outputs { outputs = fresh.outputs }
        if current != fresh.current { current = fresh.current }
        if volume != fresh.volume { volume = fresh.volume }
    }

    func start() {
        guard !running else { return }
        running = true
        // Read before installing: the glue attaches the volume listener to
        // whatever `current` reads as, so the first frame draws from a
        // synchronously taken reading and the attachment matches it.
        apply(read())
        readMute()
        installListeners()
        listeningTo = current
    }

    func stop() {
        guard running else { return }
        running = false
        removeListeners()
        listeningTo = nil
    }

    deinit {
        // A safety net, not the lifetime — the lock-card window stops the watch
        // at dismiss, and this only catches a watch torn down without its
        // stop. Without it, the listeners would outlive the object owning
        // them, firing into a block that holds nothing.
        if running { removeCoreAudioListeners(removingVolumeFrom: listeningTo) }
    }

    // MARK: - CoreAudio glue (deliberately untested)
    //
    // The one layer a test without a sound card could only rehearse, kept thin
    // on purpose: it holds no decisions, only registrations. Every choice —
    // when to install, what to attach to, when the attachment must move — is
    // made by the tested code above and arrives here as a fait accompli.

    // `nonisolated(unsafe)`, like `PlayerBridge`'s script table: these are
    // touched only from the main actor in life, and from `deinit` wherever the
    // last reference died — the removal calls themselves are thread-safe, and
    // the block hops to the main actor before touching anything that matters.
    nonisolated(unsafe) private var systemListenerInstalled = false
    nonisolated(unsafe) private var systemListener: AudioObjectPropertyListenerBlock?
    nonisolated(unsafe) private var devicesListener: AudioObjectPropertyListenerBlock?
    nonisolated(unsafe) private var volumeListener: AudioObjectPropertyListenerBlock?

    /// The default-output listener sits on the system object, which does not
    /// come and go, so it is installed once per watch and then left alone:
    /// re-adding it on every device change would queue one more callback per
    /// physical change for the same single registration. That guard is also
    /// what makes reinstalling from inside a listener block safe — the block
    /// currently firing is never the thing being removed.
    private nonisolated func installCoreAudioListeners(
        attachingVolumeTo: AudioDeviceID?, removingVolumeFrom: AudioDeviceID?
    ) {
        if !systemListenerInstalled {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.systemAudioChanged() }
            }
            systemListener = block
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
            )
            // The device list lives on the same object and comes and goes with
            // the same registration (K-009): a device plugged in or pulled out
            // without the default moving.
            var devices = Self.devicesAddress
            let devicesBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.devicesChanged() }
            }
            devicesListener = devicesBlock
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &devices, DispatchQueue.main, devicesBlock
            )
            systemListenerInstalled = true
        }
        // The volume listener follows the device: off the one it is attached
        // to, onto the device the fresh read made current. The element is the
        // wildcard because the level the card shows can live on the main
        // control or on the two stereo channels that `SystemVolume.current`
        // averages — the watch wants to hear from either kind of device.
        if let old = removingVolumeFrom { removeVolumeListener(from: old) }
        if let device = attachingVolumeTo { addVolumeListener(to: device) }
    }

    private nonisolated func removeCoreAudioListeners(removingVolumeFrom: AudioDeviceID?) {
        if systemListenerInstalled {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if let block = systemListener {
                AudioObjectRemovePropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
                )
            }
            systemListener = nil
            if let block = devicesListener {
                var devices = Self.devicesAddress
                AudioObjectRemovePropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject), &devices, DispatchQueue.main, block
                )
            }
            devicesListener = nil
            systemListenerInstalled = false
        }
        if let device = removingVolumeFrom { removeVolumeListener(from: device) }
    }

    private nonisolated static var devicesAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private nonisolated static var volumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementWildcard
        )
    }

    /// The mute, heard on the same device and by the same block as the level
    /// (G-023): the mute key changes this and not the level, so a listener on
    /// the level alone never heard the Mac go quiet.
    private nonisolated static var muteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementWildcard
        )
    }

    private nonisolated func addVolumeListener(to device: AudioDeviceID) {
        var address = Self.volumeAddress
        var mute = Self.muteAddress
        // The level alone: a full read here enumerated every device once per
        // write the lock card's bar made (F-045).
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.volumeChanged() }
        }
        volumeListener = block
        AudioObjectAddPropertyListenerBlock(device, &address, DispatchQueue.main, block)
        AudioObjectAddPropertyListenerBlock(device, &mute, DispatchQueue.main, block)
    }

    private nonisolated func removeVolumeListener(from device: AudioDeviceID) {
        guard let block = volumeListener else { return }
        var address = Self.volumeAddress
        var mute = Self.muteAddress
        // A vanished device answers with an error and nothing else — the watch
        // follows the default, and the default can disappear under it.
        AudioObjectRemovePropertyListenerBlock(device, &address, DispatchQueue.main, block)
        AudioObjectRemovePropertyListenerBlock(device, &mute, DispatchQueue.main, block)
        volumeListener = nil
    }
}

/// Re-reads the default output's latency whenever the route moves, for the
/// lyric lead.
///
/// The lyric lab (L7) found that no single lead fits every route: the
/// shipped 0.20 s is tuned for built-in speakers, which CoreAudio reports at
/// about 27 ms, while an assumed 200 ms Bluetooth route wants lines shown
/// that much later. The lead's `outputLatency` term is the route's share,
/// and this is where it comes from. It is read on the default-output change
/// only — the moment AirPods connect or the listener picks another device —
/// and published to `onChange` only when the number moved, because CoreAudio
/// sends a burst of notifications for one physical change and each report
/// re-arms the lyric wakes.
///
/// Owned by `LyricsCoordinator` and started only while Show Lyrics is on: a
/// listener who never turned lyrics on never has a CoreAudio listener
/// installed for them. The machine is injected the way `AudioWatch`'s is, so
/// every behaviour above is held by a test without a sound card; the glue at
/// the foot is the one deliberately untested layer and holds no decisions.
@MainActor
final class OutputLatencyMonitor {
    /// The default output's latency in seconds, or nil when no device
    /// answers. Nil too before the first start.
    private(set) var latency: TimeInterval?
    private(set) var isRunning = false
    /// Called with every reading that differs from the last one, the first
    /// reading included.
    var onChange: ((TimeInterval?) -> Void)?

    typealias Read = () -> TimeInterval?
    private let read: Read
    private var installListener: () -> Void
    private var removeListener: () -> Void
    private var hasReported = false

    init(
        read: Read? = nil,
        installListener: (() -> Void)? = nil,
        removeListener: (() -> Void)? = nil
    ) {
        self.read = read ?? {
            AudioOutputs.current().flatMap { AudioOutputs.outputLatency(of: $0)?.seconds }
        }
        self.installListener = installListener ?? {}
        self.removeListener = removeListener ?? {}
        if installListener == nil {
            self.installListener = { [weak self] in self?.installCoreAudioListener() }
        }
        if removeListener == nil {
            self.removeListener = { [weak self] in self?.removeCoreAudioListener() }
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        installListener()
        refresh()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        removeListener()
    }

    /// The entry the CoreAudio listener calls, and the tests in its place.
    /// A stopped watch has removed its listener and ignores a straggler.
    func defaultOutputChanged() {
        guard isRunning else { return }
        refresh()
    }

    private func refresh() {
        let fresh = read()
        guard !hasReported || fresh != latency else { return }
        hasReported = true
        latency = fresh
        onChange?(fresh)
    }

    deinit {
        // A safety net, as in `AudioWatch`: the coordinator stops the watch,
        // and this only catches one released while still running.
        if let block = listener { Self.removeSystemListener(block) }
    }

    // MARK: - CoreAudio glue (deliberately untested)

    // `nonisolated(unsafe)` for the same reason as `AudioWatch`'s: written on
    // the main actor in life, read from `deinit` wherever the last reference
    // died, and the removal call itself is thread-safe.
    nonisolated(unsafe) private var listener: AudioObjectPropertyListenerBlock?

    private nonisolated static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func installCoreAudioListener() {
        guard listener == nil else { return }
        var address = Self.defaultOutputAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.defaultOutputChanged() }
        }
        listener = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
    }

    private func removeCoreAudioListener() {
        guard let block = listener else { return }
        Self.removeSystemListener(block)
        listener = nil
    }

    private nonisolated static func removeSystemListener(_ block: @escaping AudioObjectPropertyListenerBlock) {
        var address = defaultOutputAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
    }
}
