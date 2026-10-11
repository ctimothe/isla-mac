import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// The scrubbers and the lock card's volume bar, as VoiceOver meets them.
///
/// Each of them used to be a capsule with a drag gesture, declared to
/// assistive tech as one element with a label, a value and an adjustable
/// action. The dump of the open panel found something else (H-023): an
/// AXUnknown with a label and nothing more — no value to hear and no
/// increment to perform, so the position could neither be read nor moved
/// without a pointer. One step was also 5% of the length (G-034), which is
/// nine minutes on a three-hour audiobook, and the strip a pointer had to
/// land on was 14 pt tall at the top edge of the screen (F-014).
///
/// Nothing here reaches the machine: the media controller is cut from every
/// real player, and the volume bar is read but never moved, because moving it
/// would set the owner's real output volume.
@MainActor
final class SeekAccessibilityTests: XCTestCase {
    /// The panel's scrubber is a native slider: heard as "0:27 of 3:58",
    /// moved one step by VoiceOver's increment, and tall enough to grab.
    func testThePanelScrubberIsASliderWithAValue() async throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let media = isolated.stores.media
        await LabFixtures.play(LabFixtures.Track(duration: 238, elapsed: 27, cover: nil), on: media)

        let pane = MediaPane(media: media, lyrics: isolated.stores.lyrics, morph: nil)
        let root = await AXProbe.tree(of: pane, size: CGSize(width: NotchMetrics.standardBody.width, height: 162))

        let scrubber = try XCTUnwrap(root.first(label: "Playback Position"), root.dump)
        XCTAssertEqual(scrubber.role, "AXSlider", root.dump)
        XCTAssertEqual(scrubber.valueDescription, "0:27 of 3:58", root.dump)
        XCTAssertEqual(Double(scrubber.value) ?? -1, 27, accuracy: 0.5, "an AXSlider's value is its number")
        XCTAssertTrue(scrubber.actionNames.contains("AXIncrement"), root.dump)
        XCTAssertTrue(scrubber.actionNames.contains("AXDecrement"), root.dump)
        let frame = try XCTUnwrap(scrubber.frame, root.dump)
        XCTAssertGreaterThanOrEqual(frame.height, 22, "the strip a pointer has to land on is still \(frame.height) pt tall")

