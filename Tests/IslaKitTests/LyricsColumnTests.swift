import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// The lyric column and the tall page's states and menu (spec §5.2, §5.4): which
/// state wins, what each says and offers, and what the More menu holds — as pure
/// functions first, then through the accessibility tree of the real stage.
@MainActor
final class LyricsColumnTests: XCTestCase {
    private let timeline = LyricTimeline(
        lines: [.init(at: 1, text: "First line"), .init(at: 4, text: "Second line"), .init(at: 8, text: "Third line")],
        granularity: .line
    )

    private func state(
        _ availability: LyricsAvailability, lines: [LyricsStore.Line]? = nil,
        lookup: LocalLyricsLookup? = nil, online: Bool = false, invalidLine: Int? = nil
    ) -> LyricsPageState {
        LyricsPageState.state(
            availability: availability,
            lyricsState: lines.map { .synced($0) } ?? .none,
            localLookup: lookup, onlineEnabled: online, invalidLine: invalidLine
        )
    }

    // MARK: - Which state shows

    func testTheStatesTheColumnCanBeIn() {
        XCTAssertEqual(state(.ready(timeline), lines: timeline.lines), .lines)
        XCTAssertEqual(state(.ready(timeline)), .looking, "words on their way to the store are a wait, not a blank")
        XCTAssertEqual(state(.findingLocalLyrics), .looking)
        XCTAssertEqual(state(.resolving), .resolving, "a fast answer must never flash a spinner")
        XCTAssertEqual(state(.disabled), .off)
        XCTAssertEqual(state(.noLocalLyrics), .noneFound(offersSearchOnline: true))
        XCTAssertEqual(state(.noLocalLyrics, online: true), .noneFound(offersSearchOnline: false),
                       "Search Online only while the online lookup is off")
        XCTAssertEqual(state(.invalidLocalFile(.malformed), invalidLine: 12), .unreadable(line: 12))
        XCTAssertEqual(state(.invalidLocalFile(.unreadable)), .unreadable(line: nil))
        XCTAssertEqual(state(.cannotLookUp(.noLength)), .cannotLookUp("No lyrics for live audio."))
        XCTAssertEqual(state(.cannotLookUp(.noTitle)), .cannotLookUp("This track has no title to look up."))
    }

    func testSeveralLocalFilesAreTheirOwnChoiceNotAMiss() {
        let candidate = LocalLyricsCandidate(
            id: UUID(),
            document: LocalLyricsDocument(metadata: .init(), lines: timeline.lines, offset: 0),
            origin: .imported
        )
        XCTAssertEqual(state(.noLocalLyrics, lookup: .ambiguous([candidate, candidate])), .chooseLocal)
        XCTAssertTrue(LyricsPageState.chooseLocal.replacesLines)
        XCTAssertFalse(LyricsPageState.lines.replacesLines)
    }

    /// The parser's line when it names one; the existing sentence when it does not.
    func testTheUnreadableFileNamesTheLineWhenItCan() {
        XCTAssertEqual(LyricsPageState.unreadableSentence(line: 12), "Line 12 of this file has a time Isla can't read.")
        XCTAssertEqual(LyricsPageState.unreadableSentence(line: nil), "Can't read the lyrics file for this song.")
        XCTAssertEqual(LyricsPageState.noneFoundSentence, "No lyrics found for this song.")
    }

    /// The library's line is the parser's: a bound file with a broken stamp on
    /// its second line says "2", and a readable file, or no binding, says nothing.
    func testTheLibraryNamesTheBrokenLineOfABoundFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("isla-invalid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = LocalLyricsLibrary(directory: directory)
        let identity = LocalTrackIdentity(
            playerID: "music", title: "Up Here", artist: "Mira Sol", album: "Up Here", duration: 96, recordingID: nil
        )
        XCTAssertNil(library.invalidLine(for: identity), "nothing is bound")

        let good = try library.importDocument("[00:01.00]one\n[00:02.00]two\n", binding: identity)
        XCTAssertNil(library.invalidLine(for: identity), "a readable file has no broken line")
        XCTAssertNil(library.fileName(of: good.id), "an Isla-owned copy has no name of the person's choosing")

        // The same file broken on disk after it was bound — saved half-edited from
        // a text editor — is what the unreadable state is for.
        let stored = directory.appendingPathComponent("lyrics-local/imports/\(good.id.uuidString).lrc")
        try "[00:01.00]one\n[00:7x.00]two\n".write(to: stored, atomically: true, encoding: .utf8)
        XCTAssertEqual(library.invalidLine(for: identity), 2)
        try "no timed lyrics here".write(to: stored, atomically: true, encoding: .utf8)
        XCTAssertNil(library.invalidLine(for: identity), "a refusal that is not about a time names no line")
    }

