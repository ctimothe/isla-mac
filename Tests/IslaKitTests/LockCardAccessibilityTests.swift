import AppKit
import CoreAudio
import SwiftUI
import XCTest
@testable import IslaKit

/// The lock card as VoiceOver meets it, with the output picker open and shut.
///
/// The lab's dump of the open picker (H-010) found the scrubber, the transport
/// and the volume still in reading order underneath it, interleaved with the
/// devices: "Playback Position" between MacBook Pro Speakers and AirPods Pro,
/// "Previous Track" between Studio Display and Living Room. A sighted user
/// sees a list over a dimmed card; a VoiceOver user was made to wade through
/// controls the scrim says are not there. The same dump carried two unlabelled
/// images, 690x690 and 460x300 — the blurred cover lighting the card and the
/// glass grain — read out as nameless stops (H-009).
///
/// Nothing here reaches the machine: the media controller is cut from every
/// real player, the audio watch reads fixtures and installs no listener, the
/// card's settings come from a private suite, and no device row is pressed,
/// because pressing one would change the owner's real output.
@MainActor
final class LockCardAccessibilityTests: XCTestCase {
    private static let outputs: [AudioOutputs.Output] = [
        .init(id: 41, name: "MacBook Pro Speakers", transport: kAudioDeviceTransportTypeBuiltIn),
        .init(id: 42, name: "AirPods Pro", transport: kAudioDeviceTransportTypeBluetooth),
        .init(id: 44, name: "Living Room", transport: kAudioDeviceTransportTypeAirPlay),
    ]

    /// A fixed answer for the devices, the default and the level; nothing is
    /// installed and nothing is written.
    private static func audio() -> AudioWatch {
        AudioWatch(read: { (outputs, 42, 0.62) }, readMuted: { false }, installListeners: {}, removeListeners: {})
    }

    /// The card over the private suite, on the given pane, with the lab's
    /// default track (which carries a cover, so the cover light is drawn).
    private func card(_ pane: LockScreenCard.Pane, _ isolated: ProbeStores) async -> some View {
        await LabFixtures.play(LabFixtures.Track(elapsed: 27), on: isolated.stores.media)
        return LockScreenCard(
            media: isolated.stores.media, lyrics: isolated.stores.lyrics, audio: Self.audio(), initialPane: pane
        )
        // Glass, standard size: the suite is empty, so the card's defaults —
        // and never whatever the xctest domain happens to hold.
        .defaultAppStorage(isolated.suite)
    }

    /// With the picker open, the picker is all there is: one group named
    /// "Sound Output" holding the three devices, and none of the card's own
    /// controls in reading order beside it. Escape — VoiceOver's way out of a
    /// modal, since the scrim's tap is not an element — closes it and gives
    /// the card back.
    func testThePickerIsTheOnlyThingVoiceOverReachesWhileOpen() async throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }

        let root = await AXProbe.tree(of: await card(.output, isolated), size: LockScreenCard.size(for: .standard))

        for hidden in ["Playback Position", "Previous Track", "Next Track", "Pause", "Volume", "Lyrics"] {
            XCTAssertNil(root.first(label: hidden), "\"\(hidden)\" is still reachable under the open picker\n\(root.dump)")
        }

        let picker = try XCTUnwrap(
            root.all { $0.label == "Sound Output" && !$0.children.isEmpty }.first,
            "no group named Sound Output\n\(root.dump)"
        )
        let devices = picker.all(role: "AXButton").map(\.label)
        XCTAssertEqual(Set(devices), Set(Self.outputs.map(\.name)), root.dump)
        // The playing device leads the list and says so.
        XCTAssertEqual(devices.first, "AirPods Pro", root.dump)
        XCTAssertTrue(picker.all(role: "AXButton").first?.selected ?? false, root.dump)
        // Every button on the card is one of the devices: nothing outside the
        // group is left to land on.
        XCTAssertEqual(root.all(role: "AXButton").count, Self.outputs.count, root.dump)

        XCTAssertTrue(picker.cancel(), "the picker offers no Escape\n\(root.dump)")
        let after = await root.reread(settle: 0.4)
        XCTAssertNotNil(after.first(label: "Playback Position"), "Escape did not give the card back\n\(after.dump)")
        XCTAssertNil(after.all { $0.label == "AirPods Pro" && $0.role == "AXButton" }.first, after.dump)
    }

    /// The player pane exposes no image that is decoration: the cover light
    /// behind the card and the glass grain over it were nameless 690x690 and
    /// 460x300 stops. The bound is a size because the header's 76 pt cover is
    /// content, not decoration, and what it should be called is a separate
    /// question from whether the card's own lighting should be heard at all.
    func testNoDecorativeImageIsExposed() async {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }

        let root = await AXProbe.tree(of: await card(.player, isolated), size: LockScreenCard.size(for: .standard))
        XCTAssertNotNil(root.first(label: "Playback Position"), "the player pane did not render\n\(root.dump)")

        let decorative = root.all(role: "AXImage").filter { image in
            guard image.label.isEmpty, image.title.isEmpty, let frame = image.frame else { return false }
            return frame.width >= 300 || frame.height >= 300
        }
        XCTAssertTrue(decorative.isEmpty, "\(decorative.count) unlabelled decorative images\n\(root.dump)")
    }

    /// The open picker's own popover glass carries the same grain, and it is
    /// just as silent there.
    func testTheOpenPickerExposesNoUnlabelledImage() async {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }

        let root = await AXProbe.tree(of: await card(.output, isolated), size: LockScreenCard.size(for: .standard))
        let unlabelled = root.all(role: "AXImage").filter { $0.label.isEmpty && $0.title.isEmpty }
        XCTAssertTrue(unlabelled.isEmpty, root.dump)
    }
}
