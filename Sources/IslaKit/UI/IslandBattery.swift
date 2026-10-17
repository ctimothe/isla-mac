import SwiftUI

/// The battery the Charging activity draws in its right wing (spec §19.4): a
/// body 28 × 16 at radius 6 and a cap 2 × 6 at radius 1.5, 1.5 pt apart, both
/// a track in the tint at 0.30, the level filled across the body.
///
/// Drawn rather than `battery.100`, whose fill steps in quarters: the level is
/// what this activity exists to show, and 67 % should look like 67. `scale` is
/// `CompactIslandLayout.glyphScale`, three quarters on the 24 pt island.
struct IslandBattery: View {
    let level: Int
    /// The level's fill — the green gradient while charging, white while the
    /// battery only holds.
    let fill: AnyShapeStyle
    let track: Color
    var scale: CGFloat = 1

    var body: some View {
        let bodySize = CGSize(
            width: CompactIslandLayout.batteryBodySize.width * scale,
            height: CompactIslandLayout.batteryBodySize.height * scale
        )
        let bodyShape = RoundedRectangle(cornerRadius: CompactIslandLayout.batteryRadius * scale, style: .continuous)
        HStack(spacing: CompactIslandLayout.batteryCapGap * scale) {
            ZStack(alignment: .leading) {
                bodyShape.fill(track)
                Rectangle()
                    .fill(fill)
                    .frame(width: CompactIslandLayout.batteryFillWidth(level: level, bodyWidth: bodySize.width))
            }
            .frame(width: bodySize.width, height: bodySize.height)
            .clipShape(bodyShape)
            RoundedRectangle(cornerRadius: CompactIslandLayout.batteryCapRadius * scale, style: .continuous)
                .fill(track)
                .frame(
                    width: CompactIslandLayout.batteryCapSize.width * scale,
                    height: CompactIslandLayout.batteryCapSize.height * scale
                )
        }
        // The level is spoken in the island's own value; the drawing is not a
        // second element.
        .accessibilityHidden(true)
    }
}
