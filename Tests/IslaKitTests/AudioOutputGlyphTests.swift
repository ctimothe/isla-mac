import CoreAudio
import XCTest
@testable import IslaKit

/// Apple's own symbol for each kind of device, chosen by a pure function and
/// checked against the running macOS before it is drawn.
final class AudioOutputGlyphTests: XCTestCase {
    private let bluetooth = kAudioDeviceTransportTypeBluetooth

    private func symbol(
        _ name: String?, _ transport: UInt32 = kAudioDeviceTransportTypeBluetooth,
        source: UInt32? = nil, host: HostMac = .laptop, exists: @escaping (String) -> Bool = { _ in true }
    ) -> String {
        OutputGlyph.resolve(
            OutputGlyph.candidates(transport: transport, dataSource: source, name: name, host: host),
            exists: exists
        )
    }

    // MARK: - AirPods, by generation

    func testAirPodsGenerationsAndModels() {
        XCTAssertEqual(symbol("Elshod's AirPods"), "airpods")
        XCTAssertEqual(symbol("AirPods (3rd generation)"), "airpods.gen3")
        XCTAssertEqual(symbol("AirPods 4"), "airpods.gen4")
        XCTAssertEqual(symbol("AirPods Pro"), "airpods.pro")
        XCTAssertEqual(symbol("AirPods Pro (2nd generation)"), "airpods.pro")
        XCTAssertEqual(symbol("AirPods Pro 3"), "airpods.pro.gen3")
        XCTAssertEqual(symbol("AirPods Max"), "airpods.max")
        XCTAssertEqual(symbol("Elshod's AirPods Max"), "airpods.max")
    }

    func testGenerationIsReadOnlyFromGenerationVocabulary() {
        XCTAssertNil(OutputGlyph.airPodsGeneration(["elshod", "s", "airpods"]))
        XCTAssertNil(OutputGlyph.airPodsGeneration(["airpods", "of", "3"]))
        XCTAssertEqual(OutputGlyph.airPodsGeneration(["airpods", "gen3"]), 3)
        XCTAssertEqual(OutputGlyph.airPodsGeneration(["airpods", "pro", "2nd", "generation"]), 2)
    }

    // MARK: - Beats, HomePod, displays

    func testBeatsSubtypes() {
        XCTAssertEqual(symbol("Beats Studio Pro"), "beats.headphones")
        XCTAssertEqual(symbol("Elshod's Powerbeats Pro"), "beats.powerbeats.pro")
        XCTAssertEqual(symbol("Powerbeats3"), "beats.powerbeats")
        XCTAssertEqual(symbol("Beats Studio Buds"), "beats.studiobuds")
        XCTAssertEqual(symbol("Beats Studio Buds +"), "beats.studiobuds.plus")
        XCTAssertEqual(symbol("Beats Fit Pro"), "beats.fitpro")
        XCTAssertEqual(symbol("Beats Pill"), "beats.pill")
        XCTAssertEqual(symbol("Beats X"), "beats.earphones")
        XCTAssertNotEqual(symbol("Heartbeats Speaker", kAudioDeviceTransportTypeUSB), "beats.headphones")
    }

    func testHomePodAndDisplays() {
        XCTAssertEqual(symbol("Kitchen HomePod mini", kAudioDeviceTransportTypeAirPlay), "homepod.mini")
        XCTAssertEqual(symbol("Living Room HomePod", kAudioDeviceTransportTypeAirPlay), "homepod")
        XCTAssertEqual(symbol("Studio Display Speakers", kAudioDeviceTransportTypeDisplayPort), "display")
        XCTAssertEqual(symbol("DELL U2720Q", kAudioDeviceTransportTypeDisplayPort), "display")
        XCTAssertEqual(symbol("LG TV", kAudioDeviceTransportTypeHDMI), "tv")
    }

    // MARK: - Which Mac

    func testBuiltInSpeakersDrawTheMachineTheyAreIn() {
        let builtIn = kAudioDeviceTransportTypeBuiltIn
        XCTAssertEqual(symbol("MacBook Pro Speakers", builtIn, host: .desktop), "laptopcomputer")
        XCTAssertEqual(symbol("Mac mini Speakers", builtIn), "macmini")
        XCTAssertEqual(symbol("Mac Studio Speakers", builtIn), "macstudio")
        XCTAssertEqual(symbol("iMac Speakers", builtIn), "desktopcomputer")
        XCTAssertEqual(symbol("iMac Pro Speakers", builtIn), "desktopcomputer")
        XCTAssertEqual(symbol("Mac Pro Speakers", builtIn), "macpro.gen3")
        // No help from the name: the host decides.
        XCTAssertEqual(symbol("Speakers", builtIn, host: .mini), "macmini")
        XCTAssertEqual(symbol(nil, builtIn, host: .studio), "macstudio")
        XCTAssertEqual(symbol(nil, builtIn, source: AudioOutputs.DataSource.internalSpeaker, host: .desktop), "desktopcomputer")
        XCTAssertEqual(symbol(nil, builtIn), "laptopcomputer", "default host is the laptop the app always drew")
    }

