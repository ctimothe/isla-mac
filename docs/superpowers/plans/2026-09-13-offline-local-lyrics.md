# Offline Local Lyrics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Replace Isla's brokered lyrics system with an entirely offline local-LRC library that matches conservatively, prefetches before a panel opens, and supports correction and export.

**Architecture:** LocalLyricsDocument owns LRC parsing and serializing; LocalLyricsLibrary owns imported files, selected folders, indexing, matching, bindings, migration, and file watching. LyricsCoordinator remains session-owned but resolves only through that library. LyricsStore remains the shared presentation and timing-offset store, stripped of all direct source/network code.

**Tech Stack:** Swift 6, SwiftUI, Combine, Foundation, AppKit, XCTest, shell test scripts, GitHub Actions.

## Global Constraints

- Lyrics must never open a network connection, use a token, invoke a provider, scrape a player, or silently download content.
- Only explicitly imported LRC files and files inside explicitly selected local folders may be read.
- Word sweep requires valid enhanced-LRC word timestamps and MediaController.precisionSync; every other timeline is line-level.
- Auto-match only one unambiguous candidate using the thresholds below. Ambiguity is an actionable local-file state, never a guessed match.
- Preserve the existing no-blank-caption, lock-card, Reduce Motion, VoiceOver, English, and Russian contracts.
- Do not touch the user-owned untracked file docs/research/2026-09-12-latent-failure-audit.md.
- Every code task starts with a failing focused test and ends with ../../scripts/check; use apply_patch for edits.
- No source under Sources/IslaKit/Services may retain a lyric URLSession request when this plan finishes.

---

## File structure

| Path | Responsibility |
|---|---|
| Sources/IslaKit/Services/LocalLyricsDocument.swift | Parse, validate, normalize, and serialize ordinary and enhanced LRC documents; define the app's local word-timing value. |
| Sources/IslaKit/Services/LocalLyricsLibrary.swift | Own imports, selected folders, index, watcher, conservative lookup, bindings, and v5 migration. |
| Sources/IslaKit/Services/LocalLyricsEditor.swift | Editable draft and export of an Isla-owned LRC copy. |
| Sources/IslaKit/UI/LocalLyricsEditorView.swift | Focused SwiftUI editor sheet using shared primitives and design tokens. |
| Sources/IslaKit/Services/LyricsCoordinator.swift | Session prefetch against LocalLyricsLibrary and local availability only. |
| Sources/IslaKit/Services/LyricsStore.swift | Shared UI timeline and timing nudges; no parser cache or networking. |
| Tests/IslaKitTests/LocalLyricsDocumentTests.swift | Parser, enhanced-word validity, and export round trips. |
| Tests/IslaKitTests/LocalLyricsLibraryTests.swift | Index, matching, binding, folder refresh, and migration. |
| Tests/IslaKitTests/LocalLyricsEditorTests.swift | Draft edits, owned-copy save, and export. |
| Tests/IslaKitTests/OfflineLyricsIsolationTests.swift | The lyric source path is entirely local. |
| docs/contributing-local-lyrics.md | LRC format, validator, fixture, and explicit-user-import contribution workflow. |

## Task 1: Establish local LRC documents

**Status:** complete

**Files:**
- Create: Sources/IslaKit/Services/LocalLyricsDocument.swift
- Create: Tests/IslaKitTests/LocalLyricsDocumentTests.swift
- Modify: Sources/IslaKit/Services/LyricsStore.swift
- Modify: Sources/IslaKit/Services/WordSyncedLyrics.swift

**Interfaces:**
- Produces LocalLyricsDocument, LocalLyricsMetadata, LyricWord,
  LocalLyricsDocument.Error, parse(_:), and serialize() for later tasks.
- Retains LyricsStore.Line as the rendering value type and makes it editable
  and Codable.

- [ ] **Step 1: Write the failing parser and serializer tests.**

~~~swift
func testParsesMetadataAndEnhancedWordTiming() throws {
    let document = try LocalLyricsDocument.parse("""
    [ti:Weird Fishes]
    [ar:Radiohead]
    [al:In Rainbows]
    [length:05:18]
    [00:12.00]<00:12.00>In <00:12.45>the <00:12.82>deep
    """)

    XCTAssertEqual(document.metadata.title, "Weird Fishes")
    XCTAssertEqual(document.metadata.artist, "Radiohead")
    XCTAssertEqual(document.duration, 318, accuracy: 0.001)
    XCTAssertEqual(document.lines[0].words.map(\.text), ["In", "the", "deep"])
    XCTAssertEqual(document.granularity, .word)
}

func testRejectsOutOfOrderEnhancedWords() {
    XCTAssertThrowsError(try LocalLyricsDocument.parse(
        "[00:01.00]<00:01.80>late <00:01.20>early"
    ))
}

func testSerializeRoundTripsEditableLines() throws {
    let parsed = try LocalLyricsDocument.parse("[ti:Song]\n[ar:Artist]\n[00:01.00]One")
    XCTAssertEqual(try LocalLyricsDocument.parse(parsed.serialize()), parsed)
}
~~~

- [ ] **Step 2: Run the focused tests and observe red.**

Run: swift test --filter LocalLyricsDocumentTests

Expected: compile failure mentioning LocalLyricsDocument is not in scope.

- [ ] **Step 3: Implement the pure document boundary.**

~~~swift
struct LocalLyricsMetadata: Codable, Equatable, Sendable {
    var title: String?
    var artist: String?
    var album: String?
    var version: String?
    var duration: TimeInterval?
}

