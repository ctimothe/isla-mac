import AppKit
import OSLog

/// Reads bytes from a pasteboard off the main actor, and the rule that makes
/// that safe.
///
/// A Retina screenshot is 10–21 MB, and the first read of a copy from an app
/// that renders its picture on request measured 26–29 ms on the main actor
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
/// - `changeCount`: about 1.4 million calls over 340,000 reads in two runs,
///   and nothing went wrong.
/// - `types`: both runs ended in an `NSInvalidArgumentException` thrown out of
///   `-[NSPasteboard _updateTypeCacheIfNeeded]`. The type cache is rebuilt
///   and enumerated by both calls.
///
/// Hence the rule: **while a read of a pasteboard is in flight, the main actor
/// asks that pasteboard for its `changeCount` and nothing else.** The clipboard
/// poll does not start work on it (`isReading`, and the tick that finds it
/// busy leaves the copy unspent for the next one); every other main-actor
/// call into the general pasteboard calls `settle` first, which waits for the
/// read to finish if one is running. Waiting is no worse than what the read
/// cost on the main actor before, and it is needed only when a copy lands in
/// the milliseconds a copy is being read.
///
/// What this cannot cover is AppKit's own calls on the main thread — a ⌘V in
/// the Translate field, a menu validating Paste — which touch
/// `NSPasteboard.general` without asking. The window is the read itself, and
/// the type cache for that copy should already be built by then (the poll
/// asked for `types` before it started the read), where the stress above
/// rewrote the board continuously; that is an inference, not a measurement,
/// and it is recorded in `checklist.md` rather than hidden.
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
