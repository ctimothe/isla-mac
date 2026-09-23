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
    @ObservedObject var media: MediaController
    @ObservedObject var localLyrics: LocalLyricsLibrary
    var onLyricsVisibilityChanged: () -> Void = {}
    var importLocalLyrics: () -> Void = {}
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
    @State private var clipboardHistory = NotchViewModel.clipboardHistoryEnabled
    @State private var checkUpdatesAutomatically = UpdateCheck.automaticEnabled

    static let localLyricsPrivacyCopyKey = "Lyrics stay on this Mac."

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

    var body: some View {
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
                        HStack(spacing: 8) {
                            Image(systemName: SettingsIcon.hoverDelay)
                                .islandFont(.body)
                                .foregroundStyle(Theme.secondary)
                                .frame(width: 16)
                            Text(localized("Hover Delay"))
                                .islandFont(.body)
                                .foregroundStyle(.white)
                            Slider(
                                value: hoverDelayBinding,
                                in: 0.05...1.0,
                                onEditingChanged: { editing in
                                    guard !editing else { return }
                                    commitHoverDelay()
                                }
                            )
                            .controlSize(.mini)
                            .tint(Theme.secondary)
                            Text(localized("%.2fs", hoverDelay))
                                .font(Theme.TypeRole.caption.font().monospacedDigit())
                                .foregroundStyle(Theme.tertiary)
                                .frame(width: 38, alignment: .trailing)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(localized("Hover Delay"))
                    }

                    // How wide the panel opens. The window behind it never
                    // changes size — only how much of it the island draws in —
                    // so this is free to move. The drag previews in state and
                    // commits once, on release: see `bodyWidthBinding`.
                    HStack(spacing: 8) {
                        Image(systemName: SettingsIcon.panelWidth)
                            .islandFont(.body)
                            .foregroundStyle(Theme.secondary)
                            .frame(width: 16)
                        Text(localized("Panel Width"))
                            .islandFont(.body)
                            .foregroundStyle(.white)
                        Slider(
                            value: bodyWidthBinding,
                            in: Double(NotchMetrics.minimumBodyWidth)...Double(NotchMetrics.maximumBodyWidth),
                            onEditingChanged: { editing in
                                guard !editing else { return }
                                commitBodyWidth()
                            }
                        )
                        .controlSize(.mini)
                        .tint(Theme.secondary)
                        Text(localized("%d pt", Int(bodyWidth)))
                            .font(Theme.TypeRole.caption.font().monospacedDigit())
                            .foregroundStyle(Theme.tertiary)
                            .frame(width: 38, alignment: .trailing)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(localized("Panel Width"))
                    // The island's two moments without music. Each is on by
                    // default and leaves nothing but a picture on the notch.
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
                    if let reason = media.fallbackReason {
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
                    HStack(spacing: 8) {
                        Image(systemName: SettingsIcon.lyricTiming)
                            .islandFont(.body)
                            .foregroundStyle(Theme.secondary)
                            .frame(width: 16)
                        Text(localized("Lyric Delay"))
                            .islandFont(.body)
                            .foregroundStyle(.white)
                        Slider(value: $lyrics.userOffset, in: -3...3)
                            .controlSize(.mini)
                            .tint(Theme.secondary)
                        Text(localized("%+.2fs", lyrics.userOffset))
                            .font(Theme.TypeRole.caption.font().monospacedDigit())
                            .foregroundStyle(Theme.tertiary)
                            .frame(width: 44, alignment: .trailing)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(localized("Lyric Delay"))
                    .accessibilityValue(localized("%+.2fs", lyrics.userOffset))
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
                        noteRow(localized("Languages this Mac cannot translate itself, such as Uzbek, are sent to MyMemory over the internet."))
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
                        noteRow(localized("Copies are not read or kept. Turning it off emptied the list."))
                    }
                    ForEach(PrivacyMode.Section.allCases) { privacySection in
                        toggleRow(
                            symbol: privacySymbol(for: privacySection),
                            title: privacySection.title,
                            isOn: privacyCoversBinding(for: privacySection)
                        )
                    }
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
            Text(title.uppercased())
                .islandFont(.caption, weight: .semibold)
                .tracking(Theme.capsTracking)
                .foregroundStyle(Theme.tertiary)
                .padding(.leading, 8)
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

    private func toggleRow(symbol: String, title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .islandFont(.body)
                .foregroundStyle(Theme.secondary)
                .frame(width: 16)
            Text(title)
                .islandFont(.body)
                .foregroundStyle(.white)
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .accessibilityLabel(title)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
    }

    /// A row that picks one of a short list. Segmented rather than a menu: two
    /// or three options fit, and a menu on a panel that never becomes key is a
    /// window opening over a window that cannot own it.
    private func choiceRow<Option: Identifiable & Equatable>(
        symbol: String,
        title: String,
        options: [Option],
        selection: Binding<Option>,
        title optionTitle: @escaping (Option) -> String
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .islandFont(.body)
                .foregroundStyle(Theme.secondary)
                .frame(width: 16)
            Text(title)
                .islandFont(.body)
                .foregroundStyle(.white)
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                ForEach(options) { option in
                    let isSelected = option == selection.wrappedValue
                    Button { selection.wrappedValue = option } label: {
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
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface)
            )
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
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
                Image(systemName: symbol)
                    .islandFont(.body)
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 16)
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
