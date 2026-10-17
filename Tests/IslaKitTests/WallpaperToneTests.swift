import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import IslaKit

/// How dark the wallpaper is behind a part of the screen, on fixture pictures
/// this file draws — never on the desk of whoever runs it.
///
/// The lock card's Automatic material reads this measurement over its own
/// region; the island stopped asking on 2026-10-17 (spec §19.2). What these
/// hold: dark below a mean luma of 0.20 and not above it, only the region asked
/// about counts, the picture is laid on the screen aspect-fill, the answer is
/// cached by file and date, a gated file is never opened, and every failure is
/// "not dark".
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

    /// The fixtures live in a temporary folder, which the real gate rightly
    /// refuses (it is neither the system's nor the home folder's), so the tests
    /// that are about *measuring* open the gate; the gate has its own tests.
    private func reading(of url: URL?) -> WallpaperTone.Reading {
        WallpaperTone.reading(ofWallpaperAt: url, screenSize: screen, notchCenterX: centre, mayRead: { _ in true })
    }

    // MARK: The privacy gate

    private let home = "/Users/tester"

    private func mayRead(_ path: String) -> Bool {
        WallpaperTone.isReadableWithoutPrompt(URL(fileURLWithPath: path), home: home)
    }

    /// Wallpapers in a place macOS guards (or that is another app's) are not
    /// opened: opening one raised "Isla would like to access files in your
    /// Downloads folder" at launch, with nothing on screen to explain it
    /// (review 2026-10-15).
    func testAWallpaperBehindAPrivacyGateIsNeverOpened() {
        for path in [
            "/Users/tester/Downloads/sky.jpg",
            "/Users/tester/Desktop/sky.jpg",
            "/Users/tester/Documents/Walls/sky.jpg",
            "/Users/tester/Library/Mobile Documents/com~apple~CloudDocs/sky.jpg",
            "/Users/tester/Library/CloudStorage/Dropbox/sky.jpg",
            "/Users/tester/Library/Containers/com.apple.Photos/Data/sky.jpg",
            "/Users/tester/Library/Group Containers/group.com.apple.wallpaper/sky.jpg",
            "/Users/tester/Pictures/Photos Library.photoslibrary/originals/A/sky.jpg",
            "/Users/tester/Pictures/Family.photoslibrary/originals/A/sky.jpg",
            "/Users/tester/Pictures/Trips/2024.PhotosLibrary/resources/sky.jpg",
            "/Users/tester/Movies/sky.jpg",
            "/Users/tester/Music/sky.jpg",
            "/Volumes/Backup/Walls/sky.jpg",
            "/Volumes/Backup/Users/tester/Pictures/sky.jpg",
            "/Users/someone-else/Pictures/sky.jpg",
            "/private/var/folders/xx/T/sky.jpg",
            "/tmp/sky.jpg",
            "/Users/tester",
        ] {
            XCTAssertFalse(mayRead(path), "\(path) must not be opened")
        }
        // Folded before it is judged, and the case of the volume does not matter.
        XCTAssertFalse(mayRead("/Users/tester/Pictures/../Downloads/sky.jpg"))
        XCTAssertFalse(mayRead("/Users/tester/DOWNLOADS/sky.jpg"))
        XCTAssertFalse(WallpaperTone.isReadableWithoutPrompt(URL(string: "https://example.com/sky.jpg")!, home: home),
                       "not a file")
    }

    func testTheSystemsOwnPicturesAndTheHomeFolderOutsideTheGatedPlacesAreOpened() {
        for path in [
            "/System/Library/Desktop Pictures/Sonoma.heic",
            "/Library/Desktop Pictures/Solid Colors/Black.png",
            "/Library/Application Support/com.apple.idleassetsd/Customer/4KSDR240FPS/aerial.heic",
            "/Users/tester/Pictures/sky.jpg",
            "/Users/tester/Library/Application Support/com.apple.mobileAssetDesktop/sky.heic",
            "/Users/tester/Pictures/Wallpapers/Photos Library notes/sky.jpg",
        ] {
            XCTAssertTrue(mayRead(path), "\(path) is readable without a prompt")
        }
    }

    /// The gate is decided before any file call: the reader is never invoked
    /// for a gated file, and the answer is "unknown" — no key line. For a
    /// system picture the reader is asked.
    func testAGatedWallpaperAnswersUnknownWithoutTouchingTheFile() throws {
        var asked: [URL] = []
        let reader: (URL) -> CGImage? = { url in
            asked.append(url)
            return try? self.solid(grey: 0.02)
        }
        let gated = [
            "/Users/tester/Downloads/gated-\(UUID().uuidString).jpg",
            "/Users/tester/Desktop/gated-\(UUID().uuidString).jpg",
            "/Users/tester/Documents/gated-\(UUID().uuidString).jpg",
            "/Users/tester/Library/Mobile Documents/gated-\(UUID().uuidString).jpg",
            "/Volumes/Backup/gated-\(UUID().uuidString).jpg",
            "/Users/tester/Library/Containers/gated-\(UUID().uuidString).jpg",
        ].map { URL(fileURLWithPath: $0) }
        for url in gated {
            let reading = WallpaperTone.reading(
                ofWallpaperAt: url, screenSize: screen, notchCenterX: centre,
                mayRead: { WallpaperTone.isReadableWithoutPrompt($0, home: self.home) }, thumbnail: reader
            )
            XCTAssertEqual(reading, .unknown, url.path)
        }
        XCTAssertTrue(asked.isEmpty, "a gated file is never handed to the reader: \(asked)")

        let system = URL(fileURLWithPath: "/System/Library/Desktop Pictures/gate-test-\(UUID().uuidString).heic")
        let reading = WallpaperTone.reading(
            ofWallpaperAt: system, screenSize: screen, notchCenterX: centre,
            mayRead: { WallpaperTone.isReadableWithoutPrompt($0, home: self.home) }, thumbnail: reader
        )
        XCTAssertEqual(asked, [system], "a system picture is read")
        XCTAssertEqual(reading, .dark)
    }

    /// The gate is what the app runs with unless told otherwise: a perfectly
    /// readable dark picture in a folder the gate does not know answers nothing.
    func testTheRealGateIsTheDefault() throws {
        let url = try write(solid(grey: 0.02), as: "default-gate")
        XCTAssertEqual(reading(of: url), .dark, "with the gate opened by the fixture helper")
        XCTAssertEqual(
            WallpaperTone.reading(ofWallpaperAt: url, screenSize: screen, notchCenterX: centre), .unknown,
            "a temporary folder is neither the system's nor the home folder's"
        )
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
        let first = try XCTUnwrap(WallpaperTone.meanLuminance(ofWallpaperAt: url, screenSize: screen, notchCenterX: centre, mayRead: { _ in true }))
        XCTAssertLessThan(first, 0.2)

        // Replace the contents with a bright picture and put the date back: to
        // the cache, nothing has changed.
        try write(solid(grey: 0.9), as: "cached")
        try FileManager.default.setAttributes([.modificationDate: original], ofItemAtPath: url.path)
        let cached = try XCTUnwrap(WallpaperTone.meanLuminance(ofWallpaperAt: url, screenSize: screen, notchCenterX: centre, mayRead: { _ in true }))
        XCTAssertEqual(cached, first, "the same file and date is a cache hit")

        try FileManager.default.setAttributes(
            [.modificationDate: original.addingTimeInterval(60)], ofItemAtPath: url.path
        )
        let fresh = try XCTUnwrap(WallpaperTone.meanLuminance(ofWallpaperAt: url, screenSize: screen, notchCenterX: centre, mayRead: { _ in true }))
        XCTAssertGreaterThan(fresh, 0.5, "a new modification date is read again")
    }
}
