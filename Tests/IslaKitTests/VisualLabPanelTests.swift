import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// Shared plumbing for every lab case: a session that is always put back,
/// even when the case throws half way.
@MainActor
class VisualLabCase: XCTestCase {
    func makeSession(_ name: String = #function) throws -> LabSession {
        let session = try LabSession(caseName: "\(type(of: self)).\(name.replacingOccurrences(of: "()", with: ""))")
        addTeardownBlock { @MainActor in
            try? await session.finish()
        }
        return session
    }

    /// The window the panel lives in, cropped to the part a panel can reach:
    /// the 208 pt body and its shadow. The window itself is 444 pt tall for a
    /// tab that no longer exists, and below the panel it is only transparent.
    static let panelSize = CGSize(width: VisualLab.windowSize.width, height: 268)
    static let pillSize = CGSize(width: VisualLab.windowSize.width, height: 84)

    /// The island in its window over the stand-in desktop.
    static func scene(_ vm: NotchViewModel, _ variant: LabVariant, height: CGFloat) -> AnyView {
        let geometry = vm.geometry
        return AnyView(
            ZStack(alignment: .top) {
                LabDesktop(
                    light: variant.lightDesktop,
                    menuBarHeight: geometry.notchSize.height,
                    hardwareNotch: geometry.isPhysical ? geometry.notchSize : nil
                )
                NotchContentView(vm: vm)
            }
            .frame(width: VisualLab.windowSize.width, height: height, alignment: .top)
            .clipped()
        )
    }

    /// A panel, open, on a tab, with whatever the state needs set up first.
    func openPanel(
        _ session: LabSession, tab: NotchViewModel.Tab = .media, physical: Bool = true,
        track: LabFixtures.Track? = nil,
        lyrics: LyricsAvailability? = nil,
        prepare: (NotchStores) async throws -> Void = { _ in },
        configure: (NotchViewModel) -> Void = { _ in }
    ) async throws -> NotchViewModel {
        let stores = session.makeStores()
        labTrace("stores made")
        if let track { await LabFixtures.play(track, on: stores.media) }
        if let lyrics { stores.lyrics.present(lyrics) }
        try await prepare(stores)
        labTrace("geometry")
        let geometry = try LabGeometry.make(physical: physical)
        labTrace("vm")
        let vm = NotchViewModel(geometry: geometry, stores: stores)
        labTrace("vm made")
        vm.isOpen = true
        vm.tab = tab
        configure(vm)
        return vm
    }
}

/// V1, the open panel: every tab and the states each can be put in without a
/// real player, a real pasteboard or the network.
@MainActor
final class VisualLabPanelTests: VisualLabCase {

    // MARK: Music

