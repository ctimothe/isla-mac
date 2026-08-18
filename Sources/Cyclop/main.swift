import AppKit

// Top-level code runs on the main thread; make that explicit for the compiler.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    // Keep the delegate alive for the lifetime of the process.
    objc_setAssociatedObject(app, "cyclop.delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
    app.run()
}
