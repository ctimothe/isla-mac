import Foundation

struct NowPlayingFailurePolicy {
    enum Action: Equatable {
        case restart(after: TimeInterval)
        case fallback
    }

    private(set) var consecutiveFailures = 0

    mutating func recordFailure() -> Action {
        consecutiveFailures += 1
        return consecutiveFailures >= 3 ? .fallback : .restart(after: 2)
    }

    mutating func recordSuccess() {
        consecutiveFailures = 0
    }
}
