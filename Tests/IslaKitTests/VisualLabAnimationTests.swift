import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import IslaKit

// MARK: - Curves, read from the definitions themselves

/// One curve Isla animates on, with its parameters read back from the
/// `Animation` value the app actually uses (or, for the few literals that
/// live inside a view and cannot be reached from a test, from the source line
/// itself — the test fails if that line stops saying what it is sampled as).
struct LabCurve {
    enum Kind: String { case spring, bezier, coreAnimation, decayingSine }

    var name: String
    var usedFor: String
    var source: String
    var kind: Kind
    var description: String
    var response: Double = 0
    var damping: Double = 1
    var duration: Double = 0
    var delay: Double = 0
    /// Cubic coefficients of a bezier timing curve: x(t) = ((ax t + bx) t + cx) t, same for y.
    var cubic: (ax: Double, bx: Double, cx: Double, ay: Double, by: Double, cy: Double) = (0, 0, 0, 0, 0, 0)
    /// What one unit of progress is on screen, in points, where it is known.
    var travelPoints: Double?
    var repeats = false

    /// Parses SwiftUI's own description of an `Animation`, which on this SDK
    /// spells out the spring's response and damping and the bezier solver's
    /// coefficients exactly. Returns nil for a shape it does not recognise,
    /// which the test reports as a failure rather than guessing.
    static func parse(_ animation: Animation, name: String, usedFor: String, source: String, travel: Double? = nil) -> LabCurve? {
        let text = String(describing: animation)
        var curve = LabCurve(name: name, usedFor: usedFor, source: source, kind: .spring, description: text, travelPoints: travel)
        if let delay = Self.number(after: "DelayAnimation(delay: ", in: text) { curve.delay = delay }
        if let response = Self.number(after: "response: ", in: text),
           let damping = Self.number(after: "dampingFraction: ", in: text) {
            curve.kind = .spring
            curve.response = response
            curve.damping = damping
            if let own = Self.number(after: "blendDuration: 0.0, delay: ", in: text), own > 0 { curve.delay += own }
            return curve
        }
        if let duration = Self.number(after: "BezierAnimation(duration: ", in: text),
           let ax = Self.number(after: "ax: ", in: text), let bx = Self.number(after: "bx: ", in: text),
           let cx = Self.number(after: "cx: ", in: text), let ay = Self.number(after: "ay: ", in: text),
           let by = Self.number(after: "by: ", in: text), let cy = Self.number(after: "cy: ", in: text) {
            curve.kind = .bezier
            curve.duration = duration
            curve.cubic = (ax, bx, cx, ay, by, cy)
            return curve
        }
        return nil
    }

    private static func number(after marker: String, in text: String) -> Double? {
        guard let range = text.range(of: marker) else { return nil }
        let rest = text[range.upperBound...]
        let digits = rest.prefix { "0123456789.-e".contains($0) }
        return Double(digits)
    }

    // MARK: Evaluation

    var spring: Spring { Spring(response: response, dampingRatio: damping) }

    /// Progress at time t (seconds) from 0 toward 1, and its velocity per second.
    func sample(_ t: Double) -> (value: Double, velocity: Double) {
        let local = t - delay
        guard local > 0 else { return (0, 0) }
        switch kind {
        case .spring:
            return (spring.value(target: 1.0, time: local), spring.velocity(target: 1.0, time: local))
        case .bezier, .coreAnimation:
            guard local < duration else { return (1, 0) }
            let u = local / duration
            let s = solveX(u)
            let dx = (3 * cubic.ax * s + 2 * cubic.bx) * s + cubic.cx
            let dy = (3 * cubic.ay * s + 2 * cubic.by) * s + cubic.cy
            return (y(s), dx == 0 ? 0 : dy / dx / duration)
        case .decayingSine:
            return (0, 0)
        }
    }

    private func x(_ s: Double) -> Double { ((cubic.ax * s + cubic.bx) * s + cubic.cx) * s }
    private func y(_ s: Double) -> Double { ((cubic.ay * s + cubic.by) * s + cubic.cy) * s }

    /// The bezier parameter whose x is u, by Newton with a bisection fallback.
    private func solveX(_ u: Double) -> Double {
        var s = u
        for _ in 0..<8 {
            let error = x(s) - u
            if abs(error) < 1e-9 { return s }
            let slope = (3 * cubic.ax * s + 2 * cubic.bx) * s + cubic.cx
            if abs(slope) < 1e-9 { break }
            s -= error / slope
        }
        var low = 0.0, high = 1.0
        s = u
        while high - low > 1e-10 {
            if x(s) < u { low = s } else { high = s }
            s = (low + high) / 2
        }
        return s
    }

