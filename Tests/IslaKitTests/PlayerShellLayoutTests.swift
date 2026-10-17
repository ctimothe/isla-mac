import SwiftUI
import XCTest
@testable import IslaKit

/// The player inside the real shell: the board's coordinates, converted once in
/// `PlayerLayout` (a board x less the 34 pt shoulder, a board y less 38), land
/// where the spec says on the open panel (spec §19.2, §19.6).
///
/// `PlayerPaneTests` holds the pane against its own layout; this holds the layout
/// against the shell — the body centred in the window, hanging from the top of the
/// screen, with the content starting under the header row. A change to either
/// that forgot the player fails here, at the cover's left edge or the transport's
/// middle.
@MainActor
final class PlayerShellLayoutTests: XCTestCase {
    func testTheOpenPanelPutsTheControlsAtTheSpecsCoordinates() async throws {
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
        vm.open(.player)
        XCTAssertEqual(vm.presented, .player)

        let bodyWidth = vm.openBodySize.width
        XCTAssertEqual(bodyWidth, PlayerLayout.referenceBodyWidth, accuracy: 0.001)
        let header = geometry.notchSize.height
        let size = CGSize(width: VisualLab.windowSize.width, height: vm.geometry.windowSize.height)
        let root = await AXProbe.tree(of: NotchContentView(vm: vm).defaultAppStorage(isolated.suite), size: size)

        // The body is centred in the window and hangs from its top; the content
        // starts under the header row.
        let origin = CGPoint(x: (size.width - bodyWidth) / 2, y: header)
        let layout = PlayerLayout(bodyWidth: bodyWidth, hasOutputButton: true)
        func content(_ node: AXNode) throws -> CGRect {
            let frame = try XCTUnwrap(node.frame, root.dump)
            return frame.offsetBy(dx: -origin.x, dy: -origin.y)
        }

        // The cover: a button at (54, 38) on the board, 60 × 60.
        let cover = try XCTUnwrap(root.all { $0.label == "Lyrics" && $0.role == "AXButton" && $0.value.isEmpty }.first, root.dump)
        XCTAssertEqual(try content(cover), layout.cover, accuracy: 1)

        // The transport, each control centred where the board puts it.
        let previous = try content(try XCTUnwrap(root.first(label: "Previous Track"), root.dump))
        XCTAssertEqual(previous.midX, layout.target(.previous).midX, accuracy: 1)
        XCTAssertEqual(previous.midY, layout.target(.previous).midY, accuracy: 1)
        let next = try content(try XCTUnwrap(root.first(label: "Next Track"), root.dump))
        XCTAssertEqual(next.midX, layout.target(.next).midX, accuracy: 1)
        XCTAssertEqual(next.midY, layout.controlsMidY, accuracy: 1)
        let pause = try content(try XCTUnwrap(root.first(label: "Pause"), root.dump))
        XCTAssertEqual(pause.midX, layout.centre, accuracy: 1, "Play / Pause is on m")
        XCTAssertEqual(next.midX - previous.midX, 138, accuracy: 1, "the transport's 69 pitch, twice")

        // The sung line has the subtitle: (129.2 − 34, baseline 84.5), running
        // to the equalizer's right edge.
        let band = try XCTUnwrap(root.all { $0.label == "Lyrics" && $0.value == "Third line" }.first, root.dump)
        let bandFrame = try content(band)
        let box = MediaPane.textBox(
            x: layout.textLeading, baseline: layout.subtitleBaseline, width: layout.subtitleWidth,
            size: PlayerLayout.subtitleSize, weight: .semibold
        )
        XCTAssertEqual(bandFrame.minX, box.minX, accuracy: 1)
        XCTAssertEqual(bandFrame.minY, box.minY, accuracy: 1)
        XCTAssertEqual(bandFrame.width, layout.subtitleWidth, accuracy: 1)

        // The rail is gone: no group of tabs, and the open surface is the one
        // group, named for it.
        XCTAssertNil(root.first(label: "Tabs"), root.dump)
        XCTAssertEqual(root.all { $0.role == "AXGroup" && $0.label == vm.presented.title }.count, 1, root.dump)
    }
}

private func XCTAssertEqual(_ a: CGRect, _ b: CGRect, accuracy: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.minX, b.minX, accuracy: accuracy, "minX \(a) vs \(b)", file: file, line: line)
    XCTAssertEqual(a.minY, b.minY, accuracy: accuracy, "minY \(a) vs \(b)", file: file, line: line)
    XCTAssertEqual(a.width, b.width, accuracy: accuracy, "width \(a) vs \(b)", file: file, line: line)
    XCTAssertEqual(a.height, b.height, accuracy: accuracy, "height \(a) vs \(b)", file: file, line: line)
}
