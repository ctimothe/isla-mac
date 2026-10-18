import SwiftUI

/// The curve one change of the island's outline rides, read back from the
/// animation SwiftUI hands the update (redesign spec §19.3, §19.12).
///
/// The outline is drawn by Core Animation, off the main thread
/// (`IslandOutlineHost`), and Core Animation has no idea what a SwiftUI
/// `Animation` is. What it can be given is the curve's values, sampled once
/// when the change begins, so everything that decided the curve in SwiftUI
/// keeps deciding it: `Theme.island(reduceMotion:)` for the 0.5 / 0.75 spring
/// or the 0.24 ease-in-out, `Theme.close`'s 30 ms delay, the pop-up's
/// critically damped `hudSpring`, the resting notch's `hoverNudge`. This file
/// holds no constants of its own — a curve nobody here has heard of is read
/// from its description, and one that cannot be read is the outline's own
/// spring.
///
/// SwiftUI's own solver does the sampling (`Spring`), not a copy of its
/// arithmetic, so the outline and the content that rides the same transaction
/// cannot drift apart. `OutlineCurveTests` pins the descriptions this reads
/// against the animations `Theme` defines: if a later SDK words them
/// differently the failure is there, not a quietly different island.
enum OutlineCurve: Equatable {
    /// The outline is where it is going.
    case instant
    /// `Animation.spring(response:dampingFraction:)`, started `delay` late.
    case spring(response: Double, damping: Double, delay: Double)
    /// A timing curve: `easeIn`, `easeOut`, `easeInOut`, `linear`.
    case bezier(duration: Double, cubic: Cubic, delay: Double)

    /// The coefficients SwiftUI's solver is built from: x(s) and y(s) are
    /// cubics in the curve's parameter s.
    struct Cubic: Equatable {
        var ax: Double, bx: Double, cx: Double
        var ay: Double, by: Double, cy: Double

        func x(_ s: Double) -> Double { ((ax * s + bx) * s + cx) * s }
        func y(_ s: Double) -> Double { ((ay * s + by) * s + cy) * s }
        func dx(_ s: Double) -> Double { (3 * ax * s + 2 * bx) * s + cx }
        func dy(_ s: Double) -> Double { (3 * ay * s + 2 * by) * s + cy }

