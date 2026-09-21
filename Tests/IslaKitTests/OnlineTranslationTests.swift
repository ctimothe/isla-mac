import Foundation
import XCTest
@testable import IslaKit

/// The one part of Translate that reaches the network.
final class OnlineTranslationTests: XCTestCase {
    /// One service, named in one place, over TLS, asked for exactly the text
    /// and its two languages.
    func testTheRequestCarriesOnlyTheTextAndTheLanguages() throws {
        let request = try XCTUnwrap(OnlineTranslation.request(for: "Yo'q, rahmat", from: .uzbek, to: .english))
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "api.mymemory.translated.net")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(Set(items.map(\.name)), ["q", "langpair"])
        XCTAssertEqual(items.first { $0.name == "q" }?.value, "Yo'q, rahmat")
        XCTAssertEqual(items.first { $0.name == "langpair" }?.value, "uz|en")
        XCTAssertEqual(OnlineTranslation.serviceCode(for: .chinese), "zh-CN")
    }

    /// Longer than one query: split at sentences, every piece within the
    /// service's limit, nothing lost.
    func testLongTextIsSplitAtSentencesWithinTheLimit() {
        let sentence = "Bugun havo juda issiq, suv ichishni unutmang. "
        let text = String(repeating: sentence, count: 30)
        let pieces = OnlineTranslation.chunks(of: text)
        XCTAssertGreaterThan(pieces.count, 1)
        for piece in pieces {
            XCTAssertLessThanOrEqual(piece.count, OnlineTranslation.maximumQuery)
            XCTAssertTrue(piece.hasSuffix("."), "cut at a sentence, not mid-way: \(piece.suffix(20))")
        }
        XCTAssertEqual(pieces.joined(separator: " "), text.trimmingCharacters(in: .whitespaces))

        let unbroken = String(repeating: "a", count: 1_200)
        XCTAssertTrue(OnlineTranslation.chunks(of: unbroken).allSatisfy { $0.count <= OnlineTranslation.maximumQuery })
        XCTAssertEqual(OnlineTranslation.chunks(of: unbroken).joined(), unbroken)
        XCTAssertEqual(OnlineTranslation.chunks(of: "  short  "), ["short"])
        XCTAssertEqual(OnlineTranslation.chunks(of: "   "), [])
    }

    /// The service answers with HTML entities in plain text.
    func testEntitiesAreDecodedBeforeTheyReachTheScreen() throws {
        let data = Data(#"{"responseData":{"translatedText":"Eng yaqin temir yo&#39;l stansiyasi qayerda? &quot;6&quot; &amp; &#x41;"},"responseStatus":200}"#.utf8)
        XCTAssertEqual(try OnlineTranslation.decode(data), "Eng yaqin temir yo'l stansiyasi qayerda? \"6\" & A")
        XCTAssertEqual(OnlineTranslation.unescapingEntities("AT&T & co"), "AT&T & co")
    }

    func testRefusalsAndTheDailyAllowanceAreToldApart() {
        let quota = Data(#"{"responseData":{"translatedText":"MYMEMORY WARNING: YOU USED ALL AVAILABLE FREE TRANSLATIONS FOR TODAY."},"responseStatus":429,"responseDetails":"MYMEMORY WARNING: YOU USED ALL AVAILABLE FREE TRANSLATIONS FOR TODAY.","quotaFinished":true}"#.utf8)
        XCTAssertThrowsError(try OnlineTranslation.decode(quota)) {
            XCTAssertEqual($0 as? OnlineTranslation.Failure, .quotaExhausted)
        }
        let tooLong = Data(#"{"responseData":{"translatedText":"QUERY LENGTH LIMIT EXCEEDED. MAX ALLOWED QUERY : 500 CHARS"},"responseStatus":"403","responseDetails":"QUERY LENGTH LIMIT EXCEEDED. MAX ALLOWED QUERY : 500 CHARS"}"#.utf8)
        XCTAssertThrowsError(try OnlineTranslation.decode(tooLong)) {
            XCTAssertEqual($0 as? OnlineTranslation.Failure,
                           .refused("QUERY LENGTH LIMIT EXCEEDED. MAX ALLOWED QUERY : 500 CHARS"))
        }
        XCTAssertThrowsError(try OnlineTranslation.decode(Data("<html>".utf8))) {
            XCTAssertEqual($0 as? OnlineTranslation.Failure, .unreachable)
        }
    }

    /// Only the one file talks to the network, of everything in Translate.
    func testOnlyOneTranslationSourceReachesTheNetwork() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let services = root.appendingPathComponent("Sources/IslaKit/Services")
        let files = try FileManager.default.contentsOfDirectory(at: services, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.localizedCaseInsensitiveContains("translat") }
        XCTAssertTrue(files.contains { $0.lastPathComponent == "OnlineTranslation.swift" })
        for file in files where file.lastPathComponent != "OnlineTranslation.swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            for forbidden in ["URLSession", "URLRequest", "dataTask", "mymemory"] {
                XCTAssertFalse(source.contains(forbidden), "\(file.lastPathComponent) must not reach the network")
            }
        }
    }

    /// Against the real service, only when asked: `ONLINE_TRANSLATION_LIVE=1`.
    func testLiveUzbek() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ONLINE_TRANSLATION_LIVE"] == "1")
        let uzbek = try await OnlineTranslation.translate("Thank you very much for your help today.",
                                                          from: .english, to: .uzbek)
        XCTAssertTrue(uzbek.localizedCaseInsensitiveContains("rahmat"), uzbek)
    }
}
