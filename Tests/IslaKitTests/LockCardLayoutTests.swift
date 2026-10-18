import AppKit
import Combine
import CoreAudio
import SwiftUI
import XCTest
@testable import IslaKit

/// The lock banner and the card as numbers (redesign 2026-10-15, spec §7.1,
/// §7.3): their frames, the way one grows into the other, what takes clicks
/// in each state, and what is drawn — or not — when Rest as Banner is off.
///
/// Nothing here reaches a real player, the network, the owner's audio devices or
/// a real wallpaper: the media controller is cut from every player, the audio
/// watch reads a fixture and installs no listener, every setting comes from a
/// private suite, and no control is pressed that would move the machine.
@MainActor
final class LockCardLayoutTests: XCTestCase {
    private typealias Layout = LockCardLayout

    // MARK: - Sizes and the morph

    func testTheBannerAndTheCardHaveTheBoardsSizesAndRadii() {
        XCTAssertEqual(Layout.bannerSize, CGSize(width: 360, height: 64))
        XCTAssertEqual(Layout.bannerRadius, 22, "owner decision 4: a rounded rectangle, not a capsule")
        XCTAssertEqual(Layout.cardSize(.standard), CGSize(width: 460, height: 300))
        XCTAssertEqual(Layout.cardRadius(.standard), 30)
        XCTAssertEqual(Layout.shapeSize(.banner, .compact), Layout.bannerSize, "the banner does not follow Card Size")
        XCTAssertEqual(Layout.shapeRadius(.card, .standard), 30)
    }

    /// Compact is 420 x **236** since the redesign (it was 244): the standard
    /// card without its lyric, radius 28.
    func testTheCompactCardIs420By236() {
        XCTAssertEqual(Layout.cardSize(.compact), CGSize(width: 420, height: 236))
        XCTAssertEqual(Layout.cardRadius(.compact), 28)
        XCTAssertEqual(LockScreenCard.size(for: .compact), CGSize(width: 420, height: 236),
                       "the lock window is cut from this size")
        XCTAssertEqual(LockScreenCard.size(for: .standard), CGSize(width: 460, height: 300))
        // No lyric on it: the sung line and its translation are the standard
        // card's alone, and everything under them moves up.
        XCTAssertNil(Layout.lyric(.compact))
        XCTAssertNil(Layout.translation(.compact))
        XCTAssertEqual(Layout.progress(.compact), CGRect(x: 20, y: 110, width: 380, height: 12))
        XCTAssertEqual(Layout.transport(.compact), CGRect(x: 130, y: 132, width: 160, height: 36))
        XCTAssertEqual(Layout.footer(.compact), CGRect(x: 20, y: 188, width: 380, height: 28))
        XCTAssertEqual(Layout.chevron(pane: .player, .compact), CGRect(x: 376, y: 20, width: 24, height: 24))
        XCTAssertEqual(Layout.header(.card, pane: .player, .compact).cover, CGRect(x: 20, y: 20, width: 64, height: 64))
    }

    /// **The morph keeps its top and its centre.** The banner's top edge is the
    /// card's top edge and both are centred on the window's card area, which is
    /// what makes the cover, the title and the artist travel down and out
    /// instead of being swapped (`Lock-Frames`), at either card size.
    func testTheMorphKeepsCentreXAndTop() {
        for size in NotchViewModel.LockCardSize.allCases {
            let banner = Layout.shapeFrame(.banner, size)
            let card = Layout.shapeFrame(.card, size)
            let canvas = Layout.canvas(size)
            XCTAssertEqual(banner.minY, card.minY, "\(size): the same top edge")
            XCTAssertEqual(banner.minY, 0, "\(size): hung from the top of the card's area")
            XCTAssertEqual(banner.midX, card.midX, "\(size): the same centre x")
            XCTAssertEqual(card.midX, canvas.width / 2, "\(size): centred in the window's area")
            XCTAssertEqual(card.size, canvas, "\(size): the card is the window's whole area")
            XCTAssertLessThanOrEqual(banner.maxX, card.maxX, "\(size): the banner is drawn inside the card")
            XCTAssertGreaterThanOrEqual(banner.minX, card.minX)
        }
    }

    // MARK: - The banner

    func testTheBannerFrames() {
        let header = Layout.header(.banner, pane: .player, .standard)
        XCTAssertEqual(header.cover, CGRect(x: 12, y: 12, width: 40, height: 40))
        XCTAssertEqual(header.coverRadius, 10, "concentric with the banner's 22 at a 12 inset")
        XCTAssertEqual(header.title, CGPoint(x: 64, y: 14))
        XCTAssertEqual(header.titleSize, 13)
        XCTAssertEqual(header.artist, CGPoint(x: 64, y: 32))
        XCTAssertEqual(header.artistSize, Theme.TypeRole.body.size, "the board's 11.5 is the body role")
        XCTAssertEqual(Layout.ring, CGRect(x: 314, y: 15, width: 34, height: 34))
        XCTAssertEqual(Layout.ringLineWidth, 2)
        // The ring sits as far from the right edge as the cover from the left.
        XCTAssertEqual(Layout.bannerSize.width - Layout.ring.maxX, 12)
        // The banner ignores the pane: it has only the one face.
        XCTAssertEqual(Layout.header(.banner, pane: .output, .compact), header)
    }

