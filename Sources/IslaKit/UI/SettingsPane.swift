import AppKit
import SwiftUI
import ServiceManagement

/// Settings: a sidebar of ten sections and a grouped form, in the tall body
/// (redesign 2026-10-15, spec §10).
///
/// It was every setting the app has in one scrolling list, 162 pt of window onto
/// about a thousand points of rows, with Quit at the bottom of it (H-003). Now the
/// body is 400 tall whatever the person expanded elsewhere, the left column is the
/// ten sections of `SettingsSection`, and the right is `SettingsTable.blocks` laid
/// out as System Settings lays out a pane: headers, cards of 28 pt rows, footnotes
/// under them, push buttons at the trailing edge.
///
/// **The table decides, this draws.** Which rows a section has, in what order,
/// under which header, with which footnote, is `SettingsTable`; this view owns
/// only what each row *does* — where a switch reads and writes, what a push button
/// calls — so the whole shape of the form is a test that needs no view.
struct SettingsPane: View {
    @ObservedObject var shelf: ShelfStore
    let screenshotVault: ScreenshotVault
    @ObservedObject var lyrics: LyricsStore
    /// Held, not observed. The pane reads one published field of it,
    /// `fallbackReason`, and receives that one below. Observing the whole
    /// controller re-evaluated this, the largest pane in the app, on each of
    /// the clock's ten ticks a second while music played (F-015). Diagnostics
    /// and Try Again only call into it.
    let media: MediaController
    @ObservedObject var localLyrics: LocalLyricsLibrary
    var onLyricsVisibilityChanged: () -> Void = {}
    var importLocalLyrics: () -> Void = {}
    /// Why the last Import LRC…, Add Lyrics Folder… or Rescan from here did
    /// not work, said under Import LRC…. See `NotchViewModel.LyricsNotice`.
    var lyricsNotice: String? = nil
    var addLocalLyricsFolder: () -> Void = {}
    var removeLocalLyricsFolder: (URL) -> Void = { _ in }
    var rescanLocalLyrics: () -> Void = {}
    var openLocalLyricsFolder: () -> Void = {}
    var clearImportedLyrics: () -> Void = {}
    var clearBindingsAndTimingCorrections: () -> Void = {}
    var dismissUnassignedLyricsOffset: (String) -> Void = { _ in }
    @ObservedObject var privacy: PrivacyMode
    /// The panel's claim on the keyboard, which recording a shortcut needs.
    var wantsKeyboard: Binding<Bool> = .constant(false)
    @ObservedObject var hotKeys: HotKeyCenter = .shared
    @ObservedObject var updates: UpdateCheck = .shared
    /// Observed so the "Following your Mac" line appears and goes with the
    /// System Settings switches it names.
    @ObservedObject private var appearance: SystemAppearance = .shared
    /// Observed: its one published field changes when macOS answers a
    /// read-only check or a script is refused, a handful of times a session,
    /// never on the media clock's tick. A test passes its own, so nothing it
    /// draws depends on what the runner's Mac has granted.
    @ObservedObject var automation: AutomationAccess = .shared
    /// Observed so a refresh that finds a newly installed (or removed) player
    /// redraws the rows and the Spotify head. Asked through its cache: the
    /// system is consulted once per app between refreshes, never per render.
    /// A test passes its own, so what the pane draws never depends on the
    /// apps the runner's Mac has installed.
    @ObservedObject var icons: AppIcons = .shared
    var setClipboardHistory: (Bool) -> Void = { _ in }
    var setClipboardIncludeImages: (Bool) -> Void = { _ in }
    var setClipboardKeepPinned: (Bool) -> Void = { _ in }
    var refreshClipboardPolling: () -> Void = {}
    /// Keep History and Speak Button (spec §11): the switch itself is written by
    /// `flagBinding`; these are what turning it off does to a list and a voice.
    var setTranslateKeepHistory: (Bool) -> Void = { _ in }
    var setTranslateSpeakButton: (Bool) -> Void = { _ in }
    /// The section on screen: a binding to `NotchViewModel.settingsSection`, which
    /// is also what the next open restores. Constant in the tests and the lab,
    /// where a test names the section it wants to look at.
    var selection: Binding<SettingsSection> = .constant(.default)
    /// The header strip's height, so the sidebar and the form stay where the
    /// board puts them (body y 46) on a Mac whose notch is not 38 pt tall.
    var headerHeight: CGFloat = PlayerLayout.referenceHeaderHeight
    /// Where switches are read and written: the standard domain in the app, a
    /// test's own suite in a test, so pressing one never reaches the owner's.
    var settingsDefaults: UserDefaults = .standard

    @State private var flags: [SettingsRowID: Bool] = [:]
    @State private var launchAtLogin = LaunchAtLogin.read()
    @State private var hoverDelay = NotchViewModel.hoverOpenDelay
    @State private var bodyWidth = NotchViewModel.bodyWidth
    @State private var lockCardStyle = NotchViewModel.lockCardStyle
    @State private var lockCardSize = NotchViewModel.lockCardSize
    /// Read from `settingsDefaults` when the pane appears: a property initializer
    /// cannot see it, and reading the standard domain here put a test's pane on
    /// the owner's choice.
    @State private var translateTarget = LyricTranslation.TargetChoice.automatic
    /// Observed, not snapshotted: the connect flow completes in the browser
    /// long after this pane rendered, and a one-shot copy of isConnected sat
    /// on "Connect" forever while the tokens were already in the keychain.
    @ObservedObject private var spotify = SpotifyAccount.shared
    @State private var screenshotUsage: (files: Int, bytes: Int64) = (0, 0)
    /// True from the confirming click until the vault says the files reached
    /// the Trash. The row is disabled meanwhile: the size it names is stale
    /// until then, and a second confirm would only queue a clear of nothing.
    @State private var clearingScreenshots = false
    /// When the report was last copied, so the row can say it worked. A copy
    /// has no other visible result.
    @State private var diagnosticsCopied: Date?
    @State private var collectingDiagnostics = false
    /// `media.fallbackReason`, received on its own — see `media`. A
    /// `@Published` publisher hands over its current value on subscription,
    /// so a pane that appears with the reader already down says so at once.
    @State private var fallbackReason: NowPlayingRouteFailure?

    static let localLyricsPrivacyCopyKey = "Lyrics stay on this Mac."

    // The Privacy card's notes are static so a test can read exactly what the
    // pane draws, and each literal sits inside `localized(...)` so
    // test-localizations.sh sees it used.

    /// Under the two cover switches: what covering looks like and when it
    /// comes back, so turning one on is not a leap into an unknown state.
    static var privacyCoversNote: String {
        localized("Covered text shows as moving dots until you click it, and is covered again when the panel closes.")
    }

    /// Under Hide from Screen Recording, always shown. The switch is
    /// `sharingType = .none` on the panel and nothing more, and whether
    /// ScreenCaptureKit capture on macOS 26 and 27 honours that is unproven
    /// until live session S7 (F-008). A default-on privacy switch that might
    /// not hold has to say so, and point at the covers, which work whatever
    /// the capture path is.
    static var hideFromCaptureNote: String {
        localized("Asks macOS to leave Isla out of screenshots, recordings and screen sharing. Some sharing apps may still show it, so cover Clipboard and Translate before you share.")
    }

    /// Under Include Images and Keep Pinned Items: where the history lives and
    /// what the one switch that saves anything saves (spec §9.4).
    static var clipboardMemoryNote: String {
        localized("History is kept in memory and empties when Isla quits. Keep Pinned Items saves only your pins, on this Mac.")
    }

    /// The note under Clipboard History while it is off. "Copies are not
    /// read" was false whenever Save Clipboard Screenshots was on, because
    /// that switch keeps the pasteboard poll running by itself
    /// (`NotchStores.clipboardShouldPoll`) and every copy is still looked at
    /// for an image (J-001).
    static func clipboardOffNote(imagesOn: Bool) -> String {
        imagesOn
            ? localized("Copied text is not kept. Copies are still checked for screenshots while Save Clipboard Screenshots is on.")
            : localized("Copies are not read or kept. Turning it off emptied the list.")
    }

    /// One line of the Music section's Automation block.
    enum AccessRow: Hashable {
        /// A player and where macOS stands on Isla scripting it. The bundle
        /// identifier travels with the name so the row finds its icon by it,
        /// not by matching a display name that a rename would break.
        case status(player: String, bundleID: String, state: String)
        case note(String)
        /// Opens Privacy & Security › Automation in System Settings.
        case openAutomationSettings
    }

    /// Where a refusal can be undone. An anchor a later macOS no longer knows
    /// still opens System Settings, so the action degrades to one more click
    /// rather than to nothing.
    static let automationSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!

    /// One line of the Spotify section.
    enum SpotifyRow: Hashable {
        case note(String)
        case connect
        /// Disconnect, armed by a first press like Clear and Quit.
        case confirm(title: String, armedTitle: String)
        case importAccount
    }

