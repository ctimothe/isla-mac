# Line-synced lyrics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make line-synced lyrics the default while preserving optional word karaoke for enhanced local LRC files.

**Architecture:** `LyricsStore` owns one persistent `wordKaraokeEnabled` preference. `LyricsPresentation` is the single policy boundary: word sweep requires that preference, a word-timed timeline, and a measured player clock. All three lyric surfaces consume the same store-owned policy input.

**Tech Stack:** Swift 6, SwiftUI, Foundation, XCTest, shell localization gate.

## Global Constraints

- Lyrics remain offline and local-LRC only.
- **Show Lyrics** still controls whether lyrics render at all.
- Word Karaoke defaults to off and must never invent word timing.
- English and Russian user-visible strings must remain synchronized.
- Start red, use `apply_patch` for edits, and finish with `./scripts/check`.

---

### Task 1: Persist and apply the Word Karaoke preference

**Files:**
- Modify: `Sources/IslaKit/Services/LyricsStore.swift`
- Modify: `Sources/IslaKit/UI/LyricsPresentation.swift`
- Modify: `Sources/IslaKit/UI/MediaPane.swift`
- Modify: `Sources/IslaKit/UI/LyricsStage.swift`
- Modify: `Sources/IslaKit/UI/LockScreenCard.swift`
- Test: `Tests/IslaKitTests/SharedLyricTimelineTests.swift`

**Interfaces:**
- Produces `LyricsStore.wordKaraokeEnabled: Bool` and `LyricsStore.wordKaraokeEnabledKey`.
- Changes `LyricsPresentation.usesWordTiming` to accept `wordKaraokeEnabled: Bool`.

- [ ] **Step 1: Write failing policy and persistence tests.**

```swift
func testWordKaraokeDefaultsOffAndPersistsAnExplicitSelection() {
    UserDefaults.standard.removeObject(forKey: LyricsStore.wordKaraokeEnabledKey)
    defer { UserDefaults.standard.removeObject(forKey: LyricsStore.wordKaraokeEnabledKey) }

    let lyrics = LyricsStore()
    XCTAssertFalse(lyrics.wordKaraokeEnabled)
    lyrics.wordKaraokeEnabled = true
    XCTAssertTrue(UserDefaults.standard.bool(forKey: LyricsStore.wordKaraokeEnabledKey))
}

func testWordKaraokeRequiresPreferenceWordTimelineAndMeasuredClock() {
    XCTAssertFalse(LyricsPresentation.usesWordTiming(.word, precisionMeasured: true, wordKaraokeEnabled: false))
    XCTAssertFalse(LyricsPresentation.usesWordTiming(.line, precisionMeasured: true, wordKaraokeEnabled: true))
    XCTAssertFalse(LyricsPresentation.usesWordTiming(.word, precisionMeasured: false, wordKaraokeEnabled: true))
    XCTAssertTrue(LyricsPresentation.usesWordTiming(.word, precisionMeasured: true, wordKaraokeEnabled: true))
}
```

- [ ] **Step 2: Run the focused tests and observe red.**

Run: `swift test --filter SharedLyricTimelineTests`

Expected: compilation fails because `wordKaraokeEnabled` and the policy parameter do not exist.

- [ ] **Step 3: Add the store preference and shared policy.**

```swift
@Published var wordKaraokeEnabled = UserDefaults.standard.bool(forKey: LyricsStore.wordKaraokeEnabledKey) {
    didSet { UserDefaults.standard.set(wordKaraokeEnabled, forKey: LyricsStore.wordKaraokeEnabledKey) }
}
static let wordKaraokeEnabledKey = "lyrics.wordKaraokeEnabled"

static func usesWordTiming(
    _ granularity: LyricTimeline.Granularity?,
    precisionMeasured: Bool,
    wordKaraokeEnabled: Bool
) -> Bool {
    wordKaraokeEnabled && granularity == .word && precisionMeasured
}
```

Pass `lyrics.wordKaraokeEnabled` into every existing `usesWordTiming` call in the compact Music pane, full stage, and lock card.

- [ ] **Step 4: Run the focused tests and observe green.**

Run: `swift test --filter SharedLyricTimelineTests`

Expected: all selected tests pass.

- [ ] **Step 5: Commit.**

```bash
git add Sources/IslaKit/Services/LyricsStore.swift Sources/IslaKit/UI/LyricsPresentation.swift Sources/IslaKit/UI/MediaPane.swift Sources/IslaKit/UI/LyricsStage.swift Sources/IslaKit/UI/LockScreenCard.swift Tests/IslaKitTests/SharedLyricTimelineTests.swift
git commit -m "feat: make word karaoke optional"
```

### Task 2: Expose the preference in Settings

**Files:**
- Modify: `Sources/IslaKit/UI/SettingsPane.swift`
- Modify: `Resources/en.lproj/Localizable.strings`
- Modify: `Resources/ru.lproj/Localizable.strings`
- Test: `Tests/IslaKitTests/FirstRunTests.swift`

**Interfaces:**
- Consumes `LyricsStore.wordKaraokeEnabled` from Task 1.
- Produces a localized **Word Karaoke** Settings toggle below **Show Lyrics**.

- [ ] **Step 1: Write the failing localization assertion.**

```swift
func testWordKaraokeHasEnglishAndRussianTranslations() throws {
    for language in ["en", "ru"] {
        let table = try Self.table(language)
        XCTAssertTrue(table.contains("\"Word Karaoke\" = "), "\(language) is missing Word Karaoke")
    }
    XCTAssertNotEqual(Self.value(for: "Word Karaoke", in: try Self.table("ru")), "Word Karaoke")
}
```

- [ ] **Step 2: Run the test and observe red.**

Run: `swift test --filter FirstRunTests/testWordKaraokeHasEnglishAndRussianTranslations`

Expected: failure reporting the missing key.

- [ ] **Step 3: Add the Settings toggle and translations.**

```swift
toggleRow(
    symbol: SettingsIcon.lyrics,
    title: localized("Word Karaoke"),
    isOn: $lyrics.wordKaraokeEnabled
)
```

Place it immediately below **Show Lyrics**. Add exact key-value entries:

```strings
"Word Karaoke" = "Word Karaoke";
"Word Karaoke" = "Караоке по словам";
```

- [ ] **Step 4: Run focused tests and the localization gate.**

Run: `swift test --filter FirstRunTests/testWordKaraokeHasEnglishAndRussianTranslations && bash Scripts/test-localizations.sh`

Expected: test and localization gate pass.

- [ ] **Step 5: Commit.**

```bash
git add Sources/IslaKit/UI/SettingsPane.swift Resources/en.lproj/Localizable.strings Resources/ru.lproj/Localizable.strings Tests/IslaKitTests/FirstRunTests.swift
git commit -m "feat: add word karaoke setting"
```

## Final verification

- [ ] Run `git diff --check`.
- [ ] Run `./scripts/check`.
- [ ] Run `swift test --filter OfflineLyricsIsolationTests`.
- [ ] Run `bash Scripts/bundle.sh release` and `codesign --verify --deep --strict build/Isla.app`.
