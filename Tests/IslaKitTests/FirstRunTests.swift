import SwiftUI
import XCTest
@testable import IslaKit

/// The app is `.accessory`: no Dock icon, no menu-bar item, no window. Nothing
/// about launching it is visible, and the two hotkeys appear in no string in
/// the product. The first run has to say so once, and exactly once.
@MainActor
final class FirstRunTests: XCTestCase {

    /// Every test that touches the flag goes through this: it is a real user
    /// default, and a test that left it set would switch the welcome off on the
    /// machine the suite ran on.
    private func withCleanFirstRun(_ body: () -> Void) {
        let defaults = UserDefaults.standard
        let had = defaults.object(forKey: NotchViewModel.hasCompletedFirstRunKey)
        defer {
            if let had { defaults.set(had, forKey: NotchViewModel.hasCompletedFirstRunKey) }
            else { defaults.removeObject(forKey: NotchViewModel.hasCompletedFirstRunKey) }
        }
        defaults.removeObject(forKey: NotchViewModel.hasCompletedFirstRunKey)
        body()
    }

    func testAFreshInstallHasNotCompletedItsFirstRun() {
        withCleanFirstRun {
            XCTAssertFalse(NotchViewModel.hasCompletedFirstRun)
        }
    }

    func testCompletingItIsRememberedAndNeverRepeats() {
        withCleanFirstRun {
            NotchViewModel.completeFirstRun()
            XCTAssertTrue(NotchViewModel.hasCompletedFirstRun)
            NotchViewModel.completeFirstRun()
            XCTAssertTrue(NotchViewModel.hasCompletedFirstRun)
        }
    }

    /// Dismissing the welcome leaves the panel on Music, not on whatever the
    /// welcome replaced — the island is for glancing at a track.
    func testDismissingTheWelcomeLandsOnMusic() {
        withCleanFirstRun {
            guard let vm = Self.viewModel() else {
                return XCTFail("a test host always has a screen")
            }
            vm.isShowingWelcome = true

            vm.dismissWelcome()

            XCTAssertFalse(vm.isShowingWelcome)
            XCTAssertTrue(NotchViewModel.hasCompletedFirstRun)
            XCTAssertEqual(vm.tab, .media)
        }
    }

    /// Picking a tab out of the rail is an answer to the welcome too — it says
    /// *not this, that* — so it may not leave the rail highlighted on a tab the
    /// body is not showing.
    func testChoosingATabFromTheRailAnswersTheWelcome() {
        withCleanFirstRun {
            guard let vm = Self.viewModel() else {
                return XCTFail("a test host always has a screen")
            }
            vm.isShowingWelcome = true

            vm.chooseTab(.clipboard)

            XCTAssertFalse(vm.isShowingWelcome)
            XCTAssertTrue(NotchViewModel.hasCompletedFirstRun)
            XCTAssertEqual(vm.tab, .clipboard, "the tab asked for, not Music")
        }
    }

    /// The pointer arriving on the panel must not count as an answer.
    ///
    /// `pointerArrived()` selects Music — it is how the panel is handed back to
    /// the pointer — and the pointer arrives by definition on the way to the Get
    /// Started button. Hanging the dismissal off `select` would therefore have
    /// wiped the welcome out from under the cursor reaching for it, before it
    /// had been read.
    func testThePointerCrossingThePanelDoesNotAnswerTheWelcome() {
        withCleanFirstRun {
            guard let vm = Self.viewModel() else {
                return XCTFail("a test host always has a screen")
            }
            vm.isShowingWelcome = true

            _ = vm.pointerCrossed(inside: true)

            XCTAssertTrue(vm.isShowingWelcome, "reaching for the button dismissed it")
            XCTAssertFalse(NotchViewModel.hasCompletedFirstRun)
        }
    }

