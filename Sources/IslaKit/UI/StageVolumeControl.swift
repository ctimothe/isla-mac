import SwiftUI

/// The lyric stage's speaker (spec §19.6, amended 2026-10-26): one of the
/// foot's 28 pt tools, its glyph the level's — `speaker.slash.fill` at 0 or
/// muted, then `speaker.fill` up to `speaker.wave.3.fill` — lit while its
/// slider is open. A press opens the slider and reads the level; that first
/// press is the only thing that can raise macOS's Automation prompt for the
/// player (`PlayerVolume`).
///
/// To VoiceOver it is the control itself, not only a way to it: "Spotify
/// volume, 40 percent", adjustable with VO-Up and VO-Down. The slider folds
/// three seconds after the last touch, which is no time at all for someone
/// navigating by ear, so the steps must not depend on it being open.
struct StageVolumeButton: View {
    @ObservedObject var volume: PlayerVolume

    var body: some View {
        HeaderIconButton(symbol: volume.symbol, label: volume.label, isOn: volume.isOpen) {
            volume.toggle()
        }
        .accessibilityValue(volume.spokenValue)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: volume.step(up: true)
            case .decrement: volume.step(up: false)
            @unknown default: break
            }
        }
    }
}

/// The open slider: Apple Music's, a quiet speaker at the low end and a loud
/// one at the high end around a capsule track that thickens under the finger.
///
/// Drawn on the stage's own surface, with no material of its own: the stage
/// is already one `glassSurface`, and a second layer of glass on top of it is
/// the stacking the UI rules forbid. Increase Contrast draws the track's
/// edge, as the system draws its own sliders' then; Reduce Motion keeps the
/// thickening but drops its spring.
struct StageVolumeSlider: View {
    @ObservedObject var volume: PlayerVolume
    @ObservedObject private var appearance = SystemAppearance.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let trackHeight: CGFloat = 5
    static let draggingTrackHeight: CGFloat = 8
    static let glyphSlot: CGFloat = 14
    static let spacing: CGFloat = 8

    var body: some View {
        HStack(spacing: Self.spacing) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 11, weight: .medium))
                .frame(width: Self.glyphSlot, alignment: .leading)
            track
                .volumeAccessibility(
                    level: volume.level ?? 0,
                    muted: volume.target == .system && volume.muted,
                    label: volume.label
                ) { volume.set($0) }
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 11, weight: .medium))
                .frame(width: Self.glyphSlot, alignment: .trailing)
        }
        .foregroundStyle(Theme.secondary)
        .accessibilityElement(children: .contain)
    }

    private var track: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = volume.isDragging ? Self.draggingTrackHeight : Self.trackHeight
            let fraction = volume.level ?? 0
            let dimmed = volume.target == .system && volume.muted
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.stageTrack)
                Capsule()
                    .fill(dimmed ? Theme.stageTrack : Color.white)
                    .frame(width: width * fraction)
                if appearance.increaseContrast {
                    Capsule().strokeBorder(Color.white.opacity(0.6), lineWidth: 1)
                }
            }
            .frame(height: height)
            .clipShape(Capsule())
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .animation(reduceMotion ? nil : Theme.trackSwapSpring, value: volume.isDragging)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard width > 0 else { return }
                        volume.dragChanged(fraction: value.location.x / width)
                    }
                    .onEnded { _ in volume.dragEnded() }
            )
        }
    }
}

/// The one line an open slider shows when the player refused Automation:
/// the control has fallen back to the Mac's volume, and this offers the
/// place to allow it. It is the refusal's only surface — no toast, no alert.
struct StageVolumeNotice: View {
    let app: PlayerApp

    var body: some View {
        Button {
            PlayerVolume.openAutomationSettings()
        } label: {
            Text(localized("Allow Isla to control %@…", app.displayName))
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .buttonStyle(PanelButtonStyle())
        .help(localized("Open Automation Settings…"))
    }
}
