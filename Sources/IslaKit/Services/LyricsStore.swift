import Foundation

/// Shared lyric presentation and listener-owned timing corrections.
///
/// LocalLyricsLibrary owns every document and lookup. This store deliberately
/// contains no parser, cache, resolver, request, or provider state.
@MainActor
final class LyricsStore: ObservableObject {
    struct Line: Codable, Equatable, Sendable {
        var at: TimeInterval
        var text: String
        var words: [LyricWord] = []
        var isCredit: Bool = false

        init(at: TimeInterval, text: String, words: [LyricWord] = [], isCredit: Bool = false) {
            self.at = at
            self.text = text
            self.words = words
            self.isCredit = isCredit
        }
    }

    enum State: Equatable {
        case idle
        case loading
        case synced([Line])
        case none
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var availability: LyricsAvailability = .disabled
    @Published private(set) var timingGranularity: LyricTimeline.Granularity?
    @Published private(set) var hasLocalOverride = false

    @Published var wordKaraokeEnabled = UserDefaults.standard.bool(forKey: LyricsStore.wordKaraokeEnabledKey) {
        didSet {
            UserDefaults.standard.set(wordKaraokeEnabled, forKey: LyricsStore.wordKaraokeEnabledKey)
        }
    }
    static let wordKaraokeEnabledKey = "lyrics.wordKaraokeEnabled"

    @Published var userOffset: TimeInterval = UserDefaults.standard.double(forKey: LyricsStore.offsetKey) {
        didSet {
            let clamped = min(max(userOffset, -3), 3)
            if clamped != userOffset {
                userOffset = clamped
                return
            }
            UserDefaults.standard.set(userOffset, forKey: LyricsStore.offsetKey)
        }
    }
    static let offsetKey = "lyrics.userOffset"

    @Published private(set) var trackOffset: TimeInterval = 0
    static let trackOffsetLimit: TimeInterval = 1.5
    @Published private(set) var unassignedLegacyOffsets: [UnassignedLegacyOffset] = []

    private var activeLocalTrackIdentity: LocalTrackIdentity?
    private var localTrackOffsets: [String: LocalTrackOffset] = [:]
    private let localOffsetsURL: URL
    private let unassignedOffsetsURL: URL

    struct UnassignedLegacyOffset: Codable, Equatable, Sendable, Identifiable {
        let filename: String
        let offset: TimeInterval

        var id: String { filename }
    }

    struct LegacyOffsetMigration: Sendable {
        let identity: LocalTrackIdentity
        let offset: TimeInterval
    }

    init(offsetsDirectory: URL? = nil) {
        let directory = offsetsDirectory
            ?? AppPaths.live.supportFile("lyrics-local")
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("IslaLyricsLocal")
        localOffsetsURL = directory.appendingPathComponent("offsets.json")
        unassignedOffsetsURL = directory.appendingPathComponent("unassigned-offsets.json")
        localTrackOffsets = Self.loadLocalTrackOffsets(from: localOffsetsURL)
        unassignedLegacyOffsets = Self.loadUnassignedLegacyOffsets(from: unassignedOffsetsURL)
    }

    func present(_ availability: LyricsAvailability) {
        self.availability = availability
        if case .ready(let timeline) = availability {
            timingGranularity = timeline.granularity
            state = .synced(timeline.lines)
        } else {
            timingGranularity = nil
            switch availability {
            case .disabled: state = .idle
            case .findingLocalLyrics: state = .loading
            case .noLocalLyrics, .invalidLocalFile: state = .none
            case .ready: preconditionFailure("handled above")
            }
        }
    }

    func presentLocalOverride(_ active: Bool) {
        hasLocalOverride = active
    }

    func activateTrackOffset(for identity: LocalTrackIdentity) {
        activeLocalTrackIdentity = identity
        trackOffset = trackOffset(for: identity)
    }