    /// What the Spotify section shows, as a pure function of the account so the
    /// branching is tested without a view. The section used to be inline and
    /// read none of `needsReconnect`, `signInOutcome` or the sign-in problems,
    /// so a revoked grant, a cancelled approval and a browser that never opened
    /// all looked like a Connect button that did nothing; and Disconnect, the
    /// account's one action, happened on a single unconfirmed click.
    ///
    /// Order: what just happened, then the action, then storage, refusal, what
    /// disconnecting keeps, and what the lock-screen heart does. One event gets
    /// one note: an outcome replaces the reconnect note instead of stacking
    /// under it.
    static func spotifyRows(
        connected: Bool,
        needsReconnect: Bool,
        signIn: SpotifyAccount.SignInOutcome?,
        apiBlocked: Bool,
        problem: SpotifyAccount.SignInProblem? = nil,
        canImport: Bool = false,
        storage: TokenStore.Backing = .keychain,
        refusal: SpotifyAccount.Refusal? = nil
    ) -> [SpotifyRow] {
        var rows: [SpotifyRow] = []
        if let problem { rows.append(.note(problem.explanation)) }
        switch signIn {
        case .cancelled:
            rows.append(.note(localized("Spotify sign-in was cancelled.")))
        case .expired, .failed:
            rows.append(.note(localized("Spotify sign-in did not finish. Try connecting again.")))
        case nil:
            if needsReconnect, !connected {
                rows.append(.note(localized("Spotify ended Isla's access. Connect again to use Liked Songs.")))
            }
        }
        if connected {
            rows.append(.confirm(title: localized("Disconnect Spotify Account"), armedTitle: localized("Disconnect")))
        } else {
            rows.append(.connect)
        }
        // Offered only when there is actually something to bring across.
        // Finding that out asks the keychain for attributes and never for
        // contents, so the offer itself costs no prompt — pressing it is what
        // asks, once.
        if canImport { rows.append(.importAccount) }
        if connected {
            switch storage {
            case .keychain: rows.append(.note(localized("Stored in your keychain.")))
            case .file: rows.append(.note(localized("Stored in a file only you can read.")))
            case .unavailable: rows.append(.note(localized("Cannot be stored on this Mac.")))
            }
            // Said whenever a refusal has hidden the lock-screen heart, with the
            // sentence for what Spotify said: a permission when it named one, the
            // generic "refused this account's library request" when it did not.
            // The generic line was dropped once, on the reasoning that an `.other`
            // 403 is not known to be about permission, and the heart then
            // vanished from the lock screen with no word anywhere — a control
            // that disappears owes a sentence. The sentence claims only what is
            // known (a refusal), which is why `.other` can say it. There is no
            // "Liked Songs: Allowed" value row beside it: that began as "Allowed"
            // before the API had been asked anything.
            if apiBlocked, let refusal { rows.append(.note(refusal.explanation)) }
            rows.append(.note(localized("Isla forgets the account on this Mac. Your Spotify library stays as it is.")))
            rows.append(.note(localized("The heart on the lock screen adds the song to your Liked Songs.")))
        }
        return rows
    }

    /// What the Music section says about Automation, from what
    /// `AutomationAccess` already knows — reading it costs no prompt.
    ///
    /// Refusing Automation took away shuffle, repeat, the heart and precise
    /// lyrics without a word, and on the fallback it hid a playing Spotify
    /// behind a paused Music track (J-027): the only sign was a control that
    /// was not there. So each player whose state Isla actually read gets a
    /// row, and a refusal gets the one sentence and the one action that undo
    /// it. `.unknown` — a player that is not running answers the read-only
    /// check with procNotFound — gets nothing: a guess drawn as a state is
    /// worse than no row (M-38).
    static func automationRows(_ statuses: [PlayerApp: AutomationConsent]) -> [AccessRow] {
        var rows: [AccessRow] = []
        for app in PlayerApp.allCases {
            let state: String
            switch statuses[app] ?? .unknown {
            case .allowed: state = localized("Allowed")
            case .denied: state = localized("Not allowed")
            case .notAsked: state = localized("Not asked yet")
            case .unknown: continue
            }
            rows.append(.status(player: app.displayName, bundleID: app.bundleID, state: state))
        }
        if statuses.values.contains(.denied) {
            rows.append(.note(localized("Isla cannot read a player it is not allowed to control. Allow Isla under Privacy & Security › Automation.")))
            rows.append(.openAutomationSettings)
        }
        return rows
    }

