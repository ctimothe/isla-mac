import OSLog

/// Isla's own entries in the unified log, one category per subsystem.
///
/// Before this the app wrote a dozen bare `NSLog` lines with no subsystem.
/// They reached the log, but Copy Diagnostics had no way to pick out Isla's
/// lines, and Console could not filter them. `Diagnostics` reads these back
/// for the current process only.
///
/// Privacy follows `os.Logger`'s rule: an interpolated value is private unless
/// marked otherwise. Error descriptions and states are marked public, because
/// a report that says "<private>" where the error should be cannot be acted
/// on. Track titles, file names and clipboard text are never marked public.
enum Log {
    static let subsystem = "com.ctimothe.isla"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let media = Logger(subsystem: subsystem, category: "media")
    static let storage = Logger(subsystem: subsystem, category: "storage")
    static let shelf = Logger(subsystem: subsystem, category: "shelf")
    static let updates = Logger(subsystem: subsystem, category: "updates")
}