    func testMusicPane() async throws {
        let session = try makeSession()
        let shoot = LabPhotographer(session: session, surface: "panel-music")
        let size = Self.panelSize

        try await shoot.shoot("nothing-playing", variants: LabVariant.panel, size: size,
                              notes: "The Open buttons list the players installed on the rendering Mac.") { variant in
            Self.scene(try await self.openPanel(session), variant, height: size.height)
        }
        // J-007: a browser video Music Only keeps off the island is playing.
        // The status names it and the one remedy is Open Settings; the
        // Russian sentence is the long one, so it is drawn at 480 pt too.
        try await shoot.shoot("nothing-shown-music-only-hides-a-video",
                              variants: [.base, .w480, .russian, LabVariant(name: "ru-w480", width: 480, language: "ru"), .baseIR],
                              size: size,
                              notes: "A YouTube tab in a browser is playing; Music Only filters it.") { variant in
            Self.scene(try await self.openPanel(session, prepare: { stores in
                stores.media.musicOnly = { true }
                stores.media.bundleIdentifierForPID = { _ in "com.google.Chrome" }
                var video = NowPlayingFeed.Snapshot()
                video.title = "A Video"
                video.duration = 600
                video.isPlaying = true
                video.rate = 1
                video.takenAt = Date()
                video.playerPID = 4242
                stores.media.receive(video)
            }), variant, height: size.height)
        }
        try await shoot.shoot("playing-lyrics-off", variants: LabVariant.panel, size: size) { variant in
            Self.scene(try await self.openPanel(session, track: .init(), lyrics: .disabled), variant, height: size.height)
        }
        try await shoot.shoot("playing-lyrics-caption", variants: LabVariant.panel, size: size) { variant in
            Self.scene(try await self.openPanel(session, track: .init(elapsed: 27), lyrics: LabFixtures.timeline()), variant, height: size.height)
        }
        try await shoot.shoot("playing-word-sweep-caption", variants: LabVariant.panel, size: size,
                              notes: "Word timing on: a word timeline, the karaoke switch and a measured position.") { variant in
            let vm = try await self.openPanel(
                session, track: .init(elapsed: 27.6),
                lyrics: LabFixtures.timeline(LabFixtures.wordLines, granularity: .word)
            )
            LabFixtures.enablePrecision(on: vm.media, lyrics: vm.lyrics)
            return Self.scene(vm, variant, height: size.height)
        }
        try await shoot.shoot("playing-finding-lyrics", variants: [.base, .russian], size: size) { variant in
            Self.scene(try await self.openPanel(session, track: .init(), lyrics: .findingLocalLyrics), variant, height: size.height)
        }
        try await shoot.shoot("playing-no-local-lyrics", variants: [.base, .russian], size: size) { variant in
            Self.scene(try await self.openPanel(session, track: .init(), lyrics: .noLocalLyrics), variant, height: size.height)
        }
        try await shoot.shoot("paused", variants: LabVariant.panel, size: size) { variant in
            let track = LabFixtures.Track(elapsed: 131)
            let vm = try await self.openPanel(session, track: track, lyrics: LabFixtures.timeline())
            LabFixtures.pause(track, on: vm.media)
            return Self.scene(vm, variant, height: size.height)
        }
        try await shoot.shoot("long-title", variants: LabVariant.panel, size: size) { variant in
            Self.scene(try await self.openPanel(session, track: LabFixtures.longTitle, lyrics: .disabled), variant, height: size.height)
        }
        try await shoot.shoot("cjk-title", variants: LabVariant.panel, size: size) { variant in
            Self.scene(try await self.openPanel(session, track: LabFixtures.cjkTitle, lyrics: LabFixtures.timeline(LabFixtures.cjkLines)),
                       variant, height: size.height)
        }
        try await shoot.shoot("no-artwork-waiting", variants: [.base, .baseIR], size: size,
                              notes: "The first 2.5 s of a track with no cover: the skeleton shimmer.") { variant in
            Self.scene(try await self.openPanel(session, track: .init(cover: nil), lyrics: .disabled), variant, height: size.height)
        }
        try await shoot.shoot("no-artwork-placeholder", variants: LabVariant.panel.filter { $0.backend == .host }, size: size, settle: 2.8,
                              notes: "After the 2.5 s wait the cover is declared absent and the quiet placeholder replaces the shimmer.") { variant in
            Self.scene(try await self.openPanel(session, track: .init(cover: nil), lyrics: .disabled), variant, height: size.height)
        }
        try await shoot.shoot("live-stream-no-duration", variants: [.base, .russian], size: size,
                              notes: "A stream with no length: no scrubber, and the caption says live audio has no lyrics rather than that lyrics are off.") { variant in
            Self.scene(try await self.openPanel(session, track: .init(duration: 0, elapsed: 0, source: "Radio"),
                                                lyrics: .cannotLookUp(.noLength)),
                       variant, height: size.height)
        }
        try await shoot.shoot("podcast-over-an-hour", variants: [.base, .w480], size: size,
                              notes: "Durations past an hour widen both time labels to 52 pt.") { variant in
            Self.scene(try await self.openPanel(
                session,
                track: .init(title: "Episode 214: The Long Interview", artist: "Field Notes", album: "Field Notes",
                             duration: 7_265, elapsed: 4_012, source: "Podcasts"),
                lyrics: .disabled
            ), variant, height: size.height)
        }
    }

    // MARK: Lyrics stage

    /// The lyrics stage over a track: the open panel on Music, with the stage
    /// raised, and word timing switched on when the state needs it.
    private func stage(_ session: LabSession, _ blurredCover: Data, _ track: LabFixtures.Track,
                       _ lyrics: LyricsAvailability, precision: Bool = false,
                       variant: LabVariant) async throws -> AnyView {
        var track = track
        if variant.backend == .host, track.cover != nil { track.cover = blurredCover }
        let vm = try await openPanel(session, track: track, lyrics: lyrics)
        if precision { LabFixtures.enablePrecision(on: vm.media, lyrics: vm.lyrics) }
        vm.isShowingLyrics = true
        return Self.scene(vm, variant, height: Self.panelSize.height)
    }

