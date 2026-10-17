import AppKit
import Carbon.HIToolbox
import XCTest
@testable import IslaKit

/// Delete and ⌘⌫ on the Shelf (redesign 2026-10-15, spec §8.2, decision 9).
///
/// The panel is never key outside Translate, so the key is a transient Carbon
/// hot key, registered only while the pointer is on the Shelf pane **and** a
/// selection exists. A global Delete left registered would take the person's
/// Delete key in every app until Isla quit, which is the worst bug this
/// feature could have, so the rule that registers it and the object that holds
/// it are tested exhaustively and with a fake registrar: **no test here ever
/// reserves a real key**.
@MainActor
final class ShelfDeleteKeyTests: XCTestCase {

    // MARK: - The rule

    /// All 64 combinations of the six inputs: the keys are claimed in exactly
    /// one of them. Any single input going false is enough to give them back.
    func testTheKeysAreClaimedOnlyWhenEveryTermHolds() {
        var claimed = 0
        for bits in 0..<64 {
            let open = bits & 1 != 0
            let onShelf = bits & 2 != 0
            let pointer = bits & 4 != 0
            let selection = bits & 8 != 0
            let active = bits & 16 != 0
            let locked = bits & 32 != 0
            let claim = NotchViewModel.claimsDelete(
                panelOpen: open, onShelf: onShelf, pointerOnShelf: pointer,
                hasSelection: selection, appIsActive: active, locked: locked
            )
            let expected = open && onShelf && pointer && selection && !active && !locked
            XCTAssertEqual(claim, expected, "bits \(bits)")
            if claim { claimed += 1 }
        }
        XCTAssertEqual(claimed, 1)
    }

    func testEachWayToLoseTheClaim() {
        func claims(
            open: Bool = true, onShelf: Bool = true, pointer: Bool = true, selection: Bool = true,
            active: Bool = false, locked: Bool = false
        ) -> Bool {
            NotchViewModel.claimsDelete(
                panelOpen: open, onShelf: onShelf, pointerOnShelf: pointer,
                hasSelection: selection, appIsActive: active, locked: locked
            )
        }
        XCTAssertTrue(claims(), "pointer on the Shelf, a selection: the keys are held")
        XCTAssertFalse(claims(pointer: false), "the pointer left the Shelf")
        XCTAssertFalse(claims(selection: false), "the selection emptied")
        XCTAssertFalse(claims(open: false), "the panel closed")
        XCTAssertFalse(claims(locked: true), "the screen locked: never over the password field")
        XCTAssertFalse(claims(onShelf: false), "the tab changed")
        XCTAssertFalse(claims(active: true), "Quick Look and AirDrop windows have their own use for the key")
    }

    /// Nothing selected, nothing claimed: a Delete pressed with nothing picked
    /// is never swallowed, wherever the pointer is.
    func testNoSelectionNeverClaims() {
        for pointer in [false, true] {
            XCTAssertFalse(NotchViewModel.claimsDelete(
                panelOpen: true, onShelf: true, pointerOnShelf: pointer,
                hasSelection: false, appIsActive: false, locked: false
            ))
        }
    }

    // MARK: - The holder, with a fake registrar

    /// A registrar that records instead of reserving: how many registrations
    /// are live at once, how many were ever made, and what each was for.
    @MainActor
    final class FakeRegistrar {
        final class Registration: HotKeyRegistration {
            let binding: HotKeyBinding
            let action: () -> Void
            private(set) var isLive = true
            init(binding: HotKeyBinding, action: @escaping () -> Void) {
                self.binding = binding
                self.action = action
            }
            func unregister() { isLive = false }
        }

        private(set) var all: [Registration] = []
        private(set) var peak = 0
        var refusing: Set<UInt32> = []
        var live: [Registration] { all.filter(\.isLive) }

        var registrar: ShelfDeleteKeyHolder.Registrar {
            { [unowned self] binding, action in
                if refusing.contains(binding.modifiers) { return nil }
                let registration = Registration(binding: binding, action: action)
                all.append(registration)
                peak = max(peak, live.count)
                return registration
            }
        }
    }

