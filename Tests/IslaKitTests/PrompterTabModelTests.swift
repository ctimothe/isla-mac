import Foundation
import XCTest
@testable import IslaKit

// The tab's rules (plan T10, spec 5.1, 12, 14.4 and the T7 design note), tested
// on the pure model: the views are thin glue over it. Nothing here touches
// Application Support, `UserDefaults.standard`, a real timer or a window: the
// library writes to an in-memory file and time moves only when a test moves it.

// MARK: - Fakes

/// A library file that keeps what it is given, and can be told to fail.
private final class TabFileIO: PrompterFileIO {
    var data: Data?
    var writeError: Error?
    private(set) var writes = 0
    private(set) var copies: [String] = []

    init(data: Data? = nil) { self.data = data }

    func exists() -> Bool { data != nil }
    func read() throws -> Data {
        guard let data else { throw CocoaError(.fileReadNoSuchFile) }
        return data
    }
    func writeAtomically(_ newData: Data) throws {
        if let writeError { throw writeError }
        data = newData
        writes += 1
    }
    func copyAside(as name: String) throws -> String {
        copies.append(name)
        return name
    }
}

private func libraryJSON(version: Int = 1, scripts: [[String: Any]] = []) -> Data {
    try! JSONSerialization.data(withJSONObject: ["version": version, "scripts": scripts], options: [.sortedKeys])
}

/// The tab's model on a library backed by `io`, a session on fake time and a
/// scheduler nobody advances unless a test asks.
@MainActor
private final class TabRig {
    let io: TabFileIO
    let time: StageTime
    let scheduler: StageScheduler
    let library: PrompterLibrary
    let session: PrompterSession
    private(set) var sampleCalls = 0
    private(set) var model: PrompterTabModel!

    init(io: TabFileIO = TabFileIO(), load: Bool = true) {
        self.io = io
        let time = StageTime()
        let scheduler = StageScheduler(time: time)
        self.time = time
        self.scheduler = scheduler
        library = PrompterLibrary(io: io, scheduler: scheduler)
        session = PrompterSession(now: { time.now }, scheduler: scheduler, keepAwake: StageLease())
        if load { library.load() }
        model = PrompterTabModel(library: library, session: session, sample: { [unowned self] in
            self.sampleCalls += 1
            return PrompterSampleScript(title: "Sample", pages: ["Hello [smile] there.", "Second [pause] page."])
        })
    }

    /// One script of `pages`, made current and shown.
    @discardableResult
    func script(_ title: String = "Talk", pages: [String] = ["One two three.", "Four five six."]) throws -> UUID {
        let id = try library.addScript(title: title, pages: pages)
        library.setCurrentScript(id)
        return id
    }
}

// MARK: - First run

@MainActor
final class PrompterTabModelTests: XCTestCase {

    /// 5.1 item 4 and 12: the sample script appears when the library file
    /// never existed, and the file is not created by looking.
    func testFirstRunSeedsOneSampleScriptAndMakesItCurrent() throws {
        let rig = TabRig()
        XCTAssertTrue(rig.library.isFirstRun)
        rig.model.prepare()
        XCTAssertEqual(rig.library.scripts.count, 1)
        XCTAssertEqual(rig.library.scripts[0].title, "Sample")
        XCTAssertEqual(rig.library.scripts[0].pages.count, 2)
        XCTAssertEqual(rig.library.currentScriptID, rig.library.scripts[0].id)
        XCTAssertEqual(rig.model.script?.id, rig.library.scripts[0].id)
    }

    /// Seeding twice in one run (the tab appears again) adds nothing.
    func testSeedingIsOnceEvenWhenTheTabAppearsAgain() {
        let rig = TabRig()
        rig.model.prepare()
        rig.model.prepare()
        XCTAssertEqual(rig.library.scripts.count, 1)
        XCTAssertEqual(rig.sampleCalls, 1)
    }

    /// 5.1: "Not re-seeded when emptied" (the reference app re-seeds on
    /// every appearance, which is a bug). The library still says `isFirstRun` for
    /// the rest of the run, so the model has to remember on its own.
    func testAnEmptiedLibraryIsNotSeededAgainInTheSameRun() throws {
        let rig = TabRig()
        rig.model.prepare()
        rig.model.deleteScript()
        XCTAssertTrue(rig.library.scripts.isEmpty)
        rig.model.prepare()
        XCTAssertTrue(rig.library.scripts.isEmpty, "the owner emptied it; it stays empty")
        XCTAssertEqual(rig.sampleCalls, 1)
    }

    /// And across launches: once the seed has been saved the file exists, and
    /// a library read from it is not a first run, empty or not.
    func testAnEmptiedLibraryIsNotSeededAfterARelaunch() throws {
        let first = TabRig()
        first.model.prepare()
        first.model.deleteScript()
        first.library.flush()
        XCTAssertNotNil(first.io.data, "the empty library was saved")

        let second = TabRig(io: first.io)
        XCTAssertFalse(second.library.isFirstRun)
        second.model.prepare()
        XCTAssertTrue(second.library.scripts.isEmpty)
        XCTAssertEqual(second.sampleCalls, 0)
    }

