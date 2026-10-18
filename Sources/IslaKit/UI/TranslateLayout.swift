import CoreGraphics
import Foundation

/// Where everything on the Translate surface sits (spec §19.8, board
/// `R2-Translate`), as values.
///
/// Stated in the content's coordinates — the body under the header row, the
/// reference's y less 38 — like `ClipboardLayout`, so a test that holds the
/// spec's numbers holds the pixels at 480, 560 and 620 without rendering
/// anything. Everything derives from `bw`: the pair row and the two cards each
/// split the body down its middle, the source a little wider than the result
/// because the result has no plate to inset its text from.
enum TranslateLayout {
    // MARK: - Metrics

    /// The leading and trailing margin every row keeps (§19.8: x 16 to `bw − 16`).
    static let margin: CGFloat = 16
    /// The surface's content: the three tools' shared 300 less the 38 pt
    /// header row (§19.16, amended 2026-10-18; it was 268).
    static let contentHeight: CGFloat = SurfaceLayout.translateHeight - SurfaceLayout.referenceNotchHeight

    /// The pair row at the reference's y 46, 26 tall.
    static let pairTop: CGFloat = 8
    static let pairHeight: CGFloat = 26
    /// Swap is 28 wide, its leading edge 14 left of the middle.
    static let swapWidth: CGFloat = 28

    /// The cards at the reference's y 84, radius 14, keeping the board's 24
    /// under them: 160 tall on the board's 268, 192 on the shared 300.
    static let cardTop: CGFloat = 46
    static let cardBottomRoom: CGFloat = 24
    static let cardHeight: CGFloat = contentHeight - cardTop - cardBottomRoom
    static let cardRadius: CGFloat = 14

    /// The source card's inset, 12 top and bottom and 14 at the sides; the
    /// result, which has no plate, insets its text 12 and 4.
    static let sourceInset = (vertical: CGFloat(12), horizontal: CGFloat(14))
    static let resultInset = (vertical: CGFloat(12), horizontal: CGFloat(4))
    /// The source text's right margin leaves room for the Clear ⓧ.
    static let sourceTextTrailing: CGFloat = 28
    /// What the cards keep under their text for the foot: the count or Paste on
    /// the source, Speak and Copy Translation on the result.
    static let footRoom: CGFloat = 32

    /// Both cards' type, 15 pt (§19.8).
    static let textSize: CGFloat = 15
    /// The source's line height, 1.35 of its size.
    static let lineHeight: CGFloat = 1.35

    /// The Clear ⓧ's hit frame, 24 square, at the card's top right.
    static let clearSide: CGFloat = 24
    /// The Paste push button's height: `ToolbarPushButtonStyle`'s 22.
    static let pasteHeight: CGFloat = 22
    /// "%d / 20,000", its foot 10 above the card's.
    static let counterBottomInset: CGFloat = 10
    static let counterHeight: CGFloat = 12

    /// Speak and Copy Translation, 26 × 24 (§19.8), on the same row as the
    /// source's count so the two feet line up across the gap.
    static let footerButton = CGSize(width: 26, height: 24)
    static let footerSpacing: CGFloat = 4

    // MARK: - The pair row

    struct PairBar: Equatable {
        var from: CGRect
        var swap: CGRect
        var to: CGRect
    }

    /// From from 16 to `bw / 2 − 24`; Swap at `bw / 2 − 14`; To from
    /// `bw / 2 + 30` to `bw − 16`.
    static func pairBar(bodyWidth bw: CGFloat) -> PairBar {
        let half = bw / 2
        return PairBar(
            from: CGRect(x: margin, y: pairTop, width: half - 24 - margin, height: pairHeight),
            swap: CGRect(x: half - 14, y: pairTop, width: swapWidth, height: pairHeight),
            to: CGRect(x: half + 30, y: pairTop, width: bw - margin - (half + 30), height: pairHeight)
        )
    }

    // MARK: - The cards

    /// At (16, 46), `bw / 2 − 24` wide.
    static func sourceCard(bodyWidth bw: CGFloat) -> CGRect {
        CGRect(x: margin, y: cardTop, width: bw / 2 - 24, height: cardHeight)
    }

    /// From `bw / 2 + 10` to `bw − 16`.
    static func resultCard(bodyWidth bw: CGFloat) -> CGRect {
        let left = bw / 2 + 10
        return CGRect(x: left, y: cardTop, width: bw - margin - left, height: cardHeight)
    }

    /// Where the source's text is laid: inside the inset, above the foot.
    static func sourceText(card: CGRect) -> CGRect {
        CGRect(
            x: card.minX + sourceInset.horizontal, y: card.minY + sourceInset.vertical,
            width: card.width - sourceInset.horizontal - sourceTextTrailing,
            height: max(0, card.height - sourceInset.vertical - footRoom)
        )
    }

