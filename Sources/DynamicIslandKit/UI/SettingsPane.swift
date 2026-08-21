import AppKit
import SwiftUI
import ServiceManagement

/// Everything that used to live in the status bar menu, now reachable as a
/// tab like any other: configuration is read rarely, and a menu that grows a
/// new row per feature reads worse than a pane that scrolls.
struct SettingsPane: View {
    @ObservedObject var shelf: ShelfStore
    let screenshotVault: ScreenshotVault
    let lyrics: LyricsStore
    @ObservedObject var privacy: PrivacyMode

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var hoverDelay = NotchViewModel.hoverOpenDelay
    @State private var saveClipboardImages = NotchViewModel.saveClipboardImagesEnabled
    @State private var hideFromCapture = NotchViewModel.hideFromCaptureEnabled
    @State private var sneakPeek = NotchViewModel.sneakPeekEnabled
    @State private var showOnLockScreen = NotchViewModel.showOnLockScreenEnabled
    @State private var showLyrics = NotchViewModel.showLyricsEnabled
    /// Observed, not snapshotted: the connect flow completes in the browser
    /// long after this pane rendered, and a one-shot copy of isConnected sat
    /// on "Connect" forever while the tokens were already in the keychain.
    @ObservedObject private var spotify = SpotifyAccount.shared
    @State private var screenshotUsage: (files: Int, bytes: Int64) = (0, 0)

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                section(localized("General")) {
                    toggleRow(
                        symbol: "arrow.forward.to.line",
                        title: localized("Launch at Login"),
                        isOn: launchAtLoginBinding
                    )
                    // How long a pointer has to rest on the notch before the
                    // panel opens. The default is nearly instant, which suits a
                    // real notch — a hole nothing lives under — but anyone who
                    // keeps windows near the top of the screen can slow it so a
                    // drive-by never opens the panel. Longer delays also make
                    // the pill's click-to-pause usable before the panel opens.
                    HStack(spacing: 8) {
                        Image(systemName: "cursorarrow.motionlines")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.secondary)
                            .frame(width: 16)
                        Text(localized("Hover Delay"))
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.white)
                        Slider(value: hoverDelayBinding, in: 0.05...1.0)
                            .controlSize(.mini)
                            .tint(Theme.secondary)
                        Text(String(format: "%.2fs", hoverDelay))
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(Theme.tertiary)
                            .frame(width: 38, alignment: .trailing)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(localized("Hover Delay"))
                }

                section(localized("Screenshots")) {
                    toggleRow(
                        symbol: "photo.on.rectangle",
                        title: localized("Save Clipboard Screenshots"),
                        isOn: saveClipboardImagesBinding
                    )
                    actionRow(symbol: "folder", title: localized("Show Screenshots Folder")) {
                        screenshotVault.reveal()
                    }
                    confirmRow(
                        symbol: "trash",
                        title: clearTitle,
                        armedTitle: localized("Delete These Files?"),
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
                    toggleRow(
                        symbol: "quote.bubble",
                        title: localized("Show Lyrics"),
                        isOn: Binding(
                            get: { showLyrics },
                            set: { wants in
                                showLyrics = wants
                                UserDefaults.standard.set(wants, forKey: NotchViewModel.showLyricsKey)
                            }
                        )
                    )
                    toggleRow(
                        symbol: "sparkles",
                        title: localized("Peek at New Tracks"),
                        isOn: Binding(
                            get: { sneakPeek },
                            set: { wants in
                                sneakPeek = wants
                                UserDefaults.standard.set(wants, forKey: NotchViewModel.sneakPeekKey)
                            }
                        )
                    )
                    toggleRow(
                        symbol: "lock",
                        title: localized("Show on Lock Screen"),
                        isOn: Binding(
                            get: { showOnLockScreen },
                            set: { wants in
                                showOnLockScreen = wants
                                UserDefaults.standard.set(wants, forKey: NotchViewModel.showOnLockScreenKey)
                            }
                        )
                    )
                    // Looked-up lyrics are kept on disk so a replay costs no
                    // request. Offered here because a cache the user cannot
                    // see the end of is a cache they cannot empty.
                    confirmRow(
                        symbol: "trash",
                        title: localized("Clear Lyrics Cache"),
                        armedTitle: localized("Delete These Files?"),
                        disabled: false
                    ) {
                        lyrics.clearCache()
                    }
                }

                section(localized("Spotify")) {
                    if spotify.isConnected {
                        actionRow(symbol: "heart.fill", title: localized("Disconnect Spotify Account")) {
                            SpotifyAccount.shared.disconnect()
                        }
                    } else {
                        actionRow(symbol: "heart", title: localized("Connect Spotify Account…")) {
                            connectSpotify()
                        }
                    }
                    // Offered only when there is actually something to bring
                    // across. Finding that out asks the keychain for attributes
                    // and never for contents, so the offer itself costs no
                    // prompt — pressing it is what asks, once.
                    if spotify.canImportLegacyAccount {
                        actionRow(symbol: "key", title: localized("Import Account From Keychain…")) {
                            SpotifyAccount.shared.importLegacyAccount()
                        }
                    }
                    if spotify.isConnected {
                        noteRow(storageNote)
                    }
                }

                section(localized("Privacy")) {
                    ForEach(PrivacyMode.Section.allCases) { privacySection in
                        toggleRow(
                            symbol: privacySymbol(for: privacySection),
                            title: privacySection.title,
                            isOn: privacyCoversBinding(for: privacySection)
                        )
                    }
                    toggleRow(
                        symbol: "eye.slash",
                        title: localized("Hide From Screen Recording"),
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
                    actionRow(symbol: "macwindow", title: localized("Open Panel")) {
                        (NSApp.delegate as? AppDelegate)?.togglePanel()
                    }
                    actionRow(symbol: "info.circle", title: localized("About %@", ProductIdentity.displayName)) {
                        NSApp.orderFrontStandardAboutPanel(nil)
                    }
                    confirmRow(
                        symbol: "power",
                        title: localized("Quit"),
                        armedTitle: localized("Quit Dynamic Island?")
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
                    NSLog("Dynamic Island: launch-at-login failed: \(error.localizedDescription)")
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
            }
        )
    }


    /// Reuses `PrivacyMode`'s own per-section cover, the same switch the
    /// status-bar menu's "Hide Contents" submenu flips.
    private func privacyCoversBinding(for section: PrivacyMode.Section) -> Binding<Bool> {
        Binding(
            get: { privacy.covers(section) },
            set: { on in privacy.setCovering(section, on) }
        )
    }

    /// Matches the icon each section's own tab already uses (`NotchViewModel.Tab.symbol`),
    /// so the same feature reads as the same feature here.
    /// Where the tokens are, in the user's words. Said out loud because the
    /// answer depends on how the app was signed, and somebody running a build
    /// they made themselves deserves to know it is not the keychain.
    private var storageNote: String {
        switch spotify.storage {
        case .keychain: return localized("Stored in your keychain.")
        case .file: return localized("Stored in an owner-only file, because this build is unsigned.")
        case .unavailable: return localized("Cannot be stored on this Mac.")
        }
    }

    private var hoverDelayBinding: Binding<Double> {
        Binding(
            get: { hoverDelay },
            set: { value in
                hoverDelay = value
                UserDefaults.standard.set(value, forKey: NotchViewModel.hoverDelayKey)
                // The live sampler, not just the next panel built.
                (NSApp.delegate as? AppDelegate)?.refreshPointerTuning()
            }
        )
    }

    private func privacySymbol(for section: PrivacyMode.Section) -> String {
        switch section {
        case .clipboard: return "list.clipboard.fill"
        case .notes: return "note.text"
        case .translate: return "translate"
        }
    }

    /// The one flow that needs a real dialog: pasting the client id. NSAlert
    /// with a text field, because the panel cannot present sheets — it never
    /// activates. The id is remembered, so this runs once.
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
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
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
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .frame(width: 16)
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white)
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
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
            .font(.system(size: 10.5))
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
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }
}
