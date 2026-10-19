import Foundation

/// The island's update alert (spec §19.5 f): a release Update Now can install,
/// offered once per version at the first idle moment, with a choice of Later
/// or Install.
///
/// Settings › About already offered every update, behind a gear's badge, and
/// nothing on the island said one was there. With the local feed the owner's
/// own Mac follows each change as it is made (plan 2026-10-19), and the island
/// is where it is offered: one click from a published build to the running
/// app, without opening anything.
struct UpdateOffer: Equatable {
    let release: UpdateCheck.Release
    /// The first sentence of the release's notes, or nil when they say
    /// nothing a line could carry.
    let summary: String?

    init(release: UpdateCheck.Release) {
        self.release = release
        summary = Self.summary(of: release.notes)
    }

    var version: String { release.version }

    /// The line under the title: the first sentence of the notes' first line
    /// of prose. The notes are Markdown — GitHub's, or the publish script's
    /// list of commit subjects — so headings, rules and code fences are passed
    /// over, a list marker is taken off, and inline markup (emphasis, code,
    /// links) is read as the text it marks. Truncating it to the alert's width
    /// is the view's; this only picks the words.
    nonisolated static func summary(of notes: String) -> String? {
        var inFence = false
        for raw in notes.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            guard !inFence, !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(">") else { continue }
            // A rule (---, ***, ___) is not prose.
            if line.count >= 3, Set(line.replacingOccurrences(of: " ", with: "")).count == 1,
               let mark = line.first, "-*_".contains(mark) { continue }
            line = droppingListMarker(line)
            let plain = (try? AttributedString(
                markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )).map { String($0.characters) } ?? line
            let sentence = firstSentence(plain).trimmingCharacters(in: .whitespaces)
            if !sentence.isEmpty { return sentence }
        }
        return nil
    }

    /// "- ", "* ", "+ " or "12. " at the start of a line.
    private nonisolated static func droppingListMarker(_ line: String) -> String {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") {
            return String(line.dropFirst(digits.count + 2)).trimmingCharacters(in: .whitespaces)
        }
        return line
    }

    /// Up to and including the first full stop, question or exclamation mark
    /// that ends a sentence — one followed by a space or the end of the line,
    /// so "0.3.1" and "e.g.x" are not cut.
    private nonisolated static func firstSentence(_ text: String) -> String {
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if ".!?。".contains(text[index]), next == text.endIndex || text[next] == " " {
                return String(text[...index])
            }
            index = next
        }
        return text
    }
}

/// Which version the island has had its answer about (spec §19.5 f: "that
/// version is not offered here again"). One version, the last answered; an
/// older one counts as answered with it, so a feed rolled back is not offered
/// over the build the owner already declined.
///
/// Later, the alert's 20 s running out, Settings and Quit Isla are answers.
/// Install is not, until it ends: a Mac that restarts mid-install, or an
/// install that fails and is left there, is asked again. A successful install
/// relaunches as the new version, and there is nothing left to offer.
struct UpdateOfferMemory {
    static let key = "updates.offeredVersion"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var answered: String? { defaults.string(forKey: Self.key) }

    /// Whether the island still owes `version` its offer.
    func isUnanswered(_ version: String) -> Bool {
        guard let answered else { return true }
        return UpdateCheck.isNewer(version, than: answered)
    }

    func remember(_ version: String) {
        defaults.set(version, forKey: Self.key)
    }
}

/// What a button on the update alert asks for.
enum UpdateAlertAction: Equatable {
    case later, install, tryAgain, settings, quit
}

/// What the update alert shows, by where the installer is (spec §19.5 f, and
/// plan 2026-10-19 for what happens after Install, on which the spec is
/// silent): the offer, the install under way, a failure, an update this copy
/// cannot install for itself, and an update in place that needs Isla quit.
/// Pure, so each stage is a test (`UpdateOfferTests`).
enum UpdateAlertStage: Equatable {
    /// Later, Install.
    case offer
    /// No buttons: the install runs, and the line says how far it is.
    /// `progress` is the download's fraction, or nil once it is done.
    case working(String, progress: Double?)
    /// Later, Try Again, with the reason Settings would give.
    case failed(String)
    /// Later, Settings: the card there has the download page.
    case manual(String)
    /// Later, Quit Isla.
    case restartNeeded

    /// The release the installer is working on is the offer's, or the
    /// installer is busy and Install would be ignored anyway; otherwise the
    /// offer stands — a failure left over from an older release is not this
    /// one's.
    @MainActor
    static func make(phase: UpdateInstaller.Phase, installerRelease: UpdateCheck.Release?, offer: UpdateOffer) -> UpdateAlertStage {
        guard phase.isBusy || installerRelease?.version == offer.version else { return .offer }
        switch phase {
        case .idle:
            return .offer
        case .downloading(let received, let total):
            let fraction = total > 0 ? min(max(Double(received) / Double(total), 0), 1) : 0
            // The installer's own release: busy with another one, it is that
            // one being downloaded, whatever the alert offers.
            return .working(localized("Downloading Isla %@…", installerRelease?.version ?? offer.version), progress: fraction)
        case .verifying:
            return .working(localized("Verifying…"), progress: 1)
        case .installing:
            return .working(localized("Installing…"), progress: 1)
        case .relaunching:
            return .working(localized("Restarting Isla…"), progress: 1)
        case .restartNeeded:
            return .restartNeeded
        case .failed(.cancelled):
            return .offer
        case .failed(let failure):
            return .failed(UpdatePresentation.reason(failure))
        case .manualOnly(let reason):
            return .manual(
                reason.isLocation
                    ? localized("Isla can't update itself from this location.")
                    : localized("This update can only be installed from its download page.")
            )
        }
    }

    /// The line, or two, under the title. The offer's is the summary.
    @MainActor
    func detail(summary: String?) -> String? {
        switch self {
        case .offer: return summary
        case .working(let text, _), .failed(let text), .manual(let text): return text
        case .restartNeeded: return localized("Isla has been updated. Quit Isla and open it again to finish.")
        }
    }

    /// The offer and the install under way say what Install will do; a
    /// failure, a manual update and a restart say what happened instead, in
    /// both lines.
    var showsRestartNote: Bool {
        switch self {
        case .offer, .working: return true
        case .failed, .manual, .restartNeeded: return false
        }
    }

    /// The default button, on the right; nil while the install runs. Later is
    /// on the left whenever there is a default.
    var primary: UpdateAlertAction? {
        switch self {
        case .offer: return .install
        case .working: return nil
        case .failed: return .tryAgain
        case .manual: return .settings
        case .restartNeeded: return .quit
        }
    }

    /// The download's fraction while it runs, full for the steps after it.
    var progress: Double? {
        if case .working(_, let progress) = self { return progress }
        return nil
    }

    /// Only the offer folds by itself. Once Install is pressed the alert is
    /// the install's, and a failure or a restart waits for its answer.
    var isTimed: Bool { self == .offer }
}

extension UpdateAlertAction {
    @MainActor
    var title: String {
        switch self {
        case .later: return localized("Later")
        case .install: return localized("Install")
        case .tryAgain: return localized("Try Again")
        case .settings: return localized("Settings")
        case .quit: return localized("Quit Isla")
        }
    }
}