struct LyricWord: Codable, Equatable, Sendable {
    var at: TimeInterval
    var text: String
    var end: TimeInterval?
}

struct LocalLyricsDocument: Codable, Equatable, Sendable {
    enum Error: Swift.Error, Equatable {
        case emptyTimeline, invalidTimestamp, invalidWordOrder
    }

    var metadata: LocalLyricsMetadata
    var lines: [LyricsStore.Line]
    var duration: TimeInterval? { metadata.duration }
    var granularity: LyricTimeline.Granularity

    static func parse(_ raw: String) throws -> Self
    func serialize() -> String
    func timeline(documentID: UUID?) -> LyricTimeline
}
~~~

Parse ti, ar, al, length, offset, ordinary line timestamps, and enhanced word timestamps. Reject decreasing line timestamps, decreasing words, words before their line, empty timelines, and malformed timing tags. Make LyricsStore.Line Codable and Sendable so documents and timelines can serialize safely. Replace all parser callers with this type; retain a temporary parseLRC forwarding wrapper until Task 6 removes the legacy cache class that still calls it.

Make `LyricsStore.Line.text` mutable so the editor can change it, and change
its `words` member to `[LyricWord]`. Preserve compilation of the old source
parsers temporarily by making `WordSyncedLyrics.Word` a typealias to
`LyricWord`; move no source-parsing behaviour into the local document. Task 6
will delete that compatibility type together with every old parser. Keep the
word-fraction algorithm working over `[LyricWord]` until Task 6 moves it to
`LyricSweep`.

- [ ] **Step 4: Verify green.**

Run: swift test --filter LocalLyricsDocumentTests && ../../scripts/check

Expected: parser tests pass and check passed — 4 steps.

- [ ] **Step 5: Commit.**

~~~bash
git add Sources/IslaKit/Services/LocalLyricsDocument.swift Sources/IslaKit/Services/WordSyncedLyrics.swift Tests/IslaKitTests/LocalLyricsDocumentTests.swift Sources/IslaKit/Services/LyricsStore.swift
git commit -m "feat: add local LRC document model"
~~~

## Task 2: Build the indexed local library and conservative matcher

**Status:** complete

**Files:**
- Create: Sources/IslaKit/Services/LocalLyricsLibrary.swift
- Create: Tests/IslaKitTests/LocalLyricsLibraryTests.swift
- Modify: Sources/IslaKit/Services/LyricsCoordinator.swift

**Interfaces:**
- Consumes LocalLyricsDocument.
- Produces LocalTrackIdentity, LocalLyricsCandidate, LocalLyricsLookup, and library actions for the coordinator and views.

- [ ] **Step 1: Write matching, import, binding, and folder-refresh tests.**

~~~swift
func testUniqueAlbumMatchResolvesBeforeAnyPanelOpens() throws {
    let library = LocalLyricsLibrary(directory: root)
    try library.importDocument(at: try writeLRC("studio", contents: studioLRC), binding: nil)
    guard case .ready(let candidate) = library.lookup(identity: identity(
        title: "Song", artist: "Artist", album: "Album", duration: 180
    )) else { return XCTFail("one exact local candidate should resolve") }
    XCTAssertEqual(candidate.timeline.lines.map(\.text), ["Studio"])
}

func testAmbiguousVersionsNeverAutoMatch() throws {
    let library = LocalLyricsLibrary(directory: root)
    try library.importDocument(at: try writeLRC("studio", contents: studioLRC), binding: nil)
    try library.importDocument(at: try writeLRC("acoustic", contents: acousticLRC), binding: nil)
    guard case .ambiguous(let candidates) = library.lookup(identity: identity(
        title: "Song", artist: "Artist", album: "", duration: 180
    )) else { return XCTFail("versions without an exact discriminator must not auto-match") }
    XCTAssertEqual(candidates.count, 2)
}

func testExplicitBindingWinsOverAutomaticCandidate() throws {
    let library = LocalLyricsLibrary(directory: root)
    let track = identity(title: "Song", artist: "Artist", album: "Album", duration: 180)
    let live = try library.importDocument(at: try writeLRC("live", contents: liveLRC), binding: track)
    try library.importDocument(at: try writeLRC("studio", contents: studioLRC), binding: nil)
    guard case .ready(let chosen) = library.lookup(identity: track) else {
        return XCTFail("a binding should resolve")
    }
    XCTAssertEqual(chosen.id, live.id)
}

func testRescanReplacesChangedReferencedFolderFile() throws {
    let folder = try makeFolder(named: "Library")
    let url = try write("[ti:Song]\n[ar:Artist]\n[00:01.00]First", to: folder.appendingPathComponent("song.lrc"))
    let library = LocalLyricsLibrary(directory: root)
    try library.addFolder(folder)
    try write("[ti:Song]\n[ar:Artist]\n[00:01.00]Changed", to: url)
    try library.rescanFolders()
    guard case .ready(let candidate) = library.lookup(identity: identity()) else {
        return XCTFail("the replacement should remain a unique local match")
    }
    XCTAssertEqual(candidate.timeline.lines.first?.text, "Changed")
}
~~~

`LocalLyricsLibraryTests.setUpWithError()` creates an empty `root` and removes
it in `tearDownWithError()`. Define these fixture helpers in that test file:
`writeLRC(_:contents:)` writes an `.lrc` file below `root`, `makeFolder(named:)`
creates a directory below `root`, `write(_:to:)` atomically replaces a known
fixture file, and `identity(...)` fills `LocalTrackIdentity` with `playerID:
"test"` plus the supplied title, artist, album, and duration. `studioLRC`,
`acousticLRC`, and `liveLRC` all carry valid `[ti:]`, `[ar:]`, `[al:]`, and
`[length:]` tags; the studio and live documents intentionally have the same
metadata so the binding assertion proves precedence rather than a different
automatic match.

