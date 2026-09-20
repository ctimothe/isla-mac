import Combine
import Foundation

/// The common local timeline rendered by compact, stage, and lock-card lyric
/// surfaces. A document id makes the active local file inspectable and editable.
struct LyricTimeline: Equatable, Sendable {
    enum Granularity: String, Codable, Equatable, Sendable {
        case word
        case line
    }

    let lines: [LyricsStore.Line]
    let granularity: Granularity
    let documentID: UUID?

    init(lines: [LyricsStore.Line], granularity: Granularity, documentID: UUID? = nil) {
        self.lines = lines
        self.granularity = granularity
        self.documentID = documentID
    }
}

enum LyricsAvailability: Equatable, Sendable {
    case disabled
    case findingLocalLyrics
    case ready(LyricTimeline)
    case noLocalLyrics
    case invalidLocalFile(LocalLyricsLibrary.FileIssue)
}

/// Session-owned local lyric prefetch. It begins from Now Playing, never from
/// a SwiftUI surface, and reads only explicit imports and selected folders.
@MainActor
final class LyricsCoordinator: ObservableObject {
    @Published private(set) var availability: LyricsAvailability = .disabled
    @Published private(set) var hasLocalOverride = false
    @Published private(set) var localLookup: LocalLyricsLookup?

    let library: LocalLyricsLibrary
    private let media: MediaController
    private let isEnabled: () -> Bool
    private let isOnlineEnabled: () -> Bool
    private let onlineCache: OnlineLyricsCache
    private let onlineLookUp: (LocalTrackIdentity) async -> OnlineLyrics.Outcome
    /// A timeline LRCLIB answered with, for the track on screen now. Cleared on
    /// every track change, so a fetch that lands late for the previous song
    /// cannot present itself against this one.
    private var onlineTimeline: LyricTimeline?
    /// Bumped per track, so a slow answer can tell it is no longer wanted.
    private var lookUpGeneration = 0
    private weak var presentation: LyricsStore?
    private var observers = Set<AnyCancellable>()
    private var logicalTrackKey: String?
    private var currentIdentity: LocalTrackIdentity?

    var currentLocalTrackIdentity: LocalTrackIdentity? { currentIdentity }

    init(
        media: MediaController,
        library: LocalLyricsLibrary,
        isEnabled: @escaping () -> Bool,
        isOnlineEnabled: @escaping () -> Bool = { false },
        presentation: LyricsStore? = nil,
        onlineCache: OnlineLyricsCache? = nil,
        onlineLookUp: @escaping (LocalTrackIdentity) async -> OnlineLyrics.Outcome = {
            await OnlineLyrics.lookUp($0)
        }
    ) {
        self.media = media
        self.library = library
        self.isEnabled = isEnabled
        // Default false, so a coordinator built without an opinion — every
        // existing test — never reaches the network.
        self.isOnlineEnabled = isOnlineEnabled
        self.presentation = presentation
        self.onlineCache = onlineCache ?? OnlineLyricsCache()
        self.onlineLookUp = onlineLookUp
    }

    func start() {
        guard observers.isEmpty else { return }
        media.$track
            .combineLatest(media.$duration)
            .sink { [weak self] track, duration in
                self?.reconcileTrack(track: track, duration: duration)
            }
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
        onlineTimeline = nil
        lookUpGeneration += 1
        localLookup = nil
        hasLocalOverride = false
        presentation?.presentLocalOverride(false)
        availability = .disabled
        presentation?.present(.disabled)
    }

    func refreshVisibility() {
        reconcileTrack(track: media.track, duration: media.duration, force: true)
    }

    /// Ask again, including the network. A remembered miss is forgotten first,
    /// so Retry means retry rather than "show me the same no".
    func retry() {
        onlineTimeline = nil
        if let currentIdentity { onlineCache.forget(currentIdentity) }
        recheckCurrentTrack()
    }

    func importLocalOverride(_ lrc: String) throws {
        guard let currentIdentity else { return }
        _ = try library.importDocument(lrc, binding: currentIdentity)
        markLocalOverride()
    }

    func importLocalFile(at url: URL) throws {
        guard let currentIdentity else { return }
        _ = try library.importDocument(at: url, binding: currentIdentity)
        markLocalOverride()
    }

    func selectLocalCandidate(_ candidate: LocalLyricsCandidate) {
        guard let currentIdentity else { return }
        library.bind(candidate, to: currentIdentity)
        markLocalOverride()
    }

