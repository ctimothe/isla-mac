import AppKit
import SwiftUI

/// The Translate surface (spec §11, §19.8): a pair row of two pop-up
/// buttons with the swap between them, a source card you type into on the left
/// and the answer as plain text on the right, and — with Keep History on — a
/// list of the last twenty translations in place of both.
///
/// Every frame comes from `TranslateLayout`, in the content's coordinates under
/// the header row, so what a test holds is what is drawn at 480, 560 and 620. Nothing here decides *what* is translated or by
/// which engine: that is `Translator`, whose rules (engines, availability,
/// obstacles, online consent) this view only draws.
///
/// The source card sits on a surface — that is the whole signal that it can be
/// typed into, since a caret only shows up once there is something in it. Each
/// pop-up is its language: the source can detect or be told, the target is
/// chosen, and the swap exchanges the languages and the text the way every
/// translator's swap does.
struct TranslatePane: View {
    @ObservedObject var translator: Translator
    /// ⌃⌥⌘T fills the source field with whatever was on the clipboard, so this
    /// pane can be displaying the same secret the clipboard tab covers.
    @ObservedObject var privacy: PrivacyMode
    /// Whether the panel holds the keyboard. Drops to false when the user
    /// clicks into another app, and the field follows it — the caret has to
    /// stop blinking here when it has genuinely gone elsewhere.
    @Binding var wantsKeyboard: Bool
    /// Whether the History list is up in place of the cards: the header's
    /// History button toggles it (`NotchViewModel.translateShowsHistory`).
    @Binding var showsHistory: Bool
    private let bodyWidth: CGFloat

    /// Observed on their own: nested objects do not propagate, and the answer's
    /// sweep and the list must redraw without the whole pane being re-evaluated
    /// for anything else.
    @ObservedObject private var history: TranslationHistory
    @ObservedObject private var speaker: TranslationSpeaker
    /// Keep History and Speak Button, live: the Settings rows write these keys
    /// and the pane follows without a relaunch. Read through the translator's
    /// own defaults, so a test's private suite is the one asked.
    @AppStorage private var keepHistory: Bool
    @AppStorage private var speakButton: Bool

    @FocusState private var focused: Bool
    /// False while the pane is drawn only as the page beside the one on
    /// screen, for a swipe's length (§19.16): it translates nothing until it
    /// is the page.
    private let isLive: Bool
    /// True while the pages travel under the fingers or a dot (§19.16). The
    /// source text is then drawn by SwiftUI in place of the editor, which
    /// stays mounted, invisible, so the keyboard focus it holds survives a
    /// swipe that comes back.
    ///
    /// The editor is an AppKit text view. Carried sideways by the travel it
    /// was the one thing on the page that did not move as one with the
    /// island: the owner's film (2026-10-18) shows the source card swiped past
    /// the last page with a dark band across its foot and its left part over
    /// the island's edge. A SwiftUI copy of the text is cut by the outline
    /// like everything else, and costs no AppKit layout per frame. Its frame
    /// in the window is not reported while it travels either: reporting it
    /// wrote the view model on every frame of the swipe, which redrew the
    /// whole island a second time per frame (perf review, finding 2).
    private let isTravelling: Bool
    /// The two bindings' values when this pane was built. A binding reads its
    /// source live, so two of them always compare equal; `==` compares these
    /// instead, or a change would never reach a pane `.equatable()` keeps.
    private let keyboardClaim: Bool
    private let historyClaim: Bool

    init(
        translator: Translator,
        privacy: PrivacyMode,
        wantsKeyboard: Binding<Bool>,
        showsHistory: Binding<Bool> = .constant(false),
        bodyWidth: CGFloat = NotchMetrics.defaultBodyWidth,
        isLive: Bool = true,
        isTravelling: Bool = false
    ) {
        self.translator = translator
        self.privacy = privacy
        _wantsKeyboard = wantsKeyboard
        _showsHistory = showsHistory
        keyboardClaim = wantsKeyboard.wrappedValue
        historyClaim = showsHistory.wrappedValue
        self.bodyWidth = bodyWidth
        self.isLive = isLive
        self.isTravelling = isTravelling
        _history = ObservedObject(wrappedValue: translator.history)
        _speaker = ObservedObject(wrappedValue: translator.speaker)
        _keepHistory = AppStorage(wrappedValue: false, NotchViewModel.translateKeepHistoryKey, store: translator.defaults)
        _speakButton = AppStorage(wrappedValue: true, NotchViewModel.translateSpeakButtonKey, store: translator.defaults)
    }

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
    ///
    /// The field holds at most `Translator.commandInputLimit` characters — the
    /// number the hot key and the Service already cut to, and the one the
    /// card's counter counts against — so a paste past it is cut and says so
    /// the way theirs does, instead of reaching a text view that stalls at that
    /// size (J-017).
    static func typed(_ text: String, privacy: PrivacyMode, translator: Translator) {
        guard text != translator.input else { return }
        // Only while covering: a reveal recorded with the cover off would
        // leave the pane already uncovered the moment it is turned on.
        if privacy.covers(.translate) { privacy.reveal(revealID) }
        switch edit(text, replacing: translator.input) {
        case .accepted(let kept, let notice):
            translator.input = kept
            // After the text: setting `input` clears the notice.
            if let notice { translator.notice = notice }
        case .refused(let notice):
            // The field keeps what it held. Assigned every time, not only the
            // first: `@Published` publishes each assignment, and that
            // publication is what makes the editor, which has already taken the
            // rejected letter into its own storage, ask the binding for its text
            // again and put the old one back.
            translator.notice = notice
        }
    }

