import SwiftUI

extension View {
    /// Draws this as the song `key`'s cover, swapped for the next song's with
    /// the one shared swap (`Theme.trackSwap`): the incoming cover settles
    /// from 0.96 as it fades in, opacity only under Reduce Motion.
    ///
    /// Put on the picture inside a cover's frame, never on the frame itself:
    /// the frame is what the open and close morph carries between the island
    /// and the panel, and an identity change there would end the morph and
    /// start a fresh view mid-flight.
    func trackSwapCover(_ key: String?, reduceMotion: Bool) -> some View {
        modifier(TrackSwapModifier(key: key, transition: Theme.trackSwapCover(reduceMotion: reduceMotion),
                                   animation: Theme.trackSwap(reduceMotion: reduceMotion)))
    }

    /// The same swap for words: a crossfade, in the same transaction as the
    /// cover's.
    func trackSwapText(_ key: String?, reduceMotion: Bool) -> some View {
        modifier(TrackSwapModifier(key: key, transition: .opacity,
                                   animation: Theme.trackSwap(reduceMotion: reduceMotion)))
    }
}

/// One identity per song, so the outgoing and incoming copies are two views
/// that transition, and an animation tied to the key alone, so nothing else
/// the surface redraws rides it.
private struct TrackSwapModifier: ViewModifier {
    let key: String?
    let transition: AnyTransition
    let animation: Animation

    func body(content: Content) -> some View {
        ZStack {
            content
                .id(key)
                .transition(transition)
        }
        .animation(animation, value: key)
    }
}
