import AppKit
import SwiftUI

/// The tray (spec §19.7, board `R2-Shelf-Open`): the board's tiles in rows
/// under the header strip, filling the three tools' shared page and scrolling
/// down past two and a bit rows (§19.7, amended 2026-10-18). Scrolling down
/// rather than sideways is the point: sideways is always the pages' swipe.
/// The Shelf's limit of sixty stands.
///
/// Every frame comes from `ShelfLayout` in the content's coordinates, so what a
/// test holds is what is drawn. It replaced §8.1's grid and §8.2's selection
/// bar; the store under it (selection, the cap, offline files, duplicates,
/// drag-out and ⌘-moves, Quick Look and AirDrop) is untouched. The header —
/// the glyph, the count and Remove All — is the shell's (`SurfaceHeader`).
struct ShelfPane: View {
    @ObservedObject var shelf: ShelfStore
    /// Remove All's question, the model's: the header asks it and the tray
    /// says it, in place of the row, with its two answers.
    @ObservedObject var clear: ShelfClearConfirmation
    var bodyWidth: CGFloat = 560

    /// Where the pointer is in the grid's viewport, and how far the grid is
    /// scrolled: together they say which tile it is over, *decided* by
    /// `ShelfLayout.tileIndex` on every redraw rather than reported by each
    /// tile's own `onHover`.
    ///
    /// Per-tile hover breaks on the Shelf's most repetitive gesture: removing
    /// tiles one after another. Hover events are made of mouse movement, and
    /// when a removed tile's neighbour slides under a pointer that has not
    /// moved, there are no events — the neighbour never learns it is hovered,
    /// its badge never appears, and the click meant to remove it selects it
    /// instead.
    @State private var hoverPoint: CGPoint?
    @State private var scrollOffset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if clear.isAsking {
                clearQuestion
                    .transition(.opacity)
            } else if shelf.items.isEmpty {
                emptyLine
                    .transition(.opacity)
            } else {
                grid
            }
            noticeLine
        }
        .frame(width: bodyWidth, height: ShelfLayout.viewport(bodyWidth: bodyWidth).height, alignment: .topLeading)
        // Only fades: nothing grows or slides between the states, so Reduce
        // Motion has nothing to take away.
        .animation(Theme.contentAnimation, value: shelf.items.isEmpty)
        .animation(Theme.contentAnimation, value: clear.isAsking)
        .animation(Theme.contentAnimation, value: shelf.notice)
        // A question left standing would be waiting inside the next visit to
        // the Shelf, one click from emptying it.
        .onDisappear { clear.cancel() }
        .onChange(of: shelf.items.isEmpty) { _, empty in if empty { clear.cancel() } }
        // The line is drawn where the tray is, so it is heard only when the
        // Shelf is on screen.
        .onChange(of: shelf.notice) { _, notice in
            if let notice { Announcer.shared.announce(notice.text) }
        }
    }

    // MARK: - Empty (§19.7)

    /// One line, centred: what the Shelf is for and how files reach it.
    private var emptyLine: some View {
        Text(localized("Drag files to the notch to keep them here."))
            .font(.system(size: ShelfLayout.emptyLineSize, weight: .regular))
            .tracking(Theme.tracking(forSize: ShelfLayout.emptyLineSize))
            .foregroundStyle(.white.opacity(Theme.shelfEmptyLineOpacity))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .frame(width: bodyWidth, height: ShelfLayout.viewport(bodyWidth: bodyWidth).height)
    }

    // MARK: - The grid (§19.7)

    private var grid: some View {
        let items = shelf.items
        let viewport = ShelfLayout.viewport(bodyWidth: bodyWidth)
        let hovered = hoverPoint.flatMap {
            ShelfLayout.tileIndex(
                at: CGPoint(x: $0.x, y: $0.y + scrollOffset), count: items.count, bodyWidth: bodyWidth
            )
        }
        return ScrollView(.vertical, showsIndicators: false) {
            ZStack(alignment: .topLeading) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    let frame = ShelfLayout.tileFrame(index: index, bodyWidth: bodyWidth)
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
                height: max(viewport.height, ShelfLayout.contentHeight(count: items.count, bodyWidth: bodyWidth)),
                alignment: .topLeading
            )
        }
        // A clipped top or bottom fades over 16 pt instead of ending on a
        // hard edge.
        .scrollEdgeFade(.vertical, length: ShelfLayout.edgeFade)
        .scrollDisabled(!ShelfLayout.scrolls(count: items.count, bodyWidth: bodyWidth))
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
    }

    // MARK: - Remove All asks first (§8.4, §19.7)

    /// "Remove all %d items? Files are untouched." with Cancel and Remove All,
    /// in place of the row while the question stands.
    private var clearQuestion: some View {
        VStack(spacing: 10) {
            Text(localized("Remove all %d items? Files are untouched.", shelf.items.count))
                .islandFont(.body, weight: .regular)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
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
        }
        .padding(.horizontal, 24)
        .frame(width: bodyWidth, height: ShelfLayout.viewport(bodyWidth: bodyWidth).height)
    }

    // MARK: - The notice (§8.4)

    /// What the Shelf did on its own account — cards pushed past the cap, a
    /// drop it already held, an AirDrop refusal — under the last row, or at
    /// the foot of a grid that scrolls (`ShelfLayout.noticeTop`), for the
    /// notice's few seconds. The tray's one inline line, so a failure here
    /// has one place and no toast.
    @ViewBuilder
    private var noticeLine: some View {
        if let notice = shelf.notice {
            Text(notice.text)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.85)
                .help(notice.text)
                .padding(.horizontal, 18)
                .frame(width: bodyWidth, height: ShelfLayout.noticeHeight)
                .offset(y: ShelfLayout.noticeTop(count: shelf.items.count, bodyWidth: bodyWidth))
                .transition(.opacity)
                .accessibilityHidden(true)
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

// MARK: - A tile (§19.7)

private struct ShelfTile: View {
    let item: ShelfItem
    @ObservedObject var shelf: ShelfStore
    /// Handed down from the tray, which is the one place that can know it
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

    /// The picture's box: a thumbnail at its own shape, long side 42, centred in
    /// the 42 pt square; a type's icon fills the square.
    private var iconFrame: CGRect {
        let box = ShelfLayout.icon
        let size = item.isPreview ? ShelfLayout.fittedSize(of: item.icon.size) : box.size
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
            // the badge, otherwise it swallows every click aimed at it.
            ShelfDragSource(
                items: { shelf.dragCards(startingAt: item).map { ($0.url, $0.icon) } },
                thumbnail: iconFrame,
                onClick: { modifiers in shelf.select(item, modifiers: modifiers) },
                onDoubleClick: { shelf.open(item) },
                onPress: { pressed in isPressed = pressed },
                // A ⌘-drag moved the file, or the Trash took it: the tile
                // follows it, or leaves with it (F-020).
                onMoved: { urls in shelf.followMove(urls) },
                toolTip: item.isOffline ? "\(item.name) — \(localized("Disk not connected"))" : item.name
            )
            .frame(width: ShelfLayout.tile.width, height: ShelfLayout.tile.height)
            if ShelfWell.showsBadge(isSelected: isSelected, isHovered: isHovered) {
                removeBadge
            }
        }
        .frame(width: ShelfLayout.tile.width, height: ShelfLayout.tile.height, alignment: .topLeading)
        .contentShape(RoundedRectangle(cornerRadius: ShelfLayout.tileRadius, style: .continuous))
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
        // client. Without it a tile was not an element at all: its name floated
        // loose in the tray, and select, open and drag lived in the AppKit
        // overlay, which has no accessibility, so nothing on the Shelf could be
        // used (F-006). `.ignore` swallows that overlay and the badge too; what
        // they do is offered here instead.
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
        // the menu does.
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

    /// The plate, the picture and the name — everything a tile draws.
    private var visual: some View {
        ZStack(alignment: .topLeading) {
            plate
                .frame(width: ShelfLayout.tile.width, height: ShelfLayout.tile.height)
            picture
                .frame(width: iconFrame.width, height: iconFrame.height)
                .offset(x: iconFrame.minX, y: iconFrame.minY)
            nameBlock
                .frame(width: ShelfLayout.nameWidth, alignment: .top)
                .offset(x: ShelfLayout.nameOrigin.x, y: ShelfLayout.nameOrigin.y)
        }
    }

    /// White 0.10, 0.14 under the pointer; picked, 0.18 inside a blue ring;
    /// a drop it already held, the drop target's lit look.
    @ViewBuilder
    private var plate: some View {
        let shape = RoundedRectangle(cornerRadius: ShelfLayout.tileRadius, style: .continuous)
        switch well {
        case .none:
            shape.fill(Theme.shelfTilePlate)
        case .hover:
            shape.fill(Theme.shelfHoverWell)
        case .selected:
            shape.fill(Theme.shelfSelectedWell)
                .overlay(shape.strokeBorder(Theme.shelfBlue, lineWidth: Theme.shelfSelectedRingWidth))
        case .alreadyKept:
            shape.fill(Theme.shelfDropWellLit)
                .overlay(shape.strokeBorder(Theme.shelfBlue, lineWidth: Theme.shelfDropRingWidth))
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

    /// The name: two lines at most, centred, the second cut in the middle so
    /// the extension survives (`ShelfTileName`).
    private var nameBlock: some View {
        VStack(spacing: 0) {
            ForEach(Array(ShelfTileName.drawnLines(item.name, selected: false).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: ShelfLayout.nameSize, weight: .semibold))
                    .tracking(Theme.tracking(forSize: ShelfLayout.nameSize))
                    .foregroundStyle(item.isOffline ? Theme.tertiary : Color.white.opacity(Theme.shelfTileNameOpacity))
                    .lineLimit(1)
                    .fixedSize()
                    .frame(height: ShelfLayout.nameLineHeight)
            }
        }
    }

    /// The badge: `xmark.circle.fill` 17 at the tile's (57.75, 5.5), white 0.62
    /// over a 14 pt black 0.28 disc. Its target is the 24 pt floor, centred on
    /// the glyph, so a near miss on the corner of a tile does not select it.
    private var removeBadge: some View {
        let badge = ShelfLayout.badge
        let target: CGFloat = 24
        return Button { shelf.remove(item) } label: {
            ZStack {
                Circle()
                    .fill(Theme.shelfBadgeDisc)
                    .frame(width: ShelfLayout.badgeDisc, height: ShelfLayout.badgeDisc)
                Image(systemName: "xmark.circle.fill")
                    .resizable()
                    .frame(width: badge.width, height: badge.height)
                    .foregroundStyle(Theme.shelfBadgeGlyph)
            }
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
        .transition(.opacity)
    }

    /// What VoiceOver hears after the name: the age or the missing disk, then
    /// whether it is picked.
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


// MARK: - The drop surface (§19.7)

/// What a file drag over the notch opens (board `R2-Shelf-Drag`): two
/// targets that name what letting go does. Drawing, not controls: the drop
/// itself is taken by the window's own drag handling (`NotchRootView`), and
/// which target it lands on is `ShelfDropTarget.target`, so nothing here may
/// catch the pointer on its way.
struct ShelfDropSurface: View {
    var bodyWidth: CGFloat
    var dropTarget: ShelfDropTarget

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach([ShelfDropTarget.keep, .airDrop], id: \.self) { target in
                ShelfDropWell(target: target, isLit: dropTarget == target)
                    .placedAt(SurfaceLayout.inContent(ShelfDropTarget.well(target, bodyWidth: bodyWidth)))
            }
        }
        .allowsHitTesting(false)
    }
}

/// One target: a glyph, its name, and a second line that says what letting go
/// does — so a person aiming at AirDrop is told, in words, that it sends and
/// keeps nothing.
private struct ShelfDropWell: View {
    let target: ShelfDropTarget
    let isLit: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ShelfDropTarget.radius, style: .continuous)
        VStack(spacing: 4) {
            // The symbol takes white; AirDrop's real icon is full-colour and is
            // left as macOS draws it.
            ShelfIconView(icon: target.icon, size: ShelfDropTarget.glyphSize)
                .foregroundStyle(Color.white)
                .accessibilityHidden(true)
                .padding(.bottom, 4)
            Text(target.title)
                .font(.system(size: 15, weight: .semibold))
                .tracking(Theme.tracking(forSize: 15))
                .foregroundStyle(Color.white)
                .lineLimit(1)
            Text(target.caption)
                .font(.system(size: 12, weight: .regular))
                .tracking(Theme.tracking(forSize: 12))
                .foregroundStyle(Color.white.opacity(isLit ? Theme.shelfDropCaptionLit : Theme.shelfDropCaptionResting))
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(shape.fill(isLit ? Theme.shelfDropWellLit : Theme.shelfDropWellResting))
        .overlay {
            if isLit {
                shape.strokeBorder(Theme.shelfBlue, lineWidth: Theme.shelfDropRingWidth)
            }
        }
        .animation(Theme.contentAnimation, value: isLit)
    }
}
