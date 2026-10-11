import ServiceManagement
import XCTest
@testable import IslaKit

/// Launch at Login says what macOS decided (F-027).
///
/// The switch used to log any error and re-read `status == .enabled`, so a
/// Mac that wanted the user's approval in Login Items (`.requiresApproval`,
/// the usual answer on a fresh account) snapped the switch back to off with
/// no words, and every other failure was silent too.
@MainActor
final class LaunchAtLoginTests: XCTestCase {
    /// Stands in for `SMAppService.mainApp`: no test registers the real app.
    private final class FakeLoginItem: LoginItemService {
        var status: SMAppService.Status
        var statusAfterRegister: SMAppService.Status
        var statusAfterUnregister: SMAppService.Status = .notRegistered
        var failure: Error?

        init(status: SMAppService.Status, statusAfterRegister: SMAppService.Status = .enabled) {
            self.status = status
            self.statusAfterRegister = statusAfterRegister
        }

        func register() throws {
            status = statusAfterRegister
            if let failure { throw failure }
        }

        func unregister() throws {
            status = statusAfterUnregister
            if let failure { throw failure }
        }
    }

    private let refusal = NSError(
        domain: "SMAppServiceErrorDomain", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"]
    )

    func testStatusMapsToState() {
        XCTAssertEqual(LaunchAtLogin.state(status: .enabled, error: nil), .on)
        XCTAssertEqual(LaunchAtLogin.state(status: .notRegistered, error: nil), .off)
        XCTAssertEqual(LaunchAtLogin.state(status: .notFound, error: nil), .off)
        XCTAssertEqual(LaunchAtLogin.state(status: .requiresApproval, error: nil), .needsApproval)
        XCTAssertEqual(LaunchAtLogin.state(status: .notRegistered, error: refusal),
                       .failed(refusal.localizedDescription))
    }

    /// The registration stands and waits on the user, so the switch is on
    /// (pending) rather than off, and the row says where to go.
    func testRequiresApprovalStaysOnAndSaysWhy() {
        let service = FakeLoginItem(status: .notRegistered, statusAfterRegister: .requiresApproval)
        let state = LaunchAtLogin.set(true, service: service)

        XCTAssertEqual(state, .needsApproval)
        XCTAssertTrue(state.isOn, "pending approval reads as on, not snapped back to off")
        XCTAssertEqual(LaunchAtLogin.note(state), localized("Needs your approval in Login Items."))
        XCTAssertTrue(state.offersLoginItems)
    }

    /// Some versions of macOS throw from `register()` while leaving the
    /// service pending approval. The status is the truth: it is the same
    /// pending case, not a failure.
    func testApprovalWinsOverTheErrorThatCameWithIt() {
        let service = FakeLoginItem(status: .notRegistered, statusAfterRegister: .requiresApproval)
        service.failure = refusal

        XCTAssertEqual(LaunchAtLogin.set(true, service: service), .needsApproval)
    }

    func testOtherFailuresSayTheReasonInline() {
        let service = FakeLoginItem(status: .notRegistered, statusAfterRegister: .notRegistered)
        service.failure = refusal
        let state = LaunchAtLogin.set(true, service: service)

        XCTAssertEqual(state, .failed(refusal.localizedDescription))
        XCTAssertFalse(state.isOn)
        XCTAssertFalse(state.offersLoginItems)
        XCTAssertEqual(LaunchAtLogin.note(state),
                       localized("Launch at Login failed: %@", refusal.localizedDescription))
    }

    func testPlainOnAndOffSayNothing() {
        let service = FakeLoginItem(status: .notRegistered)
        let on = LaunchAtLogin.set(true, service: service)
        XCTAssertEqual(on, .on)
        XCTAssertNil(LaunchAtLogin.note(on))

        let off = LaunchAtLogin.set(false, service: service)
        XCTAssertEqual(off, .off)
        XCTAssertNil(LaunchAtLogin.note(off))
        XCTAssertFalse(off.offersLoginItems)
    }

    /// A turn-off that throws but still leaves the item unregistered did
    /// what was asked; it must not read "Launch at Login failed".
    func testTurnOffThatThrowsButLandsOffSaysNothing() {
        let service = FakeLoginItem(status: .enabled)
        service.failure = refusal
        let state = LaunchAtLogin.set(false, service: service)

        XCTAssertEqual(state, .off)
        XCTAssertNil(LaunchAtLogin.note(state))
    }

    /// Turning a pending registration off withdraws it, so the note goes.
    func testTurningOffAPendingRegistrationWithdrawsIt() {
        let service = FakeLoginItem(status: .requiresApproval)
        XCTAssertEqual(LaunchAtLogin.read(service), .needsApproval)
        XCTAssertEqual(LaunchAtLogin.set(false, service: service), .off)
    }
}
