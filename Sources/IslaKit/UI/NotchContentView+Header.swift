import SwiftUI

/// The header row: what the island shows shut and open. Stored properties live in NotchContentView.swift.
extension NotchContentView {
    // MARK: - Header
    //
    // This strip sits directly on top of the menu bar. Menu bar utilities such
    // as Ice watch for clicks there with a global event monitor — a passive
    // observer that sees the click no matter which window consumes it — so
    // clicking here toggles them as a side effect. No controls go in this row —
    // the tab switcher lives in the rail below — and the one gesture it answers
    // is the one the island already owns: the click that shuts the panel.

    @ViewBuilder
    var header: some View {
        if isOpen {
            openHeader
        } else {
            // Mounted whenever the panel is shut — folded into the notch too,
            // drawn at nothing there. A pill that was only in the tree while it
            // showed could not fold: removed, a view keeps the frame it had,
            // so its cover sat still at the old width while the edge swept in
            // over it and sliced it. Kept, it rides the wings as they contract
            // and dissolves on its own curve; see `compactMediaHeader`.
            //
            // This transition is load-bearing, and not for the reason it looks
            // like. A removed view with a transition stays in the tree until the
            // transition ends; a removed view with `.identity` is gone the
            // instant the flag flips. The cover and the equalizer travel from
            // *here* to the open panel, and `matchedGeometryEffect` can only
            // interpolate between two views that are both in the tree for the
            // same transaction. Take this transition away and the morph does not
            // break loudly — it silently goes back to being a crossfade.
            ZStack {
                // The music stays mounted under the moment, faded rather than
                // removed, so the cover's morph and the fold described above
                // are exactly as they were when the moment ends.
                compactMediaHeader(morph: travellingMorph)
                    // A live activity that outranks the song (a timer, a
                    // recording) replaces it as an alert does, and so does a
                    // new track's alert, as the pop-up does (§3.5, amended
                    // 2026-11-15).
                    .opacity(
                        vm.ambient == nil && vm.hud == nil && vm.confirmation == nil && vm.updateOffer == nil
                            && !holdsLive && vm.activity != .peek ? 1 : 0
                    )
                    // Faded under the update alert, and out of VoiceOver's
                    // way with it: the alert's container lets its own
                    // children through, and a song nobody can see is not one.
                    .accessibilityHidden(vm.updateOffer != nil)
                // One activity at a time, the highest first (`IslandActivity`):
                // an alert replaces what it outranks, and the replaced one is
                // gone, not waiting underneath (spec §19.1).
                switch vm.activity {
                case .hud:
                    // Its own view, watching the live level: a press redraws
                    // the pop-up and not this body (`HUDLiveLevel`).
                    HUDPillContent(live: vm.hudLive, size: size, notchHeight: vm.geometry.notchSize.height)
                        .transition(Theme.hudArrival(reduceMotion: reduceMotion))
                case .peek:
                    // A new track, shown exactly as the pop-up is (§3.5,
                    // amended 2026-11-15): its shape, its spring and its fade.
                    if let song = vm.nowPlaying.presented {
                        NewTrackAlertContent(
                            song: song, size: size, notchHeight: vm.geometry.notchSize.height,
                            animatesEqualizer: compactActivity.animatesEqualizer,
                            equalizerColors: CompactEqualizerMotion.colors(
                                isPlaying: compactActivity.tintsEqualizer,
                                tint: vm.coverTint.nsColor,
                                increaseContrast: appearance.increaseContrast
                            ),
                            reduceMotion: reduceMotion
                        )
                        .transition(Theme.hudArrival(reduceMotion: reduceMotion))
                    }
                case .confirmation(let confirmation):
                    // A compact activity, and it arrives as one: the
                    // charger's look, which under Reduce Motion is a fade.
                    confirmationHeader(confirmation)
                        .transition(Theme.compactArrival(reduceMotion: reduceMotion))
                case .ambient(let ambient):
                    ambientHeader(ambient)
                        .transition(ambientArrival(ambient))
                case .update(let offer):
                    UpdateAlertView(
                        offer: offer, size: size, notchHeight: vm.geometry.notchSize.height,
                        onAction: { vm.onUpdateAction?($0) }
                    )
                    .transition(Theme.expandedArrival(reduceMotion: reduceMotion))
                case .shelf(let count):
                    shelfHeader(count: count)
                        .transition(Theme.compactArrival(reduceMotion: reduceMotion))
                case .live(let live):
                    // One view per kind, so a timer turning into a download
                    // is content leaving and arriving, not one view morphing.
                    Group {
                        if vm.showsLiveControls, case .recording(let state) = live {
                            MicrophoneControlsView(
                                state: state, size: size, notchHeight: vm.geometry.notchSize.height,
                                increaseContrast: appearance.increaseContrast,
                                onAction: { vm.onMicrophoneControl?($0) }
                            )
                            .transition(Theme.expandedArrival(reduceMotion: reduceMotion))
                        } else if vm.showsLiveControls {
                            TimerControlsView(
                                live: live, size: size, notchHeight: vm.geometry.notchSize.height,
                                increaseContrast: appearance.increaseContrast,
                                onAction: { vm.onTimerControl?($0) }
                            )
                            .transition(Theme.expandedArrival(reduceMotion: reduceMotion))
                        } else {
                            LiveCompactHeader(live: live, size: size, reduceMotion: reduceMotion)
                                .transition(Theme.compactArrival(reduceMotion: reduceMotion))
                        }
                    }
                    .id(live.kind)
                case .music, .none:
                    EmptyView()
                }
            }
            // The island to assistive tech, on the stack that holds both the
            // music and the moment, so that a peek or a charger changes this
            // element's value rather than swapping one element for another.
            // Under the update alert it lets the alert's buttons through.
            .modifier(islandAccessibility(open: false))
            .transition(Theme.scaleIn(0.9, reduceMotion: reduceMotion))
        }
    }