    // MARK: - The More menu's items (spec §5.2)

    private func kinds(_ items: [LyricsMoreMenuItem]) -> [LyricsMoreMenuItem.Kind] { items.map(\.kind) }

    func testTheMenuWithNoFileAndOnlineOff() {
        let items = LyricsMoreMenuModel.items(localFileName: nil, onlineOn: false, offset: 0)
        XCTAssertEqual(
            kinds(items),
            [.header, .earlier, .later, .offset, .reset, .separator, .importFile, .separator, .settings]
        )
        XCTAssertEqual(
            items.map(\.title).filter { !$0.isEmpty },
            ["Lyric Timing", "Lyrics Earlier", "Lyrics Later", "+0.00s", "Reset Lyric Timing",
             "Import LRC File…", "Lyrics Settings…"]
        )
        XCTAssertFalse(items.contains { $0.kind == .searchAgain }, "Search Again only when the online lookup is on")
        XCTAssertFalse(items.contains { $0.kind == .edit || $0.kind == .removeBinding }, "no file, no file group")
    }

    func testTheMenuWithALocalFileBound() {
        let items = LyricsMoreMenuModel.items(localFileName: "Up Here.lrc", onlineOn: true, offset: 0.25)
        XCTAssertEqual(
            kinds(items),
            [.header, .earlier, .later, .offset, .reset, .separator,
             .header, .edit, .removeBinding, .separator,
             .importFile, .searchAgain, .separator, .settings]
        )
        XCTAssertEqual(items[6].title, "Up Here.lrc", "the file's own name heads its group")
        XCTAssertEqual(items[7].title, "Edit Lyrics…")
        XCTAssertEqual(items[8].title, "Remove Local Binding")
        XCTAssertEqual(items[11].title, "Search Again")
    }

    /// A file matched by its tags, never bound by a choice, can be edited but has
    /// no binding to remove.
    func testAFileThatIsOnlyMatchedCannotBeUnbound() {
        let items = LyricsMoreMenuModel.items(localFileName: "Up Here.lrc", hasBinding: false, onlineOn: false, offset: 0)
        XCTAssertTrue(items.contains { $0.kind == .edit })
        XCTAssertFalse(items.contains { $0.kind == .removeBinding })
    }

    func testTheOffsetIsAReadoutAndResetNeedsOneToClear() {
        let none = LyricsMoreMenuModel.items(localFileName: nil, onlineOn: false, offset: 0)
        let some = LyricsMoreMenuModel.items(localFileName: nil, onlineOn: false, offset: -0.5)
        XCTAssertEqual(some.first { $0.kind == .offset }?.title, "-0.50s")
        XCTAssertEqual(some.first { $0.kind == .offset }?.isEnabled, false, "the correction is a line, never pressed")
        XCTAssertEqual(none.first { $0.kind == .reset }?.isEnabled, false, "nothing to reset")
        XCTAssertEqual(some.first { $0.kind == .reset }?.isEnabled, true)
    }

    func testWithoutSyncedWordsThereIsNothingToNudge() {
        let items = LyricsMoreMenuModel.items(localFileName: nil, onlineOn: false, offset: 0, canNudge: false)
        XCTAssertEqual(items.first { $0.kind == .earlier }?.isEnabled, false)
        XCTAssertEqual(items.first { $0.kind == .later }?.isEnabled, false)
        XCTAssertEqual(items.first { $0.kind == .importFile }?.isEnabled, true, "import never depends on the words")
    }

    func testAnIslaOwnedCopyIsNamedByItsTitle() {
        let candidate = LocalLyricsCandidate(
            id: UUID(),
            document: LocalLyricsDocument(metadata: .init(title: "Up Here"), lines: timeline.lines, offset: 0),
            origin: .imported
        )
        XCTAssertEqual(LyricsMoreMenuModel.fileName(stored: "Up Here.lrc", candidate: candidate, trackTitle: nil), "Up Here.lrc")
        XCTAssertEqual(LyricsMoreMenuModel.fileName(stored: nil, candidate: candidate, trackTitle: "Other"), "Up Here.lrc")
        let untitled = LocalLyricsCandidate(
            id: UUID(), document: LocalLyricsDocument(metadata: .init(), lines: timeline.lines, offset: 0), origin: .imported
        )
        XCTAssertEqual(LyricsMoreMenuModel.fileName(stored: nil, candidate: untitled, trackTitle: "From The Player"), "From The Player.lrc")
    }

