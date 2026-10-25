import AppKit
import SwiftUI

/// One row of a page's More menu (refinement pass 2026-10-25), apart from
/// AppKit, so which rows each surface lists, their words, what is enabled and
/// which shows ⌘, are things a test reads.
struct HeaderMenuItem: Equatable {
    enum Kind: Equatable {
        case lyrics, hideLyrics, lyricsSettings, clearClipboardHistory, separator, settings
    }

    var kind: Kind
    var title: String
    var isEnabled = true
    /// Whether the row shows ⌘, — only where the key really opens Settings.
    var showsSettingsKey = false
}

/// The ⋯ at the top right of every page and the stage, where the gear stood.
///
/// The gear went from the pages in the first round of this pass, and the
/// owner's first question was the right one: "how is the settings gonna be
/// accessed". The answer is the Mac's: a More button in the gear's own spot
/// and well, holding what the page can do and, below a separator, Settings….
/// Settings keeps its X (`NotchContentView.closeSettingsButton`), the way back.
///
/// A page's menu never repeats a button its header already shows: the Shelf's
/// Remove All and Translate's History stay buttons where they were — the
/// owner asked for Remove All back beside the well, not inside it — so those
/// two menus hold Settings… alone. The player's lists Lyrics; the stage's
/// Hide Lyrics and Lyrics Settings…; Clipboard's Clear History…, which asks
/// the pane's own question first.
enum HeaderMoreMenu {
    /// The rows, top to bottom, or none for a surface with no More button
    /// (Settings, the drop surface, the welcome).
    ///
    /// - Parameter hasSong: a song, playing or paused — Lyrics is enabled
    ///   for one, as the island's menu enables it (spec §19.9).
    /// - Parameter clipboardClearable: Clipboard holds an entry Clear History
    ///   would remove, and is not asking already.
    /// - Parameter panelIsKey: whether the panel has the keyboard. ⌘, opens
    ///   Settings only then (`NotchPanel.settingsKeyHandled`); on every other
    ///   surface the key belongs to the app in front, and a menu showing it
    ///   would be promising a shortcut that does nothing.
    static func items(
        for surface: NotchViewModel.Surface, hasSong: Bool, clipboardClearable: Bool, panelIsKey: Bool
    ) -> [HeaderMenuItem] {
        var page: [HeaderMenuItem]
        switch surface {
        case .player:
            page = [HeaderMenuItem(kind: .lyrics, title: localized("Lyrics"), isEnabled: hasSong)]
        case .stage:
            page = [
                HeaderMenuItem(kind: .hideLyrics, title: localized("Hide Lyrics")),
                HeaderMenuItem(kind: .lyricsSettings, title: localized("Lyrics Settings…")),
            ]
        case .clipboard:
            page = [HeaderMenuItem(
                kind: .clearClipboardHistory, title: localized("Clear History…"), isEnabled: clipboardClearable
            )]
        case .tray, .translate:
            page = []
        case .settings, .drop, .welcome:
            return []
        }
        if !page.isEmpty { page.append(HeaderMenuItem(kind: .separator, title: "")) }
        page.append(HeaderMenuItem(kind: .settings, title: localized("Settings…"), showsSettingsKey: panelIsKey))
        return page
    }

    /// The menu AppKit draws, in the system's appearance like every menu in
    /// the app. Each row runs `perform` with its kind; the menu keeps the
    /// actions alive for as long as it is.
    static func menu(_ items: [HeaderMenuItem], perform: @escaping (HeaderMenuItem.Kind) -> Void) -> NSMenu {
        let menu = ActionMenu(title: localized("More"))
        menu.autoenablesItems = false
        for item in items {
            if item.kind == .separator {
                menu.addItem(.separator())
                continue
            }
            let action = MenuAction { perform(item.kind) }
            let row = NSMenuItem(title: item.title, action: #selector(MenuAction.run(_:)), keyEquivalent: "")
            row.target = action
            row.isEnabled = item.isEnabled
            if item.showsSettingsKey {
                row.keyEquivalent = ","
                row.keyEquivalentModifierMask = .command
            }
            menu.actions.append(action)
            menu.addItem(row)
        }
        return menu
    }

    /// `NSMenuItem.target` is weak: the menu holds what its rows call.
    private final class ActionMenu: NSMenu {
        var actions: [MenuAction] = []
    }

    private final class MenuAction: NSObject {
        let body: () -> Void
        init(_ body: @escaping () -> Void) { self.body = body }
        @objc func run(_ sender: Any?) { body() }
    }
}

extension NotchViewModel {
    /// The More menu's rows for what is on screen now.
    func moreMenuItems(panelIsKey: Bool) -> [HeaderMenuItem] {
        HeaderMoreMenu.items(
            for: presented, hasSong: media.track != nil,
            clipboardClearable: !clipboardClear.isAsking && clipboard.items.contains { !$0.isPinned },
            panelIsKey: panelIsKey
        )
    }