    func trackOffset(for identity: LocalTrackIdentity) -> TimeInterval {
        if let exact = localTrackOffsets[Self.localOffsetKey(identity)] {
            return Self.clampedTrackOffset(exact.offset)
        }
        return localTrackOffsets.values.first(where: {
            $0.identity.playerID == "legacy" && Self.sameRecording($0.identity, identity)
        }).map { Self.clampedTrackOffset($0.offset) } ?? 0
    }

    func nudgeTrackOffset(by delta: TimeInterval) {
        guard let activeLocalTrackIdentity else { return }
        setLocalTrackOffset(trackOffset(for: activeLocalTrackIdentity) + delta, for: activeLocalTrackIdentity)
    }

    func clearTrackOffset() {
        guard let activeLocalTrackIdentity else { return }
        setLocalTrackOffset(0, for: activeLocalTrackIdentity)
    }

    func removeTrackOffset(for identity: LocalTrackIdentity) {
        localTrackOffsets.removeValue(forKey: Self.localOffsetKey(identity))
        persistLocalOffsets()
        if activeLocalTrackIdentity == identity { trackOffset = trackOffset(for: identity) }
    }

    func clearLocalTrackOffsets() {
        localTrackOffsets.removeAll()
        trackOffset = 0
        persistLocalOffsets()
    }

    func dismissUnassignedLegacyOffset(named filename: String) {
        unassignedLegacyOffsets.removeAll { $0.filename == filename }
        Self.writeUnassignedLegacyOffsets(unassignedLegacyOffsets, to: unassignedOffsetsURL)
    }

    func clear() {
        activeLocalTrackIdentity = nil
        trackOffset = 0
        presentLocalOverride(false)
        present(.disabled)
    }

    /// Retains only timing corrections from pre-local releases. The old lyric
    /// text is never decoded or displayed.
    static func migrateLegacyOffsets(
        _ assigned: [LegacyOffsetMigration],
        unassigned: [UnassignedLegacyOffset],
        directory: URL,
        fileManager: FileManager = .default
    ) {
        let offsetsURL = directory.appendingPathComponent("offsets.json")
        var offsets = loadLocalTrackOffsets(from: offsetsURL, fileManager: fileManager)
        for migration in assigned where abs(migration.offset) > 0.000_001 {
            let key = localOffsetKey(migration.identity)
            guard offsets[key] == nil else { continue }
            offsets[key] = LocalTrackOffset(
                identity: migration.identity,
                offset: clampedTrackOffset(migration.offset)
            )
        }
        writeLocalTrackOffsets(offsets, to: offsetsURL, fileManager: fileManager)

        let unassignedURL = directory.appendingPathComponent("unassigned-offsets.json")
        let existing = loadUnassignedLegacyOffsets(from: unassignedURL, fileManager: fileManager)
        let merged = Dictionary(
            (existing + unassigned).map { ($0.filename, $0) },
            uniquingKeysWith: { first, _ in first }
        ).values.sorted { $0.filename < $1.filename }
        writeUnassignedLegacyOffsets(merged, to: unassignedURL, fileManager: fileManager)
    }

    static func current(in lines: [Line], at position: TimeInterval) -> (line: Line?, next: Line?) {
        guard !lines.isEmpty else { return (nil, nil) }
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
        return (
            found >= 0 ? lines[found] : nil,
            found + 1 < lines.count ? lines[found + 1] : nil
        )
    }

    static func sweepSpan(text: String, slot: TimeInterval) -> TimeInterval {
        min(max(Double(text.count) * 0.08, 1.0), max(slot, 0.5))
    }

    private static let creditPrefixes = [
        "作词", "作曲", "编曲", "制作", "混音", "母带",
        "lyrics by", "composed by", "written by", "produced by", "producer",
        "mixed by", "mastered by", "arranged by", "engineered by", "featuring",
    ]

