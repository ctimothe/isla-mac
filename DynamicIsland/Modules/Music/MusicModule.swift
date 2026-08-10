import Combine
import IslandCore
import SwiftUI

@MainActor
final class MusicModule: IslandModule, ObservableObject {
    let id = "music"
    let priority = 100 // sole MVP module; leaves headroom to rank future modules around it

    @Published private(set) var isActive = false
    @Published private(set) var nowPlaying: NowPlayingInfo?
    var isActivePublisher: AnyPublisher<Bool, Never> { $isActive.eraseToAnyPublisher() }

    private let client = MediaRemoteAdapterClient(bundle: .main)

    func start() {
        Task {
            await client.start()
            for await info in await client.stream {
                nowPlaying = info
                // Locked decision: "has a current track" (playing OR paused),
                // not strictly `playing == true` — matches macOS's own Now
                // Playing widget.
                isActive = (info.title != nil || info.artist != nil)
            }
            // Stream ended (subprocess died/missing resources) -> graceful
            // degradation, locked decision #4: no error UI, just go inactive.
            isActive = false
            nowPlaying = nil
        }
    }

    func compactView() -> AnyView { AnyView(MusicCompactView(module: self)) }
    func expandedView() -> AnyView { AnyView(MusicExpandedView(module: self)) }
}
