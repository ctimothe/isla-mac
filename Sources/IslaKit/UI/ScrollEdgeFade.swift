import SwiftUI

/// A short fade at each edge of a scroll view that has content beyond it,
/// and at no other edge.
///
/// The Clipboard list cut its fifth row square against Clear, and the Shelf
/// strip at its cap cut its last card with no cue at all (H-017): content
/// read as cropped rather than scrollable, and the header's count disagreed
/// with what could be seen. Scrollers are hidden on purpose in this panel, so
/// the edge itself has to say there is more. Apple's own answer is a scroll
/// edge effect, which is macOS 26 only and shaped for toolbars; the app runs
/// on 15, and two looks for one meaning are worse than one, so this is the
/// same idea drawn as a mask.
///
/// The fade is decided per edge from the scroll geometry, never painted on
/// both ends by default: a list that fits draws no fade, and the first row is
/// never dimmed at rest. The decision is a value that changes only when an
/// edge starts or stops being clipped, so scrolling a long list re-renders
/// the mask twice, not once per frame, and an idle list costs nothing.
///
/// One primitive for every list that clips. It used to be on course to be
/// three — one in Theme, one here, one in Settings — wrapping the same two
/// scroll views twice; anything else that scrolls under a hard edge applies
/// `.scrollEdgeFade(...)` rather than mixing its own gradient.
struct ScrollEdgeFade: ViewModifier {
    let axis: Axis
    let length: CGFloat

    @State private var edges: Edge.Set = []

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Edge.Set.self) { geometry in
                let visible = geometry.visibleRect
                switch axis {
                case .vertical:
                    return Self.edges(
                        offset: visible.minY, content: geometry.contentSize.height,
                        container: visible.height
                    )
                case .horizontal:
                    return Self.edges(
                        offset: visible.minX, content: geometry.contentSize.width,
                        container: visible.width, axis: .horizontal
                    )
                }
            } action: { _, clipped in
                edges = clipped
            }
            // Always masked, opaque where nothing is clipped. Adding and
            // removing the mask with the edges would change the scroll
            // view's identity and throw away its offset mid-scroll.
            .mask {
                GeometryReader { geo in
                    LinearGradient(
                        stops: Self.stops(
                            viewport: axis == .vertical ? geo.size.height : geo.size.width,
                            fade: length, edges: edges
                        ),
                        startPoint: axis == .vertical ? .top : .leading,
                        endPoint: axis == .vertical ? .bottom : .trailing
                    )
                }
            }
    }

    /// Half a point of slack either way. Layout rounding left lists that
    /// fit a fraction of a point "taller" than their viewport, and the
    /// elastic bounce past either end puts the offset briefly outside the
    /// content; neither is content hidden behind an edge.
    private static let slack: CGFloat = 0.5

    /// The edges with content beyond them. `offset` is where the visible
    /// window starts along the axis, in content coordinates; `content` the
    /// scrolled content's length; `container` the window's. Vertical edges
    /// are `.top`/`.bottom`, horizontal ones `.leading`/`.trailing`.
    static func edges(
        offset: CGFloat, content: CGFloat, container: CGFloat, axis: Axis = .vertical
    ) -> Edge.Set {
        var clipped: Edge.Set = []
        if offset > slack {
            clipped.insert(axis == .vertical ? .top : .leading)
        }
        if offset + container < content - slack {
            clipped.insert(axis == .vertical ? .bottom : .trailing)
        }
        return clipped
    }

    /// The mask along the axis: transparent at a clipped edge, ramping to
    /// opaque over `fade` points, opaque everywhere else. The ramp ends at
    /// the clip itself, so the last visible sliver of a cut row is the
    /// faintest thing drawn rather than a square edge. The four stops sit
    /// in the same places whichever edges are clipped, and only their
    /// colours change. On a viewport shorter than two ramps they meet in
    /// the middle instead of crossing.
    static func stops(viewport: CGFloat, fade: CGFloat, edges: Edge.Set) -> [Gradient.Stop] {
        let ramp = max(0, min(fade, viewport / 2))
        let near = viewport > 0 ? ramp / viewport : 0
        let far = viewport > 0 ? (viewport - ramp) / viewport : 1
        let start: Color = edges.contains(.top) || edges.contains(.leading) ? .clear : .black
        let end: Color = edges.contains(.bottom) || edges.contains(.trailing) ? .clear : .black
        return [
            .init(color: start, location: 0),
            .init(color: .black, location: near),
            .init(color: .black, location: far),
            .init(color: end, location: 1),
        ]
    }
}

extension View {
    /// Fades the edges of this scroll view that have more content beyond
    /// them. Apply it to the `ScrollView` itself, with the axis it scrolls.
    func scrollEdgeFade(_ axis: Axis = .vertical, length: CGFloat = Theme.scrollFadeLength) -> some View {
        modifier(ScrollEdgeFade(axis: axis, length: length))
    }
}