        /// The parameter whose x is `u`, by Newton with a bisection fallback.
        func solve(x u: Double) -> Double {
            var s = u
            for _ in 0..<8 {
                let error = x(s) - u
                if abs(error) < 1e-9 { return s }
                let slope = dx(s)
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
    }

    /// The same curve without its delay. A change that interrupts a moving one
    /// does not wait out the delay: the outline would stand still for it, and
    /// then lurch on with the speed it had before it stopped.
    var withoutDelay: OutlineCurve {
        switch self {
        case .instant: return .instant
        case .spring(let response, let damping, _): return .spring(response: response, damping: damping, delay: 0)
        case .bezier(let duration, let cubic, _): return .bezier(duration: duration, cubic: cubic, delay: 0)
        }
    }

    /// What an animation nobody can read becomes: the outline's own spring
    /// (§19.3), the curve every change of its size is specified on.
    static let island = OutlineCurve.spring(
        response: Theme.islandResponse, damping: Theme.islandDamping, delay: 0
    )

    /// The most keyframes per second a change is sampled at. The render server
    /// interpolates linearly between them at the display's own rate, so this
    /// only has to be finer than the curve bends.
    static let sampleRate: Double = 120

    /// The longest a change is followed: past three seconds nothing the island
    /// does is still moving.
    static let longestChange: Double = 3

    /// The curve of an update: none when animations are off for it or it
    /// carries none, else what the animation says.
    static func of(_ animation: Animation?, disablesAnimations: Bool = false) -> OutlineCurve {
        guard !disablesAnimations, let animation else { return .instant }
        return parse(String(describing: animation)) ?? .island
    }

    /// Reads the curve out of an `Animation`'s description, which on this SDK
    /// spells out a spring's response and damping and a timing curve's solver
    /// coefficients exactly (the visual lab reads the same text).
    static func parse(_ text: String) -> OutlineCurve? {
        let delay = number(after: "DelayAnimation(delay: ", in: text[...]) ?? 0
        if let spring = text.range(of: "FluidSpringAnimation(response: ") {
            let body = text[spring.lowerBound...]
            guard let response = number(after: "response: ", in: body),
                  let damping = number(after: "dampingFraction: ", in: body), response > 0 else { return nil }
            // The spring's own delay field, which `.delay(_:)` leaves at zero
            // and a hand-built one may not; the modifier's adds to it.
            let own = number(after: ", delay: ", in: body) ?? 0
            return .spring(response: response, damping: damping, delay: delay + own)
        }
        if let duration = number(after: "BezierAnimation(duration: ", in: text[...]),
           let ax = number(after: "ax: ", in: text[...]), let bx = number(after: "bx: ", in: text[...]),
           let cx = number(after: "cx: ", in: text[...]), let ay = number(after: "ay: ", in: text[...]),
           let by = number(after: "by: ", in: text[...]), let cy = number(after: "cy: ", in: text[...]),
           duration > 0 {
            return .bezier(
                duration: duration,
                cubic: Cubic(ax: ax, bx: bx, cx: cx, ay: ay, by: by, cy: cy),
                delay: delay
            )
        }
        return nil
    }

    private static func number(after marker: String, in text: Substring) -> Double? {
        guard let range = text.range(of: marker) else { return nil }
        let digits = text[range.upperBound...].prefix { "0123456789.-e".contains($0) }
        return Double(digits)
    }

    // MARK: Progress

    /// How far along the change is, from 0 to 1 (a spring passes 1 on its way:
    /// about 3 % for the island's), `time` seconds after it began.
    /// `velocity` is the progress per second the change inherits from one it
    /// interrupted — a spring keeps its momentum when it is turned round, a
    /// timing curve starts again from rest, as SwiftUI's do.
    func progress(at time: Double, initialVelocity velocity: Double = 0) -> Double {
        switch self {
        case .instant:
            return 1
        case .spring(let response, let damping, let delay):
            let local = time - delay
            guard local > 0 else { return 0 }
            return Spring(response: response, dampingRatio: damping)
                .value(target: 1.0, initialVelocity: velocity, time: local)
        case .bezier(let duration, let cubic, let delay):
            let local = time - delay
            guard local > 0 else { return 0 }
            guard local < duration else { return 1 }
            return cubic.y(cubic.solve(x: local / duration))
        }
    }

    /// The same, as a rate: progress per second.
    func velocity(at time: Double, initialVelocity velocity: Double = 0) -> Double {
        switch self {
        case .instant:
            return 0
        case .spring(let response, let damping, let delay):
            let local = time - delay
            // Held still until the delay is over: a held value has no speed.
            guard local > 0 else { return 0 }
            return Spring(response: response, dampingRatio: damping)
                .velocity(target: 1.0, initialVelocity: velocity, time: local)
        case .bezier(let duration, let cubic, let delay):
            let local = time - delay
            guard local > 0, local < duration else { return 0 }
            let s = cubic.solve(x: local / duration)
            let slope = cubic.dx(s)
            return slope == 0 ? 0 : cubic.dy(s) / slope / duration
        }
    }

    /// The change as keyframes: progress at 1 / `sampleRate` steps from its
    /// start to the first moment it is within 0.0004 of its end and stays
    /// there — the last keyframe is exactly 1.
    ///
    /// Sampled rather than handed to Core Animation as a spring because a
    /// spring (`CASpringAnimation`) cannot say `Theme.close`'s 30 ms delay or
    /// the 0.24 ease-in-out, and because it would be a second implementation
    /// of the curve to keep equal to SwiftUI's. One sampler serves every curve
    /// the island moves on.
    func keyframes(initialVelocity velocity: Double = 0) -> (duration: Double, progress: [Double]) {
        if self == .instant { return (0, [1]) }
        let step = 1 / Self.sampleRate
        let limit = Int(Self.longestChange * Self.sampleRate)
        var values: [Double] = []
        values.reserveCapacity(limit + 1)
        for index in 0...limit {
            values.append(progress(at: Double(index) * step, initialVelocity: velocity))
        }
        // The first sample from which it never leaves the settle band again.
        var settled = values.count - 1
        while settled > 0, abs(values[settled - 1] - 1) <= 0.0004 { settled -= 1 }
        let count = max(1, settled)
        var trimmed = Array(values[0...count])
        trimmed[count] = 1
        return (Double(count) * step, trimmed)
    }
}