    func testLyricsStage() async throws {
        let session = try makeSession()
        let shoot = LabPhotographer(session: session, surface: "panel-lyrics-stage")
        let size = Self.panelSize
        let note = "Hosting render: the stage's 60 pt ambience blur is drawn from a pre-blurred cover, since cacheDisplay cannot draw SwiftUI blur."
        let blurredCover = LabFixtures.preblurred(LabFixtures.cover())

        try await shoot.shoot("before-first-line", variants: LabVariant.panel, size: size, settle: 0.3, notes: note) { variant in
            try await self.stage(session, blurredCover, .init(elapsed: 1), LabFixtures.timeline(), variant: variant)
        }
        try await shoot.shoot("line-synced", variants: LabVariant.panel, size: size, settle: 0.3, notes: note) { variant in
            try await self.stage(session, blurredCover, .init(elapsed: 27), LabFixtures.timeline(), variant: variant)
        }
        try await shoot.shoot("mid-line-sweep", variants: LabVariant.panel, size: size, settle: 0.3,
                              notes: note + " Word-granularity timeline without word stamps: the sweep runs linearly across the line.") { variant in
            try await self.stage(session, blurredCover, .init(elapsed: 28), LabFixtures.timeline(granularity: .word), precision: true, variant: variant)
        }
        try await shoot.shoot("word-karaoke", variants: LabVariant.panel, size: size, settle: 0.3, notes: note) { variant in
            try await self.stage(session, blurredCover, .init(elapsed: 27.4), LabFixtures.timeline(LabFixtures.wordLines, granularity: .word),
                            precision: true, variant: variant)
        }
        // Parsed from LRC, so the break is the end the parser gives the line
        // before it, as in a real file — and the stage draws the interlude
        // marker half way through its fill, not a blank row.
        let gapLines = try LabFixtures.gapLines()
        try await shoot.shoot("instrumental-gap", variants: [.base, .contrast, .russian], size: size, settle: 0.3,
                              notes: note + " An empty LRC stamp ends the line before the break; the interlude marker fills toward the voice, 14 s away.") { variant in
            try await self.stage(session, blurredCover, .init(elapsed: 26), LabFixtures.timeline(gapLines), variant: variant)
        }
        try await shoot.shoot("long-lines-wrapping", variants: [.base, .w480, .w620], size: size, settle: 0.3, notes: note) { variant in
            try await self.stage(session, blurredCover, .init(elapsed: 16), LabFixtures.timeline(LabFixtures.longLines), variant: variant)
        }
        try await shoot.shoot("cjk-lines", variants: [.base, .w480], size: size, settle: 0.3, notes: note) { variant in
            try await self.stage(session, blurredCover, LabFixtures.cjkTitle, LabFixtures.timeline(LabFixtures.cjkLines), variant: variant)
        }
        try await shoot.shoot("no-lyrics-offline", variants: LabVariant.panel, size: size, notes: note) { variant in
            try await self.stage(session, blurredCover, .init(), .noLocalLyrics, variant: variant)
        }
        try await shoot.shoot("no-lyrics-online-on", variants: [.base, .russian], size: size,
                              defaults: [NotchViewModel.onlineLyricsKey: true], notes: note) { variant in
            try await self.stage(session, blurredCover, .init(), .noLocalLyrics, variant: variant)
        }
        try await shoot.shoot("loading", variants: [.base, .russian], size: size, notes: note) { variant in
            try await self.stage(session, blurredCover, .init(), .findingLocalLyrics, variant: variant)
        }
        try await shoot.shoot("resolving-blank", variants: [.base], size: size,
                              notes: note + " Deliberately empty while a quick answer is still possible.") { variant in
            try await self.stage(session, blurredCover, .init(), .resolving, variant: variant)
        }
        try await shoot.shoot("lyrics-off", variants: LabVariant.panel, size: size, notes: note) { variant in
            try await self.stage(session, blurredCover, .init(), .disabled, variant: variant)
        }
        try await shoot.shoot("invalid-local-file", variants: [.base, .russian], size: size, notes: note) { variant in
            try await self.stage(session, blurredCover, .init(), .invalidLocalFile(.malformed), variant: variant)
        }
        // G-007: an Import from the page refused at line 2. The notice sits
        // under the header, and has to fit the narrowest panel in Russian.
        let russianNarrow = LabVariant(name: "ru-w480", width: 480, language: "ru")
        try await shoot.shoot("import-notice", variants: [.base, .w480, .russian, russianNarrow], size: size, settle: 0.3,
                              notes: note + " The notice an Import from the page leaves when the file has a broken stamp.") { variant in
            var track = LabFixtures.Track(elapsed: 27)
            if variant.backend == .host, track.cover != nil { track.cover = blurredCover }
            let broken = session.temp.appendingPathComponent("broken.lrc")
            try Data("[00:01.00]a\n[00:7x.00]b".utf8).write(to: broken, options: .atomic)
            let vm = try await self.openPanel(session, track: track, lyrics: LabFixtures.timeline())
            vm.importLocalLyricsFile(at: broken, for: nil, from: .stage)
            vm.isShowingLyrics = true
            return Self.scene(vm, variant, height: size.height)
        }
        try await shoot.shoot("no-artwork", variants: [.base], size: size, settle: 0.3) { variant in
            try await self.stage(session, blurredCover, .init(cover: nil), LabFixtures.timeline(), variant: variant)
        }
    }

    // MARK: Shelf

