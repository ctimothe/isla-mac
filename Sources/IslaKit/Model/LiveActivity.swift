import Foundation

/// A live activity beyond the song and the Shelf (plan
/// `2026-11-14-islandcn-activities`, spec §19.1 amended 2026-11-14): it
/// stands on the island for as long as what it shows is true, like the
/// iPhone's timer, recording and download activities.
///
/// The values are the services' own (`IslandTimerState`, `CaptureState`,
/// `DownloadProgress`), so what the island draws is what the service knows,
/// with no copy to fall out of step.
enum LiveActivity: Equatable {
    /// Another app has the microphone or a camera (S4).
    case recording(CaptureState)
    /// A countdown, running or paused (S3).
    case timer(IslandTimerState)
    /// A stopwatch, running or paused (S3).
    case stopwatch(IslandTimerState)
    /// Downloads in progress in ~/Downloads, oldest first (S5).
    case downloads([DownloadProgress])

    /// §19.1's live ranks, amended 2026-11-14. Recording outranks everything
    /// live: it is the one that says something is listening. A timer is a
    /// deadline the person set and outranks the song; a stopwatch counts
    /// up and has no deadline, but is still the person's own; a download is
    /// the Mac's, under the song and over the Shelf. Music is 14, the Shelf 16.
    var rank: Int {
        switch self {
        case .recording: return 11
        case .timer: return 12
        case .stopwatch: return 13
        case .downloads: return 15
        }
    }

    /// The identity the island's motion keys on (`IslandMotion`): one kind
    /// turning into another is a swap of content, a timer ticking is not.
    var kind: String {
        switch self {
        case .recording: return "recording"
        case .timer: return "timer"
        case .stopwatch: return "stopwatch"
        case .downloads: return "downloads"
        }
    }

    /// Whether a value change moves the island's edges, as against redrawing
    /// inside them. Only whether something is there does.
    var isTimer: Bool {
        switch self {
        case .timer, .stopwatch: return true
        case .recording, .downloads: return false
        }
    }

    /// The highest of each kind that stands, in rank order. Pure, so the
    /// order is a test.
    static func standing(
        capture: CaptureState?, countdown: IslandTimerState?, stopwatch: IslandTimerState?,
        downloads: [DownloadProgress]
    ) -> [LiveActivity] {
        var live: [LiveActivity] = []
        if let capture, !capture.isEmpty { live.append(.recording(capture)) }
        if let countdown { live.append(.timer(countdown)) }
        if let stopwatch { live.append(.stopwatch(stopwatch)) }
        if !downloads.isEmpty { live.append(.downloads(downloads)) }
        return live.sorted { $0.rank < $1.rank }
    }

    /// What VoiceOver hears for the island while it shows this.
    func accessibilityLabel(at now: Date) -> String {
        switch self {
        case .recording(let state):
            switch (state.microphoneApps.isEmpty, state.cameraInUse) {
            case (false, true): return localized("Microphone and camera in use")
            case (true, true): return localized("Camera in use")
            default: return localized("Microphone in use")
            }
        case .timer(let state):
            let text = IslandTimerCenter.format(state.remaining(at: now) ?? 0, roundingUp: true)
            return state.isPaused ? localized("Timer paused, %@ left", text) : localized("Timer, %@ left", text)
        case .stopwatch(let state):
            let text = IslandTimerCenter.format(state.elapsed(at: now), roundingUp: false)
            return state.isPaused ? localized("Stopwatch paused, %@", text) : localized("Stopwatch, %@", text)
        case .downloads(let items):
            guard let first = items.first else { return localized("Downloads") }
            if let fraction = first.fraction {
                return localized("Downloading %@, %d percent", first.name, Int((fraction * 100).rounded()))
            }
            return localized("Downloading %@", first.name)
        }
    }
}
