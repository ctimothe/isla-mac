import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import IslaKit

/// Whether the wallpaper behind the island is dark (redesign spec §3.3), on
/// fixture pictures this file draws — never on the desk of whoever runs it.
///
/// The key line is gated on this, so what these hold is: dark below a mean
/// luma of 0.20 and not above it, only the strip behind the island counts, the
/// picture is laid on the screen aspect-fill, the answer is cached by file and
/// date, and every failure is "not dark" — a missing flourish rather than a
/// stroke on a light desktop.
final class WallpaperToneTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wallpaper-tone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Fixtures

    /// A picture drawn by `draw`, in sRGB.
    private func image(width: Int, height: Int, draw: (CGContext) -> Void) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        draw(context)
        return try XCTUnwrap(context.makeImage())
    }

    private func fill(_ context: CGContext, grey: CGFloat, _ rect: CGRect) {
        context.setFillColor(CGColor(srgbRed: grey, green: grey, blue: grey, alpha: 1))
        context.fill(rect)
    }

    private func solid(grey: CGFloat, width: Int = 640, height: Int = 400) throws -> CGImage {
        try image(width: width, height: height) { fill($0, grey: grey, CGRect(x: 0, y: 0, width: width, height: height)) }
    }

    @discardableResult
    private func write(_ image: CGImage, as name: String = UUID().uuidString) throws -> URL {
        let url = directory.appendingPathComponent("\(name).png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private let screen = CGSize(width: 1512, height: 982)
    private var centre: CGFloat { screen.width / 2 }

    private func reading(of url: URL?) -> WallpaperTone.Reading {
        WallpaperTone.reading(ofWallpaperAt: url, screenSize: screen, notchCenterX: centre)
    }

    // MARK: Dark and light

    func testADarkPictureIsDarkAndALightOneIsNot() throws {
        let aerial = try write(solid(grey: 8.0 / 255), as: "aerial")      // the owner's measured 8/255
        let sky = try write(solid(grey: 0.41), as: "sky-blue")
        XCTAssertEqual(reading(of: aerial), .dark)
        XCTAssertEqual(reading(of: sky), .light)
    }

    /// The line is 0.20 of *encoded* luma, the units the spec's four
    /// measurements are in: Pro Black at 0.09 is dark and Sonoma at 0.36 is
    /// not. In linear light Sonoma would be about 0.1 and fall under the line.
    func testTheThresholdIsTwentyPercentOfEncodedLuma() throws {
        XCTAssertEqual(WallpaperTone.darkThreshold, 0.20)
        XCTAssertEqual(reading(of: try write(solid(grey: 0.09))), .dark, "Pro Black")
        XCTAssertEqual(reading(of: try write(solid(grey: 0.19))), .dark, "just under the line")
        XCTAssertEqual(reading(of: try write(solid(grey: 0.22))), .light, "just over it")
        XCTAssertEqual(reading(of: try write(solid(grey: 0.36))), .light, "Sonoma")
        XCTAssertEqual(WallpaperTone.reading(forMeanLuminance: 0.1999), .dark)
        XCTAssertEqual(WallpaperTone.reading(forMeanLuminance: 0.20), .light, "at the line is not under it")
    }

    func testTheMeanIsRec709LumaOfTheEncodedValues() throws {
        let green = try image(width: 8, height: 8) {
            $0.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
            $0.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let mean = try XCTUnwrap(WallpaperTone.meanLuminance(of: green, in: CGRect(x: 0, y: 0, width: 8, height: 8)))
        XCTAssertEqual(mean, 0.7152, accuracy: 0.003)
    }

    // MARK: Failure is not dark

    func testEveryFailureIsNotDark() throws {
        XCTAssertEqual(reading(of: nil), .unknown, "no wallpaper URL")
        XCTAssertEqual(reading(of: directory.appendingPathComponent("missing.png")), .unknown, "a file that is not there")
        XCTAssertEqual(reading(of: directory), .unknown, "a folder, which is what a rotating wallpaper names")
        let corrupt = directory.appendingPathComponent("corrupt.png")
        try Data("not a picture at all".utf8).write(to: corrupt)
        XCTAssertEqual(reading(of: corrupt), .unknown, "an unreadable file")
        XCTAssertEqual(WallpaperTone.reading(forMeanLuminance: nil), .unknown)
        XCTAssertFalse(KeyLine.isShown(tone: reading(of: nil), increaseContrast: false), "so no key line")
    }

    // MARK: Only the strip behind the island counts

    /// The top 60 pt — 6 % of this screen's height — is what the island sits
    /// on. A wallpaper dark at the top and bright below is dark for this
    /// purpose, and the other way round is not.
    func testOnlyTheStripBehindTheIslandIsMeasured() throws {
        let width = 1512, height = 982
        let darkTop = try image(width: width, height: height) {
            fill($0, grey: 0.9, CGRect(x: 0, y: 0, width: width, height: height))
            // CGContext's origin is bottom-left: the top strip is the highest rows.
            fill($0, grey: 0.02, CGRect(x: 0, y: height - 70, width: width, height: 70))
        }
        let lightTop = try image(width: width, height: height) {
            fill($0, grey: 0.02, CGRect(x: 0, y: 0, width: width, height: height))
            fill($0, grey: 0.9, CGRect(x: 0, y: height - 70, width: width, height: 70))
        }
        XCTAssertEqual(reading(of: try write(darkTop)), .dark)
        XCTAssertEqual(reading(of: try write(lightTop)), .light)
    }

    /// And only within 310 pt of the notch's centre.
    func testOnlyTheWidthBehindTheIslandIsMeasured() throws {
        let width = 1512, height = 982
        let darkMiddle = try image(width: width, height: height) {
            fill($0, grey: 0.9, CGRect(x: 0, y: 0, width: width, height: height))
            fill($0, grey: 0.02, CGRect(x: 756 - 330, y: 0, width: 660, height: height))
        }
        let lightMiddle = try image(width: width, height: height) {
            fill($0, grey: 0.02, CGRect(x: 0, y: 0, width: width, height: height))
            fill($0, grey: 0.9, CGRect(x: 756 - 330, y: 0, width: 660, height: height))
        }
        XCTAssertEqual(reading(of: try write(darkMiddle)), .dark)
        XCTAssertEqual(reading(of: try write(lightMiddle)), .light)
    }

    func testTheRegionIsTheNotchsCentrePlusOrMinusThreeTenAcrossTheTopSixtyPoints() {
        let region = WallpaperTone.islandRegion(screenSize: screen, notchCenterX: centre)
        XCTAssertEqual(region, CGRect(x: 756 - 310, y: 0, width: 620, height: 60))
        let atTheEdge = WallpaperTone.islandRegion(screenSize: screen, notchCenterX: 100)
        XCTAssertEqual(atTheEdge.minX, 0, "clipped to the screen, never negative")
        XCTAssertEqual(atTheEdge.maxX, 410)
    }

    // MARK: Aspect-fill

    /// A square picture on a 2:1 screen is scaled to the screen's width and the
    /// overflow above and below is cropped: the screen's top edge is a quarter
    /// of the way down the picture.
    func testATallPictureIsCroppedAboveAndBelowAspectFill() {
        let region = WallpaperTone.imageRegion(
            for: CGRect(x: 100, y: 0, width: 200, height: 60),
            screenSize: CGSize(width: 1000, height: 500), imageSize: CGSize(width: 1000, height: 1000)
        )
        XCTAssertEqual(region, CGRect(x: 100, y: 250, width: 200, height: 60))
    }

    /// A wide picture is cropped left and right: the screen's left edge is a
    /// quarter of the way across.
    func testAWidePictureIsCroppedLeftAndRightAspectFill() {
        let region = WallpaperTone.imageRegion(
            for: CGRect(x: 0, y: 0, width: 200, height: 60),
            screenSize: CGSize(width: 1000, height: 500), imageSize: CGSize(width: 2000, height: 500)
        )
        XCTAssertEqual(region, CGRect(x: 500, y: 0, width: 200, height: 60))
    }

    func testAPictureOfTheScreensOwnShapeMapsOneToOneScaled() {
        let region = WallpaperTone.imageRegion(
            for: CGRect(x: 100, y: 0, width: 200, height: 60),
            screenSize: CGSize(width: 1000, height: 500), imageSize: CGSize(width: 500, height: 250)
        )
        XCTAssertEqual(region, CGRect(x: 50, y: 0, width: 100, height: 30), "half-size picture, half-size region")
        XCTAssertTrue(WallpaperTone.imageRegion(for: .zero, screenSize: .zero, imageSize: .zero).isNull, "nothing to map is nothing")
    }

    // MARK: Thumbnail

    func testTheThumbnailIsNoLargerThanTwoHundredFiftySixPixels() throws {
        let url = try write(solid(grey: 0.5, width: 2000, height: 1000))
        let thumbnail = try XCTUnwrap(WallpaperTone.thumbnail(at: url))
        XCTAssertLessThanOrEqual(max(thumbnail.width, thumbnail.height), 256)
        XCTAssertEqual(Double(thumbnail.width) / Double(thumbnail.height), 2, accuracy: 0.05, "the shape is kept")
    }

    // MARK: Cache

    /// Cached by URL and modification date: the same file and date answers from
    /// the cache without being read again, and a new date reads it again.
    func testTheAnswerIsCachedByFileAndModificationDate() throws {
        let url = try write(solid(grey: 0.02), as: "cached")
        // A whole-second date, set before the first read, so putting it back is
        // exact: a date taken from the file carries nanoseconds that do not
        // survive the round trip through `Date`.
        let original = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: original], ofItemAtPath: url.path)
        let first = try XCTUnwrap(WallpaperTone.meanLuminance(ofWallpaperAt: url, screenSize: screen, notchCenterX: centre))
        XCTAssertLessThan(first, 0.2)

        // Replace the contents with a bright picture and put the date back: to
        // the cache, nothing has changed.
        try write(solid(grey: 0.9), as: "cached")
        try FileManager.default.setAttributes([.modificationDate: original], ofItemAtPath: url.path)
        let cached = try XCTUnwrap(WallpaperTone.meanLuminance(ofWallpaperAt: url, screenSize: screen, notchCenterX: centre))
        XCTAssertEqual(cached, first, "the same file and date is a cache hit")

        try FileManager.default.setAttributes(
            [.modificationDate: original.addingTimeInterval(60)], ofItemAtPath: url.path
        )
        let fresh = try XCTUnwrap(WallpaperTone.meanLuminance(ofWallpaperAt: url, screenSize: screen, notchCenterX: centre))
        XCTAssertGreaterThan(fresh, 0.5, "a new modification date is read again")
    }

    // MARK: The model

    /// The model answers off the main actor, lands on it, and a failure is
    /// `unknown`. Injected: it reads the fixture, not this Mac's desktop.
    @MainActor
    func testTheModelPublishesWhatItFoundOffTheMainActor() async throws {
        let screens = NSScreen.screens
        try XCTSkipIf(screens.isEmpty, "needs a display to describe")
        let dark = try write(solid(grey: 0.02), as: "model-dark")
        var url: URL? = dark
        let model = WallpaperToneModel(
            target: { (screens[0], screens[0].frame.midX) },
            wallpaperURL: { _ in url }
        )
        XCTAssertEqual(model.reading, .unknown, "nothing is known before the first look")

        model.refresh()
        try await waitFor { model.reading == .dark }

        url = nil
        model.refresh()
        try await waitFor { model.reading == .unknown }
    }

    @MainActor
    private func waitFor(_ condition: () -> Bool, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for the wallpaper answer") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
