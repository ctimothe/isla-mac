import Foundation

/// Synced lyrics for the current track, from LRCLIB.
///
/// This is the app's first and only network call, so its manners matter. One
/// request per track, ever: an answer — including "no lyrics exist" — is
/// cached on disk, so replaying an album a year later asks for nothing twice.
/// Fetching happens only while the media pane is actually showing, and an
/// off switch in Settings turns the feature, and with it the network, off
/// entirely.
///
/// LRCLIB because it is the one open, keyless, account-less source of
/// timestamped lyrics; every player's own lyrics API is private. The `get`
/// endpoint matches on title, artist, album and duration, which is exactly
/// the identity the media feed already carries.
@MainActor
final class LyricsStore: ObservableObject {
    struct Line: Equatable {
        /// Seconds from the start of the track at which this line begins.
        var at: TimeInterval
        let text: String
        /// Word starts within this line, when a word-synced source had them.
        var words: [WordSyncedLyrics.Word] = []
        /// Who wrote, produced or mixed the track, rather than a word anybody
        /// sings. Shown during the intro and never swept: a sweep says "this is
        /// being sung right now", which of a producer credit is a lie.
        var isCredit: Bool = false

        init(at: TimeInterval, text: String, words: [WordSyncedLyrics.Word] = [], isCredit: Bool = false) {
            self.at = at
            self.text = text
            self.words = words
            self.isCredit = isCredit
        }
    }

    enum State: Equatable {
        case idle
        case loading
        /// Sorted by time. Empty never reaches here — that is `.none`.
        case synced([Line])
        /// The track exists in the catalogue without timestamps, or not at all.
        case none
    }

    @Published private(set) var state: State = .idle

    /// The cache key the current `state` describes — the track without the
    /// Spotify id, so a second lookup for the same song can be told apart from a
    /// different one.
    private var loadedCacheKey: String?
    /// Words held across a same-track reload, so the caption never empties while
    /// a better source is being asked.
    private var retained: [Line]?

    /// The listener's own correction to lyric timing, in seconds. Positive
    /// makes lines arrive later, negative earlier.
    ///
    /// However good the clock, some catalogue entries are simply timed against
    /// a different master of the song — a remaster shifted by half a second is
    /// common — and no amount of position accuracy can fix data that is offset
    /// at the source. Every serious karaoke surface ships this knob. Persisted
    /// globally: this is the catalogue-wide layer for "every source runs a
    /// beat hot". A single entry's own shift belongs to the per-track layer
    /// below, so fixing one remaster never moves any other track.
    @Published var userOffset: TimeInterval = UserDefaults.standard.double(forKey: LyricsStore.offsetKey) {
        didSet {
            let clamped = min(max(userOffset, -3), 3)
            if clamped != userOffset { userOffset = clamped; return }
            UserDefaults.standard.set(userOffset, forKey: Self.offsetKey)
        }
    }
    static let offsetKey = "lyrics.userOffset"

    /// The per-track timing correction for the loaded track, in seconds — the
    /// layer the stage's Sync buttons write. A remaster shifted half a second
    /// is fixed once, for that track, forever, without moving any other track.
    ///
    /// Clamped at write (±`trackOffsetLimit`), summed unclamped at read in
    /// `LyricSweep.lead` together with the global and the source bias. Keyed
    /// by cache key and persisted inside the v4 entry, so it survives relaunch
    /// and never leaks across tracks. The overlay carries nudges made while
    /// no entry is on disk yet — before the first fetch settles — into the
    /// write that follows.
    @Published private(set) var trackOffset: TimeInterval = 0
    static let trackOffsetLimit: TimeInterval = 1.5
    private var trackOffsets: [String: TimeInterval] = [:]
    /// The tier the loaded words came from, for its code-only bias. Nil until
    /// the first settle or cache hit, in which case the bias reads 0.
    private var loadedSource: LyricSource?

    /// The source tier's correction for the loaded track. Seeded 0 for every
    /// tier; adjustable only here, in code, when a whole catalogue proves hot.
    var currentSourceBias: TimeInterval { loadedSource?.bias ?? 0 }

    /// The full correction applied at read: global, then source, then track.
    /// A plain sum — each layer was already clamped where it was written.
    var effectiveOffset: TimeInterval {
        userOffset + currentSourceBias + trackOffset
    }

    /// Moves the loaded track's layer by `delta`, clamped to ±1.5s. With no
    /// track loaded there is nothing to correct, so the call is a no-op.
    func nudgeTrackOffset(by delta: TimeInterval) {
        guard let key = loadedCacheKey else { return }
        setTrackOffset((trackOffsets[key] ?? trackOffset) + delta, for: key)
    }

    /// Forgets the loaded track's correction. The long-press on the stage's
    /// offset readout is the only caller in the UI.
    func clearTrackOffset() {
        guard let key = loadedCacheKey else { return }
        setTrackOffset(0, for: key)
    }

    private func setTrackOffset(_ value: TimeInterval, for key: String) {
        let clamped = min(max(value, -Self.trackOffsetLimit), Self.trackOffsetLimit)
        trackOffsets[key] = clamped
        if key == loadedCacheKey { trackOffset = clamped }
        persistTrackOffset()
    }

    /// Rewrites the v4 entry carrying the current layer. Only when there is
    /// an entry to rewrite: settled words from a known tier. A nudge made
    /// before the first settle has no lines to rewrite with, so the overlay
    /// above holds it until the fetch's own write lands.
    private func persistTrackOffset() {
        guard let key = loadedCacheKey,
              case .synced(let lines) = state,
              let source = loadedSource else { return }
        writeCache(key, lines: lines, source: source, trackOffset: trackOffsets[key] ?? 0)
    }

