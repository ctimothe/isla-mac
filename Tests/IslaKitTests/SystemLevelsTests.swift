import CoreGraphics
import XCTest
@testable import IslaKit

// MARK: - Fakes

/// A volume that is a value: no device, no CoreAudio.
@MainActor
final class FakeVolumeOutput: VolumeOutput {
    var state: (level: Float, muted: Bool, deviceSymbol: String?)?
    var writeSucceeds = true
    private(set) var writes: [(level: Float, muted: Bool)] = []

    init(level: Float = 0.5, muted: Bool = false, symbol: String? = nil) {
        state = (level, muted, symbol)
    }

    func read() -> (level: Float, muted: Bool, deviceSymbol: String?)? { state }

    func write(level: Float, muted: Bool, from old: (level: Float, muted: Bool)) -> Bool {
        writes.append((level, muted))
        guard writeSucceeds else { return false }
        state?.level = level
        state?.muted = muted
        return true
    }
}

final class FakeDisplayClient: DisplayBrightnessClient {
    var value: Float
    private(set) var sets: [(Float, CGDirectDisplayID)] = []
    init(_ value: Float) { self.value = value }
    func brightness(of display: CGDirectDisplayID) -> Float? { value }
    func setBrightness(_ new: Float, of display: CGDirectDisplayID) -> Bool {
        sets.append((new, display))
        value = new
        return true
    }
}

/// "Present" or "missing", the two answers a resolver can give.
struct FakeDisplayResolver: DisplayBrightnessResolver {
    var client: DisplayBrightnessClient?
    func resolve() -> DisplayBrightnessClient? { client }
}

final class FakeKeyboardClient: KeyboardBrightnessClient {
    var value: Float
    private(set) var sets: [Float] = []
    init(_ value: Float) { self.value = value }
    func brightness() -> Float? { value }
    func setBrightness(_ new: Float) -> Bool {
        sets.append(new)
        value = new
        return true
    }
}

struct FakeKeyboardResolver: KeyboardBrightnessResolver {
    var client: KeyboardBrightnessClient?
    func resolve() -> KeyboardBrightnessClient? { client }
}

/// The step arithmetic and the applier (spec §12). No test here reads or
/// writes a real volume or brightness: every collaborator is a fake.
@MainActor
final class SystemLevelsTests: XCTestCase {

    // MARK: Arithmetic

    func testSixteenCoarseStepsCoverTheRange() {
        XCTAssertEqual(HUDStep.coarse, 1.0 / 16.0)
        XCTAssertEqual(HUDStep.fine, 1.0 / 64.0, "⌥⇧ gives quarter steps")
        XCTAssertEqual(HUDStep.coarse / HUDStep.fine, 4)
        var level: Float = 0
        for _ in 0..<16 { level = HUDStep.stepped(level, raising: true, fine: false) }
        XCTAssertEqual(level, 1, "sixteen presses from silence to full, exactly")
        for _ in 0..<64 { level = HUDStep.stepped(level, raising: false, fine: true) }
        XCTAssertEqual(level, 0, "sixty-four fine presses back down")
    }

    func testStepsClampAtBothEnds() {
        XCTAssertEqual(HUDStep.stepped(1, raising: true, fine: false), 1)
        XCTAssertEqual(HUDStep.stepped(0.99, raising: true, fine: false), 1)
        XCTAssertEqual(HUDStep.stepped(0, raising: false, fine: false), 0)
        XCTAssertEqual(HUDStep.stepped(0.01, raising: false, fine: true), 0)
        XCTAssertEqual(HUDStep.stepped(0.5, raising: true, fine: false), 0.5625)
        XCTAssertEqual(HUDStep.stepped(0.5, raising: false, fine: true), 0.484375)
    }

    func testMuteKeepsTheLevelAndTogglesTheMute() {
        var result = HUDStep.volume(after: .mute, level: 0.4, muted: false, fine: false)
        XCTAssertEqual(result.level, 0.4)
        XCTAssertTrue(result.muted)
        result = HUDStep.volume(after: .mute, level: 0.4, muted: true, fine: false)
        XCTAssertEqual(result.level, 0.4, "the level it returns to is never lost")
        XCTAssertFalse(result.muted)
    }

