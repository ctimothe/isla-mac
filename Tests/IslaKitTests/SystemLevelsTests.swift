import CoreAudio
import CoreGraphics
import XCTest
@testable import IslaKit

// MARK: - Fakes

/// A volume that is a value: no device, no CoreAudio. It models the one thing
/// that makes the real one dangerous — the default output can change between a
/// read and a write.
@MainActor
final class FakeVolumeOutput: VolumeOutput {
    /// nil is an output with no volume Isla can set.
    var state: (level: Float, muted: Bool)?
    /// What `AudioOutputs.current()` would answer now.
    var defaultDevice: AudioDeviceID
    /// If set, the default output becomes this right after the next `read()`:
    /// AirPods connecting in the middle of a press.
    var switchDefaultAfterRead: AudioDeviceID?
    var writeSucceeds = true
    private(set) var writes: [(device: AudioDeviceID, level: Float, muted: Bool)] = []
    private(set) var reads = 0

    init(level: Float = 0.5, muted: Bool = false, device: AudioDeviceID = 42) {
        state = (level, muted)
        defaultDevice = device
    }

    func read() -> VolumeState? {
        reads += 1
        guard let state else { return nil }
        let reading = VolumeState(device: defaultDevice, level: state.level, muted: state.muted)
        if let next = switchDefaultAfterRead { defaultDevice = next; switchDefaultAfterRead = nil }
        return reading
    }

    func write(level: Float, muted: Bool, from old: VolumeState) -> VolumeWriteResult {
        guard defaultDevice == old.device else { return .deviceChanged }
        writes.append((old.device, level, muted))
        guard writeSucceeds else { return .failed }
        state = (level, muted)
        return .written
    }
}

final class FakeDisplayClient: DisplayBrightnessClient {
    var value: Float
    var sets: [(Float, CGDirectDisplayID)] = []
    init(_ value: Float) { self.value = value }
    func brightness(of display: CGDirectDisplayID) -> Float? { value }
    func setBrightness(_ new: Float, of display: CGDirectDisplayID) -> Bool {
        sets.append((new, display))
        value = new
        return true
    }
}

/// "Present" or "missing", the two answers a resolver can give, and how many
/// times it was asked: resolving loads a private framework.
final class FakeDisplayResolver: DisplayBrightnessResolver {
    var client: DisplayBrightnessClient?
    private(set) var resolves = 0
    init(client: DisplayBrightnessClient?) { self.client = client }
    func resolve() -> DisplayBrightnessClient? { resolves += 1; return client }
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

final class FakeKeyboardResolver: KeyboardBrightnessResolver {
    var client: KeyboardBrightnessClient?
    private(set) var resolves = 0
    init(client: KeyboardBrightnessClient?) { self.client = client }
    func resolve() -> KeyboardBrightnessClient? { resolves += 1; return client }
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

    /// The built-in display alone (`builtIn` an id), or a lone external one.
    private func lone(_ builtIn: CGDirectDisplayID?) -> DisplayTopology {
        guard let builtIn else { return DisplayTopology(builtIn: nil, active: [9], main: 9) }
        return DisplayTopology(builtIn: builtIn, active: [builtIn], main: builtIn)
    }

    private func applier(
        volume: FakeVolumeOutput = FakeVolumeOutput(),
        display: DisplayBrightnessClient? = nil, builtIn: CGDirectDisplayID? = 1,
        keyboard: KeyboardBrightnessClient? = nil
    ) -> SystemLevelApplier {
        SystemLevelApplier(
            volume: volume,
            displays: FakeDisplayResolver(client: display),
            topology: { [self] in lone(builtIn) },
            keyboards: FakeKeyboardResolver(client: keyboard)
        )
    }

