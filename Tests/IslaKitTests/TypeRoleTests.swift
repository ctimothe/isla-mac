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
        // Redesign 2026-10-15, spec §2.2: the boards' reading text (12.5) and the
        // tall lyric page (17) are the two roles added, so eight where it was six.
        XCTAssertLessThanOrEqual(roles.count, 8, "six roles and the redesign's two")
    }

    /// The two roles the redesign adds (spec §2.2): reading text between `body`
    /// and `subhead`, and the lyric page between `title` and `display`.
    func testTheRedesignAddsReadingAndLyric() {
        XCTAssertEqual(Theme.TypeRole.reading.size, 12.5)
        XCTAssertEqual(Theme.TypeRole.lyric.size, 17)
        XCTAssertGreaterThan(Theme.TypeRole.reading.size, Theme.TypeRole.body.size)
        XCTAssertLessThan(Theme.TypeRole.reading.size, Theme.TypeRole.subhead.size)
        XCTAssertGreaterThan(Theme.TypeRole.lyric.size, Theme.TypeRole.title.size)
        XCTAssertLessThan(Theme.TypeRole.lyric.size, Theme.TypeRole.display.size)
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
