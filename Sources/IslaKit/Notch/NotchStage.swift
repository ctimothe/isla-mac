import AppKit
import SwiftUI

/// The island's view stack, built in one place: the root view the panel owns,
/// the layers that draw the island's outline, and the hosting views that draw
/// the SwiftUI island and its Shelf bubble.
///
/// The controller builds its panel from this and so does the hitch lab
/// (`OutlineHitchLab`), which is the point of it being a function and not a
/// paragraph of `NotchController.build`: a measurement of the island's morphs
/// is only worth anything if it measures the stack the app ships, and two
/// copies of this wiring would drift the first time one of them grew a layer.
///
/// Back to front:
/// 1. the outline's fill and shadow (`IslandOutlineHost.backdrop`),
/// 2. the island (`hosting`): the SwiftUI content, its layer cut by the outline,
/// 3. the Shelf's bubble (`bubble`): beside the island, so outside that cut,
/// 4. the outline's line (`IslandOutlineHost.overlay`), over the content so
///    nothing lies over the border.
@MainActor
enum NotchStage {
    struct Stack {
        let root: NotchRootView
        let hosting: NSHostingView<NotchContentView>
        let bubble: IslandBubbleHostingView
        let outline: IslandOutlineHost
    }

    static func make(viewModel vm: NotchViewModel, windowSize: CGSize) -> Stack {
        let root = NotchRootView(frame: CGRect(origin: .zero, size: windowSize))
        root.autoresizingMask = [.width, .height]

        let outline = IslandOutlineHost(windowSize: windowSize)
        let hosting = NSHostingView(rootView: NotchContentView(vm: vm, outline: outline))
        // The pages settle on this view's display link, frame by frame
        // (§19.16), rather than on a timer that drifts against the display.
        (vm.pageTravel.clock as? DisplayPageClock)?.view = hosting
        hosting.frame = root.bounds
        hosting.autoresizingMask = [.width, .height]
        hosting.sizingOptions = []
        outline.attach(content: hosting)

        let bubble = IslandBubbleHostingView(rootView: IslandBubbleLayer(vm: vm))
        bubble.frame = root.bounds
        bubble.autoresizingMask = [.width, .height]
        bubble.sizingOptions = []
        outline.attach(bubble: bubble)

        root.addSubview(outline.backdrop)
        root.addSubview(hosting)
        root.addSubview(bubble)
        root.addSubview(outline.overlay)
        root.islandHosting = hosting
        return Stack(root: root, hosting: hosting, bubble: bubble, outline: outline)
    }
}
