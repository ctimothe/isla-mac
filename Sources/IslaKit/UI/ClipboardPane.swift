import SwiftUI

struct ClipboardPane: View {
    @ObservedObject var clipboard: ClipboardStore
    @ObservedObject var privacy: PrivacyMode
    /// Read through `@AppStorage` rather than once from
    /// `NotchViewModel.clipboardHistoryEnabled`, so Turn On below redraws the
    /// pane the moment it writes the switch. The store is a parameter only so
    /// a test can hand it a private suite instead of the owner's defaults.
    @AppStorage private var historyEnabled: Bool
    /// The Settings switch, flipped on from here. Local only: history never
    /// leaves the Mac, so turning it on beside the sentence that says it is
    /// off asks nothing of anyone.
    private let turnOnHistory: () -> Void

    init(
        clipboard: ClipboardStore,
        privacy: PrivacyMode,
        historyDefaults: UserDefaults = .standard,
        turnOnHistory: @escaping () -> Void = {}
    ) {
        self.clipboard = clipboard
        self.privacy = privacy
        _historyEnabled = AppStorage(wrappedValue: true, NotchViewModel.clipboardHistoryKey, store: historyDefaults)
        self.turnOnHistory = turnOnHistory
    }

    /// Privacy & Security > Paste from Other Apps, then the Privacy &
    /// Security root. The anchor is not one Apple documents, so the root is
    /// the fallback when it does not open: one more click from there beats a
    /// button that does nothing.
    static let privacySettingsURLs: [URL] = [
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard",
        "x-apple.systempreferences:com.apple.preference.security",
    ].compactMap(URL.init(string:))