    // MARK: - The menu as AppKit gets it

    private func controller(
        file: String? = nil, online: Bool = false, offset: TimeInterval = 0, record: @escaping (String) -> Void = { _ in }
    ) -> LyricsMoreMenuController {
        LyricsMoreMenuController(
            context: { .init(localFileName: file, hasBinding: true, onlineOn: online, offset: offset, canNudge: true) },
            actions: .init(
                nudge: { record("nudge \($0)") }, resetTiming: { record("reset") }, editLyrics: { record("edit") },
                removeBinding: { record("unbind") }, importFile: { record("import") },
                searchAgain: { record("search") }, openSettings: { record("settings") }
            )
        )
    }

    func testTheNSMenuHoldsTheModelsRowsInOrder() {
        let menu = controller(file: "Up Here.lrc", online: true, offset: 0.25).makeMenu()
        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        XCTAssertEqual(
            titles,
            ["Lyric Timing", "Lyrics Earlier", "Lyrics Later", "+0.25s", "Reset Lyric Timing",
             "Up Here.lrc", "Edit Lyrics…", "Remove Local Binding", "Import LRC File…", "Search Again",
             "Lyrics Settings…"]
        )
        XCTAssertEqual(menu.items.filter(\.isSeparatorItem).count, 3)
        // The two headers are headers and the readout cannot be chosen.
        XCTAssertTrue(menu.items.first { $0.title == "Lyric Timing" }?.isSectionHeader ?? false)
        XCTAssertTrue(menu.items.first { $0.title == "Up Here.lrc" }?.isSectionHeader ?? false)
        XCTAssertEqual(menu.items.first { $0.title == "+0.25s" }?.isEnabled, false)
        XCTAssertNotNil(menu.items.first { $0.title == "Lyrics Earlier" }?.image, "− beside Lyrics Earlier")
        XCTAssertNotNil(menu.items.first { $0.title == "Lyrics Later" }?.image, "+ beside Lyrics Later")
    }

    func testEveryRowDoesWhatItSays() {
        var log: [String] = []
        let controller = controller { log.append($0) }
        for kind: LyricsMoreMenuItem.Kind in [.earlier, .later, .reset, .edit, .removeBinding, .importFile, .searchAgain, .settings] {
            controller.perform(kind)
        }
        XCTAssertEqual(log, ["nudge -0.25", "nudge 0.25", "reset", "edit", "unbind", "import", "search", "settings"])
        for kind: LyricsMoreMenuItem.Kind in [.header, .offset, .separator] { controller.perform(kind) }
        XCTAssertEqual(log.count, 8, "a header, the readout and a separator do nothing")
    }

    /// "Lyrics Settings…" opens Settings on the Lyrics section (redesign
    /// 2026-10-15, spec §10: R4 gave the lyric switches a section of their own,
    /// where R1 could only point at Music's top), and Settings is 400 tall.
    func testLyricsSettingsOpensSettingsAtTheLyricSwitches() throws {
        let suiteName = "com.ctimothe.isla.lyricscolumn.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: NotchStores(), defaults: suite)
        vm.select(.media)
        vm.lyricsMoreMenu.perform(.settings)
        XCTAssertEqual(vm.tab, .settings)
        XCTAssertEqual(vm.settingsSection, .lyrics)
        XCTAssertEqual(vm.openBodySize.height, 400, "Settings is always tall (R4)")
    }

    /// The menus' controllers can outlive the model when the panel is rebuilt
    /// for a display change; a late action must do nothing, not crash
    /// (review 2026-10-15: `unowned` self).
    func testAMenuControllerOutlivingItsModelDoesNothing() throws {
        var controllers: (LyricsMoreMenuController, LyricsTranslateMenuController)?
        weak var weakModel: NotchViewModel?
        autoreleasepool {
            let vm = try! NotchViewModel(geometry: LabGeometry.make(), stores: NotchStores())
            weakModel = vm
            controllers = (vm.lyricsMoreMenu, vm.lyricsTranslateMenu)
        }
        let (more, translate) = try XCTUnwrap(controllers)
        XCTAssertNil(weakModel, "the controllers do not keep the model alive")
        for kind: LyricsMoreMenuItem.Kind in [.earlier, .later, .reset, .edit, .removeBinding, .importFile, .searchAgain, .settings] {
            more.perform(kind)
        }
        _ = more.makeMenu()
        translate.perform(.showTranslation)
        _ = translate.makeMenu()
    }

