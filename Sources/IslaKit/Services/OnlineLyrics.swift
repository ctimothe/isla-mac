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
    static func lookUp(
        _ identity: LocalTrackIdentity,
        transport: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            try await URLSession.shared.data(for: request)
        }
    ) async -> Outcome {
        guard let request = request(for: identity) else { return .none }
        do {
            let (data, response) = try await transport(request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return timeline(from: data, status: status)
        } catch {
            return .failed
        }
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
    }

    private let directory: URL?
    private var entries: [String: Entry] = [:]

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
        guard Date().timeIntervalSince(entry.checkedAt) < Self.missLifetime else { return nil }
        return .some(nil)
    }

    func remember(_ outcome: OnlineLyrics.Outcome, for identity: LocalTrackIdentity) {
        switch outcome {
        case .found(let timeline):
            entries[Self.key(identity)] = Entry(lines: timeline.lines, checkedAt: Date())
        case .none:
            entries[Self.key(identity)] = Entry(lines: nil, checkedAt: Date())
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

    private func save() {
        guard let file, let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: file, options: .atomic)
    }
}
