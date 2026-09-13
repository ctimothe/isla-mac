import Combine
import Foundation

/// Legacy broker identity kept only until Task 6 removes the retired broker
/// implementation files. The active coordinator uses LocalTrackIdentity.
struct LyricIdentity: Equatable, Sendable {
    let playerID: String
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let spotifyID: String?
    let isrc: String?
    let locale: String
    let cacheDuration: TimeInterval

    init(
        playerID: String,
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval,
        spotifyID: String? = nil,
        isrc: String? = nil,
        locale: String = Locale.current.identifier
    ) {
        self.playerID = playerID
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.spotifyID = spotifyID
        self.isrc = isrc
        self.locale = locale
        cacheDuration = duration
    }

    func enriched(
        spotifyID: String?, isrc: String?, exactDuration: TimeInterval?
    ) -> LyricIdentity {
        LyricIdentity(
            playerID: playerID, title: title, artist: artist, album: album,
            duration: exactDuration ?? duration, spotifyID: spotifyID ?? self.spotifyID,
            isrc: isrc ?? self.isrc, locale: locale, cacheDuration: cacheDuration
        )
    }

    private init(
        playerID: String, title: String, artist: String, album: String, duration: TimeInterval,
        spotifyID: String?, isrc: String?, locale: String, cacheDuration: TimeInterval
    ) {
        self.playerID = playerID
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.spotifyID = spotifyID
        self.isrc = isrc
        self.locale = locale
        self.cacheDuration = cacheDuration
    }
}

/// The common value rendered by compact, stage, and lock-card lyric surfaces.
struct LyricTimeline: Equatable, Sendable {
    enum Granularity: String, Codable, Equatable, Sendable {
        case word
        case line
    }

    let lines: [LyricsStore.Line]
    let granularity: Granularity
    /// Stable identifier for an explicitly local document. Broker-era entries
    /// remain nil until their implementation is removed in Task 6.
    let documentID: UUID?
    /// Retained temporarily for the broker's response contract. Local entries
    /// fill these compatibility values and Task 6 deletes them.
    let attribution: String
    let source: String
    let matchConfidence: Double
    let cacheExpiry: Date

    init(
        lines: [LyricsStore.Line],
        granularity: Granularity,
        documentID: UUID? = nil,
        attribution: String,
        source: String,
        matchConfidence: Double,
        cacheExpiry: Date
    ) {
        self.lines = lines
        self.granularity = granularity
        self.documentID = documentID
        self.attribution = attribution
        self.source = source
        self.matchConfidence = matchConfidence
        self.cacheExpiry = cacheExpiry
    }
}

/// Retired broker failures, preserved only while the broker source compiles.
struct LyricsFailure: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case connection
        case rateLimited
        case service
    }

    let kind: Kind
    let retryable: Bool
}

enum LyricsResolution: Equatable, Sendable {
    case available(LyricTimeline)
    case unavailable
    case failed(LyricsFailure)
}

enum LyricsAvailability: Equatable, Sendable {
    case disabled
    case settlingPlayback
    case findingLocalLyrics
    case ready(LyricTimeline)
    case noLocalLyrics
    case invalidLocalFile(LocalLyricsLibrary.FileIssue)
    /// Compatibility cases disappear with retired source code in Task 6.
    case resolving
    case unavailable
    case failed(LyricsFailure)
}

/// Compatibility protocol for the retired broker code. LyricsCoordinator no
/// longer accepts it on its active initializer.
@MainActor
protocol LyricsResolving: AnyObject {
    func resolve(_ identity: LyricIdentity) async -> LyricsResolution
}

@MainActor
final class UnconfiguredLyricsResolver: LyricsResolving {
    func resolve(_ identity: LyricIdentity) async -> LyricsResolution {
        .failed(LyricsFailure(kind: .service, retryable: false))
    }
}

/// Session-owned local lyric prefetch. It starts on Now Playing, never when a
/// SwiftUI lyric view happens to be created.
@MainActor
final class LyricsCoordinator: ObservableObject {
    @Published private(set) var availability: LyricsAvailability = .disabled
    @Published private(set) var hasLocalOverride = false
    @Published private(set) var localLookup: LocalLyricsLookup?

    let library: LocalLyricsLibrary
    private let media: MediaController
    private let isEnabled: () -> Bool
    private weak var presentation: LyricsStore?
    private var observers = Set<AnyCancellable>()
    private var logicalTrackKey: String?
    private var currentIdentity: LocalTrackIdentity?

