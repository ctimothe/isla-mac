import Foundation
import XCTest
@testable import IslaKit

/// Hearing about a new version, without the check ever offering the wrong one
/// or running unasked.
@MainActor
final class UpdateCheckTests: XCTestCase {

    func testLaterNumbersAreNewer() {
        XCTAssertTrue(UpdateCheck.isNewer("0.3.0", than: "0.2.0"))
        XCTAssertTrue(UpdateCheck.isNewer("0.10.0", than: "0.9.3"), "numbers, not strings")
        XCTAssertTrue(UpdateCheck.isNewer("1.0", than: "0.9.9"))
        XCTAssertTrue(UpdateCheck.isNewer("0.2.1", than: "0.2"))
    }

    func testTheSameOrOlderIsNotNewer() {
        XCTAssertFalse(UpdateCheck.isNewer("0.2.0", than: "0.2.0"))
        XCTAssertFalse(UpdateCheck.isNewer("0.2", than: "0.2.0"))
        XCTAssertFalse(UpdateCheck.isNewer("0.1.9", than: "0.2.0"))
    }

    /// A beta running locally is older than the same numbers released, and a
    /// pre-release on GitHub is never offered.
    func testPreReleases() {
        XCTAssertTrue(UpdateCheck.isNewer("0.3.0", than: "0.3.0-beta.1"))
        XCTAssertFalse(UpdateCheck.isNewer("0.4.0-beta.1", than: "0.3.0"))
    }

    /// A malformed tag must not become a download button.
    func testAMalformedTagIsNeverNewer() {
        XCTAssertFalse(UpdateCheck.isNewer("latest", than: "0.2.0"))
        XCTAssertFalse(UpdateCheck.isNewer("", than: "0.2.0"))
        XCTAssertFalse(UpdateCheck.isNewer("1..0", than: "0.2.0"))
        XCTAssertTrue(UpdateCheck.isNewer("0.3.0", than: "dev"), "a build with no version still hears of releases")
    }

