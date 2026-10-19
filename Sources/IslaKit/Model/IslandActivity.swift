import Foundation

/// What the island shows (redesign spec §19.1): exactly one activity, chosen by
/// rank.
///
/// It replaced `IslandMoment`, a three-way choice between the pop-up, the
/// charger or headphones, and the peek that left the song and the Shelf to
/// whoever drew the pill. The island is now a list of everything that can hold
/// it — alerts, which come and go, and live activities, which stand while
/// something is true — and this is the one function that says which one does.
///
/// The ranks are §19.1's table. Locked (1) and files dragged to the notch (2)
/// are presentations of their own — the locked pill and the drop surface —
/// and never reach this function; Battery Low, Translated and Full Battery
/// (4, 5, 8) are R9's and join it there. The update choice (9) was built
/// ahead of R9, with the local update feed (plan 2026-10-19).
enum IslandActivity: Equatable {
    /// Volume or brightness (§19.5 d), rank 3.
    case hud(HUDMoment)
    /// Headphones connected (§19.5 c, rank 6) or the charger (§19.4, rank 7).
    case ambient(AmbientActivity)
    /// An update Isla can install, with a choice of Later or Install
    /// (§19.5 f), rank 9.
    case update(UpdateOffer)
    /// A new track showing itself (§3.5, kept), rank 10.
    case peek
    /// Something playing (§19.4), rank 11: live while `CompactMediaActivity`
    /// is not hidden.
    case music
    /// The Shelf holding files (§19.4, §19.7), rank 12: live while it has any.
    case shelf(count: Int)
    /// The bare notch.
    case none

    /// §19.1's rank, 1 the highest; nil for the bare notch.
    var rank: Int? {
        switch self {
        case .hud: return 3
        case .ambient(.headphones): return 6
        case .ambient(.charging): return 7
        case .update: return 9
        case .peek: return 10
        case .music: return 11
        case .shelf: return 12
        case .none: return nil
        }
    }

    /// An alert comes, holds for its time, and folds.
    var isAlert: Bool {
        switch self {
        case .hud, .ambient, .update, .peek: return true
        case .music, .shelf, .none: return false
        }
    }

    /// A live activity stands for as long as what it shows is true.
    var isLive: Bool {
        switch self {
        case .music, .shelf: return true
        case .hud, .ambient, .update, .peek, .none: return false
        }
    }

    /// Whether it waits for the island when it cannot show at once. Volume and
    /// brightness never do: while a surface is open the key applies and
    /// nothing is drawn, and a level shown a second late is a level out of
    /// date (R5).
    var queues: Bool {
        if case .hud = self { return false }
        return isAlert
    }

    /// The highest of what is standing. The alerts are the controller's to
    /// keep one at a time (`IslandAlertQueue`); if more than one is set, the
    /// highest still wins here, so the island never draws two.
    static func current(
        hud: HUDMoment?, ambient: AmbientActivity?, update: UpdateOffer? = nil,
        isPeeking: Bool, musicIsVisible: Bool, shelfCount: Int
    ) -> IslandActivity {
        if let hud { return .hud(hud) }
        if let ambient { return .ambient(ambient) }
        if let update { return .update(update) }
        // A peek widens the music pill to show a new title; with no song to
        // widen there is nothing for it to draw.
        if isPeeking && musicIsVisible { return .peek }
        if musicIsVisible { return .music }
        if shelfCount > 0 { return .shelf(count: shelfCount) }
        return .none
    }

    /// The second live activity, waiting as a bubble beside the island
    /// (§19.1, §19.7): the Shelf's count while Music holds the island. Only
    /// Music and the Shelf are live, so only the Shelf is ever the bubble, and
    /// only beside a compact live activity — never during an alert, while a
    /// surface is open, or while locked.
    static func bubble(beside activity: IslandActivity, shelfCount: Int, isOpen: Bool, isLocked: Bool) -> Int? {
        guard activity == .music, shelfCount > 0, !isOpen, !isLocked else { return nil }
        return shelfCount
    }
}

