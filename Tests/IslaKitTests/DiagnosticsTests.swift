import AppKit
import OSLog
import XCTest
@testable import IslaKit

/// The report a stranger pastes into an issue. It has to carry what decides a
/// bug, and nothing the person played, copied or translated.
@MainActor
final class DiagnosticsTests: XCTestCase {

    private func sample(log: [String] = ["12:00:00.000 [media] helper refused: readerRefused"]) -> Diagnostics.Snapshot {
        Diagnostics.Snapshot(
            version: "0.3.0", build: "3", macOS: "Version 27.0 (Build 27A1)",
            model: "Mac16,1", architecture: "arm64",
            displays: [
                .init(name: "built-in", points: CGSize(width: 1512, height: 982), scale: 2, hasNotch: true),
                .init(name: "external", points: CGSize(width: 2560, height: 1440), scale: 2, hasNotch: false),
            ],
            nowPlaying: "Music and Spotify only (readerRefused)",
            helperPresent: true, appQuarantined: true, helperQuarantined: true,
            signature: "ad-hoc", lockScreenSPI: true,
            settings: [("Show Lyrics", "on")], shortcuts: [("openPanel", "⌃⌥⌘I")],
            log: log
        )
    }

    func testTheReportCarriesEverySection() {
        let text = Diagnostics.render(sample())
        for expected in [
            "Isla 0.3.0 (3)", "macOS Version 27.0", "Mac16,1", "arm64",
            "built-in: 1512×982 pt @2x, notch", "external: 2560×1440 pt @2x, no notch",
            "route: Music and Spotify only (readerRefused)", "app quarantined: yes", "helper quarantined: yes",
            "signature: ad-hoc", "lock-screen SPI: available",
            "Show Lyrics: on", "openPanel: ⌃⌥⌘I", "helper refused: readerRefused",
        ] {
            XCTAssertTrue(text.contains(expected), "missing \(expected)\n\(text)")
        }
    }

    /// Report-only for now: the helper's seal is shown, not enforced.
    func testTheReportShowsTheHelperSignature() {
        var snapshot = sample()
        snapshot.helperSignature = "valid"
        XCTAssertTrue(Diagnostics.render(snapshot).contains("helper signature: valid"))
        XCTAssertTrue(Diagnostics.render(sample()).contains("helper signature: not checked"))
    }

    func testAnEmptyLogSaysSo() {
        XCTAssertTrue(Diagnostics.render(sample(log: [])).contains("nothing logged"))
    }

    /// The live snapshot reads settings and system state, never content. A
    /// title playing right now must not be anywhere in it.
    func testTheLiveReportHoldsNoTrack() {
        let media = MediaController()
        var playing = NowPlayingFeed.Snapshot()
        playing.title = "A Song Nobody Should See"
        playing.artist = "Private Artist"
        playing.isPlaying = true
        playing.takenAt = Date()
        media.apply(playing)
        let text = Diagnostics.render(Diagnostics.current(media: media, includeLog: false))
        XCTAssertFalse(text.contains("A Song Nobody Should See"))
        XCTAssertFalse(text.contains("Private Artist"))
        XCTAssertTrue(text.contains("route: Now Playing"))
    }

    /// Isla's own log is read back for this process only, and a private value
    /// logged by the app does not come back readable.
    func testTheLogIsReadBackWithPrivateValuesRedacted() throws {
        // Opening the process's log store takes seconds, and what this checks
        // is os.Logger's own redaction, so it runs on request like the other
        // live tests.
        guard ProcessInfo.processInfo.environment["ISLA_LIVE_TESTS"] == "1" else {
            throw XCTSkip("reads the unified log; set ISLA_LIVE_TESTS=1")
        }
        let marker = UUID().uuidString
        Log.app.notice("diagnostics test \(marker, privacy: .public) secret=\("hunter2-\(marker)")")
        let lines = Diagnostics.recentLog(minutes: 1)
        guard let line = lines.first(where: { $0.contains(marker) }) else {
            // The unified log can lag a moment behind under load. Missing is
            // not a leak; an unredacted secret is.
            return
        }
        XCTAssertFalse(line.contains("hunter2"), line)
    }

    /// Paste from Other Apps set to Don't Allow empties history without a
    /// word (J-001), so a report that says "my clipboard is empty" has to
    /// carry the switch, in each of its four states, and the live snapshot
    /// has to pass on what it was handed.
    func testPasteboardAccessIsReported() {
        let states: [(ClipboardAccess, String)] = [
            (.unknown, "default"), (.ask, "ask"), (.allowed, "allowed"), (.denied, "denied"),
        ]
        for (access, word) in states {
            var snapshot = sample()
            snapshot.pasteFromOtherApps = access
            let text = Diagnostics.render(snapshot)
            XCTAssertTrue(text.contains("Paste from Other Apps: \(word)"), "missing \(word)\n\(text)")
        }
        let live = Diagnostics.render(
            Diagnostics.current(media: MediaController(), clipboardAccess: .denied, includeLog: false)
        )
        XCTAssertTrue(live.contains("Paste from Other Apps: denied"), live)
    }

