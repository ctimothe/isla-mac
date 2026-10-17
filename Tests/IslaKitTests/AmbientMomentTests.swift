import AppKit
import CoreAudio
import SwiftUI
import XCTest
@testable import IslaKit

/// The island's moments without music: the charger going in, headphones
/// connecting. Each fires once per arrival, widens the pill only as far as it
/// needs, and draws in the wings like everything else the pill shows.
@MainActor
final class AmbientMomentTests: XCTestCase {

    func testOnlyTheMomentPowerArrivesIsAnEvent() {
        let battery = AmbientWatch.Power(onExternalPower: false, level: 40)
        let charging = AmbientWatch.Power(onExternalPower: true, level: 40)
        let now = Date()
        func pluggedIn(_ previous: AmbientWatch.Power?, _ next: AmbientWatch.Power) -> Bool {
            AmbientWatch.pluggedIn(previous: previous, now: next, lastAnnounced: nil, at: now)
        }
        XCTAssertTrue(pluggedIn(battery, charging))
        XCTAssertFalse(pluggedIn(charging, charging), "a level change while charging")
        XCTAssertFalse(pluggedIn(charging, battery), "unplugging")
        XCTAssertFalse(pluggedIn(nil, charging), "a launch while plugged in")
    }

    /// A loose USB-C dock drops and restores power every few seconds (G-033).
    /// Each restore is a real plug-in edge, and each one re-grew the pill. The
    /// charger now keeps the quiet window headphones already had.
    func testAFlappingChargerIsAnnouncedOnce() {
        let battery = AmbientWatch.Power(onExternalPower: false, level: 40)
        let charging = AmbientWatch.Power(onExternalPower: true, level: 40)
        let t0 = Date()
        XCTAssertFalse(AmbientWatch.pluggedIn(
            previous: battery, now: charging, lastAnnounced: t0, at: t0.addingTimeInterval(5), quiet: 30
        ), "the same charger five seconds later is not news")
        XCTAssertTrue(AmbientWatch.pluggedIn(
            previous: battery, now: charging, lastAnnounced: t0, at: t0.addingTimeInterval(31), quiet: 30
        ), "past the quiet window it is a new plug-in")
        XCTAssertFalse(AmbientWatch.pluggedIn(
            previous: charging, now: charging, lastAnnounced: t0, at: t0.addingTimeInterval(31), quiet: 30
        ), "the quiet window never turns a non-edge into an event")
        XCTAssertFalse(AmbientWatch.pluggedIn(
            previous: battery, now: charging, lastAnnounced: t0, at: t0.addingTimeInterval(5)
        ), "the default window is the headphones' one")
    }