    /// What a More row does. Each is a road that already exists — the
    /// player's Lyrics, the stage's Hide Lyrics, the lyric menu's Lyrics
    /// Settings…, Clipboard's Clear History question, the gear — so the menu
    /// adds a way in and no new behaviour.
    func performMoreMenu(_ kind: HeaderMenuItem.Kind) {
        switch kind {
        case .lyrics: openStage()
        case .hideLyrics: hideLyrics()
        case .lyricsSettings: openLyricsSettings()
        case .clearClipboardHistory:
            // The question the pane draws at its foot, with Cancel and Clear
            // History; nothing is removed until it is answered.
            clipboardClear.ask(count: clipboard.items.filter { !$0.isPinned }.count)
        case .settings: pressGear()
        case .separator: break
        }
    }
}

/// Pops the More menu up under its button, its right edge on the button's
/// (`OutputMenuPresenter.popUpPoint`), from the non-activating panel the way
/// the Output and lyric menus are: an `NSMenu` pops up from any window, key or
/// not, and `MenuTracking` holds the panel open while it is up. A SwiftUI
/// `Menu` would do the same today, but its label cannot be the gear's well
/// exactly, and the app's other menus are all built this way.
@MainActor
final class HeaderMoreMenuPresenter {
    weak var anchor: NSView?

    func present(items: (_ panelIsKey: Bool) -> [HeaderMenuItem], perform: @escaping (HeaderMenuItem.Kind) -> Void) {
        guard let anchor else { return }
        // Read as the menu opens, not as the button draws: the keyboard moves
        // between surfaces while the panel is up.
        let menu = HeaderMoreMenu.menu(items(anchor.window?.isKeyWindow == true), perform: perform)
        _ = menu.popUp(
            positioning: nil,
            at: OutputMenuPresenter.popUpPoint(anchorSize: anchor.bounds.size, menuWidth: menu.size.width),
            in: anchor
        )
    }
}

/// The More button: `ellipsis` in the gear's well — 26 × 26, radius 8, white
/// 0.08 (0.14 under the pointer), the glyph at 14 medium in secondary — with
/// the update badge the gear carried, so an update waiting still shows on
/// every page.
///
/// To VoiceOver it is a menu button called "More", as a Mac's ⋯ is: the
/// representation is a SwiftUI `Menu` with the same rows from the same
/// function, so pressing it from VoiceOver opens the same choices.
struct HeaderMoreButton: View {
    let hasUpdate: Bool
    let items: (_ panelIsKey: Bool) -> [HeaderMenuItem]
    let perform: (HeaderMenuItem.Kind) -> Void
    @StateObject private var holder = BuiltOnce { HeaderMoreMenuPresenter() }

    var body: some View {
        let label = localized("More")
        HeaderToolButton(symbol: "ellipsis", label: label, badge: hasUpdate) {
            holder.value.present(items: items, perform: perform)
        }
        .background(MenuAnchor { holder.value.anchor = $0 })
        .accessibilityRepresentation {
            // Translate's language pop-ups do the same (`TranslateMenus`).
            Menu {
                ForEach(Array(items(holder.value.anchor?.window?.isKeyWindow == true).enumerated()), id: \.offset) { _, item in
                    if item.kind == .separator {
                        Divider()
                    } else {
                        Button(item.title) { perform(item.kind) }
                            .disabled(!item.isEnabled)
                    }
                }
            } label: {
                // The well's own size, so the element an assistive client
                // finds is the control's frame and not a bare label's line.
                Text(label)
                    .frame(width: SurfaceHeaderLayout.toolSide, height: SurfaceHeaderLayout.toolSide)
            }
            // Borderless, not the automatic pop-up, which reads as a pop-up
            // button rather than a menu, and not the bordered button, whose
            // bezel pads the element past the well.
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: SurfaceHeaderLayout.toolSide, height: SurfaceHeaderLayout.toolSide)
            .accessibilityLabel(label)
            .accessibilityValue(hasUpdate ? localized("Update available") : "")
        }
    }
}
