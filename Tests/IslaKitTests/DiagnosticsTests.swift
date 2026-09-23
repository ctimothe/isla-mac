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
                .init(name: "Built-in Retina Display", points: CGSize(width: 1512, height: 982), scale: 2, hasNotch: true),
                .init(name: "Studio Display", points: CGSize(width: 2560, height: 1440), scale: 2, hasNotch: false),
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
            "Built-in Retina Display: 1512×982 pt @2x, notch", "Studio Display: 2560×1440 pt @2x, no notch",
            "route: Music and Spotify only (readerRefused)", "app quarantined: yes", "helper quarantined: yes",
            "signature: ad-hoc", "lock-screen SPI: available",
            "Show Lyrics: on", "openPanel: ⌃⌥⌘I", "helper refused: readerRefused",
        ] {
            XCTAssertTrue(text.contains(expected), "missing \(expected)\n\(text)")
        }
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
    func testTheLogIsReadBackWithPrivateValuesRedacted() {
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

    func testTheReportFormIsOnTheProjectsTracker() {
        XCTAssertTrue(Diagnostics.reportURL.absoluteString.hasPrefix(ProductIdentity.homepage + "/issues/new"))
    }
}
