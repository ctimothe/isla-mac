import SwiftUI

/// The open panel's body: the panes and their travel. Stored properties live in NotchContentView.swift.
extension NotchContentView {
    // MARK: - Body

    var content: some View {
        let headerHeight = vm.geometry.notchSize.height
        return ZStack(alignment: .topLeading) {
            panes
                .frame(
                    width: size.width,
                    // A page's dots have their own band under it (§19.16): the
                    // pane ends above the band, so no list or card runs under them.
                    height: max(0, size.height - headerHeight - SurfaceLayout.dotsBand(for: vm.presented)),
                    alignment: .topLeading
                )
                // Between two pages the taller arriving one would run on into
                // the band, under the dots; cut there while they travel. At
                // rest nothing is cut, as before.
                .clipShape(PaneClip(isCutting: vm.travellingLeg != nil))
            // After the pages, so VoiceOver reads the row after the page.
            if vm.presented.isPage {
                PageDots(
                    current: PageDots.current(leg: vm.travellingLeg, presented: vm.presented),
                    chosen: vm.presented.pageIndex ?? 0,
                    bodySize: size, headerHeight: headerHeight,
                    turn: { vm.travel(to: $0, reduceMotion: reduceMotion) },
                    adjust: { vm.adjustPage(by: $0, reduceMotion: reduceMotion) }
                )
                .accessibilitySortPriority(-1)
                .transition(.opacity)
            }
        }
            .frame(width: size.width, height: max(0, size.height - headerHeight), alignment: .topLeading)
            // A sideways swipe anywhere over a page turns it (§19.16).
            // Weakly: the monitor must not keep a view model a rebuild replaced.
            .onPageSwipe(enabled: vm.presented.isPage && !vm.isLockedPresentation) { [weak vm] event, over in
                vm?.pageScroll(event, over: over) ?? false
            }
            // VO-Escape, or Switch Control's Escape, anywhere in the body closes
            // the panel, as the header does. A panel opened from assistive tech is
            // pinned open, and the pin ends only on a real mouse-down in another
            // app, so without this the only way out was the global hot key —
            // which someone who opened Isla by its button may not know (G-015).
            .accessibilityAction(.escape) { vm.onIslandClick?() }
    }

