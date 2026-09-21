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
        var plainLyrics: String?
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
    static func timeline(from data: Data, status: Int) -> Outcome {
        // 404 is the service's honest "no such recording"; anything else that
        // is not a success is a failure to retry, not an answer.
        if status == 404 { return .none }
        guard (200..<300).contains(status) else { return .failed }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            return .failed
        }
        if response.instrumental == true { return .none }
        guard let synced = response.syncedLyrics,
              !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let document = try? LocalLyricsDocument.parse(synced)
        else { return .none }
        return .found(document.timeline(documentID: nil))
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
    static func lookUp(
        _ identity: LocalTrackIdentity,
        transport: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            try await URLSession.shared.data(for: request)
        }
    ) async -> Outcome {
        guard let request = request(for: identity) else { return .none }
        let exact: Outcome
        do {
            let (data, response) = try await transport(request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // An instrumental is an answer, and the search would only find the
            // same record again.
            if (200..<300).contains(status),
               (try? JSONDecoder().decode(Response.self, from: data))?.instrumental == true {
                return .none
            }
            exact = timeline(from: data, status: status)
        } catch {
            return .failed
        }
        if case .found = exact { return exact }
        if exact == .failed { return .failed }

        var searchFailed = false
        for query in searchQueries(for: identity) {
            guard let search = searchRequest(title: query.title, artist: query.artist) else { continue }
            do {
                let (data, response) = try await transport(search)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(status),
                      let rows = try? JSONDecoder().decode([SearchRow].self, from: data) else {
                    searchFailed = true
                    continue
                }
                if let match = bestMatch(in: rows, for: identity) { return .found(match) }
            } catch {
                searchFailed = true
            }
        }
        // A search that could not be asked says nothing about the catalogue,
        // so it is a failure to retry, not a miss to remember.
        return searchFailed ? .failed : .none
    }

    // MARK: - Search

    /// One row of a search answer. Only what the match reads is decoded.
    struct SearchRow: Decodable, Equatable, Sendable {
        var trackName: String?
        var artistName: String?
        var albumName: String?
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
    /// length within tolerance — the closest length winning.
    static func bestMatch(in rows: [SearchRow], for identity: LocalTrackIdentity) -> LyricTimeline? {
        let wantTitle = comparable(baseTitle(identity.title))
        let wantArtist = comparable(primaryArtist(identity.artist))
        guard !wantTitle.isEmpty, !wantArtist.isEmpty else { return nil }
        var best: (difference: TimeInterval, timeline: LyricTimeline)?
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
            guard best.map({ difference < $0.difference }) ?? true,
                  let document = try? LocalLyricsDocument.parse(synced) else { continue }
            best = (difference, document.timeline(documentID: nil))
        }
        return best?.timeline
    }

    /// A title without the edition a service appends to it: a bracketed
    /// "(feat. …)" or "[Live]", and a trailing " - 2011 Remaster",
    /// " - Demo - September 1996", " - Radio Edit".
    static func baseTitle(_ title: String) -> String {
        var text = title
        while let range = text.range(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, options: .regularExpression) {
            text.removeSubrange(range)
        }
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
/// cached, because the next attempt may well work.
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
    }

    private let directory: URL?
    private var entries: [String: Entry] = [:]
    private var flush: Task<Void, Never>?

    /// How long a "LRCLIB does not have this" is believed. The catalogue is
    /// community-contributed and grows, so a miss is a fact with a shelf life.
    static let missLifetime: TimeInterval = 60 * 60 * 24 * 14

    init(directory: URL? = AppPaths.live.supportFile("lyrics-online")) {
        self.directory = directory
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
            return .some(LyricTimeline(lines: lines, granularity: .line, documentID: nil))
        }
        guard entry.searched == true,
              Date().timeIntervalSince(entry.checkedAt) < Self.missLifetime else { return nil }
        return .some(nil)
    }

    func remember(_ outcome: OnlineLyrics.Outcome, for identity: LocalTrackIdentity) {
        switch outcome {
        case .found(let timeline):
            entries[Self.key(identity)] = Entry(lines: timeline.lines, checkedAt: Date())
        case .none:
            entries[Self.key(identity)] = Entry(lines: nil, checkedAt: Date(), searched: true)
        case .failed:
            return
        }
        save()
    }

    /// Forget one recording's answer, so Retry can really ask again.
    func forget(_ identity: LocalTrackIdentity) {
        entries.removeValue(forKey: Self.key(identity))
        save()
    }

    func clear() {
        entries = [:]
        save()
    }

    var count: Int { entries.count }

    private var file: URL? { directory?.appendingPathComponent("cache.json") }

    private func load() {
        guard let file, let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return }
        entries = decoded
    }

    /// Encoded on the main actor, because that is where the dictionary lives,
    /// and written off it.
    ///
    /// This used to encode and write synchronously on every answer. A run of
    /// fast skips is a run of answers, so it was a main-thread file write per
    /// skip — on the one thread the panel, the scrubber and the lyric sweep all
    /// draw from. Coalesced too: several answers inside a second cost one
    /// write, and the last one wins because each carries the whole dictionary.
    private func save() {
        guard let file, let data = try? JSONEncoder().encode(entries) else { return }
        flush?.cancel()
        flush = Task { [file] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await Self.write(data, to: file)
        }
    }

    private static func write(_ data: Data, to file: URL) async {
        await Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? data.write(to: file, options: .atomic)
        }.value
    }

    /// Writes what is pending right now, for a test that must observe the file.
    func flushForTests() async {
        flush?.cancel()
        guard let file, let data = try? JSONEncoder().encode(entries) else { return }
        await Self.write(data, to: file)
    }
}