    init(
        media: MediaController,
        library: LocalLyricsLibrary,
        isEnabled: @escaping () -> Bool,
        presentation: LyricsStore? = nil
    ) {
        self.media = media
        self.library = library
        self.isEnabled = isEnabled
        self.presentation = presentation
    }

    /// Compatibility initializer for callers that have not yet moved their
    /// store ownership to LocalLyricsLibrary. Its resolver and cache are never
    /// used; the active path is still entirely local.
    convenience init(
        media: MediaController,
        resolver _: any LyricsResolving,
        isEnabled: @escaping () -> Bool,
        presentation: LyricsStore? = nil,
        cache _: LicensedLyricsCache? = nil
    ) {
        self.init(
            media: media,
            library: LocalLyricsLibrary(directory: AppPaths.live.supportDirectory),
            isEnabled: isEnabled,
            presentation: presentation
        )
    }

    func start() {
        guard observers.isEmpty else { return }
        media.$track
            .combineLatest(media.$duration)
            .sink { [weak self] track, duration in
                self?.reconcileTrack(track: track, duration: duration)
            }
            .store(in: &observers)
        media.$positionSettled
            .sink { [weak self] _ in self?.publishAvailability() }
            .store(in: &observers)
        library.$revision
            .dropFirst()
            .sink { [weak self] _ in self?.recheckCurrentTrack() }
            .store(in: &observers)
        reconcileTrack(track: media.track, duration: media.duration)
    }

    func stop() {
        observers.removeAll()
        logicalTrackKey = nil
        currentIdentity = nil
        localLookup = nil
        hasLocalOverride = false
        presentation?.presentLocalOverride(false)
        availability = .disabled
        presentation?.present(.disabled)
    }

    /// Kept as a source-compatible Settings callback while consent becomes a
    /// local-only Show Lyrics switch.
    func refreshConsent() {
        reconcileTrack(track: media.track, duration: media.duration, force: true)
    }

    func retry() {
        recheckCurrentTrack()
    }

    func importLocalOverride(_ lrc: String) throws {
        guard let currentIdentity else { return }
        _ = try library.importDocument(lrc, binding: currentIdentity)
        hasLocalOverride = true
        presentation?.presentLocalOverride(true)
    }

    func removeLocalOverride() throws {
        guard let currentIdentity else { return }
        library.removeBinding(for: currentIdentity)
        hasLocalOverride = false
        presentation?.presentLocalOverride(false)
    }

    /// Cache clearing no longer affects local documents. Settings is rewired
    /// to explicit local-library actions in Task 5.
    func clearCache() {}

    private func reconcileTrack(
        track: MediaController.Track?, duration: TimeInterval, force: Bool = false
    ) {
        guard isEnabled(), let track, !track.title.isEmpty, duration > 0 else {
            logicalTrackKey = nil
            currentIdentity = nil
            localLookup = nil
            hasLocalOverride = false
            presentation?.presentLocalOverride(false)
            availability = .disabled
            presentation?.present(availability)
            return
        }

        guard force || logicalTrackKey != track.key else {
            publishAvailability()
            return
        }

        logicalTrackKey = track.key
        currentIdentity = LocalTrackIdentity(
            playerID: media.lyricPlayerID,
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: duration,
            recordingID: nil
        )
        hasLocalOverride = false
        presentation?.presentLocalOverride(false)
        resolveCurrentTrack()
    }

    private func recheckCurrentTrack() {
        guard currentIdentity != nil else { return }
        resolveCurrentTrack()
    }

    private func resolveCurrentTrack() {
        guard let identity = currentIdentity else { return }
        localLookup = nil
        publishAvailability()
        localLookup = library.lookup(identity: identity)
        publishAvailability()
    }

    private func publishAvailability() {
        guard isEnabled(), currentIdentity != nil else {
            availability = .disabled
            presentation?.present(availability)
            return
        }
        guard media.positionSettled else {
            availability = .settlingPlayback
            presentation?.present(availability)
            return
        }
        switch localLookup {
        case .ready(let candidate): availability = .ready(candidate.timeline)
        case .invalid(let issue): availability = .invalidLocalFile(issue)
        case .noMatch, .ambiguous: availability = .noLocalLyrics
        case nil: availability = .findingLocalLyrics
        }
        presentation?.present(availability)
    }
}