    func testVolumeUpWhileMutedUnmutesAsMacOSDoes() {
        let result = HUDStep.volume(after: .volumeUp, level: 0.4, muted: true, fine: false)
        XCTAssertFalse(result.muted)
        XCTAssertEqual(result.level, 0.4625, accuracy: 0.0001, "and still raises the level")
        // Even at the top, where the level cannot move.
        XCTAssertFalse(HUDStep.volume(after: .volumeUp, level: 1, muted: true, fine: false).muted)
        // Volume down behind a mute lowers the level and stays muted.
        let down = HUDStep.volume(after: .volumeDown, level: 0.4, muted: true, fine: false)
        XCTAssertTrue(down.muted)
        XCTAssertEqual(down.level, 0.3375, accuracy: 0.0001)
    }

    func testKeysMapToTheirFamily() {
        XCTAssertEqual(MediaKey.volumeUp.kind, .volume)
        XCTAssertEqual(MediaKey.mute.kind, .volume)
        XCTAssertEqual(MediaKey.brightnessDown.kind, .display)
        XCTAssertEqual(MediaKey.keyboardBrightnessUp.kind, .keyboard)
        XCTAssertNil(MediaKey.mute.raises)
        XCTAssertEqual(MediaKey.brightnessUp.raises, true)
        XCTAssertEqual(MediaKey.keyboardBrightnessDown.raises, false)
    }

    // MARK: Volume

    private func applier(
        volume: FakeVolumeOutput = FakeVolumeOutput(),
        display: DisplayBrightnessClient? = nil, builtIn: CGDirectDisplayID? = 1,
        keyboard: KeyboardBrightnessClient? = nil
    ) -> SystemLevelApplier {
        SystemLevelApplier(
            volume: volume,
            displays: FakeDisplayResolver(client: display),
            builtInDisplay: { builtIn },
            keyboards: FakeKeyboardResolver(client: keyboard)
        )
    }

    func testVolumeKeysStepTheVolumeAndReportIt() {
        let volume = FakeVolumeOutput(level: 0.5, symbol: "laptopcomputer")
        let sut = applier(volume: volume)
        XCTAssertEqual(
            sut.apply(.volumeUp, fine: false),
            HUDReading(kind: .volume, level: 0.5625, muted: false, deviceSymbol: "laptopcomputer")
        )
        XCTAssertEqual(sut.apply(.volumeDown, fine: true)?.level, 0.546875, "a fine step down")
        XCTAssertEqual(volume.state?.level, 0.546875, "written to the device")
    }

    func testMuteKeepsTheLevelAndUnmuteRestoresIt() {
        let volume = FakeVolumeOutput(level: 0.5)
        let sut = applier(volume: volume)
        let muted = sut.apply(.mute, fine: false)
        XCTAssertEqual(muted?.muted, true)
        XCTAssertEqual(muted?.level, 0.5, "the bar keeps the level")
        XCTAssertEqual(volume.state?.level, 0.5, "and the device keeps it")
        let back = sut.apply(.mute, fine: false)
        XCTAssertEqual(back?.muted, false)
        XCTAssertEqual(back?.level, 0.5)
    }

    func testVolumeUpWhileMutedUnmutesInTheApplierToo() {
        let volume = FakeVolumeOutput(level: 0.25, muted: true)
        let reading = applier(volume: volume).apply(.volumeUp, fine: false)
        XCTAssertEqual(reading?.muted, false)
        XCTAssertEqual(volume.state?.muted, false)
        XCTAssertEqual(volume.writes.last?.muted, false)
    }

    func testAVolumeAtItsLimitIsStillApplied() {
        let reading = applier(volume: FakeVolumeOutput(level: 1)).apply(.volumeUp, fine: false)
        XCTAssertEqual(reading?.level, 1, "clamped, shown, consumed")
    }

