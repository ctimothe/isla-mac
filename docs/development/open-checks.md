# Open checks

What is still owed: hardware checks that only a person at a notched MacBook can
run, and findings and decisions that are still open. Nothing here is done.

**When you tick a check, record the Mac model, the macOS version and the date
beside its ID**, then delete the line in the same commit (git keeps it). A check
that a test now holds completely is deleted, not ticked; when a test holds part
of a check, only the part a person must see stays here.

Checks are grouped by what they need set up, roughly in the order they are best
run: everyday use first, then privacy answers, language and accessibility
switches, the lock screen, power, Volume and Brightness, an external display,
the update feed, and measurements on a quiet Mac last.

## The island and its activities

- **IC2-H1** Every surface on the owner's notch, over a light and a dark
  wallpaper: the island's activities, the player and its transport, the lyric
  stage, the Shelf, Clipboard, Translate, Settings' rows and sidebar, the lock
  card, the volume pop-up, the right-click and Output menus. No glyph is
  missing, cut off or a different size from its neighbours; the menus tint
  theirs.
- **IC2-H2** AirPods (and any Beats or HomePod at hand) as the output: the
  Output menu, the headphones alert, the volume pop-up and the lock card draw
  that model's own shape, the same size as the Hugeicons glyphs beside it.
- **IC2-H3** Skip a song in Spotify and in Music with the panel shut: the new
  track drops under the notch exactly as a volume press does (same shape, same
  speed in and out, no sideways widening), holds about 2 s and folds back into
  the song's pill. A volume key while it shows takes over in place; a skip
  during its hold keeps it and swaps the cover; a click opens the player;
  Reduce Motion makes it a crossfade; a long title or artist ends in an
  ellipsis inside the shape, never under the camera. With Open on Hover on and
  the pointer resting under the notch, a skip shows the alert and does not
  open the panel.
- **IC-H1** The per-change springs on the owner's notch (appear, expand, fold,
  dismiss): nothing overshoots past the bezel.
- **IC-H3** A 1-minute timer from the right-click menu: the wings count down; a
  click opens pause and cancel, which fold after 6 s; Timer Done shows with the
  Glass sound. Install an update mid-timer: the timer is still there.
- **IC-H4** Microphone and Camera on, a FaceTime call: the activity shows with
  FaceTime's icon, a click opens its card (a click on the icon brings FaceTime
  forward), and it goes within a second of hanging up.
- **IC-H5** Downloads on: a Safari and a Chrome download show the ring, then
  Downloaded; a click reveals the file. An AirDrop from a phone says AirDrop.
- **IC-H6** A timer while music plays: the song waits as the bubble, pinches
  off the island's end with the neck, and merges back when the timer is
  cancelled.
- **IC-H7** A song playing while an app holds the microphone (Granola, cmux):
  the song holds the island and the microphone waits as the bubble with that
  app's icon, never Siri's. A click on the bubble opens the card on the island.
- **IC-H8** The card's Mute: the other side of a call hears nothing and the
  island shows a crossed-out microphone (beside a playing song, as the
  bubble); Unmute restores it. Mute during a Granola dictation, then end it:
  Audio MIDI Setup shows the microphone unmuted, and it stays so after a
  restart. Quit Isla while muted: unmuted. Quit names each app in a menu; the
  chosen one quits as ⌘Q would, and the orange dot goes.
- **IC-H9** Five minutes talking to Granola, music paused and then playing: the
  microphone activity shows the whole time (on the island or as the bubble)
  and never says Muted unless the island's Mute was pressed.
- **R7-H1** At Default and at More Space display scaling, the outline is flush
  with the 14-inch notch with no seam, compact and expanded. Changes the
  scaling, so run it last in a sitting.
- **R7-H2** With Reduce Motion on, the island changes size calmly with no
  overshoot and content only crossfades.
- **R7-H3** The shut island's stroke over Aerial, Sonoma and a white
  wallpaper: visible on each, never on the bare notch (pause everything to see
  it), never along the top edge.
- **R7-H4** Music playing with files on the Shelf: the bubble sits beside the
  island, the gap between them passes clicks to the menu bar, a click on the
  bubble opens the tray, a copied screenshot shows the Shelf for about 2 s, and
  a file dropped on the notch keeps it.
- **R7-H5** AirPods connecting show the expanded headphones alert; with Volume
  and Brightness on, the volume keys show the expanded pop-up with the output's
  name, the bar and the number.
- **R8d-H6** A file on the Shelf with a song playing: the bubble arrives, widens
  by a digit and goes; a click on it opens the tray, a click on the island or
  the bare notch still opens the player, and nothing is dead.
- **MO-03** Pause a song, unlocked and over the lock screen, and watch the fold:
  no bare black wing lingers after the cover goes and nothing snaps.
- **MR-H5** "Lyrics imported", "Copied" (Return in Clipboard) and "Added to
  Shelf" show on the shut island for about 1.5 s.

