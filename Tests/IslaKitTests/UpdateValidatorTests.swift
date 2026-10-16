import Foundation
import XCTest
@testable import IslaKit

/// The check on the staged copy, the last thing standing between a signed disk
/// image and the app being replaced. Real tiny bundles, really code-signed.
@MainActor
final class UpdateValidatorTests: XCTestCase {
    private let page = URL(string: "https://github.com/ctimothe/isla-mac/releases/tag/v1.1")!

    private func validator(version: String = "1.0", build: String = "1") -> BundleUpdateValidator {
        BundleUpdateValidator(runningVersion: version, runningBuild: build)
    }

    private func release(_ version: String = "1.1") -> UpdateCheck.Release {
        UpdateCheck.Release(version: version, page: page)
    }

    private func result(_ app: URL, running: BundleUpdateValidator? = nil, release: UpdateCheck.Release? = nil) async -> UpdateValidationError? {
        do {
            try await (running ?? validator()).validate(app, release: release ?? self.release())
            return nil
        } catch {
            return error as? UpdateValidationError
        }
    }

    func testASignedNewerIslaPasses() async throws {
        let folder = try UpdateTestSupport.folder(self)
        let app = try UpdateTestSupport.tinyApp(in: folder, version: "1.1", build: "2")
        let outcome = await result(app)
        XCTAssertNil(outcome)
    }

    func testAnotherBundleIdentifierIsRefused() async throws {
        let folder = try UpdateTestSupport.folder(self)
        let app = try UpdateTestSupport.tinyApp(in: folder, bundleID: "com.example.notisla", version: "1.1", build: "2")
        let outcome = await result(app)
        XCTAssertEqual(outcome, .wrongIdentifier)
    }

    func testAVersionOtherThanTheAdvertisedOneIsRefused() async throws {
        let folder = try UpdateTestSupport.folder(self)
        let app = try UpdateTestSupport.tinyApp(in: folder, version: "1.2", build: "2")
        let outcome = await result(app)
        XCTAssertEqual(outcome, .wrongVersion, "the image holds 1.2, the release said 1.1")
    }

    func testTheSameVersionIsNotAnUpdate() async throws {
        let folder = try UpdateTestSupport.folder(self)
        let app = try UpdateTestSupport.tinyApp(in: folder, version: "1.0", build: "2")
        let outcome = await result(app, release: release("1.0"))
        XCTAssertEqual(outcome, .notNewer)
    }

    func testAnOlderVersionIsNotAnUpdate() async throws {
        let folder = try UpdateTestSupport.folder(self)
        let app = try UpdateTestSupport.tinyApp(in: folder, version: "0.9", build: "9")
        let outcome = await result(app, release: release("0.9"))
        XCTAssertEqual(outcome, .notNewer, "a downgrade is not an update, whatever its build says")
    }

    func testABuildThatIsNotGreaterIsRefused() async throws {
        let folder = try UpdateTestSupport.folder(self)
        for build in ["1", "0"] {
            let app = try UpdateTestSupport.tinyApp(in: folder, name: "B\(build).app", version: "1.1", build: build)
            let outcome = await result(app)
            XCTAssertEqual(outcome, .buildNotNewer, "build \(build) against a running 1")
        }
    }

    func testABuildThatIsNotANumberIsRefused() async throws {
        let folder = try UpdateTestSupport.folder(self)
        let app = try UpdateTestSupport.tinyApp(in: folder, version: "1.1", build: "two")
        let outcome = await result(app)
        XCTAssertEqual(outcome, .buildNotNewer)
    }

    func testAnUnsignedBundleIsRefused() async throws {
        let folder = try UpdateTestSupport.folder(self)
        let app = try UpdateTestSupport.tinyApp(in: folder, version: "1.1", build: "2", signing: .none)
        let outcome = await result(app)
        XCTAssertEqual(outcome, .signatureInvalid)
    }

    func testABundleChangedAfterSigningIsRefused() async throws {
        let folder = try UpdateTestSupport.folder(self)
        let app = try UpdateTestSupport.tinyApp(in: folder, version: "1.1", build: "2", marker: "signed")
        let passes = await result(app)
        XCTAssertNil(passes)
        try Data("changed".utf8).write(to: app.appendingPathComponent("Contents/Resources/marker.txt"))
        let outcome = await result(app)
        XCTAssertEqual(outcome, .signatureInvalid)
    }

