import SwiftUI

/// Two columns, the way every translator is laid out: source on the left,
/// result on the right. The left one sits on a surface — that is the whole
/// signal that it can be typed into, since a caret only shows up once there
/// is something in it.
///
/// Each column's heading is its language, and a menu: the source can detect
/// or be told, the target is chosen, and the swap between them exchanges the
/// languages and the text the way every translator's swap does. It was English
/// and Russian, decided by the script typed, until 2026-09-21.
struct TranslatePane: View {
    @ObservedObject var translator: Translator
    /// ⌃⌥⌘T fills the source field with whatever was on the clipboard, so this
    /// pane can be displaying the same secret the clipboard tab covers.
    @ObservedObject var privacy: PrivacyMode
    /// Whether the panel holds the keyboard. Drops to false when the user
    /// clicks into another app, and the field follows it — the caret has to
    /// stop blinking here when it has genuinely gone elsewhere.
    @Binding var wantsKeyboard: Bool

    @FocusState private var focused: Bool

    /// The one reveal id for the whole pane: uncovering the source uncovers
    /// the answer beside it, since one without the other hides nothing.
    static let revealID = "translate.source"

    /// Covered until deliberately revealed, like a clipboard row. The reveal is
    /// per-session and keyed to the pane, not to any particular text; the
    /// controller conceals it again when the hot key brings in new text.
    private var covered: Bool {
        privacy.hides(.translate, Self.revealID) && !translator.input.isEmpty
    }

    /// What the editor writes through. A keystroke is the person at the
    /// keyboard, and the cover is against a passing camera, not against them:
    /// covering what they type made the field go to dust on the first letter
    /// and turned the click meant to place the caret into a reveal (F-021).
    /// So typing uncovers the pane. Text that arrives without a keystroke, the
    /// hot key and the Service, is assigned to the translator directly and
    /// never passes through here, so a clipboard secret stays covered. The
    /// comparison keeps an editor that writes back the text it was just given
    /// from counting as a keystroke.
    static func typed(_ text: String, privacy: PrivacyMode, translator: Translator) {
        guard text != translator.input else { return }
        // Only while covering: a reveal recorded with the cover off would
        // leave the pane already uncovered the moment it is turned on.
        if privacy.covers(.translate) { privacy.reveal(revealID) }
        translator.input = text
    }
    /// Whether the empty field shows its placeholder. Only empty: a covered
    /// field holds text by definition, and its dust is what shows.
    static func showsPlaceholder(input: String, covered: Bool) -> Bool {
        input.isEmpty && !covered
    }

    /// Measured once, off the layout path. See `body`.
    @State private var paneSize: CGSize = .zero

    /// Largest first. Four rungs, far enough apart that a change is always a
    /// deliberate-looking drop rather than a wobble. Raw points, not roles: a
    /// rung is a fit calculation against the measured pane, and rounding it to
    /// the nearest role would move where every paragraph wraps.
    static let ladder: [CGFloat] = [27, 20, 15, 11]

