import AppKit
import Combine
import UniformTypeIdentifiers

/// Choosing, turning and swiping between the surfaces. Stored properties live in NotchViewModel.swift.
extension NotchViewModel {
    /// The welcome has been read. Sets the flag that keeps it from ever coming
    /// back, and lands on what a click would have opened.
    func dismissWelcome() {
        isShowingWelcome = false
        Self.completeFirstRun()
        land(on: openTarget)
    }

    /// A surface somebody asked for — by shortcut, by the menu.
    ///
    /// Distinct from the roads the *machinery* moves the panel by — the
    /// pointer arriving, a click on the island, which land without the
    /// keyboard (`land(on:)`) — because none of those is an answer to
    /// anything. A hot key used to count as machinery
    /// too, and its surface opened invisibly behind the welcome (J-018). The
    /// pointer arrives by definition on the way to the Get Started button, so
    /// dismissing the welcome from `open` would have wiped it out from under
    /// the cursor reaching for it. Reaching for a surface is a decision; the
    /// pointer crossing the panel is not.
    func choose(_ surface: Surface) {
        if isShowingWelcome {
            isShowingWelcome = false
            Self.completeFirstRun()
        }
        open(surface)
    }

    /// Text that ⌃⌥⌘T or the "Translate in Isla" service brought, already
    /// through `Translator.prepareCommandInput`. The controller decides
    /// whether the panel may open at all (the lock refusal) and holds it open;
    /// this decides what the surface shows.
    ///
    /// Through `choose`, not `open`: a shortcut is somebody asking for this
    /// surface, and the welcome prints the shortcut, so the first thing a new
    /// user does with it is press it. Through `open` the text landed in a field
    /// the welcome was covering, the keyboard went to it unseen and the panel
    /// folded (J-018).
    ///
    /// No text leaves the field as it was — an image on the clipboard is not
    /// a reason to throw away a sentence somebody typed — and only the notice
    /// says what happened (F-040).
    func receiveCommandedTranslation(_ prepared: Translator.CommandInput) {
        if let text = prepared.text {
            // Covered again before the text lands. The pane's reveal is keyed
            // to the pane, not to its text, so a pane uncovered for the last
            // thing translated would otherwise show this clipboard's contents
            // in full, and the hot key opens the panel at exactly the moment a
            // shared screen would catch it. Assigned directly rather than
            // through the editor, so this text does not count as typed and
            // stays covered.
            privacy.conceal(TranslatePane.revealID)
            // And quiet with it. Setting the text below stops the voice only
            // when the text differs; the same text brought again left the
            // answer being read aloud from under the cover just drawn.
            translator.speaker.stop()
            // A standing Use Online press is for what is typed, never for
            // what the clipboard brings: a copied password or token would
            // otherwise go to MyMemory on a press made for other words, with
            // nobody looking (owner, 2026-10-26). The card asks again — "not
            // downloaded" and Use Online — for this text.
            translator.revokeOnlineRequest()
            translator.input = text
            // The text lands in the field, and the field is under the list while
            // History is up.
            translateShowsHistory = false
        }
        // After the text: setting `input` clears the notice.
        translator.notice = prepared.notice
        // Spoken too: the keyboard lands in the field, and VoiceOver reads the
        // field, not the line under it, so a blind user would hear the panel
        // open on an unchanged field and nothing about why.
        if let notice = prepared.notice { Announcer.shared.announce(notice) }
        choose(.translate)
    }

    /// Translate, from a Clipboard row's menu (spec §9.2): the entry's text goes
    /// where ⌃⌥⌘T and the service put theirs — through the same preparation
    /// (trimmed, capped, noticed) and the same landing on Translate.
    func translateClipboardText(_ text: String) {
        receiveCommandedTranslation(Translator.prepareCommandInput(text))
    }