    // MARK: - The card

    func testTheStandardCardFrames() {
        let header = Layout.header(.card, pane: .player, .standard)
        XCTAssertEqual(header.cover, CGRect(x: 20, y: 20, width: 64, height: 64))
        XCTAssertEqual(header.coverRadius, 10)
        XCTAssertEqual(header.title, CGPoint(x: 98, y: 28))
        XCTAssertEqual(header.titleSize, Theme.TypeRole.title.size)
        XCTAssertEqual(header.artist, CGPoint(x: 98, y: 50))
        XCTAssertEqual(header.artistSize, 13)

        XCTAssertEqual(Layout.heart(.standard), CGRect(x: 384, y: 18, width: 28, height: 28))
        XCTAssertEqual(Layout.chevron(pane: .player, .standard), CGRect(x: 420, y: 20, width: 24, height: 24))
        XCTAssertEqual(Layout.lyric(.standard), CGPoint(x: 20, y: 104))
        XCTAssertEqual(Layout.translation(.standard), CGPoint(x: 20, y: 125))
        XCTAssertEqual(Layout.progress(.standard), CGRect(x: 20, y: 158, width: 420, height: 12))
        XCTAssertEqual(Layout.transport(.standard), CGRect(x: 150, y: 190, width: 160, height: 36))

        let footer = Layout.footer(.standard)
        XCTAssertEqual(footer, CGRect(x: 20, y: 252, width: 420, height: 28))
        XCTAssertEqual(Layout.footerButton, 28)
        // The slider runs 40 to 380 of the footer, the Output button sits at 392.
        XCTAssertEqual(Layout.footerSlider(.standard).minX - footer.minX, 40)
        XCTAssertEqual(Layout.footerSlider(.standard).width, 340)
        XCTAssertEqual(footer.width - Layout.footerButton, 392)
        XCTAssertEqual(Layout.footerSlider(.standard).midY, footer.midY, "centred on the rail")
    }

    /// Title and artist stop short of the control at their right and truncate at
    /// the tail: 240 on the banner, 276 on the card with the heart and 300
    /// without (spec §7.1).
    func testTitleAndArtistStopShortOfTheControlAtTheirRight() {
        XCTAssertEqual(Layout.titleWidth(.banner, pane: .player, .standard, hasHeart: false), 240)
        XCTAssertEqual(Layout.titleWidth(.card, pane: .player, .standard, hasHeart: true), 276)
        XCTAssertEqual(Layout.titleWidth(.card, pane: .player, .standard, hasHeart: false), 300)
        XCTAssertEqual(Layout.titleWidth(.card, pane: .player, .compact, hasHeart: true), 236, "the compact card is 40 narrower")
        for hasHeart in [true, false] {
            for size in NotchViewModel.LockCardSize.allCases {
                let header = Layout.header(.card, pane: .player, size)
                let right = header.title.x + Layout.titleWidth(.card, pane: .player, size, hasHeart: hasHeart)
                let control = hasHeart ? Layout.heart(size).minX : Layout.chevron(pane: .player, size).minX
                XCTAssertLessThan(right, control, "\(size) heart \(hasHeart): the title runs into its control")
            }
        }
        let banner = Layout.header(.banner, pane: .player, .standard)
        XCTAssertLessThan(banner.title.x + 240, Layout.ring.minX)
        let lyrics = Layout.header(.card, pane: .lyrics, .standard)
        XCTAssertLessThan(
            lyrics.title.x + Layout.titleWidth(.card, pane: .lyrics, .standard, hasHeart: false),
            Layout.chevron(pane: .lyrics, .standard).minX
        )
    }

    // MARK: - The panes (spec §7.3)

    func testTheLyricsPaneHasTheSmallHeaderAndTheBackChevron() {
        let header = Layout.header(.card, pane: .lyrics, .standard)
        XCTAssertEqual(header.cover, CGRect(x: 20, y: 20, width: 34, height: 34))
        XCTAssertEqual(header.title, CGPoint(x: 64, y: 21))
        XCTAssertEqual(header.titleSize, 13)
        XCTAssertEqual(header.artist, CGPoint(x: 64, y: 38))
        XCTAssertEqual(Layout.chevron(pane: .lyrics, .standard), CGRect(x: 420, y: 20, width: 24, height: 24))
        // Four translated lines on the standard card — one before the sung line
        // and two after — and they fit the room above the footer exactly.
        XCTAssertEqual(Layout.lyricRowCount(.standard, translated: true), 4)
        XCTAssertEqual(Layout.rowsBefore(count: 4), 1)
        XCTAssertEqual(Layout.rowsBefore(count: 5), 2, "an odd window keeps the sung line in the middle")
        XCTAssertEqual(Layout.lyricsArea(.standard).minY, 68)
        XCTAssertEqual(Layout.lyricStackHeight(count: 4, translated: true), 176)
        for size in NotchViewModel.LockCardSize.allCases {
            for translated in [false, true] {
                let count = Layout.lyricRowCount(size, translated: translated)
                XCTAssertLessThanOrEqual(
                    Layout.lyricStackHeight(count: count, translated: translated), Layout.lyricsArea(size).height,
                    "\(size) translated \(translated): the rows run into the footer"
                )
            }
        }
        // The footer: Hide Lyrics, a 300 progress row and the small transport.
        XCTAssertEqual(Layout.lyricsFooterProgress(.standard).width, 300)
        XCTAssertEqual(Layout.lyricsFooterProgress(.standard).minX, 64)
        XCTAssertEqual(Layout.lyricsTransport(.standard).maxX, 450, "ends 10 from the card's edge")
    }

