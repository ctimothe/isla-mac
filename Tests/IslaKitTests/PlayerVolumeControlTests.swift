import CoreAudio
import XCTest
@testable import IslaKit

/// A player whose Apple Events wait for the test: each read and write is held
/// until the test answers it, as a slow Spotify (or one with its Automation
/// prompt up) holds `PlayerBridge`'s queue. Nothing here reaches a real player.
@MainActor
final class SlowVolumeScripter: PlayerVolumeScripting {
    var reads: [(app: PlayerApp, answer: @MainActor (Int?, OSStatus) -> Void)] = []
    var writes: [(percent: Int, app: PlayerApp, answer: @MainActor (OSStatus) -> Void)] = []
    /// Writes that have been sent and not answered: never more than one, if
    /// the control keeps one in flight.
    var inFlight = 0
    var mostInFlight = 0

    func readVolume(of app: PlayerApp, completion: @escaping @MainActor @Sendable (Int?, OSStatus) -> Void) {
        reads.append((app, completion))
    }

    func writeVolume(_ percent: Int, to app: PlayerApp, completion: @escaping @MainActor @Sendable (OSStatus) -> Void) {
        inFlight += 1
        mostInFlight = max(mostInFlight, inFlight)
        writes.append((percent, app, { [weak self] outcome in
            self?.inFlight -= 1
            completion(outcome)
        }))
    }
}

/// The Mac's output, answered at once and remembered: no CoreAudio.
@MainActor
final class FakeMacVolume: MacVolumeAccess {
    /// The default output: what a read answers and the only device a write
    /// may land on.
    var state: VolumeState?
    var reads = 0
    var writes: [VolumeState] = []
    /// Writes aimed at a device that was not the default any more: refused as
    /// `MacVolume` refuses them, so nothing was written.
    var refusedWrites: [VolumeState] = []

    /// The output switching to another device (AirPods connecting) while the
    /// old one is still present.
    func switchDefault(to next: VolumeState) { state = next }

    init(state: VolumeState? = VolumeState(device: 41, level: 0.5, muted: false)) {
        self.state = state
    }

    func read(completion: @escaping @MainActor @Sendable (VolumeState?) -> Void) {
        reads += 1
        completion(state)
    }

    func write(_ target: VolumeState, from: VolumeState, completion: @escaping @MainActor @Sendable (VolumeWriteResult) -> Void) {
        guard from.device == state?.device else {
            refusedWrites.append(target)
            return completion(.deviceChanged)
        }
        writes.append(target)
        state = target
        completion(.written)
    }
}

/// The lyric stage's volume control (owner 2026-10-26: "when the lyrics
/// screen is open we need a button to change the volume of the song").
/// Music and Spotify move their own volume, anything else the Mac's; a drag
/// keeps one Apple Event in flight and the newest value waiting; a refused
/// Automation falls back to the Mac with one line saying so.
@MainActor
final class PlayerVolumeControlTests: XCTestCase {
    private var consents: [PlayerApp: AutomationConsent] = [:]
    private var idle: [@MainActor @Sendable () -> Void] = []

    private func make(
        scripter: SlowVolumeScripter = SlowVolumeScripter(), mac: FakeMacVolume = FakeMacVolume()
    ) -> (PlayerVolume, SlowVolumeScripter, FakeMacVolume) {
        let model = PlayerVolume(
            scripter: scripter, mac: mac,
            consent: { [unowned self] in self.consents[$0] ?? .allowed },
            schedule: { [unowned self] _, work in
                self.idle.append(work)
                return {}
            }
        )
        return (model, scripter, mac)
    }

    // MARK: Whose volume

    func testMusicAndSpotifyMoveTheirOwnVolumeAndEverythingElseTheMacs() {
        XCTAssertEqual(PlayerVolumeTarget.forSource(bundleID: "com.apple.Music"), .app(.music))
        XCTAssertEqual(PlayerVolumeTarget.forSource(bundleID: "com.spotify.client"), .app(.spotify))
        XCTAssertEqual(PlayerVolumeTarget.forSource(bundleID: "com.apple.Safari"), .system)
        XCTAssertEqual(PlayerVolumeTarget.forSource(bundleID: "com.google.Chrome"), .system)
        XCTAssertEqual(PlayerVolumeTarget.forSource(bundleID: nil), .system)
    }