    /// Where Acknowledgements… goes: the third-party notices the bundle ships
    /// (`Scripts/bundle.sh` copies `THIRD_PARTY_NOTICES.md` into
    /// `Contents/Resources/Licenses`), which carry the MIT attribution the
    /// upstream project this app began as requires. Nil outside a bundle.
    static func acknowledgementsURL(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md", subdirectory: "Licenses")
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { proxy in
            let bodyWidth = PlayerLayout.bodyWidth(paneWidth: proxy.size.width)
            // The board's y of 46 less the header: a Mac with a shorter notch
            // has a taller pane and the same screen position.
            let top = SettingsLayout.contentTop - headerHeight
            let formX = SettingsLayout.formLeading - PlayerLayout.paneLeading
            let formWidth = SettingsLayout.formWidth(bodyWidth: bodyWidth)
            ZStack(alignment: .topLeading) {
                SettingsSidebar(selection: selection, icons: icons)
                    .offset(y: top)
                // The hairline between the two, 5 pt past the sidebar.
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(width: 0.5, height: max(0, proxy.size.height - top))
                    .offset(x: SettingsLayout.dividerLeading - PlayerLayout.paneLeading, y: top)
                    .accessibilityHidden(true)
                form(width: formWidth, narrow: SettingsLayout.isNarrow(bodyWidth: bodyWidth))
                    .frame(width: formWidth, height: max(0, proxy.size.height - top), alignment: .topLeading)
                    .offset(x: formX, y: top)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        // Live state, not a snapshot taken once at launch: System Settings can
        // flip Launch at Login from outside, and the folder can empty or fill
        // between visits to this tab (#11 taught the same lesson for the menu
        // this replaces).
        .onAppear {
            // Also how the approval note clears: the way back from Open
            // Login Items… is to reopen this tab.
            launchAtLogin = LaunchAtLogin.read()
            // Every switch is read afresh: Save Clipboard Screenshots and Show
            // Screen Captures are also written by the Shelf's own prompts.
            flags = [:]
            translateTarget = LyricTranslation.TargetChoice.current(in: settingsDefaults)
            lockCardStyle = NotchViewModel.lockCardStyle(in: settingsDefaults)
            lockCardSize = NotchViewModel.LockCardSize(
                rawValue: settingsDefaults.string(forKey: NotchViewModel.lockCardSizeKey) ?? ""
            ) ?? .standard
            refreshUsage()
            // The answer can change in System Settings while Isla is not
            // looking, and the way back from Open Automation Settings… is
            // to reopen this tab. Read-only and off the main thread; it never
            // prompts.
            automation.refresh()
            // No `icons.refresh()` here. This closure runs after the first
            // render, which has already filled the cache, so clearing it made
            // every opening resolve each player twice on the main actor. The
            // panel refreshes the cache once as it opens
            // (`NotchViewModel.isOpen`), before anything draws.
        }
        .onReceive(media.$fallbackReason) { fallbackReason = $0 }
    }

    // MARK: - The form

    /// What decides the form's shape right now: every condition a block depends
    /// on, read from the state it lives in.
    private var context: SettingsContext {
        var c = SettingsContext()
        c.hasBattery = AmbientWatch.hasBattery
        c.opensOnHover = flag(.openOnHover)
        c.launchNote = LaunchAtLogin.note(launchAtLogin)
        c.offersLoginItems = launchAtLogin.offersLoginItems
        c.followingYourMac = followingYourMacLine
        c.clipboardHistoryOn = flag(.clipboardHistory)
        c.screenshotsKeepPolling = flag(.saveClipboardScreenshots)
        var notes = HotKeyAction.allCases.filter { hotKeys.refused.contains($0) }.map { action in
            localized("macOS would not register %@. Choose another shortcut.", hotKeys.bindings[action]?.displayString ?? "")
        }
        // A combination another action owned moves to this one, as in System
        // Settings, and the loser says so: the restore button puts everything
        // back (J-023).
        if let taken = hotKeys.displaced {
            notes.append(localized(
                "%@ now belongs to “%@”. “%@” has no shortcut.",
                taken.binding.displayString, taken.to.title, taken.from.title
            ))
        }
        c.shortcutNotes = notes
        c.canRestoreShortcuts = HotKeyAction.allCases.contains { hotKeys.bindings[$0] != $0.defaultBinding }
        c.musicOnly = flag(.musicOnly)
        c.nowPlayingFailure = fallbackReason?.explanation
        c.automation = Self.automationRows(automation.consents)
        // Only the Music section lists them, and `context` is rebuilt on every
        // render: resolving ~25 known players on the main actor for About or
        // Privacy was work for a group that is not on screen.
        if selection.wrappedValue == .music { c.installedPlayers = icons.installedPlayers() }
        c.delayIsSet = abs(lyrics.userOffset) > 0.01
        c.onlineLyrics = flag(.lookUpLyricsOnline)
        c.onlineTranslation = flag(.translateOnline)
        c.lyricsNotice = lyricsNotice
        c.libraryHasFolders = !localLyrics.selectedFolders.isEmpty
        c.hasUnassignedCorrections = !lyrics.unassignedLegacyOffsets.isEmpty
        c.showOnLockScreen = flag(.showOnLockScreen)
        c.spotify = spotifyRows
        c.offersDownload = updates.lastAvailable != nil
        c.updateNotes = updateNotes
        c.automaticUpdates = flag(.checkForUpdatesAutomatically)
        c.diagnosticsCopied = diagnosticsCopied != nil
        return c
    }

    private var spotifyRows: [SpotifyRow] {
        Self.spotifyRows(
            connected: spotify.isConnected,
            needsReconnect: spotify.needsReconnect,
            signIn: spotify.signInOutcome,
            apiBlocked: spotify.apiBlocked,
            problem: spotify.signInProblem,
            canImport: spotify.canImportLegacyAccount,
            storage: spotify.storage,
            refusal: spotify.refusal
        )
    }

    /// The lines under About's update row: a check in flight, or why one failed.
    /// "Latest version" is the row's own label, and a newer version is the
    /// Download button's.
    private var updateNotes: [String] {
        var notes: [String] = []
        switch updates.state {
        case .idle, .upToDate, .available:
            break
        case .checking:
            notes.append(localized("Checking…"))
        case .failed(let reason):
            switch reason {
            case .offline: notes.append(localized("Could not reach GitHub. Try again later."))
            case .rateLimited: notes.append(localized("GitHub is limiting checks right now. Try again in an hour."))
            case .server: notes.append(localized("GitHub did not answer properly. Try again later."))
            }
        }
        // Outside the switch on purpose: a known update stays on offer through
        // a later failed or in-flight check (J-019).
        if updates.lastAvailable != nil {
            notes.append(localized("Quit Isla, then replace it in Applications with the new version."))
        }
        return notes
    }

    private func form(width: CGFloat, narrow: Bool) -> some View {
        let section = selection.wrappedValue
        let blocks = SettingsTable.blocks(for: section, context: context)
        return ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    blockView(block, width: width)
                }
            }
            .frame(width: width, alignment: .topLeading)
            .padding(.bottom, 8)
        }
        // A section taller than the body scrolls inside its own area. The
        // scroller stays hidden on purpose; the bottom edge fading while rows
        // continue below it is the cue, the same primitive Clipboard and Shelf
        // use. One scroll per section: coming back to a section starts at its top.
        .id(section)
        .scrollEdgeFade()
    }

    @ViewBuilder
    private func blockView(_ block: SettingsBlock, width: CGFloat) -> some View {
        switch block {
        case .header(let title):
            // A heading, named in the title's own case, so the headings rotor
            // has a stop per group and VoiceOver reads it as it is drawn
            // (H-024).
            Text(title)
                .islandFont(.reading, weight: .semibold)
                .foregroundStyle(Theme.settingsHeader)
                .padding(.leading, 2)
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
        case .group(let rows):
            groupCard(rows)
                .padding(.bottom, 6)
        case .footnote(let text):
            Text(text)
                .islandFont(.caption, weight: .regular)
                .foregroundStyle(Theme.tertiary)
                .lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, SettingsLayout.rowInset)
                .padding(.top, -2)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .buttons(let rows):
            TrailingFlowLayout(spacing: 8, lineSpacing: 6) {
                ForEach(rows, id: \.self) { row in
                    pushButton(row)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.bottom, 6)
        case .free(let row):
            freeView(row, width: width)
        case .space(let height):
            Color.clear.frame(height: height)
        }
    }

    /// A card of rows: white 0.055 at radius 9, the rows 28 tall with an inset
    /// hairline between each.
    private func groupCard(_ rows: [SettingsRowID]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                // Laid over the row's top edge, not stacked above it: the board's
                // rows are 28 apart with the hairline drawn on the boundary, and a
                // stacked half point made every group a half point per row too tall.
                rowView(row)
                    .overlay(alignment: .top) { if index > 0 { rowDivider } }
            }
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: SettingsLayout.groupRadius, style: .continuous)
                .fill(Theme.settingsGroupFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsLayout.groupRadius, style: .continuous)
                .strokeBorder(Theme.settingsGroupEdge, lineWidth: 0.5)
        )
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: SettingsLayout.hairlineHeight)
            .padding(.horizontal, SettingsLayout.hairlineInset)
            .accessibilityHidden(true)
    }

    // MARK: Rows

    /// The row's switch state: what this pane last set, else what is stored, else
    /// the spec's default (`SettingsRowID.isOn`).
    private func flag(_ row: SettingsRowID) -> Bool {
        flags[row] ?? row.isOn(in: settingsDefaults)
    }

    /// A binding to a switch. `persists` is false for the rows whose own store
    /// writes the key — the clipboard's three switches, the update check's —
    /// so the value is not written twice by two owners; `then` is what else the
    /// switch does.
    private func flagBinding(
        _ row: SettingsRowID, persists: Bool = true, then: @escaping (Bool) -> Void = { _ in }
    ) -> Binding<Bool> {
        Binding(
            get: { flag(row) },
            set: { wants in
                flags[row] = wants
                if persists { row.write(wants, in: settingsDefaults) }
                then(wants)
            }
        )
    }

    /// Why Word Karaoke, Lyric Delay, Translate Lyrics, Look Up Lyrics Online and
    /// Lyric Band are dimmed: they only act on lyrics the island is showing.
    private var lyricsOffReason: String? {
        flag(.showLyrics) ? nil : localized("Needs Show Lyrics")
    }

    @ViewBuilder
    private func rowView(_ row: SettingsRowID) -> some View {
        switch row {
        // General
        case .launchAtLogin:
            switchRow(row, isOn: launchAtLoginBinding)
        case .openOnHover:
            switchRow(row, isOn: flagBinding(row))
        case .hoverDelay:
            // How long a pointer has to rest on the notch before the panel
            // opens. Only shown when a hover is what opens it. The default is
            // nearly instant, which suits a real notch — a hole nothing lives
            // under — but anyone who keeps windows near the top of the screen
            // can slow it so a drive-by never opens the panel.
            SettingsSliderRow(
                title: row.title,
                value: hoverDelayBinding,
                range: 0.05...1.0,
                drawnValue: localized("%.2fs", hoverDelay),
                spokenValue: localized("%.2f seconds", hoverDelay),
                commit: commitHoverDelay
            )
        case .panelWidth:
            // How wide the panel opens. The window behind it never changes
            // size — only how much of it the island draws in — so this is free
            // to move. The drag previews in state and commits once, on
            // release: see `bodyWidthBinding`.
            SettingsSliderRow(
                title: row.title,
                value: bodyWidthBinding,
                range: Double(NotchMetrics.minimumBodyWidth)...Double(NotchMetrics.maximumBodyWidth),
                drawnValue: localized("%d pt", Int(bodyWidth)),
                spokenValue: localized("%d points", Int(bodyWidth)),
                drawnValueWidth: 52,
                commit: commitBodyWidth
            )
        case .charging, .headphones, .newTracks, .volumeAndBrightness:
            switchRow(row, isOn: flagBinding(row))

        // Privacy
        case .clipboardHistory:
            switchRow(row, isOn: flagBinding(row, persists: false) { setClipboardHistory($0) })
        case .includeImages:
            switchRow(row, isOn: flagBinding(row, persists: false) { setClipboardIncludeImages($0) })
        case .keepPinned:
            switchRow(row, isOn: flagBinding(row, persists: false) { setClipboardKeepPinned($0) })
        case .coverClipboard:
            switchRow(row, isOn: privacyCoversBinding(for: .clipboard))
        case .coverTranslate:
            switchRow(row, isOn: privacyCoversBinding(for: .translate))
        case .hideFromRecording:
            switchRow(row, isOn: flagBinding(row) { _ in
                // The live panel, not just the next one built.
                (NSApp.windows.first { $0 is NotchPanel } as? NotchPanel)?.applyCaptureExclusion()
            })

        // Shortcuts
        case .shortcutOpenPanel:
            ShortcutRecorderRow(action: .openPanel, center: hotKeys, wantsKeyboard: wantsKeyboard)
        case .shortcutLyrics:
            ShortcutRecorderRow(action: .showLyrics, center: hotKeys, wantsKeyboard: wantsKeyboard)
        case .shortcutTranslate:
            ShortcutRecorderRow(action: .translateClipboard, center: hotKeys, wantsKeyboard: wantsKeyboard)

        // Music
        case .nowPlayingReader, .automationPermission:
            // The failure groups' one button each (spec §10): Try Again and
            // Open Automation Settings… are drawn here and nowhere else.
            SettingsRowChrome(label: row.title) { pushButton(row) }
        case .automationStatus:
            automationStatusRows
        case .installedPlayers:
            installedPlayerRows
        case .musicOnly:
            // First among the switches because it decides what reaches the
            // island at all; everything below it is about the music that does.
            switchRow(row, isOn: flagBinding(row))
        case .volumeAndOutput:
            // On out of the box: it only reads until a person drags the slider
            // or picks an output, and the owner waived the default-off rule for
            // it (decision 8, checklist.md §"Scope divergence").
            switchRow(row, isOn: flagBinding(row))
        case .lyricBand:
            switchRow(row, isOn: flagBinding(row), disabledReason: lyricsOffReason)

        // Lyrics
        case .showLyrics:
            switchRow(row, isOn: flagBinding(row) { _ in onLyricsVisibilityChanged() })
        case .wordKaraoke:
            switchRow(row, isOn: $lyrics.wordKaraokeEnabled, disabledReason: lyricsOffReason)
        case .showNextLineEarly:
            // For the singer who reads a line before singing it: the island's
            // one-line lyric turns early. The footnote says what does not move,
            // since the highlight is what the Lyric Delay below tunes.
            SettingsChoiceRow(
                title: row.title,
                options: LyricReadAhead.allCases,
                selection: $lyrics.readAhead,
                optionTitle: { $0.title }
            )
        case .lyricDelay:
            // The correction that moves every song at once — a catalogue, or a
            // pair of AirPods, which delay the audio and leave every lyric on
            // the Mac running early by the same amount. The slider, fine steps
            // and a live preview of the line: see `LyricDelayControls`.
            LyricDelayControls(lyrics: lyrics, media: media, disabledReason: lyricsOffReason)
                .disabledWithReason(lyricsOffReason)
        case .translateLyrics:
            // A translated line under each lyric line (spec §5.3, decision 11):
            // off until chosen, and the footnote says where the work is done
            // before either is touched.
            switchRow(row, isOn: flagBinding(row), disabledReason: lyricsOffReason)
        case .translateTo:
            SettingsPopUpRow(
                title: row.title,
                options: LyricTranslation.TargetChoice.all,
                selection: Binding(
                    get: { translateTarget },
                    set: { choice in
                        translateTarget = choice
                        choice.apply(to: settingsDefaults)
                    }
                ),
                optionTitle: { choice in
                    switch choice {
                    case .automatic: return localized("Automatic")
                    case .language(let language): return language.name
                    }
                },
                dividerAfter: LyricTranslation.TargetChoice.separatorAfter
            )
            .disabled(!flag(.translateLyrics) || lyricsOffReason != nil)
            .opacity(flag(.translateLyrics) && lyricsOffReason == nil ? 1 : 0.4)
        case .lookUpLyricsOnline:
            // The one switch in the lyric path that reaches the network, and the
            // footnote under it says so before it is flipped rather than in a
            // policy nobody opens.
            switchRow(row, isOn: flagBinding(row) { _ in onLyricsVisibilityChanged() }, disabledReason: lyricsOffReason)
        case .libraryFolders:
            libraryFolderRows
        case .unassignedCorrections:
            unassignedCorrectionRows

        // Lock Screen
        case .showOnLockScreen, .restAsBanner:
            // Banner or card, resting (spec §7.1): on, the song waits as a slim
            // banner under the clock and a click opens the card; off, the card
            // shows directly. Read when the lock window is made, like the
            // card's size, so a switch flipped during a lock applies at the
            // next one.
            switchRow(row, isOn: flagBinding(row))
        case .cardSize:
            SettingsChoiceRow(
                title: row.title,
                options: NotchViewModel.LockCardSize.allCases,
                selection: Binding(
                    get: { lockCardSize },
                    set: { size in
                        lockCardSize = size
                        settingsDefaults.set(size.rawValue, forKey: NotchViewModel.lockCardSizeKey)
                    }
                ),
                optionTitle: { $0.title }
            )

        // Translate
        case .translateOnline:
            // The one switch in Translate that reaches the network. Off, every
            // language this Mac can translate still works; on, the ones it
            // cannot — Uzbek above all — go to the one service
            // `OnlineTranslation` names, and the footnote says so before it is
            // flipped.
            switchRow(row, isOn: flagBinding(row))
        case .keepHistory:
            // Off empties the list at once (`NotchViewModel.setTranslateKeepHistory`);
            // the Translate tab reads the switch itself when an answer lands.
            switchRow(row, isOn: flagBinding(row) { setTranslateKeepHistory($0) })
        case .speakButton:
            // Off stops anything being read aloud; the tab hides the button.
            switchRow(row, isOn: flagBinding(row) { setTranslateSpeakButton($0) })

        // Spotify
        case .spotifyAccount, .spotifyImport:
            SettingsRowChrome(label: row.title) { pushButton(row) }

        // Screenshots
        case .saveClipboardScreenshots:
            switchRow(row, isOn: flagBinding(row) { _ in refreshClipboardPolling() })
        case .showScreenCaptures:
            switchRow(row, isOn: flagBinding(row))

        // About
        case .updateStatus:
            // Whether a newer Isla is out. Pressing the button is the consent
            // for its one request; the switch under it, which asks daily, is off
            // until turned on.
            SettingsRowChrome(label: updateLabel) { pushButton(row) }
        case .downloadUpdate:
            SettingsRowChrome(label: nil) { pushButton(row) }
        case .checkForUpdatesAutomatically:
            switchRow(row, isOn: flagBinding(row, persists: false) { updates.setAutomatic($0) })
        case .copyDiagnostics:
            // What a stranger needs to tell the owner what went wrong: the
            // report, and the form that asks for it.
            linkRow(
                row, title: collectingDiagnostics ? localized("Collecting…") : row.title,
                disabled: collectingDiagnostics, action: copyDiagnostics
            )
        case .reportProblem:
            linkRow(row) { NSWorkspace.shared.open(Diagnostics.reportURL) }
        case .acknowledgements:
            linkRow(row, action: openAcknowledgements)

        // Rows that are not drawn in a card: see `freeView` and `pushButton`.
        case .openLoginItems, .restoreShortcuts, .resetLyricDelay, .openLyricsFolder, .addLyricsFolder,
             .importLRC, .rescanLocalLyrics, .clearImportedLyrics, .clearBindings, .translationLanguages,
             .showScreenshotsFolder, .clearScreenshotsFolder, .quit,
             .cardStyle, .spotifyHead, .aboutHead:
            EmptyView()
        }
    }

    /// The label of the update row: what the last check found, or the version
    /// running.
    private var updateLabel: String {
        if case .upToDate(let version) = updates.state {
            return localized("Isla %@ is the latest version.", version)
        }
        return localized("Isla %@", ProductIdentity.version)
    }

    /// A row that sits outside a card: the style previews, the two heads, Quit.
    @ViewBuilder
    private func freeView(_ row: SettingsRowID, width: CGFloat) -> some View {
        switch row {
        case .cardStyle:
            LockStylePicker(
                title: row.title,
                selection: Binding(
                    get: { lockCardStyle },
                    set: { style in
                        lockCardStyle = style
                        settingsDefaults.set(style.rawValue, forKey: NotchViewModel.lockCardStyleKey)
                    }
                ),
                formWidth: width
            )
        case .spotifyHead:
            HStack(spacing: 10) {
                SettingsSectionIcon(glyph: .spotify, side: 40, icons: icons)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: row.title)
                        .islandFont(.subhead, weight: .semibold)
                        .foregroundStyle(.white)
                    // "Connected" in green (spec §10): the one place the section
                    // says where the account stands, so it says it in a colour.
                    Text(spotify.isConnected ? localized("Connected") : localized("Not connected"))
                        .islandFont(.reading, weight: .regular)
                        .foregroundStyle(spotify.isConnected ? Theme.settingsConnected : Theme.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 6)
            .padding(.bottom, 10)
            .accessibilityElement(children: .combine)
        case .aboutHead:
            // The app icon, its name and its version; pressing it opens the
            // standard About panel, as the footer's About button always did.
            Button {
                AboutWindow.show()
            } label: {
                HStack(spacing: 12) {
                    SettingsSectionIcon(glyph: .isla, side: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: ProductIdentity.displayName)
                            .islandFont(.title, weight: .semibold)
                            .foregroundStyle(.white)
                        Text(localized("Version %@", ProductIdentity.version))
                            .islandFont(.reading, weight: .regular)
                            .foregroundStyle(Theme.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 4)
                .padding(.bottom, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(PanelButtonStyle())
            .accessibilityLabel(row.title)
        case .quit:
            // Quit is the only way out of an app that Force Quit does not list,
            // so it is a button in the last section of the pane the welcome page
            // points at, not a footer to scroll to (H-003).
            HStack(alignment: .center, spacing: 8) {
                Text(localized("Nothing leaves your Mac unless you turn it on."))
                    .islandFont(.caption, weight: .regular)
                    .foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 2)
                Spacer(minLength: 8)
                pushButton(row)
            }
            .padding(.top, 2)
        default:
            EmptyView()
        }
    }

    // MARK: Row parts

    /// The whole row is the switch: its title is the toggle's label, so a click
    /// on the words flips it, and `PanelSwitchStyle` draws the on-state itself
    /// because AppKit's switch only shows one in a key window (H-002). The
    /// accessibility label stays the bare title so VoiceOver reads the row by its
    /// name.
    ///
    /// `disabledReason` dims the row the way a disabled action row is dimmed and
    /// says why where a pointer rests and where VoiceOver lands, for the
    /// switches that do nothing while the one they depend on is off (M-34).
    private func switchRow(
        _ row: SettingsRowID, isOn: Binding<Bool>, disabledReason: String? = nil
    ) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 8) {
                if let icon = row.icon { RowIcon(symbol: icon) }
                Text(row.title)
                    .islandFont(.reading, weight: .regular)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(PanelSwitchStyle(rowHeight: SettingsLayout.rowHeight, horizontalInset: SettingsLayout.rowInset))
        .accessibilityLabel(row.title)
        .disabledWithReason(disabledReason)
    }

    /// A plain tappable row with a glyph — Copy Diagnostics and its neighbours.
    /// Not a destructive action, so not a push button and not red.
    private func linkRow(
        _ row: SettingsRowID, title: String? = nil, disabled: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon = row.icon { RowIcon(symbol: icon) }
                Text(title ?? row.title)
                    .islandFont(.reading, weight: .regular)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, SettingsLayout.rowInset)
            .frame(minHeight: SettingsLayout.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelButtonStyle())
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .accessibilityLabel(title ?? row.title)
    }

    private func push(_ title: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(ToolbarPushButtonStyle())
            .disabled(disabled)
    }

    /// A push button (spec §10: actions are push buttons on trailing rows, never
    /// red text rows). The ones that destroy something ask first, and the
    /// question is on the button's own plate, in the destructive style.
    @ViewBuilder
    private func pushButton(_ row: SettingsRowID) -> some View {
        switch row {
        case .openLoginItems:
            // User-initiated, and like Open Automation Settings… it needs no
            // activation: System Settings comes forward on its own from a panel
            // that is never key.
            push(row.title) { SMAppService.openSystemSettingsLoginItems() }
        case .restoreShortcuts:
            push(row.title) { hotKeys.restoreDefaults() }
        case .nowPlayingReader:
            push(localized("Try Again")) { media.retryNowPlaying(userAsked: true) }
        case .automationPermission:
            // NSWorkspace needs no activation, so this works from a panel that
            // never becomes key; System Settings comes forward on its own.
            push(localized("Open Automation Settings…")) { NSWorkspace.shared.open(Self.automationSettingsURL) }
        case .resetLyricDelay:
            push(row.title) { lyrics.userOffset = 0 }
        case .openLyricsFolder:
            push(row.title) { openLocalLyricsFolder() }
        case .addLyricsFolder:
            push(row.title) { addLocalLyricsFolder() }
        case .importLRC:
            push(row.title) { importLocalLyrics() }
        case .rescanLocalLyrics:
            push(row.title) { rescanLocalLyrics() }
        case .clearImportedLyrics:
            ConfirmPushButton(title: row.title, armedTitle: localized("Delete These Files")) {
                clearImportedLyrics()
            }
        case .clearBindings:
            ConfirmPushButton(title: row.title, armedTitle: localized("Delete These Files")) {
                clearBindingsAndTimingCorrections()
            }
        case .translationLanguages:
            push(row.title) { Translator.openTranslationLanguages() }
        case .spotifyAccount:
            if spotify.isConnected {
                ConfirmPushButton(title: localized("Disconnect Spotify Account"), armedTitle: localized("Disconnect")) {
                    SpotifyAccount.shared.disconnect()
                }
            } else {
                push(localized("Connect Spotify Account…")) { SpotifyAccount.shared.beginAuthorization() }
            }
        case .spotifyImport:
            push(localized("Import Account from Keychain…")) { SpotifyAccount.shared.importLegacyAccount() }
        case .showScreenshotsFolder:
            push(row.title) { screenshotVault.reveal() }
        case .clearScreenshotsFolder:
            ConfirmPushButton(
                title: clearTitle, armedTitle: localized("Delete These Files"),
                disabled: screenshotUsage.files == 0 || clearingScreenshots
            ) {
                clearScreenshots()
            }
        case .updateStatus:
            push(row.title, disabled: updates.state == .checking) { updates.check() }
        case .downloadUpdate:
            if let known = updates.lastAvailable {
                push(localized("Download Isla %@", known.version)) { NSWorkspace.shared.open(known.page) }
            }
        case .quit:
            push(row.title) { NSApp.terminate(nil) }
        default:
            EmptyView()
        }
    }

    /// One row per player Isla read, "Spotify … Not allowed": read, not set, so a
    /// label and a value rather than a control, and VoiceOver hears it as one
    /// element, "Spotify, Not allowed".
    private var automationStatusRows: some View {
        let statuses: [(player: String, bundleID: String, state: String)] = Self.automationRows(automation.consents).compactMap {
            if case let .status(player, bundleID, state) = $0 { return (player, bundleID, state) } else { return nil }
        }
        return VStack(spacing: 0) {
            ForEach(Array(statuses.enumerated()), id: \.offset) { index, status in
                // The player's own icon before its name, found by bundle
                // identifier; none when the app is not installed.
                SettingsRowChrome(label: status.player, appIcon: icons.icon(status.bundleID)) {
                    Text(status.state)
                        .islandFont(.reading, weight: .regular)
                        .foregroundStyle(Theme.secondary)
                }
                .accessibilityElement(children: .combine)
                .overlay(alignment: .top) { if index > 0 { rowDivider } }
            }
        }
    }

    /// One read-only row per music app installed on this Mac, with its real icon
    /// and the name the Finder shows. A label, not a control: VoiceOver says the
    /// name.
    private var installedPlayerRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(icons.installedPlayers().enumerated()), id: \.element.bundleID) { index, player in
                SettingsRowChrome(label: player.name, appIcon: player.icon) { EmptyView() }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(player.name)
                    .overlay(alignment: .top) { if index > 0 { rowDivider } }
            }
        }
    }

    /// The folders the library scans, each with Remove, and under a folder the
    /// files a scan could not show, by name. The scan always knew; nothing drew
    /// it, so a folder with two broken files looked like one with none (G-007).
    private var libraryFolderRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(localLyrics.selectedFolders.enumerated()), id: \.element.path) { index, folder in
                VStack(spacing: 0) {
                    SettingsRowChrome(label: folder.lastPathComponent) {
                        Button(localized("Remove")) { removeLocalLyricsFolder(folder) }
                            .buttonStyle(ToolbarPushButtonStyle())
                            .accessibilityLabel(localized("Remove %@", folder.lastPathComponent))
                    }
                    let unreadable = localLyrics.unreadableFiles(in: folder)
                    if !unreadable.isEmpty {
                        Text(localized("Couldn't read: %@", unreadable.joined(separator: ", ")))
                            .islandFont(.caption, weight: .regular)
                            .foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, SettingsLayout.rowInset)
                            .padding(.bottom, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .overlay(alignment: .top) { if index > 0 { rowDivider } }
            }
        }
    }

    /// A timing correction whose file Isla could not tie to a track any more:
    /// pressing it sets it aside, and deletes no file.
    private var unassignedCorrectionRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(lyrics.unassignedLegacyOffsets.enumerated()), id: \.element.id) { index, correction in
                Button {
                    dismissUnassignedLyricsOffset(correction.filename)
                } label: {
                    HStack(spacing: 8) {
                        RowIcon(symbol: SettingsIcon.dismiss)
                        Text(localized("Dismiss %@", correction.filename))
                            .islandFont(.reading, weight: .regular)
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, SettingsLayout.rowInset)
                    .frame(minHeight: SettingsLayout.rowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PanelButtonStyle())
                .accessibilityHint(localized("%+.2fs", correction.offset))
                .overlay(alignment: .top) { if index > 0 { rowDivider } }
            }
        }
    }

    // MARK: Actions and bindings

    private var clearTitle: String {
        guard screenshotUsage.files > 0 else { return localized("Clear Screenshots Folder") }
        let size = ByteCountFormatter.string(fromByteCount: screenshotUsage.bytes, countStyle: .file)
        return localized("Clear Screenshots Folder (%@)", size)
    }

    private func clearScreenshots() {
        clearingScreenshots = true
        // Inside the answer, not after the call: the trash runs on the vault's
        // queue, and refreshing on the next line reloaded the Shelf and the size
        // before a single file had moved, so both stayed until the next visit
        // (F-034).
        screenshotVault.clear { moved in
            clearingScreenshots = false
            shelf.load()
            // The files are in the Trash now, so the cards have to go with them.
            // Safe to look here: the vault lives in the app's own folder, which
            // macOS does not guard.
            shelf.refreshFromDisk()
            refreshUsage()
            // The button's title changing is all a sighted user needs; VoiceOver
            // hears what happened, with the count the vault actually moved.
            Announcer.shared.announce(moved == 1
                ? localized("Moved 1 file to the Trash.")
                : localized("Moved %d files to the Trash.", moved))
        }
    }

    private func copyDiagnostics() {
        collectingDiagnostics = true
        Task { @MainActor in
            await Diagnostics.copyToPasteboard(media: media)
            collectingDiagnostics = false
            let copied = Date()
            diagnosticsCopied = copied
            try? await Task.sleep(for: .seconds(4))
            if diagnosticsCopied == copied { diagnosticsCopied = nil }
        }
    }

    private func openAcknowledgements() {
        Self.showAcknowledgements(url: Self.acknowledgementsURL())
    }

    /// Opens the notices file, or the About panel when that cannot be done. The
    /// row used to do nothing at all when `NSWorkspace.open` answered false (a
    /// Mac with no handler for Markdown) or the file was not where the bundle
    /// said it was; the About panel is the nearest thing that names what Isla is
    /// made of. The three parts are seams so a test can play each refusal.
    @MainActor
    static func showAcknowledgements(
        url: URL?,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        open: (URL) -> Bool = { NSWorkspace.shared.open($0) },
        fallback: @MainActor () -> Void = { AboutWindow.show() }
    ) {
        if let url, exists(url), open(url) { return }
        fallback()
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin.isOn },
            set: { wants in launchAtLogin = LaunchAtLogin.set(wants) }
        )
    }

    /// Reuses `PrivacyMode`'s own per-section cover, so this row and the dots
    /// it draws over a pane cannot disagree about what is hidden.
    private func privacyCoversBinding(for section: PrivacyMode.Section) -> Binding<Bool> {
        Binding(
            get: { privacy.covers(section) },
            set: { on in privacy.setCovering(section, on) }
        )
    }

    /// The drag's live preview, and nothing more. A slider writes its binding
    /// on every tick of the drag, and this setter used to persist the width
    /// and rebuild the whole panel per tick (audit A7): one drag across the
    /// range tore the panel down and rebuilt it — view model included, pointer
    /// watcher restarted — for every point of travel, ~140 times for a width
    /// that was obsolete on the next tick. A tick is not a decision; letting
    /// go is. The persist and the rebuild happen once, in `commitBodyWidth`,
    /// when the slider reports the drag ended.
    private var bodyWidthBinding: Binding<Double> {
        Binding(
            get: { Double(bodyWidth) },
            set: { value in
                let width = CGFloat(value.rounded())
                guard width != bodyWidth else { return }
                bodyWidth = width
            }
        )
    }

    /// The one commit, when the drag ends. Still rebuilt, not nudged: the
    /// geometry is computed once when the panel is built, and rebuilding is
    /// the path a display change already takes. That cost was the reason for
    /// deferring — paying it per tick was ~140 teardowns per drag — and paying
    /// it once, for the width that was actually chosen, is what the rebuild is
    /// for. The commit is the tested unit on `NotchViewModel`, so what lands
    /// on disk is clamped and rounded the way the read side expects; the state
    /// takes the returned value in case the commit adjusted what was asked for.
    private func commitBodyWidth() {
        let committed = NotchViewModel.commitBodyWidth(CGFloat(bodyWidth), into: .standard)
        bodyWidth = committed
        (NSApp.delegate as? AppDelegate)?.refreshGeometry()
    }

    /// The drag's live preview only, like `bodyWidthBinding`: the persist and
    /// the sampler retune happen once, in `commitHoverDelay`, when the drag
    /// ends, rather than on every tick of it.
    private var hoverDelayBinding: Binding<Double> {
        Binding(get: { hoverDelay }, set: { hoverDelay = $0 })
    }

    private func commitHoverDelay() {
        UserDefaults.standard.set(hoverDelay, forKey: NotchViewModel.hoverDelayKey)
        // The live sampler, not just the next panel built.
        (NSApp.delegate as? AppDelegate)?.refreshPointerTuning()
    }

    /// Off the main thread: walking the folder takes as long as the folder is
    /// big, and this is the thread the whole panel lives on (#11).
    private func refreshUsage() {
        DispatchQueue.global(qos: .userInitiated).async {
            let usage = screenshotVault.usage()
            DispatchQueue.main.async { screenshotUsage = usage }
        }
    }

    /// The Mac display settings Isla is following right now, by their System
    /// Settings names, or nil when none is on.
    private var followingYourMacLine: String? {
        var names: [String] = []
        if appearance.reduceMotion { names.append(localized("Reduce Motion")) }
        if appearance.reduceTransparency { names.append(localized("Reduce Transparency")) }
        if appearance.increaseContrast { names.append(localized("Increase Contrast")) }
        guard !names.isEmpty else { return nil }
        return localized("Following your Mac: %@", names.joined(separator: ", "))
    }
}