    /// Files on disk for the shelf to hold, in the lab's own folder.
    private func shelfFiles(_ session: LabSession, count: Int) throws -> [URL] {
        let folder = session.temp.appendingPathComponent("shelf", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let named = [
            "Screenshot 2026-10-11 at 09.12.44.png", "Quarterly Report.pdf", "Meeting notes.txt",
            "Isla icon draft.png", "Invoice 0042.pdf", "todo.md",
        ]
        let pdf: Data = {
            let data = NSMutableData()
            var box = CGRect(x: 0, y: 0, width: 300, height: 400)
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                  let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.systemTeal.cgColor)
            context.fill(CGRect(x: 30, y: 300, width: 240, height: 60))
            context.setFillColor(NSColor.darkGray.cgColor)
            for row in 0..<8 { context.fill(CGRect(x: 30, y: 260 - row * 22, width: 220 - (row % 3) * 40, height: 8)) }
            context.endPDFPage()
            context.closePDF()
            return data as Data
        }()
        return try (0..<count).map { index in
            let base = named[index % named.count]
            let name = index < named.count ? base
                : (base as NSString).deletingPathExtension + " \(index / named.count + 1)." + (base as NSString).pathExtension
            let url = folder.appendingPathComponent(name)
            switch url.pathExtension {
            case "png": try LabFixtures.cover(side: 240).write(to: url)
            case "pdf": try pdf.write(to: url)
            default: try Data("Lab fixture \(index)\n".utf8).write(to: url)
            }
            return url
        }
    }

    /// Stores the cards the way the shelf persists them and loads them back.
    private func stock(_ shelf: ShelfStore, session: LabSession, urls: [URL]) {
        let now = Date().timeIntervalSince1970
        // Ages that read the same on every run: the shelf prints them
        // relative to now.
        let ages: [Double] = [30, 5 * 60, 3 * 3600, 26 * 3600, 4 * 86400, 12 * 86400]
        session.suite.set(urls.map(\.path), forKey: "shelf.urls")
        session.suite.set(urls.indices.map { now - ages[$0 % ages.count] - Double($0) }, forKey: "shelf.urls.dates")
        shelf.load()
    }

