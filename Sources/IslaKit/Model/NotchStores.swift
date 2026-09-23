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
    let lyrics: LyricsStore
    let localLyricsLibrary: LocalLyricsLibrary
    let lyricsCoordinator: LyricsCoordinator
    /// Shared by every pane that shows something worth not showing.
    let privacy = PrivacyMode()
    /// The charger and headphones, for the island's moments without music.
    let ambient = AmbientWatch()

    /// Raised when a screenshot arrives on its own — copied elsewhere, or
    /// synced from a phone. The panel's view model wires itself to this;
    /// the store that produces it outlives any single panel.
    var onScreenshot: ((URL) -> Void)?

    private var started = false

    init(
        lyricsEnabled: (() -> Bool)? = nil,
        localLyricsDirectory: URL = AppPaths.live.supportDirectory
    ) {
        // Import a listener's old local override and timing correction before
        // the retired cache helper gets a chance to prune its cache files.
        // The local library is now the coordinator's only lyric authority.
        let library = LocalLyricsLibrary(directory: localLyricsDirectory)
        localLyricsLibrary = library
        lyrics = LyricsStore(offsetsDirectory: library.storageDirectory)
        lyricsCoordinator = LyricsCoordinator(
            media: media,
            library: library,
            isEnabled: lyricsEnabled ?? { NotchViewModel.showLyricsEnabled },
            isOnlineEnabled: { NotchViewModel.onlineLyricsEnabled },
            presentation: lyrics
        )
    }

    func clearImportedLyrics() {
        localLyricsLibrary.clearImportedDocuments()
    }

    func clearBindingsAndTimingCorrections() {
        localLyricsLibrary.clearBindings()
        lyrics.clearLocalTrackOffsets()
    }

    func start() {
        guard !started else { return }
        started = true
        // Baselines the recording pickup: the scan offers what finished after
        // this stamp, so stamping at the first shelf open instead would miss a
        // recording made between install and that open. Stamped once — the key
        // existing is what makes it once — and never moved again.
        if UserDefaults.standard.object(forKey: RecordingPickup.sinceKey) == nil {
            UserDefaults.standard.set(Date(), forKey: RecordingPickup.sinceKey)
        }
        media.start()
        lyricsCoordinator.start()
        localLyricsLibrary.startWatchingFolders()
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
        clipboard.recordsHistory = { NotchViewModel.clipboardHistoryEnabled }
        clipboard.onImage = { [weak self] png in
            guard let self else { return }
            self.screenshotVault.save(png) { [weak self] url in
                guard let self, let url else { return }
                self.shelf.add([url])
                self.onScreenshot?(url)
            }
        }
        // A captured recording lands on the shelf the way a screenshot does.
        // Copied bytes go through the vault — they exist only in memory, like
        // a screenshot to the clipboard — and answer to the same capture
        // switch, which is what keeps a disk-filling copy off the disk. A
        // copied file is already on disk, so the shelf references it directly
        // and no switch is asked: nothing is written, only remembered.
        clipboard.onMovieData = { [weak self] data, ext in
            guard let self else { return }
            self.screenshotVault.saveMovie(data, fileExtension: ext) { [weak self] url in
                guard let self, let url else { return }
                self.shelf.add([url])
                self.onScreenshot?(url)
            }
        }
        clipboard.onMovieFile = { [weak self] url in
            guard let self else { return }
            self.shelf.add([url])
            self.onScreenshot?(url)
        }
        refreshClipboardPolling()
        ambient.start()
    }

    /// The pasteboard is read only while something wants what is on it:
    /// history, or clipboard screenshots for the Shelf. With both off,
    /// nothing polls at all.
    static func clipboardShouldPoll(history: Bool, images: Bool) -> Bool {
        history || images
    }

    func refreshClipboardPolling() {
        if Self.clipboardShouldPoll(
            history: NotchViewModel.clipboardHistoryEnabled,
            images: NotchViewModel.saveClipboardImagesEnabled
        ) {
            clipboard.start()
        } else {
            clipboard.stop()
        }
    }

    func stop() {
        guard started else { return }
        started = false
        lyricsCoordinator.stop()
        localLyricsLibrary.stopWatchingFolders()
        media.stop()
        clipboard.stop()
        ambient.stop()
    }

    /// Paused while nobody can see or reach the panel — the display asleep, or
    /// the Mac locked with the lock-screen card switched off. Everything here
    /// polls something, and none of it can change while the screen is dark.
    /// Quietens what a dark or shielded screen has no use for.
    ///
    /// - Parameter keepingMediaRunning: true while the lock card is on screen.
    ///   The card shows a scrubber and a moving lyric, and both are driven by
    ///   the position ticker that `setActive(false)` stops. `screenLocked()`
    ///   activated media and then called this five lines later, which switched
    ///   it straight back off: the clock froze the moment the Mac locked, the
    ///   bar stopped, and the lyric stood still on whichever line it had
    ///   reached. Passed rather than inferred from call order, because order is
    ///   exactly what went wrong.
    func suspendForIdleScreen(keepingMediaRunning: Bool = false) {
        clipboard.stop()
        if !keepingMediaRunning { media.setActive(false) }
    }

    func resumeFromIdleScreen() {
        refreshClipboardPolling()
        // A wake is the likeliest moment for a failed route to work again. The
        // helper can lose a race with a waking MediaRemote, and a user who
        // cleared the download quarantine has usually put the Mac to sleep
        // since. Costs nothing while Now Playing is healthy, and a refused
        // load waits for the user to ask (see `retryNowPlaying`).
        media.retryNowPlaying(userAsked: false)
    }
}
