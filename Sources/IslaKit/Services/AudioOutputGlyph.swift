import AppKit
import CoreAudio
import Foundation
import IOKit.ps

/// Which kind of Mac this is, for the glyph of its own speakers.
///
/// The built-in output used to draw a laptop on every Mac, so a Mac mini or a
/// Studio played its music "through" a MacBook. The system's Sound menu draws
/// the machine itself, and these are the symbols Apple ships for each.
enum HostMac: Equatable {
    case laptop, mini, studio, pro, desktop

    /// Candidate symbols for this machine, best first. The last one is old
    /// enough to exist on every supported macOS, so a newer, more specific
    /// symbol (`macstudio`, macOS 13) can never leave the row empty.
    var symbols: [String] {
        switch self {
        case .laptop: return ["laptopcomputer"]
        case .mini: return ["macmini", "desktopcomputer"]
        case .studio: return ["macstudio", "desktopcomputer"]
        case .pro: return ["macpro.gen3", "desktopcomputer"]
        case .desktop: return ["desktopcomputer"]
        }
    }

    /// The machine from its model identifier. Pure, so the rule is held by a
    /// test on any Mac. Macs from 2022 on carry a bare "Mac14,2" that names no
    /// family at all, and for those the one public tell is the battery: only
    /// a laptop has one. A virtual machine or an unknown identifier lands on
    /// the generic desktop, which is merely vague, never a wrong laptop.
    static func parse(model: String?, hasBattery: Bool) -> HostMac {
        let model = model ?? ""
        if model.hasPrefix("MacBook") { return .laptop }
        if model.hasPrefix("Macmini") { return .mini }
        if model.hasPrefix("MacPro") { return .pro }
        if model.hasPrefix("iMac") { return .desktop }
        return hasBattery ? .laptop : .desktop
    }

    /// Read once, on first use. The machine does not change under a running
    /// app, and `sysctl` plus a power-source query is not something a body
    /// pass should repeat. Neither call prompts for anything.
    static let current: HostMac = {
        var size = 0
        var model: String?
        if sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 {
            var buffer = [CChar](repeating: 0, count: size)
            if sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 {
                model = String(cString: buffer)
            }
        }
        return parse(model: model, hasBattery: hasInternalBattery())
    }()

    private static func hasInternalBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return list.contains { source in
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                    as? [String: Any] else { return false }
            return description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }
}

