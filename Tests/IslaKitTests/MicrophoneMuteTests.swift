import XCTest
@testable import IslaKit

/// The island's Mute writes down what it changed and gives back exactly that
/// (owner, 2026-11-15). A mute the device kept after the activity went came
/// back after a restart, and Siri's listener then re-applied it every half a
/// minute, so the bookkeeping is the feature. No test touches a real device.
final class MicrophoneMuteTests: XCTestCase {
    /// Microphones by UID: each element's mute switch, or its level where
    /// there is no switch.
    private final class Mac: @unchecked Sendable {
        var mutes: [String: [UInt32: Bool]] = [:]
        var levels: [String: [UInt32: Float]] = [:]
        var present: [String] = []

        var hardware: MicrophoneMute.Hardware {
            MicrophoneMute.Hardware(
                microphones: { self.present },
                mute: { self.present.contains($0) ? self.mutes[$0]?[$1] : nil },
                setMute: { device, element, on in
                    guard self.mutes[device]?[element] != nil else { return false }
                    self.mutes[device]?[element] = on
                    return true
                },
                level: { self.present.contains($0) ? self.levels[$0]?[$1] : nil },
                setLevel: { device, element, level in
                    guard self.levels[device]?[element] != nil else { return false }
                    self.levels[device]?[element] = level
                    return true
                }
            )
        }
    }

    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        suite = "com.ctimothe.isla.micmute.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    /// Release gives back only what hold changed: a channel the person had
    /// muted already stays muted, and nothing is left written down.
    func testReleaseGivesBackOnlyWhatHoldChanged() {
        let mac = Mac()
        mac.present = ["builtin", "usb"]
        mac.mutes = ["builtin": [0: false], "usb": [1: true, 2: false]]
        XCTAssertTrue(MicrophoneMute.hold(mac.hardware, defaults: defaults))
        XCTAssertEqual(mac.mutes["builtin"]?[0], true)
        XCTAssertEqual(mac.mutes["usb"], [1: true, 2: true])

        MicrophoneMute.release(mac.hardware, defaults: defaults)
        XCTAssertEqual(mac.mutes["builtin"]?[0], false)
        XCTAssertEqual(mac.mutes["usb"], [1: true, 2: false], "the channel muted before stays muted")
        XCTAssertEqual(MicrophoneMute.held(defaults), [])
    }

    /// A microphone with no switch is turned down and given its level back;
    /// one already at zero is not written down.
    func testAMicrophoneWithoutASwitchGetsItsLevelBack() {
        let mac = Mac()
        mac.present = ["usb", "silent"]
        mac.levels = ["usb": [0: 0.7], "silent": [0: 0]]
        XCTAssertTrue(MicrophoneMute.hold(mac.hardware, defaults: defaults))
        XCTAssertEqual(mac.levels["usb"]?[0], 0)
        MicrophoneMute.release(mac.hardware, defaults: defaults)
        XCTAssertEqual(mac.levels["usb"]?[0], 0.7)
        XCTAssertEqual(mac.levels["silent"]?[0], 0)
    }

    /// The note outlives the process: a run that ended while muted is given
    /// back by the next one's release. A microphone unplugged in between
    /// keeps its note until it is there again.
    func testAMuteLeftByAnEarlierRunIsGivenBackAndAnUnpluggedOneWaits() {
        let mac = Mac()
        mac.present = ["builtin", "usb"]
        mac.mutes = ["builtin": [0: false], "usb": [0: false]]
        MicrophoneMute.hold(mac.hardware, defaults: defaults)

        mac.present = ["builtin"]
        MicrophoneMute.release(mac.hardware, defaults: defaults)
        XCTAssertEqual(mac.mutes["builtin"]?[0], false)
        XCTAssertEqual(MicrophoneMute.held(defaults).map(\.device), ["usb"])

        mac.present = ["builtin", "usb"]
        MicrophoneMute.release(mac.hardware, defaults: defaults)
        XCTAssertEqual(mac.mutes["usb"]?[0], false)
        XCTAssertEqual(MicrophoneMute.held(defaults), [])
    }

    /// Nothing to mute is said, so the island does not claim a mute; a second
    /// hold does not write the same channel twice.
    func testHoldSaysWhetherAnythingIsHeld() {
        let mac = Mac()
        mac.present = ["builtin"]
        mac.mutes = ["builtin": [0: true]]
        XCTAssertFalse(MicrophoneMute.hold(mac.hardware, defaults: defaults), "already muted by the person")

        mac.mutes = ["builtin": [0: false]]
        XCTAssertTrue(MicrophoneMute.hold(mac.hardware, defaults: defaults))
        XCTAssertTrue(MicrophoneMute.hold(mac.hardware, defaults: defaults))
        XCTAssertEqual(MicrophoneMute.held(defaults).count, 1)
    }
}
