import EventKit

@MainActor
protocol CalendarAuthorizationClient: AnyObject {
    var status: EKAuthorizationStatus { get }
    func requestFullAccess(completion: @escaping (Result<Bool, Error>) -> Void)
}

@MainActor
final class EventKitCalendarAuthorizationClient: CalendarAuthorizationClient {
    private let store: EKEventStore

    init(store: EKEventStore) {
        self.store = store
    }

    var status: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    func requestFullAccess(completion: @escaping (Result<Bool, Error>) -> Void) {
        store.requestFullAccessToEvents { granted, error in
            if let error {
                completion(.failure(error))
            } else {
                completion(.success(granted))
            }
        }
    }
}
