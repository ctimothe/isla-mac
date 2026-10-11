import AppKit
import XCTest
@testable import IslaKit

/// The one voice Isla has for assistive technology (F-013).
///
/// Sighted people get a peek, a charger moment, a lock-card track change and a
/// shake; VoiceOver users used to get silence for every one of them. The
/// announcer is how those moments reach speech, and it is rate-limited so that
/// one gesture arriving by two routes — a click and the AX action, a hot key
/// pressed twice — is spoken once.
@MainActor
final class AnnouncerTests: XCTestCase {
    private var spoken: [String] = []
    private var clock: TimeInterval = 1_000
    private var savedSink: ((String) -> Void)?
    private var savedNow: (() -> TimeInterval)?

    override func setUp() {
        super.setUp()
        spoken = []
        clock = 1_000
        let announcer = Announcer.shared
        savedSink = announcer.sink
        savedNow = announcer.now
        announcer.sink = { [unowned self] in spoken.append($0) }
        announcer.now = { [unowned self] in clock }
        announcer.forget()
    }

    override func tearDown() {
        let announcer = Announcer.shared
        if let savedSink { announcer.sink = savedSink }
        if let savedNow { announcer.now = savedNow }
        announcer.forget()
        super.tearDown()
    }

    func testAnnouncementsReachTheSinkOnceAndRefuseDuplicates() {
        let announcer = Announcer.shared

        announcer.announce("Charging, 82 percent")
        clock += 0.5
        announcer.announce("Charging, 82 percent")
        XCTAssertEqual(spoken, ["Charging, 82 percent"],
                       "the same sentence twice inside a second is one event arriving by two routes")

        clock += 0.1
        announcer.announce("AirPods Pro connected")
        XCTAssertEqual(spoken, ["Charging, 82 percent", "AirPods Pro connected"],
                       "a different sentence is news and is never held back")

        // 1.2 s after the first charging sentence was spoken: a second plug-in
        // is a second event, and silence would be the bug again.
        clock = 1_000 + 1.2
        announcer.announce("Charging, 82 percent")
        XCTAssertEqual(spoken.last, "Charging, 82 percent")
        XCTAssertEqual(spoken.count, 3)
    }

    func testEmptyTextIsNeverSpoken() {
        Announcer.shared.announce("")
        XCTAssertEqual(spoken, [], "an empty announcement is VoiceOver saying nothing, loudly")
    }

    func testALockedRefusalIsAnnounced() throws {
        let probe = ProbeFixtures.isolatedStores()
        defer { probe.release() }
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: probe.stores)

        vm.nudgeLockedIsland()
        XCTAssertEqual(spoken, [], "unlocked, there is nothing to refuse and nothing to say")

        vm.isLockedPresentation = true
        vm.nudgeLockedIsland()
        XCTAssertEqual(spoken, ["Unlock your Mac to open Isla."])

        // The click and the AX action, or ⌃⌥⌘I pressed twice: one sentence.
        clock += 0.3
        vm.nudgeLockedIsland()
        XCTAssertEqual(spoken.count, 1, "the refusal is heard once, not twice")
    }
}
