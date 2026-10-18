import AppKit
import XCTest
@testable import IslaKit

/// The lyrics stage (spec §19.6, board `R2-Lyrics`): the lines over a foot
/// that carries the cover, the song, its transport and the stage's tools,
/// held at the three widths a person can choose, in the content's
/// coordinates (the board's y less the 38 pt header row).
@MainActor
final class LyricsStageLayoutTests: XCTestCase {
    private let widths: [CGFloat] = [480, 560, 620]
    /// 400 tall less the header row.
    private let contentHeight = SurfaceLayout.stageHeight - SurfaceLayout.referenceNotchHeight

    func testTheLinesTakeTheStageAboveTheFoot() {
        for bw in widths {
            let layout = StageLayout(bodyWidth: bw)
            XCTAssertEqual(layout.lines, CGRect(x: 24, y: 0, width: bw - 48, height: 268), "\(bw)")
            XCTAssertEqual(layout.hairline.minY, 314 - 38)
            XCTAssertLessThanOrEqual(layout.lines.maxY + 8, layout.hairline.minY, "the fade ends before the foot")
        }
        XCTAssertEqual(StageLayout.readingCentre, 114)
    }

    /// The transport is centred on the body whatever its width, and the
    /// song's two lines end 8 short of it.
    func testTheFootAtEveryWidth() {
        for bw in widths {
            let layout = StageLayout(bodyWidth: bw)
            XCTAssertEqual(layout.cover, CGRect(x: 24, y: 292, width: 40, height: 40))
            XCTAssertEqual(layout.transport(.playPause).midX, bw / 2, accuracy: 0.001, "\(bw)")
            XCTAssertEqual(layout.transport(.previous).minY, 334 - 38)
            XCTAssertEqual(layout.title.maxX, layout.transport(.previous).minX - 8, "\(bw)")
            XCTAssertEqual(layout.artist.maxX, layout.title.maxX)
            XCTAssertEqual(layout.tool(.hideLyrics).maxX, bw - 26, "\(bw)")
            XCTAssertEqual(layout.tool(.hideLyrics).minY, 336 - 38)
            XCTAssertEqual(layout.progress, CGRect(x: 24, y: 384 - 38, width: bw - 48, height: 3))
        }
    }

    /// Nothing in the foot touches anything else, and all of it is inside the
    /// body — the narrowest width is where the four tools come nearest the
    /// transport.
    func testNothingInTheFootOverlaps() {
        for bw in widths {
            let layout = StageLayout(bodyWidth: bw)
            var frames: [(String, CGRect)] = [
                ("cover", layout.cover), ("title", layout.title), ("artist", layout.artist),
                ("progress", layout.progress),
            ]
            frames += StageLayout.Transport.allCases.map { ("\($0)", layout.transport($0)) }
            frames += StageLayout.Tool.allCases.map { ("\($0)", layout.tool($0)) }
            let content = CGRect(x: 0, y: 0, width: bw, height: contentHeight)
            for (name, frame) in frames {
                XCTAssertTrue(content.contains(frame), "\(name) \(frame) leaves the body at \(bw)")
            }
            for (i, a) in frames.enumerated() {
                for b in frames[(i + 1)...] where a.0 != "title" || b.0 != "artist" {
                    XCTAssertFalse(a.1.intersects(b.1), "\(a.0) overlaps \(b.0) at \(bw)")
                }
            }
            XCTAssertGreaterThan(layout.title.width, 90, "the song keeps room for a name at \(bw)")
        }
    }

    /// The stage's way out of "no lyrics", in Russian at the narrowest body:
    /// Import and Search Online side by side, measured from the shipped table
    /// at the offer buttons' 11 pt medium and 10 pt padding, inside the lines.
    func testTheNoneFoundOffersFitInRussianAt480() throws {
        let russian = try Self.russianTable()
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        func button(_ key: String) throws -> CGFloat {
            let title = try XCTUnwrap(russian[key], "ru.lproj has no \(key)")
            return ceil((title as NSString).size(withAttributes: [.font: font]).width) + 20
        }
        let row = try button("Import LRC…") + 8 + button("Search Online")
        XCTAssertLessThanOrEqual(row, StageLayout(bodyWidth: 480).lines.width)
    }

    // MARK: The menu and the way back

    /// Shuffle and Repeat left the player for the stage's More menu
    /// (§19.6) and lead it, above a separator, where the player reports them.
    func testTheMoreMenuLeadsWithShuffleAndRepeat() {
        let items = LyricsMoreMenuModel.items(
            localFileName: nil, onlineOn: false, offset: 0, shuffle: true, repeatMode: .all
        )
        XCTAssertEqual(items.prefix(3).map(\.kind), [.shuffle, .repeatMode, .separator])
        XCTAssertTrue(items[0].isChecked)
        XCTAssertEqual(items[1].title, "Repeat: All Tracks")
        XCTAssertTrue(items[1].isChecked)

        let off = LyricsMoreMenuModel.items(
            localFileName: nil, onlineOn: false, offset: 0, shuffle: false, repeatMode: .off
        )
        XCTAssertFalse(off[0].isChecked)
        XCTAssertFalse(off[1].isChecked)

        // A player that reports neither leaves the menu to the words.
        let none = LyricsMoreMenuModel.items(localFileName: nil, onlineOn: false, offset: 0)
        XCTAssertEqual(none.first?.kind, .header)
        XCTAssertFalse(none.contains { $0.kind == .shuffle || $0.kind == .repeatMode })
    }

    /// Hide Lyrics is the way back to the player, and the stage with no song
    /// is drawn as the player: there are no words to show.
    func testHideLyricsGoesBackToThePlayer() throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: isolated.stores)
        vm.openStage()
        XCTAssertEqual(vm.surface, .stage)
        XCTAssertEqual(vm.presented, .player, "no song: the stage is the empty player")
        vm.hideLyrics()
        XCTAssertEqual(vm.surface, .player)
    }

    private static func russianTable() throws -> [String: String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/ru.lproj/Localizable.strings")
        let text = try String(contentsOf: url, encoding: .utf8)
        let pattern = try NSRegularExpression(
            pattern: #"^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";"#, options: .anchorsMatchLines
        )
        var table: [String: String] = [:]
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let key = Range(match.range(at: 1), in: text),
                  let value = Range(match.range(at: 2), in: text) else { continue }
            table[String(text[key])] = String(text[value])
        }
        return table
    }
}
