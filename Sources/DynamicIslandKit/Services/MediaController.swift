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
    /// Where we asked the player to jump, and when — see `apply`.
    private var pendingSeek: (target: TimeInterval, at: Date)?
    /// True while the position is being corrected against the player's own
    /// clock rather than MediaRemote's. The lyric lead reads this: with a
    /// precise position most of the compensation is unnecessary.
    @Published private(set) var precisionSync = false
    private var precisionTimer: Timer?
    private var precisionInFlight = false

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
    }

    func stop() {
        precisionTimer?.invalidate()
        precisionTimer = nil
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
        updateTicker()
        updatePrecisionSync()
        guard active else { return }
        tick()
        if feedAvailable {
            feed.refresh()
        } else {
            refreshFromPlayers()
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
        guard let pid = displayedPlayerPID else { return false }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == PlayerApp.spotify.bundleID
    }

    private func updatePrecisionSync() {
        let wanted = isActive && displayedPlayerIsSpotify
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
        PlayerBridge.preciseSpotifyPosition { [weak self] value in
            guard let self else { return }
            self.precisionInFlight = false
            guard let value, self.isActive, self.displayedPlayerIsSpotify else { return }
            // The player's own answer outranks every heuristic: no tolerance,
            // no ratchet — while paused it simply confirms where we stand,
            // and a pending seek still gets its settle window.
            guard self.pendingSeek == nil else { return }
            self.setAnchor(value)
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
        setAnchor(clamped)
        pendingSeek = (clamped, Date())
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
        if track != fresh { track = fresh }
        let playerChanged = displayedPlayerPID != snapshot.playerPID
        displayedPlayerPID = snapshot.playerPID
        if playerChanged {
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
        let stale = describesAMomentAlreadyPast(snapshot, isPlaying: reportedPlaying)
        if let pending = pendingSeek {
            let settled = abs(reported - pending.target) < 2.5
            let expired = Date().timeIntervalSince(pending.at) > 1.5
            if settled || expired {
                pendingSeek = nil
                // Even on expiry the reading has to be worth having. A seek
                // made while paused often gets no fresh reading at all until
                // playback resumes, and adopting the pre-seek one then threw
                // the bar back to where the track was before the drag — the
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
        canSkip = true
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
        let value = anchor.position + Date().timeIntervalSince(anchor.at)
        position = duration > 0 ? min(value, duration) : value
    }
}
