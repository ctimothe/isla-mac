import XCTest
@testable import IslaKit

/// Six roles, not fifteen sizes.
///
/// Every size in this app was chosen locally and well, which is how there came
/// to be fifteen of them. A reader cannot tell 10pt from 11pt apart as a
/// decision — only as noise. The roles are the vocabulary; a size that is not
/// a role has to justify itself.
final class TypeRoleTests: XCTestCase {

    func testTheRolesAreDistinctAndOrdered() {
        let roles = Theme.TypeRole.allCases.map(\.size)
        XCTAssertEqual(roles, roles.sorted(), "roles ascend")
        XCTAssertEqual(Set(roles).count, roles.count, "no two roles share a size")
        XCTAssertLessThanOrEqual(roles.count, 7, "six roles, seven at the outside")
    }

    /// The smallest role is the one carrying most of the panel's labels, and
    /// AppKit's caption floor is 10pt. 9pt and below is below what the platform
    /// itself will set.
    func testNoRoleIsBelowTheCaptionFloor() {
        for role in Theme.TypeRole.allCases {
            XCTAssertGreaterThanOrEqual(role.size, 10, "\(role) is below AppKit's caption floor")
        }
    }
}
