import Combine
import Foundation

// Foundation and Combine only, like the rest of the prompter's model layer.
// The Prompter tab's rules live here and the views (`PrompterTab`) only draw
// what this says and forward what the person does: which script and page are
// shown, what each operation does to the library, which one message a limit
// puts on which control, when Start is available and why not, what the
// library's failures look like. All of it is tested without a window.

// MARK: - Sample script

/// The one script a first run starts with (spec 5.1 item 4): a short talk in
/// the app's language, with a `[smile]` and a `[pause]` cue so the cue syntax
/// is seen working before it is read about.
///
/// The text is in the string tables like every other user-facing string, in
/// both languages, keyed by its English text. `make` takes the lookup so a
/// test can read the shipped tables of either language directly; the app
/// passes `localized`, which already follows the language the app ended up
/// in.
struct PrompterSampleScript: Equatable {
    var title: String
    var pages: [String]

    static let titleKey = "Sample Script"
    static let firstPageKey =
        "Welcome to the Prompter. [smile] This is a sample script. Isla shows it here, on the island, and moves it along as you read, so your eyes stay close to the camera."
    static let secondPageKey =
        "Pages split a talk into parts. [pause] Anything in square brackets is a cue, a note to yourself that is never read aloud. Edit this script or add your own, then press Start."

    static let keys = [titleKey, firstPageKey, secondPageKey]

    static func make(lookup: (String) -> String) -> PrompterSampleScript {
        PrompterSampleScript(title: lookup(titleKey), pages: [lookup(firstPageKey), lookup(secondPageKey)])
    }

    /// Written out with literal `localized` calls, not routed through `make`:
    /// `test-localizations.sh` finds a string's use by scraping those calls,
    /// and a key reached only through a constant would look unused.
    /// `PrompterTabModelTests` holds this equal to `make` so the two cannot
    /// drift.
    static var current: PrompterSampleScript {
        PrompterSampleScript(
            title: localized("Sample Script"),
            pages: [
                localized("Welcome to the Prompter. [smile] This is a sample script. Isla shows it here, on the island, and moves it along as you read, so your eyes stay close to the camera."),
                localized("Pages split a talk into parts. [pause] Anything in square brackets is a cue, a note to yourself that is never read aloud. Edit this script or add your own, then press Start."),
            ]
        )
    }
}

// MARK: - Start

/// Whether the tab's primary control can be pressed, and what it says
/// (spec 5.1 item 3, E-20, the T7 design note: "one primary Start button that
/// becomes Resume when a session is paused").
enum PrompterStartAvailability: Equatable {
    /// Start (or, with a session already running, a way back to its stage).
    case ready
    /// A session is paused, for any reason: pressing continues it.
    case resume
    case unavailable(Reason)

    enum Reason: Equatable {
        /// No page has a word (E-20).
        case nothingToRead
        /// A big script is being tokenized on a background task; a second
        /// Start meanwhile does nothing (ruling 20.4 #11).
        case preparing
        /// The library is from a newer Isla: readable by it, never by this.
        case libraryReadOnly
        case libraryUnreadable
    }

    var isEnabled: Bool {
        if case .unavailable = self { return false }
        return true
    }

    @MainActor
    var label: String {
        self == .resume ? localized("Resume") : localized("Start")
    }

    /// The stated reason Start is dim, nil when it is not.
    @MainActor
    var reason: String? {
        guard case .unavailable(let reason) = self else { return nil }
        switch reason {
        case .nothingToRead: return localized("Nothing to read yet")
        case .preparing: return localized("Preparing your script…")
        case .libraryReadOnly: return localized("Saved by a newer Isla, so it is read-only")
        case .libraryUnreadable: return localized("Couldn't read your scripts")
        }
    }
}

// MARK: - Notices

/// What is wrong with the library, as the tab shows it. One surface per event
/// (14.4): the first two replace the tab's body with an inline alert, because
/// nothing in it can be saved; a failed save is a quiet line, because the
/// edits are kept and the speaker can still read them.
enum PrompterLibraryNotice: Equatable {
    /// `corruptCopy` is the `library.corrupt-<timestamp>.json` made before
    /// anything could be saved, nil when even the copy failed.
    case unreadable(corruptCopy: String?)
    case newerVersion(Int)
    case writeFailed

    var blocksTheTab: Bool {
        switch self {
        case .unreadable, .newerVersion: return true
        case .writeFailed: return false
        }
    }

    /// A newer Isla's file is never replaced from an older one.
    var offersNewLibrary: Bool {
        if case .unreadable = self { return true }
        return false
    }

