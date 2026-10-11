import AppKit
import Combine
import CoreText
import SwiftUI

// MARK: - Faces

/// The face the stage reads in: the family setting at the size setting.
struct PrompterTypeface: Equatable, Sendable {
    let family: PrompterFontFamily
    let size: Double
}

/// Turns `prompter.fontFamily` into a font (design note, type; E-32).
enum PrompterFontResolver {
    /// OpenDyslexic's PostScript name, then its family name: either is how a
    /// user who installed it will have it.
    static let dyslexiaFontName = "OpenDyslexic-Regular"
    private static let dyslexiaFontNames = [dyslexiaFontName, "OpenDyslexic"]

    struct Resolved {
        let font: NSFont
        /// The family asked for is not installed and a stand-in was used.
        /// Settings says "not installed" from this (T9); the stage itself
        /// falls back silently.
        let isFallback: Bool
    }

    /// The system face, medium weight (the design note's reading weight), in
    /// one of its designs.
    static func systemFont(size: Double, design: NSFontDescriptor.SystemDesign) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .medium)
        guard design != .default,
              let descriptor = base.fontDescriptor.withDesign(design),
              let font = NSFont(descriptor: descriptor, size: size) else { return base }
        return font
    }

    /// Sans, serif and mono are the system face's own designs and always
    /// exist. OpenDyslexic is looked up by name and, when it is missing, is
    /// the rounded system face: the nearest thing the system ships to a face
    /// drawn for legibility, and never a crash or an empty stage (E-32).
    static func resolve(
        family: PrompterFontFamily,
        size: Double,
        lookup: (String, CGFloat) -> NSFont? = { NSFont(name: $0, size: $1) }
    ) -> Resolved {
        switch family {
        case .sans: return Resolved(font: systemFont(size: size, design: .default), isFallback: false)
        case .serif: return Resolved(font: systemFont(size: size, design: .serif), isFallback: false)
        case .mono: return Resolved(font: systemFont(size: size, design: .monospaced), isFallback: false)
        case .dyslexia:
            for name in dyslexiaFontNames {
                if let font = lookup(name, CGFloat(size)) { return Resolved(font: font, isFallback: false) }
            }
            return Resolved(font: systemFont(size: size, design: .rounded), isFallback: true)
        }
    }

    /// Whether `family` is available as itself, for Settings (T9).
    static func isInstalled(_ family: PrompterFontFamily) -> Bool {
        !resolve(family: family, size: PrompterFontSize.lg.points).isFallback
    }
}

/// Widths from CoreText, which is safe to call from any thread, so a big page
/// is measured on the background task that lays it out. Tracking is measured
/// as it is drawn (`Theme.tracking(forSize:)`, applied with `.tracking` in
/// the view), or every line would run a little long.
struct CoreTextMeasurer: PromptTextMeasuring, @unchecked Sendable {
    // `@unchecked`: a `CTFont` is immutable and documented thread-safe; the
    // compiler only cannot see that through the CF type.
    private let font: CTFont
    private let tracking: Double
    let metrics: PromptFontMetrics
    let fontName: String

    init(font: NSFont, tracking: Double) {
        self.font = font as CTFont
        self.tracking = tracking
        metrics = PromptFontMetrics(
            pointSize: Double(font.pointSize), ascender: Double(font.ascender),
            descender: Double(font.descender), leading: Double(font.leading)
        )
        fontName = font.fontName
    }

    func width(of text: String) -> Double {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTTrackingAttributeName as String): tracking,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        return CTLineGetTypographicBounds(line, nil, nil, nil)
    }
}

// MARK: - The stage's model

/// The stage's state that has to outlive a view: the layout cache, the page's
/// offset and the hand on the wheel. One per `NotchViewModel`, made while the
/// switch is on (`attachPrompter`) and never shared, so a rebuilt panel has
/// its own cache and the cache is never another view's (spec 10.2).
///
/// It reads the session and the settings and writes to the session only the
/// way a person would: a jump for a tapped word or a finished scroll, a
/// pause and resume around a scroll (8.5). Stop is never its business: the
/// stage's Stop goes through `NotchViewModel.stopPrompter()`.
@MainActor
final class PrompterStageModel: ObservableObject {
    /// Runs one layout and hands it back. The live one is a detached task;
    /// a test runs inline.
    typealias Runner = @Sendable (@escaping @Sendable () -> PromptLayout) async -> PromptLayout
    typealias MeasurerFactory = @MainActor (PrompterTypeface) -> any PromptTextMeasuring

