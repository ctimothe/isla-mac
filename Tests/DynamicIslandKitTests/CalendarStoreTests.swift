import EventKit
import XCTest
@testable import DynamicIslandKit

@MainActor
final class CalendarStoreTests: XCTestCase {
    func testStartNeverRequestsPermission() {
        let auth = CalendarAuthorizationSpy(status: .notDetermined)
        let store = CalendarStore(authorization: auth)

        store.start()

        XCTAssertEqual(auth.requestCount, 0)
        XCTAssertEqual(store.access, .notRequested)
    }

    func testButtonActionRequestsPermissionOnce() {
        let auth = CalendarAuthorizationSpy(status: .notDetermined)
        let store = CalendarStore(authorization: auth)

        store.requestAccess()

        XCTAssertEqual(auth.requestCount, 1)
    }
}

@MainActor
private final class CalendarAuthorizationSpy: CalendarAuthorizationClient {
    var status: EKAuthorizationStatus
    private(set) var requestCount = 0

    init(status: EKAuthorizationStatus) {
        self.status = status
    }

    func requestFullAccess(completion: @escaping (Result<Bool, Error>) -> Void) {
        requestCount += 1
        completion(.success(true))
    }
}
