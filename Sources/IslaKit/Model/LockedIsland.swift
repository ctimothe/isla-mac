import CoreGraphics

/// What the island does over the lock screen (redesign 2026-10-15, spec §3.7,
/// owner decision 1): **one surface per activity**.
///
/// While the lock banner or the lock card is on screen it is the song's surface,
/// and the island at the notch shows no wings — it rests in the notch exactly as
/// when nothing plays, the way the iPhone shows a Live Activity on the Lock Screen
/// *instead of* in its island, never in both at once. A hover still
/// nudges the resting notch and a click still refuses with `RefusalShake` and
/// "Unlock your Mac to open Isla." With Show on Lock Screen off nothing of this
/// applies and the island behaves as it did.
///
/// Pure, so the rule is held by `LockedIslandTests` rather than by a view's
/// `if`.
enum LockedIsland {
    /// Whether the banner or the card is what the lock screen shows of the song:
    /// the Mac is locked, the card is switched on, and there is a song for it to
    /// draw — the card window is made on every lock and draws nothing without a
    /// track (F-026), so with none there is no surface to defer to.
    static func presentsSong(locked: Bool, showOnLockScreen: Bool, hasTrack: Bool) -> Bool {
        locked && showOnLockScreen && hasTrack
    }

    /// Whether the island's wings are drawn: the compact island shows something
    /// (`compactVisible`), and nothing else on the lock screen is showing it.
    static func showsWings(
        compactVisible: Bool, locked: Bool, showOnLockScreen: Bool, hasTrack: Bool
    ) -> Bool {
        compactVisible && !presentsSong(locked: locked, showOnLockScreen: showOnLockScreen, hasTrack: hasTrack)
    }
}

extension NotchViewModel {
    /// The banner or the card holds the song on the lock screen right now.
    var lockSurfacePresentsSong: Bool {
        LockedIsland.presentsSong(
            locked: isLockedPresentation, showOnLockScreen: showOnLockScreen(), hasTrack: media.track != nil
        )
    }

    /// Whether the locked island draws wings.
    var lockedIslandShowsWings: Bool {
        LockedIsland.showsWings(
            compactVisible: compactMediaActivity.isVisible, locked: isLockedPresentation,
            showOnLockScreen: showOnLockScreen(), hasTrack: media.track != nil
        )
    }

    /// The region over the shield that answers the pointer: the wings' width
    /// while they are drawn, and — now that the island rests in the notch while
    /// the banner holds the song — the notch grown for a hover (8 pt each side
    /// and its shoulders), so the nudge the pointer asked for lands inside the
    /// rect that heard it.
    var lockedIslandSize: CGSize {
        let notch = geometry.notchSize
        if lockSurfacePresentsSong {
            return CGSize(
                width: notch.width + 2 * (Theme.collapsedTopRadius + NotchMetrics.hoverNudgeWidth),
                height: notch.height
            )
        }
        return CGSize(width: bodySize.width, height: notch.height)
    }
}
