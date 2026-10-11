import XCTest
@testable import IslaKit

@MainActor
final class TranslatorTests: XCTestCase {
    nonisolated(unsafe) private var defaults: UserDefaults!
    private let suite = "TranslatorTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    /// Detecting, with the target left on Russian, is the rule this tab ran on
    /// when English and Russian were its only languages: Russian goes out to
    /// English, everything else comes in to Russian.
    func testDetectingKeepsTheOldEnglishRussianRule() {
        XCTAssertEqual(Translator.route(for: "hello", source: nil, target: .russian),
                       .init(source: .english, target: .russian))
        XCTAssertEqual(Translator.route(for: "привет, как дела", source: nil, target: .russian),
                       .init(source: .russian, target: .english))
        // And the same turn for any target: text already in it goes to English.
        XCTAssertEqual(Translator.route(for: "Men ertaga ertalab ishga boraman", source: nil, target: .uzbek),
                       .init(source: .uzbek, target: .english))
        XCTAssertEqual(Translator.route(for: "good morning to you", source: nil, target: .english),
                       .init(source: .english, target: .russian))
    }

    /// A Russian paragraph quoting one Kazakh name is translated from Russian,
    /// on the Mac. It used to be read as Kazakh, which only the online engine
    /// knows, so with Translate Online on the whole paragraph left the Mac.
    func testAQuotedForeignNameDoesNotSendAParagraphOnline() {
        let paragraph = LanguageDetectionTests.russianParagraphQuotingAKazakhName
        XCTAssertEqual(Translator.route(for: paragraph, source: nil, target: .english).source, .russian)
    }

    /// A source somebody chose is used as chosen, even for text that looks
    /// like something else.
    func testAChosenSourceIsNotSecondGuessed() {
        XCTAssertEqual(Translator.route(for: "hello", source: .uzbek, target: .russian),
                       .init(source: .uzbek, target: .russian))
    }

    /// H-005: every new user was offered Russian, so an English, German or
    /// Uzbek reader had to find the menu before the tab was any use. A fresh
    /// install now translates into the first system language on offer.
    func testAFreshInstallTranslatesIntoTheReadersLanguage() {
        XCTAssertEqual(Translator.defaultTarget(preferredLanguages: ["de-DE", "en"]), .german)
        XCTAssertEqual(Translator.defaultTarget(preferredLanguages: ["en-US"]), .english)
        XCTAssertEqual(Translator.defaultTarget(preferredLanguages: ["zh-Hans-CN"]), .chinese)
        XCTAssertEqual(Translator.defaultTarget(preferredLanguages: ["zh-Hant-TW"]), .chinese, "any Chinese")
        XCTAssertEqual(Translator.defaultTarget(preferredLanguages: ["pt-BR"]), .portuguese)
        XCTAssertEqual(Translator.defaultTarget(preferredLanguages: ["uz-Latn-UZ", "ru"]), .uzbek)
        XCTAssertEqual(Translator.defaultTarget(preferredLanguages: ["xx-YY", "ja-JP"]), .japanese,
                       "the first language on offer, not the first language")
        XCTAssertEqual(Translator.defaultTarget(preferredLanguages: ["xx-YY"]), .english)
        XCTAssertEqual(Translator.defaultTarget(preferredLanguages: []), .english)

        let translator = Translator(defaults: defaults, preferredLanguages: ["de-DE", "en"])
        XCTAssertEqual(translator.target, .german)
        // Kept, so the second launch, when the welcome has been dismissed and
        // the account no longer looks fresh, does not fall back to Russian.
        XCTAssertEqual(defaults.string(forKey: Translator.targetKey), "de")
        defaults.set(true, forKey: NotchViewModel.hasCompletedFirstRunKey)
        XCTAssertEqual(Translator(defaults: defaults, preferredLanguages: ["en"]).target, .german)
    }

    /// An account that has been through the welcome and never touched the
    /// menu has been translating into Russian all along. An upgrade must not
    /// move that under it.
    func testAnUpgradeKeepsTheTargetItHad() {
        defaults.set(true, forKey: NotchViewModel.hasCompletedFirstRunKey)
        let translator = Translator(defaults: defaults, preferredLanguages: ["en"])
        XCTAssertEqual(translator.target, .russian)
        XCTAssertNil(defaults.string(forKey: Translator.targetKey), "nothing written that was not chosen")
    }

