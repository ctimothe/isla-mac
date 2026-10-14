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
    /// Settings — and with no slider row at a width that has the slider on the
    /// player.
    func testTheEntriesWithoutTheVolumeRow() {
        let entries = OutputMenuModel.entries(outputs: Self.outputs, current: 42, includesVolume: false)
        XCTAssertEqual(entries, [
            .header("Output"),
            .device(Self.outputs[1], isCurrent: true),
            .device(Self.outputs[0], isCurrent: false),
            .device(Self.outputs[2], isCurrent: false),
            .device(Self.outputs[3], isCurrent: false),
            .separator,
            .soundSettings,
        ])
    }

    /// Below 540 the menu gains a "Volume" header and the slider row above
    /// "Output", with a separator between them.
    func testTheEntriesWithTheVolumeRow() {
        let entries = OutputMenuModel.entries(outputs: Self.outputs, current: 41, includesVolume: true)
        XCTAssertEqual(Array(entries.prefix(5)), [
            .header("Volume"), .volume, .separator, .header("Output"),
            .device(Self.outputs[0], isCurrent: true),
        ])
        XCTAssertEqual(entries.last, .soundSettings)
        XCTAssertEqual(entries.filter { $0 == .volume }.count, 1)
    }

    /// An output with a fixed volume has no level to set. The player and the lock
    /// card omit their sliders for it, and so does the folded menu — it used to
    /// add one that read 0 % and moved nothing (review 2026-10-15).
    func testTheFoldedMenuHasNoSliderForAnOutputWithNoVolume() {
        let entries = OutputMenuModel.entries(
            outputs: Self.outputs, current: 41, includesVolume: true, hasVolume: false
        )
        XCTAssertFalse(entries.contains(.volume))
        XCTAssertFalse(entries.contains(.header("Volume")))
        XCTAssertEqual(entries.first, .header("Output"))

        let fixed = AudioWatch(
            read: { (Self.outputs, 41, nil) }, readMuted: { false }, installListeners: {}, removeListeners: {}
        )
        fixed.start()
        let menu = controller(fixed).makeMenu(includesVolume: true)
        XCTAssertTrue(menu.items.allSatisfy { $0.view == nil }, "no slider row in the NSMenu either")
        XCTAssertEqual(menu.items.first?.title, "Output")
    }

    /// With no known default nothing is marked playing, and the list is the
    /// system's.
    func testNoDefaultMarksNothing() {
        let entries = OutputMenuModel.entries(outputs: Self.outputs, current: nil, includesVolume: false)
        let devices = entries.compactMap { entry -> (AudioDeviceID, Bool)? in
            if case .device(let device, let current) = entry { return (device.id, current) }
            return nil
        }
        XCTAssertEqual(devices.map(\.0), [41, 42, 43, 44])
        XCTAssertFalse(devices.contains { $0.1 })
    }

    // MARK: - The NSMenu

    func testTheMenuHasHeadersRowsAndACheckmarkOnTheCurrentDevice() {
        let menu = controller(audio()).makeMenu(includesVolume: false)
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
        XCTAssertTrue(items.allSatisfy { $0.view == nil }, "no slider row where the player has the slider")
    }

    func testTheFoldedMenuCarriesTheSliderRow() {
        let menu = controller(audio()).makeMenu(includesVolume: true)
        XCTAssertEqual(Array(menu.items.prefix(4)).map(\.title), ["Volume", "Volume", "", "Output"])
        let slider = menu.items[1]
        XCTAssertNotNil(slider.view, "the slider is a view in the menu")
        XCTAssertEqual(slider.view?.frame.size, NSSize(width: OutputMenuController.menuWidth, height: OutputMenuController.sliderRowHeight))
        XCTAssertTrue(menu.items[0].isSectionHeader)
        XCTAssertTrue(menu.items[2].isSeparatorItem)
    }

    // MARK: - Nothing moves until a row is chosen

    func testBuildingTheMenuSelectsAndOpensNothing() {
        let watch = audio()
        let controller = controller(watch)
        _ = controller.makeMenu(includesVolume: false)
        _ = controller.makeMenu(includesVolume: true)
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
        let menu = controller.makeMenu(includesVolume: false)
        // The row's own target, action and the device it carries are the wiring
        // being held.
        fire(try! XCTUnwrap(menu.items.first { $0.title == "Living Room" }))
        XCTAssertEqual(selected, [44])
        XCTAssertEqual(haptics, 1)
        XCTAssertEqual(watch.current, 44, "the watch re-read the machine")
        let rebuilt = controller.makeMenu(includesVolume: false)
        XCTAssertEqual(rebuilt.items.filter { $0.state == .on }.map(\.title), ["Living Room"])
        XCTAssertEqual(rebuilt.items[1].title, "Living Room", "and the one playing leads the list")
    }

    /// A device that refuses is not a change: no haptic, no re-read to a state
    /// that did not happen.
    func testARefusedSelectionIsNotAChange() {
        selectSucceeds = false
        let watch = audio()
        let controller = controller(watch)
        let menu = controller.makeMenu(includesVolume: false)
        fire(try! XCTUnwrap(menu.items.first { $0.title == "Living Room" }))
        XCTAssertEqual(selected, [44], "it was asked")
        XCTAssertEqual(haptics, 0)
        XCTAssertEqual(watch.current, 42)
    }

    func testSoundSettingsOpensSystemSettingsAtSound() {
        let controller = controller(audio())
        let menu = controller.makeMenu(includesVolume: false)
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
