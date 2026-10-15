import AppKit
import SwiftUI

/// Raises a flag and lowers it again a moment later.
///
/// The moment is 1.1 s everywhere in the panel, and it is a compromise between
/// two failures: shorter and the checkmark is gone before the eye returns from
/// wherever the copy was going, longer and a second copy lands while the first
/// is still being confirmed, so the tick never appears to move.
@MainActor
func flash(_ flag: Binding<Bool>) {
    flag.wrappedValue = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
        flag.wrappedValue = false
    }
}

/// Copies, then says so.
///
/// The panel has no other way to confirm a copy: the pasteboard is invisible,
/// and the thing that was copied is usually going somewhere the panel cannot
/// see. Turning the icon into a tick for a moment is the whole feedback, which
/// is why it is worth having in one place rather than four.
///
/// The tick was all of it, though, and a tick is only for the eye: the label
/// and the help kept saying "Copy" after the copy had happened, so VoiceOver
/// read the same word before and after and a press sounded like nothing
/// (M-06). While the tick shows, the button is called "Copied" and says so
/// once through the announcer, which is the only way the moment reaches
/// speech without moving the VoiceOver cursor.
struct CopyButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// What the button is called at rest. A pane with more than one thing to
    /// copy names which one ("Copy Translation"), because a bare "Copy" read
    /// out of context does not say what lands on the pasteboard.
    var title: String = localized("Copy")
    /// The key that copies the same thing without the pointer, shown in the
    /// help at rest ("Copy Translation (⇧⌘C)"). A shortcut nobody can find
    /// is one only the person who wrote it uses; the tooltip is where a Mac
    /// says what a button's key is when there is no menu to list it in.
    var shortcut: String? = nil
    /// Moves when the same copy is made some other way — by `shortcut` — so
    /// the tick confirms that one too. The speaking is left to whoever made
    /// the copy. A count that also moves for the button's own press costs
    /// nothing: the flag is already up, and raising it again is the same tick.
    var copiesElsewhere: Int = 0
    /// The plate's side: 22 everywhere, 24 for Translate's footer (spec §11).
    var side: CGFloat = 22
    let copy: () -> Void

    @State private var copied = false

    private var name: String { copied ? localized("Copied") : title }

    /// The label never carries the key: VoiceOver reads the shortcut glyphs
    /// one by one, and "Copy Translation, shift command C" on every visit
    /// is noise.
    private var help: String {
        guard !copied, let shortcut else { return name }
        return "\(name) (\(shortcut))"
    }

    var body: some View {
        Button {
            copy()
            flash($copied)
            Announcer.shared.announce(localized("Copied"))
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .islandFont(.caption, weight: .semibold)
                .foregroundStyle(copied ? Theme.success : Theme.secondary)
                .symbolSwap(value: copied, reduceMotion: reduceMotion)
                .frame(width: side, height: side)
                .contentShape(Rectangle())
        }
        .buttonStyle(PanelButtonStyle())
        .help(help)
        .accessibilityLabel(name)
        .animation(Theme.contentAnimation, value: copied)
        .onChange(of: copiesElsewhere) { flash($copied) }
    }
}

/// Every two-press confirmation that is armed right now, by the closure that
/// takes its question back.
///
/// Escape is how macOS says cancel, and an armed Clear is the nearest thing in
/// the panel there is to cancel. It used to close the whole panel instead
/// (owner decision 3): the arming survived out of sight, and the next open
/// found a red "Clear Everything" one stray click from emptying the shelf.
/// `NotchViewModel.consumeEscape()` asks here first, so the first Escape
/// disarms and only the second, with nothing left armed, folds the panel.
///
/// A registry rather than an environment value because the Escape is read at
/// the window (`NotchPanel.escapeHandled`, or the pinned panel's transient hot
/// key), far from any view. An entry is withdrawn the moment its arming ends
/// for any reason, including the pane going away, so a torn-down pane cannot
/// keep claiming Escapes; the closures the panes register hold their arming
/// weakly for the same reason.
@MainActor
final class ArmedConfirmations {
    static let shared = ArmedConfirmations()

    /// How long an unanswered arming stands before it lapses on its own.
    ///
    /// 3 s is enough to move a pointer back onto the word that just turned
    /// red. It is not enough for VoiceOver, where the arming is heard rather
    /// than seen and the cursor has to be walked back to the button — 3 s
    /// lapsed while the announcement was still being read. 8 s is the
    /// VoiceOver allowance; the resting state is still the safe one.
    static func armedDuration(voiceOver: Bool) -> TimeInterval {
        voiceOver ? 8 : 3
    }

    private var disarms: [UUID: () -> Void] = [:]

    /// Records an armed confirmation. Keep the token to withdraw it when the
    /// arming ends by any other route.
    @discardableResult
    func register(_ disarm: @escaping () -> Void) -> UUID {
        let token = UUID()
        disarms[token] = disarm
        return token
    }

    func withdraw(_ token: UUID) {
        disarms[token] = nil
    }

    /// Takes back every armed question. True when there was one, which is
    /// what makes this Escape spent.
    func disarmAll() -> Bool {
        guard !disarms.isEmpty else { return false }
        // Emptied before the closures run, so a closure that withdraws its own
        // token — every pane's does — finds nothing to mutate mid-iteration.
        let pending = disarms.values
        disarms.removeAll()
        pending.forEach { $0() }
        return true
    }
}

