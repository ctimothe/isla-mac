import CoreGraphics
import Foundation

/// Where everything on the Translate tab sits (redesign 2026-10-15, spec §11), as
/// values.
///
/// Stated in the board's body coordinates, like `ClipboardLayout` and
/// `ShelfLayout`, and converted to the pane's by `PlayerLayout.inPane`, so a test
/// that holds the spec's numbers holds the pixels at 480, 560 and 620 without
/// rendering anything.
///
/// At the default 560 the numbers are the board's: the pair bar at y 46 with the
/// two pop-ups 210 × 22 at x 58 and 336 and the swap at 290, the source card at
/// (58, 76) 240 × 116, the result at 318. Wider and narrower bodies derive from
/// `bw` rather than hard-coding the 560 positions: the pop-ups give up width
/// below 560 (never overlapping the swap or each other), the cards share the
/// content width in the board's 240 : 228 proportion, and the right-hand column
/// rides the trailing edge.
enum TranslateLayout {
    // MARK: - Metrics

    /// The pair bar hangs 8 under the header (the board's 46 on a 38 header).
    static let pairBarOffset: CGFloat = 8
    static let popUpHeight: CGFloat = 22
    static let popUpWidth: CGFloat = 210
    /// The swap button's side (spec §11: 24 pt).
    static let swapSide: CGFloat = 24
    /// The least air between a pop-up and the swap, which is what sets the
    /// pop-ups' width on a narrow body.
    static let swapGap: CGFloat = 8

    /// The cards start 30 under the pair bar's top: the bar's 22, and 8 of air.
    static let cardsDrop: CGFloat = 30
    /// The cards end 16 above the body's foot: 116 tall on 208, 308 on 400.
    static let cardFootInset: CGFloat = 16
    /// Between the cards.
    static let cardGap: CGFloat = 20
    static let cardRadius: CGFloat = 12
    /// The source card is 6 wider than half the room between the cards, which is
    /// how the board's 240 and 228 divide 488.
    static let sourceBonus: CGFloat = 6

    /// Text inside the cards: 12 in from the card's leading edge, 9 down.
    static let textInset: CGFloat = 12
    static let textTop: CGFloat = 9
    /// The source text's right margin leaves room for the Clear ⓧ; the result's
    /// is 16 (212 of 228).
    static let sourceTextTrailing: CGFloat = 28
    static let resultTextTrailing: CGFloat = 16

    /// Type sizes: 15 on the standard body and 13.5 on the tall one (spec §11).
    /// Raw sizes, not roles — the roles' `title` is 16 and `subhead` 13, and the
    /// board draws these two for a text that has to fit a card of a set size.
    static let textSize: CGFloat = 15
    static let tallTextSize: CGFloat = 13.5

    /// The Clear ⓧ's hit frame, 24 square, centred where the board's 18 pt
    /// glyph is (the glyph at the card's top right, 8 down and 24 in).
    static let clearSide: CGFloat = 24
    /// The Paste push button's height: `ToolbarPushButtonStyle`'s 22.
    static let pasteHeight: CGFloat = 22

    /// Speak and Copy Translation are 24 pt (spec §11); the footer starts 4 left
    /// of the text so the glyphs, not their plates, line up with it.
    static let footerButton: CGFloat = 24
    static let footerLead: CGFloat = 4
    static let footerSpacing: CGFloat = 4

    // MARK: - The pair bar

    struct PairBar: Equatable {
        var from: CGRect
        var swap: CGRect
        var to: CGRect
    }

    /// The pop-ups' width at this content width: 210 where there is room for it
    /// and the swap's slot between (560 and wider), narrower below.
    static func popUpWidth(bodyWidth: CGFloat) -> CGFloat {
        let content = PlayerLayout.paneWidth(bodyWidth: bodyWidth)
        return min(popUpWidth, ((content - swapSide - 2 * swapGap) / 2).rounded(.down))
    }

