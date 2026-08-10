import Foundation
import Testing
@testable import IslandCore

// Pure, synchronous reassembly logic extracted out of MediaRemoteAdapterClient
// specifically so a Pipe read splitting a JSON line across two `availableData`
// calls (a real, documented risk per the implementation plan) can be tested
// without spawning a real subprocess.
struct NDJSONLineBufferTests {
    private func data(_ string: String) -> Data { Data(string.utf8) }

    @Test func yieldsOneCompleteLine() {
        var buffer = NDJSONLineBuffer()
        let lines = buffer.append(data("{\"a\":1}\n"))
        #expect(lines == [data("{\"a\":1}")])
    }

    @Test func yieldsNoLinesWhenChunkHasNoNewlineYet() {
        var buffer = NDJSONLineBuffer()
        let lines = buffer.append(data("{\"a\":1}"))
        #expect(lines.isEmpty)
    }

    @Test func reassemblesALineSplitAcrossTwoChunks() {
        var buffer = NDJSONLineBuffer()
        let firstResult = buffer.append(data("{\"a\":"))
        #expect(firstResult.isEmpty)

        let secondResult = buffer.append(data("1}\n"))
        #expect(secondResult == [data("{\"a\":1}")])
    }

    @Test func yieldsMultipleLinesFromOneChunkInOrder() {
        var buffer = NDJSONLineBuffer()
        let lines = buffer.append(data("{\"a\":1}\n{\"a\":2}\n"))
        #expect(lines == [data("{\"a\":1}"), data("{\"a\":2}")])
    }

    @Test func skipsEmptyLines() {
        var buffer = NDJSONLineBuffer()
        let lines = buffer.append(data("{\"a\":1}\n\n{\"a\":2}\n"))
        #expect(lines == [data("{\"a\":1}"), data("{\"a\":2}")])
    }
}