    private func holder(_ fake: FakeRegistrar, onPress: @escaping () -> Void = {}) -> ShelfDeleteKeyHolder {
        ShelfDeleteKeyHolder(registrar: fake.registrar, onPress: onPress)
    }

    /// Delete, and ⌘⌫ — two keys, plain and Command, both the Delete key's code.
    func testItHoldsDeleteAndCommandDelete() {
        let fake = FakeRegistrar()
        let keys = holder(fake)
        XCTAssertFalse(keys.isRegistered)
        keys.update(wanted: true)
        XCTAssertTrue(keys.isRegistered)
        XCTAssertEqual(fake.live.count, 2)
        XCTAssertEqual(
            Set(fake.live.map { "\($0.binding.keyCode):\($0.binding.modifiers)" }),
            [
                "\(kVK_Delete):0",
                "\(kVK_Delete):\(UInt32(cmdKey))",
            ]
        )
        XCTAssertEqual(ShelfDeleteKeyHolder.bindings.count, 2)
    }

    /// Asking again for what is already so does nothing, in both directions: a
    /// burst of notifications cannot register a second pair that nothing could
    /// ever give back.
    func testItNeverRegistersTwice() {
        let fake = FakeRegistrar()
        let keys = holder(fake)
        for _ in 0..<5 { keys.update(wanted: true) }
        XCTAssertEqual(fake.all.count, 2, "one pair, however many times it was asked")
        XCTAssertEqual(fake.peak, 2)
        for _ in 0..<5 { keys.update(wanted: false) }
        XCTAssertTrue(fake.live.isEmpty)
        XCTAssertEqual(fake.all.count, 2, "giving them back again registers nothing")
    }

    func testItGivesBothKeysBackTheMomentItIsToldTo() {
        let fake = FakeRegistrar()
        let keys = holder(fake)
        keys.update(wanted: true)
        keys.update(wanted: false)
        XCTAssertFalse(keys.isRegistered)
        XCTAssertTrue(fake.live.isEmpty, "not one registration outlives the claim")
        XCTAssertTrue(fake.all.allSatisfy { !$0.isLive })
    }

    func testTeardownGivesThemBackAndIsSafeToRepeat() {
        let fake = FakeRegistrar()
        let keys = holder(fake)
        keys.update(wanted: true)
        keys.teardown()
        keys.teardown()
        XCTAssertTrue(fake.live.isEmpty)
        keys.update(wanted: true)
        XCTAssertEqual(fake.live.count, 2, "and it can claim again afterwards")
        keys.teardown()
        XCTAssertTrue(fake.live.isEmpty)
    }

    /// The claim's whole life, step by step: every way it can start and stop,
    /// in an order that walks each input down and up. After every single
    /// step the number of live registrations is two exactly when the claim
    /// holds and zero otherwise, never more, and at the end none are left.
    func testRegistrationFollowsTheClaimThroughEveryTransition() {
        struct Inputs {
            var open = false, onShelf = false, pointer = false, selection = false, active = false, locked = false
            var claim: Bool {
                NotchViewModel.claimsDelete(
                    panelOpen: open, onShelf: onShelf, pointerOnShelf: pointer,
                    hasSelection: selection, appIsActive: active, locked: locked
                )
            }
        }
        let fake = FakeRegistrar()
        let keys = holder(fake)
        var inputs = Inputs()
        func step(_ label: String, _ change: (inout Inputs) -> Void) {
            change(&inputs)
            keys.update(wanted: inputs.claim)
            XCTAssertEqual(fake.live.count, inputs.claim ? 2 : 0, "after \(label)")
            XCTAssertLessThanOrEqual(fake.live.count, 2, "never a second pair, after \(label)")
            XCTAssertEqual(keys.isRegistered, inputs.claim, "after \(label)")
        }
        step("the panel opens") { $0.open = true }
        step("the Shelf is showing") { $0.onShelf = true }
        step("something is selected") { $0.selection = true }
        step("the pointer arrives") { $0.pointer = true }              // claimed
        step("the pointer leaves") { $0.pointer = false }              // given back
        step("the pointer returns") { $0.pointer = true }              // claimed
        step("the selection empties") { $0.selection = false }         // given back
        step("a card is picked") { $0.selection = true }               // claimed
        step("the panel closes") { $0.open = false }                   // given back
        step("the panel opens again") { $0.open = true }               // claimed
        step("the screen locks") { $0.locked = true }                  // given back
        step("the Mac unlocks") { $0.locked = false }                  // claimed
        step("the tab changes") { $0.onShelf = false }                 // given back
        step("the Shelf comes back") { $0.onShelf = true }             // claimed
        step("the app activates for Quick Look") { $0.active = true }  // given back
        step("Quick Look closes") { $0.active = false }                // claimed
        step("everything at once") {                                    // given back
            $0.open = false; $0.pointer = false; $0.selection = false; $0.locked = true
        }
        keys.teardown()
        XCTAssertTrue(fake.live.isEmpty, "nothing is left registered at the end")
        XCTAssertLessThanOrEqual(fake.peak, 2, "at no point were there more than the one pair")
        // Every registration ever made was given back.
        XCTAssertTrue(fake.all.allSatisfy { !$0.isLive })
    }

