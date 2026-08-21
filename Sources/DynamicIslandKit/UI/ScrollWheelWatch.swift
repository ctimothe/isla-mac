import AppKit
import SwiftUI

/// Reports that the pointer's owner turned a wheel — or put two fingers on the
/// trackpad — while the attached view is on screen.
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
private struct ScrollWheelWatch: ViewModifier {
    var onScroll: () -> Void

    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                    // The tail of an inertial flick keeps arriving after the
                    // fingers are gone; it is the same gesture and still counts.
                    // A zero-delta event is not a scroll at all — those arrive
                    // at the start and end of every trackpad phase.
                    if event.scrollingDeltaY != 0 || event.scrollingDeltaX != 0 {
                        onScroll()
                    }
                    return event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}

extension View {
    /// Calls `action` whenever a scroll event reaches this app while the view
    /// is on screen.
    func onScrollWheel(perform action: @escaping () -> Void) -> some View {
        modifier(ScrollWheelWatch(onScroll: action))
    }
}
