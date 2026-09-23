import AppKit
import Quartz

/// Quick Look and AirDrop for the Shelf: the two things a file on a shelf is
/// most often kept for besides dragging it out. AirDrop is the paid notch
/// apps' most-praised shelf feature.
///
/// Both act on what a drag would carry: the whole selection when the card
/// belongs to it, otherwise that card. See `ShelfStore.dragURLs`.
@MainActor
enum ShelfSharing {
    // MARK: AirDrop

    static func canAirDrop(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { return false }
        return service.canPerform(withItems: urls)
    }

    /// The system's own AirDrop sheet. It is drawn by macOS, so it looks and
    /// behaves the way it does in Finder, and nothing about the files passes
    /// through Isla beyond their URLs.
    static func airDrop(_ urls: [URL]) {
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else { return }
        // The app never activates on its own. Here the user asked for a window
        // to choose a device in, and an inactive app's window opens behind the
        // one they are working in.
        NSApp.activate()
        service.perform(withItems: urls)
    }

    // MARK: Quick Look

    private static let source = QuickLookSource()

    /// The system's Quick Look panel on the files, the one space bar opens in
    /// Finder.
    ///
    /// The panel is handed its data source directly. Apple's documented
    /// route is a controller in the key window's responder chain, and this
    /// panel is almost never key: it takes the keyboard only for Translate.
    /// macOS logs a note about the missing controller and shows the files
    /// anyway. The app is activated for the same reason as AirDrop, because
    /// the panel needs to be key to take the space bar and arrow keys.
    static func quickLook(_ urls: [URL]) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        source.urls = urls
        NSApp.activate()
        panel.dataSource = source
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        panel.makeKeyAndOrderFront(nil)
    }

    private final class QuickLookSource: NSObject, QLPreviewPanelDataSource {
        var urls: [URL] = []

        func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

        func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
            urls.indices.contains(index) ? urls[index] as NSURL : nil
        }
    }
}
