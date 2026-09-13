import Combine
import Foundation

/// The minimum metadata a lyric service needs to identify a recording.
///
/// This is deliberately playback-free: position, library contents, account
/// credentials and any installation identifier stay out of a resolve request.
struct LyricIdentity: Equatable, Sendable {
    let playerID: String
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let spotifyID: String?
    let isrc: String?
    let locale: String
    /// The duration observed when this logical track began. Catalogue metadata
    /// may later refine the request duration, but imports and licensed cache
    /// entries must keep the same per-track storage key.
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
            playerID: playerID,
            title: title,
            artist: artist,
            album: album,
            duration: exactDuration ?? duration,
            spotifyID: spotifyID ?? self.spotifyID,
            isrc: isrc ?? self.isrc,
            locale: locale,
            cacheDuration: cacheDuration
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

struct LyricTimeline: Equatable, Sendable {
    enum Granularity: String, Codable, Equatable, Sendable {
        case word
        case line
    }

    let lines: [LyricsStore.Line]
    let granularity: Granularity
    let attribution: String
    let source: String
    let matchConfidence: Double
    let cacheExpiry: Date

    init(
        lines: [LyricsStore.Line],
        granularity: Granularity,
        attribution: String,
        source: String,
        matchConfidence: Double,
        cacheExpiry: Date
    ) {
        self.lines = lines
        self.granularity = granularity
        self.attribution = attribution
        self.source = source
        self.matchConfidence = matchConfidence
        self.cacheExpiry = cacheExpiry
    }
}

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
    case resolving
    case ready(LyricTimeline)
    case unavailable
    case failed(LyricsFailure)
}

/// The client-side contract for the licensed broker. A real adapter can only
/// be enabled after the provider agreement and broker endpoint exist.
@MainActor
protocol LyricsResolving: AnyObject {
    func resolve(_ identity: LyricIdentity) async -> LyricsResolution
}

/// Safe production default while the provider contract is not configured.
/// It neither contacts community sources nor emits track metadata.
@MainActor
final class UnconfiguredLyricsResolver: LyricsResolving {
    func resolve(_ identity: LyricIdentity) async -> LyricsResolution {
        .failed(LyricsFailure(kind: .service, retryable: false))
    }
}

/// Session-owned lyric resolution. It begins when Now Playing is valid, not
/// when SwiftUI happens to construct a lyric surface.
@MainActor
final class LyricsCoordinator: ObservableObject {
    @Published private(set) var availability: LyricsAvailability = .disabled
    @Published private(set) var hasLocalOverride = false

    private let media: MediaController
    private let resolver: any LyricsResolving
    private let isEnabled: () -> Bool
    private let cache: LicensedLyricsCache?
    private weak var presentation: LyricsStore?
    private var observers = Set<AnyCancellable>()
    private var request: Task<Void, Never>?
    private var logicalTrackKey: String?
    private var currentIdentity: LyricIdentity?
    private var resolution: LyricsResolution?

    init(
        media: MediaController,
        resolver: any LyricsResolving,
        isEnabled: @escaping () -> Bool,
        presentation: LyricsStore? = nil,
        cache: LicensedLyricsCache? = nil
    ) {
        self.media = media
        self.resolver = resolver
        self.isEnabled = isEnabled
        self.presentation = presentation
        self.cache = cache
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
            .sink { [weak self] settled in self?.publishAvailability(positionSettled: settled) }
            .store(in: &observers)
        Publishers.CombineLatest3(
            media.$spotifyTrackID, media.$spotifyISRC, media.$spotifyExactDuration
        )
        .sink { [weak self] spotifyID, isrc, exactDuration in
            self?.enrichCurrentIdentity(
                spotifyID: spotifyID, isrc: isrc, exactDuration: exactDuration
            )
        }
        .store(in: &observers)
        reconcileTrack(track: media.track, duration: media.duration)
    }

