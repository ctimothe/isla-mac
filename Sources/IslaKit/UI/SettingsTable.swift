import CoreGraphics
import Foundation

/// The ten sections of Settings, in the order the sidebar lists them (redesign
/// 2026-10-15, spec §10).
///
/// Pure data: the sidebar, the form, the deep links and "the last section shown"
/// all read this one enum, so a section cannot be in the sidebar and missing
/// from the table, or the other way round. `SettingsTableTests` holds the
/// order, the titles, the icons and the colours.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, privacy, shortcuts, music, lyrics, lockScreen, translate, spotify, screenshots, about

    var id: String { rawValue }

    /// The section last shown, restored on the next open (HIG: a settings window
    /// opens where it was left). Not in the per-tier env files or anywhere a
    /// reviewer must look: one string, the case's raw value.
    static let storageKey = "settings.lastSection"
    static let `default`: SettingsSection = .general

    /// What a suite remembers, or General when nothing is stored — or when what
    /// is stored is a section this build does not have, which a downgrade or a
    /// hand-written default can leave.
    static func stored(in defaults: UserDefaults) -> SettingsSection {
        defaults.string(forKey: storageKey).flatMap(SettingsSection.init(rawValue:)) ?? .default
    }

    func store(in defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.storageKey)
    }

    /// The sidebar's label and the heading of the form's first group. Written
    /// as literals inside `localized(...)` so `test-localizations.sh` sees each
    /// one used.
    var title: String {
        switch self {
        case .general: return localized("General")
        case .privacy: return localized("Privacy")
        case .shortcuts: return localized("Shortcuts")
        case .music: return localized("Music")
        case .lyrics: return localized("Lyrics")
        case .lockScreen: return localized("Lock Screen")
        case .translate: return localized("Translate")
        case .spotify: return localized("Spotify")
        case .screenshots: return localized("Screenshots")
        case .about: return localized("About")
        }
    }

    /// What the 18 pt tile at the head of the row draws: a symbol on the
    /// section's colour, or — for the two sections that are an app — that app's
    /// own mark, as System Settings draws one for each app that has a pane.
    enum Glyph: Equatable {
        case symbol(String, Theme.SettingsTint)
        case spotify
        case isla
    }

    var glyph: Glyph {
        switch self {
        case .general: return .symbol("gearshape", .grey)
        case .privacy: return .symbol("hand.raised", .blue)
        case .shortcuts: return .symbol("keyboard", .grey)
        case .music: return .symbol("music.note", .rose)
        case .lyrics: return .symbol("quote.bubble.fill", .orange)
        case .lockScreen: return .symbol("lock.display", .indigo)
        case .translate: return .symbol("translate", .blue)
        case .spotify: return .spotify
        case .screenshots: return .symbol("photo.on.rectangle", .grey)
        case .about: return .isla
        }
    }
}

/// What a row holds when nothing is stored (spec §10's brackets, §14).
enum SettingsDefault: Equatable {
    case on
    case off
    case number(Double)
    case text(String)

    var isOn: Bool? {
        switch self {
        case .on: return true
        case .off: return false
        case .number, .text: return nil
        }
    }
}

/// Every control the form can draw, by identity.
///
/// A row is one identity whatever it draws: `rows(in:)` on a section's blocks is
/// the list a test reads, and the view dispatches on it. A row that is one
/// stored value names its `key` and its `defaultValue` here and nowhere else —
/// `NotchViewModel`'s accessors read the default back from this table, so
/// "absent means the spec's default" cannot drift between the form and the code
/// that obeys it.
@MainActor
enum SettingsRowID: String, CaseIterable, Hashable {
    // General
    case launchAtLogin, openLoginItems, openOnHover, hoverDelay, panelWidth
    case charging, headphones, newTracks, volumeAndBrightness
    // Privacy
    case clipboardHistory, includeImages, keepPinned
    case coverClipboard, coverTranslate, hideFromRecording
    // Shortcuts
    case shortcutOpenPanel, shortcutLyrics, shortcutTranslate, restoreShortcuts
    // Music
    case nowPlayingReader, automationStatus, automationPermission
    case musicOnly, installedPlayers, volumeAndOutput, lyricBand
    // Lyrics
    case showLyrics, wordKaraoke, showNextLineEarly, lyricDelay, resetLyricDelay
    case translateLyrics, translateTo, lookUpLyricsOnline
    case openLyricsFolder, addLyricsFolder, importLRC, rescanLocalLyrics
    case clearImportedLyrics, clearBindings, libraryFolders, unassignedCorrections
    // Lock Screen
    case showOnLockScreen, cardStyle, restAsBanner, cardSize
    // Translate
    case translateOnline, keepHistory, speakButton, translationLanguages
    // Spotify
    case spotifyHead, spotifyAccount, spotifyImport
    // Screenshots
    case saveClipboardScreenshots, showScreenCaptures, showScreenshotsFolder, clearScreenshotsFolder
    // About
    case aboutHead, updateStatus, downloadUpdate, checkForUpdatesAutomatically
    case copyDiagnostics, reportProblem, acknowledgements, quit

