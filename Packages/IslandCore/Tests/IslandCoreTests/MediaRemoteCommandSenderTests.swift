import Testing
@testable import IslandCore

// Covers the one MediaRemoteCommandSender path testable without a real
// perl/mediaremote-adapter subprocess: it must not crash/throw when the
// vendored adapter resources aren't present in the bundle. The actual
// command-sending path needs the real vendored framework and a real player —
// out of unit-test scope (manual QA, per the plan).
struct MediaRemoteCommandSenderTests {
    @Test func sendDoesNotCrashWhenAdapterResourcesAreMissing() async {
        let sender = MediaRemoteCommandSender(bundle: .main)
        await sender.send(.play)
        // No crash/throw is the assertion; reaching this line is success.
    }
}