    func testWindowAroundTheSungLineHasOneLineBeforeItWhenItIsFour() {
        XCTAssertEqual(LockScreenCard.window(around: 3, count: 10, size: 4), [2, 3, 4, 5], "one before, two after")
        XCTAssertEqual(LockScreenCard.window(around: 0, count: 10, size: 4), [0, 1, 2, 3], "slid inside the song")
        XCTAssertEqual(LockScreenCard.window(around: 9, count: 10, size: 4), [6, 7, 8, 9])
        XCTAssertEqual(LockScreenCard.window(around: 4, count: 10, size: 5), [2, 3, 4, 5, 6], "odd windows are unchanged")
    }

    /// The Output pane is the macOS Sound module: no now-playing header, a Back
    /// chevron two points higher than the others, a volume row whose bar is the
    /// board's 380 wide between its two speaker glyphs.
    func testTheOutputPaneHasNoHeaderAndASoundVolumeRow() {
        XCTAssertFalse(Layout.header(.card, pane: .output, .standard).visible, "no now-playing header")
        XCTAssertTrue(Layout.header(.card, pane: .player, .standard).visible)
        XCTAssertEqual(Layout.chevron(pane: .output, .standard), CGRect(x: 420, y: 18, width: 24, height: 24))
        XCTAssertEqual(Layout.outputTitle, CGPoint(x: 20, y: 20))
        XCTAssertEqual(Layout.outputHeading, CGPoint(x: 20, y: 80))
        XCTAssertEqual(Layout.outputCircle, 26)

        let row = Layout.outputVolume(.standard)
        let bar = row.width - 2 * (SystemVolumeSlider.soundGlyphSlot + SystemVolumeSlider.soundSpacing)
        XCTAssertEqual(bar, Layout.outputBarWidthOnStandard, "the board's 380 between the glyphs")
        XCTAssertEqual(SystemVolumeSlider.soundTrackHeight, 8, "an 8 pt track with a knob")
        // The speaker glyphs sit at the board's 26 and 434.
        XCTAssertEqual(row.minX + SystemVolumeSlider.soundGlyphSlot / 2, 26)
        XCTAssertEqual(row.maxX - SystemVolumeSlider.soundGlyphSlot / 2, 434)
    }

    // MARK: - What takes clicks

    /// **Hit-testing follows the visible shape in both states.** The window is
    /// cut once to the card's area and the banner is drawn at the top of it, so
    /// while the song rests as a banner everything under it belongs to the
    /// password field; grown, the card takes the whole area.
    func testHitTestingFollowsTheVisibleShapeInBothStates() {
        let size = NotchViewModel.LockCardSize.standard
        let margin = LockCardWindow.shadowMargin
        let canvas = CGRect(x: margin, y: margin, width: 460, height: 300)
        let presentation = LockCardPresentation(restsAsBanner: true)
        let root = LockCardRootView(frame: CGRect(origin: .zero, size: LockCardWindow.windowSize))
        root.cardRect = canvas
        // The window's own rule (`LockCardWindow.hitArea`), on a clock the test
        // holds: the card's rect takes clicks once the grow has been drawn.
        var now: TimeInterval = 1_000
        root.hitArea = LockCardWindow.hitArea(
            following: presentation, cardSize: size, canvas: canvas, reduceMotion: { false }, now: { now })

        // AppKit's space is bottom-left: the top of the area is canvas.maxY.
        let inBanner = NSPoint(x: canvas.midX, y: canvas.maxY - 32)
        let besideBanner = NSPoint(x: canvas.minX + 10, y: canvas.maxY - 32)
        let underBanner = NSPoint(x: canvas.midX, y: canvas.maxY - 150)

        XCTAssertEqual(presentation.form, .banner)
        XCTAssertNotNil(root.hitTest(inBanner), "the banner answers")
        XCTAssertNil(root.hitTest(besideBanner), "the card's corner is empty while it is a banner")
        XCTAssertNil(root.hitTest(underBanner), "and so is everything under it")
        let banner = Layout.visibleRect(.banner, size, canvas: canvas)
        XCTAssertEqual(banner.size, Layout.bannerSize)
        XCTAssertEqual(banner.maxY, canvas.maxY, "hung from the card's top edge")
        XCTAssertEqual(banner.midX, canvas.midX)

        presentation.expand(now: now)
        now += Theme.lockCardMorphResponse
        XCTAssertNotNil(root.hitTest(inBanner))
        XCTAssertNotNil(root.hitTest(besideBanner), "the card has taken its corner")
        XCTAssertNotNil(root.hitTest(underBanner), "and the room under the banner")
        XCTAssertNil(root.hitTest(NSPoint(x: 4, y: 4)), "the margin is still the lock screen's")

        presentation.collapse()
        XCTAssertNil(root.hitTest(underBanner), "folded back, the card's room is given back")
        XCTAssertNotNil(root.hitTest(inBanner))
    }