    /// A library that already has scripts is never seeded, whatever its flag.
    func testAnExistingLibraryIsNeverSeeded() throws {
        let io = TabFileIO(data: libraryJSON(scripts: [[
            "id": UUID().uuidString, "title": "Mine", "updatedAt": "2027-01-15T08:00:00Z", "pages": ["a b c"],
        ]]))
        let rig = TabRig(io: io)
        rig.model.prepare()
        XCTAssertEqual(rig.library.scripts.map(\.title), ["Mine"])
        XCTAssertEqual(rig.sampleCalls, 0)
    }

    /// Nothing is seeded into a library that cannot be written (unreadable or
    /// from a newer Isla): the seed would be refused and, worse, remembered as
    /// done.
    func testAnUnwritableLibraryIsNotSeeded() {
        let io = TabFileIO(data: Data("not json".utf8))
        let rig = TabRig(io: io)
        rig.model.prepare()
        XCTAssertEqual(rig.sampleCalls, 0)
        XCTAssertTrue(rig.library.scripts.isEmpty)
        XCTAssertEqual(io.writes, 0, "the broken file was not touched")
    }

    /// Before `load()` the model does nothing, and does not mark itself done.
    func testPrepareBeforeTheLibraryIsLoadedDoesNothingAndCanRunLater() {
        let rig = TabRig(load: false)
        rig.model.prepare()
        XCTAssertEqual(rig.sampleCalls, 0)
        rig.library.load()
        rig.model.prepare()
        XCTAssertEqual(rig.library.scripts.count, 1)
    }

    /// The hint under the sample belongs to the sample only.
    func testTheFirstRunHintIsForTheSeededScriptOnly() throws {
        let rig = TabRig()
        rig.model.prepare()
        XCTAssertTrue(rig.model.showsFirstRunHint)
        rig.model.addScript()
        XCTAssertFalse(rig.model.showsFirstRunHint)
    }

    // MARK: The sample script in both languages

