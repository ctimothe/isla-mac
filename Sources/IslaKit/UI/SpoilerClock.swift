import SwiftUI

/// One animation clock for every spoiler field inside it.
///
/// A covered list is many rows of the same dust, and each row drawing itself
/// from its own `TimelineView` means N schedules, N invalidations and N
/// wake-ups per frame for one visual effect. Wrapping the list in this drives
/// all of them from a single 20 Hz timeline; each field still draws its own
/// seeded pattern, so nothing about the result changes.
///
/// `active` is false when nothing inside is covered. The Clipboard tab used to
/// run this clock whatever the cover said, so on a default install — covers
/// off — an unchanging list redrew twenty times a second for nothing (F-016).
struct SpoilerClock<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var active = true
    @ViewBuilder var content: Content

    var body: some View {
        if reduceMotion {
            // Still dust needs no clock at all.
            content.environment(\.spoilerTime, 0)
        } else {
            // Paused rather than taken out of the tree. Swapping the timeline
            // for bare content when the last row is revealed would change the
            // list's identity under the pointer: every row rebuilt, the
            // hovered one's controls gone mid-click, a row's Copied flash
            // cut short. A paused schedule keeps the same views and simply
            // stops waking them; the time it hands down is the last frame's,
            // so dust that is still fading out freezes where it was instead
            // of jumping to another pattern. Still a value, never nil, so no
            // field falls back to a timeline of its own.
            TimelineView(Self.schedule(active: active)) { timeline in
                content.environment(\.spoilerTime, timeline.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    /// 20 Hz while something is covered, no frames at all otherwise.
    static func schedule(active: Bool) -> AnimationTimelineSchedule {
        .animation(minimumInterval: 1.0 / 20, paused: !active)
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