    func testTheCompactCardsBannerIsCentredInItsNarrowerArea() {
        let canvas = CGRect(x: 12, y: 12, width: 420, height: 236)
        let banner = Layout.visibleRect(.banner, .compact, canvas: canvas)
        XCTAssertEqual(banner.midX, canvas.midX)
        XCTAssertEqual(banner.maxY, canvas.maxY)
        XCTAssertTrue(canvas.contains(banner))
    }

    /// **The banner's rect holds until the grow has been drawn** (review
    /// 2026-10-15). `form` flips to `.card` the instant `expand()` runs, and the
    /// shape then takes 0.36 s to grow; the whole 460 x 300 took clicks meanwhile,
    /// so a quick second click below the banner hit a half-faded control outside
    /// the glass. The rule: (form, time since the grow began, settle) -> the shape
    /// that takes clicks. Folding back switches at once.
    func testTheHitAreaStaysTheBannersUntilTheGrowIsDrawn() {
        let settle = Layout.morphSettle(reduceMotion: false)
        XCTAssertEqual(settle, Theme.lockCardMorphResponse, "the spring's 0.36 s")
        XCTAssertEqual(Layout.morphSettle(reduceMotion: true), Theme.reducedMotionDuration, "the 0.24 crossfade")

        XCTAssertEqual(Layout.hitForm(.banner, sinceExpand: nil, settle: settle), .banner)
        XCTAssertEqual(Layout.hitForm(.banner, sinceExpand: 5, settle: settle), .banner, "a banner is a banner")
        XCTAssertEqual(Layout.hitForm(.card, sinceExpand: nil, settle: settle), .card,
                       "a card that never was a banner (Rest as Banner off) takes the card's rect")
        XCTAssertEqual(Layout.hitForm(.card, sinceExpand: 0, settle: settle), .banner, "growing: not yet")
        XCTAssertEqual(Layout.hitForm(.card, sinceExpand: settle - 0.001, settle: settle), .banner)
        XCTAssertEqual(Layout.hitForm(.card, sinceExpand: settle, settle: settle), .card, "drawn")
        XCTAssertEqual(Layout.hitForm(.card, sinceExpand: 0.30, settle: Layout.morphSettle(reduceMotion: true)),
                       .card, "Reduce Motion is drawn sooner: 0.24 s")
    }

    func testAQuickSecondClickBelowTheGrowingBannerGoesToTheLockScreen() {
        let size = NotchViewModel.LockCardSize.standard
        let canvas = CGRect(x: 12, y: 12, width: 460, height: 300)
        let presentation = LockCardPresentation(restsAsBanner: true)
        let root = LockCardRootView(frame: CGRect(origin: .zero, size: LockCardWindow.windowSize))
        root.cardRect = canvas
        var now: TimeInterval = 50
        root.hitArea = LockCardWindow.hitArea(
            following: presentation, cardSize: size, canvas: canvas, reduceMotion: { false }, now: { now })
        let underBanner = NSPoint(x: canvas.midX, y: canvas.maxY - 150)
        let inBanner = NSPoint(x: canvas.midX, y: canvas.maxY - 32)

        presentation.expand(now: now)
        XCTAssertEqual(presentation.form, .card, "the state has flipped")
        now += 0.10
        XCTAssertNil(root.hitTest(underBanner), "but the glass has not grown there yet")
        XCTAssertNotNil(root.hitTest(inBanner))
        now += 0.30
        XCTAssertNotNil(root.hitTest(underBanner), "0.40 s on, the card is drawn and answers")

        presentation.collapse()
        XCTAssertNil(root.hitTest(underBanner), "folding gives the room back at once")
        presentation.expand(now: now)
        now += 0.10
        XCTAssertNil(root.hitTest(underBanner), "and a second grow waits again")
    }

    // MARK: - Rest as Banner

    func testRestAsBannerIsOnUntilSwitchedOff() {
        let suite = makeSuite()
        XCTAssertTrue(NotchViewModel.restAsBannerEnabled(in: suite), "spec §14: on by default")
        suite.set(false, forKey: NotchViewModel.restAsBannerKey)
        XCTAssertFalse(NotchViewModel.restAsBannerEnabled(in: suite))
        suite.set(true, forKey: NotchViewModel.restAsBannerKey)
        XCTAssertTrue(NotchViewModel.restAsBannerEnabled(in: suite))
        XCTAssertEqual(NotchViewModel.restAsBannerKey, "lock.restAsBanner")
    }

