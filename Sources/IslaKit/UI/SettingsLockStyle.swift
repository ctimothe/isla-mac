import SwiftUI

/// The four Card Style choices as small renders of the card itself (redesign
/// 2026-10-15, spec §10): Automatic, Transparent, Tinted and Solid, the chosen
/// one ringed in the accent at 2 pt.
///
/// **A render, not a picture.** Each preview asks `LockCardMaterial.decision` —
/// the function the lock card asks — what its material is, and draws that layer
/// at that alpha over a stand-in wallpaper, with the same Reduce Transparency
/// and Increase Contrast the card reads. So the preview cannot drift from the
/// card: when the material rules change (R2 changed them once already, after the
/// first boards were drawn), the previews change with them, and under Reduce
/// Transparency all four are Solid, as the footnote says the card is. Hardware
/// check R4-H3 holds them against the lock screen itself.
struct LockStylePicker: View {
    let title: String
    @Binding var selection: NotchViewModel.LockCardStyle
    let formWidth: CGFloat
    @ObservedObject private var appearance = SystemAppearance.shared

    var body: some View {
        let size = SettingsLayout.previewSize(formWidth: formWidth)
        // The ring stands 3 pt outside the preview and the form's scroll view
        // clips at its own edge, so the row insets 4 pt each side.
        let inset: CGFloat = 4
        let rowWidth = formWidth - inset * 2
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(NotchViewModel.LockCardStyle.allCases.enumerated()), id: \.element) { index, style in
                if index > 0 { Spacer(minLength: 0) }
                option(style, size: size)
            }
        }
        .frame(width: rowWidth)
        .padding(.horizontal, inset)
        .padding(.top, 4)
        .padding(.bottom, SettingsLayout.previewLabelGap)
        .accessibilityRepresentation {
            Picker(title, selection: $selection) {
                ForEach(NotchViewModel.LockCardStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
    }

    private func option(_ style: NotchViewModel.LockCardStyle, size: CGSize) -> some View {
        let isSelected = style == selection
        return Button {
            selection = style
        } label: {
            VStack(spacing: SettingsLayout.previewLabelGap) {
                LockStylePreview(
                    style: style, size: size,
                    reduceTransparency: appearance.reduceTransparency,
                    increaseContrast: appearance.increaseContrast
                )
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: SettingsLayout.previewRadius + 3, style: .continuous)
                            .strokeBorder(Theme.accent, lineWidth: Theme.settingsPreviewRingWidth)
                            .padding(-3)
                    }
                }
                Text(style.title)
                    .islandFont(.body, weight: isSelected ? .medium : .regular)
                    .foregroundStyle(isSelected ? Color.white : Theme.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: size.width + 12)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelButtonStyle())
        .accessibilityLabel(style.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// One miniature of the lock card in a style: a stand-in wallpaper, the card's
/// material, and the marks a card carries — cover, title, artist, scrubber,
/// transport — as bars, because at 80 pt wide a mark can only say where it is.
struct LockStylePreview: View {
    let style: NotchViewModel.LockCardStyle
    let size: CGSize
    var reduceTransparency = false
    var increaseContrast = false

    /// What the card is made of in this style: the card's own decision, for a
    /// song with a cover over a wallpaper of the unknown brightness the card
    /// assumes when it cannot measure one (`LockCardMaterial.unknownLuminance`,
    /// Sonoma's). Static and pure so a test holds that the previews ask the
    /// same function the card does.
    static func decision(
        style: NotchViewModel.LockCardStyle, reduceTransparency: Bool, increaseContrast: Bool
    ) -> LockCardMaterial.Decision {
        LockCardMaterial.decision(
            style: style, hasArtwork: true, luminance: LockCardMaterial.unknownLuminance,
            reduceTransparency: reduceTransparency, increaseContrast: increaseContrast
        )
    }

    /// The card's frame inside the preview: inset a seventh either side and an
    /// eighth above and below, so the wallpaper reads as the thing behind it.
    var card: CGRect {
        CGRect(
            x: size.width * 0.14, y: size.height * 0.17,
            width: size.width * 0.72, height: size.height * 0.66
        )
    }

    var body: some View {
        let decision = Self.decision(
            style: style, reduceTransparency: reduceTransparency, increaseContrast: increaseContrast
        )
        let cardRadius = card.height * 0.2
        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: Theme.settingsPreviewWallpaper, startPoint: .topLeading, endPoint: .bottomTrailing
            )
            ZStack(alignment: .topLeading) {
                material(decision)
                marks
            }
            .frame(width: card.width, height: card.height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
            .overlay {
                // The hairline Solid and Transparent carry; the cover's light
                // is its own edge.
                if decision.layer == .solid || decision.layer == .blackWash {
                    RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                        .strokeBorder(Theme.settingsPreviewEdge, lineWidth: 0.5)
                }
            }
            .offset(x: card.minX, y: card.minY)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: SettingsLayout.previewRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SettingsLayout.previewRadius, style: .continuous)
                .strokeBorder(Theme.settingsPreviewEdge, lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func material(_ decision: LockCardMaterial.Decision) -> some View {
        switch decision.layer {
        case .coverLight:
            Theme.settingsPreviewCoverLight.opacity(decision.alpha)
        case .neutralFill:
            Theme.lockCardSolid.opacity(decision.alpha)
        case .blackWash:
            Theme.lockCardTransparent(alpha: decision.alpha)
        case .solid:
            Theme.lockCardSolid
        }
    }

    private var marks: some View {
        let w = card.width
        let h = card.height
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: h * 0.05, style: .continuous)
                .fill(Theme.settingsPreviewCover)
                .frame(width: h * 0.22, height: h * 0.22)
                .offset(x: w * 0.07, y: h * 0.10)
            Capsule().fill(Theme.settingsPreviewInk)
                .frame(width: w * 0.34, height: max(1.5, h * 0.045))
                .offset(x: w * 0.07 + h * 0.22 + w * 0.04, y: h * 0.14)
            Capsule().fill(Theme.settingsPreviewInkSoft)
                .frame(width: w * 0.24, height: max(1.5, h * 0.04))
                .offset(x: w * 0.07 + h * 0.22 + w * 0.04, y: h * 0.25)
            Capsule().fill(Theme.settingsPreviewInkSoft)
                .frame(width: w * 0.86, height: max(1.5, h * 0.04))
                .offset(x: w * 0.07, y: h * 0.62)
            Capsule().fill(Theme.settingsPreviewInk)
                .frame(width: w * 0.40, height: max(1.5, h * 0.04))
                .offset(x: w * 0.07, y: h * 0.62)
            HStack(spacing: w * 0.07) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(Theme.settingsPreviewInk).frame(width: h * 0.08, height: h * 0.08)
                }
            }
            .frame(width: w * 0.86)
            .offset(x: w * 0.07, y: h * 0.78)
        }
    }
}