/// The chrome every labelled row shares: an optional label that wraps before a
/// control gives way, and a trailing control that never does (spec §10, "labels
/// wrap before controls"). 28 tall at the least, inset 10 either side.
struct SettingsRowChrome<Trailing: View>: View {
    var label: String?
    var icon: String? = nil
    /// An installed app's real icon, drawn at the optical size of the tiles
    /// (`AppIconImage`) before the label.
    var appIcon: NSImage? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            if let icon { RowIcon(symbol: icon) }
            if let appIcon { AppIconImage(image: appIcon, side: SettingsLayout.rowAppIconSide) }
            if let label {
                Text(label)
                    .islandFont(.reading, weight: .regular)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing()
                .fixedSize()
        }
        .padding(.horizontal, SettingsLayout.rowInset)
        .frame(minHeight: SettingsLayout.rowHeight)
    }
}

/// Lays push buttons out against the trailing edge and wraps them onto a
/// further line when they do not fit, the last line flush right as a Finder
/// window's bottom bar is. A plain `HStack` ran "Show Screenshots Folder" and
/// "Clear Screenshots Folder (12 MB)" off the 274 pt form at 480.
struct TrailingFlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6

    private func lines(for subviews: Subviews, width: CGFloat) -> [[Int]] {
        var lines: [[Int]] = [[]]
        var x: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if x > 0, x + spacing + size.width > width {
                lines.append([])
                x = 0
            }
            x += (x > 0 ? spacing : 0) + size.width
            lines[lines.count - 1].append(index)
        }
        return lines
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = lines(for: subviews, width: width)
        var height: CGFloat = 0
        var widest: CGFloat = 0
        for (rowIndex, row) in rows.enumerated() {
            let sizes = row.map { subviews[$0].sizeThatFits(.unspecified) }
            height += (sizes.map(\.height).max() ?? 0) + (rowIndex > 0 ? lineSpacing : 0)
            widest = max(widest, sizes.map(\.width).reduce(0, +) + CGFloat(max(row.count - 1, 0)) * spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in lines(for: subviews, width: bounds.width) {
            let sizes = row.map { subviews[$0].sizeThatFits(.unspecified) }
            let rowWidth = sizes.map(\.width).reduce(0, +) + CGFloat(max(row.count - 1, 0)) * spacing
            var x = bounds.maxX - rowWidth
            for (offset, index) in row.enumerated() {
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sizes[offset]))
                x += sizes[offset].width + spacing
            }
            y += (sizes.map(\.height).max() ?? 0) + lineSpacing
        }
    }
}