    /// What the field does with an edit that arrives from the editor.
    enum Edit: Equatable {
        case accepted(String, notice: String?)
        case refused(notice: String)
    }

    /// Decides an edit against the limit.
    ///
    /// An edit that would take text the person is already typing past
    /// `commandInputLimit` is **refused**: the field keeps what it held, and a
    /// line says why. It used to keep the first 20,000 characters of whatever
    /// the editor handed over, so a letter typed into the middle of a full field
    /// silently threw away the last letter of the person's own text.
    ///
    /// The one cut that remains is a block arriving in an **empty** field — a
    /// paste. There is nothing of the person's own to lose, a pasted block
    /// cannot be accepted a piece at a time, and the notice says what was kept
    /// (the same sentence the hot key gives). The Paste button reaches here
    /// already cut. A paste of a few characters into a field with text in it
    /// that would go past the limit is refused with the rest: the editor does
    /// not say which of the two an edit was, and refusing is the answer that
    /// loses nothing.
    static func edit(_ text: String, replacing previous: String) -> Edit {
        let kept = limited(text)
        guard let cutNotice = kept.notice else { return .accepted(text, notice: nil) }
        if previous.isEmpty { return .accepted(kept.text, notice: cutNotice) }
        // An edit that does not make the text longer is never refused, whatever
        // the length: a history entry restored past the limit would otherwise
        // be impossible to shorten one letter at a time.
        if text.count <= previous.count { return .accepted(text, notice: nil) }
        let number = Translator.commandInputLimit.formatted(.number.locale(Locale(identifier: appLanguage)))
        return .refused(notice: localized("The limit is %@ characters.", number))
    }

    /// `text` cut to the field's limit, with the line that says so when it was.
    static func limited(_ text: String) -> (text: String, notice: String?) {
        let limit = Translator.commandInputLimit
        guard let cut = text.index(text.startIndex, offsetBy: limit, limitedBy: text.endIndex), cut < text.endIndex else {
            return (text, nil)
        }
        let locale = Locale(identifier: appLanguage)
        return (
            String(text[..<cut]),
            localized("Only the first %@ characters were kept.", limit.formatted(.number.locale(locale)))
        )
    }

    /// "35 / 20,000", grouped the way the app's language groups it, like the
    /// notice's number (see `Translator.prepareCommandInput`). Written out, not
    /// looked up: two numbers and a slash read the same in every language.
    static func counterText(count: Int, locale: Locale = Locale(identifier: appLanguage)) -> String {
        "\(count.formatted(.number.locale(locale))) / \(Translator.commandInputLimit.formatted(.number.locale(locale)))"
    }

    /// Whether the empty field shows its placeholder. Only empty: a covered
    /// field holds text by definition, and its dust is what shows.
    static func showsPlaceholder(input: String, covered: Bool) -> Bool {
        input.isEmpty && !covered
    }

    /// What the result column shows.
    enum Showing: Equatable {
        case translating
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
    static func showing(failure: Bool, output: Bool, covered: Bool, translating: Bool) -> Showing {
        if translating, failure || !output { return .translating }
        if failure { return .failure }
        if output { return covered ? .covered : .answer }
        return .nothing
    }

    /// The extra leading that sets the source's lines 1.35 of its size apart
    /// (§19.8), over what the system font already leaves between them.
    static func lineSpacing(size: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size, weight: .medium)
        let natural = font.ascender - font.descender + font.leading
        return max(0, size * TranslateLayout.lineHeight - natural)
    }

    // MARK: - Body

    /// Places a view at a content frame.
    private func placed(_ rect: CGRect) -> some ViewModifier {
        Placement(frame: rect)
    }

