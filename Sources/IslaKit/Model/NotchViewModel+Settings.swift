import AppKit
import Combine
import UniformTypeIdentifiers

/// Every setting's key, default and accessor. Stored properties live in NotchViewModel.swift.
extension NotchViewModel {
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

    /// Volume and Brightness turned on or off in Settings (spec §12). The switch
    /// is already written; this asks macOS for Accessibility when it went on and
    /// lets the key tap follow the setting and the permission together.
    func setVolumeAndBrightness(_ enabled: Bool) {
        if !enabled {
            hud = nil
            hudStrip = nil
        }
        stores.hud.settingChanged(to: enabled)
    }

    /// Whether Settings should show its "Accessibility" group: the setting is on
    /// and the permission is missing. Published by the controller of the keys.
    var accessibilityMissing: AnyPublisher<Bool, Never> {
        stores.hud.$needsAccessibility.removeDuplicates().eraseToAnyPublisher()
    }

    /// Whether Settings should add the stale-entry line to that group: the
    /// permission has stayed missing past `MediaKeyHUD.staleEntryAfter`.
    /// Whether Settings should say the Mac is not passing the keys on: trusted,
    /// on, and no tap for `MediaKeyHUD.tapRefusedAfter`.
    var volumeKeysRefused: AnyPublisher<Bool, Never> {
        stores.hud.$tapRefused.removeDuplicates().eraseToAnyPublisher()
    }

    /// Whether Isla is resetting its own Accessibility entry right now: Settings
    /// greys "Open Privacy & Security…" meanwhile.
    var accessibilityRepairing: AnyPublisher<Bool, Never> {
        stores.hud.$isRepairing.removeDuplicates().eraseToAnyPublisher()
    }

    var accessibilityEntrySuspectedStale: AnyPublisher<Bool, Never> {
        stores.hud.$suspectsStaleEntry.removeDuplicates().eraseToAnyPublisher()
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

    /// Defaults to **on**, which is an owner-waived exception to the rule that
    /// anything touching a system-wide setting starts off (decision 8, 15 Oct
    /// 2026; checklist.md §"Scope divergence" records it). What
    /// makes it safe: the controls only *read* until a person drags the slider or
    /// picks an output — the volume is not written, and the default output is
    /// not changed, by drawing them. Off hides the slider and the Output button
    /// and the lyric band keeps its place (spec §4.5).
    static let volumeAndOutputKey = "player.volumeAndOutput"

    /// Defaults to **on**. The sung line and the next one under the title
    /// (spec §4.3); it reaches nothing but the lyrics Show Lyrics already
    /// allows. Off hides the band and the layout takes the no-lyric positions.
    static let lyricBandKey = "player.lyricBand"

    // MARK: Lyric translation (spec §5.3, §14; owner decision 11)

    static let translateLyricsKey = "lyrics.translate"

    /// Defaults to **off** (decision 11). On its own it reaches nothing: the
    /// translation is made on this Mac, and goes to MyMemory only for a pair
    /// nothing here offers and only if Translate Online — its own, older
    /// consent — is on as well (`LyricTranslation`).
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

    /// Low Battery Warning and Fully Charged (spec §19.5 a, b), both on:
    /// IOKit's battery readings, no permission, nothing leaves the Mac.
    static let lowBatteryKey = "island.lowBattery"
    static let fullBatteryKey = "island.fullBattery"
    /// Microphone and Camera, and Downloads (plan 2026-11-14 S4, S5): off.
    static let recordingKey = "island.recording"
    static let downloadsKey = "island.downloads"
    static var lowBatteryEnabled: Bool { SettingsRowID.lowBattery.isOn(in: .standard) }
    static var fullBatteryEnabled: Bool { SettingsRowID.fullBattery.isOn(in: .standard) }

    static var headphonesEnabled: Bool { headphonesEnabled(in: .standard) }
    static func headphonesEnabled(in defaults: UserDefaults) -> Bool {
        SettingsRowID.headphones.isOn(in: defaults)
    }

    /// Volume and Brightness (spec §12, §14): **off** until chosen. The one
    /// moment that needs a permission, replaces a system pop-up and sets the
    /// Mac's volume and brightness. Reads the default back from the table.
    static var volumeAndBrightnessEnabled: Bool { volumeAndBrightnessEnabled(in: .standard) }
    static func volumeAndBrightnessEnabled(in defaults: UserDefaults) -> Bool {
        SettingsRowID.volumeAndBrightness.isOn(in: defaults)
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
    /// Speak Button defaults to **on** (spec §14): it sends nothing anywhere and
    /// changes nothing until pressed.
    static let translateSpeakButtonKey = "translate.speakButton"

    /// Keep History defaults to **off** (spec §14): the last 20 translations in
    /// memory, gone at quit, never written to disk; turning it on is the person
    /// choosing to be remembered. Release R4's Settings row; the Translate tab
    /// reads it.
    static func translateKeepHistoryEnabled(in defaults: UserDefaults) -> Bool {
        SettingsRowID.keepHistory.isOn(in: defaults)
    }

    /// How the lock card is finished.
    ///
    /// Nothing above the login shield can sample the wallpaper, so every style
    /// is a recipe the card draws for itself (`LockScreenCard.glassRouting`).
    /// **Transparent** is the default when nothing is stored (owner,
    /// 2026-10-31: the card should show the wallpaper by default; spec §7.2
    /// amended). Its black wash is only a floor — the contrast solver raises
    /// it until the dimmest type clears 4.5:1 — so the lyric stays legible on
    /// a bright wallpaper. **Automatic** (redesign 2026-10-15) was the default
    /// before that: the cover's light, today's Tinted recipe, at an
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

    /// The stored choice, or **Compact** when nothing (or nothing this build
    /// knows) is stored (owner, 2026-10-31: the smaller card is the default;
    /// spec §7.1 amended). A person who picked Standard keeps it.
    static func lockCardSize(in defaults: UserDefaults) -> LockCardSize {
        LockCardSize(rawValue: defaults.string(forKey: lockCardSizeKey) ?? "") ?? .compact
    }

    static var lockCardSize: LockCardSize { lockCardSize(in: .standard) }

    static let lockCardStyleKey = "lockCardStyle"

    /// The stored choice, or **Transparent** when nothing (or nothing this
    /// build knows) is stored — only the default changed, in the redesign and
    /// again on 2026-10-31 (spec §7.2, §14), so a person who picked a style
    /// keeps it.
    static func lockCardStyle(in defaults: UserDefaults) -> LockCardStyle {
        LockCardStyle(rawValue: defaults.string(forKey: lockCardStyleKey) ?? "") ?? .clear
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

    /// Swipe to Open and Close (`IslandPull`), on unless switched off. Read at
    /// each gesture's began, so the switch takes effect on the next swipe.
    static let swipeToOpenKey = "island.swipeToOpen"
    static var swipeToOpenEnabled: Bool { SettingsRowID.swipeToOpen.isOn(in: .standard) }

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
}