    static func pairBar(bodyWidth: CGFloat, headerHeight: CGFloat = PlayerLayout.referenceHeaderHeight) -> PairBar {
        let content = PlayerLayout.paneWidth(bodyWidth: bodyWidth)
        let left = PlayerLayout.paneLeading
        let y = headerHeight + pairBarOffset
        let width = popUpWidth(bodyWidth: bodyWidth)
        return PairBar(
            from: CGRect(x: left, y: y, width: width, height: popUpHeight),
            // Centred on the content's middle — the board's 290 at 560 is its left
            // edge (302 − 12) — so the two gaps are the same at every width.
            swap: CGRect(x: left + content / 2 - swapSide / 2, y: y - 1, width: swapSide, height: swapSide),
            to: CGRect(x: left + content - width, y: y, width: width, height: popUpHeight)
        )
    }

    // MARK: - The cards

    static func cardTop(headerHeight: CGFloat = PlayerLayout.referenceHeaderHeight) -> CGFloat {
        headerHeight + pairBarOffset + cardsDrop
    }

    static func cardHeight(bodyHeight: CGFloat, headerHeight: CGFloat = PlayerLayout.referenceHeaderHeight) -> CGFloat {
        max(0, bodyHeight - cardFootInset - cardTop(headerHeight: headerHeight))
    }

    static func sourceCard(bodySize: CGSize, headerHeight: CGFloat = PlayerLayout.referenceHeaderHeight) -> CGRect {
        let content = PlayerLayout.paneWidth(bodyWidth: bodySize.width)
        let width = ((content - cardGap) / 2 + sourceBonus).rounded()
        return CGRect(
            x: PlayerLayout.paneLeading, y: cardTop(headerHeight: headerHeight), width: width,
            height: cardHeight(bodyHeight: bodySize.height, headerHeight: headerHeight)
        )
    }

    static func resultCard(bodySize: CGSize, headerHeight: CGFloat = PlayerLayout.referenceHeaderHeight) -> CGRect {
        let source = sourceCard(bodySize: bodySize, headerHeight: headerHeight)
        let right = PlayerLayout.paneLeading + PlayerLayout.paneWidth(bodyWidth: bodySize.width)
        let left = source.maxX + cardGap
        return CGRect(x: left, y: source.minY, width: right - left, height: source.height)
    }

    /// Where the source's text is laid: inside the card, above its foot (the
    /// counter and Paste live there).
    static func sourceText(card: CGRect) -> CGRect {
        CGRect(
            x: card.minX + textInset, y: card.minY + textTop,
            width: card.width - textInset - sourceTextTrailing, height: max(0, card.height - textTop - 32)
        )
    }

    static func clear(card: CGRect) -> CGRect {
        CGRect(x: card.maxX - 27, y: card.minY + 5, width: clearSide, height: clearSide)
    }

    /// "%d / 5,000", 22 above the card's foot (the board's 170 on a card ending at 192).
    static func counter(card: CGRect) -> CGRect {
        CGRect(x: card.minX + textInset, y: card.maxY - 22, width: card.width - 2 * textInset, height: 12)
    }

    static func paste(card: CGRect, width: CGFloat = 66) -> CGRect {
        CGRect(x: card.minX + textInset, y: card.maxY - 32, width: width, height: pasteHeight)
    }

    /// The result's text: plain, at the card's own leading edge (no plate behind
    /// it), 9 down.
    static func resultText(card: CGRect) -> CGRect {
        CGRect(
            x: card.minX, y: card.minY + textTop,
            width: card.width - resultTextTrailing, height: max(0, card.height - textTop - 34)
        )
    }

    /// The footer's row: Speak, Copy Translation, then the origin. 24 tall,
    /// 29 above the card's foot (the board's 163 on 192).
    static func footer(card: CGRect) -> CGRect {
        CGRect(x: card.minX - footerLead, y: card.maxY - 29, width: card.width + footerLead, height: footerButton)
    }

    static func speakButton(card: CGRect) -> CGRect {
        CGRect(x: footer(card: card).minX, y: footer(card: card).minY, width: footerButton, height: footerButton)
    }

    static func copyButton(card: CGRect, showsSpeak: Bool) -> CGRect {
        let first = footer(card: card)
        let offset = showsSpeak ? footerButton + footerSpacing : 0
        return CGRect(x: first.minX + offset, y: first.minY, width: footerButton, height: footerButton)
    }