## Opening, closing, pointer and gestures

- **R8c-H4** From a resting pointer, flick to the island and click at once,
  twenty times: the panel opens every time, never a click on the menu bar
  behind it, and the hover lights on arrival.
- **R8-H4** Right-click the island and an open header row over a full-screen
  app and with Ice running: the menu appears each time. Locked, a right-click
  only shakes.
- **R8-H8** ⌃⌥⌘I, right-click the header row, Escape: the menu closes and the
  panel stays; a second Escape folds the panel.
- **MR-H11** Two fingers down over the shut island open what a click opens (the
  tray over the Shelf's bubble); two up on the header, or anywhere on the
  player, close it. With natural scrolling on and off, on the trackpad and a
  Magic Mouse: a short pull settles back, list and grid scrolling is untouched,
  a sideways swipe still turns pages, Notification Center and Mission Control
  still work, a wheel never opens it. Locked, a pull down shakes and opens
  nothing.
- **R8d-H2** Click to open and click again halfway, a dozen times; press the
  gear twice before it lands: the outline turns round without a jump or pause
  and ends where the state says.
- **MR-H18** Click the shut island ten times with music playing, then open on
  the Shelf's bubble and the lyric stage, and close each way: the outline moves
  in the frame after the click and the body fades in behind it, the cover
  still flies from the pill, nothing pops in after the fade, and the first open
  after a fresh launch is as quick as the tenth. Repeat with Reduce Motion on.
- **R8b-H1** On the trackpad, swipe slowly and flicked through all four pages
  and back: the pages follow the fingers 1:1, a flick turns one page, the ends
  rubber-band, nothing stutters at 120 Hz with Clipboard's list and the
  player's artwork up, quick presses of two dots carry on without a jump, and
  a click into Clipboard's search as it settles takes the keyboard first time.
- **R8b-H2** The same swipes on a Magic Mouse, with the same results.
- **R8b-H3** A wheel mouse scrolls the page under it and never turns one; the
  dots do.
- **R8b-H7** Typing in Safari, swipe to Clipboard: Safari keeps the keyboard and
  its caret blinks. ⌃⌥⌘V then ⌃Tab puts the caret in Translate; ⌃⇧Tab twice
  reaches the Shelf and once more Music, without switching Safari's tab;
  Escape folds the panel. On a Clipboard opened from the bare notch, a row
  click copies without stealing the caret and a click into search takes it.
- **R8b-H9** On Clipboard press Music's dot and leave the pointer: the panel
  shrinks to Music and stays, and folds once the pointer goes up onto Music and
  back down past it. From Settings, the X, three seconds' rest, then a click
  on a browser tab just right of Music folds it; the X returns to the page
  Settings came from.
- **R8c-H2** Music to the gear, Settings to the X, Clipboard away with ⌃⌥⌘V and
  back: one pane at a time, the old one gone before the new one arrives, the
  outline growing and shrinking under them with nothing drawn outside it.
- **R8c-H1** With text in Translate's card, swipe past the last page and hold,
  then back slowly toward Clipboard: no dark band at the card's foot, neither
  card crosses the outline, the text stays put and the caret returns.
- **R8d-H8** The same swipe and flick on Translate with text, then drag a file
  over the island: nothing crosses the border at any moment of the spring, and
  the drop surface appears in place.
- **KB-01** ⌃⌥⌘I then Escape closes the panel; ⌃⌥⌘I then ⌘-Tab closes it;
  ⌃⌥⌘L then Escape closes it; with no pin up, Escape still reaches TextEdit
  and Terminal; in Translate with text the first Escape clears and the second
  closes; with Quick Look open from a pinned Shelf, Escape closes Quick Look
  only; no "macOS refused the transient Escape hot key" line is logged.
- **KB-04** With the panel open, run the Show Isla Shortcut (the panel stays
  open) and Show Lyrics (the stage stays up); open Isla from Spotlight while it
  runs (the running copy answers). Never launch the copy in `build/`.
- **PG-SCROLL** The lyric stage scrolls both ways and holds where it is left.

## Music, the player and accounts

- **SPOTIFY-DEV** (owner) In Spotify's developer dashboard (Users and Access),
  see whether Isla's app is still in development mode; if it is, only listed
  accounts can connect.
- **MR-H17** Settings › Connections lists the installed players with their
  icons (uninstall one: its row goes). Connect with an unlisted Spotify
  account: one line says Spotify has not admitted it and no star ever shows.
  Cancel the consent page ("Spotify sign-in was cancelled."), turn the network
  off ("Isla couldn't reach Spotify."), then a listed account: the line clears,
  the row shows Disconnect and the star works. `log show` traces each step and
  no token.
- **KX-02** Press Connect twice and approve the first tab: the account connects.
  Disconnect, then Connect: Spotify's consent page appears with "Not you?".
- **R8-H6** Favourite in Music: the star follows Music's own heart both ways,
  and on a catalogue song not in the library one tap fills it and it stays
  filled. The same in Spotify with the account connected.
- **MR-H3** The star shows for Music and a connected Spotify on the player and
  the lock card, and the song really becomes a favourite.
- **MR-H4** The header's app icon reads as small as an iPhone Live Activity's.
- **R8c-H5** Spotify, Apple Music, Yandex Music and a browser tab in turn: the
  header shows the app's icon and name; at Panel Width 480 on a wide notch, the
  icon alone with the name on hover.
- **R1-H7** The Output menu, the stage's More menu and the translation menu
  (right-click Show Translation) open under their buttons from the panel, and
  tooltips appear.
- **MR-H9** Skip ten times in Spotify and ten in Music, from Isla and from the
  player, fast and slow, on a normal and a throttled (3G) network: one swap per
  song on the shut island, player, stage and lock card, with title, artist,
  cover and equalizer colour together; never a new title over the old cover,
  never the wrong song's lyrics. Reduce Motion makes it a fade.
- **MR-H14** Spotify playing, open the stage and press the speaker: macOS asks
  once about controlling Spotify; the slider moves Spotify's own volume, not
  the Mac's, and folds 3 s after letting go. Music the same; Safari moves the
  Mac's volume. With Automation for Spotify denied, the slider moves the Mac's
  volume and says "Allow Isla to control Spotify…". VoiceOver says "Spotify
  volume, N percent". Restore the permission afterwards.
- **ES-H1** Spotify playing, start a browser video (Music Only on), open the
  island: the song is held. Pause, play, pause: each answers on the song.
- **ES-H2** Press Next, then Pause within half a second: the button turns to
  Play at once, before the new title arrives.
- **ES-H3** Quit Spotify mid-song with the panel open: the island says nothing
  is playing within a second.

## Lyrics

- **R8-H5** On a synced song the player's sung line turns with the voice, and a
  long line wraps to two on the stage.
- **READ-01** On a track that sings continuously, shut island: the next line is
  on screen about half a second before the voice; across a long instrumental it
  waits for the previous line's end; Off restores the on-the-voice turn.
- **READ-02** On a ballad, Auto feels like the 0.5 s that was right; on a
  faster song with shorter lines it turns about 0.35–0.45 s early without
  feeling like too much.
- **VERSION-01** "We Are The People" (Empire Of The Sun) from Yandex Music: the
  overrun notice shows on the stage; right-click the sung line, Sync Here: the
  lines land on the voice and the notice goes; Reset brings it back. The
  compact caption and the lock card show no notice but follow the sync.
- **MR-H6** Context lyric lines dim faster and stay legible under Increase
  Contrast.
- **MR-H2** The stage's previous, play and next look like the player's and the
  lock card's; dragging the stage's bar seeks.
- **R1-H6** Translate Lyrics on a Russian or an English song: the translations
  arrive together and sit under each line.
- **ES-H4** Word-synced lyrics on the stage, pause mid-word: the sweep stops
  where it is and does not step back.

## Shelf

Setup: `tccutil reset` for the Desktop, Documents and Downloads services only
(never Accessibility), fourteen files of different kinds, a Finder window in
icon view, screenshots set to save to `~/Pictures`, an AirDrop device nearby.

- **SH-03 (S2)** After the reset, with captures going to `~/Pictures`, opening
  the Shelf raises no Desktop prompt, and every prompt that does appear is
  explained by what triggered it.
- **PG-PROTECTED** A file from a protected folder raises macOS's prompt only
  when the Shelf is opened or used, never at launch.
- **R3-H1** Three Finder files dragged in land as icons; the same drag over
  AirDrop sends without keeping.
- **R8-H2** A Finder drag onto the notch lights Keep on Shelf and AirDrop under
  the pointer; a drop on Keep on Shelf keeps the file, one on AirDrop opens the
  AirDrop sheet with it.
- **R3-H2** Delete with the pointer on the Shelf removes the selection and never
  the files.
- **R3-H5** Mail frontmost, pointer resting on the Shelf: ⌫ deletes text in
  Mail unless a tile was selected during this opening; reopening shows no
  selection.
- **ES-H6** Select a tile, leave the pointer on the tray, ⌘-Tab to Mail, press
  Delete in a draft: Mail deletes a character and the card stays.
- **R8b-H4** Fourteen files: tiles in rows (six at 560, five at 480), two rows
  and part of a third; two fingers and a wheel scroll the grid with fades; a
  quick sideways swipe turns the page and never moves the grid; turning between
  Shelf, Clipboard and Translate moves neither the outline nor the dots.
- **MR-H13** The same files in a Finder icon-view window beside the tray: no
  plate behind any tile; the name at 12 regular in two lines, the second cut in
  the middle; a grey date under it; a picked tile is a grey rounded square
  behind the icon with the name on a pill in the Highlight colour (change
  Highlight with the tray open); ⌘ and ⇧ clicks pick several; the remove badge
  shows on hovered or picked tiles; light mode and Increase Contrast read.
- **SH-05** A Desktop card dragged into a Finder folder copies it (the original
  stays, "+" badge); a ⌘-drag moves it and the card follows the moved file;
  ⌘-dragging onto the Trash removes the card; pressing ⌘ mid-drag turns copy
  into move; the thumbnail stays under the pointer where it was grabbed.
- **ES-H5** Keep a file on the Shelf, rename it in Finder, open the tray: the
  card is there under the new name and opens the file.
- **SH-03 (S9)** On a Mac set to Russian, ⇧⌘3 to a file: the still arrives on
  the Shelf the next time it opens.

## Clipboard and Translate

- **R8-H3** ⌃⌥⌘V from Safari: Clipboard opens with the caret in its search,
  typing narrows the list, arrows move the selection, Return copies and closes,
  ⌘V in Safari pastes the row, and ⌘, from Clipboard opens Settings and gives
  the keyboard back.
- **R3-H3** An image copied in Safari appears under Images and pastes back.
- **R3-H7** With Paste from Other Apps on Ask, copying a picture with history on
  asks once and never twice.
- **R4-H5** On Ask, opening Translate raises no alert; pressing Paste raises
  macOS's alert once.
- **CB-02** Under Don't Allow, Clipboard shows the sentence and Open Privacy
  Settings lands on Paste from Other Apps (record it if it lands on the Privacy
  & Security root). Set Allow, reopen, copy: the copy appears without a
  relaunch. Copy Diagnostics shows the state each time.
- **R8c-H8** A lyric playing and the panel on Clipboard: copy ten screenshots
  (⌃⌘⇧4) and ten pictures from a browser or editor and paste each elsewhere.
  The sweep and hover never stutter; every picture is in the history (and on
  the Shelf with Save Clipboard Screenshots on); two copies within a second
  keep the second; ⌘V with ⌃⌥⌘T pressed together ten times with Translate's
  field focused does not crash; under Ask the alert appears once and Isla stays
  responsive; Instruments shows the `pasteboard read` interval off the main
  thread.
- **R4-H9** With a Japanese input method, type into a Translate source holding
  20,000 characters: the letter is refused and the field does not show it.
- **R4-H2** Speak in a Russian and an English voice: each speaks, Stop Speaking
  stops.
- **R4-H4** Translate's pop-ups open from the panel with the chosen item over
  the button at Panel Width 480, 560 and 620.
- **R4-H7** (the look) In Russian at 480, a cut pop-up label ends in "…".
- **MR-H19** English → Russian with Russian not downloaded and Apple
  Intelligence off, type "salom": the card says Russian is not downloaded; Use
  Online replaces it with a spinner in the same frame and the answer follows;
  " dunyo" translates without a second press; changing the target, Clear or
  closing the panel brings the card back and sends nothing; network off gives
  one alert with Try Again; a downloaded Russian answers on the Mac.
- **PV-03** Translate Online on, translate one Uzbek sentence, quit Isla, then
  `sqlite3 ~/Library/Caches/com.ctimothe.isla/Cache.db "select count(*) from cfurl_cache_response where request_key like '%mymemory%'"`
  answers 0 (or the file is absent). Spotify still connects, refreshes and
  hearts a track, and an update check still answers.

## Settings, language and accessibility

Setup: the Mac's language set to Russian (log out and in) for the first group;
Panel Width at 480, 560 and 620 in turn; VoiceOver and Reduce Motion ready.

- **MR-H16** Every Settings section beside System Settings, dark and Russian, at
  480, 560 and 620: 13 pt labels, grey 11 pt footers, System Settings' row
  height, its own icons in the sidebar and Isla's in About. Changing the accent
  colour with Settings open recolours selection, switches, sliders, segmented
  controls, buttons, Update Now, the shortcut ring and the Lock Screen style
  ring. Every segment takes one click though the panel is not key; pop-ups
  open on the first click from another app; Increase Contrast keeps outlines;
  Russian sidebar titles do not truncate.
- **SET-01** Click the words "Launch at Login": the switch flips. Graphite and
  Yellow accents look right.
- **B10-H1** Russian at 480, Clipboard with Paste from Other Apps on Don't
  Allow: the whole sentence shows beside «Открыть настройки» and the button
  opens Paste from Other Apps. Settings › Блокировка: the four card styles sit
  inside the form with «Автоматически» whole; at 560 and 620 they look as
  before.
- **TRUNCATION** (the look) Every surface in Russian at 480 and 620: no text
  truncates inside its own box, and each header well lightens under the
  pointer. Layout is held by `PanelLayoutSweepTests`; this is the eye's half.
- **SET-02** With VoiceOver on, the rotor's Headings in each Settings section
  list that section's group headers.
- **VO-KEYS** With VoiceOver on, press ⌃⌥⌘L and ⌃⌥⌘T, which are also VO-⌘-L and
  VO-⌘-T. Record which one wins.
- **R8b-H5** One real VoiceOver pass over the page dots: "Pages, Page n of 4,
  name"; increment and decrement turn one page and stop at the ends.
- **AN-02** (the owner's half) Without VoiceOver, a click arms Clear on the
  Shelf and the word stays red while the pointer rests on it.
- **R8e-H5** After the gear, VoiceOver reads Settings and finds the sidebar and
  the first switch without a second navigation; Tab from the header reaches the
  sidebar.
- **R8b-H6** Reduce Motion: a dot and ⌃Tab crossfade in place; a swipe still
  follows the fingers and settles without overshoot.
- **R8d-H3** Reduce Motion: the outline changes size on the 0.24 s ease-in-out
  with no overshoot, and the line and shadow fade with it.
- **R8e-H4** Reduce Motion: the gear and the X are the plain fade out and in, in
  the same order, the form there as the new pane becomes visible.
- **B9-H1** (Reduce Motion half after the normal one) Play/pause, the heart, the
  gear and its X, Copy, repeat and shuffle: the old glyph shrinks away as the
  new one grows in its place, about as quickly as before, nothing jumping
  beside it; under Reduce Motion, a cross-fade.

## Lock screen

Setup: wallpapers Aerial, Pro Black, Sonoma, Sky Blue and plain white; tracks
with a pale cover, a dark cover, no cover (a podcast or a browser tab) and one
with lyrics; AirPods.

- **CARD-H1** With style and size never chosen, lock on a playing song over a
  bright and a dark wallpaper: the card is Compact, shows the wallpaper through
  it, and every line reads; Standard, once chosen, does the same.
- **R2-H1** The banner under the clock reads on Aerial, Pro Black, Sonoma and
  Sky Blue.
- **R2-H2** A click turns the banner into the card and the chevron turns it
  back; the card grows in place.
- **R2-H3** At Automatic, the lyric reads over Aerial's bright lines.
- **R2-H4** The Output pane switches to AirPods, with the haptic.
- **R2-H5** A click on the notch shakes; no music wings at the notch while the
  banner or card shows (the volume pop-up and the charger may take them).
- **R2-H6** A song with no cover at Automatic: the card stays mostly solid and
  every line reads.
- **R2-H7** Transparent over Sky Blue and white: the black rises enough that
  the artist line and times read; over Aerial it stays at 0.30.
- **R2-H8** Picking a device on the Output pane stays on the pane; with Rest as
  Banner off the card shows directly.
- **LC-01** A white or pastel cover, in Tinted and in Transparent: the artist
  line, the times and the lyric status read; a dark cover looks as before.
- **CT-02** Over a pale cover, the card's lyric context lines keep their depth;
  in a dark room, the lyric stage's do too.
- **CARD-GLASS** On a locked macOS 26 Mac with a coverless song, say whether the
  drawn card reads well. If the system material would read better, record it
  here; do not change the code for it.
- **R4-H3** Settings › Lock Screen's style previews match the real lock screen.
- **B22-H2** Lock on a playing song, the card on the player: the bar moves
  smoothly, both times turn every second, a drag on the bar seeks, and the
  banner's ring turns clockwise from the top.
- **LOCK-DISPLAY** Lock and unlock with the card on and off, and plug a display
  in while locked: the card and its space come back correctly.
- **LOCK-CYCLES** Lock and unlock several times, including after display sleep:
  the card appears centred at its own size every time.
- **R8d-H5** Lock and unlock with the panel shut and a song playing, and with
  the panel open: the pill over the shield is as before; on unlock the island
  returns once, in place, with no stale outline or mask.

## Charger, battery and headphones

Setup: a MacBook with MagSafe, Apple's 61 W USB-C charger, a USB-C display or
hub, AirPods, Optimized Battery Charging on; start below 80 percent, panel
shut, pointer away. The hold checks need the battery holding at 80 percent.

- **FS-AMBIENT** Plug in a charger, connect AirPods, and use Quick Look and
  AirDrop from a Shelf card: the activities show and both system panels open.
- **MR-H22** Panel open on Music, plug a charger: the capsule 6 pt under the
  panel shows "61 W" or "MagSafe" with the level and a green line for 3 s;
  AirPods show "Connected" for 4 s; "Copied" and "Added to Shelf" show there
  too; a volume key takes it over; a page turn carries it; Return in Clipboard
  shows "Copied" on the shut island instead.
- **MR-H15** Panel shut: MagSafe shows "MagSafe", the level and a green ring
  with a bolt for 3 s; USB-C shows "61 W" with a battery and bolt; a USB-C
  display alone shows nothing; unplugging shows nothing; below 20 percent the
  colours are red; VoiceOver speaks the charging phrase.
- **MR-H24** The 61 W charger plugged in below 80 percent: the island grows at
  once with "61 W" in green, and again after a 2 s unplug, with the pointer on
  the island and over a full-screen app. Repeat with MagSafe; at the hold, "On
  Hold" from the first frame.
- **MR-H21** At the 80 percent hold: "61 W On Hold" with "80%", a white battery
  with no bolt and a white line; MagSafe reads "MagSafe On Hold" with the white
  ring; Russian reads "61 Вт Пауза" and "MagSafe Пауза". Record the `ioreg`
  `NotChargingReason` beside what the pill said.
- **IC-H2** On battery, Battery Low at 20 % and at 10 %; on power, Full Battery
  once at 100 % and not again until the charge has fallen below 95 %.

## Volume and Brightness

Setup: switch Volume and Brightness on and grant Accessibility; music playing;
AirPods, EarPods and an external keyboard at hand. Leave it on for the
external display and update checks.

- **R5-H1** Turning it on and granting Accessibility: the volume keys show
  Isla's pop-up and never the Mac's, without removing and re-adding Isla.
  - **R5-H1a** With a stale entry (granted to an older build), the macOS prompt
    shows and the keys work after granting.
  - **R5-H1b** After an update with the setting on, the new build's first
    launch shows the prompt once (run it in the update sitting).
  - **R5-H1c** Declining is not asked again at the next launch of the same
    code, but the footnote shows at once; off and on asks again.
  - **R5-H1d** On a Mac where Isla never had an entry, the prompt shows and no
    footnote appears if you grant within 30 s.
  - **R5-H1e** Relaunch onto a locked Mac and onto a dark display with a stale
    entry: nothing is reset and no prompt hides behind the lock; the first
    awake, unlocked moment repairs and prompts once.
- **R5-H2** Mute keeps the level, dimmed; unmute restores it.
- **R5-H3** The display and keyboard brightness keys on the MacBook Pro.
- **R5-H4** Turning the setting off gives the keys back at once.
- **R5-H5** An external keyboard's volume keys behave the same.
- **R5-H6** Volume down while muted, compared with the Mac's own pop-up (Isla
  keeps the Mac muted).
- **R5-H7** (macOS's half) ⌥+volume opens Sound settings, ⇧+volume changes
  silently.
- **R5-H9** AirPods connecting while a volume key is held never jump their
  volume.
- **R5-H10** The Settings sidebar and the Spotify row show Spotify's own icon;
  About's Isla icon matches the tiles; Connections lists Яндекс Музыка and both
  Telegrams with their icons.
- **R8c-H3** With the Mac busy (`yes > /dev/null` once per core), volume up,
  down and mute and brightness, tapped and held: the pop-up appears with the
  first press, the bar follows with no lag or overshoot, and a refused output
  (HDMI with no volume) shows nothing while macOS answers.
- **MR-H7** With the panel open on each surface, a volume, mute and brightness
  press draws the 32 pt capsule 6 pt under the body, centred, covering nothing,
  click-through, folding 1.5 s after the last press; at 480 and 620, under
  Increase Contrast and Reduce Motion; VoiceOver says the level once.
- **MR-H8** Holding volume-up and brightness-up, the bar is on the level the
  number says on every frame: no trail, no hesitation on the first press, no
  replay after a main-thread stall.
- **MR-H10** Hold volume up for 3 s then down, on the built-in speakers, EarPods
  and AirPods: the bar moves with every repeat and stops the instant the key is
  released; after the menu-bar slider moves, the next key steps from where the
  slider left it; AirPods connecting mid-hold are never set to the speakers'
  level; with the setting off the system pop-up appears unchanged.
- **MR-H25** The same song, hold volume up and down for 10 s with the setting on
  and then off. Crackle in both is memory pressure; crackle only with it on is
  a bug: report it with the time.
- **MR-H23** Show on Lock Screen on, music playing, lock (⌃⌘Q) and press volume
  up, down, mute and brightness: the compact pill shows instead of the system's
  OSD, the level changes, the card's bar moves and is not covered, the pill
  folds 1.5 s later, a click shakes, a charger shows its 3 s pill. After
  unlocking, record the log's "N heard, M taken" (N of 0 means the system's
  OSD is the right result). With Show on Lock Screen off, the OSD is the
  system's.

## External display

Setup: the notched built-in display, then an external display connected over
USB-C; lid closable.

- **PG-SYNTHETIC** On the external display, with its drawn notch: the player,
  Shelf, Clipboard, Translate and Settings, a charger and a pop-up all work.
- **R8d-H4** The player over a busy window has its soft shadow, none under the
  compact island, the new-track alert or the charger; the line is 2 pt and
  crisp on both displays with no seam along the top edge; Increase Contrast
  raises it; the charger's line is green.
- **R5-H8** With the external display as main, and with the lid closed, the
  brightness keys go to macOS.
- **MR-H7 (unnotched half)** The open panel's level capsule on the external
  display.

## Updates

Setup: a clean committed checkout, `bash Scripts/publish-dev-update.sh`,
Volume and Brightness on, Spotify connected. A screen saver with a password
grace and a second user account for DU-H6.

- **UPDATE-REHEARSAL** `bash Scripts/rehearse-update.sh` and Update Now from it:
  swapped, relaunched, Accessibility kept, nothing left behind (no
  `.Isla-update-*` beside the app, nothing in `hdiutil info`); record what macOS
  said about App Management. Then Cancel mid-download, a copy run off the DMG
  (offers only the download page), and the network off (Try Again).
- **DU-H2** Accessibility (the pop-up), Spotify and the Settings choices survive
  an update.
- **DU-H3** Later folds the alert and the gear keeps its badge.
- **DU-H4** Open the panel while the alert shows: it goes with the open and
  returns when the panel closes; a volume key over it replaces it with the
  pop-up, and it returns after.
- **DU-H5** Record what macOS said about App Management on the first feed
  update (a prompt, a "prevented from modifying apps" notice, or nothing), and
  whether the first publish asked to allow the keychain read of "Isla Dev
  Update Signing".
- **DU-H6** Show on Lock Screen off, publish a build and lock before it is
  offered: nothing shows under the shield and the alert appears after unlock.
  Repeat with the screen saver running and with another user switched in.
- **DU-H7** `rm -rf .dev-updates`, then publish: the new folder is found and the
  build offered within a few seconds, without relaunching Isla.
- **DU-H8** An install whose disk image is slow to eject still installs, and the
  log says "a detach try did not exit cleanly, but the disk image is gone". This
  cannot be forced: tick it on the first update where it happens.

## Launch, lifecycle and platforms

- **PG-LIFECYCLE** Quit and relaunch, and with Launch at Login on, log out and
  in: the island returns each time, and only one Isla runs.
- **INTEL** The Intel slice has been built, never run. Needs an Intel Mac.

## Measurements

Run last, on a quiet Mac (no builds, no `yes`, display awake), from the main
checkout. Each takes the installed build; record its version.

- **IDLE-BUDGET** `bash Scripts/measure-idle.sh closed-idle` (music paused, 5
  min) and `closed-playing` (5 min): CPU at or below 0.1 %, RSS at or below
  88 MB.
- **B17-H2** The lyric stage open (⌃⌥⌘L), pointer off it:
  `measure-idle.sh open-stage 12`.
- **B22-H1** A line-timed song playing, the stage open, pointer off it:
  `measure-idle.sh open-stage 12`; the stage stands still between lines and its
  rest bar still fills.
- **B18-H2** Watch the open player for a minute: the elapsed time and the bar
  move every second, the sung line turns with the voice, and a drag on the bar
  carries the time with the finger.
- **B19-H1** A word-timed song with word karaoke on, the panel open on the
  player, pointer off it: `measure-idle.sh open-player 12` (the player half
  measured 4.5 %); then the same on the lyric stage.
- **B19-H2** Watch the word sweep for a minute on the player, the stage and the
  lock card: the edge stays with the voice word by word, a turning line carries
  its lit half as it fades, a line on two rows fills the top row first, a pause
  stops the edge, a seek moves it at once.
- **B20-H1** (the watch; the cost is measured) The open player for a minute:
  the bar moves smoothly and the elapsed time turns every second; a click or
  drag on the bar lands at once; a pause stops the bar; a new song starts the
  bar from its own position.
- **B21-H1** The panel open on the player with the Lyric Band on and a
  line-timed song, pointer off it: `measure-idle.sh open-player 12` (7.2 %
  before this change, 1.9 % with the band off). Then a minute's watch: every
  line turns on the voice; a pause and resume, a seek into and across a line,
  and a Lyric Delay nudge each show the right line at once, none turning back.
- **REST-H1** A line-timed song from its start, the island open on the stage:
  the intro shows the note and the track filling, and the first line lights as
  the track fills; a solo mid-song does the same. Locked on the same song, the
  card's rest looks and moves the same way.
- **B11-H1** With lyrics on, open the player on a song whose title and artist do
  not fit (Jeff Buckley, "Lover, You Should've Come Over"): the line rests about
  2.5 s with its far end faded, slides left at an even pace, lands on the same
  picture with no jump and rests again; the artist line alone does the same;
  under Reduce Motion, or on another page, it stands still with an ellipsis.
  Isla's CPU on that song stays near what it is on a song that fits.
- **R8d-H1** With the Mac busy (`yes > /dev/null` once per core): open and close
  from the notch, the gear and the X, and alerts coming and going, twenty times
  each: the island's edge moves without steps and nothing is drawn outside it.
- **R8d-H9** Activity Monitor's GPU history and Energy for Isla, panel shut with
  music and the caption on, then a minute open on the player: no higher than
  the previous build, if it is still installed.
- **R8e-H1** The gear from the player twenty times, then the X: the old pane
  recedes and is gone, the new one arrives from 0.97, the island grows
  underneath, and the pane never shows without its form.
- **R8e-H2** The same twenty presses with the Mac busy. This decides the
  Settings staged-mount delay: keep 80 ms, move to 100 ms, or drop it
  (`SettingsPane.mountsAfter`).
- **R8e-H3** Open Settings straight from the shut island, and use "Lyrics
  Settings…" from the player, ten times each: from shut the form arrives with
  the opening, from the player as the gear does; never a blank body that fills
  late.
- **R8e-H6** Settings to player with the X, twenty times: no worse than the
  previous build.
- **PERF-CYCLOP** `bash Scripts/build-reference.sh`, then
  `bash Scripts/measure-performance.sh build/reference/Cyclop.app build/app.noindex/Isla.app <report.md>`:
  three 60-second runs each; application and helper RSS no higher than the
  reference median; no helper survives its parent.
- **SYNC-WORDS** `bash Scripts/measure-sync.sh` against a live Spotify and
  against Apple Music: word timing at or below 150 ms p95, or that publisher
  stays line-level.
- **S-LEAD** Per player and per route (built-in speakers, AirPods), put
  CoreAudio's reported output latency from the trail beside the by-ear lyric
  correction. Decides whether `LyricLeadModel.appliesOutputLatency` turns on.

## Open findings

- **Lock card rest test.** No test checks the lock card's lyrics during a rest;
  the stage has one (`StageAndCardTickTests`). About 15 lines.
- **Empty test preference files.** Some suites still leave empty plists in
  `~/Library/Preferences`: `AccessibilityProbe` deletes its file and something
  writes it again (about 509 per gate run), TranslateRig about 67, twenty
  smaller suites a few each. Find what writes after `release()`.
  `bash Scripts/clean-test-plists.sh` counts them; `--apply` moves them aside
  (owner's call, never a delete).
- **A crashed test process leaves one empty store file.** The private test store
  is removed at exit (`StoreDefaults`). Recommendation: accept; the cleanup
  script covers it.
- **The open stage costs about 1 point of CPU more than the lock card between
  lines.** Suspected backing-store redraw (`CABackingStoreUpdate`). Sample it:
  `ISLA_IDLE_STATES=open-stage-interlude bash Scripts/measure-idle-lab.sh sample`.
- **VoiceOver's one-step slider increment** (Lyric Delay, Panel Width) works on
  macOS 27 and not on 26.6, where the system's own step applies. Two tests skip
  below 27 (`LyricDelayCopyTests.testAVoiceOverStepMovesTheDelayByOneStep`,
  `SettingsAccessibilityTests.testAVoiceOverStepCommitsTheWidth`). An
  `accessibilityRepresentation` slider or a stepper would fix it.
- **`Scripts/test-lifecycle.sh` and `measure-performance.sh` launch the built app
  against the real `~/Library/Application Support/Isla`**, so every gate run
  executes one-time migrations on the owner's data. Needs an app-level hook to
  redirect the data folder and defaults.
- **A lyric timed for a longer version** still loses the lines stamped past the
  track's end, even after Sync Here; the compact caption and the lock card show
  an overrunning lyric without the notice.
- **The lyric stage cuts a very long line at Panel Width 480** after its second
  row.
- **`Diagnostics` reports Launch at Login as off while macOS approval is
  pending**; use `LaunchAtLogin.read()`.
- **`SettingsIcon.about` and `SettingsIcon.quit` are unused** by the app (kept
  for the lab and `SettingsIcon.all`).
- **Debt.** `LockScreenCard` carries about 22 white and black literals, a second
  theme outside `Theme`; `NotchMetrics.collapseRectShrinkDelay` is tied to the
  open spring's settle by comment only; `Translator` uses the deprecated
  `GenerationOptions(sampling:)` because `samplingMode:` exists only in the
  macOS 27 SDK; `scripts/check` is tracked lowercase beside `Scripts/`, one
  folder on a case-insensitive disk and two on a case-sensitive one.

## Open decisions (owner)

- **Developer ID signing and notarization.** Isla ships ad-hoc with its own
  pinned certificate. Without a Developer ID, a first install needs the `xattr`
  step, macOS can offer to delete the media helper, an update asks again for
  folder and Automation grants, and Homebrew will not take it. Needs Apple
  Developer Program membership.
- **Merge `feat/islandcn-identical` to `main`.** It carries batch 22 and the
  islandcn slices so far; merging releases to every user. Run B22-H1, B22-H2
  and the IC/IC2 checks first, and the full gate.
- **Clipboard text to Translate Online** (decision 21): whether text from the
  clipboard waits for one click before it goes to MyMemory.
- **Spotify cover fetch** has no switch; whether to gate it.
- **Quiet in full screen**: whether to add a Settings switch and a Focus filter
  for quiet ambient moments.
- **Backlog, not scheduled:** prefetching the next track (needs Spotify's
  `user-read-playback-state` scope, so every connected user would consent
  again); word-level lyrics from an online source (LRCLIB is line-level);
  per-source lyric bias (`LyricSource.bias`, all zero); focus rings and
  panel-level shortcuts beyond ⌘, (⌘W, Return to confirm); README screenshots
  from the live app.
