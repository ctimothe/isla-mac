import SwiftUI

struct ShelfPane: View {
    @ObservedObject var shelf: ShelfStore
    var isTargeted: Bool

    /// Which card the pointer is over — decided by the pane, not by the cards.
    ///
    /// Per-card `onHover` breaks on the shelf's most repetitive gesture:
    /// deleting cards one after another. Hover events are made of mouse
    /// movement, and when a deleted card's neighbour slides under a pointer
    /// that has not moved, there are no events — the neighbour never learns it
    /// is hovered, its ✕ never appears, and the click meant to delete it
    /// selects it instead, until a stray wiggle of the mouse fixes everything.
    /// So the pane tracks the pointer and every card's frame itself, and
    /// re-decides on either change: the pointer moving, or the cards moving
    /// under it. Scrolling the strip is the same case and heals the same way.
    @State private var hoveredID: UUID?
    @State private var hoverPoint: CGPoint?
    @State private var frames: [UUID: CGRect] = [:]

    var body: some View {
        VStack(spacing: 0) {
            if shelf.items.isEmpty {
                dropHint
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(shelf.items) { item in
                            ShelfCard(item: item, shelf: shelf, isHovered: hoveredID == item.id)
                                .background(
                                    GeometryReader { geo in
                                        Color.clear.preference(
                                            key: CardFramesKey.self,
                                            value: [item.id: geo.frame(in: .named("shelf"))]
                                        )
                                    }
                                )
                        }
                    }
                    .padding(.horizontal, 2)
                    .frame(maxHeight: .infinity)
                }
                // A full strip ended on a card cut through the middle with no
                // cue that more lay past it (H-017). The end with cards
                // beyond it fades; a strip that fits fades nowhere.
                .scrollEdgeFade(.horizontal)
                .coordinateSpace(name: "shelf")
                .onContinuousHover(coordinateSpace: .named("shelf")) { phase in
                    switch phase {
                    case .active(let point):
                        hoverPoint = point
                        rehit()
                    case .ended:
                        hoverPoint = nil
                        hoveredID = nil
                    }
                }
                .onPreferenceChange(CardFramesKey.self) { new in
                    frames = new
                    rehit()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // With cards on it the Shelf had no drop target at all: the
                // dashed well is the empty state's, the window is click-
                // through everywhere but the panel, and a file dragged over
                // the strip got no word that letting go would keep it (M-22).
                // The pill says so over the strip, not over the footer, and
                // only fades: nothing grows or slides, so Reduce Motion has
                // nothing to take away. The cards step back under it: at
                // full strength their names and glyphs showed through the
                // pill's glass and the sentence had to compete with them.
                .opacity(isTargeted ? 0.4 : 1)
                .overlay {
                    if isTargeted {
                        dropPill.transition(.opacity)
                    }
                }
                .animation(Theme.contentAnimation, value: isTargeted)
                footer
            }
        }
        .padding(.top, 2)
    }

    /// The one decision both signals feed: which frame holds the last known
    /// pointer position.
    private func rehit() {
        guard let hoverPoint else { return }
        hoveredID = frames.first(where: { $0.value.contains(hoverPoint) })?.key
    }

    /// The lit edge of a drop target, the empty well's and the pill's alike,
    /// so the two states of one gesture are drawn by one line.
    private static let dropEdge = Color.white.opacity(0.6)
    private static let dropDash = StrokeStyle(lineWidth: 1.5, dash: [6, 5])

    /// What a drag over a strip of cards is told. Drawing, not a control: the
    /// drop itself is taken by the window's own drag handling, so the pill
    /// must never catch the pointer on its way there.
    private var dropPill: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.and.arrow.down.on.square")
                .islandFont(.caption, weight: .semibold)
                .accessibilityHidden(true)
            Text(localized("Drop to keep on the Shelf"))
                .islandFont(.caption, weight: .semibold)
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // The sync pill's glass: it floats inside an opaque panel, so there
        // is nothing behind it to sample.
        .glassSurface(cornerRadius: 999, elevation: .pill, samplesBackdrop: false)
        .overlay(Capsule().strokeBorder(Self.dropEdge, style: Self.dropDash))
        // One element, the sentence: the glass underneath is an image too,
        // and on its own it reached VoiceOver as a nameless "image".
        .accessibilityElement(children: .combine)
        .allowsHitTesting(false)
    }

    private var dropHint: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(
                isTargeted ? Self.dropEdge : Theme.hairline,
                style: Self.dropDash
            )
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isTargeted ? Theme.surface : .clear)
            )
            .overlay(
                // The glyph alone used to be the whole empty state, and
                // VoiceOver read it by its symbol's name, "Download
                // Multiple" (F-036). The words say what the Shelf is for, where
                // files come from and how many it keeps; the glyph is drawing.
                VStack(spacing: 6) {
                    // Something arriving on the stack the tab is drawn as.
                    Image(systemName: "square.and.arrow.down.on.square")
                        .islandFont(.display, weight: .light)
                        .foregroundStyle(isTargeted ? .white : Theme.tertiary)
                        .accessibilityHidden(true)
                    // Under a drag the headline turns from what the Shelf is
                    // for into what letting go will do (M-22); the line
                    // below, where files come from and how many fit, stays.
                    Text(isTargeted ? localized("Release to add to the Shelf") : localized("Drop files here to keep them"))
                        .islandFont(.body)
                        .foregroundStyle(isTargeted ? .white : Theme.secondary)
                    Text(localized("From Finder, Mail, Photos or a browser. Holds %d.", ShelfStore.limit))
                        .islandFont(.caption, weight: .regular)
                        .foregroundStyle(Theme.tertiary)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(Theme.contentAnimation, value: isTargeted)
    }

    /// Two footers, one per state, and never both verbs at once.
    ///
    /// With cards picked, the destructive verb is "Remove 2" and acts on
    /// those two. It used to be Clear, beside "2 selected": a person reads
    /// Clear as acting on what they picked, and it emptied the whole shelf,
    /// with only the armed "Clear Everything" — in the very spot of the
    /// second press — to warn them (H-015). Clear comes back once nothing is
    /// picked, so emptying the shelf is still one deliberate step away.
    ///
    /// The leading slot holds one line: the count while there is a
    /// selection, otherwise the shelf's last notice, if it has one — except
    /// that an AirDrop refusal is shown over the count (F-049).
    ///
    /// With cards picked the footer is the Shelf's action bar. Quick Look and
    /// AirDrop — the two things a shelf is most often kept for besides a drag
    /// — with Copy and Show in Finder lived only in the right-click menu, and
    /// a trackpad user who never right-clicks never found them (F-037). The
    /// deselect ✕ sits with the count it clears, as a token's close does,
    /// and away from Remove, so a near miss on one never lands on the other.
    private var footer: some View {
        HStack(spacing: 10) {
            // An AirDrop refusal takes the count's place for its four
            // seconds (`Notice.showsOverSelection`): it answers the press of
            // a verb in this very bar, which only shows with a selection. The
            // count and its ✕ come back when it lapses.
            if let notice = shelf.notice, shelf.selection.isEmpty || notice.showsOverSelection {
                noticeLine(notice)
            } else if !shelf.selection.isEmpty {
                HStack(spacing: 2) {
                    Text(localized("%d selected", shelf.selection.count))
                        .islandFont(.caption, weight: .regular)
                        .foregroundStyle(Theme.tertiary)
                    ShelfBarButton(symbol: "xmark", title: localized("Deselect")) { shelf.clearSelection() }
                }
            }
            Spacer(minLength: 0)
            if !shelf.selection.isEmpty {
                actionBar
                ConfirmTextButton(
                    title: localized("Remove %d", shelf.selection.count),
                    armedTitle: localized("Remove %d from Shelf", shelf.selection.count)
                ) { shelf.removeSelected() }
                // A fresh button for every selection, so an arming always
                // names the cards the second press removes: armed on two,
                // then ⌘-clicking a third, it starts over rather than
                // removing three on the strength of a confirmation for two.
                .id(shelf.selection)
            } else {
                ConfirmTextButton(
                    title: localized("Clear"),
                    armedTitle: localized("Clear Everything")
                ) { shelf.clear() }
            }
        }
        .padding(.top, 2)
        .animation(Theme.contentAnimation, value: shelf.notice)
        // The line is drawn where the pane is, so it is heard only when the
        // Shelf is on screen: a screenshot saved with the panel shut has
        // nobody to tell, and VoiceOver should not speak up over another tab.
        .onChange(of: shelf.notice) { _, notice in
            if let notice { Announcer.shared.announce(notice.text) }
        }
    }

    private func noticeLine(_ notice: ShelfStore.Notice) -> some View {
        // Two lines at most: the eviction sentence ends on what matters
        // most — the files themselves are untouched — and at the narrowest
        // panel, in Russian, one line cut it off.
        Text(notice.text)
            .islandFont(.caption, weight: .regular)
            .foregroundStyle(Theme.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .transition(.opacity)
    }

    /// The selection's verbs, in the card menu's order. Each acts on the
    /// picked cards a drag would carry — in shelf order, without a card
    /// whose disk is away — and the bar goes quiet when that leaves nothing.
    /// Copy takes the first of them: the pasteboard path writes one file with
    /// its image data, and several at once is a change of its own.
    private var actionBar: some View {
        let cards = shelf.selectedCards
        return HStack(spacing: 2) {
            ShelfBarButton(symbol: "eye", title: localized("Quick Look")) {
                ShelfSharing.quickLook(cards.map(\.url))
            }
            ShelfBarButton(symbol: "dot.radiowaves.up.forward", title: localized("AirDrop")) {
                ShelfSharing.airDrop(cards.map(\.url), refusingOn: shelf)
            }
            ShelfBarButton(symbol: "doc.on.doc", title: localized("Copy")) {
                if let first = cards.first { shelf.copy(first) }
            }
            ShelfBarButton(symbol: "folder", title: localized("Show in Finder")) {
                shelf.reveal(cards)
            }
        }
        .disabled(cards.isEmpty)
    }
}

private struct CardFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct ShelfCard: View {
    let item: ShelfItem
    @ObservedObject var shelf: ShelfStore
    /// Handed down from the pane, which is the one place that can know it
    /// correctly when cards move under a stationary pointer.
    let isHovered: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The mouse is down on the card, or a drag that started on it is still
    /// in flight. Reported by the drag overlay, which owns the mouse.
    @State private var isPressed = false
    /// The thumbnail's box in the card, measured, so a drag lifts the picture
    /// from where it is drawn rather than from a copy of the layout's sums.
    @State private var thumbnailBox: CGRect = .zero

    private var isSelected: Bool { shelf.isSelected(item) }

    /// The card's coordinate space, for `thumbnailBox`. The drag overlay
    /// covers the card exactly, so the box is in the overlay's terms too.
    private static let space = "shelfCard"

    var body: some View {
        VStack(spacing: 6) {
            // Fit, not fill: a screenshot is landscape and a file icon is
            // square, and forcing either into the other's box is what squashed
            // the wide ones. The box is wide enough for a 16:10 frame, so a
            // square icon simply centres in it.
            Image(nsImage: item.icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 68, height: 40)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { thumbnailBox = $0 }
                // A disk that is not plugged in: the card is still the card,
                // only out of reach until the disk comes back.
                .opacity(item.isOffline ? Theme.offlineThumbnailOpacity : 1)
            // The name, then how long ago. A capture's name already carries
            // its date, but "Screenshot 2026-09-21 at 15.43.23" has to be read
            // and worked out; "5 min. ago" is known at a glance, and it is what
            // tells two captures of the same minute's session apart.
            VStack(spacing: 1) {
                // Cut by `ShelfItem.compactName`, which keeps the last word —
                // the "15.04.44" that tells one capture from the next — where
                // a middle cut kept "Scree" and ".44.png" (H-025). The middle
                // truncation stays only as a backstop for a pixel of
                // difference between the measure and the drawing. The whole
                // name is the card's tool tip, on the drag view below.
                Text(Self.fittedName(item.name))
                    .islandFont(.caption, weight: .regular)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if item.isOffline {
                    // In place of the age, which is the less useful line once
                    // the file cannot be opened: what a person needs to know
                    // is why, and what brings it back.
                    Text(localized("Disk not connected"))
                        .islandFont(.caption, weight: .regular)
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                } else if let date = item.date {
                    // Re-read twice a minute, so "Just now" does not linger
                    // into the afternoon on a shelf left open.
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(ShelfItem.age(of: date, now: context.date))
                            .islandFont(.caption, weight: .regular)
                            .foregroundStyle(Theme.tertiary)
                            .lineLimit(1)
                    }
                    .help(date.formatted(date: .abbreviated, time: .shortened))
                }
            }
            .frame(height: 24, alignment: .top)
        }
        .padding(.horizontal, ShelfItem.cardInset)
        .padding(.vertical, 8)
        .frame(width: ShelfItem.cardWidth, height: 92)
        .coordinateSpace(.named(Self.space))
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Theme.selectedChip : (isHovered ? Theme.surfaceHover : Theme.surface))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.selectedChipBorder.opacity(isSelected ? 1 : 0), lineWidth: 1.5)
                .allowsHitTesting(false)
        )
        // Drawn under the drag overlay, which draws nothing, so the mark
        // presses with the card it belongs to.
        .overlay(alignment: .topLeading) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .islandFont(.subhead, weight: .regular)
                    .foregroundStyle(.white)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        // The press answers on the way down (F-038). Only what is drawn
        // dips: the drag overlay below sits outside the scale, so the region
        // that owns the mouse stays exactly where the press began, and the
        // thumbnail box it lifts the drag image from is the unscaled one.
        // Reduce Motion asks for no change of size, so the card dims instead.
        .scaleEffect(isPressed && !reduceMotion ? Theme.pressScale : 1)
        .opacity(isPressed && reduceMotion ? Theme.pressDimOpacity : 1)
        .animation(Theme.contentAnimation, value: isPressed)
        // Owns clicks and drags: a group drag needs one dragging item per file,
        // which SwiftUI's onDrag cannot express. It must stay *below* the close
        // button, otherwise it swallows every click aimed at it.
        .overlay(
            ShelfDragSource(
                items: { shelf.dragCards(startingAt: item).map { ($0.url, $0.icon) } },
                thumbnail: thumbnailBox,
                onClick: { modifiers in shelf.select(item, modifiers: modifiers) },
                onDoubleClick: { shelf.open(item) },
                onPress: { pressed in isPressed = pressed },
                // A ⌘-drag moved the file, or the Trash took it: the card
                // follows it, or leaves with it (F-020).
                onMoved: { urls in shelf.followMove(urls) },
                toolTip: item.name
            )
        )
        .overlay(alignment: .topTrailing) {
            if isHovered {
                Button { shelf.remove(item) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .islandFont(.subhead, weight: .regular)
                        .foregroundStyle(Color.white.opacity(0.75))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PanelButtonStyle())
                .help(localized("Remove from Shelf"))
                .accessibilityLabel(localized("Remove from Shelf"))
                .padding(2)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        // Grouped as Finder groups a file's menu: what it is, looking at it,
        // sending it on, where it lives, and the destructive verb last and
        // apart (M-14). The header says which file this is before anything
        // is done to it (M-23).
        .contextMenu {
            CardMenuHeader(item: item)
            Divider()
            Button("Quick Look") { ShelfSharing.quickLook(shelf.dragURLs(startingAt: item)) }
            Button("Open") { shelf.open(item) }
            Divider()
            Button("AirDrop") { ShelfSharing.airDrop(shelf.dragURLs(startingAt: item), refusingOn: shelf) }
            Button("Copy") { shelf.copy(item) }
            Divider()
            Button("Show in Finder") { shelf.reveal(item) }
            Divider()
            Button("Remove from Shelf", role: .destructive) { shelf.remove(item) }
        }
        // One element per card, for VoiceOver and every other assistive
        // client. Without it a card was not an element at all: its name and
        // its age floated loose in the pane and interleaved across cards
        // ("Just now" read beside the wrong file), the selection mark was an
        // image of its own, and select, open and drag lived in the AppKit
        // overlay, which has no accessibility, so nothing on the Shelf could
        // be used (F-006). `.ignore` swallows that overlay, the check mark and
        // the hover ✕ too; what they do is offered here instead. Making
        // `DragView` accessible was the other way, and it still left two
        // elements per card with the texts loose beside them.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.name)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        // VO-Space opens the file, as a double-click and Finder's Return do.
        .accessibilityAction { shelf.open(item) }
        // The context menu's verbs, in the Actions rotor. Written bottom-up:
        // SwiftUI vends named actions outermost first, so the last declared
        // is the first offered, and the rotor should read Select, Quick Look,
        // AirDrop, Copy, Show in Finder, then the destructive Remove last, as
        // the menu does. Select is the ⌘-click toggle, because a VoiceOver
        // user picks cards one at a time and a plain click's "this one
        // instead" would drop the rest.
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
        .animation(Theme.contentAnimation, value: isHovered)
        .animation(Theme.contentAnimation, value: isSelected)
    }

    /// Names already fitted, by name. A pick re-draws every card on the shelf
    /// and fitting one measures it once per character it gives up — sixty
    /// captures were some fifteen hundred measurements on a click. A shelf
    /// holds sixty names, so the cache is emptied rather than ordered when it
    /// outgrows a few shelves' worth.
    private static var fittedNames: [String: String] = [:]

    private static func fittedName(_ name: String) -> String {
        if let fitted = fittedNames[name] { return fitted }
        if fittedNames.count >= 4 * ShelfStore.limit { fittedNames.removeAll() }
        let fitted = ShelfItem.compactName(name, fitting: ShelfItem.cardNameWidth, measure: ShelfItem.measureCardName)
        fittedNames[name] = fitted
        return fitted
    }

    /// What the card's second line says, then whether it is picked.
    ///
    /// The age is worked out here rather than read from the drawn line, which
    /// lives inside its own `TimelineView`: an ignored subtree is not read, so
    /// the value is as fresh as the card's last pass, and the shelf redraws
    /// every card on any change to it. "Selected" goes into the value as well
    /// as the trait, so it is heard wherever the card is read and not only by
    /// a client that looks for the trait; it used to be a check-mark image of
    /// its own, read as a stray "Selected" beside whichever text came next.
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

/// The card menu's first line: kind, size and folder, or the disk an offline
/// card waits for. Disabled — it is a label, not a verb.
///
/// A view of its own so the file is read when the menu is built, not with
/// the card: a context menu's items are written inside the card's body, and
/// anything computed there runs on every pass of every card (the reason
/// AirDrop's availability is asked on the click, see `ShelfSharing.airDrop`).
private struct CardMenuHeader: View {
    let item: ShelfItem

    var body: some View {
        Button(item.menuHeader()) {}
            .disabled(true)
    }
}

/// One verb of the Shelf's action bar: a glyph in a 24 pt square, its word
/// in the tool tip and for VoiceOver.
///
/// Glyphs, not words: "Быстрый просмотр", "Показать в Finder" and their
/// neighbours do not fit beside the count and "Убрать 2" in a 480 pt panel,
/// and a cut verb is worse than none. They are the glyphs the system uses for
/// the same verbs, so they are read the way they are read in Finder.
private struct ShelfBarButton: View {
    let symbol: String
    let title: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    /// The bar's square: the caption-sized floor (`Theme.minimumHitSize`) is
    /// for a word; a lone glyph needs the square to be found by the pointer.
    static let side: CGFloat = 24

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .islandFont(.body, weight: .regular)
                .foregroundStyle(isEnabled ? Theme.secondary : Theme.tertiary)
                .frame(width: Self.side, height: Self.side)
                .contentShape(Rectangle())
        }
        .buttonStyle(PanelButtonStyle())
        .help(title)
        .accessibilityLabel(title)
    }
}