    private let session: URLSession
    private let cacheDirectory: URL
    private var loadedKey: String?
    private var inFlight: Task<Void, Never>?

    init(session: URLSession? = nil, cacheDirectory: URL? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 8
            // The disk cache below is the real cache; URLSession's would be a
            // second copy of the same bytes.
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration)
        }
        self.cacheDirectory = cacheDirectory ?? AppPaths.live.supportFile("lyrics")
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("IslaLyrics", isDirectory: true)
    }

    // MARK: - Load identity

    /// The exact catalogue duration as load identity, bucketed to 0.1s.
    ///
    /// The daemon reports a rounded number while the Web API knows the real
    /// one, and raw doubles would re-fire on float noise; the bucket is what
    /// converges. Empty for unknown, so a reading refines nil exactly once.
    /// The views' task ids build from this, so both change in lockstep.
    static func exactDurationIdentity(_ exactDuration: TimeInterval?) -> String {
        guard let exactDuration else { return "" }
        return "|d\(Int((exactDuration * 10).rounded()))"
    }

    /// Called with the displayed track. Same track twice is free.
    /// - Parameter spotifyID: the catalogue id when Spotify is the player —
    ///   the community word-synced database is keyed by it.
    /// - Parameter isrc: the catalogue ISRC from Task 1's Web-API metadata,
    ///   letting searched tiers join on recording identity instead of text.
    /// - Parameter exactDuration: the catalogue duration in seconds, the
    ///   number the duration gate compares against instead of the daemon's
    ///   rounded reading. Bucketed to 0.1s in the load identity below.
    func load(
        title: String, artist: String, album: String, duration: TimeInterval,
        spotifyID: String? = nil, isrc: String? = nil, exactDuration: TimeInterval? = nil
    ) {
        let key = Self.cacheKey(title: title, artist: artist, album: album, duration: duration)
        // A track whose Spotify id arrives a beat after its metadata reloads
        // once: the id unlocks the word-synced database, and it is worth one
        // more lookup. An id-bearing load is never replaced by an id-less one.
        // The Web-API metadata arrives later still, carrying the ISRC and the
        // exact catalogue duration, and reloads once more: exact identity can
        // rescue a match the text search got wrong, the gate compares against
        // the real duration instead of the daemon's rounded reading, and the
        // held words cover the gap. The duration rides in identity bucketed
        // to 0.1s — without this the equal-identity early return below would
        // keep the refinement from ever applying. The bucket converges:
        // snapshot-rounded first, exact second, then stable: at most one
        // extra fetch per track, and sub-0.05s jitter never leaves its
        // bucket. It sits before the ISRC so an isrc-less echo stays a string
        // prefix of the load it echoes, which is what the stale-echo guard
        // below recognizes. A load carrying *less* identity than the one in
        // flight is a stale echo, not news — the views re-fire their task on
        // every published change, so an isrc-less reload after an isrc-bearing
        // one would otherwise downgrade the match and fetch again for nothing.
        // The views' task ids mirror this identity, so each refinement
        // re-fires the load exactly once.
        let identity = key + (spotifyID.map { "|\($0)" } ?? "") + Self.exactDurationIdentity(exactDuration) + (isrc.map { "|\($0)" } ?? "")
        guard identity != loadedKey else { return }
        if let loadedKey, loadedKey.hasPrefix(identity) { return }
        loadedKey = identity
        inFlight?.cancel()

        guard !title.isEmpty, duration > 0 else {
            retained = nil
            loadedCacheKey = nil
            state = .none
            return
        }

        // The words already on screen stay there while the same track is looked
        // up again.
        //
        // A Spotify track resolves twice: once on its metadata, and again a beat
        // later when the catalogue id arrives and unlocks the word-synced source.
        // Blanking on that second pass emptied the caption mid-song for as long as
        // a network round trip takes — the song kept playing and the words went
        // away. They are the same track's words either way, so they are held until
        // something better answers.
        if case .synced(let showing) = state, loadedCacheKey == key {
            retained = showing
        } else {
            retained = nil
            state = .loading
        }
        loadedCacheKey = key
        let referenceDuration = exactDuration ?? duration
        inFlight = Task { [weak self] in
            guard let self else { return }
            // The cache read is disk I/O and JSON decoding, so it happens off
            // the main actor like the write does — it used to run inline on
            // every track change, in the frame the lyric crossfade was
            // animating.
            let url = self.cacheURL(key)
            let skipCache = self.bypassCacheOnce
            self.bypassCacheOnce = false
            let cached = skipCache ? nil : await Task.detached(priority: .userInitiated) {
                Self.readCacheEntry(at: url)
            }.value
            guard !Task.isCancelled, self.loadedKey == identity else { return }
            if let cached {
                // The persisted track layer comes back with the words: the
                // offset corrected this entry's timing, so it is restored for
                // exactly this key and no other.
                self.loadedSource = cached.source
                self.trackOffsets[key] = cached.trackOffset
                self.trackOffset = cached.trackOffset
                self.settle(Self.cleaned(cached.lines, title: title, artist: artist))
                return
            }
            await self.fetch(
                key: identity, cacheKey: key, spotifyID: spotifyID, isrc: isrc,
                title: title, artist: artist, album: album,
                duration: duration, refDuration: referenceDuration
            )
        }
    }

    /// Publishes a result without throwing a better one away.
    ///
    /// An empty answer for a track whose words are already on screen means this
    /// source knew less than the last, not that the song has no lyrics. Taking it
    /// at face value is how a word-synced lookup that missed took the line-level
    /// lyrics down with it.
    private func settle(_ lines: [Line]) {
        if lines.isEmpty, let retained, !retained.isEmpty {
            state = .synced(retained)
            return
        }
        retained = nil
        state = lines.isEmpty ? .none : .synced(lines)
    }

    func clear() {
        inFlight?.cancel()
        loadedKey = nil
        loadedCacheKey = nil
        loadedSource = nil
        trackOffset = 0
        retained = nil
        state = .idle
    }

    /// Throws away what was cached for this track and asks the services again.
    ///
    /// The escape hatch for a bad match. The Kugou and LRCLIB tiers find
    /// lyrics by *search*, and a search can land on a cover, a remix, or the
    /// wrong song outright — after which the cache faithfully serves the wrong
    /// answer on every replay forever, with nothing short of clearing the
    /// whole cache to fix one track. This deletes exactly that entry and
    /// re-runs the full three-tier fetch with the cache bypassed for one pass.
    func research(
        title: String, artist: String, album: String, duration: TimeInterval,
        spotifyID: String? = nil, isrc: String? = nil, exactDuration: TimeInterval? = nil
    ) {
        inFlight?.cancel()
        let key = Self.cacheKey(title: title, artist: artist, album: album, duration: duration)
        let url = cacheURL(key)
        Self.cacheIO.async {
            try? FileManager.default.removeItem(at: url)
        }
        // The deleted entry carried this track's correction, and the correction
        // belonged to that entry's timing — a fresh match may be timed
        // differently, so the layer restarts at 0 rather than silently moving
        // words it was never measured against. Done without persisting: the
        // file is already gone and the refetch's own write lands the 0.
        trackOffsets.removeValue(forKey: key)
        if loadedCacheKey == key { trackOffset = 0 }
        loadedKey = nil
        bypassCacheOnce = true
        load(
            title: title, artist: artist, album: album, duration: duration,
            spotifyID: spotifyID, isrc: isrc, exactDuration: exactDuration
        )
    }

    /// Every cache mutation — writes, the v3 prune riding along, research
    /// deletions, full clears — goes through this one serial queue, in
    /// dispatch order. The global queue used to let a fetch's write overtake a
    /// nudge's rewrite of the same file and pin the track to the older value;
    /// a serial queue cannot reorder them.
    nonisolated private static let cacheIO = DispatchQueue(label: "Isla.lyricsCache", qos: .utility)

    /// One-shot cache bypass, consumed by the next `load`.
    private var bypassCacheOnce = false

    /// Catalogue hygiene, applied to every source in one place.
    ///
    /// LRC files routinely open with a credit line — the song's own
    /// "Title - Artist", sometimes a lyricist credit — stamped at t≈0. It is
    /// metadata wearing a lyric's clothes, and displayed it reads as a bad
    /// match even when the match is right. Dropped when it echoes the track's
    /// identity; and a file that is nothing but credits is not lyrics at all.
    /// Prefixes that announce a credit rather than a lyric, in the languages
    /// the three catalogues actually ship.
    private static let creditPrefixes = [
        "作词", "作曲", "编曲", "制作", "混音", "母带",
        "lyrics by", "composed by", "written by", "produced by", "producer",
        "mixed by", "mastered by", "arranged by", "engineered by", "featuring",
    ]

    static func cleaned(_ lines: [Line], title: String, artist: String) -> [Line] {
        let fold: (String) -> String = { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased() }
        let t = fold(title), a = fold(artist)
        var result = lines
        var index = 0
        // Only the run at the top: the same words later in a song are somebody
        // singing them.
        while index < result.count {
            let text = fold(result[index].text)
            let echoesTheTrack = (!t.isEmpty && text.contains(t)) && (!a.isEmpty && text.contains(a))
            let announcesACredit = creditPrefixes.contains { text.hasPrefix($0) }
            guard echoesTheTrack || announcesACredit else { break }
            result[index].isCredit = true
            index += 1
        }
        // A file that is nothing but credits is not lyrics, and one surviving
        // sung line is a fragment rather than a song.
        guard result.filter({ !$0.isCredit }).count >= 2 else { return [] }
        return spacedCredits(result)
    }

    /// The shortest a credit may stay on screen and still be read.
    static let minimumCreditSlot: TimeInterval = 1.4
    /// And the longest it is worth holding one.
    static let maximumCreditSlot: TimeInterval = 3.0

    /// Gives each opening credit its own moment.
    ///
    /// Catalogues stamp the whole block at zero, which would put four names on
    /// the same instant: the display shows the last of them and the rest never
    /// existed. Spread across the intro instead — the room between the first
    /// credit and the first sung line — each gets a slot long enough to read,
    /// and none is ever pushed onto the singing. Where the intro is too short
    /// for the whole block, only what fits is kept.
    static func spacedCredits(_ lines: [Line]) -> [Line] {
        let credits = lines.prefix { $0.isCredit }
        guard credits.count > 1 || (credits.count == 1 && lines.count > 1) else { return lines }
        guard let firstSung = lines.dropFirst(credits.count).first else { return lines }

        let start = credits.first?.at ?? 0
        let room = firstSung.at - start
        guard room > minimumCreditSlot else {
            // No intro to speak of: a credit shown for a blink is worse than
            // none, so the block goes and the song starts on its first word.
            return Array(lines.dropFirst(credits.count))
        }
        let affordable = min(credits.count, max(1, Int(room / minimumCreditSlot)))
        let slot = min(maximumCreditSlot, room / Double(affordable))
        var result = Array(lines.dropFirst(credits.count))
        for (index, credit) in credits.prefix(affordable).enumerated().reversed() {
            var moved = credit
            moved.at = start + Double(index) * slot
            result.insert(moved, at: 0)
        }
        return result
    }

    /// Where the settled words came from. Written into every cache entry so
    /// later work (finer clocks, per-track offsets) can tell a word-synced
    /// track from a line-level one without refetching.
    enum LyricSource: String {
        case amll
        case qq
        case kugou
        case lrclib

        /// How much a tier is trusted when two answer at once. The exact-ID
        /// database never actually reaches arbitration — an answer keyed by
        /// track id is used, not scored — but it heads the table so the order
        /// reads as the fetch order. LRCLIB never arbitrates either: it is
        /// the line floor below every word tier, so its trust is unused.
        var trust: Double {
            switch self {
            case .amll: return 1.0
            case .qq: return 0.95
            case .kugou: return 0.85
            case .lrclib: return 0
            }
        }

        /// This tier's catalogue-wide timing correction, in seconds. Every
        /// tier is seeded 0; when a whole source proves consistently hot or
        /// cold the fix is one literal here, never a setting and never a
        /// migration — the sum in `LyricSweep.lead` picks it up for every
        /// track from that tier at once.
        var bias: TimeInterval {
            switch self {
            case .amll: return 0
            case .qq: return 0
            case .kugou: return 0
            case .lrclib: return 0
            }
        }
    }

    /// A search hit from a word tier, reduced to what matching judges.
    struct MatchCandidate {
        let title: String
        let artist: String
        let duration: TimeInterval?
        let isrc: String?
    }

    /// Case- and diacritic-folded, the same fold `cleaned` judges credits by.
    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
    }

    /// What reissues add to a title the catalogue filed plain: featured
    /// artists, parentheticals ("(Remastered)", "(Live)"), " - Remaster…"
    /// suffixes. Applied to the query side when the raw texts disagree, so
    /// "Title (Remastered)" still finds "Title".
    static func cleanTitle(_ title: String) -> String {
        var text = title
        text = text.replacingOccurrences(of: #"(?i)\s*\b(feat\.?|ft\.?|featuring)\b.+$"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s*[\(\[].*?[\)\]]"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)\s+-\s+remaster.*$"#, with: "", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespaces)
    }

    static func cleanArtist(_ artist: String) -> String {
        var text = artist
        text = text.replacingOccurrences(of: #"(?i)\s*\b(feat\.?|ft\.?|featuring)\b.+$"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s*[\(\[].*?[\)\]]"#, with: "", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespaces)
    }

    private static func textScore(queryTitle: String, queryArtist: String, title: String, artist: String) -> Double {
        func part(_ a: String, _ b: String) -> Double {
            if a.isEmpty || b.isEmpty { return 0 }
            if a == b { return 1 }
            // A catalogue entry filed plain against a tagged query, or the
            // reverse — close, but not the certainty of equality.
            if a.contains(b) || b.contains(a) { return 0.8 }
            return 0
        }
        return (part(queryTitle, title) + part(queryArtist, artist)) / 2
    }

    private static func passesGate(_ duration: TimeInterval?, refDuration: TimeInterval) -> Bool {
        // Same recording, same length: the one rule that keeps a cover or a
        // remix with the right name from masquerading as the original. A hit
        // with no duration cannot be checked and is rejected rather than
        // trusted — the old Kugou tier required it too.
        guard let duration else { return false }
        return abs(duration - refDuration) <= 3
    }

    /// Picks the searched hit to download. An ISRC-exact hit — the same
    /// recording by catalogue identity, from Task 1's Web-API metadata —
    /// outranks any scored hit outright. The rest rank by title/artist
    /// resemblance, raw then cleaned, among the hits inside the ±3s duration
    /// gate. Ties keep the provider's own order. A pool with nothing
    /// resembling the query answers nil rather than its first row: without a
    /// floor, index 0 won by default and a wrong song played word-synced.
    static func pickMatch(
        title: String, artist: String, isrc: String?,
        refDuration: TimeInterval, candidates: [MatchCandidate]
    ) -> Int? {
        if let isrc, !isrc.isEmpty {
            let wanted = isrc.uppercased()
            if let exact = candidates.firstIndex(where: {
                guard let hit = $0.isrc, !hit.isEmpty else { return false }
                return hit.uppercased() == wanted
            }) { return exact }
        }
        let queryTitle = normalize(title), queryArtist = normalize(artist)
        let cleanQueryTitle = normalize(cleanTitle(title)), cleanQueryArtist = normalize(cleanArtist(artist))
        var best: (index: Int, score: Double)?
        for (index, candidate) in candidates.enumerated() {
            guard passesGate(candidate.duration, refDuration: refDuration) else { continue }
            // Only the query side is cleaned: stripping the catalogue side
            // would erase the very markers — "(Cover)", "(Live)" — that tell
            // a re-recording from the original.
            let candidateTitle = normalize(candidate.title), candidateArtist = normalize(candidate.artist)
            let raw = textScore(
                queryTitle: queryTitle, queryArtist: queryArtist,
                title: candidateTitle, artist: candidateArtist
            )
            let cleaned = textScore(
                queryTitle: cleanQueryTitle, queryArtist: cleanQueryArtist,
                title: candidateTitle, artist: candidateArtist
            )
            let score = max(raw, cleaned)
            if score > (best?.score ?? -1) { best = (index, score) }
        }
        guard let best, best.score > 0 else { return nil }
        return best.index
    }

    /// How much of a tier is genuinely word-timed. Line-level stragglers
    /// inside a word tier score below a fully timed one.
    static func wordCoverage(_ lines: [Line]) -> Double {
        guard !lines.isEmpty else { return 0 }
        return Double(lines.filter { !$0.words.isEmpty }.count) / Double(lines.count)
    }

    /// Whether a tier's timing is believable: lines in order, words in order
    /// within their line, and no word ending past the track. Ends get a
    /// second of grace — the snapshot duration is the daemon's rounded
    /// reading against the provider's own clock, and a tier timed a beat
    /// long is mistimed data only past that.
    static func timingSanity(_ lines: [Line], duration: TimeInterval) -> Double {
        guard !lines.isEmpty else { return 0 }
        for pair in zip(lines, lines.dropFirst()) {
            if pair.1.at < pair.0.at { return 0 }
        }
        var within = 0, total = 0
        for line in lines {
            var last = line.at
            for word in line.words {
                if word.at < last { return 0 }
                last = word.at
                total += 1
                if (word.end ?? word.at) <= duration + 1 { within += 1 }
            }
        }
        guard total > 0 else { return 1 }
        return Double(within) / Double(total)
    }

    /// Best non-empty word tier wins: coverage times sanity times source
    /// trust. A zero — insane timing, or nothing timed at all — never wins;
    /// the caller falls through to the line floor instead.
    static func arbitrate(_ contenders: [(LyricSource, [Line])], duration: TimeInterval) -> (LyricSource, [Line])? {
        var best: (LyricSource, [Line], Double)?
        for (source, lines) in contenders {
            guard !lines.isEmpty else { continue }
            let score = wordCoverage(lines) * timingSanity(lines, duration: duration) * source.trust
            if score > (best.map(\.2) ?? 0) { best = (source, lines, score) }
        }
        return best.map { ($0.0, $0.1) }
    }

    /// The line being sung at `position`, and the one after it.
    ///
    /// Pure and computed by the caller per repaint rather than published per
    /// tick: the media pane already redraws four times a second for the
    /// progress bar, so publishing the current line as state would only add a
    /// second invalidation for information the repaint already has.
    static func current(in lines: [Line], at position: TimeInterval) -> (line: Line?, next: Line?) {
        guard !lines.isEmpty else { return (nil, nil) }
        // Binary search for the last line at or before the position.
        var low = 0
        var high = lines.count - 1
        var found = -1
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].at <= position {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        let line = found >= 0 ? lines[found] : nil
        let next = found + 1 < lines.count ? lines[found + 1] : nil
        return (line, next)
    }

    /// How long the voice plausibly spends singing `text`, inside a slot that
    /// runs until the next line starts.
    ///
    /// The slot is the wrong span to sweep over: it includes whatever
    /// instrumental gap follows the words, so a line before a pause swept at
    /// half the voice's speed and sat behind every word from the middle on.
    /// Singing runs on the order of twelve characters a second; estimating
    /// from length and capping at the slot means the sweep finishes when the
    /// words do and then holds, full, through the silence.
    static func sweepSpan(text: String, slot: TimeInterval) -> TimeInterval {
        let estimated = Double(text.count) * 0.08
        return min(max(estimated, 1.0), max(slot, 0.5))
    }

    // MARK: - Fetch

    private func fetch(
        key: String, cacheKey: String, spotifyID: String?, isrc: String?,
        title: String, artist: String, album: String,
        duration: TimeInterval, refDuration: TimeInterval
    ) async {
        // The exact-ID database first and alone: an answer keyed by track id
        // is used, never scored — and it used to be awaited jointly with the
        // two searches, so every exact hit paid for both before it could be
        // used. The searches start only on a miss now; arbitration among them
        // is unchanged.
        // Staging taxes every word-tier miss with the full amll latency: QQ
        // and Kugou wait for it to answer or time out first. Accepted on
        // purpose — amll hits are the common Spotify case, so the exact answer
        // lands sooner for most tracks than a joint start would let it, and a
        // miss merely waits out one lookup. A hanging amll delays the miss by
        // at most the session's 8s request timeout, never forever.
        let amllLines = await fetchAmll(spotifyID: spotifyID)
        guard !Task.isCancelled, loadedKey == key else { return }
        if let amllLines, !amllLines.isEmpty {
            let usable = Self.cleaned(amllLines, title: title, artist: artist)
            if !usable.isEmpty {
                settleFetched(key: cacheKey, lines: usable, source: .amll)
                return
            }
        }
        async let qq = fetchQQ(title: title, artist: artist, isrc: isrc, refDuration: refDuration)
        async let kugou = fetchKugou(title: title, artist: artist, isrc: isrc, refDuration: refDuration)
        let (qqLines, kugouLines) = await (qq, kugou)
        guard !Task.isCancelled, loadedKey == key else { return }
        if let (source, lines) = Self.arbitrate(
            [(.qq, qqLines ?? []), (.kugou, kugouLines ?? [])], duration: refDuration
        ) {
            guard !Task.isCancelled, loadedKey == key else { return }
            let usable = Self.cleaned(lines, title: title, artist: artist)
            if !usable.isEmpty {
                settleFetched(key: cacheKey, lines: usable, source: source)
                return
            }
        }
        await fetchLRCLIB(key: key, cacheKey: cacheKey, title: title, artist: artist, album: album, duration: duration)
    }

    /// Publishes a fetched tier: remembers its source for the bias layer,
    /// restores a nudge made while the fetch was in flight, and writes both
    /// to the v4 entry together so the next launch replays them as one.
    private func settleFetched(key: String, lines: [Line], source: LyricSource) {
        loadedSource = source
        let offset = trackOffsets[key] ?? 0
        trackOffset = offset
        writeCache(key, lines: lines, source: source, trackOffset: offset)
        state = .synced(lines)
    }

    /// The amll-ttml-db community database: CC0, word-by-word TTML, one file
    /// per Spotify track id, served straight from the repository. Nil id in,
    /// nil out — the tier simply does not exist without one.
    private func fetchAmll(spotifyID: String?) async -> [Line]? {
        guard let spotifyID,
              let url = URL(string: "https://raw.githubusercontent.com/Steve-xmh/amll-ttml-db/main/spotify-lyrics/\(spotifyID).ttml"),
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let parsed = WordSyncedLyrics.parseTTML(data)
        guard !parsed.isEmpty else { return nil }
        return parsed.map { Line(at: $0.at, text: $0.text, words: $0.words) }
    }

    /// QQ Music's word-synced tier: scored search, then the QRC download for
    /// the winning hit.
    private func fetchQQ(title: String, artist: String, isrc: String?, refDuration: TimeInterval) async -> [Line]? {
        let pool = await QQLyrics.searchSongs(title: title, artist: artist, session: session)
        guard !pool.isEmpty else { return nil }
        let candidates = pool.map {
            MatchCandidate(title: $0.title, artist: $0.artist, duration: $0.duration, isrc: $0.isrc)
        }
        guard let index = Self.pickMatch(
            title: title, artist: artist, isrc: isrc,
            refDuration: refDuration, candidates: candidates
        ) else { return nil }
        guard let body = await QQLyrics.fetchLyric(songID: pool[index].songID, session: session) else { return nil }
        let parsed = WordSyncedLyrics.parseQRCBody(body)
        guard !parsed.isEmpty else { return nil }
        return parsed.map { Line(at: $0.at, text: $0.text, words: $0.words) }
    }

    /// Kugou's lyric search and KRC download. Unofficial and keyless; the
    /// scored match (ISRC, then text inside the ±3s duration gate) keeps a
    /// cover or remix from masquerading, the same rule the LRCLIB search
    /// fallback uses.
    private func fetchKugou(title: String, artist: String, isrc: String?, refDuration: TimeInterval) async -> [Line]? {
        var search = URLComponents(string: "https://lyrics.kugou.com/search")!
        search.queryItems = [
            URLQueryItem(name: "ver", value: "1"),
            URLQueryItem(name: "man", value: "yes"),
            URLQueryItem(name: "client", value: "pc"),
            URLQueryItem(name: "keyword", value: "\(artist) - \(title)"),
            URLQueryItem(name: "duration", value: String(Int(refDuration * 1000))),
        ]
        struct SearchReply: Decodable {
            struct Candidate: Decodable {
                let id: String
                let accesskey: String
                let duration: Int?
                let songname: String?
                let singername: String?
                let filename: String?
                let isrc: String?
            }
            let candidates: [Candidate]
        }
        guard let searchURL = search.url,
              let (data, _) = try? await session.data(from: searchURL),
              let reply = try? JSONDecoder().decode(SearchReply.self, from: data),
              !reply.candidates.isEmpty else { return nil }
        let matches = reply.candidates.map { hit -> MatchCandidate in
            // `filename` is the catalogue's own "singer - song" pairing, the
            // fallback when the named fields are absent.
            var name = hit.songname ?? "", singer = hit.singername ?? ""
            if name.isEmpty, let file = hit.filename, !file.isEmpty {
                let parts = file.split(separator: "-", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                if parts.count == 2 {
                    if singer.isEmpty { singer = parts[0] }
                    name = parts[1]
                } else {
                    name = file
                }
            }
            // Kugou reports candidate duration in milliseconds.
            let duration = hit.duration.map { TimeInterval($0) / 1000 }
            return MatchCandidate(title: name, artist: singer, duration: duration, isrc: hit.isrc)
        }
        guard let index = Self.pickMatch(
            title: title, artist: artist, isrc: isrc,
            refDuration: refDuration, candidates: matches
        ) else { return nil }
        let match = reply.candidates[index]

        var download = URLComponents(string: "https://lyrics.kugou.com/download")!
        download.queryItems = [
            URLQueryItem(name: "ver", value: "1"),
            URLQueryItem(name: "client", value: "pc"),
            URLQueryItem(name: "id", value: match.id),
            URLQueryItem(name: "accesskey", value: match.accesskey),
            URLQueryItem(name: "fmt", value: "krc"),
            URLQueryItem(name: "charset", value: "utf8"),
        ]
        struct DownloadReply: Decodable { let content: String? }
        guard let downloadURL = download.url,
              let (body, _) = try? await session.data(from: downloadURL),
              let payload = try? JSONDecoder().decode(DownloadReply.self, from: body),
              let base64 = payload.content,
              let encrypted = Data(base64Encoded: base64),
              let decrypted = WordSyncedLyrics.decryptKRC(encrypted) else { return nil }
        let parsed = WordSyncedLyrics.parseKRCBody(decrypted)
        guard !parsed.isEmpty else { return nil }
        return parsed.map { Line(at: $0.at, text: $0.text, words: $0.words) }
    }

    private func fetchLRCLIB(
        key: String, cacheKey: String,
        title: String, artist: String, album: String, duration: TimeInterval
    ) async {
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "album_name", value: album),
            URLQueryItem(name: "duration", value: String(Int(duration.rounded()))),
        ]
        var request = URLRequest(url: components.url!)
        // LRCLIB asks its clients to identify themselves.
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        request.setValue(
            "\(ProductIdentity.executableName)/\(version) (\(ProductIdentity.bundleIdentifier))",
            forHTTPHeaderField: "User-Agent"
        )

        struct Payload: Decodable {
            let syncedLyrics: String?
            let duration: TimeInterval?
        }

        var lines: [Line] = []
        // Whether the service actually answered "no lyrics", as opposed to
        // failing to answer. Only a real answer is worth remembering.
        var serviceAnswered = false
        do {
            let (data, response) = try await session.data(for: request)
            guard !Task.isCancelled, loadedKey == key else { return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // 404 is an answer: this track is not in the catalogue. 429 and the
            // 5xx family are the service being unable to answer, and caching
            // those as "no lyrics" pinned every track played during an outage
            // to silence, permanently and with no way back short of deleting
            // cache files by hand.
            serviceAnswered = status == 200 || status == 404
            if status == 200,
               let payload = try? JSONDecoder().decode(Payload.self, from: data),
               let synced = payload.syncedLyrics {
                lines = Self.parseLRC(synced)
            }

            // The exact-match endpoint wants the album name the catalogue has,
            // and players routinely report a different one — a single's title
            // where the catalogue filed the album, or the other way round. One
            // search by title and artist rescues those, gated on duration so a
            // cover or a remix with the same name cannot masquerade: same
            // recording, same length.
            if lines.isEmpty {
                var search = URLComponents(string: "https://lrclib.net/api/search")!
                search.queryItems = [
                    URLQueryItem(name: "track_name", value: title),
                    URLQueryItem(name: "artist_name", value: artist),
                ]
                var searchRequest = URLRequest(url: search.url!)
                searchRequest.setValue(request.value(forHTTPHeaderField: "User-Agent"), forHTTPHeaderField: "User-Agent")
                let (results, _) = try await session.data(for: searchRequest)
                guard !Task.isCancelled, loadedKey == key else { return }
                if let candidates = try? JSONDecoder().decode([Payload].self, from: results) {
                    let match = candidates.first {
                        guard let synced = $0.syncedLyrics, !synced.isEmpty,
                              let candidateDuration = $0.duration else { return false }
                        return abs(candidateDuration - duration) <= 3
                    }
                    if let synced = match?.syncedLyrics {
                        lines = Self.parseLRC(synced)
                    }
                }
            }

            // A miss is an answer too, and caching it is what keeps a track
            // with no lyrics from being asked about on every replay — but only
            // when the service was in a position to answer.
            lines = Self.cleaned(lines, title: title, artist: artist)
            if !lines.isEmpty || serviceAnswered {
                // A miss is cached too, and the miss entry carries the same
                // layers a hit would: the next replay restores them as one.
                loadedSource = .lrclib
                let offset = trackOffsets[cacheKey] ?? 0
                trackOffset = offset
                writeCache(cacheKey, lines: lines, source: .lrclib, trackOffset: offset)
            }
        } catch {
            guard !Task.isCancelled, loadedKey == key else { return }
            // Offline or refused: say nothing rather than something wrong, and
            // leave the cache alone so the next launch can try again. Words
            // already on screen for this track survive — a failed lookup knows
            // less than the one that succeeded, not more.
            settle([])
            return
        }
        settle(lines)
    }

    // MARK: - LRC

    /// `[mm:ss.xx] text`, tolerating several timestamps per line and the
    /// `[offset:±ms]` tag some files carry.
    static func parseLRC(_ raw: String) -> [Line] {
        var offset: TimeInterval = 0
        var lines: [Line] = []

        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            if let range = line.range(of: #"^\[offset:\s*([+-]?\d+)\]"#, options: .regularExpression) {
                let value = line[range].dropFirst("[offset:".count).dropLast()
                offset = (TimeInterval(value.trimmingCharacters(in: .whitespaces)) ?? 0) / 1000
                continue
            }

            var times: [TimeInterval] = []
            var rest = Substring(line)
            while let match = rest.range(of: #"^\[(\d+):(\d{1,2}(?:\.\d{1,3})?)\]"#, options: .regularExpression) {
                let stamp = rest[match].dropFirst().dropLast()
                let parts = stamp.split(separator: ":")
                if parts.count == 2,
                   let minutes = TimeInterval(parts[0]),
                   let seconds = TimeInterval(parts[1]) {
                    times.append(minutes * 60 + seconds)
                }
                rest = rest[match.upperBound...]
            }
            guard !times.isEmpty else { continue }

            let text = rest.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            for time in times {
                // The offset tag shifts the whole file; clamped so a broken
                // one can never push a line before the track starts.
                lines.append(Line(at: max(0, time - offset), text: text))
            }
        }
        return lines.sorted { $0.at < $1.at }
    }

    // MARK: - Disk cache

    static func cacheKey(title: String, artist: String, album: String, duration: TimeInterval) -> String {
        let identity = "\(title)|\(artist)|\(album)|\(Int(duration.rounded()))"
        // A filename, so it has to survive slashes and unicode: FNV-1a is
        // plenty for a cache that only ever collides with itself.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in identity.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    private func cacheURL(_ key: String) -> URL {
        // v4: every entry carries its source tier. v3 files would decode
        // without one and pin a track to an untagged answer, so like the
        // v1→v2 bump they are simply ignored, and pruned below.
        cacheDirectory.appendingPathComponent("\(key).lrc4.json")
    }

    private struct CachedLyrics: Codable {
        let times: [TimeInterval]
        let texts: [String]
        var wordTimes: [[TimeInterval]]? = nil
        var wordTexts: [[String]]? = nil
        /// Word end times, -1 standing for "the source did not know". Optional
        /// so files written before ends were kept still decode; their words
        /// fall back to next-start exactly as they always did.
        var wordEnds: [[TimeInterval]]? = nil
        /// Which lines are credits. Optional so files written before credits
        /// were kept still decode — theirs simply had them dropped.
        var credits: [Bool]? = nil
        /// Which tier answered: amll, qq, kugou or lrclib. Optional so
        /// untagged files still decode; only the suffix decides what is read.
        var source: String? = nil
        /// This track's timing correction, in seconds. Optional so entries
        /// written before the track layer existed still decode — theirs reads 0.
        var trackOffset: TimeInterval? = nil
    }

    /// How many cached tracks to keep. The cache is one small file per track
    /// ever played, misses included, and nothing used to remove any of it: a
    /// heavy listener accumulated files forever with no setting, no expiry,
    /// and no way to clear them short of finding the folder.
    static let cacheLimit = 500

    /// Read by the sync probe for its word-tier fixture as well as by `load`,
    /// so it is internal rather than private. Pure disk + decode, no state.
    nonisolated static func readCache(at url: URL) -> [Line]? {
        readCacheEntry(at: url)?.lines
    }

    /// The full v4 entry: the words, which tier wrote them, and this track's
    /// timing correction. `load` restores all three together so a nudge
    /// replays with the entry it was measured against, never another track's.
    nonisolated static func readCacheEntry(
        at url: URL
    ) -> (lines: [Line], source: LyricSource?, trackOffset: TimeInterval)? {
        guard let data = try? Data(contentsOf: url),
              let cached = try? JSONDecoder().decode(CachedLyrics.self, from: data),
              cached.times.count == cached.texts.count else { return nil }
        let lines: [Line] = cached.times.indices.map { index in
            var words: [WordSyncedLyrics.Word] = []
            if let wt = cached.wordTimes, let wx = cached.wordTexts,
               index < wt.count, index < wx.count, wt[index].count == wx[index].count {
                let ends = cached.wordEnds.flatMap { index < $0.count ? $0[index] : nil }
                words = zip(wt[index], wx[index]).enumerated().map { wordIndex, pair in
                    let end = ends.flatMap { wordIndex < $0.count && $0[wordIndex] >= 0 ? $0[wordIndex] : nil }
                    return WordSyncedLyrics.Word(at: pair.0, text: pair.1, end: end)
                }
            }
            let isCredit = cached.credits.map { index < $0.count && $0[index] } ?? false
            return Line(at: cached.times[index], text: cached.texts[index], words: words, isCredit: isCredit)
        }
        let source = cached.source.flatMap(LyricSource.init(rawValue:))
        return (lines, source, cached.trackOffset ?? 0)
    }

    /// Encodes and writes off the main thread.
    ///
    /// A word-synced track carries a timing per word, and encoding plus an
    /// atomic write of that used to happen on the main actor during the exact
    /// frame the lyric crossfade was animating.
    private func writeCache(_ key: String, lines: [Line], source: LyricSource, trackOffset: TimeInterval) {
        let cached = CachedLyrics(
            times: lines.map(\.at),
            texts: lines.map(\.text),
            wordTimes: lines.map { $0.words.map(\.at) },
            wordTexts: lines.map { $0.words.map(\.text) },
            wordEnds: lines.map { $0.words.map { $0.end ?? -1 } },
            credits: lines.map(\.isCredit),
            source: source.rawValue,
            trackOffset: trackOffset
        )
        let url = cacheURL(key)
        let directory = cacheDirectory
        let limit = Self.cacheLimit
        Self.cacheIO.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let data = try? JSONEncoder().encode(cached) else { return }
            try? data.write(to: url, options: .atomic)
            Self.pruneCache(directory: directory, limit: limit)
        }
    }

    /// Drops the least recently used entries once the cache exceeds its limit,
    /// and clears out abandoned v3 files while it is there — the format bump
    /// left those unreadable but on disk forever.
    private nonisolated static func pruneCache(directory: URL, limit: Int) {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in urls where url.pathExtension == "json" && !url.lastPathComponent.hasSuffix(".lrc4.json") {
            try? fm.removeItem(at: url)
        }
        let current = urls.filter { $0.lastPathComponent.hasSuffix(".lrc4.json") }
        guard current.count > limit else { return }
        let dated = current.map { url -> (URL, Date) in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return (url, date)
        }
        .sorted { $0.1 < $1.1 }
        for (url, _) in dated.prefix(current.count - limit) {
            try? fm.removeItem(at: url)
        }
    }

    /// Everything the lyric cache has put on disk. Offered in Settings, so the
    /// cache is something the user can see the size of and empty.
    func clearCache() {
        let directory = cacheDirectory
        Self.cacheIO.async {
            let fm = FileManager.default
            guard let urls = try? fm.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { return }
            for url in urls { try? fm.removeItem(at: url) }
        }
    }
}