    @MainActor
    var title: String {
        switch self {
        case .unreadable: return localized("Couldn't read your scripts")
        case .newerVersion: return localized("Saved by a newer Isla")
        case .writeFailed: return localized("Couldn't save your changes. They are kept and Isla will try again.")
        }
    }

    /// The explanation's key (and English text), so a test can look the same
    /// sentence up in either table.
    var detailKey: String {
        switch self {
        case .unreadable:
            return "Isla kept a copy of the file next to it. Nothing is deleted until you start a new library."
        case .newerVersion:
            return "A newer version of Isla saved these scripts. Update Isla to edit them; nothing here will be changed."
        case .writeFailed:
            return ""
        }
    }

    /// Literal calls, for the same reason as the sample script's; held equal
    /// to `detailKey` by a test.
    @MainActor
    var detail: String {
        switch self {
        case .unreadable:
            return localized("Isla kept a copy of the file next to it. Nothing is deleted until you start a new library.")
        case .newerVersion:
            return localized("A newer version of Isla saved these scripts. Update Isla to edit them; nothing here will be changed.")
        case .writeFailed:
            return ""
        }
    }
}

/// A refused edit, shown once on the control that caused it (14.4: over a
/// size limit is a field error, never a toast and never a banner as well).
struct PrompterInlineError: Equatable {
    enum Target: Equatable {
        case addPage
        case editor
        case newScript
        case duplicateScript
    }

    let target: Target
    let message: String
}

/// The capture chip of the control row (spec 5.1 item 3): the setting, never
/// a promise (11.5).
struct PrompterTabChip: Equatable {
    let text: String
    let symbol: String
    /// Visible: the chip leads to the switch in Settings.
    let opensSettings: Bool
    let caveat: String
}

/// The quiet line under the editor: words and an estimated reading time at
/// the current speed.
struct PrompterTabStats: Equatable {
    let words: Int
    let seconds: Double

    @MainActor
    var line: String {
        localized("Words: %d · %@", words, Self.clock(seconds))
    }

    /// `m:ss`; anything that is not a finite, non-negative number is `0:00`.
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let whole = Int(seconds)
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

// MARK: - Library

extension PrompterLibrary {
    /// The script the tab shows and a start reads: the library's current one,
    /// or the first when none is current. One definition, so the tab and a
    /// hot-key start cannot disagree about which script that is (ruling
    /// 20.3 #10).
    var activeScript: PrompterScriptRecord? {
        currentScriptID.flatMap(script) ?? scripts.first
    }
}

// MARK: - Model

/// What the Prompter tab is showing and what it does about it.
///
/// It is held by `PrompterParts`, so a display change that rebuilds the panel
/// (and with it every view and the view model) hands the new panel the same
/// model: the page, the caret and the text are where the speaker left them
/// (7.3). Everything an edit changes goes straight to the library, which
/// saves it on its own debounce.
@MainActor
final class PrompterTabModel: ObservableObject {
    private let library: PrompterLibrary
    private let session: PrompterSession
    private let sample: () -> PrompterSampleScript

    /// The selected page of the active script. The view model mirrors it into
    /// `prompterPage`, the page a start begins on.
    @Published private(set) var page = 0
    /// The one message a refused edit leaves, until the next edit, selection
    /// or dismissal.
    @Published private(set) var inlineError: PrompterInlineError?
    /// Moves when an edit was refused: the editor shows the text the library
    /// kept, not the text that was typed over it.
    @Published private(set) var revision = 0

    /// The sample was offered, or the library turned out not to need one. The
    /// library's own `isFirstRun` stays true for the rest of the run, so
    /// without this an emptied library would be seeded again the next time
    /// the tab appeared (the upstream bug spec 5.1 names).
    private var didSeed = false
    private var seededScriptID: UUID?

    private struct SelectionKey: Hashable {
        let script: UUID
        let page: Int
    }
    private var selections: [SelectionKey: NSRange] = [:]

    init(
        library: PrompterLibrary,
        session: PrompterSession,
        sample: @escaping () -> PrompterSampleScript = { PrompterSampleScript.current }
    ) {
        self.library = library
        self.session = session
        self.sample = sample
    }

    // MARK: Reading

    var script: PrompterScriptRecord? { library.activeScript }
    var pages: [String] { script?.pages ?? [] }
    var canEdit: Bool { library.canWrite }
    var readMarks: Set<Int> { session.readPages }

    /// The page's text, or empty when there is no page.
    var pageText: String {
        let pages = pages
        return pages.indices.contains(page) ? pages[page] : ""
    }

    var showsFirstRunHint: Bool {
        guard let seededScriptID else { return false }
        return seededScriptID == script?.id
    }

