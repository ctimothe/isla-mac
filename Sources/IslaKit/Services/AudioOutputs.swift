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

        return ids.compactMap { id in
            guard hasOutputStreams(id), let name = name(of: id) else { return nil }
            return Output(id: id, name: name, transport: transport(of: id), dataSource: dataSource(of: id))
        }
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

    private static func transport(of id: AudioDeviceID) -> UInt32 {
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
/// The machine is injected. `read` and the two listener closures default to
/// the CoreAudio implementations at the foot of this class and are overridden
/// by the tests, so every behaviour of the watch is driven without a sound
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

    /// One reading of the machine: what can play, what does, how loud.
    typealias Read = () -> (outputs: [AudioOutputs.Output], current: AudioDeviceID?, volume: Float?)

    private let read: Read
    private var installListeners: () -> Void
    private var removeListeners: () -> Void

    /// The device the volume listener is attached to. The listener must follow
    /// the default, and this is what tells the watch when it has to move.
    private var listeningTo: AudioDeviceID?
    private var running = false

    init(
        read: Read? = nil,
        installListeners: (() -> Void)? = nil,
        removeListeners: (() -> Void)? = nil
    ) {
        self.read = read ?? { (AudioOutputs.available(), AudioOutputs.current(), SystemVolume.current()) }
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

    /// The one entry the CoreAudio listener blocks call — and the one the tests
    /// drive in their place, and the card on a pane change. Re-reads are cheap
    /// property gets, so there is nothing to debounce: every "something may
    /// have moved" moment lands here and publishes only what actually moved.
    func systemAudioChanged() {
        refresh()
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
            systemListenerInstalled = false
        }
        if let device = removingVolumeFrom { removeVolumeListener(from: device) }
    }

    private nonisolated static var volumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementWildcard
        )
    }

    private nonisolated func addVolumeListener(to device: AudioDeviceID) {
        var address = Self.volumeAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.systemAudioChanged() }
        }
        volumeListener = block
        AudioObjectAddPropertyListenerBlock(device, &address, DispatchQueue.main, block)
    }

    private nonisolated func removeVolumeListener(from device: AudioDeviceID) {
        guard let block = volumeListener else { return }
        var address = Self.volumeAddress
        // A vanished device answers with an error and nothing else — the watch
        // follows the default, and the default can disappear under it.
        AudioObjectRemovePropertyListenerBlock(device, &address, DispatchQueue.main, block)
        volumeListener = nil
    }
}
