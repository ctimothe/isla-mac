import AppKit
import Combine

/// The scriptable-players-only fallback. Stored properties live in MediaController.swift.
extension MediaController {
    // MARK: - Fallback: scriptable players only

    /// Internal so a test can hand in a reason without a helper to refuse.
    func switchToScriptingFallback(_ reason: NowPlayingRouteFailure) {
        // A retry that failed: the fallback never stopped, so there is
        // nothing to switch to, only a fresh reason to show.
        if retryingNowPlaying {
            retryingNowPlaying = false
            fallbackReason = reason
            Log.media.notice("retry failed (\(reason.rawValue, privacy: .public)); staying on Music and Spotify scripting")
            return
        }
        guard feedAvailable else { return }
        feedAvailable = false
        fallbackReason = reason
        // Every other reason arrives with the helper already down. This one
        // has it up and publishing, and it is not to be listened to: its
        // records are empty, and on the fallback they would only be dropped.
        // A retry starts a fresh one.
        if reason == .reportsNothing { feed.stop() }
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
        Log.media.error("Now Playing unavailable (\(reason.rawValue, privacy: .public)); falling back to Music and Spotify scripting")

        let center = DistributedNotificationCenter.default()
        for app in PlayerApp.allCases {
            observers.append(center.addObserver(
                forName: app.changeNotification, object: nil, queue: .main
            ) { [weak self] note in
                // The announcer is not made the active app here any more. It
                // used to be, before anyone had answered, so a paused Music
                // announcing anything took the transport — and, as the
                // preferred player, the island — from a Spotify still on
                // screen. The active app is whichever one the island shows,
                // set when `refreshFromPlayers` shows it.
                MainActor.assumeIsolated { self?.fallbackHeard(app, note.userInfo ?? [:]) }
            })
        }
        refreshFromPlayers()
    }

    /// Tries Now Playing again after a fallback.
    ///
    /// The fallback used to be one-way: only `stop()` cleared it, and only
    /// quitting called that. Three failures in one bad minute (a wake, a
    /// macOS update mid-session, a quarantined download the user has since
    /// fixed) left browser and podcast audio invisible until the next launch.
    /// Called on screen wake and from Settings. The fallback keeps running
    /// until the helper delivers its first snapshot, and only then hands over
    /// (`feedDelivered`). Dropping the fallback first meant a helper that
    /// went mute again cost about 45 s of dead Music and Spotify after every
    /// wake and unlock, until the watchdog gave up. A retry that fails comes
    /// back through `switchToScriptingFallback` with a fresh reason.
    ///
    /// A refused load is retried only when the user asks. Each refused load of
    /// the quarantined dylib raises macOS's "Not Opened … Move to Trash"
    /// alert, and a retry on every wake would put that alert up every morning.
    func retryNowPlaying(userAsked: Bool) {
        guard !feedAvailable, !retryingNowPlaying else { return }
        guard userAsked || fallbackReason != .readerRefused else { return }
        retryingNowPlaying = true
        Log.media.notice("retrying Now Playing alongside the fallback")
        feed.start()
    }

    /// The feed's way in. The first snapshot of a retry is the proof the
    /// helper works, so the fallback goes then, and not before.
    ///
    /// Not any snapshot, though (G-009). The fallback used to go on the
    /// helper's first record, empty or not, and an empty one is what a
    /// MediaRemote still waking answers, or one closed to perl: the island
    /// went blank over a Spotify the fallback had been showing. An empty
    /// record is proof only when it agrees with the fallback, which then
    /// shows nothing either; otherwise the fallback keeps working, the retry
    /// stays open, and the first record with a song in it hands over.
    func feedDelivered(_ snapshot: NowPlayingFeed.Snapshot) {
        if retryingNowPlaying {
            guard !snapshot.isEmpty || track == nil else { return }
            retryingNowPlaying = false
            observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
            observers.removeAll()
            feedAvailable = true
            fallbackReason = nil
            Log.media.notice("Now Playing is back")
        }
        // A record from a helper this route has already given up on describes
        // nothing the island should show; the fallback is in charge.
        guard feedAvailable else { return }
        receive(snapshot)
        watchForEmptyRoute(after: snapshot)
    }

    /// How long the helper may answer with nothing after a player said it
    /// plays before the route counts as closed. Several of the helper's
    /// five-second heartbeats, and long enough for MediaRemote to catch up
    /// with a player's own announcement, which it can trail by a second.
    static let emptyRouteLimit: TimeInterval = 10

