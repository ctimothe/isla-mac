# Mobbin pass: ideas ranked against the verified backlog

Produced 2026-10-11. Seven Sonnet researchers ran at least 12 Mobbin searches each (screens, flows, sections) per Isla surface; an Opus design lead merged and ranked the ideas against the apple-design bar, the Wave A backlog and the project's recorded decisions. Evidence ids are Mobbin screen ids, so each pattern can be re-found. Patterns only: nothing here copies another product's branding or assets.

## 1. Shelf cards go offline or missing, never silently deleted
Shelf · effort M · verdict: adopt · addresses: F-001, F-019, F-020, F-022

Give each card three states. Normal. Offline: the card's volume root is not mounted (check the volume URL off the main actor, not the file error). Keep the card, drop the thumbnail to about 45% opacity with a small disk glyph and the caption 'Disk not connected', disable drag, keep Remove. Missing: the volume is present and the file is gone. Dim the card, caption 'Moved or deleted', actions Locate (re-resolve the bookmark) and Remove. Nothing is evicted until the user chooses. Pass the Shelf's live URLs to pruneDropInbox so it skips Dropped folders a card still uses (F-019). On a .move drag result, re-resolve through the bookmark so the card follows the file (F-020). Do the reachability scan off main and apply the result once (F-022). Dim only the thumbnail so the filename keeps its contrast token. Tests: a ShelfStoreTests case for a nonexistent /Volumes root, and one for a prune that skips a referenced folder.

- Why: Closes the only P1 data-loss finding in the Shelf, plus three related findings. It is the biggest trust gain on the surface and needs no new UI system.
- Apple check: Responsibility and Agency: the user decides what is removed, and a status is shown instead of a silent loss. Meets the bar.
- Evidence: IKEA c751d6f7-57dc-4f1f-956c-cc5ce8036960; Cherrypick 9c60adb4-71cd-4c77-887a-bdc1df5a3ba8; OpenPhone 04c3ef88-f825-4297-b030-dc94bf749b65; HBO Max 2c6b51a6-80b2-40f0-8513-83e693c55da3; Dropbox d0569b07-8f20-48c0-b2c9-644df6a3e658

## 2. Clipboard rows get a named context menu, mirrored as VoiceOver actions
Clipboard · effort S · verdict: adopt · addresses: F-005, F-014, F-037

Add a .contextMenu to ClipRow with Copy, then Reveal or Hide (covered rows only), a divider, and Remove with role .destructive. Expose the same verbs through .accessibilityAction(named:). Replace the fixed 'Copy Entry' label with the row's preview text, or 'Hidden' when the row is covered, and keep Copy as the default action. Copy the Shelf's existing context-menu setup so the non-activating panel does not take key status.

- Why: Closes the P1 VoiceOver blocker (F-005) for a small effort. It also gives pointer users a way to remove a row without aiming at the 22 pt hover xmark.
- Apple check: Familiarity (right-click verbs, with the destructive item last behind a divider) and Flexibility (works for the full range of abilities). Meets the bar.
- Evidence: WhatsApp 11ae6c12-5e25-4090-bbcc-b476f73aa3de; Linear Mobile 1d6b3350-2ad6-4be7-aee2-001e19dbcb6d; Perplexity dcbfe8d1-8337-4f4e-b3f6-89ff772b440e; DeepSeek e66a5318-a324-4617-94a7-dcffd780e50a

## 3. Honest no-length, live and unreadable lyric states on the stage and the lock card
Now playing, lyrics, lock card · effort S · verdict: adopt · addresses: F-007, F-009, F-031

Add availability cases to LyricsCoordinator that are never .disabled: .noLength (live stream or browser audio with duration 0) and .unreadable(reason) for an LRC parse failure. LyricsPresentation maps each case to a short title plus one reason line, for example 'No lyrics for live audio' or 'This file could not be read (line 12)'. It shows an offer only when the offer can work: Show Lyrics only for a real .disabled. On the lock card, when duration <= 0, stop drawing the dead 0:00 / -0:00 bar (keep the spacing), as MediaPane already does, and show a static 'Live' label. When the length has not loaded yet, show '--:--' instead. Both surfaces use the same copy. Fix the F-009 parser (collect the pairs, stable-sort, then validate) so 'unreadable' appears only for real failures. Add en and ru keys and LyricsPresentation tests.

- Why: Closes the P1 dead 'Show Lyrics' button (F-007) and the two related honesty findings, so the panel and the lock card stop disagreeing. Mostly copy and an enum.
- Apple check: Feedback kinds (status, error) and Simplicity: the user gets a specific reason and never a control that cannot work. Meets the bar.
- Evidence: SiriusXM 054b1468-75bb-48c4-a2da-cdfe00b0f957; Apple TV 9d1a7760-4198-4a64-a363-0aedf2145576; Apple Podcasts c091b559-a228-4122-9251-2d49d3f91b73; Brink a79b557b-7c75-4ba4-acf2-0aee23545c5a; Shopee 4fab273f-3fe0-4f81-b4b8-542b60942f23

## 4. Covered content: an always-visible eye, copy without revealing, and the Translate output covered too
Clipboard and Translate privacy cover · effort S · verdict: adopt-with-changes · addresses: F-002, F-005, F-016

On a covered clipboard row, show a small eye at all times. The dust already marks the row as covered, so no hover is needed. Clicking the row copies without revealing. The eye reveals the row, and the row re-covers when the pointer leaves it or after about 5 s (a cut under Reduce Motion). VoiceOver hears 'Hidden'. In Translate, put the output column under the same SpoilerField and the same reveal id as the source, so one reveal uncovers both. Run SpoilerClock only while a covered row is actually on screen.

- Why: The researcher's reveal pattern also fixes the P1 leak where the translation of a covered secret shows in full (F-002). Change: apply it to Translate, not only to Clipboard.
- Apple check: Responsibility (privacy holds in every column) and Feedback (the state is visible without hover). Meets the bar.
- Evidence: CLEAR 3c9f89d5-8e16-4f77-8cdd-1fe3f9f07907; Believe 8e67d429-67d4-4e5b-b8a3-d42575182390; Rocket Money c0ba7943-75bb-4fa4-842e-f1f92193a2c0; Expedia 203a893a-2b42-44aa-b316-faa15aff043c

