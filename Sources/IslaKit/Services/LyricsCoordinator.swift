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
    private weak var presentation: LyricsStore?
    private var observers = Set<AnyCancellable>()
    private var logicalTrackKey: String?
    private var currentIdentity: LocalTrackIdentity?

    var currentLocalTrackIdentity: LocalTrackIdentity? { currentIdentity }

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
        localLookup = nil
        hasLocalOverride = false
        presentation?.presentLocalOverride(false)
        availability = .disabled
        presentation?.present(.disabled)
    }

    func refreshVisibility() {
        reconcileTrack(track: media.track, duration: media.duration, force: true)
    }

    func retry() {
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
    }

    private func publishAvailability() {
        guard isEnabled(), currentIdentity != nil else {
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
        case .noMatch, .ambiguous: availability = .noLocalLyrics
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
