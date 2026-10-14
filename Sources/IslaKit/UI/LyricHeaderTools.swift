import AppKit
import SwiftUI

// MARK: - Expand / Collapse (spec §6)

/// The header's Expand / Collapse button: 22 × 22, `rectangle.expand.vertical`
/// while the body is standard and `rectangle.compress.vertical` while it is
/// tall, secondary, with the same word as its tooltip and its accessibility
/// label.
///
/// A view of its own, taking a binding, because four tabs wear it — the lyric
/// column now, and Shelf, Clipboard and Translate in the releases that follow
/// (owner decisions 7 and 12). The host places it at `HeaderToolFrames.expand`,
/// `(bw − 39, 8)`, and decides what the binding writes (`NotchViewModel
/// .setExpanded`); this knows nothing of tabs or heights.
struct ExpandCollapseButton: View {
    @Binding var isExpanded: Bool

    /// The word, for the tooltip and the accessibility label.
    static func label(isExpanded: Bool) -> String {
        isExpanded ? localized("Collapse") : localized("Expand")
    }

    static func symbol(isExpanded: Bool) -> String {
        isExpanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical"
    }

    var body: some View {
        let label = Self.label(isExpanded: isExpanded)
        Button { isExpanded.toggle() } label: {
            Image(systemName: Self.symbol(isExpanded: isExpanded))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .frame(width: HeaderToolFrames.side, height: HeaderToolFrames.side)
                .contentShape(RoundedRectangle(cornerRadius: HeaderToolFrames.cornerRadius, style: .continuous))
        }
        .buttonStyle(PanelButtonStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}

extension HeaderToolFrames {
    /// A 22 pt icon button's corner (spec §2.3).
    static let cornerRadius: CGFloat = 7
}

// MARK: - A header icon

/// One of the lyric page's two other header tools, 22 × 22: a glyph at 12 pt,
/// secondary, and — for a switch like Show Translation — the selected fill
/// behind the filled glyph while it is on.
struct HeaderIconButton: View {
    let symbol: String
    let label: String
    var isOn = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isOn ? Color.white : Theme.secondary)
                .frame(width: HeaderToolFrames.side, height: HeaderToolFrames.side)
                .background(
                    RoundedRectangle(cornerRadius: HeaderToolFrames.cornerRadius, style: .continuous)
                        .fill(isOn ? Theme.selectedChip : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: HeaderToolFrames.cornerRadius, style: .continuous))
        }
        .buttonStyle(PanelButtonStyle())
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

// MARK: - More Lyrics Options (spec §5.2)

/// Builds the More menu and acts on it.
///
/// An `NSMenu`, as the Output menu is and for the same reasons: the board draws
/// plain menu rows with their symbols, one of them a header and one the
/// correction as a line that cannot be pressed, and a SwiftUI `Menu` cannot
/// say either. The panel is a non-activating `NSPanel`, which an NSMenu pops up
/// from like any window, and `MenuTracking` already holds the panel open for as
/// long as a menu is up.
///
/// Every effect is a closure the host hands in, and the context is read when
/// the menu opens, not when the button is drawn — the correction, the bound
/// file and the online switch are all things that move while the panel is up.
@MainActor
final class LyricsMoreMenuController: NSObject {
    struct Context {
        var localFileName: String?
        var hasBinding: Bool
        var onlineOn: Bool
        var offset: TimeInterval
        var canNudge: Bool
    }

    struct Actions {
        var nudge: (TimeInterval) -> Void = { _ in }
        var resetTiming: () -> Void = {}
        var editLyrics: () -> Void = {}
        var removeBinding: () -> Void = {}
        var importFile: () -> Void = {}
        var searchAgain: () -> Void = {}
        var openSettings: () -> Void = {}
    }

    /// The menu is as wide as its longest row needs and no narrower than the
    /// board's 244.
    static let menuWidth: CGFloat = 244

    private let context: () -> Context
    private let actions: Actions
    private var kinds: [ObjectIdentifier: LyricsMoreMenuItem.Kind] = [:]

    init(context: @escaping () -> Context, actions: Actions) {
        self.context = context
        self.actions = actions
    }

    static func symbol(for kind: LyricsMoreMenuItem.Kind) -> String? {
        switch kind {
        case .earlier: return "minus"
        case .later: return "plus"
        case .edit: return "pencil"
        case .removeBinding: return "minus.circle"
        case .importFile: return "doc.badge.plus"
        case .searchAgain: return "arrow.clockwise"
        case .header, .offset, .reset, .separator, .settings: return nil
        }
    }