    private var holdsLive: Bool {
        if case .live = vm.activity { return true }
        return false
    }

    /// The charger is a compact activity and arrives as one; headphones are
    /// an expanded alert and arrive as one (spec §19.3).
    private func ambientArrival(_ ambient: AmbientActivity) -> AnyTransition {
        switch ambient {
        case .charging: return Theme.compactArrival(reduceMotion: reduceMotion)
        case .headphones, .batteryLow, .batteryFull, .timerDone: return Theme.expandedArrival(reduceMotion: reduceMotion)
        }
    }

    /// What the island is to VoiceOver and Switch Control: one button called
    /// Isla, in every state the island has, whose value says what it shows.
    ///
    /// The element used to live inside the music header and was hidden while
    /// the pill was folded, on the reasoning that a folded pill has nothing on
    /// screen to describe. But the island is not only a display: it is the one
    /// way into the app, which has no Dock icon, no menu-bar item and no
    /// window. With nothing playing the tree held only the hosting view, and a
    /// blind user could neither find Isla nor open it — while the welcome told
    /// them to click it (H-001). So the island is always there now, with
    /// "Nothing is playing." as its value when that is the truth.
    ///
    /// Open, the same element sits on the header strip — the strip a pointer
    /// clicks to shut the panel — and says so. A panel opened from assistive
    /// tech is pinned open, and nothing in it used to close it again: the
    /// strip was a bare tap gesture with no trait and no action (G-015).
    ///
    /// Accessibility modifiers do not change layout, so the matched-geometry
    /// ids and the fold are untouched, and the strip stays free of controls
    /// for the pointer: menu-bar monitors such as Ice see exactly what they
    /// saw before.
    func islandAccessibility(open: Bool) -> IslandAccessibility {
        IslandAccessibility(
            containsControls: !open && !vm.isLockedPresentation && vm.updateOffer != nil,
            value: open ? openIslandValue : closedIslandValue,
            hint: open ? localized("Closes the panel") : localized("Opens the panel"),
            action: {
                // Locked, the same refusal a click gets — the shake and the
                // spoken "Unlock your Mac to open Isla." It used to return
                // silently, which to someone who cannot see the pill was a
                // button that did nothing at all.
                guard !vm.isLockedPresentation else {
                    vm.nudgeLockedIsland()
                    return
                }
                vm.onIslandClick?()
            }
        )
    }

