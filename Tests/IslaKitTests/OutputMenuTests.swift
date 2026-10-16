import AppKit
import CoreAudio
import XCTest
@testable import IslaKit

/// The player's Output menu (spec §4.5): what it lists, in what order, what a
/// row does, and that nothing moves until a row is chosen.
///
/// The machine is a fake: `select` records the device it was asked for instead of
/// moving the owner's output, `openURL` records instead of opening System
/// Settings, the haptic is a counter, and the watch reads a value.
@MainActor
final class OutputMenuTests: XCTestCase {
    private static let outputs: [AudioOutputs.Output] = [
        .init(id: 41, name: "MacBook Pro Speakers", transport: kAudioDeviceTransportTypeBuiltIn),
        .init(id: 42, name: "AirPods Pro", transport: kAudioDeviceTransportTypeBluetooth),
        .init(id: 43, name: "Studio Display Speakers", transport: kAudioDeviceTransportTypeDisplayPort),
        .init(id: 44, name: "Living Room", transport: kAudioDeviceTransportTypeAirPlay),
    ]

    private var machineCurrent: AudioDeviceID? = 42
    private var selected: [AudioDeviceID] = []
    private var opened: [URL] = []
    private var haptics = 0
    private var selectSucceeds = true

    private func audio() -> AudioWatch {
        let watch = AudioWatch(
            read: { [unowned self] in (Self.outputs, self.machineCurrent, 0.62) },
            readMuted: { false }, installListeners: {}, removeListeners: {}
        )
        watch.start()
        return watch
    }

    private func controller(_ audio: AudioWatch) -> OutputMenuController {
        OutputMenuController(
            audio: audio,
            select: { [unowned self] id in
                self.selected.append(id)
                if self.selectSucceeds { self.machineCurrent = id }
                return self.selectSucceeds
            },
            openURL: { [unowned self] in self.opened.append($0) },
            haptic: { [unowned self] in self.haptics += 1 }
        )
    }

    /// What a click does: the item's own target and action, with the item. Not
    /// `NSMenu.performActionForItem(at:)`, which goes through `NSApp` and so
    /// answers nothing in a test process that has not made an application yet.
    private func fire(_ item: NSMenuItem) {
        let target = try! XCTUnwrap(item.target as? NSObject, "\(item.title) has no target")
        _ = target.perform(try! XCTUnwrap(item.action, "\(item.title) has no action"), with: item)
    }

    // MARK: - What it lists

    /// "Output", the devices with the one playing first, a separator and Sound
    /// Settings — and no volume row, ever.
    func testTheEntries() {
        let entries = OutputMenuModel.entries(outputs: Self.outputs, current: 42)
        XCTAssertEqual(entries, [
            .header("Output"),
            .device(Self.outputs[1], isCurrent: true),
            .device(Self.outputs[0], isCurrent: false),
            .device(Self.outputs[2], isCurrent: false),
            .device(Self.outputs[3], isCurrent: false),
            .separator,
            .soundSettings,
        ])
        XCTAssertFalse(entries.contains(.header("Volume")), "volume left the island (owner, 2026-10-16)")
    }

    /// With no known default nothing is marked playing, and the list is the
    /// system's.
    func testNoDefaultMarksNothing() {
        let entries = OutputMenuModel.entries(outputs: Self.outputs, current: nil)
        let devices = entries.compactMap { entry -> (AudioDeviceID, Bool)? in
            if case .device(let device, let current) = entry { return (device.id, current) }
            return nil
        }
        XCTAssertEqual(devices.map(\.0), [41, 42, 43, 44])
        XCTAssertFalse(devices.contains { $0.1 })
    }

    // MARK: - The NSMenu

    func testTheMenuHasHeadersRowsAndACheckmarkOnTheCurrentDevice() {
        let menu = controller(audio()).makeMenu()
        let items = menu.items
        XCTAssertEqual(items.map(\.title), [
            "Output", "AirPods Pro", "MacBook Pro Speakers", "Studio Display Speakers", "Living Room", "", "Sound Settings…",
        ])
        XCTAssertTrue(items[0].isSectionHeader)
        XCTAssertTrue(items[5].isSeparatorItem)
        XCTAssertEqual(items.filter { $0.state == .on }.map(\.title), ["AirPods Pro"], "one checkmark, on the one playing")
        for item in items[1...4] {
            XCTAssertNotNil(item.image, "\(item.title) wears its symbol")
            XCTAssertEqual(item.image?.size, NSSize(width: 26, height: 26), "in a 26 pt circle")
            XCTAssertFalse(item.image?.isTemplate ?? true, "drawn in white on its own fill, not tinted by the menu")
        }
        XCTAssertGreaterThanOrEqual(menu.minimumWidth, OutputMenuController.menuWidth)
    }

    /// No island menu has a Volume row, at any width and for any device,
    /// including one with a volume to give (the watch reads 0.62 here): neither
    /// a header, nor a titled row, nor a view in the menu.
    func testNoMenuHasAVolumeRow() {
        for current: AudioDeviceID? in [41, 42, 43, 44, nil] {
            machineCurrent = current
            let menu = controller(audio()).makeMenu()
            XCTAssertFalse(menu.items.contains { $0.title == "Volume" }, "a Volume row for \(String(describing: current))")
            XCTAssertTrue(menu.items.allSatisfy { $0.view == nil }, "a view row in the menu")
            XCTAssertEqual(menu.items.first?.title, "Output")
        }
    }

