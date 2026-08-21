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
        let at: TimeInterval
        let text: String
        /// Word starts within this line, when a word-synced source had them.
        var words: [WordSyncedLyrics.Word] = []

        init(at: TimeInterval, text: String, words: [WordSyncedLyrics.Word] = []) {
            self.at = at
            self.text = text
            self.words = words
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

    /// The listener's own correction to lyric timing, in seconds. Positive
    /// makes lines arrive later, negative earlier.
    ///
    /// However good the clock, some catalogue entries are simply timed against
    /// a different master of the song — a remaster shifted by half a second is
    /// common — and no amount of position accuracy can fix data that is offset
    /// at the source. Every serious karaoke surface ships this knob. Persisted
    /// globally: a per-track table would be more precise and much harder to
    /// discover, and the common case is "this whole catalogue runs a beat hot".
    @Published var userOffset: TimeInterval = UserDefaults.standard.double(forKey: LyricsStore.offsetKey) {
        didSet {
            let clamped = min(max(userOffset, -3), 3)
            if clamped != userOffset { userOffset = clamped; return }
            UserDefaults.standard.set(userOffset, forKey: Self.offsetKey)
        }
    }
    static let offsetKey = "lyrics.userOffset"

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
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("DynamicIslandLyrics", isDirectory: true)
    }

    /// Called with the displayed track. Same track twice is free.
    /// - Parameter spotifyID: the catalogue id when Spotify is the player —
    ///   the community word-synced database is keyed by it.
    func load(title: String, artist: String, album: String, duration: TimeInterval, spotifyID: String? = nil) {
        let key = Self.cacheKey(title: title, artist: artist, album: album, duration: duration)
        // A track whose Spotify id arrives a beat after its metadata reloads
        // once: the id unlocks the word-synced database, and it is worth one
        // more lookup. An id-bearing load is never replaced by an id-less one.
        let identity = key + (spotifyID.map { "|\($0)" } ?? "")
        guard identity != loadedKey else { return }
        if let loadedKey, loadedKey.hasPrefix(key), spotifyID == nil { return }
        loadedKey = identity
        inFlight?.cancel()

        guard !title.isEmpty, duration > 0 else {
            state = .none
            return
        }

        state = .loading
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
                Self.readCache(at: url)
            }.value
            guard !Task.isCancelled, self.loadedKey == identity else { return }
            if let cached {
                let usable = Self.cleaned(cached, title: title, artist: artist)
                self.state = usable.isEmpty ? .none : .synced(usable)
                return
            }
            await self.fetch(
                key: identity, cacheKey: key, spotifyID: spotifyID,
                title: title, artist: artist, album: album, duration: duration
            )
        }
    }

    func clear() {
        inFlight?.cancel()
        loadedKey = nil
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
    func research(title: String, artist: String, album: String, duration: TimeInterval, spotifyID: String? = nil) {
        inFlight?.cancel()
        let key = Self.cacheKey(title: title, artist: artist, album: album, duration: duration)
        let url = cacheURL(key)
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.removeItem(at: url)
        }
        loadedKey = nil
        bypassCacheOnce = true
        load(title: title, artist: artist, album: album, duration: duration, spotifyID: spotifyID)
    }

    /// One-shot cache bypass, consumed by the next `load`.
    private var bypassCacheOnce = false

    /// Catalogue hygiene, applied to every source in one place.
    ///
    /// LRC files routinely open with a credit line — the song's own
    /// "Title - Artist", sometimes a lyricist credit — stamped at t≈0. It is
    /// metadata wearing a lyric's clothes, and displayed it reads as a bad
    /// match even when the match is right. Dropped when it echoes the track's
    /// identity; and a file that is nothing but credits is not lyrics at all.
    static func cleaned(_ lines: [Line], title: String, artist: String) -> [Line] {
        let fold: (String) -> String = { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased() }
        let t = fold(title), a = fold(artist)
        var result = lines
        while let first = result.first {
            let text = fold(first.text)
            let isCredit = (!t.isEmpty && text.contains(t)) && (!a.isEmpty && text.contains(a))
            let isCreditPrefix = text.hasPrefix("作词") || text.hasPrefix("作曲") || text.hasPrefix("编曲")
                || text.hasPrefix("lyrics by") || text.hasPrefix("composed by")
            guard isCredit || isCreditPrefix else { break }
            result.removeFirst()
        }
        // One surviving line is a fragment, not a song.
        return result.count >= 2 ? result : []
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
        key: String, cacheKey: String, spotifyID: String?,
        title: String, artist: String, album: String, duration: TimeInterval
    ) async {
        // Best source first. The community TTML database carries hand-reviewed
        // word timing and is keyed by the exact track id, so there is no
        // matching to get wrong; Kugou's KRC is word-synced too but found by
        // search; LRCLIB's LRC is line-level and the floor.
        if let spotifyID, let words = await fetchAmll(spotifyID: spotifyID) {
            guard !Task.isCancelled, loadedKey == key else { return }
            let usable = Self.cleaned(words, title: title, artist: artist)
            if !usable.isEmpty {
                writeCache(cacheKey, lines: usable)
                state = .synced(usable)
                return
            }
        }
        if let words = await fetchKugou(title: title, artist: artist, duration: duration) {
            guard !Task.isCancelled, loadedKey == key else { return }
            let usable = Self.cleaned(words, title: title, artist: artist)
            if !usable.isEmpty {
                writeCache(cacheKey, lines: usable)
                state = .synced(usable)
                return
            }
        }
        await fetchLRCLIB(key: key, cacheKey: cacheKey, title: title, artist: artist, album: album, duration: duration)
    }

    /// The amll-ttml-db community database: CC0, word-by-word TTML, one file
    /// per Spotify track id, served straight from the repository.
    private func fetchAmll(spotifyID: String) async -> [Line]? {
        guard let url = URL(string: "https://raw.githubusercontent.com/Steve-xmh/amll-ttml-db/main/spotify-lyrics/\(spotifyID).ttml") else { return nil }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let parsed = WordSyncedLyrics.parseTTML(data)
        guard !parsed.isEmpty else { return nil }
        return parsed.map { Line(at: $0.at, text: $0.text, words: $0.words) }
    }

    /// Kugou's lyric search and KRC download. Unofficial and keyless; the
    /// duration gate (±3s) keeps a cover or remix from masquerading, the same
    /// rule the LRCLIB search fallback uses.
    private func fetchKugou(title: String, artist: String, duration: TimeInterval) async -> [Line]? {
        var search = URLComponents(string: "https://lyrics.kugou.com/search")!
        search.queryItems = [
            URLQueryItem(name: "ver", value: "1"),
            URLQueryItem(name: "man", value: "yes"),
            URLQueryItem(name: "client", value: "pc"),
            URLQueryItem(name: "keyword", value: "\(artist) - \(title)"),
            URLQueryItem(name: "duration", value: String(Int(duration * 1000))),
        ]
        struct SearchReply: Decodable {
            struct Candidate: Decodable {
                let id: String
                let accesskey: String
                let duration: Int?
            }
            let candidates: [Candidate]
        }
        guard let searchURL = search.url,
              let (data, _) = try? await session.data(from: searchURL),
              let reply = try? JSONDecoder().decode(SearchReply.self, from: data) else { return nil }
        let match = reply.candidates.first {
            guard let ms = $0.duration else { return false }
            // Kugou reports candidate duration in milliseconds.
            return abs(TimeInterval(ms) / 1000 - duration) <= 3
        }
        guard let match else { return nil }

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
                writeCache(cacheKey, lines: lines)
            }
        } catch {
            guard !Task.isCancelled, loadedKey == key else { return }
            // Offline or refused: say nothing rather than something wrong,
            // and leave the cache alone so the next launch can try again.
            state = .none
            return
        }
        state = lines.isEmpty ? .none : .synced(lines)
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
        // v2: the payload gained word timing; v1 files decode without it and
        // would pin a track to line-level forever, so they are simply ignored.
        cacheDirectory.appendingPathComponent("\(key).lrc2.json")
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
    }

    /// How many cached tracks to keep. The cache is one small file per track
    /// ever played, misses included, and nothing used to remove any of it: a
    /// heavy listener accumulated files forever with no setting, no expiry,
    /// and no way to clear them short of finding the folder.
    static let cacheLimit = 500

    private nonisolated static func readCache(at url: URL) -> [Line]? {
        guard let data = try? Data(contentsOf: url),
              let cached = try? JSONDecoder().decode(CachedLyrics.self, from: data),
              cached.times.count == cached.texts.count else { return nil }
        return cached.times.indices.map { index in
            var words: [WordSyncedLyrics.Word] = []
            if let wt = cached.wordTimes, let wx = cached.wordTexts,
               index < wt.count, index < wx.count, wt[index].count == wx[index].count {
                let ends = cached.wordEnds.flatMap { index < $0.count ? $0[index] : nil }
                words = zip(wt[index], wx[index]).enumerated().map { wordIndex, pair in
                    let end = ends.flatMap { wordIndex < $0.count && $0[wordIndex] >= 0 ? $0[wordIndex] : nil }
                    return WordSyncedLyrics.Word(at: pair.0, text: pair.1, end: end)
                }
            }
            return Line(at: cached.times[index], text: cached.texts[index], words: words)
        }
    }

    /// Encodes and writes off the main thread.
    ///
    /// A word-synced track carries a timing per word, and encoding plus an
    /// atomic write of that used to happen on the main actor during the exact
    /// frame the lyric crossfade was animating.
    private func writeCache(_ key: String, lines: [Line]) {
        let cached = CachedLyrics(
            times: lines.map(\.at),
            texts: lines.map(\.text),
            wordTimes: lines.map { $0.words.map(\.at) },
            wordTexts: lines.map { $0.words.map(\.text) },
            wordEnds: lines.map { $0.words.map { $0.end ?? -1 } }
        )
        let url = cacheURL(key)
        let directory = cacheDirectory
        let limit = Self.cacheLimit
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let data = try? JSONEncoder().encode(cached) else { return }
            try? data.write(to: url, options: .atomic)
            Self.pruneCache(directory: directory, limit: limit)
        }
    }

    /// Drops the least recently used entries once the cache exceeds its limit,
    /// and clears out abandoned v1 files while it is there — the format bump
    /// left those unreadable but on disk forever.
    private nonisolated static func pruneCache(directory: URL, limit: Int) {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in urls where url.pathExtension == "json" && !url.lastPathComponent.hasSuffix(".lrc2.json") {
            try? fm.removeItem(at: url)
        }
        let current = urls.filter { $0.lastPathComponent.hasSuffix(".lrc2.json") }
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
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            guard let urls = try? fm.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { return }
            for url in urls { try? fm.removeItem(at: url) }
        }
    }
}