// MARK: - Dependent rows

private extension View {
    @ViewBuilder
    func reasonHelp(_ reason: String?) -> some View {
        if let reason { self.help(reason).accessibilityHint(reason) } else { self }
    }

    /// A row that does nothing until something else is on: dimmed to the
    /// disabled look of `actionRow`, with the reason as its help text and its
    /// accessibility hint so a pointer and VoiceOver both get it. A nil reason
    /// leaves the row untouched.
    @ViewBuilder
    func disabledWithReason(_ reason: String?) -> some View {
        if let reason {
            self
                .disabled(true)
                .opacity(0.4)
                .help(reason)
                .accessibilityHint(reason)
        } else {
            self
        }
    }
}

// MARK: - About

/// The standard About window, brought to the front and given back.
///
/// `orderFrontStandardAboutPanel` alone orders the window front without
/// activating Isla, and an app that is not active gets its windows behind
/// the one in front, so About could open behind the app the user was in
/// (F-048). It borrows activation the way Quick Look and AirDrop do, and
/// returns it when the window closes.
@MainActor
enum AboutWindow {
    private static let lease = ActivationLease()
    /// The About window, once seen. AppKit keeps and reuses it, so one
    /// observer serves every time it is opened and closed.
    private static weak var window: NSWindow?
    private static var closing: NSObjectProtocol?