    func testAnOutputWithNoSettableVolumeLeavesTheVolumeKeysToTheSystem() {
        let volume = FakeVolumeOutput()
        volume.state = nil
        let sut = applier(volume: volume)
        for key in [MediaKey.volumeUp, .volumeDown, .mute] {
            XCTAssertNil(sut.apply(key, fine: false), "\(key) is not Isla's to take")
        }
        XCTAssertTrue(volume.writes.isEmpty)
    }

    func testAWriteTheDeviceRefusesIsNotConsumed() {
        let volume = FakeVolumeOutput()
        volume.writeSucceeds = false
        XCTAssertNil(applier(volume: volume).apply(.volumeUp, fine: false),
                     "a key whose effect did not land is the system's, which has another way to try")
    }

    // MARK: Display brightness

    func testDisplayBrightnessStepsOnTheBuiltInDisplay() {
        let client = FakeDisplayClient(0.5)
        let sut = applier(display: client, builtIn: 7)
        XCTAssertEqual(sut.apply(.brightnessUp, fine: false),
                       HUDReading(kind: .display, level: 0.5625, muted: false, deviceSymbol: nil))
        XCTAssertEqual(client.sets.last?.1, 7, "the built-in display, by its id")
        XCTAssertEqual(sut.apply(.brightnessDown, fine: true)?.level, 0.546875)
        client.value = 0
        XCTAssertEqual(sut.apply(.brightnessDown, fine: false)?.level, 0, "clamped at black")
    }

    func testAMissingDisplayServicesSymbolLeavesBrightnessToTheSystem() {
        let sut = applier(display: nil)
        XCTAssertNil(sut.apply(.brightnessUp, fine: false))
        XCTAssertNil(sut.apply(.brightnessDown, fine: false))
        // …without touching what does work.
        XCTAssertNotNil(sut.apply(.volumeUp, fine: false))
    }

    func testNoBuiltInDisplayLeavesBrightnessToTheSystem() {
        let client = FakeDisplayClient(0.5)
        let sut = applier(display: client, builtIn: nil)
        XCTAssertNil(sut.apply(.brightnessUp, fine: false))
        XCTAssertTrue(client.sets.isEmpty, "nothing was set on any display")
    }

    // MARK: Keyboard backlight

    func testKeyboardBrightnessStepsThroughTheClient() {
        let client = FakeKeyboardClient(0.25)
        let sut = applier(keyboard: client)
        XCTAssertEqual(sut.apply(.keyboardBrightnessUp, fine: false),
                       HUDReading(kind: .keyboard, level: 0.3125, muted: false, deviceSymbol: nil))
        XCTAssertEqual(sut.apply(.keyboardBrightnessDown, fine: false)?.level, 0.25)
    }

    func testAMissingCoreBrightnessSelectorLeavesTheIlluminationKeysToTheSystem() {
        let sut = applier(keyboard: nil)
        XCTAssertNil(sut.apply(.keyboardBrightnessUp, fine: false))
        XCTAssertNil(sut.apply(.keyboardBrightnessDown, fine: false))
    }

    func testEachFamilyDegradesOnItsOwn() {
        // Volume works, display and keyboard are missing: only those two pass through.
        let sut = applier(display: nil, keyboard: nil)
        XCTAssertNotNil(sut.apply(.mute, fine: false))
        XCTAssertNil(sut.apply(.brightnessUp, fine: false))
        XCTAssertNil(sut.apply(.keyboardBrightnessUp, fine: false))
    }

    /// The real resolvers are only asked in the app. Their paths are the
    /// private frameworks' and nothing else.
    func testTheResolversNameThePrivateFrameworksTheSpecNames() {
        XCTAssertEqual(
            DisplayServicesResolver.frameworkPath,
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        )
        XCTAssertEqual(
            CoreBrightnessResolver.frameworkPath,
            "/System/Library/PrivateFrameworks/CoreBrightness.framework"
        )
        XCTAssertEqual(
            SystemAccessibilityTrust.settingsURL.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
    }
}