    func testAFileThatIsNotABundleIsRefused() async throws {
        let folder = try UpdateTestSupport.folder(self)
        let empty = folder.appendingPathComponent("Isla.app", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let outcome = await result(empty)
        XCTAssertEqual(outcome, .unreadable)
        let missing = await result(folder.appendingPathComponent("Nope.app"))
        XCTAssertEqual(missing, .unreadable)
    }

    /// Sparkle's rule for certificate rotation: a new signing identity is fine,
    /// because the Ed25519 signature on the image is the gate. An ad-hoc build
    /// signed by a different run is a different identity and still passes.
    func testADifferentSigningIdentityIsAllowed() async throws {
        let folder = try UpdateTestSupport.folder(self)
        let app = try UpdateTestSupport.tinyApp(in: folder, version: "1.1", build: "2")
        let again = try UpdateTestSupport.tinyApp(in: folder, name: "Again.app", version: "1.1", build: "2", marker: "other")
        let first = await result(app)
        let second = await result(again)
        XCTAssertNil(first)
        XCTAssertNil(second)
    }

    // MARK: Identity continuity

    private func staticCode(_ app: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        XCTAssertEqual(SecStaticCodeCreateWithPath(app as CFURL, [], &code), errSecSuccess)
        return try XCTUnwrap(code)
    }

    func testOnlyACdhashRequirementIsAdHoc() {
        XCTAssertTrue(BundleUpdateValidator.isAdHoc(requirement: #"cdhash H"0123456789abcdef0123456789abcdef01234567""#))
        XCTAssertFalse(BundleUpdateValidator.isAdHoc(requirement: #"identifier "com.ctimothe.isla" and anchor apple generic and certificate leaf[subject.OU] = "TEAMID""#))
        XCTAssertFalse(BundleUpdateValidator.isAdHoc(requirement: #"identifier "com.ctimothe.isla""#))
    }

    /// An ad-hoc app's real designated requirement is a cdhash, which no update
    /// can share, so a running ad-hoc app accepts any valid signature.
    func testARunningAdHocAppAcceptsAnyValidSignature() async throws {
        let folder = try UpdateTestSupport.folder(self)
        let running = try UpdateTestSupport.tinyApp(in: folder, name: "Running.app", version: "1.0", build: "1", marker: "running")
        var requirement: SecRequirement?
        var text: CFString?
        XCTAssertEqual(SecCodeCopyDesignatedRequirement(try staticCode(running), [], &requirement), errSecSuccess)
        XCTAssertEqual(SecRequirementCopyString(try XCTUnwrap(requirement), [], &text), errSecSuccess)
        XCTAssertTrue(BundleUpdateValidator.isAdHoc(requirement: try XCTUnwrap(text) as String), "\(text as String? ?? "")")

        let check = BundleUpdateValidator.identityCheck(for: try staticCode(running))
        let update = try UpdateTestSupport.tinyApp(in: folder, name: "Update.app", version: "1.1", build: "2", marker: "update")
        XCTAssertTrue(check(update), "the Ed25519 signature is the gate, not the identity")
        XCTAssertTrue(check(running.appendingPathComponent("nope")), "an ad-hoc running app asks nothing of the staged one's identity")
    }

    /// The certificate branch, with the requirement written by hand: a running
    /// app signed by a certificate is replaced only by a copy that satisfies its
    /// designated requirement. (A real certificate needs a keychain; the
    /// requirement language does not.)
    func testARequirementIsHeldAgainstTheStagedApp() throws {
        let folder = try UpdateTestSupport.folder(self)
        let app = try UpdateTestSupport.tinyApp(in: folder, version: "1.1", build: "2")
        XCTAssertTrue(BundleUpdateValidator.identityCheck(requirementText: #"identifier "com.ctimothe.isla""#)(app))
        XCTAssertFalse(BundleUpdateValidator.identityCheck(requirementText: #"identifier "com.example.other""#)(app))
        XCTAssertFalse(BundleUpdateValidator.identityCheck(requirementText: #"anchor apple generic and certificate leaf[subject.OU] = "AAAAAAAAAA""#)(app),
                       "an ad-hoc copy does not satisfy a certificate's requirement")
        XCTAssertFalse(BundleUpdateValidator.identityCheck(requirementText: "this is not a requirement")(app), "an unparsable requirement refuses")
        XCTAssertFalse(BundleUpdateValidator.identityCheck(requirementText: #"identifier "com.ctimothe.isla""#)(folder.appendingPathComponent("Missing.app")))
    }

    func testAValidUpdateByAnotherIdentityIsRefusedForItsIdentity() async throws {
        let folder = try UpdateTestSupport.folder(self)
        let app = try UpdateTestSupport.tinyApp(in: folder, version: "1.1", build: "2")
        var validator = validator()
        validator.satisfiesRunningIdentity = { _ in false }
        do {
            try await validator.validate(app, release: release())
            XCTFail("an identity change must not pass")
        } catch {
            XCTAssertEqual(error as? UpdateValidationError, .identityChanged)
        }
        validator.satisfiesRunningIdentity = { _ in true }
        try await validator.validate(app, release: release())
    }

    func testTheIdentityIsOnlyAskedOfACopyWhoseSignatureHolds() async throws {
        let folder = try UpdateTestSupport.folder(self)
        let app = try UpdateTestSupport.tinyApp(in: folder, version: "1.1", build: "2", signing: .none)
        var validator = validator()
        validator.satisfiesRunningIdentity = { _ in false }
        do { try await validator.validate(app, release: release()); XCTFail() } catch {
            XCTAssertEqual(error as? UpdateValidationError, .signatureInvalid, "a broken signature is the first thing said")
        }
    }
}
