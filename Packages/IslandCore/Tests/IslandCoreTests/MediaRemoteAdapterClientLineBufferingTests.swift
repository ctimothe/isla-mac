import Foundation
import Testing
@testable import IslandCore

// Covers the one MediaRemoteAdapterClient path testable without a real
// perl/mediaremote-adapter subprocess: graceful degradation (locked decision #4)
// when the vendored adapter resources aren't present in the bundle. The actual
// subprocess-spawning + streaming path needs the real vendored framework and a
// real playing track — out of unit-test scope per the implementation plan
// (manual QA, section 5).
struct MediaRemoteAdapterClientLineBufferingTests {
    @Test func streamFinishesWithNoValuesWhenAdapterResourcesAreMissing() async {
        let client = MediaRemoteAdapterClient(bundle: .main)
        await client.start()

        var received: [NowPlayingInfo] = []
        for await info in await client.stream {
            received.append(info)
        }

        #expect(received.isEmpty)
    }
}
