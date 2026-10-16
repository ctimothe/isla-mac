import SwiftUI
import XCTest
@testable import IslaKit

/// The player inside the real shell: the board's body coordinates, converted once
/// in `PlayerLayout`, land where the spec says on the open panel (spec §1, §4.1).
///
/// `PlayerPaneTests` holds the pane against its own layout; this holds the layout
/// against the shell — the 14 pt padding, the 30 pt rail, the 14 pt gap and the
/// header's height that the conversion is made of. A change to any of them that
/// forgot the player fails here, at the cover's left edge or the transport's top.
@MainActor
final class PlayerShellLayoutTests: XCTestCase {
    func testTheOpenPanelPutsTheControlsAtTheSpecsBodyCoordinates() async throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        isolated.suite.set(true, forKey: NotchViewModel.lyricBandKey)
        let geometry = try LabGeometry.make()
        let vm = NotchViewModel(geometry: geometry, stores: isolated.stores)
        await LabFixtures.play(LabFixtures.Track(elapsed: 9, cover: nil), on: isolated.stores.media)
        isolated.stores.lyrics.present(.ready(LyricTimeline(
            lines: [.init(at: 1, text: "First line"), .init(at: 4, text: "Second line"), .init(at: 8, text: "Third line"), .init(at: 12, text: "Fourth line")],
            granularity: .line
        )))
        vm.isOpen = true
        vm.tab = .media

        let bodyWidth = vm.bodySize.width
        let size = CGSize(width: VisualLab.windowSize.width, height: vm.geometry.windowSize.height)
        let root = await AXProbe.tree(of: NotchContentView(vm: vm).defaultAppStorage(isolated.suite), size: size)

        // The body is centred in the window and hangs from its top.
        let origin = CGPoint(x: (size.width - bodyWidth) / 2, y: 0)
        let layout = PlayerLayout(
            bodyWidth: bodyWidth, headerHeight: geometry.notchSize.height, hasLyricBand: true, hasOutputButton: true
        )
        func body(_ node: AXNode) throws -> CGRect {
            let frame = try XCTUnwrap(node.frame, root.dump)
            return frame.offsetBy(dx: -origin.x, dy: -origin.y)
        }

        // Spec §4.1, in body coordinates: Lyrics at (bw − 40, 159), 26 × 26.
        let lyricsButton = try XCTUnwrap(root.all { $0.label == "Lyrics" && $0.role == "AXButton" && $0.frame?.width == 26 }.first, root.dump)
        let lyricsFrame = try body(lyricsButton)
        XCTAssertEqual(lyricsFrame.minX, bodyWidth - 40, accuracy: 1)
        XCTAssertEqual(lyricsFrame.minY, 159, accuracy: 1)
        XCTAssertEqual(lyricsFrame, layout.lyrics, accuracy: 1)

        // The transport: (236, 158), previous at its left edge and next 72 in.
        let previous = try body(try XCTUnwrap(root.first(label: "Previous Track"), root.dump))
        XCTAssertEqual(previous.minX, 236, accuracy: 1)
        XCTAssertEqual(previous.minY, 158, accuracy: 1)
        let next = try body(try XCTUnwrap(root.first(label: "Next Track"), root.dump))
        XCTAssertEqual(next.maxX, 336, accuracy: 1, "the transport is 100 wide")

        // The sung line: (206, 99).
        let band = try XCTUnwrap(root.all { $0.label == "Lyrics" && $0.value == "Third line" }.first, root.dump)
        let bandFrame = try body(band)
        XCTAssertEqual(bandFrame.minX, 206, accuracy: 1)
        XCTAssertEqual(bandFrame.minY, 99, accuracy: 1)
        XCTAssertEqual(bandFrame.width, bodyWidth - 220, accuracy: 1)

        // The rail's own left edge and width (14, 30) are what the 58 is made of.
        let rail = try XCTUnwrap(root.all { $0.role == "AXGroup" && $0.label == "Tabs" }.first, root.dump)
        let railFrame = try body(rail)
        XCTAssertEqual(railFrame.minX, 14, accuracy: 1)
        XCTAssertEqual(railFrame.width, 30, accuracy: 1)
        XCTAssertEqual(railFrame.maxX + PlayerLayout.railGap, PlayerLayout.paneLeading, accuracy: 1)
    }
}

private func XCTAssertEqual(_ a: CGRect, _ b: CGRect, accuracy: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.minX, b.minX, accuracy: accuracy, "minX \(a) vs \(b)", file: file, line: line)
    XCTAssertEqual(a.minY, b.minY, accuracy: accuracy, "minY \(a) vs \(b)", file: file, line: line)
    XCTAssertEqual(a.width, b.width, accuracy: accuracy, "width \(a) vs \(b)", file: file, line: line)
    XCTAssertEqual(a.height, b.height, accuracy: accuracy, "height \(a) vs \(b)", file: file, line: line)
}
