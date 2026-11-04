import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// What the Clipboard tab says when macOS will not let Isla read the
/// pasteboard (J-001). Under Paste from Other Apps set to Don't Allow the
/// poll stops itself, and before this the tab only went quiet: history and
/// clipboard screenshots emptied with nothing anywhere to say why.
///
/// Probed through the accessibility tree, so these run in the gate; the lab's
/// pictures of the same state are gated on ISLA_VISUAL_OUT.
@MainActor
final class ClipboardAccessNoticeTests: XCTestCase {
    private let sentence = "macOS is not letting Isla read what you copy, so nothing new is kept."
    private let size = CGSize(width: 560, height: 260)

    private func hasSentence(_ root: AXNode) -> Bool {
        root.flattened.contains { $0.label == sentence || $0.value == sentence || $0.title == sentence }
    }

    func testADeniedPasteboardIsSaidWithAWayToFixIt() async {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let clipboard = isolated.stores.clipboard
        isolated.record([.text("copied before the switch")], into: clipboard)
        clipboard.accessBehavior = { .denied }
        clipboard.recheckAccess()

        let root = await AXProbe.tree(of: ClipboardPane(clipboard: clipboard, privacy: isolated.stores.privacy), size: size)

        XCTAssertTrue(hasSentence(root), root.dump)
        let open = root.all(role: "AXButton").filter { $0.label == "Open Privacy Settings" }
        XCTAssertEqual(open.count, 1, root.dump)
        XCTAssertTrue(open.first?.actionNames.contains("AXPress") ?? false, root.dump)
        // What was kept before the refusal stays usable.
        XCTAssertEqual(root.all(role: "AXButton").filter { $0.label == "copied before the switch" }.count, 1, root.dump)
    }

    func testAnEmptyDeniedHistoryStillSaysWhy() async {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let clipboard = isolated.stores.clipboard
        clipboard.accessBehavior = { .denied }
        clipboard.recheckAccess()

        let root = await AXProbe.tree(of: ClipboardPane(clipboard: clipboard, privacy: isolated.stores.privacy), size: size)

        XCTAssertTrue(hasSentence(root), root.dump)
    }

    /// The sentence is never cut, in either language at any panel width
    /// (Batch 10, 2026-10-29). In Russian at 560 it ended "…поэтому новое н…":
    /// two lines beside «Открыть настройки конфиденциальности», which took half
    /// the row, and the sentence needed three; at 480 it needed four. Found
    /// by reading every render of the visual lab for an ellipsis. The
    /// sentence's drawn height is held against the height it needs at the
    /// width it was given.
    func testTheSentenceIsNeverCut() async throws {
        defer { LabLocalization.use("en") }
        for language in ["en", "ru"] {
            LabLocalization.use(language)
            let words = localized(sentence)
            for width in [NotchMetrics.minimumBodyWidth, NotchMetrics.defaultBodyWidth, NotchMetrics.maximumBodyWidth] {
                let isolated = ProbeFixtures.isolatedStores()
                defer { isolated.release() }
                let clipboard = isolated.stores.clipboard
                clipboard.accessBehavior = { .denied }
                clipboard.recheckAccess()

                let pane = ClipboardPane(clipboard: clipboard, privacy: isolated.stores.privacy, bodyWidth: width)
                let root = await AXProbe.tree(of: pane, size: CGSize(width: width, height: size.height))
                let drawn = try XCTUnwrap(
                    root.flattened.first { $0.label == words || $0.value == words }?.frame,
                    "\(language) at \(width): no sentence\n\(root.dump)"
                )
                let needed = NSHostingView(rootView: Text(words)
                    .islandFont(.body, weight: .regular)
                    .frame(width: drawn.width, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)).fittingSize.height
                XCTAssertGreaterThanOrEqual(
                    drawn.height, needed - 0.5,
                    "\(language) at \(width): the sentence is cut (\(drawn.width) wide, \(drawn.height) of \(needed) tall)"
                )
            }
        }
    }

    /// Ask and Allow are not failures, and the tab says nothing about them:
    /// one failure surface, and only for the failure.
    func testAnAllowedPasteboardSaysNothing() async {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let clipboard = isolated.stores.clipboard
        for access in [ClipboardAccess.allowed, .ask, .unknown] {
            clipboard.accessBehavior = { access }
            clipboard.recheckAccess()
            let root = await AXProbe.tree(of: ClipboardPane(clipboard: clipboard, privacy: isolated.stores.privacy), size: size)
            XCTAssertFalse(hasSentence(root), "\(access)\n\(root.dump)")
            XCTAssertNil(root.first(label: "Open Privacy Settings"), "\(access)\n\(root.dump)")
        }
    }

    /// A user back from System Settings looks at the tab, and that look is
    /// what restarts the poll: it stopped itself under Don't Allow and cannot
    /// notice the change on its own.
    func testOpeningTheTabAfterAllowResumesHistory() async {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let clipboard = isolated.stores.clipboard
        var answer = ClipboardAccess.denied
        clipboard.accessBehavior = { answer }
        clipboard.start()
        XCTAssertFalse(clipboard.isPolling)
        XCTAssertEqual(clipboard.access, .denied)

        answer = .allowed
        let root = await AXProbe.tree(of: ClipboardPane(clipboard: clipboard, privacy: isolated.stores.privacy), size: size)

        XCTAssertEqual(clipboard.access, .allowed)
        XCTAssertTrue(clipboard.isPolling)
        XCTAssertFalse(hasSentence(root), root.dump)
    }

    /// The pane's own anchor first, then the Privacy & Security root, which
    /// is where the switch lives if a macOS stops honouring the anchor.
    func testTheButtonAimsAtPasteFromOtherApps() {
        let urls = ClipboardPane.privacySettingsURLs.map(\.absoluteString)
        XCTAssertEqual(urls, [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard",
            "x-apple.systempreferences:com.apple.preference.security",
        ])
    }
}
