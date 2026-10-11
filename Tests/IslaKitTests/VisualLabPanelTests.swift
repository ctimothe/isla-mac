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
        try await shoot.shoot("instrumental-gap", variants: [.base, .contrast, .russian], size: size, settle: 0.3,
                              notes: note + " An empty LRC line is the instrumental break; the voice is 14 s away.") { variant in
            try await self.stage(session, blurredCover, .init(elapsed: 26), LabFixtures.timeline(LabFixtures.gapLines), variant: variant)
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
        try await shoot.shoot("drop-target", variants: [.base, .contrast], size: size,
                              notes: "A drag over the island: the dashed well lights.") { variant in
            Self.scene(try await self.openPanel(session, tab: .shelf, configure: { $0.isDropTargeted = true }), variant, height: size.height)
        }
        try await shoot.shoot("a-few-cards", variants: LabVariant.panel, size: size, settle: 0.8, notes: note) { variant in
            Self.scene(try await self.openPanel(session, tab: .shelf, prepare: { self.stock($0.shelf, session: session, urls: few) }),
                       variant, height: size.height)
        }
        try await shoot.shoot("two-selected", variants: [.base, .contrast, .russian], size: size, settle: 0.8, notes: note) { variant in
            Self.scene(try await self.openPanel(session, tab: .shelf, prepare: { stores in
                self.stock(stores.shelf, session: session, urls: few)
            }, configure: { vm in
                vm.shelf.select(vm.shelf.items[0], modifiers: [])
                vm.shelf.select(vm.shelf.items[2], modifiers: .command)
            }), variant, height: size.height)
        }
        try await shoot.shoot("at-the-60-cap", variants: [.base, .w480, .w620], size: size, settle: 1.5,
                              notes: note + " Sixty cards, the shelf's limit; the row scrolls sideways.") { variant in
            Self.scene(try await self.openPanel(session, tab: .shelf, prepare: { self.stock($0.shelf, session: session, urls: full) }),
                       variant, height: size.height)
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
            .text(String(repeating: "A long note that runs on and on past the edge of the row. ", count: 4)),
        ], into: clipboard)
    }

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
                              notes: "A row's copy action, pressed through accessibility: the checkmark it flashes for 1.1 s. Copies onto the lab's private pasteboard.",
                              interact: { LabAccessibility.press(localized("Copy Entry"), in: $0) }) { variant in
            Self.scene(try await self.openPanel(session, tab: .clipboard, prepare: { self.fill(session, $0.clipboard) }),
                       variant, height: size.height)
        }
        try await shoot.shoot("clear-armed", variants: [.base, .russian], size: size,
                              interact: { LabAccessibility.press(localized("Clear"), in: $0) }) { variant in
            Self.scene(try await self.openPanel(session, tab: .clipboard, prepare: { self.fill(session, $0.clipboard) }),
                       variant, height: size.height)
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
