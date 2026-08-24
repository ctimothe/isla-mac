import SwiftUI
import XCTest
@testable import DynamicIslandKit

/// The caption is allowed to be empty. It is not allowed to take its height with
/// it when it goes.
@MainActor
final class MediaPaneLayoutTests: XCTestCase {

    // MARK: - Which line to show

    /// A paused track sitting before its first timestamp used to show nothing at
    /// all, because the binary search has no line to return yet. The opening line,
    /// unswept, is what should be there: the words exist, the voice has not
    /// arrived. Times are the real shape of a catalogue entry — the cached
    /// "Advice" lyric starts at 1.58 s.
    func testALineBeforeTheFirstTimestampShowsTheOpeningLineUnswept() throws {
        let lines = [
            LyricsStore.Line(at: 1.58, text: "Don't get hung on petty things"),
            LyricsStore.Line(at: 18.2, text: "String the sinner by his wings"),
            LyricsStore.Line(at: 30, text: "In his head a brittle bone"),
        ]

        let early = try XCTUnwrap(MediaPane.displayed(lines: lines, at: 0.4))
        XCTAssertEqual(early.line.text, "Don't get hung on petty things")
        XCTAssertFalse(early.swept, "nobody has sung it yet, so it must not be swept")
        XCTAssertEqual(early.end, 18.2, accuracy: 0.001, "the end is the next line's start")

        let during = try XCTUnwrap(MediaPane.displayed(lines: lines, at: 20))
        XCTAssertEqual(during.line.text, "String the sinner by his wings")
        XCTAssertTrue(during.swept)
        XCTAssertEqual(during.end, 30, accuracy: 0.001)

        let last = try XCTUnwrap(MediaPane.displayed(lines: lines, at: 40))
        XCTAssertEqual(last.line.text, "In his head a brittle bone")
        XCTAssertTrue(last.swept)
        XCTAssertEqual(last.end, 36, accuracy: 0.001, "the last line borrows a spoken length")
    }

    /// A single-line lyric has no next line to borrow an end from.
    func testASingleLineBorrowsASpokenLengthBeforeItIsReached() throws {
        let lines = [LyricsStore.Line(at: 5, text: "only line")]
        let early = try XCTUnwrap(MediaPane.displayed(lines: lines, at: 0))
        XCTAssertFalse(early.swept)
        XCTAssertEqual(early.end, 11, accuracy: 0.001)
    }

    func testNoLinesShowsNothing() {
        XCTAssertNil(MediaPane.displayed(lines: [], at: 10))
    }

    // MARK: - Where the transport sits

    /// The transport must not move because a song has no words. A control that
    /// sits somewhere else depending on the track is a control you have to look
    /// for, and looking for a pause button is the whole cost of getting it wrong.
    ///
    /// Measured off the render rather than the view tree: SwiftUI has no public
    /// hierarchy to walk, but the pane is white-on-black, so the row where the
    /// lower half of the pane first has ink is the top of the scrubber, and that
    /// is exactly the thing that used to slide.
    func testTheTransportSitsAtTheSameHeightWithAndWithoutLyrics() async throws {
        let withWords = try await inkProfile(withLyrics: true)
        let without = try await inkProfile(withLyrics: false)

        let topOfTransport = { (rows: [Int]) -> Int in
            let half = rows.count / 2
            return (half..<rows.count).first { rows[$0] > 0 } ?? -1
        }

        let a = topOfTransport(withWords)
        let b = topOfTransport(without)
        XCTAssertGreaterThan(a, 0, "the scrubber must render for this test to mean anything")
        XCTAssertEqual(
            a, b,
            "the transport moved by \(abs(a - b)) px when the lyrics went away"
        )
    }

    // MARK: - Harness

    /// Rows of the rendered pane, each holding the number of lit pixels in it.
    private func inkProfile(withLyrics: Bool) async throws -> [Int] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Rendering the pane runs its own `.task`, which clears the store when
        // lyrics are switched off — and off is the default, because lyrics are
        // this app's only network use. Without this the harness compared two
        // identical empty renders and passed whatever the layout did.
        let defaults = UserDefaults.standard
        let hadLyrics = defaults.object(forKey: NotchViewModel.showLyricsKey)
        defaults.set(true, forKey: NotchViewModel.showLyricsKey)
        defer {
            if let hadLyrics {
                defaults.set(hadLyrics, forKey: NotchViewModel.showLyricsKey)
            } else {
                defaults.removeObject(forKey: NotchViewModel.showLyricsKey)
            }
        }

        let lyrics = LyricsStore(cacheDirectory: root)
        if withLyrics {
            let key = LyricsStore.cacheKey(
                title: "Test Song", artist: "Test Artist", album: "", duration: 180
            )
            let cached: [String: Any] = [
                "times": [1.0, 4.0, 8.0, 12.0],
                "texts": ["First line", "Second line", "Third line", "Fourth line"],
            ]
            try JSONSerialization.data(withJSONObject: cached)
                .write(to: root.appendingPathComponent("\(key).lrc3.json"))
            lyrics.load(title: "Test Song", artist: "Test Artist", album: "", duration: 180)
            for _ in 0..<50 {
                if case .synced = lyrics.state { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard case .synced = lyrics.state else {
                throw XCTSkip("the cached lyric did not load; nothing to compare against")
            }
        }
        // Left `.idle` otherwise, which is the same gate a track with no words at
        // all fails: the caption produces no view.

        let media = MediaController()
        var snapshot = NowPlayingFeed.Snapshot()
        snapshot.title = "Test Song"
        snapshot.artist = "Test Artist"
        snapshot.album = ""
        snapshot.duration = 180
        snapshot.elapsed = 9.2
        snapshot.rate = 1
        snapshot.isPlaying = true
        snapshot.takenAt = Date()
        snapshot.playerPID = 999
        media.apply(snapshot)

        let pane = MediaPane(media: media, lyrics: lyrics)
            .frame(width: NotchMetrics.standardBody.width, height: 162)
            .background(Color.black)
        let renderer = ImageRenderer(content: pane)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.nsImage, "the pane must render")
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))

        var rows: [Int] = []
        for y in 0..<bitmap.pixelsHigh {
            var lit = 0
            // The text column only. The artwork is a 122 pt square of bright
            // pixels down the left edge, and it inks every row it spans — scan
            // across it and every row looks occupied, which is how the first
            // version of this test passed with the bug still in place.
            for x in stride(from: bitmap.pixelsWide / 3, to: bitmap.pixelsWide, by: 2) {
                guard let colour = bitmap.colorAt(x: x, y: y) else { continue }
                // Anything meaningfully brighter than the black ground counts as ink.
                if colour.brightnessComponent > 0.25 { lit += 1 }
            }
            rows.append(lit)
        }
        return rows
    }
}
