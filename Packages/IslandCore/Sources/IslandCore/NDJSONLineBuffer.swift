import Foundation

/// Reassembles newline-delimited JSON from arbitrarily-fragmented `Data` chunks.
/// A single `Pipe` read can split one line across two `availableData` calls;
/// this accumulates bytes until a newline is seen before yielding a complete line.
public struct NDJSONLineBuffer {
    private var pending = Data()

    public init() {}

    public mutating func append(_ chunk: Data) -> [Data] {
        pending.append(chunk)

        var lines: [Data] = []
        while let newlineRange = pending.firstRange(of: Data([0x0A])) {
            let line = pending[pending.startIndex..<newlineRange.lowerBound]
            pending.removeSubrange(pending.startIndex..<newlineRange.upperBound)
            if !line.isEmpty {
                lines.append(Data(line))
            }
        }
        return lines
    }
}
