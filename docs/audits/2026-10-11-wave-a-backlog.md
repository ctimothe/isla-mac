# Wave A backlog (static audit)

Produced 2026-10-11 by seven Sonnet auditors against the apple-design skill, a 96-item checklist harvested from Apple's published guidance, and the project contract, then merged and verified by an Opus principal who read the cited code. 55 findings stand (8 P1, 22 P2, 25 P3), 12 were refuted or merged, 24 contradict a recorded project decision and wait for the owner. "Needs live check" marks what only a running app can settle. Severity: P0 broken or unsafe, P1 clearly un-native or user-visible defect, P2 polish, P3 nit.

## Clusters

- **privacy-cover** (3): Translate cover leaves the output visible and blinds typing; the default-on capture exclusion rests on sharingType alone and needs proof on macOS 15+ (F-002, F-008, F-021).
- **shelf-integrity** (10): Shelf cards are lost or orphaned (unmounted volumes, 7-day inbox prune, Move drags, the 60-card cap), opening it blocks on disk, and its actions and drag image are below par (F-001, F-019, F-020, F-022, F-035, F-037, F-038, F-050).
- **a11y-voiceover** (6): Clipboard rows and Shelf cards are unusable with VoiceOver, nothing is ever announced, and several controls lack labels or actions (F-005, F-006, F-013, F-029, F-030, F-036).
- **lock-card** (6): Legibility over pale covers and over unsampled glass, an empty window on every lock, a dead seek bar at duration 0, and a five-device output cap (F-003, F-012, F-026, F-031, F-032).
- **lyrics-clock** (4): Wrong 'Lyrics are off' status for zero-length tracks, compressed LRC rejected, duplicate row ids on equal timestamps, karaoke edge lagging the clock (F-007, F-009, F-010, F-011).
- **keyboard-shell** (4): Escape and Command-Tab do not end a pinned panel, no reopen or single-instance handling, intents that toggle, layout-dependent edit shortcuts (F-004, F-023, F-024, F-039).
- **hit-targets** (2): Sub-20 pt targets and drags that lose capture at the panel edge (F-014, F-028).
- **motion-reduce** (4): Reduce Motion gaps (tab scale, cover morph, cuts) and a refusal shake that likely never plays or replays (F-017, F-018, F-046, F-055).
- **perf-idle** (7): 10 Hz clock and whole-object observation on every tab, a 20 Hz clipboard timeline, main-thread lyric rescans, full-size artwork, volume-drag churn, and an unreconciled wake-up figure (F-015, F-016, F-043, F-044, F-045, F-054).
- **system-lifecycle** (4): AppleScript without timeouts, an unguarded Music relaunch, ambient moments that resurface or overwrite, a launch-only synthetic notch recheck (F-025, F-033, F-041, F-047).
- **feedback-errors** (6): Silent or misleading outcomes: Launch at Login, About behind other windows, AirDrop beep, Delete These Files race, empty-clipboard hot key, unbounded online translation (F-027, F-034, F-040, F-042, F-048, F-049).
- **contrast-type** (3): Smaller contrast and type defects on chips, the accent-filled picker glyph, and bold credits (F-051, F-052, F-053).

## Findings

### F-001 Unmounting a drive or network volume permanently erases every Shelf card on it
P1 · shelf-integrity · verified by principal: yes

- Evidence: ShelfStore.swift:238-245 isGone() returns true for NSFileReadNoSuchFileError, which a path under an unmounted /Volumes/X returns; refreshFromDisk (:180-205) removes those cards and persist()s; bookmarks resolve with .withoutMounting (:149-153) so they fall back to the bare path.
- Scenario: User parks files from an external SSD or SMB share, ejects it, opens the Shelf: cards vanish, and remounting does not bring them back.
- Fix direction: Treat a card whose volume root is not mounted as offline (keep, dim), evict only when the volume is present and the file missing; add a ShelfStoreTests case for a nonexistent /Volumes root.
- Verification: Read ShelfStore.swift:140-265.

### F-002 Translate privacy cover hides the source but shows the translation in full
P1 · privacy-cover · verified by principal: yes

- Evidence: TranslatePane.swift:26-27 covered = privacy.hides(.translate,'translate.source'); result()/outcome() (:133-183) render translator.output with no privacy check. ⌃⌥⌘T fills the source from the clipboard.
- Scenario: Translate cover on, user runs a copied secret through the hot key during a screen share: source is dust, the right column shows the translated secret in 15-27 pt type.
- Fix direction: Cover the output column with the same SpoilerField under the same reveal id; one reveal uncovers both.
- Verification: Read TranslatePane.swift:15-190.

### F-003 Lock card text drops to about 1.6-2.4:1 over a pale album cover
P1 · lock-card · verified by principal: yes

- Evidence: LockScreenCard.swift:209-235 coverLight: cover blurred, saturation 1.3, black 0.34 (0.2 in Transparent at layer opacity 0.62), bottom gradient to 0.22. Card tokens: cardSecondary 0.62, cardTertiary 0.50 (Theme.swift:385-394). Near-white cover: backdrop about 168 grey, white 2.4:1, cardSecondary about 1.8:1, cardTertiary about 1.6:1. Comment claims it is 'dimmed so white type holds over the palest one'. ContrastRampTests measure against black only.
- Scenario: A white or pastel cover on the lock screen: elapsed/remaining times, artist line, lyric status and dim lyric lines are close to unreadable; only a 3 pt shadow helps.
- Fix direction: Raise the wash to a floor that holds 4.5:1 for cardSecondary over a white source (or scale it by measured cover luminance), and extend ContrastRampTests to compute against the brightest permitted backdrop.
- Verification: Read LockScreenCard.swift:140-235 and Theme.swift:380-400; recomputed the ratios.

### F-004 Escape does nothing on a panel opened from the keyboard outside Translate, and Command-Tab leaves it up
P1 · keyboard-shell · verified by principal: yes

- Evidence: NotchPanel.swift:28 canBecomeKey == acceptsKeyboard (false unless a typing tab asked); Escape is read only in sendEvent (:81-95), which needs key status. NotchController.swift:661-665 and :875-879 promise 'Escape folds the panel from any tab'. Pinned opens (toggle() :666-695, Show Isla intent, toggleLyrics) end only on the same hot key or a click in another app (global monitor :734-759); no didActivateApplication observer.
- Scenario: User presses ⌃⌥⌘I, reads Music, presses Escape: the key goes to the app underneath and the panel stays over the menu bar until the hot key or a mouse click.
- Fix direction: While pinned, register a transient Escape hot key (Carbon, no permission) or make the pinned panel key; close a pinned panel on NSWorkspace.didActivateApplicationNotification.
- Verification: Read NotchPanel.swift whole, NotchController.swift:655-760, 870-915, 1070-1090.

