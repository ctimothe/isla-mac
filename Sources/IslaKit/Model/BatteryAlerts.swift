import Foundation

/// When Battery Low and Full Battery fire (spec §19.5 a, b).
///
/// A pure state machine over the power readings `AmbientWatch` already gets
/// from IOKit, so the rule is a test and the watch only forwards what this
/// returns. Each warning is a *crossing*, not a level: the battery menu's
/// level wobbles a point either way as the load changes, and a rule that
/// looked at the level alone would warn again on every wobble back down.
struct BatteryAlerts: Equatable {
    /// The levels a discharge warns at, highest first.
    static let lowLevels = [20, 10]
    /// A full charge is news again only after the battery falls under this,
    /// or the charger comes out: a battery held at 100 on power drifts to 99
    /// and back for hours.
    static let fullResetBelow = 95

    private var lowWarned: Set<Int> = []
    private var fullAnnounced = false
    private var last: AmbientWatch.Power?

    /// Seeded from the reading at launch, which never warns: a Mac whose
    /// battery is already under 20 when Isla starts has crossed the line
    /// before Isla was there, and a warning then would be about Isla
    /// starting, not about the battery. A battery already full on power is
    /// likewise already announced.
    init(seed: AmbientWatch.Power?) {
        last = seed
        guard let seed, let level = seed.level else { return }
        if seed.onExternalPower {
            fullAnnounced = level >= 100
        } else {
            lowWarned = Self.passed(at: level)
        }
    }

    /// The thresholds a discharge that begins at `level` has already passed:
    /// those strictly above it. A discharge that begins exactly at 20 has not
    /// crossed 20 yet; its next point down does.
    private static func passed(at level: Int) -> Set<Int> {
        Set(lowLevels.filter { level < $0 })
    }

    /// The alert a new reading raises, if any.
    mutating func reading(_ power: AmbientWatch.Power, lowPowerMode: Bool) -> AmbientActivity? {
        defer { last = power }
        guard let level = power.level else { return nil }
        if power.onExternalPower {
            if level < Self.fullResetBelow { fullAnnounced = false }
            // Full only when a charge on power reaches it. A battery that was
            // already full when the charger went in is the charger's moment
            // (rank 7), not a charge that has just finished.
            guard level >= 100, !fullAnnounced,
                  let last, last.onExternalPower, let before = last.level, before < 100
            else { return nil }
            fullAnnounced = true
            return .batteryFull(level: level)
        }
        fullAnnounced = false
        // The charger coming out starts a discharge, and starts it where the
        // battery is: unplugging at 15 is not a crossing of 20, it is a
        // battery that will cross 10. Like the seed, it never warns.
        guard let last, !last.onExternalPower else {
            lowWarned = Self.passed(at: level)
            return nil
        }
        // The lowest threshold crossed in this reading. A fall past both at
        // once (the lid shut at 22 and opened at 8) warns once, at the level
        // the battery is really at, and counts both as said.
        let crossed = Self.lowLevels.filter { level <= $0 && !lowWarned.contains($0) }
        guard !crossed.isEmpty else { return nil }
        lowWarned.formUnion(Self.lowLevels.filter { level <= $0 })
        return .batteryLow(level: level, lowPowerMode: lowPowerMode)
    }
}