    func testShelf() async throws {
        let session = try makeSession()
        let shoot = LabPhotographer(session: session, surface: "panel-shelf")
        let size = Self.panelSize
        let note = "Card previews come from QuickLook for the lab's own fixture files."
        let few = try shelfFiles(session, count: 4)
        let full = try shelfFiles(session, count: 60)

        try await shoot.shoot("empty", variants: LabVariant.panel, size: size) { variant in
            Self.scene(try await self.openPanel(session, tab: .shelf), variant, height: size.height)
        }
        // M-22: under a drag the headline says what letting go does.
        // Russian at 480 pt is the longest it gets and the narrowest it is
        // drawn, here and on the populated strip's pill below.
        let russianNarrowDrag = LabVariant(name: "ru-w480", width: 480, language: "ru")
        try await shoot.shoot("drop-target", variants: [.base, .contrast, russianNarrowDrag], size: size,
                              notes: "A drag over the island: the dashed well lights and the headline says Release.") { variant in
            Self.scene(try await self.openPanel(session, tab: .shelf, configure: { $0.isDropTargeted = true }), variant, height: size.height)
        }
        // M-22: a drag over a strip of cards had no target to see, since the
        // well is the empty state's.
        try await shoot.shoot("drag-over-populated", variants: [.base, .contrast, .motion, .russian, russianNarrowDrag],
                              size: size, settle: 0.8,
                              notes: note + " A drag over a shelf that has cards: a pill over the strip says where the file goes.") { variant in
            Self.scene(try await self.openPanel(session, tab: .shelf, prepare: { self.stock($0.shelf, session: session, urls: few) },
                                                configure: { $0.isDropTargeted = true }), variant, height: size.height)
        }
        for (state, variant, expected, absent) in [
            ("drop-target", "dark", "Release to add to the Shelf", "Drop files here to keep them"),
            ("drop-target", "ru-w480", "Отпустите, чтобы положить на полку", "Download Multiple"),
            ("drag-over-populated", "dark", "Drop to keep on the Shelf", "Download Multiple"),
            ("drag-over-populated", "ru-w480", "Отпустите, чтобы оставить на полке", "Download Multiple"),
        ] {
            let url = session.root.appendingPathComponent("a11y/panel-shelf/\(state)__\(variant).txt")
            let tree = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(tree.contains(expected), "\(state) \(variant) does not say \(expected)\n\(tree)")
            XCTAssertFalse(tree.contains(absent), "\(state) \(variant) still says \(absent)\n\(tree)")
        }
        try await shoot.shoot("a-few-cards", variants: LabVariant.panel, size: size, settle: 0.8, notes: note) { variant in
            Self.scene(try await self.openPanel(session, tab: .shelf, prepare: { self.stock($0.shelf, session: session, urls: few) }),
                       variant, height: size.height)
        }
        // F-037: with cards picked, the footer is the action bar. Russian at
        // 480 pt is the narrowest it is ever drawn, and the reason the verbs
        // are glyphs with their words in help rather than words.
        let russianNarrow = LabVariant(name: "ru-w480", width: 480, language: "ru")
        try await shoot.shoot("two-selected", variants: [.base, .contrast, .russian, russianNarrow], size: size, settle: 0.8,
                              notes: note + " Two cards picked: the footer is the action bar.") { variant in
            Self.scene(try await self.openPanel(session, tab: .shelf, prepare: { stores in
                self.stock(stores.shelf, session: session, urls: few)
            }, configure: { vm in
                vm.shelf.select(vm.shelf.items[0], modifiers: [])
                vm.shelf.select(vm.shelf.items[2], modifiers: .command)
            }), variant, height: size.height)
        }
        for (variant, labels) in [
            ("dark", ["Quick Look", "AirDrop", "Copy", "Show in Finder", "Remove 2", "Deselect"]),
            ("ru-w480", ["Быстрый просмотр", "AirDrop", "Копировать", "Показать в Finder", "Убрать 2", "Снять выбор"]),
        ] {
            let url = session.root.appendingPathComponent("a11y/panel-shelf/two-selected__\(variant).txt")
            let tree = try String(contentsOf: url, encoding: .utf8)
            let buttons = tree.split(separator: "\n").filter { $0.contains("[AXButton") }
            for label in labels {
                XCTAssertTrue(buttons.contains { $0.contains("label=\"\(label)\"") },
                              "two-selected \(variant) has no \(label) button\n\(tree)")
            }
        }
        try await shoot.shoot("at-the-60-cap", variants: [.base, .w480, .w620], size: size, settle: 1.5,
                              notes: note + " Sixty cards, the shelf's limit; the row scrolls sideways.") { variant in
            Self.scene(try await self.openPanel(session, tab: .shelf, prepare: { self.stock($0.shelf, session: session, urls: full) }),
                       variant, height: size.height)
        }
        try await shoot.shoot("at-the-60-cap-after-a-drop", variants: [.base, .w480, .russian], size: size, settle: 1.5,
                              notes: note + " One more file dropped on a full shelf: the oldest card leaves and the footer says so.") { variant in
            Self.scene(try await self.openPanel(session, tab: .shelf, prepare: { stores in
                self.stock(stores.shelf, session: session, urls: full)
                // A real file, or opening the shelf finds it gone and drops
                // the card again: the counter would read 59.
                let dropped = session.temp.appendingPathComponent("shelf/Dropped just now.png")
                try LabFixtures.cover(side: 240).write(to: dropped)
                stores.shelf.noticeLifetime = .seconds(600)
                stores.shelf.add([dropped])
            }), variant, height: size.height)
        }
        try await shoot.shoot("missing-file-pruned", variants: [.base], size: size, settle: 0.8,
                              notes: "Four cards stored, one file deleted first: the shelf has no missing-file card — opening it drops the card.") { variant in
            let missing = session.temp.appendingPathComponent("shelf/Deleted meanwhile.png")
            return Self.scene(try await self.openPanel(session, tab: .shelf, prepare: { stores in
                self.stock(stores.shelf, session: session, urls: Array(few.prefix(3)) + [missing])
            }), variant, height: size.height)
        }
        try await shoot.shoot("clear-armed", variants: [.base, .russian], size: size, settle: 0.8,
                              notes: "Clear pressed once (through its accessibility action): armed, asking again.",
                              interact: { LabAccessibility.press(localized("Clear"), in: $0) }) { variant in
            Self.scene(try await self.openPanel(session, tab: .shelf, prepare: { self.stock($0.shelf, session: session, urls: few) }),
                       variant, height: size.height)
        }
    }

    // MARK: Clipboard

    private func fill(_ session: LabSession, _ clipboard: ClipboardStore) {
        session.record([
            .file(session.temp.appendingPathComponent("Budget 2026.numbers")),
            .text("https://developer.apple.com/design/human-interface-guidelines/"),
            .text("Meet at the north entrance, 18:30 — bring the cable."),
            .text("Привет! Как дела?"),
            .text("let answer = try await translator.translate()"),
            .text(Self.longNote),
        ], into: clipboard)
    }

    /// The newest entry `fill` records, so the top row.
    private static let longNote = String(repeating: "A long note that runs on and on past the edge of the row. ", count: 4)

    /// What the top row is called. Rows are named by their preview now, not
    /// all "Copy Entry", so a press has to name the row it means.
    private static var topRowName: String { ClipItem(payload: .text(longNote), date: .distantPast).preview }

