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

    private var activeApp: PlayerApp?
    private var artworkKey: String?
    private var anchor: (position: TimeInterval, at: Date)?
    /// Where we asked the player to jump, and when — see `apply`.
    private var pendingSeek: (target: TimeInterval, at: Date)?
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
        guard active else { return }
        tick()
        if feedAvailable {
            feed.refresh()
        } else {
            refreshFromPlayers()
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

        // The PID rides along with title/artist/album: two different players
        // can report the exact same metadata, and without it a switch
        // between them would read as no change at all — stale commands and
        // artwork surviving into the newly displayed track.
        let key = "\(snapshot.playerPID ?? 0)|\(snapshot.title)|\(snapshot.artist)|\(snapshot.album)"
        track = Track(title: snapshot.title, artist: snapshot.artist, album: snapshot.album, key: key)
        let playerChanged = displayedPlayerPID != snapshot.playerPID
        displayedPlayerPID = snapshot.playerPID
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
        isPlaying = playbackIntent.desired
        duration = snapshot.duration
        sourceName = snapshot.source
        // Both directions travel together: no player has ever offered one
        // without the other, and two separately dimmed arrows would read as
        // a glitch rather than a limit.
        canSkip = snapshot.offers(.next) && snapshot.offers(.previous)

        let reported = reportedPosition(from: snapshot, isPlaying: reportedPlaying)

        // A player needs a moment to act on a seek, and until it does it keeps
        // reporting the old position. Accepting that would yank the bar back.
        if let pending = pendingSeek {
            let settled = abs(reported - pending.target) < 2.5
            let expired = Date().timeIntervalSince(pending.at) > 1.5
            if settled || expired {
                pendingSeek = nil
                adopt(reported)
            }
        } else if !describesAMomentAlreadyPast(snapshot, isPlaying: reportedPlaying) {
            adopt(reported)
        }
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
            guard let rep = NSBitmapImageRep(data: data), let cgImage = rep.cgImage else { return }
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
        guard !isPlaying, let takenAt = snapshot.takenAt, let anchor else { return false }
        return takenAt < anchor.at
    }

    private func setAnchor(_ value: TimeInterval) {
        position = value
        anchor = (value, Date())
    }

    /// Below this a forward correction is pipeline jitter, not movement.
    private let forwardTolerance: TimeInterval = 0.75
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
