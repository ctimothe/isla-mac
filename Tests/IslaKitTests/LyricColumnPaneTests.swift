import CoreAudio
import SwiftUI
import XCTest
@testable import IslaKit

/// The one Music view in its other two states, as drawn: where each control
/// actually lands against the table (`PlayerLayout.frames(for:)`) in the column
/// and on the tall page at 480, 560 and 620, and what the open panel's header
/// carries for them (spec §5.1, §5.2, §6).
///
/// Nothing reaches the machine: the controller is cut from every real player,
/// the audio watch reads a value and installs nothing, the settings come from a
/// private suite, and no control is pressed that would write the system volume.
@MainActor
final class LyricColumnPaneTests: XCTestCase {
    private static let lines: [LyricsStore.Line] = [
        .init(at: 1, text: "First line"), .init(at: 4, text: "Second line"),
        .init(at: 8, text: "Third line"), .init(at: 12, text: "Fourth line"),
        .init(at: 16, text: "Fifth line"),
    ]

    private static func audio() -> AudioWatch {
        let outputs: [AudioOutputs.Output] = [
            .init(id: 41, name: "MacBook Pro Speakers", transport: kAudioDeviceTransportTypeBuiltIn),
        ]
        return AudioWatch(read: { (outputs, 41, 0.62) }, readMuted: { false }, installListeners: {}, removeListeners: {})
    }

    override func tearDown() async throws {
        LabLocalization.uninstall()
    }

    private struct Scene {
        let root: AXNode
        let layout: PlayerLayout
        let frames: PlayerLayout.StateFrames
    }

    private func scene(_ state: PlayerLayout.State, width: CGFloat = 560, header: CGFloat = 38) async -> Scene {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        isolated.suite.set(true, forKey: NotchViewModel.volumeAndOutputKey)
        let media = isolated.stores.media
        await LabFixtures.play(LabFixtures.Track(title: "Waiting Room", elapsed: 9), on: media)
        isolated.stores.lyrics.present(.ready(LyricTimeline(lines: Self.lines, granularity: .line)))
        let pane = MediaPane(
            media: media, lyrics: isolated.stores.lyrics,
            isExpanded: state == .tall,
            morph: nil,
            showingLyrics: .constant(state != .player),
            headerHeight: header, audio: Self.audio(),
            icons: SettingsFixture.macWithApps([:])
        )
        .defaultAppStorage(isolated.suite)
        let layout = PlayerLayout(bodyWidth: width, headerHeight: header)
        let frames = layout.frames(for: state)
        let size = CGSize(
            width: PlayerLayout.paneWidth(bodyWidth: width),
            height: frames.bodyHeight - NotchGeometry.bodyBottomPadding - header
        )
        let root = await AXProbe.tree(of: pane, size: size)
        return Scene(root: root, layout: layout, frames: frames)
    }

    private func node(_ root: AXNode, _ label: String, role: String? = nil) throws -> AXNode {
        try XCTUnwrap(
            root.all { $0.label == label && (role == nil || $0.role == role) }.first,
            "no \"\(label)\"\n\(root.dump)"
        )
    }

    private func assertNear(
        _ node: AXNode, _ expected: CGRect, _ message: String, accuracy: CGFloat = 1.5,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let frame = try XCTUnwrap(node.frame, message, file: file, line: line)
        XCTAssertEqual(frame.minX, expected.minX, accuracy: accuracy, "\(message) minX \(frame)", file: file, line: line)
        XCTAssertEqual(frame.minY, expected.minY, accuracy: accuracy, "\(message) minY \(frame)", file: file, line: line)
    }

    // MARK: - Where the controls land