    func testTheSourceSetsTheTargetAndAnOpenControlReadsTheNewOne() {
        let (model, scripter, mac) = make()
        model.sourceChanged(bundleID: "com.spotify.client")
        XCTAssertEqual(model.target, .app(.spotify))
        XCTAssertTrue(scripter.reads.isEmpty, "a closed control asks the player nothing")

        model.open()
        XCTAssertEqual(scripter.reads.map(\.app), [.spotify], "opening it reads the player's own volume once")
        scripter.reads[0].answer(40, noErr)
        XCTAssertEqual(model.level, 0.4)

        model.sourceChanged(bundleID: "com.apple.Safari")
        XCTAssertEqual(model.target, .system)
        XCTAssertEqual(mac.reads, 1, "the source changing under an open control reads the new target")
        XCTAssertEqual(model.level, 0.5)
        XCTAssertEqual(scripter.reads.count, 1)
    }

    func testNothingIsAskedUntilTheControlOpens() {
        let (model, scripter, mac) = make()
        model.sourceChanged(bundleID: "com.apple.Music")
        model.sourceChanged(bundleID: "com.spotify.client")
        model.sourceChanged(bundleID: "com.apple.Safari")
        XCTAssertTrue(scripter.reads.isEmpty)
        XCTAssertTrue(scripter.writes.isEmpty)
        XCTAssertEqual(mac.reads, 0)
        XCTAssertTrue(mac.writes.isEmpty)
    }

    // MARK: Newest wins

    /// Ten moves while the first Apple Event blocks: the first goes out, the
    /// next nine collapse into the newest, and when the first answers the
    /// newest follows. Two events, never two at once, and the drawn level was
    /// the finger's all along.
    func testADragKeepsOneEventInFlightAndSendsTheNewestValue() {
        let (model, scripter, _) = make()
        model.sourceChanged(bundleID: "com.spotify.client")
        model.open()
        scripter.reads[0].answer(50, noErr)

        for step in 1...10 {
            model.dragChanged(fraction: Double(step) / 20)
            XCTAssertEqual(model.level, Double(step) / 20, "the bar draws the intended level at once")
        }
        XCTAssertEqual(scripter.writes.map(\.percent), [5], "only the first move is sent while it blocks")

        scripter.writes[0].answer(noErr)
        XCTAssertEqual(scripter.writes.map(\.percent), [5, 50], "then the newest, and nothing in between")
        scripter.writes[1].answer(noErr)
        model.dragEnded()

        XCTAssertLessThanOrEqual(scripter.writes.count, 2)
        XCTAssertEqual(scripter.mostInFlight, 1, "never two Apple Events at once")
        XCTAssertEqual(model.level, 0.5)
        XCTAssertTrue(scripter.writes.allSatisfy { $0.app == .spotify })
    }

    func testAReadThatAnswersAfterAMoveDoesNotPullTheBarBack() {
        let (model, scripter, _) = make()
        model.sourceChanged(bundleID: "com.apple.Music")
        model.open()
        model.dragChanged(fraction: 0.8)
        scripter.reads[0].answer(20, noErr)
        XCTAssertEqual(model.level, 0.8, "the finger outranks a read that was already on its way")
    }

    // MARK: The Mac's volume

    func testABrowserMovesTheMacsOutputAndRaisingAMutedMacUnmutesIt() {
        let mac = FakeMacVolume(state: VolumeState(device: 41, level: 0.3, muted: true))
        let (model, scripter, _) = make(mac: mac)
        model.sourceChanged(bundleID: "com.apple.Safari")
        model.open()
        XCTAssertEqual(PlayerVolume.symbol(level: model.level, muted: true), "speaker.slash.fill")
        XCTAssertEqual(model.symbol, "speaker.slash.fill", "a muted Mac is the slashed speaker")

        model.dragChanged(fraction: 0.6)
        model.dragEnded()
        XCTAssertEqual(mac.writes, [VolumeState(device: 41, level: 0.6, muted: false)])
        XCTAssertFalse(model.muted)
        XCTAssertTrue(scripter.reads.isEmpty && scripter.writes.isEmpty, "no Apple Event for the Mac's volume")
    }