    /// What kind of control the row is. The view's dispatch and a test's "this
    /// is a switch, so it has a default" both read it.
    enum Kind: Equatable {
        case toggle, slider, choice, popUp, shortcut
        /// A push button on a trailing row (spec §10: never a red text row).
        case push
        /// A plain tappable row with a glyph, the way a list row in System
        /// Settings is: Copy Diagnostics and its neighbours.
        case link
        /// A label and a value, read and not set.
        case value
        /// Drawn by a view of its own: the lyric-delay controls, the style
        /// previews, the Spotify and About heads, the folder list.
        case custom
    }

    var kind: Kind {
        switch self {
        case .launchAtLogin, .openOnHover, .charging, .headphones, .newTracks, .volumeAndBrightness,
             .clipboardHistory, .includeImages, .keepPinned, .coverClipboard, .coverTranslate, .hideFromRecording,
             .musicOnly, .volumeAndOutput, .lyricBand, .showLyrics, .wordKaraoke, .translateLyrics,
             .lookUpLyricsOnline, .showOnLockScreen, .restAsBanner, .translateOnline, .keepHistory, .speakButton,
             .saveClipboardScreenshots, .showScreenCaptures, .checkForUpdatesAutomatically:
            return .toggle
        case .hoverDelay, .panelWidth:
            return .slider
        case .showNextLineEarly, .cardSize:
            return .choice
        case .translateTo:
            return .popUp
        case .shortcutOpenPanel, .shortcutLyrics, .shortcutTranslate:
            return .shortcut
        case .openLoginItems, .restoreShortcuts, .nowPlayingReader, .automationPermission, .resetLyricDelay,
             .openLyricsFolder, .addLyricsFolder, .importLRC, .rescanLocalLyrics, .clearImportedLyrics,
             .clearBindings, .translationLanguages, .spotifyAccount, .spotifyImport, .showScreenshotsFolder,
             .clearScreenshotsFolder, .updateStatus, .downloadUpdate, .quit:
            return .push
        case .copyDiagnostics, .reportProblem, .acknowledgements:
            return .link
        case .automationStatus:
            return .value
        case .lyricDelay, .cardStyle, .libraryFolders, .unassignedCorrections, .installedPlayers, .spotifyHead, .aboutHead:
            return .custom
        }
    }

