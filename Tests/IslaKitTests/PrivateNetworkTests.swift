import Foundation
import XCTest
@testable import IslaKit

/// Every request Isla makes to a third party goes through one session that
/// keeps nothing (audit G-016).
///
/// With Translate Online on, the user's text travels in the `q=` query of a
/// GET. Over `URLSession.shared` that URL and the translation could sit in
/// `~/Library/Caches/com.ctimothe.isla/Cache.db` indefinitely, beside LRCLIB's
/// lookups (title, artist, album) and Spotify's answers — the Translate pane
/// covers that text behind a privacy screen while the disk kept a copy.
final class PrivateNetworkTests: XCTestCase {
    /// No disk cache, no cookie jar, no saved credentials, and no reading an
    /// answer back out of a cache someone else filled. `.ephemeral` alone
    /// still keeps an in-memory cache and cookie store for the life of the
    /// process; they are nil'd outright so nothing is kept even that long.
    func testPrivateSessionKeepsNothing() {
        let configuration = PrivateNetwork.session.configuration
        XCTAssertNil(configuration.urlCache, "a response cache can hold the translated text")
        XCTAssertNil(configuration.httpCookieStorage, "cookies would tie one request to the next")
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }

    /// The shared session is the one with the disk cache, so no source may
    /// name it — not as a call, and not as a parameter's `= .shared` default,
    /// which is how two of the five uses hid. Comments are skipped: they may
    /// say why.
    /// And no source but `PrivateNetwork.swift` may build a session of its
    /// own, or a `.default` configuration would bring the cache straight back.
    func testNoSourceUsesTheSharedSession() throws {
        var offenders: [String] = []
        var builders: [String] = []
        for file in try Self.islaKitSources() {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") { continue }
                let place = "\(file.lastPathComponent):\(index + 1)"
                if code.contains("URLSession.shared") || code.contains("URLSession = .shared") {
                    offenders.append(place)
                }
                if code.contains("URLSession(") && file.lastPathComponent != "PrivateNetwork.swift" {
                    builders.append(place)
                }
            }
        }
        XCTAssertEqual(offenders, [], "use PrivateNetwork.session")
        XCTAssertEqual(builders, [], "only PrivateNetwork builds a session")
    }

    /// The shared cache that earlier builds filled is emptied once, on the
    /// first launch of a build that no longer writes to it, and never again:
    /// the flag is what makes it once.
    func testTheOldCacheIsPurgedExactlyOnce() throws {
        let suite = "PrivateNetworkTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = URLCache(memoryCapacity: 1 << 20, diskCapacity: 0)
        // An ephemeral configuration's jar lives in memory only, so the test
        // never writes a cookie file anywhere, let alone into the real one.
        let cookies = try XCTUnwrap(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let request = URLRequest(url: URL(string: "https://api.mymemory.translated.net/get?q=private")!)

        func fill() throws {
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Cache-Control": "max-age=3600"]
            ))
            cache.storeCachedResponse(CachedURLResponse(response: response, data: Data("x".utf8)), for: request)
            let cookie = try XCTUnwrap(HTTPCookie(properties: [
                .domain: "api.mymemory.translated.net", .path: "/", .name: "id", .value: "1",
                .expires: Date().addingTimeInterval(3600),
            ]))
            cookies.setCookie(cookie)
        }

        try fill()
        XCTAssertNotNil(cache.cachedResponse(for: request), "precondition: the fake cache holds a row")
        XCTAssertFalse(cookies.cookies?.isEmpty ?? true, "precondition: the fake jar holds a cookie")

        PrivateNetwork.purgeLegacyStorage(defaults: defaults, cache: cache, cookies: cookies)
        XCTAssertNil(cache.cachedResponse(for: request))
        XCTAssertTrue(cookies.cookies?.isEmpty ?? true)
        XCTAssertTrue(defaults.bool(forKey: PrivateNetwork.purgedKey))

        // A second launch leaves alone whatever is there now.
        try fill()
        PrivateNetwork.purgeLegacyStorage(defaults: defaults, cache: cache, cookies: cookies)
        XCTAssertNotNil(cache.cachedResponse(for: request))
        XCTAssertFalse(cookies.cookies?.isEmpty ?? true)
    }

    private static func islaKitSources() throws -> [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/IslaKit")
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let files = walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "the scan must find the sources to mean anything")
        return files
    }
}
