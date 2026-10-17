import AppKit
import SwiftUI

/// What the compact island's equalizer draws (spec §19.4, §3.2).
enum CompactEqualizerMotion {
    /// At rest, paused: six bars 3 pt tall. The open header's bars stop
    /// mid-beat — the music stopping on a bar is what that equalizer
    /// describes — but on the island the spec wants a settled shape: a pause is
    /// a state, and the island's only colour, the tint, goes with it.
    static let restingHeights: [CGFloat] = [3, 3, 3, 3, 3, 3]
    /// The playing frame, which is also what Reduce Motion draws while music
    /// plays: still, but not the paused shape, so the island says "playing"
    /// without anything moving.
    static let playingHeights: [CGFloat] = [7, 13, 9, 16, 11, 14]
    /// The beat swings each bar between these, out of phase. No two bars share
    /// a period, so the six never line up into a wave that repeats.
    static let lowHeights: [CGFloat] = [4, 7, 5, 8, 6, 5]
    static let highHeights: [CGFloat] = [14, 18, 12, 17, 15, 13]
    static let durations: [CFTimeInterval] = [0.48, 0.37, 0.43, 0.41, 0.46, 0.39]

    /// The heights drawn without motion: paused, or playing under Reduce
    /// Motion.
    static func stillHeights(isPlaying: Bool) -> [CGFloat] {
        isPlaying ? playingHeights : restingHeights
    }

    /// A bar's two ends, top and bottom.
    struct BarColors: Equatable {
        var top: NSColor
        var bottom: NSColor
    }

    /// The share of white mixed into a tint's top end: spec §19.2's gradient,
    /// "the colour, 16 % lighter at the top".
    static let gradientLift: CGFloat = 0.16

    /// The tint as a gradient while playing (spec §19.4); white at the
    /// contrast-held tertiary, flat, while paused, so the bars at rest are as
    /// quiet as the tertiary text beside them.
    static func colors(isPlaying: Bool, tint: NSColor, increaseContrast: Bool) -> BarColors {
        guard isPlaying else {
            let rest = NSColor.white.withAlphaComponent(Theme.tertiaryOpacity(increaseContrast: increaseContrast))
            return BarColors(top: rest, bottom: rest)
        }
        return BarColors(top: lifted(tint), bottom: tint)
    }

    /// `color` with `gradientLift` of white mixed in, in sRGB, alpha kept.
    static func lifted(_ color: NSColor) -> NSColor {
        guard let c = color.usingColorSpace(.sRGB) else { return color }
        let lift = { (component: CGFloat) in component + (1 - component) * gradientLift }
        return NSColor(
            srgbRed: lift(c.redComponent), green: lift(c.greenComponent), blue: lift(c.blueComponent),
            alpha: c.alphaComponent
        )
    }
}

/// Six bars, 2.2 wide across 18 pt, on the compact island's right wing (spec
/// §19.4): in the cover's tint as a gradient while they move, in tertiary and
/// 3 pt tall at rest.
///
/// Core Animation again, for the header's reason: the beat runs in the render
/// server rather than re-evaluating a SwiftUI timeline on the main thread for
/// as long as music plays. Bars animate their *height*, not a scale transform,
/// so the rounded ends stay round at every height instead of being squashed
/// flat at 3 pt. Pausing removes the beat and settles the bars to rest over a
/// tenth of a second; playing starts it again from the low.
struct CompactEqualizer: View {
    var isAnimating: Bool
    var colors: CompactEqualizerMotion.BarColors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    var body: some View {
        if reduceMotion {
            HStack(spacing: CompactIslandLayout.equalizerBarSpacing) {
                ForEach(0..<CompactIslandLayout.equalizerBarCount, id: \.self) { index in
                    Capsule()
                        .fill(LinearGradient(
                            colors: [Color(nsColor: colors.top), Color(nsColor: colors.bottom)],
                            startPoint: .top, endPoint: .bottom
                        ))
                        .frame(
                            width: CompactIslandLayout.equalizerBarWidth,
                            height: CompactEqualizerMotion.stillHeights(isPlaying: isAnimating)[index]
                        )
                }
            }
            .frame(width: CompactIslandLayout.equalizerSide, height: CompactIslandLayout.equalizerSide)
        } else {
            CompactEqualizerLayers(colors: colors, isRunning: isAnimating)
                .frame(width: CompactIslandLayout.equalizerSide, height: CompactIslandLayout.equalizerSide)
        }
    }
}

private struct CompactEqualizerLayers: NSViewRepresentable {
    let colors: CompactEqualizerMotion.BarColors
    let isRunning: Bool

