import Foundation

/// Lyrics from LRCLIB, for the tracks no file on this Mac describes.
///
/// The offline design approved on 2026-09-13 ruled this out, and the amendment
/// of 2026-09-21 admits it for one reason the original could not answer: a
/// streamed track has no file, so no offline path can ever produce words for
/// it. That design's real commitments are kept rather than relaxed —
///
/// * **It is off until asked for.** `NotchViewModel.onlineLyricsEnabled`
///   defaults to false and has its own switch, separate from Show Lyrics.
/// * **A file you chose always wins.** This is consulted only when the local
///   library reports no match at all; an ambiguous local result still asks you
///   to pick, and never silently reaches the network instead.
/// * **Word timing is still never invented.** LRCLIB carries line-level LRC,
///   so a timeline from here is `.line` and the karaoke sweep stays off for it.
///   Only an enhanced LRC you import animates word by word.
/// * **Isla operates no service and holds no credential.** LRCLIB is a public,
///   free, community-contributed endpoint that needs no key and no account.
///
/// What leaves the Mac is the track's title, artist, album and duration — the
/// four fields needed to identify a recording — and nothing about the listener.
/// There is no analytics call, no contribution upload, and no identifier.
enum OnlineLyrics {
    /// LRCLIB asks clients to identify themselves so it can tell traffic apart.
    static let userAgent = "Isla/\(ProductIdentity.version) (\(ProductIdentity.homepage))"
    static let endpoint = "https://lrclib.net/api/get"
    static let searchEndpoint = "https://lrclib.net/api/search"

    /// What the endpoint answers with. Only the fields Isla reads are decoded;
    /// LRCLIB is free to add others.
    struct Response: Decodable, Equatable, Sendable {
        var syncedLyrics: String?
        var instrumental: Bool?
        var duration: Double?
    }

    enum Outcome: Equatable, Sendable {
        /// Words, timed, ready to show.
        case found(LyricTimeline)
        /// The endpoint answered and this recording has no timed words —
        /// it is instrumental, unknown, or carries only an untimed sheet.
        case none
        /// The network or the service failed. Distinct from `none` so a retry
        /// is worth offering and a miss is not cached as final.
        case failed
        /// The endpoint has timed words for this recording and the parser
        /// refused them. Shown as a miss, but remembered under the parser
        /// revision that refused it, so a release that reads more asks again.
        ///
        /// It used to be `none`, and `none` is believed for two weeks: one
        /// '<3' or one `[by:]` in LRCLIB's text, and the song said "No lyrics
        /// found" for 14 days — through the very update that learned to read
        /// it.
        case unreadable
        /// The service said too many requests (429), possibly with the time to
        /// come back at, in seconds. Nothing about the recording is known, so
        /// it is never cached, and it is no reason to retry this song: the
        /// refusal is about this address, and the coordinator pauses every
        /// lookup for it (`OnlineLyricsPause`).
        case limited(retryAfter: TimeInterval?)
    }

    /// The longest a Retry-After is believed. A header that says a week would
    /// otherwise silence lyrics for a week on one misconfigured gateway.
    static let longestRetryAfter: TimeInterval = 86_400

    /// The longest 503 Retry-After worth sitting out inside a lookup. LRCLIB's
    /// own server answers overload with 503 and `Retry-After: 1`, and a wait
    /// that short is the difference between a busy second and a missing song.
    /// Anything longer is somebody staring at "Finding lyrics…" for nothing.
    static let longestWorthWaiting: TimeInterval = 5

