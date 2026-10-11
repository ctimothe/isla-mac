import AppKit
import SwiftUI
import ServiceManagement

/// Everything that used to live in the status bar menu, now reachable as a
/// tab like any other: configuration is read rarely, and a menu that grows a
/// new row per feature reads worse than a pane that scrolls.
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
    var setClipboardHistory: (Bool) -> Void = { _ in }
    var refreshClipboardPolling: () -> Void = {}
    /// A section to scroll to on appearing, cleared once spent. A binding to
    /// `NotchViewModel.settingsScrollTarget`; constant in the tests and the
    /// lab, where nothing sends the pane anywhere.
    var scrollTarget: Binding<String?> = .constant(nil)
    @State private var clipboardHistory = NotchViewModel.clipboardHistoryEnabled
    @State private var checkUpdatesAutomatically = UpdateCheck.automaticEnabled

    static let localLyricsPrivacyCopyKey = "Lyrics stay on this Mac."

    /// The Music section's scroll id: where the Music tab's Open Settings
    /// lands, because Music Only is that section's first switch.
    static let musicSectionID = "settings.music"

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
        /// A player and where macOS stands on Isla scripting it.
        case status(player: String, state: String)
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
            if apiBlocked { rows.append(.note((refusal ?? .other).explanation)) }
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
            rows.append(.status(player: app.displayName, state: state))
        }
        if statuses.values.contains(.denied) {
            rows.append(.note(localized("Isla cannot read a player it is not allowed to control. Allow Isla under Privacy & Security › Automation.")))
            rows.append(.openAutomationSettings)
        }
        return rows
    }

    /// What macOS decided, not just whether it is enabled: a registration
    /// waiting on approval in Login Items read as off and snapped the switch
    /// back with no words (F-027).
    @State private var launchAtLogin = LaunchAtLogin.read()
    @State private var hoverDelay = NotchViewModel.hoverOpenDelay
    @State private var bodyWidth = NotchViewModel.bodyWidth
    @State private var opensOnHover = NotchViewModel.opensOnHoverEnabled
    @State private var saveClipboardImages = NotchViewModel.saveClipboardImagesEnabled
    @State private var importRecordings = NotchViewModel.importRecordingsEnabled
    @State private var hideFromCapture = NotchViewModel.hideFromCaptureEnabled
    @State private var sneakPeek = NotchViewModel.sneakPeekEnabled
    @State private var showOnLockScreen = NotchViewModel.showOnLockScreenEnabled
    @State private var lockCardStyle = NotchViewModel.lockCardStyle
    @State private var lockCardSize = NotchViewModel.lockCardSize
    @State private var showLyrics = NotchViewModel.showLyricsEnabled
    @State private var onlineLyrics = NotchViewModel.onlineLyricsEnabled
    @State private var onlineTranslation = NotchViewModel.onlineTranslationEnabled
    @State private var musicOnly = NotchViewModel.musicOnlyEnabled
    @State private var showCharging = NotchViewModel.showChargingEnabled
    @State private var showHeadphones = NotchViewModel.showHeadphonesEnabled
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

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                scrollingBody
                    .onAppear { scrollToTarget(proxy) }
                    // Set while the pane is already up, too: nothing stops a
                    // later route from sending it somewhere while Settings is
                    // the visible tab.
                    .onChange(of: scrollTarget.wrappedValue) { _, _ in scrollToTarget(proxy) }
                footer
            }
        }
    }

    /// Height of the strip pinned under the scroll: the caption-sized target
    /// floor (`Theme.minimumHitSize`, 20 pt) and a point either side.
    static let footerHeight: CGFloat = 22

    /// The version, About and Quit, always in view.
    ///
    /// Quit is the only way out of an app that Force Quit does not list, and
    /// it was the last row of Settings, past y = 1000 in a 162 pt window
    /// (H-003): the welcome page promises it lives here, and nobody who did
    /// not think to scroll would have found it. Pinned, it costs the scroll
    /// 22 pt and is never more than a glance away. Not in the open panel's
    /// header: that strip stays free of controls because menu-bar monitors
    /// such as Ice see clicks there. Quit keeps its two presses, the word
    /// form of the arming the rows use, because a footer is where a stray
    /// click lands.
    private var footer: some View {
        HStack(spacing: 6) {
            Text(localized("Isla %@", ProductIdentity.version))
                .islandFont(.caption, weight: .regular)
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button {
                AboutWindow.show()
            } label: {
                Text(localized("About %@", ProductIdentity.displayName))
                    .islandFont(.caption)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .frame(minWidth: Theme.minimumHitSize.width, minHeight: Theme.minimumHitSize.height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PanelButtonStyle())
            ConfirmTextButton(title: localized("Quit"), armedTitle: localized("Quit Isla")) {
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.footerHeight)
    }

    private var scrollingBody: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                section(localized("General")) {
                    toggleRow(
                        symbol: SettingsIcon.launchAtLogin,
                        title: localized("Launch at Login"),
                        isOn: launchAtLoginBinding
                    )
                    if let note = LaunchAtLogin.note(launchAtLogin) {
                        noteRow(note)
                    }
                    if launchAtLogin.offersLoginItems {
                        // User-initiated, and like Open Automation Settings…
                        // it needs no activation: System Settings comes
                        // forward on its own from a panel that is never key.
                        actionRow(symbol: SettingsIcon.openSystemSettings, title: localized("Open Login Items…")) {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                    }
                    toggleRow(
                        symbol: SettingsIcon.openOnHover,
                        title: localized("Open on Hover"),
                        isOn: Binding(
                            get: { opensOnHover },
                            set: { wants in
                                opensOnHover = wants
                                UserDefaults.standard.set(wants, forKey: NotchViewModel.opensOnHoverKey)
                            }
                        )
                    )
                    // How long a pointer has to rest on the notch before the
                    // panel opens. Only shown when a hover is what opens it. The
                    // default is nearly instant, which suits a real notch — a
                    // hole nothing lives under — but anyone who keeps windows
                    // near the top of the screen can slow it so a drive-by never
                    // opens the panel.
                    if opensOnHover {
                        SettingsSliderRow(
                            symbol: SettingsIcon.hoverDelay,
                            title: localized("Hover Delay"),
                            value: hoverDelayBinding,
                            range: 0.05...1.0,
                            drawnValue: localized("%.2fs", hoverDelay),
                            spokenValue: localized("%.2f seconds", hoverDelay),
                            commit: commitHoverDelay
                        )
                    }

                    // How wide the panel opens. The window behind it never
                    // changes size — only how much of it the island draws in —
                    // so this is free to move. The drag previews in state and
                    // commits once, on release: see `bodyWidthBinding`.
                    SettingsSliderRow(
                        symbol: SettingsIcon.panelWidth,
                        title: localized("Panel Width"),
                        value: bodyWidthBinding,
                        range: Double(NotchMetrics.minimumBodyWidth)...Double(NotchMetrics.maximumBodyWidth),
                        drawnValue: localized("%d pt", Int(bodyWidth)),
                        spokenValue: localized("%d points", Int(bodyWidth)),
                        commit: commitBodyWidth
                    )
                    // The island's two moments without music. Each is on by
                    // default and leaves nothing but a picture on the notch.
                    // Only on a Mac with a battery to report on.
                    if AmbientWatch.hasBattery {
                        toggleRow(
                            symbol: SettingsIcon.showCharging,
                            title: localized("Show Charging"),
                            isOn: Binding(
                                get: { showCharging },
                                set: { wants in
                                    showCharging = wants
                                    UserDefaults.standard.set(wants, forKey: NotchViewModel.showChargingKey)
                    }
                        )
                    )
                    }
                    toggleRow(
                        symbol: SettingsIcon.showHeadphones,
                        title: localized("Show Headphones Connecting"),
                        isOn: Binding(
                            get: { showHeadphones },
                            set: { wants in
                                showHeadphones = wants
                                UserDefaults.standard.set(wants, forKey: NotchViewModel.showHeadphonesKey)
                            }
                        )
                    )
                    // Why the island moves or looks the way it does when the
                    // Mac asks for less motion, less transparency or more
                    // contrast: Isla honours all three live and said nothing
                    // (M-34).
                    if let following = followingYourMacLine {
                        noteRow(following)
                    }
                }

                // Second, straight under General: it is what someone about to
                // share their screen opens Settings for, and as the eighth of
                // nine sections it sat at y ≈ 900 in a 162 pt window, under
                // Spotify, where nobody who did not think to scroll found it
                // (H-003).
                section(localized("Privacy")) {
                    toggleRow(
                        symbol: SettingsIcon.clipboardHistory,
                        title: localized("Clipboard History"),
                        isOn: Binding(
                            get: { clipboardHistory },
                            set: { wants in
                                clipboardHistory = wants
                                setClipboardHistory(wants)
                            }
                        )
                    )
                    if !clipboardHistory {
                        noteRow(Self.clipboardOffNote(imagesOn: saveClipboardImages))
                    }
                    ForEach(PrivacyMode.Section.allCases) { privacySection in
                        toggleRow(
                            symbol: privacySymbol(for: privacySection),
                            title: privacySection.settingsTitle,
                            isOn: privacyCoversBinding(for: privacySection)
                        )
                    }
                    noteRow(Self.privacyCoversNote)
                    toggleRow(
                        symbol: SettingsIcon.hideFromRecording,
                        title: localized("Hide from Screen Recording"),
                        isOn: Binding(
                            get: { hideFromCapture },
                            set: { wants in
                                hideFromCapture = wants
                                UserDefaults.standard.set(wants, forKey: NotchViewModel.hideFromCaptureKey)
                                // The live panel, not just the next one built.
                                (NSApp.windows.first { $0 is NotchPanel } as? NotchPanel)?
                                    .applyCaptureExclusion()
                            }
                        )
                    )
                    noteRow(Self.hideFromCaptureNote)
                }

                // The three ways in that need no pointer. Each can be moved or
                // cleared, because whichever keys ship, some app somewhere
                // already uses them.
                section(localized("Keyboard Shortcuts")) {
                    ShortcutRecorderRow(
                        action: .openPanel, symbol: SettingsIcon.shortcutOpenPanel,
                        center: hotKeys, wantsKeyboard: wantsKeyboard
                    )
                    ShortcutRecorderRow(
                        action: .showLyrics, symbol: SettingsIcon.shortcutLyrics,
                        center: hotKeys, wantsKeyboard: wantsKeyboard
                    )
                    ShortcutRecorderRow(
                        action: .translateClipboard, symbol: SettingsIcon.shortcutTranslate,
                        center: hotKeys, wantsKeyboard: wantsKeyboard
                    )
                    ForEach(HotKeyAction.allCases.filter { hotKeys.refused.contains($0) }) { action in
                        noteRow(localized(
                            "macOS would not register %@. Choose another shortcut.",
                            hotKeys.bindings[action]?.displayString ?? ""
                        ))
                    }
                    // A combination another action owned moves to this one,
                    // as in System Settings, and the loser says so: the
                    // restore row below puts everything back (J-023).
                    if let taken = hotKeys.displaced {
                        noteRow(localized(
                            "%@ now belongs to “%@”. “%@” has no shortcut.",
                            taken.binding.displayString, taken.to.title, taken.from.title
                        ))
                    }
                    if HotKeyAction.allCases.contains(where: { hotKeys.bindings[$0] != $0.defaultBinding }) {
                        actionRow(symbol: SettingsIcon.restoreShortcuts, title: localized("Restore Default Shortcuts")) {
                            hotKeys.restoreDefaults()
                        }
                    }
                }

                section(localized("Music")) {
                    // Above everything: while the reader is down, every other
                    // switch here describes music the island cannot see.
                    if let reason = fallbackReason {
                        noteRow(reason.explanation)
                        actionRow(symbol: SettingsIcon.tryAgain, title: localized("Try Again")) {
                            media.retryNowPlaying(userAsked: true)
                        }
                    }
                    // Next to the reader's own state because it is the other
                    // half of what the island can read: the fallback scripts
                    // Music and Spotify, and the heart, shuffle and repeat do
                    // too. Empty, and so absent, until a player has run.
                    ForEach(Self.automationRows(automation.consents), id: \.self) { row in
                        automationRow(row)
                    }
                    // First in the section because it decides what reaches the
                    // island at all; everything below it is about the music
                    // that does.
                    toggleRow(
                        symbol: SettingsIcon.musicOnly,
                        title: localized("Music Only"),
                        isOn: Binding(
                            get: { musicOnly },
                            set: { wants in
                                musicOnly = wants
                                UserDefaults.standard.set(wants, forKey: NotchViewModel.musicOnlyKey)
                            }
                        )
                    )
                    noteRow(musicOnly
                        ? localized("Videos and films stay off the island. Music apps, podcasts, and songs in Telegram still show.")
                        : localized("Anything playing shows on the island, videos included."))
                    toggleRow(
                        symbol: SettingsIcon.lyrics,
                        title: localized("Show Lyrics"),
                        isOn: Binding(
                            get: { showLyrics },
                            set: { wants in
                                showLyrics = wants
                                UserDefaults.standard.set(wants, forKey: NotchViewModel.showLyricsKey)
                                onLyricsVisibilityChanged()
                            }
                        )
                    )
                    toggleRow(
                        symbol: SettingsIcon.wordKaraoke,
                        title: localized("Word Karaoke"),
                        isOn: $lyrics.wordKaraokeEnabled,
                        disabledReason: lyricsOffReason
                    )
                    // For the singer who reads a line before singing it: the
                    // island's one-line lyric turns early. The note says what
                    // does not move, since the highlight is what the Lyric
                    // Delay below tunes.
                    choiceRow(
                        symbol: SettingsIcon.readAhead,
                        title: localized("Show next line early"),
                        options: LyricReadAhead.allCases,
                        selection: $lyrics.readAhead,
                        title: { $0.title }
                    )
                    noteRow(localized("The island's one-line lyric turns to the next line a little before it is sung; Auto gives longer lines more time. Highlight timing does not change."))
                    // The correction that moves every song at once.
                    //
                    // The per-track nudge on the lyrics page fixes one bad
                    // master; this fixes a catalogue — or a pair of AirPods,
                    // or a Bluetooth speaker, which delay the audio and leave
                    // every lyric on the Mac running early by the same amount.
                    // It existed in the store and had no writer anywhere in the
                    // interface, so the only fix for "all my lyrics run fast"
                    // was to nudge every track one at a time.
                    //
                    //
                    // The slider, fine steps and a live preview of the line:
                    // see `LyricDelayControls`.
                    LyricDelayControls(lyrics: lyrics, media: media, disabledReason: lyricsOffReason)
                        .disabledWithReason(lyricsOffReason)
                    if abs(lyrics.userOffset) > 0.01 {
                        actionRow(
                            symbol: SettingsIcon.resetTiming,
                            title: localized("Reset Lyric Delay")
                        ) {
                            lyrics.userOffset = 0
                        }
                    }
                    noteRow(localized("Negative shows lyrics earlier; positive, later."))
                    // The one switch in the lyric path that reaches the
                    // network, and the note under it says so before it is
                    // flipped rather than in a policy nobody opens.
                    toggleRow(
                        symbol: SettingsIcon.online,
                        title: localized("Look Up Lyrics Online"),
                        isOn: Binding(
                            get: { onlineLyrics },
                            set: { wants in
                                onlineLyrics = wants
                                UserDefaults.standard.set(wants, forKey: NotchViewModel.onlineLyricsKey)
                                onLyricsVisibilityChanged()
                            }
                        ),
                        disabledReason: lyricsOffReason
                    )
                    if onlineLyrics {
                        noteRow(localized("Asks LRCLIB for tracks no local file matches. It sends the title, artist, album and length — nothing about you."))
                    } else {
                        noteRow(localized("Lyrics stay on this Mac."))
                    }
                    noteRow(localized("Local Lyrics Library"))
                    actionRow(symbol: SettingsIcon.importLyrics, title: localized("Import LRC…")) {
                        importLocalLyrics()
                    }
                    if let lyricsNotice {
                        lyricsIssueRow(lyricsNotice)
                    }
                    actionRow(symbol: SettingsIcon.addFolder, title: localized("Add Lyrics Folder…")) {
                        addLocalLyricsFolder()
                    }
                    ForEach(localLyrics.selectedFolders, id: \.path) { folder in
                        actionRow(
                            symbol: SettingsIcon.removeFolder,
                            title: localized("Remove %@", folder.lastPathComponent)
                        ) {
                            removeLocalLyricsFolder(folder)
                        }
                        // The files a scan could not show, by name, under the
                        // folder they are in. The scan always knew; nothing
                        // drew it, so a folder with two broken files looked
                        // like one with none (G-007).
                        let unreadable = localLyrics.unreadableFiles(in: folder)
                        if !unreadable.isEmpty {
                            lyricsIssueRow(localized("Couldn't read: %@", unreadable.joined(separator: ", ")))
                        }
                    }
                    actionRow(symbol: SettingsIcon.rescan, title: localized("Rescan Local Lyrics")) {
                        rescanLocalLyrics()
                    }
                    actionRow(symbol: SettingsIcon.showFolder, title: localized("Open Lyrics Folder")) {
                        openLocalLyricsFolder()
                    }
                    confirmRow(
                        symbol: SettingsIcon.clear,
                        title: localized("Clear Imported Lyrics"),
                        armedTitle: localized("Delete These Files")
                    ) {
                        clearImportedLyrics()
                    }
                    confirmRow(
                        symbol: SettingsIcon.clear,
                        title: localized("Clear Bindings and Timing Corrections"),
                        armedTitle: localized("Delete These Files")
                    ) {
                        clearBindingsAndTimingCorrections()
                    }
                    if !lyrics.unassignedLegacyOffsets.isEmpty {
                        noteRow(localized("Unassigned timing corrections"))
                        ForEach(lyrics.unassignedLegacyOffsets) { correction in
                            actionRow(
                                symbol: SettingsIcon.dismiss,
                                title: localized("Dismiss %@", correction.filename)
                            ) {
                                dismissUnassignedLyricsOffset(correction.filename)
                            }
                            .accessibilityHint(localized("%+.2fs", correction.offset))
                        }
                    }
                    toggleRow(
                        symbol: SettingsIcon.peek,
                        title: localized("Peek at New Tracks"),
                        isOn: Binding(
                            get: { sneakPeek },
                            set: { wants in
                                sneakPeek = wants
                                UserDefaults.standard.set(wants, forKey: NotchViewModel.sneakPeekKey)
                            }
                        )
                    )
                }
                .id(Self.musicSectionID)

                // The card that stands over the lock screen, in a section of its
                // own: it is a surface in its own right, with its own glass and
                // its own size, not a detail of the music settings.
                section(localized("Lock Screen")) {
                    toggleRow(
                        symbol: SettingsIcon.lockScreen,
                        title: localized("Show on Lock Screen"),
                        isOn: Binding(
                            get: { showOnLockScreen },
                            set: { wants in
                                showOnLockScreen = wants
                                UserDefaults.standard.set(wants, forKey: NotchViewModel.showOnLockScreenKey)
                            }
                        )
                    )
                    // Only worth offering while there is a card to finish.
                    if showOnLockScreen {
                        choiceRow(
                            symbol: SettingsIcon.cardStyle,
                            title: localized("Glass"),
                            options: NotchViewModel.LockCardStyle.allCases,
                            selection: Binding(
                                get: { lockCardStyle },
                                set: { style in
                                    lockCardStyle = style
                                    UserDefaults.standard.set(style.rawValue, forKey: NotchViewModel.lockCardStyleKey)
                                }
                            ),
                            title: { $0.title }
                        )
                        choiceRow(
                            symbol: SettingsIcon.cardSize,
                            title: localized("Card Size"),
                            options: NotchViewModel.LockCardSize.allCases,
                            selection: Binding(
                                get: { lockCardSize },
                                set: { size in
                                    lockCardSize = size
                                    UserDefaults.standard.set(size.rawValue, forKey: NotchViewModel.lockCardSizeKey)
                                }
                            ),
                            title: { $0.title }
                        )
                    }
                }

                section(localized("Translate")) {
                    // The one switch in Translate that reaches the network. Off,
                    // every language this Mac can translate still works; on,
                    // the ones it cannot — Uzbek above all — go to the one
                    // service `OnlineTranslation` names, and the note says so
                    // before it is flipped.
                    toggleRow(
                        symbol: SettingsIcon.online,
                        title: localized("Translate Online"),
                        isOn: Binding(
                            get: { onlineTranslation },
                            set: { wants in
                                onlineTranslation = wants
                                UserDefaults.standard.set(wants, forKey: NotchViewModel.onlineTranslationKey)
                            }
                        )
                    )
                    if onlineTranslation {
                        // Which languages that is depends on the system:
                        // below macOS 26 it is all of them.
                        noteRow(Translator.onlineNote())
                    } else {
                        noteRow(localized("Translations stay on this Mac."))
                    }
                }

                section(localized("Spotify")) {
                    // Notes are inline, never a toast: the person acted on this
                    // section, so this section answers (one failure surface).
                    ForEach(Self.spotifyRows(
                        connected: spotify.isConnected,
                        needsReconnect: spotify.needsReconnect,
                        signIn: spotify.signInOutcome,
                        apiBlocked: spotify.apiBlocked,
                        problem: spotify.signInProblem,
                        canImport: spotify.canImportLegacyAccount,
                        storage: spotify.storage,
                        refusal: spotify.refusal
                    ), id: \.self) { row in
                        spotifyRow(row)
                    }
                }

                section(localized("Screenshots")) {
                    toggleRow(
                        symbol: SettingsIcon.saveScreenshots,
                        title: localized("Save Clipboard Screenshots"),
                        isOn: saveClipboardImagesBinding
                    )
                    toggleRow(
                        symbol: SettingsIcon.importRecordings,
                        title: localized("Show Screen Captures"),
                        isOn: importRecordingsBinding
                    )
                    actionRow(symbol: SettingsIcon.showFolder, title: localized("Show Screenshots Folder")) {
                        screenshotVault.reveal()
                    }
                    confirmRow(
                        symbol: SettingsIcon.clear,
                        title: clearTitle,
                        armedTitle: localized("Delete These Files"),
                        disabled: screenshotUsage.files == 0 || clearingScreenshots
                    ) {
                        clearingScreenshots = true
                        // Inside the answer, not after the call: the trash
                        // runs on the vault's queue, and refreshing on the
                        // next line reloaded the Shelf and the size before a
                        // single file had moved, so both stayed until the next
                        // visit (F-034).
                        screenshotVault.clear { moved in
                            clearingScreenshots = false
                            shelf.load()
                            // The files are in the Trash now, so the cards
                            // have to go with them. Safe to look here: the
                            // vault lives in the app's own folder, which macOS
                            // does not guard.
                            shelf.refreshFromDisk()
                            refreshUsage()
                            // The row's title changing is all a sighted user
                            // needs; VoiceOver hears what happened, with the
                            // count the vault actually moved.
                            Announcer.shared.announce(moved == 1
                                ? localized("Moved 1 file to the Trash.")
                                : localized("Moved %d files to the Trash.", moved))
                        }
                    }
                }

                // About and Quit are not here: they are the footer, pinned
                // under the scroll (see `footer`).
                section(localized("Application")) {
                    // What a stranger needs to tell the owner what went wrong:
                    // the report, and the form that asks for it.
                    actionRow(
                        symbol: SettingsIcon.copyDiagnostics,
                        title: collectingDiagnostics ? localized("Collecting…") : localized("Copy Diagnostics"),
                        disabled: collectingDiagnostics
                    ) {
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
                    if diagnosticsCopied != nil {
                        noteRow(localized("Copied. It lists versions, settings and Isla's own log, and nothing you played, copied or translated."))
                    }
                    actionRow(symbol: SettingsIcon.reportProblem, title: localized("Report a Problem…")) {
                        NSWorkspace.shared.open(Diagnostics.reportURL)
                    }
                    // Whether a newer Isla is out. Pressing the row is the
                    // consent for its one request; the switch under it, which
                    // asks daily, is off until turned on.
                    actionRow(
                        symbol: SettingsIcon.checkForUpdates,
                        title: localized("Check for Updates"),
                        disabled: updates.state == .checking
                    ) {
                        updates.check()
                    }
                    switch updates.state {
                    case .idle:
                        EmptyView()
                    case .checking:
                        noteRow(localized("Checking…"))
                    case .upToDate(let version):
                        noteRow(localized("Isla %@ is the latest version.", version))
                    case .available:
                        EmptyView()
                    case .failed(let reason):
                        switch reason {
                        case .offline: noteRow(localized("Could not reach GitHub. Try again later."))
                        case .rateLimited: noteRow(localized("GitHub is limiting checks right now. Try again in an hour."))
                        case .server: noteRow(localized("GitHub did not answer properly. Try again later."))
                        }
                    }
                    // Outside the switch on purpose: a known update stays on
                    // offer through a later failed or in-flight check (J-019).
                    if let known = updates.lastAvailable {
                        actionRow(symbol: SettingsIcon.downloadUpdate, title: localized("Download Isla %@", known.version)) {
                            NSWorkspace.shared.open(known.page)
                        }
                        noteRow(localized("Quit Isla, then replace it in Applications with the new version."))
                    }
                    toggleRow(
                        symbol: SettingsIcon.online,
                        title: localized("Check for Updates Automatically"),
                        isOn: Binding(
                            get: { checkUpdatesAutomatically },
                            set: { wants in
                                checkUpdatesAutomatically = wants
                                updates.setAutomatic(wants)
                            }
                        )
                    )
                    if checkUpdatesAutomatically {
                        noteRow(localized("Asks GitHub once a day for the latest version. It sends nothing about you."))
                    }
                }
            }
            .padding(.top, 2)
            .padding(.trailing, 4)
        }
        // The window is 162 pt onto about a thousand points of rows, and it
        // ended on a clean card edge after five switches, so Settings looked
        // like five switches (H-003). The scroller stays hidden on purpose;
        // the bottom edge fading while rows continue below it is the cue,
        // the same primitive Clipboard and Shelf use.
        .scrollEdgeFade()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Live state, not a snapshot taken once at launch: System Settings can
        // flip Launch at Login from outside, and the folder can empty or fill
        // between visits to this tab (#11 taught the same lesson for the menu
        // this replaces).
        .onAppear {
            // Also how the approval note clears: the way back from Open
            // Login Items… is to reopen this tab.
            launchAtLogin = LaunchAtLogin.read()
            saveClipboardImages = NotchViewModel.saveClipboardImagesEnabled
            importRecordings = NotchViewModel.importRecordingsEnabled
            refreshUsage()
            // The answer can change in System Settings while Isla is not
            // looking, and the way back from Open Automation Settings… is
            // to reopen this tab. Read-only and off the main thread; it never
            // prompts.
            automation.refresh()
        }
        .onReceive(media.$fallbackReason) { fallbackReason = $0 }
    }

    /// Lands the requested section at the top, then spends the request.
    ///
    /// On the next turn of the run loop rather than inside `onAppear`: the
    /// pane appears with the tab change, and its scroll view need not have
    /// laid its rows out by then — a `scrollTo` with no frame to aim at is
    /// silently dropped, and the request with it.
    private func scrollToTarget(_ proxy: ScrollViewProxy) {
        guard let target = scrollTarget.wrappedValue else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(target, anchor: .top)
            scrollTarget.wrappedValue = nil
        }
    }

    private var clearTitle: String {
        guard screenshotUsage.files > 0 else { return localized("Clear Screenshots Folder") }
        let size = ByteCountFormatter.string(fromByteCount: screenshotUsage.bytes, countStyle: .file)
        return localized("Clear Screenshots Folder (%@)", size)
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin.isOn },
            set: { wants in launchAtLogin = LaunchAtLogin.set(wants) }
        )
    }

    private var saveClipboardImagesBinding: Binding<Bool> {
        Binding(
            get: { saveClipboardImages },
            set: { wants in
                saveClipboardImages = wants
                UserDefaults.standard.set(wants, forKey: NotchViewModel.saveClipboardImagesKey)
                refreshClipboardPolling()
            }
        )
    }

    private var importRecordingsBinding: Binding<Bool> {
        Binding(
            get: { importRecordings },
            set: { wants in
                importRecordings = wants
                UserDefaults.standard.set(wants, forKey: NotchViewModel.importRecordingsKey)
            }
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

    @ViewBuilder
    private func spotifyRow(_ row: SpotifyRow) -> some View {
        switch row {
        case let .note(text):
            noteRow(text)
        case .connect:
            actionRow(symbol: SettingsIcon.connectAccount, title: localized("Connect Spotify Account…")) {
                connectSpotify()
            }
        case let .confirm(title, armedTitle):
            confirmRow(symbol: SettingsIcon.disconnectAccount, title: title, armedTitle: armedTitle) {
                SpotifyAccount.shared.disconnect()
            }
        case .importAccount:
            actionRow(symbol: SettingsIcon.importFromKeychain, title: localized("Import Account from Keychain…")) {
                SpotifyAccount.shared.importLegacyAccount()
            }
        }
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

    /// Matches the icon each section's own tab already uses (`NotchViewModel.Tab.symbol`),
    /// so the same feature reads as the same feature here.
    private func privacySymbol(for section: PrivacyMode.Section) -> String {
        switch section {
        case .clipboard: return SettingsIcon.clipboard
        case .translate: return SettingsIcon.translate
        }
    }

    /// One click: straight to Spotify's consent page in the browser. The
    /// registration is built in, so there is nothing to paste and nothing to
    /// read — the way every other platform's connect button behaves.
    private func connectSpotify() {
        SpotifyAccount.shared.beginAuthorization()
    }

    /// Off the main thread: walking the folder takes as long as the folder is
    /// big, and this is the thread the whole panel lives on (#11).
    private func refreshUsage() {
        DispatchQueue.global(qos: .userInitiated).async {
            let usage = screenshotVault.usage()
            DispatchQueue.main.async { screenshotUsage = usage }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func section<Rows: View>(_ title: String, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            // A heading, named in the title's own case: the drawn small caps
            // were plain static text, so the pane's nine sections gave the
            // headings rotor nothing to land on in some sixty stops, and
            // VoiceOver read "GENERAL" as it was drawn (H-024).
            Text(title.uppercased())
                .islandFont(.caption, weight: .semibold)
                .tracking(Theme.capsTracking)
                .foregroundStyle(Theme.tertiary)
                .padding(.leading, 8)
                .accessibilityLabel(title)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 1) {
                rows()
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.surface)
            )
        }
    }

    /// The whole row is the switch: its icon and title are the toggle's label,
    /// so a click on the words flips it, and `PanelSwitchStyle` draws the
    /// on-state itself because AppKit's switch only shows one in a key window
    /// (H-002). The accessibility label stays the bare title so VoiceOver
    /// reads the row by its name; the row's padding and height live in the
    /// style, inside the target, so the edges of the row are not dead.
    ///
    /// `disabledReason` dims the row the way a disabled action row is dimmed
    /// and says why where a pointer rests and where VoiceOver lands, for the
    /// switches that do nothing while the one they depend on is off (M-34).
    private func toggleRow(
        symbol: String, title: String, isOn: Binding<Bool>, disabledReason: String? = nil
    ) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 8) {
                RowIcon(symbol: symbol)
                Text(title)
                    .islandFont(.body)
                    .foregroundStyle(.white)
            }
        }
        .toggleStyle(PanelSwitchStyle())
        .accessibilityLabel(title)
        .disabledWithReason(disabledReason)
    }

    /// A row that picks one of a short list: see `SettingsChoiceRow`.
    private func choiceRow<Option: Identifiable & Hashable>(
        symbol: String,
        title: String,
        options: [Option],
        selection: Binding<Option>,
        title optionTitle: @escaping (Option) -> String
    ) -> some View {
        SettingsChoiceRow(
            symbol: symbol,
            title: title,
            options: options,
            selection: selection,
            optionTitle: optionTitle
        )
    }

    /// An action row that destroys something, so it asks first — same two-press
    /// arming as the panes, for the same reason a dialog is unavailable here.
    private func confirmRow(
        symbol: String,
        title: String,
        armedTitle: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        ConfirmRow(
            symbol: symbol,
            title: title,
            armedTitle: armedTitle,
            disabled: disabled,
            action: action
        )
    }

    /// A line of explanation under a section's controls. Not a control itself:
    /// it states something the user would otherwise have to guess.
    /// A lyric file or folder that did not work: the pane's secondary caption
    /// type, lined up with the title of the row it is about (the 8 pt inset,
    /// the 16 pt glyph and the 8 pt gap of `actionRow`), wrapping rather than
    /// truncating a list of names.
    private func lyricsIssueRow(_ text: String) -> some View {
        Text(text)
            .islandFont(.caption, weight: .regular)
            .foregroundStyle(Theme.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 32)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func automationRow(_ row: AccessRow) -> some View {
        switch row {
        case let .status(player, state):
            accessStatusRow(player: player, state: state)
        case let .note(text):
            noteRow(text)
        case .openAutomationSettings:
            // NSWorkspace needs no activation, so this works from a panel
            // that never becomes key; System Settings comes forward on its own.
            actionRow(symbol: SettingsIcon.openSystemSettings, title: localized("Open Automation Settings…")) {
                NSWorkspace.shared.open(Self.automationSettingsURL)
            }
        }
    }

    /// A player and its Automation state: read, not set, so it is a label and
    /// a value rather than a control, and VoiceOver hears it as one element,
    /// "Spotify, Not allowed".
    private func accessStatusRow(player: String, state: String) -> some View {
        HStack(spacing: 8) {
            RowIcon(symbol: SettingsIcon.automationAccess)
            Text(player)
                .islandFont(.body)
                .foregroundStyle(.white)
            Spacer(minLength: 8)
            Text(state)
                .islandFont(.caption, weight: .regular)
                .foregroundStyle(Theme.tertiary)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .accessibilityElement(children: .combine)
    }

    /// Why Word Karaoke, Lyric Delay and Look Up Lyrics Online are dimmed:
    /// they only act on lyrics the island is showing.
    private var lyricsOffReason: String? {
        showLyrics ? nil : localized("Needs Show Lyrics")
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

    private func noteRow(_ text: String) -> some View {
        Text(text)
            .islandFont(.body, weight: .regular)
            .foregroundStyle(Theme.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.top, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actionRow(
        symbol: String,
        title: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                RowIcon(symbol: symbol)
                Text(title)
                    .islandFont(.body)
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelButtonStyle())
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
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
    let symbol: String
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

    var body: some View {
        HStack(spacing: 8) {
            RowIcon(symbol: symbol)
            Text(title)
                .islandFont(.body)
                .foregroundStyle(.white)
                .accessibilityHidden(true)
            slider
            Text(drawnValue)
                .font(Theme.TypeRole.caption.font().monospacedDigit())
                .foregroundStyle(Theme.tertiary)
                .frame(width: drawnValueWidth, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
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
        VStack(spacing: 1) {
            SettingsSliderRow(
                symbol: SettingsIcon.lyricTiming,
                title: localized("Lyric Delay"),
                // No commit: the store persists the offset on every write and
                // nothing is rebuilt for it, so each tick may land.
                value: $lyrics.userOffset,
                range: LyricDelayStep.range,
                drawnValue: localized("%+.2fs", lyrics.userOffset),
                spokenValue: LyricDelayCopy.value(lyrics.userOffset),
                drawnValueWidth: 44,
                accessibilityStep: { LyricDelayStep.next($0, later: $1) },
                reason: disabledReason
            )
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
            .padding(.horizontal, 8)
            .frame(height: 26)
            if previewLines != nil {
                Text(localized("Move until the line lights with the voice."))
                    .islandFont(.body, weight: .regular)
                    .foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.top, 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // A publisher hands over its current value on subscription, so a
        // pane opened mid-song previews at once.
        .onReceive(media.$isPlaying) { isPlaying = $0 }
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
    let symbol: String
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
                RowIcon(symbol: symbol)
                titleText.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 8)
                capsules
            }
            .padding(.horizontal, 8)
            .frame(height: 26)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    RowIcon(symbol: symbol)
                    titleText
                    Spacer(minLength: 0)
                }
                // Under the title, not the glyph: the 8 pt inset, the 16 pt
                // glyph and the 8 pt gap `lyricsIssueRow` lines up with.
                capsules.padding(.leading, 24)
            }
            .padding(.horizontal, 8)
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
            .islandFont(.body)
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
