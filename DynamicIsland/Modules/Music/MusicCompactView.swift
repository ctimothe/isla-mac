import SwiftUI

struct MusicCompactView: View {
    @ObservedObject var module: MusicModule

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: module.nowPlaying?.playing == true ? "waveform" : "pause.fill")
                .font(.caption)
            Text(module.nowPlaying?.title ?? "")
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
    }
}
