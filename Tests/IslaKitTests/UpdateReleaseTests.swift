import Foundation
import XCTest
@testable import IslaKit

/// What a `releases/latest` answer says about the files behind a release, and
/// which of them Update Now is willing to use.
///
/// An asset is only as trustworthy as the answer that names it, and that answer
/// travels over the network. The Ed25519 signature protects the content, but a
/// URL that points anywhere else than Isla's own release downloads would let a
/// tampered answer choose what gets fetched, so every rule below turns the
/// asset into "absent" and the release then offers only its page.
@MainActor
final class UpdateReleaseTests: XCTestCase {
    private let base = "https://github.com/ctimothe/isla-mac/releases/download/v0.3.1/"
    private let page = "https://github.com/ctimothe/isla-mac/releases/tag/v0.3.1"

    private func answer(
        tag: String = "v0.3.1", body: String? = "Fixes the lyric sweep.", assets: [[String: Any]]? = nil
    ) -> Data {
        var object: [String: Any] = ["tag_name": tag, "html_url": page, "draft": false, "prerelease": false]
        if let body { object["body"] = body }
        object["assets"] = assets ?? [dmg(), signature()]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func dmg(
        name: String = "Isla-0.3.1.dmg", url: String? = nil, size: Any = 9_800_000
    ) -> [String: Any] {
        ["name": name, "browser_download_url": url ?? base + "Isla-0.3.1.dmg", "size": size]
    }

    private func signature(
        name: String = "Isla-0.3.1.dmg.sig", url: String? = nil, size: Any = 88
    ) -> [String: Any] {
        ["name": name, "browser_download_url": url ?? base + "Isla-0.3.1.dmg.sig", "size": size]
    }

    private func parse(_ data: Data, local: String = "0.3.0") throws -> UpdateCheck.Release {
        guard case .available(let release) = UpdateCheck.state(forRelease: data, localVersion: local) else {
            throw XCTSkip("not available: \(UpdateCheck.state(forRelease: data, localVersion: local))")
        }
        return release
    }

    // MARK: Decoding

    func testAReleaseCarriesItsImageItsSignatureAndItsNotes() throws {
        let release = try parse(answer())
        XCTAssertEqual(release.version, "0.3.1")
        XCTAssertEqual(release.page, URL(string: page)!)
        XCTAssertEqual(release.notes, "Fixes the lyric sweep.")
        XCTAssertEqual(release.dmg, UpdateCheck.Release.Asset(
            name: "Isla-0.3.1.dmg", url: URL(string: base + "Isla-0.3.1.dmg")!, size: 9_800_000
        ))
        XCTAssertEqual(release.signature, UpdateCheck.Release.Asset(
            name: "Isla-0.3.1.dmg.sig", url: URL(string: base + "Isla-0.3.1.dmg.sig")!, size: 88
        ))
    }

    func testAnAnswerWithoutAssetsOrNotesStillOffersTheRelease() throws {
        let object: [String: Any] = ["tag_name": "v0.3.1", "html_url": page]
        let release = try parse(try JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(release.notes, "")
        XCTAssertNil(release.dmg)
        XCTAssertNil(release.signature)
    }

    /// One malformed asset used to be able to fail the whole answer, and with it
    /// the rail dot and the Download button for a release that was fine.
    func testAMalformedAssetDoesNotSpoilTheRelease() throws {
        let release = try parse(answer(assets: [
            ["name": 7, "browser_download_url": NSNull()], dmg(), signature(),
        ]))
        XCTAssertNotNil(release.dmg)
        XCTAssertNotNil(release.signature)
    }

    func testTheKnownReleaseIsKeptForTheRailDot() async throws {
        let data = answer()
        let check = UpdateCheck(
            fetch: { request in (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!) },
            currentVersion: { "0.3.0" }
        )
        check.check()
        for _ in 0..<200 where check.state == .checking { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(check.hasUpdate)
        XCTAssertEqual(check.lastAvailable?.version, "0.3.1")
        XCTAssertEqual(check.lastAvailable?.dmg?.size, 9_800_000)
    }

    // MARK: Which assets are used

    private func assertImageRefused(_ asset: [String: Any], _ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let release = try parse(answer(assets: [asset, signature()]))
        XCTAssertNil(release.dmg, message, file: file, line: line)
        XCTAssertEqual(release.version, "0.3.1", "the release itself is still offered: \(message)", file: file, line: line)
        XCTAssertNotNil(release.signature, message, file: file, line: line)
    }

    private func assertSignatureRefused(_ asset: [String: Any], _ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let release = try parse(answer(assets: [dmg(), asset]))
        XCTAssertNil(release.signature, message, file: file, line: line)
        XCTAssertNotNil(release.dmg, message, file: file, line: line)
    }

    func testAnImageOffIslasReleaseDownloadsIsNotUsed() throws {
        for (label, url) in [
            ("wrong owner", "https://github.com/someone-else/isla-mac/releases/download/v0.3.1/Isla-0.3.1.dmg"),
            ("wrong repository", "https://github.com/ctimothe/other/releases/download/v0.3.1/Isla-0.3.1.dmg"),
            ("wrong tag", "https://github.com/ctimothe/isla-mac/releases/download/v0.3.0/Isla-0.3.1.dmg"),
            ("no v in the tag", "https://github.com/ctimothe/isla-mac/releases/download/0.3.1/Isla-0.3.1.dmg"),
            ("wrong file name", "https://github.com/ctimothe/isla-mac/releases/download/v0.3.1/Isla-0.3.0.dmg"),
            ("another file", "https://github.com/ctimothe/isla-mac/releases/download/v0.3.1/Other.dmg"),
            ("a query string", base + "Isla-0.3.1.dmg?token=1"),
            ("an empty query", base + "Isla-0.3.1.dmg?"),
            ("a fragment", base + "Isla-0.3.1.dmg#x"),
            ("a port", "https://github.com:8443/ctimothe/isla-mac/releases/download/v0.3.1/Isla-0.3.1.dmg"),
            ("plain http", "http://github.com/ctimothe/isla-mac/releases/download/v0.3.1/Isla-0.3.1.dmg"),
            ("a user", "https://user@github.com/ctimothe/isla-mac/releases/download/v0.3.1/Isla-0.3.1.dmg"),
            ("a password", "https://user:pw@github.com/ctimothe/isla-mac/releases/download/v0.3.1/Isla-0.3.1.dmg"),
            ("another host", "https://evil.example/ctimothe/isla-mac/releases/download/v0.3.1/Isla-0.3.1.dmg"),
            ("a look-alike host", "https://github.com.evil.example/ctimothe/isla-mac/releases/download/v0.3.1/Isla-0.3.1.dmg"),
            ("a subdomain", "https://objects.github.com/ctimothe/isla-mac/releases/download/v0.3.1/Isla-0.3.1.dmg"),
            ("a file URL", "file:///tmp/Isla-0.3.1.dmg"),
            ("an encoded path", "https://github.com/ctimothe/isla-mac/releases/download/v0.3.1/Isla%2D0.3.1.dmg"),
            ("a dot segment", "https://github.com/ctimothe/isla-mac/releases/download/v0.3.1/../v0.3.1/Isla-0.3.1.dmg"),
            ("a doubled slash", "https://github.com/ctimothe/isla-mac/releases/download//v0.3.1/Isla-0.3.1.dmg"),
        ] {
            try assertImageRefused(dmg(url: url), label)
        }
    }

    func testAnImageWhoseNameDisagreesWithItsURLIsNotUsed() throws {
        try assertImageRefused(dmg(name: "Isla-0.3.0.dmg"), "name differs from the URL's file")
        try assertImageRefused(dmg(name: "isla-0.3.1.dmg"), "case differs")
        try assertImageRefused(dmg(name: ""), "empty name")
    }

    func testTheImageSizeIsBounded() throws {
        let cap = 300 * 1024 * 1024
        let atCap = try parse(answer(assets: [dmg(size: cap), signature()]))
        XCTAssertEqual(atCap.dmg?.size, Int64(cap), "300 MB exactly is allowed")
        try assertImageRefused(dmg(size: cap + 1), "one byte over 300 MB")
        try assertImageRefused(dmg(size: 0), "zero size")
        try assertImageRefused(dmg(size: -5), "negative size")
        try assertImageRefused(dmg(size: "9800000"), "size as a string")
        try assertImageRefused(["name": "Isla-0.3.1.dmg", "browser_download_url": base + "Isla-0.3.1.dmg"], "no size")
    }

    func testASignatureIsHeldToTheSameRules() throws {
        try assertSignatureRefused(signature(url: "https://github.com/someone-else/isla-mac/releases/download/v0.3.1/Isla-0.3.1.dmg.sig"), "wrong owner")
        try assertSignatureRefused(signature(url: "https://github.com/ctimothe/isla-mac/releases/download/v0.3.0/Isla-0.3.1.dmg.sig"), "wrong tag")
        try assertSignatureRefused(signature(url: base + "Isla-0.3.1.dmg.sig?x=1"), "query")
        try assertSignatureRefused(signature(url: "http://github.com/ctimothe/isla-mac/releases/download/v0.3.1/Isla-0.3.1.dmg.sig"), "http")
        try assertSignatureRefused(signature(name: "Isla-0.3.1.dmg"), "name of the image")
        try assertSignatureRefused(signature(size: 1025), "over 1 KB")
        try assertSignatureRefused(signature(size: 0), "zero size")
        let atCap = try parse(answer(assets: [dmg(), signature(size: 1024)]))
        XCTAssertEqual(atCap.signature?.size, 1024)
    }

    func testAReleaseWithoutASignatureOffersNoInstallableImage() throws {
        let release = try parse(answer(assets: [dmg()]))
        XCTAssertNotNil(release.dmg)
        XCTAssertNil(release.signature)
        XCTAssertFalse(release.isInstallable)
        XCTAssertTrue(try self.parse(answer()).isInstallable)
        XCTAssertFalse(try self.parse(answer(assets: [signature()])).isInstallable)
    }

    func testTheSignatureIsNeverTakenForTheImage() throws {
        // The .sig under the image's name must not be accepted as the image.
        let release = try parse(answer(assets: [
            ["name": "Isla-0.3.1.dmg", "browser_download_url": base + "Isla-0.3.1.dmg.sig", "size": 88],
            signature(),
        ]))
        XCTAssertNil(release.dmg)
    }

    // MARK: Notes

    func testNotesAreCappedAtFourKilobytesOnALineBoundary() throws {
        let line = String(repeating: "x", count: 99) + "\n"        // 100 bytes
        let long = String(repeating: line, count: 100)             // 10,000 bytes
        let notes = try parse(answer(body: long)).notes
        XCTAssertLessThanOrEqual(notes.utf8.count, 4096)
        XCTAssertGreaterThan(notes.utf8.count, 3900, "as much as fits")
        XCTAssertTrue(long.hasPrefix(notes))
        XCTAssertTrue(notes.allSatisfy { $0 == "x" || $0 == "\n" })
        XCTAssertEqual(notes.split(separator: "\n").map(\.count), Array(repeating: 99, count: notes.split(separator: "\n").count),
                       "no line is cut in half")
    }

    func testAShortNoteIsKeptWhole() throws {
        XCTAssertEqual(try parse(answer(body: "- one\n- two")).notes, "- one\n- two")
        XCTAssertEqual(try parse(answer(body: "  \n")).notes, "", "only whitespace is no note")
        XCTAssertEqual(try parse(answer(body: "a\r\nb")).notes, "a\nb", "Windows line ends from the web editor")
    }

    func testALongLineWithNoBreakIsCutOnACharacterNotAByte() throws {
        let long = String(repeating: "я", count: 5000)               // 2 bytes each
        let notes = try parse(answer(body: long)).notes
        XCTAssertLessThanOrEqual(notes.utf8.count, 4096)
        XCTAssertTrue(notes.allSatisfy { $0 == "я" })
        XCTAssertFalse(notes.isEmpty)
    }
}
