import Combine
import CoreAudio
import SwiftUI

/// The system output volume's bar, shared by the lock card and the player.
///
/// It lived inside `LockScreenCard` — the drag, the paced writes, the latch on
/// the device a drag began on, the mute handling, VoiceOver's steps — until the
/// redesign (2026-10-15, spec §4.5) put the same bar in the Music player. Two
/// copies of that logic would have drifted the first time one of them learnt a
/// lesson (K-008 and F-045 and G-023 each taught the card one), so the logic is
/// here once, in `VolumeSliderModel`, and the two surfaces differ only in how
/// `SystemVolumeSlider` is dressed (`Look`).
///
/// **Nothing here writes the machine until a person drags or steps it.** The
/// model reads — the level, the mute, the default device, all through the
/// `AudioWatch` it is handed — and `PlayerVolumeTests` holds that with a fake
/// `System`: constructing one, attaching it to a watch, a re-read, a device
/// appearing and a track change all leave the write log empty.
@MainActor
final class VolumeSliderModel: ObservableObject {
    /// The machine, as a bundle of closures so a test can stand a fake in its
    /// place. The defaults are the live implementations; every write the app
    /// makes to the system volume goes through `setLevel` and `setMuted`.
    struct System {
        var setLevel: (Float, AudioDeviceID) -> Bool
        var setMuted: (Bool, AudioDeviceID) -> Bool
        var currentLevel: () -> Float?
        var level: (AudioDeviceID) -> Float?
        var uptime: () -> TimeInterval
        /// Runs `work` after `delay` seconds on the main actor — the held
        /// level's second chance (`VolumeWriteGate.due`).
        var after: (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void

        static let live = System(
            setLevel: { SystemVolume.set($0, device: $1) },
            setMuted: { SystemVolume.setMuted($0, device: $1) },
            currentLevel: { SystemVolume.current() },
            level: { SystemVolume.level(device: $0) },
            uptime: { ProcessInfo.processInfo.systemUptime },
            after: { delay, work in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    MainActor.assumeIsolated { work() }
                }
            }
        )
    }

    /// The level the machine reports; nil for a device with no volume to give,
    /// in which case no surface draws a bar (a slider that moves and changes
    /// nothing is the failure `SystemVolume.control` exists to rule out).
    @Published private(set) var volume: Float?
    /// Where the finger is while dragging; the bar draws from this at full
    /// rate and the write is paced behind it (F-045).
    @Published private(set) var dragging: Float?
    /// The default output is muted: the bar draws the level it will come back
    /// to, dimmed, beside a slashed speaker (G-023).
    @Published private(set) var muted = false

    private let audio: AudioWatch
    private let system: System
    /// The default output as the watch last said, which is what a drag's first
    /// event latches onto.
    private var defaultOutput: AudioDeviceID?
    /// Paces the drag's CoreAudio writes (F-045).
    private var gate = VolumeWriteGate()
    /// The device the drag writes to: the default it began on, never whatever
    /// is default at the moment of each write (K-008).
    private var latch = VolumeDragLatch()
    private var subscriptions: Set<AnyCancellable> = []

    init(audio: AudioWatch, system: System = .live) {
        self.audio = audio
        self.system = system
        audio.$current
            .sink { [weak self] now in self?.defaultOutputChanged(to: now) }
            .store(in: &subscriptions)
        // A finger on the bar owns the level until release, so the mirror
        // stands down while one drags.
        audio.$volume
            .sink { [weak self] level in
                guard let self, self.dragging == nil else { return }
                self.volume = level
            }
            .store(in: &subscriptions)
        audio.$muted
            .sink { [weak self] muted in self?.muted = muted }
            .store(in: &subscriptions)
    }

    /// Where the bar stands, 0...1: the finger while dragging, else the device.
    var level: Double { Double(dragging ?? volume ?? 0) }

    // MARK: - The drag

    /// One event of the drag, `fraction` along the bar.
    ///
    /// The first event latches the default output; a drag the default moved
    /// under writes nothing more and leaves the bar to the machine (K-008). Every
    /// event used to write CoreAudio, 60 to 120 times a second (F-045): the bar
    /// follows the finger from `dragging`, the write goes through the gate, and a
    /// held level is handed over once its interval has passed, so a finger at
    /// rest is heard at rest.
    func dragChanged(fraction: Double) {
        guard latch.target(current: defaultOutput) != nil else { return }
        let next = Float(min(max(fraction, 0), 1))
        dragging = next
        if let write = gate.offer(next, at: system.uptime()) {
            writeLatched(write)
        } else {
            system.after(VolumeWriteGate.interval) { [weak self] in
                guard let self, let due = self.gate.due(at: self.system.uptime()) else { return }
                self.writeLatched(due)
            }
        }
    }