    /// Every summons to a surface lands here — ⌃⌥⌘V, ⌃⌥⌘T, the menu, the
    /// gear. A surface that types takes the keyboard: asked for by name, a
    /// field one cannot type into is worse than briefly dimming the caret of
    /// the window underneath. The machinery's roads (`land(on:)`) and the
    /// pages' (`turnPage(to:)`) do not take it. The drop surface and the
    /// welcome are presented, never chosen, and are refused.
    ///
    /// Never the keyboard over the lock: typing there belongs to the password
    /// field, and a panel the lock lifted above the shield must not hold it.
    /// The tab model guarded Clipboard's search this way; R8's first cut of
    /// this function dropped the guard with the search toggle (R8 review).
    func open(_ surface: Surface) {
        guard surface != .drop, surface != .welcome else { return }
        self.surface = surface
        if surface.takesKeyboard, !isLockedPresentation { wantsKeyboard = true }
    }

    /// Where the island lands when nobody asked for typing: the pointer
    /// arriving, a click on the island, the welcome answered (§19.16). Since
    /// the bare notch opens the page last shown, that can be Clipboard or
    /// Translate, and landing there is not a summons — only ⌃⌥⌘V, ⌃⌥⌘T, the
    /// menu, a click into the field or focus moving into it (VoiceOver) take
    /// the keyboard. Through `open(_:)` these roads made a hover onto the bare
    /// notch, with Open on Hover off, open Clipboard holding the keyboard of
    /// the app being typed in (R8b review F1).
    func land(on surface: Surface) {
        guard surface != .drop, surface != .welcome else { return }
        self.surface = surface
    }

    /// Whether a press at `point` — body coordinates, down from the open
    /// body's top-left — asks for the keyboard (`NotchPanel.onPress`): only a
    /// press into the field of a surface that types, and never over the lock (§19.16: "or when their field is clicked").
    ///
    /// The field and nothing else. A row pressed to copy it, a dot, the gear,
    /// Swap or a language menu is an action or a way somewhere, not a request
    /// to type: with every press off the header and the dots asking, a row
    /// copied on a Clipboard the bare notch opened made the panel key on
    /// mouse-down, and a pinned panel kept it, so a ⌘V meant for the app
    /// underneath went into the search field (R8b review F2, re-review R2).
    /// While the pages move, the field is found where it is drawn: measured
    /// on the reach, a dot pressed on the way onto Clipboard asked
    /// (re-review R1), and refused for the whole leg, a click into a field
    /// that already looked still was lost (re-review N1).
    func pressClaimsKeyboard(atBodyPoint point: CGPoint) -> Bool {
        guard presented.takesKeyboard, !isLockedPresentation, let field = fieldFrame(of: presented) else {
            return false
        }
        guard let leg = travellingLeg else { return field.contains(point) }
        // On the way, the field is where the pages draw it: the press is read
        // against the drawn outline — centred in the clickable region, as the
        // outline is — and the field moves with its page, which may not be on
        // screen yet.
        guard let index = leg.strip.pages.firstIndex(of: presented), leg.mounted.contains(presented) else {
            return false
        }
        let drawn = drawnOpenBodySize
        let x = point.x - (openBodySize.width - drawn.width) / 2
        // The dots' row, not only their band: a dot's target is taller than
        // the band, and the card slid under its top on the way onto
        // Translate (R8b re-review P1).
        guard x >= 0, x < drawn.width, point.y < drawn.height - SurfaceLayout.dotsBand(for: presented),
              !PageDotsLayout.rowFrame(bodySize: drawn).contains(CGPoint(x: x, y: point.y)) else {
            return false
        }
        let paneX = leg.strip.x(ofPage: index, at: leg.position, outlineWidth: drawn.width)
        return field.offsetBy(dx: paneX, dy: 0).contains(CGPoint(x: x, y: point.y))
    }

    /// Where a surface's text field is, in body coordinates: Clipboard's
    /// search field, Translate's source card — the plate the text is typed
    /// on, its Clear and Paste included, both of which want the keyboard
    /// anyway. Nil for every other surface, and for Translate while its
    /// History list stands in place of the cards.
    func fieldFrame(of surface: Surface) -> CGRect? {
        // The panes are laid out in the content, which starts under the
        // header row, a notch tall.
        let header = geometry.notchSize.height
        switch surface {
        case .clipboard:
            return ClipboardHeader.searchField.offsetBy(dx: 0, dy: header)
        case .translate:
            guard !translateShowsHistory else { return nil }
            return TranslateLayout.sourceCard(bodyWidth: openSize(of: .translate).width).offsetBy(dx: 0, dy: header)
        default:
            return nil
        }
    }

