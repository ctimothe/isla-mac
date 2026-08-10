import IslandCore
import SwiftUI

struct MusicExpandedView: View {
    @ObservedObject var module: MusicModule
    private let commandSender = MediaRemoteCommandSender(bundle: .main)

    var body: some View {
        VStack(spacing: 8) {
            Text(module.nowPlaying?.title ?? "Nothing playing")
                .font(.headline)
            Text(module.nowPlaying?.artist ?? "")
                .font(.subheadline)
            Text(module.nowPlaying?.album ?? "")
                .font(.caption)

            HStack(spacing: 20) {
                Button {
                    send(.previous)
                } label: {
                    Image(systemName: "backward.fill")
                }
                Button {
                    send(module.nowPlaying?.playing == true ? .pause : .play)
                } label: {
                    Image(systemName: module.nowPlaying?.playing == true ? "pause.fill" : "play.fill")
                }
                Button {
                    send(.next)
                } label: {
                    Image(systemName: "forward.fill")
                }
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding()
    }

    private func send(_ command: MediaRemoteCommandSender.Command) {
        Task { await commandSender.send(command) }
    }
}
