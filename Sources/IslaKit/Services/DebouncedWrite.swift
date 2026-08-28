import Foundation

/// Holds a write back until the typing stops.
///
/// Every store that keeps a file behind a text field needs the same thing: not
/// to touch the disk on each keystroke, and never to lose the last one. The
/// shape is always identical — cancel what was waiting, wait again, and run it
/// early if the app is going away — so it lives here instead of being copied
/// into the next store that grows a field.
///
/// The waiting write is kept as a closure rather than as data, which is what
/// lets a store schedule "whatever I hold right now" without this type knowing
/// anything about notes or scripts. Capture `self` weakly at the call site:
/// the closure outlives the moment it was made, and nothing here breaks a cycle
/// for you.
@MainActor
final class DebouncedWrite {
    /// Long enough to cover the gap between two words, short enough that a
    /// pause to think already commits what was written.
    private let delay: TimeInterval
    private var pending: DispatchWorkItem?
    private var write: (() -> Void)?

    init(after delay: TimeInterval = 0.8) {
        self.delay = delay
    }

    /// Replaces whatever was waiting. The newest closure wins, because it
    /// carries the newest state.
    func schedule(_ write: @escaping () -> Void) {
        pending?.cancel()
        self.write = write
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.run() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Runs the waiting write now, if there is one. Called when the app is
    /// quitting, where a delay is a lost sentence.
    func flush() {
        pending?.cancel()
        run()
    }

    /// Drops the waiting write without running it. For the one case where the
    /// change that armed it was not a change at all — a store loading its own
    /// file back through the same observer that watches for edits.
    func cancel() {
        pending?.cancel()
        pending = nil
        write = nil
    }

    private func run() {
        pending = nil
        let write = self.write
        self.write = nil
        write?()
    }
}
