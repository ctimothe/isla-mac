import AppKit
import XCTest
@testable import IslaKit

/// The island's confirmations — "Lyrics imported", "Copied", "Added to
/// Shelf" (2026-10-25, MR-7): an alert at rank 5, held 1.5 s, that waits its
/// second for an open panel and is dropped after it, so an act made in the
/// open panel is answered there and only there.
@MainActor
final class IslandConfirmationTests: XCTestCase {
    private let imported = IslandConfirmation(.lyricsImported)
    private let copied = IslandConfirmation(.copied)
    private let added = IslandConfirmation(.addedToShelf)
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var spoken: [String] = []
    private var savedSink: ((String) -> Void)?

    override func setUp() {
        super.setUp()
        LabLocalization.use("en")
        spoken = []
        savedSink = Announcer.shared.sink
        Announcer.shared.sink = { [unowned self] in spoken.append($0) }
        Announcer.shared.forget()
    }

    override func tearDown() {
        if let savedSink { Announcer.shared.sink = savedSink }
        Announcer.shared.forget()
        LabLocalization.use("en")
        super.tearDown()
    }

    // MARK: What it says

    func testEachActHasItsSymbolAndWords() {
        XCTAssertEqual(imported.symbol, "checkmark.circle.fill")
        XCTAssertEqual(imported.title, "Lyrics imported")
        XCTAssertEqual(copied.symbol, "doc.on.doc.fill")
        XCTAssertEqual(copied.title, "Copied")
        XCTAssertEqual(added.symbol, "tray.and.arrow.down.fill")
        XCTAssertEqual(added.title, "Added to Shelf")
        for confirmation in [imported, copied, added] {
            XCTAssertNotNil(NSImage(systemSymbolName: confirmation.symbol, accessibilityDescription: nil), confirmation.symbol)
            XCTAssertEqual(confirmation.accessibilityLabel, confirmation.title)
        }
        XCTAssertEqual(IslandConfirmation.holdDuration, 1.5)
        XCTAssertFalse(copied.announcesAtTheAct, "every copy already says \"Copied\"")
        XCTAssertTrue(imported.announcesAtTheAct)
        XCTAssertTrue(added.announcesAtTheAct)

        LabLocalization.use("ru")
        XCTAssertEqual(IslandConfirmation(.lyricsImported).title, "Текст импортирован")
        XCTAssertEqual(IslandConfirmation(.copied).title, "Скопировано")
        XCTAssertEqual(IslandConfirmation(.addedToShelf).title, "Добавлено на полку")
    }

    // MARK: Its rank

    func testItRanksBesideTranslatedUnderThePopUp() {
        let hud = HUDMoment(HUDReading(kind: .volume, level: 0.5, muted: false, deviceSymbol: nil))
        let confirmation = IslandActivity.confirmation(copied)
        XCTAssertEqual(confirmation.rank, 5)
        XCTAssertTrue(confirmation.isAlert)
        XCTAssertFalse(confirmation.isLive)
        XCTAssertTrue(confirmation.queues, "it waits its second, unlike the pop-up")

        func current(hud: HUDMoment? = nil, ambient: AmbientActivity? = nil, music: Bool = false, shelf: Int = 0) -> IslandActivity {
            IslandActivity.current(
                hud: hud, confirmation: copied, ambient: ambient,
                isPeeking: music, musicIsVisible: music, shelfCount: shelf
            )
        }
        XCTAssertEqual(current(music: true, shelf: 3), confirmation, "over Music, the Shelf and a peek")
        XCTAssertEqual(current(ambient: .headphones(name: "AirPods", symbol: "airpods")), confirmation, "over headphones")
        XCTAssertEqual(current(ambient: .charging(level: 50, isCharging: true)), confirmation, "over the charger")
        XCTAssertEqual(current(hud: hud), .hud(hud), "under the key pop-up")
        XCTAssertEqual(NotchViewModel.click(on: confirmation, live: .music), .foldAlert, "a click folds it")
        XCTAssertEqual(NotchViewModel.openTarget(live: confirmation, hasTrack: true), .player)
        XCTAssertNil(IslandActivity.bubble(beside: confirmation, shelfCount: 2, isOpen: false, isLocked: false),
                     "no bubble beside an alert")
    }

    // MARK: In time

    func testANewerConfirmationReplacesTheOlderAndOutranksTheCharger() {
        var queue = IslandAlertQueue()
        let charger = IslandActivity.ambient(.charging(level: 67, isCharging: true))
        XCTAssertEqual(queue.post(.confirmation(copied), showing: .music, blocked: false, at: t0), .show)
        XCTAssertEqual(queue.post(.confirmation(added), showing: .confirmation(copied), blocked: false, at: t0),
                       .show, "an equal one replaces the older at once")
        XCTAssertEqual(queue.post(charger, showing: .confirmation(added), blocked: false, at: t0), .wait,
                       "the charger waits behind it")
        XCTAssertEqual(queue.next(at: t0.addingTimeInterval(0.9)), charger, "and shows if it folds inside the second")

        let hud = IslandActivity.hud(HUDMoment(HUDReading(kind: .volume, level: 0.5, muted: false, deviceSymbol: nil)))
        XCTAssertEqual(queue.post(.confirmation(copied), showing: hud, blocked: false, at: t0), .wait)
        XCTAssertNil(queue.next(at: t0.addingTimeInterval(1.1)), "dropped once its second is gone")
    }

