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

/// The pop-up over the lock screen, in the pill's compact form
/// (`LockedHUDLayout`, spec §3.7 amended 2026-10-26): the symbol where the
/// charger's words start, the bar and the level ending where its battery
/// ends, nothing under the notch. Watches only the live level, as the shut
/// island's pop-up does.
struct LockedHUDContent: View {
    @ObservedObject var live: HUDLiveLevel
    let size: CGSize

    var body: some View {
        if let hud = live.moment {
            let fill = Color.white.opacity(hud.muted ? HUDLayout.mutedFillOpacity : HUDLayout.levelOpacity)
            HStack(spacing: 0) {
                Image(systemName: hud.symbol)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color.white)
                    .frame(width: LockedHUDLayout.symbolSize.width, height: LockedHUDLayout.symbolSize.height)
                    .padding(.leading, CompactIslandLayout.chargingTextInset)
                Spacer(minLength: 0)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: LockedHUDLayout.barHeight / 2, style: .continuous)
                        .fill(Color.white.opacity(HUDLayout.trackOpacity))
                    RoundedRectangle(cornerRadius: LockedHUDLayout.barHeight / 2, style: .continuous)
                        .fill(fill)
                        .frame(width: LockedHUDLayout.barWidth * CGFloat(hud.level))
                }
                .frame(width: LockedHUDLayout.barWidth, height: LockedHUDLayout.barHeight)
                Text(hud.percent, format: .number)
                    .font(.system(size: LockedHUDLayout.numberSize, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(HUDLayout.numberOpacity))
                    .lineLimit(1)
                    .frame(width: LockedHUDLayout.numberWidth, alignment: .trailing)
                    .padding(.leading, LockedHUDLayout.spacing)
                    .padding(.trailing, CompactIslandLayout.batteryTrailing - CompactIslandLayout.shoulder)
            }
            .frame(width: size.width, height: size.height)
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

/// The charger, headphones or a confirmation in the capsule under the open
/// panel (spec §19.5 d, amended 2026-10-26): the shut island's words for
/// each, on one line between the capsule's insets, in the capsule's black and
/// the island's line — tinted as the island tints that alert.
///
/// - Charging: the source and the status at the left, as the shut island's
///   left wing says them ("61 W On Hold"), the level and MagSafe's ring or
///   USB-C's battery at the right.
/// - Headphones: the device's symbol, its name, "Connected" after it, dimmer.
/// - A confirmation: its symbol and its words.
struct StripNoticeContent: View {
    let notice: StripNotice
    let width: CGFloat
    let increaseContrast: Bool

    var body: some View {
        row
            .font(.system(size: StripNoticeLayout.textSize))
            .tracking(Theme.tracking(forSize: StripNoticeLayout.textSize))
            .lineLimit(1)
            .padding(.leading, HUDStripLayout.leadingInset)
            .padding(.trailing, HUDStripLayout.trailingInset)
            .frame(width: width, height: HUDStripLayout.height)
            .background(Capsule(style: .continuous).fill(Color.black))
            .overlay(
                Capsule(style: .continuous).strokeBorder(
                    IslandStroke.color(
                        tint: IslandStroke.tint(for: notice.activity, isOpen: false),
                        increaseContrast: increaseContrast
                    ),
                    lineWidth: Theme.islandStrokeWidth
                )
            )
    }