    nonisolated static let inlineRunner: Runner = { work in work() }
    nonisolated static let backgroundRunner: Runner = { work in await PrompterBackground.run(work) }

    nonisolated static func liveMeasurer(_ typeface: PrompterTypeface) -> any PromptTextMeasuring {
        CoreTextMeasurer(
            font: PrompterFontResolver.resolve(family: typeface.family, size: typeface.size).font,
            tracking: Theme.tracking(forSize: CGFloat(typeface.size))
        )
    }

    /// Up to this many words a page is laid out at once, where it is asked
    /// for: 1.8 ms with CoreText in a debug build, well under a frame (see
    /// `PrompterStagePerformanceTests`). Past it, the first screenful is laid
    /// out at once and the rest on a background task (E-26).
    static let synchronousWordLimit = 2_000
    /// A wheel that has been still this long has stopped (8.5). Long enough to
    /// bridge the gap between a trackpad's fingers lifting and its momentum
    /// starting; short enough that reading picks up again as the eye settles.
    static let wheelSettleDelay: TimeInterval = 0.25

    @Published private(set) var layout: PromptLayout?
    /// Changes with every layout installed, so the lines view can compare
    /// layouts by a number rather than by a hundred thousand positions.
    private(set) var layoutStamp = 0
    /// What the view draws the page at, and how it should get there.
    @Published private(set) var offset: Double = 0
    @Published private(set) var motion: PrompterStageMotion = .cut

    private(set) var viewport: CGSize = .zero
    private(set) var planner = PromptScrollPlanner()
    var cachedLayoutCount: Int { cache.count }

    let session: PrompterSession
    let settings: PrompterSettings
    /// What a state change is said through. The announcer by default.
    var announce: @MainActor (String) -> Void = { Announcer.shared.announce($0) }

    private let scheduler: PrompterScheduling
    private let measurerFactory: MeasurerFactory
    private let runner: Runner

    private var cache = PromptLayoutCache(capacity: 4)
    private var measurer: (typeface: PrompterTypeface, value: any PromptTextMeasuring)?
    private var resolvedFont: (typeface: PrompterTypeface, font: NSFont)?
    private var layoutKey: PromptStageLayoutKey?
    /// Bumped for every layout asked for; a background result for an older
    /// one is dropped (a resize mid-layout, a page turned, a Stop).
    private var layoutGeneration = 0
    private(set) var layoutTask: Task<Void, Never>?
    private var anchoredPlacement: PrompterReadingPosition?
    private var anchoredHeight: CGFloat = 0
    /// The motion the next accepted target moves with, when something other
    /// than the clock moved it (a tap, a scroll's settle).
    private var pendingMotion: PrompterStageMotion?

    private var wheelSettle: PrompterCancellable?
    private var wheelSerial = 0
    /// The scroll paused the clock and owes it a resume.
    private var wheelPaused = false
    /// A scroll's own pause and resume are not news.
    private var quiet = false
    private var links = Set<AnyCancellable>()

