import SwiftUI
import XCTest
@testable import IslaKit

/// The result card's states (redesign 2026-10-15, spec §11): every obstacle and
/// failure `Translator` reports maps to one glyph and its buttons, and the pane
/// draws that and nothing else — one alert at a time, in the result card.
@MainActor
final class TranslateAlertTests: XCTestCase {
    private typealias Kind = Translator.FailureKind

    private func alert(
        _ kind: Kind?, _ message: String = "message", remedies: [Translator.Remedy] = [], spent: Bool = false
    ) -> TranslateAlert {
        TranslateAlert.make(kind: kind, message: message, remedies: remedies, allowanceSpent: spent)
    }

    // MARK: - The mapping, one to one

    func testLanguageNotDownloadedOffersTheSettingsAndOnline() {
        let result = alert(.obstacle(.needsDownload(.ukrainian)), remedies: [.translationLanguages])
        XCTAssertEqual(result.glyph, .symbol("arrow.down.circle", isWarning: false))
        XCTAssertEqual(result.actions, [.translationLanguages, .useOnline])
        XCTAssertEqual(result.message, "message", "the sentence is the one Translator worded")
    }

    func testOnlineOnlyAndOffOffersToTurnItOn() {
        for obstacle in [Translator.Obstacle.needsOnline(.uzbek), .needsNewerSystem] {
            let result = alert(.obstacle(obstacle), remedies: [.turnOnOnline])
            XCTAssertEqual(result.glyph, .symbol("globe", isWarning: false), "\(obstacle)")
            XCTAssertEqual(result.actions, [.turnOnOnline], "\(obstacle)")
        }
    }

    func testUnreachableIsAWarningWithTryAgain() {
        let result = alert(.unreachable, remedies: [.retry])
        XCTAssertEqual(result.glyph, .symbol("exclamationmark.bubble", isWarning: true))
        XCTAssertEqual(result.actions, [.tryAgain])
        XCTAssertEqual(TranslateAlert.Action.tryAgain.title, "Try Again")
    }

    func testAppleIntelligenceOffHasOneRemedy() {
        let off = alert(.obstacle(.appleIntelligenceOff), remedies: [.appleIntelligenceSettings])
        XCTAssertEqual(off.glyph, .symbol("info.circle", isWarning: false))
        XCTAssertEqual(off.actions, [.appleIntelligenceSettings])
        let ineligible = alert(.obstacle(.deviceNotEligible), remedies: [])
        XCTAssertEqual(ineligible.glyph, .symbol("info.circle", isWarning: false))
        XCTAssertEqual(ineligible.actions, [])
    }

    func testTheModelStillDownloadingIsASpinnerAndASentence() {
        let result = alert(.obstacle(.modelNotReady), remedies: [])
        XCTAssertEqual(result.glyph, .spinner)
        XCTAssertEqual(result.actions, [])
    }

    /// A spent allowance and the failures `describe` words besides unreachable:
    /// the same warning glyph, and Try Again only where Translator offers a retry.
    func testQuotaAndOtherFailuresKeepTheirOwnRemedies() {
        XCTAssertEqual(alert(.quotaExhausted, remedies: []).actions, [], "a refused day is refused again")
        XCTAssertEqual(alert(.other, remedies: [.retry]).actions, [.tryAgain])
        XCTAssertEqual(alert(.other, remedies: []).actions, [], "the guardrail refuses the same text the same way")
        XCTAssertEqual(alert(nil, remedies: []).glyph, .symbol("exclamationmark.bubble", isWarning: true))
    }

    // MARK: - OnlineAllowance

    /// With today's allowance gone, "Turn On Translate Online" and "Use Online"
    /// cannot work, so neither is offered — and the card says why in the sentence
    /// Translator already has for it, naming no time the allowance does not know.
    func testASpentAllowanceWithdrawsTheOffersThatCannotWork() {
        let quota = Translator.describe(OnlineTranslation.Failure.quotaExhausted).message

        let needsOnline = alert(.obstacle(.needsOnline(.uzbek)), "Uzbek is translated online only.", remedies: [.turnOnOnline], spent: true)
        XCTAssertEqual(needsOnline.message, quota)
        XCTAssertEqual(needsOnline.actions, [])
        XCTAssertEqual(needsOnline.glyph, .symbol("exclamationmark.bubble", isWarning: true))

        let download = alert(.obstacle(.needsDownload(.ukrainian)), remedies: [.translationLanguages], spent: true)
        XCTAssertEqual(download.actions, [.translationLanguages], "Use Online is dropped, the settings button stays")
        XCTAssertFalse(quota.localizedCaseInsensitiveContains("tomorrow"), "no reset time is promised")
        XCTAssertFalse(quota.contains(":"), "no clock time in the sentence")

        // Not spent: unchanged.
        XCTAssertEqual(alert(.obstacle(.needsOnline(.uzbek)), remedies: [.turnOnOnline], spent: false).actions, [.turnOnOnline])
    }

    // MARK: - One alert surface, from the translator through the pane