- [ ] **Step 2: Run focused tests and observe red.**

Run: swift test --filter LocalLyricsLibraryTests

Expected: compile failure mentioning LocalLyricsLibrary is not in scope.

- [ ] **Step 3: Implement import, index, watcher, and matching.**

~~~swift
struct LocalTrackIdentity: Codable, Equatable, Hashable, Sendable {
    let playerID: String
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let recordingID: String?
}

struct LocalLyricsCandidate: Identifiable, Equatable, Sendable {
    enum Origin: String, Codable, Equatable, Sendable { case imported, referencedFolder }
    let id: UUID
    let document: LocalLyricsDocument
    let origin: Origin
    var timeline: LyricTimeline { document.timeline(documentID: id) }
}

enum LocalLyricsLookup: Equatable {
    case ready(LocalLyricsCandidate)
    case noMatch
    case ambiguous([LocalLyricsCandidate])
    case invalid(LocalLyricsLibrary.FileIssue)
}

@MainActor
final class LocalLyricsLibrary: ObservableObject {
    /// Production uses the default no-op. Tests use this to prove that a
    /// metadata enrichment did not initiate a second lookup.
    init(directory: URL, legacyV5Directory: URL? = nil, legacyV4Directory: URL? = nil,
         onLookup: @escaping (LocalTrackIdentity) -> Void = { _ in })
    func importDocument(at url: URL, binding: LocalTrackIdentity?) throws -> LocalLyricsCandidate
    func addFolder(_ url: URL) throws
    func removeFolder(_ url: URL)
    func rescanFolders() throws
    func lookup(identity: LocalTrackIdentity) -> LocalLyricsLookup
    func bind(_ candidate: LocalLyricsCandidate, to identity: LocalTrackIdentity)
    func removeBinding(for identity: LocalTrackIdentity)
}
~~~

`LocalLyricsLibrary.FileIssue` is a Codable, Equatable enum with at least
`malformed` and `unreadable` cases. Persist the affected file separately in
the index record: use a relative path for Isla-owned imports and a
bookmark-derived display path for selected folders; never include lyric text
in an error record.

Store imported copies below Application Support/Isla/lyrics-local/imports and persist folder URLs, index records, bindings, and file issues below Application Support/Isla/lyrics-local. Copy imports atomically. Keep selected-folder documents in place. Watch each selected directory with a file-system dispatch source and schedule rescanFolders after 150ms. Store security-scoped bookmarks for folders returned by NSOpenPanel, start access before every scan, and surface a stale bookmark as `FileIssue.unreadable` rather than silently dropping it.

Normalize fields with compatibility normalization, case/diacritic folding, punctuation collapse, and whitespace collapse. Apply only these automatic tiers: one equal title/artist/album candidate within two seconds; otherwise one equal title/artist candidate within half a second. A tie, missing title/artist tag, invalid document, or unreadable file is never a match.

Add the local presentation surface to `LyricsCoordinator.swift` in this task.
Temporarily add `documentID: UUID?` to the existing `LyricTimeline` and give
its existing initializer a default of `nil`; its final, broker-free shape after
Task 6 is:

~~~swift
struct LyricTimeline: Codable, Equatable, Sendable {
    let lines: [LyricsStore.Line]
    let granularity: Granularity
    let documentID: UUID?
}

enum LyricsAvailability: Equatable, Sendable {
    case disabled
    case settlingPlayback
    case findingLocalLyrics
    case ready(LyricTimeline)
    case noLocalLyrics
    case invalidLocalFile(LocalLyricsLibrary.FileIssue)
}
~~~

`LyricsCoordinator` also publishes `localLookup: LocalLyricsLookup?`. On an
ambiguous lookup it publishes `.noLocalLyrics` plus that exact candidate list;
on a no-match it publishes `.noLocalLyrics` plus `.noMatch`; on an invalid
file it publishes `.invalidLocalFile` plus its issue. This keeps the approved
availability vocabulary small while making ambiguity actionable and giving all
surfaces one source for the chooser state. Change
`LyricsPresentation.compactCaption` to take
`localLookup: LocalLyricsLookup? = nil`; its optional default keeps renderer
unit tests concise while the real surfaces pass the coordinator value.

Until Task 6, keep the old `LyricIdentity`, `LyricsResolution`,
`LyricsFailure`, resolver protocol, and the existing provider fields on
`LyricTimeline` solely so the not-yet-deleted broker source files compile.
Add a local-only `LyricTimeline` initializer that fills those temporary fields
with non-user-facing compatibility values and carries `documentID`. Task 6
deletes both the old types and fields after their consumers are gone.
`LocalTrackIdentity` is the only identity used by the coordinator. It must use
a stable logical track key derived from the original Now Playing event;
Spotify/Apple metadata enrichment may improve a later manual rescan but must
neither issue another lookup nor replace a shown timeline.

- [ ] **Step 4: Rewire the coordinator to local lookup.**

Remove resolver request tasks from LyricsCoordinator, but retain the old resolver implementation files unused until Task 6 deletes them with their tests in one compiling change. Build LocalTrackIdentity from Now Playing metadata, call library.lookup once per logical track, and publish ready, noLocalLyrics, invalidLocalFile, or the existing settling/finding states. Metadata enrichment may not blank a validated visible timeline. Subscribe to the library's revision publisher only to re-evaluate the *same* track after an import, binding, or folder rescan.

