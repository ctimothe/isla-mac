import AppKit

/// One Isla per login.
///
/// A second copy used to run alongside the first: it drew a second island over
/// the same notch, spawned a second media helper, and fought the first for the
/// three global hot keys and for the Spotify sign-in callback — whichever copy
/// LaunchServices happened to pick could receive the code the other one was
/// waiting for. Three Islas were registered on 2026-09-21 (F-023), and opening
/// the build copy while the installed one ran was all it took.
///
/// So at launch, before anything is built, the newer copy hands over: it posts
/// `showNotification`, which the running copy answers by opening its panel —
/// launching Isla again means *show me Isla* — and then it quits.
///
/// Two designs were turned down. A lock file in Application Support outlives a
/// crash and then refuses every launch until somebody deletes it, and the
/// running process list cannot go stale that way. Letting both run with the
/// second copy's hot keys switched off still leaves two islands and two helpers.
enum LaunchGuard {
    /// What the decision needs to know about one running copy. A value rather
    /// than `NSRunningApplication`, so the decision can be played out in a test
    /// without a second process.
    struct Instance: Equatable {
        let pid: pid_t
        let bundleIdentifier: String?
        /// Nil for a binary started straight from a shell rather than through
        /// LaunchServices, which is how the gate scripts launch the build.
        let launchDate: Date?
    }

    /// Set to `1` by `Scripts/test-lifecycle.sh` and
    /// `Scripts/measure-performance.sh`: both launch the build while the
    /// owner's installed copy is running, and a build that handed over and
    /// quit would fail the lifecycle gate for a reason that has nothing to do
    /// with what it tests.
    static let allowSecondInstanceKey = "ISLA_ALLOW_SECOND_INSTANCE"

    /// Posted by a copy that is handing over; the running copy opens its panel.
    ///
    /// Any local process can post it. It only opens the panel, through the
    /// same lock refusal as ⌃⌥⌘I, so it is no more than a key anybody at the
    /// Mac can already press — not a privilege boundary.
    static let showNotification = Notification.Name("\(ProductIdentity.bundleIdentifier).show")

    /// Whether `own` should give way to a copy already in `running`.
    ///
    /// The older copy stays: it is the island the person has been looking at,
    /// and it holds the hot keys, the helper and any sign-in in flight. Two
    /// copies started in the same instant — or one of them without a launch
    /// date — are ordered by pid instead, so each reaches the same answer about
    /// the other and exactly one of them leaves.
    static func yieldingTo(
        own: Instance,
        running: [Instance],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if environment[allowSecondInstanceKey] == "1" { return false }
        // `swift run` builds no bundle, and with no identifier there is no way
        // to tell a copy of this app from any other unbundled process.
        guard let bundleIdentifier = own.bundleIdentifier else { return false }
        return running.contains { other in
            other.pid != own.pid
                && other.bundleIdentifier == bundleIdentifier
                && isOlder(other, than: own)
        }
    }

    private static func isOlder(_ a: Instance, than b: Instance) -> Bool {
        if let aDate = a.launchDate, let bDate = b.launchDate, aDate != bDate {
            return aDate < bDate
        }
        return a.pid < b.pid
    }

    /// The live answer, and the copy to hand over to when there is one.
    ///
    /// `runningApplications(withBundleIdentifier:)` includes this process, and
    /// can still list a copy that has just quit; neither is a copy to defer to.
    @MainActor
    static func olderCopy() -> NSRunningApplication? {
        let current = NSRunningApplication.current
        guard let bundleIdentifier = current.bundleIdentifier else { return nil }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { !$0.isTerminated && $0.processIdentifier != current.processIdentifier }
        guard yieldingTo(own: instance(current), running: others.map(instance)) else { return nil }
        // The one to hand over to is the oldest: with three copies running —
        // which this guard now prevents, but a machine can still be in that
        // state from before it — the newest two both defer to the same one.
        return others.min { isOlder(instance($0), than: instance($1)) }
    }

    private static func instance(_ app: NSRunningApplication) -> Instance {
        Instance(
            pid: app.processIdentifier,
            bundleIdentifier: app.bundleIdentifier,
            launchDate: app.launchDate
        )
    }
}
