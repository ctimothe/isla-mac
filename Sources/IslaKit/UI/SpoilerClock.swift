import SwiftUI

/// One animation clock for every spoiler field inside it.
///
/// A covered list is many rows of the same dust, and each row drawing itself
/// from its own `TimelineView` means N schedules, N invalidations and N
/// wake-ups per frame for one visual effect. Wrapping the list in this drives
/// all of them from a single 20 Hz timeline; each field still draws its own
/// seeded pattern, so nothing about the result changes.
struct SpoilerClock<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewBuilder var content: Content

    var body: some View {
        if reduceMotion {
            // Still dust needs no clock at all.
            content.environment(\.spoilerTime, 0)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 20)) { timeline in
                content.environment(\.spoilerTime, timeline.date.timeIntervalSinceReferenceDate)
            }
        }
    }
}

private struct SpoilerTimeKey: EnvironmentKey {
    static let defaultValue: TimeInterval? = nil
}

extension EnvironmentValues {
    /// Set by `SpoilerClock`; nil means a field should run its own timeline.
    var spoilerTime: TimeInterval? {
        get { self[SpoilerTimeKey.self] }
        set { self[SpoilerTimeKey.self] = newValue }
    }
}
