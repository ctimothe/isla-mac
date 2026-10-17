import AppKit
import Carbon.HIToolbox

/// One row of the island's right-click menu (spec §19.9), apart from AppKit so
/// the order, the words, the keys shown and what is enabled are things a test
/// reads.
struct IslandMenuItem: Equatable {
    enum Kind: Equatable {
        case clipboard, translateClipboard, shelf, lyrics, separator, settings, quit
    }

    var kind: Kind
    var title: String
    /// The key the row shows: the global hot key's binding as `HotKeyCenter`
    /// holds it now. Shown, never claimed — the hot key does the work, so a
    /// key moved in Settings moves here, and a cleared one shows nothing.
    var shown: HotKeyBinding? = nil
    var isEnabled = true
}

/// The island's right-click menu (spec §19.9, board `R2-Menu`): an `NSMenu` at
/// the click, in the system's appearance — Clipboard, Translate Clipboard,
/// Shelf, Lyrics, then Settings… and Quit Isla. With Tools it is how
/// everything is reached when nothing is live, which is why it opens from the
/// island in every state, and from an open surface's header row.
///
/// About stays in Settings › About: the menu is for going somewhere, and
/// About is a place inside Settings already.
enum IslandMenu {
    /// The rows, top to bottom. Lyrics is enabled while a song plays: with
    /// nothing playing, the stage it opens is the empty player.
    static func items(bindings: [HotKeyAction: HotKeyBinding], songPlaying: Bool) -> [IslandMenuItem] {
        [
            IslandMenuItem(kind: .clipboard, title: localized("Clipboard"), shown: bindings[.showClipboard]),
            IslandMenuItem(
                kind: .translateClipboard, title: localized("Translate Clipboard"),
                shown: bindings[.translateClipboard]
            ),
            IslandMenuItem(kind: .shelf, title: localized("Shelf")),
            IslandMenuItem(kind: .lyrics, title: localized("Lyrics"), shown: bindings[.showLyrics], isEnabled: songPlaying),
            IslandMenuItem(kind: .separator, title: ""),
            IslandMenuItem(kind: .settings, title: localized("Settings…")),
            IslandMenuItem(kind: .quit, title: localized("Quit Isla")),
        ]
    }

    /// What a secondary click — a right-click, or a click with Control held —
    /// does at `point`, in the panel's content view (which counts from the
    /// bottom).
    enum SecondaryClick: Equatable {
        /// The menu, at the click.
        case menu
        /// The locked island's refusal: the shake a click gets (§19.9: "Over
        /// the lock it does not open; the right-click shakes as a click does").
        case shake
        /// Not the island's: a clipboard row's own menu, a tile's Open With,
        /// or — outside every rect — nothing, since the window passes it on.
        case passThrough
    }

    /// The menu opens anywhere on the closed island or its bubble — resting,
    /// a compact activity, an alert — and on an open surface's header row, the
    /// strip the notch sits in. Anywhere else on an open surface the click
    /// belongs to what is under it. Over the lock the island answers with the
    /// shake and never with the menu, whose Settings… and Quit would act over
    /// the password field.
    static func secondaryClick(
        at point: CGPoint, active: CGRect, bubble: CGRect,
        isOpen: Bool, isLocked: Bool, headerHeight: CGFloat
    ) -> SecondaryClick {
        let onIsland = active.contains(point) || bubble.contains(point)
        if isLocked { return onIsland ? .shake : .passThrough }
        guard isOpen else { return onIsland ? .menu : .passThrough }
        // `activeRect` reaches 2 pt past the window's top so a click parked on
        // the edge lands (`NotchRootView.reachingTopEdge`); the row is measured
        // down from that same top, which only gives it those 2 pt more.
        let header = CGRect(
            x: active.minX, y: active.maxY - headerHeight, width: active.width, height: headerHeight
        )
        return header.contains(point) ? .menu : .passThrough
    }

    /// What an `NSMenuItem` shows for a binding: the key as `keyEquivalent`
    /// (lower case, or AppKit reads Shift into it) and the modifiers as its
    /// mask. Nil for a key a menu cannot show.
    static func keyEquivalent(for binding: HotKeyBinding) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
        let key: String
        let name = HotKeyBinding.keyName(binding.keyCode)
        if let special = specialKeys[Int(binding.keyCode)] {
            key = String(Character(UnicodeScalar(special)!))
        } else if name.count == 1 {
            key = name.lowercased()
        } else {
            return nil
        }
        var modifiers: NSEvent.ModifierFlags = []
        if binding.modifiers & UInt32(controlKey) != 0 { modifiers.insert(.control) }
        if binding.modifiers & UInt32(optionKey) != 0 { modifiers.insert(.option) }
        if binding.modifiers & UInt32(shiftKey) != 0 { modifiers.insert(.shift) }
        if binding.modifiers & UInt32(cmdKey) != 0 { modifiers.insert(.command) }
        return (key, modifiers)
    }

    /// Keys whose glyph is not the character a menu item takes.
    private static let specialKeys: [Int: Int] = {
        var table: [Int: Int] = [
            kVK_Return: 0x0D, kVK_Tab: 0x09, kVK_Delete: 0x08, kVK_Escape: 0x1B, kVK_Space: 0x20,
            kVK_ForwardDelete: NSDeleteFunctionKey, kVK_LeftArrow: NSLeftArrowFunctionKey,
            kVK_RightArrow: NSRightArrowFunctionKey, kVK_UpArrow: NSUpArrowFunctionKey,
            kVK_DownArrow: NSDownArrowFunctionKey, kVK_Home: NSHomeFunctionKey, kVK_End: NSEndFunctionKey,
            kVK_PageUp: NSPageUpFunctionKey, kVK_PageDown: NSPageDownFunctionKey,
        ]
        let functionKeys = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
        ]
        for (index, code) in functionKeys.enumerated() { table[code] = NSF1FunctionKey + index }
        return table
    }()

    /// The menu AppKit draws. Each row runs `perform` with its kind; the menu
    /// keeps the actions alive for as long as it is.
    static func menu(_ items: [IslandMenuItem], perform: @escaping (IslandMenuItem.Kind) -> Void) -> NSMenu {
        let menu = ActionMenu(title: "Isla")
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
            if let binding = item.shown, let shown = keyEquivalent(for: binding) {
                row.keyEquivalent = shown.key
                row.keyEquivalentModifierMask = shown.modifiers
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