    /// The shut island's value: the moment if one is up, else the track, else
    /// that there is none. Over the shield it names only the alerts the
    /// locked pill draws (`lockedAlert`): the pop-up and the charger.
    private var closedIslandValue: String {
        if vm.isLockedPresentation, let alert = vm.lockedAlert {
            switch alert {
            case .hud(let hud): return hud.accessibilityLabel
            case .ambient(let ambient): return ambient.accessibilityLabel
            default: break
            }
        }
        // The level as the last press left it when this body last ran. A
        // press redraws only the pop-up (`HUDLiveLevel`), so this is the
        // arrival's level until something else re-runs the body; the spoken
        // level is the announcement's (`NotchController.presentHUD`), which
        // follows every press.
        if !vm.isLockedPresentation, let hud = vm.hud { return hud.accessibilityLabel }
        if !vm.isLockedPresentation, let confirmation = vm.confirmation { return confirmation.accessibilityLabel }
        if !vm.isLockedPresentation, let ambient = vm.ambient { return ambient.accessibilityLabel }
        if !vm.isLockedPresentation, let offer = vm.updateOffer { return localized("Isla %@ is ready", offer.version) }
        if !vm.isLockedPresentation, case .shelf(let count) = vm.activity { return IslandBubble.label(count: count) }
        if !vm.isLockedPresentation, case .live(let live) = vm.activity { return live.accessibilityLabel(at: Date()) }
        return vm.media.track == nil ? localized("Nothing is playing.") : compactAccessibilityLabel
    }

    /// The open island's value: the surface on screen, and the count or the
    /// player beside it where it has one.
    private var openIslandValue: String {
        let surface = vm.presented
        let detail: String?
        switch surface {
        case .player, .stage: detail = vm.media.sourceName
        case .tray: detail = vm.shelf.items.isEmpty ? nil : "\(vm.shelf.items.count)"
        case .clipboard: detail = nil
        case .drop, .translate, .settings, .welcome: detail = nil
        }
        guard let detail, !detail.isEmpty else { return surface.title }
        return "\(surface.title), \(detail)"
    }

    /// A confirmation on the shut island (`IslandConfirmation`): its symbol
    /// in the left wing where the charger's word starts, its words in the
    /// right ending where the charger's battery ends — both white on the
    /// island's black, nothing under the notch.
    private func confirmationHeader(_ confirmation: IslandConfirmation) -> some View {
        let scale = CompactIslandLayout.glyphScale(height: size.height)
        return HStack(spacing: 0) {
            GlyphImage(IslandGlyph(rawValue: confirmation.symbol) ?? .check, pointSize: ConfirmationLayout.symbolSize * scale)
                .foregroundStyle(Color.white)
                .padding(.leading, ConfirmationLayout.leadingInset)
            Spacer(minLength: 0)
            Text(confirmation.title)
                .font(.system(size: ConfirmationLayout.titleSize, weight: .medium))
                .tracking(Theme.tracking(forSize: ConfirmationLayout.titleSize))
                .foregroundStyle(Color.white.opacity(ConfirmationLayout.titleOpacity))
                .lineLimit(1)
                .fixedSize()
                .padding(.trailing, ConfirmationLayout.trailingInset)
        }
        .frame(width: size.width, height: size.height)
        // No element of its own: like the other moments it is the island's
        // value (`closedIslandValue`), and the act already said it.
    }

    /// The charger or the headphones on the island.
    @ViewBuilder
    func ambientHeader(_ ambient: AmbientActivity) -> some View {
        switch ambient {
        case .charging(let level, _, _, _, _):
            // `showsOnIsland` keeps a Mac with no level off the island; the
            // guard is for the type, not a state that is drawn.
            if let level { chargingHeader(ambient, level: level) }
        case .headphones(let name, let symbol):
            headphonesHeader(name: name, symbol: symbol)
        case .timerDone(let duration):
            TimerDoneView(duration: duration, size: size, notchHeight: vm.geometry.notchSize.height)
        case .batteryLow, .batteryFull:
            BatteryAlertView(
                activity: ambient, size: size, notchHeight: vm.geometry.notchSize.height,
                reduceMotion: reduceMotion, increaseContrast: appearance.increaseContrast
            )
        }
    }

    /// Charging (spec §19.4, amended 2026-10-26): MagSafe's ring or USB-C's
    /// battery, each with its own words in the left wing — see
    /// `ChargingActivityView`, which draws both.
    private func chargingHeader(_ ambient: AmbientActivity, level: Int) -> some View {
        ChargingActivityView(
            activity: ambient, level: level, size: size, notchWidth: vm.geometry.notchSize.width,
            reduceMotion: reduceMotion, increaseContrast: appearance.increaseContrast
        )
    }

