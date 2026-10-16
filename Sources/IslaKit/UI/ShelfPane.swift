import AppKit
import SwiftUI

/// The Shelf as Finder's icon view (spec §8): a grid of tiles, Finder's
/// selection, labelled actions at the foot, and two wells to drag files onto.
///
/// Every frame comes from `ShelfLayout` in the board's body coordinates and is
/// converted once, by `PlayerLayout.inPane`, so what a test holds is what is
/// drawn. This replaces a horizontal strip of 86 × 92 card plates; the store
/// under it (selection, the cap of sixty, offline files, duplicates, drag-out
/// and ⌘-moves, Quick Look and AirDrop) is untouched.
struct ShelfPane: View {
    @ObservedObject var shelf: ShelfStore
    var isTargeted: Bool
    /// The well a drag in flight is over. Only read while `isTargeted`.
    var dropTarget: ShelfDropTarget = .keep
    /// The header's height on this Mac, for the body-to-pane conversion.
    var headerHeight: CGFloat = PlayerLayout.referenceHeaderHeight

    /// Where the pointer is in the grid's viewport, and how far the grid is
    /// scrolled: together they say which tile it is over, *decided* by
    /// `ShelfLayout.tileIndex` on every redraw rather than reported by each
    /// tile's own `onHover`.
    ///
    /// Per-tile hover breaks on the shelf's most repetitive gesture: removing
    /// tiles one after another. Hover events are made of mouse movement, and
    /// when a removed tile's neighbour slides under a pointer that has not
    /// moved, there are no events — the neighbour never learns it is hovered,
    /// its ✕ never appears, and the click meant to remove it selects it
    /// instead, until a stray wiggle of the mouse fixes everything. The pane
    /// keeps the pointer and the scroll offset, and the answer follows from the
    /// layout whenever the shelf, the pointer or the scroll moves.
    @State private var hoverPoint: CGPoint?
    @State private var scrollOffset: CGFloat = 0
    @StateObject private var clear = ShelfClearConfirmation()
    @StateObject private var more = ShelfMoreMenuPresenter()

