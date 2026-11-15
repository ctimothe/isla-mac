import SwiftUI

/// Placeholder shown while artwork is on its way. The system publishes the new
/// title before it has fetched the new cover, so without this the panel would
/// sit on an empty grey square for a moment on every track change.
struct SkeletonBox: View {
    var cornerRadius: CGFloat = 14
    @State private var sweep = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Theme.surface)
                .overlay(
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.10), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.55)
                    .offset(x: sweep ? geo.size.width : -geo.size.width * 0.55)
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .onAppear {
            // A shimmer that repeats forever is exactly the kind of motion
            // Reduce Motion is asked to stop; the plain surface still reads
            // as a placeholder.
            guard !reduceMotion else { return }
            startSweep()
        }
        // And the setting is honoured live, not only at appearance. This used
        // to read it once in `onAppear`, so turning Reduce Motion on while a
        // cover was loading left the shimmer running until the box went away
        // (F-055), and turning it off left a still box.
        .onChange(of: reduceMotion) { _, reduced in
            if reduced {
                // Back to the start in a transaction that disables animations,
                // so the repeat is replaced by a still value rather than by
                // one more pass of the sweep carried in from outside.
                var stop = Transaction()
                stop.disablesAnimations = true
                withTransaction(stop) { sweep = false }
            } else {
                startSweep()
            }
        }
    }

    private func startSweep() {
        withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) {
            sweep = true
        }
    }
}
