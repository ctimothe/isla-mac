import AppKit
import XCTest
@testable import IslaKit

/// The features that were there and hard to find or impossible to switch off:
/// lyrics behind two Settings switches, a clipboard history with no off
/// switch, and a Spotify heart that vanished without a word.
@MainActor
final class FindabilityTests: XCTestCase {

    // MARK: Lyrics captions

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

    /// A switch turned back on starts from the pasteboard as it is now. A
    /// password copied while history was off must not be recorded by the
    /// first poll after it is turned on.
    func testTurningHistoryBackOnSkipsWhatWasCopiedWhileItWasOff() {
        let board = NSPasteboard(name: .init("FindabilityTests.\(UUID())"))
        let store = ClipboardStore(pasteboard: board)
        board.clearContents()
        board.setString("copied while off", forType: .string)
        store.startFresh()
        store.pollNow()
        XCTAssertTrue(store.items.isEmpty)
        board.clearContents()
        board.setString("copied after", forType: .string)
        store.pollNow()
        XCTAssertEqual(store.items.first?.preview, "copied after")
        store.stop()
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
        XCTAssertEqual(SpotifyAccount.Refusal.from(Data("<html>".utf8)), .other(nil))
        XCTAssertEqual(SpotifyAccount.Refusal.from(nil), .other(nil))
    }

    /// Spotify demands Premium of the developer who registered a Development
    /// Mode app, not of everyone who uses it. The note used to tell the
    /// listener their own plan was the problem — something a Premium listener
    /// could do nothing about, and a free listener would pay to not fix.
    func testAPremiumRefusalDoesNotAddressTheListener() {
        let explanation = SpotifyAccount.Refusal.premiumRequired.explanation
        XCTAssertEqual(
            explanation,
            "Spotify asks for Premium on Isla’s registration."
        )
        XCTAssertFalse(explanation.contains("needs Spotify Premium"))
        XCTAssertFalse(explanation.contains("your"), "names the registration, not the listener's plan")
    }
}
