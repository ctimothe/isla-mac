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
    /// actually moving, and it ends three ways that need no explaining: the
    /// script runs out, Escape, or a click anywhere outside the panel.
    var holdsOpen: Bool { tab == .teleprompter && teleprompter.isRunning }

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
    let privacy = PrivacyMode()

    private var cancellables = Set<AnyCancellable>()

    init(geometry: NotchGeometry) {
        self.geometry = geometry
        self.media = MediaController()
        self.shelf = ShelfStore()
        self.clipboard = ClipboardStore()
        self.screenshotVault = ScreenshotVault()
        self.translator = Translator()
        self.notes = NoteStore()
        self.teleprompter = TeleprompterStore()
        self.lyrics = LyricsStore()

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
        media.objectWillChange
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

    /// Defaults to on: the feature is the reason the folder exists.
    static var saveClipboardImagesEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: saveClipboardImagesKey) != nil else { return true }
        return defaults.bool(forKey: saveClipboardImagesKey)
    }

    static let showLyricsKey = "showLyrics"

    /// Defaults to on. This is the app's only network use, so the switch is
    /// the honest one: off means no request ever leaves.
    static var showLyricsEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: showLyricsKey) != nil else { return true }
        return defaults.bool(forKey: showLyricsKey)
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

    /// Defaults to off, despite the panel being able to hold a clipboard and
    /// scratch notes. Excluding a window from capture also excludes it from the
    /// user's own screenshots, and somebody photographing their island to show
    /// somebody else is a likelier need than somebody screen-sharing it by
    /// accident. Offered rather than assumed.
    static var hideFromCaptureEnabled: Bool {
        UserDefaults.standard.bool(forKey: hideFromCaptureKey)
    }

    /// Hover and click both land here. A tab that types takes the keyboard
    /// either way: showing a field one cannot type into is worse than briefly
    /// dimming the caret of the window underneath, and the dwell threshold on
    /// the rail already keeps a passing pointer from arriving here at all.
    func select(_ tab: Tab) {
        self.tab = tab
        if tab.needsKeyboard { wantsKeyboard = true }
    }

    func start() {
        media.start()
        shelf.load()

        // Screenshots reach the shelf through here whether they were taken on
        // this Mac or on a phone: a copy made on the phone arrives in the same
        // pasteboard, carried over by Continuity.
        //
        // The switch is asked by the store before it touches image data, not
        // here after the fact: turned off, a copied picture used to be encoded
        // to PNG in full just to be dropped on this doorstep — pure heat on
        // exactly the machines whose owners turned the feature off.
        clipboard.wantsImages = { Self.saveClipboardImagesEnabled }
        clipboard.onImage = { [weak self] png in
            guard let self, let url = self.screenshotVault.save(png) else { return }
            self.receivedScreenshot(at: url)
        }
        clipboard.start()
    }

    func stop() {
        media.stop()
        clipboard.stop()
        // Whatever was typed makes it to disk even when quitting mid-thought.
        notes.flush()
        teleprompter.flush()
    }

    /// A screenshot that arrived on its own — copied elsewhere, or synced
    /// from a phone by Continuity — rather than one the user handed to the
    /// panel directly. It goes on the shelf either way, but only switches to
    /// showing it when nobody is mid-sentence: the tab's own field would
    /// slide out from under the caret, and losing the keyboard mid-word sends
    /// the rest of the sentence to whatever is underneath. The shelf's
    /// counter already shows the new picture, so nothing about it is lost by
    /// waiting.
    func receivedScreenshot(at url: URL) {
        shelf.add([url])
        guard !wantsKeyboard else { return }
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