    // MARK: - The stage's geometry

    func testTheStageHoldsTheSungLineWhereTheBoardPutsIt() throws {
        for (state, centreInArea) in [
            (PlayerLayout.State.column, 104.5 - 38),
            (.tall, 176.5 - Double(PlayerLayout.tallAreaTop)),
        ] {
            let f = PlayerLayout.frames(for: state, bodyWidth: 560)
            let area = try XCTUnwrap(f.lyricArea)
            let sung = try XCTUnwrap(f.sungLine)
            XCTAssertEqual(sung.midY - area.minY, centreInArea, accuracy: 0.001)
            let centre = LyricsStage.holdingCentre(centre: sung.midY - area.minY, viewport: area.height)
            XCTAssertEqual(centre, sung.midY - area.minY, "a centre inside the viewport is held where the board has it")

            // The row's centre lands on it: anchor·H − anchor·slot + slot/2.
            let slot = try XCTUnwrap(f.lyricPitch)
            let unit = LyricsStage.anchorUnit(centre: centre, viewport: area.height, slot: slot)
            XCTAssertEqual(unit * area.height - unit * slot + slot / 2, centre, accuracy: 0.001)
            XCTAssertGreaterThan(unit, 0)
            XCTAssertLessThan(unit, 1)
        }
        XCTAssertEqual(LyricsStage.holdingCentre(centre: nil, viewport: 200), 100, "no board, the middle")
        XCTAssertEqual(LyricsStage.holdingCentre(centre: -20, viewport: 200), 70, "a centre pushed off by a notice is held in")
        XCTAssertEqual(LyricsStage.anchorUnit(centre: 100, viewport: 200, slot: 34), 0.5, "the middle is the plain centre")
    }

    func testEitherEndOfTheSongCanReachTheReadingCentre() {
        let air = LyricsStage.air(viewport: 156, slot: 23, centre: 66.5)
        XCTAssertEqual(air.top, 66.5 - 11.5, accuracy: 0.001, "the first row can sit at the centre")
        XCTAssertEqual(air.bottom, 156 - 66.5 - 11.5, accuracy: 0.001, "and so can the last")
        XCTAssertEqual(LyricsStage.air(viewport: 10, slot: 23, centre: 5).top, 0, "never negative")
        // The middle of the viewport is the page's old arithmetic.
        XCTAssertEqual(LyricsStage.air(viewport: 128, slot: LyricsStage.slotHeight, centre: 64).top, LyricsStage.centeringAir(viewport: 128))
    }

    func testTheModesSetTheBoardsTypeAndPitch() {
        XCTAssertEqual(LyricsStage.Mode.column.metrics.pitch, 23)
        XCTAssertEqual(LyricsStage.Mode.column.metrics.fontSize, 13)
        XCTAssertEqual(LyricsStage.Mode.column.metrics.weight, .bold, "the sung line bold")
        XCTAssertEqual(LyricsStage.Mode.column.metrics.contextWeight, .semibold, "the column's others semibold")
        XCTAssertEqual(LyricsStage.Mode.tall.metrics.pitch, 34)
        XCTAssertEqual(LyricsStage.Mode.tall.metrics.fontSize, 17)
        XCTAssertEqual(LyricsStage.Mode.tall.metrics.contextWeight, .bold, "the tall page's all bold")
        XCTAssertEqual(LyricsStage.Mode.tall.metrics.fontSize, Theme.TypeRole.lyric.size)
        XCTAssertEqual(LyricsStage.Mode.column.metrics.fontSize, Theme.TypeRole.subhead.size)
    }

    // MARK: - The stage in the accessibility tree

    private static let size = CGSize(width: 278, height: 156)

