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
    /// Identity of the track, used to decide when artwork must be refetched.
    var key: String { "\(app.rawValue)|\(title)|\(artist)|\(album)" }
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
        runScript(Script.state(for: app)) { descriptor in
            completion(descriptor?.stringValue.map { interpret($0, app: app) } ?? .unknown)
        }
    }

    static func state(of app: PlayerApp, completion: @escaping (PlayerState?) -> Void) {
        stateReply(of: app) { reply in
            if case let .loaded(state) = reply { completion(state) } else { completion(nil) }
        }
    }

    /// The Spotify catalogue id of the current track ("spotify:track:…" →
    /// the bare id). The licensed broker can use it to refine a match.
    static func spotifyTrackID(completion: @escaping @MainActor (String?) -> Void) {
        runScript(Script.spotifyTrackID) { result in
            MainActor.assumeIsolated {
                let raw = result?.stringValue ?? ""
                completion(raw.hasPrefix("spotify:track:") ? String(raw.dropFirst("spotify:track:".count)) : nil)
            }
        }
    }

    /// A scriptable player's own playback position, fractional seconds, asked
    /// directly. The player clock beats MediaRemote's stale elapsed reading.
    static func precisePosition(
        of app: PlayerApp,
        completion: @escaping @MainActor (TimeInterval?) -> Void
    ) {
        runScript(Script.position(of: app), priority: .pollable) { result in
            MainActor.assumeIsolated {
                completion(result?.stringValue.flatMap { TimeInterval($0.replacingOccurrences(of: ",", with: ".")) })
            }
        }
    }

    /// Never launches a player: only already-running ones are queried, and a
    /// playing app wins over a merely-open one.
    static func currentState(completion: @escaping (PlayerState?) -> Void) {
        let candidates = PlayerApp.allCases.filter(\.isRunning)
        guard !candidates.isEmpty else { return completion(nil) }

        var results: [PlayerState] = []
        let group = DispatchGroup()
        for app in candidates {
            group.enter()
            state(of: app) { state in
                if let state { results.append(state) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            completion(results.first(where: \.isPlaying) ?? results.first)
        }
    }

    // MARK: - Shuffle & repeat

    /// Repeat as the players model it. Spotify's scripting exposes only a
    /// boolean, so `.one` is reachable there through the app itself but not
    /// settable from outside; Music has the full three states.
    enum RepeatMode: String {
        case off, all, one
    }

    /// Both flags in one round trip, or nil when the player refuses to answer.
    static func playbackModes(of app: PlayerApp, completion: @escaping @MainActor ((shuffle: Bool, repeatMode: RepeatMode)?) -> Void) {
        guard app.isRunning else {
            Task { @MainActor in completion(nil) }
            return
        }
        runScript(Script.playbackModes(of: app), priority: .pollable) { result in
            MainActor.assumeIsolated {
                guard let raw = result?.stringValue else { return completion(nil) }
                let parts = raw.split(separator: "|").map(String.init)
                guard parts.count == 2 else { return completion(nil) }
                let shuffle = parts[0] == "true"
                let mode: RepeatMode
                switch parts[1] {
                case "one": mode = .one
                case "all", "true": mode = .all
                default: mode = .off
                }
                completion((shuffle, mode))
            }
        }
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
            }
        }

        /// One of every kind, so the compile test covers each body.
        static let everyKind: [Transport] = [
            .play, .pause, .next, .previous, .seek(seconds: 0),
            .shuffle(true), .repeatMode(.one), .repeatMode(.off),
        ]
    }

    /// Play and pause travel as explicit states, never as a toggle: a toggle
    /// sent against a state the island misread lands backwards.
    static func send(_ action: Transport, to app: PlayerApp) {
        guard app.isRunning else { return }
        runScript(Script.command(action.body(for: app), on: app), priority: .transport) { _ in }
    }

    /// System-wide media key, used when no scriptable player is running.
    /// Requires Accessibility permission; silently does nothing without it.
    static func postMediaKey(_ key: Int32) {
        for down in [true, false] {
            let flags: Int = down ? 0xA00 : 0xB00
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: (Int(key) << 16) | flags,
                data2: -1
            ) else { continue }
            event.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    enum MediaKey: Int32 {
        case playPause = 16, next = 17, previous = 18
    }

    // MARK: - Artwork

    static func artwork(for state: PlayerState, completion: @escaping (NSImage?) -> Void) {
        switch state.app {
        case .spotify:
            // The one thing the app ever fetches over the network. The address
            // comes out of another app's scripting dictionary, so the scheme is
            // checked: https answers for itself through TLS, while file:// or
            // some private scheme answers to nobody.
            guard let url = state.artworkURL, url.scheme?.lowercased() == "https" else {
                return completion(nil)
            }
            URLSession.shared.dataTask(with: url) { data, _, _ in
                let image = data.flatMap(NSImage.init(data:))
                DispatchQueue.main.async { completion(image) }
            }.resume()
        case .music:
            runScript(Script.musicArtwork) { descriptor in
                guard let data = descriptor?.data, !data.isEmpty else { return completion(nil) }
                completion(NSImage(data: data))
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

        static let spotifyTrackID = """
        tell application id "\(PlayerApp.spotify.bundleID)"
            if it is running then
                return (id of current track as text)
            end if
        end tell
        """

        static func position(of app: PlayerApp) -> String {
            """
            tell application id "\(app.bundleID)"
                if it is running then
                    return (player position as text)
                end if
            end tell
            """
        }

        static func playbackModes(of app: PlayerApp) -> String {
            switch app {
            case .music:
                return """
                tell application id "\(app.bundleID)"
                    set s to shuffle enabled
                    set r to song repeat
                    return (s as text) & "|" & (r as text)
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

        static let musicArtwork = """
        tell application id "com.apple.Music"
            if (count of artworks of current track) is 0 then return missing value
            return raw data of artwork 1 of current track
        end tell
        """

        static func command(_ body: String, on app: PlayerApp) -> String {
            """
            tell application id "\(app.bundleID)"
                \(body)
            end tell
            """
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

    static func runScript(
        _ source: String,
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
            if let error, let code = error[NSAppleScript.errorNumber] as? Int, code != 0 {
                // The message can echo a value from the script, a track name
                // among them, so only the code is public.
                Log.media.error("AppleScript error \(code, privacy: .public): \(String(describing: error[NSAppleScript.errorMessage] ?? ""), privacy: .private)")
            }
            DispatchQueue.main.async { completion(result) }
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