    /// Every control the pane draws in the pair bar and the cards, by name, for
    /// the layout tests: each must be inside the content area, and none may
    /// overlap another.
    static func controlFrames(
        bodySize: CGSize, headerHeight: CGFloat = PlayerLayout.referenceHeaderHeight, showsSpeak: Bool = true
    ) -> [(name: String, frame: CGRect)] {
        let bar = pairBar(bodyWidth: bodySize.width, headerHeight: headerHeight)
        let result = resultCard(bodySize: bodySize, headerHeight: headerHeight)
        let source = sourceCard(bodySize: bodySize, headerHeight: headerHeight)
        var frames: [(String, CGRect)] = [
            ("Translate From", bar.from), ("Swap Languages", bar.swap), ("Translate To", bar.to),
            ("Clear", clear(card: source)),
            ("Copy Translation", copyButton(card: result, showsSpeak: showsSpeak)),
        ]
        if showsSpeak { frames.append(("Speak", speakButton(card: result))) }
        return frames
    }

    // MARK: - History

    /// The list's first row, 20 under the "Recent" label that sits where the cards
    /// begin less 30 (the board's 44 and 64 on a 38 header).
    static func historyLabelTop(headerHeight: CGFloat = PlayerLayout.referenceHeaderHeight) -> CGFloat { headerHeight + 6 }
    static func historyListTop(headerHeight: CGFloat = PlayerLayout.referenceHeaderHeight) -> CGFloat { headerHeight + 26 }
    static let historyRowHeight: CGFloat = 40
    static let historyRowInset: CGFloat = 8

    /// The scroll window of the list: the content width, from the first row to
    /// the body's foot less the shell's 14 and 4 of air.
    static func historyViewport(bodySize: CGSize, headerHeight: CGFloat = PlayerLayout.referenceHeaderHeight) -> CGRect {
        let top = historyListTop(headerHeight: headerHeight)
        return CGRect(
            x: PlayerLayout.paneLeading, y: top,
            width: PlayerLayout.paneWidth(bodyWidth: bodySize.width), height: max(0, bodySize.height - 18 - top)
        )
    }
}

/// The header's trailing tools on the Translate tab: History, and Expand beside it
/// (spec §11). History is the 22 pt icon button at (`bw − 67`, 8); Expand is
/// `HeaderToolFrames.expand`, (`bw − 39`, 8), so it never moves whether History
/// is there or not.
enum TranslateHeader {
    static func history(bodyWidth: CGFloat) -> CGRect {
        CGRect(x: bodyWidth - 67, y: HeaderToolFrames.top, width: HeaderToolFrames.side, height: HeaderToolFrames.side)
    }

    /// Whether the tab wears History at all: only while Keep History is on, the
    /// default being off (spec §11, §14) — a person who never asked to be
    /// remembered is not offered a list of what they translated.
    static func showsHistory(keepHistory: Bool) -> Bool { keepHistory }
}

// MARK: - The pop-ups' menus (spec §11)

/// One row of a language pop-up's menu, apart from AppKit so the order and the
/// words are something a test reads.
struct TranslateMenuEntry: Equatable {
    enum Kind: Equatable {
        case header
        case separator
        /// "Detect Language", the source's first row.
        case detect
        case language(String)
        /// "Translation Languages…", the last row: System Settings, where the
        /// languages are downloaded.
        case translationLanguages
    }

    var kind: Kind
    var title: String
    var isChecked = false
}

enum TranslateMenuModel {
    enum Side { case source, target }

    /// The most targets "Recent" keeps and lists.
    static let recentCapacity = 3

    /// `recents` with `language` at the front: moved there if it was already in
    /// the list, and the list cut to three.
    static func recents(_ recents: [TranslationLanguage], adding language: TranslationLanguage) -> [TranslationLanguage] {
        Array(([language] + recents.filter { $0 != language }).prefix(recentCapacity))
    }

