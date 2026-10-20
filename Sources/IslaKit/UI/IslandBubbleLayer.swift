import AppKit
import SwiftUI

/// The Shelf waiting beside the island (spec §19.7), as a layer of its own.
///
/// It was drawn by `NotchContentView` beside the island's shell. The island's
/// content is cut by the outline's mask now (`IslandOutlineHost`), and the
/// bubble lives 16 pt outside the outline: under that mask it would not be
/// there. So it is its own small SwiftUI tree in a hosting view above the
/// island's, with the same animations it always had — it arrives and leaves as
/// compact content does, and follows the island's edge on the outline's spring
/// as the island changes width. The rest of this window-sized layer is empty
/// and takes no clicks; the bubble's own are cut by `NotchRootView.bubbleRect`
/// and, here, by `IslandBubbleHostingView.hitTest`.
struct IslandBubbleLayer: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject private var appearance = SystemAppearance.shared

    private var reduceMotion: Bool { appearance.reduceMotion }
    private var size: CGSize { vm.bodySize }

    var body: some View {
        ZStack(alignment: .top) {
            if let count = vm.bubbleCount {
                IslandBubble(
                    count: count, height: size.height,
                    outlineHeight: NotchContentView.clearingCutout(
                        size, notchHeight: vm.geometry.notchSize.height, isPhysical: vm.geometry.isPhysical
                    ).height,
                    increaseContrast: appearance.increaseContrast
                ) {
                    vm.onBubbleClick?()
                }
                .offset(x: IslandBubbleLayout.centreOffset(islandWidth: size.width, count: count))
                .transition(Theme.compactArrival(reduceMotion: reduceMotion))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(Theme.island(reduceMotion: reduceMotion), value: vm.bubbleCount != nil)
        .animation(Theme.island(reduceMotion: reduceMotion), value: size.width)
        // A tenth file widens it by a digit, on the same spring.
        .animation(Theme.island(reduceMotion: reduceMotion), value: IslandBubbleLayout.digits(vm.bubbleCount ?? 0))
    }
}

/// The bubble's hosting view: a whole-window transparent layer that answers
/// only where the bubble is. A hosting view claims every point in its bounds,
/// and this one sits above the island's, so left alone it would take the
/// island's clicks.
final class IslandBubbleHostingView: NSHostingView<IslandBubbleLayer> {
    /// A window-sized view in the key-view loop would take the focus a Tab
    /// leaves Translate's field with; the bubble is a button the pointer and
    /// VoiceOver press, not a stop for the keyboard.
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let root = superview as? NotchRootView, root.bubbleRect.contains(point) else { return nil }
        return super.hitTest(point)
    }
}
