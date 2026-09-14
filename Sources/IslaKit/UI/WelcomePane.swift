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
/// It says three things, in the order somebody who just launched an invisible
/// app needs them: that the app is running, where it is, and how to get out of
/// it. The last one is not a courtesy — an `LSUIElement` app does not appear in
/// Force Quit, so a user who cannot find the panel has no way to quit it.
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

    /// The six strings, resolved through the app's own tables by default.
    ///
    /// Handed in rather than written into the `Text`s so a test can render this
    /// pane with the *Russian* table and measure whether it still fits the body:
    /// under `swift test` there is no bundle carrying the `.lproj` folders, so
    /// `Text`'s own lookup silently falls back to the key and a fit check on it
    /// would only ever measure English. Russian here runs about a third longer,
    /// which is where a layout laid out in English overflows.
    var copy: Copy = .fromTables

    struct Copy {
        var running: String
        var whereItLives: String
        var openPanel: String
        var translateClipboard: String
        var settingsFootnote: String
        var action: String

        /// English — and therefore also the keys, since in this project the keys
        /// *are* the English text.
        static let english = Copy(
            running: "Isla is running.",
            whereItLives: "It lives at the notch. Click it to open.",
            openPanel: "Open the panel",
            translateClipboard: "Translate the clipboard",
            settingsFootnote: "Quit and everything else lives in Settings, at the bottom left.",
            action: "Get Started"
        )

        /// The same six, looked up in whichever table the app ended up running
        /// in.
        static var fromTables: Copy {
            Copy(
                running: localized(english.running),
                whereItLives: localized(english.whereItLives),
                openPanel: localized(english.openPanel),
                translateClipboard: localized(english.translateClipboard),
                settingsFootnote: localized(english.settingsFootnote),
                action: localized(english.action)
            )
        }

        var all: [String] {
            [running, whereItLives, openPanel, translateClipboard, settingsFootnote, action]
        }
    }

    /// Every key this pane shows, so a test can prove both tables carry them.
    static let localizedKeys = Copy.english.all

    var body: some View {
        // The vertical budget, measured rather than guessed, because the body is
        // a fixed 208 pt that never resizes and there is nothing to scroll: the
        // shallowest body any supported Mac can give this pane is 154 pt (208,
        // less a notch as deep as 40, less the 14 below the rail). Laid out as
        // designed — a `Spacer` holding the button to the floor, 10 pt between
        // rows — it asked for 168, and its button was cut off. Dropping the
        // spacer took it to 158 and this 8 pt spacing to 150, in *both*
        // languages. `FirstRunTests` holds the number.
        VStack(alignment: .leading, spacing: 8) {
            Text(copy.running)
                .islandFont(.title)
                .foregroundStyle(.white)

            Text(copy.whereItLives)
                .islandFont(.body, weight: .regular)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                shortcut("⌥⌘I", copy.openPanel)
                shortcut("⌥⌘T", copy.translateClipboard)
            }
            .padding(.top, 2)

            Text(copy.settingsFootnote)
                .islandFont(.caption, weight: .regular)
                .foregroundStyle(Theme.tertiary)
                // This line and the one above it are the two long enough to
                // wrap. Neither does today — both fit on one line even at the
                // narrowest panel width, in English and in Russian — but a
                // `Text` in a stack whose height is decided elsewhere truncates
                // to one line rather than taking two, so a longer translation
                // would arrive with its tail cut off instead of merely tight.
                .fixedSize(horizontal: false, vertical: true)

            // The stack flows from the top and the slack collects underneath,
            // like every other pane. A `Spacer` holding this button to the floor
            // of the body is what pushed the pane past the height it has — see
            // the note at the top.
            Button(action: onDismiss) {
                Text(copy.action)
                    .islandFont(.body)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    // The panel's own pill, one step brighter: `Theme.surface`
                    // with a hairline is what the Music tab's "Open Spotify"
                    // button is, and this is the same shape carrying the one
                    // action on screen.
                    .background(Theme.surfaceHover, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        // Aligned with every other pane rather than inset on its own: the rail
        // is beside it and the body already pads its content by 14.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 2)
        .padding(.trailing, 4)
    }

    /// Room for the widest of the shortcut glyphs, so that the two keycaps are
    /// the same size and the two labels start at the same x.
    ///
    /// The system font is proportional and these are not digits, so `⌥⌘T`
    /// measures 28.3 pt against `⌥⌘I`'s 24.3 — the two caps came out four points
    /// apart, and two rows of a two-row list not lining up is the one flaw in
    /// this pane a reader cannot help seeing. `.monospacedDigit()`, which the
    /// first draft used for this, does nothing here: it fixes the width of
    /// figures, and there are none. `FirstRunTests` measures both strings
    /// against this number, so a font change that outgrew it fails a test
    /// instead of quietly ragging the column again.
    static let keycapGlyphWidth: CGFloat = 30

    /// The glyph and what it does. The keycap is the rail icon's own well —
    /// `Theme.surface` — so a shortcut reads as a key rather than as a link.
    ///
    /// No tracking on the glyphs, deliberately: `Theme.tracking(forSize:)` adds
    /// space *after* every character including the last, which pushes a
    /// two-glyph keycap off centre inside its well. The label beside it is prose
    /// and takes the table.
    private func shortcut(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 8) {
            Text(keys)
                .font(Theme.TypeRole.body.font())
                .foregroundStyle(.white)
                // Inside the padding, so the well grows with the glyphs rather
                // than the glyphs sliding around inside a fixed well.
                .frame(minWidth: Self.keycapGlyphWidth)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            Text(label)
                .islandFont(.body, weight: .regular)
                .foregroundStyle(Theme.secondary)
        }
        // One element, so VoiceOver reads the pair as "⌥⌘I, open the panel"
        // rather than stopping on a keycap that means nothing on its own.
        .accessibilityElement(children: .combine)
    }
}