    /// A language as a menu row and as a pop-up's label: online-only ones say so.
    static func title(of language: TranslationLanguage, isOnlineOnly: Bool) -> String {
        isOnlineOnly ? localized("%@ (Online)", language.name) : language.name
    }

    /// The source pop-up's label: what it was told, or what it heard — "Detect
    /// Language" before there is anything to hear, "English (Detected)" after.
    static func sourceTitle(chosen: TranslationLanguage?, detected: TranslationLanguage, hasText: Bool, isOnlineOnly: Bool) -> String {
        if let chosen { return title(of: chosen, isOnlineOnly: isOnlineOnly) }
        return hasText ? localized("%@ (Detected)", detected.name) : localized("Detect Language")
    }

    /// The menu, top to bottom:
    ///
    /// ```
    /// ✓ Detect Language          (source only)
    /// ─────
    /// Recent                     (header)
    ///   Russian, English, Uzbek (Online)    (the last three targets)
    /// ─────
    /// On this Mac                (header)
    ///   every other language, online-only ones suffixed
    /// ─────
    /// Translation Languages…
    /// ```
    ///
    /// `chosen` is the language that is ticked: the source's choice (nil while
    /// it detects, which ticks Detect Language) or the target.
    static func entries(
        side: Side,
        chosen: TranslationLanguage?,
        recents: [TranslationLanguage],
        languages: [TranslationLanguage] = TranslationLanguage.all,
        isOnlineOnly: (TranslationLanguage) -> Bool
    ) -> [TranslateMenuEntry] {
        var entries: [TranslateMenuEntry] = []
        func row(_ language: TranslationLanguage) -> TranslateMenuEntry {
            TranslateMenuEntry(
                kind: .language(language.code), title: title(of: language, isOnlineOnly: isOnlineOnly(language)),
                isChecked: language == chosen
            )
        }
        if side == .source {
            entries.append(.init(kind: .detect, title: localized("Detect Language"), isChecked: chosen == nil))
            entries.append(.init(kind: .separator, title: ""))
        }
        let shown = Array(recents.prefix(recentCapacity))
        if !shown.isEmpty {
            entries.append(.init(kind: .header, title: localized("Recent")))
            entries.append(contentsOf: shown.map(row))
            entries.append(.init(kind: .separator, title: ""))
        }
        entries.append(.init(kind: .header, title: localized("On this Mac")))
        // Each language once: the ones listed under Recent are not repeated
        // here (the board's lists are disjoint), so choosing from either block
        // is choosing the language, and a tick is never in two places.
        entries.append(contentsOf: languages.filter { !shown.contains($0) }.map(row))
        entries.append(.init(kind: .separator, title: ""))
        entries.append(.init(kind: .translationLanguages, title: localized("Translation Languages…")))
        return entries
    }
}

// MARK: - The result card's alert (spec §11)

/// What the result card says instead of an answer, as one value: a glyph (or the
/// spinner), the sentence `Translator` already worded, and the buttons under it.
///
/// One alert at a time, in the result card, and never a toast or a banner as
/// well: `Translator` has only ever reported a failure through `failure`, and
/// this is the only place the pane draws it. The mapping is one-to-one with what
/// `Translator` reports — each `FailureKind` is a sentence it already produced —
/// and invents no new obstacle.
struct TranslateAlert: Equatable {
    enum Glyph: Equatable {
        case spinner
        case symbol(String, isWarning: Bool)
    }

    enum Action: Equatable {
        case translationLanguages
        /// "Use Online": this one text, to MyMemory, without turning
        /// Translate Online on (`Translator.useOnline`).
        case useOnline
        case turnOnOnline
        case tryAgain
        case appleIntelligenceSettings

        var title: String {
            switch self {
            case .translationLanguages: return localized("Translation Languages…")
            case .useOnline: return localized("Use Online")
            case .turnOnOnline: return localized("Turn On Translate Online")
            case .tryAgain: return localized("Try Again")
            case .appleIntelligenceSettings: return localized("Apple Intelligence Settings…")
            }
        }
    }

    var glyph: Glyph
    var message: String
    var actions: [Action]

