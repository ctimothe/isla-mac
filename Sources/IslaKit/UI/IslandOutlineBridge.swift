import SwiftUI

/// Carries the SwiftUI shell's idea of the outline to the layers that draw it
/// (`IslandOutlineHost`).
///
/// It draws nothing and has no size. What it has is the one thing a SwiftUI
/// shape cannot give a Core Animation layer: the transaction of each change.
/// `updateNSView` runs once per change of the state it is handed — not once
/// per frame, because a representable's inputs are not animated — with the
/// animation that change carries in `context.transaction`, resolved by the
/// same `.animation(_:value:)` modifiers and `withAnimation` calls that decide
/// every other motion in the shell. Placed among the shapes it replaces, it is
/// under the same modifiers they were, so it is given the same curve.
struct IslandOutlineBridge: NSViewRepresentable {
    let host: IslandOutlineHost
    let state: OutlineState

    func makeCoordinator() -> Coordinator { Coordinator(host: host) }

    func makeNSView(context: Context) -> NSView {
        // The first thing the island is: where it already is, never a motion
        // from nowhere (the shell is rebuilt on an unlock, and a cut is what
        // the lock transition promises).
        host.owner = context.coordinator
        host.apply(state, curve: .instant)
        let view = NSView(frame: .zero)
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        host.apply(
            state,
            curve: OutlineCurve.of(
                context.transaction.animation, disablesAnimations: context.transaction.disablesAnimations
            )
        )
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        // The shell leaves when the Mac locks, and the lock screen draws its
        // own pill; an outline left on the layers would sit under it. Only the
        // bridge that last asked takes it away: a shell rebuilt before the old
        // one is torn down has already put its own on the layers.
        guard coordinator.host.owner === coordinator else { return }
        coordinator.host.hide()
        coordinator.host.owner = nil
    }

    @MainActor
    final class Coordinator {
        let host: IslandOutlineHost
        init(host: IslandOutlineHost) { self.host = host }
    }
}
