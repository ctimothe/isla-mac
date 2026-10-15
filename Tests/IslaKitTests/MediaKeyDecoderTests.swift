import AppKit
import XCTest
@testable import IslaKit

/// The media keys as the keyboard sends them (redesign 2026-10-15, spec §12).
///
/// Pure: an `NX_SYSDEFINED` event's subtype and `data1` in, a key press or
/// nothing out. Nothing here creates an event tap — the tap is a seam
/// (`MediaKeyTapping`), and these tests never reach the real one.
@MainActor
final class MediaKeyDecoderTests: XCTestCase {

    /// `data1` as the system packs it: key code in the high 16 bits, state in
    /// the next 8, the repeat bit in the lowest.
    private func data1(key: Int, state: Int, isRepeat: Bool = false) -> Int {
        (key << 16) | (state << 8) | (isRepeat ? 1 : 0)
    }

    func testEveryKeyDecodesOnItsNXKeytypeCode() {
        let codes: [(MediaKey, Int)] = [
            (.volumeUp, 0), (.volumeDown, 1), (.brightnessUp, 2), (.brightnessDown, 3),
            (.mute, 7), (.keyboardBrightnessUp, 21), (.keyboardBrightnessDown, 22),
        ]
        XCTAssertEqual(MediaKey.allCases.count, codes.count, "seven keys, no more")
        for (key, code) in codes {
            XCTAssertEqual(MediaKey(rawValue: code), key, "NX_KEYTYPE \(code)")
            XCTAssertEqual(
                MediaKeyDecoder.decode(subtype: 8, data1: data1(key: code, state: 0xA)),
                MediaKeyPress(key: key, isDown: true, isRepeat: false),
                "\(key) down"
            )
        }
    }

    func testAReleaseIsKeyUpAndNeverARepeat() {
        let up = MediaKeyDecoder.decode(subtype: 8, data1: data1(key: 0, state: 0xB))
        XCTAssertEqual(up, MediaKeyPress(key: .volumeUp, isDown: false, isRepeat: false))
        // The low bit means "repeat" only on a press; a release never carries it.
        let upWithBit = MediaKeyDecoder.decode(subtype: 8, data1: data1(key: 0, state: 0xB, isRepeat: true))
        XCTAssertEqual(upWithBit?.isRepeat, false)
    }

    func testAHeldKeyRepeatsAreKeyDowns() {
        let held = MediaKeyDecoder.decode(subtype: 8, data1: data1(key: 1, state: 0xA, isRepeat: true))
        XCTAssertEqual(held, MediaKeyPress(key: .volumeDown, isDown: true, isRepeat: true))
    }

    func testAnythingElseIsPassedThrough() {
        // Another subtype: the power button's, the eject key's, a mouse's.
        XCTAssertNil(MediaKeyDecoder.decode(subtype: 1, data1: data1(key: 0, state: 0xA)))
        XCTAssertNil(MediaKeyDecoder.decode(subtype: 0, data1: data1(key: 0, state: 0xA)))
        // Another key of the right subtype: play/pause (16), next (17), eject (14).
        for code in [4, 5, 6, 8, 14, 16, 17, 18, 20, 23, 255] {
            XCTAssertNil(MediaKeyDecoder.decode(subtype: 8, data1: data1(key: code, state: 0xA)), "key \(code)")
        }
        // A state the system does not define.
        XCTAssertNil(MediaKeyDecoder.decode(subtype: 8, data1: data1(key: 0, state: 0x0)))
        XCTAssertNil(MediaKeyDecoder.decode(subtype: 8, data1: data1(key: 0, state: 0xC)))
    }

    func testTheTapListensToSystemDefinedEventsAndNothingElse() {
        XCTAssertEqual(MediaKeyDecoder.systemDefinedType, 14, "NX_SYSDEFINED")
        XCTAssertEqual(MediaKeyTapDisposition.of(CGEventType(rawValue: 14)!), .inspect)
        XCTAssertEqual(MediaKeyTapDisposition.of(.keyDown), .ignore)
        XCTAssertEqual(MediaKeyTapDisposition.of(.mouseMoved), .ignore)
    }

    func testTimeoutAndUserInputSwitchTheTapBackOn() {
        XCTAssertEqual(MediaKeyTapDisposition.of(.tapDisabledByTimeout), .reenable)
        XCTAssertEqual(MediaKeyTapDisposition.of(.tapDisabledByUserInput), .reenable)
    }

    /// The real tap's receive path for a disabled-by-timeout notice, with no port
    /// and no tap: it switches itself back on, tells its owner, and hands the
    /// event on.
    func testTheRealTapReEnablesItselfOnTimeoutAndOnUserInput() throws {
        let event = try XCTUnwrap(CGEvent(source: nil), "a plain event needs no permission")
        var reenabled = 0
        var told = 0
        let tap = EventMediaKeyTap(handler: { _, _ in XCTFail("no key was pressed"); return true }, disabled: { told += 1 })
        tap.reenable = { _ in reenabled += 1 }
        for type in [CGEventType.tapDisabledByTimeout, .tapDisabledByUserInput] {
            let answer = tap.receive(type: type, event: event)
            XCTAssertNotNil(answer, "the notice itself is never consumed")
        }
        XCTAssertEqual(reenabled, 2)
        XCTAssertEqual(told, 2, "and the owner is told, to look at trust again")
        XCTAssertFalse(tap.isRunning, "no port was ever made")

        // Any other type is handed on untouched.
        XCTAssertNotNil(tap.receive(type: .keyDown, event: event))
        XCTAssertEqual(reenabled, 2)
    }

    func testOptionShiftTogetherAreTheFineStep() {
        XCTAssertTrue(MediaKeyModifiers(flags: [.maskAlternate, .maskShift]).fine)
        XCTAssertFalse(MediaKeyModifiers(flags: [.maskAlternate]).fine)
        XCTAssertFalse(MediaKeyModifiers(flags: [.maskShift]).fine)
        XCTAssertFalse(MediaKeyModifiers(flags: [.maskCommand, .maskShift]).fine)
        XCTAssertFalse(MediaKeyModifiers(flags: []).fine)
    }

    /// The live factory in a test process makes a tap that cannot start — the
    /// suite runs on a Mac whose owner may have the setting on.
    func testTheLiveFactoryNeverStartsATapUnderTest() {
        let tap = EventMediaKeyTap.live({ _, _ in false }, {})
        XCTAssertFalse(tap.start())
        XCTAssertFalse(tap.isRunning)
    }
}