    var body: some View {
        GeometryReader { geo in
            let size = ShelfLayout.bodySize(paneSize: geo.size, headerHeight: headerHeight)
            ZStack(alignment: .topLeading) {
                if isTargeted {
                    dropWells(size)
                        .transition(.opacity)
                } else if shelf.items.isEmpty {
                    emptyState
                        .transition(.opacity)
                } else {
                    grid(size)
                    bar(size)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            // Only fades: nothing grows or slides between the states, so Reduce
            // Motion has nothing to take away.
            .animation(Theme.contentAnimation, value: isTargeted)
            .animation(Theme.contentAnimation, value: shelf.items.isEmpty)
        }
        // A question left standing would be waiting inside the next visit to
        // the Shelf, one click from emptying it.
        .onDisappear { clear.cancel() }
        .onChange(of: shelf.items.isEmpty) { _, empty in if empty { clear.cancel() } }
    }

    /// A frame in the board's body coordinates, in this pane's.
    private func pane(_ rect: CGRect) -> CGRect {
        PlayerLayout.inPane(rect, headerHeight: headerHeight)
    }

    // MARK: - Empty (§8.4)

    /// What the Shelf is for, where files come from and how many it keeps. The
    /// glyph is drawing; VoiceOver read it by its symbol's name once, "Download
    /// Multiple" (F-036), and reads the words now.
    private var emptyState: some View {
        VStack(spacing: 6) {
            // 26 pt is the board's (spec §8.4) and no role: the roles stop at
            // 21 and jump to 28, and the empty player's note and the Clipboard's
            // glyph are each their own size for the same reason.
            Image(systemName: "tray")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(Theme.tertiary)
                .accessibilityHidden(true)
                .padding(.bottom, 6)
            Text(localized("Drop files here to keep them"))
                .islandFont(.subhead, weight: .semibold)
                .foregroundStyle(.white)
            Text(localized("From Finder, Mail, Photos or a browser. Holds %d.", ShelfStore.limit))
                .islandFont(.body, weight: .regular)
                .foregroundStyle(Theme.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Dragging in (§8.3)

    /// Two wells that name what letting go does. Drawing, not controls: the
    /// drop itself is taken by the window's own drag handling
    /// (`NotchRootView`), so nothing here may catch the pointer on its way.
    private func dropWells(_ size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach([ShelfDropTarget.keep, .airDrop], id: \.self) { target in
                let frame = pane(ShelfDropTarget.well(target, bodySize: size))
                ShelfDropWell(target: target, isLit: dropTarget == target)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
            }
        }
    }

    // MARK: - The grid (§8.1)

    private func grid(_ size: CGSize) -> some View {
        let columns = ShelfLayout.columns(bodyWidth: size.width)
        let viewport = pane(ShelfLayout.viewport(bodySize: size))
        let items = shelf.items
        let hovered = hoverPoint.flatMap {
            ShelfLayout.tileIndex(
                at: CGPoint(x: $0.x, y: $0.y + scrollOffset), count: items.count, columns: columns
            )
        }
        return ScrollView(.vertical, showsIndicators: false) {
            ZStack(alignment: .topLeading) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    let frame = ShelfLayout.tileFrame(index: index, columns: columns)
                    ShelfTile(
                        item: item, shelf: shelf,
                        isHovered: hovered == index,
                        isAlreadyKept: shelf.alreadyKept.contains(item.id)
                    )
                    .offset(x: frame.minX, y: frame.minY)
                }
            }
            .frame(
                width: viewport.width,
                height: ShelfLayout.contentHeight(count: items.count, columns: columns),
                alignment: .topLeading
            )
        }
        // The row the viewport cuts fades under the bar instead of ending on a
        // hard edge (H-017's lesson), 26 pt of it (spec §8.1).
        .scrollEdgeFade(.vertical, length: ShelfLayout.overflowFade)
        .onScrollGeometryChange(for: CGFloat.self) { $0.visibleRect.minY } action: { _, offset in
            scrollOffset = offset
        }
        .frame(width: viewport.width, height: viewport.height)
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let point): hoverPoint = point
            case .ended: hoverPoint = nil
            }
        }
        .offset(x: viewport.minX, y: viewport.minY)
    }

    // MARK: - The bar (§8.2, §8.4)

    private func bar(_ size: CGSize) -> some View {
        let model = ShelfBar.make(
            itemCount: shelf.items.count, selectionCount: shelf.selection.count, notice: shelf.notice,
            isConfirmingClear: clear.isAsking, bodyWidth: size.width
        )
        let frame = pane(ShelfLayout.bar(bodySize: size))
        return Group {
            // Folded by the spec's rule below 540, and by measure above it: the
            // five verbs in Russian are wider than the 488 pt a 560 body has,
            // so the full row is offered first and the folded one is what is
            // left when it does not fit.
            if case .verbs(_, let overflow) = model.trailing, overflow.isEmpty {
                ViewThatFits(in: .horizontal) {
                    barRow(model)
                    barRow(model.folded)
                }
            } else {
                barRow(model)
            }
        }
        .frame(width: frame.width, height: frame.height, alignment: .leading)
        .offset(x: frame.minX, y: frame.minY)
        .animation(Theme.contentAnimation, value: shelf.notice)
        .animation(Theme.contentAnimation, value: shelf.selection.isEmpty)
        // The line is drawn where the pane is, so it is heard only when the
        // Shelf is on screen: a screenshot saved with the panel shut has nobody
        // to tell, and VoiceOver should not speak up over another tab.
        .onChange(of: shelf.notice) { _, notice in
            if let notice { Announcer.shared.announce(notice.text) }
        }
    }

    private func barRow(_ model: ShelfBar) -> some View {
        HStack(spacing: 6) {
            leading(model.leading)
            Spacer(minLength: 8)
            trailing(model.trailing)
        }
        .frame(height: ShelfLayout.barHeight)
    }

    @ViewBuilder
    private func leading(_ leading: ShelfBar.Leading) -> some View {
        switch leading {
        case .selection(let count):
            HStack(spacing: 6) {
                Text(localized("%d selected", count))
                    .islandFont(.body, weight: .medium)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .fixedSize()
                DeselectAllButton { shelf.clearSelection() }
            }
        case .notice(let notice):
            // Two lines at most: the eviction sentence ends on what matters
            // most — the files themselves are untouched — and at the narrowest
            // panel, in Russian, one line cut it off.
            Text(notice.text)
                .islandFont(.body, weight: .regular)
                .foregroundStyle(Theme.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
        case .hint:
            Text(localized("Drag an item out to use it anywhere."))
                .islandFont(.body, weight: .regular)
                .foregroundStyle(Theme.tertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        case .clearQuestion(let count):
            Text(localized("Remove all %d items? Files are untouched.", count))
                .islandFont(.body, weight: .regular)
                .foregroundStyle(Theme.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func trailing(_ trailing: ShelfBar.Trailing) -> some View {
        switch trailing {
        case .verbs(let inline, let overflow):
            let cards = shelf.selectedCards
            HStack(spacing: 6) {
                ForEach(inline, id: \.self) { verb in
                    Button(verb.title) { perform(verb, on: cards) }
                        .buttonStyle(ToolbarPushButtonStyle())
                        // The verbs act on what a drag would carry — in shelf
                        // order, without a tile whose disk is away — and go
                        // quiet when that leaves nothing. Remove acts on the
                        // selection itself, files or not.
                        .disabled(verb != .remove && cards.isEmpty)
                }
                if !overflow.isEmpty {
                    Button { more.present(verbs: overflow) { perform($0, on: cards) } } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(ToolbarPushButtonStyle(width: ToolbarPushButtonStyle.height))
                    .background(MenuAnchor { more.anchor = $0 })
                    .help(localized("More"))
                    .accessibilityLabel(localized("More"))
                    .disabled(cards.isEmpty)
                }
            }
            .fixedSize()
        case .clear:
            Button(localized("Clear")) {
                clear.ask(count: shelf.items.count)
            }
            .buttonStyle(ToolbarPushButtonStyle())
            .accessibilityHint(localized("Asks for confirmation before acting."))
        case .confirmClear:
            HStack(spacing: 6) {
                Button(localized("Cancel")) { clear.cancel() }
                    .buttonStyle(ToolbarPushButtonStyle())
                Button {
                    clear.confirm { shelf.clear() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "trash").font(.system(size: 11, weight: .regular))
                        Text(localized("Remove All"))
                    }
                }
                .buttonStyle(ToolbarPushButtonStyle(kind: .danger))
            }
            .fixedSize()
        case .nothing:
            EmptyView()
        }
    }

    private func perform(_ verb: ShelfVerb, on cards: [ShelfItem]) {
        switch verb {
        case .quickLook: ShelfSharing.quickLook(cards.map(\.url))
        case .airDrop: ShelfSharing.airDrop(cards.map(\.url), refusingOn: shelf)
        // The pasteboard path writes one file with its image data, and several
        // at once is a change of its own.
        case .copy: if let first = cards.first { shelf.copy(first) }
        case .showInFinder: shelf.reveal(cards)
        case .remove: shelf.removeSelected()
        }
    }
}

// MARK: - Clear asks once (§8.4)

/// "Remove all %d items? Files are untouched." — the question, in place, with
/// Cancel and Remove All. It replaces the arm-and-press-again "Clear Everything"
/// the bar had: a sentence with two named answers says what will happen to a
/// person who does not know the first press arms, and to one who cannot see the
/// word turn red.
///
/// It keeps what the arming was right about. It joins `ArmedConfirmations`, so
/// Escape answers it ("no") before Escape folds the panel — the first Escape
/// cancels, and only the second, with nothing left asked, folds — and it is said
/// to VoiceOver, which cannot see the bar change. It no longer lapses by itself:
/// the arming did, because pressing the same button twice is an accident
/// waiting; Remove All is a different button, pressed on purpose after a
/// sentence.
@MainActor
final class ShelfClearConfirmation: ObservableObject {
    @Published private(set) var isAsking = false
    private var token: UUID?

    func ask(count: Int) {
        guard !isAsking, count > 0 else { return }
        isAsking = true
        token = ArmedConfirmations.shared.register { [weak self] in self?.cancel() }
        Announcer.shared.announce(localized("Remove all %d items? Files are untouched.", count))
    }

    func cancel() {
        if let token { ArmedConfirmations.shared.withdraw(token) }
        token = nil
        isAsking = false
    }

    /// Answers yes: puts the question away first, then acts.
    func confirm(_ action: () -> Void) {
        guard isAsking else { return }
        cancel()
        action()
    }
}

// MARK: - A tile (§8.1, §8.2)

private struct ShelfTile: View {
    let item: ShelfItem
    @ObservedObject var shelf: ShelfStore
    /// Handed down from the pane, which is the one place that can know it
    /// correctly when tiles move under a stationary pointer.
    let isHovered: Bool
    let isAlreadyKept: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The mouse is down on the tile, or a drag that started on it is still in
    /// flight. Reported by the drag overlay, which owns the mouse.
    @State private var isPressed = false

    private var isSelected: Bool { shelf.isSelected(item) }

    private var well: ShelfWell? {
        ShelfWell.state(isSelected: isSelected, isHovered: isHovered, isAlreadyKept: isAlreadyKept)
    }

    /// The picture's box: a thumbnail at its own shape, long side 52, centred in
    /// the 52 pt square; a type's icon fills the square.
    private var iconSize: CGSize {
        item.isPreview ? ShelfLayout.fittedSize(of: item.icon.size) : ShelfLayout.icon.size
    }

    private var iconFrame: CGRect {
        let box = ShelfLayout.icon
        let size = iconSize
        return CGRect(
            x: box.minX + (box.width - size.width) / 2, y: box.minY + (box.height - size.height) / 2,
            width: size.width, height: size.height
        )
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            visual
                // The press answers on the way down (F-038). Only what is drawn
                // dips: the drag overlay below sits outside the scale, so the
                // region that owns the mouse stays exactly where the press
                // began. Reduce Motion asks for no change of size, so the tile
                // dims instead.
                .scaleEffect(isPressed && !reduceMotion ? Theme.pressScale : 1)
                .opacity(isPressed && reduceMotion ? Theme.pressDimOpacity : 1)
                .animation(Theme.contentAnimation, value: isPressed)
            // Owns clicks and drags: a group drag needs one dragging item per
            // file, which SwiftUI's onDrag cannot express. It must stay *below*
            // the ⓧ, otherwise it swallows every click aimed at it.
            ShelfDragSource(
                items: { shelf.dragCards(startingAt: item).map { ($0.url, $0.icon) } },
                thumbnail: iconFrame,
                onClick: { modifiers in shelf.select(item, modifiers: modifiers) },
                onDoubleClick: { shelf.open(item) },
                onPress: { pressed in isPressed = pressed },
                // A ⌘-drag moved the file, or the Trash took it: the tile
                // follows it, or leaves with it (F-020).
                onMoved: { urls in shelf.followMove(urls) },
                toolTip: item.name
            )
            .frame(width: ShelfLayout.tile.width, height: ShelfLayout.tile.height)
            if isHovered {
                removeBadge
            }
        }
        .frame(width: ShelfLayout.tile.width, height: ShelfLayout.tile.height, alignment: .topLeading)
        .contentShape(Rectangle())
        // Grouped as Finder groups a file's menu: looking at it, opening it,
        // sending it on, where it lives, and the destructive verb last and
        // apart (M-14). The header says which file this is before anything is
        // done to it (M-23).
        .contextMenu {
            CardMenuHeader(item: item)
            Divider()
            Button("Quick Look") { ShelfSharing.quickLook(shelf.dragURLs(startingAt: item)) }
                .keyboardShortcut("y", modifiers: .command)
            Button("Open") { shelf.open(item) }
            OpenWithMenu(item: item)
            Divider()
            Button("AirDrop") { ShelfSharing.airDrop(shelf.dragURLs(startingAt: item), refusingOn: shelf) }
            Button("Copy") { shelf.copy(item) }
                .keyboardShortcut("c", modifiers: .command)
            Divider()
            Button("Show in Finder") { shelf.reveal(item) }
                .keyboardShortcut("r", modifiers: .command)
            Divider()
            Button("Remove from Shelf", role: .destructive) { shelf.remove(item) }
                .keyboardShortcut(.delete, modifiers: [])
        }
        // One element per tile, for VoiceOver and every other assistive
        // client. Without it a tile was not an element at all: its name and its
        // age floated loose in the pane and interleaved across tiles ("Just
        // now" read beside the wrong file), and select, open and drag lived in
        // the AppKit overlay, which has no accessibility, so nothing on the
        // Shelf could be used (F-006). `.ignore` swallows that overlay and the
        // hover ⓧ too; what they do is offered here instead.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.name)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        // VO-Space opens the file, as a double-click and Finder's Return do.
        .accessibilityAction { shelf.open(item) }
        // The context menu's verbs, in the Actions rotor. Written bottom-up:
        // SwiftUI vends named actions outermost first, so the last declared is
        // the first offered, and the rotor should read Select, Quick Look,
        // AirDrop, Copy, Show in Finder, then the destructive Remove last, as
        // the menu does. Select is the ⌘-click toggle, because a VoiceOver user
        // picks tiles one at a time and a plain click's "this one instead"
        // would drop the rest.
        .accessibilityAction(named: Text("Remove from Shelf")) { shelf.remove(item) }
        .accessibilityAction(named: Text("Show in Finder")) { shelf.reveal(item) }
        .accessibilityAction(named: Text("Copy")) { shelf.copy(item) }
        .accessibilityAction(named: Text("AirDrop")) { ShelfSharing.airDrop(shelf.dragURLs(startingAt: item), refusingOn: shelf) }
        .accessibilityAction(named: Text("Quick Look")) { ShelfSharing.quickLook(shelf.dragURLs(startingAt: item)) }
        // Translated before it reaches `Text`: a ternary of two literals is a
        // `String`, which `Text` shows verbatim.
        .accessibilityAction(named: Text(isSelected ? localized("Deselect") : localized("Select"))) {
            shelf.select(item, modifiers: .command)
        }
        .animation(Theme.contentAnimation, value: well)
    }

    /// The well, the picture and the name — everything a tile draws.
    private var visual: some View {
        ZStack(alignment: .topLeading) {
            if let well {
                wellView(well)
                    .frame(width: ShelfLayout.well.width, height: ShelfLayout.well.height)
                    .offset(x: ShelfLayout.well.minX, y: ShelfLayout.well.minY)
                    .transition(.opacity)
            }
            picture
                .frame(width: iconFrame.width, height: iconFrame.height)
                .offset(x: iconFrame.minX, y: iconFrame.minY)
            nameBlock
                .frame(width: ShelfLayout.tile.width + 2 * ShelfLayout.nameBleed, alignment: .top)
                .offset(x: -ShelfLayout.nameBleed, y: ShelfLayout.nameTop)
        }
    }

    @ViewBuilder
    private func wellView(_ well: ShelfWell) -> some View {
        let shape = RoundedRectangle(cornerRadius: ShelfLayout.wellRadius, style: .continuous)
        switch well {
        case .hover:
            shape.fill(Theme.shelfHoverWell)
        case .selected:
            shape.fill(Theme.shelfSelectedWell)
        case .alreadyKept:
            shape.fill(Theme.shelfDropWellLit)
                .overlay(shape.strokeBorder(Theme.accent, lineWidth: Theme.shelfDropRingWidth))
        }
    }

    /// Finder's picture: a thumbnail wears a white 1.5 pt border and a soft
    /// shadow, hugging the picture itself; a file's own icon is drawn bare. A
    /// disk that is not plugged in takes the colour and most of the strength
    /// out of either (spec §8.4): the tile is still the tile, only out of reach.
    private var picture: some View {
        Image(nsImage: item.icon)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .overlay {
                if item.isPreview {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .strokeBorder(Color.white, lineWidth: 1.5)
                }
            }
            .shadow(color: item.isPreview ? Color.black.opacity(0.5) : .clear, radius: 3, x: 0, y: 2)
            .saturation(item.isOffline ? 0 : 1)
            .opacity(item.isOffline ? Theme.offlineThumbnailOpacity : 1)
            .accessibilityHidden(true)
    }

    /// The name, then how long ago. A capture's name already carries its date,
    /// but "Screenshot 2026-09-21 at 15.43.23" has to be read and worked out;
    /// "5 min. ago" is known at a glance, and it is what tells two captures of
    /// the same session apart.
    ///
    /// Two lines at most, the second cut in the middle so the extension
    /// survives (`ShelfTileName`); picked, each line is highlighted on its own
    /// in the accent, as Finder highlights a selected name. The age follows the
    /// name however many lines it took.
    private var nameBlock: some View {
        VStack(spacing: 0) {
            ForEach(Array(ShelfTileName.drawnLines(item.name, selected: isSelected).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .islandFont(.body, weight: isSelected ? .medium : .regular)
                    .foregroundStyle(item.isOffline ? Theme.tertiary : Color.white)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, isSelected ? 3 : 0)
                    .frame(height: ShelfLayout.nameLineHeight)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.accent)
                        }
                    }
            }
            ageLine
                .padding(.top, 2)
        }
    }

    @ViewBuilder
    private var ageLine: some View {
        if item.isOffline {
            // In place of the age, which is the less useful line once the file
            // cannot be opened: what a person needs to know is why, and what
            // brings it back.
            Text(localized("Disk not connected"))
                .islandFont(.caption, weight: .regular)
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
                .frame(height: ShelfLayout.ageLineHeight)
        } else if let date = item.date {
            // Re-read twice a minute, so "Just now" does not linger into the
            // afternoon on a shelf left open.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(ShelfItem.age(of: date, now: context.date))
                    .islandFont(.caption, weight: .regular)
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
            }
            .frame(height: ShelfLayout.ageLineHeight)
            .help(date.formatted(date: .abbreviated, time: .shortened))
        }
    }

    /// The ⓧ: 18 pt at the tile's (4, −3), `xmark` 8 pt semibold on #505054.
    /// Its target is the 24 pt floor, centred on the disc, so a near miss on
    /// the corner of a tile does not select it instead.
    private var removeBadge: some View {
        let badge = ShelfLayout.badge
        let target: CGFloat = 24
        return Button { shelf.remove(item) } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: badge.width, height: badge.height)
                .background(Circle().fill(Theme.shelfBadgeFill))
                .shadow(color: Color.black.opacity(0.5), radius: 1.5, x: 0, y: 1)
                .frame(width: target, height: target)
                .contentShape(Rectangle())
        }
        .buttonStyle(PanelButtonStyle())
        .help(localized("Remove from Shelf"))
        .accessibilityLabel(localized("Remove from Shelf"))
        .offset(
            x: badge.minX - (target - badge.width) / 2,
            y: badge.minY - (target - badge.height) / 2
        )
    }

    /// What the tile's second line says, then whether it is picked.
    ///
    /// The age is worked out here rather than read from the drawn line, which
    /// lives inside its own `TimelineView`: an ignored subtree is not read, so
    /// the value is as fresh as the tile's last pass, and the shelf redraws
    /// every tile on any change to it. "Selected" goes into the value as well as
    /// the trait, so it is heard wherever the tile is read and not only by a
    /// client that looks for the trait.
    private var accessibilityValue: String {
        var parts: [String] = []
        if item.isOffline {
            parts.append(localized("Disk not connected"))
        } else if let date = item.date {
            parts.append(ShelfItem.age(of: date))
        }
        if isSelected { parts.append(localized("Selected")) }
        return parts.joined(separator: ", ")
    }
}

