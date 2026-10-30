import AppKit
import Combine

/// What every surface draws of the song: one value, swapped once per song.
///
/// Owner, 2026-10-25, after a skip: "the contents are loading and they are not
/// even consistent — they should load at once, all with a clean smooth
/// animation that shouldn't feel like it was loading at all". Isla cannot make
/// the other app report faster; it can make the picture change once. A skip
/// reached the surfaces as up to five separate events — the title, the length,
/// the cover (after a 180 ms blank), the cover's tint, the lyrics — and each
/// surface animated whichever it was handed, so the island, the player, the
/// stage and the lock card each showed the new title over the old cover, then
/// over the placeholder, then the new cover, with the equalizer recolouring as
/// a third step and the artist jumping rows twice.
///
/// This is the one seam between `MediaController`'s readings, which say what
/// is true the moment it is known, and what is drawn. While a song is leaving
/// (the **hold**) the previous song stays on screen, its clock still; the next
/// song is swapped in, title, artist, cover, tint and length together, as soon
/// as its title and its own cover are in — or a cover carried from the same
/// album — and lyrics that are already settled come with it. Never longer than
/// `swapDeadline` after the new title, nor `holdCap` after the hold began.
///
/// The hold starts at Isla's own Next or Previous, at Spotify announcing
/// another song, or at the first report naming a new one; never for a restart,
/// the first song, or nothing playing, which swap at once. A skip during the
/// hold follows the newest song: the one in between is never drawn.
@MainActor
final class NowPlayingPresenter: ObservableObject {
    /// The song as the surfaces draw it.
    struct Presented: Equatable {
        var track: MediaController.Track
        /// The song's own cover, or nil for the placeholder. Never another
        /// song's: a cover still decoding when the deadline passes swaps in as
        /// the placeholder and fades in under the same key when it lands.
        var artwork: NSImage?
        var tint: CoverTint
        var duration: TimeInterval
        var sourceIcon: NSImage?
        /// Whether this song's lyrics arrived after it was swapped in. The
        /// player then turns only its subtitle to the sung line, rather than
        /// moving the artist up into the title row as well — the second of the
        /// two jumps a skip used to make (`MediaPane.titleRow`).
        var lyricsCameLate = false

        var key: String { track.key }

        static func == (lhs: Presented, rhs: Presented) -> Bool {
            lhs.track == rhs.track && lhs.artwork === rhs.artwork && lhs.tint == rhs.tint
                && lhs.duration == rhs.duration && lhs.sourceIcon === rhs.sourceIcon
                && lhs.lyricsCameLate == rhs.lyricsCameLate
        }
    }

    /// The clock of the song still drawn during a hold. Its position stops
    /// where it was when the hold began: the next song's 0:00 under the old
    /// title, or the old song's lines resolved at the new one's position, is
    /// exactly the inconsistency this type exists to remove.
    struct HeldClock: Equatable {
        var position: TimeInterval
        var isPlaying: Bool
    }

    /// Everything a surface needs from here, as a value a view can be handed
    /// and compared.
    struct Frame: Equatable {
        var presented: Presented?
        var held: HeldClock?
    }

    @Published private(set) var presented: Presented?
    /// Set only while a hold stands.
    @Published private(set) var held: HeldClock?

    var frame: Frame { Frame(presented: presented, held: held) }
    var isHolding: Bool { hold != nil }

    /// How long after the new song's title its cover is waited for. A skip's
    /// cover usually lands 20 to 70 ms behind its title (measured 2026-09-21)
    /// and a slow one in a few hundred; past this the song is swapped in with
    /// the placeholder rather than the old song staying up any longer.
    static var swapDeadline: TimeInterval = 0.35
    /// The longest a hold lasts from the moment it began, however many titles
    /// arrive in it: a run of skips cannot keep the old song up forever, and a
    /// Next with nothing after it lets the clock run again.
    static var holdCap: TimeInterval = 0.7

    private struct Hold {
        var startedAt: TimeInterval
        /// The newest song reported during the hold, and when it was.
        var titleKey: String?
        var titleAt: TimeInterval?
    }