Add coordinator tests beside the library tests that: start media without any SwiftUI lyric surface; assert one `onLookup` identity; enrich Spotify metadata; assert the callback still contains exactly that one identity and the ready caption remains populated. Add a matching Apple Music snapshot test. Do not retain any resolver mock or a test that expects a network result after this task.

- [ ] **Step 5: Verify green.**

Run: swift test --filter LocalLyricsLibraryTests && swift test --filter LyricsCoordinatorTests && ../../scripts/check

Expected: all local lookup/coordinator tests pass; legacy broker implementation files are unreachable and their obsolete tests are scheduled for removal in Task 6.

- [ ] **Step 6: Commit.**

~~~bash
git add Sources/IslaKit/Services/LocalLyricsLibrary.swift Sources/IslaKit/Services/LyricsCoordinator.swift Tests/IslaKitTests/LocalLyricsLibraryTests.swift Tests/IslaKitTests/LyricsCoordinatorTests.swift
git commit -m "feat: resolve lyrics from local library"
~~~

## Task 3: Migrate local overrides and preserve timing corrections

**Files:**
- Modify: Sources/IslaKit/Services/LocalLyricsLibrary.swift
- Modify: Sources/IslaKit/Services/LyricsStore.swift
- Modify: Tests/IslaKitTests/LocalLyricsLibraryTests.swift
- Modify: Tests/IslaKitTests/LyricSweepTests.swift

**Interfaces:**
- Consumes Task 2 imports/index and former lyrics-v5/overrides files.
- Produces imported legacy LRCs, unassigned imports, and offsets keyed by LocalTrackIdentity.

- [ ] **Step 1: Write the migration tests.**

~~~swift
func testMigrationCopiesTaggedV5OverrideAndDeletesLicensedEntries() throws {
    let track = identity(title: "Song", artist: "Artist", album: "Album", duration: 180)
    try write("[ti:Song]\n[ar:Artist]\n[al:Album]\n[length:03:00]\n[00:01.00]Private",
              to: legacyOverrides.appendingPathComponent("old.lrc"))
    try write(licensedV5JSON, to: legacyV5.appendingPathComponent("old.lrc5.json"))
    let library = LocalLyricsLibrary(directory: root, legacyV5Directory: legacyV5)
    guard case .ready(let candidate) = library.lookup(identity: track) else {
        return XCTFail("the tagged override should migrate")
    }
    XCTAssertEqual(candidate.timeline.lines.first?.text, "Private")
    XCTAssertFalse(fileManager.fileExists(atPath: legacyV5.appendingPathComponent("old.lrc5.json").path))
}

func testMigrationKeepsTaglessOverrideAsUnassignedImport() throws {
    try write("[00:01.00]Private", to: legacyOverrides.appendingPathComponent("tagless.lrc"))
    let library = LocalLyricsLibrary(directory: root, legacyV5Directory: legacyV5)
    XCTAssertEqual(library.unassignedImports.count, 1)
}

func testLocalTrackOffsetPersistsByBoundIdentity() {
    let store = LyricsStore(offsetsDirectory: root)
    store.activateTrackOffset(for: identity())
    store.nudgeTrackOffset(by: 0.25)
    let reloaded = LyricsStore(offsetsDirectory: root)
    XCTAssertEqual(reloaded.trackOffset(for: identity()), 0.25, accuracy: 0.001)
}

func testMigrationCarriesReconstructableLegacyNudgeToTaggedOverride() throws {
    let tagged = "[ti:Song]\\n[ar:Artist]\\n[al:Album]\\n[length:03:00]\\n[00:01.00]Private"
    try write(tagged, to: legacyOverrides.appendingPathComponent("old.lrc"))
    try write(legacyV4Entry(trackOffset: 0.25, identity: identity()),
              to: legacyV4.appendingPathComponent(legacyV4Name(for: identity())))
    _ = LocalLyricsLibrary(directory: root, legacyV5Directory: legacyV5, legacyV4Directory: legacyV4)
    let store = LyricsStore(offsetsDirectory: root.appendingPathComponent("lyrics-local"))
    store.activateTrackOffset(for: identity())
    XCTAssertEqual(store.trackOffset, 0.25, accuracy: 0.001)
}
~~~

In this test fixture, `legacyV5` is `root/lyrics-v5`, `legacyV4` is
`root/lyrics`, and `legacyOverrides` is `legacyV5/overrides`; create each
directory in `setUpWithError()`. Use `legacyV5` in the first two library
initializers and `legacyV4` in the third. `legacyV4Entry` emits the exact
minimal historical JSON shape (`times`, `texts`, and `trackOffset`), and
`legacyV4Name(for:)` uses a test copy of the pre-existing cache-key algorithm;
that helper is deliberately confined to migration tests and is deleted with
the legacy cache code in Task 6.

- [ ] **Step 2: Run tests and observe red.**

Run: swift test --filter LocalLyricsLibraryTests && swift test --filter LyricSweepTests

Expected: failure for unassignedImports, legacyV5Directory, or activateTrackOffset.

- [ ] **Step 3: Implement migration and local offset persistence.**

Enumerate `lyrics-v5/overrides/*.lrc` on first local-library launch. Atomically copy valid documents to imports and index tagged files. Retain tagless files in the persisted unassigned list. Retain invalid local override files in unassigned imports with a file issue; never silently destroy user text. Only after that copy pass, delete every `*.lrc5.json` provider entry and every `*.lrc4.json` community entry.

