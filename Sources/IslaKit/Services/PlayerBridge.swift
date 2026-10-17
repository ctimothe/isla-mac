import AppKit

/// Public-API bridge to the two scriptable players macOS ships with support
/// for. Everything goes through AppleScript (state, artwork, transport) and
/// distributed notifications (change events) — no private frameworks.
enum PlayerApp: String, CaseIterable {
    case music, spotify

    var bundleID: String {
        switch self {
        case .music: return "com.apple.Music"
        case .spotify: return "com.spotify.client"
        }
    }

    var displayName: String {
        switch self {
        case .music: return "Apple Music"
        case .spotify: return "Spotify"
        }
    }

    /// Distributed notification the player posts on every state change.
    var changeNotification: Notification.Name {
        switch self {
        case .music: return Notification.Name("com.apple.Music.playerInfo")
        case .spotify: return Notification.Name("com.spotify.client.PlaybackStateChanged")
        }
    }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}

struct PlayerState {
    var app: PlayerApp
    var isPlaying: Bool
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var position: TimeInterval
    var artworkURL: URL?
    /// False when the source said nothing about where the song is. Music's
    /// own announcement carries no position (`PlayerAnnouncement`), and
    /// reading its absence as 0:00 sent a song paused at 2:00 back to the
    /// start on screen.
    var positionKnown = true
    // No `key` of its own any more. It was "app|title|artist|album" against
    // the helper route's "pid|title|artist|album", and the mismatch made every
    // hand-over between the two routes re-announce an unchanged song. A song
    // found here is keyed by `MediaController.apply`, like every other.
}

enum PlayerBridge {
    private static let queue = DispatchQueue(label: "com.ctimothe.islalescript", qos: .utility)

    // MARK: - State

    /// What a player said when asked for its state.
    ///
    /// "Nothing loaded" and "could not be asked" are different answers. The
    /// first means there is no song; the second — Automation consent withheld,
    /// a player that did not answer — says nothing about the song at all, and
    /// treating it as the first blanked a paused song the island was holding.
    enum StateReply {
        case loaded(PlayerState)
        case empty
        case unknown
    }

    static func stateReply(of app: PlayerApp, completion: @escaping (StateReply) -> Void) {
        guard app.isRunning else { return completion(.empty) }
        runScript(Script.state(for: app), app: app) { descriptor in
            completion(descriptor?.stringValue.map { interpret($0, app: app) } ?? .unknown)
        }
    }

    /// What Spotify said when asked which track it is playing.
    ///
    /// Three answers, not two. An episode, an ad or a local file is a real
    /// answer with no catalogue track behind it; read as "no answer", it was
    /// asked again at 1, 2, 4 and 8 seconds, five Apple Events for an id that
    /// does not exist (K-014). And the name and artist come back with the id,
    /// because MediaRemote trails Spotify by about a second: right after a
    /// skip the script names the next song while the island still shows the
    /// last one, and the id must not attach to the wrong title (K-016).
    enum SpotifyTrackLookup: Equatable {
        case track(id: String, name: String, artist: String)
        case notATrack
        case noAnswer

        private static let trackPrefix = "spotify:track:"

        static func parse(_ raw: String?) -> SpotifyTrackLookup {
            guard let raw, !raw.isEmpty else { return .noAnswer }
            let parts = raw.components(separatedBy: "\u{1}")
            let uri = parts[0]
            if uri.hasPrefix(trackPrefix) {
                let id = String(uri.dropFirst(trackPrefix.count))
                guard !id.isEmpty else { return .noAnswer }
                return .track(
                    id: id,
                    name: parts.count > 1 ? parts[1] : "",
                    artist: parts.count > 2 ? parts[2] : ""
                )
            }
            return uri.hasPrefix("spotify:") ? .notATrack : .noAnswer
        }
    }

    /// The Spotify catalogue id of the current track, with the name and
    /// artist it belongs to. The lock-card heart is its only reader.
    static func spotifyTrackID(completion: @escaping @MainActor (SpotifyTrackLookup) -> Void) {
        runScript(Script.spotifyTrackID, app: .spotify) { result in
            MainActor.assumeIsolated { completion(.parse(result?.stringValue)) }
        }
    }

