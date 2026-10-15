import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class NotchViewModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case media, shelf, clipboard, translate, settings
        var id: String { rawValue }

        /// The rail's glyph, in its outline form; the rail fills the selected
        /// one, the way a system tab bar does.
        ///
        /// Chosen on 2026-09-21 to replace a set that was, glyph for glyph, the
        /// one the upstream project ships — `music.note`, `tray.full.fill`,
        /// `list.clipboard.fill`, `translate`, `gearshape.fill` — so the rail
        /// read as somebody else's island. Each of these is the system's own
        /// word for its tab: the note, a stack of held things, the pasteboard
        /// glyph macOS puts on Paste, a speech bubble with a letter in it
        /// (localized by the system to the reader's script), and the controls
        /// sliders.
        ///
        /// Music keeps the plain note on purpose. It was tried as `play.circle`,
        /// which read as a button rather than a place, and as
        /// `music.quarternote.3`, which read as busy; the owner asked on the
        /// same day for the simple one back. It is the system's own glyph for
        /// music, free to every Mac app, and with the other four changed the
        /// rail as a whole is no longer anybody else's. `TabContractTests`
        /// keeps those four out.
        var symbol: String {
            switch self {
            case .media: return "music.note"
            case .shelf: return "rectangle.stack"
            case .clipboard: return "doc.on.clipboard"
            case .translate: return "character.bubble"
            case .settings: return "slider.horizontal.3"
            }
        }

        /// Four of the glyphs the rail wore until 2026-09-21, from the upstream
        /// project's own set, kept here only so a test can keep them from
        /// coming back. The fifth, `music.note`, stayed: see `symbol`.
        static let retiredSymbols: Set<String> = [
            "tray.full.fill", "list.clipboard.fill", "translate", "gearshape.fill",
        ]

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
        /// that arriving and typing is a single move. The Clipboard tab's search
        /// field is not one of them: it asks only while it is open
        /// (`NotchViewModel.tabWantsKeyboard`), because a tab that took the
        /// keyboard on arrival would dim the caret of the window underneath
        /// every time somebody glanced at their history.
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

    /// Whose cache the opening refreshes; `.shared` in the app, a test's own
    /// where it counts openings.
    var icons: AppIcons = .shared

    @Published var isOpen = false {
        didSet {
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
                closeClipboardSearch()
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
                // main actor, while the Translate tab is the one on screen (the
                // tab's own arrival does it for the other openings).
                if tab == .translate { translator.speaker.refreshVoices() }
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
            isPeeking = false
        }
    }
    @Published var isDropTargeted = false
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
    private var shelfSelectionOpening: Int?
    /// Whether the Shelf has a selection that was made during this opening — the
    /// `hasSelection` of `claimsDelete`, published so the controller's sink
    /// reads it with the rest of the claim's inputs.
    @Published private(set) var shelfSelectionIsCurrent = false

    private func shelfSelectionChanged(to selection: Set<UUID>) {
        // Stamped from the value the publisher hands over (it announces before
        // it stores), and only while the panel is open: a selection made while
        // shut is not "this opening's".
        shelfSelectionOpening = selection.isEmpty || !isOpen ? nil : openingGeneration
        let current = shelfSelectionOpening == openingGeneration
        if shelfSelectionIsCurrent != current { shelfSelectionIsCurrent = current }
    }
    /// Briefly true when a new track has just arrived and is showing itself.
    @Published var isPeeking = false
    /// The charger or headphones, shown for a moment. See `AmbientActivity`.
    @Published var ambient: AmbientActivity?
    /// True while the shield is up and the panel is presenting the lock-screen
    /// card instead of its normal shell.
    @Published var isLockedPresentation = false
    /// Whether Show on Lock Screen is on, read at each use. The setting lives in
    /// `UserDefaults.standard`; a test that depended on it skipped itself on a
    /// machine with the switch off (re-review 2026-10-15), so it is a closure a
    /// test replaces and production leaves at the real default.
    var showOnLockScreen: () -> Bool = { NotchViewModel.showOnLockScreenEnabled }
    /// A screenshot arrived while another tab was showing; the rail marks the
    /// Shelf until it comes into view.
    @Published private(set) var shelfHasNew = false

    /// The Clipboard tab's kind filter and search field (spec §9.3). Owned here
    /// rather than by the pane because opening the field is a claim on the
    /// keyboard, and every way it ends — a tab change, the panel folding,
    /// Escape — has to reach it from outside the pane.
    let clipboardBrowser = ClipboardBrowser()

    /// Whether `tab` wants the panel to hold the keyboard right now: the tabs
    /// with a field in them, and the Clipboard tab for as long as its search
    /// field is open. The one rule the tab change, a press inside the panel and
    /// the search field's own opening all ask, so they cannot disagree.
    nonisolated static func tabWantsKeyboard(tab: Tab, clipboardSearching: Bool) -> Bool {
        tab.needsKeyboard || (tab == .clipboard && clipboardSearching)
    }

    /// The magnifier in the Clipboard header: the field replaces the filter and
    /// the panel becomes key, the way it does for Translate.
    func openClipboardSearch() {
        guard tab == .clipboard, !isLockedPresentation else { return }
        clipboardBrowser.beginSearch()
        wantsKeyboard = true
    }

    /// Escape, the ⓧ, a tab change and the panel folding: the field goes, what
    /// was typed goes with it, and the keyboard goes back. Only the claim the
    /// search made — Translate's is its own.
    func closeClipboardSearch() {
        guard clipboardBrowser.isSearching else { return }
        clipboardBrowser.endSearch()
        if tab == .clipboard { wantsKeyboard = false }
    }

    /// The Translate editor's frame in the window (top-left origin), for the
    /// panel's I-beam. Zero on every other tab; the pane that reports it is
    /// gone by then and a vanished view sends no last word.
    @Published var textInputRect: CGRect = .zero

    /// Whether the Translate tab shows its History list in place of the two cards
    /// (spec §11): the header's History button toggles it. Memory only, and put
    /// away by a tab change, the panel closing, text arriving by the hot key or
    /// the Service, and Keep History being turned off — each of which is a
    /// moment the person is not looking at a list they opened earlier.
    @Published var translateShowsHistory = false

    /// Keep History turned on or off in Settings (spec §11, §14). Off empties the
    /// list, now: a person who switches remembering off expects the record to go
    /// with it, and the list was only ever in memory. On starts remembering from
    /// the next answer; `Translator.received` reads the switch at that moment.
    func setTranslateKeepHistory(_ enabled: Bool) {
        guard !enabled else { return }
        translator.history.clear()
        translateShowsHistory = false
    }

    /// Speak Button turned off in Settings: whatever is being read stops, since
    /// the control that would stop it is gone (spec §11).
    func setTranslateSpeakButton(_ enabled: Bool) {
        if !enabled { translator.speaker.stop() }
    }

    @Published var tab: Tab = .media {
        didSet {
            if tab == .shelf { shelfHasNew = false }
            if tab == .translate, isOpen { translator.speaker.refreshVoices() }
            if tab != .translate {
                textInputRect = .zero
                // A tab change ends speech and the list (spec §11); the pane's
                // own disappearance stops the voice too, this is the model's
                // half, so it holds without a view on screen.
                translator.speaker.stop()
                translateShowsHistory = false
                translator.revokeOnlineRequest()
            }
            // The shelf can hold files inside the folders macOS guards, and
            // looking at one raises a permission prompt. It is asked here,
            // with the shelf on screen, rather than at launch with nothing to
            // explain it.
            if tab == .shelf { shelf.refreshFromDisk() }
            // The Clipboard search belongs to the Clipboard tab: leaving it
            // closes the field, and with it the claim on the keyboard.
            if tab != .clipboard { clipboardBrowser.endSearch() }
            // A Shelf selection is for the visit it was made in: left standing
            // it would be waiting, with Delete behind it, the next time the
            // Shelf is shown (review 2026-10-15).
            if tab != .shelf { shelf.clearSelection() }
            // Leaving the tab that types gives the keyboard straight back.
            if !Self.tabWantsKeyboard(tab: tab, clipboardSearching: clipboardBrowser.isSearching) {
                wantsKeyboard = false
            }
            // And leaving Music folds the stage, so coming back to the tab
            // lands on the player rather than on a page of words left open
            // three songs ago.
            if tab != .media { isShowingLyrics = false }
        }
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
        }
    }

    /// Where `settingsSection` is remembered. The standard domain in the app; a
    /// test's own suite otherwise.
    let defaults: UserDefaults

    /// Whether the Music tab is showing the full lyrics page instead of the
    /// player.
    ///
    /// It lives here rather than inside `MediaPane` because it is a place the
    /// app can be *sent*, not just a toggle the pane owns: ⌃⌥⌘L opens the panel
    /// straight onto it, and the verification hook does the same without a
    /// pointer. State that only the view holds is state nothing else can ask
    /// for — which is what made the hook an `onAppear` reading an environment
    /// variable rather than a route like every other way in.
    ///
    /// Since the redesign (spec §5.1) this is "the Music tab is on the lyric
    /// column or the tall page" — the lyric page is no longer a pane of its own
    /// but the player's state `C` (or `T`, see `musicPage`).
    @Published var isShowingLyrics = false

    /// The tabs the person has grown to the tall body (spec §6). Memory only: a
    /// relaunch starts every tab collapsed, and neither closing the panel nor
    /// changing tabs touches it — "a tab change keeps each tab's own expansion".
    ///
    /// For the Music tab, expanded means the **tall lyric page**. The player
    /// itself never expands (it has no Expand button), so a Music tab that is
    /// remembered as expanded but is showing the player is 208 tall; the memory
    /// is what the Lyrics button opens onto next (`musicPage`).
    @Published var expandedTabs: Set<Tab> = []

    /// Where the Music tab is: the player, the lyric column, or the tall lyric
    /// page — the one value `MediaPane`'s layout, the header's tools and the
    /// body's height all read.
    var musicPage: PlayerLayout.State {
        Self.musicPage(showingLyrics: showsLyricPage, expandedTabs: expandedTabs)
    }

    /// Whether the lyric page is what the Music tab shows: asked for, and a song
    /// to put it on. With nothing playing the tab is the empty player whatever
    /// was asked (⌃⌥⌘L on a silent Mac), and an empty player is 208 tall with
    /// no lyric tools over it.
    var showsLyricPage: Bool { isShowingLyrics && media.track != nil }

    nonisolated static func musicPage(showingLyrics: Bool, expandedTabs: Set<Tab>) -> PlayerLayout.State {
        guard showingLyrics else { return .player }
        return expandedTabs.contains(.media) ? .tall : .column
    }

    /// The height a tab's body asks for when open (spec §6): 400 when it is
    /// expanded, else 208.
    ///
    /// **Settings is always tall** (release R4, spec §10): 400 whatever the set
    /// holds, because its sidebar of ten sections is what the height is for and
    /// no Expand button reaches it. It is the one tab that must not read
    /// `expandedTabs` — a stray insert (a stored session, a test) leaves it
    /// exactly as tall as it already is.
    nonisolated static func openBodyHeight(
        tab: Tab, showingLyrics: Bool, expandedTabs: Set<Tab>
    ) -> CGFloat {
        switch tab {
        case .media:
            return musicPage(showingLyrics: showingLyrics, expandedTabs: expandedTabs).bodyHeight
        case .shelf, .clipboard, .translate:
            return expandedTabs.contains(tab)
                ? NotchMetrics.tallestBody.height : NotchMetrics.standardBodyHeight
        case .settings:
            return SettingsLayout.bodyHeight
        }
    }

    /// Grows or folds a tab's body. The caller animates (`Theme.expand`); this
    /// is state only, so the rects the controller cuts from `openBodySize` and
    /// the drawn body change on the same turn.
    func setExpanded(_ expanded: Bool, for tab: Tab) {
        // Settings is always 400 (R4, spec §10) and has no Expand button;
        // refusing here keeps a stray call from leaving a remembered "expanded"
        // that would read as a choice nobody made.
        guard tab != .settings else { return }
        if expanded { expandedTabs.insert(tab) } else { expandedTabs.remove(tab) }
    }

    /// Whether the tab on screen is showing its tall body.
    var isCurrentTabExpanded: Bool { openBodySize.height > NotchMetrics.standardBodyHeight }

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
                onlineOn: Self.onlineLyricsEnabled, offset: lyrics.trackOffset, canNudge: canNudge
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
            openSettings: { [weak self] in self?.openLyricsSettings() }
        )
    )

    /// The header's Show Translation tool: there while Translate Lyrics is on in
    /// Settings (spec §5.2). Read through the service, which hears of the switch
    /// from the defaults it is written to.
    var showsTranslationTool: Bool { translation.isEnabled }

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

    /// Why the last lyric import or folder action did not work, said once,
    /// in the section that asked.
    ///
    /// Import LRC, Add Lyrics Folder and Rescan each dropped their error with
    /// `try?`, so a file Isla could not read closed the open panel and
    /// nothing happened at all (G-007). One notice, inline where the action
    /// was taken — under the lyrics page's header, or under Import LRC… in
    /// Settings — and never a second surface for the same failure: the panel
    /// has no toast, and one failure gets one place. The next lyric action
    /// or a track change takes it away.
    struct LyricsNotice: Equatable {
        enum Origin: Equatable {
            case stage
            case settings
        }

        let origin: Origin
        let text: String
    }

    @Published private(set) var lyricsNotice: LyricsNotice?

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
    ///
    /// Music only for an arrival at the *closed* island: that is the glance at a
    /// track the island exists for. A panel already open is not being arrived
    /// at, it is being used — ⌃⌥⌘I opens on whatever tab was left, and the hand
    /// that then went for a Clipboard row had the pane swap to Music under it
    /// (J-008, 2026-10-11). The pin still goes either way: the pointer reaching
    /// the panel is what hands it back, whatever tab it is on.
    func pointerArrived() {
        isPinnedOpen = false
        if !isOpen { select(.media) }
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

    /// Raised when the panel was opened with the pointer nowhere near it: ⌃⌥⌘I,
    /// or a click that came from the keyboard rather than the mouse — the
    /// compact island's accessibility action. (There has been no menu item
    /// since 2026-08-25; the app has no menu-bar item at all.) A click from the
    /// pointer deliberately does not pin — see `clickOpened(pointerIsOnPanel:)`.
    ///
    /// Those routes exist so the panel can be reached without a mouse, and the
    /// pointer rule cancels them outright: the cursor is wherever it was left,
    /// the very next sample calls it "away", and the panel folds a third of a
    /// second after opening. A command opens until a command closes — the same
    /// hotkey again, Escape, a click outside, or ⌘-Tab to another app. Hovering onto the panel and
    /// off again hands control back to the pointer, which is what somebody
    /// reaching for it with the mouse means by leaving.
    @Published var isPinnedOpen = false

    /// Whether a pinned panel holds Escape, through a hot key registered only
    /// for as long as this answers true.
    ///
    /// "Escape" was the first way out the pin promised, and it was false: the
    /// panel is key only while Translate asks for the keyboard, Escape is read
    /// only in `NotchPanel.sendEvent`, so after ⌃⌥⌘I on Music the key went to
    /// the app underneath and the panel stayed up (F-004). Making the panel key
    /// would have answered it at the cost of dimming the frontmost window and
    /// stopping its caret — the very rudeness the never-key panel exists to
    /// avoid — so the pin holds Escape instead, and nothing else.
    ///
    /// It holds less than it could, on purpose:
    /// - **not while the panel is key**: `sendEvent` already reads Escape then,
    ///   and must keep reading it first, because an input method mid-composition
    ///   owns it and Translate spends it on clearing the field;
    /// - **not while this app is active**: Quick Look and AirDrop activate it
    ///   from a Shelf card, and their windows answer Escape themselves;
    /// - **never over the shield**: a key the lock screen's password field does
    ///   not get is one taken from the person unlocking.
    ///
    /// The cost is that the one Escape pressed while a pin stands goes to Isla
    /// and not to the app in front — a vim user reading lyrics loses one
    /// keystroke, the one that also folds the panel they were reading. The pin
    /// ends on that press, and the registration ends with it.
    nonisolated static func claimsEscape(
        pinned: Bool,
        panelHasKeyboard: Bool,
        appIsActive: Bool,
        locked: Bool
    ) -> Bool {
        pinned && !panelHasKeyboard && !appIsActive && !locked
    }

    /// Whether the Shelf holds Delete and ⌘⌫, through hot keys registered only
    /// for as long as this answers true (spec §8.2, owner decision 9).
    ///
    /// The panel is never key outside Translate, so a Delete pressed with the
    /// pointer on the Shelf goes to whatever app is in front, and the key
    /// the spec promises would do nothing. The pinned panel's Escape set the
    /// precedent (`claimsEscape`): a Carbon hot key, which needs no permission
    /// and sees nothing else that is typed, held for exactly as long as the
    /// claim stands.
    ///
    /// **A global Delete is the most expensive key to leave behind** — a
    /// registration that outlives its reason eats the person's Delete in every
    /// app until Isla quits — so the claim is as narrow as it can be made, and
    /// every term is one that must hold *now*:
    /// - the panel is open, on the Shelf, and the welcome is not over it;
    /// - the pointer is on the Shelf pane — leaving it, even to the rail, gives
    ///   Delete back, because that is the person saying their hands are
    ///   elsewhere;
    /// - there is a selection to remove — no selection, no key, so a Delete
    ///   pressed with nothing picked is never swallowed;
    /// - **not while this app is active**: Quick Look and AirDrop activate it,
    ///   and their windows have their own use for the key;
    /// - **never over the shield**.
    ///
    /// A panel that happens to be key needs none of this (`NotchPanel` reads the
    /// key itself), but the claim does not ask: while key, a registration and
    /// `sendEvent` do the same thing, and one fewer term is one fewer way for
    /// the two to disagree.
    nonisolated static func claimsDelete(
        panelOpen: Bool,
        onShelf: Bool,
        pointerOnShelf: Bool,
        hasSelection: Bool,
        appIsActive: Bool,
        locked: Bool
    ) -> Bool {
        panelOpen && onShelf && pointerOnShelf && hasSelection && !appIsActive && !locked
    }

    /// Whether another app coming to the front ends the pin.
    ///
    /// ⌘-Tab is the keyboard's click in another app, and a click in another app
    /// already ends a pin (`NotchController.updatePinnedClickMonitor`). Without
    /// this, switching apps from the keyboard left a pinned panel standing over
    /// the menu bar of the app one had switched to. This app's own activation is
    /// not another app: Quick Look and AirDrop activate Isla from inside a
    /// pinned panel, and the panel must survive that.
    func appActivated(ownPID: pid_t, activatedPID: pid_t) -> Bool {
        isPinnedOpen && activatedPID != ownPID
    }

    /// Whether the body is showing the welcome instead of the selected tab.
    ///
    /// Not a `Tab`: `TabContractTests` asserts exactly five, and a sixth that
    /// exists for one launch is not somewhere to navigate to. The rail keeps its
    /// place beside it — the copy sends the reader to the bottom left, which is
    /// where the rail's Settings icon is, so hiding the rail would leave that
    /// sentence pointing at nothing.
    ///
    /// Lowered by anything that ends the panel it opened, and set by exactly
    /// three things — Get Started, a tab picked out of the rail, and a shortcut
    /// that asks for a tab (⌃⌥⌘T, ⌃⌥⌘L, the Service). Everything else
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

    /// A tab the user picked out of the rail, or asked for by shortcut.
    ///
    /// Distinct from `select` because `select` is also how the *machinery* moves
    /// the panel to a tab — the pointer arriving, a file being dragged on — and
    /// none of those is an answer to anything. A hot key used to count as
    /// machinery too, and its tab opened invisibly behind the welcome (J-018). `pointerArrived()` in particular selects Music on a closed
    /// island, and the pointer arrives by definition on the way to the Get
    /// Started button, so dismissing
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

    /// Text that ⌃⌥⌘T or the "Translate in Isla" service brought, already
    /// through `Translator.prepareCommandInput`. The controller decides
    /// whether the panel may open at all (the lock refusal) and holds it open;
    /// this decides what the pane shows.
    ///
    /// Through `chooseTab`, not `select`: a shortcut is somebody asking for
    /// this tab as much as a click on the rail is, and the welcome prints the
    /// shortcut, so the first thing a new user does with it is press it.
    /// Through `select` the text landed in a field the welcome was covering,
    /// the keyboard went to it unseen and the panel folded (J-018).
    ///
    /// No text leaves the field as it was — an image on the clipboard is not
    /// a reason to throw away a sentence somebody typed — and only the notice
    /// says what happened (F-040).
    func receiveCommandedTranslation(_ prepared: Translator.CommandInput) {
        if let text = prepared.text {
            // Covered again before the text lands. The pane's reveal is keyed
            // to the pane, not to its text, so a pane uncovered for the last
            // thing translated would otherwise show this clipboard's contents
            // in full, and the hot key opens the panel at exactly the moment a
            // shared screen would catch it. Assigned directly rather than
            // through the editor, so this text does not count as typed and
            // stays covered.
            privacy.conceal(TranslatePane.revealID)
            translator.input = text
            // The text lands in the field, and the field is under the list while
            // History is up.
            translateShowsHistory = false
        }
        // After the text: setting `input` clears the notice.
        translator.notice = prepared.notice
        // Spoken too: the keyboard lands in the field, and VoiceOver reads the
        // field, not the line under it, so a blind user would hear the panel
        // open on an unchanged field and nothing about why.
        if let notice = prepared.notice { Announcer.shared.announce(notice) }
        chooseTab(.translate)
    }

    /// Translate, from a Clipboard row's menu (spec §9.2): the entry's text goes
    /// where ⌃⌥⌘T and the service put theirs — through the same preparation
    /// (trimmed, capped, noticed) and the same landing on the Translate tab.
    func translateClipboardText(_ text: String) {
        receiveCommandedTranslation(Translator.prepareCommandInput(text))
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
    /// Whether the wallpaper behind the island is dark, for the key line
    /// (spec §3.3). Owned here rather than by the view so the island and the
    /// open panel read one answer, and so it is computed once per change of
    /// wallpaper rather than once per view.
    let wallpaper: WallpaperToneModel
    /// The colour the cover lends the island: the equalizer's, and the key line's
    /// while music shows (spec §3.4). The fallback until a cover has been read,
    /// and for none.
    @Published private(set) var coverTint = CoverTint.fallback
    /// The machine's audio state for the player's volume slider and Output
    /// menu. Started and stopped by the Music pane while it is on screen — a
    /// listener on CoreAudio costs nothing while nobody looks — and *quiet*
    /// under test: a pane built in a test must never reach the owner's output
    /// devices, even to read them.
    let playerAudio: AudioWatch = PlayerBridge.isRunningTests
        ? AudioWatch(read: { ([], nil, nil) }, readMuted: { false }, installListeners: {}, removeListeners: {})
        : AudioWatch()
    /// The session's stores, borrowed rather than owned — see `NotchStores`.
    private let stores: NotchStores

    private var cancellables = Set<AnyCancellable>()

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
        self.wallpaper = WallpaperToneModel(target: { [geometry] in
            // No screen to ask is no answer: the labs and a process with no
            // window-server session stand a bare screen in for the real one,
            // which reads as an empty frame and must never be asked for a
            // wallpaper.
            geometry.screen.frame.isEmpty ? nil : (geometry.screen, geometry.notchCenterX)
        })

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

        // The key line's wallpaper answer arrives off the main actor and the
        // island redraws when it lands.
        wallpaper.$reading.removeDuplicates()
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // One tint per artwork. A cover already read, and no cover at all, are
        // answered on the spot; a new one is read off the main actor and
        // lands a frame or two after the cover itself, which is never seen —
        // the equalizer takes a colour change as a fade.
        media.$artwork.removeDuplicates { $0 === $1 }
            .sink { [weak self] image in self?.updateCoverTint(for: image) }
            .store(in: &cancellables)

        // A pause that settles folds the island into the notch; playing again,
        // or a different track, brings it back.
        media.$isPlaying.removeDuplicates()
            .combineLatest(media.$track.removeDuplicates { $0?.key == $1?.key })
            .sink { [weak self] isPlaying, track in
                self?.playbackChanged(isPlaying: isPlaying, hasTrack: track != nil, title: track?.title)
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

        // The remaining stores have nothing to paint while collapsed.
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

    private func updateCoverTint(for image: NSImage?) {
        if let known = CoverTint.cachedTint(for: image) {
            if coverTint != known { coverTint = known }
            return
        }
        Task { [weak self] in
            let tint = await CoverTint.resolve(image)
            // Only if this is still the cover on show: a skip can overtake a
            // slow read, and a stale colour on the new song's bars is worse than
            // the fallback it replaces.
            guard let self, self.media.artwork === image, self.coverTint != tint else { return }
            self.coverTint = tint
        }
    }

    /// Turns lyrics on from the lyrics page itself. The headline feature was
    /// off by default behind a switch in Settings, and the page only said so,
    /// so somebody who opened it to find words was sent somewhere else to get
    /// them. The switch stays the same one: this writes the key Settings reads.
    func turnOnLyrics() {
        UserDefaults.standard.set(true, forKey: Self.showLyricsKey)
        lyricsCoordinator.refreshVisibility()
    }

    /// Turns on the LRCLIB lookup from the page that just failed to find a
    /// local file, which is where a streamed song always ends up. The button
    /// carries the disclosure the Settings note does, so pressing it is the
    /// same informed choice as flipping the switch.
    func turnOnOnlineLyrics() {
        UserDefaults.standard.set(true, forKey: Self.onlineLyricsKey)
        lyricsCoordinator.refreshVisibility()
    }

    /// Import LRC, from the lyrics page (`.stage`) or from Settings
    /// (`.settings`), which is where a failure is said.
    ///
    /// The song is read before the open panel runs, because the panel is
    /// modal and a song can end while the listener browses: read after it
    /// returned, the file was bound to whichever song was playing then
    /// (G-013).
    func chooseLocalLyricsFile(from origin: LyricsNotice.Origin) {
        lyricsNotice = nil
        let identity = lyricsCoordinator.currentLocalTrackIdentity
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "lrc")!]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importLocalLyricsFile(at: url, for: identity, from: origin)
    }

    /// The import itself, apart from the panel so it can be tested.
    func importLocalLyricsFile(at url: URL, for identity: LocalTrackIdentity?, from origin: LyricsNotice.Origin) {
        lyricsNotice = nil
        do {
            try lyricsCoordinator.importLocalFile(at: url, for: identity)
        } catch {
            report(Self.importFailure(error), from: origin)
        }
    }

    /// Puts the notice where it was asked for, and says it to VoiceOver: a
    /// line of caption text appearing under a header is easy to miss without
    /// sight, and the open panel that just closed took the focus with it.
    private func report(_ text: String, from origin: LyricsNotice.Origin) {
        lyricsNotice = LyricsNotice(origin: origin, text: text)
        Announcer.shared.announce(text)
    }

    /// What a refused file is told, in the listener's words: the line to
    /// look at when a stamp is broken, and plain text otherwise. The file's
    /// own name is not repeated — they picked it a moment ago.
    static func importFailure(_ error: Error) -> String {
        switch error as? LocalLyricsDocument.Error {
        case .invalidTimestamp(let line)?, .invalidWordOrder(let line)?:
            return localized("Line %d of this file has a time Isla can't read.", line)
        case .emptyTimeline?:
            return localized("This file has no timed lyrics.")
        case nil:
            // Not text in any encoding the library reads, or not readable at
            // all — a file gone, or one macOS will not let Isla open.
            return localized("Couldn't read this file as text.")
        }
    }

    func chooseLocalLyricsFolder() {
        lyricsNotice = nil
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try localLyricsLibrary.addFolder(url)
        } catch {
            // The files inside a folder that was added are listed under its
            // row by the library; this is the folder itself failing.
            report(localized("Couldn't read: %@", url.lastPathComponent), from: .settings)
        }
    }

    func removeLocalLyricsFolder(_ url: URL) {
        lyricsNotice = nil
        localLyricsLibrary.removeFolder(url)
    }

    func rescanLocalLyrics() {
        lyricsNotice = nil
        do {
            try localLyricsLibrary.rescanFolders()
        } catch {
            let names = localLyricsLibrary.selectedFolders.map(\.lastPathComponent)
            report(localized("Couldn't read: %@", names.joined(separator: ", ")), from: .settings)
        }
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
    ///
    /// The height is now per tab (spec §6): 208 standard, 400 when the tab is
    /// expanded. The window is cut for 620 × 400 once and never resized, so only
    /// the rects and the drawn body follow this.
    var openBodySize: CGSize {
        CGSize(
            width: geometry.expandedSize.width,
            height: Self.openBodyHeight(tab: tab, showingLyrics: showsLyricPage, expandedTabs: expandedTabs)
        )
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
        // The shake says "not here" only to someone who can see it, and under
        // Reduce Motion it does not play at all. Every refusal comes through
        // here — the click, ⌃⌥⌘I, the translate and lyrics keys, the AX
        // action — so this is the one place the refusal is also spoken. The
        // announcer's repeat window keeps a click that arrives by two routes
        // to one sentence.
        Announcer.shared.announce(localized("Unlock your Mac to open Isla."))
    }

    /// What the compact island says it is: "Playing: title, artist".
    ///
    /// The pill's accessibility label and the peek's announcement are the
    /// same sentence, kept here so the two cannot drift. Empty with no track,
    /// which the announcer refuses to speak.
    var compactAccessibilityLabel: String {
        guard let track = media.track else { return "" }
        let state = compactMediaActivity == .playing ? localized("Playing") : localized("Paused")
        return "\(state): \(track.title), \(track.artist)"
    }

    /// What a deliberate open command — ⌃⌥⌘I, the translate shortcut, the
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
        /// Every display asleep: do nothing at all. A Shortcut or a Focus
        /// automation ("when AirPods connect, show lyrics") that ran with the
        /// lid shut opened a pinned panel nobody could see, started the media
        /// clock and the player polls for it, and left it pinned open at wake
        /// (J-026). There is no pill on a dark display to shake, so the refusal
        /// has nothing to say. Deferring the open to wake was rejected: the
        /// automation that asked has long finished, and a panel appearing when
        /// the lid opens is a surprise rather than an answer.
        case refuseQuietly
    }

    /// The verdict for the commanded opens — the hot keys, the Shortcuts, the
    /// Translate service — asked before any of them touches a tab, the
    /// translator, the pin or `setOpen`.
    ///
    /// `screensAsleep` is the controller's, which owns the sleep and wake
    /// notifications; it is a parameter rather than a default so a new command
    /// cannot forget to ask. The lock wins when both hold, so the shield keeps
    /// one grammar however the screen happens to be.
    func verdictForDeliberateOpen(screensAsleep: Bool) -> CommandVerdict {
        if isLockedPresentation { return .refuseWithShake }
        if screensAsleep { return .refuseQuietly }
        return .proceed
    }

    /// What a *show* asks for, as against a toggle.
    ///
    /// Show Isla and Show Lyrics used to call the hot keys' toggles, so a
    /// Shortcut or a Focus automation titled *Show* that ran while the panel
    /// was already open closed it, and Show Lyrics folded the words back to
    /// the player (F-024). A show only ever opens. Asked after the lock
    /// verdict, never instead of it.
    enum ShowVerdict: Equatable {
        /// Run the ordinary pinned open.
        case open
        /// Already showing what was asked for: touch nothing, the pin included.
        case alreadyOpen
    }

    /// Show Isla and reopening the app: an open panel, on whatever tab, is
    /// already the panel.
    nonisolated static func showVerdict(isOpen: Bool) -> ShowVerdict {
        isOpen ? .alreadyOpen : .open
    }

    /// Show Lyrics: only the lyrics page itself is already shown. Open on the
    /// player or another tab, it goes on to the words — where ⌃⌥⌘L's toggle
    /// would fold the page instead.
    nonisolated static func showLyricsVerdict(isOpen: Bool, tab: Tab, showingLyrics: Bool) -> ShowVerdict {
        isOpen && tab == .media && showingLyrics ? .alreadyOpen : .open
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
        let media = compactMediaActivity.bodySize(
            notchSize: geometry.notchSize,
            peeking: isPeeking,
            // The body the panel would open to, so the pill can never be wider
            // than the panel it turns into.
            bodyWidth: geometry.expandedSize.width
        )
        guard let ambient else { return media }
        return Self.ambientBodySize(
            ambient, media: media, notchSize: geometry.notchSize, bodyWidth: geometry.expandedSize.width
        )
    }

    /// At least as wide as the moment needs, never narrower than the music
    /// pill it may be standing in for, never wider than the panel. Pure, so
    /// the arithmetic has tests.
    nonisolated static func ambientBodySize(
        _ ambient: AmbientActivity, media: CGSize, notchSize: CGSize, bodyWidth: CGFloat
    ) -> CGSize {
        let width = min(notchSize.width + ambient.extensionWidth, bodyWidth)
        return CGSize(width: max(media.width, width), height: notchSize.height)
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

    static let clipboardHistoryKey = "clipboard.historyEnabled"

    /// Defaults to **on**, as it always was. Clipboard history reads every
    /// copy made while Isla runs. That is the feature, and it is also the one
    /// thing here a person may reasonably not want, so it has a switch.
    /// Before 2026-09-23 the only choices were keeping it or quitting the app.
    /// Off, the poll records nothing, the list is emptied, and the pasteboard
    /// is not read at all unless Save Clipboard Screenshots still needs it.
    static var clipboardHistoryEnabled: Bool { SettingsRowID.clipboardHistory.isOn(in: .standard) }

    func setClipboardHistory(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.clipboardHistoryKey)
        // Everything, pins included: off means nothing is kept (and with Keep
        // Pinned Items on, the file follows the now-empty history).
        if !enabled { clipboard.clearAll() }
        stores.refreshClipboardPolling(settingChanged: true)
    }

    /// The screenshot switch decides polling too, once history is off.
    func refreshClipboardPolling() {
        stores.refreshClipboardPolling(settingChanged: true)
    }

    // MARK: Clipboard: Include Images and Keep Pinned Items (spec §9.4, §14)

    static let clipboardIncludeImagesKey = "clipboard.includeImages"

    /// Defaults to **on** (spec §14): a picture copied while history is on is
    /// kept in memory, 12 at most, and gone when Isla quits. Nothing is written
    /// anywhere and nothing leaves the Mac, which is why this one is allowed to
    /// start on; Save Clipboard Screenshots, which does write, stays off.
    static var clipboardIncludeImagesEnabled: Bool { SettingsRowID.includeImages.isOn(in: .standard) }

    func setClipboardIncludeImages(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.clipboardIncludeImagesKey)
        if !enabled { clipboard.removeImages() }
    }

    static let clipboardKeepPinnedKey = "clipboard.keepPinned"

    /// Defaults to **off** (spec §14): the history is memory only and empties
    /// at quit, and saving even the pins is a decision the person makes. On
    /// writes the pinned text and file entries to one file on this Mac.
    static var clipboardKeepPinnedEnabled: Bool { SettingsRowID.keepPinned.isOn(in: .standard) }

    func setClipboardKeepPinned(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.clipboardKeepPinnedKey)
        clipboard.keepPinnedChanged()
    }

    /// Off switch for people who copy images all day and do not want them kept.
    static let saveClipboardImagesKey = "saveClipboardImages"

    /// Defaults to **off**. Turning it on writes a copy of every image that
    /// touches the pasteboard to `~/Pictures/Isla`, and the pasteboard
    /// carries things nobody meant to file: a screenshot of a recovery-code
    /// sheet, a photo synced from a phone. Keeping copies of a user's
    /// clipboard on disk is a decision for the user to make, not a default to
    /// discover afterwards. `ScreenshotVault` caps what it keeps once on.
    static var saveClipboardImagesEnabled: Bool { SettingsRowID.saveClipboardScreenshots.isOn(in: .standard) }

    static let importRecordingsKey = "importRecordings"

    /// Defaults to **on**: a recording the system saved is already the user's
    /// deliberate capture, and the pickup only ever offers what finished after
    /// the app first ran — nothing predating it is vacuumed in. The one system
    /// folder prompt this can raise arrives on the first shelf open, with the
    /// shelf on screen to explain it, and then never again. Off restores the
    /// copy-flow only: drops and clipboard copies still land, disk is never
    /// scanned.
    static var importRecordingsEnabled: Bool { SettingsRowID.showScreenCaptures.isOn(in: .standard) }

    static let showLyricsKey = "showLyrics"

    /// Defaults to **off**. On its own it reaches nothing but this Mac: lyrics
    /// come from files imported here and folders chosen here.
    static var showLyricsEnabled: Bool { SettingsRowID.showLyrics.isOn(in: .standard) }

    static let musicOnlyKey = "media.musicOnly"

    /// Defaults to **on**. The island is a music surface — artwork, an
    /// equalizer, lyrics — and a YouTube video or a film drawn there as if it
    /// were a song is noise. With it on, only music and podcast apps, and
    /// anything a player itself labels as audio, reach the island; see
    /// `MediaSourcePolicy`. Off restores every Now Playing session.
    static var musicOnlyEnabled: Bool { SettingsRowID.musicOnly.isOn(in: .standard) }

    static let volumeAndOutputKey = "player.volumeAndOutput"

    /// Defaults to **on**, which is an owner-waived exception to the rule that
    /// anything touching a system-wide setting starts off (decision 8, 15 Oct
    /// 2026; checklist.md §"Scope divergence" records it). What
    /// makes it safe: the controls only *read* until a person drags the slider or
    /// picks an output — the volume is not written, and the default output is
    /// not changed, by drawing them. Off hides the slider and the Output button
    /// and the lyric band keeps its place (spec §4.5).
    static var volumeAndOutputEnabled: Bool { volumeAndOutputEnabled(in: .standard) }

    /// The same, read from a given suite: the rule a test holds without touching
    /// the standard domain.
    static func volumeAndOutputEnabled(in defaults: UserDefaults) -> Bool {
        SettingsRowID.volumeAndOutput.isOn(in: defaults)
    }

    static let lyricBandKey = "player.lyricBand"

    /// Defaults to **on**. The sung line and the next one under the title
    /// (spec §4.3); it reaches nothing but the lyrics Show Lyrics already
    /// allows. Off hides the band and the layout takes the no-lyric positions.
    static var lyricBandEnabled: Bool { lyricBandEnabled(in: .standard) }

    static func lyricBandEnabled(in defaults: UserDefaults) -> Bool {
        SettingsRowID.lyricBand.isOn(in: defaults)
    }

    // MARK: Lyric translation (spec §5.3, §14; owner decision 11)

    static let translateLyricsKey = "lyrics.translate"

    /// Defaults to **off** (decision 11). On its own it reaches nothing: the
    /// translation is made on this Mac, and goes to MyMemory only for a pair
    /// nothing here offers and only if Translate Online — its own, older
    /// consent — is on as well (`LyricTranslation`).
    static var translateLyricsEnabled: Bool { translateLyricsEnabled(in: .standard) }

    /// The same, read from a given suite: the rule a test holds without touching
    /// the standard domain.
    static func translateLyricsEnabled(in defaults: UserDefaults) -> Bool {
        SettingsRowID.translateLyrics.isOn(in: defaults)
    }

    static let translateTargetKey = "lyrics.translateTarget"

    /// What Settings stored as the target, if it is still on offer; nil when
    /// nothing was chosen (or the code is no longer one the tab offers).
    static func storedTranslateTarget(in defaults: UserDefaults) -> TranslationLanguage? {
        defaults.string(forKey: translateTargetKey).flatMap(TranslationLanguage.withCode)
    }

    /// The language lyrics are translated into: what was chosen, else the first of
    /// the system's languages the Translate tab offers, else English — the rule
    /// the Translate tab's own default follows (`Translator.defaultTarget`) —
    /// **unless the song is in that language**, when the default is English
    /// (spec §5.3: "the system language when it differs from the lyric's, else
    /// English"). A Russian song on a Russian Mac used to be "translated" into
    /// the language it was already in, and so got nothing; a person who never
    /// opened Settings expected to read it (review 2026-10-15). `songLanguage`
    /// is the detected language of the lyric, nil where there is none to
    /// compare (Settings' own picker). A stored code that is no longer on offer
    /// reads as unset; a stored choice always wins, even the song's own language.
    static func translateTarget(
        in defaults: UserDefaults, preferredLanguages: [String] = Locale.preferredLanguages,
        songLanguage: TranslationLanguage? = nil
    ) -> TranslationLanguage {
        if let stored = storedTranslateTarget(in: defaults) { return stored }
        let system = Translator.defaultTarget(preferredLanguages: preferredLanguages)
        if let songLanguage, songLanguage == system, system != .english { return .english }
        return system
    }

    static let showTranslationKey = "lyrics.showTranslation"

    /// The header's Show Translation switch; **on** when never touched, so
    /// turning Translate Lyrics on shows something. Not in §14's table — it is
    /// the toggle's own memory, so a hidden translation stays hidden across a
    /// launch.
    static func showTranslationEnabled(in defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: showTranslationKey) != nil else { return true }
        return defaults.bool(forKey: showTranslationKey)
    }

    /// The last targets chosen, newest first (`LyricTranslation.record`): the
    /// translation menu's short list. Also outside §14's table.
    static let translateRecentsKey = "lyrics.translateRecents"

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
    static var onlineLyricsEnabled: Bool { SettingsRowID.lookUpLyricsOnline.isOn(in: .standard) }

    static let onlineTranslationKey = "translate.onlineEnabled"

    /// Defaults to **off**, and is the only way Translate sends text anywhere.
    ///
    /// On, a pair no engine on this Mac can translate — Uzbek and Kazakh,
    /// always — is sent to `OnlineTranslation`'s one service. Every pair the
    /// Mac can do itself still stays on it, switch or no switch.
    static var onlineTranslationEnabled: Bool { SettingsRowID.translateOnline.isOn(in: .standard) }

    // MARK: The island's three moments (spec §10: "The island shows")

    /// Charging, Headphones Connecting and New Tracks (redesign 2026-10-15,
    /// spec §10). The rows were called Show Charging, Show Headphones Connecting
    /// and Peek at New Tracks; the spec renames them under the header "The island
    /// shows" and gives each a **new key**, so the value a person already chose
    /// has to cross over once, at launch (`migrateRenamedKeys`) — a switch turned
    /// off on Monday must not come back on after the update.
    static let chargingKey = "island.charging"
    static let headphonesKey = "island.headphones"
    static let newTracksKey = "island.newTracks"

    /// The keys before the rename. Read by `migrateRenamedKeys` and nothing else;
    /// they stay until a release that no longer needs to carry a value across.
    static let legacyShowChargingKey = "island.showCharging"
    static let legacyShowHeadphonesKey = "island.showHeadphones"
    static let legacySneakPeekKey = "sneakPeek"

    /// All three default to **on**. None reaches the network or asks for a
    /// permission: the charge comes from IOKit, the headphones from the CoreAudio
    /// device list the lock card already reads, and a new track from what the
    /// island already shows. New Tracks is the one thing a notch panel can do
    /// that a menu bar item cannot, and it costs nothing when nothing is playing.
    static var chargingEnabled: Bool { chargingEnabled(in: .standard) }
    static func chargingEnabled(in defaults: UserDefaults) -> Bool {
        SettingsRowID.charging.isOn(in: defaults)
    }

    static var headphonesEnabled: Bool { headphonesEnabled(in: .standard) }
    static func headphonesEnabled(in defaults: UserDefaults) -> Bool {
        SettingsRowID.headphones.isOn(in: defaults)
    }

    static var newTracksEnabled: Bool { newTracksEnabled(in: .standard) }
    static func newTracksEnabled(in defaults: UserDefaults) -> Bool {
        SettingsRowID.newTracks.isOn(in: defaults)
    }

    /// Copies each renamed row's old value to its new key — only where the new
    /// key has never been written, so it runs once in effect (the copy is a
    /// write to the new key, and the next launch finds it set) and never
    /// overwrites a choice made after the update. The old key is left where it is:
    /// an older build run beside this one still reads it.
    static func migrateRenamedKeys(in defaults: UserDefaults = .standard) {
        for (old, new) in SettingsTable.renamedKeys {
            guard defaults.object(forKey: new) == nil, let value = defaults.object(forKey: old) else { continue }
            defaults.set(value, forKey: new)
        }
    }

    // MARK: Translate: Keep History and Speak Button (spec §11, §14)

    static let translateKeepHistoryKey = "translate.keepHistory"
    static let translateSpeakButtonKey = "translate.speakButton"

    /// Keep History defaults to **off** (spec §14): the last 20 translations in
    /// memory, gone at quit, never written to disk; turning it on is the person
    /// choosing to be remembered. Release R4's Settings row; the Translate tab
    /// reads it.
    static var translateKeepHistoryEnabled: Bool { translateKeepHistoryEnabled(in: .standard) }
    static func translateKeepHistoryEnabled(in defaults: UserDefaults) -> Bool {
        SettingsRowID.keepHistory.isOn(in: defaults)
    }

    /// Speak Button defaults to **on** (spec §14): it sends nothing anywhere and
    /// changes nothing until pressed.
    static var translateSpeakButtonEnabled: Bool { translateSpeakButtonEnabled(in: .standard) }
    static func translateSpeakButtonEnabled(in defaults: UserDefaults) -> Bool {
        SettingsRowID.speakButton.isOn(in: defaults)
    }

    /// How the lock card is finished.
    ///
    /// Nothing above the login shield can sample the wallpaper, so every style
    /// is a recipe the card draws for itself (`LockScreenCard.glassRouting`).
    /// **Automatic** (redesign 2026-10-15, spec §7.2) is the default when
    /// nothing is stored: the cover's light, today's Tinted recipe, at an
    /// opacity chosen from how bright the wallpaper behind the card is
    /// (`LockCardMaterial.automaticAlpha`) and never under 0.84 (owner
    /// decision 5), because a lighter tint let Aerial's bright lines run
    /// straight through the sung lyric. The other three are what they were:
    /// the most see-through, a tinted pane, and the opaque panel Reduce
    /// Transparency draws — the three steps macOS itself offers for its own
    /// glass. Stored values are kept: "glass" is Tinted, the card's look since
    /// the cover lit it, and a person who chose one keeps it.
    enum LockCardStyle: String, CaseIterable, Identifiable {
        case automatic
        case clear
        case glass
        case solid
        var id: String { rawValue }

        var title: String {
            switch self {
            case .automatic: return localized("Automatic")
            case .clear: return localized("Transparent")
            case .glass: return localized("Tinted")
            case .solid: return localized("Solid")
            }
        }
    }

    /// How much room the lock card takes: the full player, or a shorter one
    /// with three lines of words rather than five.
    enum LockCardSize: String, CaseIterable, Identifiable {
        case standard
        case compact
        var id: String { rawValue }

        var title: String {
            switch self {
            case .standard: return localized("Standard")
            case .compact: return localized("Compact")
            }
        }
    }

    static let lockCardSizeKey = "lockCardSize"

    static var lockCardSize: LockCardSize {
        LockCardSize(rawValue: UserDefaults.standard.string(forKey: lockCardSizeKey) ?? "") ?? .standard
    }

    static let lockCardStyleKey = "lockCardStyle"

    /// The stored choice, or **Automatic** when nothing (or nothing this build
    /// knows) is stored — only the default changed in the redesign (spec §7.2,
    /// §14), so a person who picked Transparent, Tinted or Solid keeps it.
    static func lockCardStyle(in defaults: UserDefaults) -> LockCardStyle {
        LockCardStyle(rawValue: defaults.string(forKey: lockCardStyleKey) ?? "") ?? .automatic
    }

    static var lockCardStyle: LockCardStyle { lockCardStyle(in: .standard) }

    static let restAsBannerKey = "lock.restAsBanner"

    /// Rest as Banner (spec §7.1, §14): on, the song rests on the lock screen as
    /// a slim banner under the clock and a click grows it into the card in place;
    /// off, the card shows directly with no chevron, as it did before the
    /// redesign. **On** when never touched. Read when the lock window is made, so
    /// a switch flipped during a lock applies at the next one, as the card's size
    /// does.
    static func restAsBannerEnabled(in defaults: UserDefaults) -> Bool {
        SettingsRowID.restAsBanner.isOn(in: defaults)
    }

    static var restAsBannerEnabled: Bool { restAsBannerEnabled(in: .standard) }

    static let showOnLockScreenKey = "showOnLockScreen"

    /// Defaults to on: the pill over the lock screen is the closest this app
    /// gets to the iPhone's always-on island, and it shows nothing the lock
    /// screen does not already show — the same track macOS puts in its own
    /// now-playing widget there. Off restores the old behaviour exactly: the
    /// panel sinks under the shield with every other window.
    static var showOnLockScreenEnabled: Bool { SettingsRowID.showOnLockScreen.isOn(in: .standard) }

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
    static var hideFromCaptureEnabled: Bool { SettingsRowID.hideFromRecording.isOn(in: .standard) }

    /// Hover and click both land here. A tab that types takes the keyboard
    /// either way: showing a field one cannot type into is worse than briefly
    /// dimming the caret of the window underneath, and the dwell threshold on
    /// the rail already keeps a passing pointer from arriving here at all.
    func select(_ tab: Tab) {
        self.tab = tab
        if tab.needsKeyboard { wantsKeyboard = true }
    }

    /// Settings, on `section`. The section goes first so the pane that appears
    /// for the tab change finds it already selected; every route in — the Music
    /// tab's remedy, the lyric menu's "Lyrics Settings…", a future one — is this.
    func openSettings(at section: SettingsSection) {
        settingsSection = section
        select(.settings)
    }

    /// The Music tab's remedy when Music Only keeps a playing source off the
    /// island: Settings, on the Music section, where Music Only is the first
    /// switch that is not a failure.
    func openMusicOnlySetting() {
        openSettings(at: .music)
    }

    /// "Lyrics Settings…" in the More menu (spec §5.2): Settings, on the Lyrics
    /// section (R4 gave the lyric switches a section of their own; until then
    /// they were rows of Music's and this pointed at the Music section's top).
    func openLyricsSettings() {
        openSettings(at: .lyrics)
    }

    /// Whether a pane wants this Escape for itself. Consulted before the panel
    /// folds, so that Escape cancels the nearest thing first and only the
    /// press after that, with nothing left to cancel, closes the panel.
    ///
    /// An armed two-press confirmation goes first (owner decision 3): Escape
    /// is cancel on macOS, and it used to fold the panel around a red "Clear
    /// Everything" instead of taking the question back. Disarming loses
    /// nothing.
    ///
    /// Then the text being typed into Translate, which this clears — the way
    /// a search field and Spotlight spend a first Escape (owner decision 15).
    /// That one is not reversible: there is no undo for the cleared field, and
    /// an earlier version of this comment said otherwise.
    func consumeEscape() -> Bool {
        if ArmedConfirmations.shared.disarmAll() { return true }
        switch tab {
        // An open History list is the nearest thing to cancel (spec §11); the
        // text under it is untouched.
        case .translate where translateShowsHistory:
            translateShowsHistory = false
            return true
        case .translate where !translator.input.isEmpty:
            translator.reset()
            return true
        // The open search field takes the first Escape (spec §9.3), so Escape
        // in a field means "stop searching" and never "close the panel".
        case .clipboard where clipboardBrowser.isSearching:
            closeClipboardSearch()
            return true
        default:
            return false
        }
    }

    /// ⇧⌘C, asked by the panel before the source field gets the key (H-018).
    /// Returns false when there is no translation on screen — another tab, or
    /// no answer yet — and the key falls back to an ordinary copy.
    ///
    /// An answer to text since edited claims the key and copies nothing: the
    /// Copy button is disabled in that window (K-004), and the key does what
    /// the disabled button does rather than quietly copying the source in the
    /// translation's place.
    ///
    /// Announced here rather than by the button, which only speaks for its
    /// own presses; the button still ticks, through `outputCopies`.
    func copyTranslationIfShowing() -> Bool {
        guard tab == .translate, !translator.output.isEmpty else { return false }
        if translator.copyOutput() {
            Announcer.shared.announce(localized("Copied"))
        }
        return true
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
    ///
    /// Nor when the shelf is already showing: the new card is on screen the
    /// moment `add` puts it there, and assigning the tab again re-ran
    /// `refreshFromDisk` — a reachability check and a fresh QuickLook request
    /// for every card, each preview landing as a whole-panel redraw.
    ///
    /// It no longer switches tabs at all (owner decision 14, FOC-01). A tab
    /// that changes under somebody who is reading the clipboard, or whose
    /// VoiceOver cursor is in it, is the app moving the user for something the
    /// user did not ask for. The only reason it ever moved was visibility, and
    /// the rail already has a mark for exactly that: the Shelf wears a dot
    /// until it is looked at. A drag or a drop is still a user action and still
    /// switches (`showShelfForDrag`).
    func receivedScreenshot(at url: URL) {
        guard tab != .shelf else { return }
        shelfHasNew = true
    }

    /// A file the user dropped on the panel by hand — switching to the shelf
    /// is the point, not a side effect to guard against.
    ///
    /// Usually it is already there: the drag that carried the files put the
    /// shelf up and refreshed it, and `add` loads the new cards' previews
    /// itself, so showing it again only redid the whole pass over the shelf.
    /// The welcome still comes down if the drop beat it.
    func accept(urls: [URL]) -> Bool {
        shelf.add(urls)
        if tab != .shelf {
            showShelfForDrag()
        } else if isShowingWelcome {
            isShowingWelcome = false
        }
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
    ///
    /// Assigning the tab is what refreshes the shelf, so it is assigned only
    /// when the shelf is really coming into view. A drag leaving the island and
    /// crossing back is another `draggingEntered`, and so is every later drag,
    /// and each one used to pass over the whole shelf again — a reachability
    /// check and a fresh QuickLook request per card. A panel left closed on the
    /// shelf is the other case: the drag is about to open it there, and that is
    /// the shelf coming into view.
    func showShelfForDrag() {
        let shelfInView = isOpen && tab == .shelf && !isShowingWelcome
        isShowingWelcome = false
        guard !shelfInView else { return }
        tab = .shelf
    }
}