For a tagged legacy override, reconstruct an old cache identity only when its
title, artist, album, and duration tags reproduce the old cache filename using
the historical `LyricsStore.cacheKey` algorithm. Carry that entry's nudge to
the imported document's `LocalTrackIdentity`. Do not guess from a filename,
partial tag set, or similar title. Persist every other old nudge in
`lyrics-local/unassigned-offsets.json`, show it in Settings with its legacy
filename and offset, and delete it only after the listener explicitly dismisses
it.

Replace cache-key-backed track offsets with LocalTrackIdentity values in `lyrics-local/offsets.json`. Add `init(offsetsDirectory:)` for deterministic tests, `activateTrackOffset(for:)`, `trackOffset(for:)`, and `removeTrackOffset(for:)`. Preserve the existing global offset and plus/minus 1.5-second clamp. Expose non-reconstructable legacy offsets as Settings entries until explicit dismissal.

- [ ] **Step 4: Verify green.**

Run: swift test --filter LocalLyricsLibraryTests && swift test --filter LyricSweepTests && ../../scripts/check

Expected: migrated tagged LRCs resolve locally, provider cache is deleted, tagless files survive, and timing tests pass.

- [ ] **Step 5: Commit.**

~~~bash
git add Sources/IslaKit/Services/LocalLyricsLibrary.swift Sources/IslaKit/Services/LyricsStore.swift Tests/IslaKitTests/LocalLyricsLibraryTests.swift Tests/IslaKitTests/LyricSweepTests.swift
git commit -m "feat: migrate local lyric overrides"
~~~

## Task 4: Add local controls, ambiguity picker, and offline editor

**Files:**
- Create: Sources/IslaKit/Services/LocalLyricsEditor.swift
- Create: Sources/IslaKit/UI/LocalLyricsEditorView.swift
- Create: Tests/IslaKitTests/LocalLyricsEditorTests.swift
- Modify: Sources/IslaKit/UI/LyricsStage.swift
- Modify: Sources/IslaKit/UI/MediaPane.swift
- Modify: Sources/IslaKit/UI/LockScreenCard.swift
- Modify: Sources/IslaKit/UI/LyricsPresentation.swift
- Modify: Tests/IslaKitTests/SharedLyricTimelineTests.swift
- Modify: Tests/IslaKitTests/MediaPaneLayoutTests.swift
- Modify: Tests/IslaKitTests/LockCardPaneTests.swift

**Interfaces:**
- Consumes LocalLyricsLookup and LocalLyricsLibrary actions.
- Produces LocalLyricsDraft plus a SwiftUI sheet that saves an owned document or exports to a chosen URL.

- [ ] **Step 1: Write editor and local-status tests.**

~~~swift
func testEditorSaveCreatesOwnedBoundCopyWithoutChangingSourceFile() throws {
    let source = try write("[ti:Song]\n[ar:Artist]\n[00:01.00]Before",
                           to: folder.appendingPathComponent("song.lrc"))
    let library = LocalLyricsLibrary(directory: root)
    let draft = LocalLyricsDraft(document: try LocalLyricsDocument.parse(String(contentsOf: source)))
    draft.lines[0].text = "After"
    let editor = LocalLyricsEditor(library: library)
    let saved = try editor.saveOwnedCopy(draft, binding: identity())
    XCTAssertEqual(try String(contentsOf: source), "[ti:Song]\n[ar:Artist]\n[00:01.00]Before")
    XCTAssertEqual(saved.document.lines[0].text, "After")
}

func testLocalAvailabilityAlwaysHasCaptionAndRecoveryAction() {
    let timeline = LyricTimeline(lines: [LyricsStore.Line(at: 1, text: "One")], granularity: .line, documentID: nil)
    let states: [LyricsAvailability] = [
        .disabled, .settlingPlayback, .findingLocalLyrics, .ready(timeline),
        .noLocalLyrics, .invalidLocalFile(.malformed)
    ]
    for state in states {
        XCTAssertFalse(LyricsPresentation.compactCaption(for: state, currentLine: nil).isEmpty)
    }
    XCTAssertTrue(LyricsPresentation.canOpenLocalActions(.noLocalLyrics))
    XCTAssertTrue(LyricsPresentation.canOpenLocalActions(.invalidLocalFile(.malformed)))
}
~~~

- [ ] **Step 2: Run tests and observe red.**

Run: swift test --filter LocalLyricsEditorTests && swift test --filter SharedLyricTimelineTests

Expected: compile failure for LocalLyricsDraft and missing local availability cases.

- [ ] **Step 3: Implement editor and export.**

~~~swift
@MainActor
final class LocalLyricsDraft: ObservableObject {
    @Published var metadata: LocalLyricsMetadata
    @Published var lines: [LyricsStore.Line]
    init(document: LocalLyricsDocument)
    func document() throws -> LocalLyricsDocument
}

@MainActor
final class LocalLyricsEditor {
    init(library: LocalLyricsLibrary)
    func saveOwnedCopy(_ draft: LocalLyricsDraft, binding: LocalTrackIdentity?) throws -> LocalLyricsCandidate
    func export(_ draft: LocalLyricsDraft, to url: URL) throws
}
~~~

Validate timestamps before save/export. LocalLyricsEditorView uses existing shared fonts, colors, and button primitives; include line add/remove, timestamp edit, metadata edit, Save Copy, Export, Cancel, and VoiceOver labels. Save Copy never changes a referenced source file.

- [ ] **Step 4: Rewire all surfaces to local actions.**