    /// A scriptable player's own playback position, fractional seconds, asked
    /// directly. The player clock beats MediaRemote's stale elapsed reading.
    static func precisePosition(
        of app: PlayerApp,
        completion: @escaping @MainActor (TimeInterval?) -> Void
    ) {
        runScript(Script.position(of: app), app: app, priority: .pollable) { result in
            MainActor.assumeIsolated {
                completion(result?.stringValue.flatMap { TimeInterval($0.replacingOccurrences(of: ",", with: ".")) })
            }
        }
    }

    /// Never launches a player: only already-running ones are queried, and a
    /// playing app wins over a merely-open one. See `choose(replies:…)` for
    /// how the answers are weighed. `asking` leaves out a player that may not
    /// be asked now (`MediaController.mayScript`), so its prompt is not
    /// raised; such a player is *unknown*, not absent, and its own
    /// `announced` state speaks for it.
    ///
    /// The replies are kept whole. This used to read each player through a
    /// call that turned every non-answer into nil, so a Spotify whose
    /// Automation was refused (-1743) looked exactly like a Spotify with
    /// nothing loaded, and a paused Music beside it won (J-027).
    static func currentState(
        prefer preferred: PlayerApp? = nil,
        asking: (PlayerApp) -> Bool = { _ in true },
        announced: [PlayerApp: PlayerState] = [:],
        completion: @escaping (PlayerState?) -> Void
    ) {
        let running = PlayerApp.allCases.filter(\.isRunning)
        guard !running.isEmpty else { return completion(nil) }

        var replies: [PlayerApp: StateReply] = [:]
        let group = DispatchGroup()
        for app in running {
            guard asking(app) else {
                replies[app] = .unknown
                continue
            }
            group.enter()
            stateReply(of: app) { reply in
                replies[app] = reply
                group.leave()
            }
        }
        group.notify(queue: .main) {
            completion(choose(replies: replies, announced: announced, prefer: preferred))
        }
    }

    /// Which player to show, from what each running one answered and what
    /// each announced on its own.
    ///
    /// An announcement stands in only for a player that could not be asked:
    /// one that answered has said what it is doing now, and one that answered
    /// "nothing loaded" has nothing loaded. Sound still comes first, and a
    /// player that answered outranks one that was only heard — but a player
    /// that could not be asked and announced it was playing beats a paused
    /// one that could. The other way round is J-027: the paused Music shown
    /// over a playing Spotify whose Automation had been refused, with
    /// play/pause driving Music. A player that could not be asked and has
    /// announced nothing is not a song, so it never wins on its own.
    static func choose(
        replies: [PlayerApp: StateReply],
        announced: [PlayerApp: PlayerState],
        prefer preferred: PlayerApp?
    ) -> PlayerState? {
        // `allCases` order, so the tie-break among paused players stays what
        // it was: a dictionary's order is not.
        var answered: [PlayerState] = []
        var heard: [PlayerState] = []
        for app in PlayerApp.allCases {
            switch replies[app] {
            case let .loaded(state)?: answered.append(state)
            case .unknown?: if let state = announced[app] { heard.append(state) }
            case .empty?, nil: break
            }
        }
        return choose(among: answered.filter(\.isPlaying), prefer: preferred)
            ?? choose(among: heard.filter(\.isPlaying), prefer: preferred)
            ?? choose(among: answered + heard, prefer: preferred)
    }

    /// Which of several players' answers to show.
    ///
    /// Sound first: a playing player wins over a paused one. Past that, the
    /// player already on screen wins. Without it the tie went to whichever
    /// answered first in `allCases` order, so with Music and Spotify both
    /// paused, the island swapped from the shown one to Music on the next
    /// announcement either of them made. The fallback has no heartbeat to
    /// settle a swap like that, so it stuck until the next one.
    static func choose(among results: [PlayerState], prefer preferred: PlayerApp?) -> PlayerState? {
        let playing = results.filter(\.isPlaying)
        let pool = playing.isEmpty ? results : playing
        return pool.first { $0.app == preferred } ?? pool.first
    }

