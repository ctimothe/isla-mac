import AppKit
import Quartz

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Readable so `IslaIntents` can reach the live panel the way `SettingsPane`
    /// already reaches this delegate. Still only ever set here.
    private(set) var controller: NotchController?

    /// The browser returns from Spotify's consent page through the app's URL
    /// scheme; the account object finishes the token exchange.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "isla" {
            SpotifyAccount.shared.handleCallback(url)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before anything at all — the purge, the panel, the helper, the hot
        // keys: a copy that is not going to stay must not have started a
        // second media helper or taken a key from the copy that is. See
        // `LaunchGuard` for why the newer copy is the one that leaves.
        if let older = LaunchGuard.olderCopy() {
            handOver(to: older)
            return
        }
        // The other half of that: a copy launched after this one asks for the
        // panel and quits. `.deliverImmediately`, because an accessory app is
        // almost never the active one, and a distributed notification held
        // for an inactive app would wait for an activation that may not come.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(showRequested(_:)),
            name: LaunchGuard.showNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        // First, before anything can make a request: earlier builds sent every
        // request through `URLSession.shared`, whose disk cache may still hold
        // a translated text in its URL (audit G-016). Requests go through
        // `PrivateNetwork.session` now, which writes nothing, but the rows
        // already written stay until they are removed — so they are, once.
        PrivateNetwork.purgeLegacyStorage()
        // Before anything reads a setting: the three renamed switches (Charging,
        // Headphones Connecting, New Tracks) have new keys, and a choice made
        // under the old ones is carried across once (redesign 2026-10-15, spec
        // §10). A copy that handed over to an older one above never gets here, so
        // it cannot move a value the running copy has not yet read.
        NotchViewModel.migrateRenamedKeys()
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
        // The panel never activates, so without these it cannot be opened from
        // the keyboard at all — and anything that cannot be opened from the
        // keyboard cannot be reached by assistive tech either.
        //
        // Translation without a window, an app switch, or a permission: the
        // shortcut translates whatever is already on the clipboard, and the
        // service below takes the current selection from any app that offers
        // one — macOS hands the text over itself, so reading a selection asks
        // for no Accessibility access.
        //
        // The lyrics shortcut opens the panel on the Music tab with the lyrics
        // page already up; pressing it again folds the page back to the player.
        //
        // What each is bound to lives in `HotKeyCenter`, which Settings can
        // change while the app runs.
        HotKeyCenter.shared.install([
            .openPanel: { [weak self] in self?.togglePanel() },
            .showClipboard: { [weak self] in self?.controller?.toggleClipboard() },
            // No text is passed on as `nil`, not dropped here: with an image
            // on the clipboard the shortcut used to do nothing at all, which
            // looked like a shortcut that was never registered (F-040). The
            // pane says so now.
            .translateClipboard: { [weak self] in
                self?.controller?.translateCommanded(NSPasteboard.general.string(forType: .string))
            },
            .showLyrics: { [weak self] in self?.controller?.toggleLyrics() },
        ])
        NSApp.servicesProvider = self
        // Nothing, unless the user turned the daily check on in Settings.
        UpdateCheck.shared.startAutomaticIfEnabled()
        if let folder = DebugTrail.updateRehearsal {
            // Loud on purpose: in this mode Update Now takes its release from a
            // folder, not from GitHub, and nobody should forget it is on.
            Log.updates.notice("UPDATE REHEARSAL MODE IS ON: releases come from \(folder.path, privacy: .public), not from GitHub")
        }
        // A failed or refused install belongs to the release it tried: a check
        // that finds Isla current, or a different release, ends it.
        UpdateInstaller.shared.observe(UpdateCheck.shared)
        // A crashed install can leave its staging folder beside the app.
        UpdateInstaller.sweepAtLaunch()

        // One visible moment on a fresh account, and only one. Everything about
        // this app is invisible by design — `.accessory`, no Dock icon, no
        // menu-bar item, no window — which on a first launch is
        // indistinguishable from the app having failed to start. The delay lets
        // the panel finish placing itself before it unfolds.
        //
        // Read here and not inside the controller so that the flag is asked
        // exactly once, at launch: `presentWelcome` is also what a rebuild would
        // reach if it ever wanted the pane back, and a check inside it would make
        // "once" depend on when it happened to be called.
        if !NotchViewModel.hasCompletedFirstRun {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.controller?.presentWelcome()
            }
        }

        // Verification hook, environment-gated: DI_OPEN_LYRICS=1 pins the
        // panel open shortly after launch, so an agent without Accessibility
        // permission — unable to click or reliably synthesize a hover — can
        // still photograph the real, running panel. Normal launches never
        // carry the variable.
        if DebugTrail.openLyrics {
            DebugTrail.note("launch hook armed")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                DebugTrail.note("pinning panel open on the lyrics page")
                // Through the same route the lyrics shortcut takes. This used to be a
                // `togglePanel()` here plus an `onAppear` inside `MediaPane`
                // that flipped its own `@State` — and when that state moved to
                // the view model the `onAppear` went with it, leaving the hook
                // opening the panel on the player and nothing to say so.
                self?.controller?.toggleLyrics()
            }
        }
        // The same, on the player rather than the lyrics page: the artwork, the
        // title and the caption, which is what a skip changes and what has to be
        // watched frame by frame to see whether it changes cleanly.
        if DebugTrail.openPanel {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                DebugTrail.note("pinning panel open on the player")
                self?.togglePanel()
            }
        }
    }

    /// Isla opened again — from Spotlight, Launchpad or Finder — while it is
    /// already running.
    ///
    /// There was no handler, so this did nothing visible, and for an app with
    /// no window, no Dock icon and no menu-bar item nothing visible is
    /// indistinguishable from a launch that failed (F-023). Opening the app
    /// means opening the panel. False, because there is no window for AppKit
    /// to bring forward in its place.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.show()
        return false
    }

    /// A newer copy is handing over; see `handOver(to:)`.
    @objc private func showRequested(_ notification: Notification) {
        controller?.show()
    }

    /// This copy is the newer one: give the island to the copy already
    /// running, and leave.
    ///
    /// Activation goes to that copy first. A copy launched from Finder or
    /// `open` is the active app, and when the active app quits macOS
    /// activates whichever came before it — which the running copy reads as
    /// another app coming to the front, the ⌘-Tab that ends a pin, and the
    /// panel this asked for folded the moment it opened. Its own activation
    /// ends nothing. A copy that was never active passes nothing on, which is
    /// equally harmless.
    private func handOver(to older: NSRunningApplication) {
        older.activate(from: NSRunningApplication.current, options: [])
        DistributedNotificationCenter.default().postNotificationName(
            LaunchGuard.showNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        NSApp.terminate(nil)
    }

    /// Entry point for the "Translate in Isla" service, named in the
    /// bundle's NSServices. macOS passes the selection on a private pasteboard.
    @objc func translateSelection(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>?
    ) {
        // Capped like the hot key's text: a selection can be a whole document.
        controller?.translateCommanded(pasteboard.string(forType: .string))
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        controller?.teardown()
        // The clipboard history is memory-only, so the files behind its pictures
        // end with the session.
        ClipImageSpool.session.removeAll()
        // Explicitly, because a hot key cannot release itself: the Carbon
        // callback needs a lookup table to find the instance, that table holds
        // the only strong reference, and so `deinit` never runs.
        HotKeyCenter.shared.teardown()
    }

    // MARK: - Panel hooks

    /// Settings changed something the pointer machinery holds a copy of.
    func refreshPointerTuning() {
        controller?.refreshPointerTuning()
    }

    /// Settings changed the panel's width, which is geometry.
    func refreshGeometry() {
        controller?.refreshGeometry()
    }

    // MARK: - Quick Look

    /// The Shelf's Quick Look controller. The app delegate is at the end of
    /// every responder chain, which is where the panel looks. See
    /// `ShelfSharing.quickLook`.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        !ShelfSharing.preview.urls.isEmpty
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = ShelfSharing.preview
        panel.delegate = ShelfSharing.preview
        panel.reloadData()
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    /// Private again, and no longer `@objc`: the only callers left are the open
    /// shortcut and the verification hook above. Settings used to reach it through
    /// `NSApp.delegate` for an "Open Panel" row, but that row sat inside the
    /// panel it offered to open, so it could only ever close what you were
    /// reading it in.
    private func togglePanel() {
        controller?.toggle()
    }

}