    func makeNSView(context: Context) -> CompactEqualizerLayerView {
        let view = CompactEqualizerLayerView()
        view.setColors(colors)
        view.setRunning(isRunning)
        return view
    }

    func updateNSView(_ nsView: CompactEqualizerLayerView, context: Context) {
        nsView.setColors(colors)
        nsView.setRunning(isRunning)
    }

    static func dismantleNSView(_ nsView: CompactEqualizerLayerView, coordinator: Void) {
        nsView.stopAnimating()
    }
}

private final class CompactEqualizerLayerView: NSView {
    /// Gradient layers, so each bar carries the tint's lift at its top; the
    /// gradient is stretched over the bar's own height as it beats, which is
    /// what a fill in SwiftUI does too.
    private let bars = (0..<CompactIslandLayout.equalizerBarCount).map { _ in CAGradientLayer() }
    private var isRunning = false

    private var box: CGFloat { CompactIslandLayout.equalizerSide }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        for (index, bar) in bars.enumerated() {
            // The view's layer is not flipped, so y 0 is the bar's bottom.
            bar.startPoint = CGPoint(x: 0.5, y: 0)
            bar.endPoint = CGPoint(x: 0.5, y: 1)
            bar.cornerRadius = CompactIslandLayout.equalizerBarWidth / 2
            bar.bounds = CGRect(
                x: 0, y: 0, width: CompactIslandLayout.equalizerBarWidth,
                height: CompactEqualizerMotion.restingHeights[index]
            )
            layer?.addSublayer(bar)
        }
    }

    convenience init() {
        self.init(frame: CGRect(
            x: 0, y: 0, width: CompactIslandLayout.equalizerSide, height: CompactIslandLayout.equalizerSide
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: CompactIslandLayout.equalizerSide, height: CompactIslandLayout.equalizerSide)
    }

    /// Centred vertically on the box, so a bar grows both ways from the cover's
    /// own centre line.
    override func layout() {
        super.layout()
        let step = CompactIslandLayout.equalizerBarWidth + CompactIslandLayout.equalizerBarSpacing
        for (index, bar) in bars.enumerated() {
            bar.position = CGPoint(
                x: CompactIslandLayout.equalizerBarWidth / 2 + CGFloat(index) * step,
                y: box / 2
            )
        }
    }

    func setColors(_ colors: CompactEqualizerMotion.BarColors) {
        // Without an implicit animation: the tint arrives with the cover, and a
        // bar easing from white to coral a moment after the cover has landed
        // reads as a delay rather than as a fade.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bars.forEach { $0.colors = [colors.bottom.cgColor, colors.top.cgColor] }
        CATransaction.commit()
    }

    func setRunning(_ running: Bool) {
        guard running != isRunning else { return }
        isRunning = running
        running ? startBeat() : settleToRest()
    }

    func stopAnimating() {
        bars.forEach { $0.removeAllAnimations() }
    }

    /// The model value, with no implicit animation of its own: the explicit
    /// ones below are the only motion, or a bar would be moved twice.
    private func setHeight(_ height: CGFloat, of bar: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bar.bounds.size.height = height
        CATransaction.commit()
    }

    private func startBeat() {
        let start = CACurrentMediaTime()
        for (index, bar) in bars.enumerated() {
            bar.removeAllAnimations()
            let low = CompactEqualizerMotion.lowHeights[index]
            let high = CompactEqualizerMotion.highHeights[index]
            setHeight(low, of: bar)
            let beat = CABasicAnimation(keyPath: "bounds.size.height")
            beat.fromValue = low
            beat.toValue = high
            beat.duration = CompactEqualizerMotion.durations[index]
            beat.beginTime = start + Double(index) * 0.08
            beat.autoreverses = true
            beat.repeatCount = .infinity
            beat.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            beat.isRemovedOnCompletion = false
            bar.add(beat, forKey: "beat")
        }
    }

    /// From wherever the bar is mid-beat to its resting 3 pt, on a short
    /// ease, so a pause is a settling rather than a cut.
    private func settleToRest() {
        for (index, bar) in bars.enumerated() {
            let current = bar.presentation()?.bounds.size.height ?? bar.bounds.size.height
            bar.removeAllAnimations()
            let rest = CompactEqualizerMotion.restingHeights[index]
            setHeight(rest, of: bar)
            let settle = CABasicAnimation(keyPath: "bounds.size.height")
            settle.fromValue = current
            settle.toValue = rest
            settle.duration = 0.12
            settle.timingFunction = CAMediaTimingFunction(name: .easeOut)
            bar.add(settle, forKey: "settle")
        }
    }
}
