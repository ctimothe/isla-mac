import AppKit
import QuartzCore
import SwiftUI

/// Placeholder shown while artwork is on its way. The system publishes the new
/// title before it has fetched the new cover, so without this the panel would
/// sit on an empty grey square for a moment on every track change.
struct SkeletonBox: View {
    var cornerRadius: CGFloat = 14
    @State private var sweep = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Theme.surface)
                .overlay(
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.10), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.55)
                    .offset(x: sweep ? geo.size.width : -geo.size.width * 0.55)
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .onAppear {
            // A shimmer that repeats forever is exactly the kind of motion
            // Reduce Motion is asked to stop; the plain surface still reads
            // as a placeholder.
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) {
                sweep = true
            }
        }
    }
}

/// Chooses between a static SwiftUI frame and a separately-owned Core Animation
/// view. The animated branch is structurally removed on pause, which destroys
/// its repeating animations instead of asking them to reverse or settle.
enum EqualizerPresentation: Equatable {
    case resting
    case animated

    init(isPlaying: Bool, reduceMotion: Bool) {
        self = isPlaying && !reduceMotion ? .animated : .resting
    }
}

enum EqualizerMotion {
    static let restingHeights: [CGFloat] = [4, 7, 5]
}

/// Three bars used in both the open header and compact activity.
///
/// Pausing holds the beat exactly where it stood rather than snapping the bars
/// back to their resting heights: the music stopping mid-bar is the thing being
/// described, and a jump to a tidy resting shape reads as a separate event that
/// did not happen. Reduce Motion still gets the plain, never-animated frame.
struct EqualizerBars: View {
    var isAnimating: Bool
    var opacity: CGFloat = 0.32
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    var body: some View {
        if reduceMotion {
            StaticEqualizerBars(opacity: opacity)
        } else {
            // One view across the whole play/pause cycle, not two swapped at
            // the transition: freezing in place requires the layers that are
            // mid-animation to survive the pause. Same fixed box as the
            // resting branch — a representable with no frame stretches to the
            // proposal, and the layer view pins its bars to the bottom of
            // whatever it is given.
            CoreAnimationEqualizerBars(
                opacity: opacity,
                isRunning: EqualizerPresentation(
                    isPlaying: isAnimating,
                    reduceMotion: reduceMotion
                ) == .animated
            )
            .frame(width: 10, height: 10)
        }
    }
}

private struct StaticEqualizerBars: View {
    let opacity: CGFloat

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<EqualizerMotion.restingHeights.count, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(opacity))
                    .frame(width: 2, height: EqualizerMotion.restingHeights[index])
            }
        }
        .frame(width: 10, height: 10, alignment: .bottom)
    }
}

/// `CABasicAnimation` runs in the render server rather than reevaluating a
/// SwiftUI timeline on the app's main thread. Pausing stops the layer's clock,
/// which costs the render server nothing further while it is stopped.
private struct CoreAnimationEqualizerBars: NSViewRepresentable {
    let opacity: CGFloat
    let isRunning: Bool

    func makeNSView(context: Context) -> EqualizerLayerView {
        let view = EqualizerLayerView()
        view.setOpacity(opacity)
        view.setRunning(isRunning)
        return view
    }

    func updateNSView(_ nsView: EqualizerLayerView, context: Context) {
        nsView.setOpacity(opacity)
        nsView.setRunning(isRunning)
    }

    static func dismantleNSView(_ nsView: EqualizerLayerView, coordinator: Void) {
        nsView.stopAnimating()
    }
}

private final class EqualizerLayerView: NSView {
    private let bars = (0..<3).map { _ in CALayer() }
    private let lows: [CGFloat] = [0.4, 0.7, 0.5]
    private let highs: [CGFloat] = [1.0, 0.3, 0.8]
    private let durations = [0.48, 0.37, 0.43]

    /// Whether the beat is currently running, and whether its animations have
    /// ever been installed. Separate flags: a view that has never played holds
    /// no animations at all, and one that is merely paused still holds them,
    /// stopped at the frame it reached.
    private var isRunning = false
    private var hasInstalledAnimations = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        for (index, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: 2, height: 10)
            bar.anchorPoint = CGPoint(x: 0.5, y: 0)
            bar.cornerRadius = 1
            // The resting shape, for a view that has not played yet: these
            // scales against the 10 pt bounds are the same [4, 7, 5] the
            // static branch draws, so nothing shifts between the two.
            bar.transform = CATransform3DMakeScale(1, lows[index], 1)
            layer?.addSublayer(bar)
        }
    }

    convenience init() {
        self.init(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: 10, height: 10) }

    override func layout() {
        super.layout()
        for (index, bar) in bars.enumerated() {
            bar.position = CGPoint(x: 1 + CGFloat(index) * 4, y: 0)
        }
    }

    func setOpacity(_ opacity: CGFloat) {
        let color = NSColor.white.withAlphaComponent(opacity).cgColor
        bars.forEach { $0.backgroundColor = color }
    }

    /// Starts or freezes the beat.
    ///
    /// Freezing stops the layer's own clock rather than removing the
    /// animations: the bars stay at exactly the heights they had reached, and
    /// resuming carries on from the same point in the cycle instead of
    /// restarting it. A stopped clock is nothing for the render server to
    /// advance, so a paused equalizer costs no more than a static one.
    func setRunning(_ running: Bool) {
        guard running != isRunning else { return }
        isRunning = running
        guard let layer else { return }
        if running {
            installAnimationsIfNeeded()
            resumeClock(of: layer)
        } else {
            pauseClock(of: layer)
        }
    }

    /// Real teardown, for a view going away — not the pause path.
    func stopAnimating() {
        bars.forEach { $0.removeAllAnimations() }
        hasInstalledAnimations = false
    }

    private func installAnimationsIfNeeded() {
        guard !hasInstalledAnimations else { return }
        hasInstalledAnimations = true
        let start = CACurrentMediaTime()
        for (index, bar) in bars.enumerated() {
            bar.transform = CATransform3DMakeScale(1, lows[index], 1)
            let animation = CABasicAnimation(keyPath: "transform.scale.y")
            animation.fromValue = lows[index]
            animation.toValue = highs[index]
            animation.duration = durations[index]
            animation.beginTime = start + Double(index) * 0.08
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animation.isRemovedOnCompletion = false
            bar.add(animation, forKey: "beat")
        }
    }

    private func pauseClock(of layer: CALayer) {
        guard layer.speed != 0 else { return }
        let stoppedAt = layer.convertTime(CACurrentMediaTime(), from: nil)
        layer.speed = 0
        layer.timeOffset = stoppedAt
    }

    private func resumeClock(of layer: CALayer) {
        guard layer.speed == 0 else { return }
        let stoppedAt = layer.timeOffset
        layer.speed = 1
        layer.timeOffset = 0
        layer.beginTime = 0
        // Shift the timeline forward by however long it stood still, so the
        // cycle continues from where it stopped rather than jumping.
        layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - stoppedAt
    }
}
