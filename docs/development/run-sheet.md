# Hardware run sheet

Date: 2026-10-29. Cut from `feat/mobbin-refinements` (head `9e64be4`, the branch the owner's Mac runs), whose `docs/development/checklist.md` holds 172 unticked lines, plus NI-H1 to NI-H3 from `feat/maturity-batch-0`. DU-H8 is already one of the 172, so 175 lines were sorted. Nothing here is a new check and no result is claimed: every line below restates an existing check.

How to use it. Do the sittings in order; each needs one setup and leaves the Mac ready for the next. When a check passes, record the Mac model, macOS version and date beside its ID in `checklist.md` on `feat/mobbin-refinements`, as the checklist already asks. Where a check has lettered sub-steps (R5-H1a to R5-H1e), they are done inside the parent's line. The minutes are rough and include setup.

Counts, by where each of the 175 lines ended up:

- Owner runs in ten sittings: 130
- Could be a test: 17 (16 held by tests since Batch 1, some with a clause left for the owner; 413 stays an owner run)
- Stale: 8
- Not an owner check (umbrella lines, release process, backlog and debt, a marketing task): 18
- Waiting on something outside the Mac: 2

Ordering logic. Sittings 1 and 2 need no special settings. Sitting 3 changes privacy answers. Sitting 4 changes the Mac's language and accessibility switches, so it comes after the ones that expect English. Sitting 5 locks the Mac. Sitting 6 needs a battery in a particular state and can move to any day that provides it. Sitting 7 turns Volume and Brightness on and leaves it on for 8 and 9. Sitting 9 installs updates, so it is after everything that wants the current build left alone. Sitting 10 measures a quiet Mac and goes last.

## Sittings

### Sitting 1 — Everyday island: notched MacBook, built-in display only, English, Panel Width 560, trackpad (about 100 minutes)

Setup: Spotify and Apple Music with something playing, Yandex Music and Safari installed, Ice (the menu-bar manager) running for one step, a Magic Mouse and a wheel mouse for three steps, Lock Screen and Volume and Brightness left as they are. Natural break after the pages group.

1. **R7-H3** Look at the shut island over Aerial, Sonoma and a white wallpaper: the 2 pt stroke shows on each, never on the bare notch (pause everything to get it) and never along the top edge.
2. **R1-H3** Start a new track with the panel shut: the peek's 50 pt growth reads as the island growing, not as a window appearing.
3. **R8-H7** Click a peeking track's far end a few points in from the edge: the player opens, stays while the pointer rests and folds when it walks away, and Escape in another app stays that app's. Repeat with Open on Hover on (it opens once, with no fold and reopen), then off (pause on the far end, let the peek fold, rest there: the next track still peeks).
4. **R8c-H4** From a resting pointer flick to the island and click at once, twenty times: the panel opens every time, never a click on the menu bar behind it, and hover lights on arrival.
5. **R8c-H5** Play in Spotify, Apple Music, Yandex Music and a browser tab in turn: Music's header shows the app's icon and name, and at Panel Width 480 on a wide notch the icon alone, with the name on hover.
6. **R7-H4** With music playing, put files on the Shelf: the bubble sits beside the island, the gap between them passes clicks to the menu bar, a click on the bubble opens the Shelf, a copied screenshot shows the Shelf for about 2 s, a file dropped on the notch keeps it, and "60" fits inside the bubble with room on both sides.
7. **R8d-H6** Same setup, watch the bubble arrive, widen by a digit and go: a click on it opens the tray, a click on the island or on the bare notch still opens the player, and nothing is dead.
8. **R8b-H1** On the trackpad swipe slowly and flicked through all four pages and back: pages follow the fingers 1:1, a flick turns one page, the ends rubber-band, nothing stutters at 120 Hz with Clipboard's list and the player's artwork up, quick presses of two dots carry on without a jump, the Shelf arrives only from Music's right or Translate's left, and a click into Clipboard's search as it settles takes the keyboard first time.
9. **R8b-H3** With a wheel mouse the wheel scrolls the page under it and never turns one, and the dots turn them.
10. **R8b-H2** Repeat the swipes on a Magic Mouse with the same results as R8b-H1.
11. **R8b-H7** Type in Safari and swipe to Clipboard: Safari keeps the keyboard and its caret keeps blinking; ⌃⌥⌘V then ⌃Tab puts the caret in Translate, ⌃⇧Tab twice reaches the Shelf and one more turns to Music rather than switching Safari's tab, and Escape folds the panel; on a Clipboard opened from the bare notch, a row click copies it without stealing the caret and a click into search takes it.
12. **R8b-H9** On Clipboard press Music's dot and leave the pointer: the panel shrinks to Music and stays, and folds once the pointer goes up onto Music and back down past it, or slowly down and left inside where Clipboard was; the same holds when the dot press dropped the search field's keyboard; from Settings the X, three seconds' rest, then a click on a browser tab just right of Music folds Music, and the X returns to the page Settings came from.
13. **R8c-H2** Go Music to gear, Settings to X, and Clipboard away with ⌃⌥⌘V and back: one pane at a time, the old one gone before the new one arrives, the outline growing and shrinking under them with nothing drawn outside it.
14. **R8c-H1** With text in Translate's card, swipe past the last page and hold, then swipe back slowly toward Clipboard: no dark band at the card's foot, neither card crosses the outline or its border, the text stays put and the caret returns when the pages rest.
15. **R8d-H8** Repeat that swipe and flick on Translate with text, then drag a file over the island: nothing crosses the border at any moment of the spring, the Translate stand-in does not flicker, and the drop surface appears in place.
16. **R8-H3** Press ⌃⌥⌘V from Safari: Clipboard opens with the caret in its search, typing narrows the list, arrows move the selection, Return copies and closes, ⌘V in Safari pastes the row, and ⌘, from Clipboard opens Settings and returns the keyboard.
17. **R8-H4** Right-click the island and an open header row over a full-screen app and with Ice running: the menu appears each time. The locked half (a right-click only shakes) is tried in Sitting 5.
18. **R8-H8** Press ⌃⌥⌘I, right-click the header row and press Escape: the menu closes and the panel stays, and a second Escape folds the panel.
19. **MR-H11** Two fingers down over the shut island open what a click opens (the tray over the Shelf bubble), two up on the header or anywhere on the player close it, with natural scrolling on and off, on the trackpad and the Magic Mouse; a short pull settles back, grid and list scrolling is untouched, a sideways swipe still turns pages, Notification Center and Mission Control still work, and a wheel never opens it. The locked half is tried in Sitting 5.
20. **R8d-H2** Click to open and click again halfway a dozen times, and press the gear twice before it lands: the outline turns round without a jump or pause and ends where the state says.
21. **R7-H1** Last in this sitting, because it changes the display scaling: at Default and at More Space the outline is flush with the 14-inch notch with no seam, compact and expanded.

Busy group (start `yes > /dev/null` once per core in a shell, stop it afterwards). Compare against the previous build only if it is still installed; if not, record the eye's verdict and say there was no comparison.

22. **R8d-H1** Open and close from the notch, press the gear and the X, and let alerts come and go, twenty times each: the island's edge moves without steps and content is never drawn outside it.
23. **MR-H18** Click the shut island ten times with music playing, then open on the Shelf bubble and the lyric stage, and close each way: the outline moves in the frame after the click and the body fades in behind it, the cover still flies from the pill, nothing pops in after the fade, and the first open after a fresh launch is as quick as the tenth; do the Reduce Motion repeat in Sitting 4 while it is on, and the 120 fps QuickTime count is optional.
24. **R8e-H1** Press the gear from the player twenty times, then the X: the old pane recedes and is gone, the new one arrives from 0.97, the island grows underneath, and there is never a moment where the pane shows and its form does not.
25. **R8e-H2** The same twenty presses with the Mac busy, judged better, equal or worse than the previous build; this decides whether the 80 ms delay changes or the commit is dropped.
26. **R8e-H3** Open Settings straight from the shut island, and use "Lyrics Settings…" and Music Only from the open player, ten times each: from shut the form arrives with the opening, from the player as the gear does, never a blank body that fills late.
27. **R8e-H6** Settings to player with the X, twenty times: unchanged from the previous build.
28. **R8d-H9** In Activity Monitor watch GPU history and Energy for Isla with the panel shut and music playing and the caption on, then open on the player for a minute: no higher than on the previous build.

### Sitting 2 — Real songs and accounts: Spotify account connected, Yandex Music and Apple Music, network switchable (about 100 minutes)

Setup: a Spotify account that is not listed in Isla's Spotify dashboard and one that is, Network Link Conditioner installed, Wi-Fi switchable, Lyrics on with online lyrics, Show Next Line Early on Auto, Safari with a YouTube video. Use the named tracks where a check names them.

1. **936** In the Spotify developer dashboard (Users and Access) see whether Isla's app is still in development mode; this explains the next two steps.
2. **MR-H17** In Settings › Connections check the player list and icons (uninstall one and see its row go), then press Connect with the unlisted account (one line says Spotify has not admitted it and no star ever shows), cancel the consent page ("Spotify sign-in was cancelled."), turn the network off ("Isla couldn't reach Spotify."), then use the listed account (line clears, row shows Disconnect, the star works), with the `log show` trail showing each step and no token.
3. **1433** Press Connect twice and approve the first tab: the account connects; then Disconnect and Connect again: Spotify's consent page appears with its "Not you?" switch.
4. **R8-H6** Favourite in Music (the star follows Music's own heart both ways, and on a catalogue song not in the library one tap fills the star and it stays filled) and in Spotify with the account connected.
5. **MR-H3** The star shows for Music and a connected Spotify on the player and the lock card and the song really becomes a favourite; it is absent for Yandex Music and a browser.
6. **R8-H5** On a synced song the player's sung line turns with the voice, and a long line wraps to two on the stage.
7. **1471** On a track that sings continuously, with the island shut, the next line is on screen about half a second before the voice and turns with the caption turn; across a long instrumental it waits for the previous line's end; Off restores the on-the-voice turn.
8. **1488** On the ballad Auto feels like the 0.5 s that was perfect, and on a faster song with shorter lines it turns about 0.35 to 0.45 s early without feeling like too much.
9. **1506** On "We Are The People" by Empire Of The Sun from Yandex Music the notice shows on the stage; right-click the sung line and choose Sync Here: lines land on the voice, the notice goes, Reset brings it back, and the compact caption and lock card show no notice but follow the sync.
10. **MR-H6** Context lyric lines dim faster and stay legible under Increase Contrast.
11. **MR-H2** The stage's previous, play and next look like the player's and the lock card's, and dragging the stage's bar seeks.
12. **MR-H4** The waveform takes the cover's colour and is white with no artwork, and the header's app icon reads as small as an iPhone Live Activity's.
13. **R1-H6** Translate Lyrics on a Russian or English song: the translations arrive together and sit under each line.
14. **R1-H7** The Output menu, the stage's More menu and the translation menu (right-click on Show Translation) open under their buttons from the non-activating panel, and `.help` tooltips appear. Skip the slider-row clause, which was withdrawn (see Stale).
15. **MR-H9** Skip ten times in Spotify and ten in Music, from Isla and from the player, fast and slow, on a fast and on a throttled network (3G profile): one swap per song on the shut island, player, stage and lock card, with title, artist, cover and equalizer colour together, never a new title over the old cover, never the wrong song's lyrics; Reduce Motion makes it a fade.
16. **MR-H14** With Spotify playing, open the stage and press the speaker: macOS asks once about controlling Spotify, the slider moves Spotify's own volume and not the menu bar's, it folds 3 s after letting go, Music behaves the same, Safari (YouTube) moves the Mac's volume, and after denying Isla under Automation for Spotify the slider moves the Mac's volume and shows "Allow Isla to control Spotify…"; VoiceOver says "Spotify volume, N percent". Restore the permission afterwards.
17. **1363** With Translate Online on, translate one Uzbek sentence, quit Isla, then run the `sqlite3` count from the checklist: it answers 0 or the file is absent; also confirm Spotify still connects, refreshes and hearts a track, and an update check still answers.
18. **MR-H19** Translate English to Russian with Russian not downloaded and Apple Intelligence off, type "salom": the card says Russian is not downloaded; Use Online replaces it with a spinner in the same frame and the answer follows, " dunyo" translates without a second press, changing the target, Clear or closing the panel brings the card back and sends nothing, network off gives one alert with Try Again, and a downloaded Russian answers on the Mac.

### Sitting 3 — Files and clipboard: fresh folder privacy, Finder, Safari, Mail, TextEdit, Terminal (about 90 minutes)

Setup: run `tccutil reset` for the Desktop, Documents and Downloads folder services only (never Accessibility), have fourteen files of different kinds and a Finder window in icon view, set screenshots to save to `~/Pictures`, and have an AirDrop-capable Mac or phone nearby.

1. **1050** After the reset, with captures set to `~/Pictures`, opening the Shelf raises no Desktop prompt, and every prompt that does appear names what triggered it.
2. **427** Protected Shelf files prompt only when the Shelf is opened or used, never at launch. Only macOS's prompt is left here: that a launch never passes over the files is held by tests (see Held by tests since Batch 6).
3. **R3-H1** Three Finder files dragged in land as icons, and the same drag over AirDrop sends without keeping.
4. **R8-H2** A Finder drag onto the notch lights Keep on Shelf and AirDrop under the pointer; a drop on Keep on Shelf keeps the file and one on AirDrop opens the AirDrop sheet with it.
5. **R3-H2** Delete with the pointer on the Shelf removes the selection and never the files.
6. **R3-H5** With Mail frontmost and the pointer resting on the Shelf, ⌫ deletes text in Mail unless a tile was selected during this opening, and reopening shows no selection.
7. **R8b-H4** With fourteen files the tray shows tiles in rows (six at 560, five at 480), two rows and part of a third, two fingers and a wheel scroll the grid with fades, a quick sideways swipe turns the page and never moves the grid, and turning between Shelf, Clipboard and Translate moves neither the outline nor the dots.
8. **MR-H13** Put the same files in a Finder icon-view window beside the tray: no plate behind any tile, name 12 regular in two lines with the second cut in the middle, grey date under it, a picked tile is a grey rounded square behind the icon with the name on a pill in the Highlight colour (change Highlight with the tray open), ⌘ and ⇧ clicks pick several, the remove badge shows on hovered or picked tiles, a re-dropped file flashes its ring, and light mode and Increase Contrast still read.
9. **1337** A Desktop card dragged into a Finder folder copies it (original stays, "+" badge), a ⌘-drag moves it and the double-click opens the moved file, ⌘-dragging onto the Trash removes the card, and pressing ⌘ mid-drag turns copy into move; the thumbnail stays under the pointer where grabbed.
10. **MR-H5** "Lyrics imported", "Copied" (Return in Clipboard) and "Added to Shelf" show on the island for about 1.5 s when the panel is shut. Skip the "never over the open panel" clause, which was superseded (see Stale).
11. **R3-H7** With Paste from Other Apps on Ask, copying a picture with history on asks once and never twice.
12. **R4-H5** On Ask, opening Translate raises no alert and pressing Paste raises macOS's alert once. The rest is held by tests (see Held by tests since Batch 6).
13. **R8c-H8** With a lyric playing and the panel on Clipboard, copy ten screenshots (⌃⌘⇧4) and ten browser or editor pictures and paste each into an agent window: the lyric sweep and hover never stutter, every picture is in the history (and on the Shelf with Save Clipboard Screenshots on), two copies within a second keep the second, ⌘V with ⌥⌘T pressed at once ten times with the Translate field focused does not crash, the Ask alert appears once with Isla staying responsive, and Instruments shows the `pasteboard read` interval off the main thread.
14. **1157** Under Don't Allow the Clipboard page shows the sentence and Open Privacy Settings lands on Paste from Other Apps (record if it lands on the Privacy & Security root); set Allow, reopen, copy: the copy appears without a relaunch, and Copy Diagnostics shows the state each time.
15. **R3-H3** An image copied in Safari appears under Images in Clipboard and pastes back.
16. **R4-H9** With a Japanese input method, type into a Translate source holding 20,000 characters: the letter is refused and the field does not show it. The plain-keyboard half is held by tests (see Held by tests since Batch 6).
17. **R4-H2** Speak in a Russian and an English voice: each speaks, and Stop Speaking stops.
18. **1077** ⌃⌥⌘I then Escape closes the panel; ⌃⌥⌘I then ⌘-Tab closes it; ⌃⌥⌘L then Escape closes it; with no pin up Escape still reaches TextEdit and Terminal; in Translate with text the first Escape clears and the second closes; a click-open never steals the caret; with Quick Look open from a pinned Shelf, Escape closes Quick Look and not the panel; and no "macOS refused the transient Escape hot key" line is logged.
19. **431** Quit and relaunch, with launch at login on and the Mac logged out and in: the island returns each time. The deleted-file clause is held by tests (see Held by tests since Batch 6); the unavailable-helper clause by `NowPlayingLifecycleTests`.
20. **1397** With the panel open, run the Show Isla Shortcut (the panel stays open) and Show Lyrics (the lyric page stays up), and open Spotlight then Isla while it runs; do not launch the copy in `build/` (the project forbids it, see Stale) and run `./scripts/check lifecycle` with the installed copy running.

### Sitting 4 — Mac in Russian, Settings, Panel Width sweeps, VoiceOver and Reduce Motion (about 70 minutes)

Setup: switch the Mac's language to Russian (log out and in) before the first step; switch back to English at the end. Keep Panel Width at 480, 560 and 620 in turn, dark appearance, and have VoiceOver and Reduce Motion ready to toggle.

1. **1048** On the Russian Mac take ⇧⌘3 to a file: the still arrives on the Shelf the next time it opens.
2. **780** In Settings click the words "Launch at Login": the switch flips; VoiceOver reads the row as a switch or toggle button, on or off; Graphite and Yellow accents look right. The line itself was closed by SET-01; these three looks are what remained owed.
3. **MR-H16** Open every Settings section beside System Settings, dark and Russian, at 480, 560 and 620: 13 pt labels, grey 11 pt footers, System Settings' row height, no edge round groups, its own icons in the sidebar and Isla's in About; changing the accent colour with Settings open recolours the selection, switches, sliders, segmented controls, buttons, Update Now, shortcut ring and Lock Screen style ring; every segment of Show Next Line Early and the Lock Screen style takes one click even though the panel is not key; pop-ups open on the first click from another app; Increase Contrast keeps outlines; Russian sidebar titles do not truncate.
4. **R4-H4** Translate's pop-ups open from the panel with the chosen item over the button at 480, 560 and 620, and Recent lists this session's targets.
5. **1269** With VoiceOver on, the rotor's Headings in each Settings section list that section's group headers. The rest is held by tests since Batch 5 (below).
6. **940** With VoiceOver on press ⌃⌥⌘L and ⌃⌥⌘T, which are also VO-⌘-L and VO-⌘-T, and record which one wins.
7. **R8e-H5** After the gear, VoiceOver reads Settings and finds the sidebar and first switch without a second navigation, Tab from the header reaches the sidebar, and pressing a sidebar section changes the form as before.
8. **R7-H2** With Reduce Motion off the overshoot reads as the island growing and not a bounce; then with it on the island changes size calmly and content only crossfades.
9. **R8b-H6** With Reduce Motion on, a dot and ⌃Tab crossfade in place, and a swipe still follows the fingers and settles without overshoot.
10. **R8d-H3** With Reduce Motion on, the outline changes size on the 0.24 s ease-in-out with no overshoot and the line and shadow fade with it.
11. **R8e-H4** With Reduce Motion on, the gear and the X are the plain fade out and in, in the same order, with the form there as the new pane becomes visible.

### Sitting 5 — Lock screen: notched MacBook, Lock Screen layout set to Card (about 75 minutes)

Setup: wallpapers Aerial, Pro Black, Sonoma, Sky Blue and plain white; tracks with a white or pastel cover, a dark cover, no cover (a podcast or browser tab) and one with lyrics; AirPods for the output step. The R2 lines describe the Card layout (banner and card); the Full Screen layout has no open check of its own.

1. **R2-H1** The banner under the clock reads on Aerial, Pro Black, Sonoma and Sky Blue.
2. **R2-H2** A click turns the banner into the card and the chevron turns the card back, the card growing in place.
3. **R2-H3** At Automatic the lyric reads over Aerial's bright lines.
4. **R2-H4** The output pane switches to AirPods, with the haptic.
5. **R2-H5** No wings at the notch while the banner or card shows, and a click on the notch still shakes. Skip the no-wings clause for volume and charger pills, which may now show (see Stale).
6. **R2-H6** A song with no cover at Automatic leaves the card mostly solid with every line readable.
7. **R2-H7** Transparent over Sky Blue and a white wallpaper raises the black enough that the artist line and times read, and over Aerial it stays at 0.30.
8. **R2-H8** Picking a device on the Output pane stays on the pane, and with Rest as Banner off the card otherwise behaves as before.
9. **1012** Lock with a white or pastel cover playing, in Tinted and in Transparent: the artist line, times and lyric status read; a dark cover looks as it did before.
10. **1304** Look at the lock card over a pale cover for depth, and (in a dark room) at the lyric stage, with the narrower floor-to-neighbour step.
11. **752** On a locked macOS 26 Mac with a coverless song, say whether the card reads well (recipe over recipe); if the system material read better, amend the record, not the code.
12. **R4-H3** Compare Settings › Lock Screen's style previews with the real lock screen: they match.
13. **1231** Pause a song unlocked and over the lock screen: the fold leaves no bare black wing and no snap; then hover the resting island and step a lyric line with decision 18 in mind.
14. **931** Lock and unlock with the card on and off, and plug a display in while locked: the card and space come back correctly.
15. **425** Repeat lock and unlock several times, including after display sleep: the card appears centred at its own size every time.
16. **R8d-H5** Lock and unlock with the panel shut and a song playing, and with the panel open: the pill over the shield is as before and on unlock the island returns once, in place, with no stale outline or mask.

Also while locked, try the two locked halves left in Sitting 1: a right-click on the island only shakes (R8-H4) and a two-finger pull down shakes and opens nothing (MR-H11).

### Sitting 6 — Charger and AirPods: a MacBook with MagSafe, Apple's 61 W USB-C charger, a USB-C display or hub, AirPods, Optimized Battery Charging (about 45 minutes plus waiting)

Setup: start below 80 percent, panel shut, pointer away. The last step needs the battery to be holding at 80 percent, which may be a different day.

1. **955** Plug in a charger, connect AirPods, and use Quick Look and AirDrop from a Shelf card: the pills show, and both system panels open from the app.
2. **MR-H22** Open the panel on Music and plug a charger: about 0.6 s later the capsule 6 pt under the panel shows "61 W" or "MagSafe" with the level and a green line for 3 s and folds; AirPods show "Connected" for 4 s; "Copied" and "Added to Shelf" show in the capsule; a volume key takes it over; a page turn carries it; Return in Clipboard shows "Copied" on the shut island instead; shut, each still shows on the island.
3. **MR-H15** With the panel shut, MagSafe shows "MagSafe", the level and a green ring with a bolt for 3 s, a USB-C charger shows "61 W" with a battery and bolt, a USB-C display alone shows nothing, unplug shows nothing, below 20 percent the colours are red, a replug within 5 s of the pointer leaving shows and within 30 s of a shown moment does not; VoiceOver speaks the charging phrases.
4. **MR-H24** Plug the 61 W charger in below 80 percent: the island grows with the menu bar's bolt reading "61 W" in green, and shows again after a 2 s unplug, with the pointer on the island and over a full-screen app; repeat with MagSafe; and (at the hold) "On Hold" from the first frame.
5. **MR-H21** At the 80 percent hold the 61 W charger reads "61 W On Hold" with "80%", a white battery with no bolt and a white line, MagSafe reads "MagSafe On Hold" with the white ring, Russian reads "61 Вт Пауза" and "MagSafe Пауза", and the `ioreg` reason value is recorded beside what the pill said.

### Sitting 7 — Volume and Brightness on, Accessibility granted: AirPods, EarPods, an external keyboard (about 80 minutes)

Setup: switch Volume and Brightness on and grant Accessibility; leave both on for Sittings 8 and 9. Music playing throughout.

1. **R5-H1** Turn it on and grant Accessibility: the volume keys show Isla's pop-up and never the Mac's, and the keys work without removing and re-adding Isla. Run the sub-steps with it: **R5-H1a** with a stale entry the prompt shows and the keys work after granting; **R5-H1c** declining is not asked again at the next launch of the same code but the footnote shows, and off and on asks again; **R5-H1d** on a Mac with no Isla entry the prompt shows and no footnote appears if you grant within 30 s; **R5-H1e** is done at the end of this sitting. R5-H1b is in Sitting 9.
2. **R5-H2** Mute keeps the level, dimmed, and unmute restores it.
3. **R5-H3** The display and keyboard brightness keys work on the MacBook Pro.
4. **R5-H4** Turning the setting off gives the keys back at once.
5. **R5-H5** An external keyboard's volume keys behave the same.
6. **R5-H6** Volume down while muted: compare with the Mac's own pop-up (Isla keeps the Mac muted).
7. **R5-H9** AirPods connecting while a volume key is held never jump their volume.
8. **R5-H10** The Settings sidebar and the Spotify head show Spotify's own icon, About's Isla icon matches the tiles, and Players on This Mac lists Яндекс Музыка and both Telegrams with their icons.
9. **R7-H5** AirPods connecting shows the expanded headphones alert, and the volume keys show the expanded pop-up with the output's name, the bar and the number. Skip "the amber bar": it was made plain white (see Stale).
10. **R8c-H3** With the Mac busy, volume up, down and mute and brightness, tapped and held: the pop-up appears with the first press, the bar follows with no lag or overshoot, a held key moves smoothly, and a refused output (HDMI with no volume) shows nothing and macOS answers.
11. **MR-H7** With the panel open on each surface (player, Shelf, Clipboard, Translate, stage, Settings) a volume, mute and brightness press draws the 32 pt capsule 6 pt under the body, centred, covering nothing, click-through, folding 1.5 s after the last press, at 480 and 620, under Increase Contrast and Reduce Motion, with VoiceOver saying the level once; the unnotched half is done in Sitting 8 when the external display is connected.
12. **MR-H8** Holding volume-up and brightness-up the bar stays on the level the number says on every frame, with no trail, no hesitation on the first press and no replay after a main-thread stall (build something), as light as the system's own.
13. **MR-H10** Hold volume up for 3 s then down on the built-in speakers, EarPods and AirPods: the bar moves with every repeat, stops the instant the key is released, takes no catch-up steps, and the menu-bar slider then the key steps from where the slider left it; AirPods connecting mid-hold are never set to the speakers' level; mute still toggles; with the setting off the system pop-up appears unchanged.
14. **MR-H25** With the same song hold volume up and down for 10 s with the setting on, then off: crackle in both is memory pressure; crackle only with it on is reported with the time.
15. **MR-H23** With Show on Lock Screen on and music playing, lock (⌃⌘Q) and press volume up, down, mute and brightness: the island shows the compact pill and not the system's OSD, the level really changes, the card's bar moves and is not covered, the pill folds 1.5 s later, a click shakes, and a charger plug shows its 3 s pill; after unlocking record "N heard, M taken" from the log (if N is 0 the system's OSD is the correct result); with Show on Lock Screen off the OSD is the system's.
16. **R5-H1e** Relaunch Isla onto a locked Mac and onto a dark display with the setting on and a stale entry: nothing is reset and no prompt shows behind the lock; the first awake, unlocked moment repairs and prompts once.

### Sitting 8 — External display: notched built-in plus an external display and a USB-C connection, lid closable (about 35 minutes)

Setup: start with only the built-in display, then connect the external one.

1. **NI-H2** On the notched Mac with Show on Built-in Display off and no other display, nothing is drawn at the notch and clicks and hovers reach the menu bar; ⌃⌥⌘I, ⌃⌥⌘V, ⌃⌥⌘T and Spotlight open the panel, which fades out after it folds; no peek, charger or headphones pill shows; a volume key shows macOS's own pop-up; plugging a display in or waking with the pointer at top centre opens nothing; turning the switch back on restores the island at once.
2. **NI-H3** With an external display connected the island moves to it, synthetic, and works as on any notchless display; unplugging it falls back to NI-H2.
3. **429** Walk the player, Shelf, Clipboard, Translate and Settings, a charger and a pop-up, on the external display with the synthetic notch.
4. **R8d-H4** The player over a busy window has the same soft shadow as before, none under the compact island, the peek or the charger; the line is 2 pt and crisp on the built-in display and the external one, with no seam along the top edge or hairline between black and line; Increase Contrast raises it; the charger's line is green.
5. **R5-H8** With the external display as main, and again with the lid closed, the brightness keys go to macOS.

### Sitting 9 — Update feed: a clean committed checkout, `Scripts/publish-dev-update.sh`, Volume and Brightness on, Spotify connected (about 60 minutes)

Setup: stay on the feed build; publish builds one at a time and wait for each to be offered. A screen saver with a password grace and a second user account are needed for DU-H6.

1. **DU-H4** Open the panel while the alert shows: it goes with the open and returns when the panel closes, and a volume key over it replaces it with the pop-up and it returns after.
2. **DU-H3** Press Later: the alert folds, the gear keeps its badge, the same version is not offered again and the next published build is; left alone it folds after 20 s, and not while the pointer rests on it.
3. **DU-H6** With Show on Lock Screen off, publish a build and lock the Mac before it is offered: nothing shows under the shield and the alert appears after the unlock; repeat with the screen saver running and with another user switched in.
4. **DU-H7** Run `rm -rf .dev-updates`, then publish: the new folder is found and the build offered within a few seconds without relaunching Isla.
5. **DU-H1** Install the offered build: the alert shows within about two seconds of publishing, it downloads, verifies and restarts as the new version (Settings › About says so), `hdiutil info` shows nothing mounted and no `.Isla-update-*` is left beside the app.
6. **R5-H1b** After that update, with Volume and Brightness already on, the first launch of the new build shows the Accessibility prompt once; the same after a development reinstall with the same build number.
7. **DU-H5** Record what macOS said about App Management on the first update through the feed (prompt, "prevented from modifying apps" notice, or nothing) and whether the first publish asked to allow the keychain read of "Isla Dev Update Signing"; if this was already seen, record it from memory and say so.
8. **DU-H2** Accessibility (the pop-up), Spotify and the Settings choices survived the update.
9. **DU-H8** Install from a build that judges the detach by `hdiutil info`: it installs even when macOS is slow to eject, and the log says "a detach try did not exit cleanly, but the disk image is gone" when that happened. This cannot be forced; tick it on the first update where the eject is slow, and keep the line open until then.

### Sitting 10 — Measurements: a quiet Mac, nothing else running, AirPods for one step (about 50 minutes plus 5-minute runs)

Setup: no builds, no `yes`, display awake; run from the main checkout.

1. **433** Run `bash Scripts/measure-idle.sh closed-idle` (5 min) and `closed-playing` (5 min) and compare with the budget (CPU at or below 0.1 percent, RSS at or below 88 MB); the parity comparison against Cyclop 0.6.5 needs a reference build from `Scripts/build-reference.sh` and has been blocked since the earlier result of 0.3 percent CPU and 19.05 against 19.03 MiB helper RSS.
2. **730** The full `Scripts/measure-performance.sh` run against that same Cyclop build; it is the same run as the comparison in step 1.
3. **420** Run `Scripts/measure-sync.sh` against a live Spotify and against Apple Music: word timing at or below 150 ms at the 95th percentile, or the publisher stays line-level.
4. **1186** In the S-LEAD owner session, per player and per route (built-in speakers, AirPods), put CoreAudio's reported latency from the trail beside the by-ear correction.

## Stale

- **412** "Every tab passes its workflow": tabs and the rail were withdrawn (spec §19.11, release R8, `SurfaceContractTests`); the pages are covered by Sittings 1 and 3.
- **R1-H1** The 300 pt island with 8 pt margins: the 300 pt island and 40 pt wings were withdrawn (decision 2, spec §19.11); widths are now §19.4's `nw + 70`, and R7-H1 checks the current outline.
- **R1-H2** The key line: §3.3's key line was withdrawn (spec §19.11) in favour of the 2 pt stroke in §19.3, which R7-H3 checks.
- **R1-H4** Player to lyric column to tall page: the lyric column and tall page were withdrawn (spec §19.11 and §19.6, "the stage is the one lyric surface"); MR-H18 covers opening the stage.
- **R1-H5** The player's volume slider: volume left the island on 2026-10-16 (spec §4.5 amendment, "The player ... draw no volume bar"); the Output menu half is in R1-H7 and R2-H4.
- **R1-H8** Translations re-spacing the column and tall page, and the tall page's growth: the same withdrawal as R1-H4.
- **R4-H6** "Use Online ... sends once": MR-H19 says it supersedes this (spec §11 amendment of 2026-10-26).
- **1832** The lab's Shelf case "is stale since R3": already fixed, `VisualLabPanelTests.testShelf` now expects "Release to add to the Shelf" and "Send to a nearby device" (changed in commit `92827da`).

The five "tab" lines in 433's idle table (`tab-music`, `tab-settings`, `tab-shelf`, `tab-clipboard` and the "After MS-12 and MS-13: the four tab rows again" row) are stale for the same reason as 412; there are no tabs to open. Only `closed-idle` and `closed-playing` remain meaningful, and Sitting 10 uses them.

Stale in part, kept as owner runs or tests with the clause dropped:

- **R1-H7** the slider row inside the Output menu below 540 pt (withdrawn, spec §4.5).
- **R2-H5** "no wings while the banner or card shows": spec §3.7, amended 2026-10-26, lets the volume pop-up and the charger take the locked island's wings (see MR-H23).
- **R7-H5** "the amber bar": the pop-up was made plain white on 2026-10-18 (spec §12 amendment).
- **MR-H5** "never over the open panel": MR-H22 (spec §19.5 d, 2026-10-26) shows every alert under the open panel.
- **R8-H1** lists Tools among the surfaces: Tools was withdrawn on 2026-10-18 (spec §19.16).
- **R8c-H6** "each tile shows its day over its time": MR-H13 (spec §8, 2026-10-26) replaced it with the name over a grey date.
- **R8d-H1 and R8e-H2** compare with the R8c and R8d builds, which are no longer installed.
- **413** and **1157** say "lyrics page" and "Clipboard tab", now the stage and the Clipboard page; the behaviour is unchanged.
- **1397** asks for the copy in `build/` to be launched from Finder; CLAUDE.md forbids opening that bundle because each launch registers a second Isla with LaunchServices.

## Held by tests since Batch 6 (2026-10-29)

- **R4-H9**, all but the Japanese input method: a letter typed into the
  middle of a full source is refused by the model
  (`TranslateReviewFixTests.testAnInsertionPastTheLimitIsRefused`) and is
  gone from the real `NSTextView` behind the field too, a second refusal
  included, while a letter typed once there is room lands
  (`testTheEditorOfAFullFieldDoesNotShowARefusedLetter`). Writing that test
  showed the source's comment was wrong about why: the editor puts the old
  text back by itself, with or without the refusal's publication. The
  comment now says so; no behaviour changed.
- **R4-H5**, all but macOS's own alert: opening Translate reads nothing
  from the pasteboard and Paste reads once
  (`TranslatePasteTests.testOpeningTheTabReadsNothingAndShowsPasteEnabled`,
  `testPressingPasteFillsTheFieldAndReadsOnce`, counted by a lazy item that
  is asked for bytes only on a real read); under Don't Allow, Paste is off
  and its tooltip says why
  (`TranslateReviewFixTests.testPasteIsDisabledUnderDontAllowWithAReason`).
- **427** and **431**, the logic: a launch makes no pass over the Shelf's
  files, and only the tray coming into view makes one, once per arrival
  (`FirstRunTests.testALaunchNeverPassesOverTheShelfAndEachArrivalOnTheTrayDoesOnce`);
  that pass evicts a card whose file was deleted
  (`ShelfStoreTests.testRefreshFromDiskEvictsACardWhoseFileWasDeleted`)
  or put in the Trash (`testAFileInTheTrashIsGoneAndIsNotReloaded`) and
  keeps one it cannot read (`testRefreshFromDiskKeepsACardWhoseFileExistsButIsUnreadable`).
  Until the tray is opened after a relaunch, the bubble still counts a
  deleted file: by design, since looking sooner is what would raise the
  folder prompts at launch.

## Held by tests since Batch 5 (2026-10-29)

- **1269**, all but the rotor: VO-Up on Panel Width commits at once and once
  (`SettingsAccessibilityTests.testAVoiceOverStepCommitsTheWidth`, macOS 27);
  each section's group headers are headings
  (`testGroupHeadersAreHeadings`); and Russian VoiceOver hears
  "пунктов: 560", never the "560 пт" it used to hear, «Пт» being how Russian
  writes Friday (`testRussianVoiceOverHearsPointsNotAWeekday`; the bug was
  real and is fixed). "Glass reads as a radio group" is stale: the Glass row
  left Settings on 2026-10-15.

## Held by tests since Batch 1 (2026-10-29)

These no longer need a sitting, except for the clause named after "owner".
Each was either already held by a test (named) or got one; all run in
`./scripts/check`.

- **415** `LyricCaptionStatesTests`: every caption state says something.
- **422** `LocalLyricsLibraryTests.testAnIndexedFolderIsReadyAfterLaunch`,
  `testARescanNeverReplacesAShownLyricWithALowerConfidenceCandidate`, and
  `LyricsCoordinatorTests.testARescanThatTiesWithTheShownLyricKeepsItShown`.
  The last one found a bug, now fixed: a rescan that found a second copy of
  the playing song replaced the lyric on screen with "Choose local lyrics…".
- **982** `LyricSweepTests.testTheSignMigrationKeepsEveryListenersTiming`,
  `LyricDelayCopyTests.testAnUpgradedDelayReadsPlusWhereItReadMinusAndMovesNoLine`.
- **1113** `ConfirmationTests` (durations, Escape, VoiceOver, the lapse and the
  second press). Owner: the word stays red while the pointer rests on it.
- **R4-H7** `PanelLayoutSweepTests.testTranslatesAlertCardsFitTheCardInRussianAt480`.
  Owner: the "…" is drawn on a cut pop-up label.
- **R5-H7** `MediaKeyDecoderTests`, `MediaKeyHUDTests`. Owner: macOS's own
  answer to ⌥ (Sound settings) and ⇧ (silent step), which Isla leaves to it.
- **R8-H1**, **R8b-H8**, **R8c-H6**, **MR-H1**, **MR-H20**
  `PanelLayoutSweepTests` (every surface in Russian at 480 and 620, the dots
  and gear, the headers, one well size). Owner: text that truncates inside its
  own box, and a hover lightening each well.
- **R8b-H5** `PageDotsTests`. Owner: one real VoiceOver pass for the keyboard
  claim.
- **R8b-H10** `PlayerPaneTests.testEveryHonouredPauseOfAnLrcWithEndStampsHoldsTheComingLineDim`.
  Note: the sweep honours pauses of 1.5 s or more (`LyricSweep.minimumHonouredGap`),
  not "a second or more" as the check says; a 1 s breath keeps the line lit.
- **R8c-H7** `ClipboardImageMemoryTests` (ten 20 MB copies grew memory by
  23 MB against a 50 MB bound; the oldest pastes byte for byte).
- **R8d-H7** `IslandAccessibilityTests`, `IslandOutlineHostTests.testTheLayerViewsTakeNoEvents`.
- **MR-H12** `HUDStripPlacementTests`, `HUDStripTests`.

Still an owner run: **413** (the lyric stage scrolled both ways). A test that
fed real scroll events through the app passed once and then failed on the same
code, because whether the events arrive depends on the window server and the
pointer, so it was not kept.

## Waiting on something outside the Mac

- **NI-H1** Needs Apple to name the new MacBook Pro's model identifiers (support.apple.com/108052) and one of those Macs; then add them to `NativeIsland.models` and record `sysctl hw.model` and the built-in display's insets.
- **934** The Intel slice has only been built, never run; it needs an Intel Mac.

## Not an owner check

Umbrella lines that pass when the lines above pass:

- **418** (validation across notch, lock card, offline, folders, VoiceOver, Reduce Motion, languages and local LRC), **428** (physical notch) and **430** (English and Russian layouts; the string half is also `Scripts/test-localizations.sh`).

Release process, owned by CI and `Scripts/release.sh` rather than a hardware sitting:

- **457** and **488** (Developer ID signing, notarization, stapling; I could not confirm from the checklist whether the 0.4.0 CI release closed them, so check the release workflow's output), **464**, **465**, **467**, **468**, **469** (release-gate evidence, audit close-out, clean release commit, release notes, `Scripts/release.sh`).

Backlog and debt, not checks:

- **713** next-track prefetch, **742** word-level fetched lyrics, **747** per-source bias, **774** focus rings and panel shortcuts (⌘, now exists), **785** `collapseRectShrinkDelay` tied to a spring by comment, **787** a deprecated `GenerationOptions(sampling:)` call, **790** `scripts/check` casing.
- **939** README screenshots, which need the live app on the owner's screen.