    static func show() {
        lease.begin()
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        NSApp.orderFrontStandardAboutPanel(nil)
        guard window == nil else { return }
        // The one window that was not there a moment ago. AppKit hands out
        // no reference to its About panel, and being new is the one sure way
        // to tell it from the island's own windows.
        guard let opened = NSApp.windows.first(where: { !before.contains(ObjectIdentifier($0)) }) else {
            return
        }
        window = opened
        if let closing { NotificationCenter.default.removeObserver(closing) }
        closing = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: opened, queue: .main
        ) { _ in
            MainActor.assumeIsolated { lease.end() }
        }
    }
}

// MARK: - Row parts

/// The glyph at the head of a Settings row. Decoration, so VoiceOver never
/// stops on it: the row's title already says what the row is, and the
/// glyph's system name said something else — "Skip Slide" for Card Size,
/// "Circle With The Left Half Filled" for Glass, "Audiobook" for headphones —
/// one extra stop per row before the control it sat beside (H-009).
struct RowIcon: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .islandFont(.body)
            .foregroundStyle(Theme.secondary)
            .frame(width: 16)
            .accessibilityHidden(true)
    }
}

/// A Settings row that sets a number: glyph, title, slider, and the value
/// drawn short at the trailing edge.
///
/// To VoiceOver the row is the slider alone, named by the title and valued
/// with its unit spelled out — "Panel Width, 560 points". Each of the three
/// copies this replaces combined its children into one element, which named
/// it but let the slider's bare number win the value: "560", and "0" for the
/// Lyric Delay row that had declared "+0.00s" (H-024). The drawn title and
/// figure are hidden rather than combined, so neither is a second stop.
///
/// `commit` is for a value that is expensive to apply (a panel rebuild, a
/// sampler retune), so it is applied once, when the slider reports editing
/// ended, rather than on every tick of a drag (audit A7). Without one, every
/// write lands as it is made.
///
/// A VoiceOver step needs nothing more. The plan for this row assumed an
/// increment writes the value without reporting any editing, so the panel
/// would never resize from VO-Up; on macOS 27 the probe saw SwiftUI bracket
/// each `accessibilityPerformIncrement` as editing began, one write, editing
/// ended, so a step commits once, on its own.
/// `SettingsAccessibilityTests.testAnIncrementOnTheRowCommits` holds that,
/// and would catch a SwiftUI that stopped bracketing.
struct SettingsSliderRow: View {
    /// A row's glyph, when it has one. The grouped form (spec §10) wears none on
    /// a slider; the parameter stays for a caller that wants one.
    var symbol: String? = nil
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// Compact, for the eye: "560 pt", "+0.25s".
    let drawnValue: String
    /// Whole words, for the ear: "560 points", "+0.25 seconds".
    let spokenValue: String
    var drawnValueWidth: CGFloat = 38
    var commit: (() -> Void)? = nil
    /// Where one VoiceOver increment (`later: true`) or decrement moves the
    /// value from, when the slider's own step is the wrong size. Left nil the
    /// slider keeps its native step — and the native editing bracket around
    /// it, which `commit` relies on (see above). Only Lyric Delay sets one:
    /// the native step is a tenth of the range, 0.6 s there, wider than the
    /// whole window inside which a listener stops noticing the offset.
    var accessibilityStep: ((_ value: Double, _ up: Bool) -> Double)? = nil
    /// Why the row is dimmed, when it is (the dimming itself is the caller's,
    /// `disabledWithReason`): the slider is the element a pointer and
    /// VoiceOver land on, so the reason is put on it.
    var reason: String? = nil

