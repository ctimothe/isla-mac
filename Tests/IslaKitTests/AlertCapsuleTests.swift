import SwiftUI
import XCTest
@testable import IslaKit

/// Every alert under the open panel (spec §19.5 d, amended 2026-10-26; owner:
/// "it's not consistent: when the island is open and I charge, it doesn't
/// show under the island — every HUD should"). The charger, headphones and
/// the confirmations take the level's capsule while a surface is open, one at
/// a time by the island's ranks with the level above them all; the shut
/// island's queue is what it was.
@MainActor
final class AlertCapsuleTests: XCTestCase {
    private let copied = IslandConfirmation(.copied)
    private let added = IslandConfirmation(.addedToShelf)
    private let held = AmbientActivity.charging(level: 80, isCharging: false, port: .usbC, watts: 61, hold: .onHold)

    override func setUp() {
        super.setUp()
        LabLocalization.use("en")
    }

    private func rig() throws -> (NotchController, NotchViewModel, ProbeStores) {
        let isolated = ProbeFixtures.isolatedStores()
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: isolated.stores)
        let root = NotchRootView(frame: CGRect(origin: .zero, size: vm.geometry.windowSize))
        let controller = NotchController()
        controller.attachForTesting(viewModel: vm, rootView: root)
        controller.hudFoldDelay = 0.15
        controller.confirmationHold = 0.2
        controller.momentsQuietForTesting = false
        return (controller, vm, isolated)
    }

    private func reading(_ level: Float = 0.5) -> HUDReading {
        HUDReading(kind: .volume, level: level, muted: false, deviceSymbol: nil)
    }

    private func spin(until done: () -> Bool, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    // MARK: Where a notice goes

    func testANoticeGoesUnderTheOpenPanelAndWaitsOnlyForADragOrTheLock() {
        func place(open: Bool = false, drop: Bool = false, locked: Bool = false) -> NotchController.NoticePlacement {
            NotchController.noticePlacement(isOpen: open, isDropTargeted: drop, isLocked: locked)
        }
        XCTAssertEqual(place(), .island, "shut: the island, through its queue, as before")
        XCTAssertEqual(place(open: true), .strip, "open: the capsule, now")
        XCTAssertEqual(place(open: true, drop: true), .island, "a drag: the drop surface is the answer, and it waits")
        XCTAssertEqual(place(open: true, locked: true), .island)
        XCTAssertEqual(place(locked: true), .island)
    }

    func testTheCapsuleCarriesWhatTheQueueCanShowThere() {
        XCTAssertEqual(StripNotice(.confirmation(copied)), .confirmation(copied))
        XCTAssertEqual(StripNotice(.ambient(held)), .ambient(held))
        XCTAssertNil(StripNotice(.peek), "the peek is the song's")
        XCTAssertNil(StripNotice(.music))
        XCTAssertEqual(StripNotice.confirmation(copied).activity, .confirmation(copied))
    }

    // MARK: Showing it

    func testAConfirmationOverAnOpenPanelShowsInTheCapsuleAndFolds() throws {
        let (controller, vm, isolated) = try rig()
        defer { isolated.release() }
        vm.isOpen = true
        controller.presentConfirmation(copied)
        XCTAssertEqual(vm.stripNotice, .confirmation(copied), "under the panel, at once")
        XCTAssertNil(vm.confirmation, "not the shut island's")
        XCTAssertEqual(vm.activity, .none, "the capsule is not an island activity")
        XCTAssertEqual(vm.bodySize, vm.openBodySize, "and changes nothing about the panel")
        spin(until: { vm.stripNotice == nil })
        XCTAssertNil(vm.stripNotice, "folded after its hold")
    }

    func testTheChargerOverAnOpenPanelShowsInTheCapsule() throws {
        try XCTSkipUnless(NotchViewModel.chargingEnabled, "Show Charging is off in this host's defaults")
        let (controller, vm, isolated) = try rig()
        defer { isolated.release() }
        vm.isOpen = true
        controller.presentAmbient(held)
        XCTAssertEqual(vm.stripNotice, .ambient(held))
        XCTAssertNil(vm.ambient)
    }

    func testTheChargerUnderTheOpenPanelIsStillQuietBeforeAnAudience() throws {
        try XCTSkipUnless(NotchViewModel.chargingEnabled, "Show Charging is off in this host's defaults")
        let (controller, vm, isolated) = try rig()
        defer { isolated.release() }
        controller.momentsQuietForTesting = true
        vm.isOpen = true
        controller.presentAmbient(held)
        XCTAssertNil(vm.stripNotice, "a mirrored display or a full-screen film: not even under the panel")
    }

    // MARK: One at a time, the level highest

    func testTheLevelTakesTheCapsuleOverANotice() throws {
        let (controller, vm, isolated) = try rig()
        defer { isolated.release() }
        controller.confirmationHold = 5
        vm.isOpen = true
        controller.presentConfirmation(copied)
        XCTAssertNotNil(vm.stripNotice)
        controller.presentHUD(reading())
        XCTAssertNotNil(vm.hudStrip, "the level")
        XCTAssertNil(vm.stripNotice, "replaced, and dropped (spec §19.1)")
        spin(until: { vm.hudStrip == nil })
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNil(vm.stripNotice, "a replaced notice does not come back")
    }

    func testANoticeBehindTheLevelWaitsItsPatienceAndThenShows() throws {
        let (controller, vm, isolated) = try rig()
        defer { isolated.release() }
        vm.isOpen = true
        controller.presentHUD(reading())
        XCTAssertFalse(controller.presentInStrip(.confirmation(added)), "outranked by the level: it waits")
        XCTAssertNil(vm.stripNotice)
        spin(until: { vm.stripNotice != nil })
        XCTAssertNil(vm.hudStrip)
        XCTAssertEqual(vm.stripNotice, .confirmation(added), "the level folded inside its patience")
    }

    func testAConfirmationOutranksTheChargerInTheCapsule() throws {
        let (controller, vm, isolated) = try rig()
        defer { isolated.release() }
        controller.confirmationHold = 5
        vm.isOpen = true
        XCTAssertTrue(controller.presentInStrip(.ambient(held)))
        XCTAssertTrue(controller.presentInStrip(.confirmation(copied)), "rank 5 over rank 7")
        XCTAssertEqual(vm.stripNotice, .confirmation(copied))
        XCTAssertFalse(controller.presentInStrip(.ambient(held)), "and the charger waits behind it")
        XCTAssertEqual(vm.stripNotice, .confirmation(copied))
    }

    // MARK: The close

    func testANoticeTheCloseCutShortIsHandedToTheShutIsland() async throws {
        let (controller, vm, isolated) = try rig()
        defer { isolated.release() }
        vm.isOpen = true
        controller.presentConfirmation(copied)
        XCTAssertNotNil(vm.stripNotice)
        // Return in the Clipboard: copy and close in one press.
        vm.isOpen = false
        XCTAssertNil(vm.stripNotice, "the capsule goes with the panel")
        let deadline = Date().addingTimeInterval(3)
        while vm.confirmation == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(vm.confirmation, copied, "and the shut island shows it for its hold")
    }

    func testANoticeThatWasReadGoesWithThePanel() async throws {
        let (controller, vm, isolated) = try rig()
        defer { isolated.release() }
        controller.confirmationHold = 5
        vm.isOpen = true
        controller.presentConfirmation(copied)
        try await Task.sleep(for: .seconds(StripNotice.handBackWindow + 0.1))
        vm.isOpen = false
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(vm.confirmation, "it stood long enough to be read")
        XCTAssertNil(vm.stripNotice)
    }

    /// Codex review 2026-10-26: a "Copied" waiting behind the level has no
    /// `stripNotice` yet, and the close used to say nothing about it.
    func testANoticeWaitingBehindTheLevelIsHandedToTheShutIslandOnClose() async throws {
        let (controller, vm, isolated) = try rig()
        defer { isolated.release() }
        controller.hudFoldDelay = 5
        vm.isOpen = true
        controller.presentHUD(reading())
        XCTAssertFalse(controller.presentInStrip(.confirmation(copied)), "outranked by the level: it waits")
        vm.isOpen = false
        XCTAssertNil(vm.stripNotice)
        let deadline = Date().addingTimeInterval(3)
        while vm.confirmation == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(vm.confirmation, copied, "it was never seen, so the shut island shows it")
    }

    /// Codex review 2026-10-26: a charger that waited behind a confirmation
    /// is asked again as it leaves the queue, so a moment that turned quiet
    /// meanwhile does not show it.
    func testAWaitingChargerIsAskedAgainWhenTheCapsuleFrees() throws {
        let (controller, vm, isolated) = try rig()
        defer { isolated.release() }
        vm.isOpen = true
        XCTAssertTrue(controller.presentInStrip(.confirmation(copied)))
        XCTAssertFalse(controller.presentInStrip(.ambient(held)), "it waits behind the confirmation")
        controller.momentsQuietForTesting = true
        spin(until: { vm.stripNotice != .confirmation(copied) })
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNil(vm.stripNotice, "quiet now: the waiting charger is refused, not shown")
    }

    /// Codex review 2026-10-27: a plug-in that waited for the capsule shows
    /// the newest reading, not the edge's.
    func testAWaitingChargerShowsItsNewestReading() throws {
        let (controller, vm, isolated) = try rig()
        defer { isolated.release() }
        vm.isOpen = true
        let edge = AmbientActivity.charging(level: 80, isCharging: false, port: .usbC, watts: nil, hold: .settling)
        controller.latestCharge = (held, Date())
        controller.presentAmbient(edge)
        XCTAssertEqual(vm.stripNotice, .ambient(held), "the re-read's On Hold, 61 W, not the edge's Charging")
    }

    func testTheHandBackRule() {
        XCTAssertTrue(StripNotice.handsBack(shownFor: 0))
        XCTAssertTrue(StripNotice.handsBack(shownFor: 0.5))
        XCTAssertFalse(StripNotice.handsBack(shownFor: StripNotice.handBackWindow))
        XCTAssertFalse(StripNotice.handsBack(shownFor: 2))
    }

    func testADragTakesTheNoticeDown() throws {
        let (controller, vm, isolated) = try rig()
        defer { isolated.release() }
        controller.confirmationHold = 5
        vm.isOpen = true
        controller.presentConfirmation(copied)
        vm.isDropTargeted = true
        XCTAssertNil(vm.stripNotice, "the drop surface is the panel's whole answer")
    }

    func testAShutIslandStillQueuesAsBefore() throws {
        let (controller, vm, isolated) = try rig()
        defer { isolated.release() }
        controller.presentConfirmation(copied)
        XCTAssertEqual(vm.confirmation, copied, "the shut island's pill")
        XCTAssertNil(vm.stripNotice, "never the capsule")
    }

    // MARK: Drawing

    func testEveryNoticeRendersInTheCapsule() throws {
        let width = HUDStripLayout.preferredWidth
        for notice: StripNotice in [
            .ambient(held),
            .ambient(.charging(level: 64, isCharging: true, port: .magSafe, watts: 140)),
            .ambient(.charging(level: 12, isCharging: true, port: .usbC, watts: 61)),
            .ambient(.headphones(name: "AirPods Max", symbol: "airpodsmax")),
            .confirmation(copied), .confirmation(added), .confirmation(IslandConfirmation(.lyricsImported)),
        ] {
            let renderer = ImageRenderer(content: StripNoticeContent(notice: notice, width: width, increaseContrast: false))
            let image = try XCTUnwrap(renderer.nsImage, "\(notice) renders")
            XCTAssertEqual(image.size.height, HUDStripLayout.height, accuracy: 0.5, "the level's 32 pt")
            XCTAssertEqual(image.size.width, width, accuracy: 0.5)
        }
    }

    /// A name that fits is never cut (Batch 4, 2026-10-29). In Russian the
    /// capsule said "AirPods… Подключено" with room to spare after it: the
    /// row's spacer was offered its share before the name had what it needed.
    /// "AirPods Max" and "Подключено" need about 159 pt of the 220 pt
    /// capsule's 162; the name gives way only when it truly does not fit.
    func testAHeadphoneNameThatFitsIsNeverCut() async throws {
        defer { LabLocalization.use("en") }
        for language in ["en", "ru"] {
            LabLocalization.use(language)
            let name = "AirPods Max"
            let capsule = StripNoticeContent(
                notice: .ambient(.headphones(name: name, symbol: "airpodsmax")),
                width: HUDStripLayout.preferredWidth, increaseContrast: false
            )
            let root = await AXProbe.tree(of: capsule, size: CGSize(width: HUDStripLayout.preferredWidth,
                                                                    height: HUDStripLayout.height))
            let drawn = try XCTUnwrap(root.all { $0.label == name || $0.value == name }.first?.frame, root.dump)
            let natural = NSHostingView(rootView: Text(name)
                .font(.system(size: StripNoticeLayout.textSize))
                .tracking(Theme.tracking(forSize: StripNoticeLayout.textSize))
                .fixedSize()).fittingSize.width
            XCTAssertGreaterThanOrEqual(drawn.width, natural - 0.5, "\(language): the name is cut\n\(root.dump)")
        }
    }

    /// The confirmations' row ended in the same trailing spacer; none of
    /// their words is cut in either language, at the width the capsule is
    /// drawn at — `preferredWidth`, since every open body is at least 480
    /// wide (`minimumWidth` is a floor no panel reaches).
    func testNoConfirmationIsCut() async throws {
        defer { LabLocalization.use("en") }
        for language in ["en", "ru"] {
            LabLocalization.use(language)
            for kind in [IslandConfirmation.Kind.lyricsImported, .copied, .addedToShelf] {
                let confirmation = IslandConfirmation(kind)
                let capsule = StripNoticeContent(notice: .confirmation(confirmation),
                                                 width: HUDStripLayout.preferredWidth, increaseContrast: false)
                let root = await AXProbe.tree(of: capsule, size: CGSize(width: HUDStripLayout.preferredWidth,
                                                                        height: HUDStripLayout.height))
                let title = confirmation.title
                let drawn = try XCTUnwrap(root.all { $0.label == title || $0.value == title }.first?.frame, root.dump)
                let natural = NSHostingView(rootView: Text(title)
                    .font(.system(size: StripNoticeLayout.textSize))
                    .tracking(Theme.tracking(forSize: StripNoticeLayout.textSize))
                    .fixedSize()).fittingSize.width
                XCTAssertGreaterThanOrEqual(drawn.width, natural - 0.5,
                                            "\(language) \(kind)\n\(root.dump)")
            }
        }
    }
}