    /// A page reached by a swipe, a dot or ⌃Tab (§19.16). Unlike `open(_:)`
    /// it never takes the keyboard: looking through the pages must not take
    /// typing away from the app in front, so Clipboard and Translate wait for
    /// a click into their field. Leaving a page that held the keyboard gives
    /// it back, Clipboard to Translate included — except by ⌃Tab, which only
    /// a panel holding the keyboard hears, and which keeps it
    /// (`turnPageByKey`). Refuses anything that is not a page.
    func turnPage(to page: Surface) {
        guard page.isPage else { return }
        surface = page
        if !isTurningByKey { wantsKeyboard = false }
    }

    // MARK: - Swiping between pages (§19.16)

    /// The four pages side by side at this display's sizes.
    func pageStrip() -> PageStrip {
        PageStrip(pages: Surface.pages, widths: Surface.pages.map { openSize(of: $0).width })
    }

    /// One scroll event over the open island, from `PageSwipeMonitor`:
    /// whether it was the pages' — swallowed — or is handed on to the page
    /// under the pointer. `over` is whether the pointer is over the pages.
    ///
    /// A release turns the page through `turnPage(to:)`, so a swipe never
    /// takes the keyboard and leaving a page gives it back; a swipe that goes
    /// back to where it began turns nothing and leaves the keyboard alone.
    func pageScroll(_ event: PageScroll, over: Bool) -> Bool {
        guard isOpen, !isLockedPresentation, presented.isPage else {
            pageSwipe = PageSwipe()
            return false
        }
        let leg = pageTravel.leg
        let strip = leg?.strip ?? pageStrip()
        let position = leg?.position ?? CGFloat(strip.pages.firstIndex(of: presented) ?? 0)
        let context = PageSwipe.Context(strip: strip, presented: position, over: over)
        switch pageSwipe.handle(event, context) {
        case .pass:
            return false
        case .swallow:
            return true
        case .grab(let position):
            let anchor = min(max(Int(position.rounded()), 0), strip.lastIndex)
            pageTravel.grab(
                strip: strip, position: position,
                reach: max(0, anchor - 1)...min(strip.lastIndex, anchor + 1)
            )
            return true
        case .move(let position):
            pageTravel.move(to: position)
            return true
        case .release(let target, let position, let velocity):
            pageTravel.move(to: position)
            let page = strip.pages[target]
            // `presented` as well: on the stage with no song the pages show
            // Music, and a swipe back to it turned the stage into Music, so a
            // song starting no longer showed its lyrics (R8b re-review N6).
            if page != surface, page != presented {
                // Outside the travel's still transactions, so the header's
                // title follows the page on the shell's own crossfade; the
                // pages themselves are drawn by the travel.
                isTurningByTravel = true
                turnPage(to: page)
                isTurningByTravel = false
            }
            pageTravel.settle(to: target, velocity: velocity, reduceMotion: SystemAppearance.shared.reduceMotion)
            return true
        }
    }

    /// One scroll event that landed on the panel, for the vertical pull: what
    /// the pull says, with its stretch drawn here. The controller swallows the
    /// event for anything but `.pass` and plays out an open, a close or a
    /// refusal — the panel's machinery is its, as a click's is.
    ///
    /// It runs beside `pageScroll`, not inside it: the pages hear events only
    /// while a page is open, and the pull is mostly for the shut island. The
    /// two cannot both take a gesture — the first 10 pt give it to one or the
    /// other, by its direction — so neither asks the other.
    func pullScroll(_ event: PageScroll, region: IslandPull.Region) -> IslandPull.Outcome {
        let context = IslandPull.Context(
            enabled: Self.swipeToOpenEnabled, isOpen: isOpen, locked: isLockedPresentation, region: region,
            surface: presented, travelling: pageTravel.leg != nil
        )
        let outcome = islandPull.handle(event, context)
        let reduceMotion = SystemAppearance.shared.reduceMotion
        switch outcome {
        case .stretch(let points):
            pullStretch.track(reduceMotion || isLockedPresentation ? 0 : points)
        case .open, .close, .refuse, .settle:
            pullStretch.settle(reduceMotion: reduceMotion)
        case .pass, .swallow:
            break
        }
        return outcome
    }