    /// One surface per event: posted over an open panel it waits, and shows
    /// only if the panel closes inside the second — Return copying and closing,
    /// a drag-opened panel folding back. A panel that stays open answers for
    /// itself, and the confirmation lapses.
    func testOverAnOpenPanelItWaitsASecondThenLapses() {
        var queue = IslandAlertQueue()
        XCTAssertEqual(queue.post(.confirmation(copied), showing: .music, blocked: true, at: t0), .wait)
        XCTAssertEqual(queue.next(at: t0.addingTimeInterval(0.3)), .confirmation(copied), "the panel closed in time")

        XCTAssertEqual(queue.post(.confirmation(added), showing: .none, blocked: true, at: t0), .wait)
        XCTAssertNil(queue.next(at: t0.addingTimeInterval(1.2)), "the panel stayed: nothing later on the island")
    }

    func testThePillFitsItsWordsBesideTheNotch() {
        let notch = CGSize(width: 185, height: 38)
        for confirmation in [imported, copied, added] {
            let size = ConfirmationLayout.bodySize(title: confirmation.title, notchSize: notch, bodyWidth: 560)
            XCTAssertEqual(size.height, 38)
            XCTAssertGreaterThanOrEqual(size.width, notch.width + NotchMetrics.compactChargingExtension, "never narrower than the charger")
            let wing = (size.width - notch.width) / 2
            XCTAssertGreaterThanOrEqual(
                wing,
                ConfirmationLayout.titleWidth(confirmation.title) + ConfirmationLayout.trailingInset
                    + CompactIslandLayout.cutoutClearance,
                "\(confirmation.title) fits the right wing, clear of the notch"
            )
        }
        let capped = ConfirmationLayout.bodySize(title: String(repeating: "W", count: 80), notchSize: notch, bodyWidth: 480)
        XCTAssertEqual(capped.width, 480, "never wider than the panel")
    }

    // MARK: The controller

    private func rig() throws -> (NotchController, NotchViewModel, ProbeStores) {
        let isolated = ProbeFixtures.isolatedStores()
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: isolated.stores)
        let root = NotchRootView(frame: CGRect(origin: .zero, size: vm.geometry.windowSize))
        let controller = NotchController()
        controller.attachForTesting(viewModel: vm, rootView: root)
        controller.confirmationHold = 0.2
        return (controller, vm, isolated)
    }

    func testItShowsForItsHoldThenTheIslandReturnsToWhatIsLive() async throws {
        XCTAssertEqual(NotchController().confirmationHold, 1.5, "the hold")
        let (controller, vm, isolated) = try rig()
        defer { isolated.release() }
        // Held: the model's road to it is weak, as the app's is.
        withExtendedLifetime(controller) { vm.confirm(.lyricsImported) }
        XCTAssertEqual(vm.activity, .confirmation(imported))
        XCTAssertEqual(vm.bodySize.height, vm.geometry.notchSize.height, "a compact pill")
        let deadline = Date().addingTimeInterval(3)
        while vm.confirmation != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(vm.confirmation, "folded after its hold")
        XCTAssertEqual(vm.activity, .none)
        _ = controller
    }

    func testANewConfirmationRestartsTheHold() async throws {
        let (controller, vm, isolated) = try rig()
        defer { isolated.release() }
        controller.confirmationHold = 0.5
        controller.presentConfirmation(copied)
        try await Task.sleep(for: .milliseconds(300))
        controller.presentConfirmation(added)
        let last = Date()
        XCTAssertEqual(vm.confirmation, added, "the newer replaces the older")
        let deadline = Date().addingTimeInterval(3)
        while vm.confirmation != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(vm.confirmation)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(last), 0.45, "the older's timer did not fold the newer")
    }

    func testThePopUpReplacesItAndAnOpenPanelHoldsItBack() throws {
        let (controller, vm, isolated) = try rig()
        defer { isolated.release() }
        controller.presentConfirmation(copied)
        controller.presentHUD(HUDReading(kind: .volume, level: 0.4, muted: false, deviceSymbol: nil))
        XCTAssertNil(vm.confirmation, "replaced by the pop-up, so dropped")
        XCTAssertNotNil(vm.hud)

        vm.hud = nil
        vm.isOpen = true
        controller.presentConfirmation(added)
        XCTAssertNil(vm.confirmation, "nothing over the open panel")
        vm.isOpen = false
        vm.isLockedPresentation = true
        controller.presentConfirmation(added)
        XCTAssertNil(vm.confirmation, "nor over the lock screen")
    }

    func testOpeningThePanelTakesItDown() throws {
        let (controller, vm, isolated) = try rig()
        defer { isolated.release() }
        controller.presentConfirmation(imported)
        XCTAssertNotNil(vm.confirmation)
        vm.isOpen = true
        XCTAssertNil(vm.confirmation, "the panel shows its own answer")
    }

    // MARK: Spoken once

    func testEachActSpeaksOnceAndCopyingNotAgain() throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: isolated.stores)
        var posted: [IslandConfirmation] = []
        vm.onConfirmation = { posted.append($0) }
        vm.confirm(.lyricsImported)
        vm.confirm(.addedToShelf)
        vm.confirm(.copied)
        XCTAssertEqual(posted, [imported, added, copied])
        XCTAssertEqual(spoken, ["Lyrics imported", "Added to Shelf"], "Copied was already said by the copy")
    }

    func testAnAcceptedDropAsksForAddedToShelf() throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: isolated.stores)
        var posted: [IslandConfirmation] = []
        vm.onConfirmation = { posted.append($0) }
        let file = isolated.temp.appendingPathComponent("note.txt")
        try Data("hi".utf8).write(to: file)
        XCTAssertTrue(vm.acceptDrop(urls: [file]))
        XCTAssertEqual(posted, [added])
    }
}
