import Foundation
import XCTest
@testable import IslaKit

/// Spec 12.2 and E-56: every `prompter.*` setting is typed, clamped on load as
/// well as on write, and a hand-edited plist (NaN, infinity, a wrong type, an
/// enum value this release does not know, a number out of range) loads as the
/// default or the nearest value in range, with no crash and no write back.
///
/// Every test runs on `InMemoryDefaults`. None touches `UserDefaults.standard`
/// or a suite of it: the old store's NaN overflowed the stack on a real
/// machine, and a test that wrote a NaN into the machine's own defaults would
/// leave the next launch to find it.
@MainActor
final class PrompterSettingsTests: XCTestCase {
    private typealias Key = PrompterSettings.Key

    private func load(_ stored: [String: Any]) -> PrompterSettingsValues {
        let defaults = InMemoryDefaults(stored)
        let values = PrompterSettingsValues.load(from: defaults)
        XCTAssertTrue(defaults.writes.isEmpty, "loading must never write, or a bad value would feed back into the plist")
        return values
    }

    // MARK: The table

    func testNothingStoredLoadsTheSpecDefaults() {
        let values = load([:])
        XCTAssertEqual(values.mode, .classic)
        XCTAssertEqual(values.speed, 3.0)
        XCTAssertEqual(values.fontSize, .lg)
        XCTAssertEqual(values.fontFamily, .sans)
        XCTAssertEqual(values.highlight, .white)
        XCTAssertEqual(values.cueColor, .white)
        XCTAssertEqual(values.cueBrightness, .dim)
        XCTAssertEqual(values.readingPosition, .centered)
        XCTAssertEqual(values.columnWidth, 360)
        XCTAssertFalse(values.paragraphDividers)
        XCTAssertTrue(values.showLastSpoken)
        XCTAssertTrue(values.showElapsed)
        XCTAssertTrue(values.keepAwake)
        XCTAssertFalse(values.autoNext)
        XCTAssertEqual(values.autoNextDelay, 3)
        XCTAssertEqual(values, .defaults)
    }

    /// Release 1 owns exactly these keys. The microphone, speech-language,
    /// Apple-processing and document-folder keys belong to releases 2 to 4 and
    /// must not exist yet: a key with no feature behind it is a control
    /// waiting to be drawn for something that does not work.
    func testTheKeysAreExactlyReleaseOnesRowsOfTheTable() {
        XCTAssertEqual(Key.enabled, "prompter.enabled")
        XCTAssertEqual(Set(Key.settings), [
            "prompter.mode", "prompter.speed", "prompter.fontSize", "prompter.fontFamily",
            "prompter.highlight", "prompter.cueColor", "prompter.cueBrightness",
            "prompter.readingPosition", "prompter.columnWidth", "prompter.paragraphDividers",
            "prompter.showLastSpoken", "prompter.showElapsed", "prompter.keepAwake",
            "prompter.autoNext", "prompter.autoNextDelay",
        ])
        XCTAssertEqual(Key.settings.count, Set(Key.settings).count, "no key listed twice")
        XCTAssertFalse(Key.settings.contains(Key.enabled), "the switch is the feature's, not a setting Reset can clear")
        for later in ["prompter.micUID", "prompter.speechLocale", "prompter.allowAppleSpeech", "prompter.lastDocumentFolder"] {
            XCTAssertFalse(Key.settings.contains(later), "\(later) is not a release 1 setting")
        }
    }