    /// The row's label (or, for a push row, its button). The lock-style row's
    /// title is the group header over its previews, but it is also the name the
    /// radio group of previews carries.
    var title: String {
        switch self {
        case .launchAtLogin: return localized("Launch at Login")
        case .openLoginItems: return localized("Open Login Items…")
        case .openOnHover: return localized("Open on Hover")
        case .hoverDelay: return localized("Hover Delay")
        case .panelWidth: return localized("Panel Width")
        case .charging: return localized("Charging")
        case .headphones: return localized("Headphones Connecting")
        case .newTracks: return localized("New Tracks")
        case .volumeAndBrightness: return localized("Volume and Brightness")
        case .clipboardHistory: return localized("Clipboard History")
        case .includeImages: return localized("Include Images")
        case .keepPinned: return localized("Keep Pinned Items")
        case .coverClipboard: return PrivacyMode.Section.clipboard.settingsTitle
        case .coverTranslate: return PrivacyMode.Section.translate.settingsTitle
        case .hideFromRecording: return localized("Hide from Screen Recording")
        case .shortcutOpenPanel: return HotKeyAction.openPanel.title
        case .shortcutLyrics: return HotKeyAction.showLyrics.title
        case .shortcutTranslate: return HotKeyAction.translateClipboard.title
        case .restoreShortcuts: return localized("Restore Default Shortcuts")
        case .nowPlayingReader: return localized("Now Playing reader")
        case .automationStatus: return localized("Automation")
        case .automationPermission: return localized("Permission")
        case .musicOnly: return localized("Music Only")
        // The group's header, and what VoiceOver calls the list of players.
        case .installedPlayers: return localized("Players on This Mac")
        case .volumeAndOutput: return localized("Volume and Output")
        case .lyricBand: return localized("Lyric Band")
        case .showLyrics: return localized("Show Lyrics")
        case .wordKaraoke: return localized("Word Karaoke")
        case .showNextLineEarly: return localized("Show next line early")
        case .lyricDelay: return localized("Lyric Delay")
        case .resetLyricDelay: return localized("Reset Lyric Delay")
        case .translateLyrics: return localized("Translate Lyrics")
        case .translateTo: return localized("Translate To")
        case .lookUpLyricsOnline: return localized("Look Up Lyrics Online")
        case .openLyricsFolder: return localized("Open Lyrics Folder")
        case .addLyricsFolder: return localized("Add Lyrics Folder…")
        case .importLRC: return localized("Import LRC…")
        case .rescanLocalLyrics: return localized("Rescan Local Lyrics")
        case .clearImportedLyrics: return localized("Clear Imported Lyrics")
        case .clearBindings: return localized("Clear Bindings and Timing Corrections")
        case .libraryFolders: return localized("Local Lyrics Library")
        case .unassignedCorrections: return localized("Unassigned timing corrections")
        case .showOnLockScreen: return localized("Show on Lock Screen")
        case .cardStyle: return localized("Card Style")
        case .restAsBanner: return localized("Rest as Banner")
        case .cardSize: return localized("Card Size")
        case .translateOnline: return localized("Translate Online")
        case .keepHistory: return localized("Keep History")
        case .speakButton: return localized("Speak Button")
        case .translationLanguages: return localized("Translation Languages…")
        case .spotifyHead: return localized("Spotify")
        case .spotifyAccount: return localized("Account")
        case .spotifyImport: return localized("From another Mac")
        case .saveClipboardScreenshots: return localized("Save Clipboard Screenshots")
        case .showScreenCaptures: return localized("Show Screen Captures")
        case .showScreenshotsFolder: return localized("Show Screenshots Folder")
        case .clearScreenshotsFolder: return localized("Clear Screenshots Folder")
        case .aboutHead: return localized("About %@", ProductIdentity.displayName)
        case .updateStatus: return localized("Check for Updates")
        // The version is the update's, known only to the view that draws it.
        case .downloadUpdate: return localized("Download Isla %@", "").trimmingCharacters(in: .whitespaces)
        case .checkForUpdatesAutomatically: return localized("Check for Updates Automatically")
        case .copyDiagnostics: return localized("Copy Diagnostics")
        case .reportProblem: return localized("Report a Problem…")
        case .acknowledgements: return localized("Acknowledgements…")
        case .quit: return localized("Quit Isla")
        }
    }

    /// The glyph at the head of the few rows that carry one (spec §10's
    /// boards): the island's three moments, and the About section's plain rows.
    /// Every other row is its label alone — the single list wore a glyph on
    /// each row and read as a menu, which the grouped form is not.
    var icon: String? {
        switch self {
        case .charging: return SettingsIcon.showCharging
        case .headphones: return SettingsIcon.showHeadphones
        case .newTracks: return "music.note"
        case .volumeAndBrightness: return "speaker.wave.2"
        case .copyDiagnostics: return SettingsIcon.copyDiagnostics
        case .reportProblem: return SettingsIcon.reportProblem
        case .acknowledgements: return "doc.text"
        default: return nil
        }
    }