    /// The finger lifted. The level the gate still holds is where it let go,
    /// and it always lands.
    func dragEnded() {
        if let held = gate.finish() { writeLatched(held) }
        latch.end()
        volume = system.currentLevel() ?? dragging
        dragging = nil
    }

    /// A drag a new song cut short lets go here (K-017): a gesture torn down
    /// without `onEnded` left the bar pinned to the old finger and the mirror
    /// deaf until the next drag. A finger still down simply writes its place
    /// again on the next move, so nothing live is lost by clearing these. A
    /// level the gate was still holding lands now, rather than never (F-045).
    func endForTrackChange() {
        if let held = gate.finish(), let device = latch.device {
            commit(held, device: device)
        }
        latch.end()
        if dragging != nil {
            dragging = nil
            volume = audio.volume
        }
    }

    /// VoiceOver's step, or any other discrete move: written straight to the
    /// current default, and the bar re-read from the device afterwards.
    func step(to level: Double) {
        let next = Float(level)
        guard let device = defaultOutput else { return }
        commit(next, device: device)
        volume = system.level(device) ?? next
    }

    // MARK: - The machine moving under us

    /// AirPods taking over mid-drag used to be sent the finger's level for the
    /// speakers (K-008). The default moving under a drag ends it instead: the
    /// level the gate still held lands on the device it was meant for, the bar
    /// goes back to mirroring the machine, and the rest of the gesture writes
    /// nothing.
    private func defaultOutputChanged(to now: AudioDeviceID?) {
        defaultOutput = now
        let dragged = latch.device
        guard latch.defaultMoved(to: now) else { return }
        if let held = gate.finish(), let dragged { commit(held, device: dragged) }
        dragging = nil
        volume = audio.volume
    }

    // MARK: - Writes

    /// One paced write from the drag, onto the device the drag latched.
    /// Nothing is written once the default has moved under the drag.
    private func writeLatched(_ level: Float) {
        guard let device = latch.device else { return }
        commit(level, device: device)
    }

    /// The one write path for the bar — the drag's paced writes and its flush,
    /// and VoiceOver's steps — noted on the media trail so a live session can
    /// count the writes a drag makes. A level raised above zero on a muted
    /// output unmutes it, as the volume keys do (G-023): the level goes first,
    /// so the sound comes back at the new level rather than a blip of the old.
    private func commit(_ level: Float, device: AudioDeviceID) {
        DebugTrail.note("volume slider: write \(level)")
        _ = system.setLevel(level, device)
        if SystemVolume.unmutes(muted: muted, newLevel: level), system.setMuted(false, device) {
            // Straight into the model, so the next paced write does not unmute
            // again before the watch's listener reports it.
            muted = false
        }
    }
}

/// The bar itself: a speaker glyph, a track, and — for the player and the menu
/// — a knob.
struct SystemVolumeSlider: View {
    /// How the bar is dressed. The behaviour is the model's and does not vary.
    enum Look {
        /// The lock card's: a 4 pt track in the card's own greys, no knob, a
        /// quiet speaker at each end.
        case card
        /// The player's (spec §4.5): a 4 pt track with a 12 pt knob, a 10 pt
        /// `speaker.fill` at the leading end only — the row has no room for two.
        case player
        /// The Output menu's slider row (below 540): the player's bar with the
        /// loud speaker at the far end too, as the system's own sound menu has.
        case menu
        /// The lock card's Output pane (spec §7.3), the macOS Sound module's
        /// slider: an 8 pt track with a knob, a quiet speaker and a loud one at
        /// the ends in slots of their own, so the bar between them is the 380
        /// the board draws.
        case sound
    }

    @ObservedObject var model: VolumeSliderModel
    var look: Look