    private func stage(
        lyrics: LyricsStore, media: MediaController, mode: LyricsStage.Mode = .column, online: Bool = false,
        lookup: LocalLyricsLookup? = nil, invalidLine: Int? = nil, notice: String? = nil,
        record: @escaping (String) -> Void = { _ in }
    ) -> LyricsStage {
        LyricsStage(
            media: media, lyrics: lyrics, localLookup: lookup,
            turnOnLyrics: { record("turn on lyrics") },
            turnOnOnlineLyrics: { record("search online") }, importLocalFile: { record("import") },
            notice: notice, editBlankLyrics: { record("edit") }, invalidLine: invalidLine,
            mode: mode, onlineEnabled: { online }, readingCentre: mode == .column ? 66.5 : 90.5
        )
    }

    private func rig() -> (ProbeStores, LyricsStore) {
        let isolated = ProbeFixtures.isolatedStores()
        let store = LyricsStore(
            offsetsDirectory: isolated.temp.appendingPathComponent("column-offsets", isDirectory: true),
            defaults: isolated.suite
        )
        return (isolated, store)
    }

    func testNoneFoundOffersImportAndSearchOnlineWhileOnlineIsOff() async throws {
        let (isolated, store) = rig()
        defer { isolated.release() }
        store.present(.noLocalLyrics)
        var log: [String] = []
        let root = await AXProbe.tree(
            of: stage(lyrics: store, media: isolated.stores.media) { log.append($0) }.defaultAppStorage(isolated.suite),
            size: Self.size
        )
        XCTAssertNotNil(
            root.all { [$0.label, $0.title, $0.value].contains("No lyrics found for this song.") }.first, root.dump
        )
        let importButton = try XCTUnwrap(root.first(label: "Import LRC…"), root.dump)
        let search = try XCTUnwrap(root.first(label: "Search Online"), root.dump)
        XCTAssertTrue(importButton.press())
        XCTAssertTrue(search.press())
        XCTAssertEqual(log, ["import", "search online"], "Search Online turns the lookup on")
    }

    func testNoneFoundOffersNoSearchOnlineWhenOnlineIsOn() async throws {
        let (isolated, store) = rig()
        defer { isolated.release() }
        store.present(.noLocalLyrics)
        let root = await AXProbe.tree(
            of: stage(lyrics: store, media: isolated.stores.media, online: true).defaultAppStorage(isolated.suite),
            size: Self.size
        )
        XCTAssertNotNil(root.first(label: "Import LRC…"), root.dump)
        XCTAssertNil(root.first(label: "Search Online"), "it is on already: nothing to turn on\n\(root.dump)")
    }

    func testTheUnreadableFileNamesItsLineAndOffersTheEditorAndImport() async throws {
        let (isolated, store) = rig()
        defer { isolated.release() }
        store.present(.invalidLocalFile(.malformed))
        var log: [String] = []
        let root = await AXProbe.tree(
            of: stage(lyrics: store, media: isolated.stores.media, invalidLine: 12) { log.append($0) }
                .defaultAppStorage(isolated.suite),
            size: Self.size
        )
        XCTAssertNotNil(
            root.all { [$0.label, $0.title, $0.value].contains("Line 12 of this file has a time Isla can't read.") }.first,
            root.dump
        )
        XCTAssertTrue(try XCTUnwrap(root.first(label: "Edit Lyrics…"), root.dump).press())
        XCTAssertTrue(try XCTUnwrap(root.first(label: "Import LRC…"), root.dump).press())
        XCTAssertEqual(log, ["edit", "import"])
    }

    func testLookingSaysSoAndLyricsOffOffersTheSwitch() async throws {
        let (isolated, store) = rig()
        defer { isolated.release() }
        store.present(.findingLocalLyrics)
        let looking = await AXProbe.tree(
            of: stage(lyrics: store, media: isolated.stores.media).defaultAppStorage(isolated.suite), size: Self.size
        )
        XCTAssertNotNil(
            looking.all { [$0.label, $0.title, $0.value].contains("Looking for lyrics…") }.first, looking.dump
        )

        store.present(.disabled)
        var log: [String] = []
        let off = await AXProbe.tree(
            of: stage(lyrics: store, media: isolated.stores.media) { log.append($0) }.defaultAppStorage(isolated.suite),
            size: Self.size
        )
        XCTAssertNotNil(off.all { [$0.label, $0.title, $0.value].contains("Lyrics are off.") }.first, off.dump)
        XCTAssertTrue(try XCTUnwrap(off.first(label: "Show Lyrics"), off.dump).press())
        XCTAssertEqual(log, ["turn on lyrics"])
    }