Replace retry/import/remove-override callbacks with `importLocalFile`, `openLyricsFolder`, `rescanLocalLyrics`, `selectCandidate`, `removeBinding`, `editLyrics`, and `exportLyrics`. Add `localLookup` parameters to MediaPane, LockScreenCard, LyricsStage, and LyricsPresentation; Task 5 wires the coordinator's published value into them. For noLocalLyrics and invalidLocalFile, compact and lock-card actions open the full stage. No duplicate alert/toast. Replace resolving spinner conditions with findingLocalLyrics. Use local accessible captions in every state. When `localLookup` is `.ambiguous`, the stage lists those candidates and the compact caption reads “Choose local lyrics…”; it never guesses one candidate.

Add a focused UI contract assertion for every availability state: compact caption,
lock-card label, and full-stage entry point are nonempty/reachable. Add VoiceOver
labels for import, folder, rescan, candidate selection, remove binding, edit,
and export. Keep stage and compact transitions opacity-only when Reduce Motion
is enabled; reuse the existing motion environment test harness rather than
adding a second animation policy.

- [ ] **Step 5: Verify green.**

Run: swift test --filter LocalLyricsEditorTests && swift test --filter SharedLyricTimelineTests && swift test --filter MediaPaneLayoutTests && swift test --filter LockCardPaneTests && ../../scripts/check

Expected: all surfaces share local availability and editor leaves source files untouched.

- [ ] **Step 6: Commit.**

~~~bash
git add Sources/IslaKit/Services/LocalLyricsEditor.swift Sources/IslaKit/UI/LocalLyricsEditorView.swift Sources/IslaKit/UI/LyricsStage.swift Sources/IslaKit/UI/MediaPane.swift Sources/IslaKit/UI/LockScreenCard.swift Sources/IslaKit/UI/LyricsPresentation.swift Tests/IslaKitTests/LocalLyricsEditorTests.swift Tests/IslaKitTests/SharedLyricTimelineTests.swift Tests/IslaKitTests/MediaPaneLayoutTests.swift Tests/IslaKitTests/LockCardPaneTests.swift
git commit -m "feat: edit and bind local lyrics"
~~~

## Task 5: Replace Settings and store ownership

**Files:**
- Modify: Sources/IslaKit/Model/NotchStores.swift
- Modify: Sources/IslaKit/Model/NotchViewModel.swift
- Modify: Sources/IslaKit/UI/NotchContentView.swift
- Modify: Sources/IslaKit/UI/SettingsPane.swift
- Modify: Tests/IslaKitTests/LyricsCoordinatorTests.swift
- Create: Tests/IslaKitTests/SettingsPaneTests.swift

**Interfaces:**
- Consumes LocalLyricsLibrary actions and exposes one session-owned localLyricsLibrary.

- [ ] **Step 1: Write Settings/store tests.**

~~~swift
func testNotchStoresOwnOneLocalLibraryForTheSession() {
    let stores = NotchStores(localLyricsDirectory: root)
    XCTAssertTrue(stores.localLyricsLibrary === stores.lyricsCoordinator.library)
}

func testSettingsCopyPromisesLocalOnlyLyrics() {
    XCTAssertEqual(SettingsPane.localLyricsPrivacyCopyKey, "Lyrics stay on this Mac.")
}
~~~

- [ ] **Step 2: Run tests and observe red.**

Run: swift test --filter LyricsCoordinatorTests && swift test --filter SettingsPaneTests

Expected: missing localLyricsLibrary or localLyricsPrivacyCopy.

- [ ] **Step 3: Implement session ownership and Settings management.**

NotchStores exposes `init(localLyricsDirectory:)` for deterministic tests;
production derives that directory from AppPaths. It constructs
LocalLyricsLibrary once, passes the same instance to LyricsCoordinator, starts
folder watching with the session, and stops it during teardown. Replace
clearLyricsCache with clearImportedLyrics and a separate
clearBindingsAndOffsets confirmation action. Route all stage/Settings callbacks
through NotchViewModel. At the NotchContentView boundary, observe the
coordinator and pass its `localLookup` plus local action closures to every
lyrics surface introduced in Task 4.

Keep Show Lyrics but remove broker disclosure. Add Add Lyrics Folder…, Remove
Lyrics Folder, Import LRC…, Open Lyrics Folder, Rescan Local Lyrics, Clear
Imported Lyrics, Clear Bindings and Timing Corrections, and an unassigned
offset list with an explicit Dismiss action. Use NSOpenPanel with directories
only for folder addition and .lrc files only for import. State that files stay
on this Mac and Isla does not download lyrics. `localLyricsPrivacyCopyKey` is a
testable key only; every displayed value must pass through `localized(_)`.

- [ ] **Step 4: Verify green.**

Run: swift test --filter LyricsCoordinatorTests && swift test --filter SettingsPaneTests && ../../scripts/check

Expected: one session-owned library and no broker-consent callback.

- [ ] **Step 5: Commit.**

~~~bash
git add Sources/IslaKit/Model/NotchStores.swift Sources/IslaKit/Model/NotchViewModel.swift Sources/IslaKit/UI/NotchContentView.swift Sources/IslaKit/UI/SettingsPane.swift Tests/IslaKitTests/LyricsCoordinatorTests.swift Tests/IslaKitTests/SettingsPaneTests.swift
git commit -m "feat: manage local lyrics in settings"
~~~

## Task 6: Delete broker/community paths and prove lyric isolation