### F-005 VoiceOver reads every clipboard row as 'Copy Entry' and cannot remove or reveal one
P1 · a11y-voiceover · verified by principal: yes

- Evidence: ClipboardPane.swift:111-117 .accessibilityElement(children: .combine) then .accessibilityLabel('Copy Entry') replaces the combined text; Remove (:77-94) and the reveal eye exist only on hover and carry no accessibility action.
- Scenario: VoiceOver user opens Clipboard: 20 rows read 'Copy Entry, button'; they cannot tell entries apart, delete one, or reveal a covered one.
- Fix direction: Label with the preview (or 'Hidden' when covered), keep Copy as the default action, add named actions Remove and Reveal.
- Verification: Read ClipboardPane.swift:100-120.

### F-006 Shelf cards expose no accessibility element, label or action
P1 · a11y-voiceover · verified by principal: yes

- Evidence: ShelfPane.swift: the only accessibility modifier is on the hover-only remove button (:208); select/open/drag live in the ShelfDragSource NSView overlay (ShelfDragSource.swift:32-103) with no accessibility overrides; Quick Look, AirDrop, Copy, Show in Finder only in contextMenu (:213-221).
- Scenario: VoiceOver user cannot select, open, Quick Look, AirDrop or remove a card; name and age are not announced as one element.
- Fix direction: Make each card one element (label name, value age plus selection, isSelected trait) with actions Open, Quick Look, AirDrop, Copy, Show in Finder, Remove independent of hover.
- Verification: Grepped ShelfPane.swift and ShelfDragSource.swift for accessibility.

### F-007 Lyrics say 'Lyrics are off.' and offer a dead 'Show Lyrics' button for any track with no length
P1 · lyrics-clock · verified by principal: yes

- Evidence: LyricsCoordinator.swift:221 guard ... duration > 0 else availability = .disabled; LyricsPresentation.swift:19-21 maps .disabled to 'Lyrics are off.' and :54-55 to Offer.turnOnLyrics; NotchViewModel.swift:383-386 turnOnLyrics only rewrites the already-true key and refreshVisibility hits the same guard. MediaPane compactLyricsStatus shows the caption unconditionally.
- Scenario: Lyrics on; a live stream or browser audio with duration 0 plays: caption says lyrics are off and the stage's 'Show Lyrics' does nothing.
- Fix direction: Add an availability for 'cannot look up' (no duration) with honest copy and no offer; never map it to .disabled.
- Verification: Read LyricsCoordinator.swift:200-250, LyricsPresentation.swift:1-70, NotchViewModel.swift:375-392, MediaPane.swift:520-575.

### F-008 Hide from Screen Recording relies only on sharingType = .none, which may not exclude the panel from ScreenCaptureKit on macOS 15+
P1 · privacy-cover · verified by principal: no · needs live check

- Evidence: NotchPanel.swift:163-168 is the whole mechanism; default on with the justification 'a password read out to a meeting' (NotchViewModel.swift:894-905); the lock card is also a NotchPanel.
- Scenario: If the OS ignores sharingType for ScreenCaptureKit capture, a user sharing their screen with Clipboard open trusts a default-on switch that does nothing.
- Fix direction: Test on macOS 26.6 and 27 with QuickTime and a ScreenCaptureKit app; if it leaks, reword the setting and stop promising, or auto-cover Clipboard/Translate while a capture is detected.
- Verification: Read NotchPanel.swift:160-168 and the default; the code fact is confirmed, the OS behaviour cannot be settled from code. Kept P1 because it is a default-on privacy promise.

### F-009 Compressed LRC (several timestamps on one line) is rejected as invalid, locally and from LRCLIB
P2 · lyrics-clock · verified by principal: yes

- Evidence: LocalLyricsDocument.swift:89-94 compares each timestamp to the previous one across lines and throws invalidTimestamp, so '[00:10][01:30]Chorus' then '[00:20]Verse' fails. OnlineLyrics.swift:99,227 parse LRCLIB synced text with try?, so the same file is silently a miss. Caption becomes 'No lyrics for this track.' with no reason.
- Scenario: A standard LRC with a stacked chorus line is refused entirely.
- Fix direction: Collect all (timestamp, text) pairs, stable-sort, then validate; surface the parse failure reason in the stage.
- Verification: Read LocalLyricsDocument.swift:60-100; grepped parser call sites.

### F-010 Lyric stage keys rows and scroll position by timestamp, so equal timestamps share one id
P2 · lyrics-clock · verified by principal: yes

- Evidence: LyricsStage.swift:244 ForEach(..., id: \.element.at), :247 .id(line.at), :254 scrollPosition(id:), :284 reading = lines[anchor].at. Parser accepts equal stamps (strict < check) and multi-stamp lines; cleaned() does not dedupe.
- Scenario: Bilingual LRC (original plus translation at one time) or duplicated stamps: rows drawn twice or skipped, scroll anchor ambiguous, lock card (index ids) disagrees with the stage.
- Fix direction: Key rows and scrollPosition by index (or an id minted at parse), or merge same-time lines into one two-row line.
- Verification: Read LyricsStage.swift:238-290 and the parser.

### F-011 Karaoke sweep animates over 0.25 s while the clock ticks every 0.1 s, so the lit edge trails the voice
P2 · lyrics-clock · verified by principal: yes · needs live check

- Evidence: KaraokeText.swift:108 .linear(duration: 0.25) with the comment 'one tick of the position ticker'; MediaController.swift:330 positionTickInterval = 0.1. Each tick retargets before the last finishes; steady-state gap about 2.5 ticks of motion. Sync gate (MotionValuesTests) measures the clock, not the drawn edge; comments in KaraokeText, LyricsStage:321 and KaraokeTextTests still describe the 4 Hz ticker.
- Scenario: Word-timed lyrics: the lit edge reaches each word noticeably after the singer while line changes are on time.
- Fix direction: Use .linear(duration: MediaController.positionTickInterval) or drive the edge from TimelineView; assert duration <\= tick in a test; re-run Scripts/measure-sync.sh since the 0.20 s lead may have been calibrated against the old lag.
- Verification: Read KaraokeText.swift:95-110 and MediaController.swift:325-335.