    /// A dot, VoiceOver's increment and decrement, ⌃Tab (§19.16): the page
    /// at once — the header and the gear follow it — and never the keyboard,
    /// while the pages travel there on the island's spring from where they
    /// are on screen. One page along travels the row; further travels a
    /// straight leg between the two pages alone, so the outline does not
    /// flicker through the sizes of the pages between. Under Reduce Motion
    /// nothing slides: the page is replaced in place, on the crossfade every
    /// pane swap has. Anything that is not a page, or not open, is refused.
    func travel(to page: Surface, reduceMotion: Bool) {
        // `presented` as well as `surface`: the stage with no song is drawn as
        // the empty player, whose own dot built a strip of two Music pages
        // (R8b review F3).
        guard isOpen, !isLockedPresentation, page.isPage, presented.isPage, page != surface, page != presented
        else { return }
        // Fingers on the pages lose them to the dot or the key: the rest of
        // their gesture would otherwise fight the travel frame by frame, and
        // its release turn somewhere else (R8b review F7).
        pageSwipe.yield()
        guard !reduceMotion else {
            pageTravel.finish()
            turnPage(to: page)
            return
        }
        let row = pageStrip()
        guard row.pages.contains(page) else { return }
        if let leg = pageTravel.leg, let index = leg.strip.pages.firstIndex(of: page) {
            pageTravel.aim(strip: leg.strip, from: leg.position, to: index, reduceMotion: false)
        } else if let leg = pageTravel.leg {
            // A second dot during a straight leg, for a page the leg does not
            // hold: the pages carry on from where they are. Ending the first
            // leg put the outline at the first dot's page in one frame (R8b
            // review F5).
            // Where their speed would carry them, as a swipe's release is
            // read: the page they are heading for, not the one they left.
            let heading = leg.strip.position(
                at: leg.strip.offset(of: leg.position) + PageSwipe.projection(
                    velocity: pageTravel.velocity * leg.strip.pointsPerPage(at: leg.position)
                )
            )
            switch leg.strip.joining(
                page, width: openSize(of: page).width, row: row.pages, at: leg.position, heading: heading
            ) {
            case .end(let strip, let shift):
                guard let index = strip.pages.firstIndex(of: page) else { return }
                pageTravel.aim(onto: strip, shift: shift, to: index, reduceMotion: false)
            case .via(let via):
                // From there a strip of the two alone, even when they are
                // neighbours: on the row, the pages' overshoot past `via`
                // showed the page beyond it, on the far side from where they
                // were going, for a few frames (R8b re-review P2).
                let start = leg.strip.pages[via]
                let pair = row.pages.filter { $0 == start || $0 == page }
                let strip = PageStrip(pages: pair, widths: pair.map { openSize(of: $0).width })
                guard let from = pair.firstIndex(of: start), let target = pair.firstIndex(of: page) else { return }
                pageTravel.aim(via: via, then: strip, from: from, to: target, reduceMotion: false)
            }
        } else {
            pageTravel.finish()
            let leg = straightLeg(from: presented, to: page)
            pageTravel.aim(strip: leg.strip, from: CGFloat(leg.from), to: leg.target, reduceMotion: false)
        }
        isTurningByTravel = true
        turnPage(to: page)
        isTurningByTravel = false
    }

    /// The leg a dot starts from `start` at rest: the row when `page` is
    /// beside it; otherwise a strip of the two alone, in the row's order, so
    /// the outline does not flicker through the sizes of the pages between.
    private func straightLeg(from start: Surface, to page: Surface) -> (strip: PageStrip, from: Int, target: Int) {
        let row = pageStrip()
        let a = row.pages.firstIndex(of: start) ?? 0
        let b = row.pages.firstIndex(of: page) ?? 0
        if abs(b - a) == 1 { return (row, a, b) }
        let pair = [row.pages[min(a, b)], row.pages[max(a, b)]]
        let strip = PageStrip(pages: pair, widths: pair.map { openSize(of: $0).width })
        return (strip, a < b ? 0 : 1, a < b ? 1 : 0)
    }

    /// One page along, as VoiceOver's increment and decrement and ⌃Tab turn
    /// them; nothing past either end.
    func adjustPage(by step: Int, reduceMotion: Bool) {
        guard let page = page(by: step) else { return }
        travel(to: page, reduceMotion: reduceMotion)
    }