    var notice: PrompterLibraryNotice? {
        switch library.status {
        case .unreadable(let copy): return .unreadable(corruptCopy: copy)
        case .newerVersion(let version): return .newerVersion(version)
        case .notLoaded, .ready: return library.writeFailure == nil ? nil : .writeFailed
        }
    }

    // MARK: First run

    /// Called when the tab appears. Seeds the sample into a library that
    /// never had a file, once; looks at nothing else.
    func prepare() {
        guard !didSeed, library.status == .ready else { return }
        didSeed = true
        guard library.isFirstRun, library.scripts.isEmpty else { return }
        let sample = sample()
        guard let id = try? library.addScript(title: sample.title, pages: sample.pages) else { return }
        library.setCurrentScript(id)
        seededScriptID = id
        page = 0
    }

    // MARK: Scripts

    func selectScript(_ id: UUID) {
        guard library.script(id) != nil else { return }
        library.setCurrentScript(id)
        page = 0
        inlineError = nil
    }

    @discardableResult
    func addScript() -> Bool {
        do {
            let id = try library.addScript(title: localized("Untitled Script"))
            library.setCurrentScript(id)
            page = 0
            inlineError = nil
            return true
        } catch {
            surface(error, on: .newScript)
            return false
        }
    }

    /// A blank title would leave a row with no name, so it is refused.
    func renameScript(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let id = script?.id else { return }
        try? library.renameScript(id, title: trimmed)
    }

    @discardableResult
    func duplicateScript() -> Bool {
        guard let original = script else { return false }
        do {
            let id = try library.duplicateScript(original.id, title: localized("%@ Copy", original.title))
            library.setCurrentScript(id)
            page = 0
            inlineError = nil
            return true
        } catch {
            surface(error, on: .duplicateScript)
            return false
        }
    }

    /// The view asks first (`ConfirmTextButton`); this is the deed. The
    /// script that takes its place is its neighbour, not whichever is first.
    func deleteScript() {
        guard let doomed = script, let at = library.scripts.firstIndex(where: { $0.id == doomed.id }) else { return }
        guard (try? library.deleteScript(doomed.id)) != nil else { return }
        selections = selections.filter { $0.key.script != doomed.id }
        if seededScriptID == doomed.id { seededScriptID = nil }
        let remaining = library.scripts
        library.setCurrentScript(remaining.isEmpty ? nil : remaining[min(at, remaining.count - 1)].id)
        page = 0
        inlineError = nil
    }

    // MARK: Pages

    func selectPage(_ index: Int) {
        guard pages.indices.contains(index) else { return }
        page = index
        inlineError = nil
    }

    @discardableResult
    func addPage() -> Bool {
        guard let id = script?.id else { return false }
        do {
            page = try library.addPage(scriptID: id)
            inlineError = nil
            return true
        } catch {
            surface(error, on: .addPage)
            return false
        }
    }

    /// The last page cannot go: a script with no page has no editor and no
    /// way to add text back. Delete the script instead.
    var canDeletePage: Bool { canEdit && pages.count > 1 }

    /// Any text at all, whitespace included, is the owner's and is confirmed
    /// (spec 5.1: "delete after arm-then-confirm if non-empty").
    func deletionNeedsConfirmation(page index: Int) -> Bool {
        pages.indices.contains(index) && !pages[index].isEmpty
    }

    func deletePage(_ index: Int) {
        guard canDeletePage, pages.indices.contains(index), let id = script?.id else { return }
        guard (try? library.deletePage(scriptID: id, index: index)) != nil else { return }
        selections = selections.filter { $0.key.script != id }
        let remaining = pages.count
        if index < page {
            page -= 1
        } else if index == page {
            page = min(page, remaining - 1)
        }
        inlineError = nil
    }

    /// The page at `from` ends up at `to`; the page being read stays the one
    /// being read wherever it lands.
    func movePage(from: Int, to: Int) {
        guard canEdit, from != to, pages.indices.contains(from), pages.indices.contains(to),
              let id = script?.id else { return }
        guard (try? library.movePage(scriptID: id, from: from, to: to)) != nil else { return }
        selections = selections.filter { $0.key.script != id }
        if page == from {
            page = to
        } else if from < page, to >= page {
            page -= 1
        } else if from > page, to <= page {
            page += 1
        }
    }

    // MARK: Editing

    func setText(_ text: String) {
        guard canEdit, let script, pages.indices.contains(page), text != pages[page] else { return }
        do {
            try library.setPage(scriptID: script.id, index: page, text: text)
            inlineError = nil
        } catch {
            surface(error, on: .editor)
            revision += 1
        }
    }

    func dismissInlineError() {
        if inlineError != nil { inlineError = nil }
    }

