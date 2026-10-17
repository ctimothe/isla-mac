import CoreAudio
import SwiftUI
import XCTest
@testable import IslaKit

/// The lyrics stage as drawn, where each control actually lands against the
/// board (`StageLayout`, spec §19.6) at 480, 560 and 620, and what the open
/// panel's header carries for it and for every other surface (§19.8). It
/// replaces the lyric column and the tall page of §5.1, which §19.11 withdrew —
/// with Expand / Collapse, the More button in the header and the rail.
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
        let layout: StageLayout
    }

    /// The stage hosted at exactly the size the shell gives its content: the
    /// body's width, and 400 less the 38 pt header row.
    private func scene(width: CGFloat = 560) async -> Scene {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        isolated.suite.set(true, forKey: NotchViewModel.volumeAndOutputKey)
        let media = isolated.stores.media
        await LabFixtures.play(LabFixtures.Track(title: "Waiting Room", elapsed: 9), on: media)
        isolated.stores.lyrics.present(.ready(LyricTimeline(lines: Self.lines, granularity: .line)))
        let surface = LyricsStageSurface(
            media: media, lyrics: isolated.stores.lyrics, bodyWidth: width, audio: Self.audio()
        )
        .defaultAppStorage(isolated.suite)
        let root = await AXProbe.tree(of: surface, size: CGSize(width: width, height: SurfaceLayout.stageHeight - 38))
        return Scene(root: root, layout: StageLayout(bodyWidth: width))
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

    /// The foot: the transport's three wells centred on `bw / 2`, Output and Hide
    /// Lyrics at the right end of the tools, Hide Lyrics lit.
    func testTheStagePutsItsFootWhereTheBoardDoes() async throws {
        for width: CGFloat in [480, 560, 620] {
            let s = await scene(width: width)
            let l = s.layout
            try assertNear(try node(s.root, "Previous Track"), l.transport(.previous), "previous at \(width)")
            try assertNear(try node(s.root, "Pause"), l.transport(.playPause), "pause at \(width)")
            try assertNear(try node(s.root, "Next Track"), l.transport(.next), "next at \(width)")
            try assertNear(try node(s.root, "Sound Output"), l.tool(.output), "output at \(width)")
            let hide = try node(s.root, "Hide Lyrics", role: "AXButton")
            try assertNear(hide, l.tool(.hideLyrics), "Hide Lyrics at \(width)")
            XCTAssertEqual(try XCTUnwrap(hide.frame).width, 28, accuracy: 1)
            XCTAssertTrue(hide.selected, "the open Lyrics button is the lit one")
            XCTAssertEqual(l.tool(.hideLyrics).maxX, width - 26, "the last tool ends 26 from the right edge")
            XCTAssertNil(s.root.all { $0.label == "Volume" }.first, "no volume on the stage at \(width)")
        }
    }

    /// The sung line is where the board puts it, in the surface as drawn: its
    /// row starts at the lines' left edge (x 24) and is centred on the sung
    /// line's y (the line's top at 138, 28 tall).
    func testTheSungLineLandsWhereTheBoardPutsIt() async throws {
        for width: CGFloat in [480, 560, 620] {
            let s = await scene(width: width)
            let row = try XCTUnwrap(
                s.root.all { $0.label == "Third line" && $0.role == "AXButton" }.first, s.root.dump
            )
            let frame = try XCTUnwrap(row.frame)
            XCTAssertEqual(frame.minX, s.layout.lines.minX, accuracy: 1.5, "at \(width): \(frame)")
            XCTAssertEqual(s.layout.lines.minX, 24)
            XCTAssertEqual(frame.midY, StageLayout.readingCentre, accuracy: 3, "at \(width): \(frame)")
            XCTAssertTrue(row.selected, "it is the line being sung")
        }
    }

    /// Shuffle and Repeat left the player for the stage's More menu (§19.6),
    /// and nothing of the column or the tall page is left to find: no band
    /// button, no Expand, no rail.
    func testTheStageHasNoModeButtonsAndNothingOfTheColumn() async throws {
        let s = await scene()
        for label in ["Shuffle", "Repeat", "Expand", "Collapse", "Tabs", "Lyrics"] {
            XCTAssertNil(
                s.root.all { $0.label == label && $0.role != "AXStaticText" }.first,
                "\"\(label)\" on the stage\n\(s.root.dump)"
            )
        }
        XCTAssertNotNil(s.root.first(label: "Third line"), "the lines are the stage\n\(s.root.dump)")
    }

    /// The foot names the song: the title and, under it, the artist (§19.6).
    func testTheFootNamesTheSongAndTheArtist() async throws {
        let s = await scene()
        let named = { (text: String) in s.root.all { [$0.label, $0.value, $0.title].contains(text) }.first }
        let title = try XCTUnwrap(named("Waiting Room"), s.root.dump)
        let artist = try XCTUnwrap(named(LabFixtures.Track().artist), s.root.dump)
        try assertNear(title, s.layout.title, "title", accuracy: 2)
        try assertNear(artist, s.layout.artist, "artist", accuracy: 2)
    }

    // MARK: - The open panel

    private struct Shell {
        let root: AXNode
        let origin: CGPoint
        let vm: NotchViewModel
        let bodyWidth: CGFloat
        let header: CGFloat
    }

    private func shell(_ surface: NotchViewModel.Surface) async throws -> Shell {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        isolated.suite.set(true, forKey: NotchViewModel.volumeAndOutputKey)
        let geometry = try LabGeometry.make()
        let vm = NotchViewModel(geometry: geometry, stores: isolated.stores, defaults: isolated.suite)
        await LabFixtures.play(LabFixtures.Track(elapsed: 9), on: isolated.stores.media)
        isolated.stores.lyrics.present(.ready(LyricTimeline(lines: Self.lines, granularity: .line)))
        vm.isOpen = true
        vm.open(surface)
        let size = CGSize(width: VisualLab.windowSize.width, height: vm.geometry.windowSize.height)
        let root = await AXProbe.tree(of: NotchContentView(vm: vm).defaultAppStorage(isolated.suite), size: size)
        let width = vm.openBodySize.width
        return Shell(
            root: root, origin: CGPoint(x: (size.width - width) / 2, y: 0), vm: vm, bodyWidth: width,
            header: geometry.notchSize.height
        )
    }

    private func body(_ node: AXNode, in shell: Shell) throws -> CGRect {
        try XCTUnwrap(node.frame).offsetBy(dx: -shell.origin.x, dy: -shell.origin.y)
    }

    /// Spec §19.6, §19.16: the stage's header carries the gear at
    /// (`bw − 46`, 6), 26 × 26, where Tools stood, and the playing app's icon —
    /// and not the old More and Expand pair at `bw − 65` and `bw − 39`. More is
    /// in the foot now.
    func testTheStagesHeaderCarriesTheGearAndTheFootCarriesMore() async throws {
        let s = try await shell(.stage)
        XCTAssertEqual(s.vm.presented, .stage)
        let gearButton = try XCTUnwrap(s.root.all { $0.role == "AXButton" && $0.label == "Settings" }.first, s.root.dump)
        let tools = try body(gearButton, in: s)
        XCTAssertEqual(tools, SurfaceHeaderLayout.gear(bodyWidth: s.bodyWidth, notchHeight: s.header), accuracy: 1)
        XCTAssertNil(s.root.first(label: "Tools"), "Tools is withdrawn (§19.16)")
        XCTAssertEqual(tools.minX, s.bodyWidth - 46, accuracy: 1)
        XCTAssertNil(s.root.first(label: "Expand"))
        XCTAssertNil(s.root.first(label: "Collapse"))
        let more = try body(try XCTUnwrap(s.root.first(label: "More Lyrics Options"), s.root.dump), in: s)
        let expected = StageLayout(bodyWidth: s.bodyWidth).tool(.more).offsetBy(dx: 0, dy: s.header)
        XCTAssertEqual(more.minX, expected.minX, accuracy: 1.5)
        XCTAssertEqual(more.minY, expected.minY, accuracy: 1.5)
        XCTAssertEqual(s.vm.openBodySize.height, 400 - 38 + s.header, accuracy: 0.001)
    }

    /// The player's header carries the gear and nothing else: no lyric tools,
    /// no Expand (§19.16).
    func testThePlayersHeaderCarriesOnlyTheGear() async throws {
        let s = try await shell(.player)
        let gear = try body(try XCTUnwrap(
            s.root.all { $0.role == "AXButton" && $0.label == "Settings" }.first, s.root.dump
        ), in: s)
        XCTAssertEqual(gear.minX, s.bodyWidth - 46, accuracy: 1)
        XCTAssertNil(s.root.first(label: "Tools"))
        XCTAssertNil(s.root.first(label: "More Lyrics Options"))
        XCTAssertNil(s.root.first(label: "Expand"))
    }

    /// Every page and Settings carry the gear at (`bw − 46`, 6) and never an
    /// Expand: their bodies have one size (§19.8, §19.11, §19.16). No surface
    /// carries a Tools button any more.
    func testEveryPageAndSettingsCarryTheGearAndNoExpand() async throws {
        for surface in [NotchViewModel.Surface.tray, .clipboard, .translate, .settings] {
            let s = try await shell(surface)
            XCTAssertNil(s.root.first(label: "Tools"), "\(surface)")
            let button = try XCTUnwrap(
                s.root.all { $0.role == "AXButton" && $0.label == "Settings" }.first, "\(surface)\n\(s.root.dump)"
            )
            let tools = try body(button, in: s)
            XCTAssertEqual(tools.minX, s.bodyWidth - 46, accuracy: 1, "\(surface)")
            XCTAssertEqual(tools.size.width, 26, accuracy: 1, "\(surface)")
            XCTAssertEqual(tools.midY, s.header / 2, accuracy: 1, "\(surface)")
            XCTAssertNil(s.root.first(label: "Expand"), "\(surface)")
            XCTAssertNil(s.root.first(label: "Collapse"), "\(surface)")
        }
    }
}

private func XCTAssertEqual(_ a: CGRect, _ b: CGRect, accuracy: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.minX, b.minX, accuracy: accuracy, "minX \(a) vs \(b)", file: file, line: line)
    XCTAssertEqual(a.minY, b.minY, accuracy: accuracy, "minY \(a) vs \(b)", file: file, line: line)
    XCTAssertEqual(a.width, b.width, accuracy: accuracy, "width \(a) vs \(b)", file: file, line: line)
    XCTAssertEqual(a.height, b.height, accuracy: accuracy, "height \(a) vs \(b)", file: file, line: line)
}
