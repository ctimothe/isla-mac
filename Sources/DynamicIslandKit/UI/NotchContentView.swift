import SwiftUI

struct NotchContentView: View {
    @ObservedObject var vm: NotchViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isOpen: Bool { vm.isOpen || vm.isDropTargeted }
    private var size: CGSize { vm.bodySize }
    private var compactActivity: CompactMediaActivity { vm.compactMediaActivity }
    private var topRadius: CGFloat { isOpen ? Theme.openTopRadius : Theme.collapsedTopRadius }

    var body: some View {
        if vm.isLockedPresentation {
            // Two layers with the shield up: the pill where it always lives —
            // visible, never hoverable, the island refusing to disappear just
            // because the desktop did — and the player at the true center of
            // the display, where a locked laptop is actually looked at.
            ZStack(alignment: .top) {
                if compactActivity.isVisible {
                    ZStack(alignment: .top) {
                        NotchShape(
                            topRadius: Theme.collapsedTopRadius,
                            bottomRadius: Theme.collapsedBottomRadius
                        )
                        .fill(Color.black)
                        .frame(
                            width: size.width + 2 * Theme.collapsedTopRadius,
                            height: vm.geometry.notchSize.height
                        )
                        compactMediaHeader
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                    .overlay {
                        if vm.isHovering {
                            NotchShape(
                                topRadius: Theme.collapsedTopRadius,
                                bottomRadius: Theme.collapsedBottomRadius
                            )
                            .stroke(
                                LinearGradient(
                                    colors: [.clear, .white.opacity(0.10), .white.opacity(0.34)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 1
                            )
                            .frame(
                                width: size.width + 2 * Theme.collapsedTopRadius,
                                height: vm.geometry.notchSize.height
                            )
                            .transition(.opacity)
                        }
                    }
                    .animation(Theme.contentAnimation, value: vm.isHovering)
                    // The edge says the island is there; the shake says it is
                    // not opening here. Two different answers to two different
                    // gestures, rather than one shake for both.
                    .contentShape(Rectangle())
                    .onTapGesture { vm.onIslandClick?() }
                    .refusalShake(trigger: vm.lockedHoverNudges)
                }
            }
            // Held to the whole panel, top-aligned. The panel is anchored to
            // the notch, so the top of this window *is* the cutout — and a
            // stack left to hug a 32 pt pill gets centred in 444 pt instead,
            // which floats the island two hundred points down the lock screen,
            // over the clock. The card used to force this fill; it has a window
            // of its own now, so the fill has to be stated.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // Nothing here animates from the layout it had a moment ago. Locking
            // while the panel was open leaves an open→closed animation in
            // flight, and swapping the whole view tree under it made SwiftUI
            // interpolate the card and the pill *from* the old 700×444 notch
            // window — visibly sliding in from the left, at the wrong size, for
            // the length of that animation. The lock screen is a cut, not a
            // transition.
            .animation(nil, value: vm.isLockedPresentation)
            .transaction { $0.animation = nil }
        } else {
            shell
        }
    }

    private var shell: some View {
        // The shape is wider than the body by `topRadius` on each side: that
        // slack is where the concave shoulders live, so it must not be clipped.
        ZStack(alignment: .top) {
            NotchShape(
                topRadius: topRadius,
                bottomRadius: isOpen ? Theme.openBottomRadius : Theme.collapsedBottomRadius
            )
            .fill(Color.black)
            .frame(width: size.width + 2 * topRadius, height: size.height)
            .shadow(
                color: .black.opacity(isOpen ? 0.5 : (compactActivity.isVisible ? 0.28 : 0)),
                radius: isOpen ? 18 : 5,
                y: isOpen ? 8 : 2
            )
            .overlay { hoverEdge }
            // Hover read from the drawn shape, not from the pointer watcher.
            // The watcher's rect is deliberately 12pt wider and taller than the
            // island — generous is right for *opening*, where a near miss
            // should still work, and wrong for an edge, which lit up while the
            // cursor was visibly beside the island rather than on it.
            .onHover { if !isOpen { vm.isHovering = $0 } }

            if !isOpen, compactActivity.isVisible {
                compactWingSurface
                    .transition(.opacity)
            }

            VStack(spacing: 0) {
                header
                if isOpen {
                    content
                        .transition(.opacity)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipped()
        }
        .frame(width: size.width + 2 * topRadius, height: size.height, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // A click anywhere on the collapsed island opens it. The equalizer
        // wing keeps its own tap for play/pause — a child gesture wins, so
        // pausing still costs one click and does not open anything.
        .contentShape(Rectangle())
        .onTapGesture { if !isOpen { vm.onIslandClick?() } }
        .animation(Theme.open(reduceMotion: reduceMotion), value: isOpen)
        .animation(Theme.contentAnimation, value: vm.isHovering)
        .animation(Theme.compact(reduceMotion: reduceMotion), value: compactActivity)
        .animation(Theme.compact(reduceMotion: reduceMotion), value: vm.isPeeking)
        .animation(Theme.paneAnimation, value: vm.tab)
    }

    // MARK: - Header
    //
    // This strip sits directly on top of the menu bar. Menu bar utilities such
    // as Ice watch for clicks there with a global event monitor — a passive
    // observer that sees the click no matter which window consumes it — so
    // clicking here toggles them as a side effect. Nothing interactive goes in
    // this row; the tab switcher lives in the rail below.

    @ViewBuilder
    private var header: some View {
        if isOpen {
            openHeader
        } else if compactActivity.isVisible {
            compactMediaHeader
                .transition(Theme.scaleIn(0.9, reduceMotion: reduceMotion))
        } else {
            Color.clear
                .frame(width: vm.geometry.notchSize.width, height: vm.geometry.notchSize.height)
        }
    }

    private var openHeader: some View {
        HStack(spacing: 0) {
            Text(vm.tab.title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.tertiary)
                .padding(.leading, 16)
                .id(vm.tab)
                .transition(.opacity)
            Spacer(minLength: 0)
            Color.clear.frame(width: vm.geometry.notchSize.width, height: 1)
            Spacer(minLength: 0)
            trailing
                .padding(.trailing, 16)
                .transition(.opacity)
        }
        .frame(height: vm.geometry.notchSize.height)
    }

    private var compactMediaHeader: some View {
        let wingWidth = max(0, (size.width - vm.geometry.notchSize.width) / 2)
        return HStack(spacing: 0) {
            // Resting, each wing centres its content the way it always did —
            // pinning to the edges put the artwork and equalizer flush against
            // the pill's rounded ends with no inset at all. Only the peek
            // leads-aligns, because a title reads from the left, and it takes
            // an inset with it so nothing touches the curve.
            HStack(spacing: 7) {
                compactArtwork
                // Only while peeking, and only on the left wing: the title is
                // what the peek exists to show, and the right wing keeps the
                // equalizer so the pill still says whether audio is moving.
                if vm.isPeeking, let track = vm.media.track {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.title)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(track.artist)
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                    }
                    .transition(.opacity)
                    Spacer(minLength: 0)
                }
            }
            .padding(.leading, vm.isPeeking ? 10 : 0)
            .frame(width: wingWidth, alignment: vm.isPeeking ? .leading : .center)

            Color.clear
                .frame(width: vm.geometry.notchSize.width, height: 1)

            compactPlaybackState
                .padding(.trailing, vm.isPeeking ? 12 : 0)
                .frame(width: wingWidth, alignment: vm.isPeeking ? .trailing : .center)
                // Direct transport on the pill: a click on the equalizer wing
                // toggles playback without opening the panel — pausing should
                // not cost a hover, a dwell and a second click. The gesture
                // races the hover-open by design: with the default delay the
                // panel opens first and the click lands in it harmlessly; with
                // a longer configured delay the pill becomes a real button.
                .contentShape(Rectangle())
                .onTapGesture { vm.media.togglePlayPause() }
        }
        .frame(width: size.width, height: vm.geometry.notchSize.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(compactAccessibilityLabel)
        .accessibilityAction(named: vm.media.isPlaying ? localized("Pause") : localized("Play")) {
            vm.media.togglePlayPause()
        }
    }

    /// The answer to a hover: an edge, not an opening.
    ///
    /// Drawn only while collapsed, because an open panel has already answered.
    /// It is the whole affordance for click-to-open — without it the island
    /// looks inert, and nobody clicks something that has never reacted to them.
    /// Over the shield it is the *only* answer: the island stays lit there and
    /// stays shut, and the edge says the first half of that before a click says
    /// the second.
    @ViewBuilder
    private var hoverEdge: some View {
        if vm.isHovering, !isOpen {
            NotchShape(
                topRadius: topRadius,
                bottomRadius: isOpen ? Theme.openBottomRadius : Theme.collapsedBottomRadius
            )
            // Nothing along the top. That edge lies against the bezel, where
            // the island is meant to be continuous with the hardware — a line
            // there draws the boundary the whole shape exists to hide. The
            // gradient starts clear and arrives at the bottom, so the light
            // appears to come from below and the sides fade into it.
            //
            // And faint. At full white it read as a hard outline, which states
            // a border; this states a surface catching a little light.
            .stroke(
                LinearGradient(
                    colors: [.clear, .white.opacity(0.10), .white.opacity(0.34)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1
            )
            .transition(.opacity)
        }
    }

    /// The display can never reproduce the physical cutout's zero-light black
    /// at every brightness. The software-only wings therefore fade from an
    /// intentional graphite surface into true black at the hardware edges.
    /// That makes the difference read as depth rather than a failed colour
    /// match, while the centre remains visually continuous with the camera.
    private var compactWingSurface: some View {
        let wingWidth = max(0, (size.width - vm.geometry.notchSize.width) / 2 + topRadius)
        return HStack(spacing: 0) {
            CompactWingSurface(side: .left)
                .frame(width: wingWidth)

            Color.clear
                .frame(width: vm.geometry.notchSize.width)

            CompactWingSurface(side: .right)
                .frame(width: wingWidth)
        }
        .frame(width: size.width + 2 * topRadius, height: size.height)
        .clipShape(
            NotchShape(
                topRadius: Theme.collapsedTopRadius,
                bottomRadius: Theme.collapsedBottomRadius
            )
        )
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var compactArtwork: some View {
        ZStack {
            Group {
                if let artwork = vm.media.artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .scaledToFill()
                        .id(vm.media.track?.key)
                        .transition(.opacity)
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.75))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.surface)
                }
            }
            .opacity(compactActivity.showsArtworkPlayBadge ? 0.58 : 1)

            if compactActivity.showsArtworkPlayBadge {
                Circle()
                    .fill(Color.black.opacity(0.72))
                    .frame(width: 15, height: 15)
                    .overlay(
                        Image(systemName: "play.fill")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.92))
                            .offset(x: 0.5)
                    )
                    .overlay(
                        Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                    )
                    .transition(Theme.scaleIn(0.82, reduceMotion: reduceMotion))
            }
        }
        .frame(width: 22, height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 0.5)
        )
        .animation(Theme.contentAnimation, value: compactActivity.showsArtworkPlayBadge)
    }

    private var compactPlaybackState: some View {
        EqualizerBars(
            isAnimating: compactActivity.animatesEqualizer,
            opacity: compactActivity == .playing ? 0.82 : 0.58
        )
    }

    private var compactAccessibilityLabel: String {
        guard let track = vm.media.track else { return "" }
        let state = compactActivity == .playing ? localized("Playing") : localized("Paused")
        return "\(state): \(track.title), \(track.artist)"
    }

    @ViewBuilder
    private var trailing: some View {
        switch vm.tab {
        case .media:
            HStack(spacing: 6) {
                if vm.media.track != nil {
                    EqualizerBars(isAnimating: vm.media.isPlaying)
                }
                Text(vm.media.sourceName ?? "")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
            }
        case .shelf:
            counter(vm.shelf.items.count)
        case .clipboard:
            counter(vm.clipboard.items.count)
        case .translate:
            // Nothing: the columns name both languages already, and the strip
            // is the one part of the panel worth not spending on a repeat.
            EmptyView()
        case .settings:
            EmptyView()
        }
    }

    @ViewBuilder
    private func counter(_ value: Int) -> some View {
        if value > 0 {
            Text("\(value)")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.tertiary)
        }
    }

