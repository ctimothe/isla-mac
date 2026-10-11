import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// What a clipboard full of text costs the main thread when ⌃⌥⌘T puts it in
/// the Translate field (J-017), uncapped and at `Translator.commandInputLimit`.
///
/// A bench, not a gate: timing depends on the machine and on what else it is
/// doing, so it runs only when asked — `ISLA_BENCH=1 swift test --filter
/// TranslateInputBench` — and prints its numbers rather than asserting a
/// ceiling a slow CI runner would trip over. The numbers that chose the limit
/// are in the commit that introduced it.
///
/// Two figures per size. *Set + layout* is the synchronous stall: the
/// assignment and the layout pass that has to finish before the panel can
/// draw again. *Main-thread CPU* is everything the main thread did in the
/// half second after — the text view's own deferred layout, the pane's
/// language detection and type-size fit, the translation it schedules — read
/// from the thread's CPU clock, so time spent idle in the run loop does not
/// count. Stores are isolated (`ProbeFixtures`): no engine is reachable and
/// nothing touches the owner's defaults or support folder.
@MainActor
final class TranslateInputBench: XCTestCase {
    func testTheCapBoundsTheStall() async throws {
        guard ProcessInfo.processInfo.environment["ISLA_BENCH"] == "1" else {
            throw XCTSkip("set ISLA_BENCH=1 to measure")
        }
        // A log, the realistic multi-megabyte clipboard: lines of words.
        let line = "2026-10-11 08:00:00.000 isla[4242:1337] translate: the quick brown fox jumps over it\n"
        let huge = String(repeating: line, count: 2_000_000 / line.utf8.count)
        let capped = try XCTUnwrap(Translator.prepareCommandInput(huge).text)

        // One sentence first and thrown away: whichever size went first paid
        // for loading the language recognizer and the font caches, which a
        // running app paid long ago. Then the capped text, so nothing the 2 MB
        // pane leaves running — its text view's deferred layout, its
        // translation — is billed to it.
        _ = await measure("Where is the nearest train station?")
        let cut = await measure(capped)
        let uncapped = await measure(huge)
        print(String(
            format: "TranslateInputBench: %d chars set+layout %.1f ms, main-thread CPU %.1f ms; "
                + "%d chars set+layout %.1f ms, main-thread CPU %.1f ms",
            huge.count, uncapped.wall, uncapped.cpu, capped.count, cut.wall, cut.cpu
        ))
    }

    private func measure(_ text: String) async -> (wall: Double, cpu: Double) {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let size = CGSize(width: 488, height: 154)
        let window = NSWindow(
            contentRect: NSRect(x: -40_000, y: -40_000, width: size.width, height: size.height),
            styleMask: [.borderless], backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: TranslatePane(
            translator: isolated.stores.translator,
            privacy: isolated.stores.privacy,
            wantsKeyboard: .constant(false)
        ).frame(width: size.width, height: size.height))
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        await Self.settle(0.3)

        let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let wallStart = DispatchTime.now().uptimeNanoseconds
        isolated.stores.translator.input = text
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        let wall = Double(DispatchTime.now().uptimeNanoseconds - wallStart) / 1e6
        // Past the pane's 320 ms debounce, so the translation it schedules
        // for this text is in the figure too.
        await Self.settle(0.5)
        hosting.layoutSubtreeIfNeeded()
        let cpu = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1e6
        window.contentView = nil
        return (wall, cpu)
    }

    private static func settle(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}