    func removeLocalBinding() {
        guard let currentIdentity else { return }
        library.removeBinding(for: currentIdentity)
        hasLocalOverride = false
        presentation?.presentLocalOverride(false)
    }

    private func markLocalOverride() {
        hasLocalOverride = true
        presentation?.presentLocalOverride(true)
    }

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
            presentation?.present(.disabled)
            return
        }

        // A track change, or a correction to the one already showing.
        //
        // The second case is not hypothetical: the player publishes the title
        // before it knows the length, so this ran once with the new track and
        // the *previous* track's duration. Keyed on the title alone, the stale
        // duration then stuck for as long as the song played — and duration is
        // what both the local matcher (±2s) and the online lookup identify a
        // recording by, so that song simply had no lyrics until it was played
        // again. Observed on 2026-09-21: a lookup cached against a length
        // belonging to the song before it.
        let durationMoved = currentIdentity.map { abs($0.duration - duration) > 1 } ?? true
        guard force || logicalTrackKey != track.key || durationMoved else {
            publishAvailability()
            return
        }

        logicalTrackKey = track.key
        // A new song: whatever the network said about the last one is not about
        // this one, and any answer still in flight is stale.
        onlineTimeline = nil
        lookUpGeneration += 1
        currentIdentity = LocalTrackIdentity(
            playerID: media.lyricPlayerID,
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: duration,
            recordingID: nil
        )
        if let currentIdentity { presentation?.activateTrackOffset(for: currentIdentity) }
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
        lookUpOnlineIfNeeded(for: identity)
    }

    /// The network, and only where nothing else can answer.
    ///
    /// Reached only when the local library found *no* match at all. An
    /// ambiguous local result still asks the listener to choose — a file they
    /// put there outranks anything a catalogue suggests, and quietly fetching
    /// instead of asking would be the app deciding for them.
    private func lookUpOnlineIfNeeded(for identity: LocalTrackIdentity) {
        guard isOnlineEnabled(), isEnabled(), localLookup == .noMatch else { return }
        if let remembered = onlineCache.cached(identity) {
            // Asked before: a remembered hit shows at once and a remembered
            // miss stays a miss, so a library of tracks LRCLIB does not have
            // costs one request each rather than one per play.
            onlineTimeline = remembered
            publishAvailability()
            return
        }
        let generation = lookUpGeneration
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.onlineLookUp(identity)
            guard self.lookUpGeneration == generation else { return }
            self.onlineCache.remember(outcome, for: identity)
            if case .found(let timeline) = outcome { self.onlineTimeline = timeline }
            self.publishAvailability()
        }
    }

    private func publishAvailability() {
        guard isEnabled(), let identity = currentIdentity else {
            availability = .disabled
            presentation?.present(availability)
            media.setLyricBoundaries([], lead: { 0 })
            return
        }
        // Nothing here waits for the clock to settle. The line shown is the one
        // the clock points at now, and it moves when a correction lands — the
        // way the system's own lyrics behave. The wait this used to impose
        // showed a spinner on every open of the panel.
        switch localLookup {
        case .ready(let candidate): availability = .ready(candidate.timeline)
        case .invalid(let issue): availability = .invalidLocalFile(issue)
        case .noMatch:
            // The network's answer stands in only where there is no local one.
            if let onlineTimeline {
                availability = .ready(onlineTimeline)
            } else if isOnlineEnabled(), isEnabled() {
                // Still asking. The caption already says "Finding lyrics…",
                // which is true of a request in flight as much as of a folder
                // scan, so no surface needs a new state to render.
                availability = onlineCache.cached(identity) == nil
                    ? .findingLocalLyrics
                    : .noLocalLyrics
            } else {
                availability = .noLocalLyrics
            }
        case .ambiguous: availability = .noLocalLyrics
        case nil: availability = .findingLocalLyrics
        }
        presentation?.present(availability)
        registerBoundaries()
    }

    /// Hands the clock every line's timestamp, so it can wake the surfaces on
    /// the frame a line is due instead of on its quarter-second grid. The lead
    /// is read at each wake, so a nudge takes effect on the next one.
    private func registerBoundaries() {
        guard case .ready(let timeline) = availability else {
            media.setLyricBoundaries([], lead: { 0 })
            return
        }
        let media = self.media
        let presentation = self.presentation
        media.setLyricBoundaries(timeline.lines.map(\.at)) {
            LyricSweep.lead(
                precisionSync: media.precisionSync,
                userOffset: presentation?.userOffset ?? 0,
                trackOffset: presentation?.trackOffset ?? 0
            )
        }
    }
}