    /// Opens the first of `privacySettingsURLs` that System Settings accepts.
    static func openPrivacySettings() {
        for url in privacySettingsURLs where NSWorkspace.shared.open(url) { return }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Only while something wants the pasteboard: with history and
            // clipboard screenshots both off nothing is lost to the refusal,
            // and a failure nobody is affected by is not worth the space.
            if clipboard.access == .denied, NotchStores.clipboardShouldPoll(
                history: historyEnabled,
                images: NotchViewModel.saveClipboardImagesEnabled
            ) {
                deniedNotice
            }
            if clipboard.items.isEmpty {
                emptyState
            } else {
                ScrollView(showsIndicators: false) {
                    // One clock for every covered row in the list — see
                    // `SpoilerClock` — and only while one is covered.
                    SpoilerClock(active: spoilerClockActive) {
                        LazyVStack(spacing: 3) {
                            ForEach(clipboard.items) { item in
                                ClipRow(item: item, clipboard: clipboard, privacy: privacy)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                // Six rows in a five-row window cut the fifth square against
                // Clear, which read as a cropped list rather than one that
                // scrolls (H-017). The cut edge fades instead, and only
                // while something is beyond it.
                .scrollEdgeFade()
                footer
            }
        }
        .padding(.top, 2)
        // Don't Allow stops the poll, and a stopped poll cannot notice the
        // switch going back to Allow. Looking at this tab is the moment a
        // user back from System Settings expects history to resume, so the
        // system is asked again here rather than on a timer.
        .onAppear { clipboard.recheckAccess() }
    }

    /// Whether the list's spoiler clock has anything to animate. The tab
    /// used to run it unconditionally, and covers are off by default, so an
    /// unchanging list redrew twenty times a second (F-016). Needs the
    /// section covered and a row still hidden: revealing the last row stops
    /// the clock, covering the section again starts it.
    static func spoilerClockActive(covers: Bool, hiddenCount: Int) -> Bool {
        covers && hiddenCount > 0
    }

    private var spoilerClockActive: Bool {
        let covers = privacy.covers(.clipboard)
        // Only walked when the section covers: `hides` is false for every
        // row otherwise. The history holds at most 40 rows.
        let hidden = covers
            ? clipboard.items.filter { privacy.hides(.clipboard, $0.id.uuidString) }.count
            : 0
        return Self.spoilerClockActive(covers: covers, hiddenCount: hidden)
    }

    /// The glyph alone used to be the whole empty tab, and VoiceOver read it
    /// by its symbol's name, "Paste" (F-036, M-08). The words say what lands
    /// here and what never does — concealed copies, which is what password
    /// managers mark theirs as, are skipped before they are read — and the
    /// glyph is drawing. Laid out like the empty Shelf, so the two tabs read
    /// as one panel.
    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: NotchViewModel.Tab.clipboard.symbol)
                .islandFont(.display, weight: .light)
                .foregroundStyle(Theme.tertiary)
                .accessibilityHidden(true)
            if historyEnabled {
                Text(localized("Nothing copied yet"))
                    .islandFont(.body)
                    .foregroundStyle(Theme.secondary)
                Text(localized("Text and files you copy appear here. Copies from password managers are skipped."))
                    .islandFont(.caption, weight: .regular)
                    .foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // An empty list with history off is not "nothing copied yet",
                // and saying which one it is saves a hunt. The way back on
                // sits under the sentence: sending someone to Settings for a
                // switch they could be handed here was a second hunt.
                Text(localized("Clipboard history is off in Settings."))
                    .islandFont(.body, weight: .regular)
                    .foregroundStyle(Theme.secondary)
                Button(localized("Turn On"), action: turnOnHistory)
                    .buttonStyle(OfferButtonStyle())
                    .padding(.top, 4)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Paste from Other Apps set to Don't Allow (J-001). Before this the
    /// history only went quiet: nothing new arrived, clipboard screenshots
    /// stopped reaching the Shelf, and nothing anywhere said why. Inline
    /// above the list, because the failure belongs to this section and to
    /// nothing else; Settings carries no second banner for the same event.
    /// What was kept before the refusal stays below it, still usable.
    private var deniedNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(localized("macOS is not letting Isla read what you copy, so nothing new is kept."))
                .islandFont(.body, weight: .regular)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(localized("Open Privacy Settings")) { Self.openPrivacySettings() }
                .buttonStyle(OfferButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
        .padding(.bottom, 8)
    }

    private var footer: some View {
        HStack {
            Spacer()
            ConfirmTextButton(
                title: localized("Clear"),
                armedTitle: localized("Clear Everything")
            ) { clipboard.clear() }
        }
        .padding(.top, 2)
    }
}

struct ClipRow: View {
    let item: ClipItem
    @ObservedObject var clipboard: ClipboardStore
    @ObservedObject var privacy: PrivacyMode
    @State private var hovering = false
    @State private var justCopied = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var hidden: Bool { privacy.hides(.clipboard, item.id.uuidString) }

    /// The row's kind glyph. A covered row wears one neutral glyph whatever it
    /// holds: the link glyph on row 5 told a screen-share audience which of the
    /// covered rows is a URL, and a file's told them it was a file (H-026). The
    /// copied tick still wins over it, in the body.
    static func glyph(for item: ClipItem, hidden: Bool) -> String {
        hidden ? "text.alignleft" : item.symbol
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: justCopied ? "checkmark" : Self.glyph(for: item, hidden: hidden))
                .islandFont(.caption)
                .foregroundStyle(justCopied ? Theme.success : Theme.tertiary)
                .symbolSwap(value: justCopied, reduceMotion: reduceMotion)
                .frame(width: 14)
            SpoilerText(
                text: item.preview,
                hidden: hidden,
                seed: UInt64(bitPattern: Int64(item.id.uuidString.hashValue))
            )
            Spacer(minLength: 6)
            if justCopied {
                // The tick alone was the confirmation: a 12 pt glyph turning
                // green, which sunlight, a colour-blind eye or a shared screen
                // all lose (H-016). The word holds the trailing slot for the
                // flash, in place of the hover controls, so a copy is a shape
                // and a word, never a tint alone.
                Text(localized("Copied"))
                    .islandFont(.caption)
                    .foregroundStyle(Theme.secondary)
                    .transition(.opacity)
            } else {
                // At rest on a covered pane, not only under the pointer: a
                // covered row that shows nothing says nothing about how to
                // read it, and the eye was the one control a hover-less
                // touch or trackpad user never found (M-04).
                if privacy.covers(.clipboard) {
                    RevealEye(hidden: hidden) { privacy.toggle(item.id.uuidString) }
                }
                if hovering {
                    Button { clipboard.remove(item) } label: {
                        Image(systemName: "xmark")
                            .islandFont(.caption, weight: .semibold)
                            .foregroundStyle(Theme.secondary)
                            // A 10pt glyph is a ~10pt target sitting beside the
                            // reveal eye, inside a row whose own background
                            // copies to the pasteboard — missing it by two
                            // points overwrote what the user had copied.
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PanelButtonStyle())
                    .accessibilityLabel(localized("Remove Entry"))
                }
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hovering ? Theme.surfaceHover : Theme.surface)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: copy)
        // Everything the hover controls do, without the hover. Remove and
        // the eye used to appear only under a pointer, so a keyboard or
        // VoiceOver user could not do either (F-005). The menu is AppKit's,
        // and `MenuTracking` holds the panel open while it is up.
        .contextMenu {
            Button(localized("Copy"), action: copy)
            if privacy.covers(.clipboard) {
                Button(hidden ? localized("Show") : localized("Hide"), action: toggleCover)
            }
            Divider()
            Button(localized("Remove Entry"), role: .destructive) { clipboard.remove(item) }
        }
        // One element per row, named by what it would copy. It used to be
        // `.combine` under a fixed label, so every row in the list was the
        // same "Copy Entry" button and twenty of them could not be told
        // apart (F-005). `.ignore` swallows the glyph, the text and the hover
        // controls; what the controls do is offered as actions below. A
        // covered row says only "Hidden" — the cover's own label, which
        // `.ignore` would otherwise drop — because a screen reader must not
        // be the hole in a feature about not showing things.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        // VO-Space copies, as a click does.
        .accessibilityAction { copy() }
        // The menu's verbs, in the Actions rotor. Written bottom-up: SwiftUI
        // vends named actions outermost first, so the rotor reads Show or
        // Hide, then the destructive Remove last, as the menu does.
        .accessibilityAction(named: Text(localized("Remove Entry"))) { clipboard.remove(item) }
        .accessibilityActions {
            if privacy.covers(.clipboard) {
                Button(hidden ? localized("Show") : localized("Hide"), action: toggleCover)
            }
        }
        .animation(Theme.contentAnimation, value: hovering)
        .animation(Theme.contentAnimation, value: justCopied)
    }

    /// The preview, or "Hidden" under the cover, or "Copied" for the flash.
    /// A row whose preview is empty keeps the old generic name rather than
    /// none at all: a nameless button is read as just "button".
    private var accessibilityLabel: String {
        if hidden { return localized("Hidden") }
        if justCopied { return localized("Copied") }
        return item.preview.isEmpty ? localized("Copy Entry") : item.preview
    }

    /// One copy for the click, VO-Space and the menu. The announcement is how
    /// the moment reaches speech (M-02): the label turning to "Copied" is
    /// heard only if VoiceOver happens to read the row again inside the
    /// flash, and it does not move on its own. `Announcer` drops the second
    /// of two identical sentences inside a second, so a click and the AX
    /// action arriving together are said once.
    private func copy() {
        clipboard.copy(item)
        flash($justCopied)
        Announcer.shared.announce(localized("Copied"))
    }

    private func toggleCover() {
        privacy.toggle(item.id.uuidString)
    }
}