    /// A file dropped on the island while the welcome is up must land where the
    /// user can see it.
    ///
    /// The welcome is drawn over the pane switch, so with it still showing the
    /// drop had no highlight, no card and no counter — and the `setOpen(true)`
    /// the controller follows a drag with early-returns on the panel the welcome
    /// had already opened, so nothing on screen moved and the file appeared to
    /// have gone nowhere.
    ///
    /// The flag stays unset on purpose: a drop is a real interaction, but it is
    /// not the user answering the welcome, and somebody who has only ever dropped
    /// a file on the island has not been told where Quit is.
    func testAFileDroppedOnTheWelcomeShowsTheShelf() {
        withCleanFirstRun {
            guard let vm = Self.viewModel() else {
                return XCTFail("a test host always has a screen")
            }
            vm.isShowingWelcome = true

            vm.showShelfForDrag()

            XCTAssertFalse(vm.isShowingWelcome, "the drop landed behind the welcome")
            XCTAssertEqual(vm.tab, .shelf)
            XCTAssertFalse(
                NotchViewModel.hasCompletedFirstRun,
                "a drop is not an answer to the welcome — the next launch still owes it"
            )
        }
    }

    /// And the same for the drop itself, not only the drag crossing the island:
    /// `accept(urls:)` is the other place that used to set the tab straight.
    func testAcceptingFilesTakesTheWelcomeDown() {
        withCleanFirstRun {
            guard let vm = Self.viewModel() else {
                return XCTFail("a test host always has a screen")
            }
            vm.isShowingWelcome = true

            XCTAssertTrue(vm.accept(urls: []))

            XCTAssertFalse(vm.isShowingWelcome)
            XCTAssertEqual(vm.tab, .shelf)
            XCTAssertFalse(NotchViewModel.hasCompletedFirstRun)
        }
    }

    /// A drop lands on a shelf the drag already brought up, and `add` loads the
    /// new cards' previews itself — so the drop must not pass over the whole
    /// shelf again: a reachability check and a fresh QuickLook request per card,
    /// each preview landing as a whole-panel redraw. The welcome, if the drop
    /// beat it down, still goes.
    func testADropOnTheShelfDoesNotRefreshItAgain() {
        withCleanFirstRun {
            guard let vm = Self.viewModel() else {
                return XCTFail("a test host always has a screen")
            }
            vm.showShelfForDrag()
            vm.isShowingWelcome = true
            let refreshes = vm.shelf.refreshesForTests

            XCTAssertTrue(vm.accept(urls: []))

            XCTAssertEqual(vm.shelf.refreshesForTests, refreshes, "the drag already refreshed the shelf")
            XCTAssertEqual(vm.tab, .shelf)
            XCTAssertFalse(vm.isShowingWelcome)
        }
    }

    /// The same for a screenshot arriving while the shelf is on screen: its
    /// card is already there, and re-showing the shelf redid every other one.
    func testAScreenshotArrivingOnTheShelfDoesNotRefreshIt() {
        withCleanFirstRun {
            guard let vm = Self.viewModel() else {
                return XCTFail("a test host always has a screen")
            }
            vm.isOpen = true
            vm.tab = .shelf
            let refreshes = vm.shelf.refreshesForTests

            vm.receivedScreenshot(at: URL(fileURLWithPath: "/tmp/Screenshot.png"))

            XCTAssertEqual(vm.shelf.refreshesForTests, refreshes)
            XCTAssertEqual(vm.tab, .shelf)
        }
    }

    /// And for a drag crossing back onto a shelf already on screen — every
    /// exit and re-entry is another `draggingEntered`, and so is every later
    /// drag. Only the shelf coming into view is refreshed: a panel left closed
    /// on the shelf that the drag is about to open, or one under the welcome.
    func testADragReenteringAnOpenShelfDoesNotRefreshIt() {
        withCleanFirstRun {
            guard let vm = Self.viewModel() else {
                return XCTFail("a test host always has a screen")
            }
            vm.isOpen = true
            vm.tab = .shelf
            let refreshes = vm.shelf.refreshesForTests

            vm.showShelfForDrag()
            XCTAssertEqual(vm.shelf.refreshesForTests, refreshes, "the shelf was already on screen")

            vm.isOpen = false
            vm.showShelfForDrag()
            XCTAssertEqual(vm.shelf.refreshesForTests, refreshes + 1, "a closed panel opens onto the shelf")

            vm.isOpen = true
            vm.isShowingWelcome = true
            vm.showShelfForDrag()
            XCTAssertEqual(vm.shelf.refreshesForTests, refreshes + 2, "the welcome was covering it")
            XCTAssertFalse(vm.isShowingWelcome)
        }
    }