    /// The same, exhaustively: walk every one of the 64 input combinations, in
    /// Gray-code order so each step flips one input, and check the invariant
    /// after each.
    func testEveryCombinationLeavesTheRightNumberRegistered() {
        let fake = FakeRegistrar()
        let keys = holder(fake)
        for index in 0..<64 {
            let bits = index ^ (index >> 1)
            let claim = NotchViewModel.claimsDelete(
                panelOpen: bits & 1 != 0, onShelf: bits & 2 != 0, pointerOnShelf: bits & 4 != 0,
                hasSelection: bits & 8 != 0, appIsActive: bits & 16 != 0, locked: bits & 32 != 0
            )
            keys.update(wanted: claim)
            XCTAssertEqual(fake.live.count, claim ? 2 : 0, "combination \(bits)")
        }
        keys.teardown()
        XCTAssertTrue(fake.live.isEmpty)
        XCTAssertLessThanOrEqual(fake.peak, 2)
    }

    /// macOS may refuse one of the two keys. What was registered is still given
    /// back with `update(wanted: false)`, and a refusal leaves no half-held pair
    /// that a later claim would skip over unnoticed.
    func testARefusedKeyDoesNotStrandTheOther() {
        let fake = FakeRegistrar()
        fake.refusing = [UInt32(cmdKey)]
        let keys = holder(fake)
        keys.update(wanted: true)
        XCTAssertEqual(fake.live.count, 1, "plain Delete held, ⌘⌫ refused")
        keys.update(wanted: false)
        XCTAssertTrue(fake.live.isEmpty, "the one that was held goes back")

        fake.refusing = [UInt32(cmdKey), 0]
        keys.update(wanted: true)
        XCTAssertFalse(keys.isRegistered, "nothing registered is nothing held")
        XCTAssertTrue(fake.live.isEmpty)
    }

    /// A press runs the owner's closure, which re-asks the claim before acting.
    func testAPressReachesTheOwner() {
        let fake = FakeRegistrar()
        var presses = 0
        let keys = holder(fake) { presses += 1 }
        keys.update(wanted: true)
        fake.live.forEach { $0.action() }
        XCTAssertEqual(presses, 2, "one per key")
    }

    // MARK: - The pointer, as the sampler reports it

    func testThePointerWatcherReportsEnteringAndLeavingTheShelf() {
        let watcher = PointerWatcher()
        var reports: [Bool] = []
        watcher.onShelfChange = { reports.append($0) }
        // Far from any real pointer: assigning the rect samples where the mouse
        // really is, and the developer's must not count.
        let zone = CGRect(x: 1_000_000, y: 1_000_000, width: 400, height: 150)
        watcher.shelfRect = zone
        XCTAssertEqual(reports, [], "a rect cut around nothing reports nothing")

        watcher.sampleShelf(at: CGPoint(x: 1_000_100, y: 1_000_100))
        XCTAssertEqual(reports, [true])
        watcher.sampleShelf(at: CGPoint(x: 1_000_120, y: 1_000_100))
        XCTAssertEqual(reports, [true], "moving about on the Shelf says nothing more")
        watcher.sampleShelf(at: CGPoint(x: 5, y: 5))
        XCTAssertEqual(reports, [true, false], "leaving reports once")
        watcher.sampleShelf(at: CGPoint(x: 6, y: 6))
        XCTAssertEqual(reports, [true, false])
    }

