import AppKit

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

    @Published private(set) var track: Track?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var sourceName: String?
    /// The icon of the app the sound is coming from.
    ///
    /// Taken from the running process rather than matched against a list of
    /// bundle identifiers we happen to know, so a browser tab, a podcast app or
    /// something nobody here has heard of all get their own icon for free — and
    /// none of them needs this app updated to be recognised.
    @Published private(set) var sourceIcon: NSImage?
    /// Whether the player accepts skipping at all. A browser tab playing one
    /// video registers no handler for it — the command leaves and nothing
    /// happens — so the buttons go dim rather than dead, the way the system's
    /// own Now Playing widget dims them for the same session. True until told
    /// otherwise: the scripted fallback below drives Music and Spotify, and
    /// both skip fine.
    @Published private(set) var canSkip = true
    /// Shuffle, when the displayed player can be asked. Nil hides the button
    /// rather than dimming it: unlike skipping — which every session at least
    /// conceptually has — shuffle simply does not exist for a browser tab.
    @Published private(set) var shuffleEnabled: Bool?
    /// Repeat, same contract.
    @Published private(set) var repeatMode: PlayerBridge.RepeatMode?
    /// Whether the displayed player has the full three repeat states.
    /// Spotify's scripting has only the boolean.
    @Published private(set) var supportsRepeatOne = false

    private let feed = NowPlayingFeed()
    private var feedAvailable = true
    private var displayedPlayerPID: pid_t?
    private var playbackIntent = PlaybackIntent(reported: false)
    private var reportedPlayback = ReportedPlayback()

    /// How long a non-playing stranger has to keep claiming the session
    /// before it is believed. Long enough to ride out window switching,
    /// short enough that a genuinely departed player does not leave a ghost.
    /// Internal so the tests can collapse it.
    var foreignHoldWindow: TimeInterval = 10
    /// When a non-playing session from another PID first tried to take the
    /// display from a session we are still showing.
    private var foreignSince: Date?

    private var activeApp: PlayerApp?
    private var artworkKey: String?
    /// The pid `sourceIcon` was resolved for.
    private var sourceIconPID: pid_t?
    /// Tracks the app has already asked the helper to resend a cover for.
    ///
    /// Once per track, because a session with genuinely no artwork — a browser
    /// tab, most podcasts — would otherwise be asked again on every snapshot,
    /// twice a second, forever.
    private var artworkRequestedFor: Set<String> = []
    private var anchor: (position: TimeInterval, atMono: TimeInterval)? {
        // A new anchor moves every boundary's wall time with it.
        didSet { armBoundaryTimer() }
    }
    /// The clock the anchor extrapolates on. Wall time jumps on NTP steps and
    /// across sleep, and the anchor used to ride it — a +5s step teleported the
    /// bar and the lyric. `systemUptime` never jumps, so the extrapolation
    /// survives both. A seam, like `foreignHoldWindow`: tests freeze it while
    /// the wall runs on. `Date` stays only inside the 1.5s seek-verdict window,
    /// where what matters is ordering recent events, not measuring durations.
    var monotonicNow: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// How fast the player says the track is moving. Podcast and video apps
    /// routinely play at 1.5× or 2×, and the ticker extrapolating at 1×
    /// regardless meant the bar fell behind between polls and lurched forward
    /// on each one; below 1× it ran ahead and was yanked back.
    private var playbackRate: Double = 1 {
        didSet { if playbackRate != oldValue { armBoundaryTimer() } }
    }
    /// Where we asked the player to jump, when — and from where, because the
    /// pre-seek trajectory is the only thing that can unmask a reading taken
    /// after the seek was issued but before the player applied it.
    private var pendingSeek: (target: TimeInterval, at: Date, origin: TimeInterval)?
    /// The last seek, kept past the pending window: Spotify's own broadcast
    /// can deliver a pre-seek position after the pending guard has cleared,
    /// and anchoring on it replays the jump backwards on screen. The origin
    /// travels along so only broadcasts shaped like the pre-seek trajectory
    /// are dropped — a genuine pause or track change right after a click
    /// still carries the millisecond-exact position and is kept.
    private var lastSeek: (target: TimeInterval, at: Date, origin: TimeInterval)?

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
    @Published private(set) var precisionSync = false
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
    @Published private(set) var positionSettled = false

    // MARK: - Lyric boundaries

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
    private var lyricBoundaries: [TimeInterval] = []
    private var lyricLead: @MainActor () -> TimeInterval = { 0 }
    private var boundaryTimer: Timer?

    /// When the next lyric wake is scheduled for, if one is. Read from the
    /// armed timer rather than recomputed, so a test sees what was scheduled.
    var lyricWakeDateForTests: Date? { boundaryTimer?.fireDate }

    func setLyricBoundaries(_ boundaries: [TimeInterval], lead: @escaping @MainActor () -> TimeInterval) {
        lyricBoundaries = boundaries.sorted()
        lyricLead = lead
        armBoundaryTimer()
    }

    /// Seconds until the next boundary strictly ahead of the clock, or nil
    /// when the song has no more lines to turn. Pure, so the arithmetic is
    /// testable without a timer.
    static func nextLyricWake(
        boundaries: [TimeInterval], lead: TimeInterval, position: TimeInterval, rate: Double
    ) -> TimeInterval? {
        guard rate > 0 else { return nil }
        // Sorted, so the first boundary past the clock is the next one. Half a
        // millisecond of slack keeps a wake that fired exactly on a boundary
        // from re-arming for the boundary it just served.
        guard let next = boundaries.first(where: { $0 - lead > position + 0.0005 }) else { return nil }
        return ((next - lead) - position) / rate
    }

    private func armBoundaryTimer() {
        boundaryTimer?.invalidate()
        boundaryTimer = nil
        guard isPlaying, isActive, let anchor, !lyricBoundaries.isEmpty else { return }
        let now = anchor.position + (monotonicNow() - anchor.atMono) * playbackRate
        guard let delay = Self.nextLyricWake(
            boundaries: lyricBoundaries, lead: lyricLead(), position: now, rate: playbackRate
        ) else { return }
        let timer = Timer(timeInterval: max(delay, 0.001), repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        // No tolerance: the whole point is the frame the line is due on.
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        boundaryTimer = timer
    }
    /// How long an active panel waits for an authoritative reading before it
    /// settles for the position it has. Long enough for the ~150ms a real fix
    /// takes, short enough that nobody reads it as missing lyrics.
    static var settleGrace: TimeInterval = 1.2
    private var settleWatchdog: Task<Void, Never>?
    /// Spotify's catalogue id for the displayed track, when Spotify is the
    /// displayed player and has answered. The word-synced lyrics database is
    /// keyed by it; everything else falls back to title/artist matching.
    @Published private(set) var spotifyTrackID: String?
    /// The catalogue ISRC for the displayed track, when the Web API has
    /// answered. Lyric tiers join providers on this instead of guessing from
    /// title text; nil means unknown, never "this track has none".
    @Published private(set) var spotifyISRC: String?
    /// The catalogue's exact duration in seconds, alongside the id
    /// above. The snapshot's own duration is the daemon's rounded reading;
    /// this is the number the duration-gated lyric matching compares against.
    @Published private(set) var spotifyExactDuration: TimeInterval?
    /// Answers exact catalogue metadata for a Spotify track id.
    ///
    /// A seam, not a second path: production leaves this nil and the lookup
    /// goes to `SpotifyAccount.shared` over the network. Tests substitute
    /// canned answers because the AppleScript id lookup that triggers the
    /// fetch never resolves without a running Spotify, and the fetch would
    /// otherwise be untestable. Internal so tests can reach it, like
    /// `foreignHoldWindow` above.
    var spotifyMetadataProvider: ((String) async -> SpotifyAccount.TrackMetadata?)?
    private var precisionTimer: Timer?
    private var precisionInFlight = false
    /// How often a scriptable player's own clock is asked while its panel is
    /// open. Apple Music and Spotify both expose this public scripting value.
    /// Every two seconds the lyric sweep stair-stepped on the beat of the poll —
    /// a correction yanking the clock up to a tenth forward, then a dead anchor
    /// free-running until the next one — so the cadence is one second.
    static let precisionPollInterval: TimeInterval = 1.0
    /// Tight, for the same reason: a coalesced timer firing late reintroduces
    /// the very stepping the cadence above removes.
    static let precisionPollTolerance: TimeInterval = 0.1
    /// How many RTT-aged corrections the drift regression keeps. One snap
    /// carried the poll's ±80ms of scheduling jitter straight into the sweep;
    /// the mean of five converges to the player's line instead.
    static let correctionWindowSize = 5

    /// How often the position is republished while the panel is open.
    ///
    /// This was four times a second, chosen so the scrubber advanced in
    /// sub-pixel steps. It is also how stale the published position can be,
    /// and *that* is what a lyric reads: `position` only moves when this fires,
    /// so a surface drawing between two ticks is showing a number up to a full
    /// interval old. The live probe measured it — steady-play delta ran a
    /// median 0.235s behind Spotify against a true pipeline lag of about
    /// 0.11s, the rest being exactly this staleness — and the spread it
    /// produced was what failed the harness's 150ms word-timing gate, with the
    /// bias itself very nearly zero.
    ///
    /// Ten times a second costs six extra wake-ups per second, only while the
    /// panel is open, and cuts the worst-case staleness from 250ms to 100ms.
    /// The boundary timer beside it still fires exactly on a line change, so
    /// what this governs is the sweep and the bar between those changes.
    static let positionTickInterval: TimeInterval = 0.1
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

    private var ticker: Timer?
    /// Deferred blanking of a cover whose replacement is still in flight.
    private var blankArtwork: Task<Void, Never>?
    private var observers: [Any] = []
    /// Whether the panel is open — the ticker below runs only then.
    private var isActive = false

    // MARK: - Lifecycle

    func start() {
        feed.onUpdate = { [weak self] snapshot in self?.receive(snapshot) }
        feed.onUnavailable = { [weak self] in self?.switchToScriptingFallback() }
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
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.playerAnnouncedChange(.music) }
        }
    }

    private func applySpotifyBroadcast(_ note: Notification) {
        guard displayedPlayerIsSpotify,
              let position = note.userInfo?["Playback Position"] as? Double else { return }
        guard pendingSeek == nil else { return }
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
        isActive = false
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
        isHolding = false
        feed.stop()
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        observers.removeAll()
        ticker?.invalidate()
        ticker = nil
        boundaryTimer?.invalidate()
        boundaryTimer = nil
    }

    /// Panel visibility. The position ticker hangs off this: it exists to move
    /// a bar, and a bar in a collapsed panel is painted for nobody — at four
    /// wake-ups a second for as long as anything plays. The position itself is
    /// never lost, because the anchor records where it stood and when: opening
    /// computes it from there instantly, and the feed's fresh answer corrects
    /// whatever drifted a beat later.
    func setActive(_ active: Bool) {
        trace("setActive \(active ? 1 : 0)")
        isActive = active
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
        updatePrecisionSync()
        guard active else { return }
        refreshPlaybackModes()
        tick()
        if feedAvailable {
            feed.refresh()
        } else {
            refreshFromPlayers()
        }
    }

    // MARK: - Shuffle & repeat

    /// Asks the displayed player where its switches stand. Cheap enough to
    /// call on pane appearance and after every toggle; a no-op for sessions
    /// that cannot answer.
    func refreshPlaybackModes() {
        guard let app = displayedPlayerApp else {
            shuffleEnabled = nil
            repeatMode = nil
            return
        }
        supportsRepeatOne = app == .music
        PlayerBridge.playbackModes(of: app) { [weak self] modes in
            guard let self, self.displayedPlayerApp == app else { return }
            self.shuffleEnabled = modes?.shuffle
            self.repeatMode = modes?.repeatMode
        }
    }

    func toggleShuffle() {
        guard let app = displayedPlayerApp, let current = shuffleEnabled else { return }
        // Optimistic, like play/pause: the switch answers the click now and
        // the read-back a beat later corrects it if the player refused.
        shuffleEnabled = !current
        PlayerBridge.setShuffle(app, enabled: !current)
        readBackModes()
    }

    /// Cycles off → all → one → off where the player has all three, and
    /// off → all → off where it has two.
    func cycleRepeat() {
        guard let app = displayedPlayerApp, let current = repeatMode else { return }
        let next: PlayerBridge.RepeatMode
        switch (current, supportsRepeatOne) {
        case (.off, _): next = .all
        case (.all, true): next = .one
        case (.all, false), (.one, _): next = .off
        }
        repeatMode = next
        PlayerBridge.setRepeat(app, mode: next)
        readBackModes()
    }

    /// The truth, shortly after the command has had time to land.
    private func readBackModes() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated { self?.refreshPlaybackModes() }
        }
    }

    // MARK: - Precision sync

    /// MediaRemote's readings are the floor on accuracy: measured against
    /// Spotify's own clock they sit 0.9–1.1s stale, because the daemon
    /// re-serves one elapsed/timestamp pair between state changes. Spotify,
    /// though, answers its exact position over scripting to within ~50ms —
    /// so while the panel is open and Spotify is the displayed player, the
    /// position is corrected against the player itself every second.
    ///
    /// Spotify only, deliberately: it is the player that answers, and the
    /// first use raises macOS's one-time automation consent for it. Scoped to
    /// the open panel so a closed pill costs nothing and prompts for nothing.
    private var displayedPlayerIsSpotify: Bool {
        spotifyDisplayForTests ?? (displayedPlayerApp == .spotify)
    }

    private var precisionPlayer: PlayerApp? {
        if let precisionPlayerForTests { return precisionPlayerForTests }
        if spotifyDisplayForTests == true { return .spotify }
        return displayedPlayerApp
    }

    /// The scriptable player behind the displayed session, when it is one.
    /// Browsers and everything else answer nil — the honest value, since
    /// shuffle and repeat cannot even be asked about there.
    private var displayedPlayerApp: PlayerApp? {
        guard let pid = displayedPlayerPID, let bundle = bundleIdentifierForPID(pid) else { return nil }
        return PlayerApp.allCases.first { $0.bundleID == bundle }
    }

    /// A coarse player class for lyric matching. It is metadata, never an
    /// account or a process identifier, and lets timing policy distinguish
    /// scriptable players from unmeasured Now Playing publishers.
    var lyricPlayerID: String {
        displayedPlayerApp?.rawValue ?? "other"
    }

    /// Asks Spotify which track this is, and asks again if it does not answer.
    ///
    /// Everything Spotify-specific hangs off this id: the word-synced lyrics
    /// database is keyed by it, and so is the heart, which is simply not drawn
    /// while the id is nil. One attempt was not enough. The very first lookup
    /// after launch routinely fails — it is the call that triggers macOS's
    /// one-time automation consent, and it returns nothing while the dialog is
    /// still on screen — and a script can also come back empty if Spotify is
    /// mid-track-change. The id then stayed nil for the rest of that track, so
    /// the heart never appeared for the song that happened to be playing at
    /// launch, which is exactly when somebody would look for it.
    private func requestSpotifyTrackID(for key: String, playerPID: pid_t?, attempt: Int) {
        guard displayedPlayerIsSpotify else { return }
        PlayerBridge.spotifyTrackID { [weak self] id in
            guard let self,
                  self.track?.key == key,
                  self.displayedPlayerPID == playerPID else { return }
            if let id {
                self.spotifyTrackID = id
                Task { [weak self] in await self?.requestSpotifyMetadata(trackID: id, forKey: key) }
                return
            }
            // Backing off, and giving up well before it could become a poll.
            guard attempt < 4 else { return }
            let delay = pow(2.0, Double(attempt))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    self?.requestSpotifyTrackID(for: key, playerPID: playerPID, attempt: attempt + 1)
                }
            }
        }
    }

    /// Fetches the catalogue's exact identity for the resolved Spotify track.
    ///
    /// One attempt, not the retry loop above: a lookup that fails simply
    /// leaves the fields nil and title/artist matching covers the track. The
    /// next track change refetches, so a failure never needs polling for the
    /// rest of the song — and a failed lookup must never raise anything,
    /// because there is no user-grantable permission behind it.
    func requestSpotifyMetadata(trackID: String, forKey key: String) async {
        let metadata: SpotifyAccount.TrackMetadata?
        if let provider = spotifyMetadataProvider {
            metadata = await provider(trackID)
        } else {
            metadata = await SpotifyAccount.shared.trackMetadata(id: trackID)
        }
        // The track may have moved on while the lookup was in flight. The
        // key — pid plus title/artist/album — already identifies the track,
        // so a stale answer fails this and never pins the previous song's
        // identity onto the new one. Assigned unconditionally past the guard:
        // a track the catalogue does not know keeps nil rather than a
        // predecessor's values.
        //
        // The key alone is not enough: two catalogue IDs can share one key —
        // same title, artist, album and pid for a re-release — so a late
        // answer for the departed ID would still pass the key guard and pin
        // its ISRC onto the track the new ID now owns. The resolved ID is the
        // second half of the guard: set beside the fetch call, it has moved
        // on by the time a stale answer lands.
        guard track?.key == key, spotifyTrackID == trackID else { return }
        spotifyISRC = metadata?.isrc
        // The Web API speaks milliseconds; everything past this line —
        // lyric gates, task identities — speaks seconds.
        spotifyExactDuration = metadata.map { TimeInterval($0.durationMs) / 1000 }
    }

    /// Test seam: pins the resolved catalogue id the metadata guard reads,
    /// standing in for the AppleScript lookup that never resolves without a
    /// running Spotify. Production sets `spotifyTrackID` beside the fetch;
    /// tests do the same through here.
    func setSpotifyTrackIDForTests(_ id: String?) { spotifyTrackID = id }

    /// Test seam for late Spotify catalogue metadata. Production writes these
    /// fields through `requestSpotifyMetadata(trackID:forKey:)`.
    func setSpotifyMetadataForTests(
        trackID: String?, isrc: String?, exactDuration: TimeInterval?
    ) {
        spotifyTrackID = trackID
        spotifyISRC = isrc
        spotifyExactDuration = exactDuration
    }

    private func updatePrecisionSync() {
        // Playing, too. A paused track's position cannot move, so asking
        // Spotify where it is every second — a fresh AppleScript compile
        // and an Apple event into another process each time — bought a number
        // already known. Pausing and walking away used to leave that running
        // indefinitely.
        let wanted = isActive && isPlaying && precisionPlayer != nil
        if precisionSync != wanted { precisionSync = wanted }
        guard wanted else {
            precisionTimer?.invalidate()
            precisionTimer = nil
            return
        }
        guard precisionTimer == nil else { return }
        // A (re)starting loop is a new line: origins measured before a pause
        // describe a frozen position against a running clock, and regressing
        // them with the fresh ones would lean the mean backwards for five polls.
        correctionWindow = []
        let timer = Timer(timeInterval: Self.precisionPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.precisionCorrect() }
        }
        timer.tolerance = Self.precisionPollTolerance
        RunLoop.main.add(timer, forMode: .common)
        precisionTimer = timer
        precisionCorrect()
    }

    /// The smoothed anchor for a window of RTT-aged corrections.
    ///
    /// Each correction implies an origin — where the track stood at monotonic
    /// zero had it always run at `rate` — and the mean of those origins is the
    /// line the player is actually on. Zero-mean scheduling jitter cancels
    /// across the window instead of yanking the sweep every poll, while a real
    /// drift moves every sample and carries the mean with it. A single sample
    /// is just a snap: the regression only helps once there is a window.
    static func regressedAnchorPosition(
        corrections: [(atMono: TimeInterval, position: TimeInterval)],
        rate: Double,
        nowMono: TimeInterval
    ) -> TimeInterval {
        guard let last = corrections.last else { return 0 }
        guard rate > 0 else { return last.position }
        let mean = corrections.map { $0.position - $0.atMono * rate }.reduce(0, +)
            / TimeInterval(corrections.count)
        return mean + nowMono * rate
    }

    /// What a Spotify play/pause/track-change broadcast is worth.
    ///
    /// The reading arrives in 10-30ms with millisecond precision, so it anchors
    /// at once — then a correction is asked for immediately rather than on the
    /// next poll, and the position reads unsettled until that authoritative
    /// answer lands so no lyric is chosen from the hint. The guards (Spotify
    /// displayed, no seek in flight, sane value) stay with the caller.
    func handleSpotifyPlaybackState(position broadcastPosition: TimeInterval) {
        setAnchor(broadcastPosition)
        positionSettled = false
        precisionCorrect()
    }

    private func precisionCorrect() {
        guard !precisionInFlight, let player = precisionPlayer else { return }
        precisionInFlight = true
        let askedMono = monotonicNow()
        // The seek verdict below is the one place the wall clock stays: it
        // orders a reading against a seek issued moments ago, and thresholds
        // (1.5s expiry, 0.6 phantom, 0.8 target) are unchanged.
        let askedWall = Date()
        let fetch = precisionPositionFetcher ?? { completion in
            PlayerBridge.precisePosition(of: player, completion: completion)
        }
        fetch { [weak self] value in
            guard let self else { return }
            self.precisionInFlight = false
            guard let value, self.isActive, self.precisionPlayer == player else { return }

            // With corrections stewarding the position, this loop must also
            // settle a pending seek — the MediaRemote branch that used to is
            // skipped, and skipping this too left pendingSeek set forever
            // after one in-panel seek: corrections permanently disabled, the
            // clock free-running on a dead anchor, and everything downstream
            // of the position drifting for the rest of the track.
            if let pending = self.pendingSeek {
                switch Self.judgeSeekReading(
                    reading: value,
                    target: pending.target,
                    issuedAt: pending.at,
                    askedAt: askedWall,
                    now: Date(),
                    origin: pending.origin,
                    rate: self.isPlaying ? self.playbackRate : 0
                ) {
                case .discard: return
                case .settleIgnore: self.pendingSeek = nil; return
                case .settleAdopt: self.pendingSeek = nil
                }
            }

            // The script's answer is already old by the time it arrives —
            // it describes the moment mid-round-trip, so while playing it is
            // aged by half the trip before use. Without this every correction
            // pulled the clock back by its own latency, and the measured
            // result was a position that froze for a third of a second on every
            // poll: the exact stutter this path exists to remove. The
            // trip is timed on the monotonic clock, so a wall step mid-round-trip
            // cannot stretch or shrink it.
            let nowMono = self.monotonicNow()
            let latency = nowMono - askedMono
            let corrected = self.isPlaying ? value + latency / 2 : value
            let delta = corrected - self.position
            self.trace(String(format: "pc val=%.2f lat=%.2f delta=%.2f pos=%.2f", value, latency, delta, self.position))

            // Monotonic while playing: time does not go backwards, so a small
            // backward disagreement is sampling noise and only re-bases the
            // clock. A large one is a real rewind and is taken whole. Forward
            // and large corrections join the regression window instead of
            // snapping the anchor, so one jittered answer cannot move the sweep.
            if delta >= 0 || delta <= -1.0 || !self.isPlaying {
                // ...unless the jump is event-scale — a seek made in the
                // player, not drift. The window still leans on the old line,
                // and regressing a +30s jump would drag the anchor back towards
                // where the track was for five polls. Flush and snap, mirroring
                // the 1.0s band the rebase rule above already draws.
                if self.isPlaying, abs(delta) >= 1.0 {
                    self.correctionWindow = []
                    self.setAnchor(corrected)
                } else {
                    self.correctionWindow.append((atMono: nowMono, position: corrected))
                    if self.correctionWindow.count > Self.correctionWindowSize {
                        self.correctionWindow.removeFirst(
                            self.correctionWindow.count - Self.correctionWindowSize)
                    }
                    let rate = self.isPlaying ? self.playbackRate : 0
                    self.setAnchor(Self.regressedAnchorPosition(
                        corrections: self.correctionWindow, rate: rate, nowMono: nowMono))
                }
            } else {
                self.anchor = (self.position, nowMono)
            }
            if !self.positionSettled { self.positionSettled = true }
        }
    }

    // MARK: - Transport

    func togglePlayPause() {
        let target = playbackIntent.toggle(at: Date())
        // The latest tap owns the icon immediately. Reports from before the
        // command completed are reconciled without repainting it backwards.
        isPlaying = playbackIntent.desired
        setAnchor(position)
        updateTicker()
        if let target { dispatchPlayback(target) }
    }

    func next() {
        trace("cmd next")
        dispatch(feed: .next, transport: .next, key: .next)
    }

    func previous() {
        trace("cmd previous")
        dispatch(feed: .previous, transport: .previous, key: .previous)
    }

    func seek(to seconds: TimeInterval) {
        guard duration > 0 else { return }
        let clamped = min(max(0, seconds), duration)
        let origin = anchor.map { $0.position } ?? position
        trace(String(format: "seek to=%.2f origin=%.2f", clamped, origin))
        // Our own jump is not a reading to be corroborated, and a candidate
        // left over from before it would judge the next reading against a
        // trajectory the track has already left.
        rewindCandidate = nil
        setAnchor(clamped)
        // Our own jump starts a new line: corrections measured against the old
        // one would lean the regression back towards it for five polls.
        correctionWindow = []
        pendingSeek = (clamped, Date(), origin)
        lastSeek = (clamped, Date(), origin)
        if let held = heldScriptablePlayer {
            sendToPlayer(.seek(seconds: Int(clamped)), held)
        } else if feedAvailable {
            feed.seek(to: clamped, playerPID: displayedPlayerPID)
        } else if let activeApp {
            sendToPlayer(.seek(seconds: Int(clamped)), activeApp)
        }
    }

    /// Sends a command to a scriptable player directly. Injectable so a test
    /// can see where a tap went without a real player receiving it.
    var sendToPlayer: (PlayerBridge.Transport, PlayerApp) -> Void = { action, app in
        PlayerBridge.send(action, to: app)
    }

    /// The player a command must go to directly, around MediaRemote.
    ///
    /// The helper addresses a command to the shown player by pid, but it can
    /// reach only a player it has seen own Now Playing in its lifetime; for any
    /// other pid it hands the command to whoever owns Now Playing now. Under a
    /// film, that is the film: after a relaunch with a film playing, the song
    /// the island found paused in Spotify would have sent its play tap to the
    /// film. So a held song whose player can be scripted is driven through it.
    private var heldScriptablePlayer: PlayerApp? {
        isHolding ? displayedPlayerApp : nil
    }

    private func dispatch(
        feed command: NowPlayingFeed.Command,
        transport action: PlayerBridge.Transport,
        key: PlayerBridge.MediaKey
    ) {
        if let held = heldScriptablePlayer {
            sendToPlayer(action, held)
        } else if feedAvailable {
            feed.send(command, playerPID: displayedPlayerPID)
        } else if let activeApp {
            sendToPlayer(action, activeApp)
        } else {
            PlayerBridge.postMediaKey(key.rawValue)
        }
    }

    private func dispatchPlayback(_ playing: Bool) {
        // The per-client command set has no toggle of its own (#23), so the
        // desired state travels explicitly.
        dispatch(
            feed: playing ? .play : .pause,
            transport: playing ? .play : .pause,
            key: .playPause
        )
    }

    // MARK: - Feed

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

    /// What one snapshot from the live feed does to the display.
    enum Admission: Equatable {
        /// A music source: shown as normal.
        case accept
        /// Not music, and nothing worth keeping: the island shows nothing.
        case clear
        /// Not music, but a song is still loaded in a player that is still
        /// running: the song stays, untouched.
        case keep
    }

    func admission(for snapshot: NowPlayingFeed.Snapshot) -> Admission {
        guard musicOnly() else { return .accept }
        // An empty report — the helper caught between two sessions, or a
        // film's tab closed — used to clear the island to "Nothing is playing"
        // over a song still loaded, which then came back on the next report as
        // a brand-new track, lyrics and cover reloaded.
        //
        // Only for a song whose player can be asked what it is doing. Held on
        // an empty report, a song from any other player — Tidal, a browser —
        // could never be checked again: a playing pill kept animating after
        // the music stopped, until the app quit.
        if snapshot.isEmpty {
            return holdsASong(against: snapshot) && displayedPlayerApp != nil ? .keep : .accept
        }
        if isMusic(snapshot) { return .accept }
        // A film has taken the Now Playing session — macOS reports only the
        // latest one. It used to be turned straight into "nothing playing",
        // which cleared the song paused a moment earlier: pause Spotify, start
        // a film in a tab, open the island, and it said "Nothing is playing"
        // with a song sitting paused in Spotify. The song is still what the
        // island is about, for as long as the player holding it is running.
        return holdsASong(against: snapshot) ? .keep : .clear
    }

    /// Whether a report is music by the Music Only rules.
    private func isMusic(_ snapshot: NowPlayingFeed.Snapshot) -> Bool {
        MediaSourcePolicy.allows(
            bundleIdentifier: snapshot.playerPID.flatMap(bundleIdentifierForPID),
            mediaType: snapshot.mediaType,
            artist: snapshot.artist
        )
    }

    /// Whether the displayed song outlives a report that does not describe it.
    ///
    /// Only a song does. Holding once asked nothing but whether the displayed
    /// player still ran — so switching Music Only on while a film was showing
    /// held the film itself, its browser very much running. And only against
    /// another app: the displayed player now reporting something filtered has
    /// replaced its own song.
    private func holdsASong(against snapshot: NowPlayingFeed.Snapshot) -> Bool {
        guard track != nil, displayedIsMusic,
              let pid = displayedPlayerPID, isProcessRunning(pid) else { return false }
        return snapshot.playerPID != pid
    }

    /// Whether what the island shows passed the Music Only rules — a song, not
    /// a film shown while the filter was off.
    private var displayedIsMusic = false

    /// A source Music Only keeps off the island is playing. `NotchViewModel`
    /// folds a paused song's lingering pill the moment this turns true: once a
    /// film is playing, the pill has nothing left to say.
    @Published private(set) var otherMediaIsPlaying = false

    /// Fresh reports asked of the helper after a player's own announcement.
    private(set) var freshReportsAskedForTests = 0

    /// A player announced a change of its own — play, pause, a new track.
    ///
    /// Spotify and Music post these the moment anything happens, from their
    /// own window, a media key or Control Center alike. The helper hears
    /// MediaRemote's own notifications only sometimes — on macOS 26 they were
    /// measured arriving not at all; on macOS 27 a browser's play and pause
    /// arrived within milliseconds (2026-09-21) — and otherwise notices on its
    /// two-second poll, so a change the notifications missed reached the
    /// island up to two seconds late. The player's announcement is reliable,
    /// so the helper is asked at once, and once more a moment later, since
    /// MediaRemote can trail the player's own announcement.
    func playerAnnouncedChange(_ app: PlayerApp) {
        heldPlayerChanged(app)
        guard feedAvailable else { return }
        askForFreshReport()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated { self?.askForFreshReport() }
        }
    }

    private func askForFreshReport() {
        freshReportsAskedForTests += 1
        feed.refresh()
    }

    /// Where the live feed arrives. Filtering happens here and not inside
    /// `apply`, which every test drives directly with made-up pids that no
    /// real app owns.
    func receive(_ snapshot: NowPlayingFeed.Snapshot) {
        let verdict = admission(for: snapshot)
        traceFeed(snapshot, verdict)
        let otherPlaying = verdict != .accept && !snapshot.isEmpty
            && (snapshot.isPlaying || snapshot.rate > 0)
        if otherMediaIsPlaying != otherPlaying { otherMediaIsPlaying = otherPlaying }
        switch verdict {
        case .accept:
            apply(snapshot)
            // Only once the report is what the island shows. `apply` holds a
            // paused stranger off for a while, and dropping the hold for a
            // report it refused left the held song on screen with its taps
            // going through the helper — which, not knowing the song's player,
            // hands them to whoever owns Now Playing.
            guard snapshot.isEmpty || displayedPlayerPID == snapshot.playerPID else { return }
            isHolding = false
            searchedUnder = nil
            displayedIsMusic = !snapshot.isEmpty && isMusic(snapshot)
        case .clear:
            isHolding = false
            apply(NowPlayingFeed.Snapshot())
            // Nothing held — but that only means Isla never *saw* a song, not
            // that there is none. After a relaunch, or a film started before a
            // song, the film owns Now Playing and a song paused in Spotify is
            // invisible to MediaRemote: the island said "Nothing is playing"
            // over it. So look, once per film.
            if let pid = snapshot.playerPID, searchedUnder != pid {
                searchedUnder = pid
                trace("search: \(snapshot.title) owns Now Playing and nothing is held; asking the music players")
                adoptLoadedSong()
            }
        case .keep:
            if !isHolding { trace("hold: \(snapshot.title) owns Now Playing; holding \(track?.title ?? "-")") }
            // Entering the hold is the moment MediaRemote stops describing the
            // song, so it is the moment to ask the song's player directly.
            // Every later heartbeat from the film changes nothing about the
            // song and asks nothing; the player's own announcements do.
            guard !isHolding else { return }
            isHolding = true
            syncHeldPlayer()
        }
    }

    /// The last raw snapshot the trail described, so the helper's two-second
    /// heartbeat writes a line only when something in it changed.
    private var lastFeedTrace: String?

    /// Every change in what the helper reports, before any judgement: owner,
    /// playing flag, rate, title and the admission verdict. Verification only.
    private func traceFeed(_ snapshot: NowPlayingFeed.Snapshot, _ verdict: Admission) {
        let env = ProcessInfo.processInfo.environment
        guard env["DI_OPEN_LYRICS"] == "1" || env["DI_MEDIA"] == "1" else { return }
        let bundle = snapshot.playerPID.flatMap(bundleIdentifierForPID) ?? "-"
        let line = String(
            format: "feed: pid=%d %@ playing=%d rate=%.2f el=%.2f \"%@\" -> %@",
            snapshot.playerPID ?? 0, bundle, snapshot.isPlaying ? 1 : 0, snapshot.rate,
            snapshot.elapsed, snapshot.title, "\(verdict)"
        )
        guard line != lastFeedTrace else { return }
        lastFeedTrace = line
        DebugTrail.note(line)
    }

    // MARK: - Holding a song under a film

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
    private(set) var isHolding = false

    /// The held player's state, read over AppleScript. Injectable so a test can
    /// answer for Spotify without Spotify.
    var heldPlayerState: (PlayerApp, @escaping (PlayerBridge.StateReply) -> Void) -> Void = { app, reply in
        PlayerBridge.stateReply(of: app) { answer in
            MainActor.assumeIsolated { reply(answer) }
        }
    }

    /// A player announced a play, pause or track change of its own. Worth a
    /// question only when it is the player whose song is being held; when the
    /// song is Now Playing's own, MediaRemote has already said the same thing.
    func heldPlayerChanged(_ app: PlayerApp) {
        if isHolding {
            guard displayedPlayerApp == app else { return }
            syncHeldPlayer()
            return
        }
        // Nothing held under a film yet: a player that just changed may now
        // have a song worth showing — one started, or loaded, under the film.
        if searchedUnder != nil { adoptLoadedSong() }
    }

    /// The film a search for a loaded song has already been made under, so its
    /// heartbeat every two seconds does not ask the players again. Cleared when
    /// a music source takes Now Playing back.
    private var searchedUnder: pid_t?

    /// A song loaded in any running music player, playing or paused.
    var loadedSong: (@escaping (PlayerState?) -> Void) -> Void = { reply in
        PlayerBridge.currentState { state in
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

    /// Shows a song found in a music player while a film owns Now Playing.
    private func adoptLoadedSong() {
        loadedSong { [weak self] state in
            guard let self, !self.isHolding, self.searchedUnder != nil,
                  let state, let pid = self.pidForPlayer(state.app) else { return }
            var snapshot = NowPlayingFeed.Snapshot()
            snapshot.title = state.title
            snapshot.artist = state.artist
            snapshot.album = state.album
            snapshot.duration = state.duration
            snapshot.elapsed = state.position
            snapshot.isPlaying = state.isPlaying
            snapshot.rate = state.isPlaying ? 1 : 0
            snapshot.takenAt = Date()
            snapshot.playerPID = pid
            snapshot.source = state.app.displayName
            self.trace(String(format: "adopt: %@ from %@ playing=%d at %.2f",
                              state.title, state.app.displayName, state.isPlaying ? 1 : 0, state.position))
            self.isHolding = true
            self.displayedIsMusic = true
            self.apply(snapshot)
            self.fetchHeldArtwork(state)
        }
    }

    /// MediaRemote cannot resend a cover while it describes the film, so a held
    /// song that has none — adopted, or changed under the film — asks its
    /// player for one.
    private func fetchHeldArtwork(_ state: PlayerState) {
        guard let key = track?.key else { return }
        heldArtwork(state) { [weak self] image in
            guard let self, self.track?.key == key, let image else { return }
            self.blankArtwork?.cancel()
            self.blankArtwork = nil
            self.artworkKey = key
            self.artwork = image
        }
    }

    /// Asks the held song's player what it is doing and shows exactly that.
    ///
    /// Through `apply`, as an ordinary snapshot, so the pause, the position and
    /// a track changed under the film all go the one well-trodden way. The
    /// title and artist are carried over verbatim when the player still names
    /// the same song, so the track's identity — and with it the cover, which
    /// MediaRemote cannot resend while it describes the film — survives the
    /// question.
    private func syncHeldPlayer() {
        guard let app = displayedPlayerApp else { return }
        let pid = displayedPlayerPID
        heldPlayerState(app) { [weak self] reply in
            guard let self, self.isHolding, self.displayedPlayerPID == pid else { return }
            let state: PlayerState
            switch reply {
            case let .loaded(loaded):
                state = loaded
            case .empty:
                // The player answered, and has nothing loaded: no song to hold.
                self.isHolding = false
                self.clear()
                return
            case .unknown:
                // The player could not be asked — Automation consent withheld,
                // or no answer in time. That says nothing about the song, so it
                // stays as last known rather than the island claiming nothing
                // is playing over a song that may be sitting there paused.
                self.trace("sync: \(app.displayName) did not answer; keeping \(self.track?.title ?? "-")")
                return
            }
            var snapshot = NowPlayingFeed.Snapshot()
            let same = self.track.map {
                $0.title == state.title && $0.artist == state.artist
            } ?? false
            snapshot.title = same ? (self.track?.title ?? state.title) : state.title
            snapshot.artist = same ? (self.track?.artist ?? state.artist) : state.artist
            snapshot.album = same ? (self.track?.album ?? state.album) : state.album
            snapshot.duration = state.duration > 0 ? state.duration : self.duration
            snapshot.elapsed = state.position
            snapshot.isPlaying = state.isPlaying
            snapshot.rate = state.isPlaying ? 1 : 0
            snapshot.takenAt = Date()
            snapshot.playerPID = pid
            snapshot.source = self.sourceName
            self.trace(String(format: "sync: %@ playing=%d at %.2f", state.title, state.isPlaying ? 1 : 0, state.position))
            self.apply(snapshot)
            // A different song than the one held — changed under the film —
            // has no cover yet, and MediaRemote cannot send one.
            if !same { self.fetchHeldArtwork(state) }
        }
    }

    func apply(_ snapshot: NowPlayingFeed.Snapshot) {
        guard !snapshot.isEmpty else { return clear() }

        // macOS's "active" session follows app focus, not audio: focusing a
        // browser holding a paused video displaces the player that is
        // actually making sound, and the feed starts describing the wrong
        // one. The island keeps its own counsel — a session that is not
        // playing never takes the display away from the one being shown.
        //
        // The hold is not forever, because the displayed player may be
        // genuinely gone — quit, or its session expired — and then the
        // stranger is all there is. A stranger that persists for the whole
        // window is adopted; one that starts playing is adopted at once,
        // because new audio is the one claim that outranks everything.
        if let currentPID = displayedPlayerPID,
           let snapshotPID = snapshot.playerPID,
           snapshotPID != currentPID,
           !snapshot.isPlaying, snapshot.rate <= 0 {
            let now = Date()
            if let foreignSince {
                if now.timeIntervalSince(foreignSince) < foreignHoldWindow { return }
                // Held long enough: fall through and adopt it.
            } else {
                foreignSince = now
                return
            }
        }
        foreignSince = nil

        // The PID rides along with title/artist/album: two different players
        // can report the exact same metadata, and without it a switch
        // between them would read as no change at all — stale commands and
        // artwork surviving into the newly displayed track.
        let key = "\(snapshot.playerPID ?? 0)|\(snapshot.title)|\(snapshot.artist)|\(snapshot.album)"
        // Assigned only when it actually differs. `@Published` never compares,
        // so rebuilding an identical Track every poll fired objectWillChange
        // every two seconds forever, and the whole panel graph was rebuilt off
        // the back of it — measured at roughly a quarter of the app's idle CPU,
        // spent re-rendering a collapsed shell that had not changed.
        let trackChanged = track?.key != key
        let playerChanged = displayedPlayerPID != snapshot.playerPID
        // Clear metadata for the departing logical track before publishing the
        // new one. Otherwise a subscriber can observe the new title paired
        // with the previous recording ID for one synchronous Combine turn.
        if trackChanged || playerChanged {
            spotifyTrackID = nil
            spotifyISRC = nil
            spotifyExactDuration = nil
        }
        let fresh = Track(title: snapshot.title, artist: snapshot.artist, album: snapshot.album, key: key)
        if track != fresh { track = fresh }
        // Adopted *before* the Spotify id is asked for. Asking first tested the
        // player the last snapshot came from: switching Music → Spotify skipped
        // the lookup for the first Spotify track, so its word-synced lyrics
        // silently degraded, and switching the other way asked Spotify what it
        // was playing and then pinned that id to a Music track, keying its
        // lyrics to the wrong song entirely.
        displayedPlayerPID = snapshot.playerPID
        if trackChanged || playerChanged {
            // A new song is a new line for the regression too.
            correctionWindow = []
            requestSpotifyTrackID(for: key, playerPID: snapshot.playerPID, attempt: 0)
        }
        if playerChanged {
            positionSettled = false
            shuffleEnabled = nil
            repeatMode = nil
            if isActive { refreshPlaybackModes() }
            updatePrecisionSync()
            // Both readers carry state about the player that just went away:
            // the flag history that decides what a dropped flag means, and the
            // stamp that decides whether a reading is news. Carried across, a
            // switch to a session that reports differently reads as a state
            // change that never happened.
            reportedPlayback = ReportedPlayback()
            lastReadingAt = nil
        }
        // Both fields are consulted, but not as a plain OR: the rate settles
        // about half a second after the flag on a real pause, and counting it
        // during that gap keeps the island playing after the music stopped.
        let now = Date()
        let reportedPlaying = reportedPlayback.resolve(
            isPlaying: snapshot.isPlaying,
            rate: snapshot.rate,
            at: now
        )
        let queuedTarget: Bool?
        if playerChanged {
            playbackIntent = PlaybackIntent(reported: reportedPlaying)
            queuedTarget = nil
        } else {
            queuedTarget = playbackIntent.reconcile(reported: reportedPlaying, at: now)
        }
        // Same reason as `track` above: unconditional writes to @Published are
        // what turned a quiet 2s poll into a full SwiftUI invalidation.
        if isPlaying != playbackIntent.desired { isPlaying = playbackIntent.desired }
        if duration != snapshot.duration { duration = snapshot.duration }
        if sourceName != snapshot.source { sourceName = snapshot.source }
        refreshSourceIcon(for: snapshot.playerPID)
        // Both directions travel together: no player has ever offered one
        // without the other, and two separately dimmed arrows would read as
        // a glitch rather than a limit.
        let skippable = snapshot.offers(.next) && snapshot.offers(.previous)
        if canSkip != skippable { canSkip = skippable }

        let reported = reportedPosition(from: snapshot, isPlaying: reportedPlaying)

        // A player needs a moment to act on a seek, and until it does it keeps
        // reporting the old position. Accepting that would yank the bar back.
        // While the position is being corrected against the player's own
        // clock, MediaRemote's readings are strictly the worse source — and
        // letting both steer measurably oscillated: MediaRemote's stale-pair
        // aging pushed the clock ahead, the next correction pulled it back,
        // and the lyric edge stuttered on the beat of the poll. One steward
        // at a time. A track change still adopts, so a skip does not wait
        // two seconds for the next correction.
        let precisionSteers = precisionSync && !playerChanged && !trackChanged
        let stale = describesAMomentAlreadyPast(snapshot, isPlaying: reportedPlaying)
        trace(String(
            format: "apply el=%.2f age=%@ rate=%.2f play=%d stale=%d steer=%d rep=%.2f pos=%.2f pend=%d",
            snapshot.elapsed,
            snapshot.takenAt.map { String(format: "%.2f", Date().timeIntervalSince($0)) } ?? "nil",
            snapshot.rate, reportedPlaying ? 1 : 0, stale ? 1 : 0,
            precisionSync && !playerChanged && !trackChanged ? 1 : 0,
            reportedPosition(from: snapshot, isPlaying: reportedPlaying),
            position, pendingSeek == nil ? 0 : 1
        ))
        // The rate the clock extrapolates at, from the player itself. Zero is
        // what a paused session reports and says nothing about how fast it will
        // resume, so the last positive rate is kept.
        if snapshot.rate > 0 {
            // A rate change discontinues the regression line the way a seek
            // and a track change already do (see both): every origin in the
            // window was measured while the track moved at the old rate, and
            // `regressedAnchorPosition` derives each origin as
            // `position - atMono * rate` at the *current* rate — so a window
            // built at 1x surviving into 2x playback recomputes those origins
            // a growing distance off, leaning the mean towards the speed
            // mismatch instead of the player's drift and "correcting" every
            // fresh reading backwards for the five polls it takes the window
            // to age out. Only a change flushes: a steady rate is the
            // ordinary case and must keep the line it has been building, and
            // the first positive rate after a pause is no change at all —
            // the loop that was paused flushes its own window on restart.
            if snapshot.rate != playbackRate { correctionWindow = [] }
            playbackRate = snapshot.rate
        }
        if precisionSteers {
            // Position is the correction loop's job; everything else in the
            // snapshot — track, playing state, commands, artwork — landed
            // above as usual.
        } else if let pending = pendingSeek {
            switch Self.judgeSeekReading(
                reading: reported,
                target: pending.target,
                issuedAt: pending.at,
                // A snapshot without a capture time cannot prove it is
                // post-seek; distantPast makes the gate treat it as stale.
                askedAt: snapshot.takenAt ?? .distantPast,
                now: Date(),
                origin: pending.origin,
                rate: isPlaying ? playbackRate : 0
            ) {
            case .discard:
                break
            case .settleIgnore:
                pendingSeek = nil
            case .settleAdopt:
                pendingSeek = nil
                // Even here the reading has to be worth having. A seek made
                // while paused often gets no fresh reading at all until
                // playback resumes, and adopting a superseded one threw the
                // bar back to where the track was before the drag — the
                // exact yank this whole path exists to avoid.
                if !stale { adopt(reported, mayRewindAtOnce: trackChanged || playerChanged) }
            }
        } else if !stale {
            adopt(reported, mayRewindAtOnce: trackChanged || playerChanged)
        }
        if !stale, let takenAt = snapshot.takenAt { lastReadingAt = takenAt }
        updateTicker()
        if let queuedTarget { dispatchPlayback(queuedTarget) }

        if let data = snapshot.artwork {
            blankArtwork?.cancel()
            blankArtwork = nil
            artworkKey = key
            artworkRequestedFor.insert(key)
            decodeArtwork(data, for: key)
        } else if Self.shouldAskForArtwork(
            showing: artwork != nil,
            describesDisplayedTrack: artworkKey == key,
            feedAvailable: feedAvailable,
            alreadyAsked: artworkRequestedFor.contains(key)
        ) {
            artworkRequestedFor.insert(key)
            feed.requestArtwork()
        } else if artworkKey != key {
            artworkKey = key
            // A different track: it has not been asked about, and the set is
            // reset rather than added to, so it holds one key rather than every
            // song of the session.
            artworkRequestedFor = []
            // Measured: on a skip the new title arrives at +51ms and its
            // artwork at +68ms, in the very next line. Blanking the moment the
            // title changes therefore buys nothing and costs two crossfades —
            // old cover to skeleton, skeleton to new cover — where one would
            // do, which is most of what makes a skip feel slow. Waiting out
            // that gap first collapses it to a single swap; a track that
            // genuinely has no cover still falls back to the skeleton, just
            // late enough that nobody sees a flash.
            blankArtwork?.cancel()
            blankArtwork = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                self?.artwork = nil
            }
        }
    }

    /// Whether to ask the helper to send this track's cover again.
    ///
    /// Artwork rides only the update where it changed, because it is the bulk of
    /// the payload and a track keeps one cover for its whole length. So a copy
    /// lost after that update is lost for the rest of the song: the helper still
    /// holds the same artwork id and will never send it again. Losing it is
    /// ordinary — the session going empty while another player takes the display
    /// clears it — and the symptom is an album cover that stays a grey note until
    /// the track changes.
    ///
    /// Asked once per track. A session that genuinely has no cover — a browser
    /// tab, most podcasts — would otherwise be asked twice a second for as long
    /// as it played. And never while the scripted fallback is driving: there is
    /// no helper listening to answer.
    static func shouldAskForArtwork(
        showing: Bool,
        describesDisplayedTrack: Bool,
        feedAvailable: Bool,
        alreadyAsked: Bool
    ) -> Bool {
        guard !showing else { return false }
        guard describesDisplayedTrack else { return false }
        guard feedAvailable else { return false }
        return !alreadyAsked
    }

    /// The icon belonging to a pid, cached because the answer only changes when
    /// the player does — and `NSRunningApplication` is a lookup, not a free read.
    private func refreshSourceIcon(for pid: pid_t?) {
        guard let pid, pid > 0 else {
            if sourceIcon != nil { sourceIcon = nil }
            return
        }
        guard pid != sourceIconPID else { return }
        sourceIconPID = pid
        let icon = NSRunningApplication(processIdentifier: pid)?.icon
        if sourceIcon !== icon { sourceIcon = icon }
    }

    /// JPEG decoding on the main thread is what makes a track change stutter,
    /// so it happens off it and the finished image is handed back.
    private func decodeArtwork(_ data: Data, for key: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let rep = NSBitmapImageRep(data: data), let cgImage = rep.cgImage else {
                // An undecodable payload must not leave the previous track's
                // cover standing: the deferred blank was already cancelled on
                // the strength of this data existing, and no later snapshot
                // for this track will schedule another one.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.artworkKey == key else { return }
                    self.artwork = nil
                }
                return
            }
            let image = NSImage(
                cgImage: cgImage,
                size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
            )
            DispatchQueue.main.async { [weak self] in
                guard let self, self.artworkKey == key else { return }
                self.artwork = image
            }
        }
    }

    private func clear() {
        // The helper publishes an empty record every two seconds whether or not
        // anything is playing, so this runs forever on an idle Mac. `@Published`
        // does not compare before firing, so writing nil over nil still
        // invalidated the whole panel graph twice a minute, all day — the same
        // regression documented and fixed on the playing path above.
        guard track != nil || isPlaying || position != 0 || sourceName != nil || activeApp != nil
            || spotifyTrackID != nil || spotifyISRC != nil || spotifyExactDuration != nil else {
            return
        }
        activeApp = nil
        track = nil
        blankArtwork?.cancel()
        blankArtwork = nil
        artwork = nil
        artworkKey = nil
        // The session is gone, so the next one has earned a fresh ask — this is
        // exactly the path that loses the cover, and remembering that we already
        // asked would make the loss permanent.
        artworkRequestedFor = []
        isPlaying = false
        duration = 0
        position = 0
        sourceName = nil
        sourceIcon = nil
        sourceIconPID = nil
        displayedPlayerPID = nil
        playbackIntent = PlaybackIntent(reported: false)
        reportedPlayback = ReportedPlayback()
        lastReadingAt = nil
        foreignSince = nil
        positionSettled = false
        spotifyTrackID = nil
        spotifyISRC = nil
        spotifyExactDuration = nil
        canSkip = true
        playbackRate = 1
        shuffleEnabled = nil
        repeatMode = nil
        // The rest of the clock's state, which used to survive the session it
        // belonged to: a leftover `pendingSeek` gated the *next* session's
        // first snapshot through the seek-settle path, and the precision loop
        // kept its two-second timer — and its published flag — alive with
        // nothing playing at all.
        anchor = nil
        pendingSeek = nil
        rewindCandidate = nil
        correctionWindow = []
        updatePrecisionSync()
        updateTicker()
    }

    // MARK: - Fallback: scriptable players only

    private func switchToScriptingFallback() {
        guard feedAvailable else { return }
        feedAvailable = false
        // The hold and the search describe the helper's view of Now Playing,
        // which this route no longer has. Left set, taps kept going to a held
        // song the fallback was no longer showing.
        isHolding = false
        searchedUnder = nil
        if otherMediaIsPlaying { otherMediaIsPlaying = false }
        // Nothing reports supported commands on this route, and the two apps it
        // drives both skip — so the arrows come back rather than staying dim
        // on a state no longer being refreshed.
        canSkip = true
        NSLog("Isla: Now Playing helper unavailable, falling back to Music/Spotify scripting")

        let center = DistributedNotificationCenter.default()
        for app in PlayerApp.allCases {
            observers.append(center.addObserver(
                forName: app.changeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.activeApp = app
                    self?.refreshFromPlayers()
                }
            })
        }
        refreshFromPlayers()
    }

    private func refreshFromPlayers() {
        PlayerBridge.currentState { [weak self] state in
            guard let self else { return }
            guard let state else { return self.clear() }

            let playerChanged = self.activeApp != state.app
            self.activeApp = state.app
            self.sourceName = state.app.displayName
            self.track = Track(title: state.title, artist: state.artist, album: state.album, key: state.key)
            let queuedTarget: Bool?
            if playerChanged {
                self.playbackIntent = PlaybackIntent(reported: state.isPlaying)
                queuedTarget = nil
            } else {
                queuedTarget = self.playbackIntent.reconcile(reported: state.isPlaying, at: Date())
            }
            self.isPlaying = self.playbackIntent.desired
            self.duration = state.duration
            self.adopt(state.position)
            self.updateTicker()
            if let queuedTarget { self.dispatchPlayback(queuedTarget) }

            guard self.artworkKey != state.key else { return }
            self.artworkKey = state.key
            self.artwork = nil
            PlayerBridge.artwork(for: state) { [weak self] image in
                guard let self, self.artworkKey == state.key else { return }
                self.artwork = image
            }
        }
    }

    // MARK: - Position

    /// What a report actually says by the time it is read.
    ///
    /// MediaRemote does not keep the elapsed time running. The field is a
    /// reading taken when the session last changed state, and the timestamp
    /// beside it says when — a tab playing for three minutes keeps reporting
    /// the second it started at, and many browsers report a plain zero. Taken
    /// literally, every refresh describes the beginning of the track, and
    /// `adopt` reads the gap as a seek made in the player and obeys it. Which
    /// is exactly what hovering did: open the panel, refresh, bar to zero.
    ///
    /// So the reading is aged by the clock that came with it. A paused session
    /// is left alone — its reading is not moving and there is nothing to add.
    private func reportedPosition(
        from snapshot: NowPlayingFeed.Snapshot,
        isPlaying: Bool
    ) -> TimeInterval {
        // The already-resolved verdict, not the raw fields: a session judged
        // paused must not have its reading aged forward by a rate that has
        // simply not settled yet.
        guard isPlaying, let takenAt = snapshot.takenAt else {
            return snapshot.elapsed
        }
        let since = Date().timeIntervalSince(takenAt)
        // A stamp from the future is not a clock to add to. Trust the reading.
        guard since >= 0 else { return snapshot.elapsed }
        let rate = snapshot.rate > 0 ? snapshot.rate : 1
        let aged = snapshot.elapsed + since * rate
        return snapshot.duration > 0 ? min(aged, snapshot.duration) : aged
    }

    /// The stamp on the last player reading whose position was accepted.
    ///
    /// Deliberately not our own clock. Comparing against `anchor.at` was the
    /// first attempt and it wedges: `anchor.at` is pushed forward by every tap
    /// and every seek we make, so a single local action locks out a player
    /// that has not published since, and the bar then stays frozen for the
    /// whole paused period. Only the player advances this one.
    private var lastReadingAt: Date?

    /// Whether a reading describes a moment we are already past, and so has
    /// nothing to say about where the track stands now.
    ///
    /// This is the pause glitch. MediaRemote does not keep `elapsed` running:
    /// it republishes the reading from the last change of state, so a track
    /// three minutes in still reports the second it started at. While playing
    /// that is harmless, because the reading is aged by the clock beside it.
    /// Paused, there is nothing to age it by — the raw reading is used — and a
    /// pause publishes before the player has refreshed it. The bar was told to
    /// go back three minutes, `adopt` read a jump that large as a deliberate
    /// seek and obeyed, and the next poll brought the real position and threw
    /// it forward again. Two visible jumps for standing still.
    ///
    /// A reading stamped before the moment we last knew the position is not
    /// news, so it is ignored until the player publishes a fresher one.
    private func describesAMomentAlreadyPast(
        _ snapshot: NowPlayingFeed.Snapshot,
        isPlaying: Bool
    ) -> Bool {
        // Playing readings are aged forward by the clock that came with them,
        // so they always describe now and are always worth having.
        guard !isPlaying else { return false }

        guard let takenAt = snapshot.takenAt else {
            // No stamp at all. Freshness cannot be judged, and the sessions
            // that omit one are the same sessions this file documents as
            // reporting elapsed as a plain zero — taking those literally
            // sawtoothed the bar back to the start of the track every poll.
            return true
        }

        guard let lastReadingAt else { return false }
        return takenAt <= lastReadingAt
    }

    private func setAnchor(_ value: TimeInterval) {
        position = value
        anchor = (value, monotonicNow())
    }

    /// Verification-only: one-line breadcrumbs through the position pipeline
    /// and every hold decision. Compiled in, inert in a normal run. On with
    /// `DI_OPEN_LYRICS=1`, which also pins the lyrics page open, or with
    /// `DI_MEDIA=1` alone — the one that can be left running on a Mac somebody
    /// is using, because it draws nothing.
    private func trace(_ message: @autoclosure () -> String) {
        let env = ProcessInfo.processInfo.environment
        guard env["DI_OPEN_LYRICS"] == "1" || env["DI_MEDIA"] == "1" else { return }
        DebugTrail.note(message())
    }

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
    private let forwardTolerance: TimeInterval = 0.05
    /// A disagreement this large is an event — a seek made in the player
    /// itself, or a track change — not a discrepancy to be smoothed over.
    private let seekThreshold: TimeInterval = 2

    /// A large step backwards, waiting for a second reading to agree with it.
    private var rewindCandidate: (value: TimeInterval, at: Date)?

    /// What a big jump backwards on the same track is worth.
    ///
    /// MediaRemote does not keep `elapsed` running: it republishes the reading
    /// from the session's last state change, and Spotify's is routinely a plain
    /// zero — carrying a *fresh* timestamp, so the staleness guard, which only
    /// judges age, waves it through. Taken literally the clock landed at the
    /// start of the track while the music played on a minute in, and everything
    /// downstream followed: the lyrics stage showed the song's opening lines,
    /// and clicking one seeked the player back to them. From the outside that
    /// reads as "every lyric click sends the song backwards".
    ///
    /// Value alone cannot separate that from a rewind the listener really made
    /// in the player — both are simply a smaller number. Persistence can: a
    /// real jump is still there on the next reading, aged forward by the time
    /// between them, while a phantom is contradicted the moment the session
    /// publishes anything real. So one lone step backwards is held, and the
    /// reading after it decides.
    static func corroboratesRewind(
        reading: TimeInterval,
        candidate: (value: TimeInterval, at: Date)?,
        now: Date,
        rate: Double
    ) -> Bool {
        guard let candidate else { return false }
        let elapsed = max(0, now.timeIntervalSince(candidate.at))
        let expected = candidate.value + elapsed * max(rate, 0)
        return abs(reading - expected) <= 1.5
    }

    /// Takes a position reported by the player, without letting the report undo
    /// what has already been shown.
    ///
    /// Every reading arrives late: the helper, the pipe and the parse sit
    /// between the player's clock and ours, so a report is normally a little
    /// *behind* the bar. Accepting it moves the bar backwards — and backwards
    /// is the one direction anybody notices, because time does not do it. So
    /// the two directions get different rules rather than one shared tolerance:
    /// backwards only for something big enough to be a real event, forwards for
    /// anything past the jitter. Left alone, the bar keeps its own count, which
    /// runs at exactly the speed the music does.
    /// - Parameter mayRewindAtOnce: true where a jump backwards needs no
    ///   corroboration because its cause is already known — a new track starts
    ///   at its own beginning, and waiting a reading for that would leave the
    ///   bar showing the old song's position through the start of the new one.
    private func adopt(_ reported: TimeInterval, mayRewindAtOnce: Bool = false) {
        if !positionSettled { positionSettled = true }
        var value = max(0, reported)
        if duration > 0 { value = min(value, duration) }
        let delta = value - position
        let now = Date()
        let nowMono = monotonicNow()

        if delta <= -seekThreshold, !mayRewindAtOnce, isPlaying {
            let confirmed = Self.corroboratesRewind(
                reading: value, candidate: rewindCandidate, now: now,
                rate: playbackRate
            )
            rewindCandidate = confirmed ? nil : (value, now)
            trace(String(format: "adopt rep=%.2f delta=%.2f %@", reported, delta,
                         confirmed ? "REWIND-CONFIRMED" : "REWIND-HELD"))
            guard confirmed else {
                // Keep the clock running under the held reading, so the ignored
                // difference cannot accumulate into the next comparison.
                anchor = (position, nowMono)
                return
            }
            position = value
            anchor = (value, nowMono)
            return
        }
        rewindCandidate = nil
        trace(String(format: "adopt rep=%.2f delta=%.2f %@", reported, delta,
                     delta >= forwardTolerance || delta <= -seekThreshold ? "TAKE" : "rebase"))

        if delta >= forwardTolerance || delta <= -seekThreshold {
            position = value
            anchor = (value, nowMono)
        } else {
            // Keep what is on screen and re-base the clock under it, so the
            // ignored difference cannot accumulate into the next comparison.
            anchor = (position, nowMono)
        }
    }

    private func updateTicker() {
        ticker?.invalidate()
        ticker = nil
        trace("ticker active=\(isActive ? 1 : 0) playing=\(isPlaying ? 1 : 0) spotify=\(displayedPlayerIsSpotify ? 1 : 0)")
        // The precision loop is gated on the same two facts, so it is
        // re-evaluated wherever they change rather than at the handful of call
        // sites that happened to remember.
        updatePrecisionSync()
        guard isPlaying, isActive else {
            boundaryTimer?.invalidate()
            boundaryTimer = nil
            return
        }
        let timer = Timer(timeInterval: Self.positionTickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        // A twentieth of the interval, so the grid stays a grid. At the old
        // 0.05 tolerance on a 0.25 interval the system was free to slide a
        // tick a fifth of the way to the next one.
        timer.tolerance = Self.positionTickInterval / 20
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
        armBoundaryTimer()
    }

    /// Advances the bar from the anchor. Internal so tests can drive the clock
    /// without waiting on the quarter-second timer.
    func tick() {
        guard let anchor, isPlaying else { return }
        let value = anchor.position + (monotonicNow() - anchor.atMono) * playbackRate
        position = duration > 0 ? min(value, duration) : value
        // Whether this was the grid or a boundary, the next boundary is armed
        // from the position just published.
        armBoundaryTimer()
    }
}
