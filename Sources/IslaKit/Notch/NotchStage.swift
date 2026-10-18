import AppKit
import SwiftUI

/// The island's view stack, built in one place: the root view the panel owns
/// and the hosting view that draws the SwiftUI island inside it.
///
/// The controller builds its panel from this and so does the hitch lab
/// (`OutlineHitchLab`), which is the point of it being a function and not a
/// paragraph of `NotchController.build`: a measurement of the island's morphs
/// is only worth anything if it measures the stack the app ships, and two
/// copies of this wiring would drift the first time one of them grew a layer.
@MainActor
enum NotchStage {
    struct Stack {
        let root: NotchRootView
        let hosting: NSHostingView<NotchContentView>
    }

    static func make(viewModel vm: NotchViewModel, windowSize: CGSize) -> Stack {
        let root = NotchRootView(frame: CGRect(origin: .zero, size: windowSize))
        root.autoresizingMask = [.width, .height]

        let hosting = NSHostingView(rootView: NotchContentView(vm: vm))
        // The pages settle on this view's display link, frame by frame
        // (§19.16), rather than on a timer that drifts against the display.
        (vm.pageTravel.clock as? DisplayPageClock)?.view = hosting
        hosting.frame = root.bounds
        hosting.autoresizingMask = [.width, .height]
        if #available(macOS 14.0, *) {
            hosting.sizingOptions = []
        }
        root.addSubview(hosting)
        return Stack(root: root, hosting: hosting)
    }
}
