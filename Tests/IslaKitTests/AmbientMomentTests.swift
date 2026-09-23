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
        let pods = AudioOutputs.Output(id: 7, name: "AirPods Pro", transport: kAudioDeviceTransportTypeBluetooth)
        let speaker = AudioOutputs.Output(id: 9, name: "Speaker", transport: kAudioDeviceTransportTypeBluetooth)
        XCTAssertEqual(AmbientWatch.newArrivals(known: [9], now: [pods, speaker]).map(\.id), [7])
        XCTAssertTrue(AmbientWatch.newArrivals(known: [7, 9], now: [pods, speaker]).isEmpty)
    }

    func testThePillGrowsOnlyAsFarAsTheMomentNeeds() {
        let notch = CGSize(width: 200, height: 32)
        let folded = notch
        let charging = NotchViewModel.ambientBodySize(.charging(level: 80), media: folded, notchSize: notch, bodyWidth: 560)
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
            .charging(level: 80), media: CGSize(width: 460, height: 32), notchSize: notch, bodyWidth: 560
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
        for activity in [AmbientActivity.charging(level: 82), .headphones(name: "AirPods Pro", symbol: "airpodspro")] {
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
