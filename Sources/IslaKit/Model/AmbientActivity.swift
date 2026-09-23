import CoreGraphics

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
    case charging(level: Int?)
    /// A Bluetooth audio output appeared.
    case headphones(name: String, symbol: String)

    /// How much wider than the notch the pill grows for it. The charge fits
    /// the resting pill. A device name needs a wider right wing, but not the
    /// peek's whole title-and-artist width, which drawn with one short name
    /// left half the pill empty.
    var extensionWidth: CGFloat {
        switch self {
        case .charging: return NotchMetrics.compactMediaExtension
        case .headphones: return NotchMetrics.ambientNameExtension
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .charging(let level):
            guard let level else { return localized("Charging") }
            return localized("Charging, %d percent", level)
        case .headphones(let name, _):
            return localized("%@ connected", name)
        }
    }
}