    init(
        session: PrompterSession,
        settings: PrompterSettings,
        scheduler: PrompterScheduling = MainQueuePrompterScheduler(),
        measurerFactory: @escaping MeasurerFactory = { PrompterStageModel.liveMeasurer($0) },
        runner: @escaping Runner = PrompterStageModel.backgroundRunner
    ) {
        self.session = session
        self.settings = settings
        self.scheduler = scheduler
        self.measurerFactory = measurerFactory
        self.runner = runner

        // `@Published` sends before the property changes, so each sink is
        // handed the new value and reads the rest of the session as it stands.
        // `progress` is the last thing a page load sets, so by the time it
        // arrives the session's `script` is already the new page.
        session.$progress
            .sink { [weak self] progress in self?.refresh(progress: progress) }
            .store(in: &links)
        session.$state
            .sink { [weak self] state in self?.stateWillChange(to: state) }
            .store(in: &links)
        // A lock or sleep during a scroll, including one that lands on the
        // scroll's own user pause and so changes no state, ends the scroll
        // without giving the clock back (ruling 20.6 #2).
        session.$isPausedBySystem
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in self?.abandonWheel() }
            .store(in: &links)
        settings.didChange
            .sink { [weak self] _ in
                guard let self else { return }
                self.refresh(progress: self.session.progress)
            }
            .store(in: &links)
    }

    // MARK: Inputs from the view

    /// The text region's size. A new width can be a new column (a new
    /// layout); a new height moves the guide. Both re-anchor by the reading
    /// offset, never by pixel (10.6, E-28, E-38).
    func setViewport(_ size: CGSize) {
        guard size != viewport, size.width.isFinite, size.height.isFinite else { return }
        viewport = size
        refresh(progress: session.progress)
    }

    /// A tap on a word: reading jumps there and the page may move back to it
    /// (8.5: a jump arms exactly one backward update).
    func tapWord(_ index: Int) {
        guard session.state.isLive, let script = session.script, script.words.indices.contains(index) else { return }
        planner.armBackward()
        pendingMotion = .manual
        session.jump(toOffset: script.words[index].range.lowerBound)
    }

    /// A wheel or trackpad delta, in points (positive moves the page down, to
    /// earlier text). `final` when the system says the gesture is over; a
    /// wheel that simply stops is over after `wheelSettleDelay`.
    ///
    /// Spec 8.5 for Classic: only while running; the clock pauses while the
    /// hand is on the page and resumes from the line under the guide when it
    /// lets go.
    func wheel(deltaY: Double, final: Bool) {
        guard deltaY.isFinite, let geometry = geometry() else { return }
        if !planner.isManual {
            guard deltaY != 0, session.state == .running else { return }
            quiet = true
            session.pause(.user)
            quiet = false
            wheelPaused = session.state == .paused(.user)
            planner.beginManual()
        }
        planner.scroll(by: deltaY, within: geometry.manualRange)
        publish(.manual)
        wheelSerial &+= 1
        wheelSettle?.cancel()
        wheelSettle = nil
        if final {
            endWheel()
        } else {
            let serial = wheelSerial
            wheelSettle = scheduler.after(Self.wheelSettleDelay) { [weak self] in
                guard let self, self.wheelSerial == serial else { return }
                self.endWheel()
            }
        }
    }

    /// The model is being let go: a display change rebuilt the panel, or the
    /// switch handed its parts to a new model (`NotchViewModel.attachPrompter`).
    /// A scroll still in progress owed the clock a resume that its settle,
    /// which holds the model weakly, would never deliver once the model was
    /// gone: the session sat in a user pause the speaker had not asked for,
    /// and the new stage had no hand on the wheel to give it back. It is
    /// handed back here, as the wheel stopping would have, unless the system
    /// paused the session meanwhile (ruling 20.6 #2).
    func relinquish() {
        let owed = wheelPaused
        abandonWheel()
        guard owed, session.state == .paused(.user), !session.isPausedBySystem else { return }
        quiet = true
        session.resume()
        quiet = false
    }

    /// For a test: the background layout in flight, if any, has landed.
    func layoutSettled() async {
        await layoutTask?.value
    }

    // MARK: Reading

    /// The face the words are drawn in: the one they were measured in, made
    /// once per setting rather than on every 20 Hz redraw, so the lines view
    /// sees the same font from frame to frame and is not rebuilt for it.
    func displayFont(for typeface: PrompterTypeface) -> NSFont {
        if let resolvedFont, resolvedFont.typeface == typeface { return resolvedFont.font }
        let font = PrompterFontResolver.resolve(family: typeface.family, size: typeface.size).font
        resolvedFont = (typeface, font)
        return font
    }

    /// What VoiceOver hears for the page (15).
    var accessibilityValue: String {
        PrompterStageSpeech.accessibilityValue(script: session.script, layout: layout, progress: session.progress)
    }

    func geometry() -> PromptScrollGeometry? {
        guard let layout, viewport.height > 0 else { return nil }
        return PromptScrollGeometry(
            layout: layout, viewport: Double(viewport.height), placement: settings.values.readingPosition
        )
    }

    // MARK: Private

    private func stateWillChange(to new: PrompterSessionState) {
        let old = session.state
        if !quiet, let sentence = PrompterStageSpeech.announcement(from: old, to: new, hasNextPage: session.hasNextPage) {
            announce(sentence)
        }
        if new == .ended || new == .idle {
            tearDown()
        } else if new.isLive, !old.isLive {
            // A start: the page loaded (and sent its progress) while the
            // session was not yet live, so it is laid out now.
            refresh(progress: session.progress, live: true)
        }
    }

    /// Everything a run left: the layout (a big page's is megabytes), the
    /// cache, the offset, a scroll's pending settle and a layout in flight.
    private func tearDown() {
        layoutGeneration &+= 1
        layoutTask?.cancel()
        layoutTask = nil
        wheelSettle?.cancel()
        wheelSettle = nil
        wheelSerial &+= 1
        wheelPaused = false
        cache.removeAll()
        layoutKey = nil
        layoutStamp &+= 1
        layout = nil
        planner = PromptScrollPlanner()
        anchoredPlacement = nil
        pendingMotion = nil
        motion = .cut
        offset = 0
    }

    private func currentMeasurer(for typeface: PrompterTypeface) -> any PromptTextMeasuring {
        if let measurer, measurer.typeface == typeface { return measurer.value }
        let value = measurerFactory(typeface)
        measurer = (typeface, value)
        return value
    }

    /// Re-derives the page's offset from the reading progress, laying the
    /// page out first when the layout's key changed.
    private func refresh(progress: Double, live: Bool? = nil) {
        guard live ?? session.state.isLive, let script = session.script,
              viewport.width > 0, viewport.height > 0 else { return }
        let values = settings.values
        let typeface = PrompterTypeface(family: values.fontFamily, size: values.fontSize.points)
        let measurer = currentMeasurer(for: typeface)
        let column = PrompterStageMetrics.columnWidth(setting: values.columnWidth, bodyWidth: Double(viewport.width))
        let key = PromptStageLayoutKey(
            script: script, fontName: measurer.fontName, pointSize: typeface.size,
            columnWidth: column, dividers: values.paragraphDividers
        )
        if key != layoutKey {
            requestLayout(key, script: script, measurer: measurer, column: column,
                          dividers: values.paragraphDividers, progress: progress)
            return
        }
        guard let geometry = geometry() else { return }
        let target = geometry.offset(forProgress: progress, in: script, interpolates: session.mode.isTimerMode)
        if anchoredPlacement != values.readingPosition {
            anchoredPlacement = values.readingPosition
            planner.reanchor(target)
            publish(.readingPosition)
            return
        }
        if anchoredHeight != viewport.height {
            anchoredHeight = viewport.height
            planner.reanchor(target)
            publish(.cut)
            return
        }
        let motion = pendingMotion ?? (session.mode.isTimerMode ? .timer : .follow)
        if planner.follow(target) {
            pendingMotion = nil
            publish(motion)
        }
    }

    private func requestLayout(
        _ key: PromptStageLayoutKey, script: PromptScript, measurer: any PromptTextMeasuring,
        column: Double, dividers: Bool, progress: Double
    ) {
        layoutKey = key
        layoutGeneration &+= 1
        layoutTask?.cancel()
        layoutTask = nil

        if let cached = cache.layout(for: key) {
            install(cached, script: script, progress: progress)
            return
        }
        if script.words.count <= Self.synchronousWordLimit {
            let full = PromptFlowLayout.layout(script, measurer: measurer, columnWidth: column, dividers: dividers)
            cache.insert(full, for: key)
            install(full, script: script, progress: progress)
            return
        }

        // A big page: its first screenful now, so Start is not a blank stage,
        // and the whole of it on a background task (E-26). The first lines
        // of a layout do not depend on what follows them, so the screenful is
        // exactly the top of the full layout and swapping it for the full one
        // moves nothing.
        let prefix = PromptFlowLayout.layout(
            script, measurer: measurer, columnWidth: column, dividers: dividers,
            stopBelow: Double(viewport.height) + 2 * PrompterStageMetrics.cullBuffer
        )
        if Int(max(0, progress)) < prefix.lineOfWord.count {
            install(prefix, script: script, progress: progress)
        } else {
            // Reading stands past the screenful (a resume deep in the page):
            // nothing rather than the wrong lines, for the moment it takes.
            layoutStamp &+= 1
            layout = nil
        }
        let generation = layoutGeneration
        let runner = self.runner
        layoutTask = Task { [weak self] in
            let full = await runner {
                PromptFlowLayout.layout(script, measurer: measurer, columnWidth: column, dividers: dividers)
            }
            guard let self, generation == self.layoutGeneration, !Task.isCancelled else { return }
            self.layoutTask = nil
            self.cache.insert(full, for: key)
            self.install(full, script: script, progress: self.session.progress)
        }
    }

    private func install(_ layout: PromptLayout, script: PromptScript, progress: Double) {
        layoutStamp &+= 1
        self.layout = layout
        anchoredPlacement = settings.values.readingPosition
        anchoredHeight = viewport.height
        pendingMotion = nil
        guard let geometry = geometry() else { return }
        planner.reanchor(geometry.offset(forProgress: progress, in: script, interpolates: session.mode.isTimerMode))
        publish(.cut)
    }

    private func publish(_ motion: PrompterStageMotion) {
        if self.motion != motion { self.motion = motion }
        if offset != planner.displayed { offset = planner.displayed }
    }

    /// The hand let go: settle inside the page, find the line under the guide,
    /// read on from its first word, and give the clock back (8.5). A reader
    /// who came back to the line being read carries on from where they were,
    /// rather than being sent to the start of that line.
    private func endWheel() {
        wheelSettle?.cancel()
        wheelSettle = nil
        guard planner.isManual else { return }
        defer { wheelPaused = false }
        guard let geometry = geometry(), let script = session.script else {
            planner = PromptScrollPlanner()
            return
        }
        let layout = geometry.layout
        let settled = planner.endManual(within: geometry.manualRange)
        publish(.manual)
        planner.armBackward()
        pendingMotion = .manual
        let current = PromptWordStates.currentWord(in: script, progress: session.progress)
        if let line = geometry.lineAtGuide(offset: settled),
           line != current.flatMap(layout.lineIndex(ofWord:)),
           let first = layout.items[layout.lines[line].items].first {
            session.jump(toOffset: script.words[first.word].range.lowerBound)
        } else {
            refresh(progress: session.progress)
        }
        // Never over a lock or sleep that came after the scroll began: the
        // pause is then the system's as well, and only the speaker resumes it
        // (11.3). `abandonWheel` has normally cleared `wheelPaused` by now;
        // this is the second defence, read at the moment of resuming.
        if wheelPaused, session.state == .paused(.user), !session.isPausedBySystem {
            quiet = true
            session.resume()
            quiet = false
        }
    }

    /// A lock or sleep arrived mid-scroll. The settle is called off and the
    /// scroll's pause is no longer the wheel's to give back. The page settles
    /// where the hand left it, without a jump: the reading position stays
    /// where the clock stopped, and the one backward move armed here lets the
    /// page return to it on the speaker's resume.
    private func abandonWheel() {
        wheelSettle?.cancel()
        wheelSettle = nil
        wheelSerial &+= 1
        wheelPaused = false
        guard planner.isManual else { return }
        if let geometry = geometry() {
            planner.endManual(within: geometry.manualRange)
            planner.armBackward()
            pendingMotion = .manual
            publish(.manual)
        } else {
            planner = PromptScrollPlanner()
        }
    }
}