    func testTheChoiceIsRememberedAndAFreshTranslatorStartsOnIt() {
        let translator = Translator(defaults: defaults, preferredLanguages: ["ru"])
        XCTAssertNil(translator.source, "detects by default")
        XCTAssertEqual(translator.target, .russian, "the reader's own language")

        translator.choose(target: .uzbek)
        translator.choose(source: .english)
        let restored = Translator(defaults: defaults, preferredLanguages: ["ru"])
        XCTAssertEqual(restored.source, .english)
        XCTAssertEqual(restored.target, .uzbek)

        translator.choose(source: nil)
        XCTAssertNil(Translator(defaults: defaults, preferredLanguages: ["ru"]).source, "detecting is remembered too")
    }

    /// Choosing the language already on the other side swaps the two rather
    /// than translating a language into itself.
    func testChoosingTheOtherSidesLanguageSwaps() {
        let translator = Translator(defaults: defaults, preferredLanguages: ["ru"])
        translator.choose(source: .english)
        translator.choose(target: .uzbek)

        translator.choose(source: .uzbek)
        XCTAssertEqual(translator.source, .uzbek)
        XCTAssertEqual(translator.target, .english)

        translator.choose(target: .uzbek)
        XCTAssertEqual(translator.source, .english)
        XCTAssertEqual(translator.target, .uzbek)
    }

    /// A new language clears the answer on screen at once: it was an answer
    /// in the old language, under a heading that already names the new one.
    func testChoosingALanguageClearsTheAnswerInTheOldOne() {
        let translator = Translator(defaults: defaults, preferredLanguages: ["ru"])
        translator.choose(target: .russian)
        translator.input = "salom"
        translator.received("привет", for: "salom", by: .online)
        translator.choose(target: .russian)
        XCTAssertEqual(translator.output, "привет", "choosing the same language changes nothing")
        translator.choose(target: .english)
        XCTAssertEqual(translator.output, "")
        XCTAssertNil(translator.engine)
        XCTAssertEqual(translator.input, "salom", "what was typed stays")
    }

    /// A detected source is swapped as the language it was detected as.
    func testSwapTurnsADetectedSourceIntoTheTarget() {
        let translator = Translator(defaults: defaults, preferredLanguages: ["ru"])
        translator.choose(target: .uzbek)
        translator.input = "Where is the station?"
        translator.swap()
        XCTAssertEqual(translator.source, .uzbek)
        XCTAssertEqual(translator.target, .english)
        translator.swap()
        XCTAssertEqual(translator.source, .english)
        XCTAssertEqual(translator.target, .uzbek)
    }

    // MARK: - Engines

    /// The best engine the Mac has, in order, and online only for a pair the
    /// Mac does not offer at all.
    func testEnginesAreTriedBestFirst() {
        var mac = Translator.Capabilities(systemInstalled: true, systemSupported: true,
                                          modelSupportsPair: true, modelObstacle: nil, onlineEnabled: true)
        XCTAssertEqual(Translator.engines(given: mac), [.system, .intelligence])

        mac.systemInstalled = false
        XCTAssertEqual(Translator.engines(given: mac), [.intelligence])

        // Uzbek: neither on-device engine offers it.
        var uzbek = Translator.Capabilities()
        XCTAssertEqual(Translator.engines(given: uzbek), [], "nothing leaves the Mac unless asked")
        uzbek.onlineEnabled = true
        XCTAssertEqual(Translator.engines(given: uzbek), [.online])
    }

    /// The privacy promise, exhaustively: a pair either on-device engine
    /// offers is never sent online — not when its language is not downloaded,
    /// not with Apple Intelligence off, and not as the next try after an
    /// on-device engine failed or refused, which the list's order would
    /// otherwise make it (found in review, 2026-09-21).
    func testAPairTheMacOffersNeverListsTheOnlineEngine() {
        let obstacles: [Translator.Obstacle?] = [nil, .appleIntelligenceOff, .modelNotReady, .deviceNotEligible]
        for installed in [false, true] {
            for supported in [false, true] where supported || !installed {
                for model in [false, true] where supported || model {
                    for obstacle in obstacles {
                        let mac = Translator.Capabilities(
                            systemInstalled: installed, systemSupported: supported, modelSupportsPair: model,
                            modelObstacle: obstacle, onlineEnabled: true
                        )
                        XCTAssertFalse(Translator.engines(given: mac).contains(.online), "\(mac)")
                    }
                }
            }
        }
    }

