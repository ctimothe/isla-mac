import CoreAudio
import XCTest
@testable import DynamicIslandKit

/// The glyph names the device, not the wire.
final class AudioOutputSymbolTests: XCTestCase {

    /// The built-in Mac keeps transport `bltn` whether the sound is coming out
    /// of the speakers or out of something in the headphone jack. Transport
    /// alone therefore draws a laptop while you are wearing headphones.
    func testTheDataSourceBeatsTheTransport() {
        XCTAssertEqual(
            AudioOutputs.symbol(
                forTransport: kAudioDeviceTransportTypeBuiltIn,
                dataSource: AudioOutputs.DataSource.headphones
            ),
            "headphones"
        )
        XCTAssertEqual(
            AudioOutputs.symbol(
                forTransport: kAudioDeviceTransportTypeBuiltIn,
                dataSource: AudioOutputs.DataSource.internalSpeaker
            ),
            "laptopcomputer"
        )
        XCTAssertEqual(
            AudioOutputs.symbol(
                forTransport: kAudioDeviceTransportTypeBuiltIn,
                dataSource: AudioOutputs.DataSource.externalSpeaker
            ),
            "hifispeaker"
        )
    }

    /// USB publishes no data source at all — measured on this machine, where
    /// USB-C EarPods report only `usb`. A floor-standing speaker glyph was a
    /// confident wrong answer for the commonest USB output there is; the
    /// generic one is merely vague, which is the honest state of the knowledge.
    func testUSBIsNeutralBecauseNothingDistinguishesEarPodsFromMonitors() {
        XCTAssertEqual(AudioOutputs.symbol(forTransport: kAudioDeviceTransportTypeUSB), "speaker.wave.2")
        XCTAssertNotEqual(AudioOutputs.symbol(forTransport: kAudioDeviceTransportTypeUSB), "hifispeaker")
    }

    func testTheRestOfTheTransportsAreUnchanged() {
        XCTAssertEqual(AudioOutputs.symbol(forTransport: kAudioDeviceTransportTypeBluetooth), "headphones")
        XCTAssertEqual(AudioOutputs.symbol(forTransport: kAudioDeviceTransportTypeAirPlay), "airplayaudio")
        XCTAssertEqual(AudioOutputs.symbol(forTransport: kAudioDeviceTransportTypeHDMI), "tv")
        XCTAssertEqual(AudioOutputs.symbol(forTransport: kAudioDeviceTransportTypeBuiltIn), "laptopcomputer")
    }

    /// Every glyph the mapping can return has to exist, or a row draws nothing.
    func testEverySymbolResolves() {
        let transports: [UInt32] = [
            kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeBluetooth,
            kAudioDeviceTransportTypeAirPlay, kAudioDeviceTransportTypeHDMI,
            kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeVirtual, 0,
        ]
        let sources: [UInt32?] = [
            nil, AudioOutputs.DataSource.headphones,
            AudioOutputs.DataSource.internalSpeaker, AudioOutputs.DataSource.externalSpeaker,
        ]
        for transport in transports {
            for source in sources {
                let name = AudioOutputs.symbol(forTransport: transport, dataSource: source)
                XCTAssertNotNil(
                    NSImage(systemSymbolName: name, accessibilityDescription: nil),
                    "\(name) does not resolve"
                )
            }
        }
    }

    /// The Apple families, told apart by name because nothing else can.
    ///
    /// AirPods Pro and AirPods Max both arrive over Bluetooth publishing no data
    /// source; CoreAudio has no idea they are different products. The system's
    /// own output menu draws the distinction, so this one does too, with Apple's
    /// own symbols rather than lookalikes.
    func testAppleDevicesGetTheirOwnGlyph() {
        func symbol(_ name: String, _ transport: UInt32 = kAudioDeviceTransportTypeBluetooth) -> String {
            AudioOutputs.symbol(forTransport: transport, dataSource: nil, name: name)
        }
        XCTAssertEqual(symbol("Elshod's AirPods Max"), "airpods.max")
        XCTAssertEqual(symbol("AirPods Pro"), "airpods.pro")
        XCTAssertEqual(symbol("Elshod's AirPods"), "airpods")
        XCTAssertEqual(symbol("Beats Studio Pro"), "beats.headphones")
        XCTAssertEqual(symbol("Living Room HomePod"), "homepod")
        XCTAssertEqual(symbol("Apple TV"), "appletv")
        XCTAssertEqual(symbol("Studio Display", kAudioDeviceTransportTypeDisplayPort), "display")
    }

    /// Wired headphones, which is what a USB-C EarPods is — and the case that
    /// used to draw a floor-standing speaker.
    func testWiredHeadphonesReadAsHeadphones() {
        XCTAssertEqual(
            AudioOutputs.symbol(forTransport: kAudioDeviceTransportTypeUSB, dataSource: nil, name: "EarPods"),
            "headphones"
        )
        XCTAssertEqual(
            AudioOutputs.symbol(forTransport: kAudioDeviceTransportTypeUSB, dataSource: nil, name: "Some USB Headset"),
            "headphones"
        )
    }

    /// An unrecognised name changes nothing: it falls through to the transport
    /// and is generic rather than wrong.
    func testAnUnknownNameFallsThroughToTheTransport() {
        XCTAssertEqual(
            AudioOutputs.symbol(forTransport: kAudioDeviceTransportTypeUSB, dataSource: nil, name: "Scarlett 2i2"),
            "speaker.wave.2"
        )
        XCTAssertEqual(
            AudioOutputs.symbol(forTransport: kAudioDeviceTransportTypeBuiltIn, dataSource: nil, name: "MacBook Pro Speakers"),
            "laptopcomputer"
        )
    }
}
