import AppKit
import CoreAudio
import SwiftUI
import XCTest
@testable import IslaKit

/// The player as drawn, measured through the accessibility tree: where each
/// control actually lands against the board (`PlayerLayout`), with and without a
/// sung line, in English and in Russian (spec §19.6, §13).
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

    /// The content the shell gives the player: the reference body wide, and 160
    /// tall under the header row on any notch.
    private static let contentSize = CGSize(width: PlayerLayout.referenceBodyWidth, height: 160)

    /// The pane hosted at exactly the size the shell gives it.
    private func scene(
        lyrics: Bool = true, lyricBand: Bool = true, outputButton: Bool = true,
        duration: TimeInterval = 238, elapsed: TimeInterval = 9, playing: Bool = true, volume: Float? = 0.62,
        title: String = "Waiting Room", cover: Bool = false
    ) async -> Scene {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        isolated.suite.set(lyricBand, forKey: NotchViewModel.lyricBandKey)
        isolated.suite.set(outputButton, forKey: NotchViewModel.volumeAndOutputKey)
        let media = isolated.stores.media
        let track = LabFixtures.Track(
            title: title, duration: duration, elapsed: elapsed, playing: playing,
            cover: cover ? LabFixtures.cover() : nil
        )
        await LabFixtures.play(track, on: media)
        let store = isolated.stores.lyrics
        if lyrics {
            store.present(.ready(LyricTimeline(lines: Self.lines, granularity: .line)))
        }
        let pane = MediaPane(
            media: media, lyrics: store, morph: nil, audio: Self.audio(volume: volume),
            icons: SettingsFixture.macWithApps([:])
        )
        .defaultAppStorage(isolated.suite)
        let layout = PlayerLayout(hasOutputButton: outputButton)
        let root = await AXProbe.tree(of: pane, size: Self.contentSize)
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

    /// With a lyric: the transport, the Output button and the progress strip are
    /// where `PlayerLayout` — the board — puts them: each control a 42 pt target
    /// centred on its place on the row.
    func testTheControlsLandWhereTheBoardPutsThem() async throws {
        let s = await scene()
        let l = s.layout
        try assertFrame(try node(s.root, "Pause"), near: l.target(.playPause), "pause")
        try assertFrame(try node(s.root, "Previous Track"), near: l.target(.previous), "previous")
        try assertFrame(try node(s.root, "Next Track"), near: l.target(.next), "next")
        try assertFrame(try node(s.root, "Sound Output"), near: try XCTUnwrap(l.output), "output")

        // The progress strip: the bar's 7 pt and 8 of grab either side, over
        // the board's 231.3 pt.
        let slider = try node(s.root, "Playback Position", role: "AXSlider")
        try assertFrame(slider, near: l.progress.insetBy(dx: 0, dy: -8), "the progress strip")

        // The volume left the island (owner, 2026-10-16): no slider anywhere.
        XCTAssertNil(s.root.all { $0.label == "Volume" }.first, "no volume on the island\n\(s.root.dump)")
    }

    /// The sung line has the subtitle (§19.6): one button saying what is sung,
    /// in the subtitle's box; the next line is a preview and is left out of the
    /// tree, and the title reads "Title · Artist".
    func testTheSubtitleSaysTheSungLine() async throws {
        let s = await scene()
        let band = try XCTUnwrap(s.root.all { $0.label == "Lyrics" && $0.value == "Third line" }.first, s.root.dump)
        let box = MediaPane.textBox(
            x: s.layout.textLeading, baseline: s.layout.subtitleBaseline, width: s.layout.subtitleWidth,
            size: PlayerLayout.subtitleSize, weight: .semibold
        )
        try assertFrame(band, near: box, "the sung line")
        XCTAssertNil(s.root.all { $0.value == "Fourth line" || $0.label == "Fourth line" }.first,
                     "the next line is not a second stop for VoiceOver")
        let title = s.root.all { $0.label.contains("Waiting Room") || $0.value.contains("Waiting Room") || $0.title.contains("Waiting Room") }
        XCTAssertTrue(
            title.contains { ($0.label + $0.value + $0.title).contains("·") },
            "the title carries the artist while the sung line has the subtitle\n\(s.root.dump)"
        )
    }

    /// Before the first stamp the subtitle is the artist, not a line: there is
    /// no sung line to say.
    func testBeforeTheFirstLineTheSubtitleIsTheArtist() async throws {
        let s = await scene(elapsed: 0)
        XCTAssertNil(s.root.all { $0.value == "First line" || $0.value == "Third line" }.first, s.root.dump)
        XCTAssertNotNil(
            s.root.all { ($0.label + $0.value + $0.title).contains(LabFixtures.Track().artist) }.first,
            "the artist stands in the subtitle\n\(s.root.dump)"
        )
    }

    /// Lyric Band off, or Show Lyrics off, never draws the sung line: the
    /// subtitle is the artist and the title is the title alone. Nothing moves
    /// when it comes and goes — the layout is the same either way (§19.6).
    func testTheSungLineIsHiddenByItsSettingAndByShowLyricsOff() async throws {
        let off = await scene(lyricBand: false)
        XCTAssertNil(off.root.all { $0.value == "Third line" }.first, "Lyric Band off hides the sung line")
        let on = await scene()
        let a = try XCTUnwrap(try node(off.root, "Pause").frame)
        let b = try XCTUnwrap(try node(on.root, "Pause").frame)
        XCTAssertEqual(a, b, "nothing moves for the sung line")

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
    }

    // MARK: - Output Button off (§4.5)

    /// Output Button off: the button does not exist, and the other controls
    /// keep their places.
    func testOutputButtonOffRemovesIt() async throws {
        let s = await scene(outputButton: false)
        XCTAssertNil(s.root.all { $0.label == "Volume" }.first, s.root.dump)
        XCTAssertNil(s.root.all { $0.label == "Sound Output" }.first, s.root.dump)
        let band = try XCTUnwrap(s.root.all { $0.value == "Third line" }.first, "the sung line keeps its place")
        let box = MediaPane.textBox(
            x: s.layout.textLeading, baseline: s.layout.subtitleBaseline, width: s.layout.subtitleWidth,
            size: PlayerLayout.subtitleSize, weight: .semibold
        )
        try assertFrame(band, near: box, "sung line")
        try assertFrame(try node(s.root, "Pause"), near: s.layout.target(.playPause), "pause")
    }

    /// A device with no volume to give still has the Output button: choosing
    /// where the sound goes does not need a level, and the button never did.
    func testNoVolumeToGiveKeepsTheButton() async throws {
        let s = await scene(volume: nil)
        XCTAssertNil(s.root.all { $0.label == "Volume" }.first, s.root.dump)
        XCTAssertNotNil(s.root.all { $0.label == "Sound Output" }.first, s.root.dump)
    }

    /// The button says where the sound goes: its value is the current device's
    /// name, and its glyph follows the current device (`PlayerOutputButton.symbol`).
    func testTheOutputButtonNamesTheCurrentDevice() async throws {
        let s = await scene()
        let button = try node(s.root, "Sound Output")
        XCTAssertEqual(button.value, "MacBook Pro Speakers", s.root.dump)
    }

    /// Everything the player draws is a control a person can hit, in Russian
    /// with a title too long for its line: no control is cut by the content,
    /// and none is on top of another. (Text truncation is allowed where the
    /// spec says so — the title's tail.)
    func testNoControlIsCutOrCoveredInRussian() async throws {
        LabLocalization.use("ru")
        let s = await scene(title: "Всё, что тебе нужно — живое исполнение в Лужниках (Extended Version)")
        let content = CGRect(origin: .zero, size: Self.contentSize)
        let controls = s.root.all { node in
            guard node.frame != nil else { return false }
            return ["AXButton", "AXSlider"].contains(node.role)
        }
        XCTAssertGreaterThanOrEqual(controls.count, 5, s.root.dump)
        for control in controls {
            let frame = try XCTUnwrap(control.frame)
            XCTAssertTrue(content.insetBy(dx: -1, dy: -1).contains(frame), "\(control.label) \(frame) leaves \(content)")
        }
        // The row of transport controls never overlaps.
        let row = controls.filter { abs(($0.frame?.midY ?? 0) - s.layout.controlsMidY) < 2 }
            .sorted { ($0.frame?.minX ?? 0) < ($1.frame?.minX ?? 0) }
        XCTAssertGreaterThanOrEqual(row.count, 4, s.root.dump)
        for (a, b) in zip(row, row.dropFirst()) {
            let fa = try XCTUnwrap(a.frame), fb = try XCTUnwrap(b.frame)
            XCTAssertFalse(fa.insetBy(dx: 1, dy: 1).intersects(fb.insetBy(dx: 1, dy: 1)), "\(a.label) overlaps \(b.label)")
        }
    }

    // MARK: - A stream with no length (§4.6)

    /// `Music-Live-Stream`: no duration — no scrubber to find, a LIVE mark in the
    /// row's place.
    func testAStreamShowsLiveAndNoScrubber() async throws {
        let s = await scene(lyrics: false, duration: 0)
        XCTAssertNil(s.root.all { $0.label == "Playback Position" }.first, "nothing to scrub\n\(s.root.dump)")
        let live = try XCTUnwrap(s.root.all { $0.label == "LIVE" || $0.value == "LIVE" || $0.title == "LIVE" }.first, s.root.dump)
        let frame = try XCTUnwrap(live.frame)
        // The mark's plate begins where the elapsed time would; its text, which
        // is the element, is inset by the plate's 4 pt of padding.
        XCTAssertEqual(frame.minX, s.layout.elapsedLeading + 4, accuracy: 1, "the mark begins where the elapsed time would")
        XCTAssertEqual(frame.midY, s.layout.progress.midY, accuracy: 1, "on the progress row")
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

    // MARK: - Shuffle and Repeat (§19.6)

    /// Shuffle and Repeat left the player for the stage's More menu: the
    /// player's controls are the five of the board, and never these two, even
    /// when the source reports both. (Their menu rows are held in
    /// `LyricsColumnTests`.)
    func testShuffleAndRepeatAreNotOnThePlayer() async throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let media = isolated.stores.media
        await LabFixtures.play(LabFixtures.Track(cover: nil), on: media)
        media.playbackModesForTests = (shuffle: true, repeatMode: .one)
        let root = await AXProbe.tree(
            of: MediaPane(media: media, lyrics: isolated.stores.lyrics, morph: nil, audio: Self.audio(), icons: SettingsFixture.macWithApps([:]))
                .defaultAppStorage(isolated.suite),
            size: Self.contentSize
        )
        for label in ["Shuffle", "Repeat"] {
            XCTAssertNil(root.all { $0.label == label }.first, "\"\(label)\" on the player\n\(root.dump)")
        }
        XCTAssertNotNil(root.first(label: "Pause"), root.dump)
    }

    // MARK: - Nothing playing (§4.8)

    /// The empty player keeps the playing layout's frame and offers no transport.
    func testTheEmptyPlayerHasNoTransport() async throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let root = await AXProbe.tree(
            of: MediaPane(
                    media: isolated.stores.media, lyrics: isolated.stores.lyrics, morph: nil, audio: Self.audio(),
                    icons: SettingsFixture.macWithApps(Self.appleMusicAndSpotify)
                )
                .defaultAppStorage(isolated.suite),
            size: Self.contentSize
        )
        for label in ["Pause", "Play", "Previous Track", "Next Track", "Shuffle", "Repeat", "Volume", "Sound Output", "Playback Position"] {
            XCTAssertNil(root.all { $0.label == label }.first, "\"\(label)\" on an empty player\n\(root.dump)")
        }
        XCTAssertTrue(root.dump.contains(localized("Nothing is playing.")), root.dump)
        XCTAssertTrue(root.dump.contains(localized("Start a song in Music or Spotify, or open one here.")), root.dump)
    }

    /// §13: the empty player in Russian — the buttons stay inside the content,
    /// in one row, 22 tall, on the controls row's place, 8 apart, and the
    /// wrapping lines stay in their column. Nothing is truncated that the spec
    /// does not say may be.
    func testTheEmptyPlayerHoldsInRussian() async throws {
        LabLocalization.use("ru")
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let layout = PlayerLayout()
        let root = await AXProbe.tree(
            of: MediaPane(
                media: isolated.stores.media, lyrics: isolated.stores.lyrics, morph: nil, audio: Self.audio(),
                icons: SettingsFixture.macWithApps(Self.appleMusicAndSpotify)
            )
                .defaultAppStorage(isolated.suite),
            size: Self.contentSize
        )
        let content = CGRect(origin: .zero, size: Self.contentSize)
        XCTAssertTrue(root.dump.contains(localized("Start a song in Music or Spotify, or open one here.")), root.dump)
        XCTAssertTrue(root.dump.contains("Ничего не играет."), root.dump)
        let buttons = root.all { $0.role == "AXButton" }
        XCTAssertFalse(buttons.isEmpty, "a player to open\n\(root.dump)")
        let frames = PlayerLayout.emptyFrames(for: .nothingPlaying)
        for button in buttons {
            let frame = try XCTUnwrap(button.frame)
            XCTAssertTrue(content.contains(frame), "\(button.label) \(frame) leaves \(content)")
            XCTAssertEqual(frame.height, PlayerLayout.EmptyFrames.buttonHeight, accuracy: 1, "22 tall")
            XCTAssertEqual(frame.minY, frames.buttons.minY, accuracy: 1, "8 above the controls row's middle")
            XCTAssertLessThanOrEqual(frame.maxX, layout.timesTrailing + 1, "inside the times' span")
        }
        for (a, b) in zip(buttons, buttons.dropFirst()) {
            let fa = try XCTUnwrap(a.frame), fb = try XCTUnwrap(b.frame)
            XCTAssertEqual(fb.minX - fa.maxX, PlayerLayout.EmptyFrames.buttonSpacing, accuracy: 1, "8 apart")
        }
    }
}