    /// 4 pt track, 12 pt knob (spec §4.5); the card keeps its bare 4 pt bar.
    static let trackHeight: CGFloat = 4
    static let knobDiameter: CGFloat = 12
    /// The Sound pane's own: a thicker track wants a bigger knob.
    static let soundTrackHeight: CGFloat = 8
    static let soundKnobDiameter: CGFloat = 14
    /// The slot each end glyph sits in on the Sound pane, and the gap to the bar.
    static let soundGlyphSlot: CGFloat = 12
    static let soundSpacing: CGFloat = 8

    private var trackHeight: CGFloat { look == .sound ? Self.soundTrackHeight : Self.trackHeight }
    private var knobDiameter: CGFloat { look == .sound ? Self.soundKnobDiameter : Self.knobDiameter }
    /// The strip a pointer has to land on: 22 pt, as the scrubber's, so a near
    /// miss still lands (F-014). The row it sits in is 12 pt (player) or 22 pt
    /// (card), and the strip's extra height is given back with negative padding
    /// so the neighbours stay where the type rhythm put them.
    static let gripHeight: CGFloat = 22

    var body: some View {
        let palette = Self.palette(for: look)
        HStack(spacing: look == .card ? 8 : (look == .sound ? Self.soundSpacing : 6)) {
            // A muted Mac drew a live-looking bar (G-023). The slashed speaker
            // says so where the system's own slider does, and the fill drops
            // to the track's tone: still the level the sound comes back at,
            // no longer a level anyone is hearing. The glyph sits in the
            // slashed one's width, so the bar does not shift when it swaps.
            Image(systemName: "speaker.slash.fill")
                .islandFont(look == .sound ? .body : .caption, weight: .regular)
                .hidden()
                .overlay(alignment: .leading) {
                    Image(systemName: model.muted ? "speaker.slash.fill" : "speaker.fill")
                        .islandFont(look == .sound ? .body : .caption, weight: .regular)
                }
                .frame(width: look == .sound ? Self.soundGlyphSlot : nil, alignment: .leading)
            bar(palette)
                // The same slider as the seek bar, heard as a percentage and
                // moved in five-percent steps. This is the system's output
                // volume, and the dump found it as an AXUnknown with no value
                // (H-023). Attached to the 22 pt strip and *before* the
                // negative padding below, as the scrubber does it: the
                // element's frame is the strip a pointer lands on, not the
                // 12 pt row the strip is laid out in.
                .volumeAccessibility(level: model.level, muted: model.muted) { model.step(to: $0) }
                // The player's row is 12 pt tall; the card's is the strip's own 22.
                .padding(.vertical, look == .card || look == .sound ? 0 : -5)
            if look != .player {
                Image(systemName: "speaker.wave.3.fill")
                    .islandFont(look == .sound ? .body : .caption, weight: .regular)
                    .frame(width: look == .sound ? Self.soundGlyphSlot : nil, alignment: .trailing)
            }
        }
        .foregroundStyle(palette.glyph)
    }

    private struct Palette {
        let track: Color
        let fill: Color
        let glyph: Color
    }

    @MainActor
    private static func palette(for look: Look) -> Palette {
        switch look {
        case .card:
            return Palette(track: Theme.cardTrack, fill: .white.opacity(0.8), glyph: Theme.cardSecondary)
        case .sound:
            return Palette(track: Theme.cardTrack, fill: .white, glyph: Theme.cardSecondary)
        case .player, .menu:
            return Palette(track: Theme.surface, fill: .white.opacity(0.9), glyph: Theme.secondary)
        }
    }

    private func bar(_ palette: Palette) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            let level = model.level
            let filled = width * level
            ZStack(alignment: .leading) {
                Capsule().fill(palette.track).frame(height: trackHeight)
                Capsule()
                    .fill(model.muted ? palette.track : palette.fill)
                    .frame(width: filled, height: trackHeight)
                if look != .card {
                    Circle()
                        .fill(.white)
                        .frame(width: knobDiameter, height: knobDiameter)
                        .shadow(color: .black.opacity(0.5), radius: 3, y: 0.5)
                        .offset(x: min(max(filled - knobDiameter / 2, 0), max(width - knobDiameter, 0)))
                        .opacity(model.muted ? 0.6 : 1)
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard width > 0 else { return }
                        model.dragChanged(fraction: value.location.x / width)
                    }
                    .onEnded { _ in model.dragEnded() }
            )
        }
        .frame(height: Self.gripHeight)
    }
}
