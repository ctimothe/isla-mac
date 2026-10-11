import SwiftUI

/// Shown once, inside the panel body, on the first launch of a fresh account.
///
/// Not a window and not a tab. The 2026-08-25 amendment withdrew the status
/// item, its menu and a short-lived main window on the grounds that the panel's
/// own Settings tab was already the front door; a welcome in a window would
/// reopen exactly that question, and a sixth tab would be a place to navigate to
/// for something that exists for one launch. So this is the body, for one
/// launch, and then never again.
///
/// Two columns. On the left, one line beside each rail icon saying what that
/// tab is — the rail is right there, so the mapping is shown rather than
/// described. On the right, what somebody who just launched an invisible app
/// needs: that it is running, how to get back to it once this closes, and that
/// nothing leaves the Mac until they say so. The way back is not a courtesy —
/// an `LSUIElement` app does not appear in Force Quit, so a user who cannot find
/// the panel again cannot find Quit either.
///
/// It used to be one column that said "It lives at the notch. Click it to
/// open." — on a panel that had opened itself, so the instruction read as
/// already done — and named none of the tabs, and left ⌃⌥⌘T out (H-020).
struct WelcomePane: View {
    /// What Get Started does. A closure rather than the whole `NotchViewModel`,
    /// because the one thing this pane asks of the app is "the welcome has been
    /// read" — and taking the model for it made the pane unrenderable without a
    /// screen, since a `NotchViewModel` needs a `NotchGeometry` and there is no
    /// geometry without a display. That made the fit check below — the only
    /// guard against shipping a pane with its button cut off — skip itself on
    /// every headless CI machine, which is exactly where a layout regression
    /// would otherwise be caught before a human ever saw it.
    var onDismiss: () -> Void

    /// The strings, resolved through the app's own tables by default.
    ///
    /// Handed in rather than written into the `Text`s so a test can render this
    /// pane with the *Russian* table and measure whether it still fits the body:
    /// under `swift test` there is no bundle carrying the `.lproj` folders, so
    /// `Text`'s own lookup silently falls back to the key and a fit check on it
    /// would only ever measure English. Russian here runs about a third longer,
    /// which is where a layout laid out in English overflows.
    var copy: Copy = .fromTables

    /// The rail's own icon height, which differs between Macs
    /// (`NotchGeometry.railIconHeight`). Each legend row is cut to it so that
    /// the line sits level with the icon it names; at any other height the
    /// fourth row would be a whole icon out by the bottom of the run.
    var railIconHeight: CGFloat

    /// The keys as they are bound right now, not as they shipped. A welcome
    /// that printed the defaults would be wrong for anyone who had moved one
    /// before resetting the first run, and it was wrong for everybody once
    /// the defaults themselves changed. Empty for a shortcut cleared in
    /// Settings, and the line that would have named it says it without one.
    var openKeys = HotKeyCenter.shared.bindings[.openPanel]?.displayString ?? ""
    var lyricsKeys = HotKeyCenter.shared.bindings[.showLyrics]?.displayString ?? ""
    var translateKeys = HotKeyCenter.shared.bindings[.translateClipboard]?.displayString ?? ""

    struct Copy {
        var running: String
        var comeBack: String
        var comeBackUnbound: String
        var staysOnMac: String
        var music: String
        var musicUnbound: String
        var shelf: String
        var clipboard: String
        var translate: String
        var translateUnbound: String
        var settings: String
        var action: String

        /// English — and therefore also the keys, since in this project the keys
        /// *are* the English text.
        ///
        /// "Nothing leaves your Mac unless you turn it on" is a claim, so it is
        /// worth saying what makes it true: online lyrics, online translation,
        /// the update check and the Spotify account all default to off, and the
        /// clipboard history is held in memory and never written out.
        static let english = Copy(
            running: "Isla is running.",
            comeBack: "No Dock or menu-bar icon. Click the notch or press %@ to come back.",
            comeBackUnbound: "No Dock or menu-bar icon. Click the notch to come back.",
            staysOnMac: "Nothing leaves your Mac unless you turn it on.",
            music: "What's playing, with lyrics (%@)",
            musicUnbound: "What's playing, with lyrics",
            shelf: "Files you drop on the notch",
            clipboard: "What you copied, kept in memory",
            translate: "%@ translates what you copied",
            translateUnbound: "Translates what you copied",
            settings: "Privacy, shortcuts and Quit",
            action: "Get Started"
        )

        /// The same, looked up in whichever table the app ended up running in.
        static var fromTables: Copy { english.mapped(localized) }

        /// Every string put through one lookup. One list of fields, so a test
        /// reading the Russian table off disk and the app reading it through
        /// the bundle cannot disagree about which strings there are.
        func mapped(_ look: (String) throws -> String) rethrows -> Copy {
            Copy(
                running: try look(running),
                comeBack: try look(comeBack),
                comeBackUnbound: try look(comeBackUnbound),
                staysOnMac: try look(staysOnMac),
                music: try look(music),
                musicUnbound: try look(musicUnbound),
                shelf: try look(shelf),
                clipboard: try look(clipboard),
                translate: try look(translate),
                translateUnbound: try look(translateUnbound),
                settings: try look(settings),
                action: try look(action)
            )
        }

