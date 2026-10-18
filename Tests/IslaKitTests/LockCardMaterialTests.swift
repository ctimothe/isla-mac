import AppKit
import Dispatch
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import IslaKit

/// What the lock card is made of (redesign 2026-10-15, spec §7.2): Automatic's
/// opacity from the wallpaper behind the card, the default that applies only
/// when nothing is stored, Reduce Transparency making every style Solid, and
/// the privacy gate that stays in front of every wallpaper read.
///
/// No test here opens the owner's wallpaper or reads the standard defaults
/// domain: pictures are drawn into a temporary folder and the gate is opened or
/// shut by the test, and every setting comes from a private suite.
@MainActor
final class LockCardMaterialTests: XCTestCase {
    // MARK: - Automatic's alpha

    /// The four wallpapers the board measured: Aerial 0.03 → 0.90, Pro Black
    /// 0.09 → 0.88, Sonoma 0.36 → 0.84, Sky Blue 0.41 → 0.86.
    func testAutomaticAlphaAtTheFourReferenceLuminances() {
        XCTAssertEqual(LockCardMaterial.automaticAlpha(luminance: 0.03), 0.90, accuracy: 0.01)
        XCTAssertEqual(LockCardMaterial.automaticAlpha(luminance: 0.09), 0.88, accuracy: 0.01)
        XCTAssertEqual(LockCardMaterial.automaticAlpha(luminance: 0.36), 0.84, accuracy: 0.01)
        XCTAssertEqual(LockCardMaterial.automaticAlpha(luminance: 0.41), 0.86, accuracy: 0.01)
    }

    /// The formula itself, term by term: a lift over a dark wallpaper that
    /// reaches 0.06 at L = 0.03 and is gone by 0.30, and a lift over a bright one
    /// that starts at 0.36 and would reach 0.12 at 0.66 — but the ceiling stops
    /// the card at 0.92, which it reaches at 0.56.
    func testTheFormulaIsTheSpecsAtTheEdgesOfItsTerms() {
        XCTAssertEqual(LockCardMaterial.automaticAlpha(luminance: 0.30), 0.84, accuracy: 1e-9, "the dark term ends at 0.30")
        XCTAssertEqual(LockCardMaterial.automaticAlpha(luminance: 0.33), 0.84, accuracy: 1e-9, "and neither term lifts between 0.30 and 0.36")
        XCTAssertEqual(LockCardMaterial.automaticAlpha(luminance: 0.46), 0.84 + 0.04, accuracy: 1e-9)
        XCTAssertEqual(LockCardMaterial.automaticAlpha(luminance: 0.56), 0.92, accuracy: 1e-9)
        XCTAssertEqual(LockCardMaterial.automaticAlpha(luminance: 0.66), 0.92, accuracy: 1e-9, "clamped, not 0.96")
    }

    func testTheAlphaNeverLeavesItsFloorAndCeiling() {
        XCTAssertEqual(LockCardMaterial.floorAlpha, 0.84, "owner decision 5: mostly solid")
        XCTAssertEqual(LockCardMaterial.ceilingAlpha, 0.92)
        for step in 0...200 {
            let luminance = Double(step) / 200
            let alpha = LockCardMaterial.automaticAlpha(luminance: luminance)
            XCTAssertGreaterThanOrEqual(alpha, 0.84, "L \(luminance)")
            XCTAssertLessThanOrEqual(alpha, 0.92, "L \(luminance)")
        }
        // Past the ends of the scale, and a pure black wallpaper (L = 0 would be
        // 0.9067 unclamped): still inside them.
        XCTAssertEqual(LockCardMaterial.automaticAlpha(luminance: 1), 0.92, "a white wallpaper hits the ceiling")
        XCTAssertEqual(LockCardMaterial.automaticAlpha(luminance: 5), 0.92, "off the scale clamps to it")
        XCTAssertEqual(LockCardMaterial.automaticAlpha(luminance: -1), LockCardMaterial.automaticAlpha(luminance: 0))
        XCTAssertEqual(LockCardMaterial.automaticAlpha(luminance: 0), 0.84 + 0.06 * (0.30 / 0.27), accuracy: 1e-9)
    }

