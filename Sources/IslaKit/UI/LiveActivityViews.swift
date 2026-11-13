import AppKit
import SwiftUI

/// Sizes and colours of the new live activities (plan
/// `2026-11-14-islandcn-activities`). Pure, so the arithmetic has tests.
enum LiveActivityLayout {
    /// The system orange the iPhone draws its timer in (`#FF9F0A`).
    static let timerOrange = Color(red: 1, green: 159.0 / 255, blue: 10.0 / 255)
    /// The system blue, for a download.
    static let downloadBlue = Color(red: 10.0 / 255, green: 132.0 / 255, blue: 1)
    /// The privacy indicators' own colours: orange for the microphone, green
    /// for a camera, as macOS's menu-bar dots.
    static let microphoneOrange = timerOrange
    static let cameraGreen = Theme.chargingGreen

    /// Width beyond the notch, split between the two wings. A timer's time
    /// sits in the right wing and needs "12:34" (100) or "1:02:03" (140);
    /// a recording's app icon and a download's ring need the Shelf's 75.
    static func extensionWidth(_ live: LiveActivity) -> CGFloat {
        switch live {
        case .timer(let state):
            if case .countdown(let duration) = state.kind, duration >= 3600 { return 140 }
            return 100
        // A stopwatch has no end to size for, and passes an hour unannounced.
        case .stopwatch: return 140
        case .recording, .downloads: return NotchMetrics.compactShelfExtension
        }
    }

    /// The timer's or stopwatch's controls (the iPhone's expanded timer): a
    /// 335.4 × 120 card, the update alert's radii.
    static let controlsShape = ExpandedAlertShape(
        reference: CGSize(width: 335.4, height: 120), topRadius: 24, bottomRadius: 36
    )
    /// Timer Done, the Full Battery card's size.
    static let doneShape = ExpandedAlertShape.batteryFull

    static func bodySize(_ live: LiveActivity, expanded: Bool, notchSize: CGSize, bodyWidth: CGFloat) -> CGSize {
        if expanded, live.isTimer { return controlsShape.bodySize(notchSize: notchSize, bodyWidth: bodyWidth) }
        return CGSize(width: min(notchSize.width + extensionWidth(live), bodyWidth), height: notchSize.height)
    }

    /// The bubble beside the island, for any activity but the Shelf (which
    /// keeps its own, `IslandBubbleLayout`): islandcn's detached capsule,
    /// 62.18 wide whatever it holds.
    static let bubbleWidth: CGFloat = 62

    static let wingInset: CGFloat = 14
    static let glyphSize: CGFloat = 17
    static let timeSize: CGFloat = 15
}

/// A live activity's compact form: what it is in the left wing, its value in
/// the right one, never anything under the camera.
struct LiveCompactHeader: View {
    let live: LiveActivity
    let size: CGSize
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: 0) {
            LiveGlyph(live: live)
                .padding(.leading, LiveActivityLayout.wingInset)
            Spacer(minLength: 0)
            LiveValue(live: live, compact: true, reduceMotion: reduceMotion)
                .padding(.trailing, LiveActivityLayout.wingInset)
        }
        .frame(width: size.width, height: size.height)
    }
}

/// The activity's symbol in its colour.
struct LiveGlyph: View {
    let live: LiveActivity
    var size: CGFloat = LiveActivityLayout.glyphSize

    var body: some View {
        Image(systemName: Self.symbol(for: live))
            .font(.system(size: size, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(Self.tint(for: live))
            .frame(height: size + 2)
    }

    static func symbol(for live: LiveActivity) -> String {
        switch live {
        case .timer: return "timer"
        case .stopwatch: return "stopwatch.fill"
        case .recording(let state): return state.microphoneApps.isEmpty ? "video.fill" : "mic.fill"
        case .downloads: return "arrow.down.circle.fill"
        }
    }

    static func tint(for live: LiveActivity) -> Color {
        switch live {
        case .timer, .stopwatch: return LiveActivityLayout.timerOrange
        case .recording(let state):
            return state.microphoneApps.isEmpty ? LiveActivityLayout.cameraGreen : LiveActivityLayout.microphoneOrange
        case .downloads: return LiveActivityLayout.downloadBlue
        }
    }
}

/// The right wing: the time, the app, the ring.
struct LiveValue: View {
    let live: LiveActivity
    var compact = true
    let reduceMotion: Bool

    var body: some View {
        switch live {
        case .timer(let state), .stopwatch(let state):
            TimerText(state: state, size: compact ? LiveActivityLayout.timeSize : 12)
        case .recording(let state):
            if let app = state.microphoneApps.first,
               let icon = AppIcons.shared.icon(LiveActivityHub.owningApp(of: app)) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 20, height: 20)
            } else {
                // A camera alone does not say whose it is.
                Circle()
                    .fill(LiveGlyph.tint(for: live))
                    .frame(width: 8, height: 8)
            }
        case .downloads(let items):
            IslandProgressRing(fraction: items.first?.fraction, tint: LiveActivityLayout.downloadBlue,
                               reduceMotion: reduceMotion)
                .frame(width: 18, height: 18)
        }
    }
}

