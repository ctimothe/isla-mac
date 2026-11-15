import AppKit
import Combine

/// The Now Playing feed, a held song and announcements. Stored properties live in MediaController.swift.
extension MediaController {
    // MARK: - Feed

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

    func askForFreshReport() {
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

    /// Every change in what the helper reports, before any judgement: owner,
    /// playing flag, rate, title and the admission verdict. Verification only.
    private func traceFeed(_ snapshot: NowPlayingFeed.Snapshot, _ verdict: Admission) {
        guard DebugTrail.openLyrics || DebugTrail.media else { return }
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

    /// Shows a song found in a music player while a film owns Now Playing.
    func adoptLoadedSong() {
        // The search runs on a film's arrival, panel open or not. With nothing
        // open and no player allowed, it waits for the panel.
        guard mayScriptAnyPlayer else {
            owedPlayerQuestion = true
            return
        }
        owedPlayerQuestion = false
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
        // Music's cover is a script; Spotify's is a download from the address
        // its state already gave, and asks Spotify nothing.
        guard let key = track?.key, state.app != .music || mayScript(.music) else { return }
        heldArtwork(state) { [weak self] image in
            guard let self, self.track?.key == key, let image else { return }
            self.batchingReading {
                self.artworkKey = key
                self.artwork = image
                self.coverKey = key
            }
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
    func syncHeldPlayer() {
        guard let app = displayedPlayerApp else { return }
        // A film taking over with the panel shut, or over the lock card, is
        // not a moment the user can be asked anything in. The song stays as
        // last known — exactly what an unanswered question leaves — and the
        // question is put when the panel opens.
        guard mayScript(app) else {
            owedPlayerQuestion = true
            return
        }
        owedPlayerQuestion = false
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
        // Every field below lands as one `reading` when this returns.
        batchingReading { applyReport(snapshot) }
    }

    private func applyReport(_ snapshot: NowPlayingFeed.Snapshot) {
        guard !snapshot.isEmpty else { return clear() }
        let positionBefore = position
        let previousTrack = track

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
        // Adopted *before* the Spotify id is asked for. Asking first tested the
        // player the last snapshot came from: switching Music → Spotify skipped
        // the lookup for the first Spotify track, so its word-synced lyrics
        // silently degraded, and switching the other way asked Spotify what it
        // was playing and then pinned that id to a Music track, keying its
        // lyrics to the wrong song entirely.
        //
        // And before the track is published, for the reason the metadata above
        // is cleared first: `@Published` tells subscribers before it stores,
        // and the lyrics coordinator builds its identity from the player
        // during that very call. Adopted after, a song moving from Music to
        // Spotify was keyed to Music — and with its length unchanged, nothing
        // rebuilt the identity, so a nudge or a binding made while it played
        // in Spotify was saved under the other player.
        displayedPlayerPID = snapshot.playerPID
        let fresh = Track(title: snapshot.title, artist: snapshot.artist, album: snapshot.album, key: key)
        if track != fresh { track = fresh }
        if trackChanged || playerChanged {
            // A new song is a new line for the regression too.
            correctionWindow = []
            // Spotify's announcement of this song usually came first, and its
            // id costs nothing; the lookup is for when it did not.
            adoptAnnouncedTrackID()
            requestSpotifyTrackID(for: key, playerPID: snapshot.playerPID, attempt: 0)
            // The star is the song's, not the player's: a new song in the same
            // Music is asked again rather than wearing the last one's answer.
            if musicFavoriteForTests == nil {
                musicFavorite = nil
                favoriteHold.forget()
                if trackChanged, !playerChanged, isActive { refreshPlaybackModes() }
            }
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
        // A resume the player reports starts the clock where the track stopped.
        // The anchor kept through a pause is only re-based by a reading the
        // player publishes, and a paused session often publishes none, so it
        // can be minutes old; the re-base in `adopt` runs the clock forward
        // from it, and would credit every paused minute as playback.
        if !isPlaying, playbackIntent.desired, anchor != nil {
            anchor = (position, monotonicNow())
        }
        // Same reason as `track` above: unconditional writes to @Published are
        // what turned a quiet 2s poll into a full SwiftUI invalidation.
        if isPlaying != playbackIntent.desired { isPlaying = playbackIntent.desired }
        // Spotify reports a song's length twice, a few hundred milliseconds
        // apart and a fraction of a second different — 247.4, then 247.6 — and
        // the label rounded them to 4:07 and then 4:08. Within one song, a
        // change under a second and a half keeps the length already shown.
        let steadyDuration = !trackChanged && !playerChanged && duration > 0
            && snapshot.duration > 0 && abs(snapshot.duration - duration) < 1.5
            ? duration : snapshot.duration
        if duration != steadyDuration { duration = steadyDuration }
        if sourceName != snapshot.source { sourceName = snapshot.source }
        refreshSourceIcon(for: snapshot.playerPID)
        // Both directions travel together: no player has ever offered one
        // without the other, and two separately dimmed arrows would read as
        // a glitch rather than a limit.
        let skippable = snapshot.offers(.next) && snapshot.offers(.previous)
        if canSkip != skippable { canSkip = skippable }

        var reported = reportedPosition(from: snapshot, isPlaying: reportedPlaying)
        var heldForTrackChange = false
        if trackChanged || playerChanged {
            if awaitingTrackChangeSince != nil { trace("await track change: arrived") }
            awaitingTrackChangeSince = nil
            restartExpectedUntil = nil
            if trackChanged, !playerChanged, Self.elapsedBelongsToPreviousSong(
                reported: reported, previousPosition: positionBefore, newDuration: snapshot.duration
            ) {
                trace(String(format: "new song reported at %.2f, the old one's position; starting at 0", reported))
                reported = 0
            }
        } else if isAwaitingTrackChange() {
            heldForTrackChange = true
        } else if readingLooksLikeAnotherSong(reported) {
            beginAwaitingTrackChange(String(format: "report back at %.2f with no new name", reported))
            heldForTrackChange = true
        }

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
        } else if !stale, !heldForTrackChange {
            // A restart asked for, or confirmed by the grace running out, is
            // taken at once rather than waiting for a second reading to agree.
            let restartExpected = restartExpectedUntil.map { Date() < $0 } ?? false
            adopt(reported, mayRewindAtOnce: trackChanged || playerChanged || restartExpected)
        }
        if !stale, let takenAt = snapshot.takenAt { lastReadingAt = takenAt }
        updateTicker()
        if let queuedTarget { dispatchPlayback(queuedTarget) }

        if let data = snapshot.artwork {
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
        } else if artworkKey != key, artwork != nil, !playerChanged, let previousTrack,
                  !snapshot.album.isEmpty, previousTrack.album == snapshot.album,
                  previousTrack.artist == snapshot.artist {
            // The next song on the same album: its cover is the one on screen.
            // Blanking it while the report caught up dropped the picture to the
            // placeholder and brought the same one back half a second later
            // (filmed 2026-09-21). Kept, and replaced if the song's own
            // cover arrives different. It is this song's cover now, so the
            // presenter may swap on it at once (`Reading.hasCover`).
            artworkKey = key
            coverKey = key
            artworkRequestedFor = []
        } else if artworkKey != key {
            artworkKey = key
            // A different track: it has not been asked about, and the set is
            // reset rather than added to, so it holds one key rather than every
            // song of the session.
            artworkRequestedFor = []
            // A different song's cover is not this one's, so it comes down at
            // once. It used to wait 180 ms first, on the measurement that the
            // new cover usually lands within 68 ms and one crossfade beats two;
            // but the title had already changed, so the new title sat over the
            // old cover for those 180 ms, then over the placeholder, then the
            // new cover (owner, 2026-10-25). Hiding that gap is now
            // `NowPlayingPresenter`'s job, which keeps the whole old song drawn
            // until the new one's title and cover can be swapped in together;
            // this field only ever says what is true.
            if artwork != nil { artwork = nil }
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
        // Weak from the outermost closure. The hops back below asked for a weak
        // `self`, but to hand them one the decoding closure had to capture it
        // first, and without a list of its own it captured it strongly: the
        // `weak` never covered the decode, and the compiler said so.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let image = Self.artworkImage(data) else {
                // An undecodable payload must not leave the previous track's
                // cover standing: no later snapshot for this track will take it
                // down.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.artworkKey == key else { return }
                    self.artwork = nil
                }
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.artworkKey == key else { return }
                // One reading, picture and owner together: a reading with the
                // new picture still owned by the old song would read as "not
                // in yet" for a turn.
                self.batchingReading {
                    self.artwork = image
                    self.coverKey = key
                }
            }
        }
    }

    /// The longest side, in pixels, a cover is ever decoded at.
    ///
    /// The largest sharp use is the lock card's 118 pt cover, 236 px on a
    /// Retina screen; every other use is blurred by 44 to 60 pt, where detail
    /// past this is thrown away by the blur anyway. 512 leaves headroom for a
    /// 3x display without holding the source's own size.
    nonisolated static let artworkMaxPixel = 512

    /// A cover decoded no larger than `maxPixel` on its long side.
    ///
    /// Covers used to be decoded at the source's full size and held for the
    /// whole track: Apple Music hands over 1400 to 3000 px routinely, which is
    /// 8 to 36 MB of RGBA standing in memory to fill a 118 pt square
    /// (audit F-044). ImageIO's thumbnail path decodes straight to the smaller
    /// size, so the full bitmap never exists, and it never scales a smaller
    /// image up. `ShouldCacheImmediately` makes the decode happen here, on the
    /// caller's background queue, rather than lazily on the main thread at the
    /// first draw, which is the stutter the background decode was added for.
    /// The transform flag honours an EXIF orientation a JPEG cover may carry.
    nonisolated static func downsampledArtwork(_ data: Data, maxPixel: Int = artworkMaxPixel) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }

    /// The cover as the views take it: its point size equals its pixel size,
    /// as it always has. Every view draws it resizable into a fixed frame, so
    /// a smaller size changes how much is held, not how anything is laid out.
    nonisolated static func artworkImage(_ data: Data) -> NSImage? {
        guard let cgImage = downsampledArtwork(data) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    func clear() {
        batchingReading { clearReport() }
    }

    private func clearReport() {
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
        artwork = nil
        artworkKey = nil
        // The session is gone, so the next one has earned a fresh ask — this is
        // exactly the path that loses the cover, and remembering that we already
        // asked would make the loss permanent.
        artworkRequestedFor = []
        // Same reason, for the fallback's own tries.
        fallbackArtworkAttempts = [:]
        isPlaying = false
        duration = 0
        position = 0
        sourceName = nil
        sourceIcon = nil
        sourceIconPID = nil
        displayedPlayerPID = nil
        playbackIntent = PlaybackIntent(reported: false)
        playbackChase?.cancel()
        playbackChase = nil
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
        if musicFavoriteForTests == nil { musicFavorite = nil }
        favoriteHold.forget()
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

    // MARK: - Players' own announcements

    /// Keeps what a player's own announcement says, for a moment when the
    /// player cannot or may not be asked (`PlayerAnnouncement`). Kept on both
    /// routes: the search for a song under a film reads it as well.
    func hearAnnouncement(from app: PlayerApp, _ info: [AnyHashable: Any]) {
        announcements[app] = PlayerAnnouncement.state(from: info, app: app).map { ($0, monotonicNow()) }
    }

    /// A player's announcement on the fallback route: kept, then shown the
    /// way the route shows everything. Two observers hear it — the one
    /// `start()` keeps and the fallback's own — and their order is not
    /// promised, so this one keeps it too rather than refresh before the
    /// other has. Internal so a test can stand in for the player.
    func fallbackHeard(_ app: PlayerApp, _ info: [AnyHashable: Any]) {
        hearAnnouncement(from: app, info)
        refreshFromPlayers()
    }

    /// The announced states as they stand now.
    ///
    /// A player that has quit takes its announcement with it, or its last
    /// song would speak for it after the next launch. And a playing song is
    /// aged to now: an announcement is read again whenever the *other* player
    /// announces, by when a Spotify heard playing at 0:12 twenty seconds ago
    /// is at 0:32, and reading 0:12 dragged the clock backwards.
    func announcedStates() -> [PlayerApp: PlayerState] {
        announcements = announcements.filter { pidForPlayer($0.key) != nil }
        let now = monotonicNow()
        return announcements.mapValues { heard in
            var state = heard.state
            guard state.isPlaying, state.positionKnown else { return state }
            let aged = state.position + max(0, now - heard.heardAt)
            state.position = state.duration > 0 ? min(aged, state.duration) : aged
            return state
        }
    }

    /// Fetches the cover for a song shown on the fallback route.
    ///
    /// The key used to be recorded before the fetch, so one failed CDN
    /// request cost the song its cover for as long as it played. Two tries
    /// per song now: the next refresh retries a failure, and a cover that
    /// truly does not exist is not polled. Whatever `apply` decided about the
    /// old cover — kept for an album-mate, or taken down at once —
    /// stands until this one lands.
    func fallbackArtwork(for state: PlayerState, key: String) {
        // Before an attempt is counted: a cover consent kept back is not a
        // cover that failed, and the next refresh asks again.
        guard state.app != .music || mayScript(.music) else { return }
        // Nor is a Spotify song with no cover address — the one its own
        // announcement describes, which carries none. Counted, it spent both
        // tries before the answer that has one, once Spotify could be asked.
        guard state.app != .spotify || state.artworkURL != nil else { return }
        if fallbackArtworkAttempts[key] == nil { fallbackArtworkAttempts = [key: 0] }
        guard let attempts = fallbackArtworkAttempts[key], attempts < 2 else { return }
        fallbackArtworkAttempts[key] = attempts + 1
        heldArtwork(state) { [weak self] image in
            guard let self, self.track?.key == key, let image else { return }
            self.batchingReading {
                self.artworkKey = key
                self.artwork = image
                self.coverKey = key
            }
        }
    }
}
