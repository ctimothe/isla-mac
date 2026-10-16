import AppKit
import CoreAudio
import SwiftUI
import XCTest
@testable import IslaKit

/// The player as drawn, measured through the accessibility tree: where each
/// control actually lands against the board (`PlayerLayout`), at 480, 560 and
/// 620, with and without a lyric, in English and in Russian (spec §4, §13).
///
/// Nothing reaches the machine: the media controller is cut from every real
/// player, the audio watch reads a value and installs nothing, the settings the
/// pane reads come from a private suite, and no control is pressed that would
/// write the system volume or output.
@MainActor
final class PlayerPaneTests: XCTestCase {
    private static let outputs: [AudioOutputs.Output] = [
        .init(id: 41, name: "MacBook Pro Speakers", transport: kAudioDeviceTransportTypeBuiltIn),
        .init(id: 42, name: "AirPods Pro", transport: kAudioDeviceTransportTypeBluetooth),
    ]

    /// The two players every Mac the empty player is drawn on has, so its
    /// buttons never depend on what the runner has installed.
    private static let appleMusicAndSpotify = ["com.apple.Music": "Music", "com.spotify.client": "Spotify"]

    private static func audio(volume: Float? = 0.62) -> AudioWatch {
        AudioWatch(read: { (outputs, 41, volume) }, readMuted: { false }, installListeners: {}, removeListeners: {})
    }

    private static let lines: [LyricsStore.Line] = [
        .init(at: 1, text: "First line"), .init(at: 4, text: "Second line"),
        .init(at: 8, text: "Third line"), .init(at: 12, text: "Fourth line"),
    ]

    override func tearDown() async throws {
        LabLocalization.uninstall()
    }

    private struct Scene {
        let root: AXNode
        let layout: PlayerLayout
    }

    /// The pane at a body width, hosted at exactly the size the shell gives it.
    private func scene(
        width: CGFloat = 560, header: CGFloat = 38,
        lyrics: Bool = true, lyricBand: Bool = true, outputButton: Bool = true,
        duration: TimeInterval = 238, playing: Bool = true, volume: Float? = 0.62,
        title: String = "Waiting Room", cover: Bool = false
    ) async -> Scene {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        isolated.suite.set(lyricBand, forKey: NotchViewModel.lyricBandKey)
        isolated.suite.set(outputButton, forKey: NotchViewModel.volumeAndOutputKey)
        let media = isolated.stores.media
        let track = LabFixtures.Track(
            title: title, duration: duration, elapsed: 9, playing: playing,
            cover: cover ? LabFixtures.cover() : nil
        )
        await LabFixtures.play(track, on: media)
        let store = isolated.stores.lyrics
        if lyrics {
            store.present(.ready(LyricTimeline(lines: Self.lines, granularity: .line)))
        }
        let pane = MediaPane(
            media: media, lyrics: store, morph: nil, headerHeight: header, audio: Self.audio(volume: volume),
            icons: SettingsFixture.macWithApps([:])
        )
        .defaultAppStorage(isolated.suite)
        let layout = PlayerLayout(
            bodyWidth: width, headerHeight: header,
            hasLyricBand: lyrics && lyricBand, hasOutputButton: outputButton
        )
        let root = await AXProbe.tree(of: pane, size: layout.paneSize)
        return Scene(root: root, layout: layout)
    }

    private func node(_ root: AXNode, _ label: String, role: String? = nil) throws -> AXNode {
        try XCTUnwrap(
            root.all { $0.label == label && (role == nil || $0.role == role) }.first,
            "no \"\(label)\"\n\(root.dump)"
        )
    }

    private func assertFrame(
        _ node: AXNode, near expected: CGRect, _ message: String, accuracy: CGFloat = 1.5,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let frame = try XCTUnwrap(node.frame, message, file: file, line: line)
        XCTAssertEqual(frame.minX, expected.minX, accuracy: accuracy, "\(message) minX \(frame)", file: file, line: line)
        XCTAssertEqual(frame.minY, expected.minY, accuracy: accuracy, "\(message) minY \(frame)", file: file, line: line)
        XCTAssertEqual(frame.width, expected.width, accuracy: accuracy, "\(message) width \(frame)", file: file, line: line)
        XCTAssertEqual(frame.height, expected.height, accuracy: accuracy, "\(message) height \(frame)", file: file, line: line)
    }

