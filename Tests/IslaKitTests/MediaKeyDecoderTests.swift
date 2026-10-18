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

    /// The real tap's receive path (on its thread in the app) for a
    /// disabled-by-timeout notice, with no port and no tap: it tells its owner
    /// — who clears the holds — *before* it switches itself back on, and hands
    /// the event on.
    func testTheRealTapReEnablesItselfOnTimeoutAndOnUserInput() throws {
        let event = try XCTUnwrap(CGEvent(source: nil), "a plain event needs no permission")
        let order = LockedBox<[String]>([])
        let tap = MediaKeyTapContext(
            handler: { _, _ in XCTFail("no key was pressed"); return true },
            disabled: { order.value.append("told") },
            reenable: { _ in order.value.append("reenabled") }
        )
        for type in [CGEventType.tapDisabledByTimeout, .tapDisabledByUserInput] {
            let answer = tap.receive(type: type, event: event)
            XCTAssertNotNil(answer, "the notice itself is never consumed")
        }
        XCTAssertEqual(order.value, ["told", "reenabled", "told", "reenabled"], "the owner first, then the tap")
        XCTAssertNil(tap.port, "no port was ever made")

        // Any other type is handed on untouched.
        XCTAssertNotNil(tap.receive(type: .keyDown, event: event))
        XCTAssertEqual(order.value.count, 4)

        // A tap that is being shut down is not switched back on.
        tap.shutdown()
        _ = tap.receive(type: .tapDisabledByTimeout, event: event)
        XCTAssertEqual(order.value.last, "told")
    }

    // MARK: The real tap's receive path, with real events and no tap

    /// A real system-defined event, built the way the keyboard's arrive, as a
    /// `CGEvent` — which needs no permission and reaches no one's keys.
    private func systemDefinedEvent(
        subtype: Int16 = 8, key: Int, state: Int = 0xA, isRepeat: Bool = false, flags: CGEventFlags = []
    ) throws -> CGEvent {
        let packed = data1(key: key, state: state, isRepeat: isRepeat)
        let ns = try XCTUnwrap(NSEvent.otherEvent(
            with: .systemDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, subtype: subtype, data1: packed, data2: -1
        ))
        let event = try XCTUnwrap(ns.cgEvent)
        event.flags = flags
        return event
    }

    private let systemDefined = CGEventType(rawValue: 14)!

    func testAConsumedKeyIsSwallowedByReceive() throws {
        let event = try systemDefinedEvent(key: 0)
        let seen = LockedBox<[(MediaKeyPress, MediaKeyModifiers)]>([])
        let tap = MediaKeyTapContext(handler: { press, modifiers in seen.value.append((press, modifiers)); return true })
        XCTAssertNil(tap.receive(type: systemDefined, event: event), "nil is how a tap consumes an event")
        XCTAssertEqual(seen.value.count, 1)
        XCTAssertEqual(seen.value.first?.0, MediaKeyPress(key: .volumeUp, isDown: true, isRepeat: false))
        XCTAssertEqual(seen.value.first?.1, MediaKeyModifiers.none)
    }

    func testAKeyTheHandlerDeclinesIsReturnedToTheSystemUntouched() throws {
        let event = try systemDefinedEvent(key: 3, state: 0xB)
        let seen = LockedBox<[MediaKeyPress]>([])
        let tap = MediaKeyTapContext(handler: { press, _ in seen.value.append(press); return false })
        let answer = tap.receive(type: systemDefined, event: event)
        XCTAssertTrue(answer?.takeUnretainedValue() === event, "the very same event goes on")
        XCTAssertEqual(seen.value, [MediaKeyPress(key: .brightnessDown, isDown: false, isRepeat: false)])
    }

    func testReceiveDecodesTheRepeatBitAndForwardsTheFlags() throws {
        let event = try systemDefinedEvent(key: 1, isRepeat: true, flags: [.maskAlternate, .maskShift, .maskSecondaryFn])
        let seen = LockedBox<[(MediaKeyPress, MediaKeyModifiers)]>([])
        let tap = MediaKeyTapContext(handler: { press, modifiers in seen.value.append((press, modifiers)); return false })
        _ = tap.receive(type: systemDefined, event: event)
        XCTAssertEqual(seen.value.first?.0, MediaKeyPress(key: .volumeDown, isDown: true, isRepeat: true))
        XCTAssertEqual(seen.value.first?.1.fine, true)
        XCTAssertEqual(seen.value.first?.1.leavesToTheSystem, false)

        let chord = try systemDefinedEvent(key: 7, flags: .maskCommand)
        _ = tap.receive(type: systemDefined, event: chord)
        XCTAssertEqual(seen.value.last?.1.leavesToTheSystem, true)
    }

    func testReceiveNeverAsksTheHandlerAboutKeysThatAreNotOurs() throws {
        let asked = LockedBox(0)
        let tap = MediaKeyTapContext(handler: { _, _ in asked.value += 1; return true })
        // Play/pause, next track, eject: the right subtype, not our keys.
        for code in [16, 17, 14] {
            let event = try systemDefinedEvent(key: code)
            XCTAssertTrue(tap.receive(type: systemDefined, event: event)?.takeUnretainedValue() === event, "key \(code)")
        }
        // Another subtype of a system-defined event.
        let other = try systemDefinedEvent(subtype: 1, key: 0)
        XCTAssertTrue(tap.receive(type: systemDefined, event: other)?.takeUnretainedValue() === other)
        XCTAssertEqual(asked.value, 0)
    }

    func testADisabledNoticeNeverReachesTheHandlerEvenOnAMediaKeyEvent() throws {
        let event = try systemDefinedEvent(key: 0)
        let counts = LockedBox([0, 0, 0])   // asked, told, reenabled
        let tap = MediaKeyTapContext(
            handler: { _, _ in counts.value[0] += 1; return true },
            disabled: { counts.value[1] += 1 },
            reenable: { _ in counts.value[2] += 1 }
        )
        let answer = tap.receive(type: .tapDisabledByTimeout, event: event)
        XCTAssertTrue(answer?.takeUnretainedValue() === event, "the notice is passed, not consumed")
        XCTAssertEqual(counts.value, [0, 1, 1])
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