/// Open With ▸ in a tile's menu: the file's applications, the default first.
///
/// A view of its own so the list is asked for when the menu is built and not
/// with the tile — a SwiftUI context menu's items are written inside the tile's
/// body, and anything computed there runs on every pass of every tile (the
/// reason AirDrop's availability is asked on the click, see
/// `ShelfSharing.airDrop`). Disabled for a file whose disk is away, which has
/// no application to be asked about.
private struct OpenWithMenu: View {
    let item: ShelfItem

    var body: some View {
        let apps = item.isOffline ? [] : ShelfOpenWith.apps(for: item.url)
        Menu(localized("Open With")) {
            ForEach(apps) { app in
                Button {
                    ShelfOpenWith.open(item.url, with: app)
                } label: {
                    Label { Text(app.name) } icon: { Image(nsImage: ShelfOpenWith.icon(for: app)) }
                }
            }
        }
        .disabled(apps.isEmpty)
    }
}

/// The tile menu's first line: kind, size and folder, or the disk an offline
/// tile waits for. Disabled — it is a label, not a verb.
///
/// A view of its own so the file is read when the menu is built, not with the
/// tile (see `OpenWithMenu`).
private struct CardMenuHeader: View {
    let item: ShelfItem

    var body: some View {
        Button(item.menuHeader()) {}
            .disabled(true)
    }
}

