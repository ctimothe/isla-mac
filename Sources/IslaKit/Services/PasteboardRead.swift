import AppKit
import OSLog

/// Reads bytes from a pasteboard off the main actor, and the rule that makes
/// that safe.
///
/// A Retina screenshot is 10–21 MB, and the first read of a copy from an app
/// that renders its picture on request measured 26–38 ms on the main actor
/// (spec §19.12); the panel, the pointer sampler and every animation wait for
/// it there. A read on `queue` costs the main actor nothing.
///
/// **What Apple documents, and what it does not.** `NSPasteboard`'s reference
/// says nothing about threads, and AppKit's thread-safety notes name `NSView`
/// and `NSCell`, not the pasteboard. Its Carbon sibling, `PasteboardRef`, is
/// documented "Not thread safe". There is no documented asynchronous read
/// either: `NSItemProvider` does not adopt `NSPasteboardReading`, and a
/// screenshot's pasteboard carries no file URL to read instead. So this was
/// measured rather than assumed, on a named pasteboard with one queue reading
/// 16 MB TIFFs in a loop while the main thread called into the same object,
/// six seconds a run:
///
/// - `changeCount` and `accessBehavior`: about a million calls a run, and
///   nothing went wrong, with the board still and with another process
///   rewriting it every 50 ms.
/// - `types`, `availableType(from:)` and `string(forType:)`: AppKit crashed
///   (`-[NSPasteboard _updateTypeCacheIfNeeded]`) whenever the type cache was
///   stale for both threads at once, which is to say when a new copy had just
///   landed. Left alone on a still board they survived a million calls, so the
///   hazard is the rebuild of the cache, not the call.
///
/// Hence the rule: **while a read of a pasteboard is in flight, the main actor
/// asks that pasteboard for its `changeCount` and nothing else.** The clipboard
/// poll does not start work on it (`isReading`, and the tick that finds it
/// busy leaves the copy unspent for the next one); every other main-actor
/// call into the general pasteboard calls `settle` first, which waits for the
/// read to finish if one is running. Waiting is no worse than what the read
/// cost on the main actor before, and it is needed only in the milliseconds a
/// copy is being read. A read cannot hold it for long: Apple documents that
/// `data(forType:)` gives up and answers nil when the copying app is too slow.
///
/// **AppKit's own calls** — ⌘V in the Translate field, a menu validating Paste
/// — touch `NSPasteboard.general` on the main thread without asking, and cannot
/// be made to wait. They happen only while one of Isla's windows holds the
/// keyboard, so then the read stays on the main thread, as it always was
/// (`readsStayOnMain`). With no key window, which is where a screenshot being
/// pasted into another app leaves Isla, the bytes are read on the queue.
/// Off hardware this is argued, not measured; R8c-H8 is where it would show.
@MainActor
enum PasteboardRead {
    /// One serial queue for every read, so a slow one (a Continuity picture
    /// still arriving can hold `data(forType:)` for a while) delays the
    /// next instead of overlapping it.
    nonisolated private static let queue = DispatchQueue(label: "com.ctimothe.isla.pasteboard.read", qos: .userInitiated)
    nonisolated private static let signposter = OSSignposter(subsystem: Log.subsystem, category: "clipboard")

    /// Reads in flight, by pasteboard. Per object, not global: the hazard is
    /// two threads in one `NSPasteboard`, and a named pasteboard of a test is
    /// another object.
    private static var inFlight: [ObjectIdentifier: Int] = [:]

    /// Whether AppKit may be about to ask the pasteboard on the main thread
    /// by itself: one of Isla's windows has the keyboard (the Translate field,
    /// the Clipboard search). A seam, because a test has no such window.
    static var readsStayOnMain: () -> Bool = { NSApplication.shared.keyWindow != nil }

    /// Whether a read of this pasteboard is running right now.
    static func isReading(_ pasteboard: NSPasteboard) -> Bool {
        inFlight[ObjectIdentifier(pasteboard)] != nil
    }

    /// Call before any main-actor use of the pasteboard other than
    /// `changeCount`. Returns at once when nothing is reading; otherwise waits
    /// for the queue to drain, which is the read.
    static func settle(_ pasteboard: NSPasteboard) {
        if isReading(pasteboard) { queue.sync {} }
    }

    /// The general pasteboard, settled. Every main-actor reach for it outside
    /// the clipboard store goes through here (`PasteboardAccessContractTests`
    /// keeps it that way).
    static var general: NSPasteboard {
        settle(.general)
        return .general
    }

    /// `read` runs on the queue; `deliver` runs on the main actor with what it
    /// found, after the read is no longer counted as in flight.
    static func data(
        of type: NSPasteboard.PasteboardType,
        from pasteboard: NSPasteboard,
        using read: @escaping @Sendable (NSPasteboard, NSPasteboard.PasteboardType) -> Data?,
        then deliver: @escaping (Data?) -> Void
    ) {
        if readsStayOnMain() {
            deliver(read(pasteboard, type))
            return
        }
        let key = ObjectIdentifier(pasteboard)
        inFlight[key, default: 0] += 1
        let queued = QueuedRead(pasteboard: pasteboard, read: read)
        queue.async {
            let signposter = Self.signposter
            let interval = signposter.beginInterval("pasteboard read", id: signposter.makeSignpostID())
            let data = autoreleasepool { queued.read(queued.pasteboard, type) }
            signposter.endInterval("pasteboard read", interval, "\(data?.count ?? 0, privacy: .public) bytes")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Held until the count is settled: a freed pasteboard's
                    // address could otherwise be reused by another.
                    withExtendedLifetime(queued) {}
                    if let count = inFlight[key], count > 1 { inFlight[key] = count - 1 } else { inFlight[key] = nil }
                    deliver(data)
                }
            }
        }
    }
}

/// The pasteboard and the closure that reads it, carried to the queue. Neither
/// is `Sendable`; the rule above is what makes handing them over sound.
private struct QueuedRead: @unchecked Sendable {
    let pasteboard: NSPasteboard
    let read: @Sendable (NSPasteboard, NSPasteboard.PasteboardType) -> Data?
}
