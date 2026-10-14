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
        /// MyMemory is asked one line at a time, so this is one entry per request.
        var online: [String] = []
        var routes: [Translator.Route] = []
        var failSystem = false
        /// Translate Online as the person has it, read by the service live.
        var consent = true
        /// Whether the day's allowance has room.
        var allowance = true
        /// How long each fake engine takes, so a test can act mid-batch.
        var systemDelay: Duration?
        var onlineDelay: Duration?
        /// Lines the online fake refuses (an unreachable service) until cleared.
        var onlineFails: Set<String> = []
        /// Lines the service answers but declines (`Failure.refused`): a fact
        /// about the line, not about the batch.
        var onlineRefuses: Set<String> = []
        /// Hook run after each online answer, for a test that wants the day's
        /// allowance to run out partway.
        var afterOnline: ((String) -> Void)?
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
    /// `shown` puts a lyric surface on screen, which is what lets a batch start
    /// at all (`LyricTranslation.setDemand`); the tests about *not* asking pass
    /// false.
    private func service(
        defaults: UserDefaults, calls: Calls,
        capabilities: Translator.Capabilities = Translator.Capabilities(
            systemInstalled: true, systemSupported: true
        ),
        preferredLanguages: [String] = ["en"],
        shown: Bool = true
    ) -> LyricTranslation {
        let service = LyricTranslation(
            defaults: defaults,
            backend: LyricTranslation.Backend(
                capabilities: { route in
                    calls.routes.append(route)
                    return capabilities
                },
                system: { texts, _ in
                    calls.system.append(texts)
                    if let delay = calls.systemDelay { try await Task.sleep(for: delay) }
                    if calls.failSystem { throw LyricTranslation.Failure.unavailable }
                    return texts.map { "«\($0)»" }
                },
                model: { texts, _ in
                    calls.model.append(texts)
                    return texts.map { "«\($0)»" }
                },
                online: { text, _ in
                    calls.online.append(text)
                    if let delay = calls.onlineDelay { try await Task.sleep(for: delay) }
                    if calls.onlineFails.contains(text) { throw OnlineTranslation.Failure.unreachable }
                    if calls.onlineRefuses.contains(text) { throw OnlineTranslation.Failure.refused("NO") }
                    calls.afterOnline?(text)
                    return "«\(text)»"
                },
                // A Cyrillic letter is Russian and anything else English: enough
                // to tell the fixtures' two languages apart, and deterministic.
                detect: { text in
                    text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) } ? .russian : .english
                },
                onlineEnabled: { calls.consent },
                onlineAvailable: { calls.allowance }
            ),
            preferredLanguages: preferredLanguages
        )
        if shown { service.setDemand(.lyricArea, true) }
        return service
    }

    /// Waits, yielding, until `condition` holds: how a test gets into the middle
    /// of a slow batch without sleeping a guessed time.
    private func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out", file: file, line: line) }
            try? await Task.sleep(for: .milliseconds(5))
        }
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

    /// Spec §5.3: "the system language when it differs from the lyric's, else
    /// English". A choice, once made, wins; a stored code the tab no longer
    /// offers is unset; a song in the system language goes to English.
    func testTheTargetDefaultsToTheSystemLanguageUnlessTheSongIsInItThenEnglish() {
        let defaults = suite()
        // No song to compare with (Settings' own picker): the system language.
        XCTAssertEqual(NotchViewModel.translateTarget(in: defaults, preferredLanguages: ["de-DE", "en"]), .german)
        XCTAssertEqual(NotchViewModel.translateTarget(in: defaults, preferredLanguages: ["pt-BR"]), .portuguese)
        XCTAssertEqual(NotchViewModel.translateTarget(in: defaults, preferredLanguages: ["sw-KE"]), .english,
                       "a language the tab does not offer reads as English")
        XCTAssertEqual(NotchViewModel.translateTarget(in: defaults, preferredLanguages: []), .english)

        // A song in another language than the system's: the system language.
        XCTAssertEqual(
            NotchViewModel.translateTarget(in: defaults, preferredLanguages: ["ru-RU"], songLanguage: .english), .russian
        )
        // A song in the system's own language: English — the person who never
        // opened Settings still gets something to read.
        XCTAssertEqual(
            NotchViewModel.translateTarget(in: defaults, preferredLanguages: ["ru-RU"], songLanguage: .russian), .english,
            "a Russian song on a Russian Mac is translated into English"
        )
        XCTAssertEqual(
            NotchViewModel.translateTarget(in: defaults, preferredLanguages: ["en"], songLanguage: .english), .english,
            "an English song on an English Mac: English either way, which is the same-language skip"
        )

        // A choice wins, even over the song's own language.
        defaults.set("uk", forKey: NotchViewModel.translateTargetKey)
        XCTAssertEqual(NotchViewModel.translateTarget(in: defaults, preferredLanguages: ["de"]), .ukrainian)
        XCTAssertEqual(
            NotchViewModel.translateTarget(in: defaults, preferredLanguages: ["uk"], songLanguage: .ukrainian), .ukrainian
        )
        defaults.set("xx", forKey: NotchViewModel.translateTargetKey)
        XCTAssertEqual(NotchViewModel.translateTarget(in: defaults, preferredLanguages: ["de"]), .german)
    }

    /// Through the service: a Russian song on a Russian Mac with nothing chosen
    /// is translated, into English; with Russian chosen it is not.
    func testARussianSongOnARussianMacIsTranslatedIntoEnglishUnlessRussianWasChosen() async {
        let defaults = suite()
        defaults.set(true, forKey: NotchViewModel.translateLyricsKey)
        let calls = Calls()
        let service = service(defaults: defaults, calls: calls, preferredLanguages: ["ru-RU"])
        service.present(lines: Self.russianWithAnEnglishChorus)
        await service.settled()
        XCTAssertEqual(service.target, .english)
        XCTAssertEqual(calls.routes, [Translator.Route(source: .russian, target: .english)])
        XCTAssertEqual(service.presented?.rows, ["«в темноте у камеры»", nil, "«напевая всё, что тебе нужно»"])

        // An English song on the same Mac: the system language, as before.
        service.present(lines: Self.english)
        await service.settled()
        XCTAssertEqual(service.target, .russian)
        XCTAssertEqual(calls.routes.last, Translator.Route(source: .english, target: .russian))

        // Chosen, it stays chosen.
        service.choose(target: .russian)
        service.present(lines: Self.russianWithAnEnglishChorus)
        await service.settled()
        XCTAssertEqual(service.target, .russian)
        XCTAssertEqual(service.presented?.rows, [nil, nil, nil], "the song is already in what was chosen")
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
        XCTAssertEqual(
            calls.online, ["in the dark by the camera", "humming everything you need", "up here, up here"],
            "one request per distinct line, the credit not among them"
        )
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

    func testTheMenuNeverCreditsAnEngineWithALanguageItHasNotTranslated() async {
        let defaults = suite()
        turnOn(defaults, target: .uzbek)
        let calls = Calls()
        let service = service(defaults: defaults, calls: calls, capabilities: Translator.Capabilities(onlineEnabled: true))
        service.present(lines: Self.english)
        await service.settled()
        XCTAssertEqual(service.engine, .online)
        // Hidden, then another language chosen: nothing has run for it.
        service.setShown(false)
        service.choose(target: .russian)
        await service.settled()
        XCTAssertNotNil(service.presented, "the cached answer for the first language stays")
        XCTAssertNil(service.engine)
        let items = LyricsTranslateMenuModel.items(
            isShown: service.isShown, languages: [.uzbek, .russian], current: service.target, engine: service.engine
        )
        XCTAssertFalse(items.contains { $0.kind == .provenance }, "no engine is credited with a language nothing ran for")
        service.choose(target: .uzbek)
        await service.settled()
        XCTAssertEqual(service.engine, .online, "back on the language it was made for, from the cache")
        XCTAssertTrue(calls.online.count == 3, "no second batch")
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

// MARK: - What review found on 2026-10-15

extension LyricTranslationTests {
    private static let chorusSong: [LyricsStore.Line] = [
        .init(at: 4, text: "in the dark by the camera"),
        .init(at: 8, text: "up here, up here"),
        .init(at: 12, text: "humming everything you need"),
        .init(at: 16, text: "up here, up here"),
        .init(at: 20, text: "up here, up here"),
        .init(at: 24, text: "up here, up here"),
    ]

    // MARK: Each distinct line once

    /// A chorus sung four times is one question, answered under all four. The
    /// online engine used to be asked once per line of the song, so a song
    /// spent its chorus four times over against 5,000 characters a day.
    func testADistinctLineIsSentOnceAndAnsweredEverywhereItOccurs() async {
        let defaults = suite()
        turnOn(defaults)
        let calls = Calls()
        let service = service(defaults: defaults, calls: calls)
        service.present(lines: Self.chorusSong)
        await service.settled()
        XCTAssertEqual(calls.system, [["in the dark by the camera", "up here, up here", "humming everything you need"]],
                       "three distinct lines in one batch")
        XCTAssertEqual(service.presented?.rows, [
            "«in the dark by the camera»", "«up here, up here»", "«humming everything you need»",
            "«up here, up here»", "«up here, up here»", "«up here, up here»",
        ], "the one answer under every occurrence")
    }

    func testTheOnlineEngineAlsoSendsADistinctLineOnce() async {
        let defaults = suite()
        turnOn(defaults, target: .uzbek)
        let calls = Calls()
        let service = service(defaults: defaults, calls: calls, capabilities: Translator.Capabilities(onlineEnabled: true))
        service.present(lines: Self.chorusSong)
        await service.settled()
        XCTAssertEqual(calls.online, ["in the dark by the camera", "up here, up here", "humming everything you need"],
                       "a 4× chorus is 1 request")
        XCTAssertEqual(service.presented?.rows.compactMap { $0 }.count, 6)
    }

    // MARK: Only while shown

    func testNothingIsTranslatedWhileNoSurfaceDrawsTranslations() async {
        let defaults = suite()
        turnOn(defaults)
        let calls = Calls()
        let service = service(defaults: defaults, calls: calls, shown: false)
        XCTAssertFalse(service.isPresentedSomewhere)
        service.present(lines: Self.english)
        await service.settled()
        XCTAssertTrue(calls.system.isEmpty && calls.routes.isEmpty, "the panel is closed: not one engine is asked")
        XCTAssertNil(service.presented)

        // The lyric column appears: the batch starts.
        service.setDemand(.lyricArea, true)
        XCTAssertTrue(service.isPresentedSomewhere)
        await service.settled()
        XCTAssertEqual(calls.system.count, 1)
        XCTAssertNotNil(service.presented)

        // It goes again: nothing more is asked, and what was answered is kept
        // for the next time (a lookup, not a batch).
        service.setDemand(.lyricArea, false)
        XCTAssertFalse(service.isPresentedSomewhere)
        service.setDemand(.lyricArea, true)
        await service.settled()
        XCTAssertEqual(calls.system.count, 1)
    }

    func testNothingIsTranslatedWhileShowTranslationIsOff() async {
        let defaults = suite()
        turnOn(defaults)
        defaults.set(false, forKey: NotchViewModel.showTranslationKey)
        let calls = Calls()
        let service = service(defaults: defaults, calls: calls)
        service.present(lines: Self.english)
        await service.settled()
        XCTAssertTrue(calls.system.isEmpty && calls.routes.isEmpty, "hidden translations are not asked for")
        service.setShown(true)
        await service.settled()
        XCTAssertEqual(calls.system.count, 1, "shown: now they are")
    }

    /// A second consumer (the lock card, in R2) keeps the batch alive when the
    /// first goes, and the batch ends only when the last one has.
    func testTheBatchEndsWhenTheLastSurfaceGoes() async {
        let defaults = suite()
        turnOn(defaults)
        let calls = Calls()
        calls.systemDelay = .milliseconds(80)
        let service = service(defaults: defaults, calls: calls)
        service.setDemand(.lockCard, true)
        service.present(lines: Self.english)
        await until { !calls.system.isEmpty }
        service.setDemand(.lyricArea, false)
        XCTAssertTrue(service.isPresentedSomewhere, "the lock card still wants it")
        await service.settled()
        XCTAssertNotNil(service.presented, "the batch went on for the surface that remained")

        let other = LyricTranslationTests.Calls()
        other.systemDelay = .milliseconds(80)
        let second = self.service(defaults: suiteOn(), calls: other)
        second.present(lines: Self.english)
        await until { !other.system.isEmpty }
        second.setDemand(.lyricArea, false)
        await second.settled()
        XCTAssertNil(second.presented, "nothing wants it: the batch in flight is dropped")
    }

    /// The column becoming the tall page can bring the new stage on screen before
    /// the old one's disappearance is reported: the surface did not go.
    func testASurfaceThatReappearsBeforeTheOldOneLeavesStaysDemanded() {
        let service = self.service(defaults: suiteOn(), calls: Calls(), shown: false)
        service.setDemand(.lyricArea, true)
        service.setDemand(.lyricArea, true)
        service.setDemand(.lyricArea, false)
        XCTAssertTrue(service.isPresentedSomewhere)
        service.setDemand(.lyricArea, false)
        XCTAssertFalse(service.isPresentedSomewhere)
        service.setDemand(.lyricArea, false)
        XCTAssertFalse(service.isPresentedSomewhere, "an unmatched leave cannot go below nothing")
        service.setDemand(.lyricArea, true)
        XCTAssertTrue(service.isPresentedSomewhere)
    }

    private func suiteOn() -> UserDefaults {
        let defaults = suite()
        turnOn(defaults)
        return defaults
    }

    // MARK: A song that changes

    func testABatchInFlightIsDroppedWhenTheSongChanges() async {
        let defaults = suite()
        turnOn(defaults)
        let calls = Calls()
        calls.systemDelay = .milliseconds(80)
        let service = service(defaults: defaults, calls: calls)
        service.present(lines: Self.english)
        await until { calls.system.count == 1 }
        let other: [LyricsStore.Line] = [.init(at: 1, text: "something else entirely")]
        service.present(lines: other)
        await service.settled()
        XCTAssertEqual(calls.system.count, 2)
        XCTAssertEqual(service.presented?.key.texts, ["something else entirely"], "only the song on screen is published")
        XCTAssertEqual(service.displayRows(for: Self.english), [nil, nil, nil, nil], "the first song's answer never landed")
        XCTAssertEqual(service.displayRows(for: other), ["«something else entirely»"])
    }

    // MARK: Partial online answers are not kept

    func testAnOnlineBatchCutShortIsShownButNotKeptAndTheMissingLinesAreRetried() async {
        let defaults = suite()
        turnOn(defaults, target: .uzbek)
        let calls = Calls()
        calls.onlineFails = ["humming everything you need"]
        let service = service(defaults: defaults, calls: calls, capabilities: Translator.Capabilities(onlineEnabled: true))
        service.present(lines: Self.english)
        await service.settled()
        XCTAssertEqual(calls.online, ["in the dark by the camera", "humming everything you need"], "an unreachable service ends the batch: stopped at the failure")
        XCTAssertEqual(service.presented?.rows, [nil, "«in the dark by the camera»", nil, nil], "what came back is shown")

        // Not a loop: a write to the defaults is not a reason to ask again.
        service.refresh()
        await service.settled()
        XCTAssertEqual(calls.online.count, 2)

        // The next time the song is presented, only what is missing goes.
        calls.onlineFails = []
        service.present(lines: Self.english)
        await service.settled()
        XCTAssertEqual(
            calls.online,
            ["in the dark by the camera", "humming everything you need", "humming everything you need", "up here, up here"],
            "the line that answered is not sent again"
        )
        XCTAssertEqual(service.presented?.rows.compactMap { $0 }.count, 3, "now whole")

        // Whole, it is kept: showing it again asks nothing.
        service.present(lines: Self.english)
        await service.settled()
        XCTAssertEqual(calls.online.count, 4)
        service.setDemand(.lyricArea, false)
        service.setDemand(.lyricArea, true)
        await service.settled()
        XCTAssertEqual(calls.online.count, 4)
    }

    /// The day's allowance running out partway is a partial answer too — and
    /// while it stays spent, not one more request is made.
    func testASpentAllowanceStopsTheBatchAndKeepsItFromStartingAgain() async {
        let defaults = suite()
        turnOn(defaults, target: .uzbek)
        let calls = Calls()
        calls.afterOnline = { [unowned calls] _ in
            if calls.online.count == 2 { calls.allowance = false }
        }
        let service = service(defaults: defaults, calls: calls, capabilities: Translator.Capabilities(onlineEnabled: true))
        service.present(lines: Self.english)
        await service.settled()
        XCTAssertEqual(calls.online.count, 2, "the third line was never sent: the service had said no")
        XCTAssertEqual(service.presented?.rows.compactMap { $0 }.count, 2)

        service.present(lines: Self.english)
        await service.settled()
        XCTAssertEqual(calls.online.count, 2, "still spent: nothing is asked")

        // Another song, same day: nothing at all goes.
        service.present(lines: [.init(at: 1, text: "something else entirely")])
        await service.settled()
        XCTAssertEqual(calls.online.count, 2)
        XCTAssertNil(service.presented)

        // The day turns over: the missing line of the first song, and only it.
        calls.allowance = true
        service.present(lines: Self.english)
        await service.settled()
        XCTAssertEqual(calls.online.suffix(1), ["up here, up here"], "the lines that came back before are not sent again")
        XCTAssertEqual(service.presented?.rows.compactMap { $0 }.count, 3)
    }

    func testASpentAllowanceMeansNoBatchEvenWhenNothingHasBeenSentToday() async {
        let defaults = suite()
        turnOn(defaults, target: .uzbek)
        let calls = Calls()
        calls.allowance = false
        let service = service(defaults: defaults, calls: calls, capabilities: Translator.Capabilities(onlineEnabled: true))
        service.present(lines: Self.english)
        await service.settled()
        XCTAssertTrue(calls.online.isEmpty)
        XCTAssertNil(service.presented)
    }

    // MARK: Consent is part of the question

    /// Turning Translate Online off ends an online batch before its next line:
    /// the person said "stop sending this", and a request after that is a
    /// request they did not allow.
    func testWithdrawingConsentMidBatchSendsNothingMore() async {
        let defaults = suite()
        turnOn(defaults, target: .uzbek)
        let calls = Calls()
        calls.onlineDelay = .milliseconds(60)
        let service = service(defaults: defaults, calls: calls, capabilities: Translator.Capabilities(onlineEnabled: true))
        service.present(lines: Self.chorusSong)
        await until { calls.online.count == 1 }
        calls.consent = false
        service.refresh()
        let atTheSwitch = calls.online.count
        await service.settled()
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(calls.online.count, atTheSwitch, "no line was sent after the switch flipped")
        XCTAssertNil(service.presented, "and nothing is shown for a batch the person stopped")
    }

    /// Turning it on asks again about the song that had no engine a moment ago.
    func testGrantingConsentRetriesASongThatHadNoEngine() async {
        let defaults = suite()
        turnOn(defaults, target: .uzbek)
        let calls = Calls()
        calls.consent = false
        // What the Translate tab says: with the switch off, no engine for Uzbek.
        let service = LyricTranslation(
            defaults: defaults,
            backend: LyricTranslation.Backend(
                capabilities: { _ in Translator.Capabilities(onlineEnabled: calls.consent) },
                system: { _, _ in [] }, model: { _, _ in [] },
                online: { text, _ in
                    calls.online.append(text)
                    return "«\(text)»"
                },
                detect: { _ in .english },
                onlineEnabled: { calls.consent }
            ),
            preferredLanguages: ["en"]
        )
        service.setDemand(.lyricArea, true)
        service.present(lines: Self.english)
        await service.settled()
        XCTAssertNil(service.presented)
        XCTAssertTrue(calls.online.isEmpty)

        calls.consent = true
        service.refresh()
        await service.settled()
        XCTAssertEqual(calls.online.count, 3, "the song is asked about again")
        XCTAssertEqual(service.presented?.engine, .online)
    }

    // MARK: What Settings says

    func testTheSettingsNoteSaysWhereTheWorkIsDone() {
        XCTAssertEqual(
            LyricTranslation.settingsNote(onlineEnabled: false, belowMinimumSystem: false),
            "Translated on this Mac. Nothing is sent over the internet."
        )
        XCTAssertEqual(
            LyricTranslation.settingsNote(onlineEnabled: false, belowMinimumSystem: true),
            "Before macOS 26 this Mac cannot translate lyrics itself. Turn on Translate Online to translate them.",
            "nothing is translated on this Mac before macOS 26"
        )
        XCTAssertEqual(
            LyricTranslation.settingsNote(onlineEnabled: true, belowMinimumSystem: true),
            Translator.onlineNote(belowMinimumSystem: true), "the Translate tab's own words (K-005)"
        )
        XCTAssertEqual(
            LyricTranslation.settingsNote(onlineEnabled: true, belowMinimumSystem: false),
            Translator.onlineNote(belowMinimumSystem: false)
        )
        XCTAssertFalse(
            LyricTranslation.settingsNote(onlineEnabled: true, belowMinimumSystem: true).contains("on this Mac."),
            "it never claims the work stays here while the switch sends it away"
        )
    }

    // MARK: Review 2026-10-15, second pass

    /// A rebuild (a display plugged in) drops the content view without a
    /// promised `onDisappear`: the controller resets demand, and the old
    /// view's late lowering, tagged with the old epoch, does not touch the new
    /// panel's registration.
    func testARebuildResetsDemandWithoutTheDisappearAndStartsNoBatch() async {
        let defaults = suiteOn()
        let calls = Calls()
        calls.systemDelay = .milliseconds(80)
        let service = service(defaults: defaults, calls: calls)
        let oldEpoch = service.demandEpoch
        service.present(lines: Self.english)
        await until { !calls.system.isEmpty }
        XCTAssertTrue(service.isPresentedSomewhere)

        service.resetDemand()   // rebuild(): no onDisappear ever arrives
        XCTAssertFalse(service.isPresentedSomewhere, "the old view's demand is gone")
        await service.settled()
        XCTAssertNil(service.presented, "the batch in flight was dropped")

        // Panel closed: another song starts nothing.
        let before = calls.system.count
        service.present(lines: [.init(at: 1, text: "something else entirely")])
        await service.settled()
        XCTAssertEqual(calls.system.count, before, "no batch with the panel closed")

        // The rebuilt panel registers under the new epoch; the old view's late
        // lowering must not cancel it.
        service.setDemand(.lyricArea, true)
        service.setDemand(.lyricArea, false, epoch: oldEpoch)
        XCTAssertTrue(service.isPresentedSomewhere, "a stale lowering is ignored")
        service.setDemand(.lyricArea, false, epoch: service.demandEpoch)
        XCTAssertFalse(service.isPresentedSomewhere)
    }

    func testALineTheServiceRefusesIsSkippedAndNotSentAgain() async {
        let defaults = suite()
        turnOn(defaults, target: .uzbek)
        let calls = Calls()
        let lines: [LyricsStore.Line] = (1...10).map { .init(at: TimeInterval($0), text: "line number \($0)") }
        calls.onlineRefuses = ["line number 3"]
        let service = service(defaults: defaults, calls: calls, capabilities: Translator.Capabilities(onlineEnabled: true))
        service.present(lines: lines)
        await service.settled()
        XCTAssertEqual(calls.online.count, 10, "lines 4 to 10 were still asked")
        XCTAssertEqual(service.presented?.rows.compactMap { $0 }.count, 9, "the refused line has no translation")
        XCTAssertNil(service.presented?.rows[2])

        // Whole, so kept: reopening asks nothing, and the refused line is not re-sent.
        service.setDemand(.lyricArea, false)
        service.setDemand(.lyricArea, true)
        await service.settled()
        XCTAssertEqual(calls.online.count, 10)
        XCTAssertEqual(calls.online.filter { $0 == "line number 3" }.count, 1)
    }

    func testARefusedLineIsNotResentWhenALaterLineEndsTheBatchShort() async {
        let defaults = suite()
        turnOn(defaults, target: .uzbek)
        let calls = Calls()
        let lines: [LyricsStore.Line] = (1...5).map { .init(at: TimeInterval($0), text: "line number \($0)") }
        calls.onlineRefuses = ["line number 2"]
        calls.onlineFails = ["line number 4"]
        let service = service(defaults: defaults, calls: calls, capabilities: Translator.Capabilities(onlineEnabled: true))
        service.present(lines: lines)
        await service.settled()
        XCTAssertEqual(calls.online, ["line number 1", "line number 2", "line number 3", "line number 4"])
        calls.onlineFails = []
        service.present(lines: lines)
        await service.settled()
        XCTAssertEqual(calls.online.suffix(2), ["line number 4", "line number 5"], "line 2 is not asked again")
    }

    // MARK: Translate To: Automatic

    func testTranslateToOffersAutomaticFirstThenTheLanguages() {
        let choices = LyricTranslation.TargetChoice.all
        XCTAssertEqual(choices.first, .automatic)
        XCTAssertEqual(choices.dropFirst().count, TranslationLanguage.all.count)
        XCTAssertTrue(LyricTranslation.TargetChoice.separatorAfter(.automatic))
        XCTAssertFalse(LyricTranslation.TargetChoice.separatorAfter(.language(.english)))
        XCTAssertEqual(Set(choices.map(\.id)).count, choices.count, "ids are unique")
    }

    @MainActor
    func testAutomaticIsSelectedWhenNothingIsStoredAndClearsTheStoredLanguage() {
        let defaults = suite()
        XCTAssertEqual(LyricTranslation.TargetChoice.current(in: defaults), .automatic)
        LyricTranslation.TargetChoice.language(.german).apply(to: defaults)
        XCTAssertEqual(defaults.string(forKey: NotchViewModel.translateTargetKey), TranslationLanguage.german.code)
        XCTAssertEqual(LyricTranslation.TargetChoice.current(in: defaults), .language(.german))
        XCTAssertTrue(LyricTranslation.recentTargets(in: defaults).contains(.german), "joins the recents")
        LyricTranslation.TargetChoice.automatic.apply(to: defaults)
        XCTAssertNil(defaults.object(forKey: NotchViewModel.translateTargetKey), "Automatic removes the stored value")
        XCTAssertEqual(LyricTranslation.TargetChoice.current(in: defaults), .automatic)
    }
}
