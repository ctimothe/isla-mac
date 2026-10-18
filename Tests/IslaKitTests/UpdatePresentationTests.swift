import Foundation
import SwiftUI
import XCTest
@testable import IslaKit

/// What Settings → About says in each state of an update, as a pure value: the
/// states, their words, which buttons they offer and what the progress is.
@MainActor
final class UpdatePresentationTests: XCTestCase {
    private let page = URL(string: "https://github.com/ctimothe/isla-mac/releases/tag/v0.3.1")!

    private func release(notes: String = "- Fixed the lyric sweep.", image: Bool = true, signature: Bool = true, size: Int64 = 9_800_000) -> UpdateCheck.Release {
        let base = "https://github.com/ctimothe/isla-mac/releases/download/v0.3.1/"
        return UpdateCheck.Release(
            version: "0.3.1", page: page, notes: notes,
            dmg: image ? .init(name: "Isla-0.3.1.dmg", url: URL(string: base + "Isla-0.3.1.dmg")!, size: size) : nil,
            signature: signature ? .init(name: "Isla-0.3.1.dmg.sig", url: URL(string: base + "Isla-0.3.1.dmg.sig")!, size: 88) : nil
        )
    }

    private func make(
        check: UpdateCheck.State = .idle, known: UpdateCheck.Release? = nil,
        phase: UpdateInstaller.Phase = .idle, installerRelease: UpdateCheck.Release? = nil,
        manual: UpdateInstaller.ManualReason? = nil
    ) -> UpdatePresentation {
        UpdatePresentation.make(
            check: check, known: known, phase: phase, installerRelease: installerRelease, manualReason: manual, runningVersion: "0.3.0"
        )
    }

    // MARK: States and their words

    func testUpToDate() {
        let p = make(check: .upToDate(version: "0.3.0"))
        XCTAssertEqual(p.stage, .upToDate)
        XCTAssertEqual(p.title, "Isla is up to date")
        XCTAssertEqual(p.subtitle, "Isla 0.3.0")
        XCTAssertEqual(p.progress, .none)
        XCTAssertEqual(p.actions, [.updateStatus])
        XCTAssertNil(p.notes)
    }

    func testBeforeAnyCheckItOffersTheCheck() {
        let p = make()
        XCTAssertEqual(p.stage, .idle)
        XCTAssertEqual(p.title, "Isla 0.3.0")
        XCTAssertEqual(p.actions, [.updateStatus])
    }

    func testChecking() {
        let p = make(check: .checking)
        XCTAssertEqual(p.stage, .checking)
        XCTAssertEqual(p.title, "Checking for updates…")
        XCTAssertEqual(p.progress, .spinner)
        XCTAssertEqual(p.actions, [])
    }

    func testAnAvailableUpdateShowsItsSizeNotesAndTwoButtons() {
        let r = release()
        let p = make(check: .available(r), known: r)
        XCTAssertEqual(p.stage, .available(r))
        XCTAssertEqual(p.title, "Isla 0.3.1")
        XCTAssertEqual(p.subtitle, "Update available · \(ByteCountFormatter.string(fromByteCount: 9_800_000, countStyle: .file))")
        XCTAssertTrue(p.subtitle?.contains("9.8") == true || p.subtitle?.contains("9,8") == true, p.subtitle ?? "")
        XCTAssertEqual(p.notes, "- Fixed the lyric sweep.")
        XCTAssertEqual(p.actions, [.updateMoreInfo, .updateNow], "Update Now is the trailing, prominent one")
        XCTAssertEqual(p.progress, .none)
    }

    func testNoNotesMeansNoNotesArea() {
        let r = release(notes: "")
        XCTAssertNil(make(known: r).notes)
    }

    func testAKnownUpdateStaysOnOfferThroughARecheckAndAFailedOne() {
        let r = release()
        for check: UpdateCheck.State in [.checking, .failed(.offline), .idle] {
            let p = make(check: check, known: r)
            XCTAssertEqual(p.stage, .available(r), "\(check)")
        }
        XCTAssertEqual(make(check: .failed(.offline), known: r).footnotes, ["Could not reach GitHub. Try again later."])
    }

