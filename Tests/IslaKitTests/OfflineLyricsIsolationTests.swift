import Foundation
import XCTest
@testable import IslaKit

final class OfflineLyricsIsolationTests: XCTestCase {
    func testLyricsSourcesContainNoNetworkClientOrBrokerNames() throws {
        let serviceDirectory = Self.projectRoot
            .appendingPathComponent("Sources/IslaKit/Services")
        let sources = try Self.lyricServiceFiles(in: serviceDirectory)
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")

        for forbidden in [
            "URLSession", "BrokerLyricsResolver", "CachedLyricsResolver",
            "LRCLIB", "Kugou", "QQ", "AMLL",
        ] {
            XCTAssertFalse(sources.contains(forbidden), forbidden)
        }
    }

    @MainActor
    func testLocalLibraryDeclaresNetworkForbidden() {
        XCTAssertEqual(LocalLyricsLibrary.networkPolicy, .forbidden)
    }

    private static var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func lyricServiceFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        .filter {
            $0.pathExtension == "swift" &&
                $0.lastPathComponent.localizedCaseInsensitiveContains("lyric")
        }
    }
}
