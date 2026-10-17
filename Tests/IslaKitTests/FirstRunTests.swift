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

    /// Dismissing the welcome lands on what a click on the island would have
    /// opened (spec §19.1) — Tools on the bare notch — not on whatever surface
    /// was chosen underneath it.
    func testDismissingTheWelcomeLandsOnWhatAClickWouldOpen() {
        withCleanFirstRun {
            guard let vm = Self.viewModel() else {
                return XCTFail("a test host always has a screen")
            }
            vm.isShowingWelcome = true

            vm.dismissWelcome()

            XCTAssertFalse(vm.isShowingWelcome)
            XCTAssertTrue(NotchViewModel.hasCompletedFirstRun)
            XCTAssertEqual(vm.surface, vm.openTarget)
            XCTAssertEqual(vm.surface, .tools, "nothing is playing: the bare notch opens Tools")
        }
    }

    /// The same dismissal over a song lands on the player: what a click would
    /// open is decided by what the island shows, not by a default.
    func testDismissingTheWelcomeOverASongLandsOnThePlayer() {
        withCleanFirstRun {
            let isolated = ProbeFixtures.isolatedStores()
            defer { isolated.release() }
            guard let geometry = NotchGeometry.current() else {
                return XCTFail("a test host always has a screen")
            }
            let vm = NotchViewModel(geometry: geometry, stores: isolated.stores)
            var snapshot = NowPlayingFeed.Snapshot()
            snapshot.title = "Test Song"
            snapshot.artist = "Test Artist"
            snapshot.duration = 180
            snapshot.elapsed = 9.2
            snapshot.rate = 1
            snapshot.isPlaying = true
            snapshot.takenAt = Date()
            snapshot.playerPID = 999
            isolated.stores.media.apply(snapshot)
            vm.isShowingWelcome = true

            vm.dismissWelcome()

            XCTAssertEqual(vm.surface, .player)
        }
    }

    /// Choosing a surface — a Tools card, the menu — is an answer to the welcome
    /// too: it says *not this, that*, so the welcome may not stay over the
    /// surface asked for.
    func testChoosingASurfaceAnswersTheWelcome() {
        withCleanFirstRun {
            guard let vm = Self.viewModel() else {
                return XCTFail("a test host always has a screen")
            }
            vm.isShowingWelcome = true

            vm.choose(.clipboard)

            XCTAssertFalse(vm.isShowingWelcome)
            XCTAssertTrue(NotchViewModel.hasCompletedFirstRun)
            XCTAssertEqual(vm.surface, .clipboard, "the surface asked for, not the one a click opens")
        }
    }

    /// The pointer arriving on the panel must not count as an answer.
    ///
    /// `pointerArrived()` hands the panel back to the pointer, and the pointer
    /// arrives by definition on the way to the Get Started button. Hanging the
    /// dismissal off `open` would therefore have wiped the welcome out from
    /// under the cursor reaching for it, before it had been read.
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

    /// A file dragged to the island while the welcome is up must land where the
    /// user can see it.
    ///
    /// The drop surface is presented over whatever is chosen, the welcome
    /// included (spec §19.7), so the drag has its two targets, its highlight
    /// and its counter on screen instead of behind a pane the welcome had
    /// already put up — which made a drop during the first launch invisible:
    /// nothing moved and the file looked like it had gone nowhere. The welcome
    /// is not taken down for it, only covered, and it comes back when the drag
    /// ends.
    ///
    /// The flag stays unset on purpose: a drag is a real interaction, but it
    /// is not the user answering the welcome, and somebody who has only ever
    /// dropped a file on the island has not been told where Quit is.
    func testAFileDraggedOverTheWelcomeShowsTheDropSurface() {
        withCleanFirstRun {
            guard let vm = Self.viewModel() else {
                return XCTFail("a test host always has a screen")
            }
            vm.isShowingWelcome = true

            vm.isDropTargeted = true

            XCTAssertEqual(vm.presented, .drop, "the drag landed behind the welcome")
            XCTAssertTrue(vm.isShowingWelcome, "covered by the drop surface, not answered")
            XCTAssertFalse(
                NotchViewModel.hasCompletedFirstRun,
                "a drag is not an answer to the welcome — the next launch still owes it"
            )

            vm.isDropTargeted = false
            XCTAssertEqual(vm.presented, .welcome, "the welcome is still owed to the person")
        }
    }

    /// And for the drop itself: `accept(urls:)` keeps the files and moves
    /// nothing (spec §19.7) — a drop over the welcome is a file kept, not an
    /// answer to the welcome and not a request to look at the tray.
    func testAcceptingFilesKeepsThemAndAnswersNothing() {
        withCleanFirstRun {
            guard let vm = Self.viewModel() else {
                return XCTFail("a test host always has a screen")
            }
            vm.isShowingWelcome = true
            let chosen = vm.surface

            XCTAssertTrue(vm.accept(urls: []))

            XCTAssertEqual(vm.surface, chosen, "the surface underneath is not moved")
            XCTAssertTrue(vm.isShowingWelcome)
            XCTAssertFalse(NotchViewModel.hasCompletedFirstRun)
        }
    }

    /// A drop lands on a tray the drag never refreshed, and `add` loads the new
    /// cards' previews itself — so the drop must not pass over the whole shelf
    /// again: a reachability check and a fresh QuickLook request per card, each
    /// preview landing as a whole-panel redraw.
    func testADropOnTheTrayDoesNotRefreshItAgain() {
        withCleanFirstRun {
            guard let vm = Self.viewModel() else {
                return XCTFail("a test host always has a screen")
            }
            vm.isOpen = true
            vm.open(.tray)
            let refreshes = vm.shelf.refreshesForTests

            XCTAssertTrue(vm.accept(urls: []))

            XCTAssertEqual(vm.shelf.refreshesForTests, refreshes, "the tray was already refreshed on arrival")
            XCTAssertEqual(vm.surface, .tray)
        }
    }

    /// A screenshot is nobody asking for anything, so it must not move a
    /// person who is reading the clipboard to the tray (FOC-01; worst for
    /// VoiceOver, where the focus goes with the surface). The rail's dot for
    /// it went with the rail (§19.11); the island's collected moment says it
    /// once the panel is shut.
    func testAScreenshotOnAnOpenPanelDoesNotMoveTheUser() {
        withCleanFirstRun {
            guard let vm = Self.viewModel() else {
                return XCTFail("a test host always has a screen")
            }
            vm.isOpen = true
            vm.surface = .clipboard

            vm.receivedScreenshot(at: URL(fileURLWithPath: "/tmp/Screenshot.png"))

            XCTAssertEqual(vm.surface, .clipboard, "the surface is the user's")
            XCTAssertFalse(vm.isShowingCollected, "a surface is open: the island is not on screen")
        }
    }

    /// The same for a screenshot arriving while the tray is on screen: its
    /// card is already there, and re-showing the tray redid every other one.
    func testAScreenshotArrivingOnTheTrayDoesNotRefreshIt() {
        withCleanFirstRun {
            guard let vm = Self.viewModel() else {
                return XCTFail("a test host always has a screen")
            }
            vm.isOpen = true
            vm.surface = .tray
            let refreshes = vm.shelf.refreshesForTests

            vm.receivedScreenshot(at: URL(fileURLWithPath: "/tmp/Screenshot.png"))

            XCTAssertEqual(vm.shelf.refreshesForTests, refreshes)
            XCTAssertEqual(vm.surface, .tray)
        }
    }

    /// A drag crossing the island — every exit and re-entry is another
    /// `draggingEntered`, and so is every later drag — only presents the drop
    /// surface. It never passes over the shelf: the surface shows two targets,
    /// not the cards, so nothing needs refreshing, in a shut panel, an open
    /// tray or under the welcome.
    func testADragOverTheIslandNeverRefreshesTheShelf() {
        withCleanFirstRun {
            guard let vm = Self.viewModel() else {
                return XCTFail("a test host always has a screen")
            }
            vm.isOpen = true
            vm.surface = .tray
            let refreshes = vm.shelf.refreshesForTests

            vm.isDropTargeted = true
            vm.isDropTargeted = false
            XCTAssertEqual(vm.shelf.refreshesForTests, refreshes, "the tray was already on screen")

            vm.isOpen = false
            vm.isDropTargeted = true
            vm.isDropTargeted = false
            XCTAssertEqual(vm.shelf.refreshesForTests, refreshes, "a closed panel opens onto the drop surface")

            vm.isOpen = true
            vm.isShowingWelcome = true
            vm.isDropTargeted = true
            XCTAssertEqual(vm.shelf.refreshesForTests, refreshes, "the welcome is covered, nothing refreshed")
            XCTAssertEqual(vm.presented, .drop)
        }
    }

    /// J-018: the welcome prints the shortcuts, so the first thing a new user
    /// does with it is press one — and the hot keys worked invisibly behind
    /// it. ⌃⌥⌘T filled a field nobody could see, raised the keyboard for it
    /// and folded the panel; ⌃⌥⌘L put up a lyrics page that appeared only
    /// after Get Started. A shortcut is an answer the way a rail tab is.
    ///
    /// Isolated stores, so the view model reads no real support folder.
    func testAShortcutRetiresTheWelcome() {
        withCleanFirstRun {
            let isolated = ProbeFixtures.isolatedStores()
            defer { isolated.release() }
            guard let geometry = NotchGeometry.current() else {
                return XCTFail("a test host always has a screen")
            }
            let vm = NotchViewModel(geometry: geometry, stores: isolated.stores)
            vm.isShowingWelcome = true

            vm.receiveCommandedTranslation(Translator.prepareCommandInput("bonjour"))

            XCTAssertFalse(vm.isShowingWelcome, "the translation landed behind the welcome")
            XCTAssertTrue(NotchViewModel.hasCompletedFirstRun)
            XCTAssertEqual(vm.surface, .translate)
            XCTAssertTrue(vm.wantsKeyboard, "the field that appears takes the keyboard")
            XCTAssertEqual(vm.translator.input, "bonjour")
        }
    }

    /// An image on the clipboard opens Translate saying so, and leaves what
    /// was typed there alone rather than emptying it.
    func testAShortcutWithNoTextKeepsTheFieldAndSaysWhy() {
        withCleanFirstRun {
            let isolated = ProbeFixtures.isolatedStores()
            defer { isolated.release() }
            guard let geometry = NotchGeometry.current() else {
                return XCTFail("a test host always has a screen")
            }
            let vm = NotchViewModel(geometry: geometry, stores: isolated.stores)
            vm.translator.input = "typed earlier"

            vm.receiveCommandedTranslation(Translator.prepareCommandInput(nil))

            XCTAssertEqual(vm.surface, .translate)
            XCTAssertEqual(vm.translator.input, "typed earlier")
            XCTAssertEqual(vm.translator.notice, "The clipboard has no text.")
        }
    }
    /// H-020: none of the features was named on the one screen every user of
    /// an invisible app sees. The legend is four lines, each led by a glyph
    /// (spec §19.8): a click opens what is playing, a right-click everything
    /// else, files dragged to the notch are kept, and the live shortcuts.
    func testTheWelcomeLegendHasFourDistinctLinesAndPrintsTheLiveShortcuts() {
        let pane = WelcomePane(onDismiss: {}, openKeys: "⌃⌥⌘I", shortcuts: [
            .init(keys: "⌃⌥⌘T", name: "Translate"), .init(keys: "⌃⌥⌘L", name: "Lyrics"),
        ])
        let legend = pane.legend
        XCTAssertEqual(legend.count, 4)
        XCTAssertEqual(Set(legend.map(\.text)).count, legend.count, "two lines share their words: \(legend)")
        XCTAssertEqual(Set(legend.map(\.symbol)).count, legend.count, "two lines share a glyph: \(legend)")
        XCTAssertFalse(legend.contains(where: { $0.text.isEmpty || $0.symbol.isEmpty }), "\(legend)")
        XCTAssertEqual(pane.keysLine, "⌃⌥⌘T Translate · ⌃⌥⌘L Lyrics")
        XCTAssertEqual(legend.last?.text, pane.keysLine)
        XCTAssertTrue(pane.comeBackLine.contains("⌃⌥⌘I"), pane.comeBackLine)
        // "Click it to open", said on a panel that was already open, read as
        // done. The way back is what the line is for now.
        XCTAssertFalse(pane.comeBackLine.contains("Click it to open"))
    }

    /// A shortcut can be cleared in Settings, and a reset first run then shows
    /// the welcome without it. The line that names it must not print an empty
    /// gap where the keys were — "press  to come back" — and with every
    /// shortcut cleared the fourth line drops out instead of printing nothing.
    func testAClearedShortcutLeavesNoGapInTheWelcome() {
        let pane = WelcomePane(onDismiss: {}, openKeys: "", shortcuts: [])
        XCTAssertEqual(pane.legend.count, 3, "no shortcut, no fourth line")
        for line in pane.legend.map(\.text) + [pane.comeBackLine] {
            XCTAssertFalse(line.contains("%@"), line)
            XCTAssertFalse(line.contains("()"), line)
            XCTAssertFalse(line.contains("  "), line)
            XCTAssertFalse(line.hasPrefix(" "), line)
        }

        // `liveShortcuts` drops a cleared binding from the line rather than
        // leaving its name without keys.
        let live = WelcomePane.liveShortcuts(bindings: [:], copy: .english)
        XCTAssertEqual(live, [])
        XCTAssertEqual(
            WelcomePane.liveShortcuts(
                bindings: [.translateClipboard: HotKeyAction.translateClipboard.defaultBinding],
                copy: .english
            ).map(\.name),
            ["Translate"]
        )
    }

    /// H-020: the welcome is a surface of its own, and the island must say so.
    /// The view model keeps the surface a click would have opened underneath
    /// it, so Get Started lands there, and the open group drew its name off
    /// that — VoiceOver announced "Tools" over a pane that was the welcome.
    /// There is no rail to select anything in any more (§19.11).
    ///
    /// The second half is the control: the same probe on the same model, once
    /// the welcome is answered, does find the surface chosen — so the first
    /// half is not passing on a probe that cannot see the group at all.
    func testTheOpenGroupIsTheWelcomeWhileWelcoming() async throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: isolated.stores)
        vm.isOpen = true
        vm.isShowingWelcome = true
        let size = CGSize(width: VisualLab.windowSize.width, height: vm.geometry.windowSize.height)

        let welcoming = await AXProbe.tree(of: NotchContentView(vm: vm), size: size)
        XCTAssertNil(welcoming.first(label: "Tabs"), "the rail is gone\n\(welcoming.dump)")
        XCTAssertNil(welcoming.first(label: "Tools"), "the surface under the welcome is not announced\n\(welcoming.dump)")
        let welcome = try XCTUnwrap(welcoming.first(label: "Welcome"), welcoming.dump)

        // And it names its four lines, each readable as one element.
        for text in [
            WelcomePane.Copy.english.click, WelcomePane.Copy.english.rightClick, WelcomePane.Copy.english.drag,
        ] {
            XCTAssertFalse(
                welcome.all(where: { $0.label == text || $0.value == text || $0.title == text }).isEmpty,
                "\(text) is not on screen\n\(welcome.dump)"
            )
        }

        vm.isShowingWelcome = false
        let answered = await AXProbe.tree(of: NotchContentView(vm: vm), size: size)
        XCTAssertNil(answered.first(label: "Welcome"), answered.dump)
        XCTAssertNotNil(answered.first(label: vm.presented.title), answered.dump)
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
            // The 2026-10-11 rewrite (H-020) retired these two; a table that
            // still carries them is carrying copy nothing shows.
            for retired in [
                "It lives at the notch. Click it to open.",
                "Quit and everything else lives in Settings, at the bottom left.",
            ] {
                XCTAssertFalse(table.contains("\"\(retired)\" = "), "\(language).lproj still carries \(retired)")
            }
        }
    }

    func testEveryLocalLyricsStringHasEnglishAndRussianTranslations() throws {
        let keys = [
            "Local Lyrics Library", "Add Lyrics Folder…", "No lyrics on this Mac.",
            "This LRC file is invalid.", "Export LRC", "Lyrics stay on this Mac.",
            "No lyrics found for this song.", "Can't read the lyrics file for this song.",
            "No lyrics for live audio.", "This track has no title to look up.", "Lyrics are off.",
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
        // "Текст песен" is "the lyrics of songs", which does not agree with a
        // switch about the one song playing.
        XCTAssertEqual(Self.value(for: "Lyrics are off.", in: try Self.table("ru")), "Текст песни выключен.")
    }

    func testWordKaraokeHasEnglishAndRussianTranslations() throws {
        for language in ["en", "ru"] {
            let table = try Self.table(language)
            XCTAssertTrue(table.contains("\"Word Karaoke\" = "), "\(language) is missing Word Karaoke")
        }
        XCTAssertNotEqual(Self.value(for: "Word Karaoke", in: try Self.table("ru")), "Word Karaoke")
    }

    /// The legend takes a share of the width and wraps inside it; the message
    /// column gets the rest. At the narrowest body a user can choose, what is
    /// left must still be a column — or the title and the button are squeezed
    /// to a word a line and the height test below fails for a reason it cannot
    /// name. The share is fixed, so the old pane's 150 pt floor is held by
    /// arithmetic at every width the body can take, not by measuring the
    /// longest legend (§19.8: the legend wraps rather than pushing the message
    /// off the body).
    func testTheLegendLeavesTheMessageAColumnAtEveryBodyWidth() {
        let floor: CGFloat = 150
        for width in [NotchMetrics.minimumBodyWidth, 560, NotchMetrics.maximumBodyWidth] {
            let columns = WelcomePane.columns(bodyWidth: width)
            XCTAssertGreaterThanOrEqual(columns.message, floor, "body \(width)")
            XCTAssertEqual(
                columns.legend + WelcomePane.columnGap + columns.message,
                width - WelcomePane.margins.leading - WelcomePane.margins.trailing,
                accuracy: 0.001, "the two columns and their gap fill the pane at \(width)"
            )
        }
    }

    /// The body is 208 pt and never resizes, so a pane that does not fit is a
    /// pane with its button cut off — and the panel has no scroll bar to reveal
    /// it. Russian runs roughly a third longer than English, which is where a
    /// layout laid out in English overflows.
    ///
    /// Measured, not eyeballed: the pane is rendered at the narrowest body a
    /// user can choose, in a frame taller than it can need, and the lowest
    /// pixel it draws is compared against the height it is given less the
    /// foot's margin. (The pane lays itself out from a `GeometryReader`, which
    /// has no ideal height to ask for.) The Russian pass reads the shipped
    /// `ru.lproj` table off disk, because `Text` cannot look it up here — see
    /// `testEveryWelcomeStringIsInBothTables`.
    func testTheWelcomeFitsTheBodyInBothLanguages() throws {
        // The shallowest body any supported Mac can hand the pane, tightened
        // further by the machine actually running this if it has a screen at
        // all. The constant is the one that matters and the local geometry is
        // only ever a second, stricter opinion: the body is a fixed 208 pt
        // whatever the notch takes out of it, and display scaling makes the same
        // physical notch 38 pt on one setting and 32 on another (#27), so a
        // build machine with a shallow notch is the most forgiving case rather
        // than a representative one. The pane starts under the header row
        // (§19.8), so the notch's height is what comes off the top.
        var available = NotchMetrics.standardBodyHeight - Self.deepestNotch
        if let geometry = NotchGeometry.current() {
            available = min(available, NotchMetrics.standardBodyHeight - geometry.notchSize.height)
        }
        available -= WelcomePane.margins.bottom

        for language in ["en", "ru"] {
            let table = try Self.table(language)
            let copy = WelcomePane.Copy.english.mapped { Self.value(for: $0, in: table) }
            if language == "ru" {
                // Or the parse below quietly handed back the keys and this whole
                // pass measured English a second time.
                XCTAssertNotEqual(
                    copy.comeBack, WelcomePane.Copy.english.comeBack,
                    "the Russian pass must measure Russian"
                )
            }
            let drawn = try Self.drawnBottom(of: Self.pane(copy), width: NotchMetrics.minimumBodyWidth)
            XCTAssertLessThanOrEqual(
                drawn, available,
                "the welcome draws down to \(drawn) pt in \(language) and the body has \(available)"
            )
            XCTAssertGreaterThan(drawn, WelcomePane.margins.top + 40, "the probe must see the pane draw")
        }
    }

    // MARK: - Harness

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

    /// The row below the last pixel the view draws, rendered at `width` into a
    /// frame tall enough for any pane: where its content really ends.
    private static func drawnBottom<V: View>(of view: V, width: CGFloat) throws -> CGFloat {
        let tall: CGFloat = 400
        let renderer = ImageRenderer(content: view.frame(width: width, height: tall))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage, "the pane must render")
        let (w, h) = (image.width, image.height)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        XCTAssertTrue(drew, "a bitmap context to read the pane back")
        for row in stride(from: h - 1, through: 0, by: -1) {
            for column in 0..<w where pixels[(row * w + column) * 4 + 3] > 8 {
                return CGFloat(row + 1) / CGFloat(h) * tall
            }
        }
        return 0
    }

    /// The pane as a first run shows it: the default shortcuts, both bound.
    private static func pane(_ copy: WelcomePane.Copy) -> WelcomePane {
        WelcomePane(
            onDismiss: {}, copy: copy,
            openKeys: HotKeyAction.openPanel.defaultBinding.displayString,
            shortcuts: WelcomePane.liveShortcuts(
                bindings: [
                    .translateClipboard: HotKeyAction.translateClipboard.defaultBinding,
                    .showLyrics: HotKeyAction.showLyrics.defaultBinding,
                ],
                copy: copy
            )
        )
    }
}
