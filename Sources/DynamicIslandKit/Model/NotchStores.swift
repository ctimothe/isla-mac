import Foundation

/// The stores that belong to the session rather than to the panel.
///
/// Every one of these is independent of which display the notch is on, and the
/// panel is rebuilt whenever that changes — plugging in a monitor, changing
/// resolution, closing the lid. Building them inside the view model meant a
/// rebuild silently threw away everything they held: up to forty clipboard
/// entries that live only in memory, a half-typed translation, and, less
/// visibly, a running media feed whose observer registrations were never
/// reclaimed. None of that is a decision the user made by docking a laptop.
///
/// Owned by `NotchController`, started once at install and stopped once at
/// teardown; each `NotchViewModel` borrows the same instances.
@MainActor
final class NotchStores {
    let media = MediaController()
    let shelf = ShelfStore()
    let clipboard = ClipboardStore()
    let screenshotVault = ScreenshotVault()
    let translator = Translator()
    let lyrics = LyricsStore()
    /// Shared by every pane that shows something worth not showing.
    let privacy = PrivacyMode()

    /// Raised when a screenshot arrives on its own — copied elsewhere, or
    /// synced from a phone. The panel's view model wires itself to this;
    /// the store that produces it outlives any single panel.
    var onScreenshot: ((URL) -> Void)?

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        media.start()
        shelf.load()
        // Drop folders from previous sessions, once, off the main thread.
        DispatchQueue.global(qos: .utility).async { AppPaths.pruneDropInbox() }

        // Screenshots reach the shelf through here whether they were taken on
        // this Mac or on a phone: a copy made on the phone arrives in the same
        // pasteboard, carried over by Continuity.
        //
        // The switch is asked by the store before it touches image data, not
        // here after the fact: turned off, a copied picture used to be encoded
        // to PNG in full just to be dropped on this doorstep — pure heat on
        // exactly the machines whose owners turned the feature off.
        clipboard.wantsImages = { NotchViewModel.saveClipboardImagesEnabled }
        clipboard.onImage = { [weak self] png in
            guard let self else { return }
            self.screenshotVault.save(png) { [weak self] url in
                guard let self, let url else { return }
                self.shelf.add([url])
                self.onScreenshot?(url)
            }
        }
        clipboard.start()
    }

    func stop() {
        guard started else { return }
        started = false
        media.stop()
        clipboard.stop()
        // Whatever was typed makes it to disk even when quitting mid-thought.
    }

    /// Paused while nobody can see or reach the panel — the display asleep, or
    /// the Mac locked with the lock-screen card switched off. Everything here
    /// polls something, and none of it can change while the screen is dark.
    func suspendForIdleScreen() {
        clipboard.stop()
        media.setActive(false)
    }

    func resumeFromIdleScreen() {
        clipboard.start()
    }
}