    // MARK: - Shuffle & repeat

    /// Repeat as the players model it. Spotify's scripting exposes only a
    /// boolean, so `.one` is reachable there through the app itself but not
    /// settable from outside; Music has the full three states.
    enum RepeatMode: String {
        case off, all, one
    }

    /// Both flags in one round trip, or nil when the player refuses to answer —
    /// and, from Music, whether the song is a favourite (spec §19.6), in the
    /// same trip. Spotify's scripting has no such property (its `starred` is a
    /// corpse, see `SpotifyAccount`), so its answer carries none.
    static func playbackModes(
        of app: PlayerApp,
        completion: @escaping @MainActor ((shuffle: Bool, repeatMode: RepeatMode, favorite: Bool?)?) -> Void
    ) {
        guard app.isRunning else {
            Task { @MainActor in completion(nil) }
            return
        }
        runScript(Script.playbackModes(of: app), app: app, priority: .pollable) { result in
            MainActor.assumeIsolated {
                guard let raw = result?.stringValue else { return completion(nil) }
                let parts = raw.split(separator: "|").map(String.init)
                guard parts.count == 2 || parts.count == 3 else { return completion(nil) }
                let shuffle = parts[0] == "true"
                let mode: RepeatMode
                switch parts[1] {
                case "one": mode = .one
                case "all", "true": mode = .all
                default: mode = .off
                }
                completion((shuffle, mode, parts.count == 3 ? Self.favorite(parts[2]) : nil))
            }
        }
    }