    var body: some View {
        let font = fontSize(in: paneSize)
        let route = translator.route
        HStack(alignment: .top, spacing: 10) {
            source(font, route: route)
            result(font, route: route)
        }
        // Measured from a background layer rather than by wrapping the content
        // in a GeometryReader. Wrapped, the type size depends on a measurement
        // that depends on the very text being sized, so every wrap onto a new
        // line costs a second layout pass — which is exactly the hitch one sees
        // at the moment a line breaks. The panel never changes size, so this
        // reads once and then stays put.
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { paneSize = proxy.size }
                    .onChange(of: proxy.size) { _, new in paneSize = new }
            }
        )
        .padding(.top, 2)
        // One task for both the text and the retry counter: a keystroke
        // cancels the pending sleep, so only a pause actually translates.
        .task(id: translator.request) { await schedule() }
        .onAppear { focused = wantsKeyboard }
        .onChange(of: wantsKeyboard) { _, wants in focused = wants }
    }

    // MARK: - Left

    private func source(_ font: CGFloat, route: Translator.Route) -> some View {
        column {
            sourceMenu(route: route)
        } accessory: {
            if !translator.input.isEmpty {
                Button { translator.reset() } label: {
                    Image(systemName: "xmark")
                        .islandFont(.caption, weight: .semibold)
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PanelButtonStyle())
                .help(localized("Clear"))
                .accessibilityLabel(localized("Clear"))
            }
        } content: {
            // A `TextField(axis: .vertical)` grows to fit its text, and growing
            // means reporting a new intrinsic size, which invalidates layout
            // all the way to the root of the panel — once per wrapped line,
            // which is precisely when the hitch showed. An editor takes the
            // rectangle it is given and re-wraps inside it, so a new line
            // costs nothing outside its own bounds.
            //
            // Bound through `typed`, not straight to the translator, so that
            // only a keystroke uncovers the pane: see `typed`.
            TextEditor(text: Binding(
                get: { translator.input },
                set: { Self.typed($0, privacy: privacy, translator: translator) }
            ))
                // Transparent rather than removed: the editor has to stay in
                // the tree to keep the keyboard focus the hot key gave it, so
                // the first keystroke lands here and uncovers what it typed.
                .opacity(covered ? 0 : 1)
                .overlay {
                    if covered {
                        dust(seed: 0x5DEECE66D)
                    }
                }
                .textEditorStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.hidden)
                // The ladder's rung for this text, not a role: see `ladder`.
                .font(.system(size: font))
                .foregroundStyle(.white)
                // Grey rather than the system accent: the caret has to say
                // where typing lands without being the brightest thing in a
                // panel that is mostly dark and mostly still.
                .tint(Theme.secondary)
                .focused($focused)
                // The editor insets its text by a few points of its own; pull
                // that back so the first character lines up with the title.
                .padding(.leading, -5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // Named, or VoiceOver announced an unnamed text area: the
                // only field in the panel, and nothing said what it was for
                // (F-030).
                .accessibilityLabel(localized("Text to translate"))
                // An empty field was a dark rectangle that said nothing. The
                // invitation sits where the first character will, at the size
                // that character will take, and goes with it. Drawn, not
                // read: the label above already says it, and clicks pass
                // through to the editor underneath to place the caret.
                .overlay(alignment: .topLeading) {
                    if Self.showsPlaceholder(input: translator.input, covered: covered) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(localized("Type or paste text"))
                                .font(.system(size: font))
                                .foregroundStyle(Theme.tertiary)
                                .accessibilityHidden(true)
                            // Under the invitation, where the eye already
                            // is: an empty field after ⌃⌥⌘T is exactly the
                            // moment to say the clipboard held no text.
                            if let notice = translator.notice {
                                noticeLine(notice)
                            }
                        }
                        .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                // No Escape handler here: `NotchPanel.sendEvent` takes every
                // Escape before it reaches the responder chain, and the reset
                // lives in `NotchViewModel.consumeEscape`. A handler here was
                // dead code that looked like the behaviour.
            // With text in the field the invitation is gone, and a line over
            // the text would sit on top of it, so the notice moves below the
            // editor: a cut clipboard, or an image pressed over a sentence
            // that was already there.
            if let notice = translator.notice,
               !Self.showsPlaceholder(input: translator.input, covered: covered) {
                noticeLine(notice)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.surface)
        )
    }

    // MARK: - Right

    private func result(_ font: CGFloat, route: Translator.Route) -> some View {
        column {
            HStack(spacing: 6) {
                swapButton
                targetMenu(route: route)
            }
        } accessory: {
            if translator.engine == .online, !translator.output.isEmpty {
                // Said where it happened: this answer left the Mac.
                Image(systemName: SettingsIcon.online)
                    .islandFont(.caption, weight: .semibold)
                    .foregroundStyle(Theme.tertiary)
                    .help(localized("Translated online by MyMemory"))
                    .accessibilityLabel(localized("Translated online by MyMemory"))
            }
            if !translator.output.isEmpty {
                // Disabled, not hidden, while the answer is to the text before
                // an edit: Copy pressed in that window used to paste a
                // translation of the old sentence (K-004), and a button that
                // vanished at every pause in typing would make the header
                // jump instead.
                // Named, because "Copy" beside a field that also copies does
                // not say which text lands; and keyed, because after ⌃⌥⌘T
                // the caret is in the source and ⌘C copies that (H-018).
                CopyButton(
                    title: localized("Copy Translation"),
                    shortcut: "⇧⌘C",
                    copiesElsewhere: translator.outputCopies
                ) { translator.copyOutput() }
                    .disabled(!translator.answersInput)
                    .opacity(translator.answersInput ? 1 : 0.4)
            }
        } content: {
            outcome(font)
        }
        .padding(10)
    }

    /// What the result column shows.
    enum Showing: Equatable {
        case translating
        /// Clipboard text waiting for "Send to MyMemory" (M-25).
        case asking
        case failure
        case covered
        case answer
        case nothing
    }

    /// The spinner comes before a failure. A failure used to win, so Retry —
    /// or an edit — under "The translation could not be completed." changed
    /// nothing on screen for the whole run, and a run that failed the same
    /// way again never visibly happened at all (K-004). An earlier answer is
    /// not displaced the same way: it stays up, dimmed by the caller while it
    /// is not the field's answer, rather than flashing to a spinner at every
    /// pause in typing.
    ///
    /// The question about clipboard text sits where a failure would, and in
    /// its place: it is what stands between the text and an answer, and a run
    /// for other text takes it down before it lands (`Translator.translate`).
    static func showing(
        failure: Bool, output: Bool, covered: Bool, translating: Bool, asking: Bool = false
    ) -> Showing {
        if translating, failure || !output { return .translating }
        if asking { return .asking }
        if failure { return .failure }
        if output { return covered ? .covered : .answer }
        return .nothing
    }

    @ViewBuilder
    private func outcome(_ font: CGFloat) -> some View {
        switch Self.showing(
            failure: translator.failure != nil,
            output: !translator.output.isEmpty,
            covered: privacy.hides(.translate, Self.revealID),
            translating: translator.isTranslating,
            asking: translator.consentPrompt != nil
        ) {
        case .asking:
            // The same sentence-and-capsule as a failure, so "Send to
            // MyMemory" is pressed the way "Turn On Translate Online" is.
            offer(translator.consentPrompt ?? "")
        case .failure:
            offer(translator.failure ?? "")
        case .covered:
            // The answer is the secret too, only in another language: covering
            // the source and leaving this column readable at headline size
            // hid nothing (F-002), and the accessibility tree handed the
            // translation to anything that asked. Replaced rather than
            // overlaid, as `SpoilerField` promises: the text is not in the
            // view tree at all while it is hidden. Copy stays offered in the
            // header, so the result can be pasted somewhere without ever being
            // shown on a screen somebody else is watching.
            dust(seed: 0xA24BAED4963EE407)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .answer:
            ScrollView(showsIndicators: false) {
                Text(translator.output)
                    // The ladder's rung for this text, not a role: see `ladder`.
                    .font(.system(size: font))
                    // Dimmed while it answers the text before an edit: from
                    // the keystroke until the new answer lands it translates
                    // something no longer in the field, and it used to sit
                    // there at full white as if it were current (K-004).
                    // Kept rather than cleared, so a pause in typing does not
                    // blank the column.
                    .foregroundStyle(translator.answersInput ? Color.white : Theme.secondary)
                    .animation(Theme.contentAnimation, value: translator.answersInput)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .translating:
            // The on-device model is not instant the way a lookup table would
            // be — a paragraph takes a beat, and the very first request after
            // a boot can take considerably longer while the model loads. An
            // empty column through all of that is indistinguishable from a
            // translation that came back blank.
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(localized("Translating…"))
                    .islandFont(.body, weight: .regular)
                    .foregroundStyle(Theme.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .nothing:
            Color.clear
        }
    }

    // MARK: - Type size
    //
    // A word should read like a headline and a paragraph has to fit, so the
    // size has to move — but it moves in steps, not continuously. Sizing the
    // type to the exact text length means every keystroke re-breaks every line
    // for a fraction of a point nobody asked for, and that reads as the text
    // shaking rather than as anything smooth. One decisive drop, rarely, is
    // both calmer to look at and easier to trust.

    /// What the text actually gets to occupy inside one column: half the pane
    /// minus the gap, minus the padding, minus the title row above it — 20
    /// of padding, the 20-point row (`column`) and the 6 under it.
    private func textArea(in size: CGSize) -> CGSize {
        CGSize(
            width: max(40, (size.width - 10) / 2 - 20),
            height: max(40, size.height - 46)
        )
    }

    /// The largest rung the text still fits on. Both columns share it, computed
    /// from whichever side is longer — sides set at different scales stop
    /// looking like a pair.
    private func fontSize(in size: CGSize) -> CGFloat {
        // Before the first measurement lands there is nothing to fit type to,
        // and the pane is empty anyway.
        guard size.width > 0, size.height > 0 else { return Self.ladder[0] }
        return Self.fontSize(source: translator.trimmed, output: translator.output, column: textArea(in: size))
    }

    /// The rung for a pair of texts in a column of `column` (see `textArea`).
    /// A rung has to pass two tests: the whole text fits its area, and no word
    /// is wider than a line. The length alone used to decide, and a short
    /// sentence with one long word got the top rung: "Где находится
    /// железнодорожная станция?" is 38 characters, comfortably a headline, but
    /// at 27 points "железнодорожная" is 230 points wide in a 219-point column,
    /// and the person's own language arrived as "железнодорожна / я станция?"
    /// (H-006). Shrinking only the line that overflows, `minimumScaleFactor`'s
    /// way, would set the two columns at different sizes; SwiftUI's `Text`
    /// cannot hyphenate on macOS 15. So the whole pair steps down a rung.
    static func fontSize(source: String, output: String, column: CGSize) -> CGFloat {
        let count = CGFloat(max(source.count, output.count))
        guard count > 0 else { return ladder[0] }
        // A glyph runs about half its point size wide and 1.3 of it tall with
        // leading, so roughly `area / (0.76 · s²)` characters fit at size `s`.
        // The 0.95 keeps the last line from being the one that overflows.
        let usable = column.width * column.height * 0.95
        // The source is laid out by a text view that keeps 5 points clear on
        // each side of every line, and the pane pulls only the leading 5 back
        // (see `source`), so its lines are 5 points narrower than the result
        // column's. The narrower one decides, since the rung is shared.
        let line = column.width - 5
        // Split only once a rung above the last has passed the length test,
        // which also bounds how much text is ever measured: a text long
        // enough to be expensive has already been sent to the bottom rung.
        var words: [String]?
        for size in ladder.dropLast() where count <= usable / (0.76 * size * size) {
            let candidates = words ?? (unbreakableRuns(in: source) + unbreakableRuns(in: output))
            words = candidates
            // The same font the view sets, `.system(size:)` at regular weight,
            // or the measurement would answer for type nobody draws.
            let font = NSFont.systemFont(ofSize: size)
            if candidates.allSatisfy({ ($0 as NSString).size(withAttributes: [.font: font]).width <= line }) {
                return size
            }
        }
        // A word too wide even here, a long URL or a hash, still breaks by
        // character at the bottom rung, as text must when nothing else fits.
        return ladder[ladder.count - 1]
    }

    /// The stretches of `text` a line cannot break inside: the pieces between
    /// Unicode line-break opportunities, with the space that ends each one
    /// dropped, since a space at the end of a line hangs past the edge. Not a
    /// split on whitespace: Japanese and Chinese have none and break between
    /// almost any two characters, so a whitespace split measured a whole
    /// Japanese sentence as one word and dropped it a rung for nothing. The
    /// same rules let "железнодорожно-транспортный" break after its hyphen,
    /// as the renderer does.
    private static func unbreakableRuns(in text: String) -> [String] {
        let string = text as NSString
        let tokenizer = CFStringTokenizerCreate(
            nil, text as CFString, CFRangeMake(0, string.length), kCFStringTokenizerUnitLineBreak, nil
        )
        var runs: [String] = []
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let run = string.substring(with: NSRange(location: range.location, length: range.length))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !run.isEmpty { runs.append(run) }
        }
        return runs
    }

    // MARK: - Languages

    /// The source's heading: what it was told, or what it heard.
    private func sourceTitle(route: Translator.Route) -> String {
        guard translator.source == nil else { return route.source.name }
        return translator.trimmed.isEmpty
            ? localized("Detect Language")
            : localized("%@ (Detected)", route.source.name)
    }

    private func sourceMenu(route: Translator.Route) -> some View {
        Menu {
            Toggle(localized("Detect Language"), isOn: Binding(
                get: { translator.source == nil },
                set: { if $0 { choose { translator.choose(source: nil) } } }
            ))
            Divider()
            ForEach(TranslationLanguage.all) { language in
                languageItem(language, isChosen: translator.source == language) {
                    translator.choose(source: language)
                }
            }
        } label: {
            heading(sourceTitle(route: route))
        }
        .languageMenuStyle()
        .accessibilityLabel(localized("Translate From"))
        .accessibilityValue(sourceTitle(route: route))
    }

    /// The target's heading is the language the text is actually going into:
    /// when the source turns out to be the chosen target, the tab turns the
    /// pair around rather than translating a language into itself, and a
    /// heading that kept the choice would name a language nothing is in.
    private func targetMenu(route: Translator.Route) -> some View {
        Menu {
            ForEach(TranslationLanguage.all) { language in
                languageItem(language, isChosen: translator.target == language) {
                    translator.choose(target: language)
                }
            }
        } label: {
            heading(route.target.name)
        }
        .languageMenuStyle()
        .accessibilityLabel(localized("Translate To"))
        .accessibilityValue(route.target.name)
    }

    /// One row of a language menu: a toggle, because a menu draws a toggle as
    /// the native checkmarked item. An inline picker drew the same checkmark
    /// but had no row to tick while the source detects, and said so in the
    /// console on every open.
    private func languageItem(
        _ language: TranslationLanguage, isChosen: Bool, choose change: @escaping () -> Void
    ) -> some View {
        Toggle(menuTitle(language), isOn: Binding(
            get: { isChosen },
            set: { wants in if wants { choose(change) } }
        ))
    }

    /// A language this Mac can only translate online says so in the list,
    /// before it is picked rather than after.
    private func menuTitle(_ language: TranslationLanguage) -> String {
        translator.isOnlineOnly(language) ? localized("%@ (Online)", language.name) : language.name
    }

    private var swapButton: some View {
        Button {
            choose { translator.swap() }
        } label: {
            Image(systemName: "arrow.left.arrow.right")
                .islandFont(.caption, weight: .semibold)
                .foregroundStyle(Theme.secondary)
                // The panel's minimum target, where the glyph's own 18x14 was
                // the frame and a swap at the top edge of the screen took a
                // careful aim (F-014). It stays beside the target language:
                // between the columns it would sit on the source's surface in
                // a 10-point gutter (M-16).
                .frame(width: Theme.minimumHitSize.width, height: Theme.minimumHitSize.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(PanelButtonStyle())
        .help(localized("Swap Languages"))
        .accessibilityLabel(localized("Swap Languages"))
    }

    /// A language change is a content change like a pane change: the headings
    /// and the text settle on the same short ease rather than cutting.
    private func choose(_ change: () -> Void) {
        withAnimation(Theme.contentAnimation) { change() }
    }

    /// A sentence and the buttons that answer it: a failure and its remedies,
    /// or the question clipboard text waits behind (M-25).
    private func offer(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message)
                .islandFont(.body, weight: .regular)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Capsules, the panel's shape for an offer. They were bare
            // bold caption words, and the only way forward from the first
            // error a newcomer meets did not look like something to press
            // (H-007).
            HStack(spacing: 8) {
                ForEach(translator.remedies, id: \.self) { remedy in
                    remedyButton(remedy)
                }
            }
            .buttonStyle(OfferButtonStyle())
            // Russian's "Включить «Переводить онлайн»" is wider than this
            // column at a 480-point panel and breaks onto a second line.
            // Centred, the two lines still read as one button; left-
            // aligned, they read as a paragraph in a box. Set here rather
            // than in the style, because centring moves a one-line label
            // by a fraction of a point and the other offers were to stay
            // pixel-for-pixel what they were.
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func remedyButton(_ remedy: Translator.Remedy) -> some View {
        switch remedy {
        case .appleIntelligenceSettings:
            Button(localized("Apple Intelligence Settings…")) { Translator.openAppleIntelligenceSettings() }
        case .translationLanguages:
            Button(localized("Translation Languages…")) { Translator.openTranslationLanguages() }
        case .turnOnOnline:
            Button(localized("Turn On Translate Online")) { translator.turnOnOnline() }
        case .retry:
            Button(localized("Retry")) { translator.retry() }
        case .sendOnline:
            Button(localized("Send to MyMemory")) { translator.sendOnline() }
        }
    }

    // MARK: - Shared

    /// How text arrived by hot key or Service: none on the clipboard, or cut
    /// to the limit (`Translator.prepareCommandInput`). Caption-sized and
    /// tertiary — it is a remark about the field, not the field — and read by
    /// VoiceOver, unlike the placeholder it may sit under, because it says
    /// something the field does not.
    private func noticeLine(_ text: String) -> some View {
        Text(text)
            .islandFont(.caption, weight: .regular)
            .foregroundStyle(Theme.tertiary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// What stands in for either column while the pane is covered. Clicking
    /// the dust uncovers it, the same gesture the clipboard rows use, and one
    /// reveal uncovers both columns. Each column gets its own seed, or the two
    /// would draw the same dust side by side and read as one texture copied.
    ///
    /// Announced as "Hidden", the word a covered clipboard row uses, with a
    /// press that does what the click does. Unlabelled, the source's dust was
    /// simply absent from the tree, and a screen reader must not be the hole
    /// in a feature about not showing things.
    private func dust(seed: UInt64) -> some View {
        SpoilerField(seed: seed)
            .contentShape(Rectangle())
            .onTapGesture { privacy.reveal(Self.revealID) }
            .accessibilityElement()
            .accessibilityLabel(Text(localized("Hidden")))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { privacy.reveal(Self.revealID) }
    }

    /// A column heading: the language, set the way every header in the panel
    /// is set, with the small chevron that says it opens.
    ///
    /// One `Text`, the chevron an image inside it. As an `HStack` of a text
    /// and an image, the menu's label was two elements, and each became a
    /// menu button of its own: VoiceOver read every picker twice, and one of
    /// the two stops was the chevron alone, a 7x4-point target (H-021).
    ///
    /// Framed to the panel's minimum hit height with the hit shape over the
    /// whole frame, because the menu is as tall as its label: it was the
    /// 13-point line of caption type, at the top edge of the screen (F-014).
    private func heading(_ title: String) -> some View {
        (Text(title.uppercased()).tracking(Theme.capsTracking)
            + Text(" ")
            // A glyph fitted to the caption line, not type.
            + Text(Image(systemName: "chevron.down")).font(.system(size: 7, weight: .bold)))
            .islandFont(.caption, weight: .semibold)
            .lineLimit(1)
            .foregroundStyle(Theme.tertiary)
            .frame(minHeight: Theme.minimumHitSize.height)
            .contentShape(Rectangle())
    }

    private func column<Heading: View, Accessory: View, Content: View>(
        @ViewBuilder heading: () -> Heading,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                heading()
                Spacer(minLength: 4)
                accessory()
            }
            // The minimum hit height, so the language menus in it can be as
            // tall as a target (F-014); it was 14. Fixed rather than a
            // minimum: the 22-point Clear arrives with the first character
            // and leaves with the last, and a row that grew to hold it would
            // move the text below by two points at every one of those.
            .frame(height: Theme.minimumHitSize.height)

            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Scheduling

    private func schedule() async {
        let text = translator.trimmed
        guard !text.isEmpty else {
            translator.clear()
            return
        }
        // Wait out the typing: a word is a handful of keystrokes, and a session
        // per letter would be both wasteful and visibly jumpy.
        try? await Task.sleep(for: .milliseconds(320))
        guard !Task.isCancelled else { return }

        await translator.translate()
    }
}

private extension View {
    /// A menu drawn as its own label and nothing else — no bezel, no system
    /// arrow — so the heading reads as a heading until it is pressed.
    func languageMenuStyle() -> some View {
        menuStyle(.button)
            .buttonStyle(PanelButtonStyle())
            .menuIndicator(.hidden)
            .fixedSize()
    }
}
