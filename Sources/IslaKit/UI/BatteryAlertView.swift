import SwiftUI

extension ExpandedAlertShape {
    /// Battery Low, 325.4 × 113, radii 22 / 40 (spec §19.5 a).
    static let batteryLow = ExpandedAlertShape(
        reference: CGSize(width: 325.4, height: 113), topRadius: 22, bottomRadius: 40
    )
    /// Full Battery, 305.5 × 108, radii 18 / 36 (spec §19.5 b).
    static let batteryFull = ExpandedAlertShape(
        reference: CGSize(width: 305.5, height: 108), topRadius: 18, bottomRadius: 36
    )
}

/// Where Battery Low's and Full Battery's parts sit (spec §19.5 a, b), from
/// the reference's shape-relative numbers. One table for both: the two
/// alerts are the same layout in two colours with the indicator drawn at two
/// sizes.
struct BatteryAlertLayout: Equatable {
    let shape: ExpandedAlertShape
    /// The text's left edge and the title's top, on the reference.
    let textOrigin: CGPoint
    /// The indicator capsule: its size, its right inset and its top.
    let indicatorSize: CGSize
    let indicatorRight: CGFloat
    let indicatorTop: CGFloat
    /// Inside the capsule, in its own coordinates.
    let body: CGRect
    let bodyRadius: CGFloat
    let cap: CGRect
    let level: CGRect
    let levelRadius: CGFloat
    let bodyOpacity: Double

    static let low = BatteryAlertLayout(
        shape: .batteryLow, textOrigin: CGPoint(x: 45, y: 47.4),
        indicatorSize: CGSize(width: 70, height: 40), indicatorRight: 44.8, indicatorTop: 50.4,
        body: CGRect(x: 9.6, y: 8.5, width: 40, height: 23), bodyRadius: 10,
        cap: CGRect(x: 52.1, y: 16.25, width: 2.5, height: 7.5),
        level: CGRect(x: 15.8, y: 13, width: 8, height: 14), levelRadius: 4, bodyOpacity: 0.45
    )
    static let full = BatteryAlertLayout(
        shape: .batteryFull, textOrigin: CGPoint(x: 40, y: 51.6),
        indicatorSize: CGSize(width: 75, height: 45), indicatorRight: 34.5, indicatorTop: 45.5,
        body: CGRect(x: 13, y: 10.5, width: 44, height: 24), bodyRadius: 10,
        cap: CGRect(x: 59, y: 18.5, width: 3, height: 8),
        level: CGRect(x: 18, y: 15.5, width: 34, height: 14), levelRadius: 4, bodyOpacity: 0.40
    )

    static let titleSize: CGFloat = 14
    static let titleOpacity: Double = 0.86
    static let levelTextSize: CGFloat = 13
    static let titleToLevel: CGFloat = 8
    static let detailSize: CGFloat = 11
    static let detailOpacity: Double = 0.45
    /// The capsule behind the battery, in the tint.
    static let capsuleOpacity: Double = 0.20
    /// The level's pulse (spec §19.3, "Living details"): 1 ↔ 0.3 on a 1 s
    /// ease-in-out repeat.
    static let pulseLow: Double = 0.3
    static let pulseDuration: Double = 1

    /// The title's baseline: its top on the reference plus the ascent of 14
    /// semibold, so the cap height lands where the board draws it.
    func titleBaseline(notchHeight: CGFloat) -> CGFloat {
        shape.y(textOrigin.y + 13, notchHeight: notchHeight)
    }

    /// The detail's first baseline, 3 pt under the title's line.
    func detailBaseline(notchHeight: CGFloat) -> CGFloat {
        titleBaseline(notchHeight: notchHeight) + 3 + Self.detailSize + 2
    }

    var textLeading: CGFloat { shape.x(textOrigin.x) }

    func indicatorFrame(islandWidth: CGFloat, notchHeight: CGFloat) -> CGRect {
        CGRect(
            x: islandWidth - shape.trailing(indicatorRight) - indicatorSize.width,
            y: shape.y(indicatorTop, notchHeight: notchHeight),
            width: indicatorSize.width, height: indicatorSize.height
        )
    }