    func testDownloadingIsDeterminateWithBytesAndCancel() {
        let r = release()
        let p = make(known: r, phase: .downloading(received: 4_200_000, total: 9_800_000), installerRelease: r)
        XCTAssertEqual(p.title, "Downloading Isla 0.3.1…")
        XCTAssertEqual(p.progress, .determinate(4_200_000.0 / 9_800_000.0))
        let formatter = { (n: Int64) in ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
        XCTAssertEqual(p.detail, "\(formatter(4_200_000)) of \(formatter(9_800_000))")
        XCTAssertEqual(p.actions, [.updateCancel])
        XCTAssertNil(p.notes)
    }

    func testTheProgressFractionIsClampedAndSafeAtZero() {
        let r = release()
        XCTAssertEqual(make(known: r, phase: .downloading(received: 0, total: 0), installerRelease: r).progress, .determinate(0))
        XCTAssertEqual(make(known: r, phase: .downloading(received: 20, total: 10), installerRelease: r).progress, .determinate(1))
    }

    func testVerifyingInstallingAndRelaunchingAreIndeterminateWithNoButtons() {
        let r = release()
        let verifying = make(known: r, phase: .verifying, installerRelease: r)
        XCTAssertEqual(verifying.title, "Verifying…")
        XCTAssertEqual(verifying.progress, .indeterminate)
        XCTAssertEqual(verifying.actions, [])
        let installing = make(known: r, phase: .installing, installerRelease: r)
        XCTAssertEqual(installing.title, "Installing…")
        XCTAssertEqual(installing.progress, .indeterminate)
        let relaunching = make(known: r, phase: .relaunching, installerRelease: r)
        XCTAssertEqual(relaunching.title, "Restarting Isla…")
        XCTAssertEqual(relaunching.progress, .indeterminate)
        XCTAssertEqual(relaunching.actions, [])
    }

    /// A check finishing mid-install (the daily one) must not change what the
    /// panel says about the install under way.
    func testTheInstallInProgressWinsOverALaterCheck() {
        let running = release()
        var newer = release()
        newer = UpdateCheck.Release(version: "0.4.0", page: page)
        let p = make(check: .available(newer), known: newer, phase: .installing, installerRelease: running)
        XCTAssertEqual(p.stage, .installing(running))
        let up = make(check: .upToDate(version: "0.3.0"), known: nil, phase: .downloading(received: 1, total: 2), installerRelease: running)
        XCTAssertEqual(up.title, "Downloading Isla 0.3.1…")
    }

    func testEachFailureHasItsOwnReasonLine() {
        let r = release()
        let reasons: [UpdateInstaller.Failure: String] = [
            .signature: "The download didn't match Isla's signature, so it was deleted.",
            .offline: "Isla couldn't reach GitHub.",
            .diskSpace: "There isn't enough space on the disk.",
            .cannotReplace: "Isla couldn't replace itself in its folder.",
            .invalidUpdate: "The downloaded app isn't a valid Isla update.",
        ]
        for (failure, line) in reasons {
            let p = make(known: r, phase: .failed(failure), installerRelease: r)
            XCTAssertEqual(p.title, "The update couldn't be installed.", "\(failure)")
            XCTAssertEqual(p.subtitle, line, "\(failure)")
            XCTAssertEqual(p.actions, [.updateRetry], "\(failure)")
            XCTAssertEqual(p.progress, .none)
        }
    }

    func testACouldntOpenFailureHasItsOwnReasonLine() {
        let r = release()
        let p = make(known: r, phase: .failed(.cannotOpen), installerRelease: r)
        XCTAssertEqual(p.title, "The update couldn't be installed.")
        XCTAssertEqual(p.subtitle, "Isla couldn't open the downloaded update.")
        XCTAssertEqual(p.actions, [.updateRetry])
    }

    func testAnInstalledUpdateThatCouldNotRestartAsksToQuit() {
        let r = release()
        let p = make(known: r, phase: .restartNeeded, installerRelease: r)
        XCTAssertEqual(p.stage, .restartNeeded(r))
        XCTAssertEqual(p.title, "Isla has been updated. Quit Isla and open it again to finish.")
        XCTAssertEqual(p.actions, [.updateQuit])
        XCTAssertEqual(SettingsRowID.updateQuit.title, "Quit Isla")
        XCTAssertEqual(p.progress, .none)
        XCTAssertNil(p.notes)
    }

    func testTheOwnershipAndIdentityVerdictsReadRight() {
        let r = release()
        XCTAssertEqual(make(known: r, manual: .notOwned).title, "Isla can't update itself from this location.")
        XCTAssertEqual(make(known: r, phase: .manualOnly(.identityChanged), installerRelease: r).title,
                       "This update can only be installed from its download page.")
    }

    func testACancelledInstallIsOfferedAgainWithoutAnError() {
        let r = release()
        let p = make(known: r, phase: .failed(.cancelled), installerRelease: r)
        XCTAssertEqual(p.stage, .available(r))
        XCTAssertEqual(p.title, "Isla 0.3.1")
    }

    func testManualOnlyByLocationOffersTheDownloadPage() {
        let r = release()
        for reason: UpdateInstaller.ManualReason in [.translocated, .mountedVolume, .notAnApp, .notWritable] {
            let p = make(known: r, manual: reason)
            XCTAssertEqual(p.stage, .manualOnly(r, reason))
            XCTAssertEqual(p.title, "Isla can't update itself from this location.")
            XCTAssertEqual(p.actions, [.downloadUpdate])
            XCTAssertEqual(p.footnotes, ["Quit Isla, then replace it in Applications with the new version."])
        }
    }

    func testManualOnlyByBuildOrReleaseSaysSo() {
        let r = release(signature: false)
        for reason: UpdateInstaller.ManualReason in [.noPublicKey, .noImage, .noSignature] {
            let p = make(known: r, manual: reason)
            XCTAssertEqual(p.title, "This update can only be installed from its download page.")
            XCTAssertEqual(p.actions, [.downloadUpdate])
        }
    }

    func testAManualVerdictFromTheInstallerShowsTheSameWay() {
        let r = release()
        let p = make(known: r, phase: .manualOnly(.notWritable), installerRelease: r)
        XCTAssertEqual(p.stage, .manualOnly(r, .notWritable))
    }

    func testCheckFailuresAreFootnotesNotTheCard() {
        XCTAssertEqual(make(check: .failed(.offline)).footnotes, ["Could not reach GitHub. Try again later."])
        XCTAssertEqual(make(check: .failed(.rateLimited)).footnotes, ["GitHub is limiting checks right now. Try again in an hour."])
        XCTAssertEqual(make(check: .failed(.server)).footnotes, ["GitHub did not answer properly. Try again later."])
        XCTAssertEqual(make(check: .failed(.offline)).stage, .idle)
        XCTAssertEqual(make(check: .failed(.offline)).actions, [.updateStatus])
    }

    // MARK: Russian

    func testEveryStateHasARussianLine() throws {
        // The lab renders Russian; the table gate checks the keys. Here: every
        // string this value can produce is a key in the English table.
        let root = VisualLab.repositoryRoot.appendingPathComponent("Resources")
        let table = try String(contentsOf: root.appendingPathComponent("ru.lproj/Localizable.strings"), encoding: .utf8)
        for key in [
            "Isla is up to date", "Checking for updates…", "Update available · %@", "Update available",
            "Downloading Isla %@…", "%@ of %@", "Verifying…", "Installing…", "Restarting Isla…",
            "The update couldn't be installed.", "The download didn't match Isla's signature, so it was deleted.",
            "Isla couldn't reach GitHub.", "There isn't enough space on the disk.",
            "Isla couldn't replace itself in its folder.", "The downloaded app isn't a valid Isla update.",
            "Isla can't update itself from this location.", "This update can only be installed from its download page.",
            "Update Now", "More Info…", "Isla has been updated. Quit Isla and open it again to finish.",
            "Isla couldn't open the downloaded update.",
        ] {
            XCTAssertTrue(table.contains("\"\(key)\" ="), key)
        }
    }

    // MARK: The notes

    func testNotesLoseTheirLinksAndKeepTheirText() {
        let rendered = UpdatePresentation.renderedNotes("Fixes [the sweep](https://example.com/x) and `code`.")
        XCTAssertEqual(String(rendered.characters), "Fixes the sweep and code.")
        XCTAssertTrue(rendered.runs.allSatisfy { $0.link == nil }, "links are not clickable inside the panel")
    }

    func testNotesAreReadableAsPlainMarkdown() {
        let rendered = UpdatePresentation.renderedNotes("## Fixed\n- one\n- two\n\n**Bold** line")
        let text = String(rendered.characters)
        XCTAssertTrue(text.contains("Fixed"))
        XCTAssertFalse(text.contains("##"))
        XCTAssertTrue(text.contains("• one"))
        XCTAssertTrue(text.contains("• two"))
        XCTAssertTrue(text.contains("Bold line"))
        XCTAssertEqual(UpdatePresentation.renderedNotes("").characters.count, 0)
    }

    func testMarkdownThatCannotBeParsedIsShownAsText() {
        let text = "a [broken(link"
        XCTAssertEqual(String(UpdatePresentation.renderedNotes(text).characters), text)
    }
}
