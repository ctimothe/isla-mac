import Foundation

/// Disk cache for data whose display and retention rights are explicit.
///
/// Version 5 intentionally does not decode the v4 community entries. On first
/// use it prunes them rather than silently carrying text forward under a
/// licence that never covered it. Local LRC files live separately and are
/// never offered to a resolver or broker.
@MainActor
struct LicensedLyricsCache {
    enum Error: Swift.Error {
        case invalidLocalOverride
    }

    private let directory: URL
    private let fileManager: FileManager

    init(
        directory: URL = AppPaths.live.supportFile("lyrics-v5")
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("IslaLyrics", isDirectory: true),
        legacyDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.fileManager = fileManager
        migrateV4Entries()
        if let legacyDirectory { pruneV4Entries(in: legacyDirectory) }
    }

    func read(for identity: LyricIdentity, now: Date = Date()) -> LyricTimeline? {
        if let local = readLocalOverride(for: identity) { return local }
        let url = licensedURL(for: identity)
        guard let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.version == 5,
              entry.source == "licensed" else {
            return nil
        }
        guard entry.cacheExpiry > now else {
            try? fileManager.removeItem(at: url)
            return nil
        }
        return entry.timeline
    }

    func writeLicensed(_ timeline: LyricTimeline, for identity: LyricIdentity) throws {
        let entry = Entry(timeline: timeline)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(entry)
        try data.write(to: licensedURL(for: identity), options: .atomic)
    }

    /// Copies a user-selected LRC file into Isla support storage. Only its
    /// matching track can read it; it never becomes an outbound request body.
    func writeLocalOverride(_ lrc: String, for identity: LyricIdentity) throws {
        guard !LyricsStore.parseLRC(lrc).isEmpty else { throw Error.invalidLocalOverride }
        let overrides = overrideDirectory
        try fileManager.createDirectory(at: overrides, withIntermediateDirectories: true)
        try Data(lrc.utf8).write(to: localURL(for: identity), options: .atomic)
    }

    func removeLocalOverride(for identity: LyricIdentity) throws {
        let url = localURL(for: identity)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    func hasLocalOverride(for identity: LyricIdentity) -> Bool {
        fileManager.fileExists(atPath: localURL(for: identity).path)
    }

    func clear() {
        try? fileManager.removeItem(at: directory)
    }

    func licensedURL(for identity: LyricIdentity) -> URL {
        directory.appendingPathComponent("\(cacheKey(for: identity)).lrc5.json")
    }

    private var overrideDirectory: URL {
        directory.appendingPathComponent("overrides", isDirectory: true)
    }

    private func localURL(for identity: LyricIdentity) -> URL {
        overrideDirectory.appendingPathComponent("\(cacheKey(for: identity)).lrc")
    }

    private func readLocalOverride(for identity: LyricIdentity) -> LyricTimeline? {
        let url = localURL(for: identity)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = LyricsStore.parseLRC(raw)
        guard !lines.isEmpty else {
            try? fileManager.removeItem(at: url)
            return nil
        }
        return LyricTimeline(
            lines: lines,
            granularity: .line,
            attribution: "Local LRC",
            source: "local",
            matchConfidence: 1,
            cacheExpiry: .distantFuture
        )
    }

    private func cacheKey(for identity: LyricIdentity) -> String {
        LyricsStore.cacheKey(
            title: identity.title,
            artist: identity.artist,
            album: identity.album,
            duration: identity.cacheDuration
        )
    }

    private func migrateV4Entries() {
        pruneV4Entries(in: directory)
    }

    private func pruneV4Entries(in directory: URL) {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }
        for url in urls where url.lastPathComponent.hasSuffix(".lrc4.json") {
            try? fileManager.removeItem(at: url)
        }
    }

    private struct Entry: Codable {
        let version: Int
        let source: String
        let granularity: LyricTimeline.Granularity
        let attribution: String
        let matchConfidence: Double
        let cacheExpiry: Date
        let lines: [StoredLine]

        init(timeline: LyricTimeline) {
            version = 5
            source = "licensed"
            granularity = timeline.granularity
            attribution = timeline.attribution
            matchConfidence = timeline.matchConfidence
            cacheExpiry = timeline.cacheExpiry
            lines = timeline.lines.map(StoredLine.init)
        }

        var timeline: LyricTimeline {
            LyricTimeline(
                lines: lines.map(\.line),
                granularity: granularity,
                attribution: attribution,
                source: source,
                matchConfidence: matchConfidence,
                cacheExpiry: cacheExpiry
            )
        }
    }

    private struct StoredLine: Codable {
        let at: TimeInterval
        let text: String
        let isCredit: Bool
        let words: [StoredWord]

        init(_ line: LyricsStore.Line) {
            at = line.at
            text = line.text
            isCredit = line.isCredit
            words = line.words.map(StoredWord.init)
        }

        var line: LyricsStore.Line {
            LyricsStore.Line(at: at, text: text, words: words.map(\.word), isCredit: isCredit)
        }
    }

    private struct StoredWord: Codable {
        let at: TimeInterval
        let text: String
        let end: TimeInterval?

        init(_ word: WordSyncedLyrics.Word) {
            at = word.at
            text = word.text
            end = word.end
        }

        var word: WordSyncedLyrics.Word {
            WordSyncedLyrics.Word(at: at, text: text, end: end)
        }
    }
}
