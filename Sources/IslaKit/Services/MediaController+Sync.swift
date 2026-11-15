import AppKit
import Combine

/// Lyric boundaries, precision sync and the position clock. Stored properties live in MediaController.swift.
extension MediaController {
    // MARK: - Lyric boundaries

    /// When the next lyric wake is scheduled for, if one is. Recorded when the
    /// wake is armed rather than recomputed, so a test sees what was scheduled.
    var lyricWakeDateForTests: Date? { lyricWakeDate }
    /// The one armed wake, if any: tests read its construction back from
    /// libdispatch and check a re-arm cancels the source it replaces.
    var lyricWakeSourceForTests: DispatchSourceTimer? { boundaryTimer }

    /// What the coordinator registered, sorted: every line's start and every
    /// end `LyricSweep.effectiveEnd` honours.
    var lyricBoundariesForTests: [TimeInterval] { lyricBoundaries }

    func setLyricBoundaries(_ boundaries: [TimeInterval], lead: @escaping @MainActor () -> TimeInterval) {
        lyricBoundaries = boundaries.sorted()
        lyricLead = lead
        publishClockReadings(linesChanged: true)
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

    /// Runs `handler` on the main queue `delay` seconds from now, as close to
    /// on time as the machine allows, passing how late it actually ran.
    ///
    /// This was a Foundation `Timer` with tolerance 0 on the main run loop
    /// whose block hopped to `tick()` through a `Task { @MainActor }`. The
    /// lyric lab (L4b) measured it 4ms late at the median and 10ms at p99 on
    /// an idle Mac, and 17.7ms at worst with every core busy — later than a
    /// whole 60Hz frame, on the one wake whose point is the frame a line is
    /// due on. Tolerance 0 does not exempt a run-loop timer from the run loop's
    /// and the kernel's coalescing, and that, not the hop (about 0.05ms), was
    /// the 4ms. A `.strict` dispatch source with zero leeway is exempt: idle,
    /// it runs 0.07ms late at the median and 0.2ms at p99. With every core
    /// busy it still runs up to about 11ms late (p50 1.8ms), and that part is
    /// the main thread waiting for a core, which no choice of timer changes.
    ///
    /// The handler runs on the source's own turn of the main queue — the main
    /// actor's executor, which is what `assumeIsolated` checks — so the tick
    /// is not queued behind whatever else is waiting. A strict timer costs a
    /// little more energy per wake than a coalesced one; there is only ever one
    /// armed, for the next line, and only while a lyric timeline is registered
    /// on an open panel that is playing.
    ///
    /// Static and nonisolated so the lab measures this very construction
    /// rather than a copy of it that could drift. A display link was the other
    /// candidate and was rejected: a wake every frame, for an event every few
    /// seconds.
    nonisolated static func scheduleLyricWake(
        after delay: TimeInterval,
        _ handler: @escaping @MainActor (_ late: TimeInterval) -> Void
    ) -> DispatchSourceTimer {
        let source = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        let deadline = DispatchTime.now() + max(delay, 0)
        source.schedule(deadline: deadline, repeating: .never, leeway: .nanoseconds(0))
        source.setEventHandler {
            let late = Double(Int64(DispatchTime.now().uptimeNanoseconds) - Int64(deadline.uptimeNanoseconds)) / 1e9
            MainActor.assumeIsolated { handler(late) }
        }
        source.resume()
        return source
    }

    /// Cancels the armed lyric wake, if there is one. A dispatch source keeps
    /// firing after the last reference to it goes unless it is cancelled, so
    /// every path that drops one comes through here.
    func cancelLyricWake() {
        boundaryTimer?.cancel()
        boundaryTimer = nil
        lyricWakeDate = nil
    }

    func armBoundaryTimer() {
        cancelLyricWake()
        guard isPlaying, isActive, let anchor, !lyricBoundaries.isEmpty else { return }
        // Deliberately not `extrapolatedPosition()`: that one stops at the
        // track's end, and lyric files do stamp lines past it. A clock pinned
        // at the end would re-arm the same unreachable boundary on every wake
        // for as long as the player kept saying it was playing.
        let now = anchor.position + (monotonicNow() - anchor.atMono) * playbackRate
        guard let delay = Self.nextLyricWake(
            boundaries: lyricBoundaries, lead: lyricLead(), position: now, rate: playbackRate
        ) else { return }
        // The millisecond floor the run-loop timer had, kept so the arithmetic
        // the lab checks (L4a) still means what it meant.
        let wait = max(delay, 0.001)
        lyricWakeDate = Date().addingTimeInterval(wait)
        boundaryTimer = Self.scheduleLyricWake(after: wait) { [weak self] late in
            guard let self else { return }
            // In the shipping app the lateness depends on App Nap and the
            // process's task role, which no xctest run reproduces; a DI_MEDIA
            // trail is how a real run shows it.
            self.trace(String(format: "lyric wake late=%.3fms", late * 1000))
            self.tick()
            self.onLyricWakeForTests?()
        }
    }
    /// How long an active panel waits for an authoritative reading before it
    /// settles for the position it has. Long enough for the ~150ms a real fix
    /// takes, short enough that nobody reads it as missing lyrics.
    static var settleGrace: TimeInterval = 1.2

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
    var displayedPlayerIsSpotify: Bool {
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
    var displayedPlayerApp: PlayerApp? {
        guard let pid = displayedPlayerPID, let bundle = bundleIdentifierForPID(pid) else { return nil }
        return PlayerApp.allCases.first { $0.bundleID == bundle }
    }

    /// The bundle id behind the displayed session, nil when there is none or
    /// it cannot be named. The lyric stage's volume control reads it when it
    /// opens and when the song's source changes, to pick whose volume it moves
    /// (`PlayerVolumeTarget.forSource`, owner 2026-10-26).
    var displayedSourceBundleID: String? {
        displayedPlayerPID.flatMap(bundleIdentifierForPID)
    }

    /// A coarse player class for lyric matching. It is metadata, never an
    /// account or a process identifier, and lets timing policy distinguish
    /// scriptable players from unmeasured Now Playing publishers.
    var lyricPlayerID: String {
        displayedPlayerApp?.rawValue ?? "other"
    }

    /// Asks Spotify which track this is, and asks again if it does not answer.
    ///
    /// The lock-card heart is the id's one reader, and it is simply not drawn
    /// while the id is nil. One attempt was not enough. The very first lookup
    /// after a grant routinely fails — it is the call that triggers macOS's
    /// one-time automation consent, and it returns nothing while the dialog is
    /// still on screen — and a script can also come back empty if Spotify is
    /// mid-track-change. The id then stayed nil for the rest of that track, so
    /// the heart never appeared for the song that happened to be playing at
    /// launch, which is exactly when somebody would look for it.
    ///
    /// Spotify's own announcement usually supplies the id first, with no
    /// Apple Event at all (`adoptAnnouncedTrackID`); this is for the track that
    /// was playing before any announcement was heard. It asks only where
    /// `mayScript` lets it, and only for a connected account, since without
    /// one there is no heart to draw (G-005).
    func requestSpotifyTrackID(for key: String, playerPID: pid_t?, attempt: Int) {
        // The key first: a retry scheduled for a song since skipped asked
        // Spotify again only to drop the answer.
        guard track?.key == key, displayedPlayerIsSpotify, spotifyTrackID == nil,
              spotifyTrackIDLookupKey != key,
              spotifyAccountConnected(), mayScript(.spotify) else { return }
        // One question in flight per track. The panel opening and the consent
        // arriving can both ask for the same missing id a moment apart.
        spotifyTrackIDLookupKey = key
        spotifyTrackIDLookup { [weak self] answer in
            guard let self else { return }
            if self.spotifyTrackIDLookupKey == key { self.spotifyTrackIDLookupKey = nil }
            guard self.track?.key == key,
                  self.displayedPlayerPID == playerPID,
                  self.spotifyTrackID == nil else { return }
            switch answer {
            case let .track(id, name, artist):
                // MediaRemote trails Spotify by about a second, so right after
                // a skip the script names the next song while the island still
                // shows this one. The key guard above cannot see that — it is
                // still this track's key — and the heart then liked the song
                // the user had just skipped to (K-016). A mismatch is a
                // non-answer: asked again, by when the report has caught up or
                // the key has moved on.
                if Self.names(self.track, name: name, artist: artist) {
                    self.spotifyTrackID = id
                    // No catalogue request follows. One went to the Web API
                    // for every track, and its ISRC and exact duration had no
                    // reader (G-005); `requestSpotifyMetadata` stays for the
                    // lyrics work that may want it.
                    return
                }
            case .notATrack:
                // An episode, an ad or a local file. It has no id to find, and
                // asking four more times cost four more Apple Events (K-014).
                return
            case .noAnswer:
                break
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

    static let spotifyTrackPrefix = "spotify:track:"

    /// Spotify's last announcement that named a catalogue track.
    struct SpotifyAnnouncement {
        var id: String
        var name: String
        var artist: String
    }

    /// Takes the heart's id from Spotify's own announcement when it names the
    /// song on screen. The announcement is a distributed notification that
    /// needs no permission at all, so on a fresh grant — or none — the heart
    /// usually has its id after the first play, pause or skip without a single
    /// Apple Event.
    func adoptAnnouncedTrackID() {
        guard spotifyTrackID == nil, displayedPlayerIsSpotify,
              let announced = lastSpotifyAnnouncement,
              Self.names(track, name: announced.name, artist: announced.artist) else { return }
        spotifyTrackID = announced.id
    }

    /// Whether Spotify's name and artist describe the track on screen.
    ///
    /// The name must match, ignoring case and surrounding space. The artist is
    /// looser: MediaRemote and Spotify's scripting do not always list the same
    /// performers for a song with several, so one containing the other is a
    /// match, and an empty side says nothing either way.
    private static func names(_ track: Track?, name: String, artist: String) -> Bool {
        guard let track else { return false }
        let trimmed = { (text: String) in text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard trimmed(name) == trimmed(track.title) else { return false }
        let theirs = trimmed(artist)
        let ours = trimmed(track.artist)
        if theirs.isEmpty || ours.isEmpty { return true }
        return theirs == ours || theirs.contains(ours) || ours.contains(theirs)
    }

    /// Fetches the catalogue's exact identity for the resolved Spotify track.
    ///
    /// Nothing calls this any more. It ran beside every resolved id, and its
    /// answer — `spotifyISRC`, `spotifyExactDuration` — had no reader outside
    /// this file, so every Spotify track cost a request to api.spotify.com for
    /// nothing (G-005). It and its fields stay, tested, for the lyric matching
    /// they were built for to wire up or delete.
    ///
    /// One attempt, not the retry loop above: a lookup that fails simply
    /// leaves the fields nil and title/artist matching covers the track. A
    /// failure never needs polling for the rest of the song — and a failed
    /// lookup must never raise anything, because there is no user-grantable
    /// permission behind it.
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

    /// Re-decides the precision loop after the lyrics switch moved.
    func refreshPrecisionSync() { updatePrecisionSync() }

    func updatePrecisionSync() {
        // Playing, too. A paused track's position cannot move, so asking
        // Spotify where it is every second — a fresh AppleScript compile
        // and an Apple event into another process each time — bought a number
        // already known. Pausing and walking away used to leave that running
        // indefinitely.
        //
        // And only while lyrics are on. The correction exists for the words:
        // a scrubber cannot show the tenth of a second it buys. Without this
        // gate it ran whenever the panel was open on Spotify or Music, one
        // AppleScript compile a second for a number nothing was drawing.
        //
        // And only where the player may be asked. With Automation refused it
        // kept sending an Apple Event a second and logging -1743 for each,
        // about 3,600 log records an hour crowding Diagnostics (K-014); over
        // the lock card it would raise the first prompt under the shield.
        let wanted = isActive && isPlaying && precisionPlayer.map(mayScript) == true && lyricsShown()
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
        // Unsettled only when a correction can actually be asked for. Over the
        // lock card on a Mac that has not granted Automation, none can, and
        // nothing else settles the position there: the card's lyric would
        // have waited on an answer that was never going to come. The
        // broadcast's own millisecond reading is then the best there is.
        guard let player = precisionPlayer, isActive, mayScript(player) else { return }
        positionSettled = false
        precisionCorrect()
    }

    private func precisionCorrect() {
        // Active, as well as allowed: the answer is dropped below unless the
        // clock is on screen, so asking with everything closed — on every
        // Spotify announcement — was an Apple Event for nothing.
        guard !precisionInFlight, isActive, let player = precisionPlayer, mayScript(player) else { return }
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
            // The player may already be on the next song while the island
            // still names this one; its position is not this song's.
            if self.isAwaitingTrackChange() { return }
            if self.readingLooksLikeAnotherSong(corrected) {
                self.beginAwaitingTrackChange(String(format: "player back at %.2f", corrected))
                return
            }
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
    func reportedPosition(
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
    func describesAMomentAlreadyPast(
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

    func setAnchor(_ value: TimeInterval) {
        position = value
        anchor = (value, monotonicNow())
    }

    /// Verification-only: one-line breadcrumbs through the position pipeline
    /// and every hold decision. Compiled in, inert in a normal run. On with
    /// `DI_OPEN_LYRICS=1`, which also pins the lyrics page open, or with
    /// `DI_MEDIA=1` alone — the one that can be left running on a Mac somebody
    /// is using, because it draws nothing.
    func trace(_ message: @autoclosure () -> String) {
        guard DebugTrail.openLyrics || DebugTrail.media else { return }
        DebugTrail.note(message())
    }

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
    func adopt(_ reported: TimeInterval, mayRewindAtOnce: Bool = false) {
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
                // difference cannot accumulate into the next comparison — from
                // where it stands now, not from the last tick (see below).
                anchor = (extrapolatedPosition(at: nowMono), nowMono)
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
            // Keep the clock and re-base it, so the ignored difference cannot
            // accumulate into the next comparison. On the clock as it runs,
            // not on `position`: that is the last tick, up to a grid interval
            // old, and re-basing on it threw the interval away on every such
            // reading — the lab's clock-fidelity run left the anchor behind a
            // perfect player 36% of the time, by up to 50ms. `delta` is still
            // measured against what is on screen, so which readings are taken
            // and which are held is unchanged.
            anchor = (extrapolatedPosition(at: nowMono), nowMono)
        }
    }

    func updateTicker() {
        ticker?.invalidate()
        ticker = nil
        trace("ticker active=\(isActive ? 1 : 0) playing=\(isPlaying ? 1 : 0) spotify=\(displayedPlayerIsSpotify ? 1 : 0)")
        // The precision loop is gated on the same two facts, so it is
        // re-evaluated wherever they change rather than at the handful of call
        // sites that happened to remember.
        updatePrecisionSync()
        guard isPlaying, isActive else {
            cancelLyricWake()
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
        guard anchor != nil, isPlaying else { return }
        position = extrapolatedPosition()
        // Whether this was the grid or a boundary, the next boundary is armed
        // from the position just published.
        armBoundaryTimer()
    }
}
