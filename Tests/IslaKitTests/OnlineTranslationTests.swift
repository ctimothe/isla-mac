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
        XCTAssertEqual(Set(items.map(\.name)), ["q", "langpair", "onlyprivate", "mt"])
        XCTAssertEqual(items.first { $0.name == "q" }?.value, "Yo'q, rahmat")
        XCTAssertEqual(items.first { $0.name == "langpair" }?.value, "uz|en")
        // Machine translation only: the public memory answered "salom" with
        // "Google TRANSLEÓN".
        XCTAssertEqual(items.first { $0.name == "onlyprivate" }?.value, "1")
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
                                                          from: .english, to: .uzbek).text
        XCTAssertTrue(uzbek.localizedCaseInsensitiveContains("rahmat"), uzbek)
        // The word the public memory had poisoned.
        let hello = try await OnlineTranslation.translate("salom", from: .uzbek, to: .russian).text
        XCTAssertEqual(hello.lowercased(), "привет", hello)
    }

    // MARK: - The daily allowance (F-042)

    /// A session whose every request is answered by `MyMemoryStub`, never by
    /// the network.
    private func stubbedSession(_ answer: @escaping @Sendable (Int, String) -> Data) -> URLSession {
        MyMemoryStub.serve(answer)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MyMemoryStub.self]
        return URLSession(configuration: configuration)
    }

    private static func translated(_ text: String) -> Data {
        let body = ["responseData": ["translatedText": text], "responseStatus": 200] as [String: Any]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    private static let quotaAnswer = Data(#"{"responseData":{"translatedText":"MYMEMORY WARNING: YOU USED ALL AVAILABLE FREE TRANSLATIONS FOR TODAY."},"responseStatus":429,"responseDetails":"MYMEMORY WARNING: YOU USED ALL AVAILABLE FREE TRANSLATIONS FOR TODAY.","quotaFinished":true}"#.utf8)

    /// Pasting 100 KB with Translate Online on used to send it all, 480
    /// characters a request, one after another: 209 requests, and the
    /// anonymous allowance — 5,000 characters a day — spent on the first
    /// eleven of them while the rest kept going. Now no more than the cap
    /// leaves the Mac, and the answer says how much of the text that was.
    func testInputBeyondTheCapIsNotSent() async throws {
        let session = stubbedSession { _, _ in Self.translated("ok.") }
        let sentence = "Bugun havo juda issiq, suv ichishni unutmang. "
        let text = String(String(repeating: sentence, count: 400).prefix(10_000))

        let reply = try await OnlineTranslation.translate(text, from: .uzbek, to: .english, session: session)

        let sent = MyMemoryStub.queries
        XCTAssertLessThanOrEqual(sent.count, 10, "at most ten requests")
        XCTAssertLessThanOrEqual(sent.map(\.count).reduce(0, +), OnlineTranslation.maximumOnlineCharacters)
        XCTAssertLessThan(OnlineTranslation.maximumOnlineCharacters, 5_000,
                          "under MyMemory's published anonymous allowance of 5,000 characters a day")
        let covered = try XCTUnwrap(reply.sentCharacters, "a cut text says how much of it went")
        XCTAssertEqual(covered, sent.map(\.count).reduce(0, +))
        XCTAssertFalse(reply.text.isEmpty)

        // Text within the cap goes whole, and says nothing about a cut.
        let short = try await OnlineTranslation.translate(sentence, from: .uzbek, to: .english, session: session)
        XCTAssertNil(short.sentCharacters)
    }

    /// The service ran out of allowance on the second request, and the first
    /// request's translation — already paid for out of that allowance — was
    /// thrown away with it. It now comes back with the reason the rest did not.
    func testALaterChunkFailingKeepsEarlierText() async throws {
        let session = stubbedSession { index, _ in
            index == 0 ? Self.translated("Birinchi qism.") : Self.quotaAnswer
        }
        let text = String(repeating: "Bugun havo juda issiq, suv ichishni unutmang. ", count: 15)
        XCTAssertGreaterThan(OnlineTranslation.chunks(of: text).count, 1)

        do {
            _ = try await OnlineTranslation.translate(text, from: .uzbek, to: .english, session: session)
            XCTFail("the second piece failed")
        } catch {
            XCTAssertEqual(error as? OnlineTranslation.Failure,
                           .partial(text: "Birinchi qism.", cause: .quotaExhausted))
        }
        XCTAssertEqual(MyMemoryStub.queries.count, 2, "nothing more is asked once the allowance is spent")

        // A failure on the very first piece has nothing to keep.
        let failing = stubbedSession { _, _ in Self.quotaAnswer }
        do {
            _ = try await OnlineTranslation.translate(text, from: .uzbek, to: .english, session: failing)
            XCTFail("every piece failed")
        } catch {
            XCTAssertEqual(error as? OnlineTranslation.Failure, .quotaExhausted)
        }
    }
}

/// Answers for MyMemory in a test, and writes down every `q` it was sent.
/// Lock-guarded: the session serves requests on its own queue, off the test.
private final class MyMemoryStub: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var answer: (@Sendable (Int, String) -> Data)?
    nonisolated(unsafe) private static var sent: [String] = []

    static func serve(_ answer: @escaping @Sendable (Int, String) -> Data) {
        lock.withLock {
            self.answer = answer
            sent = []
        }
    }

    static var queries: [String] { lock.withLock { sent } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let query = request.url
            .flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first { $0.name == "q" }?.value ?? ""
        let data: Data = Self.lock.withLock {
            let index = Self.sent.count
            Self.sent.append(query)
            return Self.answer?(index, query) ?? Data()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
