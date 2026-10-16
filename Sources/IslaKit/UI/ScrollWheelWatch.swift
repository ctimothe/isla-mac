import AppKit
import SwiftUI

/// Reports that the pointer's owner turned a wheel — or put two fingers on the
/// trackpad — while the attached view is on screen, as a `ScrollSample` (the
/// distances and the two phases, no `NSEvent`) and whether the pointer was over
/// the view. What it means is the caller's to decide (`LyricFollowGate`).
///
/// A scroll view can say where it ended up, but not *who* put it there: our own
/// follow-the-song animation and a hand reading ahead both arrive as the same
/// change of offset, and a stage that mistakes one for the other either fights
/// the reader or never follows the song at all. The event stream has no such
/// ambiguity — a scroll wheel event exists only because somebody made one.
///
/// A local monitor rather than an `NSView` override: the panel never becomes
/// key, and a view inserted purely to catch wheel events would have to sit in
/// the hit-test path of the lyric buttons underneath it to receive them, where
/// it would swallow the clicks that are the whole point of the lines being
/// buttons. The monitor is installed with the view and removed with it, so it
/// listens only while the surface that cares is visible.
///
/// **Where the pointer is** is read from the event, not from hover state. The
/// monitor used to report every wheel event the app received, so a swipe over
/// the rail or the header stopped a stage it was nowhere near. `onHover` hangs
/// on tracking areas, which a non-activating panel that is not key and an
/// inactive app deliver unreliably; the event's own `locationInWindow` is always
/// there and is the pointer, so an empty anchor view laid behind the content
/// (the way the header menus find their button) says whether the event landed
/// on this view's frame. The same trick `SecondaryClick.lands` plays.
private struct ScrollWheelWatch: ViewModifier {
    var onScroll: (ScrollSample, _ overView: Bool) -> Void

    @State private var monitor: Any?
    /// The anchor behind the content, held in a box so the monitor's closure —
    /// installed once — always reads the current view.
    @State private var anchor = AnchorBox()

    func body(content: Content) -> some View {
        content
            .background(ScrollAnchor(box: anchor))
            .onAppear {
                guard monitor == nil else { return }
                let box = anchor
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                    // The tail of an inertial flick keeps arriving after the
                    // fingers are gone; it is the same gesture and still counts.
                    // A zero-delta event is not a scroll at all — those arrive
                    // at the start and end of every trackpad phase — but the
                    // gate wants to see them, because `began` opens a gesture.
                    let sample = ScrollSample(event)
                    let over = MainActor.assumeIsolated { ScrollAnchor.lands(event, in: box.view) }
                    MainActor.assumeIsolated { onScroll(sample, over) }
                    return event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}

private final class AnchorBox {
    weak var view: NSView?
}

private struct ScrollAnchor: NSViewRepresentable {
    let box: AnchorBox

    func makeNSView(context: Context) -> NSView {
        let view = FlippedAnchorView()
        box.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        box.view = nsView
    }

    /// Whether `event` landed inside `view`, in `view`'s own window.
    @MainActor
    static func lands(_ event: NSEvent, in view: NSView?) -> Bool {
        guard let view, let window = view.window, event.window === window else { return false }
        return view.bounds.contains(view.convert(event.locationInWindow, from: nil))
    }
}

extension ScrollSample.Phase {
    /// One `NSEvent.Phase` field's meaning. The option set can hold several
    /// flags; the order is the order a gesture runs them in.
    init(_ phase: NSEvent.Phase) {
        if phase.contains(.cancelled) { self = .cancelled }
        else if phase.contains(.ended) { self = .ended }
        else if phase.contains(.began) { self = .began }
        else if phase.contains(.changed) { self = .changed }
        else if phase.contains(.mayBegin) { self = .mayBegin }
        else { self = .none }
    }
}

extension ScrollSample {
    /// A trackpad reports points; a notched wheel reports lines, which are
    /// scaled to points by `LyricFollowGate.wheelLinePoints`.
    init(_ event: NSEvent) {
        let scale = event.hasPreciseScrollingDeltas ? 1 : LyricFollowGate.wheelLinePoints
        self.init(
            deltaX: event.scrollingDeltaX * scale, deltaY: event.scrollingDeltaY * scale,
            phase: Phase(event.phase), momentumPhase: Phase(event.momentumPhase)
        )
    }
}

extension View {
    /// Calls `action` with every scroll event this app receives while the view
    /// is on screen, and whether the pointer was over this view when it
    /// arrived. The view decides what a scroll over it means.
    func onScrollWheel(perform action: @escaping (ScrollSample, _ overView: Bool) -> Void) -> some View {
        modifier(ScrollWheelWatch(onScroll: action))
    }
}
