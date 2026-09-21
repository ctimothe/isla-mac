import AppKit
import XCTest
@testable import IslaKit

/// Compiles every AppleScript the bridge sends, against whichever of the two
/// players is installed here.
///
/// macOS 27's AppleScript reserves the ordinal suffixes (`st`, `nd`, `rd`,
/// `th`) as words. The state script named a variable `st`, so from then on it
/// failed to compile on every call — and a script that
/// does not compile answers exactly like a player with nothing to say. The
/// island lost every paused song under a film and the fallback path went blank,
/// with nothing but a log line to show for it. Compiling needs no Automation
/// consent and does not launch the player: both ship a static dictionary.
@MainActor
final class PlayerScriptTests: XCTestCase {
    func testEveryBridgeScriptCompilesAgainstTheInstalledPlayers() throws {
        var compiled = 0
        var unreadable: [String] = []
        for app in PlayerApp.allCases {
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) != nil else { continue }
            // A machine that cannot read the player's dictionary — a headless
            // runner, say — cannot judge our scripts either; every one would
            // fail for a reason that has nothing to do with them.
            if let reason = dictionaryUnreadable(for: app) {
                unreadable.append("\(app.displayName): \(reason)")
                continue
            }
            for (name, source) in PlayerBridge.Script.everySource(for: app) {
                let script = try XCTUnwrap(NSAppleScript(source: source), "\(app) \(name)")
                var error: NSDictionary?
                let ok = script.compileAndReturnError(&error)
                XCTAssertTrue(
                    ok,
                    "\(app.displayName) \(name) does not compile: \(error?[NSAppleScript.errorMessage] ?? "unknown error")"
                )
                compiled += 1
            }
        }
        if compiled == 0 {
            throw XCTSkip("no player's dictionary could be read here. \(unreadable.joined(separator: "; "))")
        }
    }

    /// Why a script made of nothing but the player's own terminology fails to
    /// compile here, or nil when it compiles. Nothing of ours is in it — no
    /// variables — so a failure is the machine's, not the bridge's.
    private func dictionaryUnreadable(for app: PlayerApp) -> String? {
        var error: NSDictionary?
        let probe = NSAppleScript(source: "tell application id \"\(app.bundleID)\" to get player state")
        if probe?.compileAndReturnError(&error) == true { return nil }
        return "\(error?[NSAppleScript.errorMessage] ?? "unknown error")"
    }

    /// The state script's answer keeps "nothing loaded" apart from "could not
    /// be asked": only the first may let a held song go.
    func testTheStateAnswerTellsNothingLoadedFromCannotBeAsked() {
        func reply(_ raw: String) -> PlayerBridge.StateReply { PlayerBridge.interpret(raw, app: .spotify) }
        let s = "\u{1}"

        guard case let .loaded(state) = reply(["paused", "Song", "Artist", "Album", "248000", "80800", "https://i.scdn.co/x"].joined(separator: s)) else {
            return XCTFail("a full answer is a loaded song")
        }
        XCTAssertFalse(state.isPlaying)
        XCTAssertEqual(state.position, 80.8, accuracy: 0.001)
        XCTAssertEqual(state.duration, 248, accuracy: 0.001)

        guard case .empty = reply("error\(s)-1728") else { return XCTFail("no current track is nothing loaded") }
        guard case .empty = reply(["stopped", "", "", "", "0", "0", ""].joined(separator: s)) else {
            return XCTFail("a track with no name is nothing loaded")
        }
        guard case .unknown = reply("error\(s)-1743") else { return XCTFail("withheld consent is not an answer") }
        guard case .unknown = reply("error\(s)-1712") else { return XCTFail("a timeout is not an answer") }
        guard case .unknown = reply("garbage") else { return XCTFail("a malformed answer is not an answer") }
    }

    /// Names the script's variables away from the words AppleScript reserves,
    /// so the next reserved word is caught here and not by a blank island.
    func testTheStateScriptsNameNoShortVariables() {
        for app in PlayerApp.allCases {
            let source = PlayerBridge.Script.state(for: app)
            let names = source.matches(of: /set (\w+) to/).map { String($0.output.1) }
            XCTAssertFalse(names.isEmpty, "\(app) state script sets no variables")
            for name in names {
                XCTAssertGreaterThanOrEqual(name.count, 6, "\(app) state script names a variable `\(name)`")
            }
        }
    }
}
