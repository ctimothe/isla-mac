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
    /// Why a playing track cannot be looked up at all, by any source.
    enum Reason: Equatable, Sendable {
        /// A stream, a radio station or a browser tab: no length, and length
        /// is what both the local matcher (±2s) and the catalogue identify a
        /// recording by.
        case noLength
        /// Nothing to search for.
        case noTitle
    }

    /// Show Lyrics is off, or nothing is playing (which no surface draws).
    ///
    /// Only that. It used to also mean "no title" and "no length", so every
    /// stream said "Lyrics are off." beside a Show Lyrics button that rewrote
    /// an already-true switch and could not work.
    case disabled
    /// Lyrics are on and a track is playing, but nothing can look it up.
    /// Said plainly, with no offer: nothing the listener can press would help.
    case cannotLookUp(Reason)
    /// Asked, with nothing to say yet — and deliberately drawn as nothing.
    ///
    /// A track change resolves in one of two ways: from memory, which is
    /// immediate, or from the catalogue, which is a round trip. Publishing
    /// "Finding lyrics…" for both meant every skip flashed a spinner that was
    /// gone a frame later, and a queue of skips strobed. The slot is already
    /// reserved at a fixed height, so holding it empty for a moment is
    /// invisible; `LyricsCoordinator` promotes this to `findingLocalLyrics`
    /// only once the wait is long enough to be worth admitting to.
    case resolving
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
    /// The request in flight. Held so a skip can cancel it outright rather than
    /// merely ignore its answer: ten fast skips used to leave ten requests
    /// running to completion against a free service, for nine answers nobody
    /// would ever see.
    private var lookUpTask: Task<Void, Never>?
    /// Promotes `resolving` to `findingLocalLyrics` once the wait is real.
    private var admitWaitTask: Task<Void, Never>?
    /// The last lookup for this track could not reach the catalogue. The card
    /// says what a miss says, quietly, and asks again on its own.
    ///
    /// A failure was never remembered and never retried, so it left the
    /// spinner up for as long as the song played; and the only way on was a
    /// Retry button the lock card could not even fit — "R…", filmed on
    /// 2026-09-21. Apple's players have no such button. The app asks again
    /// itself, after `retryDelays`, while the same song is playing.
    private var onlineFailed = false
    private var retryAttempt = 0
    private var retryTask: Task<Void, Never>?
    /// When a failed lookup is asked again: soon, then less often, then left
    /// for the song's next play.
    static var retryDelays: [TimeInterval] = [5, 30, 120]
    /// False until `quietGrace` has passed with no answer. Reset by every
    /// track change, so each skip gets its own quiet moment.
    private var waitIsWorthAdmitting = false

    /// How long a lyric may take to arrive before the app says it is looking.
    ///
    /// Under this, a skip shows an empty slot that fills — which reads as
    /// instant, because it is. Over it, silence would read as broken, so the
    /// spinner and "Finding lyrics…" appear. It sits just past a warm
    /// catalogue answer and well under the point a person starts to wonder.
    ///
    /// 0.35s was just short of it. Filmed on 2026-09-21, two catalogue answers
    /// landed 0.38s and 0.44s after their skips, so the spinner flashed for
    /// 67ms and 100ms and was gone — a loading state nobody could read. 0.6s
    /// clears both with room to spare.
    static var quietGrace: TimeInterval = 0.6

    /// How long a track may play with no length before it is called live
    /// audio.
    ///
    /// Players publish the title before the length (see `reconcileTrack`), so
    /// every ordinary song passes through "no length" on its way in. Said at
    /// once, each skip would flash "No lyrics for live audio." for the frame
    /// before its length landed. Over this, the length is not coming: a
    /// stream, a radio station or a browser tab. Until then the slot is held
    /// empty, the same quiet wait a lookup gets.
    static var noLengthGrace: TimeInterval = 1.5
    /// Settles a track with no length into `.cannotLookUp(.noLength)` once
    /// `noLengthGrace` has passed. Cancelled the moment a length arrives.
    private var noLengthTask: Task<Void, Never>?
    /// The track `noLengthTask` is timing, so the steady stream of identical
    /// updates a playing stream sends does not restart the clock each time.
    private var noLengthKey: String?
    private weak var presentation: LyricsStore?
    /// The route's reported output latency, for the lead model. Running only
    /// while Show Lyrics is on (`syncOutputLatencyWatch`); nil in a
    /// coordinator built without one, which is every test that does not ask.
    private let outputLatency: OutputLatencyMonitor?
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
        },
        outputLatency: OutputLatencyMonitor? = nil
    ) {
        self.outputLatency = outputLatency
        self.media = media
        self.library = library
        self.isEnabled = isEnabled
        // Default false, so a coordinator built without an opinion — every
        // existing test — never reaches the network.
        self.isOnlineEnabled = isOnlineEnabled
        self.presentation = presentation
        self.onlineCache = onlineCache ?? OnlineLyricsCache()
        self.onlineLookUp = onlineLookUp
        outputLatency?.onChange = { [weak self] seconds in self?.outputLatencyChanged(seconds) }
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
        outputLatency?.stop()
        logicalTrackKey = nil
        currentIdentity = nil
        onlineTimeline = nil
        lookUpGeneration += 1
        lookUpTask?.cancel()
        lookUpTask = nil
        admitWaitTask?.cancel()
        admitWaitTask = nil
        cancelNoLengthWait()
        resetRetries()
        localLookup = nil
        hasLocalOverride = false
        presentation?.presentLocalOverride(false)
        availability = .disabled
        presentation?.present(.disabled)
    }

    private func cancelNoLengthWait() {
        noLengthTask?.cancel()
        noLengthTask = nil
        noLengthKey = nil
    }

    private func resetRetries() {
        onlineFailed = false
        retryAttempt = 0
        retryTask?.cancel()
        retryTask = nil
    }

    /// Asks again after the next delay, if one is left and the song has not
    /// changed in the meantime.
    private func scheduleRetry(for identity: LocalTrackIdentity, generation: Int) {
        guard retryAttempt < Self.retryDelays.count else { return }
        let delay = Self.retryDelays[retryAttempt]
        retryAttempt += 1
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.lookUpGeneration == generation else { return }
            self.lookUpOnlineIfNeeded(for: identity)
        }
    }

    func refreshVisibility() {
        reconcileTrack(track: media.track, duration: media.duration, force: true)
        media.refreshPrecisionSync()
    }

    /// Ask again, including the network. A remembered miss is forgotten first,
    /// so Retry means retry rather than "show me the same no".
    func retry() {
        onlineTimeline = nil
        if let currentIdentity { onlineCache.forget(currentIdentity) }
        recheckCurrentTrack()
    }

    /// Imports a file for the song that was playing when Import was pressed.
    ///
    /// `identity` is taken by the caller before the open panel runs, not read
    /// here after it returns. It used to be `currentIdentity` at this point:
    /// browsing for a file through a track change bound the next song to
    /// this one's words for good (G-013). With nothing playing when Import
    /// was pressed, the file is kept unbound and matches by its own tags —
    /// it used to be dropped without a word.
    func importLocalFile(at url: URL, for identity: LocalTrackIdentity?) throws {
        _ = try library.importDocument(at: url, binding: identity)
        syncLocalOverride()
    }

    func selectLocalCandidate(_ candidate: LocalLyricsCandidate) {
        guard let currentIdentity else { return }
        library.bind(candidate, to: currentIdentity)
        syncLocalOverride()
    }

    func removeLocalBinding() {
        guard let currentIdentity else { return }
        library.removeBinding(for: currentIdentity)
        syncLocalOverride()
    }

    /// Reads whether the track on screen is bound from the library itself.
    ///
    /// Remove Local Binding is drawn from this flag, and it used to be a
    /// session's memory: set by an import or a choice made since launch,
    /// cleared by every track change. Skip away and back, or relaunch, and a
    /// song still bound to its file had no way to unbind it from the page —
    /// only Settings' Clear Bindings and Timing Corrections, which takes every
    /// binding with it.
    /// The saved binding is the truth, so it is asked on every resolve.
    private func syncLocalOverride() {
        let bound = currentIdentity.map { library.hasBinding(for: $0) } ?? false
        if hasLocalOverride != bound { hasLocalOverride = bound }
        if presentation?.hasLocalOverride != bound { presentation?.presentLocalOverride(bound) }
    }

    private func reconcileTrack(
        track: MediaController.Track?, duration: TimeInterval, force: Bool = false
    ) {
        syncOutputLatencyWatch()
        // Three different answers, which this guard used to fold into one:
        // off, nothing to search for, and no length to identify a recording
        // by. Folded, a stream said "Lyrics are off." with the switch on.
        guard isEnabled(), let track else {
            cancelNoLengthWait()
            forgetTrack()
            publishUnidentified(.disabled)
            return
        }
        guard !track.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            cancelNoLengthWait()
            forgetTrack()
            publishUnidentified(.cannotLookUp(.noTitle))
            return
        }
        guard duration > 0 else {
            awaitLength(of: track)
            return
        }
        // A length arrived, inside the grace or long after it: this is a
        // track like any other now, and the durationMoved check below sees a
        // new identity because the wait kept none.
        cancelNoLengthWait()

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
        lookUpTask?.cancel()
        lookUpTask = nil
        resetRetries()
        waitIsWorthAdmitting = false
        currentIdentity = LocalTrackIdentity(
            playerID: media.lyricPlayerID,
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: duration,
            recordingID: nil
        )
        if let currentIdentity { presentation?.activateTrackOffset(for: currentIdentity) }
        resolveCurrentTrack()
    }

    /// Drops the identified track and everything asked on its behalf.
    ///
    /// The generation is bumped so a lookup, retry or admit-wait still in
    /// flight for the song before cannot land on top of the state published
    /// here. The old guard never cancelled them, which was harmless while it
    /// only ever published "off"; now a stale answer would reach
    /// `publishAvailability` with no identity and overwrite "live audio" with
    /// "off".
    private func forgetTrack() {
        logicalTrackKey = nil
        currentIdentity = nil
        localLookup = nil
        onlineTimeline = nil
        lookUpGeneration += 1
        lookUpTask?.cancel()
        lookUpTask = nil
        admitWaitTask?.cancel()
        admitWaitTask = nil
        resetRetries()
        hasLocalOverride = false
        presentation?.presentLocalOverride(false)
    }

    /// A state with no track identity behind it: nothing to look up, so no
    /// line boundaries for the clock either. The old guard left the previous
    /// song's boundaries armed, waking the surfaces on its line times while a
    /// stream played.
    private func publishUnidentified(_ state: LyricsAvailability) {
        availability = state
        presentation?.present(state)
        media.setLyricBoundaries([], lead: { 0 })
    }

    /// Holds a track with no length quiet for `noLengthGrace`, then calls it
    /// live audio. Repeated updates for the same track keep the clock running
    /// rather than restart it; a length arriving cancels it in `reconcileTrack`.
    private func awaitLength(of track: MediaController.Track) {
        forgetTrack()
        guard noLengthKey != track.key else { return }
        noLengthTask?.cancel()
        noLengthKey = track.key
        publishUnidentified(.resolving)
        let key = track.key
        let grace = Self.noLengthGrace
        noLengthTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(grace))
            guard !Task.isCancelled, let self, self.noLengthKey == key else { return }
            self.publishUnidentified(.cannotLookUp(.noLength))
        }
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
        // After the lookup, which prunes a binding whose document is gone.
        syncLocalOverride()
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
            if remembered != nil, onlineCache.needsRefresh(identity) { refreshOldHit(identity) }
            return
        }
        let generation = lookUpGeneration
        lookUpTask?.cancel()
        lookUpTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.onlineLookUp(identity)
            guard !Task.isCancelled, self.lookUpGeneration == generation else { return }
            self.onlineCache.remember(outcome, for: identity)
            if case .found(let timeline) = outcome { self.onlineTimeline = timeline }
            self.onlineFailed = outcome == .failed
            if outcome == .failed { self.scheduleRetry(for: identity, generation: generation) }
            self.publishAvailability()
        }
        // And start the clock on admitting to the wait, if it becomes one.
        admitWaitTask?.cancel()
        admitWaitTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.quietGrace))
            guard !Task.isCancelled, let self, self.lookUpGeneration == generation else { return }
            self.waitIsWorthAdmitting = true
            self.publishAvailability()
        }
    }

    /// Asks once more about a hit cached before lines carried their ends,
    /// while that hit is already on screen.
    ///
    /// Without this, every song looked up before 2026-10-11 kept its lines
    /// lit through each instrumental for as long as the cache held it — the
    /// stale highlight line ends exist to remove. Dropping those hits instead
    /// would blank the stage until the network answered. So the old words
    /// show at once, the same four fields go to the same service the
    /// listener already turned on, and only a found answer replaces them; any
    /// other answer is settled in the cache (`OnlineLyricsCache.remember`) so
    /// the song is not asked about again. Quiet throughout: no wait to admit,
    /// no retry schedule, and a failure leaves the old words up and asks on
    /// the song's next play. A skip cancels it like any other lookup.
    private func refreshOldHit(_ identity: LocalTrackIdentity) {
        let generation = lookUpGeneration
        lookUpTask?.cancel()
        lookUpTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.onlineLookUp(identity)
            guard !Task.isCancelled, self.lookUpGeneration == generation else { return }
            self.onlineCache.remember(outcome, for: identity)
            guard case .found(let timeline) = outcome else { return }
            self.onlineTimeline = timeline
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
                // Quiet at first: an answer landing inside the grace never
                // draws a loading state at all.
                // A lookup that could not reach the catalogue reads as a
                // miss while the retry waits, not as a spinner that never ends.
                availability = onlineCache.cached(identity) == nil && !onlineFailed
                    ? (waitIsWorthAdmitting ? .findingLocalLyrics : .resolving)
                    : .noLocalLyrics
            } else {
                availability = .noLocalLyrics
            }
        case .ambiguous: availability = .noLocalLyrics
        case nil: availability = waitIsWorthAdmitting ? .findingLocalLyrics : .resolving
        }
        // The store has to know which file is showing, not just which song:
        // a nudge belongs to the file it corrected (J-024). This is where a
        // file first shows, and where an import, a binding, a retimed edit or
        // the catalogue's answer replaces it, so the file is told here — and
        // before the words are presented, so they never draw for one frame
        // with the last file's correction.
        if case .ready(let timeline) = availability {
            presentation?.activateTrackOffset(for: identity, documentID: timeline.documentID)
        }
        presentation?.present(availability)
        registerBoundaries()
    }

    /// Runs the output-latency watch exactly while Show Lyrics is on and the
    /// coordinator is started. Every visibility change and every track change
    /// pass through `reconcileTrack`, which calls this first, so the switch in
    /// Settings, the lyrics page's own "Show Lyrics" and a Shortcut all reach
    /// it. Turning lyrics off removes the CoreAudio listener rather than
    /// leaving it to wake for a lead nothing reads.
    private func syncOutputLatencyWatch() {
        guard let outputLatency else { return }
        if isEnabled(), !observers.isEmpty {
            outputLatency.start()
        } else {
            outputLatency.stop()
        }
    }

    /// The default output moved, and with it the route's reported latency.
    ///
    /// The number goes into the lead model, where the DI_MEDIA trail records
    /// it with every other term — that line is what the owner's S-LEAD
    /// session reads off each route. While the term is not applied
    /// (`LyricLeadModel.appliesOutputLatency`) the lead does not move, and
    /// nothing else happens. Once it is, a changed lead must re-register the
    /// boundaries: the wake already armed was computed with the old lead and
    /// would turn the next line early or late by the difference, once.
    private func outputLatencyChanged(_ seconds: TimeInterval?) {
        let before = LyricSweep.model.lead
        LyricSweep.model.outputLatency = seconds ?? LyricLeadModel.referenceOutputLatency
        if DebugTrail.openLyrics || DebugTrail.media {
            let reported = seconds.map { String(format: "%.1f ms", $0 * 1000) } ?? "unknown"
            DebugTrail.note("output latency \(reported); \(LyricSweep.model.trail)")
        }
        if LyricSweep.model.lead != before { registerBoundaries() }
    }

    /// Hands the clock every line's timestamp, so it can wake the surfaces on
    /// the frame a line is due instead of on its quarter-second grid. The lead
    /// is read at each wake, so a nudge takes effect on the next one.
    ///
    /// A line going dark at its honoured end is a change of line too, so
    /// those ends are boundaries beside the starts. Without them the line
    /// went dark on the next quarter-second tick, up to 250 ms after the
    /// voice — the same random lateness the wakes exist to remove.
    private func registerBoundaries() {
        guard case .ready(let timeline) = availability else {
            media.setLyricBoundaries([], lead: { 0 })
            return
        }
        let media = self.media
        let presentation = self.presentation
        let lines = timeline.lines
        let ends = lines.indices.compactMap { LyricSweep.effectiveEnd(of: $0, in: lines) }
        media.setLyricBoundaries(lines.map(\.at) + ends) {
            LyricSweep.lead(
                precisionSync: media.precisionSync,
                userOffset: presentation?.userOffset ?? 0,
                trackOffset: presentation?.trackOffset ?? 0
            )
        }
    }
}
