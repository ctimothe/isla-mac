import Foundation

/// Music's star between a tap and Music saying the same (spec §19.6).
///
/// Filmed on 2026-10-28: a catalogue song starred in the player. A song
/// that is not yet in the library is not favourited in place — Music hands
/// it to its library agent as a cloud edit (`eAddFavoriteForStoreItems`, a
/// request to Apple's library server and a sync after it), and until that
/// finished, 3.05 s on that Wi-Fi, `favorited of current track` went on
/// answering "false". The one read-back, 0.4 s after the tap, believed it and
/// emptied the star; each tap after that sent another cloud edit, until one
/// landed late enough to read back true. Unstarring was a local write and
/// never showed it.
///
/// So a tap is held: answers that disagree with it, or say nothing, leave the
/// star where the tap put it until Music agrees or `window` runs out. Spotify's
/// heart already treats the answer to a question asked before a tap as stale
/// (`SpotifyAccount.refreshSavedState`); this is Music's version, where the
/// answer can go on being stale for seconds after the tap.
///
/// Times are seconds on the controller's monotonic clock (`monotonicNow`):
/// a wall clock stepped back mid-hold would stretch the window.
struct MusicFavoriteHold: Equatable {
    /// The tap being held: which song, where the star should end up, and when.
    struct Tap: Equatable {
        let trackKey: String
        let wants: Bool
        let at: TimeInterval
        /// Made while an earlier tap on the same song was still held. That
        /// one's write may still land — a cloud edit started by "on" and then
        /// reversed by "off" 0.2 s later finishes seconds afterwards — so Music
        /// agreeing with this tap proves nothing, and only the window ends it.
        let overtook: Bool
    }

    private(set) var tap: Tap?

    /// How long Music may go on answering the old value before its answer is
    /// believed. About five times the catch-up measured on 2026-10-28, for a
    /// slower network; past it the write has most likely failed — offline, or
    /// the edit refused — and a star still claiming it would be the lie.
    static let window: TimeInterval = 15

    /// When Music is asked again after a tap, in seconds from the tap. The
    /// first is where the single read-back always was, so a local write still
    /// confirms in 0.4 s; then about once a second across the measured
    /// catch-up, sparser after. Each is one Apple event of a few milliseconds,
    /// and none is sent once the hold is over. At `window` the hold ends and
    /// Music is asked once more, its answer believed whatever it says.
    static let readBacks: [TimeInterval] = [0.4, 1, 2, 3, 4, 6, 8, 11]

    /// A tap: the star goes where it says and is held there. A tap while
    /// another is held replaces it — the star goes where the latest one put it.
    @discardableResult
    mutating func tapped(trackKey: String, wants: Bool, at now: TimeInterval) -> Tap {
        let tap = Tap(trackKey: trackKey, wants: wants, at: now, overtook: self.tap?.trackKey == trackKey)
        self.tap = tap
        return tap
    }

    /// The star for Music's answer to a read about `trackKey`.
    ///
    /// While a tap is held, an answer that disagrees with it or says nothing
    /// — a poll skipped for a tap behind it, "none" between songs — keeps the
    /// tap's star. Music agreeing (unless the tap overtook another), the
    /// window running out, or an answer about another song ends the hold, and
    /// Music's answer is the star from then on.
    mutating func shown(answer: Bool?, trackKey: String?, at now: TimeInterval) -> Bool? {
        guard let tap else { return answer }
        guard trackKey == tap.trackKey, now - tap.at < Self.window,
              answer != tap.wants || tap.overtook else {
            self.tap = nil
            return answer
        }
        return tap.wants
    }

    /// The window is out for `tap`. Ends the hold only if `tap` is still the
    /// one held — Music may have agreed, or a later tap replaced it — and says
    /// whether it did, so Music is asked once more and believed. Without this
    /// a hold whose last answer never arrived would hold the star for good.
    mutating func expired(_ tap: Tap) -> Bool {
        release(tap)
    }

    /// Music refused the command itself — an AppleScript error, which a
    /// cloud edit in progress is not. Ends the hold only if `tap` is still
    /// the one held, so a refusal of an earlier tap leaves a later one alone;
    /// true when it did, and the star then goes back.
    mutating func refused(_ tap: Tap) -> Bool {
        release(tap)
    }

    /// The song or the player went away: nothing is held for the next one.
    mutating func forget() {
        tap = nil
    }

    private mutating func release(_ tap: Tap) -> Bool {
        guard self.tap == tap else { return false }
        self.tap = nil
        return true
    }
}