    func testClipboard() async throws {
        let session = try makeSession()
        let shoot = LabPhotographer(session: session, surface: "panel-clipboard")
        let size = Self.panelSize

        try await shoot.shoot("empty", variants: LabVariant.panel, size: size) { variant in
            Self.scene(try await self.openPanel(session, tab: .clipboard), variant, height: size.height)
        }
        try await shoot.shoot("empty-history-off", variants: [.base, .russian, .w480], size: size,
                              defaults: [NotchViewModel.clipboardHistoryKey: false]) { variant in
            Self.scene(try await self.openPanel(session, tab: .clipboard), variant, height: size.height)
        }
        try await shoot.shoot("populated", variants: LabVariant.panel, size: size) { variant in
            Self.scene(try await self.openPanel(session, tab: .clipboard, prepare: { self.fill(session, $0.clipboard) }),
                       variant, height: size.height)
        }
        try await shoot.shoot("privacy-covered", variants: LabVariant.panel, size: size,
                              notes: "The dots drift on a clock, so their pattern differs per render.") { variant in
            Self.scene(try await self.openPanel(session, tab: .clipboard, prepare: { stores in
                self.fill(session, stores.clipboard)
                stores.privacy.setCovering(.clipboard, true)
            }), variant, height: size.height)
        }
        try await shoot.shoot("one-row-revealed", variants: [.base, .contrast, .russian], size: size,
                              notes: "Privacy on and the second row revealed by its eye: the state a reveal leaves.") { variant in
            Self.scene(try await self.openPanel(session, tab: .clipboard, prepare: { stores in
                self.fill(session, stores.clipboard)
                stores.privacy.setCovering(.clipboard, true)
                stores.privacy.toggle(stores.clipboard.items[1].id.uuidString)
            }), variant, height: size.height)
        }
        try await shoot.shoot("row-just-copied", variants: [.base], size: size,
                              notes: "A row's copy action, pressed through accessibility: the checkmark and the word Copied it shows for 1.1 s. Copies onto the lab's private pasteboard.",
                              interact: { LabAccessibility.press(Self.topRowName, in: $0) }) { variant in
            Self.scene(try await self.openPanel(session, tab: .clipboard, prepare: { self.fill(session, $0.clipboard) }),
                       variant, height: size.height)
        }
        try await shoot.shoot("clear-armed", variants: [.base, .russian], size: size,
                              interact: { LabAccessibility.press(localized("Clear"), in: $0) }) { variant in
            Self.scene(try await self.openPanel(session, tab: .clipboard, prepare: { self.fill(session, $0.clipboard) }),
                       variant, height: size.height)
        }
        // Paste from Other Apps set to Don't Allow (J-001): the store's own
        // seam plays the refusal, so the lab's private pasteboard is never
        // asked. Russian at 480 points is the long button in the narrow panel.
        func denied(_ clipboard: ClipboardStore) {
            clipboard.accessBehavior = { .denied }
            clipboard.recheckAccess()
        }
        try await shoot.shoot("access-denied", variants: [.base, .light, .contrast, .w480, .russian], size: size,
                              notes: "Paste from Other Apps set to Don't Allow, with history kept from before the refusal.") { variant in
            Self.scene(try await self.openPanel(session, tab: .clipboard, prepare: { stores in
                self.fill(session, stores.clipboard)
                denied(stores.clipboard)
            }), variant, height: size.height)
        }
        try await shoot.shoot("access-denied-empty", variants: [.base, .russian], size: size,
                              notes: "Paste from Other Apps set to Don't Allow, nothing kept.") { variant in
            Self.scene(try await self.openPanel(session, tab: .clipboard, prepare: { denied($0.clipboard) }),
                       variant, height: size.height)
        }
        for (variant, sentence) in [
            ("dark", "macOS is not letting Isla read what you copy, so nothing new is kept."),
            ("ru", "macOS не разрешает Isla читать скопированное, поэтому новое не сохраняется."),
        ] {
            for state in ["access-denied", "access-denied-empty"] {
                let url = session.root.appendingPathComponent("a11y/panel-clipboard/\(state)__\(variant).txt")
                let tree = try String(contentsOf: url, encoding: .utf8)
                XCTAssertTrue(tree.contains(sentence), "\(state) \(variant) does not say it\n\(tree)")
            }
        }
    }

    // MARK: Translate