    /// The textbook damped harmonic oscillator for the same response and
    /// damping — stiffness (2π/response)², mass 1 — to check SwiftUI's solver
    /// against.
    func closedForm(_ t: Double) -> Double {
        let local = t - delay
        guard kind == .spring, local > 0 else { return 0 }
        let omega = 2 * Double.pi / response
        if abs(damping - 1) < 1e-9 {
            return 1 - (1 + omega * local) * exp(-omega * local)
        }
        let decay = damping * omega
        let omegaD = omega * (1 - damping * damping).squareRoot()
        return 1 - exp(-decay * local) * (cos(omegaD * local) + decay / omegaD * sin(omegaD * local))
    }
}

/// V2: every spring and timing curve, sampled at 1 ms, with settle time,
/// overshoot and hand-off; and keyframes of the motions that matter most.
@MainActor
final class VisualLabAnimationTests: VisualLabCase {

    // MARK: Inventory

    private static func literal(_ file: String, _ pattern: String) throws -> Double {
        let url = VisualLab.repositoryRoot.appendingPathComponent(file)
        let source = try String(contentsOf: url, encoding: .utf8)
        let regex = try NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              let range = Range(match.range(at: 1), in: source), let value = Double(source[range]) else {
            throw NSError(domain: "VisualLab", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(file) no longer matches \(pattern)"])
        }
        return value
    }

    static func inventory() throws -> [LabCurve] {
        func curve(_ animation: Animation, _ name: String, _ usedFor: String, _ source: String, travel: Double? = nil) throws -> LabCurve {
            guard let parsed = LabCurve.parse(animation, name: name, usedFor: usedFor, source: source, travel: travel) else {
                throw NSError(domain: "VisualLab", code: 3, userInfo: [NSLocalizedDescriptionKey: "cannot read \(name): \(animation)"])
            }
            return parsed
        }
        let body = Double(NotchMetrics.standardBodyHeight - LabGeometry.physicalNotch.height)
        var curves: [LabCurve] = [
            try curve(Theme.open(reduceMotion: false), "open-close", "panel open (shape, header, cover morph) on the outline's spring; the close is \"close\"", "Theme.swift islandSpring", travel: body),
            try curve(Theme.close(reduceMotion: false), "close", "panel close (shape, header, cover morph), the outline's spring after closeShapeDelay", "Theme.swift close(reduceMotion:)", travel: body),
            try curve(Theme.open(reduceMotion: true), "open-close-reduce-motion", "panel open/close under Reduce Motion", "Theme.swift open(reduceMotion:)"),
            try curve(Theme.openAnimation, "player-layout", "player changing between two layouts of one height", "Theme.swift openAnimation", travel: body),
            try curve(Theme.compactAnimation, "compact", "pill resizing around a new track", "Theme.swift compactAnimation", travel: Double(NotchMetrics.compactMediaExtension)),
            try curve(Theme.pill(reduceMotion: false), "pill-unfold", "pill growing out of the notch and folding back, the peek widening, and the pill's content arriving and leaving with it (blur 15→0, scale x 0.8→1, opacity)", "Theme.swift pill(reduceMotion:)", travel: Double(NotchMetrics.compactMediaExtension) / 2),
            try curve(Theme.pill(reduceMotion: true), "pill-reduce-motion", "pill fold/unfold under Reduce Motion", "Theme.swift pill(reduceMotion:)"),
            try curve(Theme.lyricScroll, "lyric-scroll", "stage page step, lock-card lyric window, row brightening", "Theme.swift lyricScroll",
                      travel: Double(LyricsStage.slotHeight + LyricsStage.slotSpacing)),
            try curve(Theme.captionTurnOut, "caption-turn-out", "caption line leaving its slot (opacity, blur 2→0, 7 pt up)", "Theme.swift captionTurnOut",
                      travel: Double(LyricLineTurn.travel)),
            try curve(Theme.captionTurnIn, "caption-turn-in", "caption line arriving in its slot (opacity, blur 2→0, 7 pt from below)", "Theme.swift captionTurnIn",
                      travel: Double(LyricLineTurn.travel)),
            try curve(Theme.lyricScroll(reduceMotion: true), "lyric-scroll-reduce-motion", "lyric page under Reduce Motion", "Theme.swift lyricScroll(reduceMotion:)"),
            try curve(Theme.hoverNudge, "hover-nudge", "resting island waking under the pointer (travel: each side, resting → awake)", "Theme.swift hoverNudge",
                      travel: Double(NotchContentView.awakeShape(notch: LabGeometry.physicalNotch, shoulder: Theme.collapsedTopRadius).width
                                     - NotchContentView.restingShape(notch: LabGeometry.physicalNotch).width) / 2),
            try curve(Theme.contentAnimation, "content", "badges, hover wells, sync pill, scrub hover, chevrons", "Theme.swift contentAnimation"),
            try curve(Theme.paneAnimation, "pane", "tab swap, lyrics stage in/out, welcome dismissal", "Theme.swift paneAnimation"),
            try curve(Theme.paneIn, "pane-in", "incoming pane and the open panel's body (opacity, scale 0.97)", "Theme.swift paneIn"),
            try curve(Theme.paneOut, "pane-out", "outgoing pane and the closing panel's body", "Theme.swift paneOut"),
            try curve(Theme.artworkAnimation, "artwork", "cover crossfade on a skip, title column crossfade", "Theme.swift artworkAnimation"),
        ]
        // Literals that live inside views. Read from the source line so the
        // sample cannot drift from what ships.
        // The karaoke sweep is not a curve any more: its edge is placed from
        // the clock on every frame (`KaraokeText.clock`, F-011), and
        // `KaraokeText.sweepAnimation` is nil in every case. The lyric lab's
        // L5 measures what it draws.
        let press = try literal("Sources/IslaKit/UI/Theme.swift", #"\.animation\(\.easeOut\(duration: ([0-9.]+)\), value: configuration\.isPressed\)"#)
        curves.append(try curve(.easeOut(duration: press), "button-press", "NotchButtonStyle press dim", "Theme.swift NotchButtonStyle"))
        // The refusal shake is no longer a curve: it is time-driven
        // (`RefusalShake.offset(at:)`), sampled into refusal-shake-offset.csv.
        let shimmer = try literal("Sources/IslaKit/UI/Skeleton.swift", #"\.linear\(duration: ([0-9.]+)\)\.repeatForever"#)
        var skeleton = try curve(.linear(duration: shimmer), "skeleton-shimmer", "artwork skeleton shimmer, repeating", "Skeleton.swift")
        skeleton.repeats = true
        curves.append(skeleton)
        // The lock card's fade is Core Animation's own ease-out, read from a
        // real CAMediaTimingFunction rather than assumed equal to SwiftUI's.
        let fade = try literal("Sources/IslaKit/Notch/LockCardWindow.swift", #"context\.duration = ([0-9.]+)"#)
        let function = CAMediaTimingFunction(name: .easeOut)
        var p1: [Float] = [0, 0], p2: [Float] = [0, 0]
        function.getControlPoint(at: 1, values: &p1)
        function.getControlPoint(at: 2, values: &p2)
        let cx = 3 * Double(p1[0]), bx = 3 * (Double(p2[0]) - Double(p1[0])) - cx, ax = 1 - cx - bx
        let cy = 3 * Double(p1[1]), by = 3 * (Double(p2[1]) - Double(p1[1])) - cy, ay = 1 - cy - by
        var card = LabCurve(name: "lock-card-fade", usedFor: "lock card window fading in over the shield", source: "LockCardWindow.swift",
                            kind: .coreAnimation, description: "CAMediaTimingFunction(.easeOut) control points (\(p1), \(p2)), duration \(fade)")
        card.duration = fade
        card.cubic = (ax, bx, cx, ay, by, cy)
        curves.append(card)
        return curves
    }

    // MARK: Metrics

    struct Metrics: Codable {
        var name: String
        var usedFor: String
        var source: String
        var kind: String
        var swiftUIDescription: String
        var response: Double?
        var dampingRatio: Double?
        var duration: Double?
        var delay: Double
        var stiffness: Double?
        var damping: Double?
        var mass: Double?
        var criticallyDamped: Bool?
        var sdkSettlingDurationSeconds: Double?
        var reaches90PercentMs: Int?
        var settleWithin1PercentMs: Int
        var peakOvershootPercent: Double
        var peakOvershootAtMs: Int?
        var peakOvershootPoints: Double?
        var travelPoints: Double?
        var initialVelocityPerSecond: Double
        var peakVelocityPerSecond: Double
        var closedFormMaxDeviation: Double?
        var sampler: String
        var handOff: [HandOff]
        var thrown: [Thrown]?
        var repeats: Bool
    }

    struct HandOff: Codable {
        var reversedAtMs: Int
        var valueAtReversal: Double
        var velocityBefore: Double
        var velocityAfter: Double
        var velocityJump: Double
        var undershootPastStartPercent: Double
        var settleAfterReversalMs: Int
        var model: String
    }

    struct Thrown: Codable {
        var initialVelocityPerSecond: Double
        var peakOvershootPercent: Double
        var settleWithin1PercentMs: Int
    }

    func testCurvesSampledAtOneMillisecond() throws {
        let session = try makeSession()
        let folder = session.root.appendingPathComponent("animation", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var all: [Metrics] = []

        for curve in try Self.inventory() {
            let end: Double = curve.kind == .spring ? 1.5 : curve.delay + curve.duration + 0.1
            var csv = curve.kind == .spring ? "t_ms,value,velocity_per_s,closed_form\n" : "t_ms,value,velocity_per_s\n"
            var peak = 0.0, peakAt: Int?
            var peakVelocity = 0.0
            var reach90: Int?
            var lastOutside = 0
            var deviation = 0.0
            for ms in 0...Int(end * 1000) {
                let t = Double(ms) / 1000
                let (value, velocity) = curve.sample(t)
                if curve.kind == .spring {
                    let closed = curve.closedForm(t)
                    deviation = max(deviation, abs(closed - value))
                    csv += String(format: "%d,%.6f,%.6f,%.6f\n", ms, value, velocity, closed)
                } else {
                    csv += String(format: "%d,%.6f,%.6f\n", ms, value, velocity)
                }
                if value - 1 > peak { peak = value - 1; peakAt = ms }
                peakVelocity = max(peakVelocity, abs(velocity))
                if reach90 == nil, value >= 0.9 { reach90 = ms }
                if abs(value - 1) > 0.01 { lastOutside = ms }
            }
            try csv.write(to: folder.appendingPathComponent("\(curve.name).csv"), atomically: true, encoding: .utf8)

            let initial = curve.kind == .spring
                ? curve.spring.velocity(target: 1.0, time: 0)
                : curve.sample(curve.delay + 1e-6).velocity
            var metrics = Metrics(
                name: curve.name, usedFor: curve.usedFor, source: curve.source, kind: curve.kind.rawValue,
                swiftUIDescription: curve.description,
                response: curve.kind == .spring ? curve.response : nil,
                dampingRatio: curve.kind == .spring ? curve.damping : nil,
                duration: curve.kind == .spring ? nil : curve.duration,
                delay: curve.delay,
                stiffness: curve.kind == .spring ? curve.spring.stiffness : nil,
                damping: curve.kind == .spring ? curve.spring.damping : nil,
                mass: curve.kind == .spring ? curve.spring.mass : nil,
                criticallyDamped: curve.kind == .spring ? abs(curve.damping - 1) < 1e-9 : nil,
                sdkSettlingDurationSeconds: curve.kind == .spring ? curve.spring.settlingDuration : nil,
                reaches90PercentMs: reach90,
                settleWithin1PercentMs: lastOutside + 1,
                peakOvershootPercent: (peak * 1000).rounded() / 10,
                peakOvershootAtMs: peak > 0 ? peakAt : nil,
                peakOvershootPoints: curve.travelPoints.map { ($0 * peak * 100).rounded() / 100 },
                travelPoints: curve.travelPoints,
                initialVelocityPerSecond: initial,
                peakVelocityPerSecond: peakVelocity,
                closedFormMaxDeviation: curve.kind == .spring ? deviation : nil,
                sampler: curve.kind == .spring
                    ? "SwiftUI Spring(response:dampingRatio:).value/velocity(target:initialVelocity:time:) from the parsed Animation; closed form alongside"
                    : "cubic bezier solved from the coefficients SwiftUI (or Core Animation) reports for the curve",
                handOff: [], thrown: nil, repeats: curve.repeats
            )
            metrics.handOff = Self.handOffs(curve)
            if curve.kind == .spring { metrics.thrown = Self.thrown(curve) }
            all.append(metrics)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(all).write(to: folder.appendingPathComponent("metrics.json"))
        // The decaying sine of the refusal shake, in points over time.
        try Self.shakeSeries().write(to: folder.appendingPathComponent("refusal-shake-offset.csv"), atomically: true, encoding: .utf8)
        XCTAssertFalse(all.isEmpty)
    }

    /// The panel is reversed mid-flight — opened, then shut before it lands.
    /// SwiftUI merges a spring into the one already running and keeps its
    /// velocity; it does not merge timing curves, which run on to completion
    /// with the new one added on top.
    static func handOffs(_ curve: LabCurve) -> [HandOff] {
        [50, 100, 150, 200].compactMap { ms in
            let th = Double(ms) / 1000
            guard th > curve.delay else { return nil }
            let (x, v) = curve.sample(th)
            var undershoot = 0.0
            var lastOutside = 0
            var after = 0.0
            for step in 0...1500 {
                let tau = Double(step) / 1000
                let value: Double
                let velocity: Double
                if curve.kind == .spring {
                    // Displacement −x toward 0, carrying v.
                    value = x + curve.spring.value(target: -x, initialVelocity: v, time: tau)
                    velocity = curve.spring.velocity(target: -x, initialVelocity: v, time: tau)
                } else {
                    // The first run continues; the second subtracts a whole
                    // unit on the same curve, starting now.
                    // At the hand-off instant itself the second run is
                    // read just after its start, so its opening velocity
                    // counts: that is the kink a timing curve puts in.
                    let first = curve.sample(th + tau)
                    let second = curve.sample(curve.delay + max(tau, 1e-6))
                    value = first.value - second.value
                    velocity = first.velocity - second.velocity
                }
                if step == 0 { after = velocity }
                undershoot = min(undershoot, value)
                if abs(value) > 0.01 { lastOutside = step }
            }
            return HandOff(
                reversedAtMs: ms, valueAtReversal: x, velocityBefore: v, velocityAfter: after,
                velocityJump: after - v, undershootPastStartPercent: (-undershoot * 1000).rounded() / 10,
                settleAfterReversalMs: lastOutside + 1,
                model: curve.kind == .spring ? "merged spring, velocity carried" : "additive (timing curves do not merge)"
            )
        }
    }

    /// What the same spring would do if a gesture handed it momentum.
    static func thrown(_ curve: LabCurve) -> [Thrown] {
        // Up to past ω = 2π/response, where even a critically damped spring
        // overshoots if it is handed enough velocity toward its target.
        [2.0, 5.0, 10.0, 20.0, 40.0].map { v0 in
            var peak = 0.0, lastOutside = 0
            for ms in 0...1500 {
                let value = curve.spring.value(target: 1.0, initialVelocity: v0, time: Double(ms) / 1000)
                peak = max(peak, value - 1)
                if abs(value - 1) > 0.01 { lastOutside = ms }
            }
            return Thrown(initialVelocityPerSecond: v0, peakOvershootPercent: (peak * 1000).rounded() / 10,
                          settleWithin1PercentMs: lastOutside + 1)
        }
    }

    /// The shake itself, sampled from the function the view draws with.
    static func shakeOffset(at t: Double) -> Double {
        RefusalShake.offset(at: t)
    }

    static func shakeSeries() -> String {
        var csv = "t_ms,offset_pt\n"
        for ms in 0...600 { csv += String(format: "%d,%.4f\n", ms, shakeOffset(at: Double(ms) / 1000)) }
        return csv
    }

    // MARK: Keyframes

    static let keyframeTimes: [Int] = [0, 16, 33, 50, 83, 120, 200, 300, 500]

    func testKeyframes() async throws {
        let session = try makeSession()
        let curves = Dictionary(uniqueKeysWithValues: try Self.inventory().map { ($0.name, $0) })
        func value(_ name: String, _ ms: Int) -> Double { curves[name]!.sample(Double(ms) / 1000).value }
        session.apply(.base)

        // The two ends of the open, drawn by the real views on a clear
        // ground, with a cover that is transparent so the travelling cover
        // can be drawn on its own; and the same ends with a solid magenta
        // cover, to find where each end of the cover actually lands.
        let transparent = LabFixtures.solidCover(.clear)
        let magenta = LabFixtures.solidCover(NSColor(calibratedRed: 1, green: 0, blue: 1, alpha: 1))
        let size = Self.panelSize
        func layer(open: Bool, cover: Data) async throws -> NSBitmapImageRep {
            let stores = session.makeStores()
            await LabFixtures.play(.init(elapsed: 27, cover: cover), on: stores.media)
            stores.lyrics.present(LabFixtures.timeline())
            let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: stores)
            vm.isOpen = open
            let view = NotchContentView(vm: vm).frame(width: size.width, height: size.height, alignment: .top)
            guard let shot = await LabRenderer.host(view, size: size, variant: .base, settle: 0.2) else {
                throw NSError(domain: "VisualLab", code: 4)
            }
            return shot.rep
        }
        let openLayer = try await layer(open: true, cover: transparent)
        let pillLayer = try await layer(open: false, cover: transparent)
        let openMarked = try await layer(open: true, cover: magenta)
        let pillMarked = try await layer(open: false, cover: magenta)
        let openCover = try XCTUnwrap(Self.bounds(of: (1, 0, 1), in: openMarked), "open cover not found")
        let pillCover = try XCTUnwrap(Self.bounds(of: (1, 0, 1), in: pillMarked), "pill cover not found")
        let cover = NSImage(data: LabFixtures.cover())!
        let notch = LabGeometry.physicalNotch
        let openBody = CGSize(width: NotchMetrics.defaultBodyWidth, height: NotchMetrics.standardBodyHeight)
        let pillBody = CGSize(width: notch.width + NotchMetrics.compactMediaExtension, height: notch.height)

        let note = "Reconstructed from the sampled curves and the real end-state views; see docs/development/audits/2026-10-11-visual-lab/README.md §Keyframes."

        func frame(_ sequence: String, _ ms: Int, size: CGSize, notes: String, _ view: @escaping () -> AnyView) async throws {
            let shoot = LabPhotographer(session: session, surface: "keyframes-\(sequence)")
            try await shoot.shoot("t\(String(format: "%03d", ms))ms", variants: [LabVariant(name: "frame", backend: .imageRenderer)],
                                  size: size, settle: 0, notes: notes) { _ in view() }
        }

        // Open and close.
        for closing in [false, true] {
            for ms in Self.keyframeTimes {
                // The close rides its own curve: the open's spring started
                // `Theme.closeShapeDelay` late (H-012).
                let s = value(closing ? "close" : "open-close", ms)
                let p = closing ? 1 - s : s
                let bodyAlpha = closing ? 1 - value("pane-out", ms) : value("pane-in", ms)
                let headerAlpha = p
                let compactAlpha = 1 - p
                let composite = OpenKeyframe(
                    p: p, bodyAlpha: bodyAlpha, headerAlpha: headerAlpha, compactAlpha: compactAlpha,
                    openLayer: Self.image(openLayer), pillLayer: Self.image(pillLayer), cover: cover,
                    openCover: openCover, pillCover: pillCover, openBody: openBody, pillBody: pillBody,
                    notch: notch, canvas: size
                )
                try await frame(closing ? "close" : "open", ms, size: size,
                                notes: note + String(format: " shape progress %.3f, body alpha %.3f, header alpha %.3f.", p, bodyAlpha, headerAlpha)) {
                    AnyView(composite)
                }
            }
        }

        // The caption's line turn, each line on its own curve (H-014), and
        // the stage's page step on the lyric spring.
        for ms in Self.keyframeTimes {
            let s = value("lyric-scroll", ms)
            let out = value("caption-turn-out", ms), arriving = value("caption-turn-in", ms)
            try await frame("caption-line-turn", ms, size: CGSize(width: 420, height: 72),
                            notes: note + String(format: " outgoing progress %.3f, incoming %.3f (LyricLineTurn on both lines).", out, arriving)) {
                AnyView(CaptionTurnKeyframe(outgoing: out, incoming: arriving))
            }
            try await frame("stage-page-step", ms, size: CGSize(width: 488, height: 162),
                            notes: note + String(format: " lyric spring progress %.3f: page offset %.1f pt.", s,
                                                 -s * Double(LyricsStage.slotHeight + LyricsStage.slotSpacing))) {
                AnyView(StagePageKeyframe(progress: s))
            }
        }

        // The pill out of the notch and back in. The shape and its content
        // ride one curve since spec §19.3, both ways.
        for folding in [false, true] {
            for ms in Self.keyframeTimes {
                let shape = folding ? 1 - value("pill-unfold", ms) : value("pill-unfold", ms)
                let content = shape
                try await frame(folding ? "pill-fold" : "pill-unfold", ms, size: Self.pillSize,
                                notes: note + String(format: " shape %.3f, content presence %.3f.", shape, content)) {
                    AnyView(PillKeyframe(shape: shape, content: content, cover: cover, notch: notch))
                }
            }
        }

        // The resting island waking under the pointer — the one bump.
        for ms in Self.keyframeTimes {
            let s = value("hover-nudge", ms)
            try await frame("hover-nudge", ms, size: Self.pillSize,
                            notes: note + String(format: " hover spring %.3f (overshoot shows as the island passing its awake size).", s)) {
                AnyView(NudgeKeyframe(progress: s, notch: notch))
            }
        }

        // The refusal shake of the locked pill.
        let locked = try await {
            let stores = session.makeStores()
            await LabFixtures.play(.init(), on: stores.media)
            let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: stores)
            vm.isLockedPresentation = true
            let view = NotchContentView(vm: vm).frame(width: Self.pillSize.width, height: Self.pillSize.height, alignment: .top)
            return await LabRenderer.host(view, size: Self.pillSize, variant: .base, settle: 0.2)!.rep
        }()
        for ms in Self.keyframeTimes {
            let offset = Self.shakeOffset(at: Double(ms) / 1000)
            try await frame("refusal-shake", ms, size: Self.pillSize,
                            notes: note + String(format: " offset %.2f pt.", offset)) {
                AnyView(ZStack(alignment: .top) {
                    LabDesktop(light: false, menuBarHeight: notch.height, hardwareNotch: notch)
                    Image(nsImage: Self.image(locked)).offset(x: offset)
                })
            }
        }
    }

    static func image(_ rep: NSBitmapImageRep) -> NSImage {
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    /// The bounding box, in points, of pixels close to a colour.
    static func bounds(of color: (Double, Double, Double), in rep: NSBitmapImageRep) -> CGRect? {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in stride(from: 0, to: rep.pixelsHigh, by: 1) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 1) {
                guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                // Generous, because the colour is managed on the way to the
                // bitmap: a pure magenta cover lands as roughly (1, 0.25, 1).
                if abs(pixel.redComponent - color.0) < 0.2, abs(pixel.greenComponent - color.1) < 0.45,
                   abs(pixel.blueComponent - color.2) < 0.2, pixel.alphaComponent > 0.9 {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= 0 else { return nil }
        let scale = Double(rep.pixelsWide) / rep.size.width
        return CGRect(x: Double(minX) / scale, y: Double(minY) / scale,
                      width: Double(maxX - minX + 1) / scale, height: Double(maxY - minY + 1) / scale)
    }
}

// MARK: - Keyframe composites

private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }

/// One frame of the open or the close. The shape is the real `NotchShape` at
/// the sampled size and radii; the body and the header are the real open
/// panel at the alpha their own transitions give them, clipped to the body's
/// sampled frame; the pill's header leaves on the open spring; and the cover
/// is drawn twice along its matched-geometry path — the pill's copy fading
/// out with the compact header, the pane's fading in with the body — which is
/// what a matched pair inside two fading containers does.
private struct OpenKeyframe: View {
    static func blot(_ rect: CGRect, radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.black)
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
    }

    let p: Double
    let bodyAlpha: Double
    let headerAlpha: Double
    let compactAlpha: Double
    let openLayer: NSImage
    let pillLayer: NSImage
    let cover: NSImage
    let openCover: CGRect
    let pillCover: CGRect
    let openBody: CGSize
    let pillBody: CGSize
    let notch: CGSize
    let canvas: CGSize

    var body: some View {
        let topRadius = lerp(Theme.collapsedTopRadius, NotchViewModel.Surface.player.topRadius, p)
        let bottomRadius = lerp(Theme.collapsedBottomRadius, NotchViewModel.Surface.player.bottomRadius, p)
        let width = lerp(pillBody.width, openBody.width, p)
        let height = lerp(pillBody.height, openBody.height, p)
        let clip = CGRect(x: (canvas.width - width) / 2, y: 0, width: width, height: height)
        let coverRect = CGRect(
            x: lerp(pillCover.minX, openCover.minX, p), y: lerp(pillCover.minY, openCover.minY, p),
            width: lerp(pillCover.width, openCover.width, p), height: lerp(pillCover.height, openCover.height, p)
        )
        let coverRadius = lerp(Theme.artworkMetrics(isOpen: false).cornerRadius, Theme.artworkMetrics(isOpen: true).cornerRadius, p)
        ZStack(alignment: .topLeading) {
            LabDesktop(light: false, menuBarHeight: notch.height, hardwareNotch: notch)
            NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)
                .fill(Color.black)
                .frame(width: width + 2 * topRadius, height: height)
                .shadow(color: .black.opacity(0.28 + 0.22 * p), radius: lerp(5, 18, p), y: lerp(2, 8, p))
                .frame(width: canvas.width, alignment: .top)
            // The pill's own content, leaving: opacity and a 0.9 scale.
            // Each end layer was drawn with a transparent cover, which still
            // leaves the cover's hairline and shadow at that end; both sit on
            // the panel's black, so black blots them out and the travelling
            // cover below is the only one drawn.
            ZStack(alignment: .topLeading) {
                Image(nsImage: pillLayer)
                Self.blot(pillCover.insetBy(dx: -1.5, dy: -1.5), radius: 7)
            }
            .scaleEffect(lerp(1, 0.9, 1 - compactAlpha), anchor: .top)
            .opacity(compactAlpha)
            // The open panel: header strip and body, each at its own alpha,
            // inside the body's sampled frame.
            ZStack(alignment: .topLeading) {
                Image(nsImage: openLayer).opacity(headerAlpha)
                    .mask(alignment: .topLeading) { Rectangle().frame(width: canvas.width, height: notch.height) }
                ZStack(alignment: .topLeading) {
                    Image(nsImage: openLayer)
                    Self.blot(openCover.insetBy(dx: -3, dy: -3), radius: 16)
                }
                .opacity(bodyAlpha)
                .mask(alignment: .topLeading) {
                    Rectangle().frame(width: canvas.width, height: canvas.height - notch.height).offset(y: notch.height)
                }
            }
            .mask(alignment: .topLeading) {
                Rectangle().frame(width: clip.width, height: clip.height).offset(x: clip.minX, y: clip.minY)
            }
            ForEach(Array([compactAlpha, bodyAlpha].enumerated()), id: \.offset) { _, alpha in
                Image(nsImage: cover)
                    .resizable()
                    .frame(width: coverRect.width, height: coverRect.height)
                    .clipShape(RoundedRectangle(cornerRadius: coverRadius, style: .continuous))
                    .offset(x: coverRect.minX, y: coverRect.minY)
                    .opacity(alpha)
            }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .clipped()
    }
}

/// The caption slot during a line change, with the real `LyricLineTurn` on
/// both lines and the real `KaraokeText` drawing them. Each line has its own
/// progress because each rides its own curve (`Theme.captionTurnOut`/`In`).
private struct CaptionTurnKeyframe: View {
    let outgoing: Double
    let incoming: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Waiting Room").islandFont(.title).foregroundStyle(.white)
            Text("Halcyon Static — Low Light").islandFont(.body, weight: .regular).foregroundStyle(Theme.secondary).padding(.top, 3)
            ZStack(alignment: .leading) {
                Color.clear
                KaraokeText(text: "Walk the length of the block and back", fraction: 1,
                            tracking: Theme.tracking(forSize: Theme.TypeRole.body.size))
                    .modifier(LyricLineTurn(progress: outgoing, direction: -1))
                KaraokeText(text: "Sit in the waiting room again", fraction: 0,
                            tracking: Theme.tracking(forSize: Theme.TypeRole.body.size))
                    .modifier(LyricLineTurn(progress: 1 - incoming, direction: 1))
            }
            .frame(height: MediaPane.textBox(
                x: 0, baseline: 0, width: 0, size: PlayerLayout.subtitleSize, weight: .semibold
            ).height)
            .clipped()
            .padding(.top, 4)
        }
        .padding(12)
        .frame(width: 420, height: 72, alignment: .topLeading)
        .background(Color.black)
    }
}

/// The lyrics stage moving one line: the real `LyricRow`s, the page offset
/// by the sampled travel, and the outgoing and incoming current lines
/// crossfading on the same spring, under the stage's own edge mask.
private struct StagePageKeyframe: View {
    let progress: Double

    var body: some View {
        let lines = LabFixtures.lines
        let slot = LyricsStage.slotHeight + LyricsStage.slotSpacing
        func column(current: Int) -> some View {
            VStack(alignment: .leading, spacing: LyricsStage.slotSpacing) {
                ForEach(0..<lines.count, id: \.self) { index in
                    LyricRow(line: lines[index], isCurrent: index == current, distance: abs(index - current),
                             at: lines[current].at + 0.5, end: lines[current].at + 10,
                             fontSize: Theme.TypeRole.title.size, weight: .bold, lineLimit: 2)
                        .frame(height: LyricsStage.slotHeight, alignment: .leading)
                }
            }
        }
        // Line 2 is being left for line 3; the page starts centred on line 2.
        let start = -CGFloat(2) * slot + (162 - LyricsStage.slotHeight) / 2
        return ZStack(alignment: .topLeading) {
            column(current: 2).opacity(1 - progress)
            column(current: 3).opacity(progress)
        }
        .offset(y: start - CGFloat(progress) * slot)
        .padding(.horizontal, 22)
        .frame(width: 488, height: 162, alignment: .topLeading)
        .mask(
            LinearGradient(stops: [
                .init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                .init(color: .black, location: 0.78), .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        )
        .background(Color.black)
    }
}

/// The pill unfolding or folding: the shape at the sampled width and radii,
/// and the cover and equalizer centred in wings that follow it, dissolving on
/// the same curve with `PillPresence`'s blur, scale and opacity.
private struct PillKeyframe: View {
    let shape: Double
    let content: Double
    let cover: NSImage
    let notch: CGSize

    var body: some View {
        let resting = NotchContentView.restingShape(notch: notch)
        let bodyWidth = lerp(resting.width, notch.width + NotchMetrics.compactMediaExtension, shape)
        let top = lerp(0, Theme.collapsedTopRadius, shape)
        let bottom = lerp(Theme.restingNotchBottomRadius, Theme.collapsedBottomRadius, shape)
        let height = lerp(resting.height, notch.height, shape)
        let wing = max(0, (bodyWidth - notch.width) / 2)
        let hidden = PillPresence.appearance(shown: false, reduceMotion: false)
        let blur = lerp(hidden.blur, 0, content)
        let scaleX = lerp(hidden.scale.width, 1, content)
        return ZStack(alignment: .top) {
            LabDesktop(light: false, menuBarHeight: notch.height, hardwareNotch: notch)
            NotchShape(topRadius: top, bottomRadius: bottom)
                .fill(Color.black)
                .frame(width: bodyWidth + 2 * top, height: height)
                .shadow(color: .black.opacity(0.28 * shape), radius: 5, y: 2)
            HStack(spacing: 0) {
                Image(nsImage: cover).resizable().frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .frame(width: wing)
                Color.clear.frame(width: notch.width, height: 1)
                EqualizerBars(isAnimating: false, opacity: 0.82)
                    .frame(width: wing)
            }
            .frame(width: bodyWidth, height: notch.height)
            .blur(radius: max(0, blur)).scaleEffect(x: scaleX, y: 1).opacity(max(0, min(1, content)))
            .environment(\._accessibilityReduceMotion, true)
        }
    }
}

/// The resting island growing out of the cutout under the pointer.
private struct NudgeKeyframe: View {
    let progress: Double
    let notch: CGSize

    var body: some View {
        let resting = NotchContentView.restingShape(notch: notch)
        let awake = NotchContentView.awakeShape(notch: notch, shoulder: Theme.collapsedTopRadius)
        return ZStack(alignment: .top) {
            LabDesktop(light: false, menuBarHeight: notch.height, hardwareNotch: notch)
            NotchShape(topRadius: lerp(0, Theme.collapsedTopRadius, progress),
                       bottomRadius: lerp(Theme.restingNotchBottomRadius, Theme.collapsedBottomRadius, progress))
                .fill(Color.black)
                .frame(width: lerp(resting.width, awake.width, progress), height: lerp(resting.height, awake.height, progress))
                .shadow(color: .black.opacity(0.28 * min(1, max(0, progress))), radius: 5, y: 2)
        }
    }
}
