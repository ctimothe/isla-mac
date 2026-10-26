import OSLog

/// Isla's own entries in the unified log, one category per subsystem.
///
/// Before this the app wrote a dozen bare `NSLog` lines with no subsystem.
/// They reached the log, but Copy Diagnostics had no way to pick out Isla's
/// lines, and Console could not filter them. `Diagnostics` reads these back
/// for the current process only.
///
/// Privacy follows `os.Logger`'s rule: an interpolated value is private unless
/// marked otherwise. States, reasons and an error's domain and code are marked
/// public, because a report that says "<private>" where the error should be
/// cannot be acted on. An error's description stays private wherever it can
/// name a file or a path: Cocoa's file errors quote the file name, and a path
/// in the home folder quotes the user's name. Track titles, file names and
/// clipboard text are never public.
enum Log {
    static let subsystem = "com.ctimothe.isla"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let media = Logger(subsystem: subsystem, category: "media")
    static let storage = Logger(subsystem: subsystem, category: "storage")
    static let shelf = Logger(subsystem: subsystem, category: "shelf")
    static let updates = Logger(subsystem: subsystem, category: "updates")
    static let permissions = Logger(subsystem: subsystem, category: "permissions")
    /// Each step of a Spotify sign-in and each refusal, with Spotify's own
    /// error code, description and HTTP status, and never a token, a code, a
    /// verifier or a state (2026-10-25: the owner's Connect failed and nothing
    /// said where). `log show --predicate 'subsystem == "com.ctimothe.isla"
    /// && category == "spotify"'` reads them back.
    static let spotify = Logger(subsystem: subsystem, category: "spotify")
}
