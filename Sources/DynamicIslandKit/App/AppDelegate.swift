import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controller: NotchController?
    private var hotKey: GlobalHotKey?
    private var translateHotKey: GlobalHotKey?
    private var statusItem: NSStatusItem?
    private var privacyItem: NSMenuItem?
    private var privacyAllItem: NSMenuItem?
    private var privacySectionItems: [PrivacyMode.Section: NSMenuItem] = [:]

    /// The browser returns from Spotify's consent page through the app's URL
    /// scheme; the account object finishes the token exchange.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "dynamicisland" {
            SpotifyAccount.shared.handleCallback(url)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = NotchController()
        controller?.install()
        installStatusItem()
        // The panel never activates, so without this it cannot be opened from
        // the keyboard at all — and anything that cannot be opened from the
        // keyboard cannot be reached by assistive tech either.
        hotKey = GlobalHotKey(
            keyCode: GlobalHotKey.defaultKeyCode,
            modifiers: GlobalHotKey.defaultModifiers
        ) { [weak self] in
            self?.togglePanel()
        }

        // Translation without a window, an app switch, or a permission.
        //
        // Two routes, because they suit different moments and neither costs
        // anything. The shortcut translates whatever is already on the
        // clipboard, which needs no setup at all. The service takes the
        // current selection from any app that offers one — macOS hands the
        // text over itself, so reading a selection asks for no Accessibility
        // access, which is what every other route to it would have cost.
        translateHotKey = GlobalHotKey(
            keyCode: GlobalHotKey.translateKeyCode,
            modifiers: GlobalHotKey.defaultModifiers
        ) { [weak self] in
            guard let text = NSPasteboard.general.string(forType: .string) else { return }
            self?.controller?.translate(text)
        }
        NSApp.servicesProvider = self
    }

    /// Entry point for the "Translate in Dynamic Island" service, named in the
    /// bundle's NSServices. macOS passes the selection on a private pasteboard.
    @objc func translateSelection(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>?
    ) {
        guard let text = pasteboard.string(forType: .string) else { return }
        controller?.translate(text)
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.teardown()
    }

    // MARK: - Menu bar item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: ProductIdentity.statusSymbolName,
            accessibilityDescription: ProductIdentity.displayName
        )
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(
            withTitle: "\(ProductIdentity.displayName) \(Bundle.main.shortVersion)",
            action: nil,
            keyEquivalent: ""
        )
        menu.addItem(.separator())

        let toggle = NSMenuItem(
            title: localized("Open Panel"),
            action: #selector(togglePanel),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)

        // Sits next to the panel switch rather than in the Settings tab: it
        // changes what the panel shows, and it is the one people look for in a
        // hurry, with the camera already running.
        //
        // A submenu rather than a plain switch, because the tabs hold different
        // things and not everyone wants all of them covered. "All" comes first
        // and is what most people will ever touch; the sections below it are
        // for the case where that is too much.
        let privacy = NSMenuItem(title: localized("Hide Contents"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let all = NSMenuItem(title: localized("All"), action: #selector(togglePrivacyAll), keyEquivalent: "")
        all.target = self
        submenu.addItem(all)
        privacyAllItem = all
        submenu.addItem(.separator())

        for section in PrivacyMode.Section.allCases {
            let item = NSMenuItem(
                title: section.title,
                action: #selector(togglePrivacySection(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = section.rawValue
            submenu.addItem(item)
            privacySectionItems[section] = item
        }

        privacy.submenu = submenu
        menu.addItem(privacy)
        privacyItem = privacy

        menu.addItem(.separator())
        let quit = NSMenuItem(title: localized("Quit"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    /// Not `private`: the Settings tab's own "Open Panel" row calls this
    /// same method through `NSApp.delegate`, rather than reaching for
    /// `NotchController` itself and reinventing what the menu already does.
    @objc func togglePanel() {
        controller?.toggle()
    }

    /// Everything shown is re-read when the menu opens, not kept fresh in
    /// between: a menu nobody is looking at deserves no bookkeeping.
    func menuWillOpen(_ menu: NSMenu) {
        refreshPrivacyItems()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func togglePrivacyAll(_ sender: NSMenuItem) {
        guard let privacy = controller?.privacy else { return }
        // Anything short of everything means "turn the rest on too"; only a
        // full house turns them all off. One press, and no state where the
        // item says All while half the sections are open.
        privacy.setCoveringAll(!privacy.coversAll)
        refreshPrivacyItems()
    }

    @objc private func togglePrivacySection(_ sender: NSMenuItem) {
        guard let privacy = controller?.privacy,
              let raw = sender.representedObject as? String,
              let section = PrivacyMode.Section(rawValue: raw) else { return }
        privacy.setCovering(section, !privacy.covers(section))
        refreshPrivacyItems()
    }

    /// The parent item carries the summary: a tick when every section is
    /// covered, a dash when some are. Without it the state is a submenu away,
    /// and this is the one switch worth reading at a glance.
    private func refreshPrivacyItems() {
        guard let privacy = controller?.privacy else { return }
        privacyItem?.state = privacy.coversAll ? .on : (privacy.coversAny ? .mixed : .off)
        privacyAllItem?.state = privacy.coversAll ? .on : .off
        for (section, item) in privacySectionItems {
            item.state = privacy.covers(section) ? .on : .off
        }
    }
}

extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }
}