    func testTranslate() async throws {
        let session = try makeSession()
        let shoot = LabPhotographer(session: session, surface: "panel-translate")
        let size = Self.panelSize
        let sentence = "Where is the nearest train station?"

        try await shoot.shoot("empty", variants: LabVariant.panel, size: size) { variant in
            Self.scene(try await self.openPanel(session, tab: .translate), variant, height: size.height)
        }
        try await shoot.shoot("result", variants: LabVariant.panel, size: size, settle: 0.12,
                              notes: "The answer is handed in as an engine would hand it in; no engine runs.") { variant in
            Self.scene(try await self.openPanel(session, tab: .translate, prepare: { stores in
                stores.translator.input = sentence
                stores.translator.received("Где ближайшая железнодорожная станция?", for: sentence, by: .system)
            }), variant, height: size.height)
        }
        // H-006: a short sentence with one long word. The length alone put it
        // at 27 points, where "железнодорожная" is wider than the column and
        // broke as "железнодорожна / я". The word now steps the pair to 20, on
        // the side typed into as well as the answer, and at 480 points too.
        try await shoot.shoot("long-cyrillic-word", variants: [.base, .w480, .russian], size: size, settle: 0.12,
                              notes: "Russian typed in, English handed back: no word may break in the middle.") { variant in
            let russian = "Где находится железнодорожная станция?"
            return Self.scene(try await self.openPanel(session, tab: .translate, prepare: { stores in
                stores.translator.input = russian
                stores.translator.received("Where is the railway station?", for: russian, by: .system)
            }), variant, height: size.height)
        }
        try await shoot.shoot("result-online", variants: [.base], size: size, settle: 0.12,
                              notes: "An answer from the online service carries its globe.") { variant in
            Self.scene(try await self.openPanel(session, tab: .translate, prepare: { stores in
                stores.translator.choose(target: .uzbek)
                stores.translator.input = sentence
                stores.translator.received("Eng yaqin temir yo'l bekati qayerda?", for: sentence, by: .online)
            }), variant, height: size.height)
        }
        try await shoot.shoot("long-input", variants: [.base, .w480, .w620, .russian], size: size, settle: 0.12) { variant in
            let long = "The island sits at the notch and stays out of the way until it is asked for. " +
                "Click it and the panel opens: the music, a shelf for files, the clipboard, and this — a place to " +
                "turn a sentence into another language without leaving what you were doing."
            return Self.scene(try await self.openPanel(session, tab: .translate, prepare: { stores in
                stores.translator.input = long
                stores.translator.received(
                    "Остров сидит у выреза и не мешает, пока его не позовут. Нажмите — и панель откроется: музыка, " +
                    "полка для файлов, буфер обмена и это — место, где можно перевести фразу, не отрываясь от дела.",
                    for: long, by: .system)
            }), variant, height: size.height)
        }
        try await shoot.shoot("needs-online", variants: LabVariant.panel, size: size, settle: 0.12,
                              notes: "Uzbek with online translation off: the obstacle and its one remedy.") { variant in
            Self.scene(try await self.openPanel(session, tab: .translate, prepare: { stores in
                stores.translator.choose(target: .uzbek)
                stores.translator.input = sentence
                stores.translator.capabilitiesOverride = { _ in
                    var c = Translator.Capabilities()
                    c.targetOffDevice = true
                    return c
                }
                await stores.translator.translate()
            }), variant, height: size.height)
        }
        try await shoot.shoot("offline-error", variants: LabVariant.panel, size: size, settle: 0.12,
                              notes: "Online on, the network refused by the lab's guard: the real failure path.") { variant in
            Self.scene(try await self.openPanel(session, tab: .translate, prepare: { stores in
                stores.translator.choose(target: .uzbek)
                stores.translator.input = sentence
                stores.translator.capabilitiesOverride = { _ in
                    var c = Translator.Capabilities()
                    c.onlineEnabled = true
                    c.targetOffDevice = true
                    return c
                }
                await stores.translator.translate()
            }), variant, height: size.height)
        }
        try await shoot.shoot("missing-language-pack", variants: LabVariant.panel, size: size, settle: 0.12,
                              notes: "The system offers the pair but has not downloaded it.") { variant in
            Self.scene(try await self.openPanel(session, tab: .translate, prepare: { stores in
                stores.translator.choose(target: .german)
                stores.translator.input = sentence
                stores.translator.capabilitiesOverride = { _ in
                    var c = Translator.Capabilities()
                    c.systemSupported = true
                    return c
                }
                await stores.translator.translate()
            }), variant, height: size.height)
        }
        try await shoot.shoot("apple-intelligence-off", variants: [.base, .russian], size: size, settle: 0.12) { variant in
            Self.scene(try await self.openPanel(session, tab: .translate, prepare: { stores in
                stores.translator.choose(target: .german)
                stores.translator.input = sentence
                stores.translator.capabilitiesOverride = { _ in
                    var c = Translator.Capabilities()
                    c.modelSupportsPair = true
                    c.modelObstacle = .appleIntelligenceOff
                    return c
                }
                await stores.translator.translate()
            }), variant, height: size.height)
        }
        try await shoot.shoot("privacy-covered-input", variants: [.base, .contrast], size: size, settle: 0.12) { variant in
            Self.scene(try await self.openPanel(session, tab: .translate, prepare: { stores in
                stores.privacy.setCovering(.translate, true)
                stores.translator.input = sentence
                stores.translator.received("Где ближайшая железнодорожная станция?", for: sentence, by: .system)
            }), variant, height: size.height)
        }
    }

    // MARK: Settings