        var all: [String] {
            [
                running, comeBack, comeBackUnbound, staysOnMac,
                music, musicUnbound, shelf, clipboard,
                translate, translateUnbound, settings, action,
            ]
        }
    }

    /// Every key this pane shows, so a test can prove both tables carry them.
    static let localizedKeys = Copy.english.all

    /// Between the legends and the message.
    static let columnGap: CGFloat = 16

    /// The least the message column may be left with once the legends have
    /// taken their width. Below this the title and the button are squeezed to a
    /// word a line and the pane outgrows the body; `FirstRunTests` measures the
    /// Russian legends against it at the narrowest panel.
    static let messageMinWidth: CGFloat = 150

    /// What the line beside `tab`'s icon says.
    func legend(for tab: NotchViewModel.Tab) -> String {
        switch tab {
        case .media:
            return lyricsKeys.isEmpty ? copy.musicUnbound : String(format: copy.music, lyricsKeys)
        case .shelf:
            return copy.shelf
        case .clipboard:
            return copy.clipboard
        case .translate:
            return translateKeys.isEmpty ? copy.translateUnbound : String(format: copy.translate, translateKeys)
        case .settings:
            return copy.settings
        }
    }

    /// The way back, with the open shortcut in it while there is one.
    var comeBackLine: String {
        openKeys.isEmpty ? copy.comeBackUnbound : String(format: copy.comeBack, openKeys)
    }

    var body: some View {
        // The vertical budget, measured rather than guessed, because the body is
        // a fixed 208 pt that never resizes and there is nothing to scroll: the
        // shallowest body any supported Mac can give this pane is 154 pt (208,
        // less a notch as deep as 40, less the 14 below the rail). The single
        // column this replaced used 150 of it with two feature lines; four more
        // would not fit under it, which is why the features went beside the
        // rail, where the height is already spent on the icons. The legend
        // column asks for 150 (five icons, their gaps and the rail's 10 pt
        // footer gap) and the message column for less. `FirstRunTests` holds
        // the number in both languages at the narrowest panel.
        HStack(alignment: .top, spacing: Self.columnGap) {
            legendColumn
                // The legends are one line each and take the width they need;
                // the message wraps in what is left. Truncated instead, a
                // Russian legend lost its tail and the icon it named lost its
                // meaning.
                .fixedSize(horizontal: true, vertical: false)
            message
                .frame(minWidth: Self.messageMinWidth, maxWidth: .infinity, alignment: .topLeading)
        }
        // Aligned with every other pane rather than inset on its own: the rail
        // is beside it and the body already pads its content by 14.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.trailing, 4)
    }

    /// One line per rail icon, in the rail's own rhythm: the same row height,
    /// the same gap, and Settings held to the bottom by the same footer gap, so
    /// each line sits level with the icon it names. The pane's top is the
    /// rail's top — both start where the header ends — which is why there is
    /// no top padding here.
    var legendColumn: some View {
        VStack(alignment: .leading, spacing: NotchGeometry.railSpacing) {
            ForEach(NotchViewModel.Tab.contentTabs) { legendRow($0) }
            Spacer(minLength: Rail.footerGap)
            ForEach(NotchViewModel.Tab.utilityTabs) { legendRow($0) }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func legendRow(_ tab: NotchViewModel.Tab) -> some View {
        Text(legend(for: tab))
            .islandFont(.body, weight: .regular)
            .foregroundStyle(Theme.secondary)
            .lineLimit(1)
            .frame(height: railIconHeight, alignment: .leading)
            // Heard on its own the line says what a tab does but not which tab;
            // the icon it sits beside is a separate element in another group.
            // So it carries the tab's name, the way a sighted reader gets it
            // from the icon.
            .accessibilityLabel(tab.title)
            .accessibilityValue(legend(for: tab))
    }

    private var message: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(copy.running)
                .islandFont(.title)
                .foregroundStyle(.white)

            Text(comeBackLine)
                .islandFont(.body, weight: .regular)
                .foregroundStyle(Theme.secondary)
                // A `Text` in a stack whose height is decided elsewhere
                // truncates to one line rather than taking two, so a line this
                // long in a column this narrow would arrive with its tail cut
                // off instead of wrapped.
                .fixedSize(horizontal: false, vertical: true)

            Text(copy.staysOnMac)
                .islandFont(.caption, weight: .regular)
                .foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            // The stack flows from the top and the slack collects underneath,
            // like every other pane. A `Spacer` holding this button to the floor
            // of the body is what pushed the old single column past the height
            // it had.
            Button(action: onDismiss) {
                Text(copy.action)
            }
            // The panel's own pill, one step brighter and a little roomier:
            // `OfferButtonStyle` is what the Music tab's "Open Spotify" button
            // wears, and this is the same shape carrying the one action on
            // screen.
            .buttonStyle(OfferButtonStyle(fill: Theme.surfaceHover, horizontalPadding: 14, verticalPadding: 6))
        }
    }
}
