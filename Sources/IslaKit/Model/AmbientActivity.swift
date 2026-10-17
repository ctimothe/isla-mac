import CoreGraphics
import Foundation

/// Something the Mac itself did, shown on the island for a moment: the
/// charger going in, headphones connecting.
///
/// Before this the island existed only while music played. The category's
/// name comes from the iPhone's Live Activities, and the two moments people
/// look for first on a Mac are these two (see the 2026-09-23 market notes in
/// `docs/plans/2026-09-23-for-strangers.md`). Both come from public APIs, IOKit
/// power sources and the CoreAudio device list, and neither needs a
/// permission.
enum AmbientActivity: Equatable {
    /// External power arrived. The level is nil on a Mac that reports none.
    /// `isCharging` is false when the battery holds rather than charges: at
    /// its limit, or with charging paused.
    case charging(level: Int?, isCharging: Bool)
    /// A Bluetooth audio output appeared.
    case headphones(name: String, symbol: String)

    /// How much wider than the notch the pill grows for it. The charge fits
    /// the resting pill — the same 300 pt as the music island since the
    /// redesign (spec §3.6). A device name needs a wider right wing: two 104 pt
    /// wings, 208 in all, but not the peek's whole title-and-artist width, which
    /// drawn with one short name left half the pill empty.
    var extensionWidth: CGFloat {
        switch self {
        case .charging: return NotchMetrics.compactMediaExtension
        case .headphones: return NotchMetrics.ambientNameExtension
        }
    }

    /// How long it holds the island (spec §19.1): the charger 3 s, headphones
    /// 4 s — long enough to read a percentage, and a name with "Connected"
    /// over it. Both were 2.2 s, the track peek's beat.
    var holdDuration: TimeInterval {
        switch self {
        case .charging: return 3
        case .headphones: return 4
        }
    }

    /// The left wing's glyph for the charger: the bolt while charging, the
    /// plug while it only holds, as the battery menu draws them.
    var chargeSymbol: String {
        if case .charging(_, false) = self { return "powerplug.fill" }
        return "bolt.fill"
    }

    /// Whether the moment is drawn in the system green (spec §3.6): a battery
    /// that is charging and says how full it is. A Mac with no battery reports no
    /// level and gets a white bolt alone, a charge that is only being held gets
    /// a white plug, and headphones are white.
    var usesChargingGreen: Bool {
        guard case .charging(let level, let isCharging) = self else { return false }
        return isCharging && level != nil
    }

    var accessibilityLabel: String {
        switch self {
        case .charging(let level, let isCharging):
            guard isCharging else {
                guard let level else { return localized("Power adapter connected") }
                return localized("Power adapter connected, %d percent", level)
            }
            // No level: a Mac with no battery, which can only say the adapter is
            // in. "Charging" used to say it, but that key is now the Settings row
            // "Charging" under "The island shows" (spec §10, §15: "Зарядку", an
            // accusative no status line can use), and one key cannot be both.
            guard let level else { return localized("Power adapter connected") }
            return localized("Charging, %d percent", level)
        case .headphones(let name, _):
            return localized("%@ connected", name)
        }
    }
}
