import AppKit
import Combine

/// Now Playing for whatever the system is playing — browser tabs included.
///
/// Primary source is `NowPlayingFeed`, which reaches MediaRemote through a
/// helper hosted by `/usr/bin/perl`. If that route ever closes, the controller
/// falls back to scripting Apple Music and Spotify directly.
@MainActor
final class MediaController: ObservableObject {
    struct Track: Equatable {
        var title: String
        var artist: String
        var album: String
        var key: String
    }

    @Published var track: Track? {
        didSet {
            publishReadingUnlessBatched()
            publishClockReadings()
        }
    }
    @Published var artwork: NSImage? {
        didSet {
            // A picture taken away belongs to nobody; one put up is owned by
            // whoever put it up (`coverKey`), which every writer sets first.
            if artwork == nil { coverKey = nil }
            publishReadingUnlessBatched()
        }
    }
    @Published var isPlaying = false {
        didSet { publishClockReadings() }
    }
    @Published var duration: TimeInterval = 0 {
        didSet {
            publishReadingUnlessBatched()
            publishClockReadings()
        }
    }

    /// What one report says about the song, published once per report rather
    /// than field by field.
    ///
    /// `track`, `duration` and `artwork` are each `@Published`, and a skip used
    /// to reach subscribers as three separate events: the new title paired
    /// with the old song's length, then the length, then — up to 180 ms later —
    /// the cover (owner, 2026-10-25: "the contents are loading and they are
    /// not even consistent"). The lyrics coordinator rebuilt its identity on
    /// the first event and again on the second, so every skip asked for the
    /// new song's words twice, once with the wrong length. This is the same
    /// facts, assigned at the end of `apply` and `clear` with everything in
    /// place, so a subscriber sees one consistent reading per report. The
    /// coordinator and `NowPlayingPresenter` read it; the fields stay for
    /// everything that only needs one of them.
    struct Reading: Equatable {
        var track: Track?
        var duration: TimeInterval = 0
        var artwork: NSImage?
        /// The track `artwork` was decoded, fetched or carried for. On a skip
        /// the previous cover can still be up while the new one decodes, and
        /// only this says whether the picture is the new song's yet.
        var coverKey: String?
        var sourceIcon: NSImage?

        /// Whether the song's own cover is in: a picture, put up for it.
        var hasCover: Bool { artwork != nil && coverKey != nil && coverKey == track?.key }

        static func == (lhs: Reading, rhs: Reading) -> Bool {
            lhs.track == rhs.track && lhs.duration == rhs.duration && lhs.artwork === rhs.artwork
                && lhs.coverKey == rhs.coverKey && lhs.sourceIcon === rhs.sourceIcon
        }
    }
    @Published private(set) var reading = Reading()
    /// The track the cover on show belongs to. See `Reading.coverKey`.
    var coverKey: String? {
        didSet { publishReadingUnlessBatched() }
    }
    /// Above zero while `apply` or `clear` is mid-way: their writes land as one
    /// reading when the outermost one finishes.
    private var readingBatchDepth = 0

    private func publishReadingUnlessBatched() {
        guard readingBatchDepth == 0 else { return }
        let fresh = Reading(
            track: track, duration: duration, artwork: artwork, coverKey: coverKey, sourceIcon: sourceIcon
        )
        // `@Published` never compares; an identical reading every two-second
        // poll would wake every subscriber for nothing.
        if fresh != reading { reading = fresh }
    }

    func batchingReading<T>(_ body: () -> T) -> T {
        readingBatchDepth += 1
        defer {
            readingBatchDepth -= 1
            publishReadingUnlessBatched()
        }
        return body()
    }

    /// Isla is about to see another song: its own Next or Previous (not a
    /// restart), or Spotify announcing a different song before any report
    /// names it. `NowPlayingPresenter` starts its hold on this, so the song on
    /// screen stays drawn, still, rather than wearing the next one's 0:00.
    let trackChangeExpected = PassthroughSubject<Void, Never>()
    /// A play or pause tap, carrying the state it asked for. The presenter
    /// keeps the play button's state still while a skipped song is leaving
    /// (`NowPlayingPresenter.HeldClock`), and without this a tap made in that
    /// window changed nothing on screen until the next song was swapped in.
    let playbackTapped = PassthroughSubject<Bool, Never>()
    /// Where the position lives: on `clock`, which only the views that read
    /// it observe, so a tick does not announce a change of the whole
    /// controller (`PlaybackClock`). An unchanged value is not set again, so a
    /// frozen anchor redraws nothing.
    let clock = PlaybackClock()
    var position: TimeInterval {
        get { clock.position }
        set {
            if clock.position != newValue { clock.position = newValue }
            holdLabelSecond()
            publishClockReadings()
        }
    }

    /// The whole second the elapsed label last showed, and for which song.
    private var shownSecond: (key: String, second: Int)?

    /// The elapsed time a label shows: the position, except that while playing
    /// it never steps back a second for a correction under a second and a half.
    ///
    /// Filmed on 2026-09-21: 0:51, then 0:50, a quarter-second after a seek
    /// landed — the clock had run on from the target while the player was
    /// still resuming, and the correction pulled it back across a second.
    /// The bar and the lyrics keep the exact position; only the numerals, the
    /// one thing that reads as the clock running backwards, hold.
    var labelPosition: TimeInterval {
        guard let shown = shownSecond, shown.key == track?.key, isPlaying,
              Double(shown.second) > position.rounded(),
              Double(shown.second) - position < 1.5 else { return position }
        return Double(shown.second)
    }

