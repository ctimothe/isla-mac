import XCTest
@testable import DynamicIslandKit

final class MeetingLinkTests: XCTestCase {
    func testSupportedProviders() {
        let cases = [
            ("https://meet.google.com/abc-defg-hij", "Google Meet"),
            ("https://zoom.us/j/123", "Zoom"),
            ("https://teams.microsoft.com/l/meetup-join/abc", "Teams"),
            ("https://example.webex.com/meet/a", "Webex"),
            ("https://whereby.com/room", "Whereby"),
            ("https://meet.jit.si/room", "Jitsi"),
        ]

        for (raw, provider) in cases {
            let url = URL(string: raw)!
            XCTAssertTrue(MeetingLink.isJoinable(url), raw)
            XCTAssertEqual(MeetingLink.provider(for: url), provider, raw)
        }
    }

    func testRejectsUnknownAndInsecureMeetingLinks() {
        XCTAssertFalse(MeetingLink.isJoinable(URL(string: "https://example.com/meeting")!))
        XCTAssertFalse(MeetingLink.isJoinable(URL(string: "http://zoom.us/j/123")!))
    }
}