    /// Music's answer for the favourite: "true", "false", or "none" when there
    /// was no current track to ask.
    static func favorite(_ raw: String) -> Bool? {
        switch raw {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    /// Music's favourite, set through the scripting bridge the fallback already
    /// uses — the one Apple Events entitlement the app has. Music only: nothing
    /// else answers the question, and Spotify's is the Web API's.
    static func setFavorite(_ app: PlayerApp, _ isFavorite: Bool) {
        guard app == .music else { return }
        send(.favorite(isFavorite), to: app)
    }

    static func setShuffle(_ app: PlayerApp, enabled: Bool) { send(.shuffle(enabled), to: app) }
    static func setRepeat(_ app: PlayerApp, mode: RepeatMode) { send(.repeatMode(mode), to: app) }

    // MARK: - Transport

    /// What the transport can ask a player to do, rendered per player.
    enum Transport {
        case play, pause, next, previous
        case seek(seconds: Double)
        case shuffle(Bool)
        case repeatMode(RepeatMode)
        /// Music only (`setFavorite`); Spotify's body is a no-op the bridge
        /// never sends.
        case favorite(Bool)

        func body(for app: PlayerApp) -> String {
            switch (self, app) {
            case (.play, _): return "play"
            case (.pause, _): return "pause"
            case (.next, _): return "next track"
            // Spotify's `previous track` restarts the current song first,
            // matching its own UI; Music behaves the same way. Seeking to 0
            // first is what users expect from a "skip back" button.
            case (.previous, .spotify): return "set player position to 0\n    previous track"
            case (.previous, .music): return "back track"
            // Fractional, as the players accept: a whole second sent a lyric
            // click up to a second early, onto the line before (see
            // `NowPlayingFeed.seekWireLine`).
            case let (.seek(seconds), _): return "set player position to " + String(format: "%.3f", max(0, seconds))
            case let (.shuffle(enabled), .music): return "set shuffle enabled to \(enabled)"
            case let (.shuffle(enabled), .spotify): return "set shuffling to \(enabled)"
            case let (.repeatMode(mode), .music): return "set song repeat to \(mode.rawValue)"
            // Scripting has only the boolean; `.one` maps to on, matching how
            // Spotify itself degrades the state over this interface.
            case let (.repeatMode(mode), .spotify): return "set repeating to \(mode != .off)"
            case let (.favorite(isOn), .music): return "set favorited of current track to \(isOn)"
            case (.favorite, .spotify): return "return"
            }
        }

        /// One of every kind, so the compile test covers each body.
        static let everyKind: [Transport] = [
            .play, .pause, .next, .previous, .seek(seconds: 0),
            .shuffle(true), .repeatMode(.one), .repeatMode(.off), .favorite(true),
        ]
    }

    /// Play and pause travel as explicit states, never as a toggle: a toggle
    /// sent against a state the island misread lands backwards.
    static func send(_ action: Transport, to app: PlayerApp) {
        guard app.isRunning else { return }
        runScript(Script.command(action.body(for: app), on: app), app: app, priority: .transport) { _ in }
    }

    // MARK: - Artwork

    static func artwork(for state: PlayerState, completion: @escaping (NSImage?) -> Void) {
        switch state.app {
        case .spotify:
            // The one request no setting gates. Spotify's scripting dictionary
            // names its cover only by address, so on the fallback route and on
            // a held cover the image is fetched from Spotify's image server.
            // It carries the cover's address and nothing about the listener
            // beyond the IP that any request carries; the README's privacy
            // table lists it beside the switches. This comment used to call it
            // "the one thing the app ever fetches", which stopped being true
            // when lyrics, translation, the account and the update check
            // arrived (audit G-030).
            //
            // The address comes out of another app's scripting dictionary, so
            // the scheme is checked: https answers for itself through TLS,
            // while file:// or some private scheme answers to nobody.
            guard let url = state.artworkURL, url.scheme?.lowercased() == "https" else {
                return completion(nil)
            }
            // Decoded small and here, on URLSession's own queue: the same
            // ceiling MediaController puts on the helper's covers, so a held
            // or fallback cover does not stand in memory at the source's full
            // size (audit F-044). Through the session that keeps nothing, so
            // a listening history does not pile up in the HTTP cache one cover
            // at a time (audit G-016).
            PrivateNetwork.session.dataTask(with: url) { data, _, _ in
                let image = data.flatMap(MediaController.artworkImage)
                DispatchQueue.main.async { completion(image) }
            }.resume()
        case .music:
            runScript(Script.musicArtwork, app: .music) { descriptor in
                guard let data = descriptor?.data, !data.isEmpty else { return completion(nil) }
                // The script answers on the main thread. `NSImage(data:)` was
                // lazy and decoded the full Music cover, often 3000 px, on
                // main at the first draw; the downsample decodes at once, so
                // it is sent off main and the result handed back.
                DispatchQueue.global(qos: .userInitiated).async {
                    let image = MediaController.artworkImage(data)
                    DispatchQueue.main.async { completion(image) }
                }
            }
        }
    }

    // MARK: - Scripts

    /// Every AppleScript the bridge sends, as source, in one place.
    ///
    /// They live together so `PlayerScriptTests` can compile each one against
    /// the players installed on the machine. A script that fails to compile
    /// answers exactly like a player with nothing to say, so the failure is
    /// silent: no crash, only a log line nobody reads.
    enum Script {
        /// Joins the fields of a state answer. Character 1 cannot occur in a
        /// title, where a printable separator such as "|" can.
        private static let separator = "set fieldSeparator to character id 1"

        /// The variable names are long on purpose. The script once named its
        /// state `st`, and macOS 27's AppleScript reserves the ordinal
        /// suffixes — `st`, `nd`, `rd`, `th` — as words, so every call failed
        /// to compile. A short name is what the next reserved word looks like.
        static func state(for app: PlayerApp) -> String {
            timed(untimedState(for: app), seconds: pollSeconds)
        }

        private static func untimedState(for app: PlayerApp) -> String {
            switch app {
            case .spotify:
                return """
                \(separator)
                tell application id "com.spotify.client"
                    if it is not running then return "error" & fieldSeparator & "-600"
                    try
                        set playerStateText to player state as text
                        set currentTrackRef to current track
                        try
                            set positionMs to (round ((player position) * 1000))
                        on error
                            set positionMs to 0
                        end try
                        return playerStateText & fieldSeparator & (name of currentTrackRef) & fieldSeparator & (artist of currentTrackRef) & fieldSeparator & (album of currentTrackRef) & fieldSeparator & (duration of currentTrackRef) & fieldSeparator & positionMs & fieldSeparator & (artwork url of currentTrackRef)
                    on error number errorNumber
                        return "error" & fieldSeparator & errorNumber
                    end try
                end tell
                """
            case .music:
                return """
                \(separator)
                tell application id "com.apple.Music"
                    if it is not running then return "error" & fieldSeparator & "-600"
                    try
                        set playerStateText to player state as text
                        set currentTrackRef to current track
                        try
                            set positionMs to (round ((player position) * 1000))
                        on error
                            set positionMs to 0
                        end try
                        return playerStateText & fieldSeparator & (name of currentTrackRef) & fieldSeparator & (artist of currentTrackRef) & fieldSeparator & (album of currentTrackRef) & fieldSeparator & (round ((duration of currentTrackRef) * 1000)) & fieldSeparator & positionMs & fieldSeparator & ""
                    on error number errorNumber
                        return "error" & fieldSeparator & errorNumber
                    end try
                end tell
                """
            }
        }

        static let spotifyTrackID = timed("""
        \(separator)
        tell application id "\(PlayerApp.spotify.bundleID)"
            if it is running then
                set currentTrackRef to current track
                return (id of currentTrackRef as text) & fieldSeparator & (name of currentTrackRef) & fieldSeparator & (artist of currentTrackRef)
            end if
        end tell
        """, seconds: pollSeconds)

        static func position(of app: PlayerApp) -> String {
            timed("""
            tell application id "\(app.bundleID)"
                if it is running then
                    return (player position as text)
                end if
            end tell
            """, seconds: pollSeconds)
        }

        static func playbackModes(of app: PlayerApp) -> String {
            timed(untimedPlaybackModes(of: app), seconds: pollSeconds)
        }

        private static func untimedPlaybackModes(of app: PlayerApp) -> String {
            switch app {
            case .music:
                return """
                tell application id "\(app.bundleID)"
                    set s to shuffle enabled
                    set r to song repeat
                    set f to "none"
                    try
                        set f to (favorited of current track) as text
                    end try
                    return (s as text) & "|" & (r as text) & "|" & f
                end tell
                """
            case .spotify:
                return """
                tell application id "\(app.bundleID)"
                    set s to shuffling
                    set r to repeating
                    return (s as text) & "|" & (r as text)
                end tell
                """
            }
        }

        /// Asks only a Music that is still running. The fetch follows the
        /// state read that found Music by a beat, and an Apple event sent to a
        /// Music that quit in between launched it again (F-041) — the one
        /// script here that had no guard, where every sibling checks first.
        static let musicArtwork = timed("""
        tell application id "com.apple.Music"
            if it is not running then return missing value
            if (count of artworks of current track) is 0 then return missing value
            return raw data of artwork 1 of current track
        end tell
        """, seconds: pollSeconds)

        static func command(_ body: String, on app: PlayerApp) -> String {
            timed("""
            tell application id "\(app.bundleID)"
                \(body)
            end tell
            """, seconds: transportSeconds)
        }

        /// How long a read waits for a player before giving up. A state,
        /// position, mode, track-id or artwork answer from a healthy player
        /// takes milliseconds; one that has not come in two seconds is not
        /// coming in time to be worth showing, and the next poll asks again.
        static let pollSeconds = 2
        /// How long a tap waits. Longer than a read because the user is
        /// watching for it and a dropped tap is worse than a late one, but
        /// still seconds, not minutes.
        static let transportSeconds = 5

        /// Wraps a script in its own Apple event timeout (F-025).
        ///
        /// Every script runs on one serial queue — `NSAppleScript` is not
        /// documented as thread-safe, so a second queue would trade a stall
        /// for a crash — and none carried a timeout, so a Spotify that
        /// beachballed held that queue for AppleScript's default two minutes.
        /// Every script behind it waited too, a play tap on Music included.
        /// A Swift-side watchdog cannot help: `executeAndReturnError` cannot be
        /// cancelled, so the queue would stay blocked anyway. With the
        /// timeout the player's silence becomes error -1712 after `seconds`:
        /// the state scripts catch it and say "error", which `interpret`
        /// reads as `.unknown`, and every other caller already treats a run
        /// that returned nothing as no answer. `AutomationAccess` reads -1712
        /// as saying nothing about consent.
        ///
        /// A tap that happens to raise the one-time Automation prompt times
        /// out too while the prompt is up; the user taps again after
        /// answering it. Since the first event now goes out when the panel
        /// opens, not on a tap, that is rare.
        static func timed(_ source: String, seconds: Int) -> String {
            "with timeout of \(seconds) seconds\n\(source)\nend timeout"
        }

        /// Every source the bridge can send to `app`, named, built by the same
        /// functions the bridge calls, for the compile test.
        static func everySource(for app: PlayerApp) -> [(name: String, source: String)] {
            var sources: [(name: String, source: String)] = [
                ("state", state(for: app)),
                ("position", position(of: app)),
                ("playback modes", playbackModes(of: app)),
            ]
            switch app {
            case .spotify: sources.append(("track id", spotifyTrackID))
            case .music: sources.append(("artwork", musicArtwork))
            }
            for action in Transport.everyKind {
                sources.append(("\(action)", command(action.body(for: app), on: app)))
            }
            return sources
        }
    }

    /// errAENoSuchObject: `current track` asked of a player with none loaded.
    private static let noSuchObject = -1728
    /// procNotFound: the player quit. The script checks before it asks, since
    /// an Apple event sent to a player that has just quit launches it again.
    private static let notRunning = -600

    /// Reads a state script's answer. The script reports its own failure as
    /// "error" and the AppleScript error number, so the one error that means
    /// "nothing loaded" can be told from the ones that mean "not asked" —
    /// -1743 is a withheld Automation consent, -1712 a player that timed out.
    static func interpret(_ raw: String, app: PlayerApp) -> StateReply {
        let parts = raw.components(separatedBy: "\u{1}")
        if parts.first == "error" {
            let code = parts.count > 1 ? Int(parts[1]) : nil
            return code == noSuchObject || code == notRunning ? .empty : .unknown
        }
        guard parts.count >= 6 else { return .unknown }
        guard !parts[1].isEmpty else { return .empty }
        return .loaded(PlayerState(
            app: app,
            isPlaying: parts[0].lowercased() == "playing",
            title: parts[1],
            artist: parts[2],
            album: parts[3],
            duration: (Double(parts[4]) ?? 0) / 1000,
            position: (Double(parts[5]) ?? 0) / 1000,
            artworkURL: parts.count > 6 ? URL(string: parts[6]) : nil
        ))
    }

    /// Compiled scripts, keyed by source.
    ///
    /// The sources are constants — the position query is the same string on
    /// every one of the thirty ticks a minute the precision loop makes — and
    /// `NSAppleScript(source:)` recompiles from scratch each time it is built.
    /// Two queues reach this, so it carries its own lock.
    nonisolated(unsafe) private static var compiled: [String: NSAppleScript] = [:]
    private static let compiledLock = NSLock()

    /// Compiled scripts are cached only when the same text will be run again.
    ///
    /// Transport scripts carry their argument in the source — `set player
    /// position to 137` — so every distinct seek second is a distinct key.
    /// Caching those grew the table for the life of the process and never got a
    /// hit; the polls, which are the reason the cache exists, are constant.
    private static func script(for source: String, cacheable: Bool) -> NSAppleScript? {
        guard cacheable else { return NSAppleScript(source: source) }
        compiledLock.lock()
        defer { compiledLock.unlock() }
        if let cached = compiled[source] { return cached }
        let built = NSAppleScript(source: source)
        if let built { compiled[source] = built }
        return built
    }

    /// Transport taps waiting behind a poll, counted.
    ///
    /// One queue, deliberately: `NSAppleScript` is not documented as
    /// thread-safe, so running two of them at once to keep taps responsive
    /// would trade a stall for a crash. Instead the queue stays serial and
    /// *polling* work yields — a position query that was enqueued before a tap
    /// arrived returns without executing, so the tap waits only for whatever
    /// was already running rather than for everything queued in front of it.
    nonisolated(unsafe) private static var pendingTransport = 0
    private static let pendingLock = NSLock()

    private static func changePendingTransport(_ delta: Int) {
        pendingLock.lock()
        pendingTransport += delta
        pendingLock.unlock()
    }

    private static var transportIsWaiting: Bool {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        return pendingTransport > 0
    }

    /// True inside a test process. The unit tests never ask a real player
    /// (see `MediaControllerTests`), and the Spotify track-id lookup had no
    /// seam, so a test that pretended Spotify was showing sent real Apple
    /// Events to whatever Spotify the machine was running. That raised
    /// macOS's automation prompt for xctest on the owner's screen and hung
    /// the run until someone answered it.
    static let isRunningTests = NSClassFromString("XCTestCase") != nil

    /// The one number a script run says about Automation consent.
    ///
    /// An AppleScript error carries it directly. The state scripts catch
    /// their own errors and return them as text — "error", then the number —
    /// so a refusal inside one arrives as a successful run whose answer is
    /// that string, and is read from there. Anything else is an answer, and
    /// an answer means the event got through.
    static func outcome(errorNumber: Int?, result: String?) -> OSStatus {
        if let errorNumber, errorNumber != 0 { return OSStatus(truncatingIfNeeded: errorNumber) }
        if let result {
            let parts = result.components(separatedBy: "\u{1}")
            if parts.first == "error", parts.count > 1, let code = Int(parts[1]) {
                return OSStatus(truncatingIfNeeded: code)
            }
        }
        return OSStatus(noErr)
    }

    /// Runs one script against `app` and tells `AutomationAccess` what the
    /// outcome said about consent, so a refusal stops the background asking
    /// and a grant lets it ask again without waiting for the next check.
    static func runScript(
        _ source: String,
        app: PlayerApp,
        priority: Priority = .background,
        completion: @escaping (NSAppleEventDescriptor?) -> Void
    ) {
        if isRunningTests {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        if priority == .transport { changePendingTransport(1) }
        queue.async {
            if priority == .transport {
                changePendingTransport(-1)
            } else if priority == .pollable, transportIsWaiting {
                // Something the user pressed is behind this, and this is a poll
                // the next tick repeats — so skip it rather than make a button
                // wait on an answer nobody is missing.
                DispatchQueue.main.async { completion(nil) }
                return
            }
            var error: NSDictionary?
            let result = script(for: source, cacheable: priority != .transport)?
                .executeAndReturnError(&error)
            let errorNumber = error?[NSAppleScript.errorNumber] as? Int
            if let error, let code = errorNumber, code != 0 {
                // The message can echo a value from the script, a track name
                // among them, so only the code is public.
                Log.media.error("AppleScript error \(code, privacy: .public): \(String(describing: error[NSAppleScript.errorMessage] ?? ""), privacy: .private)")
            }
            let said = PlayerBridge.outcome(errorNumber: errorNumber, result: result?.stringValue)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { AutomationAccess.shared.learn(app, outcome: said) }
                completion(result)
            }
        }
    }

    enum Priority {
        /// A lookup whose answer is asked for once and cannot be re-asked
        /// cheaply — the Spotify track id, Music artwork, the state that
        /// decides whether anything is playing at all. These always run: a
        /// dropped answer costs the track its lyrics or its cover for the rest
        /// of its duration, or blanks the island outright.
        case background
        /// A poll the next tick repeats anyway, so skipping one costs nothing
        /// and keeps a queued tap from waiting on it.
        case pollable
        /// Something the user just pressed.
        case transport
    }
}