    /// The slider gives way first when the form is narrow: it is the one part of
    /// the row that can be shorter and still be a slider, so it takes the least
    /// the knob allows before the label is asked to wrap (spec §10, `Stress-
    /// Settings-RU-480`). The value keeps its width — a figure cut to "+0.0…" is
    /// no figure — and so does the title, which wraps rather than truncates.
    static let minimumSliderWidth: CGFloat = 56
    static let idealSliderWidth: CGFloat = 130
    /// The board's slider is 130–150 against the value: wider forms give the
    /// extra to the gap before it, not to the track.
    static let maximumSliderWidth: CGFloat = 150

    var body: some View {
        HStack(spacing: 8) {
            if let symbol { RowIcon(symbol: symbol) }
            Text(title)
                .islandFont(.reading, weight: .regular)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            slider
                .frame(minWidth: Self.minimumSliderWidth, idealWidth: Self.idealSliderWidth, maxWidth: Self.maximumSliderWidth)
            Text(drawnValue)
                .font(Theme.TypeRole.caption.font().monospacedDigit())
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
                .frame(width: drawnValueWidth, alignment: .trailing)
                .layoutPriority(1)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, SettingsLayout.rowInset)
        .frame(minHeight: SettingsLayout.rowHeight)
    }

    @ViewBuilder
    private var slider: some View {
        let base = Slider(value: $value, in: range, onEditingChanged: { editing in
            guard !editing else { return }
            commit?()
        })
        .controlSize(.mini)
        .tint(Theme.secondary)
        .accessibilityLabel(title)
        // A native slider does not vend a hint to assistive clients (the
        // probe read an empty help on it, disabled or not), so the reason is
        // part of what VoiceOver speaks as its value; the tooltip is for the
        // pointer.
        .accessibilityValue(reason.map { "\(spokenValue). \($0)" } ?? spokenValue)
        .reasonHelp(reason)
        if let accessibilityStep {
            base.accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: value = accessibilityStep(value, true)
                case .decrement: value = accessibilityStep(value, false)
                @unknown default: break
                }
            }
        } else {
            base
        }
    }
}

// MARK: - Lyric Delay

/// What the Lyric Delay value says: a direction, never a sign.
///
/// "+0.25 seconds" is a sign the listener has to decode, and until LY-01 the
/// sign ran backwards: the note under the slider said "positive, later" while
/// a positive value lit lines early, so the AirPods listener the setting
/// exists for followed it and doubled the error. A direction cannot be
/// misread the same way. Positive is later (`LyricSweep.lead`).
enum LyricDelayCopy {
    static func value(_ offset: TimeInterval) -> String {
        // Below half a hundredth the figure prints as 0.00, and "0.00 s
        // later" names a direction nothing is moved in. A slider drag
        // leaves residues that small.
        if abs(offset) < 0.005 { return localized("On time") }
        return offset > 0
            ? localized("%.2f s later", offset)
            : localized("%.2f s earlier", -offset)
    }
}

/// One fine step of Lyric Delay: 0.05 s, under a third of the −125/+45 ms
/// window inside which a viewer does not notice text and sound apart (ITU-R
/// BT.1359-1, the window `LyricLeadModel.anticipation` aims into), so a
/// step can always land inside it. On a grid, so that steps after a drag
/// land on round values instead of carrying the drag's residue along.
enum LyricDelayStep {
    static let size: TimeInterval = 0.05
    /// The store's own clamp, `LyricsStore.userOffset`.
    static let range: ClosedRange<TimeInterval> = -3...3

    /// The grid point one step later or earlier than `value`, clamped.
    ///
    /// Counted in whole steps and divided at the end, so the result is the
    /// double nearest the round value: adding 0.05 to a sum like
    /// `0.1 + 0.2`, a hair over 0.3, would carry the hair along with every
    /// step. The tolerance keeps a value that is on the grid but a hair off
    /// it from counting as already past its own point.
    static func next(_ value: TimeInterval, later: Bool) -> TimeInterval {
        let perSecond = (1 / size).rounded()
        let units = value * perSecond
        let tolerance = 1e-6
        let target = later ? (units + tolerance).rounded(.down) + 1 : (units - tolerance).rounded(.up) - 1
        return min(max(target / perSecond, range.lowerBound), range.upperBound)
    }
}

