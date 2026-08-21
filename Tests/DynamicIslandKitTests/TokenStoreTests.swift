import XCTest
@testable import DynamicIslandKit

/// The credential path, which had no coverage at all despite being the thing
/// that decides whether the app interrupts its user for a password.
final class TokenStoreTests: XCTestCase {
    private var root: URL!
    private var store: TokenStore!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        // A service name unique per run, so a test can never collide with a
        // real account or with another run on the same machine.
        store = TokenStore(
            service: "dev.dynamicisland.tests.\(UUID().uuidString)",
            paths: AppPaths(
                supportDirectory: root.appendingPathComponent("support"),
                screenshotDirectory: root.appendingPathComponent("pictures")
            )
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testRoundTripsThroughWhicheverBackingIsAvailable() {
        XCTAssertNil(store.read("refreshToken"), "nothing stored yet")
        let backing = store.write("refreshToken", "value-one")
        XCTAssertNotEqual(backing, .unavailable)
        XCTAssertEqual(store.read("refreshToken"), "value-one")

        // Overwriting replaces rather than appends.
        store.write("refreshToken", "value-two")
        XCTAssertEqual(store.read("refreshToken"), "value-two")

        store.delete("refreshToken")
        XCTAssertNil(store.read("refreshToken"))
    }

    func testAccountsDoNotBleedIntoEachOther() {
        store.write("accessToken", "access")
        store.write("refreshToken", "refresh")
        XCTAssertEqual(store.read("accessToken"), "access")
        XCTAssertEqual(store.read("refreshToken"), "refresh")

        store.delete("accessToken")
        XCTAssertNil(store.read("accessToken"))
        XCTAssertEqual(store.read("refreshToken"), "refresh", "deleting one must not take the other")
    }

    /// The file backing is what unsigned builds get, and its only protection is
    /// its mode. A regression here would hand every process on the machine a
    /// readable copy of somebody's token.
    func testFileBackingIsOwnerOnly() throws {
        // Force the file path: on a build entitled for the data-protection
        // keychain this test would otherwise assert nothing.
        guard store.write("refreshToken", "secret") == .file else {
            throw XCTSkip("this build stores credentials in the keychain")
        }
        let file = root
            .appendingPathComponent("support")
            .appendingPathComponent("spotify-credentials.json")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.int16Value, 0o600)
    }

    /// The probe that decides whether to offer "Import Account From Keychain…".
    /// It must answer without ever asking for the item's contents — asking is
    /// what raises the login-password prompt this whole design exists to avoid.
    func testLegacyProbeAnswersWithoutReadingContents() {
        // No item under this service, so the honest answer is false — and the
        // call has to return promptly rather than block on a dialog.
        let started = Date()
        XCTAssertFalse(store.legacyAccountExists("refreshToken"))
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 2,
            "an attributes-only query must not be waiting on a prompt"
        )
    }
}