    /// The clock's coarse readings (`PlaybackClock.seconds`, `.motion`), set
    /// only when they change: what the labels show and how the bar moves are
    /// worked out on every tick, and published on the few that change them.
    /// Called wherever an input to either changes — the position, the anchor,
    /// the rate, playing, the length and the song — so none can be missed.
    ///
    /// `linesChanged` is `setLyricBoundaries`', whose new lines turn on
    /// boundaries the reading was not kept against.
    func publishClockReadings(linesChanged: Bool = false) {
        let seconds = PlaybackClock.Seconds(shown: min(labelPosition, duration), duration: duration)
        if clock.seconds != seconds { clock.seconds = seconds }
        let motion: PlaybackClock.Motion = songClock.map { .moving($0) } ?? .still(position)
        // A stop, or a seek while stopped, re-stamps the line's reading: a
        // paused word sweep is drawn at it. A correction while playing need
        // not, since the boundary check below already keeps the reading on
        // the line the clock is on, and the moving sweep's edge reads
        // `motion` itself; re-stamping on every re-anchor would re-run the
        // line at the player's report rate.
        var stopped = false
        if clock.motion != motion {
            clock.motion = motion
            if case .still = motion { stopped = true }
        }
        let lead = lyricLead()
        let line = Self.linePosition(
            position: position, published: clock.linePosition, boundaries: lyricBoundaries,
            lead: lead, turned: stopped || linesChanged
        )
        if clock.linePosition != line { clock.linePosition = line }
        if clock.lineLead != lead { clock.lineLead = lead }
    }

    /// The sung line's reading of the clock (`PlaybackClock.linePosition`):
    /// the one already `published` while `position` is on the same side of
    /// every boundary, the position itself once it crosses one, once `turned`
    /// (the clock stopped, or new boundaries came), or when there are no
    /// boundaries to keep it against.
    ///
    /// The lead is the one asked now, for both readings, so a reading kept
    /// under the last lead is kept only if it still names the line the
    /// position does under this one.
    nonisolated static func linePosition(
        position: TimeInterval, published: TimeInterval, boundaries: [TimeInterval],
        lead: TimeInterval, turned: Bool
    ) -> TimeInterval {
        guard !turned, !boundaries.isEmpty else { return position }
        let same = boundariesReached(boundaries, at: position + lead)
            == boundariesReached(boundaries, at: published + lead)
        return same ? published : position
    }