    private var hold: Hold?
    private var live = MediaController.Reading()
    /// The instant a wake is already armed for, so a run of readings does not
    /// queue a wake per reading.
    private var armedFor: TimeInterval?
    /// Whether the song on screen came in through a hold, and whether its
    /// lyrics were ready then: what decides `lyricsCameLate`.
    private var swappedFromHold = false
    private var lyricsReadyAtSwap = false
    /// Covers whose tint is being read, so each is read once.
    private var resolvingTint: Set<ObjectIdentifier> = []

    private let now: () -> TimeInterval
    private let schedule: (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void
    private let clock: () -> HeldClock
    private let cachedTint: (NSImage?) -> CoverTint?
    private let resolveTint: (NSImage) async -> CoverTint
    private let lyricsReady: () -> Bool
    private let holdLyrics: (Bool) -> Void
    private var cancellables = Set<AnyCancellable>()

    /// Every collaborator is a closure, so a test drives the hold with its own
    /// clock and wakes and never waits on a real one — the same seam
    /// `MediaController.trackChangeGrace` and `monotonicNow` give its tests.
    init(
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        schedule: @escaping (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void = { delay, wake in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(max(delay, 0)))
                wake()
            }
        },
        clock: @escaping () -> HeldClock = { HeldClock(position: 0, isPlaying: false) },
        cachedTint: @escaping (NSImage?) -> CoverTint? = { CoverTint.cachedTint(for: $0) },
        resolveTint: @escaping (NSImage) async -> CoverTint = { await CoverTint.resolve($0) },
        lyricsReady: @escaping () -> Bool = { false },
        holdLyrics: @escaping (Bool) -> Void = { _ in }
    ) {
        self.now = now
        self.schedule = schedule
        self.clock = clock
        self.cachedTint = cachedTint
        self.resolveTint = resolveTint
        self.lyricsReady = lyricsReady
        self.holdLyrics = holdLyrics
    }

    /// The panel's presenter: fed by the controller and gating the store.
    static func live(media: MediaController, lyrics: LyricsStore) -> NowPlayingPresenter {
        // The store belongs to the session and outlives the panel; a presenter
        // does not. A display change rebuilds the panel, and one rebuilt in the
        // middle of a hold dropped the presenter that would have released it —
        // its wake holds it weakly — so every later answer stayed buffered
        // until some other skip happened to end a hold (Codex review,
        // 2026-10-25). A new presenter starts without a hold, so the store
        // starts without one too.
        lyrics.releasePresentation()
        let presenter = NowPlayingPresenter(
            clock: { [weak media] in
                HeldClock(position: media?.extrapolatedPosition() ?? 0, isPlaying: media?.isPlaying ?? false)
            },
            lyricsReady: { [weak lyrics] in
                if case .ready = lyrics?.pendingAvailability { return true }
                return false
            },
            holdLyrics: { [weak lyrics] holding in
                if holding { lyrics?.holdPresentation() } else { lyrics?.releasePresentation() }
            }
        )
        presenter.connect(media: media, lyrics: lyrics)
        return presenter
    }

    private func connect(media: MediaController, lyrics: LyricsStore) {
        // Before the report is applied: `$track` announces before it stores,
        // and `apply` writes the track before it adopts the new song's
        // position, so the clock read here is still the leaving song's.
        media.$track.map { $0?.key }.removeDuplicates()
            .sink { [weak self] key in self?.trackWillChange(to: key) }
            .store(in: &cancellables)
        media.trackChangeExpected
            .sink { [weak self] in self?.expectTrackChange() }
            .store(in: &cancellables)
        media.$reading
            .sink { [weak self] reading in self?.receive(reading) }
            .store(in: &cancellables)
        lyrics.$availability
            .map { availability -> Bool in
                if case .ready = availability { return true }
                return false
            }
            .removeDuplicates()
            .sink { [weak self] ready in self?.lyricsChanged(ready: ready) }
            .store(in: &cancellables)
    }

    // MARK: - Inputs

