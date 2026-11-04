import ServiceManagement
import SwiftUI
import XCTest
@testable import IslaKit

/// Settings never waits on the login-items daemon on the main thread more
/// than once a launch (speed, 2026-10-29).
///
/// `SMAppService.status` is a round trip to the daemon: 2.5 ms median and up
/// to 9 ms on a busy Mac, measured with the caller waiting. Settings asked it
/// twice, on the main thread, every time it was opened — in a `@State`
/// initial value as the pane was made, and again on appear — so a swap to
/// Settings began with 5 to 18 ms of waiting against a 8.3 ms frame. These
/// count the reads a stand-in login item sees, and where.
@MainActor
final class LaunchAtLoginReadTests: XCTestCase {
    /// A login item that counts who asks it, and on which thread.
    private final class CountingLoginItem: LoginItemService, @unchecked Sendable {
        private let lock = NSLock()
        private var current: SMAppService.Status
        private var mainReads = 0
        private var backgroundReads = 0

        init(_ status: SMAppService.Status) { current = status }

        var status: SMAppService.Status {
            lock.lock()
            defer { lock.unlock() }
            if Thread.isMainThread { mainReads += 1 } else { backgroundReads += 1 }
            return current
        }

        func change(to status: SMAppService.Status) {
            lock.lock()
            current = status
            lock.unlock()
        }

        var readsOnMain: Int { lock.lock(); defer { lock.unlock() }; return mainReads }
        var readsElsewhere: Int { lock.lock(); defer { lock.unlock() }; return backgroundReads }

        func register() throws { change(to: .enabled) }
        func unregister() throws { change(to: .notRegistered) }
    }

    override func setUp() async throws {
        LaunchAtLogin.forgetForTests()
    }

    override func tearDown() async throws {
        LaunchAtLogin.serviceOverride = nil
        LaunchAtLogin.forgetForTests()
    }

    private func settle(_ seconds: TimeInterval = 0.05) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Every arrival in Settings builds a new pane. The first of a launch may
    /// wait for one read; no later one waits at all.
    func testOpeningSettingsAsksTheDaemonOnTheMainThreadOnceALaunch() async {
        let item = CountingLoginItem(.notRegistered)
        LaunchAtLogin.serviceOverride = item
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        var hosts: [AXProbe.Host] = []
        for opening in 1...4 {
            hosts.append(AXProbe.present(SettingsFixture.pane(isolated, section: .general), size: SettingsFixture.paneSize()))
            await settle(0.1)
            XCTAssertLessThanOrEqual(item.readsOnMain, 1, "opening \(opening)")
        }
        XCTAssertGreaterThanOrEqual(item.readsElsewhere, 4, "each opening still reads, off the main thread")
        withExtendedLifetime(hosts) {}
    }

    /// The pane still follows a change made in System Settings: it reads again
    /// as it appears, off the main thread, and shows what it found.
    func testAppearingReadsAgainOffTheMainThreadAndShowsAChangeMadeOutside() async {
        let item = CountingLoginItem(.notRegistered)
        LaunchAtLogin.serviceOverride = item
        XCTAssertEqual(LaunchAtLogin.lastKnown(), .off)
        item.change(to: .enabled)
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let main = item.readsOnMain
        let root = await AXProbe.tree(of: SettingsFixture.pane(isolated, section: .general),
                                      size: SettingsFixture.paneSize(), settle: 0.4)
        XCTAssertEqual(item.readsOnMain, main, "the pane began from what was known")
        XCTAssertGreaterThanOrEqual(item.readsElsewhere, 1)
        XCTAssertEqual(LaunchAtLogin.lastKnown(), .on)
        let row = root.all(role: "AXCheckBox").first { $0.label == SettingsRowID.launchAtLogin.title }
        XCTAssertEqual(row?.value, "1", root.dump)
    }

    /// A read that set off before the switch was flipped lands after it, with
    /// the state from before the flip: it must not flip the switch back.
    func testAReadFromBeforeAFlipDoesNotUndoIt() async {
        let item = CountingLoginItem(.notRegistered)
        LaunchAtLogin.serviceOverride = item
        var delivered: [LaunchAtLogin.State] = []
        LaunchAtLogin.refresh { delivered.append($0) }
        XCTAssertEqual(LaunchAtLogin.apply(true), .on)
        await settle(0.3)
        XCTAssertEqual(delivered, [], "the stale read was dropped")
        XCTAssertEqual(LaunchAtLogin.lastKnown(), .on)

        LaunchAtLogin.refresh { delivered.append($0) }
        await settle(0.3)
        XCTAssertEqual(delivered, [.on], "a read after the flip still lands")
    }
}
