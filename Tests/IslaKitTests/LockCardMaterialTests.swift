import AppKit
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

    func testTheCoverLightIsDrawnAtTheMaterialsOpacity() {
        XCTAssertEqual(LockCardMaterial.coverLightOpacity(style: .automatic, alpha: 0.9, increaseContrast: false), 0.9)
        XCTAssertEqual(LockCardMaterial.coverLightOpacity(style: .automatic, alpha: 0.9, increaseContrast: true), 0.9,
                       "Automatic is already near-opaque")
        XCTAssertEqual(LockCardMaterial.coverLightOpacity(style: .clear, alpha: 0.9, increaseContrast: false), 0.62)
        XCTAssertEqual(LockCardMaterial.coverLightOpacity(style: .clear, alpha: 0.9, increaseContrast: true), 1)
        XCTAssertEqual(LockCardMaterial.coverLightOpacity(style: .glass, alpha: 0.9, increaseContrast: false), 1)
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
}