    /// ⌃Tab and ⌃⇧Tab (§19.16): one page along while the panel has the
    /// keyboard, on the same travel a dot starts. Whether the press was the
    /// pages': false lets it through to whatever else has a use for it — a
    /// shortcut being recorded in Settings.
    ///
    /// Unlike a swipe or a dot, the turn keeps the keyboard, onto a page with
    /// no field too. The keyboard is what is turning the pages: a Shelf that
    /// gave it back would send the next ⌃⇧Tab to the app in front, to switch
    /// that app's tabs instead of the island's pages. Escape still folds the
    /// panel from there. Past either end the press is swallowed and nothing
    /// turns: the pages do not wrap, and ⌃Tab let through to a field would
    /// move its caret to a key view nobody can see.
    func turnPageByKey(_ step: Int, reduceMotion: Bool) -> Bool {
        guard wantsKeyboard, isOpen, !isLockedPresentation, presented.isPage else { return false }
        guard let page = page(by: step) else { return true }
        isTurningByKey = true
        travel(to: page, reduceMotion: reduceMotion)
        isTurningByKey = false
        return true
    }

    /// The pages taken from under a gesture — files dragged to the notch or
    /// the welcome laid over them, or a song arriving on the stage drawn as
    /// Music's page: the gesture ends and the pages go to rest, so they are
    /// not found half way, with the clickable region cut over them, once the
    /// page is back (R8b review F6, re-review R3). The swipe monitor is
    /// removed with the pages, so the release that would have ended it never
    /// comes.
    func endPageGesture() {
        pageSwipe = PageSwipe()
        pageTravel.finish()
    }

    /// Where the person was among the pages: the page the bare notch opens,
    /// and where the lit gear goes back to. A display change builds a new
    /// view model, and both went with the old one (R8b review F9).
    struct Place: Equatable {
        var lastPage: Surface
        var settingsReturn: Surface?
    }

    var place: Place { Place(lastPage: lastPage, settingsReturn: settingsReturn) }

    /// Carries `place` over from the view model a rebuild replaced. After the
    /// surface is restored: restoring Settings records the fresh model's
    /// default as where the gear goes back to, and this writes over it.
    func restorePlace(_ place: Place) {
        lastPage = place.lastPage
        settingsReturn = place.settingsReturn
    }

    /// The page `step` places along from the one presented, or nil past
    /// either end — the pages do not wrap — or when what is presented is not
    /// a page (the stage, Settings, the drop surface, the welcome).
    func page(by step: Int) -> Surface? {
        guard let index = presented.pageIndex else { return nil }
        let next = index + step
        guard Surface.pages.indices.contains(next) else { return nil }
        return Surface.pages[next]
    }

    /// The gear (§19.16): Settings from a page or the stage, and from Settings
    /// — where it is the close button — back to where Settings was opened
    /// from. Going back to a page is a page turn, so it does not take the
    /// keyboard.
    func pressGear() {
        guard surface == .settings else {
            open(.settings)
            return
        }
        let back = settingsReturn ?? lastPage
        if back == .stage {
            surface = .stage
        } else {
            turnPage(to: back.isPage ? back : lastPage)
        }
    }

    /// Settings, on `section`. The section goes first so the pane that appears
    /// for the change finds it already selected; every route in — the player's
    /// remedy, the lyric menu's "Lyrics Settings…", the menu — is this.
    func openSettings(at section: SettingsSection) {
        settingsSection = section
        open(.settings)
    }

    /// The player's remedy when Music Only keeps a playing source off the
    /// island: Settings, on the Music section, where Music Only is the first
    /// switch that is not a failure.
    func openMusicOnlySetting() {
        openSettings(at: .music)
    }

    /// "Lyrics Settings…" in the More menu (spec §5.2): Settings, on the Lyrics
    /// section (R4 gave the lyric switches a section of their own; until then
    /// they were rows of Music's and this pointed at the Music section's top).
    func openLyricsSettings() {
        openSettings(at: .lyrics)
    }

