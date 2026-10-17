import SwiftUI

/// Where the Shelf's bubble sits and what it holds (spec §19.7). Pure, so the
/// view that draws it, the geometry that hit-tests it and the test that holds
/// it cannot describe three bubbles.
enum IslandBubbleLayout {
    /// The shape, shoulders included, as the reference measures it for a
    /// one-digit count, and 8 wider for each further digit (spec §19.7,
    /// amended 2026-10-17): at a fixed 58, "60" touched the shoulders on the
    /// owner's Mac. 8 is one tabular digit of 13 semibold, so every count
    /// keeps the one-digit bubble's padding — `IslandBubbleTests` measures it.
    static func width(count: Int) -> CGFloat {
        oneDigitWidth + CGFloat(digits(count) - 1) * digitAdvance
    }
    static let oneDigitWidth: CGFloat = 58
    static let digitAdvance: CGFloat = 8

    /// How many digits the count is drawn with. The Shelf holds at most 60,
    /// so one or two.
    static func digits(_ count: Int) -> Int {
        String(max(0, count)).count
    }
    /// From the island's outline — its shoulders, not its body — to the
    /// bubble's.
    static let gap: CGFloat = 16
    static var topRadius: CGFloat { Theme.collapsedTopRadius }
    static let bottomRadius: CGFloat = 14

    /// `tray.full.fill` 18 × 14, white; 5 pt; the count, 13 semibold,
    /// tabular, in the system blue.
    static let glyphSize = CGSize(width: 18, height: 14)
    static let spacing: CGFloat = 5
    static let countSize: CGFloat = 13
    static var countColor: Color { Theme.SettingsTint.blue.color }

    /// How far right of the island's centre the bubble's centre sits. The
    /// bubble only ever stands beside Music, a compact activity, so the
    /// island's shoulder is the compact one. A wider count moves the centre
    /// by half its growth: the left edge holds its gap and the bubble grows
    /// to the right.
    static func centreOffset(islandWidth: CGFloat, count: Int) -> CGFloat {
        islandWidth / 2 + Theme.collapsedTopRadius + gap + width(count: count) / 2
    }
}

/// The Shelf waiting beside the island while Music holds it (spec §19.1,
/// §19.7): a small island of its own, the tray and the count. A click opens
/// the Shelf.
///
/// A button, so VoiceOver finds it after the island as the second thing at the
/// top of the screen, with the Shelf activity's own label. Pressed, it takes
/// the island's `#1C1C1E`, the colour a pressed island takes.
struct IslandBubble: View {
    let count: Int
    let height: CGFloat
    let increaseContrast: Bool
    let action: () -> Void

    static func label(count: Int) -> String {
        localized("Shelf, %d items", count)
    }

    var body: some View {
        Button(action: action) {
            content
        }
        .buttonStyle(BubbleStyle(
            width: IslandBubbleLayout.width(count: count), height: height, increaseContrast: increaseContrast
        ))
        .accessibilityLabel(Self.label(count: count))
    }

    private var content: some View {
        let scale = CompactIslandLayout.glyphScale(height: height)
        return HStack(spacing: IslandBubbleLayout.spacing) {
            Image(systemName: "tray.full.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color.white)
                .frame(
                    width: IslandBubbleLayout.glyphSize.width * scale,
                    height: IslandBubbleLayout.glyphSize.height * scale
                )
            Text(count, format: .number)
                .font(.system(size: IslandBubbleLayout.countSize, weight: .semibold).monospacedDigit())
                .foregroundStyle(IslandBubbleLayout.countColor)
                .contentTransition(.numericText(value: Double(count)))
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityHidden(true)
    }

    /// The black shape, its stroke and the press, around the content.
    private struct BubbleStyle: ButtonStyle {
        let width: CGFloat
        let height: CGFloat
        let increaseContrast: Bool

        func makeBody(configuration: Configuration) -> some View {
            ZStack {
                NotchShape(topRadius: IslandBubbleLayout.topRadius, bottomRadius: IslandBubbleLayout.bottomRadius)
                    .fill(configuration.isPressed ? Theme.islandHover : Color.black)
                IslandStrokeShape(topRadius: IslandBubbleLayout.topRadius, bottomRadius: IslandBubbleLayout.bottomRadius)
                    .stroke(
                        IslandStroke.color(tint: nil, increaseContrast: increaseContrast),
                        lineWidth: Theme.islandStrokeWidth
                    )
                    .allowsHitTesting(false)
                configuration.label
            }
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .animation(Theme.contentAnimation, value: configuration.isPressed)
        }
    }
}
