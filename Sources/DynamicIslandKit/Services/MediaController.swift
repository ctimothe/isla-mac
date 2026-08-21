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
    private var anchor: (position: TimeInterval, at: Date)?
    /// How fast the player says the track is moving. Podcast and video apps
    /// routinely play at 1.5× or 2×, and the ticker extrapolating at 1×
    /// regardless meant the bar fell behind between polls and lurched forward
    /// on each one; below 1× it ran ahead and was yanked back.
    private var playbackRate: Double = 1
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
    /// reading lands. The moment the panel opens, the position is a stale
    /// extrapolation from whenever it closed — usually right, but wrong
    /// whenever a pause or seek happened while it was shut, and a lyric line
    /// chosen from it flashes wrong and then corrects. The lyric waits the
    /// ~150ms for a real fix instead.
    @Published private(set) var positionSettled = false
    /// Spotify's catalogue id for the displayed track, when Spotify is the
    /// displayed player and has answered. The word-synced lyrics database is
    /// keyed by it; everything else falls back to title/artist matching.
    @Published private(set) var spotifyTrackID: String?
    private var precisionTimer: Timer?
    private var precisionInFlight = false
    private var spotifyStateObserver: (any NSObjectProtocol)?

    private var ticker: Timer?
    /// Deferred blanking of a cover whose replacement is still in flight.
    private var blankArtwork: Task<Void, Never>?
    private var observers: [Any] = []
    /// Whether the panel is open — the ticker below runs only then.
    private var isActive = false

    // MARK: - Lifecycle

    func start() {
        feed.onUpdate = { [weak self] snapshot in self?.apply(snapshot) }
        feed.onUnavailable = { [weak self] in self?.switchToScriptingFallback() }
        feed.start()

        // Spotify broadcasts every play, pause and track change as a
        // distributed notification carrying its position to the millisecond —
        // measured arriving 10-30ms after the change, needing no permission
        // at all. It does not fire on seeks (MediaRemote pushes a fresh pair
        // ~185ms after those, covering the gap) and delivery is not
        // guaranteed, so it is an anchor source, never the only source.
        spotifyStateObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.applySpotifyBroadcast(note) }
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
        setAnchor(position)
        // Deliberately not `positionSettled = true`. Delivery of these
        // notifications is not guaranteed and they do not fire on seeks, which
        // is exactly why the flag exists — it means "an authoritative reading
        // has landed", and this is an anchor hint, not that reading.
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
        feed.stop()
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        observers.removeAll()
        ticker?.invalidate()
        ticker = nil
    }

    /// Panel visibility. The position ticker hangs off this: it exists to move
    /// a bar, and a bar in a collapsed panel is painted for nobody — at four
    /// wake-ups a second for as long as anything plays. The position itself is
    /// never lost, because the anchor records where it stood and when: opening
    /// computes it from there instantly, and the feed's fresh answer corrects
    /// whatever drifted a beat later.
    func setActive(_ active: Bool) {
        isActive = active
        if active { positionSettled = false }
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
    /// position is corrected against the player itself every two seconds.
    ///
    /// Spotify only, deliberately: it is the player that answers, and the
    /// first use raises macOS's one-time automation consent for it. Scoped to
    /// the open panel so a closed pill costs nothing and prompts for nothing.
    private var displayedPlayerIsSpotify: Bool {
        displayedPlayerApp == .spotify
    }

    /// The scriptable player behind the displayed session, when it is one.
    /// Browsers and everything else answer nil — the honest value, since
    /// shuffle and repeat cannot even be asked about there.
    private var displayedPlayerApp: PlayerApp? {
        guard let pid = displayedPlayerPID,
              let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return nil }
        return PlayerApp.allCases.first { $0.bundleID == bundle }
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

    private func updatePrecisionSync() {
        // Playing, too. A paused track's position cannot move, so asking
        // Spotify where it is every two seconds — a fresh AppleScript compile
        // and an Apple event into another process each time — bought a number
        // already known. Pausing and walking away used to leave that running
        // indefinitely.
        let wanted = isActive && isPlaying && displayedPlayerIsSpotify
        if precisionSync != wanted { precisionSync = wanted }
        guard wanted else {
            precisionTimer?.invalidate()
            precisionTimer = nil
            return
        }
        guard precisionTimer == nil else { return }
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.precisionCorrect() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        precisionTimer = timer
        precisionCorrect()
    }

    private func precisionCorrect() {
        guard !precisionInFlight, displayedPlayerIsSpotify else { return }
        precisionInFlight = true
        let asked = Date()
        PlayerBridge.preciseSpotifyPosition { [weak self] value in
            guard let self else { return }
            self.precisionInFlight = false
            guard let value, self.isActive, self.displayedPlayerIsSpotify else { return }

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
                    askedAt: asked,
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
            // result was a position that froze for a third of a second every
            // two seconds: the exact stutter this path exists to remove.
            let latency = Date().timeIntervalSince(asked)
            let corrected = self.isPlaying ? value + latency / 2 : value
            let delta = corrected - self.position

            // Monotonic while playing: time does not go backwards, so a small
            // backward disagreement is sampling noise and only re-bases the
            // clock. A large one is a real rewind and is taken whole.
            if delta >= 0 || delta <= -1.0 || !self.isPlaying {
                self.setAnchor(corrected)
            } else {
                self.anchor = (self.position, Date())
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
        dispatch(feed: .next, script: { PlayerBridge.next($0) }, key: .next)
    }

    func previous() {
        dispatch(feed: .previous, script: { PlayerBridge.previous($0) }, key: .previous)
    }

    func seek(to seconds: TimeInterval) {
        guard duration > 0 else { return }
        let clamped = min(max(0, seconds), duration)
        let origin = anchor.map { $0.position } ?? position
        setAnchor(clamped)
        pendingSeek = (clamped, Date(), origin)
        lastSeek = (clamped, Date(), origin)
        if feedAvailable {
            feed.seek(to: clamped, playerPID: displayedPlayerPID)
        } else if let activeApp {
            PlayerBridge.seek(activeApp, to: clamped)
        }
    }

    private func dispatch(
        feed command: NowPlayingFeed.Command,
        script: (PlayerApp) -> Void,
        key: PlayerBridge.MediaKey
    ) {
        if feedAvailable {
            feed.send(command, playerPID: displayedPlayerPID)
        } else if let activeApp {
            script(activeApp)
        } else {
            PlayerBridge.postMediaKey(key.rawValue)
        }
    }

    private func dispatchPlayback(_ playing: Bool) {
        // The per-client command set has no toggle of its own (#23), so the
        // desired state travels explicitly.
        dispatch(
            feed: playing ? .play : .pause,
            script: { PlayerBridge.playPause($0) },
            key: .playPause
        )
    }

    // MARK: - Feed

    /// Not private: the feed hands snapshots to this one entry point, and
    /// tests drive it the same way rather than standing up the real helper
    /// process.
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
        let fresh = Track(title: snapshot.title, artist: snapshot.artist, album: snapshot.album, key: key)
        let trackChanged = track?.key != key
        if track != fresh { track = fresh }
        let playerChanged = displayedPlayerPID != snapshot.playerPID
        // Adopted *before* the Spotify id is asked for. Asking first tested the
        // player the last snapshot came from: switching Music → Spotify skipped
        // the lookup for the first Spotify track, so its word-synced lyrics
        // silently degraded, and switching the other way asked Spotify what it
        // was playing and then pinned that id to a Music track, keying its
        // lyrics to the wrong song entirely.
        displayedPlayerPID = snapshot.playerPID
        if trackChanged || playerChanged {
            spotifyTrackID = nil
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
        // The rate the clock extrapolates at, from the player itself. Zero is
        // what a paused session reports and says nothing about how fast it will
        // resume, so the last positive rate is kept.
        if snapshot.rate > 0 { playbackRate = snapshot.rate }
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
                if !stale { adopt(reported) }
            }
        } else if !stale {
            adopt(reported)
        }
        if !stale, let takenAt = snapshot.takenAt { lastReadingAt = takenAt }
        updateTicker()
        if let queuedTarget { dispatchPlayback(queuedTarget) }

        if let data = snapshot.artwork {
            blankArtwork?.cancel()
            blankArtwork = nil
            artworkKey = key
            decodeArtwork(data, for: key)
        } else if artworkKey != key {
            artworkKey = key
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
        guard track != nil || isPlaying || position != 0 || sourceName != nil || activeApp != nil else {
            return
        }
        activeApp = nil
        track = nil
        blankArtwork?.cancel()
        blankArtwork = nil
        artwork = nil
        artworkKey = nil
        isPlaying = false
        duration = 0
        position = 0
        sourceName = nil
        displayedPlayerPID = nil
        playbackIntent = PlaybackIntent(reported: false)
        reportedPlayback = ReportedPlayback()
        lastReadingAt = nil
        foreignSince = nil
        positionSettled = false
        spotifyTrackID = nil
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
        updatePrecisionSync()
        updateTicker()
    }

    // MARK: - Fallback: scriptable players only

    private func switchToScriptingFallback() {
        guard feedAvailable else { return }
        feedAvailable = false
        // Nothing reports supported commands on this route, and the two apps it
        // drives both skip — so the arrows come back rather than staying dim
        // on a state no longer being refreshed.
        canSkip = true
        NSLog("Dynamic Island: Now Playing helper unavailable, falling back to Music/Spotify scripting")

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
        anchor = (value, Date())
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
    private func adopt(_ reported: TimeInterval) {
        if !positionSettled { positionSettled = true }
        var value = max(0, reported)
        if duration > 0 { value = min(value, duration) }
        let delta = value - position

        if delta >= forwardTolerance || delta <= -seekThreshold {
            position = value
            anchor = (value, Date())
        } else {
            // Keep what is on screen and re-base the clock under it, so the
            // ignored difference cannot accumulate into the next comparison.
            anchor = (position, Date())
        }
    }

    private func updateTicker() {
        ticker?.invalidate()
        ticker = nil
        // The precision loop is gated on the same two facts, so it is
        // re-evaluated wherever they change rather than at the handful of call
        // sites that happened to remember.
        updatePrecisionSync()
        guard isPlaying, isActive else { return }
        // Four times a second: the bar advances in sub-pixel steps, so it reads
        // as smooth without any animation smoothing the seek away with it.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func tick() {
        guard let anchor, isPlaying else { return }
        let value = anchor.position + Date().timeIntervalSince(anchor.at) * playbackRate
        position = duration > 0 ? min(value, duration) : value
    }
}