    /// The `UserDefaults` key when the row is one stored value, else nil: a
    /// login item is macOS's, a shortcut is `HotKeyCenter`'s, a cover is
    /// `PrivacyMode`'s list, and a push button stores nothing.
    var key: String? {
        switch self {
        case .openOnHover: return NotchViewModel.opensOnHoverKey
        case .hoverDelay: return NotchViewModel.hoverDelayKey
        case .panelWidth: return NotchViewModel.bodyWidthKey
        case .charging: return NotchViewModel.chargingKey
        case .headphones: return NotchViewModel.headphonesKey
        case .newTracks: return NotchViewModel.newTracksKey
        case .volumeAndBrightness: return SettingsTable.volumeAndBrightnessKey
        case .clipboardHistory: return NotchViewModel.clipboardHistoryKey
        case .includeImages: return NotchViewModel.clipboardIncludeImagesKey
        case .keepPinned: return NotchViewModel.clipboardKeepPinnedKey
        case .coverClipboard, .coverTranslate: return PrivacyMode.key
        case .hideFromRecording: return NotchViewModel.hideFromCaptureKey
        case .musicOnly: return NotchViewModel.musicOnlyKey
        case .volumeAndOutput: return NotchViewModel.volumeAndOutputKey
        case .lyricBand: return NotchViewModel.lyricBandKey
        case .showLyrics: return NotchViewModel.showLyricsKey
        case .wordKaraoke: return LyricsStore.wordKaraokeEnabledKey
        case .showNextLineEarly: return LyricsStore.readAheadKey
        case .lyricDelay: return LyricsStore.offsetKey
        case .translateLyrics: return NotchViewModel.translateLyricsKey
        case .translateTo: return NotchViewModel.translateTargetKey
        case .lookUpLyricsOnline: return NotchViewModel.onlineLyricsKey
        case .showOnLockScreen: return NotchViewModel.showOnLockScreenKey
        case .cardStyle: return NotchViewModel.lockCardStyleKey
        case .restAsBanner: return NotchViewModel.restAsBannerKey
        case .cardSize: return NotchViewModel.lockCardSizeKey
        case .translateOnline: return NotchViewModel.onlineTranslationKey
        case .keepHistory: return NotchViewModel.translateKeepHistoryKey
        case .speakButton: return NotchViewModel.translateSpeakButtonKey
        case .saveClipboardScreenshots: return NotchViewModel.saveClipboardImagesKey
        case .showScreenCaptures: return NotchViewModel.importRecordingsKey
        case .checkForUpdatesAutomatically: return UpdateCheck.automaticKey
        default: return nil
        }
    }

    /// What the row holds when its key is absent — spec §10's brackets and §14.
    /// nil where the row stores nothing of its own.
    var defaultValue: SettingsDefault? {
        switch self {
        case .launchAtLogin: return .off
        case .openOnHover: return .off
        case .hoverDelay: return .number(NotchMetrics.openDelay)
        case .panelWidth: return .number(Double(NotchMetrics.defaultBodyWidth))
        case .charging, .headphones, .newTracks: return .on
        case .volumeAndBrightness: return .off
        case .clipboardHistory, .includeImages: return .on
        case .keepPinned: return .off
        case .coverClipboard, .coverTranslate: return .off
        case .hideFromRecording: return .on
        case .musicOnly, .volumeAndOutput, .lyricBand: return .on
        case .showLyrics, .wordKaraoke: return .off
        case .showNextLineEarly: return .text("auto")
        case .lyricDelay: return .number(0)
        case .translateLyrics: return .off
        case .translateTo: return .text("automatic")
        case .lookUpLyricsOnline: return .off
        case .showOnLockScreen, .restAsBanner: return .on
        case .cardStyle: return .text(NotchViewModel.LockCardStyle.automatic.rawValue)
        case .cardSize: return .text(NotchViewModel.LockCardSize.standard.rawValue)
        case .translateOnline: return .off
        case .keepHistory: return .off
        case .speakButton: return .on
        case .saveClipboardScreenshots: return .off
        case .showScreenCaptures: return .on
        case .checkForUpdatesAutomatically: return .off
        default: return nil
        }
    }

    /// A switch's state in `defaults`: what is stored, or the default when
    /// nothing is. The one reading of "absent means the spec's default" —
    /// `NotchViewModel`'s accessors call it, so the form and the code that
    /// obeys the switch cannot disagree.
    func isOn(in defaults: UserDefaults) -> Bool {
        let fallback = defaultValue?.isOn ?? false
        guard let key, defaults.object(forKey: key) != nil else { return fallback }
        return defaults.bool(forKey: key)
    }

