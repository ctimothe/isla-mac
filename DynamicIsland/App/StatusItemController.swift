import AppKit

/// Locked decision: an LSUIElement app has no Dock icon and no discoverable
/// way to quit without this. Also carries the BSD-3-Clause attribution for
/// the vendored mediaremote-adapter dependency.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        statusItem.button?.image = NSImage(
            systemSymbolName: "smallcircle.filled.circle",
            accessibilityDescription: "Dynamic Island"
        )

        let menu = NSMenu()
        menu.addItem(withTitle: "About Dynamic Island", action: #selector(showAbout), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items {
            item.target = self
        }
        statusItem.menu = menu
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