## 5. Lock card wash scaled by cover brightness, from a small pre-blurred bitmap
Lock card · effort M · verdict: adopt-with-changes · addresses: F-003, F-044, F-012, F-052

Once per track, off the main thread, decode the cover at about 512 px with CGImageSourceCreateThumbnailAtIndex (F-044), blur it once, and measure its mean luminance. Choose the black wash strength so cardSecondary holds 4.5:1 over that luminance, with a floor for an unknown cover. Apply the same rule in Transparent and Tinted. Keep white type and do not flip to a light card. Extend ContrastRampTests to the brightest permitted backdrop, not black. Separately, check the no-artwork glassEffect case on a locked macOS 26 Mac (F-012) and pass preferDrawn if it reads wrong.

- Why: Closes the P1 legibility failure over pale covers (F-003) and the memory cost of full-size art. Change: only the luminance-scaled wash. The researcher's light-card flip variant is dropped because it risks a flash on track change.
- Apple check: Vibrancy keeps text legible over changing backgrounds, and colour sits on a solid layer. Meets the bar.
- Evidence: Apple Podcasts b7892e24-f699-4af4-84eb-47b3d55d22bf; Apple Fitness 5e65770d-0f4f-464f-8445-b23d3917ae7a; TIDE f9f6a5f2-db50-44bb-ae28-3eab81e4b2a5; Suno cd032637-379d-457e-9014-41b092aedc7f; Apple Music cc5e5fd9-cb72-48d6-abb9-1d08aa8b0942

## 6. Copy confirms on the control itself, with one Announcer helper for VoiceOver
Cross-surface feedback (lyrics, Translate, Clipboard) · effort S · verdict: adopt · addresses: F-013, F-005

Add a small, rate-limited Announcer that posts NSAccessibility announcementRequested. CopyButton and the lyric Copy line and Copy All controls swap the glyph to a checkmark with a symbol replace (a cross-fade under Reduce Motion) for about 1.2 s, change the label to 'Copied', and announce 'Copied'. Do not add a separate toast. Reuse the Announcer for the ambient moment's label, 'Press again to clear' on an armed confirmation, the new title on the lock card, and 'Unlock to open' when the locked island refuses a click.

- Why: One small helper closes F-013 across every surface, and the copy confirmation is the most visible use of it.
- Apple check: Multimodal feedback: causality, plus harmony (glyph, haptic and announcement on the same frame). One surface per event. Meets the bar.
- Evidence: Acorns flow 4dceb855-19ce-4d5f-9dc7-16356a5beea6; Brink 2caf9ed6-fc37-49c4-b7d7-5b3385039180; DeepSeek flow b032f9f3-6325-40ee-8762-60526cf186d1; Coinbase eb69f90a-5485-4975-8634-bf98898d91c3 (double feedback, avoid)

## 7. Launch at Login says when it needs approval and links to Login Items
Settings · effort S · verdict: adopt · addresses: F-027

Model the switch's status as a state, not a bool. On .requiresApproval, keep the switch visibly pending, add a note row 'Needs your approval in Login Items', and add an action row that calls SMAppService.openSystemSettingsLoginItems(). Other errors show their reason inline in the same row. Re-read the status on app activation so the row clears itself after approval. Use the existing noteRow and actionRow.

- Why: Closes F-027 with two existing row types. A switch that snaps back with no words is a clear defect.
- Apple check: Feedback (inline validation, not a silent revert) and Wayfinding (shows how to get there). Meets the bar.
- Evidence: Places 6140e55d-e900-4dc0-b7a1-44f1a4bd9b77; Truecaller dbeae924-9c68-493c-8d1d-aa8a7594c14a; Polarsteps 5006956b-68c1-4e35-aba0-290589260ab3; Quizlet dd2ac515-3ea2-4b11-8fe6-03b597f27439

## 8. Empty Shelf and empty Clipboard say what goes in and from where
Shelf and Clipboard · effort S · verdict: adopt · addresses: F-036, F-035, F-006

Shelf: keep the dashed box and Isla's glyph, and add the headline 'Drop files here to keep them' plus a second line 'From Finder, Mail, Photos or a browser. Holds 60.' Give the region an accessibilityLabel. Clipboard: 'Nothing copied yet' plus 'Text and files you copy appear here. Copies from password managers are skipped.' When history is off, show an inline Turn On button instead of that line. A list that was just cleared reads differently from one never used. Second lines use the secondary token on fills. Copy must fit at 480 pt in Russian, with en and ru keys.

- Why: Closes F-036 and states the 60-card cap before anyone hits it. Small copy work with a first-run payoff.
- Apple check: Simplicity: adding context simplifies. Wayfinding answers 'what's there'. No illustration, which keeps the restraint. Meets the bar.
- Evidence: monday.com c4ce6187-8c41-4353-9e5e-70c2dadcc5a3; Google Gemini 4015b520-9042-45c9-a952-1fe7879afda4; Claude 68308671-671d-4f0d-a4c1-fa699cedf9aa; Arc Search c5b1d5af-f7c3-4af8-b41d-458c3553f2a2; Brink 63476c8d-0a77-41a7-90c8-de4066c6a751

## 9. A Shelf drop reports what happened: added, already there, or over the cap
Shelf · effort S · verdict: adopt-with-changes · needs owner decision · addresses: F-035

ShelfStore.add() returns a result (added, duplicates, overflow). The footer shows one line for about 4 s, for example 'Added 60 of 100. The Shelf holds 60.' or 'Already on the Shelf'. For a duplicate, the existing card's hairline pulses once and the card scrolls into view (no scroll animation under Reduce Motion). From 50 cards, the footer shows 'n of 60'. The line shares the footer slot with the selection count and Clear. One surface per drop.

- Why: Closes the silent part of F-035 for a small effort. Change: the overflow policy must be decided first. Recommend refusing the excess with a message, because silently evicting the oldest cards is what makes cards look lost.
- Apple check: Feedback (completion and warning at the point of action). Meets the bar.
- Evidence: Perplexity 0882801e-93e2-49d0-89ee-dfcbc18ea95b; Alan 9246f3a3-3f0a-4b36-9607-3077163e5709; Google Photos feabcba9-7eb3-4557-b81b-1ff5bc405be1; Mistral AI a5bb0993-1f68-42ff-a51a-68f7c360681a

