import AppKit
import SwiftUI

/// Hands every scroll event the app receives to the pages while the open
/// island shows one (spec §19.16), and keeps the ones they take.
///
/// A local monitor, as `ScrollWheelWatch` is and for its reasons: the panel
/// never becomes key, and a view laid over the pages to catch the wheel would
/// sit in the hit-test path of every control on them. Unlike that watch it can
/// keep an event: a swipe the pages took must not also scroll Clipboard's
/// list or the tray's strip under it, nor glide them once the fingers lift.
///
/// Installed only while a page is on screen, and removed with the pages. Where
/// the pointer is comes from the event itself, against an empty anchor view
/// behind the pages, as the watch reads it: tracking areas are unreliable on a
/// panel that is not key.
private struct PageSwipeMonitor: ViewModifier {
    let enabled: Bool
    let handle: (PageScroll, _ overPages: Bool) -> Bool

    @State private var anchor = StagePointer()
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .background(ScrollAnchor(box: anchor))
            .onAppear { follow(enabled) }
            .onChange(of: enabled) { _, enabled in follow(enabled) }
            .onDisappear { remove() }
    }

    private func follow(_ enabled: Bool) {
        if enabled { install() } else { remove() }
    }

    private func install() {
        guard monitor == nil else { return }
        let box = anchor
        let handle = handle
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            let scroll = PageScroll(event)
            let kept = MainActor.assumeIsolated { () -> Bool in
                handle(scroll, ScrollAnchor.lands(event, in: box.view))
            }
            return kept ? nil : event
        }
    }

    private func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

extension PageScroll {
    init(_ event: NSEvent) {
        self.init(
            deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
            phase: ScrollSample.Phase(event.phase), momentumPhase: ScrollSample.Phase(event.momentumPhase),
            precise: event.hasPreciseScrollingDeltas, time: event.timestamp
        )
    }
}

extension View {
    /// Offers every scroll event to `handle` while `enabled`, with whether
    /// the pointer is over this view; an event it returns true for goes no
    /// further.
    func onPageSwipe(enabled: Bool, handle: @escaping (PageScroll, _ overPages: Bool) -> Bool) -> some View {
        modifier(PageSwipeMonitor(enabled: enabled, handle: handle))
    }
}
