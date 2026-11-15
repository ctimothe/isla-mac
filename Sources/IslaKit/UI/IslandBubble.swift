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
    /// tabular, in white (owner, 2026-10-25: it was the system blue).
    static let glyphSize = CGSize(width: 18, height: 14)
    static let spacing: CGFloat = 5
    static let countSize: CGFloat = 13
    static var countColor: Color { Color.white }

    /// How far right of the island's centre the bubble's centre sits. The
    /// bubble only ever stands beside Music, a compact activity, so the
    /// island's shoulder is the compact one. A wider count moves the centre
    /// by half its growth: the left edge holds its gap and the bubble grows
    /// to the right.
    static func centreOffset(islandWidth: CGFloat, count: Int) -> CGFloat {
        centreOffset(islandWidth: islandWidth, bubbleWidth: width(count: count))
    }

    static func centreOffset(islandWidth: CGFloat, bubbleWidth: CGFloat) -> CGFloat {
        islandWidth / 2 + Theme.collapsedTopRadius + gap + bubbleWidth / 2
    }

    /// The bubble's width for what it holds: the Shelf's grows with its
    /// count, every other activity keeps islandcn's one width.
    static func width(for bubble: IslandActivity) -> CGFloat {
        if case .shelf(let count) = bubble { return width(count: count) }
        return LiveActivityLayout.bubbleWidth
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
    /// What the bubble holds when it is not the Shelf (amended 2026-11-14):
    /// a timer, a recording, a download or the song, in minimal form.
    var activity: IslandActivity? = nil
    var reduceMotion = false
    var now: () -> Date = Date.init
    let height: CGFloat
    /// The black shape's own height: the pill's beside it, which on a real
    /// notch drops half the stroke below the body (`NotchContentView.clearingCutout`)
    /// so the two bottom lines meet. The content and the press keep `height`.
    var outlineHeight: CGFloat? = nil
    let increaseContrast: Bool
    let action: () -> Void

    /// The bubble's name, and the island's value while the Shelf holds it.
    /// One file is "Shelf, 1 item": it said "1 items", the first words
    /// VoiceOver had for a single dropped file (`CountedSentenceTests`).
    static func label(count: Int) -> String {
        count == 1 ? localized("Shelf, 1 item") : localized("Shelf, %d items", count)
    }

    var body: some View {
        Button(action: action) {
            if let activity, !isShelf {
                LiveBubbleContent(activity: activity, reduceMotion: reduceMotion)
                    .accessibilityHidden(true)
            } else {
                content
            }
        }
        .buttonStyle(BubbleStyle(
            width: activity.map(IslandBubbleLayout.width(for:)) ?? IslandBubbleLayout.width(count: count),
            height: height, outlineHeight: outlineHeight ?? height, increaseContrast: increaseContrast
        ))
        .accessibilityLabel(accessibilityName)
    }

    private var isShelf: Bool {
        if case .shelf? = activity { return true }
        return false
    }

    private var accessibilityName: String {
        switch activity {
        case .live(let live)?: return live.accessibilityLabel(at: now())
        case .music?: return localized("Music")
        default: return Self.label(count: count)
        }
    }

    private var content: some View {
        let scale = CompactIslandLayout.glyphScale(height: height)
        return HStack(spacing: IslandBubbleLayout.spacing) {
            GlyphImage(.trayFullFilled)
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
        let outlineHeight: CGFloat
        let increaseContrast: Bool

        func makeBody(configuration: Configuration) -> some View {
            ZStack(alignment: .top) {
                ZStack {
                    NotchShape(topRadius: IslandBubbleLayout.topRadius, bottomRadius: IslandBubbleLayout.bottomRadius)
                        .fill(configuration.isPressed ? Theme.islandHover : Color.black)
                    IslandStrokeShape(topRadius: IslandBubbleLayout.topRadius, bottomRadius: IslandBubbleLayout.bottomRadius)
                        .stroke(
                            IslandStroke.color(tint: nil, increaseContrast: increaseContrast),
                            lineWidth: Theme.islandStrokeWidth
                        )
                        .allowsHitTesting(false)
                }
                .frame(width: width, height: outlineHeight)
                configuration.label
                    .frame(width: width, height: height)
            }
            .frame(width: width, height: height, alignment: .top)
            .contentShape(Rectangle())
            .animation(Theme.contentAnimation, value: configuration.isPressed)
        }
    }
}
