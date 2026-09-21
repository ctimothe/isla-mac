import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class NotchViewModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case media, shelf, clipboard, translate, settings
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .media: return "music.note"
            case .shelf: return "tray.full.fill"
            case .clipboard: return "list.clipboard.fill"
            case .translate: return "translate"
            case .settings: return "gearshape.fill"
            }
        }

        var title: String {
            switch self {
            case .media: return localized("Music")
            case .shelf: return localized("Shelf")
            case .clipboard: return localized("Clipboard")
            case .translate: return localized("Translate")
            case .settings: return localized("Settings")
            }
        }

        /// Tabs with a field in them. Landing on one hands it the keyboard, so
        /// that arriving and typing is a single move.
        var needsKeyboard: Bool { self == .translate }

        /// One rail, in two groups. Four tabs is few enough that a second
        /// column was only ever there to hold the overflow — and the overflow
        /// is gone. Settings sits at the foot of the rail, below a gap: it is
        /// not something to hover past on the way to a track, so it stays out
        /// of the run people rest on.
        static let contentTabs: [Tab] = [.media, .shelf, .clipboard, .translate]
        static let utilityTabs: [Tab] = [.settings]
        static let leftRail: [Tab] = contentTabs + utilityTabs
        static let rightRail: [Tab] = []
    }

    @Published var isOpen = false
    @Published var isDropTargeted = false
    /// Briefly true when a new track has just arrived and is showing itself.
    @Published var isPeeking = false
    /// True while the shield is up and the panel is presenting the lock-screen
    /// card instead of its normal shell.
    @Published var isLockedPresentation = false
    @Published var tab: Tab = .media {
        didSet {
            // The shelf can hold files inside the folders macOS guards, and
            // looking at one raises a permission prompt. It is asked here,
            // with the shelf on screen, rather than at launch with nothing to
            // explain it.
            if tab == .shelf { shelf.refreshFromDisk() }
            // Leaving the tab that types gives the keyboard straight back.
            if !tab.needsKeyboard { wantsKeyboard = false }
            // And leaving Music folds the stage, so coming back to the tab
            // lands on the player rather than on a page of words left open
            // three songs ago.
            if tab != .media { isShowingLyrics = false }
        }
    }

    /// Whether the Music tab is showing the full lyrics page instead of the
    /// player.
    ///
    /// It lives here rather than inside `MediaPane` because it is a place the
    /// app can be *sent*, not just a toggle the pane owns: ⌥⌘L opens the panel
    /// straight onto it, and the verification hook does the same without a
    /// pointer. State that only the view holds is state nothing else can ask
    /// for — which is what made the hook an `onAppear` reading an environment
    /// variable rather than a route like every other way in.
    @Published var isShowingLyrics = false

    /// Whether the panel must stay open with no pointer on it.
    ///
    /// The one exception to the rule stated at `NotchController.setOpen` — the
    /// pointer decides, always — kept for the pin, which is what an open made
    /// without the pointer leaves behind: a deliberate request to keep the panel
    /// up while the hands are elsewhere. Nothing else holds the panel open any
    /// more; the teleprompter, which used to, went on 2026-08-22.
    var holdsOpen: Bool { isPinnedOpen }

    /// The pointer reaching the island: the panel is handed back to it.
    ///
    /// State, not event plumbing, so it can be tested without a pointer.
    /// Unconditional on Open on Hover — the setting decides whether arriving
    /// *opens* the panel, never whether arriving takes back a panel that is
    /// already open. A step of its own inside `pointerCrossed` because a drag
    /// arriving must not run it; see there.
    func pointerArrived() {
        isPinnedOpen = false
        select(.media)
    }

    /// What the pointer crossing the panel's boundary asks the panel to do.
    ///
    /// A verdict rather than an action, so the sequence that used to strand a
    /// panel open — approach, click, walk away — can be played out in a test
    /// with no panel, no screen and no cursor. The controller keeps the
    /// effects; the rules live here with the state they read.
    enum PointerCrossing: Equatable {
        /// The pointer arrived and Open on Hover is switched on.
        case opens
        /// The pointer left and nothing is holding the panel open.
        case closes
        /// Neither: an arrival that only hands the panel back to the pointer,
        /// or a departure that the pin refuses.
        case standsAsItIs
    }

    /// - Parameter inside: whether the pointer is now within the rect that
    ///   holds the panel open — `NotchGeometry.hoverRect(for:)` while open, the
    ///   collapsed hover rect while shut.
    /// - Parameter dragging: whether a drag session is in flight, in which case
    ///   the arrival is not counted at all. A drag is not a hover: the pointer
    ///   arriving with a file in hand has already said which tab it wants —
    ///   `onDragEntered` selects the Shelf — so the arrival must not reset it.
    ///   It used to, roughly `openDelay` after the file crossed the island,
    ///   which flipped the pane Shelf→Music mid-drag and took `ShelfPane`'s drop
    ///   highlight with it until the drop put it back. Leaving the pin standing
    ///   with it costs nothing: `PointerWatcher.isDragging` already holds the
    ///   panel open for as long as the session runs.
    func pointerCrossed(inside: Bool, dragging: Bool = false) -> PointerCrossing {
        if inside {
            if !dragging { pointerArrived() }
            // The arrival takes the panel back from whatever opened it without
            // a pointer, and it does so *before* the hover-to-open question is
            // asked. Asked first, with the setting off — the default — it
            // returned early and left the pin standing, so a clicked-open panel
            // ignored the pointer leaving and could only be dismissed by
            // clicking somewhere else entirely.
            return Self.opensOnHoverEnabled ? .opens : .standsAsItIs
        }
        // The one place the pointer does not decide — see `holdsOpen`. Asked
        // here rather than inside `NotchController.setOpen` so that the reasons
        // that are not the pointer, like the screen going to sleep, still close
        // a pinned panel.
        return holdsOpen ? .standsAsItIs : .closes
    }

    /// The state half of a click that opens the island. The controller owns the
    /// rest — the active rect, the animation, the pointer watcher.
    ///
    /// - Parameter pointerIsOnPanel: whether the cursor is inside the rect the
    ///   open panel holds itself open from. It normally is, because the island
    ///   sits inside that rect, so a mouse click lands the pointer there by
    ///   definition and the panel needs no pin: leaving is what closes it.
    ///   False only for a click that did not come from the mouse at all — the
    ///   compact island's accessibility action, which VoiceOver fires from the
    ///   keyboard with the cursor wherever it was left.
    func clickOpened(pointerIsOnPanel: Bool) {
        // The tab first. A hover always landed on Music — the island is for
        // glancing at a track, and the other tabs are somewhere to go once it
        // is open, not somewhere to arrive. Skipping it meant a click opened
        // whatever had been left behind and then swapped panes *during* the
        // expansion, which is most of what read as an unsmooth open.
        select(.media)
        // The hover lift goes out with the same animation that opens the panel,
        // rather than snapping off the instant `isOpen` flips.
        isHovering = false
        // Pinning a panel the pointer is already standing on is what broke the
        // walk-away: the pin is only cleared when the pointer *arrives*, and
        // arriving is a transition that had already happened before the click.
        // So the departure was refused by `holdsOpen` and the panel stayed open
        // until something else was clicked (fixed 2026-09-10).
        isPinnedOpen = !pointerIsOnPanel
    }

    /// Raised when the panel was opened with the pointer nowhere near it: ⌥⌘I,
    /// or a click that came from the keyboard rather than the mouse — the
    /// compact island's accessibility action. (There has been no menu item
    /// since 2026-08-25; the app has no menu-bar item at all.) A click from the
    /// pointer deliberately does not pin — see `clickOpened(pointerIsOnPanel:)`.
    ///
    /// Those routes exist so the panel can be reached without a mouse, and the
    /// pointer rule cancels them outright: the cursor is wherever it was left,
    /// the very next sample calls it "away", and the panel folds a third of a
    /// second after opening. A command opens until a command closes — the same
    /// hotkey again, Escape, or a click outside. Hovering onto the panel and
    /// off again hands control back to the pointer, which is what somebody
    /// reaching for it with the mouse means by leaving.
    @Published var isPinnedOpen = false

    /// Whether the body is showing the welcome instead of the selected tab.
    ///
    /// Not a `Tab`: `TabContractTests` asserts exactly five, and a sixth that
    /// exists for one launch is not somewhere to navigate to. The rail keeps its
    /// place beside it — the copy sends the reader to the bottom left, which is
    /// where the rail's Settings icon is, so hiding the rail would leave that
    /// sentence pointing at nothing.
    ///
    /// Lowered by anything that ends the panel it opened, and set by exactly two
    /// things — Get Started and a tab picked out of the rail. Everything else
    /// that takes it off screen leaves `hasCompletedFirstRun` alone, so the
    /// welcome is shown once per account *until it is answered*, not once per
    /// account full stop.
    @Published var isShowingWelcome = false

    /// The welcome has been read. Sets the flag that keeps it from ever coming
    /// back, and lands on Music: the island is for glancing at a track, and the
    /// welcome replaced whatever pane would have been there.
    func dismissWelcome() {
        isShowingWelcome = false
        Self.completeFirstRun()
        select(.media)
    }

    /// A tab the user picked out of the rail.
    ///
    /// Distinct from `select` because `select` is also how the *machinery* moves
    /// the panel to a tab — the pointer arriving, a file being dragged on, a
    /// translation arriving by hotkey — and none of those is an answer to
    /// anything. `pointerArrived()` in particular selects Music, and the pointer
    /// arrives by definition on the way to the Get Started button, so dismissing
    /// the welcome from `select` would have wiped it out from under the cursor
    /// reaching for it. Reaching for a tab is a decision; the pointer crossing
    /// the panel is not.
    func chooseTab(_ tab: Tab) {
        if isShowingWelcome {
            isShowingWelcome = false
            Self.completeFirstRun()
        }
        select(tab)
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

    /// Whether the panel currently holds the keyboard.
    ///
    /// Tracked apart from `tab` because the two come apart in one direction:
    /// clicking into another app drops the claim without changing which tab is
    /// showing, so the text one was typing survives and the panel is free to
    /// collapse. Landing on a tab that types always raises it again — there is
    /// no such thing as a panel that shows a field but cannot receive a key.
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
    /// The session's stores, borrowed rather than owned — see `NotchStores`.
    private let stores: NotchStores

    private var cancellables = Set<AnyCancellable>()

    init(geometry: NotchGeometry, stores: NotchStores) {
        self.geometry = geometry
        self.stores = stores
        self.media = stores.media
        self.shelf = stores.shelf
        self.clipboard = stores.clipboard
        self.screenshotVault = stores.screenshotVault
        self.translator = stores.translator
        self.lyrics = stores.lyrics
        self.localLyricsLibrary = stores.localLyricsLibrary
        self.lyricsCoordinator = stores.lyricsCoordinator
        self.privacy = stores.privacy

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
        Publishers.MergeMany(
            media.$track.map { $0?.key }.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            media.$isPlaying.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            media.$artwork.removeDuplicates { $0 === $1 }.map { _ in () }.eraseToAnyPublisher(),
            // The open header names the app the audio belongs to, and that name
            // can arrive a snapshot late — the pid→name lookup fails on the
            // first poll after a player launches and succeeds on the next —
            // without the track ever changing.
            media.$sourceName.removeDuplicates().map { _ in () }.eraseToAnyPublisher()
        )
        .sink { [weak self] _ in self?.objectWillChange.send() }
        .store(in: &cancellables)

        // A pause that settles folds the island into the notch; playing again,
        // or a different track, brings it back.
        media.$isPlaying.removeDuplicates()
            .combineLatest(media.$track.removeDuplicates { $0?.key == $1?.key })
            .sink { [weak self] isPlaying, track in
                self?.playbackChanged(isPlaying: isPlaying, hasTrack: track != nil, title: track?.title)
            }
            .store(in: &cancellables)

        // A film starting under Music Only folds a paused song's pill at once.
        media.$otherMediaIsPlaying.removeDuplicates().filter { $0 }
            .sink { [weak self] _ in self?.otherMediaStartedPlaying() }
            .store(in: &cancellables)

        // The remaining stores have nothing to paint while collapsed.
        for child in [
            shelf.objectWillChange,
            clipboard.objectWillChange,
        ] {
            child
                .sink { [weak self] _ in
                    guard let self, self.isOpen || self.isDropTargeted else { return }
                    self.objectWillChange.send()
                }
                .store(in: &cancellables)
        }
    }

    func chooseLocalLyricsFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "lrc")!]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? lyricsCoordinator.importLocalFile(at: url)
    }

    func chooseLocalLyricsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? localLyricsLibrary.addFolder(url)
    }

    func removeLocalLyricsFolder(_ url: URL) {
        localLyricsLibrary.removeFolder(url)
    }

    func rescanLocalLyrics() {
        try? localLyricsLibrary.rescanFolders()
    }

    func revealLocalLyricsFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([localLyricsLibrary.storageDirectory])
    }

    func clearImportedLyrics() {
        stores.clearImportedLyrics()
    }

    func clearLyricsBindingsAndTimingCorrections() {
        stores.clearBindingsAndTimingCorrections()
    }

    func dismissUnassignedLyricsOffset(named filename: String) {
        lyrics.dismissUnassignedLegacyOffset(named: filename)
    }

    /// Body this tab takes when open — asked whether it is open yet or not.
    ///
    /// Separate from `bodySize` because the rects are cut one step before the
    /// panel is marked open: `setOpen` grows the interactive area first, so
    /// the pointer never falls through a region the animation has not covered.
    /// Reading a size that returns the notch until `isOpen` flips would hand
    /// that step the collapsed size and leave the whole body drawn but deaf to
    /// the pointer.
    ///
    /// One tab is taller than the rest. Type large enough to read at a glance
    /// leaves room for two lines in the standard body, and two lines is not a
    /// teleprompter — it is a countdown. The extra height buys the paragraph
    /// the reader needs to see coming.
    var openBodySize: CGSize { geometry.expandedSize }

    /// Bumped each time the island is hovered while the Mac is locked.
    ///
    /// The island stays visible over the shield but must never open there, so a
    /// hover has nothing to do — and doing nothing at all reads as a dead app
    /// rather than as a deliberate limit. The pill answers with a short wobble
    /// instead: the same "no, not that" gesture a login field gives a wrong
    /// password, which needs no explaining and cannot be mistaken for the panel
    /// starting to open.
    @Published private(set) var lockedHoverNudges = 0

    func nudgeLockedIsland() {
        guard isLockedPresentation else { return }
        lockedHoverNudges += 1
    }

    /// What a deliberate open command — ⌥⌘I, the translate shortcut, the
    /// welcome — is worth right now.
    ///
    /// Over the shield nothing may open and nothing may take the keyboard. An
    /// open there is not merely invisible-because-covered: `setOpen(true)`
    /// grows the clickable region from the deliberate pill-sized locked rect
    /// (`applyLockedActiveRect`) to the open body, over the password field, and
    /// the translate route would additionally land on a tab that types — a
    /// window the lock presentation deliberately lifted above the shield, now
    /// key and holding the keyboard. `panel.onPress` already refuses exactly
    /// that at the keyboard, and the island's own click refusal answers with
    /// the shake; the commands get the same grammar: refuse, and shake the pill
    /// instead of doing nothing, which would read as a dead app rather than as
    /// a limit.
    ///
    /// A verdict rather than an action, so the sequence — command, refusal,
    /// shake — can be played out in a test with no panel, the same shape as
    /// `PointerCrossing`. The controller keeps the effects.
    enum CommandVerdict: Equatable {
        /// The command runs its ordinary open path.
        case proceed
        /// Over the shield: shake the pill and do nothing else.
        case refuseWithShake
    }

    /// The verdict for `toggle()` and `translate(_:)`, asked before either
    /// touches a tab, the translator, the pin or `setOpen`.
    func verdictForDeliberateOpen() -> CommandVerdict {
        isLockedPresentation ? .refuseWithShake : .proceed
    }



    var compactMediaActivity: CompactMediaActivity {
        CompactMediaActivity(
            hasTrack: media.track != nil,
            isPlaying: media.isPlaying,
            pauseHasSettled: pauseHasSettled
        )
    }

    /// True once a pause has lingered for `NotchMetrics.pausedLinger`, or at
    /// once for a paused track nobody was seen pausing. Reset the moment it
    /// plays again, so resuming brings the pill straight back.
    @Published private(set) var pauseHasSettled = false
    private var pauseSettleTask: Task<Void, Never>?
    /// Whether the last state this saw was a track playing — the only state a
    /// pause can be seen happening from.
    private var lastSawPlaying = false

    /// Decides whether a paused track shows its pill, and for how long.
    ///
    /// The linger exists so a quick resume never flickers the pill away, which
    /// makes it about a pause somebody just made. It used to run for every
    /// paused track the island merely learned about as well: a song adopted
    /// after a relaunch, or re-described while a film owned Now Playing, woke
    /// the island for five seconds with nothing to announce — filmed on
    /// 2026-09-21, the paused song's pill appearing over the notch each time
    /// the owner pressed play on a film. Those rest at once now. A linger
    /// already running is left alone, so re-describing the same pause cannot
    /// cut it short or restart it.
    ///
    /// A different song arriving paused rests too. It used to get a glance,
    /// but with the linger now only a skip's breath long a glance would be a
    /// flicker, and the owner asked for a paused island to stay out of the way.
    func playbackChanged(isPlaying: Bool, hasTrack: Bool, title: String? = nil) {
        let sawPlaying = lastSawPlaying
        lastSawPlaying = isPlaying && hasTrack
        guard hasTrack, !isPlaying else {
            pauseSettleTask?.cancel()
            pauseSettleTask = nil
            if pauseHasSettled { pauseHasSettled = false }
            DebugTrail.note("island: playing=\(isPlaying ? 1 : 0) track=\(hasTrack ? 1 : 0)")
            return
        }
        if sawPlaying {
            pauseSettleTask?.cancel()
            pauseSettleTask = nil
            // Paused while a film plays: the pill has nothing to linger for,
            // the same as a film starting during the linger.
            if media.otherMediaIsPlaying {
                if !pauseHasSettled { pauseHasSettled = true }
                DebugTrail.note("island: paused while other media plays -> rests at once")
                return
            }
            if pauseHasSettled { pauseHasSettled = false }
            DebugTrail.note("island: paused while showing -> lingers \(NotchMetrics.pausedLinger)s")
            pauseSettleTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(NotchMetrics.pausedLinger))
                guard !Task.isCancelled, let self else { return }
                self.pauseSettleTask = nil
                self.pauseHasSettled = true
                DebugTrail.note("island: pause settled -> rests in the notch")
            }
        } else if pauseSettleTask == nil, !pauseHasSettled {
            pauseHasSettled = true
            DebugTrail.note("island: a paused track nobody was seen pausing -> rests at once")
        }
    }

    /// A source Music Only keeps off the island started playing. A pause still
    /// lingering has nothing left to say once a film is playing, so its pill
    /// folds into the notch now rather than hanging over the film for the rest
    /// of its five seconds. A playing song is left alone.
    func otherMediaStartedPlaying() {
        guard pauseSettleTask != nil else { return }
        pauseSettleTask?.cancel()
        pauseSettleTask = nil
        pauseHasSettled = true
        DebugTrail.note("island: other media started playing -> the paused pill folds")
    }

    /// Size of the visible body for the current state.
    var bodySize: CGSize {
        if isOpen || isDropTargeted { return openBodySize }
        return compactMediaActivity.bodySize(
            notchSize: geometry.notchSize,
            peeking: isPeeking,
            // The body the panel would open to, so the pill can never be wider
            // than the panel it turns into.
            bodyWidth: geometry.expandedSize.width
        )
    }

    static let hasCompletedFirstRunKey = "hasCompletedFirstRun"

    /// False exactly once per account. The app has no Dock icon, no menu-bar
    /// item and no window, so a fresh install produces no visible change at
    /// all — and `LSUIElement` keeps it out of Force Quit, so someone who
    /// cannot find the panel cannot quit it either. The welcome is the one
    /// moment that says the app is running and how to reach it.
    static var hasCompletedFirstRun: Bool {
        UserDefaults.standard.bool(forKey: hasCompletedFirstRunKey)
    }

    static func completeFirstRun() {
        UserDefaults.standard.set(true, forKey: hasCompletedFirstRunKey)
    }

    /// Off switch for people who copy images all day and do not want them kept.
    static let saveClipboardImagesKey = "saveClipboardImages"

    /// Defaults to **off**. Turning it on writes a copy of every image that
    /// touches the pasteboard to `~/Pictures/Isla`, and the pasteboard
    /// carries things nobody meant to file: a screenshot of a recovery-code
    /// sheet, a photo synced from a phone. Keeping copies of a user's
    /// clipboard on disk is a decision for the user to make, not a default to
    /// discover afterwards. `ScreenshotVault` caps what it keeps once on.
    static var saveClipboardImagesEnabled: Bool {
        UserDefaults.standard.bool(forKey: saveClipboardImagesKey)
    }

    static let importRecordingsKey = "importRecordings"

    /// Defaults to **on**: a recording the system saved is already the user's
    /// deliberate capture, and the pickup only ever offers what finished after
    /// the app first ran — nothing predating it is vacuumed in. The one system
    /// folder prompt this can raise arrives on the first shelf open, with the
    /// shelf on screen to explain it, and then never again. Off restores the
    /// copy-flow only: drops and clipboard copies still land, disk is never
    /// scanned.
    static var importRecordingsEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: importRecordingsKey) != nil else { return true }
        return defaults.bool(forKey: importRecordingsKey)
    }

    static let showLyricsKey = "showLyrics"

    /// Defaults to **off**. On its own it reaches nothing but this Mac: lyrics
    /// come from files imported here and folders chosen here.
    static var showLyricsEnabled: Bool {
        UserDefaults.standard.bool(forKey: showLyricsKey)
    }

    static let musicOnlyKey = "media.musicOnly"

    /// Defaults to **on**. The island is a music surface — artwork, an
    /// equalizer, lyrics — and a YouTube video or a film drawn there as if it
    /// were a song is noise. With it on, only music and podcast apps, and
    /// anything a player itself labels as audio, reach the island; see
    /// `MediaSourcePolicy`. Off restores every Now Playing session.
    static var musicOnlyEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: musicOnlyKey) != nil else { return true }
        return defaults.bool(forKey: musicOnlyKey)
    }

    static let onlineLyricsKey = "lyrics.onlineEnabled"

    /// Defaults to **off**, and is the only thing in the lyric path that ever
    /// reaches the network.
    ///
    /// A streamed track has no file on this Mac, so no offline lookup can ever
    /// find words for it — which is why this exists at all. Turning it on lets
    /// Isla ask LRCLIB, a free community catalogue that needs no account and no
    /// key, for the words of a track the local library did not match. What
    /// leaves is the title, artist, album and duration; nothing about the
    /// listener, and nothing is uploaded. See `OnlineLyrics`.
    static var onlineLyricsEnabled: Bool {
        UserDefaults.standard.bool(forKey: onlineLyricsKey)
    }

    static let sneakPeekKey = "sneakPeek"

    /// Defaults to on: it is the one thing a notch panel can do that a menu
    /// bar item cannot, and it costs nothing when nothing is playing.
    static var sneakPeekEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: sneakPeekKey) != nil else { return true }
        return defaults.bool(forKey: sneakPeekKey)
    }

    /// How the lock card is finished.
    ///
    /// Glass is what the system's own surfaces do on this OS: the wallpaper
    /// carries through, dimmed only as far as the type needs. Solid is for the
    /// wallpapers glass cannot win against — a bright, busy photograph behind
    /// small white text — and for anybody who simply wants the panel to be a
    /// panel.
    enum LockCardStyle: String, CaseIterable, Identifiable {
        case glass, solid
        var id: String { rawValue }

        var title: String {
            switch self {
            case .glass: return localized("Glass")
            case .solid: return localized("Solid")
            }
        }
    }

    static let lockCardStyleKey = "lockCardStyle"

    static var lockCardStyle: LockCardStyle {
        LockCardStyle(rawValue: UserDefaults.standard.string(forKey: lockCardStyleKey) ?? "") ?? .glass
    }

    static let showOnLockScreenKey = "showOnLockScreen"

    /// Defaults to on: the pill over the lock screen is the closest this app
    /// gets to the iPhone's always-on island, and it shows nothing the lock
    /// screen does not already show — the same track macOS puts in its own
    /// now-playing widget there. Off restores the old behaviour exactly: the
    /// panel sinks under the shield with every other window.
    static var showOnLockScreenEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: showOnLockScreenKey) != nil else { return true }
        return defaults.bool(forKey: showOnLockScreenKey)
    }

    /// Whether a hover opens the panel on its own.
    ///
    /// Off by default. An island that unfolds whenever the cursor crosses the
    /// top of the screen interrupts what is underneath it, and the cursor
    /// crosses the top of the screen constantly — reaching the menu bar, the
    /// traffic lights, a tab. A click is a decision; a hover is traffic.
    nonisolated static let opensOnHoverKey = "opensOnHover"

    nonisolated static var opensOnHoverEnabled: Bool {
        UserDefaults.standard.bool(forKey: opensOnHoverKey)
    }

    /// How long a pointer rests on the notch before the panel opens.
    static let hoverDelayKey = "hoverOpenDelay"

    /// Clamped to what makes sense: below 50ms the panel opens on drive-bys,
    /// above a second it reads as broken.
    static var hoverOpenDelay: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: hoverDelayKey)
        guard stored > 0 else { return NotchMetrics.openDelay }
        return min(max(stored, 0.05), 1.0)
    }

    /// Forces the hand-drawn glass recipe even where Apple's own material
    /// exists.
    ///
    /// The escape hatch for the one surface whose backdrop cannot be checked
    /// from here: the lock card draws above the login shield, which is
    /// protected content, and whether `glassEffect` finds anything to sample
    /// there can only be settled by looking at a locked Mac. If it reads wrong,
    /// `defaults write com.ctimothe.isla drawnGlass -bool true` puts the
    /// recipe back with no rebuild.
    nonisolated static let drawnGlassKey = "drawnGlass"

    nonisolated static var forcesDrawnGlass: Bool {
        UserDefaults.standard.bool(forKey: drawnGlassKey)
    }

    /// How wide the panel's body is drawn.
    nonisolated static let bodyWidthKey = "bodyWidth"

    /// Clamped on read rather than on write: the value can also arrive from
    /// `defaults write` on the command line, and a body wider than the window it
    /// is drawn in is a body with its rail off the edge.
    nonisolated static func bodyWidth(in defaults: UserDefaults = .standard) -> CGFloat {
        let stored = defaults.double(forKey: bodyWidthKey)
        guard stored > 0 else { return NotchMetrics.defaultBodyWidth }
        return min(
            max(CGFloat(stored), NotchMetrics.minimumBodyWidth),
            NotchMetrics.maximumBodyWidth
        )
    }

    /// Persists the width a drag settled on, and returns the width that was
    /// actually persisted so the caller can rebuild against it rather than
    /// against what it asked for. Round first, then clamp: rounding is what
    /// the pane did at this write site before the commit existed (a slider
    /// hands over fractional ticks), and clamping mirrors `bodyWidth(in:)` —
    /// the two have to agree or a commit and a `defaults write` of the same
    /// number would disagree on read, which is the divergence the read-side
    /// clamp exists to prevent.
    ///
    /// `nonisolated` for the same reason the reader is: a default is
    /// thread-safe, and this is the one sanctioned writer of the key.
    nonisolated static func commitBodyWidth(_ width: CGFloat, into defaults: UserDefaults) -> CGFloat {
        let committed = min(
            max(width.rounded(), NotchMetrics.minimumBodyWidth),
            NotchMetrics.maximumBodyWidth
        )
        defaults.set(Double(committed), forKey: bodyWidthKey)
        return committed
    }

    /// `nonisolated` because the geometry is a plain struct built off the main
    /// actor as well as on it, and reading a default is thread-safe.
    nonisolated static var bodyWidth: CGFloat { bodyWidth(in: .standard) }

    /// Keeps the panel out of screenshots and screen recordings.
    static let hideFromCaptureKey = "hideFromCapture"

    /// Defaults to **on**. The panel can be showing clipboard history or a
    /// scratch note, and the cost of the two mistakes is not symmetric: a
    /// hidden panel costs somebody a screenshot they can retake, while a
    /// visible one costs a password read out to a meeting. Somebody who wants
    /// to photograph their island turns it off and takes the picture.
    static var hideFromCaptureEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: hideFromCaptureKey) != nil else { return true }
        return defaults.bool(forKey: hideFromCaptureKey)
    }

    /// Hover and click both land here. A tab that types takes the keyboard
    /// either way: showing a field one cannot type into is worse than briefly
    /// dimming the caret of the window underneath, and the dwell threshold on
    /// the rail already keeps a passing pointer from arriving here at all.
    func select(_ tab: Tab) {
        self.tab = tab
        if tab.needsKeyboard { wantsKeyboard = true }
    }

    /// Whether a pane wants this Escape for itself. Consulted before the panel
    /// folds, so that Escape means the nearest reversible thing first: clear
    /// the translation being typed, hand the keyboard back from the notes.
    /// Pressing it again, with nothing left to undo, closes the panel.
    func consumeEscape() -> Bool {
        switch tab {
        case .translate where !translator.input.isEmpty:
            translator.reset()
            return true
        default:
            return false
        }
    }

    /// A screenshot that arrived on its own — copied elsewhere, or synced
    /// from a phone by Continuity — rather than one the user handed to the
    /// panel directly. It is already on the shelf by the time this is called;
    /// this only decides whether to show it.
    ///
    /// Only switches tabs when the panel is actually open and nobody is
    /// mid-sentence. Switching while collapsed changed nothing anybody could
    /// see, and cost a full pass over the shelf — a `checkResourceIsReachable`
    /// per card plus thumbnail requests — which is exactly how a background
    /// copy from a phone used to raise a Desktop-or-Documents permission
    /// prompt with no visible cause. The shelf's counter shows the new picture
    /// the moment the panel is opened, so nothing is lost by waiting.
    ///
    /// Nor while the welcome is up, for the same reason it waits on a keyboard:
    /// the welcome is drawn over the pane switch, so the shelf would not appear
    /// anyway, and moving the tab underneath it would only light Shelf in the
    /// rail beside a body showing something else. Unlike a drag, a picture that
    /// arrived by itself is nobody asking for anything, so it does not get to
    /// take the welcome down — see `showShelfForDrag()`.
    func receivedScreenshot(at url: URL) {
        guard isOpen, !wantsKeyboard, !isShowingWelcome else { return }
        tab = .shelf
    }

    /// A file the user dropped on the panel by hand — switching to the shelf
    /// is the point, not a side effect to guard against.
    func accept(urls: [URL]) -> Bool {
        shelf.add(urls)
        showShelfForDrag()
        return true
    }

    /// A drag has arrived over the island, or a file has just landed on it.
    /// Puts the body on the shelf and takes the welcome down with it.
    ///
    /// The welcome is drawn *over* the pane switch, so leaving it up made a drop
    /// during the first launch completely invisible: no drop highlight, no card,
    /// no counter — and the `setOpen(true)` that follows a drag early-returns on
    /// the panel the welcome had already opened, so nothing on screen moved at
    /// all and the file looked like it had gone nowhere.
    ///
    /// Deliberately does **not** set `hasCompletedFirstRun`. A drop is a real
    /// interaction with the app, but it is not the user answering the welcome:
    /// their attention was on the file, the pane went away underneath it, and the
    /// thing the welcome exists to say — that Quit lives in Settings, because an
    /// `LSUIElement` app is not in Force Quit — is exactly what somebody who has
    /// only ever dropped a file on the island still does not know. Unanswered,
    /// the next launch asks again, on the same terms as `setOpen(false)`.
    func showShelfForDrag() {
        isShowingWelcome = false
        tab = .shelf
    }
}