    /// Cutting the rect empty — the tab changed, the panel closed — is "off the
    /// Shelf" at once, not at the next tick.
    func testAnEmptyRectEndsTheClaimAtOnce() {
        let watcher = PointerWatcher()
        var reports: [Bool] = []
        watcher.onShelfChange = { reports.append($0) }
        watcher.shelfRect = CGRect(x: 1_000_000, y: 1_000_000, width: 400, height: 150)
        watcher.sampleShelf(at: CGPoint(x: 1_000_100, y: 1_000_100))
        XCTAssertEqual(reports, [true])
        watcher.shelfRect = .zero
        XCTAssertEqual(reports, [true, false])
    }

    /// The sampler stopping — a lock, a sleep, a rebuild — gives Delete back.
    func testStoppingTheSamplerLeavesTheShelf() {
        let watcher = PointerWatcher()
        var reports: [Bool] = []
        watcher.onShelfChange = { reports.append($0) }
        watcher.shelfRect = CGRect(x: 1_000_000, y: 1_000_000, width: 400, height: 150)
        watcher.sampleShelf(at: CGPoint(x: 1_000_100, y: 1_000_100))
        watcher.stop()
        XCTAssertEqual(reports, [true, false])
    }

    /// The zone is the tray: the body's whole width, below the header strip —
    /// and not the strip, where Remove All is. There is no rail to the left of
    /// it and no padding under it any more (§19.7).
    func testThePointerZoneIsTheTray() {
        let body = CGRect(x: 100, y: 500, width: 385.3, height: 158)
        let zone = ShelfLayout.pointerZone(bodyScreenRect: body, headerHeight: 38)
        XCTAssertEqual(zone.minX, 100)
        XCTAssertEqual(zone.maxX, 100 + 385.3, accuracy: 0.001)
        XCTAssertEqual(zone.minY, 500)
        XCTAssertEqual(zone.maxY, 500 + 158 - 38, "AppKit's y runs up: the header is the top 38")
        XCTAssertFalse(zone.contains(CGPoint(x: 300, y: 500 + 158 - 10)), "the header strip")
        XCTAssertTrue(zone.contains(CGPoint(x: 120, y: 600)), "the first tile's column: no rail to be left of")
        XCTAssertTrue(zone.contains(CGPoint(x: 300, y: 600)))
        XCTAssertFalse(zone.contains(CGPoint(x: 99, y: 600)), "left of the body")
    }

    // MARK: - The key on a panel that is key

    func testWhichPressesAreTheRemoveKey() {
        XCTAssertTrue(NotchPanel.isRemoveKey(keyCode: UInt16(kVK_Delete), flags: []))
        XCTAssertTrue(NotchPanel.isRemoveKey(keyCode: UInt16(kVK_Delete), flags: .command))
        XCTAssertTrue(NotchPanel.isRemoveKey(keyCode: UInt16(kVK_Delete), flags: [.command, .capsLock]), "Caps Lock is no modifier")
        XCTAssertFalse(NotchPanel.isRemoveKey(keyCode: UInt16(kVK_Delete), flags: .option), "⌥⌫ deletes a word")
        XCTAssertFalse(NotchPanel.isRemoveKey(keyCode: UInt16(kVK_Delete), flags: .shift))
        XCTAssertFalse(NotchPanel.isRemoveKey(keyCode: UInt16(kVK_Delete), flags: .control))
        XCTAssertFalse(NotchPanel.isRemoveKey(keyCode: UInt16(kVK_Delete), flags: [.command, .option]))
        XCTAssertFalse(NotchPanel.isRemoveKey(keyCode: UInt16(kVK_ForwardDelete), flags: []))
        XCTAssertFalse(NotchPanel.isRemoveKey(keyCode: UInt16(kVK_ANSI_C), flags: .command))
    }

