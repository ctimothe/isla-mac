import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class NotchViewModel: ObservableObject {
    /// Whose cache the opening refreshes; `.shared` in the app, a test's own
    /// where it counts openings.
    var icons: AppIcons = .shared

    @Published var isOpen = false {
        didSet {
            if isOpen, !oldValue { arrivedOverAnOpenSurface = false }
            // Opening onto the tray it was left on is an arrival there, and
            // only `surface` used to say so: ⌃⌥⌘I opens without assigning
            // one, so a tray reopened by the hot key kept a card whose file
            // had been deleted, left an ejected disk's cards undimmed and
            // missed new recordings until some other page was visited. Not
            // twice, though: a click on the Shelf assigns the surface and
            // then opens, and that is one arrival. And only when the tray is
            // what the open shows: over the drop surface or the welcome the
            // cards are not drawn, and a drag must never touch the files.
            if isOpen, !oldValue, presented == .tray {
                let now = uptime()
                let justPassed = trayPassedWhileShutAt.map { now >= $0 && now - $0 < Self.trayArrivalWindow } ?? false
                if !justPassed { shelf.refreshFromDisk() }
            }
            if isOpen != oldValue { trayPassedWhileShutAt = nil }
            // Opening ends a charger or headphones moment and a track peek
            // (F-033). They were cleared only on sleep and lock, so a panel
            // opened half a second into the 2.2 s moment and closed a second
            // later snapped the pill back to "Charging" for what was left of
            // it. Cleared here, inside the open's own `withAnimation`, they
            // leave with the open rather than after it; the controller's
            // pending fold then finds nothing to fold. Only on false to true:
            // `@Published` runs this on every write, and a moment presented
            // while shut must survive a redundant `isOpen = false`.
            // The panel closing ends a Clipboard search and gives its keyboard
            // back (spec §9.3): a field left open would be waiting, with its
            // query, inside the next visit.
            if !isOpen, oldValue {
                // The capsule under the panel goes with it, in the close's own
                // transaction: it folds as the panel does, and the next press
                // is the shut island's pill, not a second indicator beside a
                // panel that is leaving.
                hudStrip = nil
                // And the charger, headphones or a confirmation in it, told to
                // the controller first: a "Copied" that Return posted as it
                // closed the panel is owed to the shut island. Told on every
                // close, not only with a notice up (Codex review 2026-10-26):
                // a "Copied" waiting behind the level has no `stripNotice`
                // yet, and was lost with the panel.
                let notice = stripNotice
                stripNotice = nil
                onStripClosed?(notice)
                // A swipe does not outlive the panel it was made on.
                pageTravel.finish()
                pageSwipe = PageSwipe()
                clipboardBrowser.clearQuery()
                // Reading a translation aloud ends with the panel (spec §11), and
                // the History list is for the visit it was opened in: the next
                // opening starts on the cards, where the field is.
                translator.speaker.stop()
                translateShowsHistory = false
                // A Use Online press is for the visit it was made in: the panel
                // closing took the screen it was pressed on away.
                translator.revokeOnlineRequest()
                // And the Shelf's selection (review 2026-10-15): a tile picked
                // on Monday was still picked on Tuesday, and with the pointer
                // resting on the grid while typing in Mail, the transient
                // Delete key ate ⌫ and removed it. A selection belongs to one
                // opening of the panel.
                shelf.clearSelection()
            }
            if isOpen, !oldValue {
                // The installed voices are read again on each opening, off the
                // main actor, while Translate is the surface on screen (the
                // surface's own arrival does it for the other openings).
                if surface == .translate { translator.speaker.refreshVoices() }
                // Apps are installed and removed while Isla runs, so the music
                // apps' icons and names are asked afresh once per opening —
                // here, before any pane draws, and not from a pane's
                // `onAppear`, which ran after the first render had filled the
                // cache and cleared it again (two lookups per app per opening,
                // mid-animation). The refresh only forgets; nothing is asked
                // until a view needs an icon.
                icons.refresh()
                openingGeneration &+= 1
                if shelfSelectionIsCurrent { shelfSelectionIsCurrent = false }
            }
            guard isOpen, !oldValue else { return }
            ambient = nil
            // A confirmation answers an act on a shut island; the panel that
            // opened over it is where the person is now, and it shows its own.
            confirmation = nil
            isPeeking = false
            endCollectedMoment()
            // The pop-up's pill too: a pill left standing over a panel that
            // just opened would fold under it with nobody asking (spec §12).
            // The level is not lost — the next press draws it as the capsule
            // under the panel (`NotchController.hudPlacement`) — and nothing
            // is handed over mid-opening, which would show the same level
            // twice for the length of the open.
            hud = nil
            // And the update alert, which is not answered by being opened
            // over: the controller offers it again once the panel closes.
            updateOffer = nil
        }
    }
    @Published var isDropTargeted = false {
        didSet {
            guard isDropTargeted else { return }
            endPageGesture()
            // The drop surface is the panel's whole answer while a drag is
            // over it; a level under it would be a second thing to look at.
            hudStrip = nil
            stripNotice = nil
        }
    }
    /// Which of the Shelf's two wells a drag in flight is over (spec §8.3): the
    /// one the drop will use, and the one that lights. Meaningful only while
    /// `isDropTargeted`; put back to `.keep` whenever a drag ends, so the next
    /// drag starts on the action a drop has always had.
    @Published var shelfDropTarget: ShelfDropTarget = .keep
    /// Whether the pointer is on the Shelf pane — reported by the pointer
    /// sampler (`PointerWatcher.onShelfChange`), not by SwiftUI hover, for the
    /// reason `onHoverChange` gives: the panel hears no hover for the frame
    /// that matters. One of the two things the transient Delete key waits for
    /// (`claimsDelete`).
    @Published var isPointerOnShelf = false
    /// Counts the panel's openings: the stamp a Shelf selection carries, so the
    /// Delete key is held only for a selection made during the *current* opening
    /// (review 2026-10-15). Clearing the selection when the panel closes already
    /// does that job; the stamp is the second wall, for any path that leaves a
    /// selection standing without passing through a close.
    private(set) var openingGeneration = 0
    var shelfSelectionOpening: Int?
    /// Whether the Shelf has a selection that was made during this opening — the
    /// `hasSelection` of `claimsDelete`, published so the controller's sink
    /// reads it with the rest of the claim's inputs.
    @Published var shelfSelectionIsCurrent = false

    /// Briefly true when a new track has just arrived and is showing itself.
    @Published var isPeeking = false
    /// The charger or headphones, shown for a moment. See `AmbientActivity`.
    @Published var ambient: AmbientActivity?
    /// The volume or brightness pop-up on the shut island, while it is up
    /// (spec §12). The highest of the island's alerts: see `IslandActivity`.
    ///
    /// Whether it is up is published; what it shows is not. A held key presses
    /// every 30 to 35 ms, and a `@Published` moment made every press re-run
    /// the island's whole body to move a bar. The moment lives in `hudLive`,
    /// which only the pop-up's own views observe, so assigning a new level
    /// while the pop-up stands publishes nothing here (`hudShown` stays true)
    /// and assigning nil or a first moment is the arrival and the fold, which
    /// the island does need to hear. Everything that read `hud` as a value —
    /// `activity`, the tests — reads it unchanged.
    var hud: HUDMoment? {
        get { hudShown ? hudLive.moment : nil }
        set {
            if let newValue {
                hudLive.update(newValue)
                if !hudShown { hudShown = true }
            } else if hudShown {
                hudShown = false
            }
        }
    }
    @Published private(set) var hudShown = false
    /// The same pop-up as a capsule under the open panel (spec §19.5 d,
    /// amended 2026-10-25, `HUDStripLayout`): shown instead of the pill while
    /// the panel is open, never beside it, and sharing the pill's live level.
    /// Not an island activity: the island is the panel then, and the capsule
    /// is a satellite of it that takes no part in `activity`, `bodySize` or the
    /// clickable region.
    var hudStrip: HUDMoment? {
        get { hudStripShown ? hudLive.moment : nil }
        set {
            if let newValue {
                hudLive.update(newValue)
                if !hudStripShown { hudStripShown = true }
            } else if hudStripShown {
                hudStripShown = false
            }
        }
    }
    @Published private(set) var hudStripShown = false
    /// The level on screen, for whichever of the two is up.
    let hudLive = HUDLiveLevel()
    /// The charger, headphones or a confirmation in the same capsule under the
    /// open panel (spec §19.5 d, amended again 2026-10-26: "every HUD should"
    /// show under the open island). The pop-up outranks it and takes the
    /// capsule whenever it comes; the controller keeps them one at a time
    /// (`NotchController.presentInStrip`). Like `hudStrip`, not an island
    /// activity.
    @Published var stripNotice: StripNotice?
    /// The panel closed, with the notice that was in the capsule if any: the
    /// controller may hand one that had barely arrived, or one still waiting
    /// for the capsule, to the shut island (`StripNotice.handsBack`).
    var onStripClosed: ((StripNotice?) -> Void)?
    /// A confirmation of the person's own act, while it is up: rank 5, below
    /// the pop-up. The controller decides when it shows (`IslandConfirmation`).
    @Published var confirmation: IslandConfirmation?
    /// An act asked for a confirmation. The controller's, which puts it
    /// through the island's alert queue.
    var onConfirmation: ((IslandConfirmation) -> Void)?

    /// The update alert, while it is up (spec §19.5 f): rank 9, below the
    /// pop-up and the charger or headphones, above the peek. The controller
    /// decides when it shows; its buttons report through `onUpdateAction`.
    @Published var updateOffer: UpdateOffer?
    /// A button on the update alert was pressed. The controller's.
    var onUpdateAction: ((UpdateAlertAction) -> Void)?
    /// A file Isla collected by itself has just landed on the Shelf, and the
    /// Shelf shows itself for `collectedMomentLifetime` from the last one —
    /// compact on the bare notch, the bubble beside a song — then the island
    /// rests (spec §19.1, amended 2026-10-17). Collected files never keep the
    /// Shelf live on their own; see `ShelfItem.Origin`.
    @Published var isShowingCollected = false
    /// §19.1's moment for a collected file.
    static let collectedMoment: Duration = .seconds(2)
    /// A seam so tests do not wait two seconds.
    var collectedMomentLifetime: Duration = NotchViewModel.collectedMoment
    var collectedMomentEnd: Task<Void, Never>?
    /// What the island shows, by §19.1's rank: an alert, else the song, else
    /// the Shelf, else the bare notch.
    var activity: IslandActivity {
        IslandActivity.current(
            hud: hud, confirmation: confirmation, ambient: ambient, update: updateOffer, isPeeking: isPeeking,
            musicIsVisible: compactMediaActivity.isVisible, shelfCount: liveShelfCount, live: liveActivities,
            expanded: expandedLive
        )
    }
    /// The timer, stopwatch, recording and downloads standing, highest first
    /// (`LiveActivityHub`, plan 2026-11-14). The controller's to set.
    @Published var liveActivities: [LiveActivity] = []
    /// The kind of the live activity whose card of controls is showing — a
    /// timer's, a stopwatch's, the microphone's: a click on it opens them in
    /// place, as the iPhone's long-press does, and they fold on their own
    /// (`NotchController.liveClicked`).
    @Published var expandedLive: String?
    /// A timer control was pressed. The controller's.
    var onTimerControl: ((TimerControl) -> Void)?
    /// A microphone control was pressed. The controller's.
    var onMicrophoneControl: ((MicrophoneControl) -> Void)?
    /// Whether the island shows a live activity's card of controls right now.
    var showsLiveControls: Bool {
        guard let kind = expandedLive, case .live(let live) = activity else { return false }
        return live.kind == kind && live.hasControls
    }
    /// The second live activity waiting as the bubble beside the island
    /// (spec §19.7, amended 2026-11-14: any live activity), or nil.
    var bubble: IslandActivity? {
        guard !showsLiveControls else { return nil }
        return IslandActivity.bubbleActivity(
            beside: activity, musicIsVisible: compactMediaActivity.isVisible, shelfCount: liveShelfCount,
            live: liveActivities, isOpen: isOpen || isDropTargeted, isLocked: isLockedPresentation
        )
    }
    /// The Shelf's count when the Shelf is the bubble (spec §19.7).
    var bubbleCount: Int? {
        if case .shelf(let count)? = bubble { return count }
        return nil
    }
    /// The Shelf's count while it is live, else 0. Live while it holds a file
    /// a person put there, or for a collected file's moment; the count is
    /// still every card, which is what the tray shows when it opens.
    var liveShelfCount: Int {
        Self.shelfCut(items: shelf.items, showingCollected: isShowingCollected).isLive ? shelf.items.count : 0
    }

    /// True while the shield is up and the panel is presenting the lock-screen
    /// card instead of its normal shell.
    @Published var isLockedPresentation = false {
        // The shield going up ends a collected file's moment, as opening does.
        didSet {
            if isLockedPresentation {
                endCollectedMoment()
                pageTravel.finish()
                pageSwipe = PageSwipe()
                // A pull under way does not cross the lock: the shell it was
                // stretching is not drawn over the shield.
                islandPull = IslandPull()
                pullStretch.track(0)
            }
        }
    }
    /// Whether Show on Lock Screen is on, read at each use. The setting lives in
    /// `UserDefaults.standard`; a test that depended on it skipped itself on a
    /// machine with the switch off (re-review 2026-10-15), so it is a closure a
    /// test replaces and production leaves at the real default.
    var showOnLockScreen: () -> Bool = { NotchViewModel.showOnLockScreenEnabled }
    /// Clipboard's kind filter and search field (spec §9.3, §19.8). Owned here
    /// rather than by the surface because what was typed has to be cleared from
    /// outside it — Escape, the surface changing, the panel folding.
    let clipboardBrowser = ClipboardBrowser()

    /// The Translate editor's frame in the window (top-left origin), for the
    /// panel's I-beam. Zero on every other tab; the pane that reports it is
    /// gone by then and a vanished view sends no last word.
    @Published var textInputRect: CGRect = .zero

    /// Whether the Translate tab shows its History list in place of the two cards
    /// (spec §11): the header's History button toggles it. Memory only, and put
    /// away by a tab change, the panel closing, text arriving by the hot key or
    /// the Service, and Keep History being turned off — each of which is a
    /// moment the person is not looking at a list they opened earlier.
    ///
    /// The list coming up ends reading aloud: it is drawn in place of the
    /// cards, Stop among them, and the voice used to read on to the end of
    /// the answer with nothing on screen to stop it.
    @Published var translateShowsHistory = false {
        didSet { if translateShowsHistory, !oldValue { translator.speaker.stop() } }
    }

    /// The surface chosen (spec §19.1): what a click, a key, a swipe or a dot
    /// asked for. What is drawn is `presented`, which lays the drop surface and
    /// the welcome over it. Music until something else is chosen: it is the
    /// first page, and the one the bare notch opens at launch (§19.16).
    @Published var surface: Surface = .player {
        didSet {
            if surface != oldValue { arrivedOverAnOpenSurface = isOpen }
            // A surface changed by anything but the pages' own turn — the
            // gear, the stage, the menu, a shortcut — puts the pages at rest
            // at once, so the new surface arrives on its own swap rather than
            // under a settle that was heading somewhere else.
            if !isTurningByTravel, pageTravel.leg != nil { pageTravel.finish() }
            // The page the bare notch opens next (§19.16), and the place the
            // lit gear goes back to. The stage and Settings are a level below a
            // page and leave the page they came from standing.
            if surface.isPage { lastPage = surface }
            if surface == .settings, oldValue != .settings { settingsReturn = oldValue }
            if surface == .translate, isOpen { translator.speaker.refreshVoices() }
            if surface != .translate {
                textInputRect = .zero
                // A surface change ends speech and the list (spec §11); the
                // pane's own disappearance stops the voice too, this is the
                // model's half, so it holds without a view on screen.
                translator.speaker.stop()
                translateShowsHistory = false
                translator.revokeOnlineRequest()
            }
            // The tray can hold files inside the folders macOS guards, and
            // looking at one raises a permission prompt. It is asked here, with
            // the tray coming into view, rather than at launch with nothing to
            // explain it — once per arrival, not on every write: a tray already
            // on screen has its cards. A shut panel opening onto the tray it
            // was left on is an arrival.
            if surface == .tray, oldValue != .tray || !isOpen {
                shelf.refreshFromDisk()
                trayPassedWhileShutAt = isOpen ? nil : uptime()
            }
            // What was typed into Clipboard's field belongs to that visit:
            // a half-remembered query hiding most of the list the next time
            // it opens would read as a broken history.
            if surface != .clipboard { clipboardBrowser.clearQuery() }
            // A Shelf selection is for the visit it was made in: left standing
            // it would be waiting, with Delete behind it, the next time the
            // tray is shown (review 2026-10-15).
            if surface != .tray { shelf.clearSelection() }
            // Remove All's question belongs to the visit it was asked in, as
            // the selection does.
            if surface != .tray { shelfClear.cancel() }
            if surface != .clipboard { clipboardClear.cancel() }
            // Leaving a surface that types gives the keyboard straight back —
            // unless ⌃Tab is what left it, which carries the keyboard with it
            // (`turnPageByKey`).
            if !surface.takesKeyboard, !isTurningByKey { wantsKeyboard = false }
        }
    }

    /// The pages on their way between two (§19.16): under the fingers, or
    /// settling after them, a dot or ⌃Tab. An object of its own, so the
    /// frames of a swipe re-render the open island and nothing else that
    /// watches this model.
    let pageTravel = PageTravel()
    /// The swipe under way: what its first 10 pt decided, and where its
    /// fingers have the pages.
    var pageSwipe = PageSwipe()
    /// The vertical two-finger pull that opens and closes the panel
    /// (`IslandPull`), fed by the controller's scroll monitor.
    var islandPull = IslandPull()
    /// What the pull draws while the fingers track: watched by the shell's
    /// outline alone.
    let pullStretch = IslandPullStretch()
    /// Set while the pages turn `surface` themselves, so their own turn does
    /// not end their travel.
    var isTurningByTravel = false
    /// Set while ⌃Tab turns the page, which keeps the keyboard where a swipe
    /// or a dot gives it back.
    var isTurningByKey = false
    /// The page last shown since launch: what the bare notch with no song, and
    /// ⌃⌥⌘I with nothing live, open (§19.16). Held for the launch only — a
    /// page somebody looked at yesterday is not where they are now.
    @Published var lastPage: Surface = .player

    /// Where the lit gear on Settings goes back to: the page or the stage
    /// Settings was opened from, by the gear or by the menu.
    var settingsReturn: Surface?

    /// Whether the surface on screen came in over another one in an island
    /// that was already open — a swap — and not with the island: what the
    /// shell asks to decide when a heavy pane may be built. A swap's arriving
    /// pane is transparent until the old one has gone (`Theme.swapIn`); the
    /// island opening onto a surface brings its content in on the open's own
    /// `Theme.paneIn`, which is 35 % opaque by the time the swap's would be
    /// built, so that arrival is not delayed.
    ///
    /// Set where the surface changes, read by the pane for as long as it
    /// lives, and cleared by the island opening: a reopening onto the surface
    /// the last swap brought is an opening. Writable for the visual lab, which
    /// draws still images (no clock to wait for) of a panel it opens by
    /// setting `isOpen` first.
    var arrivedOverAnOpenSurface = false

    /// What the open island draws: the drop surface while files are dragged
    /// to the notch, the welcome for one launch, and otherwise the surface
    /// chosen — except the stage with no song, which is the empty player:
    /// there are no words to show and nothing for 400 points to hold
    /// (⌃⌥⌘L on a silent Mac).
    var presented: Surface {
        if isDropTargeted { return .drop }
        if isShowingWelcome { return .welcome }
        if surface == .stage, media.track == nil { return .player }
        return surface
    }

    /// The Settings section on screen (redesign 2026-10-15, spec §10): the one
    /// the sidebar has selected, and the one `settings.lastSection` remembers for
    /// the next open.
    ///
    /// It replaces the scroll target the single list needed. A pointer from
    /// elsewhere that only selected the tab used to land three sections above
    /// the switch it promised (J-007's Open Settings), so each of those routes
    /// set a target for the pane to scroll to and spend; with a sidebar the route
    /// simply *selects the section*, and what the person chose in the sidebar is
    /// what is written down — a visit sent here by "Lyrics Settings…" is
    /// remembered like any other. Written through `defaults`, so a test's private
    /// suite never touches the owner's.
    @Published var settingsSection: SettingsSection {
        didSet {
            guard settingsSection != oldValue else { return }
            settingsSection.store(in: defaults)
            // Settings holds the keyboard only while a shortcut records, and
            // a recording does not outlive its section. The row gives the
            // keyboard back when its recording ends with the row still on
            // screen, and leaves it to the surface change when the row is
            // going — but a section change is not a surface change, so
            // nothing took it: the panel stayed key on General, swallowing
            // every key meant for the app in front until it was closed.
            if surface == .settings, wantsKeyboard { wantsKeyboard = false }
        }
    }

    /// Where `settingsSection` is remembered. The standard domain in the app; a
    /// test's own suite otherwise.
    let defaults: UserDefaults

    /// The Spotify account, for the player's Favourite star — nil under the
    /// test runner unless a test stands one in, so no test reads the owner's
    /// keychain through the panel.
    var spotifyAccount: SpotifyAccount? {
        if PlayerBridge.isRunningTests, SpotifyAccount.sharedOverride == nil { return nil }
        return SpotifyAccount.shared
    }

    /// When `surface` passed over the tray with the panel still shut, in
    /// awake time: the open that follows at once is the same arrival
    /// (`isOpen`), and must not pass over it again.
    private var trayPassedWhileShutAt: TimeInterval?
    /// The awake clock. A seam so a test can let time pass without waiting.
    var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// How soon after the surface the open must come to be the same arrival:
    /// the two are assigned in one turn of the run loop.
    static let trayArrivalWindow: TimeInterval = 0.5

    /// Remove All's question (spec §19.7): asked from the tray's header,
    /// said in the tray in place of the row.
    let shelfClear = ShelfClearConfirmation()
    /// Clipboard's Clear All question, held here rather than by the pane so
    /// Return can see it (`consumeListKey`) — and only it: a question armed
    /// anywhere else is not Clipboard's to answer (R-10).
    let clipboardClear = ClipboardClearConfirmation()

    /// Edit Lyrics, from the header's More menu or from a state's button: the
    /// session the editor sheet is open on. Held here and not in `MediaPane`
    /// because two places ask for it and only the pane draws the sheet.
    @Published var lyricEditing: LocalLyricsEditor.EditingSession?

    /// The More menu's controller: built once, reading the model when it opens
    /// (the correction, the bound file and the online switch all move while the
    /// panel is up) and acting through the same entry points the page's own
    /// buttons use.
    lazy var lyricsMoreMenu: LyricsMoreMenuController = LyricsMoreMenuController(
        // `weak`, not `unowned`: these controllers are held by `@State`
        // presenters in the views, which can outlive this model when the panel
        // is rebuilt for a display change, and a menu action on the old panel
        // then crashed. An orphaned menu does nothing (review 2026-10-15).
        context: { [weak self] in
            guard let self else {
                return LyricsMoreMenuController.Context(
                    localFileName: nil, hasBinding: false, onlineOn: false, offset: 0, canNudge: false
                )
            }
            var localFile: String?
            if case .some(.ready(let candidate)) = lyricsCoordinator.localLookup {
                localFile = LyricsMoreMenuModel.fileName(
                    stored: localLyricsLibrary.fileName(of: candidate.id),
                    candidate: candidate, trackTitle: media.track?.title
                )
            }
            var canNudge = false
            if case .ready = lyrics.availability, case .synced = lyrics.state { canNudge = true }
            return LyricsMoreMenuController.Context(
                localFileName: localFile, hasBinding: lyrics.hasLocalOverride,
                onlineOn: Self.onlineLyricsEnabled, offset: lyrics.trackOffset, canNudge: canNudge,
                shuffle: media.shuffleEnabled, repeatMode: media.repeatMode
            )
        },
        actions: LyricsMoreMenuController.Actions(
            nudge: { [weak self] in self?.lyrics.nudgeTrackOffset(by: $0) },
            resetTiming: { [weak self] in self?.lyrics.clearTrackOffset() },
            editLyrics: { [weak self] in
                guard let self else { return }
                guard case .some(.ready(let candidate)) = lyricsCoordinator.localLookup else { return }
                lyricEditing = LocalLyricsEditor.EditingSession(
                    candidate: candidate, identity: lyricsCoordinator.currentLocalTrackIdentity
                )
            },
            removeBinding: { [weak self] in self?.lyricsCoordinator.removeLocalBinding() },
            importFile: { [weak self] in self?.chooseLocalLyricsFile(from: .stage) },
            searchAgain: { [weak self] in self?.lyricsCoordinator.retry() },
            openSettings: { [weak self] in self?.openLyricsSettings() },
            toggleShuffle: { [weak self] in self?.media.toggleShuffle() },
            cycleRepeat: { [weak self] in self?.media.cycleRepeat() }
        )
    )

    /// The lyric translation, the session's own (`NotchStores`).
    var translation: LyricTranslation { stores.lyricTranslation }

    /// The translation menu's controller, built once and reading the service when
    /// it opens — the recents, the current language and where the batch went all
    /// move while the panel is up.
    lazy var lyricsTranslateMenu: LyricsTranslateMenuController = LyricsTranslateMenuController(
        context: { [weak self] in
            guard let self else {
                return LyricsTranslateMenuController.Context(
                    isShown: false, languages: [], current: .english, engine: nil
                )
            }
            return LyricsTranslateMenuController.Context(
                isShown: translation.isShown, languages: LyricsTranslateMenuModel.languages(
                    recents: translation.recents, current: translation.target
                ),
                current: translation.target, engine: translation.engine
            )
        },
        actions: LyricsTranslateMenuController.Actions(
            toggleShown: { [weak self] in self?.translation.toggleShown() },
            choose: { [weak self] in self?.translation.choose(target: $0) }
        )
    )

    @Published var lyricsNotice: LyricsNotice?

    /// Whether the panel must stay open with no pointer on it.
    ///
    /// The one exception to the rule stated at `NotchController.setOpen` — the
    /// pointer decides, always — kept for the pin, which is what an open made
    /// without the pointer leaves behind: a deliberate request to keep the panel
    /// up while the hands are elsewhere. Nothing else holds the panel open any
    /// more; the teleprompter, which used to, went on 2026-08-22.
    var holdsOpen: Bool { isPinnedOpen }

    /// Raised when the panel was opened with the pointer nowhere near it: ⌃⌥⌘I,
    /// or a click that came from the keyboard rather than the mouse — the
    /// compact island's accessibility action. (There has been no menu item
    /// since 2026-08-25; the app has no menu-bar item at all.) A click from the
    /// pointer deliberately does not pin — see `clickOpened(opening:pointerIsOnPanel:)`.
    ///
    /// Those routes exist so the panel can be reached without a mouse, and the
    /// pointer rule cancels them outright: the cursor is wherever it was left,
    /// the very next sample calls it "away", and the panel folds a third of a
    /// second after opening. A command opens until a command closes — the same
    /// hotkey again, Escape, a click outside, or ⌘-Tab to another app. Hovering onto the panel and
    /// off again hands control back to the pointer, which is what somebody
    /// reaching for it with the mouse means by leaving.
    @Published var isPinnedOpen = false

    /// Whether the body is showing the welcome instead of the surface chosen.
    ///
    /// Not a surface somebody can be sent to: it is presented over the choice
    /// (`presented`) for one launch, and `open(.welcome)` refuses it.
    ///
    /// Lowered by anything that ends the panel it opened, and set by exactly
    /// three things — Get Started, a surface chosen through the menu, and a
    /// shortcut that asks for one (⌃⌥⌘V, ⌃⌥⌘T, ⌃⌥⌘L, the Service). Everything
    /// else that takes it off screen leaves `hasCompletedFirstRun` alone, so
    /// the welcome is shown once per account *until it is answered*, not once
    /// per account full stop.
    @Published var isShowingWelcome = false {
        didSet { if isShowingWelcome { endPageGesture() } }
    }

    /// The pointer is on the island. Drawn as an outline, not as an opening.
    ///
    /// Hovering used to open the panel outright, which meant the island
    /// unfolded at every pass of the cursor across the top of the screen. It
    /// answers a hover with an edge now: *there is something here, and it opens
    /// when you click it.*
    @Published var isHovering = false

    /// Raised when the island is clicked — the collapsed pill, or the header
    /// strip that is all of it that shows while the panel is open. The
    /// controller owns what that means — open, close, or refuse while locked —
    /// because only it knows.
    var onIslandClick: (() -> Void)?
    /// The same for the Shelf's bubble (spec §19.7).
    var onBubbleClick: (() -> Void)?

    /// The live activity under any alert: what the island goes back to when
    /// the alert folds (spec §19.1).
    var liveActivity: IslandActivity {
        IslandActivity.current(
            hud: nil, ambient: nil, isPeeking: isPeeking,
            musicIsVisible: compactMediaActivity.isVisible, shelfCount: liveShelfCount, live: liveActivities
        )
    }

    /// Whether the panel currently holds the keyboard.
    ///
    /// Tracked apart from `surface` because the two come apart both ways.
    /// Clicking into another app drops the claim without changing the
    /// surface, so the text one was typing survives and the panel is free to
    /// collapse. And Clipboard or Translate reached by a swipe, a dot, the
    /// pointer or a click on the bare notch shows its field without it: only
    /// a summons (`open(_:)`), a press into the field (`pressClaimsKeyboard`)
    /// or focus moving into it (VoiceOver) raises it, so looking through the
    /// pages never takes typing from the app in front (§19.16, R8b review
    /// F1). The one way it outlives a surface that types is ⌃Tab, which
    /// carries it onto the Shelf and Music (`turnPageByKey`).
    @Published var wantsKeyboard = false

    let geometry: NotchGeometry
    let media: MediaController
    let shelf: ShelfStore
    let clipboard: ClipboardStore
    let screenshotVault: ScreenshotVault
    let translator: Translator
    let lyrics: LyricsStore
    let localLyricsLibrary: LocalLyricsLibrary
    let lyricsCoordinator: LyricsCoordinator
    /// Shared by every pane that shows something worth not showing.
    let privacy: PrivacyMode
    /// The colour the cover lends the island's equalizer (spec §3.4). The
    /// fallback until a cover has been read, and for none. The presented
    /// song's, so the bars recolour in the swap rather than a step after it.
    @Published private(set) var coverTint = CoverTint.fallback
    /// What every surface draws of the song, swapped once per song
    /// (`NowPlayingPresenter`). Owned here, beside the tint it now carries.
    let nowPlaying: NowPlayingPresenter
    /// The machine's audio route for the player's Output button and menu —
    /// the outputs and the current device, never the volume
    /// (`AudioWatch.followsLevel`, 2026-10-25). Started and stopped by the
    /// Music pane while it is on screen — a listener on CoreAudio costs nothing
    /// while nobody looks — and *quiet* under test: a pane built in a test must
    /// never reach the owner's output devices, even to read them.
    let playerAudio: AudioWatch = AudioWatch.player()
    /// The session's stores, borrowed rather than owned — see `NotchStores`.
    let stores: NotchStores

    private var cancellables = Set<AnyCancellable>()

    /// Bumped each time the island is hovered while the Mac is locked.
    ///
    /// The island stays visible over the shield but must never open there, so a
    /// hover has nothing to do — and doing nothing at all reads as a dead app
    /// rather than as a deliberate limit. The pill answers with a short wobble
    /// instead: the same "no, not that" gesture a login field gives a wrong
    /// password, which needs no explaining and cannot be mistaken for the panel
    /// starting to open.
    @Published var lockedHoverNudges = 0

    /// True once a pause has lingered for `NotchMetrics.pausedLinger`, or at
    /// once for a paused track nobody was seen pausing. Reset the moment it
    /// plays again, so resuming brings the pill straight back.
    @Published var pauseHasSettled = false
    var pauseSettleTask: Task<Void, Never>?
    /// Whether the last state this saw was a track playing — the only state a
    /// pause can be seen happening from.
    var lastSawPlaying = false

    init(geometry: NotchGeometry, stores: NotchStores, defaults: UserDefaults = .standard) {
        self.geometry = geometry
        self.stores = stores
        self.defaults = defaults
        // The last section shown, or General: Settings opens where it was left.
        self.settingsSection = SettingsSection.stored(in: defaults)
        self.media = stores.media
        self.shelf = stores.shelf
        self.clipboard = stores.clipboard
        self.screenshotVault = stores.screenshotVault
        self.translator = stores.translator
        self.lyrics = stores.lyrics
        self.localLyricsLibrary = stores.localLyricsLibrary
        self.lyricsCoordinator = stores.lyricsCoordinator
        self.privacy = stores.privacy
        self.nowPlaying = NowPlayingPresenter.live(media: stores.media, lyrics: stores.lyrics)

        // The panel header reads through to the stores — counters, the source
        // name, the equalizer. Nested ObservableObjects do not propagate on
        // their own, so those would only refresh when something else happened
        // to redraw the view.
        //
        // Media is forwarded even while closed: a current track now turns the
        // black notch into a compact live activity. Its position ticker still
        // runs only while the full panel is open, so this does not redraw the
        // collapsed shell four times a second.
        //
        // The stores with a text field in their pane — the translator and the
        // notes — are deliberately absent. They change on every
        // keystroke, and redrawing the whole panel per letter costs more than a
        // stale counter: it rebuilds the field, which drops the focus, so the
        // first letter typed is also the last one that lands. Their panes
        // observe them directly, and the header counter refreshes anyway,
        // because the list is only ever re-read on the way into the tab.
        // Named fields rather than `media.objectWillChange`, because that fires
        // for every field the controller publishes and one of them moves four
        // times a second. The shell renders exactly three things about the
        // track — whether there is one and which, whether it is playing, and
        // its artwork — and the panes that draw the rest observe the
        // controller directly. Forwarding the lot meant the position ticker
        // invalidated the whole view graph at 4 Hz on the notes tab, and the
        // helper's idle heartbeat — an empty snapshot every two seconds
        // forever — invalidated it at 0.5 Hz with nothing playing at all.
        //
        // The track and its cover come from the presenter, not the controller:
        // the shell draws the presented song, which changes once per skip
        // where the controller's fields change once per field. The held clock
        // too, which the player is handed by value.
        Publishers.MergeMany(
            nowPlaying.$presented.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            nowPlaying.$held.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            media.$isPlaying.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            // The open header names the app the audio belongs to, and that name
            // can arrive a snapshot late — the pid→name lookup fails on the
            // first poll after a player launches and succeeds on the next —
            // without the track ever changing.
            media.$sourceName.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            // The Shelf is a live activity (spec §19.1): its count is drawn on
            // the shut island and in the bubble, so a file kept or removed
            // while the panel is shut has to reach the island — and so does a
            // card becoming a person's, which can make the Shelf live without
            // changing the count.
            stores.shelf.$items
                .map { items in ShelfRedraw(count: items.count, holdsPlaced: items.contains { $0.origin == .placed }) }
                .removeDuplicates().map { _ in () }.eraseToAnyPublisher()
        )
        .sink { [weak self] _ in self?.objectWillChange.send() }
        .store(in: &cancellables)

        // The stage with no song is drawn as Music's page and pages like it;
        // a song arriving makes it the stage again, which is not a page, and
        // takes the page from under a swipe (R8b re-review R3). The value is
        // read from the publisher: `media.track` has not taken it yet.
        media.$track.map { $0 != nil }.removeDuplicates()
            .sink { [weak self] hasSong in
                guard let self, hasSong, surface == .stage else { return }
                endPageGesture()
            }
            .store(in: &cancellables)

        // A Use Online press ends when Translate goes under its cover: the card
        // must not be left holding a permission to send text the person can no
        // longer see. The new values are read from the publishers, not from
        // `privacy`, which has not taken them yet when `@Published` fires.
        Publishers.CombineLatest(stores.privacy.$sections, stores.privacy.$revealed)
            .sink { [weak self] sections, revealed in
                if sections.contains(.translate), !revealed.contains(TranslatePane.revealID) {
                    self?.translator.revokeOnlineRequest()
                }
            }
            .store(in: &cancellables)

        // The stamp on the Shelf's selection (`shelfSelectionIsCurrent`).
        stores.shelf.$selection
            .sink { [weak self] selection in self?.shelfSelectionChanged(to: selection) }
            .store(in: &cancellables)

        // One tint per artwork, read by the presenter before it swaps a cover
        // in, so the bars take the new colour in the same swap. It used to be
        // read here after the cover had already landed: a third step on every
        // skip, after the title and the cover (owner, 2026-10-25).
        nowPlaying.$presented.map { $0?.tint ?? CoverTint.fallback }.removeDuplicates()
            .sink { [weak self] tint in
                guard let self, self.coverTint != tint else { return }
                self.coverTint = tint
            }
            .store(in: &cancellables)

        // A pause that settles folds the island into the notch; playing again,
        // or a different track, brings it back.
        media.$isPlaying.removeDuplicates()
            .combineLatest(media.$track.removeDuplicates { $0?.key == $1?.key })
            .sink { [weak self] isPlaying, track in
                self?.playbackChanged(isPlaying: isPlaying, hasTrack: track != nil)
            }
            .store(in: &cancellables)

        // A notice is about the song it was raised over; under the next
        // song's lyrics it would read as being about that one.
        media.$track.map { $0?.key }.removeDuplicates().dropFirst()
            .sink { [weak self] _ in
                guard self?.lyricsNotice != nil else { return }
                self?.lyricsNotice = nil
            }
            .store(in: &cancellables)

        // A film starting under Music Only folds a paused song's pill at once.
        media.$otherMediaIsPlaying.removeDuplicates().filter { $0 }
            .sink { [weak self] _ in self?.otherMediaStartedPlaying() }
            .store(in: &cancellables)

        // The header's Show Translation tool appears and fills with Settings and
        // the service. Only while the panel is up: nothing paints otherwise.
        stores.lyricTranslation.objectWillChange
            .sink { [weak self] _ in
                guard let self, self.isOpen else { return }
                self.objectWillChange.send()
            }
            .store(in: &cancellables)

        // The remaining stores have nothing to paint while collapsed — the
        // Shelf's count, which the shut island does draw, reaches it through
        // the merge above.
        for child in [
            shelf.objectWillChange,
            clipboard.objectWillChange,
            clipboardBrowser.objectWillChange,
        ] {
            child
                .sink { [weak self] _ in
                    guard let self, self.isOpen || self.isDropTargeted else { return }
                    self.objectWillChange.send()
                }
                .store(in: &cancellables)
        }
    }
}
