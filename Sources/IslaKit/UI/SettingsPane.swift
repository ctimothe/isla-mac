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

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
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
            scrollingBody
                .onAppear { scrollToTarget(proxy) }
                // Set while the pane is already up, too: nothing stops a later
                // route from sending it somewhere while Settings is the
                // visible tab.
                .onChange(of: scrollTarget.wrappedValue) { _, _ in scrollToTarget(proxy) }
        }
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
                    if HotKeyAction.allCases.contains(where: { hotKeys.bindings[$0] != $0.defaultBinding }) {
                        actionRow(symbol: SettingsIcon.restoreShortcuts, title: localized("Restore Default Shortcuts")) {
                            hotKeys.restoreDefaults()
                        }
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
                        disabled: screenshotUsage.files == 0
                    ) {
                        screenshotVault.clear()
                        shelf.load()
                        // The files were just deleted, so the cards have to go
                        // with them. Safe to look here: the vault lives in the
                        // app's own folder, which macOS does not guard.
                        shelf.refreshFromDisk()
                        refreshUsage()
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
                        isOn: $lyrics.wordKaraokeEnabled
                    )
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
                    // No commit: the store persists the offset on every write
                    // and nothing is rebuilt for it, so each tick may land.
                    SettingsSliderRow(
                        symbol: SettingsIcon.lyricTiming,
                        title: localized("Lyric Delay"),
                        value: $lyrics.userOffset,
                        range: -3...3,
                        drawnValue: localized("%+.2fs", lyrics.userOffset),
                        spokenValue: localized("%+.2f seconds", lyrics.userOffset),
                        drawnValueWidth: 44
                    )
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
                        )
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
                    if spotify.isConnected {
                        actionRow(symbol: SettingsIcon.disconnectAccount, title: localized("Disconnect Spotify Account")) {
                            SpotifyAccount.shared.disconnect()
                        }
                    } else {
                        actionRow(symbol: SettingsIcon.connectAccount, title: localized("Connect Spotify Account…")) {
                            connectSpotify()
                        }
                    }
                    // Offered only when there is actually something to bring
                    // across. Finding that out asks the keychain for attributes
                    // and never for contents, so the offer itself costs no
                    // prompt — pressing it is what asks, once.
                    if spotify.canImportLegacyAccount {
                        actionRow(symbol: SettingsIcon.importFromKeychain, title: localized("Import Account from Keychain…")) {
                            SpotifyAccount.shared.importLegacyAccount()
                        }
                    }
                    if spotify.isConnected {
                        noteRow(storageNote)
                    }
                    if spotify.isConnected, spotify.apiBlocked {
                        noteRow((spotify.refusal ?? .other).explanation)
                    }
                }

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

                section(localized("Application")) {
                    actionRow(symbol: SettingsIcon.about, title: localized("About %@", ProductIdentity.displayName)) {
                        NSApp.orderFrontStandardAboutPanel(nil)
                    }
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
                    case .available(let version, let page):
                        actionRow(symbol: SettingsIcon.downloadUpdate, title: localized("Download Isla %@", version)) {
                            NSWorkspace.shared.open(page)
                        }
                        noteRow(localized("Quit Isla, then replace it in Applications with the new version."))
                    case .failed:
                        noteRow(localized("Could not reach GitHub. Try again later."))
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
                    confirmRow(
                        symbol: SettingsIcon.quit,
                        title: localized("Quit"),
                        armedTitle: localized("Quit Isla")
                    ) {
                        NSApp.terminate(nil)
                    }
                }
            }
            .padding(.top, 2)
            .padding(.trailing, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Live state, not a snapshot taken once at launch: System Settings can
        // flip Launch at Login from outside, and the folder can empty or fill
        // between visits to this tab (#11 taught the same lesson for the menu
        // this replaces).
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            saveClipboardImages = NotchViewModel.saveClipboardImagesEnabled
            importRecordings = NotchViewModel.importRecordingsEnabled
            refreshUsage()
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
            get: { launchAtLogin },
            set: { wants in
                do {
                    if wants {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    Log.app.error("launch at login failed: \(error.localizedDescription, privacy: .public)")
                }
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
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

    /// Where the tokens are, in the user's words. Said out loud because the
    /// answer depends on how the app was signed, and somebody running a build
    /// they made themselves deserves to know it is not the keychain.
    private var storageNote: String {
        switch spotify.storage {
        case .keychain: return localized("Stored in your keychain.")
        case .file: return localized("Stored in a file only you can read.")
        case .unavailable: return localized("Cannot be stored on this Mac.")
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
    private func toggleRow(symbol: String, title: String, isOn: Binding<Bool>) -> some View {
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

    var body: some View {
        HStack(spacing: 8) {
            RowIcon(symbol: symbol)
            Text(title)
                .islandFont(.body)
                .foregroundStyle(.white)
                .accessibilityHidden(true)
            Slider(value: $value, in: range, onEditingChanged: { editing in
                guard !editing else { return }
                commit?()
            })
            .controlSize(.mini)
            .tint(Theme.secondary)
            .accessibilityLabel(title)
            .accessibilityValue(spokenValue)
            Text(drawnValue)
                .font(Theme.TypeRole.caption.font().monospacedDigit())
                .foregroundStyle(Theme.tertiary)
                .frame(width: drawnValueWidth, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
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

    var body: some View {
        HStack(spacing: 8) {
            RowIcon(symbol: symbol)
            Text(title)
                .islandFont(.body)
                .foregroundStyle(.white)
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                ForEach(options) { option in
                    let isSelected = option == selection
                    Button { selection = option } label: {
                        Text(optionTitle(option))
                            .islandFont(.body)
                            .foregroundStyle(isSelected ? .white : Theme.tertiary)
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
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface)
            )
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
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
}