    static func clear(card: CGRect) -> CGRect {
        CGRect(x: card.maxX - 27, y: card.minY + 5, width: clearSide, height: clearSide)
    }

    static func counter(card: CGRect) -> CGRect {
        CGRect(
            x: card.minX + sourceInset.horizontal, y: card.maxY - counterBottomInset - counterHeight,
            width: card.width - 2 * sourceInset.horizontal, height: counterHeight
        )
    }

    /// Paste sits where the count will, centred on the same row: the row's
    /// room, in which the button takes its own width from the left. It was a
    /// fixed 66, which cut "Paste" to "Pa…" beside its glyph (owner's review,
    /// 2026-10-18) and could never hold "Вставить".
    static func paste(card: CGRect) -> CGRect {
        let row = counter(card: card)
        return CGRect(x: row.minX, y: row.midY - pasteHeight / 2, width: row.width, height: pasteHeight)
    }

    /// The result's text, inset 12 and 4.
    static func resultText(card: CGRect) -> CGRect {
        CGRect(
            x: card.minX + resultInset.horizontal, y: card.minY + resultInset.vertical,
            width: card.width - 2 * resultInset.horizontal,
            height: max(0, card.height - resultInset.vertical - footRoom)
        )
    }

    /// The footer's row: Speak, Copy Translation, then the origin on the right,
    /// centred on the source count's row.
    static func footer(card: CGRect) -> CGRect {
        let row = counter(card: card)
        return CGRect(
            x: card.minX, y: row.midY - footerButton.height / 2,
            width: card.width - resultInset.horizontal, height: footerButton.height
        )
    }

    static func speakButton(card: CGRect) -> CGRect {
        let row = footer(card: card)
        return CGRect(origin: row.origin, size: footerButton)
    }

    static func copyButton(card: CGRect, showsSpeak: Bool) -> CGRect {
        let row = footer(card: card)
        let offset = showsSpeak ? footerButton.width + footerSpacing : 0
        return CGRect(origin: CGPoint(x: row.minX + offset, y: row.minY), size: footerButton)
    }

    /// Every control the surface draws in the pair row and the cards, by name,
    /// for the layout tests: each must be inside the content, and none may
    /// overlap another.
    static func controlFrames(bodyWidth: CGFloat, showsSpeak: Bool = true) -> [(name: String, frame: CGRect)] {
        let bar = pairBar(bodyWidth: bodyWidth)
        let result = resultCard(bodyWidth: bodyWidth)
        let source = sourceCard(bodyWidth: bodyWidth)
        var frames: [(String, CGRect)] = [
            ("Translate From", bar.from), ("Swap Languages", bar.swap), ("Translate To", bar.to),
            ("Clear", clear(card: source)),
            ("Copy Translation", copyButton(card: result, showsSpeak: showsSpeak)),
        ]
        if showsSpeak { frames.append(("Speak", speakButton(card: result))) }
        return frames
    }

    // MARK: - History

    /// The "Recent" label, then the list 20 under it, where the pair row was.
    static let historyLabelTop: CGFloat = 6
    static let historyListTop: CGFloat = 26
    static let historyRowHeight: CGFloat = 40
    static let historyRowInset: CGFloat = 8

    /// The scroll window of the list: the body less its margins, from the
    /// first row to 14 above the foot.
    static func historyViewport(bodyWidth: CGFloat) -> CGRect {
        CGRect(
            x: margin, y: historyListTop,
            width: bodyWidth - 2 * margin, height: max(0, contentHeight - 14 - historyListTop)
        )
    }
}

/// Whether Translate's header offers History at all: only while Keep History
/// is on, the default being off (spec §11, §14) — a person who never asked to
/// be remembered is not offered a list of what they translated. The button
/// itself is the shell's (`SurfaceHeaderLayout.history`).
enum TranslateHeader {
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
            // A lyric translation can spend the shared allowance between the
            // failure and this redraw: Use Online is then withheld above and the
            // card would end with a message and no action. Say why instead.
            let withheld = allowanceSpent && remedies.contains(.useOnline)
            return TranslateAlert(
                glyph: .symbol("exclamationmark.bubble", isWarning: true), message: withheld ? quota : message,
                actions: remedyActions
            )
        }
    }
}

/// Which source text gets the Paste button: none while the field has any.
enum TranslatePaste {
    /// Shown on an empty source only; enabled only when the pasteboard offers text.
    static func shows(input: String) -> Bool { input.isEmpty }
}
