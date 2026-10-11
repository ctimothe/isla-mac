import AppKit
import Foundation
import XCTest
@testable import IslaKit

// Fakes shared by the stage's tests (plan T8). Nothing here reaches a font, a
// real timer, `UserDefaults.standard`, Application Support or the live app:
// widths come from a fixed table, time moves only when a test moves it, and
// the library writes to memory.

/// Every character `characterWidth` points wide, a space `spaceWidth`. A
/// layout computed with it is exact arithmetic, so a test can say where a
/// line breaks without a font installed.
struct FixedWidthMeasurer: PromptTextMeasuring {
    var characterWidth: Double = 10
    var spaceWidth: Double = 5
    var metrics = PromptFontMetrics(pointSize: 20, ascender: 16, descender: -4, leading: 0)
    /// Called for every measurement, with whether it ran on the main thread:
    /// the performance test's proof that a big page is measured elsewhere.
    var onMeasure: (@Sendable (Bool) -> Void)?

    func width(of text: String) -> Double {
        onMeasure?(Thread.isMainThread)
        if text == " " { return spaceWidth }
        return Double(text.count) * characterWidth
    }
}

/// Counts what it is told, from any thread.
final class ThreadLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var main = 0
    private var other = 0

    func record(onMain: Bool) {
        lock.lock()
        if onMain { main += 1 } else { other += 1 }
        lock.unlock()
    }

    var counts: (main: Int, other: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (main, other)
    }
}

@MainActor
final class StageTime {
    var now: TimeInterval = 2_000
}

/// Fires only when a test advances time. Cancelled entries stay listed so a
/// test can see that nothing was left armed.
@MainActor
final class StageScheduler: PrompterScheduling {
    final class Entry: PrompterCancellable {
        let interval: TimeInterval?
        var due: TimeInterval
        let action: @MainActor () -> Void
        private(set) var isCancelled = false

        init(interval: TimeInterval?, due: TimeInterval, action: @escaping @MainActor () -> Void) {
            self.interval = interval
            self.due = due
            self.action = action
        }

        func cancel() { isCancelled = true }
    }

    let time: StageTime
    private(set) var entries: [Entry] = []

    init(time: StageTime) { self.time = time }

    var live: [Entry] { entries.filter { !$0.isCancelled } }

    func every(_ interval: TimeInterval, _ action: @escaping @Sendable @MainActor () -> Void) -> PrompterCancellable {
        let entry = Entry(interval: interval, due: time.now + interval, action: action)
        entries.append(entry)
        return entry
    }

    func after(_ delay: TimeInterval, _ action: @escaping @Sendable @MainActor () -> Void) -> PrompterCancellable {
        let entry = Entry(interval: nil, due: time.now + max(0, delay), action: action)
        entries.append(entry)
        return entry
    }

    func advance(by dt: TimeInterval) {
        let target = time.now + dt
        while let entry = live.filter({ $0.due <= target + 1e-9 }).min(by: { $0.due < $1.due }) {
            time.now = max(time.now, entry.due)
            if let interval = entry.interval { entry.due += interval } else { entry.cancel() }
            entry.action()
        }
        time.now = target
    }
}

@MainActor
final class StageLease: PrompterKeepAwake {
    private(set) var held = false
    func begin() { held = true }
    func end() { held = false }
}

/// An empty library that keeps what it is given in memory.
final class StageFileIO: PrompterFileIO {
    func exists() -> Bool { false }
    func read() throws -> Data { throw CocoaError(.fileReadNoSuchFile) }
    func writeAtomically(_ data: Data) throws {}
    func copyAside(as name: String) throws -> String { name }
}

/// A session on fake time, with the parts a stage reads.
@MainActor
final class StageRig {
    let time = StageTime()
    lazy var scheduler = StageScheduler(time: time)
    let lease = StageLease()
    let defaults = InMemoryDefaults()
    lazy var settings = PrompterSettings(defaults: defaults)
    lazy var session = PrompterSession(now: { [unowned self] in self.time.now }, scheduler: scheduler, keepAwake: lease)

    /// A stage model that lays out with `measurer` and runs its background
    /// work through `runner` (inline by default, so a test is synchronous).
    func stage(
        measurer: FixedWidthMeasurer = FixedWidthMeasurer(),
        runner: PrompterStageModel.Runner? = nil
    ) -> PrompterStageModel {
        PrompterStageModel(
            session: session,
            settings: settings,
            scheduler: scheduler,
            measurerFactory: { _ in measurer },
            runner: runner ?? PrompterStageModel.inlineRunner
        )
    }

    /// Runs the clock for `seconds` in 50 ms ticks.
    func read(for seconds: TimeInterval) {
        let ticks = Int((seconds / PromptClock.tickInterval).rounded())
        for _ in 0..<ticks { scheduler.advance(by: PromptClock.tickInterval) }
    }
}

/// `count` words of one to seven letters, in prose-like rhythm, with a cue
/// and a dash every so often and a blank line now and then.
func promptFixturePage(words count: Int) -> String {
    let lexicon = ["the", "speaker", "reads", "a", "line", "slowly", "toward", "camera", "and", "pauses", "here", "now"]
    var parts: [String] = []
    parts.reserveCapacity(count)
    for index in 0..<count {
        if index % 97 == 50 {
            parts.append("[smile]")
        } else if index % 131 == 70 {
            parts.append("--")
        } else {
            parts.append(lexicon[(index * 7 + index / 3) % lexicon.count])
        }
        if index % 400 == 399 { parts.append("\n\n") }
    }
    return parts.joined(separator: " ")
}
