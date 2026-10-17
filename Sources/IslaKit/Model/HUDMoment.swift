import CoreGraphics

/// The volume and brightness pop-up as the island draws it (redesign
/// 2026-10-15, spec §12): the highest-priority moment the island has.
struct HUDMoment: Equatable {
    var kind: HUDKind
    /// 0…1. A muted volume keeps the level it will return to.
    var level: Float
    var muted: Bool
    /// The glyph in the left wing.
    var symbol: String

    init(_ reading: HUDReading) {
        kind = reading.kind
        level = min(max(reading.level, 0), 1)
        muted = reading.kind == .volume && reading.muted
        switch reading.kind {
        case .volume:
            symbol = HUDSymbol.volume(level: reading.level, muted: reading.muted, deviceSymbol: reading.deviceSymbol)
        case .display:
            symbol = HUDSymbol.display
        case .keyboard:
            symbol = HUDSymbol.keyboard
        }
    }

    /// 13 pt, and 12 for a device's own glyph: the AirPods board draws them a
    /// point smaller, since they carry more drawing in the same box.
    var symbolPointSize: CGFloat {
        HUDSymbol.isDeviceSymbol(symbol) ? HUDLayout.deviceSymbolPointSize : HUDLayout.symbolPointSize
    }

    /// The bar's fill: white, or white 0.32 when muted — dimmed, never emptied.
    var fillOpacity: Double {
        muted ? HUDLayout.mutedFillOpacity : 1
    }

    /// The percent, as the Mac's own pop-up would say it.
    var percent: Int { Int((level * 100).rounded()) }

    /// What VoiceOver hears: the level, or "Muted". New strings (spec §15).
    var accessibilityLabel: String {
        if muted { return localized("Muted") }
        let spoken = localized("%d%%", percent)
        switch kind {
        case .volume: return localized("Volume %@", spoken)
        case .display: return localized("Brightness %@", spoken)
        case .keyboard: return localized("Keyboard Brightness %@", spoken)
        }
    }

    /// How much wider than the notch the island grows: a 104 pt wing each side.
    var extensionWidth: CGFloat { 2 * HUDLayout.wing }
}

/// Which glyph the left wing wears. Pure, so each rule is a test.
enum HUDSymbol {
    static let display = "sun.max.fill"
    static let keyboard = "light.max"
    static let speaker = "speaker.wave.2.fill"
    static let silent = "speaker.fill"
    static let muted = "speaker.slash.fill"

    /// The device glyphs that say *where the sound is going* and are worth
    /// putting in place of the speaker: what is on the head, not what is on the
    /// desk. A laptop or a TV as the output is the Mac's ordinary state and
    /// says nothing; the speaker glyph stays.
    static let personalDevices: Set<String> = [
        "airpods", "airpods.pro", "airpods.max", "beats.headphones", "headphones",
    ]

    static func isDeviceSymbol(_ symbol: String) -> Bool { personalDevices.contains(symbol) }

    /// Muted first, then silence, then the device's own glyph for AirPods and
    /// headphones, else the speaker with its waves.
    static func volume(level: Float, muted isMuted: Bool, deviceSymbol: String?) -> String {
        if isMuted { return muted }
        if level <= 0 { return silent }
        if let deviceSymbol, personalDevices.contains(deviceSymbol) { return deviceSymbol }
        return speaker
    }
}

/// Where everything sits inside the pop-up (spec §12; the board's `hud()`).
///
/// Island-local, like `CompactIslandLayout`: the origin is the island body's
/// top-left and y grows downward.
enum HUDLayout {
    /// Each wing, so the pop-up is the notch plus 208 — 428 on a 14-inch Mac.
    /// The headphones moment takes the same wings (`ambientNameExtension`).
    static let wing: CGFloat = 104
    static let symbolPointSize: CGFloat = 13
    static let deviceSymbolPointSize: CGFloat = 12

    static let barHeight: CGFloat = 6
    static let barRadius: CGFloat = 3
    /// The bar sits 12 from the island's right edge, and its track is the wing
    /// less 12 on each side: 80 pt.
    static let barInset: CGFloat = 12
    static var barWidth: CGFloat { wing - 2 * barInset }
    static let trackOpacity: Double = 0.18
    static let mutedFillOpacity: Double = 0.32

    /// The track, centred on the cover's row; the fill is its left
    /// `level × width`.
    static func trackFrame(islandWidth: CGFloat, height: CGFloat) -> CGRect {
        CGRect(
            x: islandWidth - barInset - barWidth,
            y: (height - barHeight) / 2,
            width: barWidth,
            height: barHeight
        )
    }

    static func fillFrame(level: Float, islandWidth: CGFloat, height: CGFloat) -> CGRect {
        var frame = trackFrame(islandWidth: islandWidth, height: height)
        frame.size.width *= CGFloat(min(max(level, 0), 1))
        return frame
    }
}
