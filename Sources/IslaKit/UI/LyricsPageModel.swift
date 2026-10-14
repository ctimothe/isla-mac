import Foundation

/// What the lyric column and the tall page say, apart from any drawing (spec
/// §5.4), so which state wins — and what its sentence and buttons are — is
/// something a test reads rather than something it renders.
///
/// The player used to carry the status in a caption slot under the subtitle
/// ("Finding lyrics…", "Lyrics are off."); the redesign took that slot out, and
/// these states live where the words would have been: in the lyric area.
enum LyricsPageState: Equatable {
    /// Lines to draw.
    case lines
    /// Asked, with nothing to say yet — drawn as nothing, as the stage did, so a
    /// fast answer never flashes a spinner (`LyricsAvailability.resolving`).
    case resolving
    /// `Lyrics-Finding`: a spinner and "Looking for lyrics…".
    case looking
    /// Show Lyrics is off: "Lyrics are off." and the one switch that fixes it.
    case off
    /// Nothing can look this song up (a stream, a track with no title): said
    /// plainly, with no offer — nothing the listener can press would help.
    case cannotLookUp(String)
    /// `Lyrics-NotFound`: the sentence, Import LRC… and — only while the online
    /// lookup is off — Search Online, which turns it on.
    case noneFound(offersSearchOnline: Bool)
    /// More than one local file matches: the existing chooser.
    case chooseLocal
    /// `Lyrics-Invalid-File`: a file is bound and cannot be read; the line the
    /// parser names, when it names one.
    case unreadable(line: Int?)

    static func state(
        availability: LyricsAvailability,
        lyricsState: LyricsStore.State,
        localLookup: LocalLyricsLookup?,
        onlineEnabled: Bool,
        invalidLine: Int?
    ) -> LyricsPageState {
        switch availability {
        case .ready:
            // Ready with words still on their way to the store is the same wait
            // as looking: there is nothing to draw yet and something coming.
            if case .synced(let lines) = lyricsState, !lines.isEmpty { return .lines }
            return .looking
        case .resolving:
            return .resolving
        case .findingLocalLyrics:
            return .looking
        case .disabled:
            return .off
        case .cannotLookUp(.noLength):
            return .cannotLookUp(localized("No lyrics for live audio."))
        case .cannotLookUp(.noTitle):
            return .cannotLookUp(localized("This track has no title to look up."))
        case .noLocalLyrics:
            if case .ambiguous = localLookup { return .chooseLocal }
            return .noneFound(offersSearchOnline: !onlineEnabled)
        case .invalidLocalFile:
            return .unreadable(line: invalidLine)
        }
    }

    /// The unreadable file's sentence: the line the parser names when it names
    /// one, and the existing general sentence when it does not (an empty file, or
    /// one that cannot be read as text at all).
    static func unreadableSentence(line: Int?) -> String {
        guard let line else { return localized("Can't read the lyrics file for this song.") }
        return localized("Line %d of this file has a time Isla can't read.", line)
    }

    /// `Lyrics-NotFound`'s sentence. One sentence for both lookups: the board
    /// draws "No lyrics found for this song." beside Search Online, and the
    /// button is what says where else it could look.
    static var noneFoundSentence: String { localized("No lyrics found for this song.") }

    /// Whether a state wants the page's list area drawn at all. The states
    /// replace the lines; they never sit on top of them.
    var replacesLines: Bool { self != .lines }
}

/// The More menu's items, as a pure function of what decides them (spec §5.2,
/// `Lyrics-More-Menu` and `Lyrics-More-Menu-Local`). The presenter turns each
/// into an `NSMenuItem`; nothing here knows AppKit.
struct LyricsMoreMenuItem: Equatable {
    enum Kind: Equatable {
        case header
        case earlier
        case later
        /// The current correction, shown and never pressed.
        case offset
        case reset
        case separator
        case edit
        case removeBinding
        case importFile
        case searchAgain
        case settings
    }