    func testTheColumnPutsTheControlsWhereTheTableDoes() async throws {
        for width: CGFloat in [480, 560, 620] {
            let s = await scene(.column, width: width)
            let l = s.layout, f = s.frames
            try assertNear(try node(s.root, "Pause"), CGRect(x: l.inPane(f.transport).minX + 55, y: l.inPane(f.transport).minY, width: 28, height: 28), "pause at \(width)")
            try assertNear(try node(s.root, "Previous Track"), l.inPane(f.transport), "previous at \(width)")
            try assertNear(try node(s.root, "Sound Output"), l.inPane(try XCTUnwrap(f.output)), "output at \(width)")
            let hide = try node(s.root, "Hide Lyrics", role: "AXButton")
            try assertNear(hide, l.inPane(f.lyrics), "Hide Lyrics at \(width)")
            XCTAssertTrue(hide.selected, "the open Lyrics button is the selected one")
            let slider = try node(s.root, "Playback Position", role: "AXSlider")
            XCTAssertEqual(try XCTUnwrap(slider.frame).midY, l.inPane(f.progress).midY, accuracy: 1)
        }
    }

    func testTheTallPageAtThreeWidthsPutsItsFooterWhereTheTableDoes() async throws {
        for width: CGFloat in [480, 560, 620] {
            let s = await scene(.tall, width: width)
            let l = s.layout, f = s.frames
            try assertNear(try node(s.root, "Previous Track"), l.inPane(f.transport), "previous at \(width)")
            try assertNear(try node(s.root, "Sound Output"), l.inPane(try XCTUnwrap(f.output)), "output at \(width)")
            try assertNear(try node(s.root, "Hide Lyrics", role: "AXButton"), l.inPane(f.lyrics), "Hide Lyrics at \(width)")
            let progress = try node(s.root, "Playback Position", role: "AXSlider")
            XCTAssertEqual(try XCTUnwrap(progress.frame).midY, l.inPane(f.progress).midY, accuracy: 1)
            XCTAssertEqual(try XCTUnwrap(progress.frame).maxX, l.inPane(f.progress).maxX - MediaPane.timeWidths(duration: 238).remaining - 6, accuracy: 1.5)
            let volume = try node(s.root, "Volume", role: "AXSlider")
            XCTAssertEqual(try XCTUnwrap(volume.frame).maxX, l.inPane(try XCTUnwrap(f.volume)).maxX, accuracy: 1.5)
        }
    }

    /// The sung line is where the table puts it, in the pane as drawn: its row
    /// starts at the lines' left edge (268 in the column, 58 on the tall page, in
    /// body coordinates) and is centred on the sung line's y.
    func testTheSungLineLandsWhereTheTablePutsIt() async throws {
        for state in [PlayerLayout.State.column, .tall] {
            for width: CGFloat in [480, 560, 620] {
                let s = await scene(state, width: width)
                let sung = try XCTUnwrap(s.frames.sungLine)
                let expected = s.layout.inPane(sung)
                let row = try XCTUnwrap(
                    s.root.all { $0.label == "Third line" && $0.role == "AXButton" }.first, s.root.dump
                )
                let frame = try XCTUnwrap(row.frame)
                XCTAssertEqual(frame.minX, expected.minX, accuracy: 1.5, "\(state) at \(width): \(frame)")
                XCTAssertEqual(frame.midY, expected.midY, accuracy: 3, "\(state) at \(width): \(frame)")
                XCTAssertTrue(row.selected, "it is the line being sung")
            }
        }
    }

    /// The player's own controls fold away in the other two states: no band, and
    /// shuffle and repeat out of reach and out of the accessibility tree.
    func testTheColumnHasNoBandAndNoModeButtons() async throws {
        for state in [PlayerLayout.State.column, .tall] {
            let s = await scene(state)
            XCTAssertNil(
                s.root.all { $0.label == "Lyrics" && $0.role == "AXButton" && $0.frame?.width != 26 }.first,
                "the band's button is the player's, not the column's\n\(s.root.dump)"
            )
            XCTAssertNil(s.root.first(label: "Shuffle"), "folded away in \(state)")
            XCTAssertNil(s.root.first(label: "Repeat"), "folded away in \(state)")
            XCTAssertNotNil(s.root.first(label: state == .tall ? "Third line" : "Third line"), "the lines are the page\n\(s.root.dump)")
        }
    }

