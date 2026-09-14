import XCTest
@testable import IslaKit

final class ProductIdentityTests: XCTestCase {
    func testCanonicalIdentityFeedsEveryProductBoundary() {
        XCTAssertEqual(ProductIdentity.displayName, "Isla")
        XCTAssertEqual(ProductIdentity.executableName, "Isla")
        XCTAssertEqual(ProductIdentity.bundleIdentifier, "com.ctimothe.isla")
        XCTAssertEqual(ProductIdentity.supportDirectoryName, "Isla")
        XCTAssertEqual(ProductIdentity.screenshotDirectoryName, "Isla")
        XCTAssertEqual(ProductIdentity.helperResourceName, "libislamedia")
        XCTAssertEqual(ProductIdentity.internalPasteboardType, "com.ctimothe.isla.internal")
    }
}
