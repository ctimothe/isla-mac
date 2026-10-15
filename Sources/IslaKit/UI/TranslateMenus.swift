import AppKit
import SwiftUI

/// Builds a language pop-up's `NSMenu` from `TranslateMenuModel` and acts on it
/// (redesign 2026-10-15, spec §11).
///
/// An `NSMenu` popped from an anchor, as the Output and More menus are
/// (`OutputMenu.swift`), and not the SwiftUI `Menu` the two headings used to be:
/// a pop-up button's menu opens with the *chosen* row laid over the button
/// (HIG, Pop-up buttons), which a SwiftUI `Menu` — a pull-down — cannot do, and
/// it carries the section headers ("Recent", "On this Mac") as headers. The
/// panel is a non-activating `NSPanel`, which an `NSMenu` pops up from like any
/// window; `MenuTracking` holds it open while the menu is up, exactly as it did
/// for the SwiftUI menus.
///
/// Every effect is a closure with a default that does the real thing and a seam
/// a test replaces, so pressing a row in a test opens no System Settings pane.
@MainActor
final class TranslateMenuController: NSObject {
    private let translator: Translator
    let side: TranslateMenuModel.Side
    /// How a choice is applied: the pane wraps it in the content animation, the
    /// way every language change settles (`TranslatePane.choose`).
    private let apply: (() -> Void) -> Void
    private let openLanguages: () -> Void
    private var kinds: [ObjectIdentifier: TranslateMenuEntry.Kind] = [:]
    weak var anchor: NSView?

    init(
        translator: Translator, side: TranslateMenuModel.Side,
        apply: @escaping (() -> Void) -> Void = { $0() },
        openLanguages: (() -> Void)? = nil
    ) {
        self.translator = translator
        self.side = side
        self.apply = apply
        self.openLanguages = openLanguages ?? { Translator.openTranslationLanguages() }
    }

    /// The rows, read from the translator now: what is ticked, the three recent
    /// targets and which languages are online-only all move while the panel is up.
    func entries() -> [TranslateMenuEntry] {
        TranslateMenuModel.entries(
            side: side,
            chosen: side == .source ? translator.source : translator.target,
            recents: translator.recentTargets,
            isOnlineOnly: { [translator] in translator.isOnlineOnly($0) }
        )
    }

    /// The menu, and the row the pop-up lays over its button: the first ticked one.
    func makeMenu() -> (menu: NSMenu, selected: NSMenuItem?) {
        let menu = NSMenu(title: side == .source ? localized("Translate From") : localized("Translate To"))
        menu.autoenablesItems = false
        kinds.removeAll()
        var selected: NSMenuItem?
        for entry in entries() {
            switch entry.kind {
            case .separator:
                menu.addItem(.separator())
            case .header:
                menu.addItem(NSMenuItem.sectionHeader(title: entry.title))
            case .detect, .language, .translationLanguages:
                let item = NSMenuItem(title: entry.title, action: #selector(chosen(_:)), keyEquivalent: "")
                item.target = self
                item.state = entry.isChecked ? .on : .off
                kinds[ObjectIdentifier(item)] = entry.kind
                if entry.isChecked, selected == nil { selected = item }
                menu.addItem(item)
            }
        }
        return (menu, selected)
    }

    /// Opens the menu with the chosen row over the button: the anchor's top-left
    /// is the button's, and the row's top-left goes there.
    func present() {
        guard let anchor else { return }
        let (menu, selected) = makeMenu()
        _ = menu.popUp(positioning: selected, at: NSPoint(x: 0, y: 0), in: anchor)
    }

    @objc private func chosen(_ item: NSMenuItem) {
        guard let kind = kinds[ObjectIdentifier(item)] else { return }
        perform(kind)
    }

    /// What a row does, apart from the menu, so a test can press each.
    func perform(_ kind: TranslateMenuEntry.Kind) {
        switch kind {
        case .header, .separator: break
        case .detect:
            apply { translator.choose(source: nil) }
        case .language(let code):
            guard let language = TranslationLanguage.withCode(code) else { return }
            apply {
                switch side {
                case .source: translator.choose(source: language)
                case .target: translator.choose(target: language)
                }
            }
        case .translationLanguages:
            openLanguages()
        }
    }
}

/// A language pop-up: 11 pt label, the up-down chevron, a 0.12 plate, radius 6
/// (the board's `popup()`), laid over an anchor the menu pops from.
///
/// To an assistive client it is what it was: a menu button named "Translate From"
/// or "Translate To", whose value is the language and whose rows are the same
/// rows. The drawn control opens an `NSMenu`; the representation under it is a
/// SwiftUI `Menu` that VoiceOver walks natively, so the swap from `Menu` to a
/// popped `NSMenu` costs nobody the keyboard.
struct TranslatePopUp: View {
    let translator: Translator
    let title: String
    let label: String
    @StateObject private var holder: BuiltOnce<TranslateMenuController>

    init(
        translator: Translator, side: TranslateMenuModel.Side, title: String, label: String,
        apply: @escaping (() -> Void) -> Void
    ) {
        self.translator = translator
        self.title = title
        self.label = label
        _holder = StateObject(wrappedValue: BuiltOnce {
            TranslateMenuController(translator: translator, side: side, apply: apply)
        })
    }

    private var controller: TranslateMenuController { holder.value }

    var body: some View {
        Button { controller.present() } label: {
            HStack(spacing: 4) {
                Text(title)
                    .islandFont(.body, weight: .regular)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                // A glyph fitted to the plate, not type.
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.leading, 9)
            .padding(.trailing, 6)
            .frame(maxWidth: .infinity)
            .frame(height: TranslateLayout.popUpHeight)
            .background(
                RoundedRectangle(cornerRadius: ToolbarPushButtonStyle.radius, style: .continuous)
                    .fill(Theme.popUpFill)
                    // The plate's lit top edge, as the push buttons draw it.
                    .overlay(alignment: .top) {
                        Rectangle().fill(Color.white.opacity(0.12)).frame(height: 0.5)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: ToolbarPushButtonStyle.radius, style: .continuous))
            )
            .contentShape(RoundedRectangle(cornerRadius: ToolbarPushButtonStyle.radius, style: .continuous))
        }
        .buttonStyle(PanelButtonStyle())
        .background(MenuAnchor { controller.anchor = $0 })
        .help(label)
        .accessibilityRepresentation {
            Menu {
                ForEach(Array(controller.entries().enumerated()), id: \.offset) { _, entry in
                    switch entry.kind {
                    case .separator:
                        Divider()
                    case .header:
                        Text(entry.title)
                    case .detect, .language, .translationLanguages:
                        Toggle(entry.title, isOn: Binding(
                            get: { entry.isChecked },
                            set: { _ in controller.perform(entry.kind) }
                        ))
                    }
                }
            } label: {
                // The pop-up's own height, so the element an assistive client
                // finds is the control's frame and not the bare label's 16 pt
                // line (F-014): a `Menu` is as tall as its label.
                Text(title)
                    .frame(maxWidth: .infinity, minHeight: TranslateLayout.popUpHeight)
            }
            // The button style, not the automatic pop-up: the automatic one is
            // sized by AppKit's 16 pt control, the button one by its label.
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .accessibilityLabel(label)
            .accessibilityValue(title)
        }
    }
}