    /// Every behaviour the page had survives the move into the column: a line is
    /// a button that offers Sync Here, and a standing notice speaks above them.
    func testTheColumnKeepsItsRowsAndItsNotice() async throws {
        let (isolated, store) = rig()
        defer { isolated.release() }
        await LabFixtures.play(LabFixtures.Track(elapsed: 27), on: isolated.stores.media)
        store.present(LabFixtures.timeline())
        let root = await AXProbe.tree(
            of: stage(lyrics: store, media: isolated.stores.media, notice: "Couldn't read this file as text.")
                .defaultAppStorage(isolated.suite),
            size: CGSize(width: 278, height: 156)
        )
        XCTAssertFalse(root.all { $0.customActions.contains("Sync Here") }.isEmpty, "rows offer Sync Here\n\(root.dump)")
        XCTAssertNotNil(
            root.all { [$0.label, $0.title, $0.value].contains("Couldn't read this file as text.") }.first,
            "the notice is in the tree\n\(root.dump)"
        )
    }

    /// The real scroll view puts the sung row's centre where the table says, in
    /// both modes — the anchor arithmetic held against what SwiftUI lays out.
    func testTheSungRowLandsOnTheReadingCentre() async throws {
        for (mode, size, centre, pitch) in [
            (LyricsStage.Mode.column, CGSize(width: 278, height: 156), CGFloat(66.5), CGFloat(23)),
            (.tall, CGSize(width: 488, height: 252), CGFloat(90.5), CGFloat(34)),
        ] {
            let (isolated, store) = rig()
            defer { isolated.release() }
            await LabFixtures.play(LabFixtures.Track(elapsed: 27), on: isolated.stores.media)
            store.present(LabFixtures.timeline())
            var root = await AXProbe.tree(
                of: stage(lyrics: store, media: isolated.stores.media, mode: mode).defaultAppStorage(isolated.suite),
                size: size
            )
            root = await root.reread(settle: 0.5)
            let sung = try XCTUnwrap(root.all { $0.selected && $0.role == "AXButton" }.first, "\(mode)\n\(root.dump)")
            let frame = try XCTUnwrap(sung.frame)
            XCTAssertLessThanOrEqual(frame.height, pitch, "a line fits its slot in \(mode)")
            XCTAssertEqual(frame.midY, centre, accuracy: 2.5, "the sung row at the reading centre in \(mode): \(frame)")
        }
    }

    // MARK: - Instrumental dots (spec §5.4)

    func testTheInstrumentalDotsAreThreeSevenPointDotsAtTheBoardsStrengths() {
        XCTAssertEqual(Theme.instrumentalDotOpacities, [0.9, 0.55, 0.3])
        XCTAssertEqual(Theme.instrumentalDotSize, 7)
        XCTAssertEqual(InterludeMarker.accessibilityLabel, "Instrumental", "named, as a rest is")
    }

    func testTheSyncPillIsASolidCapsuleSeventyFourByTwentyFour() {
        XCTAssertEqual(Theme.syncPillSize, CGSize(width: 74, height: 24))
    }

    func testTheNoticeIsFortyTallWithARadiusOfNine() {
        XCTAssertEqual(Theme.mismatchNoticeHeight, 40)
        XCTAssertEqual(Theme.mismatchNoticeRadius, 9)
    }

    // MARK: - The editor (spec §5.5)

    func testTheEditorIsFourHundredTwentyByThreeFiftyTwo() {
        XCTAssertEqual(LocalLyricsEditorView.size, CGSize(width: 420, height: 352))
    }

    func testABlankSessionSeedsTheSongsTagsAndOneEmptyRow() {
        let identity = LocalTrackIdentity(
            playerID: "music", title: "Up Here", artist: "Mira Sol", album: "Single", duration: 96, recordingID: nil
        )
        let session = LocalLyricsEditor.EditingSession.blank(identity: identity)
        XCTAssertEqual(session.title, "Up Here")
        XCTAssertEqual(session.candidate.document.metadata.artist, "Mira Sol")
        XCTAssertEqual(session.candidate.document.metadata.duration, 96)
        XCTAssertEqual(session.candidate.document.lines.count, 1)
        XCTAssertEqual(session.candidate.document.lines.first?.text, "")
        XCTAssertEqual(session.identity, identity, "Save Copy binds to the song Edit was pressed on")
    }
}
