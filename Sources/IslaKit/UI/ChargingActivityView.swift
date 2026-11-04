import SwiftUI

/// The two Charging activities (spec §19.4, amended 2026-10-26), compact, in
/// the island's wings: the left says what is happening, the right shows how
/// full the battery is.
///
/// - **MagSafe** borrows the iPhone's MagSafe idiom: a ring that draws round to
///   the level, a bolt inside it while charging, and the port's own name in
///   the left wing. The ring draws from empty on arrival, on the island's
///   spring; under Reduce Motion it is simply there.
/// - **USB-C** (and a Mac that cannot tell, `ChargePort.adapter`) keeps the
///   drawn battery of §19.4 and lays the menu bar's bolt over it while
///   charging; the left wing says the adapter's wattage when it reports one
///   ("61 W"), else "Charging".
///
/// The left wing always starts with the source — "MagSafe", or the watts —
/// and says the battery's state after it, dimmer (amended again 2026-10-26,
/// owner on hardware): "61 W On Hold" at the Optimized Charging limit,
/// "MagSafe Charged" when full, "Not Charging" for any other reason. The
/// state used to replace the source, so a held charge on the owner's 61 W
/// adapter read "Not Charging" with no port and no watts. A level at 20 percent or below is red in
/// both, as the battery menu fills a low battery (`AmbientActivity.chargeTint`).
/// Increase Contrast takes the system's accessible green and red and a
/// stronger track.
///
/// No accessibility element of its own: the moment is the island's value
/// (`AmbientActivity.accessibilityLabel`), set on the stack above it.
struct ChargingActivityView: View {
    let activity: AmbientActivity
    let level: Int
    let size: CGSize
    /// The notch's width, so the left wing's words know how far they may run.
    let notchWidth: CGFloat
    var reduceMotion: Bool
    var increaseContrast: Bool

    var body: some View {
        let scale = CompactIslandLayout.glyphScale(height: size.height)
        let port: ChargePort = {
            if case .charging(_, _, let port, _, _) = activity { return port }
            return .adapter
        }()
        HStack(spacing: 0) {
            // "61 W On Hold" and the Russian are wider than a 90 pt wing:
            // first the whole line at full size, then the status alone — the
            // news, at its shortest ("On Hold", not "Charging On Hold"); the
            // port is already the ring or the battery on the right — and then
            // that, shrunk. Shrinking the whole line hit
            // its floor and cut the word: "61 W Not Cha…" on the owner's
            // recording (2026-10-26 15:26).
            let status = activity.shortChargeStatus
            ViewThatFits(in: .horizontal) {
                ChargingWingText(source: activity.chargeSource, status: activity.chargeStatus)
                    .fixedSize()
                ChargingWingText(source: nil, status: status)
                    .fixedSize()
                ChargingWingText(source: nil, status: status)
                    .minimumScaleFactor(CompactIslandLayout.chargingTextMinimumScale)
            }
                .islandFont(CompactIslandLayout.chargingTextSize)
                .lineLimit(1)
                .frame(
                    maxWidth: CompactIslandLayout.chargingWingTextWidth(islandWidth: size.width, notchWidth: notchWidth),
                    alignment: .leading
                )
                .padding(.leading, CompactIslandLayout.chargingTextInset)
            Spacer(minLength: 0)
            Text(localized("%d%%", level))
                .font(.system(size: CompactIslandLayout.chargingTextSize).monospacedDigit())
                .tracking(Theme.tracking(forSize: CompactIslandLayout.chargingTextSize))
                .foregroundStyle(tone)
                .lineLimit(1)
                .fixedSize()
            Group {
                if port == .magSafe {
                    MagSafeRing(
                        level: level, fill: tone, track: trackColor, isCharging: isCharging,
                        scale: scale, reduceMotion: reduceMotion
                    )
                } else {
                    IslandBattery(level: level, fill: tone, track: trackColor, scale: scale)
                        .overlay(alignment: .leading) {
                            if isCharging { BatteryBolt(scale: scale) }
                        }
                }
            }
            .padding(.leading, CompactIslandLayout.levelToBatteryGap)
            .padding(.trailing, CompactIslandLayout.batteryTrailing - CompactIslandLayout.shoulder)
        }
        .frame(width: size.width, height: size.height)
    }

    private var isCharging: Bool { activity.chargeState == .charging }

    private var tone: AnyShapeStyle { Self.tone(for: activity, increaseContrast: increaseContrast) }
    private var trackColor: Color { Self.track(for: activity, increaseContrast: increaseContrast) }

    /// The tint as a colour: green, red, or white for none. Shared with the
    /// capsule under the open panel (`StripNoticeContent`), so the two never
    /// colour one charge differently.
    static func tintColor(for activity: AmbientActivity, increaseContrast: Bool) -> Color {
        switch activity.chargeTint {
        case .green?: return increaseContrast ? Theme.chargingGreenContrast : Theme.chargingGreen
        case .red?: return increaseContrast ? Theme.lowBatteryRedContrast : Theme.lowBatteryRed
        case nil: return Color.white
        }
    }

    /// The level's style: the tint's gradient, as §19.4 draws the green, or
    /// flat white.
    static func tone(for activity: AmbientActivity, increaseContrast: Bool) -> AnyShapeStyle {
        activity.chargeTint == nil
            ? AnyShapeStyle(Color.white)
            : AnyShapeStyle(tintColor(for: activity, increaseContrast: increaseContrast).gradient)
    }

    static func track(for activity: AmbientActivity, increaseContrast: Bool) -> Color {
        tintColor(for: activity, increaseContrast: increaseContrast).opacity(
            increaseContrast ? CompactIslandLayout.batteryTrackContrastOpacity : CompactIslandLayout.batteryTrackOpacity
        )
    }
}