    func testVolumeKeysStepTheVolumeAndReportIt() {
        let volume = FakeVolumeOutput(level: 0.5, device: 77)
        let sut = applier(volume: volume)
        XCTAssertEqual(
            sut.apply(.volumeUp, fine: false),
            HUDReading(kind: .volume, level: 0.5625, muted: false, deviceSymbol: nil, outputDevice: 77),
            "the device travels with the reading; its glyph is found after the tap's callback"
        )
        XCTAssertEqual(sut.apply(.volumeDown, fine: true)?.level, 0.546875, "a fine step down")
        XCTAssertEqual(volume.state?.level, 0.546875, "written to the device")
        XCTAssertEqual(volume.writes.map(\.device), [77, 77])
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

    // MARK: The output device is latched across a press

    /// AirPods connecting between the read and the write: the level worked out
    /// from the speakers must not be written to the headphones.
    func testADefaultOutputThatChangesBetweenReadAndWriteIsNeverWrittenTo() {
        let volume = FakeVolumeOutput(level: 0.9, device: 1)
        volume.switchDefaultAfterRead = 2
        let sut = applier(volume: volume)
        XCTAssertNil(sut.apply(.volumeDown, fine: false), "passed through: the system handles the new device")
        XCTAssertTrue(volume.writes.isEmpty, "neither the old device nor the new one was written")
        XCTAssertEqual(volume.defaultDevice, 2)

        // The next press starts from the new device and lands on it.
        let reading = sut.apply(.volumeDown, fine: false)
        XCTAssertEqual(reading?.outputDevice, 2)
        XCTAssertEqual(volume.writes.map(\.device), [2])
    }

    func testAMuteThatStraddlesADeviceChangeIsPassedThroughToo() {
        let volume = FakeVolumeOutput(level: 0.5, device: 1)
        volume.switchDefaultAfterRead = 2
        XCTAssertNil(applier(volume: volume).apply(.mute, fine: false))
        XCTAssertTrue(volume.writes.isEmpty)
    }

    // MARK: Display brightness follows the display in use

    func testOnlyABuiltInDisplayThatIsInUseIsDimmedByTheKey() {
        // Built-in alone.
        XCTAssertEqual(BuiltInDisplay.target(DisplayTopology(builtIn: 1, active: [1], main: 1)), 1)
        // Built-in is the main display, with an external beside it.
        XCTAssertEqual(BuiltInDisplay.target(DisplayTopology(builtIn: 1, active: [1, 2], main: 1)), 1)
        // An external monitor is the main display: the key is the system's.
        XCTAssertNil(BuiltInDisplay.target(DisplayTopology(builtIn: 1, active: [1, 2], main: 2)))
        // Clamshell: no built-in display is active.
        XCTAssertNil(BuiltInDisplay.target(DisplayTopology(builtIn: nil, active: [2], main: 2)))
        // A built-in id that is not in the active list is not a target either.
        XCTAssertNil(BuiltInDisplay.target(DisplayTopology(builtIn: 1, active: [2], main: 2)))
    }

    func testTheApplierPassesBrightnessThroughWhenAnExternalMonitorIsMain() {
        let client = FakeDisplayClient(0.5)
        func sut(_ topology: DisplayTopology) -> SystemLevelApplier {
            SystemLevelApplier(
                volume: FakeVolumeOutput(), displays: FakeDisplayResolver(client: client),
                topology: { topology }, keyboards: FakeKeyboardResolver(client: nil)
            )
        }
        XCTAssertNotNil(sut(DisplayTopology(builtIn: 1, active: [1, 2], main: 1)).apply(.brightnessUp, fine: false))
        XCTAssertEqual(client.sets.last?.1, 1)
        client.sets.removeAll()
        XCTAssertNil(sut(DisplayTopology(builtIn: 1, active: [1, 2], main: 2)).apply(.brightnessUp, fine: false))
        XCTAssertNil(sut(DisplayTopology(builtIn: nil, active: [2], main: 2)).apply(.brightnessDown, fine: false))
        XCTAssertTrue(client.sets.isEmpty, "no display was touched")
    }

    // MARK: The private clients are resolved once, never by a press

    func testTheClientsAreResolvedOncePerPrepareAndNeverByAPress() {
        let displays = FakeDisplayResolver(client: FakeDisplayClient(0.5))
        let keyboards = FakeKeyboardResolver(client: FakeKeyboardClient(0.5))
        let sut = SystemLevelApplier(
            volume: FakeVolumeOutput(), displays: displays, topology: { [self] in lone(1) }, keyboards: keyboards
        )
        sut.prepare()
        XCTAssertEqual(displays.resolves, 1)
        XCTAssertEqual(keyboards.resolves, 1)
        for _ in 0..<20 {
            _ = sut.apply(.brightnessUp, fine: false)
            _ = sut.apply(.keyboardBrightnessUp, fine: false)
            _ = sut.apply(.volumeUp, fine: false)
        }
        XCTAssertEqual(displays.resolves, 1, "twenty presses, no second resolve")
        XCTAssertEqual(keyboards.resolves, 1)
        sut.prepare()
        XCTAssertEqual(displays.resolves, 2, "a tap restart resolves again")
        XCTAssertEqual(keyboards.resolves, 2)
    }

    func testAMissIsCachedUntilTheTapIsRestarted() {
        let displays = FakeDisplayResolver(client: nil)
        let keyboards = FakeKeyboardResolver(client: nil)
        let sut = SystemLevelApplier(
            volume: FakeVolumeOutput(), displays: displays, topology: { [self] in lone(1) }, keyboards: keyboards
        )
        sut.prepare()
        for _ in 0..<20 {
            XCTAssertNil(sut.apply(.brightnessUp, fine: false))
            XCTAssertNil(sut.apply(.keyboardBrightnessDown, fine: false))
        }
        XCTAssertEqual(displays.resolves, 1, "a client that was missing is not asked for on every press")
        XCTAssertEqual(keyboards.resolves, 1)

        // The framework turns up (a macOS update, a retry): the next tap start finds it.
        displays.client = FakeDisplayClient(0.5)
        XCTAssertNil(sut.apply(.brightnessUp, fine: false), "not before the tap restarts")
        sut.prepare()
        XCTAssertNotNil(sut.apply(.brightnessUp, fine: false))
    }

    func testAnApplierNobodyPreparedResolvesLazilyOnceAndNotAgain() {
        let displays = FakeDisplayResolver(client: nil)
        let sut = SystemLevelApplier(
            volume: FakeVolumeOutput(), displays: displays, topology: { [self] in lone(1) },
            keyboards: FakeKeyboardResolver(client: nil)
        )
        _ = sut.apply(.brightnessUp, fine: false)
        _ = sut.apply(.brightnessUp, fine: false)
        XCTAssertEqual(displays.resolves, 1)
    }

    // MARK: The keyboard id comes from the backlight list and nowhere else

    func testNoKeyboardBacklightListMeansNoKeyboardClient() {
        // The selector is missing: no guessing id 1.
        XCTAssertNil(CoreBrightnessResolver.keyboardID(responds: false, list: [NSNumber(value: 5)]))
        // The selector answered nil, or something that is not a list.
        XCTAssertNil(CoreBrightnessResolver.keyboardID(responds: true, list: nil))
        XCTAssertNil(CoreBrightnessResolver.keyboardID(responds: true, list: "1"))
        XCTAssertNil(CoreBrightnessResolver.keyboardID(responds: true, list: NSNumber(value: 1)))
        // A Mac with no backlight answers an empty list; a list with no number in it is no list.
        XCTAssertNil(CoreBrightnessResolver.keyboardID(responds: true, list: [Any]()))
        XCTAssertNil(CoreBrightnessResolver.keyboardID(responds: true, list: ["a"]))
        // Only an id from the list is used — the first.
        XCTAssertEqual(CoreBrightnessResolver.keyboardID(responds: true, list: [NSNumber(value: 7), NSNumber(value: 8)]), 7)
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