### F-012 Lock card with no cover uses system glassEffect above the shield, contradicting the checklist's 'drawn recipe' record
P2 · lock-card · verified by principal: yes · needs live check

- Evidence: LockScreenCard.swift:149-163 passes samplesBackdrop: style != .solid && media.artwork == nil and no preferDrawn; GlassSurface.swift usesSystemGlass then returns true on macOS 26. checklist.md (Lock-screen card entry) says 'no window above it is given a backdrop to blur, so the glass is a drawn recipe'. NotchViewModel.swift:840-851 calls the question unsettled.
- Scenario: Track with no artwork on a bright lock wallpaper: white type on whatever glassEffect renders with nothing to sample.
- Fix direction: Check on a locked macOS 26 Mac; if it reads wrong pass preferDrawn: true for the card and raise the drawn trailing base; then make code and checklist agree.
- Verification: Read LockScreenCard.swift:140-235, GlassSurface.swift:195-290, checklist.md:99-108.

### F-013 Nothing is ever announced to VoiceOver: peeks, charger/headphones moments, lock-card track change, armed confirmations, copy ticks, locked-island refusal
P2 · a11y-voiceover · verified by principal: yes

- Evidence: No NSAccessibility.post / AccessibilityNotification / announcement in Sources (grep). Peek and ambient last 2.2 s (NotchController.swift:1320,1367); compact island VoiceOver action silently returns while locked (NotchContentView.swift:580-583); ConfirmTextButton arms with no announcement (Confirmation.swift:64-87); CopyButton label stays 'Copy'.
- Scenario: VoiceOver user plugs in a charger, skips a track on the lock card, or presses Clear: sighted users get a visible answer, they get silence.
- Fix direction: One small Announcer helper posting announcementRequested for ambient label, new title, 'Press again to clear', 'Copied', 'Unlock to open'; rate-limit like the peek.
- Verification: Grepped Sources; read NotchContentView.swift:565-590, Confirmation.swift:60-90, NotchController.swift:1280-1372.

### F-014 Several controls have hit regions under 20 pt: swap 18x14, text buttons Clear/Deselect/remedies, 14 pt scrubber strip, 14 pt language-menu row
P2 · hit-targets · verified by principal: yes

- Evidence: TranslatePane.swift:313 frame(18,14); :370 column header row height 14; Confirmation.swift:77-82 caption Text label with no frame or contentShape (Clear in ShelfPane.swift:107, ClipboardPane.swift:45); ShelfPane.swift:102-105 Deselect same; MediaPane.swift:365 and LockScreenCard.swift:657 scrub strip height 14.
- Scenario: Clearing the Shelf, swapping languages or seeking requires landing a 10-14 pt target at the screen's top edge; near misses do nothing or copy a clipboard row.
- Fix direction: Give PanelButtonStyle a minimum hit frame with contentShape (about 24x20), grow the scrub strip to 22 pt with the same drawn bar.
- Verification: Read TranslatePane.swift:305-375, Confirmation.swift:60-90, MediaPane.swift:340-370, ShelfPane.swift:98-112.

### F-015 Media clock ticks 10 Hz on every tab and on the lock card, and every MediaController observer (SettingsPane included) re-evaluates on each tick
P2 · perf-idle · verified by principal: yes

- Evidence: NotchController.swift:1177 setActive(true) on every open regardless of tab; MediaController.swift:2065-2079 ticker gated on isPlaying && isActive only; position is @Published (:21) and tick() writes it every 0.1 s; SettingsPane.swift:12 @ObservedObject media but reads only fallbackReason (:240). Precision AppleScript poll (1 Hz) gated on the Settings switch, not a visible lyric surface (:698,714).
- Scenario: Panel left open on Shelf, Clipboard or Settings while Spotify plays: 10 whole-pane evaluations per second and one Apple event into Spotify per second for nothing on screen.
- Fix direction: Split position/label into a small PlaybackClock observed only by scrubber, caption and lyric views; run the ticker only when the music pane or a lyric surface is visible; gate the precision poll on a visible lyric surface.
- Verification: Read MediaController.swift:18-22, 692-730, 2055-2092; NotchController.swift:1170-1180; grepped SettingsPane media use.

### F-016 Clipboard tab runs a 20 Hz TimelineView even when no row is covered
P2 · perf-idle · verified by principal: yes

- Evidence: ClipboardPane.swift:27 wraps the list in SpoilerClock unconditionally; SpoilerClock.swift:19 TimelineView(.animation(minimumInterval: 1/20)) whenever Reduce Motion is off. Privacy covers default off.
- Scenario: Clipboard open with covers off: 20 update transactions per second for an unchanging list.
- Fix direction: Pass an active flag (privacy.covers(.clipboard) and any visible row hidden) and render content directly otherwise.
- Verification: Read ClipboardPane.swift:20-35 and SpoilerClock.swift:1-35.

### F-017 Tab switch keeps its 0.97/1.02 scale under Reduce Motion
P2 · motion-reduce · verified by principal: yes

- Evidence: NotchContentView.swift:848-857 builds .opacity.combined(with: .scale(...)) inline instead of Theme.scaleIn(_:reduceMotion:) (Theme.swift:134), which exists for exactly this.
- Scenario: Reduce Motion on: every tab switch still zooms.
- Fix direction: Use opacity only when reduceMotion; add a test beside MotionValuesTests.
- Verification: Read NotchContentView.swift:843-860 and Theme.swift:120-136.

### F-018 Locked-island refusal shake probably never plays, and cannot replay on a second click
P2 · motion-reduce · verified by principal: yes · needs live check

- Evidence: The locked branch carries .transaction { $0.animation = nil } (NotchContentView.swift:139-140) above lockedPill, whose .refusalShake (:200) plays via withAnimation in RefusalShake.swift:33; only implicit .animation declared beneath survives, per the file's own comment. Separately RefusalShake.swift:32-33 writes progress = 0 then animates to 1 in one pass, so from a resting 1 there is no net change to animate; ShakeOffset returns identity at progress 1 (:51).
- Scenario: Mac locked with music, user clicks the pill: likely no motion at all; at best the first click shakes and later ones do not. Tests only count lockedHoverNudges.
- Fix direction: Drive the shake with keyframeAnimator(trigger:) or a phase toggle, and verify under the nil transaction on a locked Mac.
- Verification: Read RefusalShake.swift whole and NotchContentView.swift:120-205. The 0-then-1 coalescing is reliable SwiftUI behaviour; the ancestor-transaction effect needs a live look.

