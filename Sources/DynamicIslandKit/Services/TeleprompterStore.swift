import AppKit

/// The script, and where reading it has got to.
///
/// The notch is the one place on the screen where a teleprompter belongs: it
/// sits directly under the camera, so the eyes stay on the lens instead of
/// travelling to a window somewhere below it. Every other tab is here because
/// there is room; this one is here because of where the room is.
@MainActor
final class TeleprompterStore: ObservableObject {
    /// The text being read. Kept between launches — a script is written once
    /// and read several times, often over several takes.
    @Published var script: String = "" {
        didSet {
            guard script != oldValue else { return }
            // Rewriting the script mid-take would leave the scroll pointing at
            // a line that no longer exists.
            offset = 0
            scheduleSave()
        }
    }

    /// Points per second the text creeps upward at 1×. Slow: a comfortable
    /// reading pace is far slower than anyone guesses before trying it, and
    /// the speed control multiplies this.
    static let baseRate: CGFloat = 22

    /// Multiplier on `baseRate`. Adjustable mid-take, because the pace that
    /// felt right while setting up never survives the first paragraph.
    @Published var speed: Double = 1.0 {
        didSet {
            // Enforced here, not just at today's call sites (init's defaults
            // read, the Slider, the increment buttons): the model is the one
            // place every caller passes through.
            // `isFinite` first: `min`/`max` propagate NaN, so `clamped != speed`
            // was true for NaN (nothing equals NaN), the assignment re-entered
            // this observer with the same value, and the stack overflowed. A
            // NaN can reach here from a corrupt or hand-edited defaults plist.
            let clamped = speed.isFinite ? min(max(speed, 0.3), 3.0) : 1.0
            if clamped != speed {
                speed = clamped
                return
            }
            guard speed != oldValue else { return }
            defaults.set(speed, forKey: Self.speedKey)
        }
    }

    /// Point size of the script. What makes a teleprompter legible is type
    /// large enough to read at a glance, without focusing — the glance is all
    /// the attention available while talking to a camera.
    @Published var fontSize: Double = 30 {
        didSet {
            let clamped = fontSize.isFinite ? min(max(fontSize, 18), 64) : 30
            if clamped != fontSize {
                fontSize = clamped
                return
            }
            guard fontSize != oldValue else { return }
            defaults.set(fontSize, forKey: Self.fontKey)
        }
    }

    /// How far the text has scrolled, in points. Not persisted: a new session
    /// starts at the top, which is where a take starts.
    @Published var offset: CGFloat = 0
    @Published private(set) var isRunning = false

    /// Height of the text as laid out, set by the pane once it knows. Scrolling
    /// stops here rather than running the script off into empty space.
    var contentHeight: CGFloat = 0
    /// Height of the window the text scrolls through, also from the pane.
    var viewportHeight: CGFloat = 0

    private static let speedKey = "teleprompter.speed"
    private static let fontKey = "teleprompter.fontSize"
    private let defaults: UserDefaults
    private let fileURL: URL?

    /// True when the file exists but could not be read — wrong encoding, no
    /// permission, an I/O error. Writing is forbidden in that state.
    ///
    /// The script file is documented as one anybody can open in any editor,
    /// which means it can come back saved as UTF-16, or read-only, or on a
    /// volume that went away. Every one of those used to arrive as an empty
    /// string, and the first keystroke afterwards atomically replaced a script
    /// that was still perfectly intact on disk.
    @Published private(set) var fileBroken = false

    private var timer: Timer?
    private let saves = DebouncedWrite()

    init(
        fileURL: URL? = AppPaths.live.supportFile("teleprompter.txt"),
        defaults: UserDefaults = .standard
    ) {
        self.fileURL = fileURL
        self.defaults = defaults
        if let fileURL {
            do {
                script = try String(contentsOf: fileURL, encoding: .utf8)
            } catch {
                let nsError = error as NSError
                let missing = nsError.domain == NSCocoaErrorDomain
                    && (nsError.code == NSFileReadNoSuchFileError || nsError.code == NSFileNoSuchFileError)
                if !missing {
                    fileBroken = true
                    NSLog("Dynamic Island: teleprompter.txt is unreadable: \(error.localizedDescription)")
                }
            }
        } else {
            fileBroken = true
        }
        // Not because the read above armed a save — Swift does not run property
        // observers for assignments inside the defining type's own `init`, so
        // `script`'s `didSet` never fired here. Cancelling is belt and braces
        // for a store built while a previous one's write was still pending.
        saves.cancel()
        // Clamped inline, because — as above — the observers do not run for
        // these assignments either.
        if let stored = defaults.object(forKey: Self.speedKey) as? Double, stored.isFinite {
            speed = min(max(stored, 0.3), 3.0)
        }
        if let stored = defaults.object(forKey: Self.fontKey) as? Double, stored.isFinite {
            fontSize = min(max(stored, 18), 64)
        }
    }

    // MARK: - Running

    /// The furthest the text may scroll: the last line stops in the middle of
    /// the window rather than at the top edge, so it is still being read from
    /// the same place as every line before it.
    var maxOffset: CGFloat {
        max(0, contentHeight - viewportHeight / 2)
    }

    func toggle() { isRunning ? pause() : start() }

    func start() {
        guard !script.isEmpty, !isRunning else { return }
        if offset >= maxOffset { offset = 0 }
        isRunning = true
        // 60 Hz rather than a per-line jump: text that steps line by line is
        // read in lurches, and the eye loses the line it was on at every step.
        // The timer invalidates itself once the store is gone. A weak capture
        // alone only makes the tick a no-op: the run loop keeps the timer and
        // keeps firing it sixty times a second, with nothing left anywhere
        // holding a reference to invalidate it.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated { self.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func pause() {
        isRunning = false
        timer?.invalidate()
        timer = nil
    }

    func rewind() {
        pause()
        offset = 0
    }

    /// Stops the clock and leaves the position alone. For the panel closing or
    /// the tab changing, where the only thing that has to happen immediately is
    /// that the text stops moving — where it stopped is decided on the way back
    /// in, by the pane, which puts it at the top.
    func suspend() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    private func tick() {
        guard isRunning else { return }
        offset = min(maxOffset, offset + Self.baseRate * CGFloat(speed) / 60.0)
        if offset >= maxOffset { pause() }
    }

    // MARK: - Storage

    /// Plain text, not JSON. The script is written elsewhere and pasted here,
    /// and a file anyone can open in any editor is worth more than a format
    /// only this app reads.
    private func scheduleSave() {
        saves.schedule { [weak self] in self?.persist() }
    }

    func flush() { saves.flush() }

    private func persist() {
        guard !fileBroken, let fileURL else { return }
        do {
            try script.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            NSLog("Dynamic Island: cannot write teleprompter.txt: \(error.localizedDescription)")
        }
    }

    func reveal() {
        guard let fileURL else { return }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? "".write(to: fileURL, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }
}