    private func table(_ locale: String) throws -> [String: String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/\(locale).lproj/Localizable.strings")
        let text = try String(contentsOf: url, encoding: .utf8)
        let pattern = try NSRegularExpression(
            pattern: #"^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";"#, options: .anchorsMatchLines
        )
        var result: [String: String] = [:]
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let key = Range(match.range(at: 1), in: text), let value = Range(match.range(at: 2), in: text) else { continue }
            result[String(text[key])] = String(text[value])
        }
        return result
    }

    /// 15: "The sample script ships in both languages", each with a `[smile]`
    /// and a `[pause]` cue (5.1 item 4). The keys are English text; the
    /// Russian page is not the English one.
    func testTheSampleScriptShipsInEnglishAndRussianWithCues() throws {
        let en = try table("en")
        let ru = try table("ru")
        let english = PrompterSampleScript.make(lookup: { en[$0] ?? "MISSING \($0)" })
        let russian = PrompterSampleScript.make(lookup: { ru[$0] ?? "MISSING \($0)" })

        for (name, sample) in [("en", english), ("ru", russian)] {
            XCTAssertFalse(sample.title.isEmpty, name)
            XCTAssertFalse(sample.title.hasPrefix("MISSING"), "\(name) has the title")
            XCTAssertGreaterThanOrEqual(sample.pages.count, 2, name)
            XCTAssertFalse(sample.pages.contains { $0.hasPrefix("MISSING") }, "\(name) has every page")
            let cues = sample.pages.map { PromptScript($0).cues.count }.reduce(0, +)
            XCTAssertGreaterThanOrEqual(cues, 2, "\(name) shows a [smile]-style cue and a [pause]-style cue")
        }
        XCTAssertTrue(english.pages.joined().contains("[smile]"))
        XCTAssertTrue(english.pages.joined().contains("[pause]"))
        XCTAssertNotEqual(english.pages, russian.pages)
        XCTAssertNotEqual(english.title, russian.title)
        XCTAssertTrue(
            russian.pages.joined().unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) },
            "the Russian sample is in Russian"
        )
        XCTAssertEqual(PrompterSampleScript.keys.count, Set(PrompterSampleScript.keys).count)
        for key in PrompterSampleScript.keys {
            XCTAssertNotNil(en[key], "en has \(key.prefix(24))")
            XCTAssertNotNil(ru[key], "ru has \(key.prefix(24))")
        }
    }

    /// The app reads the sample and the alerts' explanations through literal
    /// `localized` calls (the localization script finds a string's use that
    /// way); in a test host, where nothing is translated, they are the keys.
    func testTheAppsSampleAndExplanationsAreTheTablesKeys() {
        XCTAssertEqual(PrompterSampleScript.current, PrompterSampleScript.make(lookup: { $0 }))
        for notice in [PrompterLibraryNotice.unreadable(corruptCopy: nil), .newerVersion(3)] {
            XCTAssertEqual(notice.detail, notice.detailKey)
            XCTAssertFalse(notice.detail.isEmpty)
        }
    }

    // MARK: Start

    func testStartIsReadyWhenAPageHasWords() throws {
        let rig = TabRig()
        try rig.script()
        XCTAssertEqual(rig.model.startAvailability(isPreparing: false), .ready)
    }

    /// E-20 and 5.1: "Nothing to read yet" when no page has content,
    /// whitespace and a page of nothing included.
    func testStartIsDisabledWithAReasonWhenNothingIsReadable() throws {
        let rig = TabRig()
        XCTAssertEqual(rig.model.startAvailability(isPreparing: false), .unavailable(.nothingToRead), "no script at all")
        try rig.script(pages: ["", "  \n\t ", ""])
        XCTAssertEqual(rig.model.startAvailability(isPreparing: false), .unavailable(.nothingToRead))
        XCTAssertEqual(PrompterStartAvailability.unavailable(.nothingToRead).reason, "Nothing to read yet")
        XCTAssertFalse(PrompterStartAvailability.unavailable(.nothingToRead).isEnabled)
    }

    /// 20.4 #11: a big script is tokenized on a background task and a second
    /// Start meanwhile does nothing; the button says why instead.
    func testStartIsDisabledWhileABigScriptIsBeingPrepared() throws {
        let rig = TabRig()
        try rig.script()
        XCTAssertEqual(rig.model.startAvailability(isPreparing: true), .unavailable(.preparing))
        XCTAssertNotNil(PrompterStartAvailability.unavailable(.preparing).reason)
    }

    func testStartIsDisabledForAnUnreadableOrNewerLibrary() {
        let broken = TabRig(io: TabFileIO(data: Data("{".utf8)))
        XCTAssertEqual(broken.model.startAvailability(isPreparing: false), .unavailable(.libraryUnreadable))

        let newer = TabRig(io: TabFileIO(data: libraryJSON(version: 9)))
        XCTAssertEqual(newer.model.startAvailability(isPreparing: false), .unavailable(.libraryReadOnly))

        let reasons = [PrompterStartAvailability.unavailable(.libraryUnreadable), .unavailable(.libraryReadOnly)]
            .compactMap(\.reason)
        XCTAssertEqual(reasons.count, 2)
        XCTAssertEqual(Set(reasons).count, 2, "each reason is its own sentence")
    }

    /// A failed write keeps the edits in memory (E-55); the speaker can still
    /// read what is on the screen.
    func testAWriteFailureDoesNotDisableStart() throws {
        let rig = TabRig()
        try rig.script()
        rig.io.writeError = CocoaError(.fileWriteOutOfSpace)
        rig.library.flush()
        XCTAssertNotNil(rig.library.writeFailure)
        XCTAssertEqual(rig.model.startAvailability(isPreparing: false), .ready)
    }

    /// 5.1 and the design note: one primary control that becomes "Resume"
    /// while a session is paused, whatever it was paused for.
    func testTheButtonBecomesResumeWhileAnySessionIsPaused() throws {
        let rig = TabRig()
        try rig.script()
        XCTAssertEqual(PrompterStartAvailability.ready.label, "Start")
        XCTAssertTrue(rig.session.start(pages: [PromptScript("One two three four")]))
        XCTAssertEqual(rig.model.startAvailability(isPreparing: false), .ready, "running: the button only shows the stage")
        for reason in [PrompterPauseReason.user, .lock, .sleep] {
            let paused = TabRig()
            try paused.script()
            XCTAssertTrue(paused.session.start(pages: [PromptScript("One two three four")]))
            paused.session.pause(reason)
            XCTAssertEqual(paused.model.startAvailability(isPreparing: false), .resume, "\(reason)")
        }
        XCTAssertEqual(PrompterStartAvailability.resume.label, "Resume")
        XCTAssertTrue(PrompterStartAvailability.resume.isEnabled)
    }

    /// A paused session is resumed even if the library has since become
    /// unreadable or empty: the speaker is mid-talk.
    func testResumeDoesNotDependOnTheLibrary() throws {
        let rig = TabRig()
        XCTAssertTrue(rig.session.start(pages: [PromptScript("One two three four")]))
        rig.session.pause(.user)
        XCTAssertTrue(rig.library.scripts.isEmpty)
        XCTAssertEqual(rig.model.startAvailability(isPreparing: true), .resume)
    }

    // MARK: Capture chip

    /// 5.1 item 3 and 11.5: the chip shows the setting, never a promise, and
    /// when the panel is visible it is the way to Settings. The tab says
    /// "Visible when sharing" (20.4 #15 leaves that wording to the tab).
    func testTheCaptureChipTracksHideFromCapture() {
        let hidden = PrompterTabModel.captureChip(hidden: true)
        let visible = PrompterTabModel.captureChip(hidden: false)
        XCTAssertEqual(hidden.text, "Hidden from screen sharing")
        XCTAssertEqual(visible.text, "Visible when sharing")
        XCTAssertFalse(hidden.opensSettings)
        XCTAssertTrue(visible.opensSettings, "when visible, the chip leads to the switch")
        XCTAssertNotEqual(hidden.symbol, visible.symbol)
        XCTAssertFalse(hidden.caveat.isEmpty, "11.5: the tab says capture hiding is not a guarantee")
        XCTAssertEqual(hidden.caveat, visible.caveat)
    }

    // MARK: Script operations

    func testNewScriptIsSelectedAndStartsWithOneEmptyPage() throws {
        let rig = TabRig()
        XCTAssertTrue(rig.model.addScript())
        let script = try XCTUnwrap(rig.model.script)
        XCTAssertEqual(script.pages, [""])
        XCTAssertEqual(rig.library.currentScriptID, script.id)
        XCTAssertEqual(rig.model.page, 0)
        XCTAssertFalse(script.title.isEmpty)
    }

    func testSelectingAScriptShowsItsFirstPage() throws {
        let rig = TabRig()
        let first = try rig.script("A", pages: ["a1", "a2", "a3"])
        let second = try rig.script("B", pages: ["b1"])
        rig.model.selectScript(first)
        rig.model.selectPage(2)
        rig.model.selectScript(second)
        XCTAssertEqual(rig.model.script?.title, "B")
        XCTAssertEqual(rig.model.page, 0)
        rig.model.selectScript(first)
        XCTAssertEqual(rig.model.page, 0, "arriving at a script starts at its first page")
    }

    func testRenameKeepsTheTitleItWasGivenAndNeverEmptiesIt() throws {
        let rig = TabRig()
        try rig.script("Old")
        rig.model.renameScript("Keynote")
        XCTAssertEqual(rig.model.script?.title, "Keynote")
        rig.model.renameScript("   ")
        XCTAssertEqual(rig.model.script?.title, "Keynote", "a blank title would leave a row with no name")
        rig.model.renameScript("  Padded  ")
        XCTAssertEqual(rig.model.script?.title, "Padded")
    }

    func testDuplicateSitsAfterTheOriginalAndIsSelected() throws {
        let rig = TabRig()
        let id = try rig.script("Talk", pages: ["x y", "z"])
        XCTAssertTrue(rig.model.duplicateScript())
        XCTAssertEqual(rig.library.scripts.count, 2)
        XCTAssertNotEqual(rig.model.script?.id, id)
        XCTAssertEqual(rig.model.script?.pages, ["x y", "z"])
        XCTAssertNotEqual(rig.model.script?.title, "Talk", "the copy is named as a copy")
        XCTAssertTrue(rig.model.script?.title.contains("Talk") ?? false)
        XCTAssertEqual(rig.model.page, 0)
    }

    /// Deleting is confirmed by the view (`ConfirmTextButton`); the model does
    /// the deed. The current script falls to a neighbour, and the last script
    /// can go (the tab then shows its empty state).
    func testDeletingAScriptSelectsANeighbourAndTheLastOneCanGo() throws {
        let rig = TabRig()
        let a = try rig.script("A")
        let b = try rig.script("B")
        _ = try rig.script("C")
        rig.model.selectScript(b)
        rig.model.deleteScript()
        XCTAssertEqual(rig.library.scripts.map(\.title), ["A", "C"])
        XCTAssertNotNil(rig.model.script, "something is still shown")
        XCTAssertNotEqual(rig.model.script?.id, b)
        rig.model.selectScript(a)
        rig.model.deleteScript()
        rig.model.deleteScript()
        XCTAssertTrue(rig.library.scripts.isEmpty)
        XCTAssertNil(rig.model.script)
        XCTAssertEqual(rig.model.page, 0)
        rig.model.deleteScript()
        XCTAssertTrue(rig.library.scripts.isEmpty, "deleting nothing is nothing")
    }

    func testScriptListTitlesAreCoveredWhenThePrivacyCoverIsOn() throws {
        let rig = TabRig()
        try rig.script("Q3 layoffs")
        let record = try XCTUnwrap(rig.model.script)
        XCTAssertEqual(PrompterTabModel.displayTitle(record, position: 0, covered: false), "Q3 layoffs")
        let hidden = PrompterTabModel.displayTitle(record, position: 0, covered: true)
        XCTAssertFalse(hidden.contains("Q3"))
        XCTAssertFalse(hidden.isEmpty)
        XCTAssertNotEqual(
            PrompterTabModel.displayTitle(record, position: 0, covered: true),
            PrompterTabModel.displayTitle(record, position: 1, covered: true),
            "covered rows can still be told apart"
        )
    }

    // MARK: Page operations

    func testSelectingAPageClampsAndAddingOneSelectsIt() throws {
        let rig = TabRig()
        try rig.script(pages: ["a", "b"])
        rig.model.selectPage(1)
        XCTAssertEqual(rig.model.page, 1)
        rig.model.selectPage(9)
        XCTAssertEqual(rig.model.page, 1, "an index past the end is ignored")
        rig.model.selectPage(-1)
        XCTAssertEqual(rig.model.page, 1)
        XCTAssertTrue(rig.model.addPage())
        XCTAssertEqual(rig.model.pages, ["a", "b", ""])
        XCTAssertEqual(rig.model.page, 2)
    }

    /// The conservative reading of "delete after arm-then-confirm if
    /// non-empty": a page with any text needs the confirmation, an empty one
    /// does not; and the last page cannot be deleted at all, because a script
    /// with no pages has no editor and no way to add text back (delete the
    /// script instead).
    func testPageDeletionRules() throws {
        let rig = TabRig()
        try rig.script(pages: ["text", "", "  "])
        XCTAssertTrue(rig.model.deletionNeedsConfirmation(page: 0))
        XCTAssertFalse(rig.model.deletionNeedsConfirmation(page: 1))
        XCTAssertTrue(rig.model.deletionNeedsConfirmation(page: 2), "whitespace is still the owner's text")
        XCTAssertTrue(rig.model.canDeletePage)

        rig.model.deletePage(1)
        XCTAssertEqual(rig.model.pages, ["text", "  "])
        rig.model.deletePage(0)
        XCTAssertEqual(rig.model.pages, ["  "])
        XCTAssertFalse(rig.model.canDeletePage)
        rig.model.deletePage(0)
        XCTAssertEqual(rig.model.pages, ["  "], "the last page stays")
    }

    func testDeletingKeepsTheSamePageSelected() throws {
        let rig = TabRig()
        try rig.script(pages: ["a", "b", "c", "d"])
        rig.model.selectPage(2)
        rig.model.deletePage(0)
        XCTAssertEqual(rig.model.pages, ["b", "c", "d"])
        XCTAssertEqual(rig.model.pageText, "c", "an earlier page went; the one being read did not")
        rig.model.deletePage(0)
        XCTAssertEqual(rig.model.pages, ["c", "d"])
        XCTAssertEqual(rig.model.page, 0)
        rig.model.selectPage(1)
        rig.model.deletePage(1)
        XCTAssertEqual(rig.model.page, 0, "deleting the last page of a script lands on the one before")
        XCTAssertEqual(rig.model.pages, ["c"])
    }

    func testMovingAPageFollowsTheSelectedPage() throws {
        let rig = TabRig()
        try rig.script(pages: ["a", "b", "c"])
        rig.model.selectPage(0)
        rig.model.movePage(from: 0, to: 2)
        XCTAssertEqual(rig.model.pages, ["b", "c", "a"])
        XCTAssertEqual(rig.model.pageText, "a", "the selected page moved and is still selected")
        XCTAssertEqual(rig.model.page, 2)

        rig.model.movePage(from: 1, to: 0)
        XCTAssertEqual(rig.model.pages, ["c", "b", "a"])
        XCTAssertEqual(rig.model.pageText, "a")
        XCTAssertEqual(rig.model.page, 2, "a page moved past it from the other side does not move it")

        rig.model.movePage(from: 0, to: 5)
        XCTAssertEqual(rig.model.pages, ["c", "b", "a"], "an index out of range is ignored")
    }

    func testReadMarksComeFromTheSession() throws {
        let rig = TabRig()
        try rig.script(pages: ["alpha beta", "gamma"])
        XCTAssertEqual(rig.model.readMarks, [])
        XCTAssertTrue(rig.session.start(pages: [PromptScript("alpha beta"), PromptScript("gamma")]))
        for _ in 0..<400 { rig.scheduler.advance(by: 0.05) }
        XCTAssertFalse(rig.session.readPages.isEmpty, "the first page was read to its end")
        XCTAssertEqual(rig.model.readMarks, rig.session.readPages)
    }

    // MARK: Editing

    func testTypingWritesThroughToTheLibrary() throws {
        let rig = TabRig()
        try rig.script(pages: ["old"])
        rig.model.setText("new text")
        XCTAssertEqual(rig.library.script(try XCTUnwrap(rig.model.script?.id))?.pages, ["new text"])
        XCTAssertNil(rig.model.inlineError)
    }

    // MARK: Limits (14.4: a field error, once, on the control that caused it)

    private func bigScript(_ rig: TabRig, pages: [String]) throws {
        try rig.script("Big", pages: pages)
    }

    func testThePageLimitIsOneInlineMessageOnTheAddPageControl() throws {
        let rig = TabRig()
        try bigScript(rig, pages: Array(repeating: "x", count: PrompterLibrary.maxPagesPerScript))
        XCTAssertFalse(rig.model.addPage())
        let error = try XCTUnwrap(rig.model.inlineError)
        XCTAssertEqual(error.target, .addPage)
        XCTAssertTrue(error.message.contains("\(PrompterLibrary.maxPagesPerScript)"))
        XCTAssertEqual(rig.model.pages.count, PrompterLibrary.maxPagesPerScript, "nothing was added or cut")
        XCTAssertNil(rig.model.notice, "and no second surface")

        // Pressing again is the same one message, not a stack of them.
        XCTAssertFalse(rig.model.addPage())
        XCTAssertEqual(rig.model.inlineError, error)
    }

    func testTheCharacterLimitIsAFieldErrorOnTheEditorAndTheTextIsKept() throws {
        let rig = TabRig()
        try bigScript(rig, pages: ["short"])
        let tooLong = String(repeating: "a", count: PrompterLibrary.maxCharactersPerScript + 1)
        let revision = rig.model.revision
        rig.model.setText(tooLong)
        let error = try XCTUnwrap(rig.model.inlineError)
        XCTAssertEqual(error.target, .editor)
        XCTAssertEqual(rig.model.pageText, "short", "nothing is truncated or half-saved")
        XCTAssertGreaterThan(rig.model.revision, revision, "the editor is told to show the kept text again")
        XCTAssertNil(rig.model.notice)
    }

    func testTheScriptLimitIsOneInlineMessageOnTheNewScriptControl() throws {
        let io = TabFileIO(data: libraryJSON(scripts: (0..<PrompterLibrary.maxScripts).map {
            ["id": UUID().uuidString, "title": "S\($0)", "updatedAt": "2027-01-15T08:00:00Z", "pages": ["a"]]
        }))
        let rig = TabRig(io: io)
        XCTAssertFalse(rig.model.addScript())
        XCTAssertEqual(rig.model.inlineError?.target, .newScript)
        XCTAssertTrue(rig.model.inlineError?.message.contains("\(PrompterLibrary.maxScripts)") ?? false)
        XCTAssertEqual(rig.library.scripts.count, PrompterLibrary.maxScripts)

        let id = rig.library.scripts[0].id
        rig.model.selectScript(id)
        XCTAssertNil(rig.model.inlineError, "moving on takes the message back")
        XCTAssertFalse(rig.model.duplicateScript())
        XCTAssertEqual(rig.model.inlineError?.target, .duplicateScript, "duplicate is its own control")
    }

    func testAnInlineErrorClearsOnTheNextSuccessfulEditOrSelection() throws {
        let rig = TabRig()
        try bigScript(rig, pages: Array(repeating: "x", count: PrompterLibrary.maxPagesPerScript))
        XCTAssertFalse(rig.model.addPage())
        XCTAssertNotNil(rig.model.inlineError)
        rig.model.setText("fine")
        XCTAssertNil(rig.model.inlineError)

        XCTAssertFalse(rig.model.addPage())
        rig.model.selectPage(1)
        XCTAssertNil(rig.model.inlineError)

        XCTAssertFalse(rig.model.addPage())
        rig.model.dismissInlineError()
        XCTAssertNil(rig.model.inlineError)
    }

    // MARK: Library notices

    func testNoNoticeForAHealthyLibrary() throws {
        let rig = TabRig()
        try rig.script()
        XCTAssertNil(rig.model.notice)
        XCTAssertTrue(rig.model.canEdit)
    }

    /// 12.1: "Couldn't read your scripts" with Reveal in Finder (the corrupt
    /// copy) and Start a New Library; it blocks the tab, because nothing in it
    /// can be saved.
    func testAnUnreadableLibraryIsOneBlockingAlertWithTheCorruptCopy() throws {
        let io = TabFileIO(data: Data("garbage".utf8))
        let rig = TabRig(io: io)
        let notice = try XCTUnwrap(rig.model.notice)
        guard case .unreadable(let copy) = notice else { return XCTFail("\(notice)") }
        XCTAssertNotNil(copy)
        XCTAssertTrue(copy?.hasPrefix("library.corrupt-") ?? false)
        XCTAssertTrue(notice.blocksTheTab)
        XCTAssertEqual(notice.title, "Couldn't read your scripts")
        XCTAssertFalse(rig.model.canEdit)
        XCTAssertNil(rig.model.inlineError, "one surface for this failure")
    }

    func testStartingANewLibraryReplacesTheBrokenFileAndEndsTheAlert() throws {
        let io = TabFileIO(data: Data("garbage".utf8))
        let rig = TabRig(io: io)
        XCTAssertNotNil(rig.model.notice)
        rig.model.startNewLibrary()
        XCTAssertNil(rig.model.notice)
        XCTAssertTrue(rig.model.canEdit)
        XCTAssertNotEqual(io.data, Data("garbage".utf8), "the broken file was replaced only now")
        rig.model.prepare()
        XCTAssertTrue(rig.library.scripts.isEmpty, "a fresh library is the owner's choice; no sample is dropped into it")
        XCTAssertTrue(rig.model.addScript())
    }

    func testStartANewLibraryIsArmedByTheViewAndRefusedOnAHealthyLibrary() throws {
        let rig = TabRig()
        try rig.script()
        rig.model.startNewLibrary()
        XCTAssertEqual(rig.library.scripts.count, 1, "nothing is replaced when nothing is broken")
    }

    func testRevealTargetIsTheCorruptCopyOrElseTheFolder() {
        let directory = URL(fileURLWithPath: "/tmp/Prompter", isDirectory: true)
        XCTAssertEqual(
            PrompterTabModel.revealTarget(corruptCopy: "library.corrupt-1.json", directory: directory).lastPathComponent,
            "library.corrupt-1.json"
        )
        XCTAssertEqual(PrompterTabModel.revealTarget(corruptCopy: nil, directory: directory), directory)
    }

    func testANewerLibraryIsAReadOnlyNoticeThatNeverOffersToReplaceIt() throws {
        let io = TabFileIO(data: libraryJSON(version: 4))
        let rig = TabRig(io: io)
        let notice = try XCTUnwrap(rig.model.notice)
        XCTAssertEqual(notice, .newerVersion(4))
        XCTAssertTrue(notice.blocksTheTab)
        XCTAssertFalse(notice.offersNewLibrary, "a newer Isla's file is never replaced from an older one")
        XCTAssertFalse(rig.model.canEdit)
        rig.model.startNewLibrary()
        XCTAssertEqual(io.writes, 0)
        XCTAssertEqual(rig.model.notice, .newerVersion(4))
        XCTAssertNotEqual(notice.title, PrompterLibraryNotice.unreadable(corruptCopy: nil).title)
    }

    func testAWriteFailureIsOneNonBlockingNoticeAndEditsAreKept() throws {
        let rig = TabRig()
        try rig.script(pages: ["keep me"])
        rig.io.writeError = CocoaError(.fileWriteOutOfSpace)
        rig.model.setText("keep me too")
        rig.library.flush()
        let notice = try XCTUnwrap(rig.model.notice)
        XCTAssertEqual(notice, .writeFailed)
        XCTAssertFalse(notice.blocksTheTab)
        XCTAssertFalse(notice.offersNewLibrary)
        XCTAssertEqual(rig.model.pageText, "keep me too")
        XCTAssertTrue(rig.model.canEdit)

        rig.io.writeError = nil
        rig.library.flush()
        XCTAssertNil(rig.model.notice, "the next successful save ends it")
    }

    // MARK: Editor selection and the rebuild

    func testTheSelectionComesBackClampedToTheText() throws {
        let rig = TabRig()
        try rig.script(pages: ["hello there world", "second"])
        XCTAssertNil(rig.model.restoredSelection)
        rig.model.recordSelection(NSRange(location: 6, length: 5))
        XCTAssertEqual(rig.model.restoredSelection, NSRange(location: 6, length: 5))

        rig.model.setText("hello")
        XCTAssertEqual(rig.model.restoredSelection, NSRange(location: 5, length: 0), "the text got shorter under it")

        rig.model.selectPage(1)
        XCTAssertNil(rig.model.restoredSelection, "another page has its own caret")
        rig.model.recordSelection(NSRange(location: 2, length: 0))
        rig.model.selectPage(0)
        XCTAssertEqual(rig.model.restoredSelection, NSRange(location: 5, length: 0))
        rig.model.selectPage(1)
        XCTAssertEqual(rig.model.restoredSelection, NSRange(location: 2, length: 0), "and is remembered when it comes back")
    }

    func testASelectionIsForgottenWithItsScript() throws {
        let rig = TabRig()
        let a = try rig.script("A", pages: ["abcdef"])
        rig.model.recordSelection(NSRange(location: 3, length: 1))
        _ = try rig.script("B", pages: ["abcdef"])
        rig.model.selectScript(a)
        XCTAssertEqual(rig.model.restoredSelection, NSRange(location: 3, length: 1))
        rig.model.deleteScript()
        _ = try rig.script("C", pages: ["abcdef"])
        XCTAssertNil(rig.model.restoredSelection)
    }

    /// 7.3 and the rebuild path: a display change makes a new panel and a new
    /// view model, which is handed the same `PrompterParts`. The model lives
    /// in the parts, so the page, the caret and the text are the same object
    /// afterwards, not a copy reconstructed from the library.
    func testThePartsCarryOneTabModelAcrossARebuild() throws {
        let io = TabFileIO()
        let time = StageTime()
        let scheduler = StageScheduler(time: time)
        let parts = PrompterParts(
            settings: PrompterSettings(defaults: InMemoryDefaults()),
            library: PrompterLibrary(io: io, scheduler: scheduler),
            session: PrompterSession(now: { time.now }, scheduler: scheduler, keepAwake: StageLease())
        )
        parts.library.load()
        let id = try parts.library.addScript(title: "T", pages: ["one two", "three four five"])
        parts.library.setCurrentScript(id)
        parts.tab.selectPage(1)
        parts.tab.recordSelection(NSRange(location: 4, length: 0))

        let handedToTheRebuiltPanel = parts
        XCTAssertTrue(handedToTheRebuiltPanel.tab === parts.tab)
        XCTAssertEqual(handedToTheRebuiltPanel.tab.page, 1)
        XCTAssertEqual(handedToTheRebuiltPanel.tab.restoredSelection, NSRange(location: 4, length: 0))
        XCTAssertEqual(handedToTheRebuiltPanel.tab.pageText, "three four five")
    }

    /// The tab's current script is the same one a hot-key start reads.
    func testTheTabAndAStartAgreeOnTheCurrentScript() throws {
        let rig = TabRig()
        try rig.script("A")
        try rig.script("B", pages: ["b b"])
        let parts = PrompterParts(
            settings: PrompterSettings(defaults: InMemoryDefaults()),
            library: rig.library, session: rig.session
        )
        XCTAssertEqual(parts.currentScript?.id, rig.model.script?.id)
        rig.library.setCurrentScript(nil)
        XCTAssertEqual(parts.currentScript?.id, rig.library.scripts.first?.id)
        XCTAssertEqual(rig.model.script?.id, rig.library.scripts.first?.id)
    }

    // MARK: Counts and speed

    func testWordCountAndReadingTimeSkipCuesAndDashes() {
        let stats = PrompterTabModel.stats(for: "One two [smile] three -- four five six", speed: 2)
        XCTAssertEqual(stats.words, 6, "a cue and a dash are not read")
        XCTAssertEqual(stats.seconds, 3, accuracy: 0.001)
        XCTAssertEqual(PrompterTabModel.stats(for: "", speed: 3).words, 0)
        XCTAssertEqual(PrompterTabModel.stats(for: "", speed: 3).seconds, 0)
    }

    func testReadingTimeUsesAClampedSpeed() {
        let stats = PrompterTabModel.stats(for: String(repeating: "word ", count: 60), speed: .nan)
        XCTAssertEqual(stats.seconds, 60 / PromptClock.defaultSpeed, accuracy: 0.001)
    }

    func testAHugePageIsCountedWithoutBeingTokenizedOnTheMainThread() {
        let text = String(repeating: "word ", count: 30_000) // 150 KB, over the synchronous limit
        let stats = PrompterTabModel.stats(for: text, speed: 3)
        XCTAssertEqual(stats.words, 30_000)
    }

    func testDurationReadsAsMinutesAndSeconds() {
        XCTAssertEqual(PrompterTabStats.clock(0), "0:00")
        XCTAssertEqual(PrompterTabStats.clock(59.4), "0:59")
        XCTAssertEqual(PrompterTabStats.clock(61), "1:01")
        XCTAssertEqual(PrompterTabStats.clock(3_600), "60:00")
        XCTAssertEqual(PrompterTabStats.clock(.infinity), "0:00")
    }

    func testSpeedSteppingStaysInTheClocksRange() {
        XCTAssertEqual(PrompterTabModel.steppedSpeed(3, by: 1), 3.5)
        XCTAssertEqual(PrompterTabModel.steppedSpeed(3, by: -1), 2.5)
        XCTAssertEqual(PrompterTabModel.steppedSpeed(8, by: 1), 8)
        XCTAssertEqual(PrompterTabModel.steppedSpeed(0.5, by: -1), 0.5)
        XCTAssertTrue(PrompterTabModel.canStep(3, by: 1))
        XCTAssertFalse(PrompterTabModel.canStep(8, by: 1))
        XCTAssertFalse(PrompterTabModel.canStep(0.5, by: -1))
    }

    // MARK: Library file stays alone

    /// Looking at the tab, switching pages and scripts and selecting writes
    /// nothing a keystroke did not ask for beyond the current-script pointer.
    func testMerelyLookingAtAnExistingLibraryWritesNothing() throws {
        let io = TabFileIO(data: libraryJSON(scripts: [[
            "id": UUID().uuidString, "title": "Mine", "updatedAt": "2027-01-15T08:00:00Z", "pages": ["a b", "c"],
        ]]))
        let rig = TabRig(io: io)
        rig.model.prepare()
        rig.model.selectPage(1)
        rig.model.selectPage(0)
        for entry in rig.scheduler.live { entry.action() }
        rig.library.flush()
        XCTAssertEqual(io.writes, 0)
    }
}