    /// When nothing can, the failure names the language that is missing and
    /// offers only the way round that would actually be taken.
    func testAnImpossiblePairSaysWhichLanguageAndOffersTheRightWayRound() {
        let route = Translator.Route(source: .english, target: .uzbek)
        let uzbek = Translator.Capabilities()
        let obstacle = Translator.obstacle(for: route, given: uzbek)
        XCTAssertEqual(obstacle, .needsOnline(.uzbek))
        XCTAssertEqual(Translator.remedies(for: obstacle, onlineEnabled: false), [.turnOnOnline])

        let reversed = Translator.Route(source: .uzbek, target: .english)
        XCTAssertEqual(Translator.obstacle(for: reversed, given: uzbek), .needsOnline(.uzbek),
                       "English is never the reason, so it is never the one named")

        // Uzbek into Russian names Uzbek, the side the Mac lacks — not Russian,
        // which it translates perfectly well.
        var uzbekSource = Translator.Capabilities()
        uzbekSource.sourceOffDevice = true
        XCTAssertEqual(Translator.obstacle(for: .init(source: .uzbek, target: .russian), given: uzbekSource),
                       .needsOnline(.uzbek))

        let notDownloaded = Translator.Capabilities(systemInstalled: false, systemSupported: true)
        let ukrainian = Translator.obstacle(for: .init(source: .english, target: .ukrainian), given: notDownloaded)
        XCTAssertEqual(ukrainian, .needsDownload(.ukrainian))
        XCTAssertEqual(Translator.remedies(for: ukrainian, onlineEnabled: false), [.translationLanguages],
                       "a pair the Mac offers is downloaded, not sent")

        let intelligenceOff = Translator.Capabilities(modelSupportsPair: true, modelObstacle: .appleIntelligenceOff)
        let off = Translator.obstacle(for: .init(source: .english, target: .korean), given: intelligenceOff)
        XCTAssertEqual(off, .appleIntelligenceOff)
        XCTAssertEqual(Translator.remedies(for: off, onlineEnabled: false), [.appleIntelligenceSettings])
    }

    /// Below macOS 26 neither on-device engine is reachable from here: the
    /// message says so — not "Russian is not downloaded" — and the only way
    /// round is the online one, for every pair.
    func testBelowMacOS26TheMessageIsTheSystem() {
        var old = Translator.Capabilities(belowMinimumSystem: true)
        let route = Translator.Route(source: .english, target: .russian)
        XCTAssertEqual(Translator.obstacle(for: route, given: old), .needsNewerSystem)
        XCTAssertEqual(Translator.remedies(for: .needsNewerSystem, onlineEnabled: false), [.turnOnOnline])
        old.onlineEnabled = true
        XCTAssertEqual(Translator.engines(given: old), [.online])
    }

    /// The answer on screen belongs to the text it answered. For the length of
    /// the debounce it is still the previous text's, and a swap then must not
    /// replace what was just typed with it.
    func testSwapOnlyMovesAnAnswerThatAnswersTheField() {
        let translator = Translator(defaults: defaults, preferredLanguages: ["ru"])
        translator.choose(source: .english)
        translator.choose(target: .uzbek)
        translator.input = "Good morning"
        translator.received("Xayrli tong", for: "Good morning", by: .online)

        translator.input = "Good morning, everyone"
        translator.swap()
        XCTAssertEqual(translator.input, "Good morning, everyone", "a stale answer does not replace typing")
        XCTAssertEqual(translator.source, .uzbek)

        translator.swap()
        translator.received("Xayrli tong, hammaga", for: "Good morning, everyone", by: .online)
        translator.swap()
        XCTAssertEqual(translator.input, "Xayrli tong, hammaga")
        XCTAssertEqual(translator.output, "")
    }

    /// The model once translated one sentence for 218 seconds until its
    /// context was full. A translation is about as long as its source.
    func testTheModelIsCutOffLongBeforeItsContextFills() {
        XCTAssertEqual(Translator.responseTokenLimit(for: "hi"), 128)
        let sentence = "Where is the nearest train station? I need to be there by six."
        XCTAssertLessThan(Translator.responseTokenLimit(for: sentence), 400)
        XCTAssertLessThan(Translator.responseTokenLimit(for: String(repeating: "a", count: 100_000)), 8192)
    }