    func testSettings() async throws {
        let session = try makeSession()
        let shoot = LabPhotographer(session: session, surface: "panel-settings")
        let size = Self.panelSize

        try await shoot.shoot("viewport-top", variants: LabVariant.panel, size: size, settle: 0.3) { variant in
            Self.scene(try await self.openPanel(session, tab: .settings), variant, height: size.height)
        }
        try await shoot.shoot("viewport-opened-at-music", variants: [.base, .russian], size: size, settle: 0.4,
                              notes: "Reached from the Music tab's Open Settings (J-007): scrolled to the Music section, Music Only first.") { variant in
            Self.scene(try await self.openPanel(session, tab: .settings, configure: { vm in
                vm.settingsScrollTarget = SettingsPane.musicSectionID
            }), variant, height: size.height)
        }
        try await shoot.shoot("viewport-open-on-hover", variants: [.base, .russian], size: size, settle: 0.3,
                              defaults: [NotchViewModel.opensOnHoverKey: true],
                              notes: "Open on Hover on: the Hover Delay slider joins the General section.") { variant in
            Self.scene(try await self.openPanel(session, tab: .settings), variant, height: size.height)
        }

        // Every section at once: the pane on its own, at the width the panel
        // gives it, tall enough that the scroll view never has to scroll.
        func fullLength(_ variant: LabVariant, prepare: (NotchStores) async -> Void = { _ in }) async throws -> AnyView {
            let stores = session.makeStores()
            await prepare(stores)
            let paneWidth = variant.width - 14 * 2 - 30 - 14
            return AnyView(
                SettingsPane(
                    shelf: stores.shelf, screenshotVault: stores.screenshotVault, lyrics: stores.lyrics,
                    media: stores.media, localLyrics: stores.localLyricsLibrary, privacy: stores.privacy,
                    hotKeys: HotKeyCenter(defaults: session.suite, registrar: { _, _ in nil }),
                    updates: UpdateCheck(fetch: { _ in throw URLError(.notConnectedToInternet) })
                )
                .frame(width: paneWidth, height: 1500, alignment: .top)
                .frame(width: paneWidth + 24, height: 1524)
                .background(Color.black)
            )
        }
        let tall = CGSize(width: NotchMetrics.defaultBodyWidth - 14 * 2 - 30 - 14 + 24, height: 1524)
        try await shoot.shoot("all-sections-defaults", variants: [.base, .contrast, .transparency, .russian], size: tall, settle: 0.4,
                              notes: "The whole scroll content at once, outside the panel: every section with the defaults.") { variant in
            try await fullLength(variant)
        }
        try await shoot.shoot("all-sections-everything-on", variants: [.base, .russian], size: tall, settle: 0.4,
                              defaults: [
                                  NotchViewModel.onlineLyricsKey: true, NotchViewModel.onlineTranslationKey: true,
                                  NotchViewModel.opensOnHoverKey: true, NotchViewModel.saveClipboardImagesKey: true,
                                  NotchViewModel.importRecordingsKey: true,
                              ],
                              notes: "Online lyrics and translation on, hover on, captures kept, privacy covering both sections.") { variant in
            try await fullLength(variant) { stores in
                stores.privacy.setCovering(.clipboard, true)
                stores.privacy.setCovering(.translate, true)
            }
        }
        // LY-16: with a song and its lyrics playing, the Lyric Delay row
        // previews the caption's line between Earlier and Later, and says how
        // to use it. The narrowest panel in Russian is where the note wraps.
        func playingWithLyrics(_ stores: NotchStores) async {
            await LabFixtures.play(LabFixtures.Track(elapsed: 25), on: stores.media)
            stores.lyrics.present(LabFixtures.timeline())
        }
        let previewNote = "A track playing 25 s in, with lyrics: the Lyric Delay row previews the line the caption shows."
        try await shoot.shoot("all-sections-lyric-delay-preview", variants: [.base], size: tall, settle: 0.4,
                              notes: previewNote) { variant in
            try await fullLength(variant, prepare: playingWithLyrics)
        }
        let tallNarrow = CGSize(width: 480 - 14 * 2 - 30 - 14 + 24, height: 1524)
        try await shoot.shoot("all-sections-lyric-delay-preview",
                              variants: [LabVariant(name: "ru-w480", width: 480, language: "ru")],
                              size: tallNarrow, settle: 0.4, notes: previewNote) { variant in
            try await fullLength(variant, prepare: playingWithLyrics)
        }
        try await shoot.shoot("all-sections-spotify-connected", variants: [.base], size: tall, settle: 0.4,
                              notes: "A connected Spotify account, stood in by the lab's isolated account and its temporary credential file.") { variant in
            await session.connectSpotify(liked: false)
            return try await fullLength(variant)
        }
        await session.disconnectSpotify()
    }

    // MARK: Welcome

    func testWelcome() async throws {
        let session = try makeSession()
        let shoot = LabPhotographer(session: session, surface: "panel-welcome")
        let size = Self.panelSize
        try await shoot.shoot("first-run", variants: LabVariant.panel, size: size, settle: 0.2) { variant in
            Self.scene(try await self.openPanel(session, configure: { $0.isShowingWelcome = true }), variant, height: size.height)
        }
    }
}