    func testAReleaseAnswerBecomesAState() throws {
        let newer = Data(#"{"tag_name":"v0.3.0","html_url":"https://github.com/ctimothe/isla-mac/releases/tag/v0.3.0","draft":false,"prerelease":false}"#.utf8)
        XCTAssertEqual(
            UpdateCheck.state(forRelease: newer, localVersion: "0.2.0"),
            .available(UpdateCheck.Release(version: "0.3.0", page: URL(string: "https://github.com/ctimothe/isla-mac/releases/tag/v0.3.0")!))
        )
        XCTAssertEqual(UpdateCheck.state(forRelease: newer, localVersion: "0.3.0"), .upToDate(version: "0.3.0"))
        let draft = Data(#"{"tag_name":"v9.0.0","html_url":"https://example.com","draft":true}"#.utf8)
        XCTAssertEqual(UpdateCheck.state(forRelease: draft, localVersion: "0.2.0"), .failed(.server))
        XCTAssertEqual(UpdateCheck.state(forRelease: Data("nope".utf8), localVersion: "0.2.0"), .failed(.server))
    }

    /// "Download Isla x" opens the answer's page, so a tampered or intercepted
    /// answer must not be able to put a file:// or off-domain page behind an
    /// Isla-branded button (G-027).
    func testAReleasePageOffGitHubIsRefused() {
        func answer(_ page: String) -> Data {
            Data(#"{"tag_name":"v9.9.9","html_url":"\#(page)","draft":false,"prerelease":false}"#.utf8)
        }
        for page in [
            "file:///Applications",
            "https://evil.example/ctimothe/isla-mac/releases/tag/v9.9.9",
            "http://github.com/ctimothe/isla-mac/releases/tag/v9.9.9",
            "https://github.com.evil.example/ctimothe/isla-mac/releases/tag/v9.9.9",
            "https://github.com/someone-else/isla-mac/releases/tag/v9.9.9",
            "https://github.com/ctimothe/isla-mac/issues/1",
            "https://user@github.com/ctimothe/isla-mac/releases/tag/v9.9.9",
        ] {
            XCTAssertEqual(UpdateCheck.state(forRelease: answer(page), localVersion: "0.2.0"), .failed(.server), page)
        }
        let good = "https://github.com/ctimothe/isla-mac/releases/tag/v9.9.9"
        XCTAssertEqual(
            UpdateCheck.state(forRelease: answer(good), localVersion: "0.2.0"),
            .available(UpdateCheck.Release(version: "9.9.9", page: URL(string: good)!))
        )
    }

    /// The request goes to GitHub's releases API and names the version asking,
    /// and nothing else.
    func testTheCheckAsksGitHubAndReportsTheAnswer() async throws {
        let seen = Box<URLRequest>()
        let check = UpdateCheck(
            fetch: { request in
                seen.value = request
                let body = Data(#"{"tag_name":"v0.9.0","html_url":"https://github.com/ctimothe/isla-mac/releases/tag/v0.9.0"}"#.utf8)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (body, response)
            },
            currentVersion: { "0.2.0" }
        )
        check.check()
        for _ in 0..<200 where check.state == .checking {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(check.hasUpdate)
        XCTAssertEqual(seen.value?.url, UpdateCheck.latestReleaseURL)
        XCTAssertEqual(seen.value?.value(forHTTPHeaderField: "User-Agent"), "Isla/0.2.0")
        XCTAssertNil(seen.value?.httpBody)
    }

    func testAFailedRequestSaysSo() async throws {
        let check = UpdateCheck(fetch: { _ in throw URLError(.notConnectedToInternet) }, currentVersion: { "0.2.0" })
        check.check()
        for _ in 0..<200 where check.state == .checking {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(check.state, .failed(.offline))
    }

    private func settle(_ check: UpdateCheck) async throws {
        for _ in 0..<200 where check.state == .checking {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// A Tuesday offline failure used to erase Monday's "Update available":
    /// the rail dot and the Download row vanished with it.
    func testAKnownUpdateSurvivesAFailedRecheck() async throws {
        let calls = Box<Int>()
        calls.value = 0
        let check = UpdateCheck(
            fetch: { request in
                calls.value! += 1
                if calls.value! > 1 { throw URLError(.notConnectedToInternet) }
                let body = Data(#"{"tag_name":"v9.9.9","html_url":"https://github.com/ctimothe/isla-mac/releases/tag/v9.9.9"}"#.utf8)
                return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            },
            currentVersion: { "0.2.0" }
        )
        check.check()
        try await settle(check)
        XCTAssertTrue(check.hasUpdate)
        check.check()
        XCTAssertEqual(check.state, .checking)
        XCTAssertTrue(check.hasUpdate, "an in-flight recheck keeps the known update")
        try await settle(check)
        XCTAssertEqual(check.state, .failed(.offline))
        XCTAssertTrue(check.hasUpdate, "a failed recheck keeps the known update")
        XCTAssertEqual(check.lastAvailable?.version, "9.9.9")
    }

    /// Only a newer answer that says up to date (the user installed it) clears it.
    func testAnUpToDateAnswerClearsAKnownUpdate() async throws {
        let version = Box<String>()
        version.value = "9.9.9"
        let check = UpdateCheck(
            fetch: { request in
                let body = Data(#"{"tag_name":"v\#(version.value!)","html_url":"https://github.com/ctimothe/isla-mac/releases/tag/v1"}"#.utf8)
                return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            },
            currentVersion: { "0.2.0" }
        )
        check.check()
        try await settle(check)
        XCTAssertTrue(check.hasUpdate)
        version.value = "0.2.0"
        check.check()
        try await settle(check)
        XCTAssertFalse(check.hasUpdate)
        XCTAssertNil(check.lastAvailable)
    }

    /// A rate limit used to read as "Could not reach GitHub".
    func testARateLimitIsNamed() async throws {
        func outcome(status: Int, headers: [String: String]) async throws -> UpdateCheck.State {
            let check = UpdateCheck(
                fetch: { request in
                    (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
                },
                currentVersion: { "0.2.0" }
            )
            check.check()
            try await settle(check)
            return check.state
        }
        let limited = try await outcome(status: 403, headers: ["x-ratelimit-remaining": "0"])
        XCTAssertEqual(limited, .failed(.rateLimited))
        let tooMany = try await outcome(status: 429, headers: [:])
        XCTAssertEqual(tooMany, .failed(.rateLimited))
        let server = try await outcome(status: 500, headers: [:])
        XCTAssertEqual(server, .failed(.server))
        let forbidden = try await outcome(status: 403, headers: [:])
        XCTAssertEqual(forbidden, .failed(.server), "a 403 without the exhausted-quota header is not a rate limit")
    }

    /// On by default since 2026-10-20 (plan 2026-10-20-updates-for-everyone):
    /// every merge to main is released, and a copy that never asks never
    /// hears of one. A user who turned it off stays off.
    func testTheAutomaticCheckIsOnByDefaultAndStaysOffWhenTurnedOff() {
        let defaults = UserDefaults.standard
        let had = defaults.object(forKey: UpdateCheck.automaticKey)
        defer {
            if let had { defaults.set(had, forKey: UpdateCheck.automaticKey) }
            else { defaults.removeObject(forKey: UpdateCheck.automaticKey) }
        }
        defaults.removeObject(forKey: UpdateCheck.automaticKey)
        XCTAssertTrue(UpdateCheck.automaticEnabled, "absent means on")
        defaults.set(false, forKey: UpdateCheck.automaticKey)
        XCTAssertFalse(UpdateCheck.automaticEnabled, "the user's off is kept")
    }

    /// Hourly: a release reaches the island within the hour, at 24 requests a
    /// day, well under GitHub's 60 an hour for an address without a token.
    func testTheAutomaticCheckRunsHourly() {
        XCTAssertEqual(UpdateCheck.automaticInterval, 60 * 60)
        XCTAssertLessThanOrEqual(UpdateCheck.automaticTolerance, 10 * 60)
    }
}

private final class Box<Value>: @unchecked Sendable {
    var value: Value?
}