    // MARK: - Where the board puts things

    /// At 560, with a lyric: the transport, the Output and Lyrics buttons and the
    /// progress strip are where `PlayerLayout` — the board — puts them.
    func testTheControlsLandWhereTheBoardPutsThem() async throws {
        let s = await scene()
        let l = s.layout
        let play = try node(s.root, "Pause")
        try assertFrame(play, near: CGRect(x: l.inPane(l.transport).minX + 36, y: l.inPane(l.transport).minY, width: 28, height: 28), "pause")
        try assertFrame(try node(s.root, "Previous Track"), near: CGRect(origin: l.inPane(l.transport).origin, size: CGSize(width: 28, height: 28)), "previous")
        try assertFrame(try node(s.root, "Next Track"),
                        near: CGRect(x: l.inPane(l.transport).minX + 72, y: l.inPane(l.transport).minY, width: 28, height: 28), "next")
        try assertFrame(try node(s.root, "Output"), near: l.inPane(try XCTUnwrap(l.output)), "output")
        let lyricsButton = try XCTUnwrap(s.root.all { $0.label == "Lyrics" && $0.role == "AXButton" && $0.frame?.width == 26 }.first, s.root.dump)
        try assertFrame(lyricsButton, near: l.inPane(l.lyrics), "lyrics")

        // The progress strip: 22 tall, centred on the 12 pt row, and ending
        // where the remaining time begins.
        let slider = try node(s.root, "Playback Position", role: "AXSlider")
        let frame = try XCTUnwrap(slider.frame)
        XCTAssertEqual(frame.height, 22, accuracy: 0.5)
        XCTAssertEqual(frame.midY, l.inPane(l.progress).midY, accuracy: 1)
        let widths = MediaPane.timeWidths(duration: 238)
        XCTAssertEqual(frame.minX, l.inPane(l.progress).minX + widths.elapsed + 6, accuracy: 1)
        XCTAssertEqual(frame.maxX, l.inPane(l.progress).maxX - widths.remaining - 6, accuracy: 1)

        // The volume left the island (owner, 2026-10-16): no slider anywhere.
        XCTAssertNil(s.root.all { $0.label == "Volume" }.first, "no volume on the island\n\(s.root.dump)")
    }

    /// The sung line is the one button in the band, saying what is sung; the next
    /// line is a preview and is left out of the tree.
    func testTheBandSaysTheSungLine() async throws {
        let s = await scene()
        let band = try XCTUnwrap(s.root.all { $0.label == "Lyrics" && $0.value == "Third line" }.first, s.root.dump)
        try assertFrame(band, near: s.layout.inPane(s.layout.sungLine), "the sung line")
        XCTAssertNil(s.root.all { $0.value == "Fourth line" || $0.label == "Fourth line" }.first,
                     "the next line is not a second stop for VoiceOver")
    }

    /// With no lyric the band folds away and the progress row and the transport
    /// rise by exactly 20.
    func testTheBlockRisesTwentyWhenTheBandFolds() async throws {
        let with = await scene()
        let without = await scene(lyrics: false)
        let a = try XCTUnwrap(try node(with.root, "Pause").frame)
        let b = try XCTUnwrap(try node(without.root, "Pause").frame)
        XCTAssertEqual(a.minY - b.minY, PlayerLayout.noLyricRise, accuracy: 0.5)
        let sa = try XCTUnwrap(try node(with.root, "Playback Position").frame)
        let sb = try XCTUnwrap(try node(without.root, "Playback Position").frame)
        XCTAssertEqual(sa.minY - sb.minY, PlayerLayout.noLyricRise, accuracy: 0.5)
        try assertFrame(try node(without.root, "Pause"),
                        near: CGRect(x: without.layout.inPane(without.layout.transport).minX + 36,
                                     y: without.layout.inPane(without.layout.transport).minY, width: 28, height: 28),
                        "pause without a band")
    }

