import SwiftUI

/// Where the dots under a page sit (spec §19.16), in the body's coordinates:
/// from the open shape's top-left, down. Four 6 pt dots on a 14 pt pitch,
/// centred on the shape, their centre 10 above its bottom, in the 16 pt band
/// each page grew by to hold them.
enum PageDotsLayout {
    static let dotSide: CGFloat = 6
    static let pitch: CGFloat = 14
    static let hitTarget = CGSize(width: 14, height: 20)
    static let centreAboveBottom: CGFloat = 10
    static var count: Int { NotchViewModel.Surface.pages.count }

    static func centres(bodySize: CGSize) -> [CGPoint] {
        let y = bodySize.height - centreAboveBottom
        let first = bodySize.width / 2 - CGFloat(count - 1) * pitch / 2
        return (0..<count).map { CGPoint(x: first + CGFloat($0) * pitch, y: y) }
    }

    static func dotFrames(bodySize: CGSize) -> [CGRect] {
        centres(bodySize: bodySize).map {
            CGRect(x: $0.x - dotSide / 2, y: $0.y - dotSide / 2, width: dotSide, height: dotSide)
        }
    }

    /// Each dot's target: 14 × 20 centred on it, so the four meet with no gap
    /// between them and a click a little off a dot still lands on one.
    static func hitFrames(bodySize: CGSize) -> [CGRect] {
        centres(bodySize: bodySize).map {
            CGRect(
                x: $0.x - hitTarget.width / 2, y: $0.y - hitTarget.height / 2,
                width: hitTarget.width, height: hitTarget.height
            )
        }
    }

    static func rowFrame(bodySize: CGSize) -> CGRect {
        hitFrames(bodySize: bodySize).reduce(CGRect.null) { $0.union($1) }
    }
}

/// The row of dots under every page (spec §19.16): where you are among the
/// four places, and a way to each that a mouse without a trackpad's swipe
/// can use.
///
/// Each dot is a button that dims on press as every panel button does; its
/// tooltip is its page's name. The current dot is white 0.90 and the others
/// 0.30, 0.45 while the pointer is over the row. For VoiceOver the row is one
/// adjustable element — "Pages", "Page 2 of 4, Shelf" — whose increment and
/// decrement turn the page, read after the page's own content.
struct PageDots: View {
    typealias Surface = NotchViewModel.Surface

    /// The current page's place in the row.
    let current: Int
    /// The drawn outline, which the row is centred on and stands 10 above.
    let bodySize: CGSize
    /// The header row's height: the content, and this row in it, starts
    /// under it.
    let headerHeight: CGFloat
    let turn: (Surface) -> Void
    let adjust: (Int) -> Void

    @State private var hovering = false

    var body: some View {
        let row = PageDotsLayout.rowFrame(bodySize: bodySize)
        HStack(spacing: 0) {
            ForEach(Array(Surface.pages.enumerated()), id: \.element) { index, page in
                Button { turn(page) } label: {
                    Circle()
                        .fill(Color.white.opacity(Self.opacity(index: index, current: current, hovering: hovering)))
                        .frame(width: PageDotsLayout.dotSide, height: PageDotsLayout.dotSide)
                        .frame(width: PageDotsLayout.hitTarget.width, height: PageDotsLayout.hitTarget.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PanelButtonStyle())
                .help(Self.tooltip(for: page))
            }
        }
        .onContinuousHover { phase in
            if case .active = phase { hovering = true } else { hovering = false }
        }
        .animation(Theme.contentAnimation, value: hovering)
        .animation(Theme.contentAnimation, value: current)
        .offset(x: row.minX, y: row.minY - headerHeight)
        // One adjustable element for the four buttons. A plain element with
        // an adjustable action is vended to AppKit with no role and no value,
        // so VoiceOver had nothing to read; a stepped slider is what macOS
        // knows as adjustable, and says its value aloud as it moves.
        .accessibilityRepresentation {
            Slider(
                value: Binding(
                    get: { Double(current) },
                    set: { adjust(Int($0.rounded()) - current) }
                ),
                in: 0...Double(Surface.pages.count - 1), step: 1
            ) {
                Text(Self.accessibilityLabel())
            }
            .accessibilityValue(Self.accessibilityValue(current: current))
        }
    }

    nonisolated static func opacity(index: Int, current: Int, hovering: Bool) -> Double {
        if index == current { return Theme.pageDotCurrent }
        return hovering ? Theme.pageDotOtherHovered : Theme.pageDotOther
    }

    /// The page nearest where the pages are drawn — so the dot moves half way
    /// through a swipe, as the page underneath does — or the one presented.
    static func current(leg: PageTravel.Leg?, presented: Surface) -> Int {
        guard let leg else { return presented.pageIndex ?? 0 }
        let nearest = min(max(Int(leg.position.rounded()), 0), leg.strip.lastIndex)
        return leg.strip.pages[nearest].pageIndex ?? 0
    }

    static func tooltip(for page: Surface) -> String { page.title }

    static func accessibilityLabel() -> String { localized("Pages") }

    static func accessibilityValue(current: Int) -> String {
        let pages = Surface.pages
        let index = min(max(current, 0), pages.count - 1)
        return localized("Page %d of %d, %@", index + 1, pages.count, pages[index].title)
    }
}
