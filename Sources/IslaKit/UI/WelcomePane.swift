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
/// Two columns. On the left, four lines that say how the island is used, each
/// led by a glyph (spec §19.8): a click opens what is playing, a right-click
/// everything else, files dragged to the notch are kept, and the shortcuts as
/// they are bound. On the right, what somebody who just launched an invisible
/// app needs: that it is running, how to get back to it once this closes, and
/// that nothing leaves the Mac until they say so. The way back is not a
/// courtesy — an `LSUIElement` app does not appear in Force Quit, so a user who
/// cannot find the panel again cannot find Quit either.
///
/// The left column once named each rail icon beside it (H-020); §19 took the
/// rail away, so it says what to do with the island instead, which is the one
/// thing there is to find.
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

    /// The keys as they are bound right now, not as they shipped. A welcome
    /// that printed the defaults would be wrong for anyone who had moved one
    /// before resetting the first run, and it was wrong for everybody once
    /// the defaults themselves changed. Empty for a shortcut cleared in
    /// Settings, and the line that would have named it says it without one.
    var openKeys = HotKeyCenter.shared.bindings[.openPanel]?.displayString ?? ""
    /// The fourth line's shortcuts, in its order, as `HotKeyCenter` holds
    /// them; a cleared one drops out of the line rather than leaving a gap.
    var shortcuts: [Shortcut] = WelcomePane.liveShortcuts()

    /// One shortcut on the fourth line: its keys, and the surface it opens.
    struct Shortcut: Equatable {
        var keys: String
        var name: String
    }

    struct Copy {
        var running: String
        var comeBack: String
        var comeBackUnbound: String
        var staysOnMac: String
        var click: String
        var rightClick: String
        var drag: String
        var clipboard: String
        var translate: String
        var lyrics: String
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
            click: "Click the island to open what’s playing.",
            rightClick: "Right-click it for everything else.",
            drag: "Drag files to the notch to keep them.",
            clipboard: "Clipboard",
            translate: "Translate",
            lyrics: "Lyrics",
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
                click: try look(click),
                rightClick: try look(rightClick),
                drag: try look(drag),
                clipboard: try look(clipboard),
                translate: try look(translate),
                lyrics: try look(lyrics),
                action: try look(action)
            )
        }

        var all: [String] {
            [
                running, comeBack, comeBackUnbound, staysOnMac,
                click, rightClick, drag, clipboard, translate, lyrics, action,
            ]
        }
    }

    /// Every key this pane shows, so a test can prove both tables carry them.
    static let localizedKeys = Copy.english.all

    /// The fourth line's shortcuts as bound now: Translate, then Lyrics.
    @MainActor static func liveShortcuts(
        bindings: [HotKeyAction: HotKeyBinding]? = nil, copy: Copy = .fromTables
    ) -> [Shortcut] {
        let bindings = bindings ?? HotKeyCenter.shared.bindings
        let order: [(HotKeyAction, String)] = [
            (.translateClipboard, copy.translate),
            (.showLyrics, copy.lyrics),
        ]
        return order.compactMap { action, name in
            guard let keys = bindings[action]?.displayString, !keys.isEmpty else { return nil }
            return Shortcut(keys: keys, name: name)
        }
    }

    /// The body's margins: the header title's 20 at the sides, 8 under the
    /// header row (the reference's 46), and 14 at the foot.
    static let margins = EdgeInsets(top: 8, leading: 20, bottom: 14, trailing: 20)
    /// Between the legend and the message.
    static let columnGap: CGFloat = 16
    /// The legend's share of the width the two columns divide; the message
    /// takes the rest. The legend's lines wrap inside it rather than pushing
    /// the message off the body, which Russian at 480 would.
    static let legendShare: CGFloat = 0.55
    /// Between the legend's lines, and a glyph's well beside its line.
    static let legendSpacing: CGFloat = 8
    static let glyphWidth: CGFloat = 18

    /// The two columns' widths at a body width.
    static func columns(bodyWidth: CGFloat) -> (legend: CGFloat, message: CGFloat) {
        let room = bodyWidth - margins.leading - margins.trailing - columnGap
        let legend = (room * legendShare).rounded(.down)
        return (legend, room - legend)
    }

    /// One line of the legend: its glyph and its words.
    struct LegendLine: Equatable {
        var symbol: String
        var text: String
    }

    /// The four lines, the last only while a shortcut is bound.
    var legend: [LegendLine] {
        var lines = [
            LegendLine(symbol: "cursorarrow.click", text: copy.click),
            LegendLine(symbol: "contextualmenu.and.cursorarrow", text: copy.rightClick),
            LegendLine(symbol: "tray.and.arrow.down", text: copy.drag),
        ]
        if !shortcuts.isEmpty { lines.append(LegendLine(symbol: "keyboard", text: keysLine)) }
        return lines
    }

    /// "⌃⌥⌘T Translate · ⌃⌥⌘L Lyrics".
    var keysLine: String {
        shortcuts.map { "\($0.keys) \($0.name)" }.joined(separator: " · ")
    }

    /// The way back, with the open shortcut in it while there is one.
    var comeBackLine: String {
        openKeys.isEmpty ? copy.comeBackUnbound : String(format: copy.comeBack, openKeys)
    }

    var body: some View {
        GeometryReader { proxy in
            let columns = Self.columns(bodyWidth: proxy.size.width)
            HStack(alignment: .top, spacing: Self.columnGap) {
                legendColumn
                    .frame(width: columns.legend, alignment: .topLeading)
                message
                    .frame(width: columns.message, alignment: .topLeading)
            }
            .padding(Self.margins)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
    }

    var legendColumn: some View {
        VStack(alignment: .leading, spacing: Self.legendSpacing) {
            ForEach(legend, id: \.symbol) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: line.symbol)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Theme.tertiary)
                        .frame(width: Self.glyphWidth)
                        .accessibilityHidden(true)
                    Text(line.text)
                        .islandFont(.body, weight: .regular)
                        .foregroundStyle(Theme.secondary)
                        // Wrapped, never cut: a legend that loses its tail
                        // loses the half that says what to do.
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
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