    var body: some View {
        content(CGSize(width: bodyWidth, height: TranslateLayout.contentHeight))
            .frame(width: bodyWidth, height: TranslateLayout.contentHeight, alignment: .topLeading)
        // One task for both the text and the retry counter: a keystroke
        // cancels the pending sleep, so only a pause actually translates.
        .task(id: isLive ? translator.request : nil) {
            if isLive { await schedule() }
        }
        .onAppear { focused = wantsKeyboard }
        .onChange(of: wantsKeyboard) { _, wants in focused = wants }
        // Focus that came without a press — VoiceOver moving into the editor —
        // asks for the keyboard, as Clipboard's field does: a Translate the
        // island landed on holds none, and the keys went to the app in front
        // (R8b re-review Q1). Only on the page on screen, never on one drawn
        // beside it while the pages travel.
        .onChange(of: focused) { _, isFocused in if isFocused, isLive, !wantsKeyboard { wantsKeyboard = true } }
        // The list replaces the field; the field comes back asking for the
        // keyboard the panel still holds, one turn later so it exists to take it.
        .onChange(of: showsHistory) { _, shown in
            if shown {
                focused = false
            } else {
                DispatchQueue.main.async { focused = wantsKeyboard }
            }
        }
        // Reading aloud ends with the pane — a tab change takes it away — and
        // with the setting that offers it. The panel closing and the text
        // changing end it from `NotchViewModel` and `Translator`.
        .onDisappear { speaker.stop() }
        .onChange(of: speakButton) { _, on in if !on { speaker.stop() } }
    }

    @ViewBuilder
    private func content(_ size: CGSize) -> some View {
        // The list only exists while Keep History is on: turning it off while it
        // is up (from Settings, which is another tab) leaves the cards.
        if showsHistory, keepHistory {
            historyList(size)
        } else {
            cards(size)
        }
    }

    private func cards(_ size: CGSize) -> some View {
        let route = translator.route
        let fontSize = TranslateLayout.textSize
        return ZStack(alignment: .topLeading) {
            pairBar(size, route: route)
            sourceCard(size, fontSize: fontSize)
            resultCard(size, route: route, fontSize: fontSize)
        }
    }

    // MARK: - Pair bar (§11)

    private func pairBar(_ size: CGSize, route: Translator.Route) -> some View {
        let bar = TranslateLayout.pairBar(bodyWidth: size.width)
        return ZStack(alignment: .topLeading) {
            TranslatePopUp(
                translator: translator, side: .source,
                title: TranslateMenuModel.sourceTitle(
                    chosen: translator.source, detected: route.source, hasText: !translator.trimmed.isEmpty,
                    isOnlineOnly: translator.source.map(translator.isOnlineOnly) ?? false
                ),
                label: localized("Translate From"), apply: choose
            )
            .modifier(placed(bar.from))
            swapButton
                .modifier(placed(bar.swap))
            TranslatePopUp(
                translator: translator, side: .target,
                title: TranslateMenuModel.title(of: route.target, isOnlineOnly: translator.isOnlineOnly(route.target)),
                label: localized("Translate To"), apply: choose
            )
            .modifier(placed(bar.to))
        }
    }

    private var swapButton: some View {
        Button {
            choose { translator.swap() }
        } label: {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .frame(width: TranslateLayout.swapWidth, height: TranslateLayout.pairHeight)
                .contentShape(RoundedRectangle(cornerRadius: StageToolFrames.cornerRadius, style: .continuous))
        }
        .buttonStyle(PanelButtonStyle())
        .help(localized("Swap Languages"))
        .accessibilityLabel(localized("Swap Languages"))
    }

    /// A language change is a content change like a pane change: the labels
    /// and the text settle on the same short ease rather than cutting.
    private func choose(_ change: () -> Void) {
        withAnimation(Theme.contentAnimation) { change() }
    }

    // MARK: - Source card (§11)