    /// Only the limits are field errors. A read-only or unreadable library
    /// already has its alert, and a second message would be a second surface
    /// for one event.
    private func surface(_ error: Error, on target: PrompterInlineError.Target) {
        guard let error = error as? PrompterLibraryError else { return }
        switch error {
        case .tooManyPages(let limit):
            inlineError = PrompterInlineError(target: target, message: localized("A script can have up to %d pages.", limit))
        case .scriptTooLong(let limit):
            let formatted = limit.formatted(.number)
            inlineError = PrompterInlineError(target: target, message: localized("A script can hold up to %@ characters.", formatted))
        case .tooManyScripts(let limit):
            inlineError = PrompterInlineError(target: target, message: localized("You can keep up to %d scripts.", limit))
        default:
            return
        }
    }

    // MARK: Caret

    /// The editor reports where the caret and selection are; the model keeps
    /// one per page of the active script.
    func recordSelection(_ range: NSRange) {
        guard let id = script?.id, range.location != NSNotFound else { return }
        selections[SelectionKey(script: id, page: page)] = range
    }

    /// The remembered selection, clamped to the text as it is now.
    var restoredSelection: NSRange? {
        guard let id = script?.id, let range = selections[SelectionKey(script: id, page: page)] else { return nil }
        let length = pageText.utf16.count
        let location = min(max(range.location, 0), length)
        return NSRange(location: location, length: min(max(range.length, 0), length - location))
    }

    // MARK: Library notices

    /// "Start a new library", after the view's arm-then-confirm. Only from
    /// the unreadable state; the library refuses anything else.
    func startNewLibrary() {
        guard (try? library.startFreshLibrary()) != nil else { return }
        // The owner chose an empty library: no sample is dropped into it.
        didSeed = true
        seededScriptID = nil
        selections.removeAll()
        page = 0
        inlineError = nil
    }

    /// What Reveal in Finder shows: the corrupt copy made before anything
    /// could be saved, or the library's folder when even the copy failed.
    nonisolated static func revealTarget(corruptCopy: String?, directory: URL) -> URL {
        guard let corruptCopy else { return directory }
        return directory.appendingPathComponent(corruptCopy)
    }

    // MARK: Start

    func startAvailability(isPreparing: Bool) -> PrompterStartAvailability {
        if session.state.isLive {
            if case .paused = session.state { return .resume }
            return .ready
        }
        switch library.status {
        case .unreadable: return .unavailable(.libraryUnreadable)
        case .newerVersion: return .unavailable(.libraryReadOnly)
        case .notLoaded: return .unavailable(.nothingToRead)
        case .ready: break
        }
        if isPreparing { return .unavailable(.preparing) }
        guard pages.contains(where: PrompterParts.hasWords) else { return .unavailable(.nothingToRead) }
        return .ready
    }

    // MARK: Pure helpers

    /// 5.1 item 3 and 11.5.
    static func captureChip(hidden: Bool) -> PrompterTabChip {
        PrompterTabChip(
            text: hidden ? localized("Hidden from screen sharing") : localized("Visible when sharing"),
            symbol: hidden ? "eye.slash" : "eye",
            opensSettings: !hidden,
            caveat: localized("Hiding works only where the app capturing your screen honors it, and never from a hardware mirror.")
        )
    }

    /// A covered list shows no title, only a position, so a screen share
    /// learns nothing from the names of the talks.
    static func displayTitle(_ record: PrompterScriptRecord, position: Int, covered: Bool) -> String {
        if covered { return localized("Script %d", position + 1) }
        return record.title.isEmpty ? localized("Untitled Script") : record.title
    }

    /// Words a speaker will actually read (cues and dashes are not) and the
    /// time they take at `speed`. A page over the synchronous tokenizing
    /// limit is counted by whitespace instead of being tokenized on every
    /// keystroke: a figure for a quiet line, not a contract.
    static func stats(for text: String, speed: Double) -> PrompterTabStats {
        let words: Int
        if PrompterParts.tokenizesAtOnce([text]) {
            words = PromptScript(text).speakableWordCount
        } else {
            words = text.split(whereSeparator: \.isWhitespace).count
        }
        return PrompterTabStats(words: words, seconds: Double(words) / PromptClock.clampedSpeed(speed))
    }

    /// One press of the speed stepper (8.1: 0.5 to 8 in steps of 0.5).
    static func steppedSpeed(_ speed: Double, by steps: Int) -> Double {
        PromptClock.clampedSpeed(PromptClock.clampedSpeed(speed) + Double(steps) * PromptClock.speedStep)
    }

    static func canStep(_ speed: Double, by steps: Int) -> Bool {
        steppedSpeed(speed, by: steps) != PromptClock.clampedSpeed(speed)
    }
}
