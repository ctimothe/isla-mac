import Foundation

struct NDJSONBuffer {
    private var pending = Data()
    private let maximumPendingBytes: Int

    init(maximumPendingBytes: Int = 4_000_000) {
        self.maximumPendingBytes = maximumPendingBytes
    }

    mutating func append(_ chunk: Data) -> [Data] {
        pending.append(chunk)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = Data(pending[..<newline])
            pending = Data(pending[pending.index(after: newline)...])
            if !line.isEmpty { lines.append(line) }
        }
        if pending.count > maximumPendingBytes { pending.removeAll() }
        return lines
    }
}