    /// Whether a pane wants this Escape for itself. Consulted before the panel
    /// folds, so that Escape cancels the nearest thing first and only the
    /// press after that, with nothing left to cancel, closes the panel.
    ///
    /// An armed two-press confirmation goes first (owner decision 3): Escape
    /// is cancel on macOS, and it used to fold the panel around a red "Clear
    /// Everything" instead of taking the question back. Disarming loses
    /// nothing.
    ///
    /// Then the text being typed into Translate, which this clears — the way
    /// a search field and Spotlight spend a first Escape (owner decision 15).
    /// That one is not reversible: there is no undo for the cleared field, and
    /// an earlier version of this comment said otherwise.
    func consumeEscape() -> Bool {
        if ArmedConfirmations.shared.disarmAll() { return true }
        switch presented {
        // An open History list is the nearest thing to cancel (spec §11); the
        // text under it is untouched.
        case .translate where translateShowsHistory:
            translateShowsHistory = false
            return true
        case .translate where !translator.input.isEmpty:
            translator.reset()
            return true
        // A search takes the first Escape and the next one closes (spec
        // §19.8), so Escape in a field with words in it means "stop searching".
        case .clipboard where !clipboardBrowser.query.isEmpty:
            clipboardBrowser.clearQuery()
            return true
        default:
            return false
        }
    }

    /// What a list key did (`consumeListKey`).
    enum ListKeyOutcome: Equatable {
        /// Not this surface's key: it goes on to the field.
        case ignored
        case handled
        /// Taken, and the panel closes: Return copied the row.
        case handledAndClose
    }

    /// ↑, ↓ and Return on Clipboard (spec §19.8): the arrows move the
    /// selection through what the list shows, stopping at either end, and
    /// Return copies the selected row and closes the panel. Every other
    /// surface lets the key through.
    func consumeListKey(_ key: NotchPanel.ListKey) -> ListKeyOutcome {
        guard presented == .clipboard else { return .ignored }
        let listing = ClipboardBrowser.listing(
            of: clipboard.items, filter: clipboardBrowser.filter, query: clipboardBrowser.query,
            isHidden: { [privacy] in privacy.hides(.clipboard, $0.id.uuidString) }
        )
        // The Images grid draws no selection, so the keys are not its own:
        // they moved one nobody could see, and Return copied a picture nobody
        // chose and closed (R8 review F5). The same test `ClipboardPane` draws
        // the grid by; a search shows rows again.
        if clipboardBrowser.filter == .images, !listing.isSearch { return .ignored }
        switch key {
        case .up:
            clipboardBrowser.selection = ClipboardBrowser.moved(-1, in: listing, selection: clipboardBrowser.selection)
            return .handled
        case .down:
            clipboardBrowser.selection = ClipboardBrowser.moved(1, in: listing, selection: clipboardBrowser.selection)
            return .handled
        case .enter:
            // A standing question — Clear All's bar — is answered by its own
            // buttons or Escape; Return copying and closing behind it left
            // the question unanswered and the panel gone.
            guard !clipboardClear.isAsking,
                  let index = ClipboardBrowser.selectedIndex(in: listing, selection: clipboardBrowser.selection) else {
                return .handled
            }
            // A picture whose file is gone copies nothing and leaves the
            // list: the panel stays, on what is left.
            guard clipboard.copy(listing.items[index]) else { return .handled }
            Announcer.shared.announce(localized("Copied"))
            // Return copies and closes in one press, so the row's own tick is
            // gone with the panel: the island, once shut, is the one place
            // left to say it. Posted now, with the panel still open, it waits
            // its second in the queue and shows as the panel folds.
            confirm(.copied)
            return .handledAndClose
        }
    }

    /// ⇧⌘C, asked by the panel before the source field gets the key (H-018).
    /// Returns false when there is no translation on screen — another surface, or
    /// no answer yet — and the key falls back to an ordinary copy.
    ///
    /// An answer to text since edited claims the key and copies nothing: the
    /// Copy button is disabled in that window (K-004), and the key does what
    /// the disabled button does rather than quietly copying the source in the
    /// translation's place.
    ///
    /// Announced here rather than by the button, which only speaks for its
    /// own presses; the button still ticks, through `outputCopies`.
    func copyTranslationIfShowing() -> Bool {
        guard presented == .translate, !translator.output.isEmpty else { return false }
        if translator.copyOutput() {
            Announcer.shared.announce(localized("Copied"))
        }
        return true
    }
}