    private func sourceCard(_ size: CGSize, fontSize: CGFloat) -> some View {
        let card = TranslateLayout.sourceCard(bodyWidth: size.width)
        let local = { (rect: CGRect) in rect.offsetBy(dx: -card.minX, dy: -card.minY) }
        let text = local(TranslateLayout.sourceText(card: card))
        let isEmpty = translator.input.isEmpty
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: TranslateLayout.cardRadius, style: .continuous)
                .fill(Theme.translateCardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: TranslateLayout.cardRadius, style: .continuous)
                        .strokeBorder(Theme.translateCardEdge, lineWidth: 0.5)
                )
            editor(fontSize: fontSize)
                .modifier(Placement(frame: text))
            if Self.drawsStandIn(isTravelling: isTravelling, covered: covered, input: translator.input) {
                standIn(fontSize: fontSize)
                    .modifier(Placement(frame: CGRect(x: text.minX, y: text.minY + 1, width: text.width, height: text.height)))
            }
            if covered {
                dust(seed: 0x5DEECE66D)
                    .modifier(Placement(frame: text))
            }
            if isEmpty {
                emptyHints(card: card, text: text, fontSize: fontSize, local: local)
            } else {
                if !covered { footnote(card: card, local: local) }
                clearButton
                    .modifier(Placement(frame: local(TranslateLayout.clear(card: card))))
            }
        }
        .frame(width: card.width, height: card.height, alignment: .topLeading)
        .offset(x: card.minX, y: card.minY)
    }

    private func editor(fontSize: CGFloat) -> some View {
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
            .opacity(covered || isTravelling ? 0 : 1)
            .textEditorStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
            // The source's type: 15 medium, its lines 1.35 apart (§19.8).
            .font(.system(size: fontSize, weight: .medium))
            .lineSpacing(Self.lineSpacing(size: fontSize))
            .foregroundStyle(.white)
            // Grey rather than the system accent: the caret has to say
            // where typing lands without being the brightest thing in a
            // panel that is mostly dark and mostly still.
            .tint(Theme.secondary)
            .focused($focused)
            // The editor insets its text by a few points of its own; pull
            // that back so the first character lines up with the card's inset.
            .padding(.leading, -5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // Where the field is, for the panel's cursor: it is never key,
            // so AppKit's own I-beam never applies and the root view's
            // tracking areas have to know the rectangle (PTR-02). A
            // background layer for the same reason as in the other panes:
            // reading it must not feed back into layout.
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: TextInputRectKey.self,
                        value: Self.reportedInputRect(proxy.frame(in: .global), isTravelling: isTravelling)
                    )
                }
            )
            // Named, or VoiceOver announced an unnamed text area: the
            // only field in the panel, and nothing said what it was for
            // (F-030).
            .accessibilityLabel(localized("Text to translate"))
            .contentShape(Rectangle())
            // No Escape handler here: `NotchPanel.sendEvent` takes every
            // Escape before it reaches the responder chain, and the reset
            // lives in `NotchViewModel.consumeEscape`. A handler here was
            // dead code that looked like the behaviour.
    }

    /// Whether the source text is drawn by `standIn` rather than the editor:
    /// while the pages travel, when there is text and it is not covered.
    nonisolated static func drawsStandIn(isTravelling: Bool, covered: Bool, input: String) -> Bool {
        isTravelling && !covered && !input.isEmpty
    }

    /// The editor's frame as the panel's cursor is told it: none while the
    /// pages travel (see `isTravelling`), so a swipe writes the view model
    /// twice — as it starts and as it ends — instead of on every frame.
    nonisolated static func reportedInputRect(_ frame: CGRect, isTravelling: Bool) -> CGRect {
        isTravelling ? .zero : frame
    }

    /// The source text as the editor draws it, for a travel's length: the
    /// same face, size, spacing and colour, from the editor's first line.
    private func standIn(fontSize: CGFloat) -> some View {
        Text(translator.input)
            .font(.system(size: fontSize, weight: .medium))
            .lineSpacing(Self.lineSpacing(size: fontSize))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// The empty card: the invitation where the first character will go, any
    /// notice about how text arrived under it, and Paste at the foot.
    @ViewBuilder
    private func emptyHints(card: CGRect, text: CGRect, fontSize: CGFloat, local: (CGRect) -> CGRect) -> some View {
        // An empty field was a dark rectangle that said nothing. The
        // invitation sits where the first character will, at the size that
        // character will take, and goes with it. Drawn, not read: the label on
        // the editor already says it, and clicks pass through to the editor
        // underneath to place the caret.
        if Self.showsPlaceholder(input: translator.input, covered: covered) {
            VStack(alignment: .leading, spacing: 4) {
                Text(localized("Type or paste text"))
                    .font(.system(size: fontSize, weight: .regular))
                    .foregroundStyle(Theme.tertiary)
                    .accessibilityHidden(true)
                // Under the invitation, where the eye already is: an empty
                // field after ⌃⌥⌘T is exactly the moment to say the clipboard
                // held no text.
                if let notice = translator.notice {
                    noticeLine(notice)
                }
            }
            .frame(width: text.width, alignment: .leading)
            .modifier(Placement(frame: CGRect(x: text.minX, y: text.minY + 1, width: text.width, height: text.height)))
            .allowsHitTesting(false)
        }
        if TranslatePaste.shows(input: translator.input) {
            // Its own width, from the left of the foot: a fixed 66 cut "Paste"
            // to "Pa…" beside its glyph, and "Вставить" was never going to
            // fit (owner's review, 2026-10-18).
            pasteButton
                .fixedSize()
                .modifier(Placement(frame: local(TranslateLayout.paste(card: card)), alignment: .leading))
        }
    }

    /// **Paste** (`doc.on.clipboard`), enabled only when the pasteboard offers
    /// text — and decided from its list of types alone, polled once a second
    /// while the card is empty and looked at. The contents are read when the
    /// button is pressed and not before: reading them is what raises macOS's
    /// "Paste from Other Apps" alert, and opening a tab must never be the
    /// moment that appears (`Translator.pasteboardOffersText`).
    private var pasteButton: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Button {
                paste()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 11, weight: .regular))
                    Text(localized("Paste"))
                }
            }
            .buttonStyle(ToolbarPushButtonStyle())
            // Off under Don't Allow as well, and the tooltip says why: macOS
            // would refuse the read, and a button that looked usable and then
            // reported an empty clipboard blamed the wrong thing.
            .disabled(!translator.canPaste)
            .help(translator.pasteboardOffersText && translator.pasteboardAccess == .denied
                ? Translator.pasteRefusedSentence : localized("Paste"))
        }
    }

    private func paste() {
        let prepared = translator.textFromPasteboard()
        // A press is the person at the keyboard: through `typed`, so a covered
        // pane is uncovered by it the way a keystroke uncovers it.
        if let text = prepared.text { Self.typed(text, privacy: privacy, translator: translator) }
        // After the text: setting `input` clears the notice.
        translator.notice = prepared.notice
        if let notice = prepared.notice { Announcer.shared.announce(notice) }
        wantsKeyboard = true
    }

    /// What sits at the card's foot once there is text: the notice about how it
    /// arrived if there is one (a cut clipboard, a press with nothing on it), else
    /// the counter, "35 / 20,000", in the quietest of the greys — never text a
    /// person must read (spec §2.1).
    @ViewBuilder
    private func footnote(card: CGRect, local: (CGRect) -> CGRect) -> some View {
        if let notice = translator.notice {
            noticeLine(notice)
                .modifier(Placement(frame: local(CGRect(
                    x: card.minX + TranslateLayout.sourceInset.horizontal, y: card.maxY - 34,
                    width: card.width - 2 * TranslateLayout.sourceInset.horizontal, height: 26
                )), alignment: .bottomLeading))
        } else {
            Text(Self.counterText(count: translator.input.count))
                .islandFont(.caption, weight: .regular)
                .monospacedDigit()
                .foregroundStyle(Theme.quaternary)
                .lineLimit(1)
                .modifier(Placement(frame: local(TranslateLayout.counter(card: card))))
                .accessibilityHidden(true)
        }
    }

    private var clearButton: some View {
        Button { translator.reset() } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Theme.tertiary)
                .frame(width: TranslateLayout.clearSide, height: TranslateLayout.clearSide)
                .contentShape(Rectangle())
        }
        .buttonStyle(PanelButtonStyle())
        .help(localized("Clear"))
        .accessibilityLabel(localized("Clear"))
    }

    // MARK: - Result (§11)

    private func resultCard(_ size: CGSize, route: Translator.Route, fontSize: CGFloat) -> some View {
        let card = TranslateLayout.resultCard(bodyWidth: size.width)
        let local = { (rect: CGRect) in rect.offsetBy(dx: -card.minX, dy: -card.minY) }
        let text = local(TranslateLayout.resultText(card: card))
        let showing = Self.showing(
            failure: translator.failure != nil,
            output: !translator.output.isEmpty,
            covered: privacy.hides(.translate, Self.revealID),
            translating: translator.isTranslating
        )
        return ZStack(alignment: .topLeading) {
            switch showing {
            case .failure:
                alert(card: card, local: local)
            case .translating:
                // The on-device model is not instant the way a lookup table would
                // be — a paragraph takes a beat, and the very first request after
                // a boot can take considerably longer while the model loads. An
                // empty card through all of that is indistinguishable from a
                // translation that came back blank.
                translatingLine
                    .modifier(Placement(frame: CGRect(x: text.minX + 2, y: text.minY + 3, width: text.width, height: 22)))
            case .covered:
                // The answer is the secret too, only in another language: covering
                // the source and leaving this card readable at headline size
                // hid nothing (F-002), and the accessibility tree handed the
                // translation to anything that asked. Replaced rather than
                // overlaid, as `SpoilerField` promises: the text is not in the
                // view tree at all while it is hidden. Copy stays offered in the
                // footer, so the result can be pasted somewhere without ever being
                // shown on a screen somebody else is watching; Speak does not, since
                // reading it aloud is showing it.
                dust(seed: 0xA24BAED4963EE407)
                    .modifier(Placement(frame: text))
                footer(card: card, route: route, local: local, showsSpeak: false)
            case .answer:
                answer(text: text, fontSize: fontSize)
                footer(card: card, route: route, local: local, showsSpeak: speakButton)
            case .nothing:
                if translator.input.isEmpty {
                    Text(localized("Translation"))
                        .font(.system(size: fontSize, weight: .regular))
                        .foregroundStyle(Theme.quaternary)
                        .accessibilityHidden(true)
                        .modifier(Placement(frame: CGRect(x: text.minX, y: text.minY + 1, width: text.width, height: text.height)))
                }
            }
        }
        .frame(width: card.width, height: card.height, alignment: .topLeading)
        .offset(x: card.minX, y: card.minY)
    }

    /// The answer: plain text, 15 semibold, wrapping at the card's text width
    /// and scrolling when a long one does not fit. While it is being read aloud
    /// the words said so far are lit and the rest wait dim — the lyric sweep, by
    /// the engine's own word ranges (`KaraokeText` sweeps a fraction of the
    /// line's width, which a spoken range is not, so this is a lit range).
    private func answer(text: CGRect, fontSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(showsIndicators: false) {
                answerText
                    .font(.system(size: fontSize, weight: .semibold))
                    // Dimmed while it answers the text before an edit: from
                    // the keystroke until the new answer lands it translates
                    // something no longer in the field, and it used to sit
                    // there at full white as if it were current (K-004).
                    // Kept rather than cleared, so a pause in typing does not
                    // blank the card.
                    .foregroundStyle(translator.answersInput ? Color.white : Theme.secondary)
                    .animation(Theme.contentAnimation, value: translator.answersInput)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // An answer that does not cover the whole text says so under it,
            // outside the scroll so it cannot scroll away: only the first
            // part went online, or the rest never came back and why (F-042).
            // That part used to be thrown away with the failure. Try Again sits
            // beside it only when a second try could bring the rest. A
            // partial answer keeps the card through a retry rather than
            // giving way to the spinner, so the spinner takes its place
            // instead — a press that changed nothing on screen was K-004's
            // complaint.
            if let note = translator.outputNote {
                VStack(alignment: .leading, spacing: 6) {
                    noticeLine(note)
                    if translator.isTranslating {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        let actions = TranslateAlert.noteActions(
                            remedies: translator.remedies, allowanceSpent: translator.allowanceSpent(), covered: covered
                        )
                        if !actions.isEmpty { actionRow(actions) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .modifier(Placement(frame: text))
    }

    private var answerText: Text {
        let output = translator.output
        guard speaker.isSpeaking, speaker.text == output else { return Text(output) }
        let split = TranslationSpeaker.split(output, upTo: speaker.spokenEnd)
        return Text(split.spoken).foregroundStyle(Color.white) + Text(split.rest).foregroundStyle(Theme.tertiary)
    }

    private var translatingLine: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(localized("Translating…"))
                .islandFont(.reading, weight: .regular)
                .foregroundStyle(Theme.secondary)
        }
    }

    // MARK: - Footer (§11)

    /// Speak, Copy Translation, then where the answer came from: a lock for the
    /// Mac, a globe for MyMemory. Speak and Copy lead and the origin follows —
    /// with the origin first, "Translated online by MyMemory" ran into the
    /// speaker (the board's own note).
    private func footer(
        card: CGRect, route: Translator.Route, local: (CGRect) -> CGRect, showsSpeak: Bool
    ) -> some View {
        let frame = local(TranslateLayout.footer(card: card))
        return HStack(spacing: TranslateLayout.footerSpacing) {
            if showsSpeak { speakControl(route: route) }
            // Disabled, not hidden, while the answer is to the text before
            // an edit: Copy pressed in that window used to paste a
            // translation of the old sentence (K-004), and a button that
            // vanished at every pause in typing would make the footer
            // jump instead.
            // Named, because "Copy" beside a field that also copies does
            // not say which text lands; and keyed, because after ⌃⌥⌘T
            // the caret is in the source and ⌘C copies that (H-018).
            CopyButton(
                title: localized("Copy Translation"),
                shortcut: "⇧⌘C",
                copiesElsewhere: translator.outputCopies,
                side: TranslateLayout.footerButton.height
            ) { translator.copyOutput() }
                .disabled(!translator.answersInput)
                .opacity(translator.answersInput ? 1 : 0.4)
            origin
                .padding(.leading, 6)
        }
        .frame(width: frame.width, height: frame.height, alignment: .leading)
        .offset(x: frame.minX, y: frame.minY)
    }

    /// Where it came from, in the tertiary grey at the caption role. The whole
    /// sentence where it fits, the glyph alone — with the sentence as its tooltip
    /// and label — where the card is too narrow for it (480 pt, or Russian).
    private var origin: some View {
        let online = translator.engine == .online
        let words = online ? localized("Translated online by MyMemory") : localized("On this Mac")
        let symbol = online ? SettingsIcon.online : "lock.fill"
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .regular))
                Text(words)
                    .islandFont(.caption, weight: .regular)
                    .lineLimit(1)
                    .fixedSize()
            }
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .regular))
        }
        .foregroundStyle(Theme.tertiary)
        .help(words)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(words)
    }

    /// **Speak** (`speaker.wave.2.fill`, 24 pt): reads the answer in the target
    /// language's system voice. While it speaks the plate is the accent and the
    /// button is "Stop Speaking". Disabled for an answer that is to text since
    /// edited (it would read a translation of something no longer there) and for a
    /// language this Mac has no voice for, which the system would read in the
    /// wrong one.
    private func speakControl(route: Translator.Route) -> some View {
        let speaking = speaker.isSpeaking && speaker.text == translator.output
        let label = speaking ? localized("Stop Speaking") : localized("Speak")
        let canSpeak = translator.answersInput && speaker.canSpeak(languageCode: route.target.code)
        return Button {
            speaker.toggle(translator.output, languageCode: route.target.code)
        } label: {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(speaking ? Color.white : Theme.secondary)
                .frame(width: TranslateLayout.footerButton.width, height: TranslateLayout.footerButton.height)
                .background(
                    RoundedRectangle(cornerRadius: StageToolFrames.cornerRadius, style: .continuous)
                        .fill(speaking ? Theme.accent : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: StageToolFrames.cornerRadius, style: .continuous))
        }
        .buttonStyle(PanelButtonStyle())
        .disabled(!canSpeak && !speaking)
        .opacity(canSpeak || speaking ? 1 : 0.4)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(speaking ? .isSelected : [])
    }

    // MARK: - The alert (§11)

    /// The one alert, in the result card: a glyph (or the spinner), the sentence
    /// `Translator` worded, and its buttons. `TranslateAlert.make` maps each thing
    /// `Translator` reports to a glyph and buttons, one to one.
    private func alert(card: CGRect, local: (CGRect) -> CGRect) -> some View {
        let alert = TranslateAlert.make(
            kind: translator.failureKind, message: translator.failure ?? "", remedies: translator.remedies,
            allowanceSpent: translator.allowanceSpent(), covered: covered
        )
        return VStack(alignment: .leading, spacing: 8) {
            switch alert.glyph {
            case .spinner:
                ProgressView()
                    .controlSize(.small)
                    .frame(height: 18)
            case .symbol(let name, let isWarning):
                Image(systemName: name)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(isWarning ? Theme.warning : Theme.secondary)
                    .frame(height: 18)
                    .accessibilityHidden(true)
            }
            Text(alert.message)
                .islandFont(.reading, weight: .regular)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            if !alert.actions.isEmpty { actionRow(alert.actions) }
        }
        .frame(width: card.width - 2 * TranslateLayout.resultInset.horizontal, alignment: .leading)
        .modifier(Placement(frame: CGRect(
            x: TranslateLayout.resultInset.horizontal, y: 10,
            width: card.width - 2 * TranslateLayout.resultInset.horizontal, height: card.height - 10
        )))
    }

    /// The buttons: push buttons on the toolbar plate, side by side where they
    /// fit and one under the other where Russian's longer words do not.
    private func actionRow(_ actions: [TranslateAlert.Action]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { ForEach(actions, id: \.self) { actionButton($0) } }
            VStack(alignment: .leading, spacing: 6) { ForEach(actions, id: \.self) { actionButton($0) } }
        }
    }

    @ViewBuilder
    private func actionButton(_ action: TranslateAlert.Action) -> some View {
        let button = Button(action.title) { perform(action) }
            .buttonStyle(ToolbarPushButtonStyle())
        if action == .useOnline {
            // The one button that sends text off the Mac without a switch: it
            // says where before it is pressed, in the tooltip and to VoiceOver.
            button
                .help(localized("Sends this text to MyMemory over the internet."))
                .accessibilityHint(localized("Sends this text to MyMemory over the internet."))
        } else {
            button
        }
    }

    private func perform(_ action: TranslateAlert.Action) {
        switch action {
        case .appleIntelligenceSettings: Translator.openAppleIntelligenceSettings()
        case .translationLanguages: Translator.openTranslationLanguages()
        case .turnOnOnline: translator.turnOnOnline()
        case .useOnline: translator.useOnline()
        case .tryAgain: translator.retry()
        }
    }

    // MARK: - History (§11)

    /// The last twenty translations, newest first, in place of both cards. A
    /// click puts the pair and both texts back (`Translator.restore`) and returns
    /// to the cards. Covered like the rest of the pane: one reveal uncovers it.
    private func historyList(_ size: CGSize) -> some View {
        let viewport = TranslateLayout.historyViewport(bodyWidth: size.width)
        let label = CGRect(
            x: TranslateLayout.margin + TranslateLayout.historyRowInset,
            y: TranslateLayout.historyLabelTop,
            width: 200, height: 16
        )
        let hidden = privacy.hides(.translate, Self.revealID) && !history.entries.isEmpty
        return ZStack(alignment: .topLeading) {
            Text(localized("Recent"))
                .islandFont(.body, weight: .semibold)
                .foregroundStyle(Theme.secondary)
                .frame(width: label.width, height: label.height, alignment: .leading)
                .offset(x: label.minX, y: label.minY)
            Group {
                if hidden {
                    dust(seed: 0xA24BAED4963EE407)
                        .padding(.horizontal, TranslateLayout.historyRowInset)
                } else if history.entries.isEmpty {
                    Text(localized("No translations yet"))
                        .islandFont(.body, weight: .regular)
                        .foregroundStyle(Theme.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    // Re-read twice a minute so "Now" does not linger on a list
                    // left open: one timeline for every age.
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        ScrollView(showsIndicators: false) {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(history.entries.enumerated()), id: \.element.id) { index, entry in
                                    TranslateHistoryRow(entry: entry, now: context.date, showsRule: index > 0) {
                                        restore(entry)
                                    }
                                }
                            }
                        }
                        .scrollEdgeFade(.vertical, length: ClipboardLayout.overflowFade)
                    }
                }
            }
            .frame(width: viewport.width, height: viewport.height)
            .offset(x: viewport.minX, y: viewport.minY)
        }
    }

    private func restore(_ entry: TranslationHistory.Entry) {
        // The cover is left as it stands: clicking a row is as deliberate as a
        // keystroke, and a list that had to be uncovered to be clicked must not
        // drop to dust the moment the entry it chose lands.
        choose {
            translator.restore(entry)
            showsHistory = false
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

    /// What stands in for either card while the pane is covered. Clicking
    /// the dust uncovers it, the same gesture the clipboard rows use, and one
    /// reveal uncovers both cards. Each gets its own seed, or the two would draw
    /// the same dust side by side and read as one texture copied.
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

/// Lays a view in a frame: its size, its place from the container's top-left.
private struct Placement: ViewModifier {
    let frame: CGRect
    var alignment: Alignment = .topLeading

    func body(content: Content) -> some View {
        content
            .frame(width: frame.width, height: frame.height, alignment: alignment)
            .offset(x: frame.minX, y: frame.minY)
    }
}

/// One row of the History list (spec §11): 40 tall, the source (12.5 medium) over
/// the answer (11.5, secondary), and on the right the pair — "EN → RU", 10.5
/// semibold tertiary, tracked 0.4 — over the age. One button: a click restores.
struct TranslateHistoryRow: View {
    let entry: TranslationHistory.Entry
    let now: Date
    let showsRule: Bool
    let restore: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: restore) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.source)
                        .islandFont(.reading, weight: .medium)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(entry.result)
                        .islandFont(.body, weight: .regular)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(entry.pairLabel)
                        .islandFont(.caption, weight: .semibold)
                        .tracking(0.4)
                        .foregroundStyle(Theme.tertiary)
                    Text(ClipboardAge.text(of: entry.date, now: now))
                        .islandFont(.caption, weight: .regular)
                        .foregroundStyle(Theme.tertiary)
                }
                .lineLimit(1)
            }
            .padding(.horizontal, TranslateLayout.historyRowInset)
            .padding(.top, 4)
            .frame(height: TranslateLayout.historyRowHeight, alignment: .top)
            .background(
                RoundedRectangle(cornerRadius: ClipboardLayout.rowRadius, style: .continuous)
                    .fill(hovering ? Theme.clipboardWell : Color.clear)
            )
            .overlay(alignment: .top) {
                if showsRule {
                    Rectangle().fill(Theme.hairline).frame(height: 0.5)
                        .padding(.horizontal, TranslateLayout.historyRowInset)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelButtonStyle())
        .onHover { hovering = $0 }
        // One element named for what it holds, and still a button: collapsing
        // the children drops the trait the `Button` would have given it.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.source), \(entry.result)")
        .accessibilityValue("\(entry.pairLabel), \(ClipboardAge.text(of: entry.date, now: now))")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { restore() }
    }
}

