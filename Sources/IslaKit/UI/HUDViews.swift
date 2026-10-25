import AppKit
import SwiftUI

/// The volume or brightness pop-up on the shut island (spec §19.5 d), an
/// expanded alert: the output's name — or which brightness — over a row of
/// the symbol, the bar and the level as a number. The level is a plain light
/// fill on a dim track; muted, white 0.32 at the level it will return to.
///
/// A view of its own, observing only the live level (`HUDLiveLevel`), so a
/// press redraws this and nothing else. It used to be a method of
/// `NotchContentView`, whose body re-ran in full on every press of a held key.
/// The bar is at each press's level at once, with no curve (`Theme.hud`'s
/// note on why).
struct HUDPillContent: View {
    @ObservedObject var live: HUDLiveLevel
    let size: CGSize
    let notchHeight: CGFloat

    var body: some View {
        if let hud = live.moment {
            let track = HUDLayout.trackFrame(islandWidth: size.width, notchHeight: notchHeight)
            let symbol = HUDLayout.symbolFrame(notchHeight: notchHeight)
            let fill = Color.white.opacity(hud.muted ? HUDLayout.mutedFillOpacity : HUDLayout.levelOpacity)
            ZStack(alignment: .topLeading) {
                Text(hud.title)
                    .islandFont(HUDLayout.titleSize)
                    .foregroundStyle(Color.white.opacity(HUDLayout.titleOpacity))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: HUDLayout.titleWidth(islandWidth: size.width), alignment: .leading)
                    .islandBaseline(HUDLayout.titleBaseline(notchHeight: notchHeight))
                    .offset(x: HUDLayout.titleLeading)
                Image(systemName: hud.symbol)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color.white)
                    .frame(width: symbol.width, height: symbol.height)
                    .offset(x: symbol.minX, y: symbol.minY)
                RoundedRectangle(cornerRadius: HUDLayout.barRadius, style: .continuous)
                    .fill(Color.white.opacity(HUDLayout.trackOpacity))
                    .frame(width: track.width, height: track.height)
                    .offset(x: track.minX, y: track.minY)
                RoundedRectangle(cornerRadius: HUDLayout.barRadius, style: .continuous)
                    .fill(fill)
                    .frame(width: track.width * CGFloat(hud.level), height: track.height)
                    .offset(x: track.minX, y: track.minY)
                // Centred on the bar, its right edge on the reference's 34.5.
                // A cut, not a roll: the system's own pop-up has no digits to
                // animate, and a text transition re-lays the number out on
                // every frame of a held key.
                Text(hud.percent, format: .number)
                    .font(.system(size: HUDLayout.numberSize, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(HUDLayout.numberOpacity))
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: max(0, size.width - HUDLayout.numberTrailingInset), height: track.height,
                           alignment: .trailing)
                    .offset(y: track.minY)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            // No element of its own: like the other moments, the pop-up is the
            // island's value (`closedIslandValue`), set on the stack above it.
        }
    }
}

/// What the capsule under the open panel draws: the symbol, the bar and the
/// percent in one row, no title (the glyph says what it is, and the line was
/// only ever there because the shut pop-up has the height for it).
struct HUDStripContent: View {
    @ObservedObject var live: HUDLiveLevel
    let width: CGFloat
    let increaseContrast: Bool

    var body: some View {
        if let hud = live.moment {
            let fill = Color.white.opacity(hud.muted ? HUDLayout.mutedFillOpacity : HUDLayout.levelOpacity)
            HStack(spacing: HUDStripLayout.spacing) {
                Image(systemName: hud.symbol)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color.white)
                    .frame(width: HUDStripLayout.symbolSize.width, height: HUDStripLayout.symbolSize.height)
                // The track is a flexible well and the fill its left
                // `level × width`, stepping with each press like the pill's.
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: HUDStripLayout.barRadius, style: .continuous)
                            .fill(Color.white.opacity(HUDLayout.trackOpacity))
                        RoundedRectangle(cornerRadius: HUDStripLayout.barRadius, style: .continuous)
                            .fill(fill)
                            .frame(width: proxy.size.width * CGFloat(hud.level))
                            }
                    .frame(height: HUDStripLayout.barHeight)
                    .frame(maxHeight: .infinity)
                }
                Text(hud.percent, format: .number)
                    .font(.system(size: HUDStripLayout.numberSize, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(HUDLayout.numberOpacity))
                    .lineLimit(1)
                    .frame(width: HUDStripLayout.numberWidth, alignment: .trailing)
            }
            .padding(.leading, HUDStripLayout.leadingInset)
            .padding(.trailing, HUDStripLayout.trailingInset)
            .frame(width: width, height: HUDStripLayout.height)
            .background(Capsule(style: .continuous).fill(Color.black))
            // The island's own line, drawn inside the 32 points so the
            // capsule's outer size is exactly what the window arithmetic
            // (`HUDStripLayout.fits`) counts.
            .overlay(
                Capsule(style: .continuous).strokeBorder(
                    IslandStroke.color(tint: nil, increaseContrast: increaseContrast),
                    lineWidth: Theme.islandStrokeWidth
                )
            )
        }
    }
}

/// The level indicator under the open panel, as a layer of its own (spec §19.5
/// d, amended 2026-10-25).
///
/// A layer of its own for the bubble's reason (`IslandBubbleLayer`): the
/// island's content is cut by the outline's mask, and the capsule lives outside
/// the outline. It is window-sized, empty but for the capsule, and takes no
/// click at all — `IslandHUDStripHostingView.hitTest` — so it needs no entry in
/// `NotchRootView.activeRect` and the panel's hit region, the pointer sampler
/// and the collapse check never see it.
///
/// What it watches is small on purpose: whether it is up (`hudStripShown`,
/// changed on arrival and fold only), the body it sits under, and — in the
/// capsule — the live level. A held key redraws the capsule, not this.
struct HUDStripLayer: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject private var appearance = SystemAppearance.shared

    private var reduceMotion: Bool { appearance.reduceMotion }

    var body: some View {
        let frame = HUDStripLayout.frame(
            bodySize: vm.openBodySize, bottomRadius: vm.openBottomRadius, windowSize: vm.geometry.windowSize
        )
        ZStack(alignment: .top) {
            if vm.hudStripShown {
                HUDStripContent(
                    live: vm.hudLive, width: frame.width, increaseContrast: appearance.increaseContrast
                )
                .offset(y: frame.minY)
                .transition(Theme.hudStripArrival(reduceMotion: reduceMotion))
                // VoiceOver hears the level once, 250 ms after the last press
                // (`NotchController.presentHUD`, announced whether or not
                // anything is drawn); a second element here would read it
                // twice.
                .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(Theme.hud(reduceMotion: reduceMotion), value: vm.hudStripShown)
        // The body changing height under a standing capsule — a page turned
        // to a shorter one — moves it on the outline's own spring.
        .animation(Theme.island(reduceMotion: reduceMotion), value: frame.minY)
    }
}

/// The capsule's hosting view: a whole-window transparent layer that answers
/// nothing. A hosting view claims every point in its bounds; this one sits
/// above the island's, and the capsule is click-through like the window round
/// it.
final class IslandHUDStripHostingView: NSHostingView<HUDStripLayer> {
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