    /// The control keeps the device it read and installs no listener, so the
    /// output switching under an open slider (built-in speakers, then AirPods,
    /// the speakers still there) must not leave the drag on the old device
    /// reporting success. The write is refused for the old device, the new
    /// default is read, and the same level goes to it; later moves follow.
    func testADragFollowsTheDefaultOutputWhenItSwitchesUnderAnOpenSlider() {
        let mac = FakeMacVolume(state: VolumeState(device: 41, level: 0.5, muted: false))
        let (model, _, _) = make(mac: mac)
        model.sourceChanged(bundleID: "com.apple.Safari")
        model.open()
        XCTAssertEqual(model.level, 0.5)

        mac.switchDefault(to: VolumeState(device: 43, level: 0.2, muted: false))
        model.dragChanged(fraction: 0.7)

        XCTAssertEqual(mac.refusedWrites.map(\.device), [41], "the old device was offered the write and refused it")
        XCTAssertEqual(mac.writes, [VolumeState(device: 43, level: 0.7, muted: false)], "the write went to the new default")
        XCTAssertEqual(mac.reads, 2, "the new default was read once after the refusal")
        XCTAssertEqual(model.level, 0.7)

        model.dragChanged(fraction: 0.9)
        XCTAssertEqual(mac.writes.map(\.device), [43, 43], "later moves go straight to the new default")
        XCTAssertEqual(mac.refusedWrites.count, 1)
        XCTAssertEqual(mac.state?.device, 43)
    }

    // MARK: Refused Automation

    /// A refusal is an answer like any other: it belongs to the player and the
    /// read that asked. Spotify's read was still pending when the song moved
    /// to Music, and its late -1743 used to replace Music's target with the
    /// Mac's under a Spotify refusal line.
    func testALateRefusalFromThePreviousPlayersReadChangesNothing() {
        let (model, scripter, mac) = make()
        model.sourceChanged(bundleID: "com.spotify.client")
        model.open()
        XCTAssertEqual(scripter.reads.map(\.app), [.spotify])

        model.sourceChanged(bundleID: "com.apple.Music")
        XCTAssertEqual(scripter.reads.map(\.app), [.spotify, .music])
        scripter.reads[0].answer(nil, AutomationAccess.refused)

        XCTAssertEqual(model.target, .app(.music), "Music keeps its own volume")
        XCTAssertNil(model.refused, "and no Spotify refusal line is shown")
        XCTAssertEqual(mac.reads, 0, "nothing fell back to the Mac")
        scripter.reads[1].answer(30, noErr)
        XCTAssertEqual(model.level, 0.3)
    }

    /// The same for a write: the event was in flight to Spotify when the
    /// source changed to Music.
    func testALateRefusalFromThePreviousPlayersWriteChangesNothing() {
        let (model, scripter, mac) = make()
        model.sourceChanged(bundleID: "com.spotify.client")
        model.open()
        scripter.reads[0].answer(50, noErr)
        model.dragChanged(fraction: 0.2)
        XCTAssertEqual(scripter.writes.map(\.app), [.spotify])

        model.sourceChanged(bundleID: "com.apple.Music")
        scripter.writes[0].answer(AutomationAccess.refused)

        XCTAssertEqual(model.target, .app(.music))
        XCTAssertNil(model.refused)
        XCTAssertEqual(mac.reads, 0)
        XCTAssertTrue(mac.writes.isEmpty)
    }

    func testARefusalFallsBackToTheMacsVolumeWithOneLine() {
        let (model, scripter, mac) = make()
        model.sourceChanged(bundleID: "com.spotify.client")
        model.open()
        scripter.reads[0].answer(nil, AutomationAccess.refused)

        XCTAssertEqual(model.target, .system)
        XCTAssertEqual(model.refused, .spotify, "the stage shows its one line for Spotify")
        XCTAssertEqual(model.level, 0.5, "the Mac's level, read once the fallback happens")
        XCTAssertEqual(model.label, "Volume", "and the label stops saying Spotify")

        model.dragChanged(fraction: 0.7)
        model.dragEnded()
        XCTAssertEqual(mac.writes.map(\.level), [0.7])
        XCTAssertTrue(scripter.writes.isEmpty, "nothing more goes to the refused player")
    }

    func testARefusalMidDragDropsTheWaitingValueRatherThanPlayingItOnTheMac() {
        let (model, scripter, mac) = make()
        model.sourceChanged(bundleID: "com.apple.Music")
        model.open()
        scripter.reads[0].answer(50, noErr)
        model.dragChanged(fraction: 0.2)
        model.dragChanged(fraction: 0.9)
        scripter.writes[0].answer(AutomationAccess.refused)

        XCTAssertEqual(model.target, .system)
        XCTAssertEqual(scripter.writes.count, 1)
        XCTAssertTrue(mac.writes.isEmpty, "90% of Music is not 90% of the speakers")
    }