    /// Every string the welcome shows must exist in both tables, and the Russian
    /// one must actually be Russian.
    ///
    /// Reads the tables off disk rather than through `NSLocalizedString`:
    /// under `swift test` there is no bundle carrying the `.lproj` folders, so
    /// a lookup would fall back to the key and any assertion on it would pass
    /// for a string nobody ever translated.
    ///
    /// Presence alone was not enough: because the keys *are* the English text,
    /// `ru.lproj` could carry all six keys with all six English values and both
    /// this test and `Scripts/test-localizations.sh` — which compares key sets —
    /// would pass on a pane that shows English to a Russian user. So each Russian
    /// value has to differ from its own key.
    func testEveryWelcomeStringIsInBothTables() throws {
        XCTAssertFalse(WelcomePane.localizedKeys.isEmpty)

        for language in ["en", "ru"] {
            let table = try Self.table(language)
            for key in WelcomePane.localizedKeys {
                XCTAssertTrue(
                    table.contains("\"\(key)\" = "),
                    "\(language).lproj is missing the welcome key \(key)"
                )
                guard language == "ru" else { continue }
                XCTAssertNotEqual(
                    Self.value(for: key, in: table), key,
                    "ru.lproj leaves the welcome key \(key) untranslated"
                )
            }
        }
    }

    func testEveryLocalLyricsStringHasEnglishAndRussianTranslations() throws {
        let keys = [
            "Local Lyrics Library", "Add Lyrics Folder…", "No local lyrics.",
            "This LRC file is invalid.", "Export LRC", "Lyrics stay on this Mac.",
        ]
        for language in ["en", "ru"] {
            let table = try Self.table(language)
            for key in keys {
                XCTAssertTrue(table.contains("\"\(key)\" = "), "\(language) is missing \(key)")
                if language == "ru" {
                    XCTAssertNotEqual(Self.value(for: key, in: table), key, "\(key) is untranslated")
                }
            }
        }
    }

    func testWordKaraokeHasEnglishAndRussianTranslations() throws {
        for language in ["en", "ru"] {
            let table = try Self.table(language)
            XCTAssertTrue(table.contains("\"Word Karaoke\" = "), "\(language) is missing Word Karaoke")
        }
        XCTAssertNotEqual(Self.value(for: "Word Karaoke", in: try Self.table("ru")), "Word Karaoke")
    }

    /// The two keycaps have to be the same size, or the two labels beside them
    /// start at different x and a two-row list visibly fails to line up.
    ///
    /// The system font is proportional and these glyphs are not digits, so they
    /// measure four points apart on their own. `WelcomePane.keycapGlyphWidth` is
    /// the `minWidth` that equalises them, and it only does so while it is at
    /// least as wide as the wider of the two — which is what this measures, so
    /// that a font metrics change fails here instead of quietly ragging the
    /// column again.
    func testTheTwoKeycapsAreTheSameWidth() {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        for keys in HotKeyAction.allCases.map(\.defaultBinding.displayString) {
            let natural = (keys as NSString).size(withAttributes: [.font: font]).width
            XCTAssertLessThanOrEqual(
                natural, WelcomePane.keycapGlyphWidth,
                "\(keys) needs \(natural) pt and the keycap only guarantees "
                    + "\(WelcomePane.keycapGlyphWidth)"
            )
        }
    }