    /// Writes a switch. Where the row's key replaced an older one
    /// (`SettingsTable.renamedKeys`) the old key is written too, with the same
    /// value, for as long as it is listed there. `migrateRenamedKeys` copies an
    /// old value across once at launch and nothing carried a later choice back,
    /// so an older build run after this one found Charging on, in the state it
    /// had been left in before the update, however it had been turned since.
    func write(_ value: Bool, in defaults: UserDefaults) {
        guard let key else { return }
        defaults.set(value, forKey: key)
        if let legacy = SettingsTable.renamedKeys.first(where: { $0.new == key })?.old {
            defaults.set(value, forKey: legacy)
        }
    }
}

/// One thing the form lays down, top to bottom (spec §10; the boards' `form()`).
///
/// A flat list rather than a tree because the boards are one: a header, a group,
/// its footnote, a row of buttons, a gap. The view maps each to its spacing, so
/// the rhythm is stated once.
@MainActor
enum SettingsBlock: Equatable {
    /// A group header: 12 / semibold, title case (spec §10).
    case header(String)
    /// A card of rows, 28 tall, separated by inset hairlines.
    case group([SettingsRowID])
    /// 10.5 tertiary, wrapping, under the group it explains.
    case footnote(String)
    /// Push buttons at the form's trailing edge, outside any card, the way a
    /// Finder window's bottom bar and System Settings' "Advanced…" place them.
    case buttons([SettingsRowID])
    /// A row of its own, outside a card: the heads, the style previews.
    case free(SettingsRowID)
    case space(CGFloat)

    var rows: [SettingsRowID] {
        switch self {
        case .group(let rows), .buttons(let rows): return rows
        case .free(let row): return [row]
        case .header, .footnote, .space: return []
        }
    }
}

/// What the form needs to know to decide which blocks exist. A plain value, so
/// every branch of the table is a test with no view and no running player.
@MainActor
struct SettingsContext: Equatable {
    // General
    var hasBattery = true
    var offersVolumeAndBrightness = SettingsTable.shipsVolumeAndBrightness
    var opensOnHover = false
    var launchNote: String? = nil
    var offersLoginItems = false
    var followingYourMac: String? = nil
    // Privacy
    var clipboardHistoryOn = true
    var screenshotsKeepPolling = false
    // Shortcuts
    var shortcutNotes: [String] = []
    var canRestoreShortcuts = false
    // Music: the two failure groups, each only while its condition holds.
    var musicOnly = true
    var nowPlayingFailure: String? = nil
    var automation: [SettingsPane.AccessRow] = []
    /// The music apps installed on this Mac, in the order Settings lists them
    /// (`AppIcons.installedPlayers`). Empty draws no group: a header over a
    /// card with nothing in it says only that the list failed to load.
    var installedPlayers: [AppIcons.Installed] = []
    // Lyrics
    var delayIsSet = false
    var onlineLyrics = false
    var onlineTranslation = false
    var lyricsNotice: String? = nil
    var libraryHasFolders = false
    var hasUnassignedCorrections = false
    // Lock Screen
    var showOnLockScreen = true
    // Spotify: `SettingsPane.spotifyRows`, as it already was.
    var spotify: [SettingsPane.SpotifyRow] = [.connect]
    // About
    var offersDownload = false
    var updateNotes: [String] = []
    /// Check for Updates Automatically, as it stands: the line about what the
    /// check asks of GitHub is only true while it is on.
    var automaticUpdates = false
    var diagnosticsCopied = false
}

@MainActor
enum SettingsTable {
    /// Volume and Brightness (R5, spec §12) is a row of this table with a key and
    /// a default — and no place in it until R5 ships. **One flag**: R5 flips it
    /// to `true` and the General group shows the row, its footnote and the
    /// Accessibility group; nothing else in Settings changes.
    static let shipsVolumeAndBrightness = false
    static let volumeAndBrightnessKey = "island.showHUD"

    /// The sections, in the sidebar's order.
    static var sections: [SettingsSection] { SettingsSection.allCases }

