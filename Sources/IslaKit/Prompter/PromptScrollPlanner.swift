import Foundation

// Foundation only. Where the stage puts the page (spec 10.3, 10.4) and when it
// may move it (10.3's forward-only rule, 8.5's manual scroll), as values a
// test can drive line by line. The view applies the one number this produces,
// `PromptScrollPlanner.displayed`, as the page's vertical offset.
//
// Offsets are in points, added to a content y to get a y in the text region:
// reading moves the page up, so the offset falls as the speaker reads.

// MARK: - Geometry

/// One layout in one text region at one reading position.
struct PromptScrollGeometry: Sendable {
    /// How far above the region's bottom (the control row's top) the line
    /// being read always ends, even in a region barely taller than a line
    /// (10.4: "a floor keeps it above the control row"). One spacing step, so
    /// the last line never touches the controls and never sits in the fade.
    static let endClearance: Double = 8

    let layout: PromptLayout
    /// The text region's height.
    let viewport: Double
    let placement: PrompterReadingPosition

    /// Where, in the region, the line being read is centred: the middle for
    /// Centered; the middle of the second line for Near Top, so the previous
    /// line stays in view above it (10.3).
    var guideY: Double {
        switch placement {
        case .centered: return viewport / 2
        case .nearTop: return layout.metrics.pitch + layout.metrics.lineHeight / 2
        }
    }

    /// The offset that puts `line` where the reader looks.
    ///
    /// Centered puts its middle on the region's middle, which at the start is
    /// "the first line at the vertical center minus half a line" (10.4). Near
    /// Top puts it one line below the top, except the first line, which sits
    /// at the top: there is no previous line to show (10.4 "near top puts it
    /// at the top").
    ///
    /// Then the end floor: the line ends at least `endClearance` above the
    /// control row, and that never pushes its top off the region.
    func offset(forLine line: Int) -> Double {
        guard layout.lines.indices.contains(line) else { return 0 }
        let raw: Double
        switch placement {
        case .centered:
            raw = viewport / 2 - layout.lineCenter(line)
        case .nearTop:
            raw = min(0, layout.metrics.pitch - layout.lines[line].top)
        }
        let floor = viewport - Self.endClearance - layout.lineBottom(line)
        return max(-layout.lines[line].top, min(raw, floor))
    }

    /// The offset for a progress value (fractional words, `PromptClock`).
    ///
    /// Timer modes interpolate between the active word's line and the next
    /// word's by the fraction (10.3), so the page is still while a line is
    /// read and glides to the next line over the last word's time. Tracking
    /// (Follow) moves straight to the word's line. Clamped at both ends
    /// (E-30): before the first word is the first line, past the last word
    /// is the last line.
    func offset(forProgress progress: Double, in script: PromptScript, interpolates: Bool) -> Double {
        let count = script.words.count
        guard count > 0, !layout.lines.isEmpty else { return 0 }
        let clamped = progress.isFinite ? min(max(progress, 0), Double(count)) : 0
        if clamped >= Double(count) {
            return offset(forLine: layout.lines.count - 1)
        }
        let word = Int(clamped)
        let here = offset(forLine: layout.lineIndex(ofWord: word) ?? 0)
        guard interpolates, word + 1 < count else { return here }
        let next = offset(forLine: layout.lineIndex(ofWord: word + 1) ?? 0)
        return here + (next - here) * (clamped - Double(word))
    }

    /// Where a hand may take the page: from the last line at the guide
    /// (`-maxDown`) to the first line at the guide (`maxUp`), in absolute
    /// offsets (10.4).
    var manualRange: ClosedRange<Double> {
        guard !layout.lines.isEmpty else { return 0...0 }
        let first = offset(forLine: 0)
        let last = offset(forLine: layout.lines.count - 1)
        return min(first, last)...max(first, last)
    }