/// The device glyph as a list of candidates, and the one step that turns the
/// list into a symbol this macOS can draw.
///
/// **Why Bluetooth speakers are told from headphones by name, not by Class of
/// Device.** The honest source is IOBluetooth: `IOBluetoothDevice`'s
/// `classOfDevice` minor class separates a headset from a loudspeaker from a
/// car kit, and CoreAudio's device UID for a Bluetooth output is the MAC
/// address that finds the paired device. It was not used. Since macOS 11
/// IOBluetooth is gated by the Bluetooth privacy permission: reading a paired
/// device raises the system's "wants to use Bluetooth" prompt, and an app
/// with no `NSBluetoothAlwaysUsageDescription` is terminated by the system at
/// the call. This app declares no such string, and adding one (a prompt on a
/// glyph) is a product decision, not an implementation detail. A Bluetooth
/// output with a name that says nothing therefore stays `headphones`, which is
/// vague and never a prompt; one whose name says "speaker" or "soundbar" draws
/// a speaker. If the owner decides a Bluetooth prompt is worth a more exact
/// glyph, the mapping below already takes a device-class input shaped the same
/// way as the name: add a branch ahead of the Bluetooth transport case, and
/// cache the read per device UID, off the media-key path.
enum OutputGlyph {
    /// Whether this macOS draws the symbol. Cached: the answer cannot change
    /// while the app runs, and an `NSImage` lookup is not free in a body pass.
    static func exists(_ name: String) -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let known = cache[name] { return known }
        let found = NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        cache[name] = found
        return found
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Bool] = [:]

    /// The first candidate this macOS draws. The list's last entry is the
    /// choice that has always shipped, so it is the answer when none resolves;
    /// a newer symbol on a Mac that predates it degrades to the old glyph and
    /// never to an empty one.
    static func resolve(_ candidates: [String], exists: (String) -> Bool = OutputGlyph.exists) -> String {
        candidates.first(where: exists) ?? candidates.last ?? AudioOutputs.outputFallbackSymbol
    }

    /// Candidates for a device, best first. Pure: every input is injected, so
    /// the whole mapping is held by tests without a sound card or a Mac of
    /// each kind.
    ///
    /// The device's own name comes first because it is the only thing that
    /// tells AirPods Pro from AirPods Max or a Powerbeats from a Beats Studio:
    /// all arrive over Bluetooth, none publishes a data source. A name is a
    /// heuristic used only to pick a *better* glyph; anything unrecognised
    /// falls through to the transport and is generic, never wrong. Product
    /// names are the same in every language, which is what makes this survive
    /// a localised Mac.
    static func candidates(
        transport: UInt32, dataSource: UInt32?, name: String?, host: HostMac
    ) -> [String] {
        let lowered = name?.lowercased() ?? ""
        let words = tokens(lowered)

        if lowered.contains("airpods") { return airPods(lowered, words) }
        if words.contains(where: { $0.hasPrefix("beats") || $0.hasPrefix("powerbeats") })
            || lowered.contains("studio buds") {
            // Every Beats list ends in plain headphones: the model-specific
            // drawings are newer than the first Beats symbols.
            return beats(lowered) + ["headphones"]
        }
        if lowered.contains("homepod") {
            return lowered.contains("mini") ? ["homepod.mini", "homepod"] : ["homepod"]
        }
        if lowered.contains("apple tv") { return ["appletv"] }
        if lowered.contains("studio display") || lowered.contains("pro display")
            || lowered.contains("thunderbolt display") || lowered.contains("ultrafine") {
            return ["display"]
        }
        // Wired Apple headphones have a symbol of their own; the generic
        // words every third-party headset puts in its name do not.
        if lowered.contains("earpods") { return ["earpods", "headphones"] }
        if lowered.contains("earphone") || lowered.contains("earbud") || words.contains("buds") {
            return ["earbuds", "headphones"]
        }
        if lowered.contains("headphone") || lowered.contains("headset") { return ["headphones"] }

        switch dataSource {
        case AudioOutputs.DataSource.headphones: return ["headphones"]
        case AudioOutputs.DataSource.externalSpeaker: return ["hifispeaker"]
        default: break
        }
        // A Mac names itself ("MacBook Pro Speakers", "Mac mini Speakers"),
        // and a Mac that is the AirPlay target says so too. After the data
        // source: the built-in device keeps its name while something is in the
        // headphone jack.
        if let mac = macFamily(lowered) { return mac.symbols }
        if dataSource == AudioOutputs.DataSource.internalSpeaker { return host.symbols }

        if transport != kAudioDeviceTransportTypeBuiltIn, speakerWords(lowered, words) {
            return ["hifispeaker", "speaker.wave.2"]
        }
        if transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE,
           words.contains("carplay") || words.contains("car") {
            return ["car", "headphones"]
        }

        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return host.symbols
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return ["headphones"]
        case kAudioDeviceTransportTypeAirPlay: return ["airplayaudio"]
        case kAudioDeviceTransportTypeHDMI: return ["tv"]
        // A monitor's own speakers over USB-C or Thunderbolt arrive as
        // DisplayPort; a television over HDMI stays a television.
        case kAudioDeviceTransportTypeDisplayPort: return ["display", "tv"]
        // Neutral on purpose. USB is a wire, not a kind of thing: USB-C
        // EarPods and a pair of studio monitors arrive identically, publish
        // no data source, and nothing else in CoreAudio distinguishes them.
        // A generic output glyph is merely vague.
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeFireWire: return ["speaker.wave.2"]
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return ["waveform"]
        default: return ["speaker.wave.2"]
        }
    }

    // MARK: - Families

    private static func airPods(_ name: String, _ words: [String]) -> [String] {
        if name.contains("airpods max") || name.contains("airpodsmax") { return ["airpods.max", "headphones"] }
        let generation = airPodsGeneration(words)
        if name.contains("airpods pro") || name.contains("airpodspro") {
            // A bare "AirPods Pro" is Pro 1 or 2 and draws the original. The
            // name is whatever the owner called the pair, so only one that
            // says 3 gets the newer drawing.
            return (generation ?? 0) >= 3
                ? ["airpods.pro.gen3", "airpods.pro", "airpods"] : ["airpods.pro", "airpods"]
        }
        switch generation {
        case 4?: return ["airpods.gen4", "airpods.gen3", "airpods"]
        case 3?: return ["airpods.gen3", "airpods"]
        default: return ["airpods"]
        }
    }

    /// The generation a name states after "AirPods" ("AirPods 4", "AirPods Pro
    /// (2nd generation)", "AirPods gen3"), or nil. The words are read only as
    /// long as they are generation vocabulary, and stop at the first word
    /// that is neither.
    static func airPodsGeneration(_ words: [String]) -> Int? {
        guard let start = words.firstIndex(where: { $0.hasPrefix("airpods") }) else { return nil }
        for word in words[(start + 1)...] {
            if ["pro", "max", "gen", "generation"].contains(word) { continue }
            var digits = word
            if digits.hasPrefix("gen") { digits.removeFirst(3) }
            for suffix in ["st", "nd", "rd", "th"] where digits.hasSuffix(suffix) {
                digits.removeLast(2)
                break
            }
            if let value = Int(digits), (1...9).contains(value) { return value }
            return nil
        }
        return nil
    }

    private static func beats(_ name: String) -> [String] {
        let plain = name.replacingOccurrences(of: " ", with: "")
        if plain.contains("powerbeatspro") {
            return ["beats.powerbeats.pro", "beats.powerbeatspro", "beats.earphones", "beats.headphones"]
        }
        if plain.contains("powerbeats") { return ["beats.powerbeats", "beats.earphones", "beats.headphones"] }
        if plain.contains("studiobuds") {
            return plain.contains("studiobuds+") || plain.contains("studiobudsplus")
                ? ["beats.studiobuds.plus", "beats.studiobuds", "beats.earphones", "beats.headphones"]
                : ["beats.studiobuds", "beats.earphones", "beats.headphones"]
        }
        if plain.contains("fitpro") { return ["beats.fitpro", "beats.earphones", "beats.headphones"] }
        if plain.contains("solobuds") { return ["beats.solobuds", "beats.earphones", "beats.headphones"] }
        if plain.contains("pill") { return ["beats.pill", "hifispeaker", "speaker.wave.2"] }
        if plain.contains("beatsx") || plain.contains("beatsflex") || plain.contains("urbeats") {
            return ["beats.earphones", "beats.headphones"]
        }
        return ["beats.headphones", "headphones"]
    }

    /// Which Mac a device name names, or nil. "iMac" is tested before "Mac
    /// Pro" because it contains it.
    static func macFamily(_ name: String) -> HostMac? {
        if name.contains("macbook") { return .laptop }
        if name.contains("imac") { return .desktop }
        if name.contains("mac mini") || name.contains("macmini") { return .mini }
        if name.contains("mac studio") { return .studio }
        if name.contains("mac pro") { return .pro }
        return nil
    }

    private static func speakerWords(_ name: String, _ words: [String]) -> Bool {
        name.contains("speaker") || name.contains("soundbar") || name.contains("boombox")
            || name.contains("soundlink") || words.contains("boom") || words.contains("megaboom")
    }

    private static func tokens(_ lowered: String) -> [String] {
        lowered.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
