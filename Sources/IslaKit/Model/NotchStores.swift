import Combine
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
    let shelf: ShelfStore
    /// Takes the files a drag only promised. Here rather than in the panel's
    /// root view, which a display change rebuilds mid-transfer (G-025).
    let promises: PromisedDropInbox
    let clipboard: ClipboardStore
    let screenshotVault: ScreenshotVault
    let translator: Translator
    let lyrics: LyricsStore
    let localLyricsLibrary: LocalLyricsLibrary
    let lyricsCoordinator: LyricsCoordinator
    /// A translated line under each lyric line (spec §5.3). Session-owned like the
    /// lyrics it follows: the lock card (R2) reads it with the panel closed, and
    /// a panel rebuilt for a new display must not lose what it has translated.
    let lyricTranslation: LyricTranslation
    /// Shared by every pane that shows something worth not showing.
    let privacy: PrivacyMode
    /// The charger and headphones, for the island's moments without music.
    let ambient = AmbientWatch()
    /// The volume and brightness pop-up's keys (spec §12). Session-owned: a
    /// panel rebuilt for a new display must not end the tap and begin it again
    /// — a person pressing volume while a monitor is plugged in would hear the
    /// system's own pop-up for the gap. Built inert: nothing is tapped until
    /// the setting and the permission are both true and `refresh()` has run.
    let hud: MediaKeyHUD

    /// Raised when a screenshot arrives on its own — copied elsewhere, or
    /// synced from a phone. The panel's view model wires itself to this;
    /// the store that produces it outlives any single panel.
    var onScreenshot: ((URL) -> Void)?

    /// The one door a capture Isla collected by itself comes through — a
    /// copied screenshot or recording the vault saved, a recording copied as
    /// a file. Marked collected, so it shows the Shelf for a moment rather
    /// than keeping it on the island (spec §19.1, amended 2026-10-17), and
    /// announced, so the island can show that moment.
    func collect(_ url: URL) {
        shelf.add([url], origin: .collected)
        onScreenshot?(url)
    }

    private var started = false
    private var cancellables = Set<AnyCancellable>()
    private var followsLyrics = false

    /// The store parameters are a seam for the headless visual lab
    /// (`Tests/IslaKitTests/VisualLab*`), which builds whole panels without
    /// touching anything of the person's: the default `ClipboardStore` reads
    /// the general pasteboard, `ScreenshotVault` saves into `~/Pictures/Isla`
    /// (it creates the folder on its first save, never when it is built),
    /// and `PrivacyMode` and `Translator` write the standard defaults. Left
    /// out — as the app always leaves them — each is built exactly as before.
    init(
        lyricsEnabled: (() -> Bool)? = nil,
        localLyricsDirectory: URL = AppPaths.live.supportDirectory,
        shelf: ShelfStore? = nil,
        clipboard: ClipboardStore? = nil,
        screenshotVault: ScreenshotVault? = nil,
        translator: Translator? = nil,
        privacy: PrivacyMode? = nil,
        lyricTranslation: LyricTranslation? = nil,
        hud: MediaKeyHUD? = nil
    ) {
        // A test process never taps the keys: the suite runs on the owner's Mac,
        // often with the setting on, and `EventMediaKeyTap.live` and the real
        // trust check both refuse there too. The tests inject their own.
        self.hud = hud ?? MediaKeyHUD(isEnabled: { !PlayerBridge.isRunningTests && NotchViewModel.volumeAndBrightnessEnabled })
        let shelfStore = shelf ?? ShelfStore()
        self.shelf = shelfStore
        promises = PromisedDropInbox(shelf: shelfStore)
        self.clipboard = clipboard ?? ClipboardStore()
        self.screenshotVault = screenshotVault ?? ScreenshotVault()
        self.translator = translator ?? Translator()
        self.privacy = privacy ?? PrivacyMode()
        self.lyricTranslation = lyricTranslation ?? LyricTranslation()
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
            presentation: lyrics,
            // A test process never listens to the Mac's real output: its
            // reading would land in the shared lead model under every other
            // test's feet. The tests inject their own.
            outputLatency: PlayerBridge.isRunningTests ? nil : OutputLatencyMonitor()
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
        followLyricsForTranslation()
        localLyricsLibrary.startWatchingFolders()
        shelf.load()
        // Drop folders from previous sessions, once, off the main thread —
        // except the ones a card still points into. Read here, on the main
        // actor and after the load, because the shelf is not the prune's to
        // touch from a utility thread; a card added after this moment lives
        // in a folder minted now, which no week-old cutoff can reach (F-019).
        let cardFiles = Set(shelf.items.map(\.url))
        DispatchQueue.global(qos: .utility).async { AppPaths.pruneDropInbox(keeping: cardFiles) }

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
        clipboard.keepsImages = { NotchViewModel.clipboardIncludeImagesEnabled }
        // Keep Pinned Items (spec §9.4): the file and the switch, wired only
        // here, and never under test — a test that reached this would be
        // reading, and with the switch on writing, the owner's Application
        // Support. The tests inject a temporary file of their own.
        if !PlayerBridge.isRunningTests {
            clipboard.pinnedFile = PinnedClipboardFile.live
            clipboard.keepsPinned = { NotchViewModel.clipboardKeepPinnedEnabled }
            clipboard.loadPinned()
        }
        clipboard.onImage = { [weak self] png in
            guard let self else { return }
            self.screenshotVault.save(png) { [weak self] url in
                guard let url else { return }
                self?.collect(url)
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
                guard let url else { return }
                self?.collect(url)
            }
        }
        clipboard.onMovieFile = { [weak self] url in
            self?.collect(url)
        }
        refreshClipboardPolling()
        ambient.start()
    }

    /// The song's lines go to the translation whenever the lyrics change state,
    /// but handing them over starts nothing: a batch runs only while a surface
    /// that draws translations has registered demand (`LyricTranslation.setDemand`)
    /// and Show Translation is on. With the panel closed no batch runs; the lock
    /// card in R2 registers its own demand when it is up (review 2026-10-15 —
    /// this comment used to promise a batch for every song, which was the bug).
    /// `$state` hands over the value being set,
    /// and a recheck of the same song hands over the same lines, which the
    /// service treats as nothing new. Its own function, so a test can wire the
    /// two without starting a player feed.
    func followLyricsForTranslation() {
        guard !followsLyrics else { return }
        followsLyrics = true
        lyrics.$state
            .sink { [weak self] state in
                if case .synced(let lines) = state {
                    self?.lyricTranslation.present(lines: lines)
                } else {
                    self?.lyricTranslation.present(lines: nil)
                }
            }
            .store(in: &cancellables)
    }

    /// The pasteboard is read only while something wants what is on it:
    /// history, or clipboard screenshots for the Shelf. With both off,
    /// nothing polls at all.
    static func clipboardShouldPoll(history: Bool, images: Bool) -> Bool {
        history || images
    }

    /// - Parameter settingChanged: true when a Settings switch asked. A poll
    ///   that a switch turns back on starts from the pasteboard as it is now,
    ///   because whatever was copied while it was off was copied while the
    ///   user had said not to look.
    func refreshClipboardPolling(settingChanged: Bool = false) {
        guard Self.clipboardShouldPoll(
            history: NotchViewModel.clipboardHistoryEnabled,
            images: NotchViewModel.saveClipboardImagesEnabled
        ) else {
            clipboard.stop()
            return
        }
        if settingChanged {
            // Already polling means already baselined: a switch that keeps the
            // poll running has nothing old to skip, and restarting it would
            // skip a copy that was allowed.
            if !clipboard.isPolling { clipboard.startFresh() }
        } else {
            clipboard.start()
        }
    }

    func stop() {
        guard started else { return }
        started = false
        cancellables.removeAll()
        followsLyrics = false
        lyricsCoordinator.stop()
        localLyricsLibrary.stopWatchingFolders()
        media.stop()
        clipboard.stop()
        ambient.stop()
        hud.stop()
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
    /// - Parameter forLock: true from both of `screenLocked()`'s branches. The
    ///   clipboard then resumes from the pasteboard as it stands, so a copy
    ///   that arrived behind the shield is not recorded at unlock (G-011);
    ///   display sleep alone keeps the copy made just before it.
    func suspendForIdleScreen(keepingMediaRunning: Bool = false, forLock: Bool = false) {
        clipboard.stop(rebaseliningOnResume: forLock)
        if !keepingMediaRunning { media.setActive(false) }
        // The Accessibility poll too: nobody can grant a permission to a dark
        // or locked screen, and it ran every two seconds through the night.
        hud.suspend()
    }

    func resumeFromIdleScreen() {
        hud.resume()
        refreshClipboardPolling()
        // A wake is the likeliest moment for a failed route to work again. The
        // helper can lose a race with a waking MediaRemote, and a user who
        // cleared the download quarantine has usually put the Mac to sleep
        // since. Costs nothing while Now Playing is healthy, and a refused
        // load waits for the user to ask (see `retryNowPlaying`).
        media.retryNowPlaying(userAsked: false)
    }
}