    func testTheEnumsCarryTheSpecOptions() {
        XCTAssertEqual(PrompterGuidanceMode.allCases.map(\.rawValue), ["classic"], "Voice and Follow arrive with their engines")
        XCTAssertEqual(PrompterFontSize.allCases.map(\.rawValue), ["xs", "sm", "lg", "xl"])
        XCTAssertEqual(PrompterFontSize.allCases.map(\.points), [18, 22, 26, 32])
        XCTAssertEqual(PrompterFontFamily.allCases.map(\.rawValue), ["sans", "serif", "mono", "dyslexia"])
        XCTAssertEqual(PrompterTint.allCases.map(\.rawValue), ["white", "yellow", "green", "blue", "pink", "orange"])
        XCTAssertEqual(PrompterCueBrightness.allCases.map(\.rawValue), ["dim", "low", "medium", "bright"])
        XCTAssertEqual(PrompterReadingPosition.allCases.map(\.rawValue), ["centered", "nearTop"])
        XCTAssertEqual(PrompterSettingsValues.autoNextDelays, [0, 1, 3, 5])
        XCTAssertEqual(Set(PrompterSettingsValues.autoNextDelays), PrompterSession.allowedCountdowns, "the setting and the session agree")
        XCTAssertEqual(PrompterSettingsValues.defaultAutoNextDelay, PrompterSession.defaultCountdown)
        XCTAssertEqual(PrompterSettingsValues.defaults.speed, PromptClock.defaultSpeed)
        XCTAssertEqual(PrompterSettingsValues.columnWidthRange, 280...560)
    }

    // MARK: Clamp on load

    /// The old store overflowed the stack on a NaN from a hand-edited plist.
    func testNonFiniteNumbersLoadAsTheDefault() {
        for bad in [Double.nan, .infinity, -.infinity, Double.signalingNaN] {
            let values = load([Key.speed: bad, Key.columnWidth: bad])
            XCTAssertEqual(values.speed, 3.0, "speed \(bad)")
            XCTAssertEqual(values.columnWidth, 360, "column width \(bad)")
        }
    }

    func testOutOfRangeNumbersClampToTheNearestEnd() {
        XCTAssertEqual(load([Key.speed: 100.0]).speed, 8)
        XCTAssertEqual(load([Key.speed: 0.0]).speed, 0.5)
        XCTAssertEqual(load([Key.speed: -4.0]).speed, 0.5)
        XCTAssertEqual(load([Key.columnWidth: 10.0]).columnWidth, 280)
        XCTAssertEqual(load([Key.columnWidth: 99_999.0]).columnWidth, 560)
        XCTAssertEqual(load([Key.columnWidth: -360.0]).columnWidth, 280)
    }

    /// 0.5 words per second steps, the same rule the clock applies (ruling
    /// 20.2 #3), so a stored 3.3 and a live 3.3 read the same.
    func testSpeedSnapsToItsStep() {
        XCTAssertEqual(load([Key.speed: 3.3]).speed, 3.5)
        XCTAssertEqual(load([Key.speed: 3.2]).speed, 3.0)
        XCTAssertEqual(load([Key.speed: 7.9]).speed, 8.0)
    }

    func testIntegersAreAcceptedWhereADoubleIsExpected() {
        XCTAssertEqual(load([Key.speed: 4]).speed, 4)
        XCTAssertEqual(load([Key.columnWidth: 420]).columnWidth, 420)
    }

    func testInRangeValuesLoadAsStored() {
        let values = load([
            Key.mode: "classic", Key.speed: 5.5, Key.fontSize: "xl", Key.fontFamily: "dyslexia",
            Key.highlight: "yellow", Key.cueColor: "pink", Key.cueBrightness: "bright",
            Key.readingPosition: "nearTop", Key.columnWidth: 300.0, Key.paragraphDividers: true,
            Key.showLastSpoken: false, Key.showElapsed: false, Key.keepAwake: false,
            Key.autoNext: true, Key.autoNextDelay: 5,
        ])
        XCTAssertEqual(values.speed, 5.5)
        XCTAssertEqual(values.fontSize, .xl)
        XCTAssertEqual(values.fontFamily, .dyslexia)
        XCTAssertEqual(values.highlight, .yellow)
        XCTAssertEqual(values.cueColor, .pink)
        XCTAssertEqual(values.cueBrightness, .bright)
        XCTAssertEqual(values.readingPosition, .nearTop)
        XCTAssertEqual(values.columnWidth, 300)
        XCTAssertTrue(values.paragraphDividers)
        XCTAssertFalse(values.showLastSpoken)
        XCTAssertFalse(values.showElapsed)
        XCTAssertFalse(values.keepAwake)
        XCTAssertTrue(values.autoNext)
        XCTAssertEqual(values.autoNextDelay, 5)
    }