    /// The body is 208 pt and never resizes, so a pane that does not fit is a
    /// pane with its button cut off — and the panel has no scroll bar to reveal
    /// it. Russian runs roughly a third longer than English, which is where a
    /// layout laid out in English overflows.
    ///
    /// Measured, not eyeballed: the pane is rendered at the width a pane
    /// actually gets, with its height unconstrained, and the height it asks for
    /// is compared against the height it is given. The Russian pass reads the
    /// shipped `ru.lproj` table off disk, because `Text` cannot look it up here
    /// — see `testEveryWelcomeStringIsInBothTables`.
    func testTheWelcomeFitsTheBodyInBothLanguages() throws {
        // The shallowest body any supported Mac can hand the pane, tightened
        // further by the machine actually running this if it has a screen at
        // all. The constant is the one that matters and the local geometry is
        // only ever a second, stricter opinion: the body is a fixed 208 pt
        // whatever the notch takes out of it, and display scaling makes the same
        // physical notch 38 pt on one setting and 32 on another (#27), so a
        // build machine with a shallow notch is the most forgiving case rather
        // than a representative one.
        //
        // This used to `XCTSkip` without a screen, which meant the only guard
        // against shipping a pane with its button cut off skipped itself on
        // every headless CI machine — and it needed the screen only to build a
        // `NotchViewModel` for the pane to talk to. `WelcomePane` takes an
        // `onDismiss` closure now, so it renders with no model, no geometry and
        // no display.
        var available = NotchMetrics.standardBodyHeight
            - Self.deepestNotch
            - NotchGeometry.bodyBottomPadding
        if let geometry = NotchGeometry.current() {
            available = min(available, geometry.standardContentHeight)
        }

        for language in ["en", "ru"] {
            let table = try Self.table(language)
            let copy = WelcomePane.Copy(
                running: Self.value(for: WelcomePane.Copy.english.running, in: table),
                whereItLives: Self.value(for: WelcomePane.Copy.english.whereItLives, in: table),
                openPanel: Self.value(for: WelcomePane.Copy.english.openPanel, in: table),
                showLyrics: Self.value(
                    for: WelcomePane.Copy.english.showLyrics, in: table
                ),
                settingsFootnote: Self.value(
                    for: WelcomePane.Copy.english.settingsFootnote, in: table
                ),
                action: Self.value(for: WelcomePane.Copy.english.action, in: table)
            )
            if language == "ru" {
                // Or the parse below quietly handed back the keys and this whole
                // pass measured English a second time.
                XCTAssertNotEqual(
                    copy.settingsFootnote, WelcomePane.Copy.english.settingsFootnote,
                    "the Russian pass must measure Russian"
                )
            }
            let asked = try Self.naturalHeight(
                of: WelcomePane(onDismiss: {}, copy: copy),
                width: Self.paneWidth
            )
            XCTAssertLessThanOrEqual(
                asked, available,
                "the welcome asks for \(asked) pt in \(language) and the body has \(available)"
            )
        }
    }

    // MARK: - Harness

    /// What the pane itself is given: the body, less the content padding either
    /// side, less the rail and the gap beside it.
    ///
    /// Taken at the *narrowest* body a user can choose in Settings, not the
    /// default 560: a narrower pane is what makes a line wrap, and a line that
    /// wraps is what makes the pane taller than the body.
    private static var paneWidth: CGFloat {
        NotchMetrics.minimumBodyWidth - 2 * 14 - 30 - 14
    }

    /// Deeper than any notch measured so far — 38 pt is the deepest a supported
    /// Mac has reported (#27) — so that the assertion has a little room in it
    /// rather than sitting exactly on the worst case observed.
    private static let deepestNotch: CGFloat = 40

    private static func viewModel() -> NotchViewModel? {
        guard let geometry = NotchGeometry.current() else { return nil }
        return NotchViewModel(geometry: geometry, stores: NotchStores())
    }

    private static func table(_ language: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // IslaKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
        return try String(
            contentsOf: root.appendingPathComponent("Resources/\(language).lproj/Localizable.strings"),
            encoding: .utf8
        )
    }

    /// The translation for a key, taken from the table's own text. Deliberately
    /// strict: a key the table does not carry is the failure
    /// `testEveryWelcomeStringIsInBothTables` names, and silently measuring
    /// English in its place would hide it here.
    private static func value(for key: String, in table: String) -> String {
        guard let line = table
            .split(separator: "\n")
            .first(where: { $0.hasPrefix("\"\(key)\" = ") })
        else { return key }
        guard let opening = line.range(of: " = \""),
              let closing = line.range(of: "\";", options: .backwards)
        else { return key }
        return String(line[opening.upperBound..<closing.lowerBound])
    }

    /// The height a view asks for at a fixed width — its ideal height, which is
    /// exactly what overflows a body that cannot grow.
    private static func naturalHeight<V: View>(of view: V, width: CGFloat) throws -> CGFloat {
        let renderer = ImageRenderer(
            content: view
                .frame(width: width)
                .fixedSize(horizontal: false, vertical: true)
        )
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.nsImage, "the pane must render")
        return image.size.height
    }
}
