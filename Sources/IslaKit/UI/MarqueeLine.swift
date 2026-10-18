import SwiftUI

/// A line too long for its room scrolls, now and then, to show the rest of
/// itself: the player's "Title – Artist" (owner, 2026-10-18 — "Lover, You
/// Should've Come Over" was cut to "Lover, You Should've Come…" and Jeff
/// Buckley was not there at all).
///
/// The pattern is the one the iPod's Now Playing screen, tvOS's marquee text
/// style and car displays share: a line that fits is drawn as it is. One that
/// does not rests at its start, its far end faded rather than cut by an
/// ellipsis, then travels left at an even reading pace until a second copy, a
/// gap behind it, stands exactly where the first began, and rests again. The
/// jump back is to an identical picture, so the loop has no seam. While it
/// travels the near end fades too, so letters slide under both edges instead
/// of being cut.
///
/// It costs frames only while it travels: a rest is a sleep, not an animation.
/// It never moves under Reduce Motion or while its page is not the one on
/// screen (`isActive` false); it then truncates with an ellipsis as it always
/// did. The whole line is the caller's tooltip and accessibility label either
/// way, and the second copy is hidden from VoiceOver.
struct MarqueeLine<Content: View>: View {
    let room: CGFloat
    let isActive: Bool
    /// What the line says. A new value starts over from rest.
    let text: String
    @ViewBuilder let content: () -> Content

    /// How long the line rests at its start before each pass.
    static var rest: TimeInterval { 2.5 }
    /// The reading pace, points a second.
    static var speed: CGFloat { 30 }
    /// The space between the line and the copy that follows it.
    static var gap: CGFloat { 32 }
    /// The fade at each end.
    static var fade: CGFloat { 14 }

    /// Whether a line `contentWidth` wide scrolls in `room`; half a point of
    /// slack, so a line that measures a rounding over its room is not set
    /// moving for nothing.
    static func overflows(contentWidth: CGFloat, room: CGFloat) -> Bool { contentWidth > room + 0.5 }
    /// One pass: the line and its gap, so the copy lands where the line began.
    static func travel(contentWidth: CGFloat) -> CGFloat { contentWidth + gap }
    static func travelTime(contentWidth: CGFloat) -> TimeInterval { Double(travel(contentWidth: contentWidth) / speed) }

    @State private var contentWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var travelling = false

    private struct Run: Equatable {
        var text: String
        var scrolls: Bool
        var width: CGFloat
    }

    var body: some View {
        let scrolls = isActive && Self.overflows(contentWidth: contentWidth, room: room)
        ZStack(alignment: .leading) {
            if scrolls {
                HStack(spacing: Self.gap) {
                    content().fixedSize()
                    content().fixedSize().accessibilityHidden(true)
                }
                .offset(x: offset)
            } else {
                content()
            }
        }
        .frame(width: room, alignment: .leading)
        // The fades cut the sides; above and below, the mask reaches past the
        // line so an accent or a descender is never clipped.
        .mask {
            if scrolls { fadeMask.padding(.vertical, -6) } else { Color.black.padding(.vertical, -6) }
        }
        .background(alignment: .leading) {
            content()
                .fixedSize()
                .hidden()
                .accessibilityHidden(true)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        }
        .task(id: Run(text: text, scrolls: scrolls, width: contentWidth)) { await run(scrolls: scrolls) }
    }

    /// The far end always fades while the line is longer than its room; the
    /// near end only while it travels.
    private var fadeMask: some View {
        HStack(spacing: 0) {
            ZStack {
                Color.black.opacity(travelling ? 0 : 1)
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .opacity(travelling ? 1 : 0)
            }
            .frame(width: Self.fade)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: Self.fade)
        }
    }

    private func run(scrolls: Bool) async {
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            offset = 0
            travelling = false
        }
        guard scrolls else { return }
        let distance = Self.travel(contentWidth: contentWidth)
        let time = Self.travelTime(contentWidth: contentWidth)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.rest))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { travelling = true }
            withAnimation(.linear(duration: time)) { offset = -distance }
            try? await Task.sleep(for: .seconds(time))
            guard !Task.isCancelled else { return }
            withTransaction(still) { offset = 0 }
            withAnimation(.easeOut(duration: 0.2)) { travelling = false }
        }
    }
}