    /// A later release writes "voice" or "follow"; this one reads it as the
    /// mode it has, and leaves the stored value alone for the release that
    /// wrote it (no write on load, checked by `load`).
    func testUnknownEnumValuesLoadAsTheDefault() {
        let values = load([
            Key.mode: "voice", Key.fontSize: "huge", Key.fontFamily: "comic",
            Key.highlight: "purple", Key.cueColor: "", Key.cueBrightness: "BRIGHT",
            Key.readingPosition: "bottom",
        ])
        XCTAssertEqual(values.mode, .classic)
        XCTAssertEqual(values.fontSize, .lg)
        XCTAssertEqual(values.fontFamily, .sans)
        XCTAssertEqual(values.highlight, .white)
        XCTAssertEqual(values.cueColor, .white)
        XCTAssertEqual(values.cueBrightness, .dim, "raw values are case-sensitive")
        XCTAssertEqual(values.readingPosition, .centered)
        XCTAssertEqual(load([Key.mode: "follow"]).mode, .classic)
    }

    /// A Bool where a number belongs, a string where a Bool belongs, an array
    /// where an enum belongs: the default, never a coercion. `UserDefaults`'s
    /// own `bool(forKey:)` would read the string "YES" as true and
    /// `double(forKey:)` would read "3" as 3; a hand-edited value of the
    /// wrong type is a mistake, not an instruction.
    func testWrongTypesLoadAsTheDefault() {
        let values = load([
            Key.mode: 0, Key.speed: "fast", Key.fontSize: ["lg"], Key.fontFamily: 1,
            Key.highlight: true, Key.cueColor: 2.0, Key.cueBrightness: Data(),
            Key.readingPosition: ["nearTop": true], Key.columnWidth: "400",
            Key.paragraphDividers: "YES", Key.showLastSpoken: "NO", Key.showElapsed: [false],
            Key.keepAwake: 7, Key.autoNext: 1, Key.autoNextDelay: "5",
        ])
        XCTAssertEqual(values, .defaults)
        XCTAssertEqual(load([Key.speed: true]).speed, 3.0, "a Bool is not a speed")
        XCTAssertEqual(load([Key.columnWidth: false]).columnWidth, 360)
        XCTAssertEqual(load([Key.autoNextDelay: true]).autoNextDelay, 3, "true is not one second")
        XCTAssertEqual(load([Key.keepAwake: 0]).keepAwake, true, "0 is a number, not off")
    }

    /// Ruling 20.2 #9: anything outside 0, 1, 3, 5 is 3, so a hand-edited
    /// value cannot schedule a 10,000-second countdown or a negative one.
    func testAutoNextDelayAcceptsOnlyItsListedSteps() {
        for delay in [0, 1, 3, 5] {
            XCTAssertEqual(load([Key.autoNextDelay: delay]).autoNextDelay, delay)
        }
        for bad: Any in [2, 4, 10, -1, 10_000, 2.5, Double.nan, Double.infinity] {
            XCTAssertEqual(load([Key.autoNextDelay: bad]).autoNextDelay, 3, "\(bad)")
        }
        XCTAssertEqual(load([Key.autoNextDelay: 5.0]).autoNextDelay, 5, "an integral double is the integer")
    }

    // MARK: Writing

    /// Constructing the settings reads; it must not write a single key, or
    /// opening Settings once would fill the plist with defaults.
    func testConstructingWritesNothing() {
        let defaults = InMemoryDefaults([Key.speed: Double.nan, Key.mode: "voice"])
        let settings = PrompterSettings(defaults: defaults)
        XCTAssertEqual(settings.speed, 3.0)
        XCTAssertTrue(defaults.writes.isEmpty)
    }