    /// Lyric Band off, or Show Lyrics off, takes the no-lyric positions and never
    /// draws the band.
    func testTheBandIsHiddenByItsSettingAndByShowLyricsOff() async throws {
        let off = await scene(lyricBand: false)
        XCTAssertNil(off.root.all { $0.value == "Third line" }.first, "Lyric Band off hides the band")
        let pause = try XCTUnwrap(try node(off.root, "Pause").frame)
        let playing = await scene()
        let on = try XCTUnwrap(try node(playing.root, "Pause").frame)
        XCTAssertEqual(on.minY - pause.minY, PlayerLayout.noLyricRise, accuracy: 0.5)

        // Show Lyrics off is `.disabled`, whatever the band switch says.
        XCTAssertFalse(MediaPane.drawsLyricBand(setting: true, availability: .disabled, state: .idle))
    }

    /// The pure rule behind it.
    func testWhenTheBandIsDrawn() {
        let lines = Self.lines
        let ready = LyricsAvailability.ready(LyricTimeline(lines: lines, granularity: .line))
        XCTAssertTrue(MediaPane.drawsLyricBand(setting: true, availability: ready, state: .synced(lines)))
        XCTAssertFalse(MediaPane.drawsLyricBand(setting: false, availability: ready, state: .synced(lines)), "Lyric Band off")
        XCTAssertFalse(MediaPane.drawsLyricBand(setting: true, availability: ready, state: .synced([])), "no lines")
        for availability in [LyricsAvailability.disabled, .resolving, .findingLocalLyrics, .noLocalLyrics, .cannotLookUp(.noLength)] {
            XCTAssertFalse(MediaPane.drawsLyricBand(setting: true, availability: availability, state: .none), "\(availability)")
        }
        XCTAssertEqual(MediaPane.nextBandIndex(after: 1, count: 4), 2)
        XCTAssertNil(MediaPane.nextBandIndex(after: 3, count: 4), "the last line has no next")
    }

    // MARK: - Width (§4.5, §13)

    /// `Stress-Music-480`: the Output button and the Lyrics button still on the
    /// trailing edge.
    func testAt480TheEdgeHolds() async throws {
        let s = await scene(width: 480)
        try assertFrame(try node(s.root, "Output"), near: s.layout.inPane(try XCTUnwrap(s.layout.output)), "output at 480")
        let lyricsButton = try XCTUnwrap(s.root.all { $0.label == "Lyrics" && $0.frame?.width == 26 }.first)
        try assertFrame(lyricsButton, near: s.layout.inPane(s.layout.lyrics), "lyrics at 480")
        XCTAssertEqual(try XCTUnwrap(lyricsButton.frame).maxX, s.layout.paneSize.width, accuracy: 1)
    }

    /// `Stress-Music-620`: the trailing controls ride the edge.
    func testAt620TheControlsRideTheEdge() async throws {
        let wide = await scene(width: 620)
        let lyricsButton = try XCTUnwrap(wide.root.all { $0.label == "Lyrics" && $0.frame?.width == 26 }.first)
        XCTAssertEqual(try XCTUnwrap(lyricsButton.frame).maxX, wide.layout.paneSize.width, accuracy: 1)
    }

    /// Output Button off: the button does not exist, and the band keeps its
    /// place.
    func testOutputButtonOffRemovesIt() async throws {
        let s = await scene(outputButton: false)
        XCTAssertNil(s.root.all { $0.label == "Volume" }.first, s.root.dump)
        XCTAssertNil(s.root.all { $0.label == "Output" }.first, s.root.dump)
        let band = try XCTUnwrap(s.root.all { $0.value == "Third line" }.first, "the band keeps its place")
        try assertFrame(band, near: s.layout.inPane(s.layout.sungLine), "band")
    }

    /// A device with no volume to give still has the Output button: choosing
    /// where the sound goes does not need a level, and the button never did.
    func testNoVolumeToGiveKeepsTheButton() async throws {
        let s = await scene(volume: nil)
        XCTAssertNil(s.root.all { $0.label == "Volume" }.first, s.root.dump)
        XCTAssertNotNil(s.root.all { $0.label == "Output" }.first, s.root.dump)
    }

    /// The button says where the sound goes: its value is the current device's
    /// name, and its glyph follows the current device (`PlayerOutputButton.symbol`).
    func testTheOutputButtonNamesTheCurrentDevice() async throws {
        let s = await scene()
        let button = try node(s.root, "Output")
        XCTAssertEqual(button.value, "MacBook Pro Speakers", s.root.dump)
    }