**Files:**
- Delete: Sources/IslaKit/Services/BrokerLyricsResolver.swift
- Delete: Sources/IslaKit/Services/CachedLyricsResolver.swift
- Delete: Sources/IslaKit/Services/LicensedLyricsCache.swift
- Delete: Sources/IslaKit/Services/QQLyrics.swift
- Delete: Sources/IslaKit/Services/WordSyncedLyrics.swift
- Delete: Sources/IslaKit/Services/HTMLEntities.swift
- Delete: Tests/IslaKitTests/LyricsBrokerTests.swift
- Delete: Tests/IslaKitTests/LicensedLyricsCacheTests.swift
- Delete: Tests/IslaKitTests/QQLyricsTests.swift
- Delete: Tests/IslaKitTests/WordSyncedLyricsTests.swift
- Delete: Tests/IslaKitTests/HTMLEntitiesTests.swift
- Delete: services/isla-lyrics-broker/
- Delete: .github/workflows/lyrics-broker.yml
- Delete: .github/workflows/lyrics-broker-release.yml
- Modify: Sources/IslaKit/Services/LyricsStore.swift
- Modify: Sources/IslaKit/Services/LyricsCoordinator.swift
- Modify: Sources/IslaKit/Services/LyricSweep.swift
- Modify: Tests/IslaKitTests/LyricsStoreTests.swift
- Modify: Tests/IslaKitTests/LyricsRetentionTests.swift
- Modify: Tests/IslaKitTests/LyricsStageRenderTests.swift
- Modify: Tests/IslaKitTests/LockCardRenderTests.swift
- Modify: Tests/IslaKitTests/LockScreenCardRenderTests.swift
- Modify: README.md, checklist.md, docs/plans/2026-08-18-dynamic-island-parity-design.md
- Create: Tests/IslaKitTests/OfflineLyricsIsolationTests.swift

**Interfaces:**
- Consumes Tasks 1–5 local data path.
- Produces an app whose lyric implementation has no network resolver/provider contract.

- [ ] **Step 1: Write offline isolation tests.**

~~~swift
func testLyricsSourcesContainNoNetworkClientOrBrokerNames() throws {
    let sources = try lyricServiceFiles(in: projectRoot.appendingPathComponent("Sources/IslaKit/Services"))
        .filter { $0.lastPathComponent.localizedCaseInsensitiveContains("lyric") }
        .map { try String(contentsOf: $0) }
        .joined(separator: "\n")
    for forbidden in ["URLSession", "BrokerLyricsResolver", "CachedLyricsResolver", "LRCLIB", "Kugou", "QQ", "AMLL"] {
        XCTAssertFalse(sources.contains(forbidden), forbidden)
    }
}

func testLocalLibraryDeclaresNetworkForbidden() {
    XCTAssertEqual(LocalLyricsLibrary.networkPolicy, .forbidden)
}
~~~

Define `projectRoot` in the test from `#filePath` by removing
`IslaKitTests`, `Tests`, then the package root. `lyricServiceFiles(in:)` must
return only direct `*.swift` children whose name contains `Lyric`; this keeps
the negative search targeted to lyric code and does not misclassify unrelated
networking such as translation. The assertion intentionally owns the forbidden
names as test literals, so the command-line negative scan below must not scan
`Tests`.

- [ ] **Step 2: Run tests and observe red.**

Run: swift test --filter OfflineLyricsIsolationTests

Expected: failure listing URLSession or a broker class.

- [ ] **Step 3: Remove code, workflows, and source routines.**

Use git rm for listed files/directories. Reduce LyricsStore to presentation,
local offset persistence, and renderer types; remove `LyricSource`, direct
source resolution, HTTP routines, old cache decoding/writing, source bias,
and the temporary `parseLRC` wrapper. Move `wordFraction(words:at:lineEnd:)`
from WordSyncedLyrics to LyricSweep and update line/word rendering tests to
use `LyricWord`. Rewrite or delete every LyricsStore test that creates a
URLSession, fixture cache, provider result, or source tier; preserve the pure
renderer, credits, line-selection, offset, and no-blank-retention coverage by
seeding LocalLyricsLibrary documents through the coordinator instead.

Delete every old community/parser source and test listed above, including QQ,
KRC, TTML, AMLL, LRCLIB, HTML-entity decoding, and their fixtures. Do not
delete `TokenStore` or Spotify account code: those are unrelated account
credentials and remain outside the lyric data path. Add
`LocalLyricsLibrary.networkPolicy` with the only NetworkPolicy case `forbidden`
so the isolation contract is explicit.

- [ ] **Step 4: Rewrite all public docs.**

Rewrite README lyric copy and parity-design amendment: imported or selected-folder local files only. Replace broker release checklist requirements with local-library/import/export/offline validation. Remove provider cost, Cloudflare setup, consent, token, cache-rights, and deployment claims. Preserve unrelated Spotify account documentation.

- [ ] **Step 5: Verify deletion and isolation.**

Run: swift test --filter OfflineLyricsIsolationTests && rg -n "lyrics-broker|BrokerLyricsResolver|CachedLyricsResolver|LicensedLyricsCache|LRCLIB|Kugou|AMLL|u.y.qq|URLSession" Sources README.md checklist.md .github || true && ../../scripts/check

Expected: no rg matches and check passed — 4 steps.

- [ ] **Step 6: Commit.**

~~~bash
git add -u
git add Tests/IslaKitTests/OfflineLyricsIsolationTests.swift
git commit -m "refactor: make lyrics fully offline"
~~~

## Task 7: Localize, document contributions, and verify timing

