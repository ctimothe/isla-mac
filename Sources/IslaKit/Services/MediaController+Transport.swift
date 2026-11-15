import AppKit
import Combine

/// Shuffle, repeat, transport and unconfirmed taps. Stored properties live in MediaController.swift.
extension MediaController {
    // MARK: - Shuffle & repeat

    /// Asks the displayed player where its switches stand. Cheap enough to
    /// call on pane appearance and after every toggle; a no-op for sessions
    /// that cannot answer.
    func refreshPlaybackModes() {
        // A test's stand-in for the player's answer stands until it is cleared;
        // the real question would script a running player (`PlayerBridge`).
        if playbackModesForTests != nil || musicFavoriteForTests != nil { return }
        guard let app = displayedPlayerApp else {
            shuffleEnabled = nil
            repeatMode = nil
            musicFavorite = nil
            favoriteHold.forget()
            return
        }
        supportsRepeatOne = app == .music
        guard mayScript(app) else { return }
        let askedAbout = track?.key
        playbackModesReader(app) { [weak self] modes in
            guard let self, self.displayedPlayerApp == app else { return }
            self.shuffleEnabled = modes?.shuffle
            self.repeatMode = modes?.repeatMode
            // Asked about the song before this one: its favourite is that
            // song's, and the new song's own question is already queued
            // behind it. Taken as this one's, the star wore the last song's
            // answer until the next read.
            guard self.track?.key == askedAbout else { return }
            self.musicFavorite = app == .music
                ? self.favoriteHold.shown(answer: modes?.favorite, trackKey: askedAbout, at: self.monotonicNow())
                : nil
        }
    }

    /// Brings the app playing the song forward: the cover of a song with no
    /// lyrics to open is a way back to its player (spec §19.6). The player's own
    /// window — Isla itself never activates.
    func bringPlayerForward() {
        guard !PlayerBridge.isRunningTests, let pid = displayedPlayerPID,
              let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.activate()
    }