    /// Everything the player draws is a control a person can hit at the widths
    /// the panel can be and in Russian: no control is cut by the pane, and none
    /// is on top of another. (Text truncation is allowed where the spec says so —
    /// the title's tail.)
    func testNoControlIsCutOrCoveredAt480And620InRussian() async throws {
        LabLocalization.use("ru")
        for width in [CGFloat(480), 620] {
            let s = await scene(width: width, title: "Всё, что тебе нужно — живое исполнение в Лужниках (Extended Version)")
            let pane = CGRect(origin: .zero, size: s.layout.paneSize)
            let controls = s.root.all { node in
                guard node.frame != nil else { return false }
                return ["AXButton", "AXSlider"].contains(node.role)
            }.filter { $0.label != "Tabs" }
            XCTAssertGreaterThanOrEqual(controls.count, 5, s.root.dump)
            for control in controls {
                let frame = try XCTUnwrap(control.frame)
                XCTAssertTrue(pane.insetBy(dx: -1, dy: -1).contains(frame), "\(control.label) \(frame) leaves \(pane) at \(width)")
            }
            // The row of glyph buttons never overlaps (the strips — the two
            // sliders — are 22 tall and are allowed to share a row's air).
            let buttons = controls.filter { $0.role == "AXButton" && ($0.frame?.width ?? 99) <= 28 }
            for (a, b) in zip(buttons, buttons.dropFirst()) {
                let fa = try XCTUnwrap(a.frame), fb = try XCTUnwrap(b.frame)
                if abs(fa.midY - fb.midY) < 12 {
                    XCTAssertFalse(fa.insetBy(dx: 1, dy: 1).intersects(fb.insetBy(dx: 1, dy: 1)), "\(a.label) overlaps \(b.label) at \(width)")
                }
            }
        }
    }

    /// A different notch height moves nothing on screen: the same body y.
    func testANotchOf32PutsTheRowsWhereAnotchOf38Does() async throws {
        let a = await scene(header: 38)
        let b = await scene(header: 32)
        let fa = try XCTUnwrap(try node(a.root, "Pause").frame)
        let fb = try XCTUnwrap(try node(b.root, "Pause").frame)
        // Pane-local y differs by the header's difference; body y is the same.
        XCTAssertEqual((fa.minY + 38) - (fb.minY + 32), 0, accuracy: 0.5)
    }

    // MARK: - A stream with no length (§4.6)

    /// `Music-Live-Stream`: no duration — no scrubber to find, a LIVE mark in the
    /// row's place.
    func testAStreamShowsLiveAndNoScrubber() async throws {
        let s = await scene(lyrics: false, duration: 0)
        XCTAssertNil(s.root.all { $0.label == "Playback Position" }.first, "nothing to scrub\n\(s.root.dump)")
        let live = try XCTUnwrap(s.root.all { $0.label == "LIVE" || $0.value == "LIVE" || $0.title == "LIVE" }.first, s.root.dump)
        let frame = try XCTUnwrap(live.frame)
        XCTAssertEqual(frame.minX, s.layout.inPane(s.layout.progress).minX, accuracy: 1, "the mark begins the progress row")
        XCTAssertEqual(frame.height, 12, accuracy: 1)
    }

    // MARK: - Paused (§4.2)

    func testPausedShowsPlayAndTheCoverDims() async throws {
        let s = await scene(playing: false)
        XCTAssertNotNil(s.root.all { $0.label == "Play" }.first, "the play glyph replaces pause\n\(s.root.dump)")
        XCTAssertNil(s.root.all { $0.label == "Pause" }.first)
        XCTAssertEqual(Theme.playerPausedCoverBrightness, 0.8)
        XCTAssertEqual(Theme.playerPausedLyricOpacity, 0.7)
    }

    // MARK: - Shuffle and Repeat (§4.4)