    // MARK: - The button's glyph follows the device now playing

    /// The island's Output button draws the current device's own symbol, and a
    /// plain speaker until it knows (no list, no default, a device that is gone).
    func testTheButtonsGlyphIsTheCurrentDevices() {
        let symbol = { (current: AudioDeviceID?) in
            PlayerOutputButton.symbol(outputs: Self.outputs, current: current)
        }
        XCTAssertEqual(symbol(41), "laptopcomputer")
        XCTAssertEqual(symbol(42), "airpods.pro")
        XCTAssertEqual(symbol(43), "display")
        XCTAssertEqual(symbol(44), "airplayaudio")
        XCTAssertEqual(symbol(nil), "speaker.wave.2", "no default known")
        XCTAssertEqual(symbol(99), "speaker.wave.2", "a device the list does not hold")
        XCTAssertEqual(PlayerOutputButton.symbol(outputs: [], current: 41), "speaker.wave.2", "nothing read yet")
        XCTAssertEqual(AudioOutputs.outputFallbackSymbol, "speaker.wave.2")
    }

    /// The lock card's foot rail and the island's button share one mapping and
    /// differ only in the fallback each passes — the card's AirPlay glyph is
    /// unchanged.
    func testTheLockCardAndTheButtonShareOneMapping() {
        for current in [AudioDeviceID(41), 42, 43, 44] {
            XCTAssertEqual(
                AudioOutputs.symbol(outputs: Self.outputs, current: current, fallback: "airplayaudio"),
                PlayerOutputButton.symbol(outputs: Self.outputs, current: current)
            )
        }
        XCTAssertEqual(AudioOutputs.symbol(outputs: Self.outputs, current: nil, fallback: "airplayaudio"), "airplayaudio")
    }

    /// The glyph updates live: the watch republishes when the output changes
    /// (a row chosen, a device unplugged), and the button reads the watch.
    func testTheGlyphFollowsTheWatchWhenTheOutputChanges() {
        let watch = audio()
        let glyph = { PlayerOutputButton.symbol(outputs: watch.outputs, current: watch.current) }
        XCTAssertEqual(glyph(), "airpods.pro")
        machineCurrent = 41
        watch.systemAudioChanged()
        XCTAssertEqual(glyph(), "laptopcomputer", "the speakers took over")
        machineCurrent = nil
        watch.systemAudioChanged()
        XCTAssertEqual(glyph(), "speaker.wave.2", "nothing is the default")
    }

    // MARK: - Nothing moves until a row is chosen

    func testBuildingTheMenuSelectsAndOpensNothing() {
        let watch = audio()
        let controller = controller(watch)
        _ = controller.makeMenu()
        XCTAssertTrue(selected.isEmpty, "no output was chosen by building the menu")
        XCTAssertTrue(opened.isEmpty)
        XCTAssertEqual(haptics, 0)
        XCTAssertEqual(watch.current, 42)
    }

    /// Choosing a row makes it the default, ticks the haptic and re-reads the
    /// machine so the checkmark and the level follow.
    func testChoosingADeviceSelectsItAndRereads() {
        let watch = audio()
        let controller = controller(watch)
        let menu = controller.makeMenu()
        // The row's own target, action and the device it carries are the wiring
        // being held.
        fire(try! XCTUnwrap(menu.items.first { $0.title == "Living Room" }))
        XCTAssertEqual(selected, [44])
        XCTAssertEqual(haptics, 1)
        XCTAssertEqual(watch.current, 44, "the watch re-read the machine")
        let rebuilt = controller.makeMenu()
        XCTAssertEqual(rebuilt.items.filter { $0.state == .on }.map(\.title), ["Living Room"])
        XCTAssertEqual(rebuilt.items[1].title, "Living Room", "and the one playing leads the list")
    }

    /// A device that refuses is not a change: no haptic, no re-read to a state
    /// that did not happen.
    func testARefusedSelectionIsNotAChange() {
        selectSucceeds = false
        let watch = audio()
        let controller = controller(watch)
        let menu = controller.makeMenu()
        fire(try! XCTUnwrap(menu.items.first { $0.title == "Living Room" }))
        XCTAssertEqual(selected, [44], "it was asked")
        XCTAssertEqual(haptics, 0)
        XCTAssertEqual(watch.current, 42)
    }

    func testSoundSettingsOpensSystemSettingsAtSound() {
        let controller = controller(audio())
        let menu = controller.makeMenu()
        XCTAssertEqual(menu.items.last?.title, "Sound Settings…")
        fire(try! XCTUnwrap(menu.items.last))
        XCTAssertEqual(opened, [URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!])
        XCTAssertTrue(selected.isEmpty)
    }

    // MARK: - Anchored under the button

    /// The menu's right edge is on the button's right edge, a hair under it.
    func testThePopUpPointIsRightAlignedUnderTheAnchor() {
        let point = OutputMenuPresenter.popUpPoint(anchorSize: CGSize(width: 26, height: 26), menuWidth: 262)
        XCTAssertEqual(point.x, 26 - 262)
        XCTAssertEqual(point.y, 28)
    }
}