    /// The player keeps its own Lyrics button and its band.
    func testThePlayerIsStillThePlayer() async throws {
        let s = await scene(.player)
        XCTAssertNotNil(s.root.all { $0.label == "Lyrics" && $0.role == "AXButton" && $0.frame?.width == 26 }.first, s.root.dump)
        XCTAssertNil(s.root.first(label: "Hide Lyrics"))
    }

    /// The artist alone beside the smaller cover; the full line in the player.
    func testTheColumnNamesTheArtistAlone() async throws {
        let s = await scene(.column)
        let artist = try XCTUnwrap(s.root.all { [$0.label, $0.value, $0.title].contains(LabFixtures.Track().artist) }.first, s.root.dump)
        XCTAssertNotNil(artist.frame)
    }

    // MARK: - The open panel

    private struct Shell {
        let root: AXNode
        let origin: CGPoint
        let vm: NotchViewModel
        let bodyWidth: CGFloat
    }

    private func shell(_ state: PlayerLayout.State, tab: NotchViewModel.Tab = .media) async throws -> Shell {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        isolated.suite.set(true, forKey: NotchViewModel.volumeAndOutputKey)
        let geometry = try LabGeometry.make()
        let vm = NotchViewModel(geometry: geometry, stores: isolated.stores)
        await LabFixtures.play(LabFixtures.Track(elapsed: 9), on: isolated.stores.media)
        isolated.stores.lyrics.present(.ready(LyricTimeline(lines: Self.lines, granularity: .line)))
        vm.isOpen = true
        vm.tab = tab
        vm.isShowingLyrics = state != .player
        if state == .tall { vm.setExpanded(true, for: .media) }
        // Another tab, grown: the model may be tall there, and the header still
        // has no button for it in this release.
        if tab != .media { vm.setExpanded(true, for: tab) }
        let size = CGSize(width: VisualLab.windowSize.width, height: vm.geometry.windowSize.height)
        let root = await AXProbe.tree(of: NotchContentView(vm: vm).defaultAppStorage(isolated.suite), size: size)
        return Shell(
            root: root, origin: CGPoint(x: (size.width - vm.bodySize.width) / 2, y: 0), vm: vm, bodyWidth: vm.bodySize.width
        )
    }

    private func body(_ node: AXNode, in shell: Shell) throws -> CGRect {
        try XCTUnwrap(node.frame).offsetBy(dx: -shell.origin.x, dy: -shell.origin.y)
    }

    /// Spec §5.2, §6: Expand at `(bw − 39, 8)` and More at `(bw − 65, 8)`, 22 ×
    /// 22, in body coordinates; Show Translation hidden until the translation
    /// release; the player's source tag out of their way.
    func testTheColumnsHeaderCarriesMoreAndExpand() async throws {
        let s = try await shell(.column)
        let expand = try body(try XCTUnwrap(s.root.first(label: "Expand"), s.root.dump), in: s)
        XCTAssertEqual(expand, CGRect(x: s.bodyWidth - 39, y: 8, width: 22, height: 22), accuracy: 1)
        let more = try body(try XCTUnwrap(s.root.first(label: "More Lyrics Options"), s.root.dump), in: s)
        XCTAssertEqual(more, CGRect(x: s.bodyWidth - 65, y: 8, width: 22, height: 22), accuracy: 1)
        XCTAssertNil(s.root.first(label: "Show Translation"), "hidden until the translation release wires it\n\(s.root.dump)")
        XCTAssertNil(s.root.first(label: "Collapse"))
    }

    func testTheTallPageSaysCollapseInThePlaceOfExpand() async throws {
        let s = try await shell(.tall)
        let collapse = try body(try XCTUnwrap(s.root.first(label: "Collapse"), s.root.dump), in: s)
        XCTAssertEqual(collapse, CGRect(x: s.bodyWidth - 39, y: 8, width: 22, height: 22), accuracy: 1)
        XCTAssertNil(s.root.first(label: "Expand"))
        XCTAssertEqual(s.vm.openBodySize.height, 400)
    }

    /// The player does not expand: no Expand button, and no More menu — the
    /// header is the source tag's.
    func testThePlayersHeaderHasNoLyricTools() async throws {
        let s = try await shell(.player)
        XCTAssertNil(s.root.first(label: "Expand"))
        XCTAssertNil(s.root.first(label: "More Lyrics Options"))
    }