    /// Music's star, optimistic like shuffle: the star answers the click now
    /// and stays there until Music agrees (`MusicFavoriteHold`). Music refusing
    /// the command puts it back at once; Music never catching up puts it back
    /// when the hold's window runs out.
    func toggleMusicFavorite() {
        guard let current = musicFavorite else { return }
        if musicFavoriteForTests != nil {
            musicFavorite = !current
            return
        }
        guard let app = displayedPlayerApp, app == .music, let key = track?.key else { return }
        let tap = favoriteHold.tapped(trackKey: key, wants: !current, at: monotonicNow())
        musicFavorite = tap.wants
        favoriteWriter(app, tap.wants) { [weak self] accepted in
            guard let self, !accepted, self.favoriteHold.refused(tap) else { return }
            // Back where it was before the tap, then asked: a refresh that may
            // not ask (no consent) would otherwise leave the tap's star up.
            self.musicFavorite = current
            self.refreshPlaybackModes()
        }
        for delay in MusicFavoriteHold.readBacks {
            favoriteTimer(delay) { [weak self] in
                // Music agreed, a later tap replaced this one, or the song
                // moved on: nothing left to ask about.
                guard let self, self.favoriteHold.tap == tap else { return }
                self.refreshPlaybackModes()
            }
        }
        favoriteTimer(MusicFavoriteHold.window) { [weak self] in
            guard let self, self.favoriteHold.expired(tap) else { return }
            self.refreshPlaybackModes()
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

    // MARK: - Transport

    /// Whether a transport command has somewhere truthful to go: a song on
    /// the island, and a route that reaches the player showing it.
    ///
    /// Every on-screen control is already hidden without a track (MediaPane,
    /// LockScreenCard), so what this decides is the Shortcuts actions and
    /// anything bound to them (J-005). With Music Only hiding a paused YouTube
    /// tab, Play or Pause went to the helper with no pid, the helper handed it
    /// to whoever owned Now Playing — the hidden tab — and the video started
    /// while the intent reported success. A command for nothing shown now
    /// goes nowhere and says so.
    ///
    /// Not "the displayed pid is known": a helper without the pid symbol
    /// reports pid 0 for every track, and refusing those would end transport
    /// there altogether.
    private var transportReachesShownPlayer: Bool {
        guard track != nil else { return false }
        return heldScriptablePlayer != nil || feedAvailable || activeApp != nil
    }

    /// False, and nothing sent, when the island shows nothing to play or
    /// pause — see `transportReachesShownPlayer`. The check comes before the
    /// intent is touched: a tap with no player used to leave a command in
    /// flight that no report would ever resolve, and every tap after it was
    /// coalesced behind that one and never sent (J-006).
    @discardableResult
    func togglePlayPause() -> Bool {
        guard transportReachesShownPlayer else { return false }
        // Where the song stands at the tap, read while the clock still runs.
        // `position` is the last tick: a quarter-second old with the panel
        // open, so every pause stepped the bar and the sung word back by up
        // to that much before the player's own report threw them forward
        // again; and as old as the panel's last closing when a Shortcut
        // pauses, where the song then sat paused minutes behind itself.
        let standsAt = extrapolatedPosition()
        // The clock as it was before a run of taps nobody has confirmed yet,
        // in case nobody ever does (`settleUnconfirmedPlayback`).
        if !playbackIntent.hasInFlightCommand { clockBeforeUnconfirmedTaps = (standsAt, monotonicNow()) }
        let target = playbackIntent.toggle(at: Date())
        // The latest tap owns the icon immediately. Reports from before the
        // command completed are reconciled without repainting it backwards.
        isPlaying = playbackIntent.desired
        setAnchor(standsAt)
        updateTicker()
        playbackTapped.send(isPlaying)
        if let target { dispatchPlayback(target) }
        return true
    }

    @discardableResult
    func next() -> Bool {
        guard transportReachesShownPlayer else { return false }
        trace("cmd next")
        beginAwaitingTrackChange("cmd next")
        trackChangeExpected.send()
        dispatch(feed: .next, transport: .next)
        return true
    }

    @discardableResult
    func previous() -> Bool {
        guard transportReachesShownPlayer else { return false }
        trace("cmd previous")
        // A few seconds in, most players answer "previous" by restarting the
        // song, and the start of the same song is then the right thing to show
        // at once. Isla's own Spotify route seeks to 0 before stepping back, so
        // there it always changes the song. Read off the running clock:
        // `position` is the last tick, and with the panel shut that can be
        // the song's first second while the music is minutes in.
        if extrapolatedPosition() > 3, heldScriptablePlayer != .spotify {
            restartExpectedUntil = Date().addingTimeInterval(1.5)
        } else {
            beginAwaitingTrackChange("cmd previous")
            // Only here: a restart keeps the song, and holding the picture of
            // a song that is not leaving would only freeze its clock.
            trackChangeExpected.send()
        }
        dispatch(feed: .previous, transport: .previous)
        return true
    }

    // MARK: - A skip the island has not caught up with

    /// How long a skip may take to be named before the start of the same song
    /// is believed. The slowest filmed took 700ms.
    static var trackChangeGrace: TimeInterval = 1.2

    func beginAwaitingTrackChange(_ reason: String) {
        guard awaitingTrackChangeSince == nil else { return }
        awaitingTrackChangeSince = Date()
        trace("await track change: \(reason)")
    }

    /// Whether readings for the song on screen are being held back, ending
    /// the wait once its grace has run out.
    func isAwaitingTrackChange() -> Bool {
        guard let since = awaitingTrackChangeSince else { return false }
        guard Date().timeIntervalSince(since) < Self.trackChangeGrace else {
            awaitingTrackChangeSince = nil
            // No new name came, so it was a restart; the readings now held are
            // believed, rather than each one opening a fresh wait.
            restartExpectedUntil = Date().addingTimeInterval(1.5)
            trace("await track change: none came; a restart")
            return false
        }
        return true
    }

    /// Whether a reading for the song on screen puts the player back at its
    /// very start with nothing here having asked for that — the shape of a
    /// skip whose name has not been reported yet.
    func readingLooksLikeAnotherSong(_ reading: TimeInterval) -> Bool {
        guard pendingSeek == nil, position >= 3, reading < 1.5 else { return false }
        if let until = restartExpectedUntil, Date() < until { return false }
        // A song that ran to its end starting over is repeat-one, not a skip.
        if duration > 0, position >= duration - 3 { return false }
        return true
    }

    /// Whether a new song's first report carries the elapsed time of the song
    /// before it.
    ///
    /// Filmed on 2026-09-21: a skip from 3:12 into a 2:15 song showed the new
    /// title at 2:15 of 2:15 — the old position, clamped — with its last
    /// lyric line, for 1.2s. A reading past the new song's end, or matching
    /// where the old one stood, belongs to the old one.
    static func elapsedBelongsToPreviousSong(
        reported: TimeInterval,
        previousPosition: TimeInterval,
        newDuration: TimeInterval
    ) -> Bool {
        if newDuration > 0, reported >= newDuration - 0.5 { return true }
        // At any position: skipped two seconds in, the next song still
        // arrived at 0:02 and then stepped back to 0:00 (filmed 2026-09-21).
        // Near the start both readings are close to 0, and 0 is then right.
        return abs(reported - previousPosition) < 1.5
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
            sendToPlayer(.seek(seconds: clamped), held)
        } else if feedAvailable {
            feed.seek(to: clamped, playerPID: displayedPlayerPID)
        } else if let activeApp {
            sendToPlayer(.seek(seconds: clamped), activeApp)
        }
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

    /// There used to be a fourth branch, a system media key for when no route
    /// reached a player. Posting one needs Accessibility, which Isla never
    /// asks for, so it silently did nothing (J-006); and with nothing shown it
    /// would have reached whichever session macOS picked, the very one the
    /// island had declined to show. Asking for that permission, for a route
    /// that matters only when the island has nothing to show, was rejected:
    /// the verbs refuse that case before they get here instead.
    private func dispatch(
        feed command: NowPlayingFeed.Command,
        transport action: PlayerBridge.Transport
    ) {
        if let held = heldScriptablePlayer {
            sendToPlayer(action, held)
        } else if feedAvailable {
            // Only with a song shown. Without one the helper, given no pid,
            // hands the command to whoever owns Now Playing — a session the
            // island may have filtered out. The verbs check this already;
            // the queued tap `apply` sends is the other way in.
            guard track != nil else { return }
            sendToFeed(command, displayedPlayerPID)
        } else if let activeApp {
            sendToPlayer(action, activeApp)
        }
    }

    func dispatchPlayback(_ playing: Bool) {
        // The per-client command set has no toggle of its own (#23), so the
        // desired state travels explicitly.
        dispatch(feed: playing ? .play : .pause, transport: playing ? .play : .pause)
        // A song held under a film in a player that cannot be scripted —
        // Tidal, Deezer — went through the helper to its pid, and nothing
        // will ever say what it did: MediaRemote describes the film, and the
        // player has no announcement Isla hears. Waiting for a confirmation
        // there meant the second tap, and every one after it, was never sent.
        if isHolding, heldScriptablePlayer == nil {
            _ = playbackIntent.settleUnconfirmed(at: Date(), took: true)
            return
        }
        chasePlaybackConfirmation(after: PlaybackIntent.confirmationTimeout + 0.05, last: false)
    }

    // MARK: - A tap nobody confirmed

    /// How long the player has to answer once it is asked outright, before
    /// the command is settled without it.
    static var playbackChaseGrace: TimeInterval = 1.0

    private func chasePlaybackConfirmation(after delay: TimeInterval, last: Bool) {
        playbackChase?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.settleUnconfirmedPlayback(last: last) }
        }
        playbackChase = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// A play or pause command went out and no report has confirmed or
    /// contradicted it (`PlaybackIntent.settleUnconfirmed` says how that
    /// happens). First the player is asked outright, by whichever route
    /// shows the song, and its answer settles the command through `apply`
    /// like any report. Only if that brings nothing either — consent
    /// refused, a player not answering — is it settled against the last
    /// thing the player said.
    ///
    /// On the helper's own route the question is worth asking too: the
    /// helper repeats an unchanged record only every five seconds, so a
    /// pause the player ignored kept the paused icon up, and later taps
    /// waiting, for that long.
    private func settleUnconfirmedPlayback(last: Bool) {
        playbackChase = nil
        guard playbackIntent.hasInFlightCommand, track != nil else { return }
        // A hold that began after the command went out, in a player nobody
        // can script: the helper's echo now describes the film, and there is
        // nobody to ask. `dispatchPlayback` settles these at the send; one
        // sent a moment before the film took over is settled here the same
        // way, rather than against a report from before the tap, which put
        // the icon back to paused over a Tidal that had started playing.
        if isHolding, heldScriptablePlayer == nil {
            if let queued = playbackIntent.settleUnconfirmed(at: Date(), took: true) { dispatchPlayback(queued) }
            return
        }
        guard last else {
            trace("tap unconfirmed; asking the player")
            // Armed before the question: an answer that resends a queued tap
            // arms that command's own chase, which must not be overwritten.
            chasePlaybackConfirmation(after: Self.playbackChaseGrace, last: true)
            if isHolding {
                syncHeldPlayer()
            } else if feedAvailable {
                askForFreshReport()
            } else {
                refreshFromPlayers()
            }
            return
        }
        trace("tap unconfirmed; nobody answered")
        if let queued = playbackIntent.settleUnconfirmed(at: Date(), took: false) {
            // A tap that had been waiting behind the command gets its one
            // resend, and that command its own chase.
            return dispatchPlayback(queued)
        }
        guard !playbackIntent.hasInFlightCommand else { return }
        // Given up: the island shows the last thing the player said, and the
        // clock goes with it, as if the taps had not been made. A play
        // nobody confirmed had run the bar on for these two and a half
        // seconds over a song that never left its place; a pause nobody
        // confirmed had stopped it under music that played on.
        let playing = playbackIntent.desired
        if isPlaying != playing { isPlaying = playing }
        if let before = clockBeforeUnconfirmedTaps {
            if playing {
                anchor = (before.position, before.atMono)
                position = extrapolatedPosition()
            } else {
                setAnchor(before.position)
            }
        }
        clockBeforeUnconfirmedTaps = nil
        updateTicker()
    }
}