/// The arming both confirmation shapes share: press, announce, lapse, and the
/// three ways out of it — a second press, the lapse, Escape.
///
/// It was two copies of a `@State` flag and a `Task` once, which had no hover
/// pause, no voice and no way for Escape to reach them; one object now, so
/// the Settings row and the pane footers cannot drift apart again.
@MainActor
private final class ConfirmationArming: ObservableObject {
    @Published private(set) var armed = false

    private var lapse: Task<Void, Never>?
    private var token: UUID?
    private var hovering = false

    func press(armedTitle: String, action: () -> Void) {
        if armed {
            disarm()
            action()
        } else {
            arm(armedTitle)
        }
    }

    /// The pointer resting on the armed word is somebody reading it and
    /// deciding, so the lapse waits for them. It used to run under the
    /// pointer and turn the word back to Clear while it was being read.
    /// Leaving starts the full allowance again rather than what was left:
    /// the question has to stay up long enough to be answered.
    func hover(_ inside: Bool) {
        hovering = inside
        guard armed else { return }
        if inside {
            lapse?.cancel()
            lapse = nil
        } else {
            startLapse()
        }
    }

    func disarm() {
        lapse?.cancel()
        lapse = nil
        if let token { ArmedConfirmations.shared.withdraw(token) }
        token = nil
        armed = false
    }

    private func arm(_ armedTitle: String) {
        armed = true
        token = ArmedConfirmations.shared.register { [weak self] in self?.disarm() }
        // Arming only turned the word red, which nobody hears: a VoiceOver
        // user pressed Clear, heard nothing, and pressed again to find out —
        // which confirmed it.
        Announcer.shared.announce(localized("%@. Press again to confirm.", armedTitle))
        // A click arrives with the pointer already on the button, so the
        // lapse starts only once it leaves. A keyboard or VoiceOver press
        // has no pointer there, and the lapse starts now.
        if !hovering { startLapse() }
    }

    private func startLapse() {
        lapse?.cancel()
        // Read at the moment of arming, not once at launch: VoiceOver is
        // toggled with ⌘F5 mid-session as often as not.
        let duration = ArmedConfirmations.armedDuration(voiceOver: NSWorkspace.shared.isVoiceOverEnabled)
        lapse = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.disarm()
        }
    }
}

/// A destructive action that asks before it acts.
///
/// Two presses rather than a dialog. This panel never activates and hangs off
/// the top edge of the screen: a sheet would either fail to take focus or
/// cover the very thing being confirmed. Arming in place keeps the question
/// where the answer is, and walking away is the safe outcome — the arming
/// lapses on its own, so the dangerous state is never the resting one.
struct ConfirmTextButton: View {
    let title: String
    let armedTitle: String
    let action: () -> Void

    @StateObject private var arming = ConfirmationArming()

    var body: some View {
        Button {
            arming.press(armedTitle: armedTitle, action: action)
        } label: {
            Text(arming.armed ? armedTitle : title)
                .islandFont(.caption)
                .foregroundStyle(arming.armed ? Theme.danger : Theme.secondary)
                // The word alone was a 27x13 target beside Deselect (F-014):
                // a near miss above or below it hit the list instead, and one
                // to the side armed the wrong control. The floor is the
                // panel's token; the width still follows the word.
                .frame(minWidth: Theme.minimumHitSize.width, minHeight: Theme.minimumHitSize.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(PanelButtonStyle())
        .accessibilityLabel(arming.armed ? armedTitle : title)
        .accessibilityHint(arming.armed ? "" : localized("Asks for confirmation before acting."))
        .animation(Theme.contentAnimation, value: arming.armed)
        .onHover { arming.hover($0) }
        .onDisappear { arming.disarm() }
    }
}

/// The Settings shape of `ConfirmTextButton` (redesign 2026-10-15, spec §10): a
/// push button that asks before it acts.
///
/// Actions in Settings are push buttons on trailing rows and never red text
/// rows — a red row is an iOS cell, and on a Mac the one button that destroys
/// something is still a button. It looks like every other push button until it
/// is pressed once; then its plate says the question ("Delete These Files",
/// "Disconnect") in the destructive style, and a second press — before the
/// arming lapses, Escape takes it back — does the thing. Same arming as
/// `ConfirmTextButton`, so the pane footers and this cannot drift apart, and
/// the same announcement for VoiceOver, which hears the arming rather than
/// seeing it.
struct ConfirmPushButton: View {
    let title: String
    let armedTitle: String
    var disabled = false
    let action: () -> Void

    @StateObject private var arming = ConfirmationArming()

    var body: some View {
        Button {
            arming.press(armedTitle: armedTitle, action: action)
        } label: {
            Text(arming.armed ? armedTitle : title)
        }
        .buttonStyle(ToolbarPushButtonStyle(kind: arming.armed ? .danger : .normal))
        .disabled(disabled)
        .accessibilityLabel(arming.armed ? armedTitle : title)
        .accessibilityHint(arming.armed ? "" : localized("Asks for confirmation before acting."))
        .animation(Theme.contentAnimation, value: arming.armed)
        .onHover { arming.hover($0) }
        .onDisappear { arming.disarm() }
    }
}
