import AppKit
import SwiftUI

/// The update alert on the island (spec §19.5 f): the glyph, "Isla %@ is
/// ready", the release's first sentence and what Install will do, and Later
/// beside Install.
///
/// Its own view, observing the installer, so a download's progress redraws
/// these few lines and not the whole island. What it shows is
/// `UpdateAlertStage`'s, and where each part sits is `UpdateAlertLayout`'s —
/// both pure, both tested; this only draws them. Once Install is pressed the
/// alert stays and follows the install, until Isla restarts as the new
/// version or says why it could not (plan 2026-10-19).
///
/// One container to VoiceOver, named by its title, with its buttons inside:
/// the island's own "Isla" button would hide them, and an alert that cannot be
/// answered by someone who cannot see it is not a choice.
@MainActor
struct UpdateAlertView: View {
    let offer: UpdateOffer
    let size: CGSize
    let notchHeight: CGFloat
    @ObservedObject var installer: UpdateInstaller
    @ObservedObject private var appearance = SystemAppearance.shared
    let onAction: (UpdateAlertAction) -> Void

    private typealias Layout = UpdateAlertLayout

    init(
        offer: UpdateOffer, size: CGSize, notchHeight: CGFloat,
        installer: UpdateInstaller? = nil, onAction: @escaping (UpdateAlertAction) -> Void
    ) {
        self.offer = offer
        self.size = size
        self.notchHeight = notchHeight
        self.installer = installer ?? .shared
        self.onAction = onAction
    }

    var stage: UpdateAlertStage {
        UpdateAlertStage.make(phase: installer.phase, installerRelease: installer.release, offer: offer)
    }

    var body: some View {
        let stage = self.stage
        let glyph = Layout.glyphFrame(notchHeight: notchHeight)
        ZStack(alignment: .topLeading) {
            Image(systemName: Layout.glyphSymbol)
                .resizable()
                .scaledToFit()
                .foregroundStyle(Theme.updateBlue.gradient)
                .frame(width: glyph.width, height: glyph.height)
                .offset(x: glyph.minX, y: glyph.minY)
                .accessibilityHidden(true)
            Text(localized("Isla %@ is ready", offer.version))
                .islandFont(Layout.titleSize, weight: .semibold)
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: textWidth, alignment: .leading)
                .islandBaseline(Layout.titleBaseline(notchHeight: notchHeight))
                .offset(x: Layout.textLeading)
            detail(stage)
            controls(stage)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localized("Isla %@ is ready", offer.version))
    }

    private var textWidth: CGFloat { Layout.textWidth(islandWidth: size.width) }

    /// The lines under the title. The offer and the install under way: the
    /// summary (or the install's step) on the first, "Isla restarts when it
    /// is done." on the second — moving up to the first when there is no
    /// summary. A failure, a manual update or a restart: what happened, over
    /// both lines.
    @ViewBuilder
    private func detail(_ stage: UpdateAlertStage) -> some View {
        let text = stage.detail(summary: offer.summary)
        if stage.showsRestartNote {
            if let text {
                detailLine(text, line: 0, lines: 1)
                    // A step of the install changes the words in place.
                    .contentTransition(.opacity)
            }
            detailLine(localized("Isla restarts when it is done."), line: text == nil ? 0 : 1, lines: 1)
        } else if let text {
            detailLine(text, line: 0, lines: 2)
        }
    }

    private func detailLine(_ text: String, line: Int, lines: Int) -> some View {
        Text(text)
            .islandFont(Layout.detailSize, weight: .medium)
            .foregroundStyle(Color.white.opacity(Layout.detailOpacity))
            .lineLimit(lines)
            .lineSpacing(Self.detailLineSpacing)
            .truncationMode(.tail)
            .frame(width: textWidth, alignment: .leading)
            .islandBaseline(Layout.detailBaseline(line: line, notchHeight: notchHeight))
            .offset(x: Layout.textLeading)
    }

    /// The space SwiftUI adds between two wrapped lines to make their pitch
    /// the spec's 14 pt: the font's own line height is less.
    private static let detailLineSpacing: CGFloat = {
        let font = NSFont.systemFont(ofSize: UpdateAlertLayout.detailSize, weight: .medium)
        return max(0, UpdateAlertLayout.detailLineHeight - (font.ascender - font.descender + font.leading))
    }()

    @ViewBuilder
    private func controls(_ stage: UpdateAlertStage) -> some View {
        if let primary = stage.primary {
            Button(UpdateAlertAction.later.title) { onAction(.later) }
                .buttonStyle(UpdateAlertButtonStyle(
                    fill: Theme.updateLaterFill, title: .white, increaseContrast: appearance.increaseContrast
                ))
                .placedAt(Layout.laterFrame(notchHeight: notchHeight))
            Button(primary.title) { onAction(primary) }
                .buttonStyle(UpdateAlertButtonStyle(
                    fill: Theme.updateBlue, title: Theme.updateInstallTitle,
                    increaseContrast: appearance.increaseContrast
                ))
                .placedAt(Layout.installFrame(islandWidth: size.width, notchHeight: notchHeight))
        } else if let progress = stage.progress {
            let frame = Layout.progressFrame(islandWidth: size.width, notchHeight: notchHeight)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(Layout.progressTrackOpacity))
                Capsule().fill(Theme.updateInstallTitle)
                    .frame(width: frame.width * progress)
            }
            .animation(Theme.contentAnimation, value: progress)
            .placedAt(frame)
            .accessibilityElement()
            .accessibilityLabel(stage.detail(summary: nil) ?? "")
            .accessibilityValue(Text(progress, format: .percent.precision(.fractionLength(0))))
        }
    }
}

/// A capsule 35 tall in its colour at 0.22, its word 14 semibold (§19.5 f);
/// pressed, the capsule deepens. Increase Contrast rings it in its word's
/// colour, as the island's stroke strengthens.
private struct UpdateAlertButtonStyle: ButtonStyle {
    let fill: Color
    let title: Color
    let increaseContrast: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .islandFont(UpdateAlertLayout.buttonTitleSize, weight: .semibold)
            .foregroundStyle(title)
            .lineLimit(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                fill.opacity(UpdateAlertLayout.buttonFillOpacity * (configuration.isPressed ? 1.6 : 1)),
                in: Capsule()
            )
            .overlay {
                if increaseContrast { Capsule().strokeBorder(title.opacity(0.6), lineWidth: 1) }
            }
            .contentShape(Capsule())
            .animation(Theme.contentAnimation, value: configuration.isPressed)
    }
}