    static func cleaned(_ lines: [Line], title: String, artist: String) -> [Line] {
        let fold: (String) -> String = {
            $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
        }
        let title = fold(title)
        let artist = fold(artist)
        var result = lines
        var index = 0
        while index < result.count {
            let text = fold(result[index].text)
            let echoesTrack = !title.isEmpty && !artist.isEmpty && text.contains(title) && text.contains(artist)
            let isCredit = creditPrefixes.contains { text.hasPrefix($0) }
            guard echoesTrack || isCredit else { break }
            result[index].isCredit = true
            index += 1
        }
        guard result.filter({ !$0.isCredit }).count >= 2 else { return [] }
        return spacedCredits(result)
    }

    static let minimumCreditSlot: TimeInterval = 1.4
    static let maximumCreditSlot: TimeInterval = 3.0

    static func spacedCredits(_ lines: [Line]) -> [Line] {
        let credits = lines.prefix { $0.isCredit }
        guard credits.count > 1 || (credits.count == 1 && lines.count > 1),
              let firstSung = lines.dropFirst(credits.count).first
        else { return lines }

        let start = credits.first?.at ?? 0
        let room = firstSung.at - start
        guard room > minimumCreditSlot else { return Array(lines.dropFirst(credits.count)) }
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

    private struct LocalTrackOffset: Codable, Equatable {
        let identity: LocalTrackIdentity
        let offset: TimeInterval
    }

    private func setLocalTrackOffset(_ value: TimeInterval, for identity: LocalTrackIdentity) {
        let offset = Self.clampedTrackOffset(value)
        localTrackOffsets[Self.localOffsetKey(identity)] = LocalTrackOffset(identity: identity, offset: offset)
        if activeLocalTrackIdentity == identity { trackOffset = offset }
        persistLocalOffsets()
    }

    private func persistLocalOffsets() {
        Self.writeLocalTrackOffsets(localTrackOffsets, to: localOffsetsURL)
    }

    private static func localOffsetKey(_ identity: LocalTrackIdentity) -> String {
        [
            identity.playerID, identity.title, identity.artist, identity.album,
            String(format: "%.3f", identity.duration), identity.recordingID ?? "",
        ].joined(separator: "\u{1F}")
    }

    private static func clampedTrackOffset(_ value: TimeInterval) -> TimeInterval {
        min(max(value, -trackOffsetLimit), trackOffsetLimit)
    }

    private static func sameRecording(_ lhs: LocalTrackIdentity, _ rhs: LocalTrackIdentity) -> Bool {
        normalizedOffsetField(lhs.title) == normalizedOffsetField(rhs.title)
            && normalizedOffsetField(lhs.artist) == normalizedOffsetField(rhs.artist)
            && normalizedOffsetField(lhs.album) == normalizedOffsetField(rhs.album)
            && lhs.duration.rounded() == rhs.duration.rounded()
            && (lhs.recordingID == nil || rhs.recordingID == nil || lhs.recordingID == rhs.recordingID)
    }

    private static func normalizedOffsetField(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func loadLocalTrackOffsets(
        from url: URL, fileManager: FileManager = .default
    ) -> [String: LocalTrackOffset] {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let offsets = try? JSONDecoder().decode([String: LocalTrackOffset].self, from: data)
        else { return [:] }
        return offsets
    }

    private static func writeLocalTrackOffsets(
        _ offsets: [String: LocalTrackOffset], to url: URL, fileManager: FileManager = .default
    ) {
        guard let data = try? JSONEncoder().encode(offsets) else { return }
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func loadUnassignedLegacyOffsets(
        from url: URL, fileManager: FileManager = .default
    ) -> [UnassignedLegacyOffset] {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let offsets = try? JSONDecoder().decode([UnassignedLegacyOffset].self, from: data)
        else { return [] }
        return offsets
    }

    private static func writeUnassignedLegacyOffsets(
        _ offsets: [UnassignedLegacyOffset], to url: URL, fileManager: FileManager = .default
    ) {
        guard let data = try? JSONEncoder().encode(offsets) else { return }
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
