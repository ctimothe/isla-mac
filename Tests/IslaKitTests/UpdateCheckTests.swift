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
            .available(version: "0.3.0", page: URL(string: "https://github.com/ctimothe/isla-mac/releases/tag/v0.3.0")!)
        )
        XCTAssertEqual(UpdateCheck.state(forRelease: newer, localVersion: "0.3.0"), .upToDate(version: "0.3.0"))
        let draft = Data(#"{"tag_name":"v9.0.0","html_url":"https://example.com","draft":true}"#.utf8)
        XCTAssertEqual(UpdateCheck.state(forRelease: draft, localVersion: "0.2.0"), .failed)
        XCTAssertEqual(UpdateCheck.state(forRelease: Data("nope".utf8), localVersion: "0.2.0"), .failed)
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
        XCTAssertEqual(check.state, .failed)
    }

    /// It reaches the network, so it is off until the user turns it on.
    func testTheAutomaticCheckIsOffByDefault() {
        let defaults = UserDefaults.standard
        let had = defaults.object(forKey: UpdateCheck.automaticKey)
        defer {
            if let had { defaults.set(had, forKey: UpdateCheck.automaticKey) }
            else { defaults.removeObject(forKey: UpdateCheck.automaticKey) }
        }
        defaults.removeObject(forKey: UpdateCheck.automaticKey)
        XCTAssertFalse(UpdateCheck.automaticEnabled)
    }
}

private final class Box<Value>: @unchecked Sendable {
    var value: Value?
}