/// The island's alerts in time (spec §19.1).
///
/// A higher alert replaces a lower one at once, and an equal one replaces the
/// older; a replaced alert is dropped. An alert that cannot show within a
/// second of its cause — a surface is open, the Mac is locked, a higher alert
/// holds — is dropped. The second is the difference between an island that
/// tells you what just happened and one that tells you, later, what happened a
/// while ago.
///
/// What is *showing* is not kept here: the view model's fields are the one
/// record of it, and the controller passes it in, so the two cannot disagree.
/// This keeps only what is waiting. Pure, on a clock handed in, so the rule is
/// a test (`IslandActivityTests`).
struct IslandAlertQueue {
    /// How long an alert may wait for the island before it is dropped.
    static let patience: TimeInterval = 1

    /// The two exceptions to the rule. Battery Low and the update choice
    /// outlive the second and wait until the island is free; the update choice
    /// also returns when a higher alert replaces it. Battery Low is R9's; the
    /// update choice came ahead of it (plan 2026-10-19), so the standard
    /// policy names it alone, and a test proves Battery Low's half with a
    /// stand-in.
    struct Policy {
        var outlivesPatience: (IslandActivity) -> Bool
        var returnsWhenReplaced: (IslandActivity) -> Bool

        static let standard = Policy(outlivesPatience: isUpdate, returnsWhenReplaced: isUpdate)

        private static func isUpdate(_ alert: IslandActivity) -> Bool {
            if case .update = alert { return true }
            return false
        }
    }

    enum Verdict: Equatable {
        /// Show it now, replacing whatever alert is showing.
        case show
        /// It waits for the island, for a second at most.
        case wait
        /// It will not be shown.
        case drop
    }

    struct Entry: Equatable {
        var alert: IslandActivity
        var cause: Date
    }

    private(set) var waiting: [Entry] = []
    private let policy: Policy

    init(policy: Policy = .standard) {
        self.policy = policy
    }

    /// An alert's cause, at `now`. `showing` is what the island holds;
    /// `blocked` is a surface open or the Mac locked.
    mutating func post(_ alert: IslandActivity, showing: IslandActivity, blocked: Bool, at now: Date) -> Verdict {
        guard let rank = alert.rank, alert.isAlert else { return .drop }
        expire(at: now)
        let outranked = showing.isAlert && (showing.rank ?? .max) < rank
        if !blocked && !outranked {
            if showing.isAlert, showing.rank != rank, policy.returnsWhenReplaced(showing) {
                waiting.append(Entry(alert: showing, cause: now))
            }
            // Anything of its rank still waiting is older, and this replaces it.
            waiting.removeAll { $0.alert.rank == rank }
            return .show
        }
        guard alert.queues else { return .drop }
        waiting.removeAll { $0.alert.rank == rank }
        waiting.append(Entry(alert: alert, cause: now))
        return .wait
    }

    /// The island is free — an alert folded, a surface closed, the Mac
    /// unlocked: the highest alert still waiting inside its second, taken off
    /// the queue, or nil. Of two of a rank the newer goes first.
    mutating func next(at now: Date) -> IslandActivity? {
        expire(at: now)
        guard let best = waiting.indices.min(by: { a, b in
            let ra = waiting[a].alert.rank ?? .max, rb = waiting[b].alert.rank ?? .max
            return ra != rb ? ra < rb : waiting[a].cause > waiting[b].cause
        }) else { return nil }
        return waiting.remove(at: best).alert
    }

    /// Forgets everything waiting: the displays went dark.
    mutating func removeAll() {
        waiting.removeAll()
    }

    private mutating func expire(at now: Date) {
        waiting.removeAll { entry in
            !policy.outlivesPatience(entry.alert) && now.timeIntervalSince(entry.cause) > Self.patience
        }
    }
}
