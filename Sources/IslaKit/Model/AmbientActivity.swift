import CoreGraphics
import Foundation

/// Something the Mac itself did, shown on the island for a moment: the
/// charger going in, headphones connecting.
///
/// Before this the island existed only while music played. The category's
/// name comes from the iPhone's Live Activities, and the two moments people
/// look for first on a Mac are these two (see the 2026-09-23 market notes in
/// `docs/development/plans/2026-09-23-for-strangers.md`). Both come from public APIs, IOKit
/// power sources and the CoreAudio device list, and neither needs a
/// permission.
enum AmbientActivity: Equatable {
    /// External power arrived. The level is nil on a Mac that reports none.
    /// `isCharging` is false when the battery holds rather than charges: at
    /// its limit, or with charging paused.
    case charging(level: Int?, isCharging: Bool)
    /// A Bluetooth audio output appeared.
    case headphones(name: String, symbol: String)

    /// Whether the island can show it at all. A Mac with no battery shows no
    /// Charging activity (spec §19.4): it reports no level, and the level and
    /// the battery drawn round it are the activity.
    var showsOnIsland: Bool {
        if case .charging(nil, _) = self { return false }
        return true
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

    /// The glyph for a charge: the bolt while charging, the plug while it only
    /// holds, as the battery menu draws them. On the island the bolt's place is
    /// the word "Charging" (§19.4); the plug still stands in for it while the
    /// battery holds, because "Charging" would not be true.
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
            // in — and which shows no Charging activity at all (`showsOnIsland`).
            guard let level else { return localized("Power adapter connected") }
            return localized("Charging, %d percent", level)
        case .headphones(let name, _):
            return localized("%@ connected", name)
        }
    }
}
