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
        XCTAssertTrue(AmbientWatch.pluggedIn(previous: battery, now: charging))
        XCTAssertFalse(AmbientWatch.pluggedIn(previous: charging, now: charging), "a level change while charging")
        XCTAssertFalse(AmbientWatch.pluggedIn(previous: charging, now: battery), "unplugging")
        XCTAssertFalse(AmbientWatch.pluggedIn(previous: nil, now: charging), "a launch while plugged in")
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

    /// Every refusal the moment makes, one at a time.
    func testTheMomentKeepsTheTrackPeeksRestraint() {
        func allowed(
            switchOn: Bool = true, isOpen: Bool = false, isDropTargeted: Bool = false, isLocked: Bool = false,
            pointerInside: Bool = false, pointerUnderGrownPill: Bool = false, screensAsleep: Bool = false
        ) -> Bool {
            NotchController.ambientAllowed(
                switchOn: switchOn, isOpen: isOpen, isDropTargeted: isDropTargeted, isLocked: isLocked,
                pointerInside: pointerInside, pointerUnderGrownPill: pointerUnderGrownPill, screensAsleep: screensAsleep
            )
        }
        XCTAssertTrue(allowed())
        XCTAssertFalse(allowed(switchOn: false), "switched off in Settings")
        XCTAssertFalse(allowed(isOpen: true), "the panel is open")
        XCTAssertFalse(allowed(isDropTargeted: true), "a drag is over the island")
        XCTAssertFalse(allowed(isLocked: true), "the lock card owns the rects")
        XCTAssertFalse(allowed(pointerInside: true), "the pointer is on the island")
        XCTAssertFalse(allowed(pointerUnderGrownPill: true), "the pill would grow under a still cursor")
        XCTAssertFalse(allowed(screensAsleep: true), "nobody can see it")
    }

    func testThePillGrowsOnlyAsFarAsTheMomentNeeds() {
        let notch = CGSize(width: 200, height: 32)
        let folded = notch
        let charging = NotchViewModel.ambientBodySize(.charging(level: 80, isCharging: true), media: folded, notchSize: notch, bodyWidth: 560)
        XCTAssertEqual(charging.width, 200 + NotchMetrics.compactMediaExtension)
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

    func testBothMomentsAreOnUntilTurnedOff() {
        let defaults = UserDefaults.standard
        for key in [NotchViewModel.showChargingKey, NotchViewModel.showHeadphonesKey] {
            let had = defaults.object(forKey: key)
            defaults.removeObject(forKey: key)
            XCTAssertTrue(key == NotchViewModel.showChargingKey
                ? NotchViewModel.showChargingEnabled : NotchViewModel.showHeadphonesEnabled)
            if let had { defaults.set(had, forKey: key) }
        }
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
