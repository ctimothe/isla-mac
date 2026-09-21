import Foundation
import XCTest
@testable import IslaKit

/// Where the lyric path may and may not reach the network.
///
/// This used to assert that *no* lyric source mentioned a network client at
/// all — the enforcement of the offline design approved on 2026-09-13. The
/// amendment of 2026-09-21 admits exactly one exception, because a streamed
/// track has no file on this Mac and so no offline lookup can ever find words
/// for it. The guard is narrowed rather than dropped: one named file may talk
/// to one named service, and every other lyric source stays as local as it was.
final class OfflineLyricsIsolationTests: XCTestCase {
    /// The single file permitted to reach the network, and the only one.
    static let networkedSource = "OnlineLyrics.swift"

    func testOnlyOneLyricSourceReachesTheNetwork() throws {
        let files = try Self.lyricServiceFiles()
        XCTAssertTrue(
            files.contains { $0.lastPathComponent == Self.networkedSource },
            "the exception must exist to be bounded"
        )
        for file in files where file.lastPathComponent != Self.networkedSource {
            let source = try String(contentsOf: file, encoding: .utf8)
            for forbidden in ["URLSession", "URLRequest", "dataTask", "lrclib"] {
                XCTAssertFalse(
                    source.contains(forbidden),
                    "\(file.lastPathComponent) must not reach the network: \(forbidden)"
                )
            }
        }
    }

    /// The providers removed on 2026-09-14 stay removed. The amendment admits
    /// LRCLIB and nothing else — no scraping, no second catalogue, no broker
    /// for Isla to operate.
    func testTheRemovedProvidersAndTheBrokerStayRemoved() throws {
        let sources = try Self.lyricServiceFiles()
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        for forbidden in [
            "BrokerLyricsResolver", "CachedLyricsResolver", "LicensedLyricsCache",
            "Kugou", "AMLL", "musixmatch", "genius.com",
        ] {
            XCTAssertFalse(sources.contains(forbidden), forbidden)
        }
    }

    /// One service, named in one place, over TLS — its exact query and, since
    /// 2026-09-21, its search, which asks the same host with less.
    func testTheOneServiceIsTheDocumentedOne() {
        XCTAssertEqual(OnlineLyrics.endpoint, "https://lrclib.net/api/get")
        XCTAssertEqual(OnlineLyrics.searchEndpoint, "https://lrclib.net/api/search")
        for endpoint in [OnlineLyrics.endpoint, OnlineLyrics.searchEndpoint] {
            XCTAssertEqual(URL(string: endpoint)?.host, "lrclib.net", endpoint)
            XCTAssertEqual(URL(string: endpoint)?.scheme, "https", endpoint)
        }
    }

    /// The local library is still forbidden the network outright: the exception
    /// sits beside it, never inside it.
    @MainActor
    func testLocalLibraryDeclaresNetworkForbidden() {
        XCTAssertEqual(LocalLyricsLibrary.networkPolicy, .forbidden)
    }

    /// And it is off until asked for. The switch is the whole privacy claim.
    @MainActor
    func testOnlineLookupIsOffByDefault() {
        UserDefaults.standard.removeObject(forKey: NotchViewModel.onlineLyricsKey)
        XCTAssertFalse(NotchViewModel.onlineLyricsEnabled)
    }

    private static func lyricServiceFiles() throws -> [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("Sources/IslaKit/Services"),
            includingPropertiesForKeys: nil
        ).filter {
            $0.pathExtension == "swift" &&
                $0.lastPathComponent.localizedCaseInsensitiveContains("lyric")
        }
    }
}