    /// Each way a translation can stop, driven through the real `translate()`:
    /// the pane's tree holds the sentence exactly once (no second banner or
    /// toast says it again), the alert is built from the translator's own state,
    /// and a spinner state is a spinner, not a sentence in a box.
    func testEachObstacleIsOneAlertInTheResultCard() async {
        struct Case {
            var name: String
            var capabilities: Translator.Capabilities
            var target: TranslationLanguage = .russian
            var online: ((String, Translator.Route) async throws -> OnlineTranslation.Reply)?
            var kind: Translator.FailureKind
        }
        let cases: [Case] = [
            Case(name: "not downloaded", capabilities: .init(systemSupported: true), target: .ukrainian,
                 kind: .obstacle(.needsDownload(.ukrainian))),
            Case(name: "online only and off", capabilities: .init(), target: .uzbek,
                 kind: .obstacle(.needsOnline(.uzbek))),
            Case(name: "newer system", capabilities: .init(belowMinimumSystem: true),
                 kind: .obstacle(.needsNewerSystem)),
            Case(name: "Apple Intelligence off", capabilities: .init(modelSupportsPair: true, modelObstacle: .appleIntelligenceOff),
                 kind: .obstacle(.appleIntelligenceOff)),
            Case(name: "not eligible", capabilities: .init(modelSupportsPair: true, modelObstacle: .deviceNotEligible),
                 kind: .obstacle(.deviceNotEligible)),
            Case(name: "model downloading", capabilities: .init(modelSupportsPair: true, modelObstacle: .modelNotReady),
                 kind: .obstacle(.modelNotReady)),
            Case(name: "unreachable", capabilities: .init(onlineEnabled: true), target: .uzbek,
                 online: { _, _ in throw OnlineTranslation.Failure.unreachable }, kind: .unreachable),
            Case(name: "quota", capabilities: .init(onlineEnabled: true), target: .uzbek,
                 online: { _, _ in throw OnlineTranslation.Failure.quotaExhausted }, kind: .quotaExhausted),
        ]
        for item in cases {
            let isolated = ProbeFixtures.isolatedStores()
            defer { isolated.release() }
            let translator = isolated.stores.translator
            translator.allowanceSpent = { false }
            translator.capabilitiesOverride = { _ in item.capabilities }
            if let online = item.online { translator.onlineTranslate = online }
            translator.choose(target: item.target)
            translator.input = "Where is the station?"
            await translator.translate()

            XCTAssertEqual(translator.failureKind, item.kind, item.name)
            let message = translator.failure ?? ""
            XCTAssertFalse(message.isEmpty, item.name)
            let built = TranslateAlert.make(kind: translator.failureKind, message: message, remedies: translator.remedies, allowanceSpent: false)
            XCTAssertEqual(built.message, message, item.name)

            let pane = TranslatePane(
                translator: translator, privacy: isolated.stores.privacy, wantsKeyboard: .constant(false)
            )
            .background(Color.black)
            let root = await AXProbe.tree(of: pane, size: CGSize(width: 488, height: 154))
            let sayingIt = root.all { $0.value == message || $0.label == message || $0.title == message }
            XCTAssertEqual(sayingIt.count, 1, "\(item.name): the sentence is said once\n\(root.dump)")
            for action in built.actions {
                XCTAssertNotNil(root.first(label: action.title), "\(item.name): \(action.title)\n\(root.dump)")
            }
            // The remedies and nothing else: no button the alert did not list.
            let offered = Set(["Translation Languages…", "Use Online", "Turn On Translate Online", "Try Again", "Apple Intelligence Settings…"])
            let shown = root.all(role: "AXButton").filter { offered.contains($0.label) || offered.contains($0.title) }
            XCTAssertEqual(shown.count, built.actions.count, "\(item.name)\n\(root.dump)")
        }
    }

    /// "Use Online" sends one text once, leaves Translate Online off, and is the
    /// only way the online engine answers for a pair the Mac has: the switch in
    /// Settings is not turned on, and an edit ends the permission.
    func testUseOnlineAnswersOneTextAndLeavesTheSwitchAlone() async {
        let rig = TranslateRig()
        defer { rig.release() }
        let translator = rig.translator
        var sent: [String] = []
        translator.onlineTranslate = { text, _ in
            sent.append(text)
            return OnlineTranslation.Reply(text: "Привіт", sentCharacters: nil)
        }
        // The Mac supports the pair but has not downloaded it: nothing can run.
        translator.capabilitiesOverride = { _ in .init(systemSupported: true) }
        translator.choose(target: .ukrainian)
        translator.input = "Hello"
        await translator.translate()
        XCTAssertEqual(translator.failureKind, .obstacle(.needsDownload(.ukrainian)))
        XCTAssertTrue(sent.isEmpty, "nothing leaves the Mac for an obstacle")

        translator.useOnline()
        await translator.translate()
        XCTAssertEqual(sent, ["Hello"])
        XCTAssertEqual(translator.output, "Привіт")
        XCTAssertEqual(translator.engine, .online)
        XCTAssertFalse(rig.defaults.bool(forKey: NotchViewModel.onlineTranslationKey), "Translate Online is still off")

        // Another text is not covered by the permission.
        translator.input = "Goodbye"
        await translator.translate()
        XCTAssertEqual(sent, ["Hello"], "an edit ends it")
        XCTAssertEqual(translator.failureKind, .obstacle(.needsDownload(.ukrainian)))
    }

    /// The rule the exception leans on: online is never the next try after an
    /// on-device engine, whatever was pressed.
    func testUseOnlineNeverFollowsAnOnDeviceEngine() {
        var capabilities = Translator.Capabilities(systemInstalled: true, systemSupported: true)
        capabilities.onlineByRequest = true
        XCTAssertEqual(Translator.engines(given: capabilities), [.system])
        capabilities = Translator.Capabilities(modelSupportsPair: true)
        capabilities.onlineByRequest = true
        capabilities.onlineEnabled = true
        XCTAssertEqual(Translator.engines(given: capabilities), [.intelligence])
        capabilities = Translator.Capabilities(systemSupported: true)
        XCTAssertEqual(Translator.engines(given: capabilities), [], "without the request, nothing")
        capabilities.onlineByRequest = true
        XCTAssertEqual(Translator.engines(given: capabilities), [.online])
    }
}