    func makeMenu() -> NSMenu {
        let state = context()
        let menu = NSMenu(title: localized("More Lyrics Options"))
        menu.minimumWidth = Self.menuWidth
        menu.autoenablesItems = false
        kinds.removeAll()
        // The system's own appearance, as every menu in the app: nothing forced.
        let items = LyricsMoreMenuModel.items(
            localFileName: state.localFileName, hasBinding: state.hasBinding,
            onlineOn: state.onlineOn, offset: state.offset, canNudge: state.canNudge
        )
        for entry in items {
            switch entry.kind {
            case .separator:
                menu.addItem(.separator())
            case .header:
                menu.addItem(NSMenuItem.sectionHeader(title: entry.title))
            default:
                let item = NSMenuItem(title: entry.title, action: #selector(chosen(_:)), keyEquivalent: "")
                item.target = self
                item.isEnabled = entry.isEnabled
                if let symbol = Self.symbol(for: entry.kind) {
                    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                }
                kinds[ObjectIdentifier(item)] = entry.kind
                // A disabled line is a readout; leaving it with no action keeps
                // it from being picked up as something to press.
                if entry.kind == .offset { item.action = nil }
                menu.addItem(item)
            }
        }
        return menu
    }

    @objc private func chosen(_ item: NSMenuItem) {
        guard let kind = kinds[ObjectIdentifier(item)] else { return }
        perform(kind)
    }

    /// What a row does, apart from the menu, so a test can press each.
    func perform(_ kind: LyricsMoreMenuItem.Kind) {
        switch kind {
        case .earlier: actions.nudge(-LyricsMoreMenuModel.nudgeStep)
        case .later: actions.nudge(LyricsMoreMenuModel.nudgeStep)
        case .reset: actions.resetTiming()
        case .edit: actions.editLyrics()
        case .removeBinding: actions.removeBinding()
        case .importFile: actions.importFile()
        case .searchAgain: actions.searchAgain()
        case .settings: actions.openSettings()
        case .header, .offset, .separator: break
        }
    }
}

/// Pops a `LyricsMoreMenuController`'s menu up under the More button, its right
/// edge on the button's (`Lyrics-More-Menu`), the way the Output menu is popped
/// up under its own.
@MainActor
final class LyricsMoreMenuPresenter {
    weak var anchor: NSView?
    let controller: LyricsMoreMenuController

    init(controller: LyricsMoreMenuController) { self.controller = controller }

    func present() {
        guard let anchor else { return }
        let menu = controller.makeMenu()
        let width = max(menu.size.width, LyricsMoreMenuController.menuWidth)
        _ = menu.popUp(
            positioning: nil,
            // The same point rule as the Output menu: right edge to right edge,
            // a hair under the anchor.
            at: OutputMenuPresenter.popUpPoint(anchorSize: anchor.bounds.size, menuWidth: width),
            in: anchor
        )
    }
}

/// The empty view a menu is popped up from, laid in the button's background.
struct MenuAnchor: NSViewRepresentable {
    let attach: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = FlippedAnchorView()
        attach(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        attach(nsView)
    }
}

/// The More button: `ellipsis`, "More Lyrics Options", opening the one menu.
struct LyricsMoreButton: View {
    @State private var presenter: LyricsMoreMenuPresenter

    init(controller: LyricsMoreMenuController) {
        _presenter = State(initialValue: LyricsMoreMenuPresenter(controller: controller))
    }

    var body: some View {
        let label = localized("More Lyrics Options")
        Button { presenter.present() } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .frame(width: HeaderToolFrames.side, height: HeaderToolFrames.side)
                .contentShape(RoundedRectangle(cornerRadius: HeaderToolFrames.cornerRadius, style: .continuous))
        }
        .buttonStyle(PanelButtonStyle())
        .background(MenuAnchor { presenter.anchor = $0 })
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - The tools together

/// The lyric column's and the tall page's header tools, in the header's own
/// coordinates: Show Translation (hidden until the translation release wires
/// it), More, and Expand / Collapse (spec §5.2).
///
/// Each tool is placed by its own offset instead of one full-width container, so
/// the header's click-to-close — which is the rest of the strip — keeps every
/// point that is not a button.
struct LyricHeaderTools: ViewModifier {
    /// Whether the tools are on screen: the lyric column and the tall page, on
    /// the Music tab. A flag rather than a conditional application of the
    /// modifier, so the header under it keeps its identity — and with it the
    /// title's cross-fade — as the page opens and closes.
    let isShown: Bool
    let bodyWidth: CGFloat
    let showsTranslation: Bool
    let translationShown: Bool
    let toggleTranslation: () -> Void
    let moreController: LyricsMoreMenuController
    @Binding var isExpanded: Bool

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topLeading) {
                if isShown, showsTranslation {
                    HeaderIconButton(
                        symbol: translationShown ? "character.bubble.fill" : "character.bubble",
                        label: translationShown ? localized("Hide Translation") : localized("Show Translation"),
                        isOn: translationShown, action: toggleTranslation
                    )
                    .offset(x: HeaderToolFrames.showTranslation(bodyWidth: bodyWidth).minX, y: HeaderToolFrames.top)
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .topLeading) {
                if isShown {
                    LyricsMoreButton(controller: moreController)
                        .offset(x: HeaderToolFrames.more(bodyWidth: bodyWidth).minX, y: HeaderToolFrames.top)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .topLeading) {
                if isShown {
                    ExpandCollapseButton(isExpanded: $isExpanded)
                        .offset(x: HeaderToolFrames.expand(bodyWidth: bodyWidth).minX, y: HeaderToolFrames.top)
                        .transition(.opacity)
                }
            }
    }
}