    /// Headphones connected (spec §19.5 c), an expanded alert: the device's
    /// own glyph at left; "Connected" over the device's name
    /// beside it, the name truncating at its tail. The battery ring waits for
    /// a level Isla can read without a new permission (§19.15, R9), so the
    /// name takes its width.
    private func headphonesHeader(name: String, symbol: String) -> some View {
        let notchHeight = vm.geometry.notchSize.height
        let glyph = HeadphonesAlertLayout.glyphFrame(notchHeight: notchHeight)
        return ZStack(alignment: .topLeading) {
            GlyphImage(IslandGlyph(rawValue: symbol) ?? .headphones)
                .foregroundStyle(Color.white.opacity(HeadphonesAlertLayout.glyphOpacity))
                .frame(width: glyph.width, height: glyph.height)
                .offset(x: glyph.minX, y: glyph.minY)
            Text(localized("Connected"))
                .islandFont(HeadphonesAlertLayout.connectedSize)
                .foregroundStyle(Color.white.opacity(HeadphonesAlertLayout.connectedOpacity))
                .lineLimit(1)
                .islandBaseline(HeadphonesAlertLayout.connectedBaseline(notchHeight: notchHeight))
                .offset(x: HeadphonesAlertLayout.textLeading)
            Text(name)
                .islandFont(HeadphonesAlertLayout.nameSize)
                .foregroundStyle(Color.white.opacity(HeadphonesAlertLayout.nameOpacity))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: HeadphonesAlertLayout.nameWidth(islandWidth: size.width), alignment: .leading)
                .islandBaseline(HeadphonesAlertLayout.nameBaseline(notchHeight: notchHeight))
                .offset(x: HeadphonesAlertLayout.textLeading)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    /// The Shelf holding files (spec §19.4): `tray.full.fill`, white, 26 × 20
    /// at (17.3, 9); the count in SF Pro Rounded 16, tabular, white, ending
    /// 18.3 from the edge. The live activity when nothing plays.
    private func shelfHeader(count: Int) -> some View {
        let tray = CompactIslandLayout.shelfGlyphFrame(height: size.height)
        return HStack(spacing: 0) {
            GlyphImage(.trayFullFilled)
                .foregroundStyle(Color.white)
                .frame(width: tray.width, height: tray.height)
                .padding(.leading, tray.minX)
            Spacer(minLength: 0)
            Text(count, format: .number)
                .font(.system(size: CompactIslandLayout.shelfCountFontSize, design: .rounded).monospacedDigit())
                .foregroundStyle(Color.white)
                .contentTransition(.numericText(value: Double(count)))
                .lineLimit(1)
                .fixedSize()
                .padding(.trailing, CompactIslandLayout.shelfCountTrailingInset)
        }
        .frame(width: size.width, height: size.height)
    }

    /// The open panel's header strip (spec §19.6–§19.8): the notch's height,
    /// with the surface's title or glyph left of the notch and its tools
    /// right of it, each centred on the strip.
    ///
    /// Only the notch's own span closes the panel. The strip used to close on
    /// a click anywhere, which was safe while nothing in it was a control; the
    /// surfaces carry Tools, History, Remove All and Settings here now, and a
    /// click a few points beside one must not shut the panel out from under
    /// the pointer. The span is where the island is, so a click on the island
    /// still answers as it always has.
    private var openHeader: some View {
        let notch = vm.geometry.notchSize
        let span = SurfaceHeaderLayout.closeSpan(bodyWidth: size.width, notchWidth: notch.width, notchHeight: notch.height)
        return ZStack(alignment: .topLeading) {
            Color.clear
            // The close, and the island to assistive tech: the same Isla button
            // the shut island is, which says it closes (G-015).
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { vm.onIslandClick?() }
                .modifier(islandAccessibility(open: true))
                .placedAt(span)
            headerLeading(notch: notch)
            headerTrailing(notch: notch)
        }
        .frame(width: size.width, height: notch.height, alignment: .topLeading)
        .animation(Theme.contentAnimation, value: vm.presented)
    }

    @ViewBuilder
    private func headerLeading(notch: CGSize) -> some View {
        switch vm.presented {
        case .clipboard, .translate, .settings:
            if let symbol = vm.presented.symbol {
                SurfaceHeaderTitle(symbol: symbol, title: vm.presented.title)
                    .placedAt(SurfaceHeaderLayout.title(
                        bodyWidth: size.width, notchWidth: notch.width, notchHeight: notch.height
                    ))
                    .transition(.opacity)
            }
        case .player, .stage:
            // Which app the sound comes from — Spotify, Music, Telegram, a
            // browser — by its own icon and name, where the other pages name
            // themselves (owner's review, 2026-10-18). The left of the
            // player's header was empty while the right held the gear.
            let source = PlayerSourceTitle(name: vm.media.sourceName, icon: vm.media.shownSourceIcon(vm.nowPlaying.frame))
            let room = SurfaceHeaderLayout.title(bodyWidth: size.width, notchWidth: notch.width, notchHeight: notch.height)
            SurfaceHeaderTitle(glyph: source.glyph, title: source.title, showsName: source.showsName(room: room.width))
                .placedAt(room)
                .transition(.opacity)
        case .tray:
            let count = vm.shelf.items.count
            HeaderGlyphView(glyph: .symbol("tray.full.fill"))
                .placedAt(SurfaceHeaderLayout.trayGlyph(notchHeight: notch.height))
                .transition(.opacity)
            if ShelfHeader.showsCount(itemCount: count) {
                Text(count, format: .number)
                    .font(.system(size: ShelfLayout.headerCountSize, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.white)
                    .contentTransition(.numericText(value: Double(count)))
                    .lineLimit(1)
                    .placedAt(SurfaceHeaderLayout.trayCount(
                        bodyWidth: size.width, notchWidth: notch.width, notchHeight: notch.height
                    ))
                    .accessibilityLabel(ShelfHeader.countText(count))
                    .transition(.opacity)
            }
        case .drop, .welcome:
            EmptyView()
        }
    }

    @ViewBuilder
    private func headerTrailing(notch: CGSize) -> some View {
        let gear = SurfaceHeaderLayout.gear(bodyWidth: size.width, notchHeight: notch.height)
        switch vm.presented {
        case .tray:
            if ShelfHeader.showsRemoveAll(itemCount: vm.shelf.items.count) {
                let width = ShelfRemoveAllButton.width()
                ShelfRemoveAllButton { vm.askToRemoveAll() }
                    .placedAt(SurfaceHeaderLayout.removeAll(bodyWidth: size.width, width: width, notchHeight: notch.height))
                    .transition(.opacity)
            }
            gearButton.placedAt(gear)
        case .translate:
            if translateKeepsHistory {
                HeaderToolButton(
                    symbol: "clock.arrow.circlepath", label: localized("History"), isOn: vm.translateShowsHistory
                ) { vm.translateShowsHistory.toggle() }
                .placedAt(SurfaceHeaderLayout.history(bodyWidth: size.width, notchHeight: notch.height))
                .transition(.opacity)
            }
            gearButton.placedAt(gear)
        case .player, .stage, .clipboard, .settings:
            gearButton.placedAt(gear)
        case .drop, .welcome:
            EmptyView()
        }
    }

    /// The gear (spec §19.16), where the Tools button stood: Settings from a
    /// page or the stage on the island's spring, and on Settings a close
    /// button, the way back (`HeaderGear`). It carries the update badge Tools'
    /// own gear carried, so an update waiting shows on every page.
    private var gearButton: some View {
        let gear = HeaderGear(onSettings: vm.presented == .settings, hasUpdate: updates.hasUpdate)
        return HeaderToolButton(symbol: gear.symbol, label: gear.label, badge: gear.badge) {
            withAnimation(Theme.island(reduceMotion: reduceMotion)) { vm.pressGear() }
        }
        .transition(.opacity)
    }

    /// - Parameter morph: the namespace the cover and the equalizer travel in,
    ///   or `nil` where there is nowhere for them to travel to — over the lock
    ///   screen, where this pill is the only thing on screen.
    ///
    /// The cover is 8 pt from the island's left edge and the equalizer's last
    /// bar 8 pt from its right (spec §3.1), both centred in the island's height
    /// — on the 38 pt notch that is the "7 from the bottom" the board draws.
    /// Pinned to the
    /// island's own edges rather than centred in a wing, so the margins are the
    /// same on a notch of any width.
    ///
    /// Both wing objects stay laid out while the pill is folded, still against
    /// the edges of a shape that contracts to the notch. That is what makes a
    /// fold read as the island taking them in: as the wings contract the cover
    /// and the bars travel inward with their edges, and `pillPresence` dissolves
    /// them — blur, scale and fade together — on a curve that finishes before
    /// the edge arrives.
    func compactMediaHeader(morph: Namespace.ID?) -> some View {
        let shown = compactActivity.isVisible
        let notchWidth = vm.geometry.notchSize.width
        return HStack(spacing: 0) {
            compactArtwork(morph: morph)
                .pillPresence(shown, reduceMotion: reduceMotion)
                .padding(.leading, CompactIslandLayout.coverInset)
            Spacer(minLength: 0)
            compactPlaybackState(morph: morph)
                .pillPresence(shown, reduceMotion: reduceMotion)
                .padding(.trailing, CompactIslandLayout.equalizerTrailingInset)
                // No gesture here, deliberately.
                //
                // The equalizer wing used to toggle playback, from when a hover
                // opened the panel and a click had no other meaning. Now that a
                // click *is* how the island opens, a wing that did something
                // else gave the compact island two behaviours with nothing
                // visible marking the boundary — press one half and it opens,
                // press the other and the music stops.
                //
                // The compact island has no controls at all. It shows what is
                // playing, and clicking anywhere on it opens the panel, where
                // the controls actually are.
        }
        .frame(width: size.width, height: size.height)
        // No element of its own. It was one, hidden while folded, and so with
        // nothing playing the island did not exist to VoiceOver at all; the
        // island's one element now sits on whatever holds this header — see
        // `islandAccessibility(open:)`. Its single purpose is still opening:
        // a Pause action here would be a button the compact island does not
        // have, reachable only by people who cannot see that it has none.
    }

    /// The near end of the cover's travel.
    ///
    /// It used to be a second cover: 22 pt here (24 since the redesign), 118 pt in `MediaPane`, each
    /// fading on its own schedule, so opening the panel crossfaded one album
    /// past itself. The two are one object now, and the pieces that make it one
    /// are worth naming, because none of them announces itself when it breaks:
    ///
    /// - `Theme.artworkMetrics` describes both ends, so they cannot disagree
    ///   about size or silhouette.
    /// - The base is `Color.clear` and the picture rides above it. The cover has
    ///   to accept whatever size it is offered — the morph offers it the panel's
    ///   118 pt on the way out — and anything that states a size of its own is
    ///   something the effect cannot resize, leaving a cover that slides across
    ///   without ever growing. `Color.clear` takes the proposal exactly and the
    ///   clip below cuts the overflow off, which `scaledToFill` needs badly: a
    ///   16:9 cover reports itself 39 pt wide in this 22 pt slot and would hang
    ///   over the notch. `.frame(maxWidth: .infinity)` is not a substitute — it
    ///   grows to whatever the child reports, taking the clip with it.
    /// - `.morph` sits **inside** the outer frame, so the frame keeps reserving
    ///   the cover's side in the wing while the cover itself is somewhere between here and
    ///   the panel.
    /// - The image carries no `.transition(.opacity)` of its own any more. A
    ///   travelling object that fades while it travels is a crossfade wearing a
    ///   morph's clothes. One album gives way to the next through the shared
    ///   swap on the picture inside (`trackSwapCover`), keyed on the presented
    ///   song, never on this frame.
    private func compactArtwork(morph: Namespace.ID?) -> some View {
        // 22 pt at radius 5 resting, 16 at 4 on the short island. A new track
        // no longer grows it: that is the alert's own cover now (§3.5,
        // amended 2026-11-15).
        let metrics = (side: CompactIslandLayout.coverSide(height: size.height),
                       cornerRadius: CompactIslandLayout.coverRadius(height: size.height))
        return Color.clear
            .overlay {
                Group {
                    // The presented song's cover, keyed on the presented song:
                    // the two change in one transaction. Keyed on the live
                    // track, the key changed a report before the picture did,
                    // so a skip crossfaded the old cover into itself and then
                    // cut to the new one (owner, 2026-10-25).
                    if let artwork = vm.nowPlaying.presented?.artwork {
                        Image(nsImage: artwork)
                            .resizable()
                            .scaledToFill()
                            .trackSwapCover(vm.nowPlaying.presented?.key, reduceMotion: reduceMotion)
                    } else {
                        // A well and a note (spec §3.2): the left wing is never
                        // a hole, and never a second, different kind of cover.
                        Theme.coverWell
                            .overlay {
                                GlyphImage(.music, pointSize: Theme.TypeRole.body.size)
                                    .foregroundStyle(Theme.secondary)
                            }
                    }
                }
                // A cover landing after its song was swapped in fades in on
                // the swap's curve, under the same key.
                .animation(Theme.trackSwap(reduceMotion: reduceMotion), value: vm.nowPlaying.presented?.artwork)
                // Paused darkens the cover to 0.55 of itself. It was 0.58
                // opacity, which let a bright wallpaper through the picture —
                // a paused cover on a pale desktop read as a ghost — where a
                // multiply darkens it over anything.
                .colorMultiply(showsPausedCover ? Color(white: Theme.pausedCoverBrightness) : .white)
            }
            .overlay {
                if showsPausedCover {
                    // A bare glyph on the dimmed cover, 9 pt, white, with a
                    // faint shadow for the one cover that is nearly white. The
                    // 15 pt black badge this replaces was a second object on a
                    // 22 pt cover; the glyph is fitted to the cover, not type,
                    // so no role applies and the caption floor would be too
                    // large for it.
                    GlyphImage(.play, pointSize: 9)
                        .foregroundStyle(Color.white)
                        .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                        .offset(x: 0.5)
                        .transition(Theme.scaleIn(0.82, reduceMotion: reduceMotion))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 0.5)
            )
            .morph(MorphID.compact(MorphID.artwork, folded: !travelsFromThePill), in: morph)
            .frame(width: metrics.side, height: metrics.side)
            .animation(Theme.contentAnimation, value: showsPausedCover)
    }

    /// The paused cover, kept through the fold.
    ///
    /// `.paused` is the only state that draws the badge, and a settled pause is
    /// `.hidden` — so every fold began by brightening the cover back to full
    /// and popping its badge off: a flash of "playing" on the way into the
    /// notch. Paused is what the player says, not what the pill is doing.
    private var showsPausedCover: Bool {
        Self.showsPausedCover(activity: compactActivity, isPlaying: vm.media.isPlaying)
    }

    static func showsPausedCover(activity: CompactMediaActivity, isPlaying: Bool) -> Bool {
        activity.showsArtworkPlayBadge || (!activity.isVisible && !isPlaying)
    }

    /// The equalizer travels too, and it is the easier half: the pill's bars
    /// are carried to the open header's right end, so the bars never vanish on
    /// one side of the notch and reappear on the other — which reads as two
    /// equalizers for one piece of music.
    ///
    /// Six bars in the cover's tint as a gradient while music plays; at rest,
    /// 3 pt tall in tertiary, when it is paused (spec §19.4, §3.2). Three
    /// quarters of its size on the short island, scaled rather than re-laid,
    /// so the far end of the morph is the same view at the same proportions.
    private func compactPlaybackState(morph: Namespace.ID?) -> some View {
        let scale = CompactIslandLayout.glyphScale(height: size.height)
        let side = CompactIslandLayout.equalizerSide * scale
        return CompactEqualizer(
            isAnimating: compactActivity.animatesEqualizer,
            colors: CompactEqualizerMotion.colors(
                isPlaying: compactActivity.tintsEqualizer,
                tint: vm.coverTint.nsColor,
                increaseContrast: appearance.increaseContrast
            )
        )
        .scaleEffect(scale)
        .frame(width: side, height: side)
        .morph(MorphID.compact(MorphID.equalizer, folded: !travelsFromThePill), in: morph)
    }

    /// Whether the pill's cover and equalizer are the near end of their travel
    /// into the panel: while it shows, and not while a new track's alert
    /// stands over it (§3.5, amended 2026-11-15). Faded under the alert, the
    /// pill is laid out in the alert's 103 pt and its cover sits some 30 pt
    /// below where it rests, so a click on the alert flew the player's cover
    /// in from a place nobody could see (review, 2026-11-15). Folded, the
    /// panel's cover arrives with its pane, as it does from a folded pill.
    private var travelsFromThePill: Bool {
        compactActivity.isVisible && vm.activity != .peek
    }

    /// The view model's, because the peek announces the same sentence.
    private var compactAccessibilityLabel: String { vm.compactAccessibilityLabel }
}