    // MARK: - Body

    private var content: some View {
        HStack(spacing: 14) {
            Rail(vm: vm, tabs: NotchViewModel.Tab.contentTabs, footer: NotchViewModel.Tab.utilityTabs)
            panes
        }
        .padding(.horizontal, 14)
        // The body's height is measured from this same number, so the two
        // cannot drift apart into a rail that does not fit.
        .padding(.bottom, NotchGeometry.bodyBottomPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var panes: some View {
        // Content is replaced in place — no travel. The rail is vertical and
        // the panes are unrelated, so a direction would only be decoration.
        ZStack {
            pane
                .id(vm.tab)
                .transition(.asymmetric(
                    insertion: .opacity
                        .combined(with: .scale(scale: 0.97))
                        .animation(Theme.paneIn),
                    removal: .opacity
                        .combined(with: .scale(scale: 1.02))
                        .animation(Theme.paneOut)
                ))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    @ViewBuilder
    private var pane: some View {
        switch vm.tab {
        case .media:
            MediaPane(media: vm.media, lyrics: vm.lyrics)
        case .shelf:
            ShelfPane(shelf: vm.shelf, isTargeted: vm.isDropTargeted)
        case .clipboard:
            ClipboardPane(clipboard: vm.clipboard, privacy: vm.privacy)
        case .translate:
            TranslatePane(translator: vm.translator, privacy: vm.privacy, wantsKeyboard: $vm.wantsKeyboard)
        case .settings:
            SettingsPane(
                shelf: vm.shelf,
                screenshotVault: vm.screenshotVault,
                lyrics: vm.lyrics,
                privacy: vm.privacy
            )
        }
    }
}

private struct CompactWingSurface: View {
    enum Side { case left, right }

    let side: Side

    private var outer: UnitPoint { side == .left ? .leading : .trailing }
    private var inner: UnitPoint { side == .left ? .trailing : .leading }

    var body: some View {
        // Solid black, no graphite and no sheen: the wings sit flush against
        // the physical cutout, and on hardware the cutout is zero-light black —
        // any lighter surface reads as a grey strip glued to the notch rather
        // than the notch itself. Content on the wings carries the contrast.
        Color.black
    }
}

/// Tab switcher.
///
/// Hovering switches tabs, but only after the pointer has stopped: a pointer
/// crossing the rail on its way somewhere else is gone in a few dozen
/// milliseconds, while one that came to choose stays put. The same dwell
/// threshold is what separates "the mouse was flung across the top of the
/// screen" from "the mouse came to the notch" in `PointerWatcher`.
private struct Rail: View {
    @ObservedObject var vm: NotchViewModel
    /// The run of content tabs people move between.
    let tabs: [NotchViewModel.Tab]
    /// Held to the bottom of the rail, below the gap: settings, which nobody
    /// should have to hover past on the way to a track.
    var footer: [NotchViewModel.Tab] = []

    @State private var hovered: NotchViewModel.Tab?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Long enough to swallow a pass-through, short enough that a deliberate
    /// hover still feels like it answered instantly.
    private let dwell = Duration.seconds(NotchMetrics.tabDwell)

    var body: some View {
        VStack(spacing: NotchGeometry.railSpacing) {
            ForEach(tabs) { icon(for: $0) }
            if !footer.isEmpty {
                Spacer(minLength: 10)
                ForEach(footer) { icon(for: $0) }
            }
        }
        .frame(width: 30)
        // The rail owns the body's full content height: the run of tabs at the
        // top, settings held to the bottom by the gap between them.
        .frame(height: vm.geometry.standardContentHeight, alignment: .center)
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(Theme.contentAnimation, value: hovered)
        // Moving to another icon cancels the pending switch along with the
        // task, so only the icon actually rested on ever wins.
        .task(id: hovered) {
            guard let hovered, hovered != vm.tab else { return }
            try? await Task.sleep(for: dwell)
            guard !Task.isCancelled else { return }
            vm.select(hovered)
        }
    }

    @ViewBuilder
    private func icon(for tab: NotchViewModel.Tab) -> some View {
        Button {
            vm.select(tab)
        } label: {
            Image(systemName: tab.symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 30, height: vm.geometry.railIconHeight)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(fill(for: tab))
                )
                .foregroundStyle(vm.tab == tab ? Color.white : Theme.tertiary)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                // A render-time transform. Growing the frame instead would
                // re-lay out the rail on every hover, and layout that runs on
                // pointer movement is exactly the kind that shows up as a
                // stutter.
                .scaleEffect(reduceMotion ? 1 : (hovered == tab ? 1.15 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(vm.tab == tab ? [.isButton, .isSelected] : .isButton)
        .onHover { inside in
            if inside {
                hovered = tab
            } else if hovered == tab {
                hovered = nil
            }
        }
    }

    private func fill(for tab: NotchViewModel.Tab) -> Color {
        if vm.tab == tab { return Theme.surfaceHover }
        return hovered == tab ? Theme.surface : .clear
    }
}