    let kind: Kind
    let title: String
    var isEnabled = true
}

enum LyricsMoreMenuModel {
    /// The menu, top to bottom:
    ///
    /// ```
    /// Lyric Timing                       (header)
    /// − Lyrics Earlier
    /// + Lyrics Later
    /// +0.25s                             (disabled: the current offset)
    /// Reset Lyric Timing
    /// ─────
    /// Up Here.lrc                        (header, only with a local file bound)
    /// ✎ Edit Lyrics…
    /// ⊖ Remove Local Binding             (only with an explicit binding)
    /// ─────
    /// Import LRC File…
    /// ↻ Search Again                     (only with Look Up Lyrics Online on)
    /// ─────
    /// Lyrics Settings…
    /// ```
    ///
    /// - Parameters:
    ///   - localFileName: the local file the words come from, when one does —
    ///     it heads the file group and Edit Lyrics… is offered for it (today's
    ///     stage had the pencil for exactly this case).
    ///   - hasBinding: whether the song is bound to it by a choice of the
    ///     listener's, which is what Remove Local Binding undoes (a file merely
    ///     matched by its tags has no binding to remove).
    ///   - onlineOn: Look Up Lyrics Online; Search Again asks it again, so
    ///     without it there is nothing to ask.
    ///   - offset: this track's correction, in seconds.
    ///   - canNudge: whether there are synced words to correct. Without them a
    ///     nudge would sit in the overlay and be eaten by the next cache hit
    ///     (`LyricsStage.canNudgeTrack`'s reason), so Earlier and Later dim.
    static func items(
        localFileName: String?, hasBinding: Bool = true, onlineOn: Bool, offset: TimeInterval,
        canNudge: Bool = true
    ) -> [LyricsMoreMenuItem] {
        var items: [LyricsMoreMenuItem] = [
            .init(kind: .header, title: localized("Lyric Timing")),
            .init(kind: .earlier, title: localized("Lyrics Earlier"), isEnabled: canNudge),
            .init(kind: .later, title: localized("Lyrics Later"), isEnabled: canNudge),
            .init(kind: .offset, title: localized("%+.2fs", offset), isEnabled: false),
            .init(kind: .reset, title: localized("Reset Lyric Timing"), isEnabled: abs(offset) > resetThreshold),
            .init(kind: .separator, title: ""),
        ]
        if let localFileName {
            items.append(.init(kind: .header, title: localFileName))
            items.append(.init(kind: .edit, title: localized("Edit Lyrics…")))
            if hasBinding {
                items.append(.init(kind: .removeBinding, title: localized("Remove Local Binding")))
            }
            items.append(.init(kind: .separator, title: ""))
        }
        items.append(.init(kind: .importFile, title: localized("Import LRC File…")))
        if onlineOn {
            items.append(.init(kind: .searchAgain, title: localized("Search Again")))
        }
        items.append(.init(kind: .separator, title: ""))
        items.append(.init(kind: .settings, title: localized("Lyrics Settings…")))
        return items
    }

    /// A correction under this is none: the old readout drew nothing for it,
    /// and Reset has nothing to clear.
    static let resetThreshold: TimeInterval = 0.01

    /// The step Earlier and Later move the track's layer by — the stage's own
    /// 0.25 s, kept so a nudge means what it always did.
    static let nudgeStep: TimeInterval = 0.25

    /// The file the header names: the file's own name where it has one, and for
    /// an Isla-owned copy — stored under a name nobody chose — the song's
    /// title as an `.lrc`, which is what the person would call it.
    static func fileName(stored: String?, candidate: LocalLyricsCandidate, trackTitle: String?) -> String {
        if let stored, !stored.isEmpty { return stored }
        let title = [candidate.document.metadata.title, trackTitle]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? localized("Lyrics")
        return title + ".lrc"
    }
}
