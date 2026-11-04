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
    ///
    /// `port` and `watts` (2026-10-26) choose between the two Charging
    /// activities: MagSafe's ring, and USB-C's battery with its wattage. Both
    /// default to what a Mac that cannot tell would say, so a moment built
    /// without them is the generic adapter, drawn as USB-C without a name.
    ///
    /// `hold` (amended 2026-10-26) is why a battery on power is not charging,
    /// read from the battery's own reason (`ChargeHoldReading`): nil when it
    /// gives none, which reads as before.
    case charging(
        level: Int?, isCharging: Bool, port: ChargePort = .adapter, watts: Int? = nil, hold: ChargeHold? = nil
    )
    /// A Bluetooth audio output appeared.
    case headphones(name: String, symbol: String)

    /// Whether the island can show it at all. A Mac with no battery shows no
    /// Charging activity (spec §19.4): it reports no level, and the level and
    /// the battery drawn round it are the activity.
    var showsOnIsland: Bool {
        if case .charging(nil, _, _, _, _) = self { return false }
        return true
    }

    /// How long it holds the island (spec §19.1): the charger 3 s, headphones
    /// 4 s — long enough to read a percentage, and a name with "Connected"
    /// over it. Both were 2.2 s, the track peek's beat.
    var holdDuration: TimeInterval {
        switch self {
        case .charging: return Self.chargingHold
        case .headphones: return 4
        }
    }

    /// The charger's hold, both variants: the ambient alert's 3 s.
    static let chargingHold: TimeInterval = 3

    /// The glyph for a charge: the bolt while charging, the plug while it only
    /// holds, as the battery menu draws them. On the island the bolt's place is
    /// the word "Charging" (§19.4); the plug still stands in for it while the
    /// battery holds, because "Charging" would not be true.
    var chargeSymbol: String {
        if case .charging(_, false, _, _, _) = self { return "powerplug.fill" }
        return "bolt.fill"
    }

    /// Whether the moment is drawn in the system green (spec §3.6): a battery
    /// that is charging and says how full it is. A Mac with no battery reports no
    /// level and gets a white bolt alone, a charge that is only being held gets
    /// a white plug, and headphones are white.
    var usesChargingGreen: Bool {
        chargeTint == .green
    }

    /// What the battery is doing, for the word in the left wing. Nil for
    /// headphones and for a Mac that reports no level.
    /// The charger's moment, as against the headphones'.
    var isChargerMoment: Bool {
        if case .charging = self { return true }
        return false
    }

    var chargeState: ChargeState? {
        guard case .charging(let level?, let isCharging, _, _, let hold) = self else { return nil }
        return ChargeState(level: level, isCharging: isCharging, hold: hold)
    }

    /// The level's colour, and the island's stroke with it: red at
    /// `ChargeState.lowLevel` or below, as the battery menu fills a low
    /// battery, green while charging above it, white (nil) while the battery
    /// only holds or is full — a white charge says nothing it would have to
    /// take back.
    var chargeTint: ChargeTint? {
        guard case .charging(let level?, _, _, _, _) = self else { return nil }
        if level <= ChargeState.lowLevel { return .red }
        // From the state, not the raw flag: a plug-in still settling is
        // drawn as Charging, green and all (`ChargeHold.settling`).
        return chargeState == .charging ? .green : nil
    }

    /// The left wing's first words: the way the power comes in, named on
    /// every state (owner, 2026-10-26) — "MagSafe", or the adapter's
    /// wattage ("61 W") over USB-C or an adapter the Mac cannot place. Nil
    /// when the Mac can say neither.
    var chargeSource: String? {
        guard case .charging(_, _, let port, let watts, _) = self, chargeState != nil else { return nil }
        if port == .magSafe { return localized("MagSafe") }
        if let watts { return localized("%d W", watts) }
        return nil
    }

    /// The left wing's second words, drawn dimmer after the source: what the
    /// battery is doing when that is news. Nil while it simply charges and
    /// the source already says so; "Charging" alone when there is no source
    /// to say it. A hold is "On Hold" beside a source and "Charging On Hold"
    /// on its own — Apple's own wording for a charge the Mac holds.
    var chargeStatus: String? {
        guard let state = chargeState else { return nil }
        let alone = chargeSource == nil
        switch state {
        case .charging: return alone ? localized("Charging") : nil
        case .onHold: return alone ? localized("Charging On Hold") : localized("On Hold")
        case .notCharging: return localized("Not Charging")
        case .charged: return localized("Charged")
        }
    }

    /// The status at its shortest, for a wing too narrow for the whole line:
    /// a hold is "On Hold" whether or not a source stands beside it.
    var shortChargeStatus: String? {
        chargeState == .onHold ? localized("On Hold") : (chargeStatus ?? chargeSource)
    }

    /// The whole left wing as one line: the source, then the status.
    var chargeHeadline: String? {
        let parts = [chargeSource, chargeStatus].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    var accessibilityLabel: String {
        switch self {
        case .charging(let level, _, let port, _, _):
            // No level: a Mac with no battery, which can only say the adapter is
            // in — and which shows no Charging activity at all (`showsOnIsland`).
            guard let level, let state = chargeState else { return localized("Power adapter connected") }
            switch (state, port) {
            case (.charging, .magSafe): return localized("Charging over MagSafe, %d percent", level)
            case (.charging, .usbC): return localized("Charging over USB-C, %d percent", level)
            case (.charging, .adapter): return localized("Charging, %d percent", level)
            case (.onHold, _): return localized("Power adapter connected, charging on hold, %d percent", level)
            case (.notCharging, _): return localized("Power adapter connected, not charging, %d percent", level)
            case (.charged, _): return localized("Power adapter connected, charged, %d percent", level)
            }
        case .headphones(let name, _):
            return localized("%@ connected", name)
        }
    }
}

/// What a battery on external power is doing (owner, 2026-10-26). "On Hold"
/// is a charge the Mac holds on purpose — Optimized Battery Charging at 80
/// percent, a charge limit — as the battery's own reason says
/// (`ChargeHoldReading`); "Not Charging" is every other reason, an unknown one
/// included; "Charged" is full. All three used to be the same white plug,
/// and until the hold was read, a held charge said "Not Charging".
enum ChargeState: Equatable {
    case charging
    case onHold
    case notCharging
    case charged

    /// The battery menu turns its fill red at 20 percent; so does the island.
    static let lowLevel = 20

    init(level: Int, isCharging: Bool, hold: ChargeHold? = nil) {
        if isCharging {
            self = .charging
        } else if level < 100, hold == .settling {
            self = .charging
        } else if level >= 100 || hold == .full {
            self = .charged
        } else if hold == .onHold {
            self = .onHold
        } else {
            self = .notCharging
        }
    }
}

/// The two colours a charge is drawn in; white is no tint at all.
enum ChargeTint: Equatable {
    case green
    case red
}
