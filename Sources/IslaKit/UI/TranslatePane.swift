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
    /// ⌥⌘T fills the source field with whatever was on the clipboard, so this
    /// pane can be displaying the same secret the clipboard tab covers.
    @ObservedObject var privacy: PrivacyMode
    /// Whether the panel holds the keyboard. Drops to false when the user
    /// clicks into another app, and the field follows it — the caret has to
    /// stop blinking here when it has genuinely gone elsewhere.
    @Binding var wantsKeyboard: Bool

    @FocusState private var focused: Bool

    /// Covered until deliberately revealed, like a clipboard row. The reveal is
    /// per-session and keyed to the pane, not to any particular text.
    private var covered: Bool {
        privacy.hides(.translate, "translate.source") && !translator.input.isEmpty
    }
    /// Measured once, off the layout path. See `body`.
    @State private var paneSize: CGSize = .zero

    /// Largest first. Four rungs, far enough apart that a change is always a
    /// deliberate-looking drop rather than a wobble. Raw points, not roles: a
    /// rung is a fit calculation against the measured pane, and rounding it to
    /// the nearest role would move where every paragraph wraps.
    private let ladder: [CGFloat] = [27, 20, 15, 11]

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
            TextEditor(text: $translator.input)
                .opacity(covered ? 0 : 1)
                .overlay {
                    if covered {
                        // Clicking the dust uncovers it, the same gesture the
                        // clipboard rows use — the cover is against a passing
                        // camera, not against the person at the keyboard.
                        SpoilerField(seed: 0x5DEECE66D)
                            .contentShape(Rectangle())
                            .onTapGesture { privacy.reveal("translate.source") }
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
                .contentShape(Rectangle())
                // No Escape handler here: `NotchPanel.sendEvent` takes every
                // Escape before it reaches the responder chain, and the reset
                // lives in `NotchViewModel.consumeEscape`. A handler here was
                // dead code that looked like the behaviour.
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
                CopyButton { translator.copyOutput() }
            }
        } content: {
            outcome(font)
        }
        .padding(10)
    }

    @ViewBuilder
    private func outcome(_ font: CGFloat) -> some View {
        if let failure = translator.failure {
            VStack(alignment: .leading, spacing: 6) {
                Text(failure)
                    .islandFont(.body, weight: .regular)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    ForEach(translator.remedies, id: \.self) { remedy in
                        remedyButton(remedy)
                    }
                }
                .buttonStyle(PanelButtonStyle())
                .islandFont(.caption)
                .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if !translator.output.isEmpty {
            ScrollView(showsIndicators: false) {
                Text(translator.output)
                    // The ladder's rung for this text, not a role: see `ladder`.
                    .font(.system(size: font))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if translator.isTranslating {
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
        } else {
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
    /// minus the gap, minus the padding, minus the title row above it.
    private func textArea(in size: CGSize) -> CGSize {
        CGSize(
            width: max(40, (size.width - 10) / 2 - 20),
            height: max(40, size.height - 40)
        )
    }

    /// The largest rung the text still fits on. Both columns share it, computed
    /// from whichever side is longer — sides set at different scales stop
    /// looking like a pair.
    private func fontSize(in size: CGSize) -> CGFloat {
        let count = CGFloat(max(translator.trimmed.count, translator.output.count))
        // Before the first measurement lands there is nothing to fit type to,
        // and the pane is empty anyway.
        guard count > 0, size.width > 0, size.height > 0 else { return ladder[0] }
        // A glyph runs about half its point size wide and 1.3 of it tall with
        // leading, so roughly `area / (0.76 · s²)` characters fit at size `s`.
        // The 0.95 keeps the last line from being the one that overflows.
        let area = textArea(in: size)
        let usable = area.width * area.height * 0.95
        return ladder.first { count <= usable / (0.76 * $0 * $0) } ?? ladder[ladder.count - 1]
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
            Picker(selection: Binding(
                get: { translator.source?.code ?? "" },
                set: { code in choose { translator.choose(source: TranslationLanguage.withCode(code)) } }
            )) {
                ForEach(TranslationLanguage.all) { language in
                    Text(menuTitle(language)).tag(language.code)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
            .labelsHidden()
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
            Picker(selection: Binding(
                get: { translator.target.code },
                set: { code in
                    guard let language = TranslationLanguage.withCode(code) else { return }
                    choose { translator.choose(target: language) }
                }
            )) {
                ForEach(TranslationLanguage.all) { language in
                    Text(menuTitle(language)).tag(language.code)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            heading(route.target.name)
        }
        .languageMenuStyle()
        .accessibilityLabel(localized("Translate To"))
        .accessibilityValue(route.target.name)
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
                .frame(width: 18, height: 14)
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
        }
    }

    // MARK: - Shared

    /// A column heading: the language, set the way every header in the panel
    /// is set, with the small chevron that says it opens.
    private func heading(_ title: String) -> some View {
        HStack(spacing: 3) {
            Text(title.uppercased())
                .islandFont(.caption, weight: .semibold)
                .tracking(Theme.capsTracking)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                // A glyph fitted to the caption line, not type.
                .font(.system(size: 7, weight: .bold))
        }
        .foregroundStyle(Theme.tertiary)
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
            .frame(height: 14)

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
