import XCTest
@testable import IslaKit

@MainActor
final class TranslatorTests: XCTestCase {
    private var defaults: UserDefaults!
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

    /// A source somebody chose is used as chosen, even for text that looks
    /// like something else.
    func testAChosenSourceIsNotSecondGuessed() {
        XCTAssertEqual(Translator.route(for: "hello", source: .uzbek, target: .russian),
                       .init(source: .uzbek, target: .russian))
    }

    func testTheChoiceIsRememberedAndAFreshTranslatorStartsOnIt() {
        let translator = Translator(defaults: defaults)
        XCTAssertNil(translator.source, "detects by default")
        XCTAssertEqual(translator.target, .russian, "the target this tab always had")

        translator.choose(target: .uzbek)
        translator.choose(source: .english)
        let restored = Translator(defaults: defaults)
        XCTAssertEqual(restored.source, .english)
        XCTAssertEqual(restored.target, .uzbek)

        translator.choose(source: nil)
        XCTAssertNil(Translator(defaults: defaults).source, "detecting is remembered too")
    }

    /// Choosing the language already on the other side swaps the two rather
    /// than translating a language into itself.
    func testChoosingTheOtherSidesLanguageSwaps() {
        let translator = Translator(defaults: defaults)
        translator.choose(source: .english)
        translator.choose(target: .uzbek)

        translator.choose(source: .uzbek)
        XCTAssertEqual(translator.source, .uzbek)
        XCTAssertEqual(translator.target, .english)

        translator.choose(target: .uzbek)
        XCTAssertEqual(translator.source, .english)
        XCTAssertEqual(translator.target, .uzbek)
    }

    /// A detected source is swapped as the language it was detected as.
    func testSwapTurnsADetectedSourceIntoTheTarget() {
        let translator = Translator(defaults: defaults)
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

    /// The best engine the Mac has, in order, and online only when switched on.
    func testEnginesAreTriedBestFirstAndOnlineOnlyWhenAskedFor() {
        var mac = Translator.Capabilities(systemInstalled: true, systemSupported: true,
                                          modelSupportsPair: true, modelObstacle: nil, onlineEnabled: false)
        XCTAssertEqual(Translator.engines(given: mac), [.system, .intelligence])

        mac.systemInstalled = false
        XCTAssertEqual(Translator.engines(given: mac), [.intelligence])

        mac.modelObstacle = .appleIntelligenceOff
        XCTAssertEqual(Translator.engines(given: mac), [], "nothing leaves the Mac unless asked")

        mac.onlineEnabled = true
        XCTAssertEqual(Translator.engines(given: mac), [.online])

        // Uzbek: neither on-device engine has it.
        let uzbek = Translator.Capabilities(systemInstalled: false, systemSupported: false,
                                            modelSupportsPair: false, modelObstacle: nil, onlineEnabled: false)
        XCTAssertEqual(Translator.engines(given: uzbek), [])
    }

    /// When nothing can, the failure names the language that is missing and
    /// offers the way round it.
    func testAnImpossiblePairSaysWhichLanguageAndOffersOnline() {
        let route = Translator.Route(source: .english, target: .uzbek)
        let uzbek = Translator.Capabilities()
        let obstacle = Translator.obstacle(for: route, given: uzbek)
        XCTAssertEqual(obstacle, .needsOnline(.uzbek))
        XCTAssertEqual(Translator.remedies(for: obstacle, onlineEnabled: false), [.turnOnOnline])

        let reversed = Translator.Route(source: .uzbek, target: .english)
        XCTAssertEqual(Translator.obstacle(for: reversed, given: uzbek), .needsOnline(.uzbek),
                       "English is never the reason, so it is never the one named")

        let notDownloaded = Translator.Capabilities(systemInstalled: false, systemSupported: true)
        let ukrainian = Translator.obstacle(for: .init(source: .english, target: .ukrainian), given: notDownloaded)
        XCTAssertEqual(ukrainian, .needsDownload(.ukrainian))
        XCTAssertEqual(Translator.remedies(for: ukrainian, onlineEnabled: false),
                       [.translationLanguages, .turnOnOnline])

        let intelligenceOff = Translator.Capabilities(modelSupportsPair: true, modelObstacle: .appleIntelligenceOff)
        let off = Translator.obstacle(for: .init(source: .english, target: .korean), given: intelligenceOff)
        XCTAssertEqual(off, .appleIntelligenceOff)
        XCTAssertEqual(Translator.remedies(for: off, onlineEnabled: true), [.appleIntelligenceSettings])
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
        let translator = Translator(defaults: defaults)
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
}