/// The Lyric Delay row: the slider, Earlier and Later in fine steps, and —
/// while a song with lyrics plays — the line the panel would draw now, so the
/// delay can be tuned while watching it.
///
/// The correction is the one measurement of the gap between the player's
/// position and the voice reaching the ear that nothing on the Mac can make
/// (L-02, L7), and it used to be set here with no lyric in sight: every move
/// of a ±3 s slider at about 0.04 s a point meant a trip to the Music tab to
/// see what it did. Tap-along calibration was rejected for this: a tap
/// carries a motor delay of tens to hundreds of milliseconds, the same kind
/// of unknown being measured.
///
/// The preview is the caption's line through the caption's own
/// `MediaPane.captionResolution` and `KaraokeText`, so what lights here is
/// what lights on the Music tab. It reads the clock through
/// `extrapolatedPosition` inside a 0.1 s `TimelineView` rather than by
/// observing the controller: the media clock's tick stops off the Music tab
/// (MS-12), and observing it redrew all of Settings ten times a second
/// (F-015). `media` is held, not observed, and only `isPlaying` is received
/// — a handful of times a session — to decide whether there is a preview at
/// all. `LyricDelayCopyTests` holds both.
struct LyricDelayControls: View {
    @ObservedObject var lyrics: LyricsStore
    let media: MediaController
    /// Set while Show Lyrics is off; see `SettingsSliderRow.reason`.
    var disabledReason: String? = nil
    @State private var isPlaying = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            SettingsSliderRow(
                title: localized("Lyric Delay"),
                // No commit: the store persists the offset on every write and
                // nothing is rebuilt for it, so each tick may land.
                value: $lyrics.userOffset,
                range: LyricDelayStep.range,
                drawnValue: localized("%+.2fs", lyrics.userOffset),
                spokenValue: LyricDelayCopy.value(lyrics.userOffset),
                // 52 pt (spec §10): "+0.00 s" was cut to "+0.0…" in 40.
                drawnValueWidth: 52,
                accessibilityStep: { LyricDelayStep.next($0, later: $1) },
                reason: disabledReason
            )
            hairline
            HStack(spacing: 8) {
                stepper(later: false)
                Group {
                    if let lines = previewLines {
                        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                            preview(lines)
                        }
                    } else {
                        // The value in words between the two buttons that move
                        // it, so the direction each press went is read where
                        // the press was. The slider already speaks it.
                        Text(LyricDelayCopy.value(lyrics.userOffset))
                            .font(Theme.TypeRole.caption.font().monospacedDigit())
                            .foregroundStyle(Theme.tertiary)
                            .lineLimit(1)
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity)
                stepper(later: true)
            }
            .padding(.horizontal, SettingsLayout.rowInset)
            .frame(minHeight: SettingsLayout.rowHeight)
            if previewLines != nil {
                hairline
                Text(localized("Move until the line lights with the voice."))
                    .islandFont(.caption, weight: .regular)
                    .foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SettingsLayout.rowInset)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // A publisher hands over its current value on subscription, so a
        // pane opened mid-song previews at once.
        .onReceive(media.$isPlaying) { isPlaying = $0 }
    }

    private var hairline: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: SettingsLayout.hairlineHeight)
            .padding(.horizontal, SettingsLayout.hairlineInset)
            .accessibilityHidden(true)
    }

    /// The lines to preview, or nil when there is nothing to line up with:
    /// no timed lyric, or no voice because the song is paused.
    private var previewLines: [LyricsStore.Line]? {
        guard isPlaying, case .ready = lyrics.availability,
              case .synced(let lines) = lyrics.state, !lines.isEmpty else { return nil }
        return lines
    }

    private func stepper(later: Bool) -> some View {
        let title = later ? localized("Later") : localized("Earlier")
        let atEnd = later
            ? lyrics.userOffset >= LyricDelayStep.range.upperBound
            : lyrics.userOffset <= LyricDelayStep.range.lowerBound
        return Button {
            lyrics.userOffset = LyricDelayStep.next(lyrics.userOffset, later: later)
        } label: {
            Image(systemName: later ? "plus" : "minus")
                // Fitted to the 22 pt well, as the lyrics page's own
                // per-track nudge is: a caption glyph would crowd it.
                .font(.system(size: 8, weight: .bold))
        }
        .buttonStyle(NotchButtonStyle(size: 22))
        .disabled(atEnd)
        .opacity(atEnd ? 0.4 : 1)
        .help(title)
        .accessibilityLabel(title)
    }

    /// The caption's line at this moment, drawn the way the caption draws it.
    @ViewBuilder
    private func preview(_ lines: [LyricsStore.Line]) -> some View {
        let wordTiming = LyricsPresentation.usesWordTiming(
            lyrics.timingGranularity,
            precisionMeasured: media.precisionSync,
            wordKaraokeEnabled: lyrics.wordKaraokeEnabled
        )
        if let shown = MediaPane.captionResolution(lines: lines, inputs: LyricInputs(
            position: media.extrapolatedPosition(),
            precisionSync: media.precisionSync,
            userOffset: lyrics.userOffset,
            trackOffset: lyrics.trackOffset,
            wordTiming: wordTiming
        )) {
            let index = shown.centre
            let line = lines[index]
            KaraokeText(
                text: line.text,
                fraction: shown.fraction,
                clock: shown.current.flatMap { current in
                    LyricSweep.liveFraction(
                        line: line, end: LyricSweep.end(of: current, in: lines),
                        wordTiming: wordTiming,
                        clock: LyricSweep.frameClock(media: media, lead: LyricSweep.lead(
                            precisionSync: media.precisionSync, userOffset: lyrics.userOffset,
                            trackOffset: lyrics.trackOffset
                        ))
                    )
                },
                reduceMotion: reduceMotion,
                tracking: Theme.tracking(forSize: Theme.TypeRole.body.size)
            )
            .italic(line.isCredit)
            .id(index)
            .transition(.lyricLine(reduceMotion: reduceMotion))
            .frame(maxWidth: .infinity)
            .animation(Theme.lyricScroll(reduceMotion: reduceMotion), value: index)
            // Read as the words it shows. The sweep is drawn, not text, and
            // left alone it was an unnamed element with nothing to read.
            .accessibilityRepresentation { Text(line.text) }
        }
    }
}

/// A Settings row that picks one of a short list, drawn as capsules.
/// Segmented rather than a menu: two or three options fit, and a menu on a
/// panel that never becomes key is a window opening over a window that
/// cannot own it.
///
/// Drawn by hand because a native `Picker(.segmented)` looks like AppKit on
/// the dark pane (owner decision 4), but to an assistive client it is a
/// native picker: one radio group named by the row, a radio button per
/// option, the selected one valued 1. The capsules alone were loose buttons,
/// three stops with "selected" the only hint that they were one choice.
///
/// The stand-in is the `.radioGroup` style, not `.segmented`: the probe found
/// SwiftUI's segmented picker vends a tab group of tab buttons, which
/// VoiceOver announces as tabs, beside a separate unattached text for its
/// label. Nothing of the stand-in is ever drawn, so its look costs nothing;
/// `labelsHidden()` folds its title into the group's own name rather than
/// leaving it as a separate text beside the group.
struct SettingsChoiceRow<Option: Identifiable & Hashable>: View {
    var symbol: String? = nil
    let title: String
    let options: [Option]
    @Binding var selection: Option
    let optionTitle: (Option) -> String

    /// One line when the title and the capsules both fit, the capsules under
    /// the title when they do not. The new Show Next Line Early row, with
    /// four capsules and a Russian title, was squeezed at the 480 pt panel
    /// until its options read "В… / 0,… / 0,… / 0,…" and could not be told
    /// apart; truncating a choice is worse than a second line, so a row that
    /// does not fit takes the height it needs.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                if let symbol { RowIcon(symbol: symbol) }
                titleText.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 8)
                capsules
            }
            .padding(.horizontal, SettingsLayout.rowInset)
            .frame(minHeight: SettingsLayout.rowHeight)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if let symbol { RowIcon(symbol: symbol) }
                    titleText
                    Spacer(minLength: 0)
                }
                // Under the title, not the glyph.
                capsules.padding(.leading, symbol == nil ? 0 : 24)
            }
            .padding(.horizontal, SettingsLayout.rowInset)
            .padding(.vertical, 4)
        }
        .accessibilityRepresentation {
            Picker(title, selection: $selection) {
                ForEach(options) { option in
                    Text(optionTitle(option)).tag(option)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
    }

    private var titleText: some View {
        Text(title)
            .islandFont(.reading, weight: .regular)
            .foregroundStyle(.white)
    }

    private var capsules: some View {
        let increaseContrast = SystemAppearance.shared.increaseContrast
        return HStack(spacing: 2) {
            ForEach(options) { option in
                let isSelected = option == selection
                Button { selection = option } label: {
                    Text(optionTitle(option))
                        .islandFont(.body)
                        // Raised to clear 4.5:1 over the fills it really
                        // sits on, which the base ramp does not (3.26:1
                        // on the stacked capsules, F-052).
                        .foregroundStyle(isSelected ? .white : Theme.tertiary(
                            over: Theme.choiceOptionFills(increaseContrast: increaseContrast)
                        ))
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isSelected ? Theme.surfaceHover : .clear)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(PanelButtonStyle())
            }
        }
        .padding(2)
        .background {
            // Increase Contrast swaps the group's fill for the defined
            // edge that setting asks for: stacked on the section card the
            // fill left white text at 4.24:1 at best (see
            // `Theme.choiceOptionFills`).
            if increaseContrast {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface)
            }
        }
    }
}

/// A Settings row that picks one of a long list — the languages — drawn as the
/// board's pop-up: the title, and at the trailing edge a capsule holding the
/// chosen value over a pair of chevrons.
///
/// A `Menu`, the way the Translate tab's own language headings are: a menu from
/// a panel that never becomes key works through SwiftUI's own button menu, and
/// the segmented capsules of `SettingsChoiceRow` do not fit sixteen choices. To
/// an assistive client it is a native pop-up button named by the row and valued
/// by the choice.
struct SettingsPopUpRow<Option: Identifiable & Hashable>: View {
    var symbol: String? = nil
    let title: String
    let options: [Option]
    @Binding var selection: Option
    let optionTitle: (Option) -> String
    /// A separator under this option (Translate To: Automatic, then the languages).
    var dividerAfter: (Option) -> Bool = { _ in false }

    var body: some View {
        HStack(spacing: 8) {
            if let symbol { RowIcon(symbol: symbol) }
            Text(title)
                .islandFont(.reading, weight: .regular)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Menu {
                ForEach(options) { option in
                    // A toggle, because a menu draws one as the native
                    // checkmarked item (see the Translate tab's `languageItem`).
                    Toggle(optionTitle(option), isOn: Binding(
                        get: { option == selection },
                        set: { wants in if wants { selection = option } }
                    ))
                    if dividerAfter(option) { Divider() }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(optionTitle(selection))
                        .islandFont(.body)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .islandFont(.caption, weight: .semibold)
                        .foregroundStyle(Theme.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.surface))
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .menuStyle(.button)
            .buttonStyle(PanelButtonStyle())
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, SettingsLayout.rowInset)
        .frame(minHeight: SettingsLayout.rowHeight)
        .accessibilityRepresentation {
            Picker(title, selection: $selection) {
                ForEach(options) { option in
                    Text(optionTitle(option)).tag(option)
                }
            }
            .pickerStyle(.menu)
        }
    }
}