    /// Another song is on its way: Isla's own skip, or Spotify naming one.
    func expectTrackChange() {
        guard presented != nil else { return }
        beginHold()
        evaluate()
    }

    /// The controller is about to name `key`: a hold, unless it is the song
    /// already drawn, the first song, or nothing.
    func trackWillChange(to key: String?) {
        guard let key, let shown = presented, shown.key != key else { return }
        beginHold()
    }

    func receive(_ reading: MediaController.Reading) {
        live = reading
        evaluate()
    }

    /// The store's words became ready, or stopped being.
    func lyricsChanged(ready: Bool) {
        guard ready, hold == nil, swappedFromHold, !lyricsReadyAtSwap,
              var shown = presented, !shown.lyricsCameLate else { return }
        shown.lyricsCameLate = true
        presented = shown
    }

    // MARK: - The hold

    private func beginHold() {
        guard hold == nil, presented != nil else { return }
        let start = now()
        hold = Hold(startedAt: start)
        held = clock()
        holdLyrics(true)
        arm(at: start + Self.holdCap)
    }

    private func endHold() {
        guard hold != nil else { return }
        hold = nil
        held = nil
        armedFor = nil
        holdLyrics(false)
    }

    private func evaluate() {
        guard let track = live.track else {
            // Nothing playing is said at once: there is nothing to wait for.
            endHold()
            if presented != nil { presented = nil }
            return
        }
        guard let shown = presented else {
            // The first song is drawn at once; its cover fades in when it lands.
            swappedFromHold = false
            presented = make(from: live)
            return
        }
        guard var current = hold else {
            if track.key != shown.key {
                // A new song with no hold before it: its first report.
                beginHold()
                evaluate()
            } else {
                follow(live)
            }
            return
        }
        let moment = now()
        if track.key == shown.key {
            // Nothing new yet. A Next with no song after it, or an
            // announcement that came to nothing, gives the clock back; so
            // does a report coming back to the song on screen after naming
            // another (A → B → A inside the hold), at once, since the song
            // being waited for is the one already drawn.
            if moment - current.startedAt >= Self.holdCap || current.titleKey != nil {
                endHold()
                follow(live)
            }
            return
        }
        if current.titleKey != track.key {
            // The newest song is the one waited for: on A → B → C, B's cover
            // is never what the swap waits on, and B is never drawn.
            current.titleKey = track.key
            current.titleAt = moment
            hold = current
        }
        let deadline = min((current.titleAt ?? moment) + Self.swapDeadline, current.startedAt + Self.holdCap)
        if coverReady(live) || moment >= deadline {
            swap(to: live)
        } else {
            requestTint(for: live)
            arm(at: deadline)
        }
    }

    /// The same song, updated where it stands: its cover landing late, its
    /// tint read, its length corrected.
    private func follow(_ reading: MediaController.Reading) {
        guard var shown = presented, let track = reading.track, track.key == shown.key else { return }
        shown.track = track
        let cover = reading.hasCover ? reading.artwork : nil
        shown.artwork = cover
        shown.tint = tint(for: cover) ?? (cover == nil ? .fallback : shown.tint)
        shown.duration = reading.duration
        shown.sourceIcon = reading.sourceIcon
        if shown != presented { presented = shown }
        if let cover, tint(for: cover) == nil { requestTint(for: reading) }
    }

    private func swap(to reading: MediaController.Reading) {
        swappedFromHold = true
        lyricsReadyAtSwap = lyricsReady()
        // The value first, then the words, in one turn: SwiftUI draws both in
        // the same frame.
        presented = make(from: reading)
        endHold()
    }

    private func make(from reading: MediaController.Reading) -> Presented? {
        guard let track = reading.track else { return nil }
        let cover = reading.hasCover ? reading.artwork : nil
        if cover != nil, tint(for: cover) == nil { requestTint(for: reading) }
        return Presented(
            track: track, artwork: cover, tint: tint(for: cover) ?? .fallback,
            duration: reading.duration, sourceIcon: reading.sourceIcon
        )
    }

