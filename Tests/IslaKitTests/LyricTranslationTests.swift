import XCTest
@testable import IslaKit

/// Lyric translation as a service (spec §5.3, decision 11): when it is on and
/// what it is into by default, one batch per timeline and language, the cache,
/// the same-language skip, and the rule that nothing goes online unless the
/// Translate tab's own rule says it may.
///
/// Every engine is a fake. No test here reaches the network, a real language
/// model, the Translation framework, a player, or the standard defaults domain.
@MainActor
final class LyricTranslationTests: XCTestCase {
    // MARK: - Fixtures

    /// What the fakes were asked, in order, so a test says "one batch" with a
    /// number.
    @MainActor
    final class Calls {
        var system: [[String]] = []
        var model: [[String]] = []
        var online: [[String]] = []
        var routes: [Translator.Route] = []
        var failSystem = false
    }

    private static let english: [LyricsStore.Line] = [
        .init(at: 1, text: "Written by Mira Sol", isCredit: true),
        .init(at: 4, text: "in the dark by the camera"),
        .init(at: 8, text: "humming everything you need"),
        .init(at: 12, text: "up here, up here"),
    ]

    private static let russianWithAnEnglishChorus: [LyricsStore.Line] = [
        .init(at: 4, text: "в темноте у камеры"),
        .init(at: 8, text: "oh yeah"),
        .init(at: 12, text: "напевая всё, что тебе нужно"),
    ]

