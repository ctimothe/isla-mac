import CoreGraphics

/// The volume and brightness pop-up as the island draws it (spec §12, its look
/// §19.5 d): the highest of R7's alerts.
struct HUDMoment: Equatable {
    var kind: HUDKind
    /// 0…1. A muted volume keeps the level it will return to.
    var level: Float
    var muted: Bool
    /// The glyph beside the bar.
    var symbol: String
    /// The line above the bar: the output's name, or what is being
    /// brightened.
    var title: String

    init(_ reading: HUDReading) {
        kind = reading.kind
        level = min(max(reading.level, 0), 1)
        muted = reading.kind == .volume && reading.muted
        switch reading.kind {
        case .volume: title = reading.deviceName ?? localized("Volume")
        case .display: title = localized("Display Brightness")
        case .keyboard: title = localized("Keyboard Brightness")
        }
        switch reading.kind {
        case .volume:
            symbol = HUDSymbol.volume(level: reading.level, muted: reading.muted, deviceSymbol: reading.deviceSymbol)
        case .display:
            symbol = HUDSymbol.display
        case .keyboard:
            symbol = HUDSymbol.keyboard
        }
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
}

/// Which glyph the pop-up wears. Pure, so each rule is a test.
enum HUDSymbol {
    static let display = "sun.max.fill"
    static let keyboard = "light.max"
    /// One, two and three waves, by thirds of the level (spec §19.5 d).
    static let speakers = ["speaker.wave.1.fill", "speaker.wave.2.fill", "speaker.wave.3.fill"]
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
    /// headphones, else the speaker with as many waves as thirds of the level.
    static func volume(level: Float, muted isMuted: Bool, deviceSymbol: String?) -> String {
        if isMuted { return muted }
        if level <= 0 { return silent }
        if let deviceSymbol, personalDevices.contains(deviceSymbol) { return deviceSymbol }
        if level <= 1.0 / 3 + 0.0001 { return speakers[0] }
        if level <= 2.0 / 3 + 0.0001 { return speakers[1] }
        return speakers[2]
    }
}

/// Where everything sits inside the pop-up (spec §19.5 d), from the
/// reference's shape-relative numbers (`ExpandedAlertShape.volume`). Body-local,
/// like `CompactIslandLayout`: the origin is the island body's top-left and y
/// grows downward.
enum HUDLayout {
    static let shape = ExpandedAlertShape.volume

    /// The output's name, or "Display Brightness", or "Keyboard Brightness":
    /// 15 regular, white 0.90, at x 34, baseline 58, truncating at right 34.
    static let titleSize: CGFloat = 15
    static let titleOpacity: Double = 0.90
    static var titleLeading: CGFloat { shape.x(34) }
    static func titleBaseline(notchHeight: CGFloat) -> CGFloat { shape.y(58, notchHeight: notchHeight) }
    static func titleWidth(islandWidth: CGFloat) -> CGFloat {
        max(0, islandWidth - titleLeading - shape.trailing(34))
    }

    /// The symbol, white, in a 22 × 16 box at (35.5, 72.5).
    static let symbolSize = CGSize(width: 22, height: 16)
    static func symbolFrame(notchHeight: CGFloat) -> CGRect {
        CGRect(origin: CGPoint(x: shape.x(35.5), y: shape.y(72.5, notchHeight: notchHeight)), size: symbolSize)
    }

    /// The bar, 107 × 8 at radius 4, at (69.5, 76.5): a track in white 0.18,
    /// the level in amber from 0.82 to 1.0 left to right with a 5 pt glow at
    /// 0.80; muted, white 0.32 at the level it will return to, no glow.
    static let barHeight: CGFloat = 8
    static let barRadius: CGFloat = 4
    static let trackOpacity: Double = 0.18
    static let mutedFillOpacity: Double = 0.32
    static let fillStartOpacity: Double = 0.82
    static let glowRadius: CGFloat = 5
    static let glowOpacity: Double = 0.80
    /// The reference bar's distance from the shape's right edge, which a wider
    /// pop-up keeps: the bar grows between its start and the number.
    private static var barTrailing: CGFloat { shape.reference.width - 69.5 - 107 }

    static func trackFrame(islandWidth: CGFloat, notchHeight: CGFloat) -> CGRect {
        let x = shape.x(69.5)
        return CGRect(
            x: x,
            y: shape.y(76.5, notchHeight: notchHeight),
            width: max(0, islandWidth - x - shape.trailing(barTrailing)),
            height: barHeight
        )
    }

    /// The fill is the track's left `level × width`.
    static func fillFrame(level: Float, islandWidth: CGFloat, notchHeight: CGFloat) -> CGRect {
        var frame = trackFrame(islandWidth: islandWidth, notchHeight: notchHeight)
        frame.size.width *= CGFloat(min(max(level, 0), 1))
        return frame
    }

    /// The level as a number, 0–100, SF Pro Rounded 14, tabular, white 0.80,
    /// ending right 34.5, centred on the bar.
    static let numberSize: CGFloat = 14
    static let numberOpacity: Double = 0.80
    static var numberTrailingInset: CGFloat { shape.trailing(34.5) }
}