    /// Open the panel during a moment and close it: the pill must not snap
    /// back to "Charging" for whatever was left of its 2.2 s (F-033). Opening
    /// ends the moment and a track peek alike, inside the open's own
    /// transaction, so they leave with it.
    func testOpeningThePanelEndsTheMoment() throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: isolated.stores)
        vm.ambient = .charging(level: 80, isCharging: true)
        vm.isPeeking = true

        vm.isOpen = false
        XCTAssertNotNil(vm.ambient, "writing false over false is not an open")
        XCTAssertTrue(vm.isPeeking)

        vm.isOpen = true
        XCTAssertNil(vm.ambient, "the moment ends when the panel opens")
        XCTAssertFalse(vm.isPeeking, "and so does a track peek")

        vm.isOpen = false
        XCTAssertNil(vm.ambient, "nothing resurfaces on the close")
        XCTAssertFalse(vm.isPeeking)
    }

    /// A moment under a resting pointer waits for it, one second at a time,
    /// rather than folding out from under someone reading it.
    func testAMomentWaitsForThePointer() {
        XCTAssertEqual(NotchController.ambientRecheck(pointerInside: true), 1.0)
        XCTAssertNil(NotchController.ambientRecheck(pointerInside: false))
    }

    func testOnlyNewlyAppearedHeadphonesAreAnnounced() {
        let pods = AmbientWatch.Headphones(uid: "pods", name: "AirPods Pro", symbol: "airpodspro")
        let speaker = AmbientWatch.Headphones(uid: "speaker", name: "Speaker", symbol: "hifispeaker")
        let now = Date()
        XCTAssertEqual(AmbientWatch.announcements(known: ["speaker"], now: [pods, speaker], lastAnnounced: [:], at: now).map(\.uid), ["pods"])
        XCTAssertTrue(AmbientWatch.announcements(known: ["pods", "speaker"], now: [pods, speaker], lastAnnounced: [:], at: now).isEmpty)
    }

    /// AirPods hopping between a phone and the Mac, or coreaudiod restarting,
    /// reappear within seconds. The same device stays quiet for a while.
    func testTheSameHeadphonesAreNotAnnouncedTwiceInAMoment() {
        let pods = AmbientWatch.Headphones(uid: "pods", name: "AirPods Pro", symbol: "airpodspro")
        let then = Date()
        XCTAssertTrue(AmbientWatch.announcements(
            known: [], now: [pods], lastAnnounced: ["pods": then], at: then.addingTimeInterval(10)
        ).isEmpty)
        XCTAssertEqual(AmbientWatch.announcements(
            known: [], now: [pods], lastAnnounced: ["pods": then], at: then.addingTimeInterval(AmbientWatch.repeatQuiet + 1)
        ).map(\.uid), ["pods"])
    }

    /// The owner's name is what fit in the wing and the model is what got cut.
    func testTheOwnersNameComesOffADeviceName() {
        XCTAssertEqual(AmbientWatch.shortName("Elshod's AirPods Max"), "AirPods Max")
        XCTAssertEqual(AmbientWatch.shortName("Elshod’s AirPods Pro"), "AirPods Pro")
        XCTAssertEqual(AmbientWatch.shortName("Beats Studio Pro"), "Beats Studio Pro")
        XCTAssertEqual(AmbientWatch.shortName("Elshod's "), "Elshod's ", "nothing after the owner: leave it")
    }

    /// Plugged in and holding is not charging, and the plug says so.
    func testAHoldingBatteryWearsThePlugNotTheBolt() {
        XCTAssertEqual(AmbientActivity.charging(level: 80, isCharging: true).chargeSymbol, "bolt.fill")
        XCTAssertEqual(AmbientActivity.charging(level: 80, isCharging: false).chargeSymbol, "powerplug.fill")
        for symbol in ["bolt.fill", "powerplug.fill"] {
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), "\(symbol) must resolve")
        }
    }

    /// Every refusal the moment makes, one at a time. The open panel, a drag
    /// and the lock are not among them since spec §19.1: they make it wait a
    /// second (`NotchController.alertsBlocked`, `IslandActivityTests`).
    func testTheMomentKeepsTheTrackPeeksRestraint() {
        func allowed(
            switchOn: Bool = true, pointerInside: Bool = false, pointerUnderGrownPill: Bool = false,
            screensAsleep: Bool = false, quiet: Bool = false
        ) -> Bool {
            NotchController.ambientAllowed(
                switchOn: switchOn, pointerInside: pointerInside, pointerUnderGrownPill: pointerUnderGrownPill,
                screensAsleep: screensAsleep, quiet: quiet
            )
        }
        XCTAssertTrue(allowed())
        XCTAssertFalse(allowed(switchOn: false), "switched off in Settings")
        XCTAssertFalse(allowed(pointerInside: true), "the pointer is on the island")
        XCTAssertFalse(allowed(pointerUnderGrownPill: true), "the pill would grow under a still cursor")
        XCTAssertFalse(allowed(screensAsleep: true), "nobody can see it")
        XCTAssertFalse(allowed(quiet: true), "a film, a talk or a projector is showing")
    }

    /// A Keynote talk mirrored to a projector, a laptop presenting through
    /// HDMI with its lid shut, or a full-screen film must not get a 2.2 s pill
    /// with a song title or a battery percentage on the audience's screen
    /// (K-003). The resting pill stays — only the transient moments go quiet.
    func testTransientMomentsGoQuietWhereAnAudienceMayBeWatching() {
        func quiet(
            fullScreen: Bool = false, mirrored: Bool = false, soleExternal: Bool = false
        ) -> Bool {
            NotchController.momentsQuiet(
                fullScreenFrontmost: fullScreen, displayMirrored: mirrored, soleExternalDisplay: soleExternal
            )
        }
        XCTAssertFalse(quiet(), "an ordinary desktop")
        XCTAssertTrue(quiet(fullScreen: true), "a full-screen app is frontmost")
        XCTAssertTrue(quiet(mirrored: true), "a projector mirrors the screen")
        XCTAssertTrue(quiet(soleExternal: true), "a closed laptop driving only an external display")
    }

    /// A Mac with no battery (a Mini, a Studio) always has only external
    /// displays, and that is a desk and not a presentation.
    func testASoleExternalDisplayIsOnlyAClosedLaptop() {
        XCTAssertTrue(NotchController.isSoleExternalDisplay(displaysAreBuiltIn: [false], hasInternalBattery: true))
        XCTAssertTrue(NotchController.isSoleExternalDisplay(displaysAreBuiltIn: [false, false], hasInternalBattery: true))
        XCTAssertFalse(NotchController.isSoleExternalDisplay(displaysAreBuiltIn: [false], hasInternalBattery: false))
        XCTAssertFalse(NotchController.isSoleExternalDisplay(displaysAreBuiltIn: [true, false], hasInternalBattery: true))
        XCTAssertFalse(NotchController.isSoleExternalDisplay(displaysAreBuiltIn: [true], hasInternalBattery: true))
        XCTAssertFalse(NotchController.isSoleExternalDisplay(displaysAreBuiltIn: [], hasInternalBattery: true), "no displays reported")
    }

    func testThePillGrowsOnlyAsFarAsTheMomentNeeds() {
        let notch = CGSize(width: 200, height: 32)
        let folded = notch
        let charging = NotchViewModel.ambientBodySize(.charging(level: 80, isCharging: true), media: folded, notchSize: notch, bodyWidth: 560)
        XCTAssertEqual(charging.width, 200 + NotchMetrics.compactChargingExtension, "spec §19.4: the notch plus 180")
        let pods = NotchViewModel.ambientBodySize(
            .headphones(name: "AirPods Pro", symbol: "airpodspro"), media: folded, notchSize: notch, bodyWidth: 560
        )
        XCTAssertEqual(pods.width, 200 + NotchMetrics.ambientNameExtension)
        let narrow = NotchViewModel.ambientBodySize(
            .headphones(name: "AirPods Pro", symbol: "airpodspro"), media: folded, notchSize: notch, bodyWidth: 380
        )
        XCTAssertEqual(narrow.width, 380, "never wider than the panel it would open into")
        let overMusic = NotchViewModel.ambientBodySize(
            .charging(level: 80, isCharging: true), media: CGSize(width: 460, height: 32), notchSize: notch, bodyWidth: 560
        )
        XCTAssertEqual(overMusic.width, 460, "never narrower than the music pill it stands in for")
    }

    /// All three of "The island shows" (Charging, Headphones Connecting, New
    /// Tracks) are on until turned off. Read from a private suite since the
    /// redesign gave each a new key (spec §10): the test used to remove the
    /// owner's own keys from the standard domain and put them back.
    func testBothMomentsAreOnUntilTurnedOff() {
        let name = "com.ctimothe.isla.ambient.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        defer { suite.removePersistentDomain(forName: name) }
        XCTAssertTrue(NotchViewModel.chargingEnabled(in: suite))
        XCTAssertTrue(NotchViewModel.headphonesEnabled(in: suite))
        XCTAssertTrue(NotchViewModel.newTracksEnabled(in: suite))
        suite.set(false, forKey: NotchViewModel.chargingKey)
        XCTAssertFalse(NotchViewModel.chargingEnabled(in: suite))
        XCTAssertTrue(NotchViewModel.headphonesEnabled(in: suite), "one switch does not move the other")
    }

    /// Renders both moments over a grey backdrop. With SHOT_OUT set it writes
    /// the picture there, for eyes rather than assertions.
    func testBothMomentsRender() throws {
        guard let geometry = NotchGeometry.current() else { return XCTFail("a test host always has a screen") }
        var images: [NSImage] = []
        for activity in [AmbientActivity.charging(level: 82, isCharging: true), .headphones(name: "AirPods Pro", symbol: "airpodspro")] {
            let vm = NotchViewModel(geometry: geometry, stores: NotchStores())
            vm.ambient = activity
            let width = vm.geometry.expandedSize.width + 80
            let view = ZStack(alignment: .top) {
                Color(white: 0.55)
                NotchContentView(vm: vm)
            }
            .frame(width: width, height: vm.geometry.notchSize.height + 30)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            images.append(try XCTUnwrap(renderer.nsImage))
        }
        if let path = ProcessInfo.processInfo.environment["SHOT_OUT"] {
            for (index, image) in images.enumerated() {
                guard let tiff = image.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
                try png.write(to: URL(fileURLWithPath: path + "-\(index).png"))
            }
        }
    }
}

/// The Quick Look panel's data source: the files asked for, in order, and
/// nothing once the panel is gone.
@MainActor
final class ShelfSharingTests: XCTestCase {
    func testThePreviewListsTheFilesInOrder() {
        let source = ShelfSharing.PreviewSource()
        let urls = [URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b.pdf")]
        source.urls = urls
        XCTAssertEqual(source.numberOfPreviewItems(in: nil), 2)
        XCTAssertEqual(source.previewPanel(nil, previewItemAt: 1)?.previewItemURL, urls[1])
        XCTAssertNil(source.previewPanel(nil, previewItemAt: 2))
    }

    /// The controller accepts the panel only while there is something to show.
    func testTheAppAcceptsQuickLookOnlyWithFiles() {
        let delegate = AppDelegate()
        ShelfSharing.preview.urls = []
        XCTAssertFalse(delegate.acceptsPreviewPanelControl(nil))
        ShelfSharing.preview.urls = [URL(fileURLWithPath: "/tmp/a.png")]
        XCTAssertTrue(delegate.acceptsPreviewPanelControl(nil))
        ShelfSharing.preview.urls = []
    }
}
