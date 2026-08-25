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
    static let hoverDelay = "cursorarrow.motionlines"
    static let panelWidth = "arrow.left.and.right"

    // Screenshots
    static let saveScreenshots = "square.and.arrow.down"
    static let showFolder = "folder"
    static let clear = "trash"

    // Music
    /// Apple Music's own glyph for lyrics.
    static let lyrics = "quote.bubble"
    /// A brief look at the track that just started.
    static let peek = "eye"
    static let lockScreen = "lock.display"
    /// Glass or solid is an appearance choice, and this is the system's
    /// appearance glyph.
    static let cardStyle = "circle.lefthalf.filled"

    // Spotify
    static let connectAccount = "person.crop.circle.badge.plus"
    static let disconnectAccount = "person.crop.circle.badge.minus"
    static let importFromKeychain = "key"

    // Privacy
    static let clipboard = "list.clipboard.fill"
    static let translate = "translate"
    /// About recording, not about whether a person can see the panel.
    static let hideFromRecording = "video.slash"

    // Application
    static let about = "info.circle"
    static let quit = "power"

    static let all: [String] = [
        launchAtLogin, hoverDelay, panelWidth,
        saveScreenshots, showFolder, clear,
        lyrics, peek, lockScreen, cardStyle,
        connectAccount, disconnectAccount, importFromKeychain,
        clipboard, translate, hideFromRecording,
        about, quit,
    ]
}
