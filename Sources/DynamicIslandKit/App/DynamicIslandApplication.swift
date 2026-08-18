import AppKit
import ObjectiveC

public enum DynamicIslandApplication {
    @MainActor public static func run() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        objc_setAssociatedObject(app, "dynamic-island.delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
        app.run()
    }
}