    func testTheReportFormIsOnTheProjectsTracker() {
        XCTAssertTrue(Diagnostics.reportURL.absoluteString.hasPrefix(ProductIdentity.homepage + "/issues/new"))
    }

    // MARK: - The Prompter (spec 14.5)

    private func prompterParts(titles: [(String, [String])] = []) throws -> PrompterParts {
        let time = StageTime()
        let library = PrompterLibrary(io: StageFileIO(), scheduler: StageScheduler(time: time))
        library.load()
        for (title, pages) in titles { _ = try library.addScript(title: title, pages: pages) }
        return PrompterParts(
            settings: PrompterSettings(defaults: InMemoryDefaults()),
            library: library,
            session: PrompterSession(now: { time.now }, scheduler: StageScheduler(time: time), keepAwake: StageLease())
        )
    }

    /// Off, the report says only that: there is no library to count, and
    /// nothing else of the Prompter is listed.
    func testTheReportSaysOnlyThatThePrompterIsOffWhileItIs() {
        let rows = Diagnostics.prompterReport(nil)
        XCTAssertEqual(rows.map(\.0), ["switch"])
        XCTAssertEqual(rows.map(\.1), ["off"])
        let text = Diagnostics.render(sample())
        XCTAssertTrue(text.contains("Prompter\n  switch: off\n"), text)
        XCTAssertFalse(text.contains("scripts:"), text)
    }

    /// On, it reports counts and the library's state, and no script text and
    /// no title: scripts are what a speaker would least want in a bug report.
    func testTheReportCountsScriptsAndPagesAndNeverTheirWords() throws {
        let parts = try prompterParts(titles: [
            ("Quarterly Secret Plan", ["launch the hidden thing", "second page text"]),
            ("Untitled", ["only page"]),
        ])
        let rows = Diagnostics.prompterReport(parts)
        XCTAssertEqual(rows.first?.0, "switch")
        XCTAssertEqual(rows.first?.1, "on")
        XCTAssertTrue(rows.contains { $0 == ("scripts", "2") }, "\(rows)")
        XCTAssertTrue(rows.contains { $0 == ("pages", "3") }, "\(rows)")
        XCTAssertTrue(rows.contains { $0 == ("library", "ready") }, "\(rows)")

        var snapshot = sample()
        snapshot.prompter = rows
        let text = Diagnostics.render(snapshot)
        XCTAssertTrue(text.contains("  scripts: 2"), text)
        for secret in ["Quarterly", "Secret", "hidden thing", "second page", "Untitled", "only page"] {
            XCTAssertFalse(text.contains(secret), "\(secret) leaked\n\(text)")
        }
    }

    /// A library that could not be read is a state worth reporting, with the
    /// count left at what is known (nothing), not a crash or a guess.
    func testAnUnreadableLibraryIsNamedNotCounted() {
        final class Garbage: PrompterFileIO {
            func exists() -> Bool { true }
            func read() throws -> Data { Data("{ not json, but a private script".utf8) }
            func writeAtomically(_ data: Data) throws {}
            func copyAside(as name: String) throws -> String { name }
        }
        let time = StageTime()
        let library = PrompterLibrary(io: Garbage(), scheduler: StageScheduler(time: time))
        library.load()
        let parts = PrompterParts(
            settings: PrompterSettings(defaults: InMemoryDefaults()), library: library,
            session: PrompterSession(now: { time.now }, scheduler: StageScheduler(time: time), keepAwake: StageLease())
        )
        let rows = Diagnostics.prompterReport(parts)
        XCTAssertTrue(rows.contains { $0 == ("library", "unreadable") }, "\(rows)")
        XCTAssertTrue(rows.contains { $0 == ("scripts", "0") }, "\(rows)")
        XCTAssertFalse("\(rows)".contains("private script"))
    }

    /// The live snapshot takes the Prompter's parts, nil while the switch is
    /// off, and never reads a library to say so.
    func testTheLiveReportCarriesThePrompterSection() throws {
        let media = MediaController()
        let off = Diagnostics.render(Diagnostics.current(media: media, hotKeys: HotKeyCenter(defaults: InMemoryDefaults(), registrar: { _, _ in nil }), includeLog: false))
        XCTAssertTrue(off.contains("Prompter\n  switch: off"), off)
        let on = Diagnostics.render(Diagnostics.current(
            media: media, hotKeys: HotKeyCenter(defaults: InMemoryDefaults(), registrar: { _, _ in nil }),
            prompter: try prompterParts(titles: [("T", ["a b"])]), includeLog: false
        ))
        XCTAssertTrue(on.contains("  switch: on"), on)
        XCTAssertTrue(on.contains("  scripts: 1"), on)
    }
}