### F-019 Mail/Photos drops are trashed after seven days while the Shelf still shows their card
P2 · shelf-integrity · verified by principal: yes

- Evidence: NotchStores.swift:80 runs AppPaths.pruneDropInbox() every launch; AppPaths.swift:62-72 trashes Dropped/<uuid> folders older than 7 days by modification date, with no check against live shelf cards; refreshFromDisk then drops the card (isInTrash).
- Scenario: A Mail attachment kept on the Shelf for a project disappears into the Trash after a relaunch eight days later, with no notice.
- Fix direction: Pass the shelf's live URLs to the prune and skip referenced folders.
- Verification: Read AppPaths.swift:45-75 and the call site.

### F-020 Dragging a card out offers Move; Finder moves the original and the card keeps a dead path
P2 · shelf-integrity · verified by principal: yes

- Evidence: ShelfDragSource.swift:89-93 source mask [.copy,.move,.link,.generic] outside the app; draggingSession(_:endedAt:operation:) (:95-102) ignores the operation; the store refreshes only on Shelf entry.
- Scenario: Drag a screenshot from the Shelf into a same-volume Finder folder: the file moves, the card stays, and double-click/Quick Look/drag on it fail silently.
- Fix direction: On a .move result re-resolve the dragged URLs through their bookmarks or remove them; whether Move should be offered at all is an owner decision (see decisions).
- Verification: Read ShelfDragSource.swift:38-103.

### F-021 With the Translate cover on, the field goes invisible on the first typed character
P2 · privacy-cover · verified by principal: yes

- Evidence: TranslatePane.swift:24-27 covered = hides(...) && !translator.input.isEmpty; the TextEditor gets .opacity(covered ? 0 : 1) (:92) while still focused, and the SpoilerField overlay takes the click to reveal.
- Scenario: Cover on, user types a sentence: everything after the first letter is dust; clicking to place the caret reveals instead.
- Fix direction: Do not cover while the field holds the keyboard; cover on resign.
- Verification: Read TranslatePane.swift:20-125.

### F-022 Opening the Shelf does disk and network checks on the main thread and re-requests every thumbnail
P2 · shelf-integrity · verified by principal: yes · needs live check

- Evidence: ShelfStore.swift:180-205 refreshFromDisk (called on every Shelf entry) scans capture folders, calls checkResourceIsReachable per card on the main actor, then items.forEach(loadThumbnail) for all cards even if already rendered; each completion is a @Published write the whole panel observes.
- Scenario: A card on a sleeping disk or half-dead SMB share stalls the Shelf open; 60 cards cause 60 whole-panel invalidations during the tab transition.
- Fix direction: Move scan and reachability off main and apply once; skip thumbnails already rendered; batch completions.
- Verification: Read ShelfStore.swift:170-265; stall duration not measurable from code.

### F-023 No reopen handler and no single-instance guard
P2 · keyboard-shell · verified by principal: yes

- Evidence: No applicationShouldHandleReopen and no NSRunningApplication bundle-id check in Sources (grep); AppDelegate.applicationDidFinishLaunching (AppDelegate.swift:18-101). Memory notes three Islas registered on 2026-09-21.
- Scenario: Opening Isla from Spotlight while it runs does nothing visible; a second copy draws a second island, a second helper and fights for hot keys and the Spotify callback.
- Fix direction: applicationShouldHandleReopen opens the panel; at launch, exit if another instance with the bundle id is running.
- Verification: Grepped App/ and Sources.

### F-024 'Show Isla' and 'Show Lyrics' intents toggle, so running them on an open panel hides it
P2 · keyboard-shell · verified by principal: yes

- Evidence: IslaIntents.swift:69 toggleLyrics(), :82 toggle(); toggleLyrics folds the page when already up (NotchController.swift:522-525); toggle() closes an open panel.
- Scenario: A Shortcut or Focus automation titled Show Isla runs while the panel is open and closes it.
- Fix direction: Add open-only show()/showLyrics() entry points for the intents; keep toggles for hot keys.
- Verification: Read IslaIntents.swift:55-85 and NotchController.swift:515-530.

### F-025 AppleScript runs on one serial queue with no timeout
P2 · system-lifecycle · verified by principal: yes

- Evidence: PlayerBridge.swift:471-501 executeAndReturnError with no 'with timeout'; grep finds none. Precision poll runs 1 Hz into Spotify while lyrics are on; shuffle/repeat/modes and track-id lookups share the queue.
- Scenario: Spotify or Music beachballs: an in-flight script waits up to the default Apple event timeout (about 2 min) and every scripted control queues behind it.
- Fix direction: Wrap generated scripts in 'with timeout of 2 seconds' and map -1712 to the existing unknown reply.
- Verification: Read PlayerBridge.swift:465-505.

### F-026 Lock card window, AudioWatch and CoreAudio listeners are created on every lock, even with nothing playing
P2 · lock-card · verified by principal: yes · needs live check

- Evidence: NotchController.swift:256-262 calls lockCard.present unconditionally; LockCardWindow.swift:94-96 starts an AudioWatch; LockScreenCard body renders nothing when media.track is nil (:124); the panel sets ignoresMouseEvents = false and LockCardRootView.hitTest (:197-203) returns super.hitTest for the whole 460x300 card rect at display centre.
- Scenario: Lock with no music: an invisible window at screen centre may swallow clicks on the shield there, and CoreAudio listeners run for the whole lock.
- Fix direction: Present only while a track exists (and on track arrival during a lock); return nil from hitTest when there is no card content.
- Verification: Read NotchController.swift:225-262 and LockCardWindow.swift whole. Downgraded from P1: whether a click there matters depends on where the login UI sits, which needs a live look.

### F-027 Launch at Login failure is silent; 'requires approval' snaps the switch back to off
P2 · feedback-errors · verified by principal: yes

- Evidence: SettingsPane.swift:631-646 logs the error and re-reads status == .enabled; .requiresApproval reads as off with no message.
- Scenario: User turns it on, macOS wants approval in Login Items, the switch flips back with no explanation.
- Fix direction: On .requiresApproval show a note row with a button to SMAppService.openSystemSettingsLoginItems(); other errors show the reason inline.
- Verification: Read SettingsPane.swift:625-650.

