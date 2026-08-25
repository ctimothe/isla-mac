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
}