/// The source editor's frame in the window, top-left origin. Carried up to the
/// view model so the root view can show an I-beam over it (PTR-02).
struct TextInputRectKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isEmpty { value = next }
    }
}

/// Equal when everything it draws from is: the same objects, the same values,
/// and the bindings holding the same value. The closures are left out on
/// purpose — they are rebuilt on every pass of the root view and so are never
/// equal, which made SwiftUI re-run this whole pane on every frame of a page
/// swipe, once per frame for each of the two pages on screen (measured
/// 2026-10-18: 30 bodies each over a 30-frame swipe). Each one only calls into
/// the view model, or reads Reduce Motion through `SystemAppearance` when it
/// is called, so a kept copy does exactly what a fresh one would. Its own
/// state and observed objects still redraw it as ever; this only stops a
/// parent's pass from doing it for nothing (`NotchContentView.pane(for:)`).
extension TranslatePane: @MainActor Equatable {
    static func == (lhs: TranslatePane, rhs: TranslatePane) -> Bool {
        lhs.translator === rhs.translator
            && lhs.privacy === rhs.privacy
            && lhs.bodyWidth == rhs.bodyWidth
            && lhs.isLive == rhs.isLive
            && lhs.isTravelling == rhs.isTravelling
            && lhs.keyboardClaim == rhs.keyboardClaim
            && lhs.historyClaim == rhs.historyClaim
    }
}