    /// The form of a section: every block it lays down, in order.
    static func blocks(for section: SettingsSection, context: SettingsContext? = nil) -> [SettingsBlock] {
        let c = context ?? SettingsContext()
        switch section {
        case .general: return general(c)
        case .privacy: return privacy(c)
        case .shortcuts: return shortcuts(c)
        case .music: return music(c)
        case .lyrics: return lyrics(c)
        case .lockScreen: return lockScreen(c)
        case .translate: return translate(c)
        case .spotify: return spotify(c)
        case .screenshots: return screenshots(c)
        case .about: return about(c)
        }
    }

    /// The section's row identifiers, top to bottom.
    static func rows(for section: SettingsSection, context: SettingsContext? = nil) -> [SettingsRowID] {
        blocks(for: section, context: context).flatMap(\.rows)
    }

    // MARK: Sections

    private static func general(_ c: SettingsContext) -> [SettingsBlock] {
        var blocks: [SettingsBlock] = [.header(localized("General"))]
        var first: [SettingsRowID] = [.launchAtLogin, .openOnHover]
        // The hover delay is only worth a row while a hover is what opens the
        // panel; the default is nearly instant, which suits a real notch.
        if c.opensOnHover { first.append(.hoverDelay) }
        first.append(.panelWidth)
        blocks.append(.group(first))
        if let note = c.launchNote { blocks.append(.footnote(note)) }
        if c.offersLoginItems { blocks.append(.buttons([.openLoginItems])) }
        blocks.append(.footnote(localized("Click the notch to open the panel. Open on Hover also opens it when the pointer rests there.")))

        blocks.append(.header(localized("The island shows")))
        var shows: [SettingsRowID] = []
        // Only on a Mac with a battery to report on.
        if c.hasBattery { shows.append(.charging) }
        shows += [.headphones, .newTracks]
        if c.offersVolumeAndBrightness { shows.append(.volumeAndBrightness) }
        blocks.append(.group(shows))
        if c.offersVolumeAndBrightness {
            blocks.append(.footnote(localized("Volume and Brightness replaces the Mac’s own pop-up and needs Accessibility permission.")))
        }
        // Why the island moves or looks the way it does when the Mac asks for
        // less motion, less transparency or more contrast (M-34).
        if let following = c.followingYourMac { blocks.append(.footnote(following)) }
        return blocks
    }

    private static func privacy(_ c: SettingsContext) -> [SettingsBlock] {
        var blocks: [SettingsBlock] = [
            .header(localized("Clipboard")),
            .group([.clipboardHistory, .includeImages, .keepPinned]),
        ]
        if !c.clipboardHistoryOn {
            blocks.append(.footnote(SettingsPane.clipboardOffNote(imagesOn: c.screenshotsKeepPolling)))
        }
        blocks += [
            .footnote(SettingsPane.clipboardMemoryNote),
            .header(localized("Cover")),
            .group([.coverClipboard, .coverTranslate]),
            .footnote(SettingsPane.privacyCoversNote),
            .group([.hideFromRecording]),
            .footnote(SettingsPane.hideFromCaptureNote),
        ]
        return blocks
    }

    private static func shortcuts(_ c: SettingsContext) -> [SettingsBlock] {
        var blocks: [SettingsBlock] = [
            .header(localized("Keyboard Shortcuts")),
            .group([.shortcutOpenPanel, .shortcutLyrics, .shortcutTranslate]),
        ]
        for note in c.shortcutNotes { blocks.append(.footnote(note)) }
        blocks.append(.footnote(localized("Records a new shortcut. Press Delete to clear it, Escape to cancel.")))
        if c.canRestoreShortcuts { blocks.append(.buttons([.restoreShortcuts])) }
        return blocks
    }