    /// - Parameter allowanceSpent: MyMemory's daily allowance is gone
    ///   (`OnlineAllowance`). Turning Translate Online on, or using it for a
    ///   text, cannot work today, so neither is offered and the sentence says why.
    ///   No reset time is named: the allowance only knows midnight UTC is its
    ///   guess, and a guess in a sentence is a promise.
    @MainActor
    static func make(
        kind: Translator.FailureKind?, message: String, remedies: [Translator.Remedy], allowanceSpent: Bool,
        covered: Bool = false
    ) -> TranslateAlert {
        var alert = unguarded(kind: kind, message: message, remedies: remedies, allowanceSpent: allowanceSpent)
        // A card under the Privacy cover must never offer to send text the
        // person cannot see: Use Online and Turn On Translate Online both end
        // with the field's contents at MyMemory, and the second is a switch
        // that does the same for every later text. The sentence stays — it names
        // no text — and so do Translation Languages…, Try Again and the
        // settings buttons, which send nothing.
        if covered { alert.actions.removeAll { $0 == .useOnline || $0 == .turnOnOnline } }
        return alert
    }

    /// The buttons under a partial answer's note, from the same remedies, with
    /// the same two guards: a Use Online that sends text is withheld under the
    /// cover and once the day's allowance is gone.
    @MainActor
    static func noteActions(remedies: [Translator.Remedy], allowanceSpent: Bool, covered: Bool) -> [Action] {
        remedies.compactMap { remedy -> Action? in
            switch remedy {
            case .appleIntelligenceSettings: return .appleIntelligenceSettings
            case .translationLanguages: return .translationLanguages
            case .turnOnOnline: return covered ? nil : .turnOnOnline
            case .retry: return .tryAgain
            case .useOnline: return covered || allowanceSpent ? nil : .useOnline
            }
        }
    }

    @MainActor
    private static func unguarded(
        kind: Translator.FailureKind?, message: String, remedies: [Translator.Remedy], allowanceSpent: Bool
    ) -> TranslateAlert {
        // An unreachable failure after a Use Online run sets remedies = [.useOnline];
        // once the day's allowance was then spent, this still offered a send that
        // cannot work. Withheld here exactly as `noteActions` does.
        let remedyActions: [Action] = remedies.compactMap { remedy -> Action? in
            switch remedy {
            case .appleIntelligenceSettings: return .appleIntelligenceSettings
            case .translationLanguages: return .translationLanguages
            case .turnOnOnline: return .turnOnOnline
            case .retry: return .tryAgain
            case .useOnline: return allowanceSpent ? nil : .useOnline
            }
        }
        let quota = Translator.describe(OnlineTranslation.Failure.quotaExhausted).message
        switch kind {
        case .obstacle(.needsDownload):
            return TranslateAlert(
                glyph: .symbol("arrow.down.circle", isWarning: false), message: message,
                actions: allowanceSpent || remedyActions.contains(.useOnline) ? remedyActions : remedyActions + [.useOnline]
            )
        case .obstacle(.needsOnline), .obstacle(.needsNewerSystem):
            if allowanceSpent, remedyActions.contains(.turnOnOnline) {
                return TranslateAlert(glyph: .symbol("exclamationmark.bubble", isWarning: true), message: quota, actions: [])
            }
            return TranslateAlert(glyph: .symbol("globe", isWarning: false), message: message, actions: remedyActions)
        case .obstacle(.appleIntelligenceOff), .obstacle(.deviceNotEligible):
            return TranslateAlert(glyph: .symbol("info.circle", isWarning: false), message: message, actions: remedyActions)
        case .obstacle(.modelNotReady):
            return TranslateAlert(glyph: .spinner, message: message, actions: remedyActions)
        case .unreachable, .quotaExhausted, .other, nil:
            return TranslateAlert(
                glyph: .symbol("exclamationmark.bubble", isWarning: true), message: message, actions: remedyActions
            )
        }
    }
}

/// Which source text gets the Paste button: none while the field has any.
enum TranslatePaste {
    /// Shown on an empty source only; enabled only when the pasteboard offers text.
    static func shows(input: String) -> Bool { input.isEmpty }
}