    func testAKeyPanelOffersTheKeyToTheShelfFirst() throws {
        let panel = NotchPanel(contentRect: CGRect(x: 0, y: 0, width: 200, height: 40))
        defer { panel.close() }
        var asked = 0
        var answer = true
        panel.removeKeyHandled = { asked += 1; return answer }
        func press(flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
                characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}", isARepeat: false,
                keyCode: UInt16(kVK_Delete)
            ))
        }
        panel.sendEvent(try press(flags: []))
        panel.sendEvent(try press(flags: .command))
        XCTAssertEqual(asked, 2, "Delete and ⌘⌫ both go to the Shelf's handler")
        // A handler that declines (no selection, another tab) lets the key through.
        answer = false
        panel.sendEvent(try press(flags: []))
        XCTAssertEqual(asked, 3)
    }

    // MARK: - Removal never touches the file

    private struct Fixture {
        let suite: String
        let defaults: UserDefaults
        let folder: URL
        let shelf: ShelfStore
        let files: [URL]

        @MainActor
        init(names: [String]) throws {
            suite = "ShelfDeleteKeyTests.\(UUID().uuidString)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("isla-shelf-delete-\(UUID().uuidString)", isDirectory: true)
            self.folder = folder
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            shelf = ShelfStore(defaults: defaults)
            shelf.requestThumbnail = { _, done in done(nil) }
            shelf.makeBookmark = { _ in nil }
            let made = names.map { folder.appendingPathComponent($0) }
            for file in made { FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8)) }
            shelf.add(made)
            files = made
        }

        func release() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// The key removes the cards; the files stay exactly where they were, and
    /// the cards that were not picked stay too.
    func testRemovingTheSelectionNeverTouchesTheFiles() throws {
        let fixture = try Fixture(names: ["a.txt", "b.txt", "c.txt"])
        defer { fixture.release() }
        let shelf = fixture.shelf
        let fake = FakeRegistrar()
        // The key's action, wired the way the controller wires it.
        let keys = holder(fake) { shelf.removeSelected() }
        shelf.select(shelf.items[0], modifiers: [])
        shelf.select(shelf.items[2], modifiers: .command)
        keys.update(wanted: !shelf.selection.isEmpty)
        XCTAssertTrue(keys.isRegistered)

        fake.live.first?.action()

        XCTAssertEqual(shelf.items.count, 1)
        XCTAssertTrue(shelf.selection.isEmpty)
        for file in fixture.files {
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "\(file.lastPathComponent) is still on disk")
            XCTAssertEqual(try Data(contentsOf: file), Data("x".utf8))
        }
        // And with the selection gone, the claim is gone: the controller's sink
        // would hand the keys back in this same turn.
        keys.update(wanted: !shelf.selection.isEmpty)
        XCTAssertFalse(keys.isRegistered)
    }

    func testEveryRemovalPathLeavesTheFilesAlone() throws {
        let fixture = try Fixture(names: ["a.txt", "b.txt", "c.txt", "d.txt"])
        defer { fixture.release() }
        let shelf = fixture.shelf
        shelf.remove(shelf.items[0])
        shelf.select(shelf.items[0], modifiers: [])
        shelf.removeSelected()
        shelf.clear()
        XCTAssertTrue(shelf.items.isEmpty)
        for file in fixture.files {
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "\(file.lastPathComponent)")
        }
    }

    /// A Delete pressed with nothing selected removes nothing — the case the
    /// claim never lets reach here, held as the last line of defence.
    func testRemoveSelectedWithNoSelectionDoesNothing() throws {
        let fixture = try Fixture(names: ["a.txt", "b.txt"])
        defer { fixture.release() }
        fixture.shelf.removeSelected()
        XCTAssertEqual(fixture.shelf.items.count, 2)
    }
}
