import AppKit
import Quartz

/// Quick Look and AirDrop for the Shelf: the two things a file on a shelf is
/// most often kept for besides dragging it out. AirDrop is the paid notch
/// apps' most-praised shelf feature.
///
/// Both act on what a drag would carry: the whole selection when the card
/// belongs to it, otherwise that card. See `ShelfStore.dragURLs`.
///
/// Both open a window the user must work in, and an app that is not active
/// gets its windows behind the one in front, so both activate Isla. Both
/// also hand activation back to the app that had it when their window
/// closes. Left active, Isla held the keyboard with no window to type in,
/// and the document the user had been writing in stopped answering until it
/// was clicked.
@MainActor
enum ShelfSharing {
    // MARK: Returning the keyboard

    private static var returnTo: NSRunningApplication?

    private static func activateRemembering() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { returnTo = front }
        NSApp.activate()
    }

    fileprivate static func giveBackActivation() {
        guard let app = returnTo else { return }
        returnTo = nil
        // Only if Isla is still the one in front. A user who clicked into a
        // third app meanwhile has already chosen where the keyboard goes.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier else { return }
        app.activate()
    }

    // MARK: AirDrop

    private static let airDropDelegate = AirDropDelegate()

    /// The system's own AirDrop sheet. It is drawn by macOS, so it looks and
    /// behaves the way it does in Finder, and nothing about the files passes
    /// through Isla beyond their URLs.
    ///
    /// The row is always in the menu, and whether AirDrop can take the files
    /// is asked here, on the click. Asked in the menu, it ran for every card
    /// on every redraw, because a SwiftUI context menu's contents are built
    /// with the card.
    static func airDrop(_ urls: [URL]) {
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            NSSound.beep()
            return
        }
        service.delegate = airDropDelegate
        activateRemembering()
        service.perform(withItems: urls)
    }

    private final class AirDropDelegate: NSObject, NSSharingServiceDelegate {
        func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
            MainActor.assumeIsolated { ShelfSharing.giveBackActivation() }
        }

        func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error) {
            MainActor.assumeIsolated { ShelfSharing.giveBackActivation() }
        }
    }

    // MARK: Quick Look

    /// What the panel shows. Read by the controller (`AppDelegate`) when the
    /// panel asks for one.
    static let preview = PreviewSource()

    /// The system's Quick Look panel on the files, the one space bar opens in
    /// Finder.
    ///
    /// Driven the documented way. The panel looks up the responder chain for
    /// an object that accepts control, and `AppDelegate`, which sits at the end
    /// of every chain once the app is active, accepts while there are items and
    /// hands over `preview` as data source and delegate. The panel says outright
    /// that anything else must never set its data source, and warns it will
    /// raise one day.
    static func quickLook(_ urls: [URL]) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        preview.urls = urls
        activateRemembering()
        if panel.isVisible {
            panel.reloadData()
            panel.currentPreviewItemIndex = 0
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    final class PreviewSource: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
        var urls: [URL] = []

        func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

        func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
            urls.indices.contains(index) ? urls[index] as NSURL : nil
        }

        func windowWillClose(_ notification: Notification) {
            MainActor.assumeIsolated {
                urls = []
                ShelfSharing.giveBackActivation()
            }
        }
    }
}