    /// Not knowing the wallpaper costs the card nothing it would not have on an
    /// ordinary one: unknown is Sonoma's 0.36, which is exactly the floor.
    func testAnUnknownWallpaperIsTheFloor() {
        XCTAssertEqual(LockCardMaterial.unknownLuminance, 0.36)
        XCTAssertEqual(LockCardMaterial.automaticAlpha(luminance: nil), 0.84)
        XCTAssertEqual(
            LockCardMaterial.automaticAlpha(luminance: nil),
            LockCardMaterial.automaticAlpha(luminance: LockCardMaterial.unknownLuminance)
        )
    }

    // MARK: - The default style

    private func suite(_ name: String = #function) -> UserDefaults {
        let suiteName = "com.ctimothe.isla.lockcardmaterial.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    /// Automatic is the default only when nothing is stored; a person who chose
    /// Transparent, Tinted or Solid keeps their choice, and Tinted's stored word
    /// is still "glass" (spec §7.2, §14).
    func testAutomaticIsTheDefaultOnlyWhenNothingIsStored() {
        let defaults = suite()
        XCTAssertEqual(NotchViewModel.lockCardStyle(in: defaults), .automatic)
        XCTAssertEqual(NotchViewModel.LockCardStyle.automatic.rawValue, "automatic")
        XCTAssertEqual(NotchViewModel.lockCardStyleKey, "lockCardStyle")

        for stored in [NotchViewModel.LockCardStyle.clear, .glass, .solid] {
            defaults.set(stored.rawValue, forKey: NotchViewModel.lockCardStyleKey)
            XCTAssertEqual(NotchViewModel.lockCardStyle(in: defaults), stored, "a stored \(stored.rawValue) is kept")
        }
        defaults.set("automatic", forKey: NotchViewModel.lockCardStyleKey)
        XCTAssertEqual(NotchViewModel.lockCardStyle(in: defaults), .automatic)
        // A word this build does not know is not a choice: the default.
        defaults.set("frosted", forKey: NotchViewModel.lockCardStyleKey)
        XCTAssertEqual(NotchViewModel.lockCardStyle(in: defaults), .automatic)
        defaults.removeObject(forKey: NotchViewModel.lockCardStyleKey)
        XCTAssertEqual(NotchViewModel.lockCardStyle(in: defaults), .automatic)
    }

    /// Automatic is the first choice in Settings, and every style has a title in
    /// the tables.
    func testAutomaticLeadsTheChoicesAndEveryStyleIsTitled() {
        XCTAssertEqual(NotchViewModel.LockCardStyle.allCases.first, .automatic)
        XCTAssertEqual(NotchViewModel.LockCardStyle.allCases, [.automatic, .clear, .glass, .solid])
        XCTAssertEqual(NotchViewModel.LockCardStyle.automatic.title, localized("Automatic"))
        XCTAssertEqual(NotchViewModel.LockCardStyle.clear.title, localized("Transparent"))
        XCTAssertEqual(NotchViewModel.LockCardStyle.glass.title, localized("Tinted"))
        XCTAssertEqual(NotchViewModel.LockCardStyle.solid.title, localized("Solid"))
    }

    // MARK: - Reduce Transparency

    /// Reduce Transparency draws every style as Solid — the style the card is
    /// drawn in, the surface it asks the glass for, and no cover light over it.
    func testReduceTransparencyMakesEveryStyleSolid() {
        for style in NotchViewModel.LockCardStyle.allCases {
            XCTAssertEqual(
                LockCardMaterial.effectiveStyle(stored: style, reduceTransparency: true), .solid,
                "\(style) must draw as Solid under Reduce Transparency"
            )
            XCTAssertEqual(
                LockCardMaterial.effectiveStyle(stored: style, reduceTransparency: false), style,
                "and is itself otherwise"
            )
            for hasArtwork in [false, true] {
                let route = LockScreenCard.glassRouting(style: style, hasArtwork: hasArtwork, reduceTransparency: true)
                XCTAssertTrue(route.solid, "\(style) artwork \(hasArtwork): the panel, not the glass")
                XCTAssertFalse(route.samplesBackdrop)
                XCTAssertTrue(route.preferDrawn)
            }
        }
        // Without the setting the routing is what it was.
        XCTAssertFalse(LockScreenCard.glassRouting(style: .automatic, hasArtwork: true).solid)
        XCTAssertTrue(LockScreenCard.glassRouting(style: .automatic, hasArtwork: false).samplesBackdrop)
        XCTAssertTrue(LockScreenCard.glassRouting(style: .solid, hasArtwork: false).solid)
    }

    // MARK: - The material, per spec §7.2

    private typealias Decision = LockCardMaterial.Decision

    /// **Spec §7.2, row by row.** Automatic: the cover's light at the wallpaper's
    /// alpha. Transparent: black at 0.30, hairline. Tinted: the cover's light at
    /// 0.88. Solid: `#1C1C1E`, hairline. The old code kept Tinted at 1.0 and drew
    /// Transparent as the cover's light at 0.62, and its test asserted the code's
    /// own numbers (review 2026-10-15).
    func testEachStyleIsWhatSection72Says() {
        func decide(_ style: NotchViewModel.LockCardStyle, artwork: Bool = true, l: Double? = nil) -> Decision {
            LockCardMaterial.decision(style: style, hasArtwork: artwork, luminance: l, reduceTransparency: false)
        }
        // Automatic: Aerial 0.03 -> 0.90, Sonoma 0.36 -> 0.84 (the board's rows).
        XCTAssertEqual(decide(.automatic, l: 0.03).layer, .coverLight)
        XCTAssertEqual(decide(.automatic, l: 0.03).alpha, 0.90, accuracy: 0.01)
        XCTAssertEqual(decide(.automatic, l: 0.36).alpha, 0.84, accuracy: 0.01)
        XCTAssertEqual(decide(.automatic).alpha, 0.84, "unknown wallpaper: the floor")
        // Transparent: "black alpha 0.30, hairline" over a dark wallpaper; heavier
        // where the type would not clear AA (testTransparentIs...).
        XCTAssertEqual(decide(.clear, l: 0.03), Decision(layer: .blackWash, alpha: 0.30))
        XCTAssertEqual(LockCardMaterial.transparentAlpha, 0.30)
        // Tinted: "the cover's light at 0.88".
        XCTAssertEqual(decide(.glass), Decision(layer: .coverLight, alpha: 0.88))
        XCTAssertEqual(LockCardMaterial.tintedAlpha, 0.88)
        // Solid: #1C1C1E, hairline.
        XCTAssertEqual(decide(.solid), Decision(layer: .solid, alpha: 1))
    }

    /// The Solid token is `#1C1C1E` and Transparent's is black at 0.30; both are
    /// in `Theme`, so no view carries a raw colour for them.
    func testTheSolidAndTransparentTokensAreTheSpecs() throws {
        let solid = try XCTUnwrap(NSColor(Theme.lockCardSolid).usingColorSpace(.sRGB))
        XCTAssertEqual(solid.redComponent * 255, 0x1C, accuracy: 0.5)
        XCTAssertEqual(solid.greenComponent * 255, 0x1C, accuracy: 0.5)
        XCTAssertEqual(solid.blueComponent * 255, 0x1E, accuracy: 0.5)
        let clear = try XCTUnwrap(NSColor(Theme.lockCardTransparent).usingColorSpace(.sRGB))
        XCTAssertEqual(clear.redComponent, 0, accuracy: 0.001)
        XCTAssertEqual(clear.alphaComponent, 0.30, accuracy: 0.001)
    }

    /// **No cover is not no material** (review 2026-10-15): Automatic and Tinted
    /// without artwork lay the same alpha as a dark neutral, so the 0.84 floor of
    /// owner decision 5 holds for a podcast or a browser tab. Before, the view
    /// drew no light at all and the card was the bare recipe over a shield it
    /// cannot sample.
    func testAutomaticWithoutACoverIsStillMostlySolid() {
        for l in [nil, 0.03, 0.36, 0.9] as [Double?] {
            let bare = LockCardMaterial.decision(
                style: .automatic, hasArtwork: false, luminance: l, reduceTransparency: false
            )
            XCTAssertEqual(bare.layer, .neutralFill, "L \(String(describing: l))")
            XCTAssertGreaterThanOrEqual(bare.alpha, 0.84, "L \(String(describing: l)): the floor")
            XCTAssertEqual(
                bare.alpha, LockCardMaterial.decision(
                    style: .automatic, hasArtwork: true, luminance: l, reduceTransparency: false
                ).alpha, "the same alpha as with a cover"
            )
        }
        XCTAssertEqual(
            LockCardMaterial.decision(style: .glass, hasArtwork: false, luminance: nil, reduceTransparency: false),
            Decision(layer: .neutralFill, alpha: 0.88)
        )
        // Styles that never wanted a cover are unaffected by its absence.
        XCTAssertEqual(
            LockCardMaterial.decision(style: .clear, hasArtwork: false, luminance: 0.03, reduceTransparency: false),
            Decision(layer: .blackWash, alpha: 0.30)
        )
        XCTAssertEqual(
            LockCardMaterial.decision(style: .solid, hasArtwork: false, luminance: nil, reduceTransparency: false),
            Decision(layer: .solid, alpha: 1)
        )
    }

    func testReduceTransparencyAndIncreaseContrastInTheDecision() {
        for style in NotchViewModel.LockCardStyle.allCases {
            for artwork in [false, true] {
                XCTAssertEqual(
                    LockCardMaterial.decision(
                        style: style, hasArtwork: artwork, luminance: 0.03, reduceTransparency: true
                    ), Decision(layer: .solid, alpha: 1), "\(style) artwork \(artwork): Solid under Reduce Transparency"
                )
            }
        }
        XCTAssertEqual(
            LockCardMaterial.decision(
                style: .clear, hasArtwork: true, luminance: nil, reduceTransparency: false, increaseContrast: true
            ), Decision(layer: .solid, alpha: 1), "see-through is what Increase Contrast asks against"
        )
        XCTAssertEqual(
            LockCardMaterial.decision(
                style: .automatic, hasArtwork: true, luminance: nil, reduceTransparency: false, increaseContrast: true
            ).alpha, 0.84, "Automatic is already near-opaque"
        )
    }

    /// **The shadow follows what is drawn** (re-review 2026-10-15): Increase
    /// Contrast on Transparent draws Solid, and Solid carries no text shadow; the
    /// stored style used to pick it.
    func testTheTextShadowFollowsTheDrawnLayer() {
        func shadow(_ style: NotchViewModel.LockCardStyle, rt: Bool = false, ic: Bool = false) -> Double {
            LockCardMaterial.textShadowOpacity(for: LockCardMaterial.decision(
                style: style, hasArtwork: true, luminance: 0.5, reduceTransparency: rt, increaseContrast: ic).layer)
        }
        XCTAssertEqual(shadow(.clear), 0.5)
        XCTAssertEqual(shadow(.clear, ic: true), 0, "Solid is drawn, so no Transparent shadow")
        XCTAssertEqual(shadow(.clear, rt: true), 0)
        XCTAssertEqual(shadow(.solid), 0)
        XCTAssertEqual(shadow(.automatic), 0.35)
        XCTAssertEqual(shadow(.glass), 0.35)
    }

    /// The panel routing follows the decision: Solid and Transparent are panels.
    func testSolidAndTransparentAreRoutedToThePanel() {
        XCTAssertTrue(LockScreenCard.glassRouting(style: .clear, hasArtwork: true).solid)
        XCTAssertTrue(LockScreenCard.glassRouting(style: .clear, hasArtwork: false).solid)
        XCTAssertFalse(LockScreenCard.glassRouting(style: .glass, hasArtwork: true).solid)
        XCTAssertFalse(LockScreenCard.glassRouting(style: .glass, hasArtwork: false).solid)
        XCTAssertTrue(LockScreenCard.glassRouting(style: .automatic, hasArtwork: false, increaseContrast: false).samplesBackdrop)
    }

    // MARK: - Reading the wallpaper behind the card

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lock-card-tone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func solid(grey: CGFloat, width: Int = 640, height: Int = 400) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: grey, green: grey, blue: grey, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func write(_ image: CGImage) throws -> URL {
        let url = directory.appendingPathComponent("\(UUID().uuidString).png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    /// The card is centred on the display both ways, and the banner hangs from
    /// its top: both are judged against the one region.
    func testTheRegionBehindTheCardIsTheCardCentredOnTheScreen() {
        let screen = CGSize(width: 1800, height: 1169)
        XCTAssertEqual(
            WallpaperTone.cardRegion(screenSize: screen, cardSize: CGSize(width: 460, height: 300)),
            CGRect(x: 670, y: 435, width: 460, height: 300)
        )
        // The window's own placement rounds the same way (`LockCardWindow.frame`).
        let frame = LockCardWindow.frame(on: CGRect(origin: .zero, size: screen), size: CGSize(width: 460, height: 300))
        let region = WallpaperTone.cardRegion(screenSize: screen, cardSize: CGSize(width: 460, height: 300))
        XCTAssertEqual(region.midX, frame.midX)
        XCTAssertEqual(region.width, frame.width)
        // A card larger than the screen is cut to it.
        XCTAssertEqual(
            WallpaperTone.cardRegion(screenSize: CGSize(width: 300, height: 200), cardSize: CGSize(width: 460, height: 300)),
            CGRect(x: 0, y: 0, width: 300, height: 200)
        )
    }

    /// The region is the card's, not the notch's strip: a wallpaper dark across
    /// the top and bright in the middle reads bright to the card.
    func testTheMeasurementIsOverTheCardsRegion() throws {
        let screen = CGSize(width: 640, height: 400)
        let picture = try { () -> CGImage in
            let width = 640, height = 400
            let context = try XCTUnwrap(CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            // Black across the top 60 points of the screen, which in a CGContext's
            // bottom-left space is the highest rows.
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: height - 60, width: width, height: 60))
            return try XCTUnwrap(context.makeImage())
        }()
        let url = try write(picture)
        let card = WallpaperTone.meanLuminance(
            ofWallpaperAt: url, screenSize: screen,
            region: WallpaperTone.cardRegion(screenSize: screen, cardSize: CGSize(width: 460, height: 150)),
            mayRead: { _ in true }
        )
        XCTAssertEqual(try XCTUnwrap(card), 1, accuracy: 0.02, "the card sits over the white middle")
        let strip = WallpaperTone.meanLuminance(
            ofWallpaperAt: url, screenSize: screen, notchCenterX: 320, mayRead: { _ in true }
        )
        XCTAssertEqual(try XCTUnwrap(strip), 0, accuracy: 0.02, "while the island's strip is over the black top")
    }

    /// **The privacy gate is in front of the card's read too.** A wallpaper behind
    /// it — in Downloads, in iCloud Drive, on a removable volume — is never
    /// opened, however many surfaces want its brightness, and answers unknown
    /// (the floor) without a prompt.
    func testAGatedWallpaperIsNeverOpenedForTheCard() throws {
        let screen = CGSize(width: 640, height: 400)
        let region = WallpaperTone.cardRegion(screenSize: screen, cardSize: CGSize(width: 460, height: 300))
        var asked = 0
        var opened = 0
        let answer = WallpaperTone.meanLuminance(
            ofWallpaperAt: URL(fileURLWithPath: "/Users/tester/Downloads/aerial.heic"), screenSize: screen,
            region: region,
            mayRead: { _ in asked += 1; return false },
            thumbnail: { _ in opened += 1; return nil }
        )
        XCTAssertNil(answer)
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(opened, 0, "a gated file is never reached")
        XCTAssertEqual(LockCardMaterial.automaticAlpha(luminance: answer), 0.84, "and the card is at its floor")

        // The real gate says no to the same place, with no stub in the way.
        XCTAssertFalse(WallpaperTone.isReadableWithoutPrompt(
            URL(fileURLWithPath: "/Users/tester/Downloads/aerial.heic"), home: "/Users/tester"
        ))
    }

    func testTheToneModelReadsAWallpaperAndAnswersTheMaterialsAlpha() async throws {
        let url = try write(try solid(grey: 0.03))
        let model = LockCardToneModel(measure: { url, screen, region in
            WallpaperTone.meanLuminance(ofWallpaperAt: url, screenSize: screen, region: region, mayRead: { _ in true })
        })
        XCTAssertNil(model.luminance)
        XCTAssertEqual(model.alpha, 0.84, "until it has answered the card is at its floor")

        model.refresh(wallpaper: url, screenSize: CGSize(width: 640, height: 400), cardSize: CGSize(width: 460, height: 300))
        for _ in 0..<200 where model.luminance == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(try XCTUnwrap(model.luminance), 0.03, accuracy: 0.01)
        XCTAssertEqual(model.alpha, 0.90, accuracy: 0.01, "Aerial's alpha")
    }

    func testTheToneModelGivenNoWallpaperOrAGatedOneStaysAtTheFloor() async throws {
        let model = LockCardToneModel()
        model.refresh(wallpaper: nil, screenSize: CGSize(width: 640, height: 400), cardSize: CGSize(width: 460, height: 300))
        XCTAssertNil(model.luminance)
        XCTAssertEqual(model.alpha, 0.84)

        // A real gate, a path it refuses: never opened, never read.
        let gated = LockCardToneModel(measure: { url, screen, region in
            WallpaperTone.meanLuminance(
                ofWallpaperAt: url, screenSize: screen, region: region,
                mayRead: { WallpaperTone.isReadableWithoutPrompt($0, home: "/Users/tester") },
                thumbnail: { _ in XCTFail("a gated wallpaper was opened"); return nil }
            )
        })
        gated.refresh(
            wallpaper: URL(fileURLWithPath: "/Users/tester/Desktop/wall.png"),
            screenSize: CGSize(width: 640, height: 400), cardSize: CGSize(width: 460, height: 300)
        )
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(gated.luminance)
        XCTAssertEqual(gated.alpha, 0.84)
    }

    /// **A stale answer never lands.** The display changed under a slow read: the
    /// earlier request finishes after the later one has been answered, and must
    /// not overwrite it (the generation guard in `refresh`).
    func testAStaleWallpaperAnswerNeverLands() async throws {
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let model = LockCardToneModel(measure: { url, _, _ in
            if url.lastPathComponent == "old.png" {
                release.wait()
                finished.signal()
                return 0.05
            }
            return 0.90
        })
        let screen = CGSize(width: 640, height: 400)
        let card = CGSize(width: 460, height: 300)
        model.refresh(wallpaper: URL(fileURLWithPath: "/tmp/old.png"), screenSize: screen, cardSize: card)
        model.refresh(wallpaper: URL(fileURLWithPath: "/tmp/new.png"), screenSize: screen, cardSize: card)
        for _ in 0..<200 where model.luminance == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.luminance, 0.90)

        release.signal()
        let ran = await waitOffMain(finished)
        XCTAssertTrue(ran, "the earlier read did finish")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(model.luminance, 0.90, "and its answer was dropped")

        // A newer request that finds no wallpaper also outdates a read in flight.
        let slow = DispatchSemaphore(value: 0)
        let slowDone = DispatchSemaphore(value: 0)
        let second = LockCardToneModel(measure: { _, _, _ in
            slow.wait()
            slowDone.signal()
            return 0.05
        })
        second.refresh(wallpaper: URL(fileURLWithPath: "/tmp/old.png"), screenSize: screen, cardSize: card)
        second.refresh(wallpaper: nil, screenSize: screen, cardSize: card)
        slow.signal()
        _ = await waitOffMain(slowDone)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(second.luminance, "an unknown is not overwritten by the read it replaced")
    }
}

/// Waits for `semaphore` on a global queue and hands the verdict back to the
/// awaiting test, so the test's own thread never blocks. This was a
/// `Task.detached { Self.signalled(x) }.value` once, and Xcode 26.6's
/// region-based isolation checker gave up on that closure ("pattern that the
/// region-based isolation checker does not understand") and failed the CI build,
/// though Swift 6.4 compiled it. A continuation resumed from a plain dispatch
/// block has nothing for the checker to reason about.
private func waitOffMain(_ semaphore: DispatchSemaphore) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: semaphore.wait(timeout: .now() + 5) == .success)
        }
    }
}