    func testTheSongRestsAsABannerAndTheChevronFoldsItBack() {
        let presentation = LockCardPresentation(restsAsBanner: true)
        XCTAssertEqual(presentation.form, .banner)
        XCTAssertTrue(presentation.showsCollapse)

        presentation.expand()
        XCTAssertEqual(presentation.form, .card)
        presentation.pane = .lyrics
        presentation.collapse()
        XCTAssertEqual(presentation.form, .banner)
        XCTAssertEqual(presentation.pane, .player, "the card comes back on its first pane")
    }

    /// With Rest as Banner off there is no banner and no chevron: the card shows
    /// directly, as it did before the redesign.
    func testRestAsBannerOffShowsTheCardDirectlyWithNoChevron() {
        let presentation = LockCardPresentation(restsAsBanner: false)
        XCTAssertEqual(presentation.form, .card)
        XCTAssertFalse(presentation.showsCollapse)
        presentation.collapse()
        XCTAssertEqual(presentation.form, .card, "there is no banner to fold into")
    }

    // MARK: - Drawn: the banner, the card, the chevron

    private static let outputs: [AudioOutputs.Output] = [
        .init(id: 41, name: "MacBook Pro Speakers", transport: kAudioDeviceTransportTypeBuiltIn),
        .init(id: 42, name: "AirPods Pro", transport: kAudioDeviceTransportTypeBluetooth),
    ]

    private static func audio() -> AudioWatch {
        AudioWatch(read: { (outputs, 41, 0.62) }, readMuted: { false }, installListeners: {}, removeListeners: {})
    }

    private func card(
        _ presentation: LockCardPresentation, _ isolated: ProbeStores
    ) async -> some View {
        await LabFixtures.play(LabFixtures.Track(elapsed: 27), on: isolated.stores.media)
        return LockScreenCard(
            media: isolated.stores.media, lyrics: isolated.stores.lyrics, audio: Self.audio(),
            presentation: presentation
        )
        .defaultAppStorage(isolated.suite)
    }

    /// The banner is the song's cover, title and artist and a play button in a
    /// ring — and none of the card's controls, which VoiceOver must not find
    /// behind it either.
    func testTheBannerHoldsTheSongAndOneButtonAndNothingOfTheCard() async throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let root = await AXProbe.tree(
            of: await card(LockCardPresentation(restsAsBanner: true), isolated),
            size: LockScreenCard.size(for: .standard)
        )