    /// The song's cover is in, with its tint, so the equalizer recolours in
    /// the same swap rather than as a step after it.
    private func coverReady(_ reading: MediaController.Reading) -> Bool {
        guard reading.hasCover, let cover = reading.artwork else { return false }
        return tint(for: cover) != nil
    }

    private func tint(for cover: NSImage?) -> CoverTint? {
        guard let cover else { return .fallback }
        return cachedTint(cover)
    }

    private func requestTint(for reading: MediaController.Reading) {
        guard reading.hasCover, let cover = reading.artwork, cachedTint(cover) == nil else { return }
        let id = ObjectIdentifier(cover)
        guard resolvingTint.insert(id).inserted else { return }
        Task { [weak self] in
            _ = await self?.resolveTint(cover)
            guard let self else { return }
            self.resolvingTint.remove(id)
            self.evaluate()
        }
    }

    private func arm(at instant: TimeInterval) {
        if let armedFor, armedFor <= instant, armedFor > now() { return }
        armedFor = instant
        schedule(max(instant - now(), 0)) { [weak self] in
            guard let self else { return }
            if self.armedFor == instant { self.armedFor = nil }
            self.evaluate()
        }
    }
}

/// The song and the clock as a surface draws them under a frame, or — with no
/// frame, as every surface built outside the panel is (a render, a lab, a
/// test) — exactly as the controller reports them, which is what they all drew
/// before the presenter existed.
extension MediaController {
    func shownTrack(_ frame: NowPlayingPresenter.Frame?) -> Track? {
        guard let frame else { return track }
        return frame.presented?.track
    }

    func shownArtwork(_ frame: NowPlayingPresenter.Frame?) -> NSImage? {
        guard let frame else { return artwork }
        return frame.presented?.artwork
    }

    func shownDuration(_ frame: NowPlayingPresenter.Frame?) -> TimeInterval {
        frame?.presented?.duration ?? duration
    }

    func shownSourceIcon(_ frame: NowPlayingPresenter.Frame?) -> NSImage? {
        guard let frame else { return sourceIcon }
        return frame.presented?.sourceIcon
    }

    /// The clock: held still during a hold, live otherwise.
    func shownPosition(_ frame: NowPlayingPresenter.Frame?) -> TimeInterval {
        frame?.held?.position ?? position
    }

    func shownLabelPosition(_ frame: NowPlayingPresenter.Frame?) -> TimeInterval {
        frame?.held?.position ?? labelPosition
    }

    /// Where the sung line reads the song: the held song's stop during a
    /// hold, the clock's line reading otherwise (`PlaybackClock.linePosition`),
    /// which moves only when the line can turn — but only while the surface
    /// reads with the `lead` the reading was kept against. Between a delay's
    /// change and the clock's next tick the position is the honest answer,
    /// and costs that one tick.
    func shownLinePosition(_ frame: NowPlayingPresenter.Frame?, lead: TimeInterval) -> TimeInterval {
        if let held = frame?.held { return held.position }
        return clock.lineLead == lead ? clock.linePosition : position
    }

    /// The labels' whole seconds: the clock's own while the panel shows the
    /// live song, which change only when a label's text does
    /// (`PlaybackClock.seconds`); worked out from the held song otherwise.
    func shownSeconds(_ frame: NowPlayingPresenter.Frame?) -> PlaybackClock.Seconds {
        let duration = shownDuration(frame)
        guard frame?.held == nil, duration == self.duration else {
            return .init(shown: min(shownLabelPosition(frame), duration), duration: duration)
        }
        return clock.seconds
    }

    /// How the bar moves: still where the held song stopped during a hold,
    /// the clock's motion otherwise (`PlaybackClock.motion`).
    func shownMotion(_ frame: NowPlayingPresenter.Frame?) -> PlaybackClock.Motion {
        if let held = frame?.held { return .still(held.position) }
        return clock.motion
    }

    func shownIsPlaying(_ frame: NowPlayingPresenter.Frame?) -> Bool {
        frame?.held?.isPlaying ?? isPlaying
    }
}