    /// The Music section, and the only place Settings says a failure (spec §10:
    /// "one failure surface"): the reader being down, then a player Isla is not
    /// allowed to control, each a group of its own and each present only while
    /// its condition holds, above everything — while the reader is down, every
    /// switch under them describes music the island cannot see.
    private static func music(_ c: SettingsContext) -> [SettingsBlock] {
        var blocks: [SettingsBlock] = []
        if let failure = c.nowPlayingFailure {
            blocks += [
                .header(localized("Now Playing")),
                .group([.nowPlayingReader]),
                .footnote(failure),
            ]
        }
        // A player that is merely not running says nothing, and one that is
        // allowed needs nothing: the group is for a refusal, and carries the
        // state of every player Isla read so the refused one has its company.
        if c.automation.contains(.openAutomationSettings) {
            blocks += [
                .header(localized("Automation")),
                .group([.automationStatus, .automationPermission]),
            ]
            for case let .note(text) in c.automation { blocks.append(.footnote(text)) }
        }
        blocks += [
            .header(localized("Music")),
            .group([.musicOnly]),
            .footnote(c.musicOnly
                ? localized("Videos and films stay off the island.")
                : localized("Anything playing shows on the island, videos included.")),
        ]
        blocks += playersOnThisMac(c)
        blocks += [
            .header(localized("In the player")),
            .group([.volumeAndOutput, .lyricBand]),
            .footnote(localized("Volume and Output put the system volume and the AirPlay menu in the player. Lyric Band is the sung line and the next one, under the title.")),
        ]
        return blocks
    }

    /// The apps Isla recognises as music players, each with its real icon, and
    /// what Music Only does with them — written from `MediaSourcePolicy.allows`,
    /// the only place the island asks: a music or podcast app is always shown
    /// (rule 1), Telegram is shown for a song and not for a video (rule 3), any
    /// other app is shown when it labels what it plays as audio (rule 2), and
    /// with Music Only off nothing is filtered at all. Read-only: the list is a
    /// statement about the Mac, not a setting.
    ///
    /// This group's footnote is the one place the rule is stated. Music Only's
    /// own footnote used to say "Music apps, podcasts, and songs in Telegram
    /// still show" a screen's height above this one, and with Music Only on the
    /// two sat back to back saying nearly the same thing twice; Music Only's now
    /// says only what it hides, and with Music Only off this group has no
    /// footnote because "Anything playing shows" already says it.
    static func playersOnThisMac(_ c: SettingsContext) -> [SettingsBlock] {
        guard !c.installedPlayers.isEmpty else { return [] }
        var blocks: [SettingsBlock] = [
            .header(SettingsRowID.installedPlayers.title),
            .group([.installedPlayers]),
        ]
        if let note = playersNote(musicOnly: c.musicOnly, players: c.installedPlayers) {
            blocks.append(.footnote(note))
        }
        return blocks
    }

    static func playersNote(musicOnly: Bool, players: [AppIcons.Installed]) -> String? {
        guard musicOnly else { return nil }
        if players.contains(where: { MediaSourcePolicy.mixedApps.contains($0.bundleID) }) {
            return localized("These players always show, except Telegram, which shows songs but not videos. Any other app shows when it says it is playing audio.")
        }
        return localized("These players always show. Any other app shows when it says it is playing audio.")
    }

    private static func lyrics(_ c: SettingsContext) -> [SettingsBlock] {
        var blocks: [SettingsBlock] = [
            .header(localized("Lyrics")),
            .group([.showLyrics, .wordKaraoke, .showNextLineEarly]),
            .footnote(localized("The island's one-line lyric turns to the next line a little before it is sung; Auto gives longer lines more time. Highlight timing does not change.")),
            .group([.lyricDelay]),
        ]
        if c.delayIsSet { blocks.append(.buttons([.resetLyricDelay])) }
        blocks += [
            .footnote(localized("Negative shows lyrics earlier; positive, later.")),
            .header(localized("Translation")),
            .group([.translateLyrics, .translateTo]),
            .footnote(LyricTranslation.settingsNote(onlineEnabled: c.onlineTranslation)),
            .header(localized("Online")),
            .group([.lookUpLyricsOnline]),
            .footnote(c.onlineLyrics
                ? localized("Asks LRCLIB for tracks no local file matches. It sends the title, artist, album and length — nothing about you.")
                : localized("Lyrics stay on this Mac.")),
            .header(localized("Local Lyrics Library")),
            .buttons([.openLyricsFolder, .addLyricsFolder, .importLRC]),
        ]
        // Why the last Import LRC…, Add Lyrics Folder… or Rescan did not work.
        if let notice = c.lyricsNotice { blocks.append(.footnote(notice)) }
        if c.libraryHasFolders { blocks.append(.group([.libraryFolders])) }
        blocks += [
            .buttons([.rescanLocalLyrics]),
            .space(6),
            .buttons([.clearImportedLyrics]),
            .buttons([.clearBindings]),
        ]
        if c.hasUnassignedCorrections {
            blocks += [.header(localized("Unassigned timing corrections")), .group([.unassignedCorrections])]
        }
        return blocks
    }