// MARK: - The two wells (§8.3)

/// One drop well: a glyph, its name, and a caption that says what letting go
/// will do — "Drop to keep on the Shelf" resting, "Release to add to the Shelf"
/// lit — so a person aiming at AirDrop is told, in words, that it sends and
/// keeps nothing.
private struct ShelfDropWell: View {
    let target: ShelfDropTarget
    let isLit: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.shelfDropWellRadius, style: .continuous)
        VStack(spacing: 6) {
            // The symbol takes the well's grey or white; AirDrop's real icon
            // is full-colour and is left as macOS draws it.
            ShelfIconView(icon: target.icon, size: 26)
                .foregroundStyle(isLit ? Color.white : Theme.secondary)
                .accessibilityHidden(true)
                .padding(.bottom, 4)
            Text(target.title)
                .islandFont(.subhead, weight: .semibold)
                .foregroundStyle(isLit ? Color.white : Theme.secondary)
            Text(isLit ? target.litCaption : target.restingCaption)
                .islandFont(.body, weight: .regular)
                .foregroundStyle(isLit ? Theme.secondary : Theme.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(shape.fill(isLit ? Theme.shelfDropWellLit : Theme.shelfDropWellResting))
        .overlay {
            if isLit {
                shape.strokeBorder(Theme.accent, lineWidth: Theme.shelfDropRingWidth)
            } else {
                shape.strokeBorder(Theme.shelfDropWellEdge, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            }
        }
        .animation(Theme.contentAnimation, value: isLit)
        .allowsHitTesting(false)
    }
}

// MARK: - The bar's small controls

/// Deselect All: a 16 pt round ⓧ beside the count it clears, as a token's close
/// does, and away from Remove so a near miss on one never lands on the other.
/// Its target is the panel's 24 × 20 floor (F-014), not the 16 pt disc.
private struct DeselectAllButton: View {
    let action: () -> Void

    var body: some View {
        let title = localized("Deselect All")
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Theme.secondary)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.white.opacity(0.14)))
                .frame(minWidth: Theme.minimumHitSize.width, minHeight: ShelfLayout.barHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(PanelButtonStyle())
        .help(title)
        .accessibilityLabel(title)
        // The disc is 16 pt, so the target's slack on either side would push the
        // count's neighbour away: pulled back by what the floor added.
        .padding(.horizontal, -4)
    }
}