    /// How many of the sorted `boundaries` the lyric moment `at` has reached.
    /// Reached means `boundary <= at`, the comparison every lyric rule makes
    /// (`LyricSweep.index`, `moment`'s honoured end, `readingMoment`), so two
    /// moments with one count draw one caption.
    nonisolated static func boundariesReached(_ boundaries: [TimeInterval], at: TimeInterval) -> Int {
        var low = 0, high = boundaries.count
        while low < high {
            let mid = (low + high) / 2
            if boundaries[mid] <= at { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private func holdLabelSecond() {
        guard let key = track?.key else {
            shownSecond = nil
            return
        }
        let second = Int(position.rounded())
        if let shown = shownSecond, shown.key == key, isPlaying,
           second < shown.second, Double(shown.second) - position < 1.5 {
            return
        }
        shownSecond = (key, second)
    }
    @Published var sourceName: String?
    /// The icon of the app the sound is coming from.
    ///
    /// Taken from the running process rather than matched against a list of
    /// bundle identifiers we happen to know, so a browser tab, a podcast app or
    /// something nobody here has heard of all get their own icon for free — and
    /// none of them needs this app updated to be recognised.
    @Published var sourceIcon: NSImage? {
        didSet { publishReadingUnlessBatched() }
    }
    /// Whether the player accepts skipping at all. A browser tab playing one
    /// video registers no handler for it — the command leaves and nothing
    /// happens — so the buttons go dim rather than dead, the way the system's
    /// own Now Playing widget dims them for the same session. True until told
    /// otherwise: the scripted fallback below drives Music and Spotify, and
    /// both skip fine.
    @Published var canSkip = true
    /// Shuffle, when the displayed player can be asked. Nil hides the button
    /// rather than dimming it: unlike skipping — which every session at least
    /// conceptually has — shuffle simply does not exist for a browser tab.
    @Published var shuffleEnabled: Bool?
    /// Repeat, same contract.
    @Published var repeatMode: PlayerBridge.RepeatMode?
    /// Whether the displayed player has the full three repeat states.
    /// Spotify's scripting has only the boolean.
    @Published var supportsRepeatOne = false

    /// Why the app is on the Music-and-Spotify fallback, or nil while it
    /// reads Now Playing. Published so the Music tab and Settings can say it.
    /// The fallback used to be one log line and a pane reading "Nothing is
    /// playing." while a browser played.
    @Published var fallbackReason: NowPlayingRouteFailure?
    /// A retry is under way, and the fallback keeps working until it
    /// succeeds. See `retryNowPlaying`.
    var retryingNowPlaying = false

    let feed = NowPlayingFeed()
    var feedAvailable = true
    var displayedPlayerPID: pid_t?
    var playbackIntent = PlaybackIntent(reported: false)
    var reportedPlayback = ReportedPlayback()

    /// How long a non-playing stranger has to keep claiming the session
    /// before it is believed. Long enough to ride out window switching,
    /// short enough that a genuinely departed player does not leave a ghost.
    /// Internal so the tests can collapse it.
    var foreignHoldWindow: TimeInterval = 10
    /// When a non-playing session from another PID first tried to take the
    /// display from a session we are still showing.
    var foreignSince: Date?

    var activeApp: PlayerApp?
    var artworkKey: String?
    /// The pid `sourceIcon` was resolved for.
    var sourceIconPID: pid_t?
    /// Tracks the app has already asked the helper to resend a cover for.
    ///
    /// Once per track, because a session with genuinely no artwork — a browser
    /// tab, most podcasts — would otherwise be asked again on every snapshot,
    /// twice a second, forever.
    var artworkRequestedFor: Set<String> = []
    var anchor: (position: TimeInterval, atMono: TimeInterval)? {
        // A new anchor moves every boundary's wall time with it, and the bar's
        // motion.
        didSet {
            armBoundaryTimer()
            publishClockReadings()
        }
    }
    /// The clock the anchor extrapolates on. Wall time jumps on NTP steps and
    /// across sleep, and the anchor used to ride it — a +5s step teleported the
    /// bar and the lyric. `systemUptime` never jumps, so the extrapolation
    /// survives both. A seam, like `foreignHoldWindow`: tests freeze it while
    /// the wall runs on. `Date` stays only inside the 1.5s seek-verdict window,
    /// where what matters is ordering recent events, not measuring durations.
    var monotonicNow: () -> TimeInterval = SongClock.hostNow
    /// How fast the player says the track is moving. Podcast and video apps
    /// routinely play at 1.5× or 2×, and the ticker extrapolating at 1×
    /// regardless meant the bar fell behind between polls and lurched forward
    /// on each one; below 1× it ran ahead and was yanked back.
    ///
    /// A change re-anchors first, at where the old rate has carried the clock.
    /// The anchor stores a position and a moment, not a rate, so without that
    /// the new rate was applied backwards over every second since the anchor
    /// was set. Usually the snapshot carrying the new rate re-anchors anyway,
    /// but not when its position is not adopted — a seek still unconfirmed,
    /// precision sync steering, a stale or held reading — and then the next
    /// tick jumped (by 0.8s in the lab's L4, for a 1x → 2x change one second
    /// after a seek) and the lyric wake was armed seconds off. Doing it here
    /// rather than in each branch of `apply` that declines a position means a
    /// new branch cannot forget it.
    var playbackRate: Double = 1 {
        willSet {
            if newValue != playbackRate, isPlaying, anchor != nil {
                let nowMono = monotonicNow()
                anchor = (extrapolatedPosition(at: nowMono), nowMono)
            }
        }
        didSet {
            if playbackRate != oldValue { armBoundaryTimer() }
            publishClockReadings()
        }
    }

    /// Where the clock stands at `nowMono` (now, by default): the anchor run
    /// forward at the player's rate while playing, capped at the track's end;
    /// the published position otherwise. The one copy of that arithmetic —
    /// the tick, the rate change and the re-base all read it, and so should
    /// anything that needs the live position between ticks, because
    /// `position` is only as fresh as the last tick. Separate copies are how
    /// the lyric surfaces once came to disagree (see `LyricSweep`). Only the
    /// lyric wake runs its own, uncapped, and says why.
    func extrapolatedPosition(at nowMono: TimeInterval? = nil) -> TimeInterval {
        guard let songClock else { return position }
        return songClock.position(at: nowMono ?? monotonicNow())
    }

    /// The clock `extrapolatedPosition` reads, as a value: the anchor and the
    /// rate it runs at, capped at the track's end. Nil while the song is not
    /// moving. The word sweep hands it to Core Animation (`KaraokeTrack`).
    var songClock: SongClock? {
        guard isPlaying, let anchor else { return nil }
        return SongClock(
            position: anchor.position, atMono: anchor.atMono, rate: playbackRate, cap: duration > 0 ? duration : nil
        )
    }
    /// Where we asked the player to jump, when — and from where, because the
    /// pre-seek trajectory is the only thing that can unmask a reading taken
    /// after the seek was issued but before the player applied it.
    var pendingSeek: (target: TimeInterval, at: Date, origin: TimeInterval)?
    /// The last seek, kept past the pending window: Spotify's own broadcast
    /// can deliver a pre-seek position after the pending guard has cleared,
    /// and anchoring on it replays the jump backwards on screen. The origin
    /// travels along so only broadcasts shaped like the pre-seek trajectory
    /// are dropped — a genuine pause or track change right after a click
    /// still carries the millisecond-exact position and is kept.
    var lastSeek: (target: TimeInterval, at: Date, origin: TimeInterval)?

    /// What a position reading is worth while a seek is in flight.
    ///
    /// The old rule settled the seek whenever a reading landed within 2.5s of
    /// the target — but a correction already in flight when the user clicked
    /// returns the *pre-seek* position, and clicking a nearby lyric line put
    /// that stale value inside the window. It settled the seek, the monotonic
    /// rule read it as a real rewind, and the anchor was yanked back to where
    /// the track was before the click: every tap on a nearby line visibly
    /// bounced backwards. Time is the discriminator a value can never be —
    /// a reading whose round-trip began before the seek was issued describes
    /// the pre-seek world, whatever its value.
    enum SeekReadingVerdict: Equatable {
        /// Keep waiting: drop the reading, leave the seek pending.
        case discard
        /// The wait is over but the reading predates the seek: clear the
        /// pending state, use nothing from the reading.
        case settleIgnore
        /// The jump landed: clear the pending state, the reading is truth.
        case settleAdopt
    }

    static func judgeSeekReading(
        reading: TimeInterval,
        target: TimeInterval,
        issuedAt: Date,
        askedAt: Date,
        now: Date,
        origin: TimeInterval,
        rate: Double = 1
    ) -> SeekReadingVerdict {
        let expired = now.timeIntervalSince(issuedAt) > 1.5
        let postIssue = askedAt > issuedAt
        // Past the window the pending state must clear either way — left set
        // it disables corrections for the rest of the track — but a stale
        // reading still earns no say in where the anchor sits. (A reading that
        // still tracks the pre-seek trajectory after 1.5s means the player
        // refused or lost the jump, and then it is the truth — adopt it.)
        if expired { return postIssue ? .settleAdopt : .settleIgnore }
        guard postIssue else { return .discard }
        // Post-issue is necessary, not sufficient: the seek and the query
        // travel independent channels, so the query can reach the player
        // before the jump does. Being near the target proves nothing by
        // itself either — the pre-seek position keeps playing while the jump
        // is in flight, and on a short jump it drifts into the target window
        // looking exactly like a landing. What a pre-application reading
        // cannot fake is *leaving the old trajectory*: only a reading near
        // the target AND away from where the un-jumped track would be by now
        // proves the player moved.
        let phantom = origin + max(0, askedAt.timeIntervalSince(issuedAt)) * max(rate, 0)
        if abs(reading - phantom) < 0.6 { return .discard }
        return abs(reading - target) < 0.8 ? .settleAdopt : .discard
    }
    /// True while the position is being corrected against the player's own
    /// clock rather than MediaRemote's. The lyric lead reads this: with a
    /// precise position most of the compensation is unnecessary.
    @Published var precisionSync = false
    /// False from panel-open or track-change until the first authoritative
    /// reading lands: the position is an extrapolation from the anchor until
    /// then — usually right, wrong only if a pause or seek happened while the
    /// panel was shut and no broadcast reported it.
    ///
    /// No lyric surface waits on this any more. They did, and every open of
    /// the panel showed "Syncing playback…" for the 150ms a real fix takes and
    /// for the full 1.2s grace when none came — which read as lyrics that were
    /// slow, on every open, to cover a wrong line that almost never happened.
    /// The system's own lyrics show the line the clock points at and move it
    /// when a correction lands; so do these now. The flag stays as the clock's
    /// own statement of how much it trusts itself, for the tests and the trail.
    @Published var positionSettled = false

    // MARK: - Stored properties of MediaController+Sync.swift

    /// Track positions at which a lyric surface changes its line — every
    /// line's timestamp, before the lead — and how much lead the surfaces read
    /// with. Registered by `LyricsCoordinator` when a timeline is ready.
    ///
    /// The four-times-a-second ticker below moves the scrubber, and a scrubber
    /// does not care about 250ms. A lyric line does: on that grid a line lands
    /// anywhere from on time to a quarter-second late, at random, which is the
    /// "sometimes early, sometimes late" that no lead constant can fix. So the
    /// clock also wakes exactly when the next line is due — one one-shot timer,
    /// re-armed at every tick and every anchor change — and publishes the
    /// position on that frame, so every surface turns its line together and
    /// on the beat. Between boundaries nothing extra runs.
    var lyricBoundaries: [TimeInterval] = []
    var lyricLead: @MainActor () -> TimeInterval = { 0 }
    var boundaryTimer: DispatchSourceTimer?
    /// When the armed wake is due, on the wall clock. A dispatch source has no
    /// fire date to read back the way a `Timer` did, so it is recorded at the
    /// moment of arming from the same delay the source is scheduled with.
    var lyricWakeDate: Date?

    /// Called inside the wake's handler, right after the tick it ran.
    var onLyricWakeForTests: (@MainActor () -> Void)?

    private var settleWatchdog: Task<Void, Never>?
    /// Spotify's catalogue id for the displayed track, when Spotify is the
    /// displayed player and has answered. The word-synced lyrics database is
    /// keyed by it; everything else falls back to title/artist matching.
    @Published var spotifyTrackID: String?
    /// The catalogue ISRC for the displayed track, when the Web API has
    /// answered. Lyric tiers join providers on this instead of guessing from
    /// title text; nil means unknown, never "this track has none".
    @Published var spotifyISRC: String?
    /// The catalogue's exact duration in seconds, alongside the id
    /// above. The snapshot's own duration is the daemon's rounded reading;
    /// this is the number the duration-gated lyric matching compares against.
    @Published var spotifyExactDuration: TimeInterval?
    /// Answers exact catalogue metadata for a Spotify track id.
    ///
    /// A seam, not a second path: production leaves this nil and the lookup
    /// goes to `SpotifyAccount.shared` over the network. Tests substitute
    /// canned answers because the AppleScript id lookup that triggers the
    /// fetch never resolves without a running Spotify, and the fetch would
    /// otherwise be untestable. Internal so tests can reach it, like
    /// `foreignHoldWindow` above.
    var spotifyMetadataProvider: ((String) async -> SpotifyAccount.TrackMetadata?)?
    var precisionTimer: Timer?
    var precisionInFlight = false

    /// The last corrections as (monotonic moment, RTT-aged position), oldest
    /// first. Reset wherever the line discontinues — a pause lets the monotonic
    /// clock run while the position stands still, so origins from before it
    /// would drag the mean after the resume. A rate change is the same kind
    /// of discontinuity: old origins recomputed at the new rate lean the
    /// mean, so the window flushes there too. Internal so tests can pin the
    /// mid-window rate change, like `foreignHoldWindow` above.
    var correctionWindow: [(atMono: TimeInterval, position: TimeInterval)] = []
    /// The fetch behind a correction. Production asks Spotify over AppleScript;
    /// tests substitute canned answers, mirroring `spotifyMetadataProvider`.
    var precisionPositionFetcher: ((@escaping @MainActor (TimeInterval?) -> Void) -> Void)?
    /// Forces the Spotify-displayed verdict in tests, where no Spotify pid can
    /// be adopted through `NSRunningApplication`. Production leaves this nil.
    var spotifyDisplayForTests: Bool?
    /// Pins the scriptable precision source in tests without requiring a
    /// running player process.
    var precisionPlayerForTests: PlayerApp?
    private var spotifyStateObserver: (any NSObjectProtocol)?
    /// Music's own change announcement, for a Music song held under a film.
    private var musicStateObserver: (any NSObjectProtocol)?
    /// Hears every app quit, for `playerQuit`.
    private var quitObserver: (any NSObjectProtocol)?

    var ticker: Timer?
    var observers: [Any] = []
    /// Whether the panel is open — the ticker below runs only then.
    var isActive = false

    // MARK: - Stored properties of MediaController+Transport.swift

    /// What the player answered, supplied by a test so the shuffle and repeat
    /// buttons can be drawn without a player to ask. Setting it publishes the
    /// modes; `refreshPlaybackModes` then leaves them alone.
    var playbackModesForTests: (shuffle: Bool?, repeatMode: PlayerBridge.RepeatMode?)? {
        didSet {
            guard let modes = playbackModesForTests else { return }
            shuffleEnabled = modes.shuffle
            repeatMode = modes.repeatMode
        }
    }

    /// Music's favourite as a test's stand-in for the bridge answers it — the
    /// player's star is drawn only where the bridge can set it.
    var musicFavoriteForTests: Bool? {
        didSet { musicFavorite = musicFavoriteForTests }
    }

    /// Whether Music's current song is a favourite (spec §19.6), read in the
    /// same round trip as shuffle and repeat. Nil wherever the bridge cannot
    /// set it: another player, a browser, Music refusing Automation, or no
    /// current track. The player's star is drawn only when this is known, or
    /// when the Spotify account can save the song instead.
    @Published var musicFavorite: Bool?

    /// The star's last tap, held until Music says the same: a catalogue
    /// song's favourite reads back false for seconds after it was set.
    var favoriteHold = MusicFavoriteHold()

    /// The player's shuffle, repeat and favourite, read over AppleScript.
    /// Injectable, like `heldPlayerState`, so a test can answer stale, late
    /// or not at all without Music.
    var playbackModesReader: (PlayerApp, @escaping @MainActor (PlayerBridge.PlaybackModes?) -> Void) -> Void = {
        app, reply in PlayerBridge.playbackModes(of: app, completion: reply)
    }

    /// Music's favourite, written over AppleScript; the reply says whether
    /// Music took the command. Injectable for the same reason.
    var favoriteWriter: (PlayerApp, Bool, @escaping @MainActor (Bool) -> Void) -> Void = {
        app, isFavorite, reply in PlayerBridge.setFavorite(app, isFavorite, completion: reply)
    }

    /// Runs the star's read-backs and the end of its hold, `delay` seconds on.
    /// Injectable so a test can step through fifteen seconds without waiting.
    var favoriteTimer: (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated { work() }
        }
    }

    // MARK: - Stored properties of MediaController+Sync.swift

    /// The track whose id is being asked for, while the question is out.
    var spotifyTrackIDLookupKey: String?

    var lastSpotifyAnnouncement: SpotifyAnnouncement?

    /// Whether any lyric surface can be showing words. Read, not stored,
    /// like `musicOnly`, so the Settings switch reaches a running clock
    /// through `refreshPrecisionSync()`. Tests pin it.
    var lyricsShown: () -> Bool = { NotchViewModel.showLyricsEnabled }

    // MARK: - Stored properties of MediaController+Transport.swift

    /// Since when the player has evidently left the song on screen while the
    /// report naming the next one has not arrived.
    ///
    /// Filmed on 2026-09-21, frame by frame: on eleven skips the new song's
    /// clock ran under the old song's title — 0:00, sometimes 0:01, and the
    /// old song's first lyric line — for 50 to 700ms. Three sources carried the
    /// new song's position before any report carried its name: Spotify's own
    /// announcement, the one-second precision poll, and a Now Playing report
    /// updated in two steps. While this is set, readings for the song on screen
    /// are not adopted; the report with the next song ends it, and so does the
    /// grace running out, since then it was a restart after all.
    var awaitingTrackChangeSince: Date?
    /// A restart asked for, so the player back at the start of the same song
    /// is expected rather than a skip half-reported.
    var restartExpectedUntil: Date?

    /// Sends a command to a scriptable player directly. Injectable so a test
    /// can see where a tap went without a real player receiving it.
    var sendToPlayer: (PlayerBridge.Transport, PlayerApp) -> Void = { action, app in
        PlayerBridge.send(action, to: app)
    }

    /// Sends a command through the helper. Injectable for the same reason as
    /// `sendToPlayer`: a test sees what reached the helper without one running.
    lazy var sendToFeed: (NowPlayingFeed.Command, pid_t?) -> Void = { [unowned self] command, pid in
        self.feed.send(command, playerPID: pid)
    }

    /// The check a play or pause command is owed if no report settles it.
    var playbackChase: DispatchWorkItem?
    /// Where the song stood, and when, at the first tap of a run no report
    /// has confirmed. If the run is given up, the clock goes back to this.
    var clockBeforeUnconfirmedTaps: (position: TimeInterval, atMono: TimeInterval)?

    // MARK: - Stored properties of MediaController+Feed.swift

    /// Not private: the feed hands snapshots to this one entry point, and
    /// tests drive it the same way rather than standing up the real helper
    /// process.
    /// Whether the island shows only music. Read per snapshot so the switch in
    /// Settings takes effect on the next update, with nothing to restart.
    var musicOnly: () -> Bool = { NotchViewModel.musicOnlyEnabled }
    /// The bundle identifier behind a pid. Injectable so a test does not depend
    /// on which apps happen to be running on the Mac that runs it.
    var bundleIdentifierForPID: (pid_t) -> String? = {
        NSRunningApplication(processIdentifier: $0)?.bundleIdentifier
    }

    /// Whether a process is still alive. Injectable for the same reason as
    /// `bundleIdentifierForPID`.
    var isProcessRunning: (pid_t) -> Bool = { pid in
        NSRunningApplication(processIdentifier: pid).map { !$0.isTerminated } ?? false
    }

    /// Whether what the island shows passed the Music Only rules — a song, not
    /// a film shown while the filter was off.
    var displayedIsMusic = false

    /// A source Music Only keeps off the island is playing. `NotchViewModel`
    /// folds a paused song's lingering pill the moment this turns true: once a
    /// film is playing, the pill has nothing left to say.
    @Published var otherMediaIsPlaying = false

    /// Fresh reports asked of the helper after a player's own announcement.
    var freshReportsAskedForTests = 0

    /// The last raw snapshot the trail described, so the helper's two-second
    /// heartbeat writes a line only when something in it changed.
    var lastFeedTrace: String?

    /// True while a filtered session (a film) owns Now Playing and the island
    /// is holding the song that was showing before it.
    ///
    /// For that span MediaRemote describes only the film, so nothing it sends
    /// says whether the song is playing, paused or changed. Filmed on
    /// 2026-09-21: Spotify paused under a film in Firefox, the song left
    /// believing it was playing, its clock running forward to 1:23 and the
    /// precision poll — which asks Spotify directly — snapping it back to 1:21,
    /// every two seconds, the lyric line and the play button flipping with it.
    /// While holding, the song's truth comes from its own player instead.
    var isHolding = false

    /// The held player's state, read over AppleScript. Injectable so a test can
    /// answer for Spotify without Spotify.
    var heldPlayerState: (PlayerApp, @escaping (PlayerBridge.StateReply) -> Void) -> Void = { app, reply in
        PlayerBridge.stateReply(of: app) { answer in
            MainActor.assumeIsolated { reply(answer) }
        }
    }

    /// The film a search for a loaded song has already been made under, so its
    /// heartbeat every two seconds does not ask the players again. Cleared when
    /// a music source takes Now Playing back.
    var searchedUnder: pid_t?

    /// A song loaded in any running music player, playing or paused. Both
    /// the search under a film and the scripting fallback ask through here.
    ///
    /// Lazy only so the default can name the player on screen: with nothing
    /// playing, that one wins the tie (`PlayerBridge.choose`), so two paused
    /// players no longer trade places on every announcement.
    ///
    /// Only the players that may be asked now are asked: with Spotify allowed
    /// and Music never asked, a closed panel's search reads Spotify and leaves
    /// Music's prompt for the panel.
    lazy var loadedSong: (@escaping (PlayerState?) -> Void) -> Void = { [weak self] reply in
        PlayerBridge.currentState(
            prefer: self?.displayedPlayerApp ?? self?.activeApp,
            asking: { app in MainActor.assumeIsolated { self?.mayScript(app) ?? false } },
            announced: self?.announcedStates() ?? [:]
        ) { state in
            MainActor.assumeIsolated { reply(state) }
        }
    }

    /// The pid of a running player, for a song found by asking rather than by
    /// MediaRemote.
    var pidForPlayer: (PlayerApp) -> pid_t? = { app in
        NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
            .first?.processIdentifier
    }

    /// A cover for a song MediaRemote cannot describe, straight from its player.
    var heldArtwork: (PlayerState, @escaping (NSImage?) -> Void) -> Void = { state, reply in
        PlayerBridge.artwork(for: state) { image in
            MainActor.assumeIsolated { reply(image) }
        }
    }

    // MARK: - Stored properties of MediaController+Fallback.swift

    /// When the helper last published a record with a song in it, on the
    /// monotonic clock.
    var lastFullRecordAt: TimeInterval?

    // MARK: - Stored properties of MediaController+Feed.swift

    /// The last song each player announced, and when, on the monotonic clock.
    /// An announcement that names no song — a stop, or keys not understood —
    /// removes the entry: it says the old one no longer stands.
    var announcements: [PlayerApp: (state: PlayerState, heardAt: TimeInterval)] = [:]

    /// Covers asked of a player on the fallback route, by track key: one
    /// entry, reset when the track changes.
    var fallbackArtworkAttempts: [String: Int] = [:]

    // MARK: - Stored properties of MediaController+Sync.swift

    /// The stamp on the last player reading whose position was accepted.
    ///
    /// Deliberately not our own clock. Comparing against `anchor.at` was the
    /// first attempt and it wedges: `anchor.at` is pushed forward by every tap
    /// and every seek we make, so a single local action locks out a player
    /// that has not published since, and the bar then stays frozen for the
    /// whole paused period. Only the player advances this one.
    var lastReadingAt: Date?

    /// Below this a forward correction is churn, not information.
    ///
    /// This was 0.75s, and that number quietly guaranteed the bar ran behind:
    /// any reading ahead of us by less was ignored and the clock re-based, so
    /// the position could sit up to three-quarters of a second late forever,
    /// snapping forward only when the drift finally cleared the bar. Nobody
    /// sees that on a progress bar — the whole gap is under two points of
    /// travel — but a karaoke line keyed off the position sat visibly behind
    /// the voice, catching up in lurches. Forward corrections are truth, not
    /// jitter: readings never describe the future, so ahead-of-us means
    /// behind-the-player. Take them all.
    let forwardTolerance: TimeInterval = 0.05
    /// A disagreement this large is an event — a seek made in the player
    /// itself, or a track change — not a discrepancy to be smoothed over.
    let seekThreshold: TimeInterval = 2

    /// A large step backwards, waiting for a second reading to agree with it.
    var rewindCandidate: (value: TimeInterval, at: Date)?

    // MARK: - Automation consent

    /// What is showing the clock while it is active.
    ///
    /// Two surfaces activate it, and they differ in the one thing that matters
    /// here: a system prompt raised over the lock card sits under the shield,
    /// where nobody can answer it. Only the panel may raise the first one.
    enum Surface { case panel, lockCard }
    private var surface: Surface = .panel

    /// Where macOS stands on scripting a player. Production reads
    /// `AutomationAccess`; tests pin it, since a test must never reach a real
    /// player or TCC.
    var automationConsent: (PlayerApp) -> AutomationConsent = { app in
        MainActor.assumeIsolated { AutomationAccess.shared.status(app) }
    }

    /// Whether a Spotify account is connected. The track id exists for the
    /// lock-card heart alone, and the heart is drawn only for a connected
    /// account, so without one the lookup was an Apple Event for nothing.
    var spotifyAccountConnected: () -> Bool = {
        MainActor.assumeIsolated { SpotifyAccount.shared.isConnected }
    }

    /// Asks Spotify which track it is playing. A seam so a test can count the
    /// questions: under test the bridge answers nothing, so a lookup sent at
    /// the wrong moment was invisible until it could be counted.
    var spotifyTrackIDLookup: (@escaping @MainActor (PlayerBridge.SpotifyTrackLookup) -> Void) -> Void = { reply in
        PlayerBridge.spotifyTrackID(completion: reply)
    }

    /// Whether a background question may be sent to `app` now.
    ///
    /// Isla launched at login with Spotify playing and the panel closed, and
    /// "Isla wants to control Spotify" appeared unprompted, with nothing on
    /// screen to say what Isla was (G-005). The fallback did the same for
    /// every running player at launch (J-003). So: a player macOS already
    /// allows is asked as before; a refused one is never asked from the
    /// background, which also ends the once-a-second -1743 the position poll
    /// logged after a refusal (K-014); and one that would prompt is asked
    /// only once the panel is open, the moment the prompt is in context. Not
    /// on the lock card, which activates the clock too.
    ///
    /// A tap is not gated: it is the user's own action, and its prompt
    /// arrives in context by definition.
    func mayScript(_ app: PlayerApp) -> Bool {
        let consent = automationConsent(app)
        if consent == .allowed { return true }
        return consent != .denied && isActive && surface == .panel
    }

    var mayScriptAnyPlayer: Bool {
        PlayerApp.allCases.contains { mayScript($0) }
    }

    /// A question about a held song that consent kept back, so the panel
    /// opening — or the grant arriving — asks it then. Without it a song
    /// paused under a film while the panel was shut opened still reading as
    /// playing, because the one question that would have said so was skipped.
    var owedPlayerQuestion = false

    /// Asks what consent kept back, now that it may be asked. Each question
    /// carries its own gate, so this asks nothing a surface may not.
    private func payOwedQuestions() {
        updatePrecisionSync()
        if spotifyTrackID == nil, let key = track?.key {
            requestSpotifyTrackID(for: key, playerPID: displayedPlayerPID, attempt: 0)
        }
        if owedPlayerQuestion {
            if isHolding {
                syncHeldPlayer()
            } else if searchedUnder != nil, track == nil {
                adoptLoadedSong()
            }
        }
        if !feedAvailable { refreshFromPlayers() }
    }

    private var consentWatch: AnyCancellable?

    /// The consent changed: a prompt answered, a refusal learnt from a
    /// script, or the read-only check at launch. The last is what lets a Mac
    /// that already allows Isla get its heart without opening anything; a
    /// refusal stops the position poll at once rather than on its next tick.
    func automationConsentChanged() {
        payOwedQuestions()
        if isActive { refreshPlaybackModes() }
    }

    // MARK: - Lifecycle

    func start() {
        // Read-only, never a prompt: whether macOS already allows each running
        // player, so a Mac that granted access keeps everything it had.
        // Delivered on the next pass, because `@Published` announces before it
        // stores and the consent read on delivery must be the new one.
        consentWatch = AutomationAccess.shared.$consents
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.automationConsentChanged() } }
        AutomationAccess.shared.refresh()
        feed.onUpdate = { [weak self] snapshot in self?.feedDelivered(snapshot) }
        feed.onUnavailable = { [weak self] reason in self?.switchToScriptingFallback(reason) }
        feed.start()

        // Spotify broadcasts every play, pause and track change as a
        // distributed notification carrying its position to the millisecond —
        // measured arriving 10-30ms after the change, needing no permission
        // at all. It does not fire on seeks (MediaRemote pushes a fresh pair
        // ~185ms after those, covering the gap) and delivery is not
        // guaranteed, so the broadcast re-anchors at once and then asks for
        // the authoritative correction — never the only source.
        spotifyStateObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.hearAnnouncement(from: .spotify, note.userInfo ?? [:])
                self?.applySpotifyBroadcast(note)
                // And, for a song held under a film, the only report that the
                // song paused or resumed: MediaRemote is describing the film.
                self?.playerAnnouncedChange(.spotify)
            }
        }
        musicStateObserver = DistributedNotificationCenter.default().addObserver(
            forName: PlayerApp.music.changeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.hearAnnouncement(from: .music, note.userInfo ?? [:])
                self?.playerAnnouncedChange(.music)
            }
        }
        quitObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { self?.playerQuit(pid) }
        }
    }

    /// The app behind `pid` has quit, and a song it was showing goes with it.
    ///
    /// Nothing said so before. Quit Spotify mid-song and the session goes
    /// empty a moment before the process is gone; with the process still
    /// there, that empty report is exactly what a song held between two
    /// sessions looks like, so the song was kept — and a player on its way
    /// out does not answer the question that would have let it go. The
    /// island went on showing the song as playing, its clock running, until
    /// the helper repeated the empty record on its five-second heartbeat.
    ///
    /// Internal so a test can stand in for the quit.
    func playerQuit(_ pid: pid_t) {
        guard track != nil, displayedPlayerPID == pid else { return }
        trace("player \(pid) quit; its song goes with it")
        isHolding = false
        clear()
        // Whatever is left to show: another session on the helper's route,
        // the other player on the fallback's.
        if feedAvailable { askForFreshReport() } else { refreshFromPlayers() }
    }

    private func applySpotifyBroadcast(_ note: Notification) {
        receiveSpotifyBroadcast(note.userInfo ?? [:])
    }

    /// Whether a Spotify announcement is about a song other than the one on
    /// screen. On a skip it arrives before any report names the new song, and
    /// anchoring the old title to its position is what showed 0:00 under it.
    private func broadcastNamesAnotherSong(_ info: [AnyHashable: Any]) -> Bool {
        if let id = info["Track ID"] as? String, let known = spotifyTrackID, !id.hasSuffix(known) {
            return true
        }
        if let name = (info["Name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty, let title = track?.title,
           name.caseInsensitiveCompare(title) != .orderedSame {
            return true
        }
        return false
    }

    /// Spotify's own announcement, as its fields. Internal so a test can hand
    /// one in without Spotify.
    func receiveSpotifyBroadcast(_ info: [AnyHashable: Any]) {
        // Remembered whatever is on screen: on a skip the announcement comes
        // before any report names the new song, so it is the report, when it
        // catches up, that takes the id from here.
        if let uri = info["Track ID"] as? String, uri.hasPrefix(Self.spotifyTrackPrefix),
           let name = info["Name"] as? String, !name.isEmpty {
            lastSpotifyAnnouncement = SpotifyAnnouncement(
                id: String(uri.dropFirst(Self.spotifyTrackPrefix.count)),
                name: name,
                artist: info["Artist"] as? String ?? ""
            )
        }
        guard displayedPlayerIsSpotify else { return }
        adoptAnnouncedTrackID()
        guard let position = info["Playback Position"] as? Double else { return }
        guard pendingSeek == nil else { return }
        if broadcastNamesAnotherSong(info) {
            beginAwaitingTrackChange("Spotify announced another song")
            trackChangeExpected.send()
            return
        }
        if isAwaitingTrackChange() { return }
        if readingLooksLikeAnotherSong(position) {
            beginAwaitingTrackChange(String(format: "Spotify back at %.2f", position))
            return
        }
        // Delivery is unordered with the seek's own application: a broadcast
        // describing the pre-seek moment can arrive after the pending guard
        // has cleared, and anchoring on it replays the jump backwards. Only
        // that shape is dropped — one hugging the pre-seek trajectory while
        // disagreeing with the anchor — so a genuine pause or track-change
        // broadcast right after a click still lands.
        if let lastSeek {
            let elapsed = Date().timeIntervalSince(lastSeek.at)
            if elapsed < 1.2 {
                let phantom = lastSeek.origin + elapsed * (isPlaying ? max(playbackRate, 0) : 0)
                if abs(position - phantom) < 0.6, abs(position - self.position) > 0.5 { return }
            }
        }
        // Sanity-checked before it is believed. This value arrives from another
        // process's broadcast and is not validated anywhere else; a negative or
        // past-the-end position would anchor the clock outside the track.
        guard position.isFinite, position >= 0 else { return }
        guard duration <= 0 || position <= duration + 1 else { return }
        trace(String(format: "bc pos=%.2f old=%.2f", position, self.position))
        // The broadcast is an anchor hint no longer: a play, pause or
        // track-change re-anchors at once and asks for the authoritative
        // correction immediately, unsettled until it lands.
        handleSpotifyPlaybackState(position: position)
    }

    /// Returns the controller to the state `start()` expects.
    ///
    /// `feedAvailable` and `isActive` used to survive a stop, so a stop/start
    /// that happened while the scripting fallback was in use came back with the
    /// fallback flag still set — `switchToScriptingFallback` then early-returns,
    /// the player observers this method removed are never re-registered, and
    /// both routes are dead with nothing reporting an error.
    func stop() {
        feedAvailable = true
        fallbackReason = nil
        retryingNowPlaying = false
        isActive = false
        consentWatch = nil
        precisionTimer?.invalidate()
        precisionTimer = nil
        if let spotifyStateObserver {
            DistributedNotificationCenter.default().removeObserver(spotifyStateObserver)
        }
        spotifyStateObserver = nil
        if let musicStateObserver {
            DistributedNotificationCenter.default().removeObserver(musicStateObserver)
        }
        musicStateObserver = nil
        if let quitObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(quitObserver)
        }
        quitObserver = nil
        isHolding = false
        announcements = [:]
        lastFullRecordAt = nil
        feed.stop()
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        observers.removeAll()
        ticker?.invalidate()
        ticker = nil
        cancelLyricWake()
        playbackChase?.cancel()
        playbackChase = nil
    }

    /// Panel visibility. The position ticker hangs off this: it exists to move
    /// a bar, and a bar in a collapsed panel is painted for nobody — at four
    /// wake-ups a second for as long as anything plays. The position itself is
    /// never lost, because the anchor records where it stood and when: opening
    /// computes it from there instantly, and the feed's fresh answer corrects
    /// whatever drifted a beat later.
    func setActive(_ active: Bool, surface: Surface = .panel) {
        trace("setActive \(active ? 1 : 0)")
        isActive = active
        if active { self.surface = surface }
        // Only a playing track can have moved while the panel was shut. A
        // paused one is exactly where it was left, so what is already known
        // about it stays authoritative — and clearing the flag there stranded
        // every lyric surface, because nothing can set it again while paused:
        // MediaRemote republishes the reading it already gave, which is judged
        // stale, and the precision loop runs only while playing. The lyric came
        // back when the track was nudged, and not before.
        if active, isPlaying { positionSettled = false }
        settleWatchdog?.cancel()
        if active, !positionSettled {
            // And a player that answers nothing at all must not hold the lyrics
            // hostage either: past the grace, the extrapolated position is what
            // there is, and showing the line it points at beats showing none.
            settleWatchdog = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.settleGrace))
                guard !Task.isCancelled, let self, self.isActive else { return }
                if !self.positionSettled { self.positionSettled = true }
            }
        }
        updateTicker()
        guard active else { return updatePrecisionSync() }
        // Every panel open re-reads consent: the user may have changed it in
        // System Settings, and an update resets it (J-002).
        if surface == .panel { AutomationAccess.shared.refresh() }
        refreshPlaybackModes()
        // Whatever consent kept back while nothing was open — the heart's id,
        // the held song's state, the position poll, the fallback's read — is
        // asked now, if this surface may ask. The panel may; the lock card
        // only where macOS already allows it.
        payOwedQuestions()
        tick()
        if feedAvailable { feed.refresh() }
    }
}