### F-028 Dragging a scrubber or Settings slider past the panel edge makes the window click-through and can fold the panel mid-drag
P2 · hit-targets · verified by principal: yes · needs live check

- Evidence: PointerWatcher.swift:205 interactive = isDragging() || interactiveRect.contains(point); NotchController.swift:984-987 sets ignoresMouseEvents from it; isDragging (:948-950) covers file drags, shelf drags and menus only. interactiveRect has no margin; Panel Width/Hover Delay commit only on onEditingChanged(false).
- Scenario: Overshooting the scrub knob or the Panel Width slider: mouse events may go to the app underneath and the panel folds 0.32 s later, discarding the slider change.
- Fix direction: Latch 'button down inside the panel' from NotchPanel.sendEvent (leftMouseDown to leftMouseUp) into isDragging().
- Verification: Read PointerWatcher.swift:195-215 and NotchController.swift:940-990, 1450-1465; whether AppKit keeps delivering a captured drag after ignoresMouseEvents flips needs a live check.

### F-029 Lyric timing reset is a long-press with no accessibility action
P2 · a11y-voiceover · verified by principal: yes

- Evidence: LyricsStage.swift:468-478 onLongPressGesture on the offset Text with .accessibilityHint('Reset lyric timing') and no action.
- Scenario: VoiceOver or Switch Control user hears a hint for an action they cannot perform.
- Fix direction: Add .accessibilityAction(named: 'Reset lyric timing') and a context-menu item; keep the long press for pointers.
- Verification: Read LyricsStage.swift:466-482.

### F-030 Translate source field has no accessibility label or placeholder
P2 · a11y-voiceover · verified by principal: yes

- Evidence: TranslatePane.swift:91-123 TextEditor with no accessibilityLabel and no placeholder overlay.
- Scenario: VoiceOver announces an unnamed text area; an empty field is a blank dark rectangle.
- Fix direction: accessibilityLabel('Text to translate') plus a faint placeholder while empty (en/ru keys).
- Verification: Read TranslatePane.swift:85-125.

### F-031 Lock card draws a dead seek bar at 0:00 / -0:00 when the track has no length
P3 · lock-card · verified by principal: yes

- Evidence: LockScreenCard.swift:633-660 draws the bar and labels with no duration > 0 guard (handlers just return); MediaPane.swift:180-185 deliberately hides the scrubber in the same state.
- Scenario: Live stream on the lock screen: a full-width bar that does not respond.
- Fix direction: Match the panel: no bar (keep spacing) when duration <= 0.
- Verification: Read LockScreenCard.swift:625-660 and MediaPane.swift:175-187.

### F-032 Lock card output picker shows only the first five devices
P3 · lock-card · verified by principal: yes · needs live check

- Evidence: LockScreenCard.swift:520 ForEach(outputs.prefix(5)) with no scroll or 'more'; the current device may be outside the five.
- Scenario: Six or more outputs (virtual drivers are common): later devices, possibly the current one, cannot be chosen from the lock card.
- Fix direction: Always include the current device, cap by available height and scroll the rest.
- Verification: Read LockScreenCard.swift:515-555. Compact-card overflow not checked.

### F-033 Charger/headphones moment is not cleared when the panel opens, so it resurfaces on close; a second moment replaces the first
P3 · system-lifecycle · verified by principal: yes

- Evidence: clearAmbient only at NotchController.swift:86 and :195; presentAmbient (:1332-1368) cancels ambientWork and overwrites vm.ambient; closed header shows ambientHeader whenever vm.ambient != nil (NotchContentView.swift:404-409). Timers are fixed 2.2 s with no hover pause.
- Scenario: Charger plugged, panel opened at 0.5 s and closed at 1.5 s: pill snaps back to 'Charging' for 0.7 s. Charger plus AirPods together: the first is wiped.
- Fix direction: Clear ambient and peek on open; queue or merge a second moment; pause the fold while the pointer is on the pill.
- Verification: Read NotchController.swift:1280-1372 and NotchContentView.swift:398-412.

### F-034 Delete These Files reloads the Shelf before the background trash has run
P3 · feedback-errors · verified by principal: yes

- Evidence: SettingsPane.swift:221-234 calls screenshotVault.clear() then shelf.load()/refreshFromDisk()/refreshUsage() immediately; ScreenshotVault.clear() (:204-215) trashes on a utility queue with no completion. The comment 'the files were just deleted' is false at that moment.
- Scenario: After confirming, the cards and the size label stay until the next open.
- Fix direction: Give clear() a main-queue completion and refresh inside it.
- Verification: Read both sites.

### F-035 Shelf silently drops cards past 60, ignores duplicate drops, and a failed file promise only logs
P3 · shelf-integrity · verified by principal: yes

- Evidence: ShelfStore.swift:250-263 add() trims to limit with no result; duplicates skipped by URL. NotchRootView.swift:287-291 promisedFileArrived logs and returns on error; no pending card for slow promises.
- Scenario: Dropping 100 photos loses 40 with no message; a failed Mail promise shows nothing.
- Fix direction: Return a result from add() and show one section-level notice; a pending card with progress for promises.
- Verification: Read ShelfStore.swift:247-263 and NotchRootView.swift:284-296.

### F-036 Empty Shelf shows only a glyph, with no words or accessibility label
P3 · a11y-voiceover · verified by principal: yes

- Evidence: ShelfPane.swift:73-91 dropHint is a dashed box and one SF Symbol; no Text, no label.
- Scenario: First run: no hint that files can be dropped; VoiceOver gets nothing.
- Fix direction: One localized line ('Drop files here to keep them'); same for empty Clipboard.
- Verification: Read ShelfPane.swift:70-92.

### F-037 Quick Look, AirDrop, Copy and Show in Finder exist only in the card context menu
P3 · shelf-integrity · verified by principal: yes

- Evidence: ShelfPane.swift:213-221; the hover overlay has only Remove (:197-211).
- Scenario: A trackpad user who never right-clicks never finds the Shelf's two headline actions.
- Fix direction: Show a compact action row when the selection is non-empty or on hover.
- Verification: Read ShelfPane.swift grep output and :213-221.