    func testOnlineTranslationIsOffByDefaultAndThePaneCanTurnItOn() {
        XCTAssertFalse(defaults.bool(forKey: NotchViewModel.onlineTranslationKey))
        let translator = Translator(defaults: defaults, preferredLanguages: ["ru"])
        let before = translator.request
        translator.turnOnOnline()
        XCTAssertTrue(defaults.bool(forKey: NotchViewModel.onlineTranslationKey))
        XCTAssertNotEqual(translator.request, before, "and it asks again at once")
    }

    func testEveryOfferedLanguageHasAName() {
        XCTAssertEqual(TranslationLanguage.all.count, 16)
        for language in TranslationLanguage.all {
            XCTAssertFalse(language.name.isEmpty)
            XCTAssertNotEqual(language.name, language.code.uppercased(), "\(language.code) has no name")
            XCTAssertEqual(TranslationLanguage.withCode(language.code), language)
        }
        XCTAssertTrue(TranslationLanguage.all.contains(.uzbek))
    }

    /// "Turn On Translate Online" used to sit under "Uzbek is translated
    /// online. Turn on Translate Online to use it." — an offer that never said
    /// the text would leave the Mac, or for whom (H-007). Every obstacle whose
    /// remedy is that switch now names the service in the sentence above it,
    /// so the one click that sends text away is made knowing where it goes.
    /// Below macOS 26 that is every pair, which is why `needsNewerSystem` is
    /// held to the same rule as `needsOnline`.
    func testTheOnlineOfferSaysTheTextLeavesTheMac() {
        let uzbek = Translator.Obstacle.needsOnline(.uzbek).message
        XCTAssertTrue(uzbek.contains("MyMemory"), uzbek)
        XCTAssertTrue(uzbek.contains(TranslationLanguage.uzbek.name), "and still names the language: \(uzbek)")

        let obstacles: [Translator.Obstacle] = [
            .needsNewerSystem, .deviceNotEligible, .appleIntelligenceOff, .modelNotReady,
            .needsOnline(.uzbek), .needsDownload(.ukrainian),
        ]
        for obstacle in obstacles
        where Translator.remedies(for: obstacle, onlineEnabled: false).contains(.turnOnOnline) {
            XCTAssertTrue(obstacle.message.contains("MyMemory"), "\(obstacle): \(obstacle.message)")
        }
    }

    /// On macOS 15 nothing translates on this Mac, so with the switch on every
    /// pair — English into Russian too — goes to MyMemory. The Settings note
    /// said only languages "such as Uzbek" did (K-005), which let somebody
    /// expect their English to stay local.
    func testTheSettingsNoteBelowMacOS26SaysEverythingGoesOnline() {
        let tahoe = Translator.onlineNote(belowMinimumSystem: false)
        let sequoia = Translator.onlineNote(belowMinimumSystem: true)
        XCTAssertTrue(tahoe.contains("MyMemory"), tahoe)
        XCTAssertTrue(sequoia.contains("MyMemory"), sequoia)
        XCTAssertFalse(sequoia.contains("such as"), "below macOS 26 it is not some languages: \(sequoia)")
        XCTAssertTrue(sequoia.contains("everything"), sequoia)
        if #available(macOS 26.0, *) {
            XCTAssertEqual(Translator.onlineNote(), tahoe)
        } else {
            XCTAssertEqual(Translator.onlineNote(), sequoia)
        }
    }

    /// The remedies were bare bold caption text, the only way forward from the
    /// first error a newcomer meets and nothing about them clickable-looking,
    /// while Music's "Open Spotify" and the lyrics page's "Look Up Online" were
    /// capsules (H-007). Three hand-copied capsules existed; there is now one
    /// style, and the hairline stroke that draws it lives in exactly one place.
    func testRemediesWearTheSharedCapsule() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let translatePane = try String(
            contentsOf: sources.appendingPathComponent("IslaKit/UI/TranslatePane.swift"), encoding: .utf8
        )
        XCTAssertTrue(translatePane.contains(".buttonStyle(OfferButtonStyle())"))

        var strokes: [String] = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            let count = text.components(separatedBy: "Capsule().strokeBorder(Theme.hairline").count - 1
            strokes += Array(repeating: file.lastPathComponent, count: count)
        }
        XCTAssertEqual(strokes, ["Theme.swift"], "one capsule style, drawn in Theme")
    }
}
