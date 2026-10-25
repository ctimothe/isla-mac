import SwiftUI

/// Previous, Play / Pause and Next, drawn once for every surface that has them:
/// the player, the lyrics stage's foot and the lock card's two transports.
///
/// The stage drew its own — a 13 pt semibold glyph in a white 0.10 well, the
/// card's came from the type scale — so one song showed three different sets of
/// the same three buttons depending on which page you were on. The owner's
/// review of the lyric page (2026-10-25): its previous, play and next did not
/// match the player page's, and "everything should be consistently used" for
/// controls in the same context. So the glyph is the
/// player's — `PlayerLayout.Control.glyph`, the board's 35 × 22 and 29 × 34,
/// white 0.90 — and a surface with a smaller row scales it by its own target
/// over the player's 42 rather than choosing sizes of its own. What differs per
/// surface is only where the button sits and how large its hit target is; both
/// stay with the surface.
struct TransportGlyphButton: View {
    enum Kind: CaseIterable {
        case previous, playPause, next

        /// The player's control this one is drawn as, which is where its glyph
        /// size comes from.
        var control: PlayerLayout.Control {
            switch self {
            case .previous: return .previous
            case .playPause: return .playPause
            case .next: return .next
            }
        }

        /// The SF Symbol: the same three the player has always drawn.
        func symbol(isPlaying: Bool) -> String {
            switch self {
            case .previous: return "backward.fill"
            case .playPause: return isPlaying ? "pause.fill" : "play.fill"
            case .next: return "forward.fill"
            }
        }

        /// The accessibility label and help text. Play / Pause names what the
        /// press will do, not what the song is doing.
        func label(isPlaying: Bool) -> String {
            switch self {
            case .previous: return localized("Previous Track")
            case .playPause: return isPlaying ? localized("Pause") : localized("Play")
            case .next: return localized("Next Track")
            }
        }
    }

    let kind: Kind
    var isPlaying = false
    var enabled = true
    /// The surface's own hit target. The player's is 42 square; the stage keeps
    /// its 32 / 34 × 30 wells; the lock card its 24 and 36.
    var hitTarget: CGSize = CGSize(width: PlayerLayout.hitTarget, height: PlayerLayout.hitTarget)
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        _ kind: Kind, isPlaying: Bool = false, enabled: Bool = true,
        hitTarget: CGSize = CGSize(width: PlayerLayout.hitTarget, height: PlayerLayout.hitTarget),
        action: @escaping () -> Void
    ) {
        self.kind = kind
        self.isPlaying = isPlaying
        self.enabled = enabled
        self.hitTarget = hitTarget
        self.action = action
    }

    /// The glyph as drawn on a surface whose target is `hitTarget`: the
    /// player's size, scaled by how much shorter the target is than 42. The
    /// height decides, since the stage's wells are wider than they are tall.
    static func glyphSize(_ kind: Kind, hitTarget: CGSize) -> CGSize {
        let scale = hitTarget.height / PlayerLayout.hitTarget
        let glyph = kind.control.glyph
        return CGSize(width: glyph.width * scale, height: glyph.height * scale)
    }

    var body: some View {
        let symbol = kind.symbol(isPlaying: isPlaying)
        let label = kind.label(isPlaying: isPlaying)
        let glyph = Self.glyphSize(kind, hitTarget: hitTarget)
        Button(action: action) {
            Image(systemName: symbol)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: glyph.width, height: glyph.height)
                .foregroundStyle(.white.opacity(Theme.playerTransportOpacity))
                // Replaced, not swapped: a hard cut on the control the eye is
                // resting on is the most visible non-native moment there is.
                .symbolSwap(value: symbol, reduceMotion: reduceMotion)
        }
        .buttonStyle(TransportGlyphStyle(size: hitTarget.width, height: hitTarget.height))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .animation(Theme.contentAnimation, value: enabled)
        .help(label)
        .accessibilityLabel(label)
    }
}