## 10. Failures name the cause and offer only a remedy that can work
Translate (shared failure grammar, also AirDrop on the Shelf) · effort S · verdict: adopt · addresses: F-042, F-049, F-014

In Translator, map each failure kind to its remedy set. Quota, guardrail and too-long get no Retry, and too-long says to shorten the text. Offline and network failures get Retry. A missing language gets Translation Languages or Download. Online off gets Turn On Translate Online. Show one short cause sentence in secondary, and the single remedy as a bordered PanelButtonStyle pill at least 24x20. Leave the source text untouched. Add tests for each kind. Use the same grammar for AirDrop: when canPerform is false, show one inline Shelf notice with the reason instead of a beep (F-049).

- Why: Closes the dead-end Retry (F-042) and the beep-only AirDrop failure (F-049). This is where the researchers' cross-surface failure-toast idea ends up.
- Apple check: Feedback (error) with one clear path, and one failure surface per event. Meets the bar.
- Evidence: Oura 9dbf6e35-9643-449f-9d0f-c89cc6248a49; CVS Health 3fca3f3b-83ca-4e42-a8f7-b188dc1060f4; PayPal 305815a1-eb96-4544-bde7-c1342b7e15ce; Posh 84e3f3ba-13cd-4334-b618-f7c69fb91757; CHOPT f9268601-035c-498f-a3d8-07ad169064d0

## 11. Translate field gets a placeholder, a label, and an inline 'The clipboard has no text'
Translate · effort S · verdict: adopt-with-changes · addresses: F-030, F-040

Show a faint 'Type or paste text' placeholder while the field is empty, and give the field the accessibilityLabel 'Text to translate'. When ⌃⌥⌘T finds no string on the pasteboard, open Translate with one inline line 'The clipboard has no text' instead of doing nothing. Never read the pasteboard speculatively to decide anything, and skip the researcher's Paste button. Keep the placeholder outside the privacy cover logic.

- Why: Closes F-030 and F-040 with one component. Change: the Paste button is dropped, because reading the pasteboard to decide whether to show it risks a paste-permission prompt and adds chrome.
- Apple check: Wayfinding (what to do here) and feedback for a hot key that did nothing visible. Meets the bar.
- Evidence: Meta AI cfe6b9b3-fe62-49a4-a495-34a7633d69f5; Speak e9e3c39c-b8c3-420d-9b4e-f36663691426; Air NZ 27b40e1a-581f-4984-a411-fa87266029fa

## 12. Output picker marks the current device with a checkmark and lists every device
Lock card output picker · effort S · verdict: adopt-with-changes · addresses: F-053, F-032, F-013

Each row: device glyph, name, and a trailing checkmark on the selected device. The selected row gets a neutral lighter fill with primary text instead of a white glyph on the accent colour. Pin the current device first. Replace outputs.prefix(5) with a list that scrolls at a maximum height. Set the isSelected accessibility trait. Keep the existing scrim, the bottom-trailing anchor and OutputRowStyle's press state. Skip the researcher's artwork header, because the card already shows the track.

- Why: Closes the accent-contrast failure (F-053) and the five-device cap (F-032) in one change. The header is dropped to save height.
- Apple check: Craft and Flexibility: selection is not shown by colour alone, and it works on every accent. Meets the bar.
- Evidence: Apple News 3b5b16f0-00ee-46e1-bf42-e18c9e5c7acc; Apple Podcasts b7892e24-f699-4af4-84eb-47b3d55d22bf; Waking Up f3d71983-4ee1-4ddd-957d-fb7f697a7ab9; Deezer 14c3f9ee-3ffa-4b19-a12a-8ee8b7834903

## 13. The karaoke edge is placed by the clock, not animated after it
Lyrics stage and lock card · effort M · verdict: adopt · addresses: F-011

Position the word-fill mask from the playback position on each frame, with a few points of feathered edge. Use a TimelineView(.animation) that runs only while a word-timed line is on screen. The minimum fix is .linear(duration: MediaController.positionTickInterval). Add a test asserting the sweep duration is no longer than the tick. Update the stale 4 Hz comments. Re-run Scripts/measure-sync.sh and recalibrate the 0.20 s lead. Do not add blur to other rows. Never invent word timing.

- Why: Closes F-011: the lit edge stops trailing the voice by about 2.5 ticks. It is the visible quality bar for lyrics.
- Apple check: Response (no lag on a continuous value) and frame-level smoothness, with the clock as the single source. Meets the bar.
- Evidence: Apple Music cc5e5fd9-cb72-48d6-abb9-1d08aa8b0942; Apple Music Sing d36c3dea-5c6e-4088-aaed-40d79b6407e3

## 14. Shelf selection swaps the footer for an action bar
Shelf · effort M · verdict: adopt · addresses: F-037, F-006, F-014

When the selection is not empty, replace the footer row (same height) with: the count, then Quick Look, AirDrop, Copy, Show in Finder and Remove as 28 pt icon buttons with tooltips and localized labels, plus an X to deselect. The buttons are real accessibility elements. AirDrop with several items keeps ShelfSharing's activation hand-back. Clear returns when the selection empties.

- Why: Closes F-037 (the headline actions are hidden in a right-click menu) and the sub-20 pt Deselect target. It also gives F-006 real elements to build on.
- Apple check: Grouping and mapping: the controls sit next to the selection they act on. Simplicity: the common path is shown first. Meets the bar.
- Evidence: Apple Photos d55c8518-c10c-4dc4-a83b-5da9531f741b; Shazam 386cb4f3-4ca2-4925-a77e-906bb224ddec; Google Photos a0249152-98cb-466e-863c-f7a8e3baff9c; Meta AI c6c5f5ab-8318-4255-8744-16f669628436

## 15. Undo replaces arm-then-confirm for card and row removals and for Clear
Shelf and Clipboard · effort M · verdict: adopt-with-changes · needs owner decision · addresses: F-014, F-013, F-005, F-006, F-020

Remove (one card or row, or a selection) and Clear act at once. A footer strip reads 'Removed 3 cards  Undo' for about 6 s, and the same Announcer posts it. Shelf: defer persist() and inbox trashing until the strip expires, and flush on terminate. Clipboard: hold a tombstone in memory and zero it on expiry, on panel close, on lock and on sleep. Undo is also an accessibility action. Clear becomes one press. Keep the two-press pattern only for Delete These Files.

