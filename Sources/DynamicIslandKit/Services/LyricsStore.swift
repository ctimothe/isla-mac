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
    }

    /// Called with the displayed track. Same track twice is free.
    func load(title: String, artist: String, album: String, duration: TimeInterval) {
        let key = Self.cacheKey(title: title, artist: artist, album: album, duration: duration)
        guard key != loadedKey else { return }
        loadedKey = key
        inFlight?.cancel()

        guard !title.isEmpty, duration > 0 else {
            state = .none
            return
        }

        if let cached = readCache(key) {
            state = cached.isEmpty ? .none : .synced(cached)
            return
        }

        state = .loading
        inFlight = Task { [weak self] in
            await self?.fetch(key: key, title: title, artist: artist, album: album, duration: duration)
        }
    }

    func clear() {
        inFlight?.cancel()
        loadedKey = nil
        state = .idle
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

    // MARK: - Fetch

    private func fetch(key: String, title: String, artist: String, album: String, duration: TimeInterval) async {
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
        do {
            let (data, response) = try await session.data(for: request)
            guard !Task.isCancelled, loadedKey == key else { return }
            if (response as? HTTPURLResponse)?.statusCode == 200,
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
            // with no lyrics from being asked about on every replay.
            writeCache(key, lines: lines)
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
        cacheDirectory.appendingPathComponent("\(key).lrc.json")
    }

    private struct CachedLyrics: Codable {
        let times: [TimeInterval]
        let texts: [String]
    }

    private func readCache(_ key: String) -> [Line]? {
        guard let data = try? Data(contentsOf: cacheURL(key)),
              let cached = try? JSONDecoder().decode(CachedLyrics.self, from: data),
              cached.times.count == cached.texts.count else { return nil }
        return zip(cached.times, cached.texts).map { Line(at: $0, text: $1) }
    }

    private func writeCache(_ key: String, lines: [Line]) {
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let cached = CachedLyrics(times: lines.map(\.at), texts: lines.map(\.text))
        guard let data = try? JSONEncoder().encode(cached) else { return }
        try? data.write(to: cacheURL(key), options: .atomic)
    }
}