    private func suite(_ name: String = #function) -> UserDefaults {
        let suiteName = "com.ctimothe.isla.lyrictranslation.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    /// A service whose engines answer `"«text»"` and count what they were given.
    /// `capabilities` is what this Mac "can do"; `languageOf` is the recognizer.
    private func service(
        defaults: UserDefaults, calls: Calls,
        capabilities: Translator.Capabilities = Translator.Capabilities(
            systemInstalled: true, systemSupported: true
        ),
        preferredLanguages: [String] = ["en"]
    ) -> LyricTranslation {
        LyricTranslation(
            defaults: defaults,
            backend: LyricTranslation.Backend(
                capabilities: { route in
                    calls.routes.append(route)
                    return capabilities
                },
                system: { texts, _ in
                    calls.system.append(texts)
                    if calls.failSystem { throw LyricTranslation.Failure.unavailable }
                    return texts.map { "«\($0)»" }
                },
                model: { texts, _ in
                    calls.model.append(texts)
                    return texts.map { "«\($0)»" }
                },
                online: { texts, _ in
                    calls.online.append(texts)
                    return texts.map { "«\($0)»" }
                },
                // A Cyrillic letter is Russian and anything else English: enough
                // to tell the fixtures' two languages apart, and deterministic.
                detect: { text in
                    text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) } ? .russian : .english
                }
            ),
            preferredLanguages: preferredLanguages
        )
    }

    private func turnOn(_ defaults: UserDefaults, target: TranslationLanguage = .russian) {
        defaults.set(true, forKey: NotchViewModel.translateLyricsKey)
        defaults.set(target.code, forKey: NotchViewModel.translateTargetKey)
    }

    // MARK: - Defaults (spec §14)

    func testTranslateLyricsIsOffUntilChosen() {
        let defaults = suite()
        XCTAssertFalse(NotchViewModel.translateLyricsEnabled(in: defaults), "decision 11: off by default")
        XCTAssertTrue(NotchViewModel.showTranslationEnabled(in: defaults), "shown, once there is something to show")
        defaults.set(true, forKey: NotchViewModel.translateLyricsKey)
        XCTAssertTrue(NotchViewModel.translateLyricsEnabled(in: defaults))
        XCTAssertEqual(NotchViewModel.translateLyricsKey, "lyrics.translate")
        XCTAssertEqual(NotchViewModel.translateTargetKey, "lyrics.translateTarget")
    }

    /// The system language when the Translate tab offers it, else English; a
    /// choice, once made, wins; a stored code the tab no longer offers is unset.
    func testTheTargetDefaultsToTheSystemLanguageElseEnglish() {
        let defaults = suite()
        XCTAssertEqual(NotchViewModel.translateTarget(in: defaults, preferredLanguages: ["de-DE", "en"]), .german)
        XCTAssertEqual(NotchViewModel.translateTarget(in: defaults, preferredLanguages: ["pt-BR"]), .portuguese)
        XCTAssertEqual(NotchViewModel.translateTarget(in: defaults, preferredLanguages: ["sw-KE"]), .english,
                       "a language the tab does not offer reads as English")
        XCTAssertEqual(NotchViewModel.translateTarget(in: defaults, preferredLanguages: []), .english)
        defaults.set("uk", forKey: NotchViewModel.translateTargetKey)
        XCTAssertEqual(NotchViewModel.translateTarget(in: defaults, preferredLanguages: ["de"]), .ukrainian)
        defaults.set("xx", forKey: NotchViewModel.translateTargetKey)
        XCTAssertEqual(NotchViewModel.translateTarget(in: defaults, preferredLanguages: ["de"]), .german)
    }

    func testNothingIsTranslatedWhileTranslateLyricsIsOff() async {
        let defaults = suite()
        let calls = Calls()
        let service = service(defaults: defaults, calls: calls)
        service.present(lines: Self.english)
        await service.settled()
        XCTAssertNil(service.presented)
        XCTAssertTrue(calls.system.isEmpty && calls.model.isEmpty && calls.online.isEmpty && calls.routes.isEmpty)
        XCTAssertEqual(service.displayRows(for: Self.english), [nil, nil, nil, nil])
    }

    // MARK: - One batch, kept

    func testOneBatchPerTimelineAndTargetAndAHitOnReturn() async {
        let defaults = suite()
        turnOn(defaults)
        let calls = Calls()
        let service = service(defaults: defaults, calls: calls)

        service.present(lines: Self.english)
        await service.settled()
        XCTAssertEqual(calls.system.count, 1, "the whole song in one batch")
        XCTAssertEqual(calls.system[0], ["in the dark by the camera", "humming everything you need", "up here, up here"],
                       "the credit is not a lyric and is not sent")
        let rows = service.presented?.rows
        XCTAssertEqual(rows, [nil, "«in the dark by the camera»", "«humming everything you need»", "«up here, up here»"])
        XCTAssertEqual(service.presented?.engine, .system)
        XCTAssertEqual(calls.routes, [Translator.Route(source: .english, target: .russian)])

        // Showing it again — the same song, rechecked — asks nothing.
        service.present(lines: Self.english)
        service.present(lines: Self.english)
        await service.settled()
        XCTAssertEqual(calls.system.count, 1)

        // Another song, and back: the first is a lookup.
        service.present(lines: nil)
        XCTAssertNil(service.presented, "nothing on screen, nothing presented")
        service.present(lines: Self.english)
        await service.settled()
        XCTAssertEqual(calls.system.count, 1, "cache hit on re-show")
        XCTAssertEqual(service.presented?.rows, rows)

        // Another language is its own batch; coming back to the first is not.
        service.choose(target: .ukrainian)
        await service.settled()
        XCTAssertEqual(calls.system.count, 2)
        XCTAssertEqual(service.presented?.key.target, "uk")
        service.choose(target: .russian)
        await service.settled()
        XCTAssertEqual(calls.system.count, 2, "cache hit on switching back to a previous target")
        XCTAssertEqual(service.presented?.rows, rows)
    }

    /// The answer is published whole: while a batch is out nothing is presented,
    /// and when it lands every row is there at once.
    func testTheRowsArriveTogetherNeverOneByOne() async {
        let defaults = suite()
        turnOn(defaults)
        let calls = Calls()
        let service = service(defaults: defaults, calls: calls)
        var seen: [Int] = []
        let observation = service.$presented.sink { seen.append($0?.rows.compactMap { $0 }.count ?? -1) }
        defer { observation.cancel() }
        service.present(lines: Self.english)
        XCTAssertNil(service.presented, "until the batch arrives the lines show without translations")
        await service.settled()
        XCTAssertEqual(service.presented?.rows.compactMap { $0 }.count, 3)
        // Whatever it published on the way, it never published a part.
        XCTAssertFalse(seen.contains { $0 > 0 && $0 < 3 }, "\(seen)")
    }

    func testAnotherSongsRowsAreNeverLaidUnderThese() async {
        let defaults = suite()
        turnOn(defaults)
        let calls = Calls()
        let service = service(defaults: defaults, calls: calls)
        service.present(lines: Self.english)
        await service.settled()
        let other: [LyricsStore.Line] = [.init(at: 1, text: "something else entirely")]
        XCTAssertEqual(service.displayRows(for: other), [nil], "an answer for another timeline is not for this one")
    }

    // MARK: - Same language

    func testASongAlreadyInTheTargetLanguageIsNotTranslatedAtAll() async {
        let defaults = suite()
        turnOn(defaults, target: .english)
        let calls = Calls()
        let service = service(defaults: defaults, calls: calls)
        service.present(lines: Self.english)
        await service.settled()
        XCTAssertTrue(calls.system.isEmpty && calls.routes.isEmpty, "no engine is even asked about the pair")
        XCTAssertEqual(service.presented?.rows, [nil, nil, nil, nil], "an answer — kept — of no rows")
        XCTAssertFalse(LyricTranslation.hasRows(service.displayRows(for: Self.english)))
    }

    /// A line whose own language is the target — the English chorus of a Russian
    /// song, translated into English — gets no row and is not sent.
    func testALineAlreadyInTheTargetLanguageGetsNoRow() async {
        let defaults = suite()
        turnOn(defaults, target: .english)
        let calls = Calls()
        let service = service(defaults: defaults, calls: calls)
        service.present(lines: Self.russianWithAnEnglishChorus)
        await service.settled()
        XCTAssertEqual(calls.system, [["в темноте у камеры", "напевая всё, что тебе нужно"]])
        XCTAssertEqual(calls.routes, [Translator.Route(source: .russian, target: .english)])
        XCTAssertEqual(service.presented?.rows, ["«в темноте у камеры»", nil, "«напевая всё, что тебе нужно»"])
    }

    /// A name or an interjection that comes back unchanged is not drawn twice.
    func testAnAnswerThatRepeatsTheLineIsNotARow() {
        XCTAssertNil(LyricTranslation.usable("Oh Yeah", for: "oh yeah"))
        XCTAssertNil(LyricTranslation.usable("  ", for: "up here"))
        XCTAssertNil(LyricTranslation.usable(nil, for: "up here"))
        XCTAssertEqual(LyricTranslation.usable(" наверху ", for: "up here"), "наверху")
    }

    // MARK: - Online is the Translate tab's decision

    /// With Translate Online off, a pair nothing on this Mac offers is simply not
    /// translated: the online engine is never called.
    func testOnlineIsNeverUsedWhileTranslateOnlineIsOff() async {
        let defaults = suite()
        turnOn(defaults, target: .uzbek)
        let calls = Calls()
        // Nothing here offers the pair, and the switch is off.
        let service = service(defaults: defaults, calls: calls, capabilities: Translator.Capabilities(onlineEnabled: false))
        service.present(lines: Self.english)
        await service.settled()
        XCTAssertTrue(calls.online.isEmpty, "the one engine that leaves the Mac is never asked")
        XCTAssertTrue(calls.system.isEmpty && calls.model.isEmpty)
        XCTAssertNil(service.presented, "silently untranslated: one failure surface, and it is not here")
    }

    /// Never the next try after a failure on this Mac: a pair an on-device engine
    /// offers stays on the device whatever the switch says and however that engine
    /// fares.
    func testAFailureOnTheDeviceNeverFallsThroughToOnline() async {
        let defaults = suite()
        turnOn(defaults)
        let calls = Calls()
        calls.failSystem = true
        let service = service(
            defaults: defaults, calls: calls,
            capabilities: Translator.Capabilities(systemInstalled: true, systemSupported: true, onlineEnabled: true)
        )
        service.present(lines: Self.english)
        await service.settled()
        XCTAssertEqual(calls.system.count, 1)
        XCTAssertTrue(calls.online.isEmpty, "a text the device failed on is exactly the text that must not leave")
        XCTAssertNil(service.presented)
    }

    func testOnlineIsUsedForAPairNothingHereOffersWhenItIsOn() async {
        let defaults = suite()
        turnOn(defaults, target: .uzbek)
        let calls = Calls()
        let service = service(defaults: defaults, calls: calls, capabilities: Translator.Capabilities(onlineEnabled: true))
        service.present(lines: Self.english)
        await service.settled()
        XCTAssertEqual(calls.online.count, 1, "one batch")
        XCTAssertTrue(calls.system.isEmpty && calls.model.isEmpty)
        XCTAssertEqual(service.presented?.engine, .online)
        XCTAssertEqual(service.engine, .online)
    }

    /// Past the first engine that fails to the next one on this Mac, as the
    /// Translate tab does.
    func testTheModelTakesOverWhereTheFrameworkFails() async {
        let defaults = suite()
        turnOn(defaults)
        let calls = Calls()
        calls.failSystem = true
        let service = service(
            defaults: defaults, calls: calls,
            capabilities: Translator.Capabilities(systemInstalled: true, systemSupported: true, modelSupportsPair: true)
        )
        service.present(lines: Self.english)
        await service.settled()
        XCTAssertEqual(calls.system.count, 1)
        XCTAssertEqual(calls.model.count, 1)
        XCTAssertEqual(service.presented?.engine, .intelligence)
    }

    // MARK: - Failure is quiet and is not remembered

    func testAFailedBatchLeavesTheLinesAloneAndIsTriedAgainLater() async {
        let defaults = suite()
        turnOn(defaults)
        let calls = Calls()
        calls.failSystem = true
        let service = service(defaults: defaults, calls: calls)
        service.present(lines: Self.english)
        await service.settled()
        XCTAssertNil(service.presented)
        XCTAssertEqual(service.displayRows(for: Self.english), [nil, nil, nil, nil])

        // Not a loop: the same song rechecked does not ask again…
        service.present(lines: Self.english)
        await service.settled()
        XCTAssertEqual(calls.system.count, 1)

        // …but a change of language, and back, does — the failure was not kept.
        calls.failSystem = false
        service.choose(target: .ukrainian)
        await service.settled()
        service.choose(target: .russian)
        await service.settled()
        XCTAssertNotNil(service.presented)
        XCTAssertEqual(calls.system.count, 3)
    }

    func testSwitchingTranslateLyricsOffTakesTheRowsDown() async {
        let defaults = suite()
        turnOn(defaults)
        let calls = Calls()
        let service = service(defaults: defaults, calls: calls)
        service.present(lines: Self.english)
        await service.settled()
        XCTAssertNotNil(service.presented)
        defaults.set(false, forKey: NotchViewModel.translateLyricsKey)
        service.refresh()
        XCTAssertFalse(service.isEnabled)
        XCTAssertNil(service.presented)
        XCTAssertEqual(service.displayRows(for: Self.english), [nil, nil, nil, nil])
        defaults.set(true, forKey: NotchViewModel.translateLyricsKey)
        service.refresh()
        await service.settled()
        XCTAssertEqual(calls.system.count, 1, "switched back on, the kept answer is a lookup")
        XCTAssertNotNil(service.presented)
    }

    // MARK: - Show Translation, the recents and what R2 reads

    func testShowTranslationHidesTheRowsWithoutForgettingThem() async {
        let defaults = suite()
        turnOn(defaults)
        let calls = Calls()
        let service = service(defaults: defaults, calls: calls)
        service.present(lines: Self.english)
        await service.settled()
        XCTAssertEqual(service.displayRows(for: Self.english)[1], "«in the dark by the camera»")
        XCTAssertEqual(service.translation(atLine: 1), "«in the dark by the camera»")
        service.toggleShown()
        XCTAssertFalse(service.isShown)
        XCTAssertFalse(NotchViewModel.showTranslationEnabled(in: defaults), "kept across a launch")
        XCTAssertEqual(service.displayRows(for: Self.english), [nil, nil, nil, nil])
        XCTAssertNil(service.translation(atLine: 1))
        XCTAssertNotNil(service.presented, "hidden, not discarded")
        service.toggleShown()
        XCTAssertEqual(service.translation(atLine: 3), "«up here, up here»")
        XCTAssertEqual(calls.system.count, 1, "showing it again is not a second batch")
    }

    func testTheReadForTheLockCardIsTheColumnsOwnAnswer() async {
        let defaults = suite()
        turnOn(defaults)
        let service = service(defaults: defaults, calls: Calls())
        XCTAssertNil(service.translation(atLine: 0), "nothing presented, nothing to read")
        service.present(lines: Self.english)
        XCTAssertNil(service.translation(atLine: 1), "a read starts nothing and waits for nothing")
        await service.settled()
        XCTAssertNil(service.translation(atLine: 0), "a credit has none")
        XCTAssertEqual(service.translation(atLine: 2), "«humming everything you need»")
        XCTAssertNil(service.translation(atLine: 9), "past the end")
        XCTAssertNil(service.translation(atLine: -1))
    }

    func testChoosingATargetIsRememberedNewestFirstAndCapped() {
        let defaults = suite()
        let service = service(defaults: defaults, calls: Calls())
        for language in [TranslationLanguage.german, .french, .spanish, .italian, .korean, .japanese, .german] {
            service.choose(target: language)
        }
        XCTAssertEqual(service.target, .german)
        XCTAssertEqual(service.recents, [.german, .japanese, .korean, .italian, .spanish],
                       "the five most recent, newest first, once each")
        XCTAssertEqual(NotchViewModel.translateTarget(in: defaults), .german)
    }

    // MARK: - Bilingual files (spec §5.3)

    func testABilingualLRCLineDrawsItsSecondRowAsTheTranslation() throws {
        let document = try LocalLyricsDocument.parse("""
        [00:04.00]in the dark by the camera
        [00:04.00]в темноте у камеры
        [00:08.00]humming everything you need
        """)
        let lines = document.timeline(documentID: nil).lines
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].text, "in the dark by the camera\nв темноте у камеры", "merged with a newline, as it always was")
        let split = LyricTranslation.rows(of: lines[0].text)
        XCTAssertEqual(split.primary, "in the dark by the camera")
        XCTAssertEqual(split.secondary, "в темноте у камеры")
        XCTAssertNil(LyricTranslation.rows(of: lines[1].text).secondary)

        // With Translate Lyrics off — the file's own words, whatever the setting.
        let off = LyricTranslation.displayRows(lines: lines, machine: nil, enabled: false, shown: true, target: .russian)
        XCTAssertEqual(off, ["в темноте у камеры", nil])
        XCTAssertTrue(LyricTranslation.hasRows(off))
        // Hidden only where the header offers hiding: with Translate Lyrics on.
        XCTAssertEqual(
            LyricTranslation.displayRows(lines: lines, machine: nil, enabled: false, shown: false, target: .russian),
            ["в темноте у камеры", nil], "no header button without the setting, so no way the person hid it"
        )
        XCTAssertEqual(
            LyricTranslation.displayRows(lines: lines, machine: nil, enabled: true, shown: false, target: .russian),
            [nil, nil]
        )
    }

    /// A bilingual line is its file's own translation: never sent to an engine.
    func testABilingualLineIsNeverSentToAnEngine() async {
        let defaults = suite()
        turnOn(defaults)
        let calls = Calls()
        let lines: [LyricsStore.Line] = [
            .init(at: 4, text: "in the dark by the camera\nв темноте у камеры"),
            .init(at: 8, text: "humming everything you need"),
        ]
        XCTAssertFalse(LyricTranslation.isTranslatable(lines[0]))
        XCTAssertTrue(LyricTranslation.isTranslatable(lines[1]))
        let service = service(defaults: defaults, calls: calls)
        service.present(lines: lines)
        await service.settled()
        XCTAssertEqual(calls.system, [["humming everything you need"]])
        XCTAssertEqual(service.displayRows(for: lines), ["в темноте у камеры", "«humming everything you need»"],
                       "the file's row, and the machine's for the line that has none")
    }

    // MARK: - Wired to the lyrics

    /// The session follows the lyrics store: a song that arrives is translated
    /// without the panel being asked, and one that goes takes its rows with it.
    func testTheSessionFollowsTheLyricsStore() async throws {
        let defaults = suite()
        turnOn(defaults)
        let calls = Calls()
        let service = service(defaults: defaults, calls: calls)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("isla-translation-follow-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores = NotchStores(localLyricsDirectory: directory, lyricTranslation: service)
        stores.followLyricsForTranslation()
        stores.followLyricsForTranslation()

        stores.lyrics.present(.ready(LyricTimeline(lines: Self.english, granularity: .line)))
        await service.settled()
        XCTAssertEqual(calls.system.count, 1, "one subscription, one batch")
        XCTAssertEqual(service.translation(atLine: 1), "«in the dark by the camera»")

        stores.lyrics.present(.noLocalLyrics)
        XCTAssertNil(service.presented, "no lyrics, no rows")
        XCTAssertNil(service.translation(atLine: 1))
    }
}
