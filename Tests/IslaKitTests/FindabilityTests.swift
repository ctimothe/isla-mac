import AppKit
import XCTest
@testable import IslaKit

/// The features that were there and hard to find or impossible to switch off:
/// lyrics behind two Settings switches, a clipboard history with no off
/// switch, and a Spotify heart that vanished without a word.
@MainActor
final class FindabilityTests: XCTestCase {

    // MARK: Lyrics offers

    func testLyricsOffOffersToTurnThemOn() {
        XCTAssertEqual(LyricsPresentation.offer(for: .disabled, localLookup: nil, onlineEnabled: false), .turnOnLyrics)
    }

    /// A streamed song never has a local file, so "No local lyrics." was the
    /// end of the road for every Spotify listener who had not found the
    /// second switch.
    func testNoLocalMatchOffersTheOnlineLookupOnlyWhileItIsOff() {
        XCTAssertEqual(LyricsPresentation.offer(for: .noLocalLyrics, localLookup: nil, onlineEnabled: false), .lookUpOnline)
        XCTAssertNil(LyricsPresentation.offer(for: .noLocalLyrics, localLookup: nil, onlineEnabled: true))
    }

    func testPagesWithTheirOwnAnswerOfferNothing() {
        XCTAssertNil(LyricsPresentation.offer(for: .resolving, localLookup: nil, onlineEnabled: false))
        XCTAssertNil(LyricsPresentation.offer(for: .findingLocalLyrics, localLookup: nil, onlineEnabled: false))
    }

    func testTheDisabledCaptionNoLongerSendsYouToSettings() {
        let caption = LyricsPresentation.compactCaption(for: .disabled, currentLine: nil)
        XCTAssertFalse(caption.contains("Settings"), caption)
    }

    // MARK: Clipboard history

    func testClipboardHistoryIsOnUnlessTurnedOff() {
        let defaults = UserDefaults.standard
        let had = defaults.object(forKey: NotchViewModel.clipboardHistoryKey)
        defer {
            if let had { defaults.set(had, forKey: NotchViewModel.clipboardHistoryKey) }
            else { defaults.removeObject(forKey: NotchViewModel.clipboardHistoryKey) }
        }
        defaults.removeObject(forKey: NotchViewModel.clipboardHistoryKey)
        XCTAssertTrue(NotchViewModel.clipboardHistoryEnabled)
        defaults.set(false, forKey: NotchViewModel.clipboardHistoryKey)
        XCTAssertFalse(NotchViewModel.clipboardHistoryEnabled)
    }

    func testWithHistoryOffACopyIsNotRecorded() {
        let board = NSPasteboard(name: .init("FindabilityTests.\(UUID())"))
        let store = ClipboardStore(pasteboard: board)
        store.recordsHistory = { false }
        board.clearContents()
        board.setString("not for keeping", forType: .string)
        store.pollNow()
        XCTAssertTrue(store.items.isEmpty)

        store.recordsHistory = { true }
        board.clearContents()
        board.setString("kept", forType: .string)
        store.pollNow()
        XCTAssertEqual(store.items.first?.preview, "kept")
    }

    /// With history and clipboard screenshots both off, nothing reads the
    /// pasteboard at all.
    func testNothingPollsWhenNothingWantsThePasteboard() {
        XCTAssertFalse(NotchStores.clipboardShouldPoll(history: false, images: false))
        XCTAssertTrue(NotchStores.clipboardShouldPoll(history: true, images: false))
        XCTAssertTrue(NotchStores.clipboardShouldPoll(history: false, images: true))
    }

    // MARK: Spotify refusals

    func testASpotifyRefusalSaysWhy() {
        let unlisted = Data(#"{"error":{"status":403,"message":"User not registered in the Developer Dashboard"}}"#.utf8)
        XCTAssertEqual(SpotifyAccount.Refusal.from(unlisted), .notRegistered)
        let premium = Data(#"{"error":{"status":403,"message":"Premium required"}}"#.utf8)
        XCTAssertEqual(SpotifyAccount.Refusal.from(premium), .premiumRequired)
        XCTAssertEqual(SpotifyAccount.Refusal.from(Data("<html>".utf8)), .other)
        XCTAssertEqual(SpotifyAccount.Refusal.from(nil), .other)
    }
}
