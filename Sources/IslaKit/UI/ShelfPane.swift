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

    private var dropHint: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(
                isTargeted ? Color.white.opacity(0.6) : Theme.hairline,
                style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
            )
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isTargeted ? Theme.surface : .clear)
            )
            .overlay(
                Image(systemName: "tray.and.arrow.down.fill")
                    .islandFont(.display, weight: .light)
                    .foregroundStyle(isTargeted ? .white : Theme.tertiary)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(Theme.contentAnimation, value: isTargeted)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if !shelf.selection.isEmpty {
                Text(localized("%d selected", shelf.selection.count))
                    .islandFont(.caption, weight: .regular)
                    .foregroundStyle(Theme.tertiary)
            }
            Spacer()
            if !shelf.selection.isEmpty {
                Button("Deselect") { shelf.clearSelection() }
                    .buttonStyle(PanelButtonStyle())
                    .islandFont(.caption)
                    .foregroundStyle(Theme.secondary)
            }
            ConfirmTextButton(
                title: localized("Clear"),
                armedTitle: localized("Clear Everything")
            ) { shelf.clear() }
        }
        .padding(.top, 2)
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

    private var isSelected: Bool { shelf.isSelected(item) }

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
            // The name, then how long ago. A capture's name already carries
            // its date, but "Screenshot 2026-09-21 at 15.43.23" has to be read
            // and worked out; "5 min. ago" is known at a glance, and it is what
            // tells two captures of the same minute's session apart.
            VStack(spacing: 1) {
                Text(item.name)
                    .islandFont(.caption, weight: .regular)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let date = item.date {
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
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .frame(width: 86, height: 92)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Theme.selectedChip : (isHovered ? Theme.surfaceHover : Theme.surface))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.selectedChipBorder.opacity(isSelected ? 1 : 0), lineWidth: 1.5)
                .allowsHitTesting(false)
        )
        // Owns clicks and drags: a group drag needs one dragging item per file,
        // which SwiftUI's onDrag cannot express. It must stay *below* the close
        // button, otherwise it swallows every click aimed at it.
        .overlay(
            ShelfDragSource(
                urls: { shelf.dragURLs(startingAt: item) },
                onClick: { modifiers in shelf.select(item, modifiers: modifiers) },
                onDoubleClick: { shelf.open(item) }
            )
        )
        .overlay(alignment: .topLeading) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .islandFont(.subhead, weight: .regular)
                    .foregroundStyle(.white)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
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
        .contextMenu {
            Button("Copy") { shelf.copy(item) }
            Button("Open") { shelf.open(item) }
            Button("Show in Finder") { shelf.reveal(item) }
            Divider()
            Button("Remove from Shelf") { shelf.remove(item) }
        }
        .animation(Theme.contentAnimation, value: isHovered)
        .animation(Theme.contentAnimation, value: isSelected)
    }
}
