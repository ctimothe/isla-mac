import XCTest
@testable import DynamicIslandKit

final class ProductIdentityTests: XCTestCase {
    func testCanonicalIdentityFeedsEveryProductBoundary() {
        XCTAssertEqual(ProductIdentity.displayName, "Dynamic Island")
        XCTAssertEqual(ProductIdentity.executableName, "DynamicIsland")
        XCTAssertEqual(ProductIdentity.bundleIdentifier, "dev.dynamicisland.app")
        XCTAssertEqual(ProductIdentity.supportDirectoryName, "DynamicIsland")
        XCTAssertEqual(ProductIdentity.screenshotDirectoryName, "DynamicIsland")
        XCTAssertEqual(ProductIdentity.helperResourceName, "libdynamicislandmedia")
        XCTAssertEqual(ProductIdentity.internalPasteboardType, "dev.dynamicisland.internal")
        XCTAssertEqual(ProductIdentity.statusSymbolName, "capsule.fill")
    }
}
