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
        /// When the voice stops, where the source said so: an LRC file's
        /// empty stamp after this line (`LocalLyricsDocument.parse`). Nil
        /// means unknown — the line runs to the next one, as every line did
        /// before 2026-10-11. Optional so that every timeline cached or
        /// indexed before it existed still decodes; such a cache simply
        /// carries no ends until it is fetched again.
        ///
        /// Stored as the source wrote it. Whether a surface honours it — a
        /// breath of half a second must not blink the line off and on — is
        /// `LyricSweep.effectiveEnd`'s decision, made in one place.
        var end: TimeInterval?

        init(
            at: TimeInterval, text: String, words: [LyricWord] = [], isCredit: Bool = false,
            end: TimeInterval? = nil
        ) {
            self.at = at
            self.text = text
            self.words = words
            self.isCredit = isCredit
            self.end = end
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

    /// Where the listener's settings live: the app's own defaults, or a
    /// private suite under test. Injected because the xctest defaults domain
    /// outlives a test run and leaks between them, and the sign migration
    /// below writes on first launch.
    private let defaults: UserDefaults

    @Published var wordKaraokeEnabled: Bool {
        didSet {
            defaults.set(wordKaraokeEnabled, forKey: LyricsStore.wordKaraokeEnabledKey)
        }
    }
    static let wordKaraokeEnabledKey = "lyrics.wordKaraokeEnabled"

    /// "Lyric Delay": positive shows every line later. See `LyricSweep.lead`.
    @Published var userOffset: TimeInterval {
        didSet {
            let clamped = min(max(userOffset, -3), 3)
            if clamped != userOffset {
                userOffset = clamped
                return
            }
            defaults.set(userOffset, forKey: LyricsStore.offsetKey)
        }
    }
    static let offsetKey = "lyrics.userOffset"

    /// Which way the stored corrections point. Absent means 1, the build that
    /// added them to the lead and so ran every control backwards; 2 is a
    /// delay, subtracted. The global correction carries its version here, in
    /// defaults; the files carry theirs beside them (`offsetSignMarkerName`).
    static let offsetSignVersionKey = "lyrics.offsetSignVersion"
    static let offsetSignVersion = 2
    /// The files' own version marker, a one-line text file in the offsets
    /// directory. Not the defaults key: the defaults domain and the directory
    /// are separate stores, and they do not travel together. A
    /// `defaults delete com.ctimothe.isla` (how first run is re-tested) keeps
    /// the files, and a marker kept only in defaults would flip every
    /// per-track correction a second time on the next launch; a process
    /// reading a different domain — xctest's, under test — would do the same.
    /// Kept beside the files, whichever process gets there first does it, and
    /// nobody does it twice.
    static let offsetSignMarkerName = "offset-sign-version"

    @Published private(set) var trackOffset: TimeInterval = 0
    static let trackOffsetLimit: TimeInterval = 1.5
    @Published private(set) var unassignedLegacyOffsets: [UnassignedLegacyOffset] = []

    private var activeLocalTrackIdentity: LocalTrackIdentity?
    /// The lyric file showing for that track: its document id, or nil for the
    /// catalogue's words (which have none) and for a track whose words have
    /// not resolved yet. A nudge records it, so the correction stays with the
    /// file it was made against (`LocalTrackOffset.applies(to:)`).
    private var activeDocumentID: UUID?
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

    init(offsetsDirectory: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let directory = offsetsDirectory
            ?? AppPaths.live.supportFile("lyrics-local")
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("IslaLyricsLocal")
        localOffsetsURL = directory.appendingPathComponent("offsets.json")
        unassignedOffsetsURL = directory.appendingPathComponent("unassigned-offsets.json")
        // Before anything is read: the stored values are rewritten in place,
        // and what loads below is already in the new sign. `NotchStores`
        // builds the local library first, so a pre-local correction it has
        // just imported in the old sign is caught by this same pass.
        Self.migrateOffsetSign(in: defaults)
        // Never the listener's own files from inside a test process. Every
        // `NotchStores()` a test builds opens the real support directory, and
        // the first unsandboxed run of this migration on 2026-10-11 rewrote
        // the owner's offsets.json (put back by hand) while the installed
        // build — which still adds corrections to the lead — was the one
        // reading it. Those files
        // belong to whichever Isla is installed, and it flips them itself on
        // its first launch.
        if !(PlayerBridge.isRunningTests && Self.isLiveSupportDirectory(directory)) {
            Self.migrateOffsetSign(in: directory)
        }
        wordKaraokeEnabled = defaults.bool(forKey: Self.wordKaraokeEnabledKey)
        userOffset = defaults.double(forKey: Self.offsetKey)
        localTrackOffsets = Self.loadLocalTrackOffsets(from: localOffsetsURL)
        unassignedLegacyOffsets = Self.loadUnassignedLegacyOffsets(from: unassignedOffsetsURL)
    }

    /// Negates the global correction once, so the listener's effective lead is
    /// the same number after the sign flip as before it. The owner's −0.247 s
    /// (tuned for AirPods, checklist.md 2026-09-21) reads +0.247 s afterwards
    /// and lights every line at exactly the same moment; left alone it would
    /// have moved them all by half a second.
    private static func migrateOffsetSign(in defaults: UserDefaults) {
        guard defaults.integer(forKey: offsetSignVersionKey) < offsetSignVersion else { return }
        if defaults.object(forKey: offsetKey) != nil {
            let stored = defaults.double(forKey: offsetKey)
            // Zero stays zero rather than becoming −0, which the readout
            // formats as "-0.00s".
            if stored != 0 { defaults.set(-stored, forKey: offsetKey) }
        }
        defaults.set(offsetSignVersion, forKey: offsetSignVersionKey)
    }

    /// The same flip for every per-track correction in offsets.json and every
    /// unassigned legacy one, once per directory. The marker goes down last
    /// and only after both files are written, so a directory that could not
    /// be rewritten is tried again on the next launch rather than marked done
    /// with the old values still in it.
    private static func migrateOffsetSign(
        in directory: URL, fileManager: FileManager = .default
    ) {
        guard offsetSignVersion(in: directory, fileManager: fileManager) < offsetSignVersion else { return }
        let offsetsURL = directory.appendingPathComponent("offsets.json")
        let unassignedURL = directory.appendingPathComponent("unassigned-offsets.json")
        var written = true
        // A file that does not decode is left exactly as it is: the loaders
        // already read it as empty, and rewriting it here would turn a file
        // nobody can read into one nobody can recover.
        if let data = try? Data(contentsOf: offsetsURL),
           let stored = try? JSONDecoder().decode([String: LocalTrackOffset].self, from: data) {
            let flipped = stored.mapValues { $0.withOffset(-$0.offset) }
            written = writeLocalTrackOffsets(flipped, to: offsetsURL, fileManager: fileManager) && written
        }
        if let data = try? Data(contentsOf: unassignedURL),
           let stored = try? JSONDecoder().decode([UnassignedLegacyOffset].self, from: data) {
            let flipped = stored.map { UnassignedLegacyOffset(filename: $0.filename, offset: -$0.offset) }
            written = writeUnassignedLegacyOffsets(flipped, to: unassignedURL, fileManager: fileManager) && written
        }
        guard written else { return }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data("\(offsetSignVersion)\n".utf8).write(
            to: directory.appendingPathComponent(offsetSignMarkerName), options: .atomic
        )
    }

    static func isLiveSupportDirectory(_ directory: URL) -> Bool {
        let live = AppPaths.live.supportDirectory.standardizedFileURL.path
        let path = directory.standardizedFileURL.path
        return path == live || path.hasPrefix(live + "/")
    }

    private static func offsetSignVersion(in directory: URL, fileManager: FileManager) -> Int {
        let marker = directory.appendingPathComponent(offsetSignMarkerName)
        guard fileManager.fileExists(atPath: marker.path),
              let text = try? String(contentsOf: marker, encoding: .utf8),
              let version = Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return 1 }
        return version
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
            case .resolving, .findingLocalLyrics: state = .loading
            case .noLocalLyrics, .invalidLocalFile, .cannotLookUp: state = .none
            case .ready: preconditionFailure("handled above")
            }
        }
    }

    func presentLocalOverride(_ active: Bool) {
        hasLocalOverride = active
    }

    /// Called once with the song when it changes, and again with the file
    /// whenever the words on screen resolve or change (`LyricsCoordinator
    /// .publishAvailability`). That runs on every recheck of the same song, so
    /// an unchanged value is not written: a published write redraws every
    /// lyric surface even when the number is the same.
    func activateTrackOffset(for identity: LocalTrackIdentity, documentID: UUID? = nil) {
        activeLocalTrackIdentity = identity
        activeDocumentID = documentID
        let offset = trackOffset(for: identity, documentID: documentID)
        if trackOffset != offset { trackOffset = offset }
    }

    /// The nudge for this song as it applies to this file. An entry made
    /// against another file reads 0 rather than falling back to anything:
    /// the song's own entry is newer than any pre-local one, and the listener
    /// has not corrected this file yet.
    func trackOffset(for identity: LocalTrackIdentity, documentID: UUID? = nil) -> TimeInterval {
        if let exact = localTrackOffsets[Self.localOffsetKey(identity)] {
            return exact.applies(to: documentID) ? Self.clampedTrackOffset(exact.offset) : 0
        }
        return localTrackOffsets.values.first(where: {
            $0.identity.playerID == "legacy" && Self.sameRecording($0.identity, identity)
                && $0.applies(to: documentID)
        }).map { Self.clampedTrackOffset($0.offset) } ?? 0
    }

    func nudgeTrackOffset(by delta: TimeInterval) {
        guard let activeLocalTrackIdentity else { return }
        setLocalTrackOffset(
            trackOffset(for: activeLocalTrackIdentity, documentID: activeDocumentID) + delta,
            for: activeLocalTrackIdentity
        )
    }

    func clearTrackOffset() {
        guard let activeLocalTrackIdentity else { return }
        setLocalTrackOffset(0, for: activeLocalTrackIdentity)
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
        activeDocumentID = nil
        trackOffset = 0
        presentLocalOverride(false)
        present(.disabled)
    }

    /// Retains only timing corrections from pre-local releases. The old lyric
    /// text is never decoded or displayed.
    ///
    /// Pre-local corrections are always in the old sign (added to the lead).
    /// On a first upgrade this runs before any `LyricsStore` has opened the
    /// directory, writes them as they are, and the store's sign migration
    /// flips them with everything else. But the library re-runs this import
    /// whenever its index is reset, and by then the directory is already at
    /// the new sign: written as they are, those corrections would come back
    /// inverted. So into a flipped directory they are flipped on the way in.
    static func migrateLegacyOffsets(
        _ assigned: [LegacyOffsetMigration],
        unassigned: [UnassignedLegacyOffset],
        directory: URL,
        fileManager: FileManager = .default
    ) {
        let sign: TimeInterval =
            offsetSignVersion(in: directory, fileManager: fileManager) >= offsetSignVersion ? -1 : 1
        let offsetsURL = directory.appendingPathComponent("offsets.json")
        var offsets = loadLocalTrackOffsets(from: offsetsURL, fileManager: fileManager)
        for migration in assigned where abs(migration.offset) > 0.000_001 {
            let key = localOffsetKey(migration.identity)
            guard offsets[key] == nil else { continue }
            offsets[key] = LocalTrackOffset(
                identity: migration.identity,
                offset: clampedTrackOffset(sign * migration.offset)
            )
        }
        writeLocalTrackOffsets(offsets, to: offsetsURL, fileManager: fileManager)

        let unassignedURL = directory.appendingPathComponent("unassigned-offsets.json")
        let existing = loadUnassignedLegacyOffsets(from: unassignedURL, fileManager: fileManager)
        let incoming = unassigned.map {
            UnassignedLegacyOffset(filename: $0.filename, offset: sign * $0.offset)
        }
        let merged = Dictionary(
            (existing + incoming).map { ($0.filename, $0) },
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

    /// One song's nudge, and the file it was made against.
    ///
    /// Nudges were keyed by player, title, artist, album and length alone, so
    /// they belonged to the song: a song nudged +0.5 s against one file kept
    /// the +0.5 s after a correctly timed file was imported or a retimed edit
    /// saved, and the new file was half a second wrong (J-024). The key stays
    /// the song's — putting the file in it would have orphaned every nudge
    /// already saved — and the entry records the file instead. One entry per
    /// song, so a nudge against a second file replaces the first file's;
    /// switching back starts that file over at 0, which is wrong by at most
    /// one nudge rather than by a correction made for another file.
    private struct LocalTrackOffset: Codable, Equatable {
        let identity: LocalTrackIdentity
        let offset: TimeInterval
        /// The local file the nudge was made against.
        let documentID: UUID?
        /// True when it was made against the catalogue's words, which carry
        /// no document id. Nil — together with a nil `documentID` — is an
        /// entry written before nudges recorded their file (and every
        /// pre-local one `migrateLegacyOffsets` carries over): nobody knows
        /// which file it corrected, so it goes on applying to whichever one
        /// shows, exactly as it always did. Both fields are optional so that
        /// those entries still decode.
        let madeOnline: Bool?

        init(
            identity: LocalTrackIdentity, offset: TimeInterval,
            documentID: UUID? = nil, madeOnline: Bool? = nil
        ) {
            self.identity = identity
            self.offset = offset
            self.documentID = documentID
            self.madeOnline = madeOnline
        }

        /// Whether this nudge belongs to the file showing: `documentID` is the
        /// local file's, or nil for the catalogue's words.
        func applies(to documentID: UUID?) -> Bool {
            if let made = self.documentID { return made == documentID }
            if madeOnline == true { return documentID == nil }
            return true
        }

        /// The same entry with another value. The sign migration goes through
        /// this so that it cannot drop the file an entry was made against.
        func withOffset(_ offset: TimeInterval) -> LocalTrackOffset {
            LocalTrackOffset(identity: identity, offset: offset, documentID: documentID, madeOnline: madeOnline)
        }
    }

    private func setLocalTrackOffset(_ value: TimeInterval, for identity: LocalTrackIdentity) {
        let offset = Self.clampedTrackOffset(value)
        // Only the active song is ever nudged or cleared, so the file showing
        // is the one this correction was made against.
        localTrackOffsets[Self.localOffsetKey(identity)] = LocalTrackOffset(
            identity: identity, offset: offset,
            documentID: activeDocumentID, madeOnline: activeDocumentID == nil
        )
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

    @discardableResult
    private static func writeLocalTrackOffsets(
        _ offsets: [String: LocalTrackOffset], to url: URL, fileManager: FileManager = .default
    ) -> Bool {
        guard let data = try? JSONEncoder().encode(offsets) else { return false }
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: url, options: .atomic)) != nil
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

    @discardableResult
    private static func writeUnassignedLegacyOffsets(
        _ offsets: [UnassignedLegacyOffset], to url: URL, fileManager: FileManager = .default
    ) -> Bool {
        guard let data = try? JSONEncoder().encode(offsets) else { return false }
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}