### F-038 Shelf drag image is a generic 48 pt file icon at the view origin, not the card thumbnail under the pointer
P3 · shelf-integrity · verified by principal: yes

- Evidence: ShelfDragSource.swift:60-68 NSWorkspace.icon(forFile:) with setDraggingFrame(NSRect(x: offset, y: -offset, 48, 48)) in the overlay's coordinates; mouseDownPoint ignored; mouseDown gives no press feedback (:42-45).
- Scenario: Grabbing a screenshot card mid-card: the preview jumps to the card's lower-left as a file icon.
- Fix direction: Use the card thumbnail at the grab offset; show a pressed state on mouseDown.
- Verification: Read ShelfDragSource.swift:38-103.

### F-039 Editing shortcuts in the Translate field are matched by US key position
P3 · keyboard-shell · verified by principal: yes

- Evidence: NotchPanel.swift:45-52 and :103-115 map fixed key codes (A=0, Z=6, X=7, C=8, V=9).
- Scenario: German QWERTZ: the key labelled Z is key code 16, so ⌘Z does nothing and ⌘Y undoes; AZERTY ⌘A does not select all.
- Fix direction: Prefer charactersIgnoringModifiers when it is ASCII, fall back to key codes only for non-Latin layouts.
- Verification: Read NotchPanel.swift whole.

### F-040 Translate-clipboard hot key is silent when the clipboard has no text
P3 · feedback-errors · verified by principal: yes

- Evidence: AppDelegate.swift:50-51 returns when string(forType: .string) is nil.
- Scenario: Copy an image, press ⌃⌥⌘T: nothing at all, indistinguishable from an unregistered shortcut.
- Fix direction: Open Translate with an inline 'The clipboard has no text' or beep as the recorder does.
- Verification: Read AppDelegate.swift:44-56.

### F-041 Music artwork script has no 'if it is running' guard and can relaunch Music
P3 · system-lifecycle · verified by principal: yes

- Evidence: PlayerBridge.swift:351-356 musicArtwork tells Music directly; the position and track-id scripts (:312-328) guard on running.
- Scenario: Music quits between the state read and the artwork fetch: the Apple event launches it again.
- Fix direction: Add the running check as the sibling scripts do.
- Verification: Read PlayerBridge.swift:308-358.

### F-042 Online translation is unbounded and all-or-nothing; Retry is offered for failures that cannot succeed
P3 · feedback-errors · verified by principal: yes

- Evidence: OnlineTranslation.swift:65-84 sequential 480-character requests, throws on first failure discarding the rest; Translator.swift:454-458 always sets remedies = [.retry].
- Scenario: Pasting 100 KB with online on burns the daily quota over minutes; a quota failure offers Retry.
- Fix direction: Cap online input with a message; keep partial results; no Retry for quota/guardrail/too-long.
- Verification: Read OnlineTranslation.swift:60-90 and Translator.swift:448-460.

### F-043 Local lyrics folders are fully re-read and parsed on the main thread at launch and on every folder event
P3 · perf-idle · verified by principal: yes · needs live check

- Evidence: LocalLyricsLibrary.swift:148-160 init calls rescanFolders() (@MainActor, :50); watchers on the main queue (:575-583) schedule a full rescan after 150 ms (:588-595); no mtime check.
- Scenario: A large lyrics library delays launch and stalls the UI whenever a sync client touches the folder. Not visible with the owner's 12 KB library.
- Fix direction: Index by path, mtime and size off the main actor; parse lazily.
- Verification: Read LocalLyricsLibrary.swift:145-215, 570-600. Cost estimates not measured.

### F-044 Artwork is decoded and held at full source resolution and fed to two large live blurs
P3 · perf-idle · verified by principal: yes · needs live check

- Evidence: MediaController.swift:1672-1696 NSBitmapImageRep at pixel size, no downscale (off-main, good); consumers max 118 pt; LockScreenCard.swift:210-219 scale 1.5 + blur 44; LyricsStage blur 60.
- Scenario: A 3000 px cover holds about 36 MB decoded for the track; blur cost unmeasured.
- Fix direction: Decode with CGImageSourceCreateThumbnailAtIndex at about 512 px; one pre-blurred small bitmap for ambience.
- Verification: Read MediaController.swift:1672-1700; GPU cost needs Instruments.

### F-045 Lock card volume drag writes CoreAudio and re-enumerates every device on each pointer event
P3 · perf-idle · verified by principal: yes · needs live check

- Evidence: LockScreenCard.swift:713-719 SystemVolume.set per onChanged; the volume listener calls systemAudioChanged -> refresh -> AudioOutputs.available() + current() + volume (AudioOutputs.swift:258, 288-307).
- Scenario: Many audio devices: drag stutters on the lock card.
- Fix direction: Coalesce writes to about 30 Hz; on a volume-property change re-read volume only.
- Verification: Read both sites; stutter needs a live check.

### F-046 Play/pause and heart .symbolEffect(.replace) may cut instead of replace because the state change is not animated
P3 · motion-reduce · verified by principal: no · needs live check

- Evidence: MediaPane.swift:426-431 contentTransition on media.isPlaying; controls HStack animates canSkip and modes only (:460-462); LockScreenCard.swift:848 heart likewise.
- Scenario: Clicking pause may hard-cut the glyph the comment says it replaced.
- Fix direction: Check live; if it cuts, add .animation(Theme.contentAnimation, value: media.isPlaying) on the glyph.
- Verification: Read the sites; whether symbol content transitions need an enclosing animation cannot be settled from code.

### F-047 Synthetic-notch recheck runs only at launch
P3 · system-lifecycle · verified by principal: yes · needs live check

- Evidence: verifySyntheticNotch called only from install() (NotchController.swift:130, :379-391); NotchGeometry.decide (:109-117) believes a zero safe area when the display frame changed; the 2 s watchdog checks frames, not the notch.
- Scenario: A display arrangement change that moves the internal display's frame while the safe area reads 0 for a beat leaves a synthetic pill on a notched Mac until a later notification.
- Fix direction: Re-arm verifySyntheticNotch at the end of every build().
- Verification: Read NotchController.swift:320-352, 375-392, 425-480 and NotchGeometry.swift:100-120. Trigger is inferred.

### F-048 About Isla is ordered front without activating the app
P3 · feedback-errors · verified by principal: yes · needs live check