/// A countdown's time left or a stopwatch's time gone, redrawn once a second
/// while it runs and not at all while it is paused. The digits turn over in
/// place (`numericText`), the iPhone's motion for a changing number, and the
/// paused time dims rather than blinking.
struct TimerText: View {
    let state: IslandTimerState
    let size: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: state.isPaused ? 3600 : 1)) { context in
            let seconds = state.remaining(at: context.date) ?? state.elapsed(at: context.date)
            let isCountdown = state.remaining(at: context.date) != nil
            Text(IslandTimerCenter.format(seconds, roundingUp: isCountdown))
                .font(.system(size: size, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(LiveActivityLayout.timerOrange.opacity(state.isPaused ? 0.6 : 1))
                .contentTransition(.numericText(countsDown: isCountdown))
                .animation(.snappy(duration: 0.25), value: Int(seconds))
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// A ring that springs to a new value (islandcn's `IslandProgress`, response
/// 0.97, damping 0.74, fitted to the iPhone's progress bars). With no value
/// it turns slowly as an arc, which Reduce Motion stills.
struct IslandProgressRing: View {
    let fraction: Double?
    let tint: Color
    let reduceMotion: Bool
    var lineWidth: CGFloat = 3

    static let spring = Animation.spring(response: 0.97, dampingFraction: 0.74)

    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.22), lineWidth: lineWidth)
            if let fraction {
                Circle()
                    .trim(from: 0, to: max(0.02, min(1, fraction)))
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? Theme.reducedMotion : Self.spring, value: fraction)
            } else {
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 270 : -90))
                    .onAppear {
                        guard !reduceMotion else { return }
                        withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { spin = true }
                    }
            }
        }
        .accessibilityHidden(true)
    }
}

/// The second live activity's minimal form, in the bubble beside the island.
struct LiveBubbleContent: View {
    let activity: IslandActivity
    let reduceMotion: Bool

    var body: some View {
        switch activity {
        case .live(let live):
            HStack(spacing: 4) {
                LiveGlyph(live: live, size: 12)
                if live.isTimer { LiveValue(live: live, compact: false, reduceMotion: reduceMotion) }
            }
        case .music:
            Image(systemName: "waveform")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.white)
        default:
            EmptyView()
        }
    }
}

/// The timer's or stopwatch's controls, the iPhone's expanded timer: the
/// kind and the time large at left, Pause or Resume and Cancel or Reset as
/// round buttons at right. A click anywhere else folds it.
struct TimerControlsView: View {
    let live: LiveActivity
    let size: CGSize
    let notchHeight: CGFloat
    let increaseContrast: Bool
    let onAction: (TimerControl) -> Void

    private var state: IslandTimerState? {
        switch live {
        case .timer(let state), .stopwatch(let state): return state
        case .recording, .downloads: return nil
        }
    }

    private var isTimer: Bool {
        if case .timer = live { return true }
        return false
    }

    var body: some View {
        let shape = LiveActivityLayout.controlsShape
        HStack(alignment: .center, spacing: 12) {
            LiveGlyph(live: live, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(isTimer ? localized("Timer") : localized("Stopwatch"))
                    .islandFont(13, weight: .medium)
                    .foregroundStyle(Color.white.opacity(0.55))
                if let state { TimerText(state: state, size: 28) }
            }
            Spacer(minLength: 8)
            if let state {
                roundButton(
                    symbol: state.isPaused ? "play.fill" : "pause.fill",
                    label: state.isPaused ? localized("Resume") : localized("Pause"),
                    fill: LiveActivityLayout.timerOrange
                ) { onAction(state.isPaused ? .resume : .pause) }
                roundButton(
                    symbol: isTimer ? "xmark" : "arrow.counterclockwise",
                    label: isTimer ? localized("Cancel Timer") : localized("Reset Stopwatch"),
                    fill: Color.white
                ) { onAction(isTimer ? .cancel : .reset) }
            }
        }
        .padding(.horizontal, shape.x(40))
        .padding(.top, notchHeight + 6)
        .padding(.bottom, 14)
        .frame(width: size.width, height: size.height, alignment: .top)
    }

    private func roundButton(symbol: String, label: String, fill: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .bold))
        }
        .buttonStyle(RoundControlStyle(fill: fill, increaseContrast: increaseContrast))
        .accessibilityLabel(label)
    }
}

/// What a timer's control asks for.
enum TimerControl: Equatable {
    case pause, resume, cancel, reset
}

/// A 44 pt circle in its colour at 0.25, its symbol in the colour; pressed,
/// the circle deepens, as the update alert's capsules do.
private struct RoundControlStyle: ButtonStyle {
    let fill: Color
    let increaseContrast: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(fill)
            .frame(width: 44, height: 44)
            .background(fill.opacity(0.25 * (configuration.isPressed ? 1.6 : 1)), in: Circle())
            .overlay {
                if increaseContrast { Circle().strokeBorder(fill.opacity(0.6), lineWidth: 1) }
            }
            .contentShape(Circle())
            .animation(Theme.contentAnimation, value: configuration.isPressed)
    }
}

/// Timer Done: the timer glyph, "Timer" over "Done", and how long it ran.
struct TimerDoneView: View {
    let duration: TimeInterval
    let size: CGSize
    let notchHeight: CGFloat

    var body: some View {
        let shape = LiveActivityLayout.doneShape
        HStack(spacing: 12) {
            Image(systemName: "timer")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(LiveActivityLayout.timerOrange)
            VStack(alignment: .leading, spacing: 2) {
                Text(localized("Timer"))
                    .islandFont(14, weight: .semibold)
                    .foregroundStyle(Color.white.opacity(0.86))
                Text(localized("Done"))
                    .islandFont(11, weight: .medium)
                    .foregroundStyle(Color.white.opacity(0.45))
            }
            Spacer(minLength: 8)
            Text(IslandTimerCenter.format(duration, roundingUp: true))
                .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(LiveActivityLayout.timerOrange)
        }
        .padding(.horizontal, shape.x(40))
        .padding(.top, notchHeight + 4)
        .frame(width: size.width, height: size.height, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(localized("Timer done"))
    }
}