/// The left wing's words as one line, so the source and the status shrink
/// together: the source at the wing's usual white, the status after it at the
/// secondary white, as a subtitle sits under a title. One `Text`, so one
/// baseline and one scale.
struct ChargingWingText: View {
    let source: String?
    let status: String?

    var body: some View {
        let primary = Color.white.opacity(CompactIslandLayout.chargingTextOpacity)
        let secondary = Color.white.opacity(CompactIslandLayout.chargingStatusOpacity)
        switch (source, status) {
        case let (source?, status?):
            // An attributed string rather than an interpolated `Text`: the
            // interpolation is a localization key ("%@ %@") the tables do not
            // carry, and `Text + Text` is deprecated on macOS 26. Both words
            // arrive localized already.
            Text(Self.joined(source: source, status: status, primary: primary, secondary: secondary))
        case let (source?, nil):
            Text(source).foregroundStyle(primary)
        case let (nil, status?):
            Text(status).foregroundStyle(primary)
        case (nil, nil):
            Text(localized("Charging")).foregroundStyle(primary)
        }
    }

    static func joined(source: String, status: String, primary: Color, secondary: Color) -> AttributedString {
        var lead = AttributedString(source + " ")
        lead.foregroundColor = primary
        var tail = AttributedString(status)
        tail.foregroundColor = secondary
        return lead + tail
    }
}

/// MagSafe's ring: a track all the way round and the level drawn over it
/// clockwise from twelve o'clock, round-capped, as the iPhone draws a MagSafe
/// charge. The bolt sits in the middle while it charges.
struct MagSafeRing: View {
    let level: Int
    let fill: AnyShapeStyle
    let track: Color
    let isCharging: Bool
    var scale: CGFloat = 1
    var reduceMotion: Bool

    /// What the ring shows, 0…1. Built at the level, so a still render (the
    /// visual lab, a snapshot) shows the charge; on screen `onAppear` empties
    /// it before the first frame and draws it round to the level, and a later
    /// reading moves it on the same curve.
    @State private var drawn: CGFloat

    init(level: Int, fill: AnyShapeStyle, track: Color, isCharging: Bool, scale: CGFloat = 1, reduceMotion: Bool) {
        self.level = level
        self.fill = fill
        self.track = track
        self.isCharging = isCharging
        self.scale = scale
        self.reduceMotion = reduceMotion
        _drawn = State(initialValue: MagSafeRing.fraction(level: level))
    }

    var body: some View {
        let diameter = CompactIslandLayout.magSafeRingDiameter * scale
        let line = CompactIslandLayout.magSafeRingLineWidth * scale
        ZStack {
            Circle()
                .stroke(track, lineWidth: line)
            Circle()
                .trim(from: 0, to: drawn)
                .stroke(fill, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if isCharging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: CompactIslandLayout.magSafeBoltSize * scale, weight: .bold))
                    .foregroundStyle(Color.white)
            }
        }
        .frame(width: diameter, height: diameter)
        .onAppear {
            guard !reduceMotion else { return }
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { drawn = 0 }
            DispatchQueue.main.async { draw() }
        }
        .onChange(of: level) { draw() }
        .accessibilityHidden(true)
    }

    private func draw() {
        withAnimation(Theme.pill(reduceMotion: reduceMotion)) { drawn = MagSafeRing.fraction(level: level) }
    }

    /// The share of the ring a level draws, never past either end.
    nonisolated static func fraction(level: Int) -> CGFloat {
        CGFloat(min(max(level, 0), 100)) / 100
    }
}

/// The menu bar's charging bolt over the drawn battery: white, knocked out of
/// the fill by a black outline so it reads over the level and the track alike.
struct BatteryBolt: View {
    var scale: CGFloat = 1

    var body: some View {
        let size = CompactIslandLayout.batteryBoltSize * scale
        let bodyWidth = CompactIslandLayout.batteryBodySize.width * scale
        ZStack {
            Image(systemName: "bolt.fill")
                .font(.system(size: size + 2 * scale, weight: .heavy))
                .foregroundStyle(Color.black)
            Image(systemName: "bolt.fill")
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(Color.white)
        }
        // Centred on the body, not on the body and cap together.
        .frame(width: bodyWidth)
        .accessibilityHidden(true)
    }
}

extension CompactIslandLayout {
    // MARK: Charging's two variants (spec §19.4, amended 2026-10-26)

    /// How far the left wing's words may shrink to fit it.
    static let chargingTextMinimumScale: CGFloat = 0.7

    /// The status after the source ("On Hold", "Charged"): the secondary
    /// white, so the port reads first.
    static let chargingStatusOpacity: Double = 0.55

    /// The left wing's room for words: from the inset to 4 pt short of the
    /// notch, so nothing runs under the camera.
    static func chargingWingTextWidth(islandWidth: CGFloat, notchWidth: CGFloat) -> CGFloat {
        max(0, (islandWidth - notchWidth) / 2 - chargingTextInset - 4)
    }

    /// MagSafe's ring: 18 across, a 3 pt line — the battery body's height and
    /// a little more, so ring and battery sit on the same line of the wing.
    static let magSafeRingDiameter: CGFloat = 18
    static let magSafeRingLineWidth: CGFloat = 3
    static let magSafeBoltSize: CGFloat = 8

    /// The bolt laid over the USB-C battery.
    static let batteryBoltSize: CGFloat = 10

    /// The track under Increase Contrast, which asks for defined edges.
    static let batteryTrackContrastOpacity: Double = 0.45
}