    @ViewBuilder
    private var row: some View {
        switch notice {
        case .ambient(let ambient):
            switch ambient {
            case .charging(let level?, _, let port, _, _):
                HStack(spacing: HUDStripLayout.spacing) {
                    ChargingWingText(source: ambient.chargeSource, status: ambient.chargeStatus)
                        .minimumScaleFactor(CompactIslandLayout.chargingTextMinimumScale)
                    Spacer(minLength: 0)
                    Text(localized("%d%%", level))
                        .monospacedDigit()
                        .foregroundStyle(ChargingActivityView.tone(for: ambient, increaseContrast: increaseContrast))
                        .fixedSize()
                    let isCharging = ambient.chargeState == .charging
                    let fill = ChargingActivityView.tone(for: ambient, increaseContrast: increaseContrast)
                    let track = ChargingActivityView.track(for: ambient, increaseContrast: increaseContrast)
                    if port == .magSafe {
                        MagSafeRing(
                            level: level, fill: fill, track: track, isCharging: isCharging,
                            scale: StripNoticeLayout.glyphScale, reduceMotion: true
                        )
                    } else {
                        IslandBattery(level: level, fill: fill, track: track, scale: StripNoticeLayout.glyphScale)
                            .overlay(alignment: .leading) {
                                if isCharging { BatteryBolt(scale: StripNoticeLayout.glyphScale) }
                            }
                    }
                }
            case .charging:
                // No level: a Mac with no battery shows no Charging at all
                // (`showsOnIsland`), here as on the island.
                EmptyView()
            case .headphones(let name, let symbol):
                HStack(spacing: HUDStripLayout.spacing) {
                    Image(systemName: symbol)
                        .resizable()
                        .symbolRenderingMode(.hierarchical)
                        .scaledToFit()
                        .foregroundStyle(Color.white.opacity(HeadphonesAlertLayout.glyphOpacity))
                        .frame(width: StripNoticeLayout.symbolSize.width, height: StripNoticeLayout.symbolSize.height)
                    // The name gives way at its tail; "Connected" is always
                    // whole, because it is the news.
                    HStack(spacing: 4) {
                        Text(name)
                            .foregroundStyle(Color.white.opacity(CompactIslandLayout.chargingTextOpacity))
                            .truncationMode(.tail)
                        Text(localized("Connected"))
                            .foregroundStyle(Color.white.opacity(CompactIslandLayout.chargingStatusOpacity))
                            .fixedSize()
                    }
                }
                // Held to the leading edge by a frame, not a trailing
                // `Spacer`: the stack's 10 pt spacing stood before the spacer
                // even at no width, and in Russian, where "Подключено" is the
                // longer word, those 10 pt cut the name to "AirPods…" in a
                // capsule it fitted (`AlertCapsuleTests`, 2026-10-29).
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .confirmation(let confirmation):
            HStack(spacing: HUDStripLayout.spacing) {
                Image(systemName: confirmation.symbol)
                    .font(.system(size: StripNoticeLayout.textSize, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: StripNoticeLayout.symbolSize.width)
                Text(confirmation.title)
                    .foregroundStyle(Color.white.opacity(ConfirmationLayout.titleOpacity))
                Spacer(minLength: 0)
            }
        }
    }
}

/// The notices' measures inside the level's capsule (`HUDStripLayout`).
enum StripNoticeLayout {
    /// A point under the shut island's 14: the capsule is 32 tall, the
    /// island's wing the notch's height.
    static let textSize: CGFloat = 13
    /// The battery and MagSafe's ring at three quarters of the island's.
    static let glyphScale: CGFloat = 0.75
    static let symbolSize = HUDStripLayout.symbolSize
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
/// changed on arrival and fold only); while it is up, the outline it sits
/// under (`HUDStripPlaced`); and, in the capsule, the live level. A held key
/// redraws the capsule, not this.
struct HUDStripLayer: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject private var appearance = SystemAppearance.shared

    private var reduceMotion: Bool { appearance.reduceMotion }

    var body: some View {
        ZStack(alignment: .top) {
            if vm.hudStripShown || vm.stripNotice != nil {
                HUDStripPlaced(
                    vm: vm, travel: vm.pageTravel, pull: vm.pullStretch,
                    increaseContrast: appearance.increaseContrast, reduceMotion: reduceMotion
                )
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
        .animation(Theme.hud(reduceMotion: reduceMotion), value: vm.stripNotice)
    }

    /// The capsule under the outline as it is drawn this instant: the
    /// presented surface's body, or between two pages the mix the travel has
    /// reached (`drawnOpenBodySize`, what the shell draws the open island at),
    /// with the pull's give on its height as the outline takes it.
    ///
    /// Not `openBodySize`. While the pages travel that is every page the leg
    /// can reach, together — the clickable region, cut once per leg — and the
    /// capsule sat under the tallest of them: a dot from Clipboard to Music
    /// left it a hundred points under Music's outline, in the middle of the
    /// screen, until it folded (owner, 2026-10-26;
    /// `HUDStripPlacementTests`).
    static func capsuleFrame(for vm: NotchViewModel) -> CGRect {
        var body = vm.drawnOpenBodySize
        body.height = max(0, body.height + vm.pullStretch.points)
        return HUDStripLayout.frame(
            bodySize: body, bottomRadius: vm.openBottomRadius, windowSize: vm.geometry.windowSize
        )
    }
}

/// The capsule where the outline is: mounted only while it is up.
///
/// The outline moves on two things the view model does not publish — the
/// pages travelling (`PageTravel`) and the pull's give
/// (`IslandPullStretch`) — and a leg ends with no publish of the view model
/// at all. The layer used to watch the view model alone, so a capsule up
/// through a page turn kept the frame it was given mid-leg until it folded.
/// This view watches both, and exists only while the capsule does: with it
/// folded, the frames of a swipe re-run nothing of the layer, and with it
/// up they move it exactly as they move the outline — on the travel's still
/// transactions under the fingers, on the island's spring otherwise.
struct HUDStripPlaced: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var travel: PageTravel
    @ObservedObject var pull: IslandPullStretch
    let increaseContrast: Bool
    let reduceMotion: Bool

    /// How many times a body was asked for, for the test that a folded
    /// capsule watches nothing (`HUDStripPlacementTests`). Main-actor state a
    /// test reads; the app never does.
    static var bodies = 0

    var body: some View {
        Self.bodies &+= 1
        let frame = HUDStripLayer.capsuleFrame(for: vm)
        return Group {
            // The level first: it outranks everything else the capsule
            // carries, and the controller never leaves both up — this only
            // says which to draw if it ever did.
            if vm.hudStripShown {
                HUDStripContent(live: vm.hudLive, width: frame.width, increaseContrast: increaseContrast)
            } else if let notice = vm.stripNotice {
                StripNoticeContent(notice: notice, width: frame.width, increaseContrast: increaseContrast)
            }
        }
            .offset(y: frame.minY)
            // The body changing height under a standing capsule — a page
            // turned to a shorter one — moves it on the outline's own spring.
            // The travel's frames carry animations disabled, so under the
            // fingers it follows them one to one, as the outline does.
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
