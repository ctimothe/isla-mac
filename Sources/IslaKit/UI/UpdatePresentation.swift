import Foundation

/// What Settings → About says about an update, as a value.
///
/// The About section is styled after System Settings → General → Software
/// Update: a card that says what is happening and, under it, the buttons that
/// make sense *now*. Every state — up to date, checking, an update on offer,
/// downloading, verifying, installing, restarting, failed, and the cases where
/// Isla can only point at the download page — is one `Stage`, decided here from
/// three inputs: what the last check found, what the installer is doing, and
/// whether this copy of Isla may replace itself at all. The view draws the
/// result and decides nothing, so every state is a test with no view, and the
/// visual lab can show each without a download.
///
/// What outranks what: an install in progress (or failed, or refused) is about
/// the release it started with, and a check that lands meanwhile — the daily
/// one — does not change what the panel says about it. Without one, a release a
/// check has found is on offer, as the rail dot already says, through a failed
/// or in-flight recheck (J-019).
@MainActor
struct UpdatePresentation: Equatable {
    enum Stage: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateCheck.Release)
        case downloading(UpdateCheck.Release, received: Int64, total: Int64)
        case verifying(UpdateCheck.Release)
        case installing(UpdateCheck.Release)
        case relaunching(UpdateCheck.Release)
        /// Installed, and Isla could not restart itself.
        case restartNeeded(UpdateCheck.Release)
        case failed(UpdateCheck.Release, UpdateInstaller.Failure)
        case manualOnly(UpdateCheck.Release, UpdateInstaller.ManualReason)
    }

    enum Progress: Equatable {
        case none
        /// The small spinner beside "Checking for updates…".
        case spinner
        /// 0…1.
        case determinate(Double)
        /// A bar with no end in sight: verifying, installing, restarting.
        case indeterminate
    }

    let stage: Stage
    let title: String
    let subtitle: String?
    /// "4.2 MB of 9.8 MB", under the bar.
    let detail: String?
    let progress: Progress
    /// The release's notes as the author wrote them (Markdown), only while an
    /// update is on offer.
    let notes: String?
    /// The buttons under the card, leading to trailing: the prominent one is
    /// last, as in a macOS alert.
    let actions: [SettingsRowID]
    /// Lines under the card: why a check failed, how to install by hand.
    let footnotes: [String]
    /// The release the buttons act on.
    let release: UpdateCheck.Release?
    /// "Rehearsal: update from a local folder", under the card's title: set only
    /// when the check reads a local folder (`DI_UPDATE_REHEARSAL`), so nobody
    /// mistakes a rehearsal for a real release.
    let rehearsalNote: String?

    /// Before any check, with nothing known: the About section as a test or the
    /// default context sees it.
    static var initial: UpdatePresentation {
        make(check: .idle, known: nil, phase: .idle, installerRelease: nil, manualReason: nil, runningVersion: ProductIdentity.version)
    }

    static func make(
        check: UpdateCheck.State,
        known: UpdateCheck.Release?,
        phase: UpdateInstaller.Phase,
        installerRelease: UpdateCheck.Release?,
        manualReason: UpdateInstaller.ManualReason?,
        runningVersion: String,
        rehearsal: Bool = false
    ) -> UpdatePresentation {
        let stage = stage(
            check: check, known: known, phase: phase, installerRelease: installerRelease, manualReason: manualReason
        )
        return UpdatePresentation(stage: stage, check: check, runningVersion: runningVersion, rehearsal: rehearsal)
    }

    private static func stage(
        check: UpdateCheck.State, known: UpdateCheck.Release?, phase: UpdateInstaller.Phase,
        installerRelease: UpdateCheck.Release?, manualReason: UpdateInstaller.ManualReason?
    ) -> Stage {
        if let working = installerRelease {
            switch phase {
            case .downloading(let received, let total): return .downloading(working, received: received, total: total)
            case .verifying: return .verifying(working)
            case .installing: return .installing(working)
            case .relaunching: return .relaunching(working)
            case .restartNeeded: return .restartNeeded(working)
            case .failed(let failure) where failure != .cancelled: return .failed(working, failure)
            case .manualOnly(let reason): return .manualOnly(working, reason)
            case .failed, .idle: break
            }
        }
        if let known {
            if let reason = manualReason { return .manualOnly(known, reason) }
            return .available(known)
        }
        switch check {
        case .checking: return .checking
        case .upToDate: return .upToDate
        case .idle, .failed, .available: return .idle
        }
    }

    private init(stage: Stage, check: UpdateCheck.State, runningVersion: String, rehearsal: Bool) {
        self.stage = stage
        var title = ""
        var subtitle: String?
        var detail: String?
        var progress = Progress.none
        var notes: String?
        var actions: [SettingsRowID] = []
        var footnotes: [String] = []
        var release: UpdateCheck.Release?

        switch stage {
        case .idle:
            title = localized("Isla %@", runningVersion)
            actions = [.updateStatus]
        case .checking:
            title = localized("Checking for updates…")
            progress = .spinner
        case .upToDate:
            title = localized("Isla is up to date")
            subtitle = localized("Isla %@", runningVersion)
            actions = [.updateStatus]
        case .available(let r):
            release = r
            title = localized("Isla %@", r.version)
            if let image = r.dmg {
                subtitle = localized("Update available · %@", Self.size(image.size))
            } else {
                subtitle = localized("Update available")
            }
            notes = r.notes.isEmpty ? nil : r.notes
            actions = [.updateMoreInfo, .updateNow]
        case .downloading(let r, let received, let total):
            release = r
            title = localized("Downloading Isla %@…", r.version)
            progress = .determinate(total > 0 ? min(max(Double(received) / Double(total), 0), 1) : 0)
            detail = localized("%@ of %@", Self.size(min(received, max(total, 0))), Self.size(total))
            actions = [.updateCancel]
        case .verifying(let r):
            release = r
            title = localized("Verifying…")
            progress = .indeterminate
        case .installing(let r):
            release = r
            title = localized("Installing…")
            progress = .indeterminate
        case .relaunching(let r):
            release = r
            title = localized("Restarting Isla…")
            progress = .indeterminate
        case .restartNeeded(let r):
            release = r
            title = localized("Isla has been updated. Quit Isla and open it again to finish.")
            actions = [.updateQuit]
        case .failed(let r, let failure):
            release = r
            title = localized("The update couldn't be installed.")
            subtitle = Self.reason(failure)
            actions = [.updateRetry]
        case .manualOnly(let r, let reason):
            release = r
            title = reason.isLocation
                ? localized("Isla can't update itself from this location.")
                : localized("This update can only be installed from its download page.")
            subtitle = localized("Isla %@", r.version)
            actions = [.downloadUpdate]
            // How to do it by hand, said once the person is sent there.
            footnotes.append(localized("Quit Isla, then replace it in Applications with the new version."))
        }

        // Why a check failed. Shown whatever the card says: a known update
        // stays on offer through a failed recheck, and the failure is still news.
        if case .failed(let reason) = check {
            switch reason {
            case .offline: footnotes.insert(localized("Could not reach GitHub. Try again later."), at: 0)
            case .rateLimited: footnotes.insert(localized("GitHub is limiting checks right now. Try again in an hour."), at: 0)
            case .server: footnotes.insert(localized("GitHub did not answer properly. Try again later."), at: 0)
            }
        }

        self.title = title
        self.subtitle = subtitle
        self.detail = detail
        self.progress = progress
        self.notes = notes
        self.actions = actions
        self.footnotes = footnotes
        self.release = release
        self.rehearsalNote = rehearsal ? localized("Rehearsal: update from a local folder") : nil
    }

    /// One reason line per failure; the signature one says the file was
    /// deleted because it was.
    static func reason(_ failure: UpdateInstaller.Failure) -> String {
        switch failure {
        case .signature: return localized("The download didn't match Isla's signature, so it was deleted.")
        case .offline: return localized("Isla couldn't reach GitHub.")
        case .diskSpace: return localized("There isn't enough space on the disk.")
        case .cannotReplace: return localized("Isla couldn't replace itself in its folder.")
        case .cannotOpen: return localized("Isla couldn't open the downloaded update.")
        case .invalidUpdate, .cancelled: return localized("The downloaded app isn't a valid Isla update.")
        }
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: Notes

    /// The release notes as the panel draws them: inline Markdown with its
    /// white space kept, headings as bold lines and list markers as bullets
    /// (the inline parser knows neither), and no link left clickable — the panel
    /// is never key, and a link there would open a browser from a place that
    /// promised not to. "More Info…" is the way to the page.
    static func renderedNotes(_ markdown: String) -> AttributedString {
        let prepared = markdown
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var text = String(line)
                if let heading = text.range(of: #"^\s{0,3}#{1,6}\s+"#, options: .regularExpression) {
                    return "**" + text[heading.upperBound...].trimmingCharacters(in: .whitespaces) + "**"
                }
                if let bullet = text.range(of: #"^\s*[-*+]\s+"#, options: .regularExpression) {
                    text = "• " + text[bullet.upperBound...]
                }
                return text
            }
            .joined(separator: "\n")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var attributed = (try? AttributedString(markdown: prepared, options: options)) ?? AttributedString(prepared)
        let linked = attributed.runs.filter { $0.link != nil }.map(\.range)
        for range in linked { attributed[range].link = nil }
        return attributed
    }
}