    /// Translate has the button since R4 (redesign 2026-10-15, spec §11: Expand at
    /// `bw − 39`, beside History); Settings never does — its body is always tall
    /// (spec §10). Before R4 this asserted Translate had none yet.
    func testTranslateHasTheExpandButtonAndSettingsNeverDoes() async throws {
        let translate = try await shell(.player, tab: .translate)
        let button = try XCTUnwrap(
            translate.root.first(label: "Expand") ?? translate.root.first(label: "Collapse"), translate.root.dump
        )
        XCTAssertEqual(
            try body(button, in: translate), CGRect(x: translate.bodyWidth - 39, y: 8, width: 22, height: 22), accuracy: 1
        )

        let settings = try await shell(.player, tab: .settings)
        XCTAssertNil(settings.root.first(label: "Expand"))
        XCTAssertNil(settings.root.first(label: "Collapse"))
    }

    /// The Clipboard's button is the same one in the same place, beside Search
    /// (spec §9.3): the history here is empty and grown, which is when it says
    /// Collapse — Clear History on the tall Clipboard must leave a way back.
    func testTheClipboardHasTheButtonWhileItIsTall() async throws {
        let s = try await shell(.player, tab: .clipboard)
        let collapse = try body(try XCTUnwrap(s.root.first(label: "Collapse"), s.root.dump), in: s)
        XCTAssertEqual(collapse, CGRect(x: s.bodyWidth - 39, y: 8, width: 22, height: 22), accuracy: 1)
        XCTAssertNil(s.root.first(label: "Expand"))
        XCTAssertNil(s.root.first(label: "Search"), "nothing to search in an empty history")
    }

    /// The Shelf's button is the same one in the same place: here the shelf is
    /// empty and grown, which is when it says Collapse — Clear on the tall
    /// Shelf must leave a way back to 208.
    func testTheShelfHasTheButtonWhileItIsTall() async throws {
        let s = try await shell(.player, tab: .shelf)
        let collapse = try body(try XCTUnwrap(s.root.first(label: "Collapse"), s.root.dump), in: s)
        XCTAssertEqual(collapse, CGRect(x: s.bodyWidth - 39, y: 8, width: 22, height: 22), accuracy: 1)
        XCTAssertNil(s.root.first(label: "Expand"))
    }

    /// The rail's Settings rides the foot: on the tall body its icon is as far
    /// above the body's bottom as it is on the standard one, and the four top
    /// items are where they were.
    func testTheRailsFootFollowsTheBodyAndTheTopItemsStayPut() async throws {
        let standard = try await shell(.column)
        let tall = try await shell(.tall)
        func rail(_ shell: Shell, _ label: String) throws -> CGRect {
            try body(try XCTUnwrap(shell.root.first(label: label), shell.root.dump), in: shell)
        }
        for label in ["Music", "Shelf", "Clipboard", "Translate"] {
            XCTAssertEqual(try rail(standard, label), try rail(tall, label), "\(label) never moves")
        }
        let standardFoot = try rail(standard, "Settings")
        let tallFoot = try rail(tall, "Settings")
        XCTAssertEqual(tallFoot.minY - standardFoot.minY, 192, accuracy: 1, "Settings rides the foot")
        XCTAssertEqual(tallFoot.maxY, 400 - NotchGeometry.bodyBottomPadding, accuracy: 1)
    }
}

private func XCTAssertEqual(_ a: CGRect, _ b: CGRect, accuracy: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.minX, b.minX, accuracy: accuracy, "minX \(a) vs \(b)", file: file, line: line)
    XCTAssertEqual(a.minY, b.minY, accuracy: accuracy, "minY \(a) vs \(b)", file: file, line: line)
    XCTAssertEqual(a.width, b.width, accuracy: accuracy, "width \(a) vs \(b)", file: file, line: line)
    XCTAssertEqual(a.height, b.height, accuracy: accuracy, "height \(a) vs \(b)", file: file, line: line)
}