- Why: Removes the precision and data-loss risk of the small xmark and the caption-sized Clear. Change: it needs the owner's ruling on the open Escape and arming decision, and Shelf and Clipboard must change together.
- Apple check: Agency: easy undo for slips, and confirmation only for destructive, irreversible actions. Strongly meets the bar.
- Evidence: Medium ed637f28-2d0d-40a6-bb79-b7fe7d8505e8; Google Photos 271108af-b336-489e-bac3-7b4639152cb4; CVS Health f8dca081-488d-4e7c-b79f-9f9281222c3a; Quo 28233f22-360a-456d-9973-ef2942fdf2fa; Spotify a2495459-509e-47ce-a925-e93e063d856c

## 16. Swap button centred between the two languages at 24x24
Translate · effort S · verdict: adopt · addresses: F-014

Move the swap out of the target header into the gutter between the columns. Overlay it on the column boundary if the 10 pt gutter cannot widen, and give it a 24x24 hit frame. On swap, rotate the glyph 180 degrees while the headings cross-fade (opacity only under Reduce Motion). Keep it enabled while a translation is in flight. Redo the textArea(in:) column math.

- Why: Fixes the worst Translate target in F-014 (18x14 at the screen edge). Placing it between both languages also shows that it acts on both.
- Apple check: Grouping and mapping (the control sits between what it changes) and Response. Meets the bar.
- Evidence: Google Lens 5d4b33c2-b47d-4a79-8fa4-df693d3e3506; Meta AI eb2873d4-983a-4d92-8211-af4da5625271; CapCut 81cf3e13-fc99-4b28-8bbe-4a11584205fc

## 17. The open lock-card pane is shown by a filled well, not just a brighter glyph
Lock card foot rail · effort S · verdict: adopt · addresses: F-053, F-014, F-052

In paneButton, draw a 22 pt translucent well (the existing glass fill token) behind the glyph of the open pane (lyrics or output). Keep the glyph white and leave the siblings bare. Grow the hit frame toward 24 pt. It must still read under Increase Contrast.

- Why: A one-opacity-step difference fails over pale covers and for low-vision users. This is a cheap fix.
- Apple check: Craft: selection is shown by shape, not by one opacity step. Meets the bar.
- Evidence: Apple Music d36c3dea-5c6e-4088-aaed-40d79b6407e3; Apple Podcasts c091b559-a228-4122-9251-2d49d3f91b73; Moonly 11291242-f955-4e61-9d65-e3263ff87781

## 18. Delete These Files states the consequence, and refreshes only when the trash is done
Settings (screenshot vault) · effort S · verdict: adopt · addresses: F-034, F-013

When the button arms, show a caption read at arm time: 'Moves 37 files, 214 MB, to the Trash. Their Shelf cards go too.' Give ScreenshotVault.clear() a main-queue completion. Disable the row until it fires, then refresh the Shelf and the size label inside it. Announce the armed state. Keep press-twice. For Shelf Clear, the Undo idea replaces confirmation, and its strip can say 'The files stay where they are.'

- Why: Closes the F-034 race and makes the only irreversible removal specific. Change from the researchers: Shelf Clear does not get a confirmation, because Undo covers it.
- Apple check: Agency: a confirmation only where the action is really destructive, and it says exactly what goes. Meets the bar.
- Evidence: Alta 92784a3e-bfa1-460c-a5a4-fb548c2c88ee; Fitbit 955c5e0d-8a80-4fa4-a86d-02e1fbac0658; foodpanda 1677b564-8b7a-4b06-95fa-bb84208d9540; Noom 8039e2dc-7db3-4944-9ed1-9706c0bc5094

## 19. Lock-card volume slider: speaker endcaps, a taller grab strip, coalesced writes
Lock card foot rail · effort S · verdict: adopt-with-changes · addresses: F-014, F-045

Add a small speaker glyph at the quiet end and a speaker-with-waves at the loud end, using card tokens. Grow the hit height to 22 pt over the same drawn bar. Coalesce SystemVolume.set to about 30 Hz, and on a volume-property change re-read only the volume, not the whole device list (F-045). If the rail gets crowded, move the volume into the output popover, as Deezer does.

