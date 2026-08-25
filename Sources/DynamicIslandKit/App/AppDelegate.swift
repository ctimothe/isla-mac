import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchController?
    private var hotKey: GlobalHotKey?
    private var translateHotKey: GlobalHotKey?

    /// The browser returns from Spotify's consent page through the app's URL
    /// scheme; the account object finishes the token exchange.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "dynamicisland" {
            SpotifyAccount.shared.handleCallback(url)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = NotchController()
        controller?.install()
        // Built here rather than wherever a view first mentions it.
        //
        // Creating it reads the keychain, and that read can put up the system's
        // password prompt. Left lazy, the first thing to mention `shared` was
        // the lock-screen card — so the prompt arrived *on the lock screen*,
        // over the password field, which is both the worst moment to ask and
        // the moment somebody is least able to make sense of the question. At
        // launch it is at least attached to the user having just started the
        // app. Costs nothing when no account is connected: the initializer
        // returns without touching the keychain in that case.
        _ = SpotifyAccount.shared
        // The panel never activates, so without this it cannot be opened from
        // the keyboard at all — and anything that cannot be opened from the
        // keyboard cannot be reached by assistive tech either.
        hotKey = GlobalHotKey(
            keyCode: GlobalHotKey.defaultKeyCode,
            modifiers: GlobalHotKey.defaultModifiers
        ) { [weak self] in
            self?.togglePanel()
        }

        // Translation without a window, an app switch, or a permission.
        //
        // Two routes, because they suit different moments and neither costs
        // anything. The shortcut translates whatever is already on the
        // clipboard, which needs no setup at all. The service takes the
        // current selection from any app that offers one — macOS hands the
        // text over itself, so reading a selection asks for no Accessibility
        // access, which is what every other route to it would have cost.
        translateHotKey = GlobalHotKey(
            keyCode: GlobalHotKey.translateKeyCode,
            modifiers: GlobalHotKey.defaultModifiers
        ) { [weak self] in
            guard let text = NSPasteboard.general.string(forType: .string) else { return }
            self?.controller?.translate(text)
        }
        NSApp.servicesProvider = self

        // Verification hook, environment-gated: DI_OPEN_LYRICS=1 pins the
        // panel open shortly after launch, so an agent without Accessibility
        // permission — unable to click or reliably synthesize a hover — can
        // still photograph the real, running panel. Normal launches never
        // carry the variable.
        if ProcessInfo.processInfo.environment["DI_OPEN_LYRICS"] == "1" {
            DebugTrail.note("launch hook armed")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                DebugTrail.note("pinning panel open")
                self?.togglePanel()
            }
        }
    }

    /// Entry point for the "Translate in Dynamic Island" service, named in the
    /// bundle's NSServices. macOS passes the selection on a private pasteboard.
    @objc func translateSelection(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>?
    ) {
        guard let text = pasteboard.string(forType: .string) else { return }
        controller?.translate(text)
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.teardown()
        // Explicitly, because a hot key cannot release itself: the Carbon
        // callback needs a lookup table to find the instance, that table holds
        // the only strong reference, and so `deinit` never runs. Nothing here
        // is load-bearing at quit — the process is going away — but it is the
        // one call site that keeps the teardown path real instead of dead code
        // waiting for the first rebinding to expose it.
        hotKey?.unregister()
        translateHotKey?.unregister()
        hotKey = nil
        translateHotKey = nil
    }

    // MARK: - Menu bar item

    /// Settings changed something the pointer machinery holds a copy of.
    func refreshPointerTuning() {
        controller?.refreshPointerTuning()
    }

    /// Settings changed the panel's width, which is geometry.
    func refreshGeometry() {
        controller?.refreshGeometry()
    }

    /// Not `private`: the Settings tab's own "Open Panel" row calls this
    /// through `NSApp.delegate` rather than reaching for `NotchController`
    /// itself. It is the only route left — there is no menu and no window.
    @objc func togglePanel() {
        controller?.toggle()
    }

}

extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }
}