    func stop() {
        observers.removeAll()
        request?.cancel()
        request = nil
        logicalTrackKey = nil
        currentIdentity = nil
        resolution = nil
        hasLocalOverride = false
        presentation?.presentLocalOverride(false)
        availability = .disabled
        presentation?.present(.disabled)
    }

    func refreshConsent() {
        reconcileTrack(track: media.track, duration: media.duration, force: true)
    }

    func retry() {
        guard currentIdentity != nil else { return }
        request?.cancel()
        request = nil
        // A visible, validated timeline remains the truth while retry checks
        // for an equal-or-better result. Clearing it would blank the caption;
        // accepting a weaker result would be worse than the transient failure.
        if case .available = resolution {
            // Keep the shown timeline.
        } else {
            resolution = nil
        }
        beginResolve()
    }

    func importLocalOverride(_ lrc: String) throws {
        guard let cache, let identity = currentIdentity else { return }
        try cache.writeLocalOverride(lrc, for: identity)
        hasLocalOverride = true
        presentation?.presentLocalOverride(true)
        retry()
    }

    func removeLocalOverride() throws {
        guard let cache, let identity = currentIdentity else { return }
        try cache.removeLocalOverride(for: identity)
        hasLocalOverride = false
        presentation?.presentLocalOverride(false)
        retry()
    }

    func clearCache() {
        cache?.clear()
    }

    private func reconcileTrack(
        track: MediaController.Track?, duration: TimeInterval, force: Bool = false
    ) {
        guard isEnabled() else {
            request?.cancel()
            request = nil
            logicalTrackKey = nil
            currentIdentity = nil
            resolution = nil
            hasLocalOverride = false
            presentation?.presentLocalOverride(false)
            availability = .disabled
            presentation?.present(availability)
            return
        }
        guard let track, !track.title.isEmpty, duration > 0 else {
            request?.cancel()
            request = nil
            logicalTrackKey = nil
            currentIdentity = nil
            resolution = nil
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

        request?.cancel()
        logicalTrackKey = track.key
        currentIdentity = LyricIdentity(
            playerID: media.lyricPlayerID,
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: media.spotifyExactDuration ?? duration,
            spotifyID: media.spotifyTrackID,
            isrc: media.spotifyISRC
        )
        hasLocalOverride = currentIdentity.map { cache?.hasLocalOverride(for: $0) ?? false } ?? false
        presentation?.presentLocalOverride(hasLocalOverride)
        resolution = nil
        beginResolve()
    }

    private func beginResolve() {
        guard let identity = currentIdentity, let key = logicalTrackKey else { return }
        publishAvailability()
        request = Task { [weak self, resolver] in
            let resolved = await resolver.resolve(identity)
            guard !Task.isCancelled, let self, self.logicalTrackKey == key else { return }
            if case .available(let shown) = self.resolution,
               case .available(let candidate) = resolved,
               candidate.matchConfidence < shown.matchConfidence {
                self.publishAvailability()
                return
            }
            self.resolution = resolved
            self.publishAvailability()
        }
    }

    private func enrichCurrentIdentity(
        spotifyID: String?, isrc: String?, exactDuration: TimeInterval?
    ) {
        guard let currentIdentity else { return }
        let enriched = currentIdentity.enriched(
            spotifyID: spotifyID, isrc: isrc, exactDuration: exactDuration
        )
        guard enriched != currentIdentity else { return }
        // This deliberately changes only data used by a later retry. The
        // in-flight request keeps its stable identity and visible state.
        self.currentIdentity = enriched
    }

    private func publishAvailability(positionSettled: Bool? = nil) {
        guard isEnabled(), currentIdentity != nil else {
            availability = .disabled
            presentation?.present(availability)
            return
        }
        guard positionSettled ?? media.positionSettled else {
            availability = .settlingPlayback
            presentation?.present(availability)
            return
        }
        switch resolution {
        case .available(let timeline): availability = .ready(timeline)
        case .unavailable: availability = .unavailable
        case .failed(let failure): availability = .failed(failure)
        case nil: availability = .resolving
        }
        presentation?.present(availability)
    }
}