    /// Falls back when the helper keeps answering with nothing while Music
    /// or Spotify says it is playing (G-009).
    ///
    /// A MediaRemote closed to perl, as 15.4 once closed it, raises no error
    /// here: the helper stays up and publishes records with every field
    /// blank, which is also exactly what an idle Mac publishes. So emptiness
    /// alone proves nothing — a rule of "N empty records" would fire on every
    /// idle Mac. What does is a scriptable player that is running and
    /// announced it plays, after the last record that had a song in it, and
    /// ten seconds of nothing since. The island said "Nothing is playing" over
    /// that Spotify indefinitely, and Settings showed no problem.
    private func watchForEmptyRoute(after snapshot: NowPlayingFeed.Snapshot) {
        let now = monotonicNow()
        guard snapshot.isEmpty else {
            lastFullRecordAt = now
            return
        }
        let unanswered = announcements.contains { app, heard in
            heard.state.isPlaying
                && heard.heardAt > (lastFullRecordAt ?? -.infinity)
                && now - heard.heardAt >= Self.emptyRouteLimit
                && pidForPlayer(app) != nil
        }
        guard unanswered else { return }
        trace("route: only empty records for \(Int(Self.emptyRouteLimit)) s after a player announced it plays")
        switchToScriptingFallback(.reportsNothing)
    }

    /// Asks the scriptable players what they hold and shows it, the way the
    /// helper route shows a snapshot: through `apply`.
    ///
    /// This used to build the track by hand, and every feature `apply` grew
    /// since was missing here. With no pid, the displayed player was unknown,
    /// so shuffle, repeat, precision sync, Spotify's broadcasts and the heart
    /// all switched off and lyric nudges were saved under "other". With no
    /// track-change branch, a skip in Apple Music two minutes into a song
    /// kept the old clock under the new title: `adopt` held the rewind for a
    /// second reading this route never sends. And its own `app|…` key made
    /// every hand-over between routes re-announce an unchanged song. One
    /// path, so none of that can drift apart again.
    ///
    /// Internal so a test can stand in for a player's announcement.
    func refreshFromPlayers() {
        // J-003: a DMG user whose helper is refused lands here at launch, and
        // reading every running player there raised one Automation prompt per
        // player over whatever they were doing, with no panel to explain it.
        // Where no player may be asked yet, the panel opening asks — and
        // until then the players' own announcements are what the island
        // shows. Before, it showed nothing over a song that was playing.
        guard mayScriptAnyPlayer else {
            guard !feedAvailable else { return }
            let running = PlayerApp.allCases.filter { pidForPlayer($0) != nil }
            let replies = Dictionary(uniqueKeysWithValues: running.map { ($0, PlayerBridge.StateReply.unknown) })
            // Nothing heard is nothing known, and the island keeps what it
            // shows rather than blank a song nobody has said is gone.
            guard let state = PlayerBridge.choose(
                replies: replies, announced: announcedStates(), prefer: displayedPlayerApp ?? activeApp
            ) else { return }
            return showFromPlayers(state)
        }
        loadedSong { [weak self] state in
            // A reply that lands after the helper is back describes a route
            // no longer in charge; shown, it replaced the helper's song with
            // whatever the script had found a moment earlier.
            guard let self, !self.feedAvailable else { return }
            guard let state else { return self.clear() }
            self.showFromPlayers(state)
        }
    }

    /// Shows one player's state on the fallback, asked or heard, through
    /// `apply` as a snapshot.
    private func showFromPlayers(_ state: PlayerState) {
        let pid = pidForPlayer(state.app)
        // `apply` holds off a paused stranger until it has kept claiming
        // the session for `foreignHoldWindow`, and on the helper route the
        // two-second heartbeat brings that moment. Nothing re-asks here, so
        // a hold for a player that has quit never ended: Spotify's last
        // song stayed on the island over a paused Music. A player that is
        // gone has nothing left to show.
        if let shown = displayedPlayerPID, shown != pid, !isProcessRunning(shown) {
            clear()
        }
        // Music's announcement says nothing of where the song is. Read as
        // 0:00, a pause at 2:00 sent the bar and the lyric back to the start;
        // the song on screen keeps the place its clock has carried it to, and
        // only a song not on screen starts from its beginning.
        let same = displayedPlayerPID == pid
            && track?.title == state.title && track?.artist == state.artist
        var snapshot = NowPlayingFeed.Snapshot()
        snapshot.title = state.title
        snapshot.artist = state.artist
        snapshot.album = state.album
        snapshot.duration = state.duration > 0 || !same ? state.duration : duration
        snapshot.elapsed = state.positionKnown ? state.position : (same ? extrapolatedPosition() : 0)
        snapshot.isPlaying = state.isPlaying
        snapshot.rate = state.isPlaying ? 1 : 0
        snapshot.takenAt = Date()
        snapshot.playerPID = pid
        snapshot.source = state.app.displayName
        let key = "\(pid ?? 0)|\(state.title)|\(state.artist)|\(state.album)"
        // Read before `apply`, which moves `artworkKey` on to the new song
        // whether or not its cover has come.
        let coverShown = artworkKey == key && artwork != nil
        trace(String(format: "fallback: %@ from %@ playing=%d at %.2f",
                     state.title, state.app.displayName, state.isPlaying ? 1 : 0, snapshot.elapsed))
        apply(snapshot)
        // Only once the island shows it: a stranger `apply` held off must
        // not take the transport from the song still on screen.
        guard displayedPlayerPID == pid, track?.key == key else { return }
        activeApp = state.app
        displayedIsMusic = true
        if !coverShown { fallbackArtwork(for: state, key: key) }
    }
}