**Files:**
- Modify: Resources/en.lproj/Localizable.strings
- Modify: Resources/ru.lproj/Localizable.strings
- Create: docs/contributing-local-lyrics.md
- Create: Scripts/validate-lrc.swift
- Create: Scripts/validate-lrc.sh
- Create: Tests/Fixtures/local-word-timed.lrc
- Modify: Scripts/measure-sync.sh
- Modify: Scripts/sync-probe/SyncProbe.swift
- Modify: Tests/IslaKitTests/LocalLyricsDocumentTests.swift
- Modify: Tests/IslaKitTests/FirstRunTests.swift

**Interfaces:**
- Consumes the local document parser, selected import fixture, and current sync harness.
- Produces a contributor validator and timing probes that consume only user-selected local fixtures.

- [ ] **Step 1: Write localization and validator tests.**

~~~swift
func testEveryLocalLyricsStringHasEnglishAndRussianTranslations() throws {
    let keys = ["Local Lyrics Library", "Add Lyrics Folder…", "No local lyrics", "This LRC file is invalid", "Export LRC", "Lyrics stay on this Mac."]
    let english = try Self.table("en")
    let russian = try Self.table("ru")
    for key in keys {
        XCTAssertTrue(english.contains("\"\(key)\" = "))
        XCTAssertTrue(russian.contains("\"\(key)\" = "))
        XCTAssertNotEqual(Self.value(for: key, in: russian), key)
    }
}

func testValidatorFixtureAcceptsEnhancedLocalLRC() throws {
    XCTAssertNoThrow(try LocalLyricsDocument.parse(validEnhancedFixture))
}
~~~

- [ ] **Step 2: Run tests and observe red.**

Run: swift test --filter LocalLyricsDocumentTests && bash Scripts/test-localizations.sh

Expected: missing local translation or fixture assertion failure.

- [ ] **Step 3: Add strings, guide, fixtures, and validator.**

Add matching English and Russian entries for every local-library action/status.
Keep the test in `FirstRunTests` so it reuses that file's existing private
`table(_:)` and `value(for:in:)` helpers; add the literal keys to source via
`localized(_)` calls so `Scripts/test-localizations.sh` recognizes them as
used. Implement `Scripts/validate-lrc.swift` with `@testable import IslaKit`
and `LocalLyricsDocument.parse(_:)`: require exactly one file argument, print
metadata, line count, and granularity, and exit 0 for valid input, 1 for a
malformed file, and 2 for bad invocation. Implement
`Scripts/validate-lrc.sh` by following the existing sync probe build pattern:
run `swift build`, obtain `swift build --show-bin-path`, compile the validator
with `-I "$BUILD/Modules" "$BUILD"/IslaKit.build/*.o -framework Carbon`, then
execute it. Document accepted tags, timestamps, exact-version practices,
editor/export behavior, and explicit user import. Add only non-copyrighted
sample text such as One, Two, and Three.

- [ ] **Step 4: Convert the timing probe to local fixtures.**

Require `SYNC_LRC_FIXTURE=/absolute/path/file.lrc` before the script pauses or
seeks a player; export it to the compiled probe. `measure-sync.sh` must reject
a missing, unreadable, malformed, or line-only fixture. Replace
`Probe.resolveFixture(truthStart:)` with a function that reads exactly that
file, parses it through LocalLyricsDocument, requires `.word`, and populates
the word edges from its line and word timestamps. Delete cache lookup and the
synthetic grid fallback. Preserve player-state restoration and the <= 0.150s
p95 gate. The probe must not inspect an old cache or cause a lyric lookup.

- [ ] **Step 5: Verify green.**

Run: bash Scripts/validate-lrc.sh Tests/Fixtures/local-word-timed.lrc && bash Scripts/test-localizations.sh && ../../scripts/check

Expected: validator prints granularity: word and all gates pass.

- [ ] **Step 6: Run manual release validation.**

Run Spotify and Apple Music probes separately with the same selected local enhanced-LRC fixture; preserve reports in docs/verification and accept word animation only when both p95 values are <= 0.150s. Validate physical notch, lock card, no-network behavior, folder changes, import/export, ambiguous files, invalid files, VoiceOver, Reduce Motion, English, and Russian. Rebuild with bash Scripts/bundle.sh release, verify codesign --verify --deep --strict build/Isla.app, then reinstall only after checks pass. Record a blocked Apple Music probe only when no Apple Music track is available.

- [ ] **Step 7: Commit.**

~~~bash
git add Resources/en.lproj/Localizable.strings Resources/ru.lproj/Localizable.strings docs/contributing-local-lyrics.md Scripts/validate-lrc.swift Scripts/validate-lrc.sh Scripts/measure-sync.sh Scripts/sync-probe/SyncProbe.swift Tests/IslaKitTests/LocalLyricsDocumentTests.swift Tests/IslaKitTests/FirstRunTests.swift Tests/Fixtures/local-word-timed.lrc docs/verification
git commit -m "docs: support offline local lyric contributions"
~~~

## Final verification

- [ ] Run git diff --check and verify only intended files changed.
- [ ] Run ../../scripts/check and show its complete passing output.
- [ ] Run swift test --filter OfflineLyricsIsolationTests and show the no-network result.
- [ ] Run bash Scripts/bundle.sh release plus codesign --verify --deep --strict build/Isla.app.
- [ ] Inspect git status --short; the user-owned audit document must remain untracked and unstaged.
- [ ] Review the complete diff against docs/superpowers/specs/2026-09-13-offline-local-lyrics-design.md and confirm every removal, local-library behavior, migration, UI, localization, and release gate is represented.
