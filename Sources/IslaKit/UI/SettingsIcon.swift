import Foundation

/// Every symbol the Settings pane draws, named once.
///
/// Gathered so the set can be judged as a set — an icon that means the wrong
/// thing is mostly visible next to its neighbours — and so a test can prove each
/// name still resolves. An unresolvable name draws nothing at all, which reads
/// as a broken build rather than as the typo it is.
///
/// The rule for choosing one: name the action, not the mood. A row that saves
/// gets the platform's save glyph; a row that connects an account gets a person;
/// a row that shows a brief preview gets an eye. Decorative symbols — `sparkles`
/// above all — say "something happens here" and nothing else.
enum SettingsIcon {
    // General
    static let launchAtLogin = "arrow.up.forward.app"
    /// A pointer resting on something, which is what the switch is about.
    static let openOnHover = "cursorarrow.rays"
    static let hoverDelay = "cursorarrow.motionlines"
    static let panelWidth = "arrow.left.and.right"

    // Keyboard Shortcuts
    /// The panel, at the top of the screen, which is what the shortcut opens.
    static let shortcutOpenPanel = "rectangle.topthird.inset.filled"
    /// The lyrics page's own glyph, not the Music section's switch.
    static let shortcutLyrics = "text.quote"
    static let shortcutTranslate = "translate"
    static let restoreShortcuts = "arrow.uturn.backward"

    // Screenshots
    static let saveScreenshots = "square.and.arrow.down"
    /// A recording arriving on its own: video coming in, not going out.
    static let importRecordings = "video.badge.plus"
    static let showFolder = "folder"
    static let clear = "trash"

    // Music
    /// What reaches the island at all: music, and not a film.
    static let musicOnly = "music.note"
    /// Apple Music's own glyph for lyrics.
    static let lyrics = "quote.bubble"
    /// Word-by-word, as opposed to the line: the glyph is about the words.
    static let wordKaraoke = "text.word.spacing"
    /// A file arriving. `saveScreenshots` already owns the tray glyph, and an
    /// import is a document being added, not a screenshot being kept.
    static let importLyrics = "doc.badge.plus"
    static let addFolder = "folder.badge.plus"
    /// Removing a folder from the library forgets it; nothing on disk is touched,
    /// so it is not the trash.
    static let removeFolder = "folder.badge.minus"
    static let rescan = "arrow.clockwise"
    /// Starting the Now Playing reader again, a cycle rather than a refresh.
    static let tryAgain = "arrow.triangle.2.circlepath"
    /// Dismissing a leftover timing correction sets it aside; it deletes no file.
    static let dismiss = "xmark.circle"
    /// A switch that reaches the network. The globe is kept for those and only
    /// those — lyrics looked up online, text translated online — so the rows
    /// that can send something off this Mac say so at a glance.
    static let online = "globe"
    /// The whole catalogue moved in time, as opposed to one track's nudge.
    static let lyricTiming = "metronome"
    static let resetTiming = "arrow.counterclockwise"
    /// A brief look at the track that just started.
    static let peek = "eye"
    static let lockScreen = "lock.display"
    static let cardSize = "rectangle.compress.vertical"
    /// Glass or solid is an appearance choice, and this is the system's
    /// appearance glyph.
    static let cardStyle = "circle.lefthalf.filled"

    // Spotify
    static let connectAccount = "person.crop.circle.badge.plus"
    static let disconnectAccount = "person.crop.circle.badge.minus"
    static let importFromKeychain = "key"

    // Privacy
    /// The same glyphs as the Clipboard and Translate tabs, so each feature
    /// reads as the same feature here.
    static let clipboard = "doc.on.clipboard"
    static let translate = "character.bubble"
    /// About recording, not about whether a person can see the panel.
    static let hideFromRecording = "video.slash"

    // Application
    static let about = "info.circle"
    static let quit = "power"

    static let all: [String] = [
        launchAtLogin, openOnHover, hoverDelay, panelWidth,
        shortcutOpenPanel, shortcutLyrics, shortcutTranslate, restoreShortcuts,
        saveScreenshots, importRecordings, showFolder, clear,
        musicOnly, lyrics, wordKaraoke, importLyrics, addFolder, removeFolder, rescan, tryAgain, dismiss,
        online, lyricTiming, resetTiming, peek, lockScreen, cardStyle,
        connectAccount, disconnectAccount, importFromKeychain,
        clipboard, translate, hideFromRecording,
        about, quit,
    ]
}