- Evidence: SettingsPane.swift:536 NSApp.orderFrontStandardAboutPanel(nil) with no activate; ShelfSharing.swift:26 activates for exactly this reason.
- Scenario: The About window may open behind the frontmost app.
- Fix direction: Activate and hand activation back as ShelfSharing does.
- Verification: Grepped both sites.

### F-049 AirDrop unavailability is a system beep only
P3 · feedback-errors · verified by principal: yes

- Evidence: ShelfSharing.swift:51-54 beeps when the service is nil or canPerform is false; didFailToShareItems only restores activation.
- Scenario: Rare: canPerform false (file gone, managed Mac) gives a beep, silent at zero alert volume.
- Fix direction: One inline Shelf notice saying why.
- Verification: Read ShelfSharing.swift:40-70. Downgraded from P1: the system AirDrop sheet reports Bluetooth/AirDrop-off and send failures itself.

### F-050 With Save Clipboard Screenshots on, a copy carrying both text and an image (spreadsheet cells, rich text) is saved as an image and its text never reaches history
P3 · shelf-integrity · verified by principal: yes

- Evidence: ClipboardStore.swift:198-210 checks wantsImages() and .png/.tiff before the text path and returns.
- Scenario: Opt-in only (default off, NotchViewModel.swift:656-658): copying a Numbers range makes a screenshot card and no text entry.
- Fix direction: Prefer text when a string flavour is present alongside an image.
- Verification: Read ClipboardStore.swift:190-220 and the default. Downgraded from P2 because the setting is off by default.

### F-051 Lyric credits render bold although the comment says never bold
P3 · contrast-type · verified by principal: no

- Evidence: LyricRow.swift:113-118 comment 'Never swept, never bold' but .islandFont(fontSize, weight: weight) passes the caller's weight.
- Scenario: Credits may render bold italic like a sung line.
- Fix direction: Use .regular or .medium for credits.
- Verification: Read LyricRow.swift:110-122; did not confirm callers pass .bold.

### F-052 Tertiary text sits under 4.5:1 on chip and hover fills
P3 · contrast-type · verified by principal: no

- Evidence: Theme.tertiary is 4.58:1 over black only; computed about 4.29:1 on surface, 3.52:1 on surfaceHover (SettingsPane.swift:828, 870-877; ShelfPane.swift:158; ClipboardPane.swift:68). Contrast tests use black only.
- Scenario: Settings notes, unselected segment labels and Shelf ages fall just under AA, worse on hover.
- Fix direction: Use secondary on fills or test tokens against surface and hover fills.
- Verification: Not re-read; arithmetic consistent with token values quoted elsewhere.

### F-053 Output picker marks the selected device with a white glyph on the accent colour
P3 · contrast-type · verified by principal: no

- Evidence: LockScreenCard.swift:575-583 per auditor; white on Yellow accent about 1.4:1.
- Scenario: Yellow or Orange accent: the selected device's glyph nearly vanishes.
- Fix direction: Add a checkmark and use a dark glyph on light accents.
- Verification: Not re-read.

### F-054 Idle wake-up figure does not reconcile with the timers that run while the display is awake
P3 · perf-idle · verified by principal: no · needs live check

- Evidence: Repeating timers while idle and awake: PointerWatcher 8 Hz, ClipboardStore 2 Hz, geometry watchdog 0.5 Hz, feed watchdog 0.25 Hz, helper heartbeat 0.2 Hz (about 11 per second), versus a recorded 0.33 per second averaged over uptime; checklist.md:210-212 CPU gate open.
- Scenario: The recorded number likely averages sleep time and overstates how quiet the app is.
- Fix direction: Re-measure with powermetrics, display on, 5 minutes idle; record beside the CPU number.
- Verification: Measurement task, not a code defect; timers spot-checked in NotchController and PointerWatcher.

### F-055 Smaller Reduce Motion gaps: cover morph and shell still travel (only faster), lock card and stage cut instead of fade, skeleton reads the setting once
P3 · motion-reduce · verified by principal: no · needs live check

- Evidence: Theme.open(reduceMotion:) only shortens the spring (Theme.swift:126-128) while matchedGeometry cover morph stays (NotchContentView.swift:735, MediaPane.swift:272); .animation(reduceMotion ? nil : ...) at LockScreenCard.swift:234 and others; Skeleton.swift:28-36 checks in onAppear only.
- Scenario: Reduce Motion on: the cover still zooms 22 to 118 pt in 0.12 s; lock card panes snap.
- Fix direction: Drop morph ids under Reduce Motion; use a short opacity fade instead of nil; onChange(reduceMotion) in SkeletonBox.
- Verification: Theme.swift:120-136 and the coverLight nil animation read; the rest not re-read.

## Refuted or merged

- Lock card 'clicks aimed at the password field are swallowed' (P1): merged into F-026 and downgraded to P2; the code confirms an empty click-taking window at display centre, but harm depends on the login UI's position, which code cannot show.
- AirDrop failure 'P1': downgraded to F-049 (P3); the system AirDrop sheet surfaces Bluetooth/AirDrop-off and send failures itself, and only canPerform == false beeps.
- Settings switches only clickable on the mini switch (P1) and no keyboard operation on four tabs (P1): moved to decisions_for_owner, both are listed as open owner decisions at checklist.md:508-510.
- Reduce Motion removes refusal feedback (P1): split; the Reduce Motion part is a code-documented choice (decisions), the VoiceOver silence merged into F-013.
- 'Panel keyboard and VoiceOver reachability is unproven' (P1, a11y auditor): vague umbrella; its concrete parts are F-004, F-013 and the keyboard-navigation owner decision.
- No VoiceOver announcements (P1): kept as F-013 but downgraded to P2; the hard VoiceOver blockers are F-005 and F-006.
- Duplicates merged: Escape on pinned panel (3 auditors) into F-004; Shelf VoiceOver (3) into F-006; Clipboard VoiceOver (3) into F-005; pane scale under Reduce Motion (2) into F-017; karaoke lag (2) into F-011; equal-timestamp ids (2) into F-010; lyric reset long-press (3) into F-029; small targets (3) into F-014; Shelf refresh on main (2) into F-022; drag image (2) into F-038; context-menu-only actions (2) into F-037; lock card empty window (2) into F-026; AppleScript timeout (2) into F-025; peek/ambient timers and queueing (3) into F-033 and F-013; haptics switch (3) and Panel Width live preview (2) into decisions.
- Uppercasing not locale-aware: speculative; no shipped locale (en, ru) is affected.
- Main-thread launch work is unmeasured: no defect named; folded into F-043 and F-054 where concrete.
- Peek artist line small and regular weight: taste without a measurable failure; covered by the type-size owner decision.
- 'Finding lyrics...' forever for a ready timeline with no lines: auditor's own reading is that callers treat empty as a miss; no reachable path shown.
- Scrubber offered for sources that ignore seeks, stale stage scroll on replaced lines, interlude state, RTL karaoke sweep, row isCurrent animated twice, unused Theme.compactAnimation, inline animation literals (ISL-01), tracking step function, glass not grouped/elevation ignored, lock pane buttons brightness-only, cover images unlabeled, ru number formatting, clipboard preview LF-only, update check failure wording, vault write failure silent, Disconnect Spotify unconfirmed, section headers without isHeader, Settings slider values and symbols for VoiceOver, privacy switch titles, Clear Everything wording, missing .help tooltips, hot-key recorder silent reassignment, press feedback on rows, stale click-through window for about 190 ms, drop margin not effective while collapsed, helper polling during display sleep, online lyrics cache rewrite, clipboard full-payload reads, Shelf strip not lazy, privacy-dust cost, ScrollWheelWatch monitor leak, boundary-timer re-arm, artwork parse on main, CoreAudio enumeration on main, session/fast-user-switch observers, rebuild debounce, synthetic notch height, SkyLight drift logging, helper double relaunch, wake re-announcement, deliberate opens while locked with the card off: plausible P3 polish not verified by the principal in this pass and not ranked into the backlog; keep them in the auditors' reports for the owning cluster to triage.

