import SwiftUI

/// The card at the head of Settings → About that says what an update is doing:
/// the draw of `UpdatePresentation`, in the form's own card, the way System
/// Settings → General → Software Update shows a release and then its progress.
///
/// It decides nothing. The words, the progress and the notes arrive in the
/// presentation; the buttons are rows of the table, under the card. What it does
/// own is how a change of state looks, and that follows the Mac: states change
/// layout (a bar and a caption appear, the notes go) with the panel's own
/// critically damped expand spring, or with its 0.24 s crossfade under Reduce
/// Motion — and the endless bar, which is motion by nature, becomes a slow
/// fade in and out instead of a sweep.
struct UpdateCard: View {
    let presentation: UpdatePresentation

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @ObservedObject private var appearance: SystemAppearance = .shared

    private var reduceMotion: Bool { systemReduceMotion || appearance.reduceMotion }

    /// The notes are cut at this many lines in the panel: the card is a summary,
    /// and "More Info…" opens the whole text on its page.
    static let notesLineLimit = 6
    static let barHeight: CGFloat = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let note = presentation.sourceNote {
                Text(verbatim: note)
                    .islandFont(.caption, weight: .regular)
                    .foregroundStyle(Theme.tertiary)
                    .padding(.top, 4)
            }
            if presentation.progress != .none && presentation.progress != .spinner {
                bar
                    .padding(.top, 8)
                    .transition(.opacity)
            }
            if let detail = presentation.detail {
                Text(verbatim: detail)
                    .islandFont(.caption, weight: .regular)
                    .foregroundStyle(Theme.secondary)
                    .monospacedDigit()
                    .padding(.top, 5)
                    .transition(.opacity)
            }
            if let notes = presentation.notes {
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: SettingsLayout.hairlineHeight)
                    .padding(.vertical, 8)
                    .accessibilityHidden(true)
                Text(UpdatePresentation.renderedNotes(notes))
                    .islandFont(.reading, weight: .regular)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(Self.notesLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, SettingsLayout.rowInset)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: SettingsLayout.groupRadius, style: .continuous)
                .fill(Theme.settingsGroupFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsLayout.groupRadius, style: .continuous)
                .strokeBorder(Theme.settingsGroupEdge, lineWidth: 0.5)
        )
        .animation(Theme.expand(reduceMotion: reduceMotion), value: presentation.stage.kind)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            if presentation.progress == .spinner {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: presentation.title)
                    .islandFont(.subhead, weight: .semibold)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle = presentation.subtitle {
                    Text(verbatim: subtitle)
                        .islandFont(.reading, weight: .regular)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        // Not a heading: the headings rotor has a stop per group header, which
        // `SettingsAccessibilityTests` holds, and the card is not one.
        .accessibilityElement(children: .combine)
    }

    // MARK: The bar

    @ViewBuilder
    private var bar: some View {
        switch presentation.progress {
        case .determinate(let fraction):
            ProgressTrack {
                GeometryReader { geometry in
                    Capsule()
                        .fill(Theme.SettingsTint.blue.color)
                        .frame(width: max(geometry.size.width * fraction, fraction > 0 ? Self.barHeight : 0))
                        // The bar steps with the bytes, a short linear glide
                        // between them; a bar that springs is travel, so with
                        // Reduce Motion it only steps.
                        .animation(reduceMotion ? nil : .linear(duration: 0.15), value: fraction)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(presentation.title)
            .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
        case .indeterminate:
            ProgressTrack {
                IndeterminateFill(reduceMotion: reduceMotion)
            }
            .accessibilityElement()
            .accessibilityLabel(presentation.title)
        case .none, .spinner:
            EmptyView()
        }
    }
}

extension UpdatePresentation.Stage {
    /// Which state, without its numbers: the layout changes when this does, and
    /// not on every byte of progress.
    var kind: Int {
        switch self {
        case .idle: return 0
        case .checking: return 1
        case .upToDate: return 2
        case .available: return 3
        case .downloading: return 4
        case .verifying: return 5
        case .installing: return 6
        case .relaunching: return 7
        case .failed: return 8
        case .manualOnly: return 9
        case .restartNeeded: return 10
        }
    }
}

/// The groove a bar runs in: white at 0.14, as the toolbar plate is, so a bar is
/// the same material as the buttons under it.
private struct ProgressTrack<Fill: View>: View {
    @ViewBuilder var fill: () -> Fill

    var body: some View {
        Capsule()
            .fill(Color.white.opacity(0.14))
            .frame(height: UpdateCard.barHeight)
            .overlay(alignment: .leading) { fill().clipShape(Capsule()) }
            .clipShape(Capsule())
    }
}

/// A bar with no end in sight. A short segment sweeps along the groove; under
/// Reduce Motion nothing travels, and the same segment's opacity rises and
/// falls instead, because a fade is not motion.
private struct IndeterminateFill: View {
    let reduceMotion: Bool

    private static let period: TimeInterval = 1.4

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = (t.truncatingRemainder(dividingBy: Self.period)) / Self.period
            GeometryReader { geometry in
                let segment = geometry.size.width * 0.35
                if reduceMotion {
                    let pulse = 0.5 - 0.5 * cos(phase * 2 * .pi)
                    Capsule()
                        .fill(Theme.SettingsTint.blue.color)
                        .frame(width: geometry.size.width * 0.5)
                        .opacity(0.35 + 0.5 * pulse)
                        .offset(x: geometry.size.width * 0.25)
                } else {
                    Capsule()
                        .fill(Theme.SettingsTint.blue.color)
                        .frame(width: segment)
                        .offset(x: -segment + (geometry.size.width + segment) * phase)
                }
            }
        }
    }
}