    private var panes: some View {
        // At rest, one pane: the presented surface, replaced in place — the
        // old one gone before the new one starts, each with the slight scale
        // about the top edge that is the only travel a swap has, so the two
        // are never on screen together (`Theme.swapOut`, `swapIn`). Reduce
        // Motion takes the scale, and the swap is a plain fade out and in
        // (F-017). The body's own size springs on the island's curve
        // underneath (`openBodySize`), and the outline's mask cuts whatever
        // of either pane is outside it on the way.
        //
        // Between two pages (§19.16), the two either side of the travel, side
        // by side, each at its own size, moved by exactly the travel and
        // clipped by the outline. One `ForEach` keyed by the surface for both,
        // so the page on screen when a swipe begins stays the view it was —
        // its scroll, its field, its hover — and the neighbour joins it, and
        // later leaves, with no transition: it is off the outline when it does.
        let scales = Theme.paneSwapScales(reduceMotion: reduceMotion)
        let leg = vm.travellingLeg
        let shown = leg?.mounted ?? [vm.presented]
        return ZStack(alignment: .topLeading) {
            ForEach(shown) { surface in
                let frame = paneSize(surface)
                pane(for: surface)
                    .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                    .offset(x: paneX(surface, leg: leg))
                    .transition(leg != nil ? .identity : .asymmetric(
                        insertion: .opacity
                            .combined(with: .scale(scale: scales.insertion, anchor: .top))
                            .animation(Theme.swapIn),
                        removal: .opacity
                            .combined(with: .scale(scale: scales.removal, anchor: .top))
                            .animation(Theme.swapOut)
                    ))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // One group, named for what it holds.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(vm.presented.title)
    }

    /// A pane's own frame: its surface's open body less the header row, and
    /// less the dots' band on a page.
    private func paneSize(_ surface: NotchViewModel.Surface) -> CGSize {
        let body = vm.openSize(of: surface)
        return CGSize(
            width: body.width,
            height: max(0, body.height - vm.geometry.notchSize.height - SurfaceLayout.dotsBand(for: surface))
        )
    }

    /// Where a pane's leading edge sits in the outline: centred, and on the
    /// way between two pages moved by exactly the travel (`PageStrip`).
    private func paneX(_ surface: NotchViewModel.Surface, leg: PageTravel.Leg?) -> CGFloat {
        guard let leg, let index = leg.strip.pages.firstIndex(of: surface) else {
            return (size.width - vm.openSize(of: surface).width) / 2
        }
        return leg.strip.x(ofPage: index, at: leg.position, outlineWidth: size.width)
    }

    /// Whether a pane drawn now is the surface on screen, or a page beside it
    /// only for a swipe's length (§19.16). Only the one on screen may hold
    /// the keyboard or start work: a neighbour that took focus on appearing
    /// would take the keyboard from the page the fingers are still on — and
    /// keep it if they went back — and Translate passed on the way would
    /// translate its text for nobody.
    nonisolated static func paneIsLive(
        _ surface: NotchViewModel.Surface, presented: NotchViewModel.Surface
    ) -> Bool {
        surface == presented
    }

    @ViewBuilder
    private func pane(for surface: NotchViewModel.Surface) -> some View {
        let bodyWidth = vm.openSize(of: surface).width
        let live = Self.paneIsLive(surface, presented: vm.presented)
        let keyboard = live ? $vm.wantsKeyboard : .constant(false)
        switch surface {
        case .player:
            // The namespace goes down with the player: the far end of the
            // cover's travel is drawn inside it, and it is the one surface that
            // has an end to offer.
            MediaPane(
                media: vm.media,
                lyrics: vm.lyrics,
                openStage: { withAnimation(Theme.island(reduceMotion: reduceMotion)) { vm.openStage() } },
                bringPlayerForward: { vm.media.bringPlayerForward() },
                openMusicOnlySetting: vm.openMusicOnlySetting,
                morph: travellingMorph,
                audio: vm.playerAudio,
                spotify: vm.spotifyAccount,
                coverTint: vm.coverTint.nsColor,
                isLive: live,
                nowPlaying: vm.nowPlaying.frame,
                // The open's first pass builds the flight's two ends alone;
                // the rest comes in with every other surface's body
                // (`bodyStaged`, `MediaPane.holdsBackRest`).
                holdsBackRest: !bodyStaged
            )
            // Skipped on a pass that changes nothing it draws: during a page
            // swipe this body is re-run on every frame, and without it so was
            // each page under it (`MediaPane ==`).
            .equatable()
        case .stage:
            LyricsStageSurface(
                media: vm.media,
                lyrics: vm.lyrics,
                bodyWidth: bodyWidth,
                localLookup: vm.lyricsCoordinator.localLookup,
                turnOnLyrics: vm.turnOnLyrics,
                turnOnOnlineLyrics: vm.turnOnOnlineLyrics,
                importLocalFile: { vm.chooseLocalLyricsFile(from: .stage) },
                notice: vm.lyricsNotice?.origin == .stage ? vm.lyricsNotice?.text : nil,
                selectLocalCandidate: vm.lyricsCoordinator.selectLocalCandidate,
                removeLocalBinding: vm.lyricsCoordinator.removeLocalBinding,
                localLibrary: vm.localLyricsLibrary,
                currentLocalTrackIdentity: { vm.lyricsCoordinator.currentLocalTrackIdentity },
                invalidLine: {
                    vm.lyricsCoordinator.currentLocalTrackIdentity.flatMap { vm.localLyricsLibrary.invalidLine(for: $0) }
                },
                editingSession: $vm.lyricEditing,
                moreMenu: vm.lyricsMoreMenu,
                translateMenu: vm.lyricsTranslateMenu,
                hideLyrics: { withAnimation(Theme.island(reduceMotion: reduceMotion)) { vm.hideLyrics() } },
                audio: vm.playerAudio,
                translation: vm.translation,
                coverTint: vm.coverTint.nsColor,
                nowPlaying: vm.nowPlaying.frame
            )
        case .tray:
            ShelfPane(shelf: vm.shelf, clear: vm.shelfClear, bodyWidth: bodyWidth)
        case .drop:
            ShelfDropSurface(bodyWidth: bodyWidth, dropTarget: vm.shelfDropTarget)
        case .clipboard:
            ClipboardPane(
                clipboard: vm.clipboard, privacy: vm.privacy, browser: vm.clipboardBrowser,
                bodyWidth: bodyWidth,
                wantsKeyboard: keyboard,
                translate: { vm.translateClipboardText($0) },
                clearConfirmation: vm.clipboardClear,
                turnOnHistory: { vm.setClipboardHistory(true) },
                isLive: live
            )
            .equatable()
        case .translate:
            TranslatePane(
                translator: vm.translator, privacy: vm.privacy, wantsKeyboard: keyboard,
                showsHistory: $vm.translateShowsHistory, bodyWidth: bodyWidth, isLive: live,
                isTravelling: vm.travellingLeg != nil
            )
                .equatable()
                .onPreferenceChange(TextInputRectKey.self) { vm.textInputRect = $0 }
        case .settings:
            SettingsPane(
                shelf: vm.shelf,
                screenshotVault: vm.screenshotVault,
                lyrics: vm.lyrics,
                media: vm.media,
                localLyrics: vm.localLyricsLibrary,
                onLyricsVisibilityChanged: vm.lyricsCoordinator.refreshVisibility,
                importLocalLyrics: { vm.chooseLocalLyricsFile(from: .settings) },
                lyricsNotice: vm.lyricsNotice?.origin == .settings ? vm.lyricsNotice?.text : nil,
                addLocalLyricsFolder: vm.chooseLocalLyricsFolder,
                removeLocalLyricsFolder: vm.removeLocalLyricsFolder,
                rescanLocalLyrics: vm.rescanLocalLyrics,
                openLocalLyricsFolder: vm.revealLocalLyricsFolder,
                clearImportedLyrics: vm.clearImportedLyrics,
                clearBindingsAndTimingCorrections: vm.clearLyricsBindingsAndTimingCorrections,
                dismissUnassignedLyricsOffset: vm.dismissUnassignedLyricsOffset,
                privacy: vm.privacy,
                wantsKeyboard: $vm.wantsKeyboard,
                setClipboardHistory: vm.setClipboardHistory,
                setClipboardIncludeImages: vm.setClipboardIncludeImages,
                setClipboardKeepPinned: vm.setClipboardKeepPinned,
                refreshClipboardPolling: vm.refreshClipboardPolling,
                setTranslateKeepHistory: vm.setTranslateKeepHistory,
                setTranslateSpeakButton: vm.setTranslateSpeakButton,
                setVolumeAndBrightness: vm.setVolumeAndBrightness,
                accessibilityMissing: vm.accessibilityMissing,
                accessibilityEntrySuspectedStale: vm.accessibilityEntrySuspectedStale,
                accessibilityRepairing: vm.accessibilityRepairing,
                volumeKeysRefused: vm.volumeKeysRefused,
                selection: $vm.settingsSection,
                // Built once the old pane has gone and this one is still
                // transparent (`Theme.swapIn` starts then): the heaviest tree
                // in the island, and the morph's costliest frame when it was
                // built in the first one (§19.3, 2026-10-18).
                mountsAfter: vm.arrivedOverAnOpenSurface ? Theme.swapOutDuration : 0
            )
        case .welcome:
            WelcomePane(onDismiss: { vm.dismissWelcome() })
        }
    }
}
