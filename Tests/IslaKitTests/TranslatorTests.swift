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

    // MARK: - Asking once (G-026, K-004)

    /// A translator whose engines are stated and whose every capability lookup
    /// is counted — the lookup is the first thing a run does, so a count of
    /// zero means nothing was asked of any engine, MyMemory included.
    private func countingTranslator() -> (Translator, () -> Int) {
        let translator = Translator(defaults: defaults, preferredLanguages: ["ru"])
        translator.choose(source: .uzbek)
        translator.choose(target: .russian)
        var calls = 0
        translator.capabilitiesOverride = { _ in
            calls += 1
            // Nothing on this Mac and online off: a run that does get through
            // ends in an obstacle, never in a request leaving the machine.
            return Translator.Capabilities()
        }
        return (translator, { calls })
    }

    /// The pane re-runs its task every time the tab reappears, and every run
    /// used to translate again: switching Music → Translate → Music sent the
    /// same Uzbek sentence to MyMemory once per return and spent the day's
    /// quota on text that already had its answer on screen (G-026).
    func testUnchangedTextIsNotTranslatedAgain() async {
        let (translator, calls) = countingTranslator()
        translator.input = "salom"
        translator.received("привет", for: "salom", by: .online)

        await translator.translate()
        XCTAssertEqual(calls(), 0, "the answer on screen already answers this text")
        XCTAssertEqual(translator.output, "привет")
        XCTAssertEqual(translator.engine, .online)
        XCTAssertFalse(translator.isTranslating)

        // A space at the end is not new text: it is trimmed before it is sent.
        translator.input = "salom "
        await translator.translate()
        XCTAssertEqual(calls(), 0, "a trailing space is the same question")
        XCTAssertEqual(translator.output, "привет")
    }

    /// Retry is the person asking again on purpose; it must still ask.
    func testRetryStillAsksAgain() async {
        let (translator, calls) = countingTranslator()
        translator.input = "salom"
        translator.received("привет", for: "salom", by: .online)
        await translator.translate()
        XCTAssertEqual(calls(), 0)

        translator.retry()
        await translator.translate()
        XCTAssertEqual(calls(), 1, "a retry is a new request")
    }

    /// Anything that changes the question changes the answer: other text,
    /// another language, or the answer having been cleared away.
    func testChangedTextOrLanguageAsksAgain() async {
        let (translator, calls) = countingTranslator()
        translator.input = "salom"
        translator.received("привет", for: "salom", by: .online)

        translator.input = "salom dunyo"
        await translator.translate()
        XCTAssertEqual(calls(), 1, "other text")

        translator.input = "salom"
        translator.received("привет", for: "salom", by: .online)
        translator.choose(target: .english)
        await translator.translate()
        XCTAssertEqual(calls(), 2, "another language")

        translator.received("hello", for: "salom", by: .online)
        translator.clear()
        await translator.translate()
        XCTAssertEqual(calls(), 3, "a cleared answer")
    }

    /// For the debounce and the engine's time after an edit, the answer on
    /// screen is the previous text's. It used to look and copy exactly like a
    /// current one, so Copy pressed in that window pasted a translation of the
    /// sentence before the edit (K-004).
    func testAnAnswerToEarlierTextIsNotTheInputsAnswer() {
        let translator = Translator(defaults: defaults, preferredLanguages: ["ru"])
        XCTAssertFalse(translator.answersInput, "no answer at all")
        translator.input = "Good morning"
        translator.received("Доброе утро", for: "Good morning", by: .intelligence)
        XCTAssertTrue(translator.answersInput)

        translator.input = "Good morning "
        XCTAssertTrue(translator.answersInput, "a trailing space asks nothing new")

        translator.input = "Good morning, everyone"
        XCTAssertFalse(translator.answersInput, "the answer is to the text before the edit")
        XCTAssertEqual(translator.output, "Доброе утро", "kept on screen, dimmed, until the new one lands")
    }

    /// A failure used to win over the spinner, so Retry — or an edit — under
    /// "The translation could not be completed." changed nothing on screen for
    /// the whole run, and an identical failure never changed at all (K-004).
    func testAFailureGivesWayToTheSpinnerWhileARunIsInFlight() {
        typealias Pane = TranslatePane
        XCTAssertEqual(Pane.showing(failure: true, output: false, covered: false, translating: true), .translating)
        XCTAssertEqual(Pane.showing(failure: true, output: false, covered: false, translating: false), .failure)
        XCTAssertEqual(Pane.showing(failure: false, output: false, covered: false, translating: true), .translating)
        // An earlier answer stays up, dimmed, rather than flashing to a
        // spinner on every pause in typing.
        XCTAssertEqual(Pane.showing(failure: false, output: true, covered: false, translating: true), .answer)
        XCTAssertEqual(Pane.showing(failure: false, output: true, covered: true, translating: true), .covered)
        XCTAssertEqual(Pane.showing(failure: false, output: true, covered: true, translating: false), .covered)
        XCTAssertEqual(Pane.showing(failure: false, output: false, covered: false, translating: false), .nothing)
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

    // MARK: - Text that arrives by hot key or Service

    /// F-040: with an image on the clipboard ⌃⌥⌘T did nothing at all, which is
    /// indistinguishable from a shortcut that is not registered. No text, or
    /// only whitespace, is now a sentence the pane can show, and no text to
    /// put in the field — so what was typed there stays.
    func testCommandInputWithNoTextSaysSo() {
        for raw in [nil, "  \n", ""] as [String?] {
            let prepared = Translator.prepareCommandInput(raw)
            XCTAssertNil(prepared.text, "\(String(describing: raw)) is not text")
            XCTAssertEqual(prepared.notice, "The clipboard has no text.")
        }
        let plain = Translator.prepareCommandInput("  hello\n")
        XCTAssertEqual(plain.text, "hello")
        XCTAssertNil(plain.notice)
    }

    /// J-017: a multi-megabyte clipboard went whole into a `TextEditor` the pane
    /// re-measures on every body pass, on the main thread. It is cut to the
    /// limit before anything sees it, and the pane says it was cut.
    func testCommandInputIsCapped() {
        let english = Locale(identifier: "en_US")
        let prepared = Translator.prepareCommandInput(String(repeating: "a", count: 25_000), locale: english)
        XCTAssertEqual(prepared.text?.count, 20_000)
        XCTAssertEqual(prepared.notice, "Only the first 20,000 characters were kept.")

        let exact = Translator.prepareCommandInput(String(repeating: "a", count: 20_000), locale: english)
        XCTAssertEqual(exact.text?.count, 20_000)
        XCTAssertNil(exact.notice, "the limit itself is not a cut")

        // Leading whitespace does not count against the limit: a log indented
        // by more than the limit's worth of blanks is not "no text".
        let indented = String(repeating: " ", count: 30_000) + "word"
        XCTAssertEqual(Translator.prepareCommandInput(indented).text, "word")

        // Counted in characters, not UTF-16 units: a cut never splits a
        // flag or an accented letter into a broken glyph.
        let flags = String(repeating: "🇺🇿", count: 20_001)
        XCTAssertEqual(Translator.prepareCommandInput(flags, locale: english).text, String(repeating: "🇺🇿", count: 20_000))
    }

    /// The notice belongs to the text it was about. A keystroke, Clear or a
    /// swap replaces that text, and the sentence goes with it.
    func testANoticeGoesWithTheNextEdit() {
        let translator = Translator(defaults: defaults, preferredLanguages: ["en"])
        translator.notice = "The clipboard has no text."
        translator.input = "h"
        XCTAssertNil(translator.notice)

        translator.notice = "The clipboard has no text."
        translator.reset()
        XCTAssertNil(translator.notice)
    }
}
