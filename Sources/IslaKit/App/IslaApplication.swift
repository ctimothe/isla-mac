import AppKit
import ObjectiveC

public enum IslaApplication {
    /// Always, and with nothing to switch it.
    ///
    /// There is no Dock icon, no status-bar item and no window: the island at
    /// the notch is the whole app, and its Settings tab carries Open Panel,
    /// About and Quit. A `.regular` policy would put an icon in the Dock for an
    /// app with no window to show, and a status item would be a second front
    /// door to what the panel already does.
    static let activationPolicy: NSApplication.ActivationPolicy = .accessory

    @MainActor public static func run() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(activationPolicy)
        objc_setAssociatedObject(app, "dynamic-island.delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
        app.run()
    }
}
