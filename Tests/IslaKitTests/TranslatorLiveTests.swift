import XCTest
@testable import IslaKit

/// The whole translator against this Mac's real engines, only when asked:
/// `TRANSLATOR_LIVE=1`. It needs Apple's frameworks as the Mac has them and,
/// for Uzbek, the network — neither of which a build machine promises.
@MainActor
final class TranslatorLiveTests: XCTestCase {
    func testEveryEngineAnswersForThePairsItOwns() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TRANSLATOR_LIVE"] == "1")
        let suite = "TranslatorLiveTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let translator = Translator(defaults: defaults)
        let cases: [(String, TranslationLanguage?, TranslationLanguage)] = [
            ("Where is the nearest train station? I need to be there by six.", nil, .russian),
            ("Привет, как дела? Давно не виделись.", nil, .russian),
            ("Delete all my files", .english, .turkish),
            ("Thank you very much for your help today.", .english, .korean),
            ("Thank you very much for your help today.", .english, .uzbek),
            ("Men ertaga ertalab ishga boraman.", nil, .english),
            // What the owner typed on 2026-09-21, with the source detecting.
            ("salom", nil, .russian),
            ("yaxshimisiz", nil, .russian),
            ("yaxshimisiz jigar!!!", .uzbek, .russian),
        ]
        for online in [false, true] {
            defaults.set(online, forKey: NotchViewModel.onlineTranslationKey)
            for (text, source, target) in cases {
                translator.choose(source: source)
                translator.choose(target: target)
                translator.input = text
                let started = Date()
                await translator.translate()
                let route = translator.route
                print(String(
                    format: "LIVE online=%d %@→%@ %.2fs engine=%@ | %@ | %@",
                    online ? 1 : 0, route.source.code, route.target.code, Date().timeIntervalSince(started),
                    String(describing: translator.engine), translator.output, translator.failure ?? "-"
                ))
                if route.source == .uzbek || route.target == .uzbek {
                    XCTAssertEqual(translator.engine, online ? .online : nil)
                } else {
                    XCTAssertFalse(translator.output.isEmpty, "\(text) → \(route.target.code)")
                    XCTAssertNotEqual(translator.engine, .online, "a pair the Mac owns stays on it")
                }
            }
        }
    }
}