## Decisions that contradict a recorded project decision (owner)

1. Keyboard navigation inside the panel (focus rings, Tab/arrow movement, Space/Return, transport keys). Recorded as an open owner decision at checklist.md:508-509; three auditors rate it P1 (A11-12/FOC-02 fail). Recommend deciding now: it blocks Full Keyboard Access users from every tab but Translate. F-004 (Escape) can ship without it.
2. Settings toggles with a detached label (checklist.md:510): only the 24x14 mini switch is clickable (SettingsPane.swift:783-801). Auditors rate it a CTL-01 failure. Recommend a labelled Toggle or a row-wide tap target.
3. Escape closes the panel instead of disarming a two-press confirmation (checklist.md:511), and the 3 s disarm timer has no hover pause and no VoiceOver extension (Confirmation.swift:70-75).
4. SettingsPane.choiceRow hand-rolled segmented control (checklist.md:499): no arrow keys or radio-group semantics; the 'Glass' row title also matches its first option.
5. collapseRectShrinkDelay 0.45 s (checklist open item): clicks on the retracting body are swallowed for up to about 0.45 s after a close.
6. Panel Width does not preview live (deliberate after audit A7, SettingsPane.swift:690-722); auditors flag CTL-06.
7. No haptics switch (checklist.md:172-175 records haptics with no setting); three auditors cite HAP-02. Either add a Settings toggle or record that the trackpad's own setting governs.
8. Reduce Motion removes the locked-island refusal entirely (RefusalShake.swift:28-31, 'nothing honest to substitute'). Auditors want a non-travel channel (opacity dip or announcement).
9. Lyric context lines sit at 0.28/0.34 white (2.27:1 and 2.89:1 over black) by documented design (LyricRow.swift:50-70), below 3:1 even for large text; credits 0.34 ignore Increase Contrast. Raise to about 0.36 or record the depth-over-contrast choice in checklist.md.
10. Fixed point sizes with no Dynamic Type or larger-text option (body 11, caption 10, Theme.swift:196-205): not recorded in checklist.md as a divergence. Record it or offer a one-step larger-text setting.
11. Paused pill folds after 0.4 s (owner request 2026-09-21, NotchMetrics.swift pausedLinger): buffering or ad gaps may now flicker the pill. Consider a longer linger only when the pause follows a track change.
12. Lock card heart writes to the owner's Spotify Liked Songs from a locked Mac (LockScreenCard.swift:834-860). CLAUDE.md requires anything touching an account to be recorded in checklist.md and default off; the lock-card entry lists previous/play/next and volume only. Hide it on the shield or record and gate it.
13. Screen-capture pickup accepts any movie in a capture folder, Desktop included (RecordingPickup.swift:85-97, comment assumes Screenshot is the only writer). Any .mov/.mp4 saved to the Desktop lands on the Shelf. Consider the prefix rule or the kMDItemIsScreenCapture attribute.
14. A clipboard screenshot switches an open panel to the Shelf with no user action (NotchViewModel.swift:955-957, deliberate). FOC-01 says do not move the user.
15. Escape in Translate clears the typed text (NotchViewModel.swift:921-928, described as 'reversible' though nothing restores it).
16. Pointer-away folds the panel while the user is typing in Translate (NotchController.swift:1135-1141, the pointer decides by design); keystrokes then land in the app underneath.
17. Shelf drag-out offers Move by default while the Shelf only references originals (ShelfDragSource.swift:92); a same-volume Finder drop moves the user's file. Copy-by-default with Option for Move is the conservative choice (F-020 covers the stale card either way).
18. hoverNudge (damping 0.72) and lyricScroll (0.86) overshoot exceptions compute to under a point of visible bump (Theme.swift:106-108, 239-240); either make the bump visible or make them critically damped. Also the comment cites MotionValuesTests while the assertion lives in RestingNotchTests.
19. Idle 8 Hz pointer sampler and 2 s geometry watchdog on an awake display (PointerWatcher.swift:3-10, 105-119); the CPU gate is still open at checklist.md:210-212.
20. Island only on the notched or primary display, no setting (NotchGeometry.swift:134-138); external displays never exercised (checklist).
21. Hot-key-filled clipboard text is auto-translated online after 320 ms when Translate Online is on and detection picks an online-only language; consider one click before sending clipboard text off the Mac.
22. Dropping text or links on the island is refused (files only, NotchRootView.swift:86); several competitors accept them.
23. Lyric slots are a fixed 40 pt with a two-line limit (LyricsStage.swift:219-220, 400): CJK or long Russian lines truncate; deliberate trade for arithmetic scrolling.
24. Arrow cursor pinned over the whole active rect, including the Translate editor where macOS shows an I-beam (NotchRootView.swift:137-165); one auditor reads it as documented-deliberate, another as a defect.