    /// The seconds a Retry-After header asks for, or nil when it is absent or
    /// unreadable (RFC 9110 section 10.2.3: delay-seconds, or an HTTP-date).
    ///
    /// A date is measured against the response's own `Date` header when that
    /// parses, because the server's clock and this Mac's may be minutes
    /// apart and the server's date is the one the sender meant it against;
    /// only without one does `now` stand in. A date already past is no wait,
    /// and nothing is believed past `longestRetryAfter`.
    static func retryAfter(from response: HTTPURLResponse, now: Date) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty
        else { return nil }
        func clamped(_ seconds: TimeInterval) -> TimeInterval {
            min(max(seconds, 0), longestRetryAfter)
        }
        // Digits only: delay-seconds is a non-negative integer, so "-5", "+5"
        // and "1.5" are not a delay and are read as no header at all.
        if raw.allSatisfy({ $0.isASCII && $0.isNumber }) {
            // A Double so a string of forty digits clamps instead of failing
            // to fit an Int and being read as no header at all.
            return Double(raw).map(clamped)
        }
        guard let when = httpDate(raw) else { return nil }
        let from = response.value(forHTTPHeaderField: "Date").flatMap(httpDate) ?? now
        return clamped(when.timeIntervalSince(from))
    }

    /// An HTTP-date in any of the three forms RFC 9110 section 5.6.7 names:
    /// IMF-fixdate, and the two obsolete forms a recipient MUST still accept,
    /// rfc850 ("Sunday, 06-Nov-94 08:49:37 GMT") and asctime ("Sun Nov  6
    /// 08:49:37 1994", which pads a one-digit day with a second space — runs
    /// of spaces are collapsed before parsing). All are GMT.
    private static func httpDate(_ text: String) -> Date? {
        let normalised = text.split(separator: " ").joined(separator: " ")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        for format in [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEEE, dd-MMM-yy HH:mm:ss zzz",
            "EEE MMM d HH:mm:ss yyyy",
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: normalised) { return date }
        }
        return nil
    }

    /// The exact-match query. Duration is included on purpose: it is what keeps
    /// a single from matching its own ten-minute live version, which the
    /// offline design named as a thing never to get wrong.
    static func request(for identity: LocalTrackIdentity) -> URLRequest? {
        // The endpoint matches on the pair. A bare title would match some other
        // recording entirely, so a track that cannot be identified is not asked
        // about at all — the guard lives here so every caller inherits it.
        guard !identity.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !identity.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              var components = URLComponents(string: endpoint)
        else { return nil }
        var items = [
            URLQueryItem(name: "track_name", value: identity.title),
            URLQueryItem(name: "artist_name", value: identity.artist),
        ]
        if !identity.album.isEmpty {
            items.append(URLQueryItem(name: "album_name", value: identity.album))
        }
        if identity.duration > 0 {
            items.append(URLQueryItem(
                name: "duration", value: String(Int(identity.duration.rounded()))
            ))
        }
        components.queryItems = items
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        // Short, because this runs while somebody is looking at "Finding
        // lyrics…". A slow answer is worth less than a quick "not found".
        request.timeoutInterval = 8
        return request
    }

    /// Turns an answer into a timeline, or says why there is none.
    ///
    /// Only `syncedLyrics` is used. A plain sheet has no timestamps, and this
    /// app's whole standard is that a lyric on screen is where the voice
    /// actually is — showing an untimed wall of text on a stage that scrolls
    /// with the song would be inventing exactly what the design forbids.
    ///
    /// `duration` is the length of the recording playing, and lines stamped
    /// past it are dropped: the clock stops at the end of the track, so they
    /// can never light, and a stage that lists them shows words the song
    /// playing does not have. Zero means unknown and keeps every line.
    static func timeline(from data: Data, status: Int, duration: TimeInterval = 0) -> Outcome {
        read(data, status: status, duration: duration).outcome
    }

    /// `timeline(from:status:duration:)`, and whether the words fitted the
    /// track before any were dropped — which `lookUp` needs, to decide
    /// whether a better-fitting row is worth searching for.
    private static func read(
        _ data: Data, status: Int, duration: TimeInterval
    ) -> (outcome: Outcome, fits: Bool) {
        // 404 is the service's honest "no such recording"; anything else that
        // is not a success is a failure to retry, not an answer.
        if status == 404 { return (.none, false) }
        guard (200..<300).contains(status) else { return (.failed, false) }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            return (.failed, false)
        }
        if response.instrumental == true { return (.none, false) }
        guard let synced = response.syncedLyrics,
              !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return (.none, false) }
        guard let document = try? LocalLyricsDocument.parse(synced) else { return (.unreadable, false) }
        let timeline = document.timeline(documentID: nil)
        // Nothing reachable at all is nothing timed to this cut.
        guard let kept = reachable(timeline, duration: duration) else { return (.none, false) }
        return (.found(kept), fits(timeline, duration: duration))
    }

    /// Whether a timeline was written for a recording of this length: its last
    /// sung stamp no later than the end, give or take `durationTolerance`.
    ///
    /// The lyric lab (2026-10-11) found 1,249 lines in 69 of 540 LRCLIB
    /// answers stamped past their own record's length, 1,207 of which never
    /// showed. Both the exact query and the search compared lengths and
    /// never the stamps, so a row timed to an extended cut was taken as long
    /// as its listed length agreed. Lines carry no empty rows since revision
    /// 3 of the parser (an empty stamp is a line end), so the last line is the
    /// last sung one.
    static func fits(_ timeline: LyricTimeline, duration: TimeInterval) -> Bool {
        guard let past = Self.overrun(of: timeline, duration: duration) else { return true }
        return past <= durationTolerance
    }

    /// How far the last sung stamp runs past the end of a track this long, or
    /// nil when the length is unknown (zero, negative or not finite) or there
    /// is no line. Negative when the words end before the track does.
    ///
    /// The one measurement of "timed for a longer version": `fits` is
    /// `overrun <= durationTolerance`, the ranking compares it, and the
    /// timeline carries it to the stage (`LyricTimeline.overrun`). It is read
    /// off the whole answer, before `reachable` drops the lines past the end.
    static func overrun(of timeline: LyricTimeline, duration: TimeInterval) -> TimeInterval? {
        guard duration > 0, duration.isFinite, let last = timeline.lines.map(\.at).max() else { return nil }
        return last - duration
    }

    /// The lines the clock can reach on a track this long, or nil when none
    /// can. A timeline that does not fit is still kept rather than refused —
    /// refusing would have turned about one track in eight into a miss with
    /// no better row to offer — but without the lines that could never show.
    ///
    /// The timeline that comes back carries its `overrun`, measured before
    /// the drop.
    private static func reachable(_ timeline: LyricTimeline, duration: TimeInterval) -> LyricTimeline? {
        guard duration > 0, duration.isFinite else { return timeline }
        let overrun = Self.overrun(of: timeline, duration: duration)
        let kept = timeline.lines.filter { $0.at <= duration }
        guard !kept.isEmpty else { return nil }
        return LyricTimeline(
            lines: kept, granularity: timeline.granularity, documentID: timeline.documentID,
            overrun: overrun
        )
    }

    /// The whole round trip. The transport is a parameter so the tests never
    /// touch the network — and so a test can prove the request is shaped right
    /// without one.
    ///
    /// The exact query first, then a search. The exact query matches title,
    /// artist, album and duration together, and a streaming service's
    /// metadata rarely agrees with the catalogue on all four: checked against
    /// LRCLIB on 2026-09-21, "waltz", "We Say Goodbye" and "Spit" all have
    /// timed lyrics there, filed under albums Spotify does not name, and each
    /// came back "No lyrics found". The search matches on title and main
    /// artist, and holds the duration to three seconds so a live version or a
    /// different edit is never taken for the recording playing.
    ///
    /// An exact answer whose words run past the end of the track is the
    /// wrong cut's timing under the right recording's name, so it is not
    /// final either: the search is asked for a row that fits. If none does,
    /// the exact answer is kept, with only the lines the clock can reach —
    /// a found lyric is never turned into a miss by being checked harder.
    ///
    /// Two rules about a service that is struggling, both from the 2026-10-15
    /// ban: a 429 stops the lookup where it stands, because the search would
    /// ask the same gateway a second later, and any 5xx ends the search loop,
    /// because the next query meets the same overloaded server. A 503 with a
    /// Retry-After of `longestWorthWaiting` or less is the one exception,
    /// asked once more (`send`).
    static func lookUp(
        _ identity: LocalTrackIdentity,
        transport: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            try await PrivateNetwork.session.data(for: request)
        },
        sleep: @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(for: .seconds(seconds))
        },
        now: @Sendable () -> Date = { Date() }
    ) async -> Outcome {
        guard let request = request(for: identity) else { return .none }
        // The best answer that overran the track, held in case nothing fits
        // better: the one that overruns least, the exact query's winning a tie.
        var overrunning: LyricTimeline?
        var unreadable = false
        do {
            let sent = try await send(request, transport: transport, sleep: sleep, now: now)
            if sent.status == 429 { return .limited(retryAfter: sent.retryAfter) }
            let status = sent.status
            let data = sent.data
            // An instrumental is an answer, and the search would only find the
            // same record again.
            if (200..<300).contains(status),
               (try? JSONDecoder().decode(Response.self, from: data))?.instrumental == true {
                return .none
            }
            let exact = read(data, status: status, duration: identity.duration)
            switch exact.outcome {
            case .found(let timeline):
                if exact.fits { return .found(timeline) }
                overrunning = timeline
            case .failed, .limited: return .failed
            case .unreadable: unreadable = true
            case .none: break
            }
        } catch {
            return .failed
        }

        var searchFailed = false
        for query in searchQueries(for: identity) {
            guard let search = searchRequest(title: query.title, artist: query.artist) else { continue }
            do {
                let sent = try await send(search, transport: transport, sleep: sleep, now: now)
                if sent.status == 429 {
                    // An answer already in hand is not thrown away for a
                    // refusal: a found lyric is never turned into a miss. The
                    // pause is not armed from here, then — the next song's
                    // first request meets the same 429 and arms it, and that
                    // one request is the cost of keeping the words. It also
                    // answered, so the pause's streak is not wiped by it
                    // (`OnlineLyricsPause.answered(at:)`): the next 429
                    // continues the streak instead of starting over.
                    if let overrunning { return .found(overrunning) }
                    return .limited(retryAfter: sent.retryAfter)
                }
                if (500..<600).contains(sent.status) {
                    // The next query would meet the same overloaded server.
                    if let overrunning { return .found(overrunning) }
                    return .failed
                }
                guard (200..<300).contains(sent.status),
                      let rows = try? JSONDecoder().decode([SearchRow].self, from: sent.data) else {
                    searchFailed = true
                    continue
                }
                let candidate = bestCandidate(in: rows, for: identity)
                if candidate.sawUnreadable { unreadable = true }
                if let match = candidate.match {
                    if match.fits { return .found(match.timeline) }
                    if overruns(match.timeline, lessThan: overrunning) { overrunning = match.timeline }
                }
            } catch {
                searchFailed = true
            }
        }
        if let overrunning { return .found(overrunning) }
        // A search that could not be asked says nothing about the catalogue,
        // so it is a failure to retry, not a miss to remember. Words the
        // parser refused are not a miss either: they are asked again once
        // the parser improves.
        if searchFailed { return .failed }
        return unreadable ? .unreadable : .none
    }

    /// One request, and one more if the server only asked for a moment.
    ///
    /// LRCLIB's own server answers overload with 503 and `Retry-After: 1`, so
    /// a 503 whose Retry-After is `longestWorthWaiting` seconds or less is
    /// waited out and the same request sent exactly once more. A second 503,
    /// a longer wait, or none named is the caller's failure to read. A lookup
    /// cancelled during the wait — a skip — does not send the second request.
    private static func send(
        _ request: URLRequest,
        transport: @Sendable (URLRequest) async throws -> (Data, URLResponse),
        sleep: @Sendable (TimeInterval) async -> Void,
        now: @Sendable () -> Date
    ) async throws -> (data: Data, status: Int, retryAfter: TimeInterval?) {
        var retried = false
        while true {
            let (data, response) = try await transport(request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            let named = http.flatMap { Self.retryAfter(from: $0, now: now()) }
            guard status == 503, !retried, let wait = named, wait <= longestWorthWaiting else {
                return (data, status, named)
            }
            retried = true
            await sleep(wait)
            if Task.isCancelled { return (data, status, named) }
        }
    }

    /// Whether `candidate` runs less far past the track's end than `held`, or
    /// nothing is held. A tie keeps what is held, so the exact query's answer
    /// outranks a search row of the same overrun.
    private static func overruns(_ candidate: LyricTimeline, lessThan held: LyricTimeline?) -> Bool {
        guard let held else { return true }
        return (candidate.overrun ?? .infinity) < (held.overrun ?? .infinity)
    }

    // MARK: - Search

    /// One row of a search answer. Only what the match reads is decoded.
    struct SearchRow: Decodable, Equatable, Sendable {
        var trackName: String?
        var artistName: String?
        var duration: Double?
        var instrumental: Bool?
        var syncedLyrics: String?
    }

    /// How far a candidate's length may be from the recording playing. Wide
    /// enough for two services rounding the same file differently, narrow
    /// enough to refuse an edit or a live take.
    static let durationTolerance: TimeInterval = 3

    static func searchRequest(title: String, artist: String) -> URLRequest? {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              var components = URLComponents(string: searchEndpoint) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 8
        return request
    }

    /// The title and artist as the player names them, then — if different —
    /// the title without its edition and the artist without the company:
    /// "Child Psychology - 2023 Remaster" by "Black Box Recorder, Someone" is
    /// searched as "Child Psychology" by "Black Box Recorder" as well.
    static func searchQueries(for identity: LocalTrackIdentity) -> [(title: String, artist: String)] {
        let exact = (title: identity.title, artist: identity.artist)
        let bare = (title: baseTitle(identity.title), artist: primaryArtist(identity.artist))
        if bare.title.caseInsensitiveCompare(exact.title) == .orderedSame,
           bare.artist.caseInsensitiveCompare(exact.artist) == .orderedSame {
            return [exact]
        }
        return [exact, bare]
    }

    /// The timed candidate that is this recording, if one is: the same title
    /// once editions are set aside, the main artist among its artists, and the
    /// length within tolerance. A row whose words fit the track beats one
    /// whose words run past its end; among rows that run past it, the one
    /// that runs least wins; among equals the closest length wins.
    /// The timeline comes back without lines past the end of the track.
    static func bestMatch(in rows: [SearchRow], for identity: LocalTrackIdentity) -> LyricTimeline? {
        bestCandidate(in: rows, for: identity).match?.timeline
    }

    /// `bestMatch`, and what `lookUp` needs besides: whether the winner fits
    /// the track, and whether a row that matched was refused by the parser.
    static func bestCandidate(
        in rows: [SearchRow], for identity: LocalTrackIdentity
    ) -> (match: (timeline: LyricTimeline, fits: Bool)?, sawUnreadable: Bool) {
        let wantTitle = comparable(baseTitle(identity.title))
        let wantArtist = comparable(primaryArtist(identity.artist))
        guard !wantTitle.isEmpty, !wantArtist.isEmpty else { return (nil, false) }
        var best: (fits: Bool, overrun: TimeInterval, difference: TimeInterval, timeline: LyricTimeline)?
        var sawUnreadable = false
        for row in rows where row.instrumental != true {
            guard let synced = row.syncedLyrics,
                  !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let name = row.trackName, comparable(baseTitle(name)) == wantTitle,
                  let artist = row.artistName, comparable(artist).contains(wantArtist)
            else { continue }
            var difference: TimeInterval = 0
            if identity.duration > 0 {
                guard let length = row.duration,
                      abs(length - identity.duration) <= durationTolerance else { continue }
                difference = abs(length - identity.duration)
            }
            // Every matching row is read now, not only one that would win on
            // length: whether its words fit is in the words, and it ranks
            // ahead of length. A listed length within a second of the track's
            // said nothing about the 40 s of stamps after its end.
            guard let document = try? LocalLyricsDocument.parse(synced) else {
                sawUnreadable = true
                continue
            }
            let timeline = document.timeline(documentID: nil)
            let fits = fits(timeline, duration: identity.duration)
            let overrun = max(Self.overrun(of: timeline, duration: identity.duration) ?? 0, 0)
            // Fitting first. Among rows that all run past the end, the one
            // that runs least is the nearest to the recording playing: LRCLIB
            // copies one timeline onto many releases, so twenty rows listed
            // from 5 s to 312 s can carry identical stamps, and the listed
            // length ranks nothing. Only then the closest length.
            let better = best.map { held in
                if fits != held.fits { return fits }
                if !fits, overrun != held.overrun { return overrun < held.overrun }
                return difference < held.difference
            } ?? true
            guard better, let kept = reachable(timeline, duration: identity.duration) else { continue }
            best = (fits, overrun, difference, kept)
        }
        return (best.map { ($0.timeline, $0.fits) }, sawUnreadable)
    }

    /// A bracketed edition in any of the brackets titles arrive in: ASCII,
    /// and the full-width and CJK pairs a Japanese or Chinese catalogue uses
    /// — "Title（Remastered）" never matched its own LRCLIB row. Each pair
    /// closes with its own partner.
    private static let bracketedEdition =
        #"\s*(?:\([^)]*\)|\[[^\]]*\]|（[^）]*）|［[^］]*］|【[^】]*】|「[^」]*」|『[^』]*』|〔[^〕]*〕)"#

    /// A title without the edition a service appends to it: a bracketed
    /// "(feat. …)" or "[Live]", and a trailing " - 2011 Remaster",
    /// " - Demo - September 1996", " - Radio Edit".
    ///
    /// A title that is nothing but brackets is the title: "(Nice Dream)"
    /// stripped to nothing, and `bestMatch` gives up on an empty title before
    /// it reads a single row, so that song could never be found by search.
    static func baseTitle(_ title: String) -> String {
        var text = title
        while let range = text.range(of: bracketedEdition, options: .regularExpression) {
            text.removeSubrange(range)
        }
        let bare = withoutTrailingEdition(text)
        if !bare.isEmpty { return bare }
        let kept = withoutTrailingEdition(title)
        return kept.isEmpty ? title.trimmingCharacters(in: .whitespacesAndNewlines) : kept
    }

    /// The " - 2011 Remaster" half of `baseTitle`.
    private static func withoutTrailingEdition(_ title: String) -> String {
        var text = title
        let editions = [
            "remaster", "live", "demo", "version", "edit", "mix", "mono", "stereo",
            "acoustic", "radio", "single", "deluxe", "bonus", "session", "take",
            "recorded", "anniversary", "explicit", "clean", "instrumental",
        ]
        if let dash = text.range(of: " - ") {
            let tail = text[dash.upperBound...].lowercased()
            if editions.contains(where: { tail.contains($0) }) {
                text = String(text[..<dash.lowerBound])
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The first-named artist: before a comma, an ampersand, or a "feat.".
    static func primaryArtist(_ artist: String) -> String {
        var text = artist
        for separator in [",", " & ", " feat. ", " feat ", " ft. ", " featuring ", " x ", " and "] {
            if let range = text.range(of: separator, options: .caseInsensitive) {
                text = String(text[..<range.lowerBound])
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Case, accents and punctuation set aside, so "Don’t" and "Dont" agree.
    static func comparable(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            // An apostrophe joins a word rather than ending one: "Don’t" is
            // "dont", not "don t".
            .replacingOccurrences(of: #"['’‘`´ʼ]"#, with: "", options: .regularExpression)
        let kept = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }
}

/// What has already been asked, so a track is fetched once.
///
/// Both answers are kept. A hit spares the network on every replay; a miss
/// spares it too, which matters more — a library full of tracks LRCLIB does not
/// have would otherwise ask again on every single play. A failure is never
/// cached, because the next attempt may well work. Words the parser refused
/// are kept as a miss tied to the parser's revision, so the next play does not
/// ask again but the next parser does.
@MainActor
final class OnlineLyricsCache {
    private struct Entry: Codable {
        var lines: [LyricsStore.Line]?
        var checkedAt: Date
        /// Whether the miss was the search's too. A miss remembered from the
        /// exact query alone, before the search existed, is asked again —
        /// otherwise the songs it would now find stayed "No lyrics found" for
        /// the rest of the miss's two-week life.
        var searched: Bool?
        /// For a hit, the cache format it was last asked under; nil is
        /// format 1. See `OnlineLyricsCache.format`.
        var format: Int?
        /// For an unreadable answer, the parser revision that refused it. Nil
        /// for an ordinary miss, which is a fact about the catalogue and not
        /// about the parser.
        var parserRevision: Int?
        /// For a hit, how far its last stamp ran past the track's end
        /// (`LyricTimeline.overrun`). The cached lines are the reachable ones,
        /// so it cannot be recomputed from them. Nil for a hit cached before
        /// it was kept, which format 3 asks about once more.
        var overrun: Double?
    }

    /// What a hit written now carries. Format 2 hits keep their line ends
    /// (`LyricsStore.Line.end`, 2026-10-11); a format 1 hit was cached before
    /// ends existed, so its lines stay lit to the next stamp — through every
    /// instrumental, a median 28.9 s a track in the lyric lab.
    ///
    /// Such a hit is still shown at once, because dropping it would leave the
    /// stage blank until the network answered, and is asked about once more
    /// in the background (`needsRefresh`). Only a found answer replaces it.
    /// Anything else leaves the old words up and stamps the hit with this
    /// format, so the refresh costs one request per song and not one per play.
    ///
    /// Format 3 (2026-10-11, ly/VERSION-01) keeps each hit's `overrun`. A
    /// format 2 hit has none, so a song already cached as timed for a longer
    /// cut would never be flagged nor re-ranked; it is asked about once, in
    /// the background, like a format 1 hit.
    static let format = 3

    private let directory: URL?
    private let capacity: Int
    /// The parser revision this cache reads with. A parameter only so a test
    /// can stand in for the next release; the app uses the parser's own.
    private let parserRevision: Int
    private var entries: [String: Entry] = [:]
    private var flush: Task<Void, Never>?

    /// How long a "LRCLIB does not have this" is believed. The catalogue is
    /// community-contributed and grows, so a miss is a fact with a shelf life.
    static let missLifetime: TimeInterval = 60 * 60 * 24 * 14

    /// Answers kept, newest by when they were checked. A hit carries the song's
    /// whole timeline, and nothing used to leave: every song ever looked up
    /// stayed in memory and in the file for the life of the install. A song
    /// pushed out is only asked again the next time it plays.
    nonisolated static let defaultCapacity = 1000

    init(
        directory: URL? = AppPaths.live.supportFile("lyrics-online"),
        capacity: Int = OnlineLyricsCache.defaultCapacity,
        parserRevision: Int = LocalLyricsDocument.parserRevision
    ) {
        self.directory = directory
        self.capacity = capacity
        self.parserRevision = parserRevision
        load()
    }

    /// Keyed by the recording, not by the player: the same song from Music and
    /// from Spotify is one lookup.
    static func key(_ identity: LocalTrackIdentity) -> String {
        [identity.title, identity.artist, identity.album, String(Int(identity.duration.rounded()))]
            .map { $0.lowercased() }
            .joined(separator: "\u{1F}")
    }

    /// `.some(.some(timeline))` is a remembered hit, `.some(.none)` a
    /// remembered miss still inside its lifetime, and `nil` means ask.
    func cached(_ identity: LocalTrackIdentity) -> LyricTimeline?? {
        guard let entry = entries[Self.key(identity)] else { return nil }
        if let lines = entry.lines {
            return .some(LyricTimeline(lines: lines, granularity: .line, documentID: nil, overrun: entry.overrun))
        }
        guard isBelieved(entry, now: Date()) else { return nil }
        return .some(nil)
    }

    /// Whether a remembered miss still stands: asked by the search too,
    /// inside its lifetime, and — for words the parser refused — refused by
    /// a parser no older than this one.
    ///
    /// A miss checked "in the future" is not believed. Its age is the clock
    /// now minus the stamp, and nothing refused a negative one, so a miss
    /// written while the clock ran a day fast stood for the fortnight plus
    /// the day (G-037). A negative age is a clock that was wrong, and asking
    /// once more costs one request.
    private func isBelieved(_ miss: Entry, now: Date) -> Bool {
        let age = now.timeIntervalSince(miss.checkedAt)
        guard miss.searched == true, age >= 0, age < Self.missLifetime else { return false }
        return miss.parserRevision.map { $0 >= parserRevision } ?? true
    }

    func remember(_ outcome: OnlineLyrics.Outcome, for identity: LocalTrackIdentity) {
        let key = Self.key(identity)
        switch outcome {
        case .found(let timeline):
            entries[key] = Entry(
                lines: timeline.lines, checkedAt: Date(), format: Self.format, overrun: timeline.overrun
            )
        case .none, .unreadable:
            // Only the background refresh of an old hit asks about a song
            // with a hit (Retry forgets first). Its "nothing better" keeps
            // the words on screen and settles the refresh.
            if var hit = entries[key], hit.lines != nil {
                hit.format = Self.format
                hit.checkedAt = Date()
                entries[key] = hit
            } else {
                entries[key] = Entry(
                    lines: nil, checkedAt: Date(), searched: true,
                    parserRevision: outcome == .unreadable ? parserRevision : nil
                )
            }
        case .failed, .limited:
            return
        }
        trim()
        save()
    }

    /// A remembered hit from before line ends existed, still to be asked
    /// about once. See `format`.
    func needsRefresh(_ identity: LocalTrackIdentity) -> Bool {
        guard let entry = entries[Self.key(identity)], entry.lines != nil else { return false }
        return (entry.format ?? 1) < Self.format
    }

    /// Forget one recording's answer, so Retry can really ask again.
    func forget(_ identity: LocalTrackIdentity) {
        entries.removeValue(forKey: Self.key(identity))
        save()
    }

    private var file: URL? { directory?.appendingPathComponent("cache.json") }

    /// Misses past their lifetime, misses from before the search existed, and
    /// refusals by an older parser are left behind: `cached` would ask again
    /// for any of them, so all they kept was their room.
    private func load() {
        guard let file, let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return }
        let now = Date()
        entries = decoded.filter { _, entry in
            entry.lines != nil || isBelieved(entry, now: now)
        }
        trim()
    }

    /// Down to capacity, the answers checked longest ago first.
    private func trim() {
        guard entries.count > capacity else { return }
        let oldest = entries
            .sorted { $0.value.checkedAt < $1.value.checkedAt }
            .prefix(entries.count - capacity)
        for (key, _) in oldest { entries.removeValue(forKey: key) }
    }

    /// Written off the main actor, and encoded there too.
    ///
    /// This used to encode and write synchronously on every answer. A run of
    /// fast skips is a run of answers, so it was a main-thread file write per
    /// skip — on the one thread the panel, the scrubber and the lyric sweep all
    /// draw from. Coalesced too: several answers inside a second cost one
    /// write, and the last one wins because each carries the whole dictionary.
    /// The encode stayed behind on the main actor, once per answer and over
    /// every song ever cached, until it moved into the write: what leaves here
    /// is a copy of the dictionary, which costs nothing until it is changed.
    private func save() {
        guard let file else { return }
        let snapshot = entries
        flush?.cancel()
        flush = Task { [file] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await Self.write(snapshot, to: file)
        }
    }

    private static func write(_ entries: [String: Entry], to file: URL) async {
        await Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(entries) else { return }
            try? FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? data.write(to: file, options: .atomic)
        }.value
    }

    /// Writes what is pending right now, for a test that must observe the file.
    func flushForTests() async {
        flush?.cancel()
        guard let file else { return }
        await Self.write(entries, to: file)
    }
}