        let before = media.position
        XCTAssertTrue(scrubber.increment(), root.dump)
        await AXProbe.wait(0.05)
        XCTAssertEqual(media.position - before, SeekAccessibility.seekStep(duration: 238), accuracy: 0.05,
                       "one VoiceOver step should move the song by seekStep(238) = 11.9 s")
        XCTAssertEqual(SeekAccessibility.seekStep(duration: 238), 11.9, accuracy: 0.0001)
    }

    /// 5% of a song, never under five seconds and never over fifteen — the
    /// vocabulary of the Podcasts skip buttons, not a ninth of an hour.
    func testStepsAreBounded() {
        XCTAssertEqual(SeekAccessibility.seekStep(duration: 30), 5, accuracy: 0.0001)
        XCTAssertEqual(SeekAccessibility.seekStep(duration: 180), 9, accuracy: 0.0001)
        XCTAssertEqual(SeekAccessibility.seekStep(duration: 10_800), 15, accuracy: 0.0001)
        // A length the clock has not learnt yet still steps somewhere sane.
        XCTAssertEqual(SeekAccessibility.seekStep(duration: 0), 5, accuracy: 0.0001)
    }

    /// The lock card's scrubber gets the same slider, and the same step.
    func testTheLockCardScrubberIsASlider() async throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let media = isolated.stores.media
        await LabFixtures.play(LabFixtures.Track(duration: 10_800, elapsed: 600, cover: nil), on: media)

        let card = LockScreenCard(media: media, lyrics: isolated.stores.lyrics, audio: Self.quietAudio(volume: nil))
        let root = await AXProbe.tree(of: card, size: LockScreenCard.size(for: .standard))

        let scrubber = try XCTUnwrap(root.first(label: "Playback Position"), root.dump)
        XCTAssertEqual(scrubber.role, "AXSlider", root.dump)
        XCTAssertEqual(scrubber.valueDescription, "10:00 of 3:00:00", root.dump)
        let frame = try XCTUnwrap(scrubber.frame, root.dump)
        XCTAssertGreaterThanOrEqual(frame.height, 22, root.dump)

        let before = media.position
        XCTAssertTrue(scrubber.decrement(), root.dump)
        await AXProbe.wait(0.05)
        XCTAssertEqual(before - media.position, 15, accuracy: 0.05,
                       "a three-hour audiobook steps back fifteen seconds, not nine minutes")
    }

    /// The lock card's volume is a slider heard as a percentage. Only read:
    /// performing its increment would set the machine's real output volume.
    func testTheLockCardVolumeIsASlider() async throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let media = isolated.stores.media
        await LabFixtures.play(LabFixtures.Track(duration: 238, elapsed: 27, cover: nil), on: media)

        let card = LockScreenCard(media: media, lyrics: isolated.stores.lyrics, audio: Self.quietAudio(volume: 0.42))
        let root = await AXProbe.tree(of: card, size: LockScreenCard.size(for: .standard))

        let volume = try XCTUnwrap(root.first(label: "Volume"), root.dump)
        XCTAssertEqual(volume.role, "AXSlider", root.dump)
        // Whole percents in the reader's own locale ("42%", "42 %"): the level
        // arrives as a Float, and 0.42 used to be spoken as 41.999999.
        XCTAssertEqual(volume.valueDescription, 0.42.formatted(.percent.precision(.fractionLength(0))), root.dump)
        XCTAssertTrue(volume.valueDescription.contains("42"), root.dump)
        XCTAssertTrue(volume.actionNames.contains("AXIncrement"), root.dump)
        let frame = try XCTUnwrap(volume.frame, root.dump)
        XCTAssertGreaterThanOrEqual(frame.height, 22, root.dump)
    }

    /// A muted Mac's bar is heard as muted, not as a level nobody can hear
    /// (G-023). Only read, for the same reason as the test above.
    func testAMutedLockCardVolumeSaysMuted() async throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let media = isolated.stores.media
        await LabFixtures.play(LabFixtures.Track(duration: 238, elapsed: 27, cover: nil), on: media)

        let card = LockScreenCard(
            media: media, lyrics: isolated.stores.lyrics, audio: Self.quietAudio(volume: 0.42, muted: true)
        )
        let root = await AXProbe.tree(of: card, size: LockScreenCard.size(for: .standard))

        let volume = try XCTUnwrap(root.first(label: "Volume"), root.dump)
        XCTAssertEqual(volume.role, "AXSlider", root.dump)
        XCTAssertEqual(volume.valueDescription, localized("Muted"), root.dump)
    }

    /// An audio watch that reads a fixed answer and installs nothing: no
    /// devices, no default, and the given level.
    private static func quietAudio(volume: Float?, muted: Bool = false) -> AudioWatch {
        AudioWatch(read: { ([], nil, volume) }, readMuted: { muted }, installListeners: {}, removeListeners: {})
    }
}

private extension AXNode {
    /// VoiceOver's VO-Up on an adjustable element.
    func increment() -> Bool { perform("accessibilityPerformIncrement") }
    /// VoiceOver's VO-Down on an adjustable element.
    func decrement() -> Bool { perform("accessibilityPerformDecrement") }

    /// What VoiceOver speaks for a slider. An AXSlider's AXValue is its
    /// number; the words a listener hears are its value description.
    var valueDescription: String {
        let selector = NSSelectorFromString("accessibilityValueDescription")
        guard element.responds(to: selector) else { return "" }
        let answer = element.perform(selector)?.takeUnretainedValue()
        if let string = answer as? String { return string }
        if let attributed = answer as? NSAttributedString { return attributed.string }
        return answer.map { String(describing: $0) } ?? ""
    }

    private func perform(_ name: String) -> Bool {
        let selector = NSSelectorFromString(name)
        guard element.responds(to: selector) else { return false }
        typealias Perform = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(element.method(for: selector), to: Perform.self)(element, selector)
    }
}