    private static func lockScreen(_ c: SettingsContext) -> [SettingsBlock] {
        var blocks: [SettingsBlock] = [
            .header(localized("Lock Screen")),
            .group([.showOnLockScreen]),
        ]
        // Only worth offering while there is a card to finish.
        guard c.showOnLockScreen else { return blocks }
        blocks += [
            .header(localized("Card Style")),
            .free(.cardStyle),
            .footnote(localized("Automatic tints the card with the cover and reads the wallpaper behind it. With Reduce Transparency it is Solid.")),
            .group([.restAsBanner, .cardSize]),
            .footnote(localized("The card waits as a slim banner under the clock; click it to open.")),
        ]
        return blocks
    }

    private static func translate(_ c: SettingsContext) -> [SettingsBlock] {
        [
            .header(localized("Translate")),
            .group([.translateOnline]),
            // Which languages that is depends on the system: below macOS 26 it
            // is all of them.
            .footnote(c.onlineTranslation ? Translator.onlineNote() : localized("Translations stay on this Mac.")),
            .group([.keepHistory, .speakButton]),
            .footnote(localized("History keeps your last 20 translations in memory. Speak reads a translation aloud with the system voice.")),
            .buttons([.translationLanguages]),
        ]
    }

    /// The Spotify section from `SettingsPane.spotifyRows`: what just happened,
    /// the action, storage, refusal, what disconnecting keeps. Notes are inline,
    /// never a toast: the person acted on this section, so this section answers.
    private static func spotify(_ c: SettingsContext) -> [SettingsBlock] {
        var account: [SettingsRowID] = [.spotifyAccount]
        if c.spotify.contains(.importAccount) { account.append(.spotifyImport) }
        var blocks: [SettingsBlock] = [
            .header(localized("Spotify")),
            .free(.spotifyHead),
            .group(account),
        ]
        for case let .note(text) in c.spotify { blocks.append(.footnote(text)) }
        return blocks
    }

    private static func screenshots(_ c: SettingsContext) -> [SettingsBlock] {
        [
            .header(localized("Screenshots")),
            .group([.saveClipboardScreenshots, .showScreenCaptures]),
            .buttons([.showScreenshotsFolder, .clearScreenshotsFolder]),
        ]
    }

    private static func about(_ c: SettingsContext) -> [SettingsBlock] {
        var update: [SettingsRowID] = [.updateStatus]
        if c.offersDownload { update.append(.downloadUpdate) }
        update.append(.checkForUpdatesAutomatically)
        var blocks: [SettingsBlock] = [.free(.aboutHead), .group(update)]
        for note in c.updateNotes { blocks.append(.footnote(note)) }
        // Only while the switch is on: with it off nothing is asked of GitHub,
        // and the line used to say it was asked once a day.
        if c.automaticUpdates {
            blocks.append(.footnote(localized("Asks GitHub once a day for the latest version. It sends nothing about you.")))
        }
        blocks.append(.group([.copyDiagnostics, .reportProblem, .acknowledgements]))
        if c.diagnosticsCopied {
            blocks.append(.footnote(localized("Copied. It lists versions, settings and Isla's own log, and nothing you played, copied or translated.")))
        }
        blocks.append(.free(.quit))
        return blocks
    }

    // MARK: The one-time key rename (spec §10, last paragraph)

    /// Old key, new key: the three labels spec §10 renames — "Show Charging" to
    /// "Charging", "Show Headphones Connecting" to "Headphones Connecting",
    /// "Peek at New Tracks" to "New Tracks" — keep their meaning and get new keys.
    static let renamedKeys: [(old: String, new: String)] = [
        (NotchViewModel.legacyShowChargingKey, NotchViewModel.chargingKey),
        (NotchViewModel.legacyShowHeadphonesKey, NotchViewModel.headphonesKey),
        (NotchViewModel.legacySneakPeekKey, NotchViewModel.newTracksKey),
    ]
}