    /// Kept, flanking the transport, and only when the source reports them; the
    /// tooltip is "Repeat: This Track" with the existing value strings.
    func testShuffleAndRepeatFlankTheTransportWhenReported() async throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let media = isolated.stores.media
        await LabFixtures.play(LabFixtures.Track(cover: nil), on: media)
        media.playbackModesForTests = (shuffle: true, repeatMode: .one)
        // No lyric is loaded, so the band is folded and the block sits at the
        // no-lyric positions.
        let layout = PlayerLayout(bodyWidth: 560, hasLyricBand: false)
        let root = await AXProbe.tree(
            of: MediaPane(media: media, lyrics: isolated.stores.lyrics, morph: nil, audio: Self.audio(), icons: SettingsFixture.macWithApps([:]))
                .defaultAppStorage(isolated.suite),
            size: layout.paneSize
        )
        let shuffle = try node(root, "Shuffle")
        let repeatButton = try node(root, "Repeat")
        XCTAssertEqual(shuffle.value, "On")
        XCTAssertEqual(repeatButton.value, "This Track")
        XCTAssertEqual(repeatButton.help, "Repeat: This Track")
        let transport = layout.inPane(layout.transport)
        XCTAssertLessThan(try XCTUnwrap(shuffle.frame).maxX, transport.minX + 1)
        XCTAssertGreaterThan(try XCTUnwrap(repeatButton.frame).minX, transport.maxX - 1)
        try assertFrame(shuffle, near: layout.inPane(layout.shuffle), "shuffle", accuracy: 2)
        try assertFrame(repeatButton, near: layout.inPane(layout.repeatButton), "repeat", accuracy: 2)
    }

    // MARK: - Nothing playing (§4.8)

    /// The empty tab keeps the playing layout's frame and offers no transport.
    func testTheEmptyPlayerHasNoTransport() async throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let layout = PlayerLayout(bodyWidth: 560)
        let root = await AXProbe.tree(
            of: MediaPane(
                    media: isolated.stores.media, lyrics: isolated.stores.lyrics, morph: nil, audio: Self.audio(),
                    icons: SettingsFixture.macWithApps(Self.appleMusicAndSpotify)
                )
                .defaultAppStorage(isolated.suite),
            size: layout.paneSize
        )
        for label in ["Pause", "Play", "Previous Track", "Next Track", "Shuffle", "Repeat", "Volume", "Output", "Playback Position"] {
            XCTAssertNil(root.all { $0.label == label }.first, "\"\(label)\" on an empty player\n\(root.dump)")
        }
        XCTAssertTrue(root.dump.contains(localized("Nothing is playing.")), root.dump)
        XCTAssertTrue(root.dump.contains(localized("Start a song in Music or Spotify, or open one here.")), root.dump)
    }

    /// §13: the empty player at the narrowest panel in Russian — the buttons stay
    /// inside the pane, in one row, 22 tall, and the wrapping lines stay in their
    /// 330 pt column. Nothing is truncated that the spec does not say may be.
    func testTheEmptyPlayerHoldsAt480InRussian() async throws {
        LabLocalization.use("ru")
        for width in [CGFloat(480), 620] {
            let isolated = ProbeFixtures.isolatedStores()
            defer { isolated.release() }
            let layout = PlayerLayout(bodyWidth: width)
            let root = await AXProbe.tree(
                of: MediaPane(
                    media: isolated.stores.media, lyrics: isolated.stores.lyrics, morph: nil, audio: Self.audio(),
                    icons: SettingsFixture.macWithApps(Self.appleMusicAndSpotify)
                )
                    .defaultAppStorage(isolated.suite),
                size: layout.paneSize
            )
            let pane = CGRect(origin: .zero, size: layout.paneSize)
            XCTAssertTrue(root.dump.contains(localized("Start a song in Music or Spotify, or open one here.")), root.dump)
            XCTAssertTrue(root.dump.contains("Ничего не играет."), root.dump)
            let buttons = root.all { $0.role == "AXButton" }
            XCTAssertFalse(buttons.isEmpty, "a player to open\n\(root.dump)")
            for button in buttons {
                let frame = try XCTUnwrap(button.frame)
                XCTAssertTrue(pane.contains(frame), "\(button.label) \(frame) leaves \(pane) at \(width)")
                XCTAssertEqual(frame.height, PlayerLayout.EmptyFrames.buttonHeight, accuracy: 1, "22 tall")
                XCTAssertEqual(frame.minY, layout.inPane(CGRect(x: 0, y: 132, width: 1, height: 1)).minY, accuracy: 1, "at y 132")
            }
            for (a, b) in zip(buttons, buttons.dropFirst()) {
                let fa = try XCTUnwrap(a.frame), fb = try XCTUnwrap(b.frame)
                XCTAssertEqual(fb.minX - fa.maxX, PlayerLayout.EmptyFrames.buttonSpacing, accuracy: 1, "8 apart")
            }
        }
    }
}