        XCTAssertNotNil(root.first(label: "Pause"), "the ring's play/pause\n\(root.dump)")
        for absent in ["Playback Position", "Previous Track", "Next Track", "Collapse", "Lyrics", "Volume"] {
            XCTAssertNil(root.first(label: absent), "\"\(absent)\" is on the banner\n\(root.dump)")
        }
        XCTAssertNotNil(
            root.all(role: "AXButton").first { $0.label.contains(LabFixtures.Track().title) },
            "the banner is one button named for the song\n\(root.dump)"
        )
        // And only one element for the song (review 2026-10-15): the button's label
        // is "title, artist", so a text element for each beside it made VoiceOver
        // read the song twice.
        let track = LabFixtures.Track()
        let texts = root.all { node in
            node.role == "AXStaticText"
                && [track.title, track.artist].contains(where: { node.label == $0 || node.value == $0 })
        }
        XCTAssertTrue(texts.isEmpty, "title and artist are the button's label alone\n\(root.dump)")
    }

    /// The card, in contrast, reads its title and artist as text of their own.
    func testTheCardKeepsTheTitleAndArtistAsText() async throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let root = await AXProbe.tree(
            of: await card(LockCardPresentation(restsAsBanner: false), isolated),
            size: LockScreenCard.size(for: .standard)
        )
        let track = LabFixtures.Track()
        XCTAssertFalse(root.all { $0.role == "AXStaticText" && ($0.label == track.title || $0.value == track.title) }.isEmpty,
                       root.dump)
    }

    func testTheCardHasTheChevronOnlyWhenItRestsAsABanner() async throws {
        let resting = ProbeFixtures.isolatedStores()
        defer { resting.release() }
        let growing = LockCardPresentation(restsAsBanner: true)
        growing.expand()
        let withChevron = await AXProbe.tree(
            of: await card(growing, resting), size: LockScreenCard.size(for: .standard)
        )
        XCTAssertNotNil(withChevron.first(label: "Collapse"), withChevron.dump)
        XCTAssertNotNil(withChevron.first(label: "Playback Position"), "the card has its scrubber\n\(withChevron.dump)")

        let direct = ProbeFixtures.isolatedStores()
        defer { direct.release() }
        let withoutChevron = await AXProbe.tree(
            of: await card(LockCardPresentation(restsAsBanner: false), direct),
            size: LockScreenCard.size(for: .standard)
        )
        XCTAssertNil(withoutChevron.first(label: "Collapse"), "Rest as Banner off has no chevron\n\(withoutChevron.dump)")
        XCTAssertNotNil(withoutChevron.first(label: "Playback Position"), withoutChevron.dump)
    }

    // MARK: - Translation demand (spec §5.3, review 2026-10-15)

    /// A service whose engine answers `"«text»"`, reading a private suite, with
    /// Translate Lyrics on or off. Nothing leaves the process.
    private func makeService(translating: Bool, defaults: UserDefaults) -> (LyricTranslation, [LyricsStore.Line]) {
        if translating {
            defaults.set(true, forKey: NotchViewModel.translateLyricsKey)
            defaults.set(TranslationLanguage.russian.code, forKey: NotchViewModel.translateTargetKey)
        }
        let service = LyricTranslation(
            defaults: defaults,
            backend: LyricTranslation.Backend(
                capabilities: { _ in Translator.Capabilities(systemInstalled: true, systemSupported: true) },
                system: { texts, _ in texts.map { "«\($0)»" } },
                model: { texts, _ in texts.map { "«\($0)»" } },
                online: { text, _ in "«\(text)»" },
                detect: { _ in .english },
                onlineEnabled: { false },
                onlineAvailable: { false }
            ),
            preferredLanguages: ["en"]
        )
        let lines: [LyricsStore.Line] = [
            .init(at: 4, text: "in the dark by the camera"),
            .init(at: 8, text: "humming everything you need"),
            .init(at: 12, text: "up here, up here"),
        ]
        service.present(lines: lines)
        return (service, lines)
    }

    /// The card raises its own demand when it is the form on screen and lowers it
    /// when it folds, with the epoch it raised under — so no translation is ever
    /// made for a banner, and one is made for a card.
    func testTheCardRaisesAndLowersTranslationDemand() {
        let (service, _) = makeService(translating: true, defaults: makeSuite())
        XCTAssertFalse(service.isPresentedSomewhere)

        let presentation = LockCardPresentation(restsAsBanner: true)
        presentation.attach(translation: service)
        XCTAssertFalse(service.isPresentedSomewhere, "a banner draws no lyric and asks for no translation")

        presentation.expand()
        XCTAssertTrue(service.isPresentedSomewhere, "the card is on screen")
        presentation.expand()
        presentation.collapse()
        XCTAssertFalse(service.isPresentedSomewhere, "folded back, the demand is lowered once and fully")

        presentation.expand()
        XCTAssertTrue(service.isPresentedSomewhere)
        presentation.end()
        XCTAssertFalse(service.isPresentedSomewhere, "dismissed")
        presentation.expand()
        XCTAssertFalse(service.isPresentedSomewhere, "a dismissed card never raises it again")
    }

    func testACardThatOpensAsTheCardRaisesItAtPresent() {
        let (service, _) = makeService(translating: true, defaults: makeSuite())
        let presentation = LockCardPresentation(restsAsBanner: false)
        presentation.attach(translation: service)
        XCTAssertTrue(service.isPresentedSomewhere)
        presentation.end()
        XCTAssertFalse(service.isPresentedSomewhere)
    }

    /// A rebuild of the panel resets the demand; the card's late lowering names an
    /// older epoch and must not take the rebuilt panel's registration away.
    func testALateLoweringAfterARebuildLeavesTheNewRegistrationAlone() {
        let (service, _) = makeService(translating: true, defaults: makeSuite())
        let presentation = LockCardPresentation(restsAsBanner: false)
        presentation.attach(translation: service)
        XCTAssertTrue(service.isPresentedSomewhere)

        service.resetDemand()
        XCTAssertFalse(service.isPresentedSomewhere)
        service.setDemand(.lockCard, true)
        XCTAssertTrue(service.isPresentedSomewhere)

        presentation.end()
        XCTAssertTrue(service.isPresentedSomewhere, "the old card's lowering named the old epoch")
    }

    /// **A rebuild while locked must not lose the card's demand** (review
    /// 2026-10-15, both reviewers). A display change while locked rebuilds the
    /// panel, `rebuild()` calls `resetDemand()`, and the lock window then presents
    /// again. `raisedEpoch` still held the old epoch, the card thought itself
    /// registered, and with Rest as Banner off nothing raised it again until unlock.
    /// This goes through `representExisting`, the method `present()`'s re-present
    /// branch is made of (re-review: the test used to call the resync itself, so
    /// deleting it from `present` stayed green).
    func testTheCardRaisesItsDemandAgainAfterARebuildWhileLocked() {
        let (service, _) = makeService(translating: true, defaults: makeSuite())
        let window = LockCardWindow()
        let presentation = LockCardPresentation(restsAsBanner: false)
        window.presentation = presentation
        presentation.attach(translation: service)
        XCTAssertTrue(service.isPresentedSomewhere, "the card opened as the card")

        var steps: [String] = []
        service.resetDemand()                      // NotchController.rebuild()
        XCTAssertFalse(service.isPresentedSomewhere, "the registration went with the rebuild")
        window.representExisting(
            refreshTone: { steps.append("tone"); XCTAssertTrue(service.isPresentedSomewhere, "resynced first") },
            placeWindow: { steps.append("window") }
        )
        XCTAssertTrue(service.isPresentedSomewhere, "and the card has asked again")
        XCTAssertEqual(steps, ["tone", "window"], "the wallpaper and the window are still its job")

        window.representExisting(refreshTone: {}, placeWindow: {})
        service.setDemand(.lockCard, false)
        XCTAssertFalse(service.isPresentedSomewhere, "one registration, not two")

        presentation.end()
        XCTAssertFalse(service.isPresentedSomewhere)
    }

    func testABannerThatGrowsAfterARebuildRaisesUnderTheNewEpoch() {
        let (service, _) = makeService(translating: true, defaults: makeSuite())
        let presentation = LockCardPresentation(restsAsBanner: true)
        presentation.attach(translation: service)
        presentation.expand()
        XCTAssertTrue(service.isPresentedSomewhere)
        service.resetDemand()
        presentation.resync()
        XCTAssertTrue(service.isPresentedSomewhere, "raised again under the epoch the rebuild made")
        presentation.collapse()
        XCTAssertFalse(service.isPresentedSomewhere, "and the fold lowers it under that epoch, not the old one")
    }

    // MARK: - Where the card asks for translations (review 2026-10-15)

    /// The compact card's player pane has no lyric, so it has nothing to
    /// translate; the lyric-bearing panes (the standard player, the Lyrics pane) do,
    /// and only with a song.
    func testTheCardAsksForTranslationsOnlyWhereItDrawsAndOnlyWithASong() {
        func wants(
            _ card: Bool, size: NotchViewModel.LockCardSize, pane: LockScreenCard.Pane, track: Bool
        ) -> Bool {
            LockCardPresentation(restsAsBanner: !card, pane: pane, size: size, hasTrack: track).wantsTranslation
        }
        XCTAssertTrue(wants(true, size: .standard, pane: .player, track: true))
        XCTAssertTrue(wants(true, size: .standard, pane: .lyrics, track: true))
        XCTAssertTrue(wants(true, size: .compact, pane: .lyrics, track: true), "the Lyrics pane draws them at any size")
        XCTAssertTrue(wants(true, size: .compact, pane: .output, track: true), "the Output pane keeps it, at any size")
        XCTAssertTrue(wants(true, size: .standard, pane: .output, track: true))
        XCTAssertFalse(wants(true, size: .compact, pane: .player, track: true), "the compact player draws no lyric")
        XCTAssertFalse(wants(true, size: .standard, pane: .player, track: false), "no song, nothing to translate")
        XCTAssertFalse(wants(true, size: .compact, pane: .lyrics, track: false))
        XCTAssertFalse(wants(false, size: .standard, pane: .player, track: true), "a banner draws no lyric")
    }

    func testTheDemandFollowsThePaneTheSizeAndTheSong() {
        let (service, _) = makeService(translating: true, defaults: makeSuite())
        let presentation = LockCardPresentation(restsAsBanner: false, size: .compact, hasTrack: false)
        presentation.attach(translation: service)
        XCTAssertFalse(service.isPresentedSomewhere, "a lock with no track raises nothing, Rest as Banner or not")

        presentation.hasTrack = true
        XCTAssertFalse(service.isPresentedSomewhere, "a compact player pane still has no lyric")
        presentation.pane = .lyrics
        XCTAssertTrue(service.isPresentedSomewhere, "the Lyrics pane does")
        presentation.pane = .player
        XCTAssertFalse(service.isPresentedSomewhere)
        presentation.size = .standard
        XCTAssertTrue(service.isPresentedSomewhere, "and a standard card's player does")
        presentation.hasTrack = false
        XCTAssertFalse(service.isPresentedSomewhere, "the song ended")
        presentation.hasTrack = true
        presentation.end()
        XCTAssertFalse(service.isPresentedSomewhere)
    }

    /// **A visit to Output must not cancel a batch in flight** (re-review
    /// 2026-10-15): the compact card's Output pane dropped the demand, against its
    /// own comment, so Lyrics -> Output -> Lyrics lowered it and raised it again.
    func testLyricsToOutputAndBackKeepsTheDemandRaisedOnTheCompactCard() {
        let (service, _) = makeService(translating: true, defaults: makeSuite())
        let presentation = LockCardPresentation(restsAsBanner: false, pane: .lyrics, size: .compact, hasTrack: true)
        presentation.attach(translation: service)
        XCTAssertTrue(service.isPresentedSomewhere)
        let epoch = service.demandEpoch
        presentation.pane = .output
        XCTAssertTrue(service.isPresentedSomewhere, "Output keeps it")
        presentation.pane = .lyrics
        XCTAssertTrue(service.isPresentedSomewhere)
        XCTAssertEqual(service.demandEpoch, epoch)
        presentation.end()
        XCTAssertFalse(service.isPresentedSomewhere)
    }

    /// The window feeds the presentation from the media controller: no song at
    /// present means no demand, and one started mid-lock raises it.
    func testTheDemandIsRaisedForASongStartedMidLock() async {
        let (service, _) = makeService(translating: true, defaults: makeSuite())
        let presentation = LockCardPresentation(restsAsBanner: false, hasTrack: false)
        presentation.attach(translation: service)
        XCTAssertFalse(service.isPresentedSomewhere, "no song yet")
        // The window's own sink (`LockCardWindow.follow`), fed by a subject.
        let tracks = PassthroughSubject<String?, Never>()
        let following = LockCardWindow.follow(tracks, presentation: presentation)
        tracks.send(nil)
        XCTAssertFalse(service.isPresentedSomewhere)
        tracks.send("a song")
        XCTAssertTrue(service.isPresentedSomewhere, "a song started mid-lock raises it")
        tracks.send("another song")
        XCTAssertTrue(service.isPresentedSomewhere, "a skip never passes through nil")
        tracks.send(nil)
        XCTAssertFalse(service.isPresentedSomewhere, "the song ended")
        following.cancel()
        tracks.send("late")
        XCTAssertFalse(service.isPresentedSomewhere, "a cancelled follow feeds nothing")
        presentation.end()
    }

    /// Ending the lock while the morph is still in flight lowers the demand now:
    /// the grow's animation has nothing to do with it.
    func testDismissEndsTheDemandWhileTheMorphIsInFlight() {
        let (service, _) = makeService(translating: true, defaults: makeSuite())
        let presentation = LockCardPresentation(restsAsBanner: true)
        presentation.attach(translation: service)
        presentation.expand(now: 10)
        XCTAssertTrue(service.isPresentedSomewhere)
        XCTAssertEqual(presentation.hitForm(reduceMotion: false, now: 10.1), .banner, "the morph is in flight")
        presentation.end()
        XCTAssertFalse(service.isPresentedSomewhere, "dismissed mid-morph")
        presentation.expand(now: 11)
        presentation.collapse()
        XCTAssertFalse(service.isPresentedSomewhere, "and nothing later raises it")
    }

    /// The translation line under the sung one exists only when Translate Lyrics
    /// is on: the service answers `translation(atLine:)` for the card, and with
    /// the switch off — or before the batch has landed — there is nothing to draw.
    func testTheTranslationLineIsThereOnlyWhenLyricTranslationIsOn() async {
        let on = makeService(translating: true, defaults: makeSuite())
        let presentation = LockCardPresentation(restsAsBanner: false)
        presentation.attach(translation: on.0)
        XCTAssertNil(on.0.translation(atLine: 1), "a read starts nothing and waits for nothing")
        await on.0.settled()
        XCTAssertEqual(on.0.translation(atLine: 1), "«humming everything you need»")
        presentation.end()

        let off = makeService(translating: false, defaults: makeSuite())
        let shown = LockCardPresentation(restsAsBanner: false)
        shown.attach(translation: off.0)
        await off.0.settled()
        XCTAssertNil(off.0.translation(atLine: 1), "Translate Lyrics is off: no line")
        shown.end()
    }

    /// And it is drawn: the card under the sung line, in its own place.
    func testTheCardDrawsTheTranslationUnderTheSungLine() async throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let (translation, lines) = makeService(translating: true, defaults: isolated.suite)
        let presentation = LockCardPresentation(restsAsBanner: false)
        presentation.attach(translation: translation)
        await translation.settled()
        isolated.stores.lyrics.present(.ready(LyricTimeline(lines: lines, granularity: .line)))
        await LabFixtures.play(LabFixtures.Track(elapsed: 9), on: isolated.stores.media)

        let card = LockScreenCard(
            media: isolated.stores.media, lyrics: isolated.stores.lyrics, audio: Self.audio(),
            translation: translation, presentation: presentation
        )
        .defaultAppStorage(isolated.suite)
        let root = await AXProbe.tree(of: card, size: LockScreenCard.size(for: .standard))
        XCTAssertTrue(root.dump.contains("«humming everything you need»"), root.dump)
        presentation.end()

        let plain = ProbeFixtures.isolatedStores()
        defer { plain.release() }
        let (silent, same) = makeService(translating: false, defaults: plain.suite)
        plain.stores.lyrics.present(.ready(LyricTimeline(lines: same, granularity: .line)))
        await LabFixtures.play(LabFixtures.Track(elapsed: 9), on: plain.stores.media)
        let without = LockScreenCard(
            media: plain.stores.media, lyrics: plain.stores.lyrics, audio: Self.audio(),
            translation: silent, presentation: LockCardPresentation(restsAsBanner: false)
        )
        .defaultAppStorage(plain.suite)
        let bare = await AXProbe.tree(of: without, size: LockScreenCard.size(for: .standard))
        XCTAssertFalse(bare.dump.contains("«"), bare.dump)
    }

    // MARK: - Fixtures

    private func makeSuite(_ name: String = #function) -> UserDefaults {
        let suiteName = "com.ctimothe.isla.lockcardlayout.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }
}