/// The "…" menu that carries the bar's verbs below 540 (§8.2). An `NSMenu`
/// popped up from the button, for the reasons the lyric More menu is one: the
/// panel is a non-activating `NSPanel` that a menu pops up from like any
/// window, `MenuTracking` holds it open while the menu is up, and the board
/// draws plain rows with their glyphs and key hints.
@MainActor
final class ShelfMoreMenuPresenter: NSObject, ObservableObject {
    var anchor: NSView?
    private var perform: ((ShelfVerb) -> Void)?

    /// The key hint a verb shows in the menu: the ones the context menu names.
    static func keyEquivalent(for verb: ShelfVerb) -> String? {
        switch verb {
        case .copy: return "c"
        case .showInFinder: return "r"
        case .quickLook, .airDrop, .remove: return nil
        }
    }

    func present(verbs: [ShelfVerb], perform: @escaping (ShelfVerb) -> Void) {
        guard let anchor else { return }
        self.perform = perform
        let menu = NSMenu()
        menu.autoenablesItems = false
        for verb in verbs {
            let item = NSMenuItem(title: verb.title, action: #selector(picked(_:)), keyEquivalent: Self.keyEquivalent(for: verb) ?? "")
            if Self.keyEquivalent(for: verb) != nil { item.keyEquivalentModifierMask = .command }
            item.target = self
            item.tag = ShelfVerb.allCases.firstIndex(of: verb) ?? 0
            item.image = verb.icon.nsImage
            menu.addItem(item)
        }
        _ = menu.popUp(
            positioning: nil,
            at: OutputMenuPresenter.popUpPoint(anchorSize: anchor.bounds.size, menuWidth: max(menu.size.width, 0)),
            in: anchor
        )
    }

    @objc private func picked(_ sender: NSMenuItem) {
        guard ShelfVerb.allCases.indices.contains(sender.tag) else { return }
        perform?(ShelfVerb.allCases[sender.tag])
    }
}