    func testAPlayerAlreadyKnownRefusedIsNeverAsked() {
        consents[.spotify] = .denied
        let (model, scripter, mac) = make()
        model.sourceChanged(bundleID: "com.spotify.client")
        model.open()
        XCTAssertTrue(scripter.reads.isEmpty, "a known refusal sends no event to earn another -1743")
        XCTAssertEqual(model.target, .system)
        XCTAssertEqual(model.refused, .spotify)
        XCTAssertEqual(mac.reads, 1)
    }

    // MARK: Folding

    func testTheSliderFoldsAfterItsIdleTimeButNotUnderAFinger() {
        let (model, scripter, _) = make()
        model.sourceChanged(bundleID: "com.apple.Music")
        model.open()
        scripter.reads[0].answer(30, noErr)
        model.dragChanged(fraction: 0.4)
        idle.last?()
        XCTAssertTrue(model.isOpen, "a timer armed before the drag never folds it under the finger")
        model.dragEnded()
        idle.last?()
        XCTAssertFalse(model.isOpen)
        XCTAssertEqual(PlayerVolume.idleTimeout, 3)
    }

    // MARK: The glyph and VoiceOver

    func testTheGlyphFollowsTheLevel() {
        XCTAssertEqual(PlayerVolume.symbol(level: 0, muted: false), "speaker.slash.fill")
        XCTAssertEqual(PlayerVolume.symbol(level: 0.6, muted: true), "speaker.slash.fill")
        XCTAssertEqual(PlayerVolume.symbol(level: 0.05, muted: false), "speaker.fill")
        XCTAssertEqual(PlayerVolume.symbol(level: 0.25, muted: false), "speaker.wave.1.fill")
        XCTAssertEqual(PlayerVolume.symbol(level: 0.5, muted: false), "speaker.wave.2.fill")
        XCTAssertEqual(PlayerVolume.symbol(level: 1, muted: false), "speaker.wave.3.fill")
        XCTAssertEqual(PlayerVolume.symbol(level: nil, muted: false), "speaker.wave.2.fill", "unread: a neutral speaker")
    }

    func testVoiceOverHearsWhoseVolumeAndThePercent() {
        XCTAssertEqual(PlayerVolumeTarget.app(.spotify).label, "Spotify volume")
        XCTAssertEqual(PlayerVolumeTarget.app(.music).label, "Music volume")
        XCTAssertEqual(PlayerVolumeTarget.system.label, "Volume")
        let english = Locale(identifier: "en_US")
        XCTAssertEqual(PlayerVolume.spokenValue(level: 0.4, muted: false, locale: english), "40%")
        // CoreAudio's floats widen to 0.41999998…: heard as a whole percent.
        XCTAssertEqual(PlayerVolume.spokenValue(level: Double(Float(0.42)), muted: false, locale: english), "42%")
        XCTAssertEqual(PlayerVolume.spokenValue(level: 0.4, muted: true, locale: english), "Muted")
        XCTAssertEqual(PlayerVolume.spokenValue(level: nil, muted: false, locale: english), "")
    }

    func testVoiceOverStepsByFivePercentAndOpensWhenNothingIsKnownYet() {
        let (model, scripter, _) = make()
        model.sourceChanged(bundleID: "com.spotify.client")
        model.step(up: true)
        XCTAssertTrue(model.isOpen, "with no level to step from, a step opens the control and reads it")
        XCTAssertTrue(scripter.writes.isEmpty)
        scripter.reads[0].answer(40, noErr)
        model.step(up: true)
        XCTAssertEqual(model.level ?? 0, 0.45, accuracy: 0.0001)
        XCTAssertEqual(scripter.writes.map(\.percent), [45])
        scripter.writes[0].answer(noErr)
        model.step(up: false)
        model.step(up: false)
        XCTAssertEqual(model.level ?? 0, 0.35, accuracy: 0.0001)
    }

    // MARK: The script

    func testTheVolumeScriptsAreThePlayersOwnSoundVolume() {
        for app in PlayerApp.allCases {
            XCTAssertEqual(PlayerBridge.Transport.soundVolume(40).body(for: app), "set sound volume to 40")
            XCTAssertEqual(PlayerBridge.Transport.soundVolume(140).body(for: app), "set sound volume to 100")
            let read = PlayerBridge.Script.soundVolume(of: app)
            XCTAssertTrue(read.contains("sound volume"))
            XCTAssertTrue(read.contains("if it is running"), "an event to a player that quit would launch it")
            XCTAssertTrue(PlayerBridge.Script.everySource(for: app).contains { $0.name == "sound volume" })
        }
    }
}