    /// The text wraps before the indicator, 12 pt clear of it.
    func textWidth(islandWidth: CGFloat, notchHeight: CGFloat) -> CGFloat {
        max(0, indicatorFrame(islandWidth: islandWidth, notchHeight: notchHeight).minX - 12 - textLeading)
    }
}

/// Battery Low and Full Battery (spec §19.5 a, b): the title and the level in
/// the tint, a line of advice under them, and a drawn battery at right whose
/// level pulses. Under Reduce Motion the level stands still.
struct BatteryAlertView: View {
    let activity: AmbientActivity
    let size: CGSize
    let notchHeight: CGFloat
    let reduceMotion: Bool
    let increaseContrast: Bool

    @State private var dim = false

    private var isLow: Bool {
        if case .batteryLow = activity { return true }
        return false
    }

    private var layout: BatteryAlertLayout { isLow ? .low : .full }

    private var tint: Color {
        if isLow { return increaseContrast ? Theme.lowBatteryRedContrast : Theme.lowBatteryRed }
        return increaseContrast ? Theme.chargingGreenContrast : Theme.chargingGreen
    }

    private var level: Int {
        switch activity {
        case .batteryLow(let level, _), .batteryFull(let level): return level
        default: return 0
        }
    }

    /// The title, the advice: Apple's wording for each (§19.5 a, b).
    static func title(for activity: AmbientActivity) -> String {
        if case .batteryLow = activity { return localized("Battery Low") }
        return localized("Full Battery")
    }

    static func detail(for activity: AmbientActivity) -> String {
        switch activity {
        case .batteryLow(_, true): return localized("Connect a charger soon.")
        case .batteryLow: return localized("Connect a charger soon, or turn on Low Power Mode.")
        default: return localized("You can unplug the charger.")
        }
    }

    var body: some View {
        let indicator = layout.indicatorFrame(islandWidth: size.width, notchHeight: notchHeight)
        let textWidth = layout.textWidth(islandWidth: size.width, notchHeight: notchHeight)
        ZStack(alignment: .topLeading) {
            HStack(alignment: .firstTextBaseline, spacing: BatteryAlertLayout.titleToLevel) {
                Text(Self.title(for: activity))
                    .islandFont(BatteryAlertLayout.titleSize, weight: .semibold)
                    .foregroundStyle(Color.white.opacity(BatteryAlertLayout.titleOpacity))
                Text(localized("%d%%", level))
                    .islandFont(BatteryAlertLayout.levelTextSize)
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }
            .lineLimit(1)
            .frame(width: textWidth, alignment: .leading)
            .islandBaseline(layout.titleBaseline(notchHeight: notchHeight))
            .offset(x: layout.textLeading)
            Text(Self.detail(for: activity))
                .islandFont(BatteryAlertLayout.detailSize, weight: .medium)
                .foregroundStyle(Color.white.opacity(BatteryAlertLayout.detailOpacity))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: textWidth, alignment: .leading)
                .islandBaseline(layout.detailBaseline(notchHeight: notchHeight))
                .offset(x: layout.textLeading)
            batteryIndicator
                .frame(width: indicator.width, height: indicator.height)
                .offset(x: indicator.minX, y: indicator.minY)
                .accessibilityHidden(true)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(activity.accessibilityLabel)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: BatteryAlertLayout.pulseDuration).repeatForever(autoreverses: true)) {
                dim = true
            }
        }
    }

    private var batteryIndicator: some View {
        let layout = self.layout
        return ZStack(alignment: .topLeading) {
            Capsule().fill(tint.opacity(BatteryAlertLayout.capsuleOpacity))
            RoundedRectangle(cornerRadius: layout.bodyRadius, style: .continuous)
                .fill(tint.opacity(layout.bodyOpacity))
                .frame(width: layout.body.width, height: layout.body.height)
                .offset(x: layout.body.minX, y: layout.body.minY)
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(tint.opacity(layout.bodyOpacity))
                .frame(width: layout.cap.width, height: layout.cap.height)
                .offset(x: layout.cap.minX, y: layout.cap.minY)
            RoundedRectangle(cornerRadius: layout.levelRadius, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(0.82), tint], startPoint: .leading, endPoint: .trailing))
                .frame(width: layout.level.width, height: layout.level.height)
                .offset(x: layout.level.minX, y: layout.level.minY)
                .opacity(dim ? BatteryAlertLayout.pulseLow : 1)
        }
    }
}