    /// The line whose middle is nearest the guide when the page sits at
    /// `offset`. `line(atContentY:)` changes line at a line's top; shifting the
    /// guide by half a pitch less half a line moves that change to half way
    /// between two middles.
    func lineAtGuide(offset: Double) -> Int? {
        let metrics = layout.metrics
        return layout.line(atContentY: guideY - offset - metrics.lineHeight / 2 + metrics.pitch / 2)
    }
}

// MARK: - The planner

/// The page's offset over time: the clock's targets, filtered by the
/// forward-only rule, and a hand's scroll on top.
///
/// Spec 10.3: a target behind the current offset by more than 1 pt is ignored
/// unless a tap, the end of a manual scroll or a page change armed a single
/// backward update. Without that rule a recognizer revising an earlier word
/// (Follow, release 3) bounced the page back and forth under the speaker; in
/// the timer modes it is what keeps a rounding wobble from ever showing as a
/// step back.
struct PromptScrollPlanner: Sendable, Equatable {
    static let backwardTolerance: Double = 1
    /// How much of the distance past an end a hand still moves the page (10.4).
    static let rubberBand: Double = 0.2

    /// The clock's offset, as last accepted; nil before the first target.
    private(set) var offset: Double?
    private(set) var backwardArmed = false
    /// The hand's raw travel since the scroll began, before the rubber band.
    private var manualTravel: Double?

    var isManual: Bool { manualTravel != nil }

    /// What the view draws.
    private(set) var displayed: Double = 0

    /// Lets exactly one backward update through: the next target is taken
    /// whichever way it goes, and the permission is spent on it either way, so
    /// an arming a forward tap did not need cannot linger until a revision
    /// comes along to use it.
    mutating func armBackward() {
        backwardArmed = true
    }

    /// Offers the clock's target. Returns whether what is drawn moved.
    /// Ignored entirely while a hand is on the page: the text under a scroll
    /// belongs to the hand (8.5).
    @discardableResult
    mutating func follow(_ target: Double) -> Bool {
        guard target.isFinite, manualTravel == nil else { return false }
        if let offset, target > offset + Self.backwardTolerance, !backwardArmed {
            return false
        }
        backwardArmed = false
        offset = target
        let moved = displayed != target
        displayed = target
        return moved
    }

    /// A new layout (width, size, face, page, reading position): the target
    /// is taken as it is. Pixels from the old layout mean nothing in the new
    /// one; the caller re-derives the target from the reading offset (10.6,
    /// E-28), which is what keeps the same word under the guide.
    mutating func reanchor(_ target: Double) {
        guard target.isFinite else { return }
        offset = target
        manualTravel = nil
        backwardArmed = false
        displayed = target
    }

    mutating func beginManual() {
        if manualTravel == nil { manualTravel = 0 }
    }

    /// Moves the page by a hand's delta, held to `range` with the rubber band
    /// past either end. The raw travel is kept, so a hand that comes back gets
    /// the page back exactly where it left it.
    mutating func scroll(by delta: Double, within range: ClosedRange<Double>) {
        guard let travel = manualTravel, delta.isFinite else { return }
        manualTravel = travel + delta
        displayed = Self.rubberBand((offset ?? 0) + travel + delta, in: range)
    }

    /// The hand let go: the page settles inside `range` (the band springs
    /// back) and the clock's targets are taken again. Returns where it
    /// settled, which is where the reader's eye was.
    @discardableResult
    mutating func endManual(within range: ClosedRange<Double>) -> Double {
        let settled = min(max(displayed, range.lowerBound), range.upperBound)
        manualTravel = nil
        offset = settled
        displayed = settled
        return settled
    }

    /// Past an end, 20 percent of the excess (10.4).
    static func rubberBand(_ value: Double, in range: ClosedRange<Double>) -> Double {
        if value > range.upperBound { return range.upperBound + (value - range.upperBound) * rubberBand }
        if value < range.lowerBound { return range.lowerBound - (range.lowerBound - value) * rubberBand }
        return value
    }
}