    func testSettersClampBeforeTheyStore() {
        let defaults = InMemoryDefaults()
        let settings = PrompterSettings(defaults: defaults)

        settings.speed = 20
        XCTAssertEqual(settings.speed, 8)
        XCTAssertEqual(defaults.double(Key.speed), 8)

        settings.speed = .nan
        XCTAssertEqual(settings.speed, 3, "NaN is the default on write as on load")

        settings.columnWidth = 1
        XCTAssertEqual(settings.columnWidth, 280)
        XCTAssertEqual(defaults.double(Key.columnWidth), 280)

        settings.autoNextDelay = 4
        XCTAssertEqual(settings.autoNextDelay, 3)
        settings.autoNextDelay = 0
        XCTAssertEqual(defaults.storage[Key.autoNextDelay] as? Int, 0)
    }

    /// One change writes one key; setting what is already there writes
    /// nothing.
    func testASetterWritesOnlyItsOwnKeyAndOnlyOnAChange() {
        let defaults = InMemoryDefaults()
        let settings = PrompterSettings(defaults: defaults)
        settings.highlight = .white
        settings.speed = 3
        XCTAssertTrue(defaults.writes.isEmpty, "the values already in force")
        settings.highlight = .green
        XCTAssertEqual(defaults.writes, [Key.highlight])
        XCTAssertEqual(defaults.storage[Key.highlight] as? String, "green")
    }

    func testEverySettingRoundTrips() {
        let defaults = InMemoryDefaults()
        let settings = PrompterSettings(defaults: defaults)
        settings.mode = .classic
        settings.speed = 1.5
        settings.fontSize = .xs
        settings.fontFamily = .mono
        settings.highlight = .orange
        settings.cueColor = .blue
        settings.cueBrightness = .medium
        settings.readingPosition = .nearTop
        settings.columnWidth = 512
        settings.paragraphDividers = true
        settings.showLastSpoken = false
        settings.showElapsed = false
        settings.keepAwake = false
        settings.autoNext = true
        settings.autoNextDelay = 1

        let reread = PrompterSettings(defaults: defaults)
        XCTAssertEqual(reread.values, settings.values)
        XCTAssertNotEqual(reread.values, .defaults)
        XCTAssertTrue(defaults.writes.allSatisfy { $0.hasPrefix("prompter.") })
    }

    /// Spec 5.3: Reset Prompter Settings does not touch scripts, and it does
    /// not turn the feature off either.
    func testResetForgetsEverySettingButNotTheSwitch() {
        let defaults = InMemoryDefaults([Key.enabled: true, "unrelated": 1])
        let settings = PrompterSettings(defaults: defaults)
        settings.speed = 6
        settings.highlight = .pink
        settings.autoNext = true

        settings.reset()

        XCTAssertEqual(settings.values, .defaults)
        XCTAssertEqual(defaults.storage[Key.enabled] as? Bool, true)
        XCTAssertEqual(defaults.storage["unrelated"] as? Int, 1)
        for key in Key.settings {
            XCTAssertNil(defaults.storage[key], "\(key) survives reset")
        }
    }

    /// Settings views observe the object; a change has to say so.
    func testAChangeIsPublished() {
        let settings = PrompterSettings(defaults: InMemoryDefaults())
        var announced = 0
        let token = settings.objectWillChange.sink { announced += 1 }
        settings.fontSize = .xl
        settings.fontSize = .xl
        XCTAssertEqual(announced, 1, "a real change once, a repeat not at all")
        token.cancel()
    }

    // MARK: The seam

    func testUserDefaultsIsADefaults() {
        // A type-level check: constructing one would mean a suite of the
        // machine's real defaults.
        let type: Defaults.Type = UserDefaults.self
        XCTAssertTrue(type == UserDefaults.self)
    }

    func testTheFakeRecordsWritesAndRemovals() {
        let defaults = InMemoryDefaults()
        defaults.set(1, forKey: "a")
        defaults.removeObject(forKey: "a")
        defaults.set(nil, forKey: "b")
        XCTAssertEqual(defaults.writes, ["a", "a", "b"])
        XCTAssertNil(defaults.object(forKey: "a"))
        XCTAssertNil(defaults.object(forKey: "b"))
    }
}

private extension InMemoryDefaults {
    func double(_ key: String) -> Double? { (storage[key] as? NSNumber)?.doubleValue }
}
