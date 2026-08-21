import AppKit
import Combine

@MainActor
final class NotchViewModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case media, shelf, clipboard, translate, notes, teleprompter, settings
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .media: return "music.note"
            case .shelf: return "tray.full.fill"
            case .clipboard: return "list.clipboard.fill"
            case .translate: return "translate"
            case .notes: return "note.text"
            case .teleprompter: return "text.viewfinder"
            case .settings: return "gearshape.fill"
            }
        }

        var title: String {
            switch self {
            case .media: return localized("Music")
            case .shelf: return localized("Shelf")
            case .clipboard: return localized("Clipboard")
            case .translate: return localized("Translate")
            case .notes: return localized("Notes")
            case .teleprompter: return localized("Teleprompter")
            case .settings: return localized("Settings")
            }
        }

        /// Tabs with a field in them. Landing on one hands it the keyboard, so
        /// that arriving and typing is a single move.
        var needsKeyboard: Bool { self == .translate || self == .notes }

        /// Which rail the icon sits on. The left one carries the original six
        /// and is full — icon height is a ceiling now, not a constant (#26,
        /// #27), so a seventh icon would not overflow the panel, but it would
        /// shrink every icon on the rail to make room, which is the same
        /// objection in a quieter voice. Growth continues in a second column
        /// on the right, which the scratch notes open. Settings joins that
        /// column rather than the content rail: it is not something to hover
        /// past on the way to a track or a calendar, so it sits last,
        /// furthest from the tabs people actually rest on.
        static let leftRail: [Tab] = [.media, .shelf, .clipboard, .translate]
        static let rightRail: [Tab] = [.notes, .teleprompter, .settings]
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
            // Leaving the notes sweeps out the blank ones — they cost one
            // hover to recreate, and a trail of empty cards is the clutter a
            // scratchpad exists to avoid.
            if oldValue == .notes, tab != .notes { notes.leave() }
            // Leaving the tab that types gives the keyboard straight back.
            if !tab.needsKeyboard { wantsKeyboard = false }
            // Leaving the teleprompter stops the scroll and drops the pin, so
            // the panel goes back to obeying the pointer like everything else.
            if oldValue == .teleprompter, tab != .teleprompter { teleprompter.suspend() }
        }
    }

    /// Whether the panel must stay open with no pointer on it.
    ///
    /// This is the one exception to the rule stated at `NotchController.setOpen`
    /// — the pointer decides, always — and it exists because the teleprompter
    /// cannot work under that rule: the whole point is reading while looking at
    /// the camera, hands nowhere near the trackpad. The exception is kept as
    /// narrow as it can be. It applies to one tab, only while the script is
    /// actually moving, and it ends four ways that need no explaining: the
    /// script runs out, a click anywhere outside the panel, leaving the tab, or
    /// anything that closes the panel outright — the space changing, the
    /// display sleeping. (Escape is not among them: the panel only receives key
    /// events on the tabs that take the keyboard, and this is not one of them.)
    var holdsOpen: Bool { (tab == .teleprompter && teleprompter.isRunning) || isPinnedOpen }

    /// Raised when the panel was opened by a deliberate command rather than by
    /// the pointer — the ⌥⌘I hotkey or the menu item.
    ///
    /// Those routes exist so the panel can be reached without a mouse, and the
    /// pointer rule cancels them outright: the cursor is wherever it was left,
    /// the very next sample calls it "away", and the panel folds a third of a
    /// second after opening. A command opens until a command closes — the same
    /// hotkey again, Escape, or a click outside. Hovering onto the panel and
    /// off again hands control back to the pointer, which is what somebody
    /// reaching for it with the mouse means by leaving.
    @Published var isPinnedOpen = false

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
    let notes: NoteStore
    let teleprompter: TeleprompterStore
    let lyrics: LyricsStore
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
        self.notes = stores.notes
        self.teleprompter = stores.teleprompter
        self.lyrics = stores.lyrics
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
    var openBodySize: CGSize {
        tab == .teleprompter ? geometry.tallExpandedSize : geometry.expandedSize
    }

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

    /// How far the notch sits from the middle of its display.
    ///
    /// Zero on every Mac whose cutout is centred, which is all of them — but
    /// the locked window covers the whole screen, and a layout that centres the
    /// pill in that window is quietly assuming the two are the same thing. This
    /// measures it instead.
    var lockedPillOffset: CGFloat {
        guard isLockedPresentation else { return 0 }
        return geometry.notchCenterX - geometry.screen.frame.midX
    }

    var compactMediaActivity: CompactMediaActivity {
        CompactMediaActivity(hasTrack: media.track != nil, isPlaying: media.isPlaying)
    }

    /// Size of the visible body for the current state.
    var bodySize: CGSize {
        if isOpen || isDropTargeted { return openBodySize }
        return compactMediaActivity.bodySize(
            notchSize: geometry.notchSize,
            peeking: isPeeking
        )
    }

    /// Off switch for people who copy images all day and do not want them kept.
    static let saveClipboardImagesKey = "saveClipboardImages"

    /// Defaults to **off**. Turning it on writes a copy of every image that
    /// touches the pasteboard to `~/Pictures/DynamicIsland`, and the pasteboard
    /// carries things nobody meant to file: a screenshot of a recovery-code
    /// sheet, a photo synced from a phone. Keeping copies of a user's
    /// clipboard on disk is a decision for the user to make, not a default to
    /// discover afterwards. `ScreenshotVault` caps what it keeps once on.
    static var saveClipboardImagesEnabled: Bool {
        UserDefaults.standard.bool(forKey: saveClipboardImagesKey)
    }

    static let showLyricsKey = "showLyrics"

    /// Defaults to **off**. This is the app's only network use: turning it on
    /// sends what is currently playing — title, artist, album, and for Spotify
    /// the track id — to three third-party services. That is listening history
    /// leaving the machine, so it is asked for rather than assumed. Off means
    /// no request ever leaves.
    static var showLyricsEnabled: Bool {
        UserDefaults.standard.bool(forKey: showLyricsKey)
    }

    static let sneakPeekKey = "sneakPeek"

    /// Defaults to on: it is the one thing a notch panel can do that a menu
    /// bar item cannot, and it costs nothing when nothing is playing.
    static var sneakPeekEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: sneakPeekKey) != nil else { return true }
        return defaults.bool(forKey: sneakPeekKey)
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
        case .notes where wantsKeyboard:
            wantsKeyboard = false
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
    func receivedScreenshot(at url: URL) {
        guard isOpen, !wantsKeyboard else { return }
        tab = .shelf
    }

    /// A file the user dropped on the panel by hand — switching to the shelf
    /// is the point, not a side effect to guard against.
    func accept(urls: [URL]) -> Bool {
        shelf.add(urls)
        tab = .shelf
        return true
    }
}
