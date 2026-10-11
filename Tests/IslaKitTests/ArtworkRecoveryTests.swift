import AppKit
import XCTest
@testable import IslaKit

/// The album cover has to come back.
@MainActor
final class ArtworkRecoveryTests: XCTestCase {

    /// The reported bug, as a decision table.
    ///
    /// Play something else, come back to Spotify, and the cover was a grey note
    /// for the rest of the song: artwork rides only the update where it changed,
    /// the app's copy had been cleared when the session went empty, and the
    /// helper still held the same artwork id so it never sent one again.
    func testACoverThatWentMissingIsAskedForOnce() {
        XCTAssertTrue(
            MediaController.shouldAskForArtwork(
                showing: false, describesDisplayedTrack: true,
                feedAvailable: true, alreadyAsked: false
            ),
            "displaying a track with no cover is exactly when to ask"
        )
        XCTAssertFalse(
            MediaController.shouldAskForArtwork(
                showing: false, describesDisplayedTrack: true,
                feedAvailable: true, alreadyAsked: true
            ),
            "a session with genuinely no cover must not be asked twice a second forever"
        )
    }

    func testNothingIsAskedForWhenThereIsNothingToFix() {
        // Already showing it.
        XCTAssertFalse(MediaController.shouldAskForArtwork(
            showing: true, describesDisplayedTrack: true,
            feedAvailable: true, alreadyAsked: false
        ))
        // The cover we hold belongs to a different track; the track-change path
        // owns that case and blanks it deliberately.
        XCTAssertFalse(MediaController.shouldAskForArtwork(
            showing: false, describesDisplayedTrack: false,
            feedAvailable: true, alreadyAsked: false
        ))
        // The scripting fallback is driving. There is no helper listening.
        XCTAssertFalse(MediaController.shouldAskForArtwork(
            showing: false, describesDisplayedTrack: true,
            feedAvailable: false, alreadyAsked: false
        ))
    }

    /// The wire word, which the helper matches exactly.
    func testTheHelperIsAskedInAWordItKnows() {
        XCTAssertEqual(NowPlayingFeed.artworkRequestLine, "art")
    }

    // MARK: - Decoded size

    /// A 2000 by 1200 PNG made here, so the test owns its pixels.
    ///
    /// The cover used to be decoded at its full source size and held for the
    /// whole track: an Apple Music cover of 3000 px is about 36 MB of RGBA,
    /// while the largest sharp use is 118 pt. The long side now stops at 512
    /// and the aspect ratio survives.
    func testALargeCoverIsDecodedSmall() throws {
        let data = try XCTUnwrap(Self.png(width: 2000, height: 1200))
        let image = try XCTUnwrap(MediaController.downsampledArtwork(data))
        XCTAssertEqual(image.width, 512)
        XCTAssertEqual(image.height, 307)
    }

    /// Downsampling is a ceiling, never an upscale: a small cover keeps its
    /// own pixels, so nothing gets softer than it was.
    func testASmallCoverIsLeftAlone() throws {
        let data = try XCTUnwrap(Self.png(width: 300, height: 300))
        let image = try XCTUnwrap(MediaController.downsampledArtwork(data))
        XCTAssertEqual(image.width, 300)
        XCTAssertEqual(image.height, 300)
    }

    /// An undecodable payload answers nil, which is what lets the caller blank
    /// the previous track's cover instead of leaving it standing.
    func testGarbageDecodesToNil() {
        XCTAssertNil(MediaController.downsampledArtwork(Data("not an image".utf8)))
        XCTAssertNil(MediaController.downsampledArtwork(Data()))
    }

    private static func png(width: Int, height: Int) -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