    /// The built-in device keeps its name while something is in the jack.
    func testHeadphonesInTheJackBeatTheMachineName() {
        XCTAssertEqual(
            symbol("MacBook Pro Speakers", kAudioDeviceTransportTypeBuiltIn, source: AudioOutputs.DataSource.headphones),
            "headphones"
        )
    }

    func testHostFromModelIdentifier() {
        XCTAssertEqual(HostMac.parse(model: "MacBookPro18,3", hasBattery: false), .laptop)
        XCTAssertEqual(HostMac.parse(model: "Macmini9,1", hasBattery: false), .mini)
        XCTAssertEqual(HostMac.parse(model: "MacPro7,1", hasBattery: false), .pro)
        XCTAssertEqual(HostMac.parse(model: "iMac21,1", hasBattery: false), .desktop)
        XCTAssertEqual(HostMac.parse(model: "Mac14,2", hasBattery: true), .laptop, "bare identifier: the battery decides")
        XCTAssertEqual(HostMac.parse(model: "Mac14,13", hasBattery: false), .desktop)
        XCTAssertEqual(HostMac.parse(model: nil, hasBattery: false), .desktop)
    }

    // MARK: - Bluetooth that is not headphones

    /// Class of Device is not read (it needs the Bluetooth permission); the
    /// name says what it can, and silence stays headphones.
    func testBluetoothSpeakersAreToldByName() {
        XCTAssertEqual(symbol("JBL Flip 6 Speaker"), "hifispeaker")
        XCTAssertEqual(symbol("Sony Soundbar"), "hifispeaker")
        XCTAssertEqual(symbol("UE MEGABOOM 3"), "hifispeaker")
        XCTAssertEqual(symbol("Toyota CarPlay"), "car")
        XCTAssertEqual(symbol("WH-1000XM5"), "headphones", "a name that says nothing stays headphones")
        XCTAssertEqual(symbol("Galaxy Buds"), "earbuds")
        XCTAssertEqual(symbol("EarPods", kAudioDeviceTransportTypeUSB), "earpods")
    }

    // MARK: - Existence fallback

    /// A symbol newer than the running macOS degrades along the list to the
    /// one that always shipped, never to a glyph that draws nothing.
    func testAMissingSymbolFallsBackDownTheList() {
        let old: Set<String> = ["airpods", "airpods.pro", "headphones", "laptopcomputer", "desktopcomputer", "tv"]
        let has = { (name: String) in old.contains(name) }
        XCTAssertEqual(symbol("AirPods 4", exists: has), "airpods")
        XCTAssertEqual(symbol("AirPods Pro 3", exists: has), "airpods.pro")
        XCTAssertEqual(symbol("AirPods Max", exists: has), "headphones")
        XCTAssertEqual(symbol("Beats Fit Pro", exists: has), "headphones")
        XCTAssertEqual(symbol("Mac mini Speakers", kAudioDeviceTransportTypeBuiltIn, exists: has), "desktopcomputer")
        XCTAssertEqual(symbol("DELL U2720Q", kAudioDeviceTransportTypeDisplayPort, exists: { $0 == "tv" }), "tv")
    }

    func testNothingResolvingReturnsTheOldChoiceNotNothing() {
        XCTAssertEqual(OutputGlyph.resolve(["airpods.gen4", "airpods"], exists: { _ in false }), "airpods")
        XCTAssertEqual(OutputGlyph.resolve([], exists: { _ in false }), AudioOutputs.outputFallbackSymbol)
    }

    /// Every candidate's last entry is a symbol this macOS really has.
    func testEveryListEndsInARealSymbol() {
        let names = [
            "AirPods Pro 3", "AirPods 4", "AirPods Max", "Powerbeats Pro", "Beats Studio Buds +", "Beats Pill",
            "HomePod mini", "Apple TV", "Studio Display", "EarPods", "Galaxy Buds", "JBL Speaker", "Mac Studio Speakers",
            "Mac Pro Speakers", "MacBook Air Speakers", "Toyota CarPlay", nil,
        ]
        let transports: [UInt32] = [
            kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeAirPlay,
            kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeUSB,
            kAudioDeviceTransportTypeVirtual, 0,
        ]
        for name in names {
            for transport in transports {
                for host in [HostMac.laptop, .mini, .studio, .pro, .desktop] {
                    let list = OutputGlyph.candidates(transport: transport, dataSource: nil, name: name, host: host)
                    XCTAssertNotNil(
                        NSImage(systemSymbolName: list.last!, accessibilityDescription: nil),
                        "\(list.last!) for \(name ?? "nil") does not resolve"
                    )
                }
            }
        }
    }

    // MARK: - One fallback

    func testTheLockCardAndThePlayerShareOneFallback() throws {
        XCTAssertEqual(AudioOutputs.outputFallbackSymbol, "speaker.wave.2")
        let source = try String(contentsOfFile: #filePath.replacingOccurrences(
            of: "Tests/IslaKitTests/AudioOutputGlyphTests.swift",
            with: "Sources/IslaKit/UI/LockScreenCard.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("fallback: \"airplayaudio\""))
        XCTAssertTrue(source.contains("fallback: AudioOutputs.outputFallbackSymbol"))
    }
}