- Why: The bar now reads as volume and is easier to grab. The F-045 coalescing from the backlog is added, because it is the same code path.
- Apple check: Familiarity (Apple's own volume vocabulary) and continuous 1:1 feedback without stutter. Meets the bar.
- Evidence: Apple Music d36c3dea-5c6e-4088-aaed-40d79b6407e3; Apple News 7a593acc-4089-4ad6-8897-c0386cf587f0; Amazon Alexa 854b4138-d4b8-4e94-bbaa-f2da355b350b; Deezer e6e41348-9f60-4faf-9f9f-68a11c11b7e9

## 20. Ambient moments: one slot that updates in place, a glyph-and-value layout, cleared when the panel opens
Ambient moments (charger, headphones) · effort M · verdict: adopt-with-changes · addresses: F-033, F-013, F-055

Replace the single overwritable vm.ambient with a small moment model. A second event updates the same pill, for example by adding a trailing glyph, and the pill folds 2.2 s after the last change. Clear moments and peeks when the panel opens so nothing resurfaces. Pause the fold while the pointer rests on the pill. Use one layout: identity glyph leading, value trailing (charge percent with a small determinate ring, tinted green at full; headphones battery when macOS reports it, otherwise the name), with monospaced digits. Announce the label through the Announcer. Under Reduce Motion, cross-fade the trailing slot. Test the orders charger then headphones, headphones then charger, and panel open mid-moment.

- Why: Closes F-033. Change: the researchers' hover-to-expand variant and the actions inside a moment (Switch output) are dropped, because hover only brightens and the compact island has no controls.
- Apple check: Spatial consistency (one anchored slot) and Utility (a glanceable value instead of a sentence). Meets the bar.
- Evidence: Swiggy flow 4646cbfc-0436-4e68-9fc2-8fe285a96c1b; sweetgreen flow 6109f9fa-947a-4c60-a854-6c7bc401190d; Flighty a878818a-1f9e-4da1-93d6-5463fe9b0fcf; Binance 75e68d47-ad27-423b-a083-fc15091b88f3; Opal fc3f12d6-0024-4c1e-b7b3-d5d4cd9488b9; Instagram 46f634c4-fa71-4d6a-9301-318e10592eb4

## 21. Dragging a card lifts its real thumbnail from the point you grabbed
Shelf drag-out · effort M · verdict: adopt · addresses: F-038

Build the NSDraggingItem image from the card's cached thumbnail (never a new QuickLook request mid-drag), at screen scale, offset so the pointer stays on the same point of the card, with a soft shadow and a 1.04 scale. For a multi-selection, draw up to three offset thumbnails with a token-coloured count badge. Give mouseDown a 0.97 press scale, and dim the source card to 50% until the session ends. Under Reduce Motion, skip the lift animation and keep the image.

- Why: Closes F-038 directly. It is the clearest direct-manipulation gap in the app.
- Apple check: Direct manipulation: content stays under the pointer and respects the grab offset. Response: feedback on press. Meets the bar.
- Evidence: Todoist 2b40d727-3fda-4a32-b221-b3781909b09e; Shopee e6d9291c-f5c5-4f5d-8395-5cc2eee174c4; Obsidian 9a0771d2-d259-416f-b986-469d4c626c71; BFF 34318498-2bfe-495d-b1dd-9f5dffae5e81

## 22. While a file drag is over the Shelf, a label says what will happen
Shelf drop target · effort S · verdict: adopt · addresses: F-036

While a file drag is inside the panel on the Shelf tab, at any card count, dim the grid slightly and overlay one dashed pill: 'Drop to keep on Shelf', or 'Add 3 files' when the pasteboard count is known (file promises fall back to the generic line). Drive it from vm.isDropTargeted. Use opacity only, no scale under Reduce Motion. On an empty Shelf, the headline from the empty state changes to 'Release to add to Shelf'.

- Why: With 1 to 60 cards there is no visible target today. Because the window is click-through, this label is the only sign that it accepted the drag.
- Apple check: Hint in the direction of the gesture, with continuous feedback during the drag. Meets the bar.
- Evidence: Obsidian flow 2b948e61-00cf-44d3-96df-96bf90f266ae; untitled c11b28b6-b41e-41fb-adcd-91258f3779b7; Duolingo b4d03292-1d95-4f2a-97b4-27fd72edef0c

## 23. Card context menu: grouped, identity header, Remove last as destructive
Shelf context menu · effort S · verdict: adopt-with-changes · addresses: F-037, F-006

Order: a disabled header item with kind, size and parent folder (the volume name when offline), then Quick Look, Open, a divider, AirDrop and Copy, a divider, Show in Finder, a divider, and Remove with role .destructive. Build the header as a disabled NSMenu item, not a custom view. Add Remove only together with the Undo path. Leave Copy Path out unless the owner asks for it.

- Why: Two cards both called 'Screenshot 2026-10-11' can now be told apart, and the headline action leads. Remove waits for Undo so the menu does not add a second irreversible route.
- Apple check: Familiarity (the Notes and Finder menu order) and Grouping. Meets the bar.
- Evidence: Apple Notes a52a8ecd-f37a-4945-9b1e-8bcb1cb79153; Dropbox d0569b07-8f20-48c0-b2c9-644df6a3e658; Google Drive 6bb45ae6-f13d-4f59-87f6-f6d32c3f7b0e; Obsidian 09dec6de-5d1b-4020-922b-ad238e77263c

## 24. Name the current audio output under the lock-card controls
Lock card foot rail · effort S · verdict: adopt-with-changes · addresses: F-013

Add a 10 to 11 pt tertiary caption with the current output's name (tail truncation) beside or under the output glyph. Use the name as the output button's accessibilityValue. Hide the caption in Compact size. Add en and ru keys.

- Why: A locked-Mac user can tell where sound is going without opening the picker. Change: hidden in Compact, where the card has no room for it.
- Apple check: Simplicity: adding context (like time remaining on a scrubber) simplifies. Meets the bar.
- Evidence: Apple Music d36c3dea-5c6e-4088-aaed-40d79b6407e3; Apple Music mini player 46d34dbf-5b97-4704-9427-6c9385374f57; Apple Podcasts b7892e24-f699-4af4-84eb-47b3d55d22bf

## 25. Ask once before clipboard text goes online, and show which engine was used
Translate (online engine) · effort M · verdict: adopt-with-changes · needs owner decision · addresses: F-042

Replace the grey globe with a labelled chip, 'Online · MyMemory'. Text that arrives through the hot key or Services and needs the online engine waits behind one inline line, 'Send to MyMemory' / 'Not now', instead of being sent after 320 ms. The choice is remembered for the session, not forever. Typed text keeps today's flow once the setting is on. Cap online input length and say so, and keep partial results instead of discarding them (F-042). This is an inline column alert, not a toast.

- Why: Fits the rule that nothing leaves the machine without an opt-in. The owner must reverse the current auto-send behaviour.
- Apple check: Responsibility: ask at the right moment, transparently, for only what is needed. Meets the bar.
- Evidence: Structured fd506bc7-2c02-4ba0-ab7c-85f42d286c8e; Runna 5876fe0a-be7c-45ac-9760-a59e7a6af7ba; Instacart 904e90db-727c-4ba0-90fb-f7b4d3c1d7b2; Azar 37e5d73d-f8b7-4f9c-be94-51a56fc1c6cc

## 26. Language picker: a separate 'Detected' label, Detect and Recents first, status apart from the name
Translate language menus · effort S · verdict: adopt-with-changes · needs owner decision · addresses: new, F-052

The source heading shows the language name with a quiet 'Detected' sub-label instead of the 'ENGLISH (DETECTED)' suffix. Each menu lists Detect first, then Recents (the last 3 used), then all languages. Online-only and not-installed become a trailing status mark or text suffix, not part of the name. When NLLanguageRecognizer confidence is low, show a Suggested section with the top 2 guesses. Keep a native SwiftUI Menu with no search field. The researchers also want sentence case instead of tracked capitals in these headings. That is a panel-wide Theme.capsTracking change for the owner.

- Why: A wrong guess becomes one click to fix, and a frequent language change drops from scanning 16 rows to one click. The capitals question is decided panel-wide, not here.
- Apple check: Direct, specific labels, and a guess shown apart from a choice. Meets the bar. The capitals change strains consistency unless done panel-wide.
- Evidence: Freeform c9b89267-79ec-4a34-b55e-3a9bb9a34e75; Freeform ed2bde90-2880-4e18-9c06-f34378890c3e; Google Translate 0cebf73d-e923-4e12-95eb-af68aac46237; Brink 9b25ef0a-d261-4e81-9eb2-e0b568029915; Notion 56dea59d-358c-43b8-ac1c-99da310e6d7c

## 27. Welcome says what Isla is and what never leaves the Mac
First run (WelcomePane) · effort S · verdict: adopt-with-changes · addresses: new

Keep 'Click it to open' and the Quit footnote. Add a few glyph rows that each name a part of Isla (Music and lyrics, Shelf, Clipboard, Translate), each with one short line, and a data footnote 'Nothing leaves your Mac unless you switch it on' that opens Settings > Privacy. Keep one primary button. It must pass WelcomePane's fit test in Russian at the fixed body height, with en and ru keys. No carousel and no window.

- Why: Every user sees this screen, and the privacy stance is Isla's differentiator. Change: it stays one screen inside the panel, not Stocks-style slides.
- Apple check: Purpose and Responsibility (transparency up front) without marketing chrome. Meets the bar.
- Evidence: Stocks flow 1f3f5507-7875-4313-a1ef-83d77e71c791; Stocks 0a2206aa-3dcc-40fe-a466-2f0b7814aaf6; Klarna c997084b-c986-470f-8507-13d24266d222; Raycast 76d2a569-05bd-4694-8d1a-7dff72ff768f

## 28. Settings rows that could surprise get a one-line description, and the whole row toggles
Settings · effort M · verdict: adopt-with-changes · needs owner decision · addresses: F-052, F-014

Make the full row the Toggle's label and hit target instead of the 24x14 mini switch. Add one persistent secondary line, only on rows whose consequence is not obvious: Translate Online, online Lyrics, Save Clipboard Screenshots, Hide from Screen Recording, Open on Hover, Automatic Updates. Use the secondary token, not tertiary, on fills. Each line must stay on one line at 480 pt in Russian.

- Why: Closes open owner decision 2 and the tertiary-on-fill contrast miss. Change: descriptions only where a user could be surprised, so the scroll stays short.
- Apple check: Familiarity (System Settings row anatomy) and Simplicity (context where it is needed). Meets the bar.
- Evidence: Meetup 9ea56474-24b7-40e9-811b-aa3996dd467c; Todoist af999f34-13d8-4c5d-b9e8-4f128b658865; Garmin Connect 2d08960b-a68f-46c2-8dce-1757bf7cf9bd; Substack 78ef3559-1f61-4bdd-817f-cf2568c2a222

## 29. Slow Mail and Photos drops show a pending card that ends as a card or a retryable failure
Shelf (file promises) · effort M · verdict: adopt-with-changes · addresses: F-035, F-022

At drop time, insert a placeholder card keyed to the promise receiver: a generic type icon, the filename if the promise names one, and an indeterminate ring over the thumbnail (determinate only when progress is known). On arrival, swap it for the real card. On error, turn it into a dimmed card reading 'Couldn't receive' with Retry and Remove. On cancellation, remove it so no phantom card is left. Quick Look and AirDrop are disabled on pending cards. Pending cards must not hold the panel open.

- Why: Closes the silent-promise half of F-035. Change: indeterminate progress by default, because many providers do not report progress.
- Apple check: Feedback (ongoing status, then completion or error in place). Meets the bar.
- Evidence: Grailed bd1f7d69-9877-48e4-adc5-1ee669c842bd; Dropbox 0344b16a-a8e5-442b-a8f9-efddae1ab159; Shopify flow 1ba44287-d376-4694-b4fe-710723007a76; Perplexity 0882801e-93e2-49d0-89ee-dfcbc18ea95b

## 30. Language availability is shown before translating, with a labelled first-use state
Translate · effort M · verdict: adopt-with-changes · addresses: new

Read LanguageAvailability for the chosen pair. When the pair is ready, show nothing. When a language is not installed, the result column shows 'Download Russian' (with the size if the API gives it), which triggers Apple's own download sheet through .translationTask. While the model loads on first use, replace the bare spinner with a labelled line, 'Preparing Russian'. Never show a fake percentage.

- Why: Turns a failure after the fact into a next step, and stops first use from looking like a hang. Change: Apple's system sheet is used, not a custom progress bar.
- Apple check: Feedback: warn before problems and expose ongoing status. Meets the bar.
- Evidence: Meta AI flow cd7115c9-4a4c-4cb8-a945-7581487d09e8; Meta AI d70b7e69-6a14-4793-b4f5-e8da21f71bf0; Google Translate 67d272e8-0813-4ec6-8984-492b656b5fa9; Freeform c9b89267-79ec-4a34-b55e-3a9bb9a34e75

## 31. About and Diagnostics: activate correctly, and disclose before copying
Settings > Application · effort S · verdict: adopt-with-changes · addresses: F-048

Activate before orderFrontStandardAboutPanel and hand activation back, as ShelfSharing does (F-048). Add a version and build line with an update status chip (Up to date, Update available, Not checked). Show the diagnostics footer before the click ('lists versions, settings and Isla's log, nothing you played, copied or translated'), and confirm with Copied. Turn the update-check failure line into a Try Again action row. No sub-page.

- Why: Closes F-048 and moves the reassurance to before the action. Change: the researchers' in-pane About sub-page is dropped, because it adds navigation depth that waits on the keyboard decision.
- Apple check: Responsibility (disclose before data leaves) and Wayfinding. Meets the bar.
- Evidence: Qantas 9362efea-b998-4ace-9400-99c6d4d86bf7; Structured f25a5ade-aef9-48b3-abe6-67469705eeb1; Up c8f73cd3-d071-4056-9bf6-a3def736008c; IKEA 3c236fb0-4755-4e33-9c9e-418eedf8cb47

## 32. Spotify account row: name the account, press twice to disconnect, say what stays
Settings (Spotify account) · effort S · verdict: adopt-with-changes · needs owner decision · addresses: new

Show the connected display name, but only if the existing API call already returns it. Disconnect arms like ConfirmTextButton with the caption 'Isla forgets you on this Mac. Your Spotify library stays as it is. Reconnect any time.' Do not claim the grant is revoked at spotify.com. The result is one inline line, not a toast. In the same section, say that the lock-card heart writes to Liked Songs, pending owner decision 12.

- Why: Disconnect is the one account action and it has no confirmation. The heart disclosure depends on decision 12.
- Apple check: Responsibility (honest about what an account action does) and Agency. Meets the bar.
- Evidence: foodpanda 1677b564-8b7a-4b06-95fa-bb84208d9540; Gmail 6cfe5b8d-5111-425b-b853-b6ee435f50e4; Uber Eats 035eeb71-dd57-4203-9615-5f1bda565dbf

## 33. Long titles: an edge fade at rest, one marquee pass on hover or track change
Now playing panel and lock card · effort S · verdict: adopt-with-changes · addresses: new

Replace tail truncation on title and artist with a trailing edge fade. After a 1.5 s hold, scroll the full title once when the track changes or while the pointer is over it, then stop. Never loop. Under Reduce Motion there is no scroll, and the full title is in a .help tooltip and the accessibilityLabel. No continuous timeline on an idle panel. Layout must not shift.

- Why: Classical titles and podcast episode names become readable. Change: one pass, not a looping marquee, so the idle panel does not get a new 10 Hz-style cost.
- Apple check: Respects the reduced-motion rule against slow looping oscillation, because the scroll runs once and is triggered by the user or a track change. Meets the bar with the change.
- Evidence: Apple Music cc5e5fd9-cb72-48d6-abb9-1d08aa8b0942; Spotify c9cb0602-c90a-4e10-9e03-14be4407c20c; Medium b99fa29d-edb0-4ecc-ae7a-22ea84fa66ae

## 34. Dependent settings dim with a reason, and the OS accessibility settings Isla follows are shown
Settings · effort S · verdict: adopt · addresses: new

When Show Lyrics is off, show Word Karaoke, Lyric Lead and the precision poll dimmed, with a trailing 'Needs Show Lyrics' and the disabled accessibility state plus the reason. When Reduce Motion, Reduce Transparency or Increase Contrast is on, add one read-only line, for example 'Following your Mac: Reduce Motion on'.

- Why: Explains why controls do nothing and why the island stopped moving. Small and honest.
- Apple check: Wayfinding and Feedback (status). Meets the bar.
- Evidence: Reddit 259e494e-3310-42de-99e3-25fe2ca3dcb2; Quizlet dd2ac515-3ea2-4b11-8fe6-03b597f27439; Revolut Business flow 83e1e805-00d8-4a37-9631-f3bdba197de1

## 35. Separate switches for the charger and headphones moments, plus Pause Moments
Settings (ambient moments) · effort M · verdict: adopt-with-changes · addresses: new

Split the single ambient switch into Charger and Headphones. Add Pause Moments with 1 hour and Until Tomorrow. Stay quiet while a fullscreen app is frontmost. Add 'quiet while screen is shared' only if it can be detected without a permission and F-008's live check says capture detection is reliable. Any future moment type ships off by default.

- Why: Gives quiet-by-default real controls. Change: rules limited to what Isla can know without asking.
- Apple check: Flexibility (personalise and hide what you do not use) and Utility (feedback people can turn down). Meets the bar.
- Evidence: Instagram 13d150f2-0591-4ff7-8246-d0a635c1b059; Asana e0b02709-89a1-4f6d-8ecd-d0f6ebd07c2d; GitHub 19a7a142-aebd-4429-b31d-83adcd3895a7; Microsoft Teams 28e15a96-41ff-4b08-8800-7c23f8899453

## 36. An interlude marker that fills as the gap elapses
Lyrics stage and lock card · effort M · verdict: adopt-with-changes · addresses: new

In LyricSweep (the one timeline, no new copy), add a gap rule: before the first line and in any gap of 5 s or more, the slot above the next line shows a small note glyph with a progress fill derived from next timestamp minus now, including the lyric lead. It uses a fixed 40 pt slot so the arithmetic scroll holds, and it is static under Reduce Motion. No breathing loop.

- Why: Intros and solos stop looking frozen or out of sync. Change: a progress fill instead of Apple's breathing dots, which were not captured anyway and are a slow loop.
- Apple check: Status feedback that points toward the next state. The progress fill avoids slow looping oscillation. Meets the bar.
- Evidence: YouTube Music 03a38956-a898-4f03-ad9a-122b1975a909; Deezer e2207979-6b54-40f5-836c-ad8bc810d422; Deezer 4d076e31-d344-49a1-917e-43a909ba0345

## 37. Speak the source or the result, on-device
Translate · effort S · verdict: adopt-with-changes · addresses: new

Add a play glyph with a 24 pt hit target at the bottom trailing corner of each column, using AVSpeechSynthesizer (local, no permission, no network). Disable it when AVSpeechSynthesisVoice has no voice for that language, rather than speaking with the wrong accent. Copy stays in the header.

- Why: Hearing a word is a main reason to open a translator, and it stays on the Mac. Change: the control is disabled when no matching voice exists.
- Apple check: Familiarity (Apple's Translate sheet places play here) and Purpose. Meets the bar.
- Evidence: Freeform c9b89267-79ec-4a34-b55e-3a9bb9a34e75; Messages 79899ce9-2486-4070-a4ec-12dd1fffbfc5; Google Lens af2b18cd-6c8c-4acf-8671-050ac9c43298

## 38. Explain the Automation prompt before it appears, and show its state
Music pane and Settings · effort M · verdict: adopt-with-changes · addresses: new, F-027

First verify in PlayerBridge when the Automation prompt fires today. Then, beside the lyrics precision switch (and in the Music empty state if that is where the prompt arrives), show one line, 'Isla asks macOS once to read the playhead from Spotify', with Continue (which makes the first Apple event on a gesture) and Not now. In Settings, add a compact access group: Spotify and Music automation and Launch at Login, each with Allowed, Not allowed or Not asked yet, read through AEDeterminePermissionToAutomateTarget without asking, plus one Open System Settings action. Show only states Isla can actually read.

- Why: Puts Isla's sentence on screen before the OS sentence, and makes a denial recoverable. Change: verify the trigger first, and no onboarding window.
- Apple check: Responsibility: ask at the right moment, only for what is needed, transparently. Meets the bar.
- Evidence: Cash App a83fa99d-5202-4250-898a-8ccb1745143d; Lovi 0a3b1dd9-7406-4ab4-b067-2a177ac4a6f7; Dot 180d7c84-b631-4ef5-ba8e-c136ed0f7b2f; Keeta 818929b4-954f-4efd-8dfb-54df76e5c1f6

## 39. Keyboard model for list tabs: arrows, Return, Delete, Space for Quick Look, type to filter
Clipboard and Shelf · effort L · verdict: adopt-with-changes · needs owner decision · addresses: F-005, F-004, F-037, F-014

As one deliberate Tier 3 change with the keyboard-navigation decision: let the Clipboard and Shelf tabs request the keyboard through the Translate path and release it on collapse. Up and Down move a visible selected row or card. Clipboard: Return copies, Delete removes, and typing filters on full text, never revealing covered rows, with a 'No matches for "x"' state and a Clear search action. Shelf: Space opens Quick Look and the arrows move the preview. A one-line key-hint strip appears only while the keyboard is in use. Escape keeps closing the panel (fix F-004 first). Use layout-independent shortcuts (F-039).

- Why: The largest accessibility gain left after the P1 fixes, and it brings search to Clipboard. It changes the never-key shell contract, so it must wait for owner decision 1.
- Apple check: Flexibility: desktop means deep workflows with precise keyboard control. Strains the shell's non-activating contract, so the owner must decide.
- Evidence: Juicebox 2af813bf-0129-45d1-81ed-069edee76e16; Magnific 14ceb943-f04a-460f-b4f5-2ebd78d74aff; Revolut Business 52ede146-a46a-46aa-954a-23290f455865; Rodeo a9e8425e-786f-4d05-9685-c6ac6638a781; Apple Notes a52a8ecd-f37a-4945-9b1e-8bcb1cb79153

## 40. Spoken-audio transport: skip 15 and 30, a speed chip, time left
Now playing panel · effort M · verdict: trial-behind-a-switch · addresses: new

Only when a session looks long-form (a known podcast or audiobook bundle, or a duration over about 20 min plus a speech hint), swap previous and next for skip back 15 and forward 30. Use MediaRemote skip commands when they are advertised, and otherwise seek by position as the scrubber does. Show a rate chip such as '1.5x' from playbackRate and a remaining time that accounts for the rate. Hide shuffle and repeat in this mode. Ship it behind a default-off switch until the detection rule proves it will not flip a DJ mix.

- Why: A real fix for podcast listening, but misdetection would break the music transport. A switch keeps the risk opt-in.
- Apple check: Flexibility (adapt to the situation) and Familiarity (the Podcasts vocabulary). Neutral until detection is proven.
- Evidence: Spotify c9cb0602-c90a-4e10-9e03-14be4407c20c; Spotify 8bf33f71-651d-48df-915d-8655331d25eb; Apple Podcasts e3eadea4-23f9-4781-b8fa-57abb3d355be; Brink 9ad1664d-5e1b-4243-bb4f-a2db5abc504f

## Rejected themes

- Chapter-segmented scrubber: Now Playing does not expose chapters for most players, and Isla must not scrape.
- Blurring lyric lines by their distance from the current line: contradicts the recorded opacity-only depth decision (LyricRow comment). Context-line contrast is owner decision 9.
- Light-card variant on the lock card: risks a flash on track change across three styles and Increase Contrast. The luminance-scaled wash (rank 5) is enough.
- Centred glass HUD on the lock card for heart and output changes: repeats what the heart fill, the route caption and the Announcer already show, and adds chrome over the shield.
- Expanding ambient moments on hover, and actions inside a moment (Switch output, Block again): contradicts 'hover only brightens, click opens' and 'the compact island has no controls'.
- Swipe actions on clipboard rows: a touch pattern with no discoverability on macOS that competes with scroll and the pointer-leave fold. Undo and the context menu cover the mis-click problem.
- Type filter chips on Clipboard: only two types exist, and they would add chrome to a deliberately sparse 480 pt panel.
- Pinned clipboard items with persistence: breaks the memory-only promise and drifts toward the withdrawn Snippets tab. The owner can reopen it as a default-off opt-in.
- Share-card export of selected lyric lines: copyright exposure and a growth play rather than a design fix. Deferred unless the owner wants a growth loop with a character cap.
- Inline translated sub-line under the focused lyric: L effort and collides with the fixed 40 pt two-line slots (decision 23). Deferred.
- Below the 40 cut (decent, but lower gain per effort or blocked by open decisions 4, 6, 15 and 23, or by F-028): stacked Translate layout for long text, session-only translation history, link-aware and file-aware clipboard previews, relative times on clipboard rows, lock-style picker cards with preview thumbnails, a ghost outline while dragging the Panel Width slider, release notes in the update row, a Live Activity-style redesign of the Compact lock card, inline shortcut-conflict UI in the recorder.
- Toasts for success where an inline row already answers, full-screen success pages, multi-slide onboarding carousels, tracking-style permission pre-prompts, Apple Music Sing vocal attenuation, podcast transcripts: these conflict with one failure surface per event, the no-window and no-account stance, the one-entitlement rule, or data Isla cannot get.

## Gaps in the research

- Mobbin has no macOS app, notch, menu-bar or lock-screen screens. Every reference is iOS or web and was translated by judgement.
- No music no-lyrics, lyrics-loading or instrumental-gap screens were found apart from one YouTube Music note glyph and one Deezer mic glyph. Apple Music's three-dot interlude was not captured.
- No system volume or brightness HUD, AirPods proximity card or charging moment exists in Mobbin, so the volume HUD question remains a product call.
- Stills carry no motion timing, spring, haptic or VoiceOver behaviour. Contrast is not measurable from previews, so ContrastRampTests must settle every ratio.
- No drag-over state for a web dropzone and no multi-item drag badge were found. The stacked drag image transfers Finder behaviour.
- No pattern was found for AirDrop being unavailable (F-049), for expanding a long clipboard clip, or for keyboard focus inside a non-activating panel (F-004).
- None of the research addresses F-006 (a Shelf card as one accessibility element), F-008 (whether capture exclusion actually works), F-017 and F-018 (Reduce Motion code gaps), F-023 and F-024 (reopen and intents), or the perf-idle cluster beyond F-044. These stay backlog code fixes.
