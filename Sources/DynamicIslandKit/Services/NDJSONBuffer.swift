import Foundation

struct NDJSONBuffer {
    private var pending = Data()
    private let maximumPendingBytes: Int
    /// True while the remainder of an over-long record is being thrown away.
    ///
    /// Dropping the buffered prefix alone left the *tail* of that record still
    /// arriving, and the next newline then handed that mid-record fragment out
    /// as if it were a line — garbage the decoder silently discarded, taking
    /// the following real snapshot's place in the process. Skipping to the next
    /// newline is what resynchronizes the stream.
    private var resyncing = false

    /// Raised when a record was too large to assemble, so the caller can ask
    /// for a fresh one rather than wait out a track it will never be told
    /// about. Artwork is the only field that ever gets near the limit, and the
    /// helper does not re-send it on its own.
    var onOversizedRecord: (() -> Void)?

    /// Large enough for the biggest artwork the decoder will accept, with room
    /// for the rest of the record around it. It used to sit *below* that
    /// ceiling, so any cover above roughly 3 MB destroyed the whole snapshot —
    /// title included — and the helper, having already marked that artwork as
    /// sent, never offered it again: the track showed a skeleton for its entire
    /// duration.
    init(maximumPendingBytes: Int = 12_000_000) {
        self.maximumPendingBytes = maximumPendingBytes
    }

    mutating func append(_ chunk: Data) -> [Data] {
        pending.append(chunk)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = Data(pending[..<newline])
            pending = Data(pending[pending.index(after: newline)...])
            if resyncing {
                // That newline ended the record being discarded; the stream is
                // aligned again from here.
                resyncing = false
                continue
            }
            if !line.isEmpty { lines.append(line) }
        }
        if pending.count > maximumPendingBytes {
            pending.removeAll()
            if !resyncing {
                resyncing = true
                NSLog("Dynamic Island: dropped an oversized now-playing record")
                // Deferred out of this mutating call. Invoked inline, a handler
                // that touched the buffer it was called from would trap on
                // overlapping exclusive access.
                let notify = onOversizedRecord
                DispatchQueue.main.async { notify?() }
            }
        }
        return lines
    }
}
