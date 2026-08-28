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

    static func state(of app: PlayerApp, completion: @escaping (PlayerState?) -> Void) {
        guard app.isRunning else { return completion(nil) }
        runScript(stateScript(for: app)) { descriptor in
            guard let raw = descriptor?.stringValue, !raw.isEmpty else { return completion(nil) }
            completion(parse(raw, app: app))
        }
    }

    /// The Spotify catalogue id of the current track ("spotify:track:…" →
    /// the bare id). The community word-lyrics database is keyed by it.
    static func spotifyTrackID(completion: @escaping @MainActor (String?) -> Void) {
        let script = """
        tell application id "\(PlayerApp.spotify.bundleID)"
            if it is running then
                return (id of current track as text)
            end if
        end tell
        """
        runScript(script) { result in
            MainActor.assumeIsolated {
                let raw = result?.stringValue ?? ""
                completion(raw.hasPrefix("spotify:track:") ? String(raw.dropFirst("spotify:track:".count)) : nil)
            }
        }
    }

    /// Spotify's own playback position, fractional seconds, asked directly.
    /// The one scriptable value that beats MediaRemote: the daemon's readings
    /// sit about a second stale, the player's own answer lands within ~50ms.
    static func preciseSpotifyPosition(completion: @escaping @MainActor (TimeInterval?) -> Void) {
        let script = """
        tell application id "\(PlayerApp.spotify.bundleID)"
            if it is running then
                return (player position as text)
            end if
        end tell
        """
        runScript(script, priority: .pollable) { result in
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
        let script: String
        switch app {
        case .music:
            script = """
            tell application id "\(app.bundleID)"
                set s to shuffle enabled
                set r to song repeat
                return (s as text) & "|" & (r as text)
            end tell
            """
        case .spotify:
            script = """
            tell application id "\(app.bundleID)"
                set s to shuffling
                set r to repeating
                return (s as text) & "|" & (r as text)
            end tell
            """
        }
        runScript(script, priority: .pollable) { result in
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

    static func setShuffle(_ app: PlayerApp, enabled: Bool) {
        switch app {
        case .music: command("set shuffle enabled to \(enabled)", on: app)
        case .spotify: command("set shuffling to \(enabled)", on: app)
        }
    }

    static func setRepeat(_ app: PlayerApp, mode: RepeatMode) {
        switch app {
        case .music:
            command("set song repeat to \(mode.rawValue)", on: app)
        case .spotify:
            // Scripting has only the boolean; `.one` maps to on, matching how
            // Spotify itself degrades the state over this interface.
            command("set repeating to \(mode != .off)", on: app)
        }
    }

    // MARK: - Transport

    static func playPause(_ app: PlayerApp) { command("playpause", on: app) }
    static func next(_ app: PlayerApp) { command("next track", on: app) }
    static func previous(_ app: PlayerApp) {
        // Spotify's `previous track` restarts the current song first, matching
        // its own UI; Music behaves the same way. Seeking to 0 first is what
        // users expect from a "skip back" button.
        command(app == .spotify ? "set player position to 0\n    previous track" : "back track", on: app)
    }

    static func seek(_ app: PlayerApp, to seconds: TimeInterval) {
        command("set player position to \(Int(seconds))", on: app)
    }

    private static func command(_ body: String, on app: PlayerApp) {
        guard app.isRunning else { return }
        runScript("""
        tell application id "\(app.bundleID)"
            \(body)
        end tell
        """, priority: .transport) { _ in }
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
            runScript("""
            tell application id "com.apple.Music"
                if (count of artworks of current track) is 0 then return missing value
                return raw data of artwork 1 of current track
            end tell
            """) { descriptor in
                guard let data = descriptor?.data, !data.isEmpty else { return completion(nil) }
                completion(NSImage(data: data))
            }
        }
    }

    // MARK: - Scripts

    private static func stateScript(for app: PlayerApp) -> String {
        let sep = "set sep to character id 1"
        switch app {
        case .spotify:
            return """
            \(sep)
            tell application id "com.spotify.client"
                try
                    set st to player state as text
                    set t to current track
                    try
                        set pos to (round ((player position) * 1000))
                    on error
                        set pos to 0
                    end try
                    return st & sep & (name of t) & sep & (artist of t) & sep & (album of t) & sep & (duration of t) & sep & pos & sep & (artwork url of t)
                on error
                    return ""
                end try
            end tell
            """
        case .music:
            return """
            \(sep)
            tell application id "com.apple.Music"
                try
                    set st to player state as text
                    set t to current track
                    try
                        set pos to (round ((player position) * 1000))
                    on error
                        set pos to 0
                    end try
                    return st & sep & (name of t) & sep & (artist of t) & sep & (album of t) & sep & (round ((duration of t) * 1000)) & sep & pos & sep & ""
                on error
                    return ""
                end try
            end tell
            """
        }
    }

    private static func parse(_ raw: String, app: PlayerApp) -> PlayerState? {
        let parts = raw.components(separatedBy: "\u{1}")
        guard parts.count >= 6, !parts[1].isEmpty else { return nil }
        return PlayerState(
            app: app,
            isPlaying: parts[0].lowercased() == "playing",
            title: parts[1],
            artist: parts[2],
            album: parts[3],
            duration: (Double(parts[4]) ?? 0) / 1000,
            position: (Double(parts[5]) ?? 0) / 1000,
            artworkURL: parts.count > 6 ? URL(string: parts[6]) : nil
        )
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

    static func runScript(
        _ source: String,
        priority: Priority = .background,
        completion: @escaping (NSAppleEventDescriptor?) -> Void
    ) {
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
                NSLog("Isla: AppleScript error \(code): \(error[NSAppleScript.errorMessage] ?? "")")
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
