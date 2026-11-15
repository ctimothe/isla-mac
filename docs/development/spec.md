# Isla specification

What Isla does and the rules it keeps. This is the behaviour contract: when
the app and this file disagree, one of them is wrong, and the change that
fixes it updates both. When behaviour changes, update this file in the same
change. History lives in git; this file describes only the app as it is.

Numbers here are the ones the code holds; the type that holds each is named
so a reader can check it. Exact pixel layouts live in the layout types
(`PlayerLayout`, `ShelfLayout`, `ClipboardLayout`, `TranslateLayout`,
`SettingsLayout`, `LockCardLayout`, `CompactIslandLayout`,
`ExpandedAlertShape`, `SurfaceLayout`) and their tests, not here.

## 1. Purpose and scope

Isla is a macOS accessory app that turns the MacBook's camera notch into an
island in the style of the iPhone's Dynamic Island: it shows one activity at a
time (what is playing, a timer, a charger, files kept on the Shelf), and a
click opens a panel with the player, synced lyrics, a file Shelf, clipboard
history, translation and Settings.

- **Target.** Notched MacBooks on macOS 15 or later, Apple silicon and Intel.
  On a display without a notch Isla draws one (§4). There is no special
  behaviour for any other kind of Mac or display.
- **Origin.** Isla began from Cyclop 0.6.5 (MIT, pinned upstream commit
  `7ab60c8198681ea6c895fa55458448efb6e4c36e`); its attribution ships in
  `THIRD_PARTY_NOTICES.md`. Everything else about its identity is original
  (§19). islandcn (MIT) is the reference for the island's look, icons and
  motion; Hugeicons' free set (MIT) supplies the glyphs. Both are credited in
  `THIRD_PARTY_NOTICES.md`.
- **Languages.** English and Russian, everywhere (§19).

## 2. The invisible app

Isla has no Dock icon, no menu-bar item and no window. It is an `.accessory`
app (`LSUIElement`), the policy is set once in `IslaApplication.run()` and is
never changed at runtime. Every route in is the island, a hot key, the
right-click menu, the Services menu, a Shortcuts action, or Spotlight opening
the app (which hands over to the running copy).

- **First run.** The first launch on an account opens the panel on its own,
  about 0.8 s after launch, on the **welcome** surface: Isla is running, it
  lives at the notch, how to open it, the hot keys, that nothing leaves the
  Mac but update checks, and Get Started. Only Get Started (or choosing a
  page) sets `hasCompletedFirstRun`; any other way the welcome leaves the
  screen offers it again at the next launch.
- **About, Quit, Open Panel** and every privacy switch live in Settings
  (`SettingsPane`). The right-click menu also has Quit Isla.
- **One copy.** A second launch hands over to the running copy and exits
  (`LaunchGuard`). The built bundle in `build/` is never opened: each launch
  from there registers another Isla with LaunchServices.

## 3. Shell and window

- **The panel.** One borderless, non-activating `NSPanel` (`NotchPanel`) hosts
  SwiftUI content. Its level is `CGWindowLevelForKey(.statusWindow) + 1`
  (`NotchPanel.normalLevel`; the lock path reads it back, so it is changed
  there and nowhere else). Collection behaviour: `.canJoinAllSpaces`,
  `.stationary`, `.fullScreenAuxiliary`, `.ignoresCycle`.
- **Never main, rarely key.** `canBecomeMain` is always false. `canBecomeKey`
  is true only while a surface that types asks for the keyboard — Clipboard
  and Translate (`Surface.takesKeyboard`) — and while a Settings shortcut field
  records. A page reached by a swipe, a dot, the pointer or a click on the
  bare notch never takes the keyboard; a summons (⌃⌥⌘V, ⌃⌥⌘T, the menu), a
  press into the field (`NotchViewModel.pressClaimsKeyboard`) or VoiceOver
  moving focus into it does. Looking at Isla must never take typing away from
  the app in front.
- **One window size.** The window is cut once, `NotchMetrics.maximumWindow`
  (700 × 444 pt), large enough for the tallest body any surface asks for
  (`NotchMetrics.tallestBody`, 620 × 400) plus the level capsule under it, and
  is never resized. It is transparent outside the drawn island. What is
  clickable is decided separately by `activeRect` on `NotchRootView`;
  everything outside it passes clicks through. Resizing across a lock produced
  stretched window-server snapshots, which is also why the lock card is a
  window of its own (§12).
- **Geometry.** All constants live in `NotchMetrics`; derived rects in
  `NotchGeometry`. The panel width is a setting, 480–620 pt, default 560
  (`NotchMetrics.minimumBodyWidth`, `maximumBodyWidth`, `defaultBodyWidth`);
  it narrows the body inside the unchanged window.
- **Rendering of the outline.** The island's fill, shadow, content mask and
  stroke are `CAShapeLayer`s (`IslandOutlineHost`) animated by the render
  server. The shell describes the outline (`OutlineState`); each change
  arrives with its transaction (`IslandOutlineBridge`), whose curve is read
  back from the SwiftUI animation (`OutlineCurve`) and sampled into keyframes
  shared by every layer, so fill, mask, line and shadow cannot disagree by a
  frame and a stalled main thread does not freeze a morph already begun. The
  Shelf's bubble and the level capsule draw in hosting views of their own
  above the island (`NotchStage`).

## 4. Displays and notch detection

- A display has a notch when `safeAreaInsets.top > 0`; its exact cutout comes
  from `auxiliaryTopLeftArea` and `auxiliaryTopRightArea`.
- Without one, Isla draws a **synthetic notch** centred at the top of the
  display: 200 pt wide (`NotchGeometry.syntheticNotchWidth`) and as tall as
  the menu bar.
- The panel is placed on the notched display; `NSScreen.main` is never used to
  choose it, because a panel that never activates makes it meaningless.
  Geometry is recomputed on `NSApplication.didChangeScreenParametersNotification`.
  A display change rebuilds the panel on the right display and keeps the open
  surface, the clipboard history and any half-typed translation.
- Every compact activity holds at notch widths 180–240 pt and notch heights
  24, 32 and 38 pt; every expanded shape and surface at panel widths 480, 560
  and 620; all in English and Russian. `PanelLayoutSweepTests` holds this.

## 5. The island

### 5.1 The outline

Every activity and surface is one black shape hung from the top of the screen.

- **Shape.** Quadratic shoulders at the top and quadratic bottom corners
  (`NotchShape`), not circular arcs. The resting island is the notch itself;
  a compact activity is the notch's height and wider than it (its wings grow,
  the camera's span does not); an expanded activity or surface keeps its own
  width, never narrower than the notch plus 20, and hangs lower. The resting
  radii are `Theme.collapsedTopRadius` 8.67 and `collapsedBottomRadius` 12.67.
- **Stroke.** 2 pt (`Theme.islandStrokeWidth`), along both shoulders, both
  sides and the bottom, never the top edge. The activity's tint at 0.21, or
  white 0.14 where it has none; Increase Contrast raises them to 0.42 and 0.30.
  It is drawn on every wallpaper whenever the shape is larger than the resting
  notch, never on the bare notch (`IslandStroke`). A compact activity's
  outline is half a stroke taller than its body so the bottom line never falls
  inside the camera cutout (`NotchContentView.clearingCutout`).
- **Shadow.** A shape taller than 68 pt casts black 0.22, radius 14
  (`Theme.islandShadow*`), so an open surface separates from a busy window.
- **Fill.** Black. Content sits on it directly. Nothing draws past the
  outline: every surface's content is masked by it on every frame, and the
  stroke is drawn over the content.
- **Hover.** The surface turns `Theme.islandHover`; the resting notch nudges
  8 × 3 pt on `Theme.hoverNudge`. A hover never opens the panel unless Open on
  Hover is on.
- **Tints.** Green for charging and a healthy battery, red at 20 % or less,
  the system accent for the update and the Shelf's count, white elsewhere
  (`Theme`).

### 5.2 Activities and ranks

The island shows exactly one activity, the highest-ranked one standing
(`IslandActivity.current`). Rank 1 is highest.

| Rank | Activity | Kind | Holds | A click |
|---|---|---|---|---|
| 1 | Locked (§12) | compact | while locked | shakes (`RefusalShake`) |
| 2 | Files dragged to the notch (§9) | drop surface | while the drag is over it | — (the drop decides) |
| 3 | Volume or brightness (§14) | alert | 1.5 s after the last press | folds it |
| 4 | Battery Low; Timer Done | alert | 5 s; 10 s with the Glass sound | folds it |
| 5 | A confirmation: "Lyrics imported", "Copied", "Added to Shelf" | compact alert | 1.5 s | folds it |
| 6 | Headphones connected | alert | 4 s | folds it |
| 7 | Charging (MagSafe or USB-C) | compact alert | 3 s | folds it |
| 8 | Full Battery | alert | 5 s | folds it |
| 9 | Isla update ready (§15) | alert with a choice | until answered, at most 20 s | its buttons |
| 10 | New track | alert | 2.2 s (`sneakPeekDuration`) | opens the player |
| 11 | Timer, running or paused | live | until it ends or is cancelled | its card: pause or resume, cancel |
| 12 | Stopwatch, running or paused | live | until reset | its card: pause or resume, reset |
| 13 | Music | live | while something plays, and a short linger after a pause | opens the player |
| 14 | Recording: another app has the microphone or a camera | live | while it does | its card: the app, Mute or Unmute, Quit; a camera alone opens the panel |
| 15 | Downloads in progress in ~/Downloads | live | while one is in progress | opens the Downloads folder |
| 16 | Shelf holding files | live | see §9 | opens the tray |
| — | Nothing | the bare notch | — | opens the player if there is a song, else the page last shown |

The rule behind the live ranks: what the person started and is attending to
(a timer, a stopwatch, the song) stands over what an app does on its own (a
microphone in use, a download), and the Shelf waits under everything. A
muted microphone keeps its rank.

### 5.3 Alerts

- An alert folds back to the highest live activity when its hold ends.
- A higher alert replaces a lower one at once; an equal one replaces the
  older. A replaced alert is dropped, except the update choice, which waits
  for the next idle moment.
- An alert that cannot show within 1 s of its cause (a surface is open, the
  Mac is locked, a higher alert holds) is dropped (`IslandAlertQueue.patience`),
  except Battery Low, Timer Done and the update choice, which wait.
- A confirmation posted while a surface is open waits for the panel to close
  and then shows its 1.5 s; if the panel is still open 5 s after the act it
  lapses (`IslandAlertQueue.confirmationPatience`). It never speaks: the act
  already announced itself.
- Volume and brightness never queue: a level shown late is a level out of date.
- **While the panel is open**, the level, the charger, headphones and
  confirmations show in a 32 pt capsule 6 pt under the open body, centred on
  the notch, click-through and hidden from VoiceOver (`HUDStripLayout`,
  `StripNotice`). The level outranks the notices and takes the capsule at
  once. The capsule follows page turns and the pull, and a panel that closes
  takes it with it; a notice that had stood under 0.6 s is handed to the shut
  island for its whole hold. The shut island's pill and the open panel's
  capsule are never both drawn.
- **Refusals.** The charger, headphones and the new track are not shown over
  a full-screen film or mirrored display, while the displays are dark, or
  while their switch is off. The new track and headphones are also refused
  with the pointer on the island. Every alert posts its label as a VoiceOver
  announcement when shown (the level at most every 0.25 s).

### 5.4 Live activities and the bubble

- When two live activities stand, the second **waits as the bubble** beside
  the island: a small shape of its own, one minimal form (a ring, a glyph,
  the remaining time; the Shelf's count, 8 pt wider per extra digit). It
  grows out of the island's end on the split spring with a metaball neck
  between them while the gap is small (`IslandNeck`), and merges back on the
  unsplit spring; under Reduce Motion it fades.
- The bubble shows only beside a compact live activity: never during an
  alert, while a surface is open, or while locked. It has its own hit region
  (`NotchRootView.bubbleRect`), so the gap between it and the island passes
  clicks to the menu bar. A click on it opens what its activity opens; a card
  opened from the bubble holds the island until it folds.
- **Timers** start from the right-click menu's Timer submenu (1, 3, 5, 10, 15,
  25, 30 or 60 minutes, `IslandTimerCenter.presetMinutes`, or a Stopwatch),
  which also pauses, resumes, cancels and resets them. A running timer
  survives Isla replacing itself for an update (`island.timers`). A click on a
  timer opens its card in place, folding after 6 s.
- **Recording** reads which processes have audio input running and whether a
  camera is in use (`CaptureWatch`); nothing is asked of macOS. Each process
  counts as the app macOS holds responsible for it; one that belongs to no
  app (Siri's listener) counts as nothing. **Mute** is the Mac's own input
  mute on each real microphone (`MicrophoneMute`), held, not set: Isla records
  exactly what it changed and gives back exactly that when the last app lets
  go of the microphone, when the switch goes off, when Isla quits, and at the
  next launch after a run that ended muted. "Muted" on the island is the
  island's own Mute, never read from the device. **Quit** sends the chosen app
  its own Quit; it is the only thing that puts out the menu bar's orange dot.
- **Downloads** lists ~/Downloads and shows a download in progress as a ring,
  then "Downloaded" (or "AirDrop" for a file AirDrop delivered); a click
  reveals the file (`DownloadWatch`).

### 5.5 Compact activities

Compact activities are the notch's height. Widths are the notch plus a fixed
extension (`NotchMetrics.compactMediaExtension` 70, `compactShelfExtension`
75, `compactChargingExtension` 180), or derived from content
(`CompactIslandLayout`).

- **Music.** The cover on the left wing, the equalizer on the right in the
  cover's tint (`CoverTint`). Paused, the cover dims and the bars rest. No
  artwork shows a well with a note. The compact island has no controls: every
  point of it opens the panel. VoiceOver: "Now playing: %@ by %@".
- **Shelf.** The Shelf glyph and the item count. "Shelf, %d items".
- **Charging.** Which port is read once per plug-in, off the main thread
  (`ChargePortReading`): **MagSafe** draws "MagSafe", the level and a ring with
  a bolt; **USB-C** draws the adapter's watts ("61 W") with a drawn battery.
  The port's identity leads; the state follows it ("61 W On Hold",
  "MagSafe Charged", "Not Charging"). "On Hold" means the Mac is holding the
  charge on purpose, read from the battery's `NotChargingReason`
  (`ChargeHoldReading`). Shown at the edge the power source turns AC and
  corrected in place by re-reads over the next 3 s; power back within 1 s of
  leaving is not news. A Mac without a battery shows no Charging activity.
- **Locked.** A lock glyph in the wing (§12).
- **Timer, Stopwatch, Recording, Downloads.** Their glyph and their time or
  ring (`LiveActivityViews`).
- On a synthetic notch, covers and glyphs scale down with the notch's height.

### 5.6 Expanded alerts

Each is one shape from `ExpandedAlertShape`, hung under the notch.

- **Battery Low** fires on battery once as the charge falls through 20 % and
  once through 10 %; plugging in resets both. The advice mentions Low Power
  Mode only while it is off. The level pulses (`BatteryAlerts`).
- **Full Battery** fires once when the charge reaches 100 % on power, and not
  again until it falls below 95 %. Optimized charging holding at 80 % is not
  full.
- **Timer Done** takes Full Battery's shape with the timer glyph and the set
  duration, "Timer", "Done".
- **Headphones connected**: the device's own drawing (AirPods of each model,
  Beats, EarPods and other Apple devices use Apple's artwork where the Mac has
  it), "Connected", its name, and a battery ring only when a level is readable
  without any new permission. Detected by `AmbientWatch`; headphones keep a
  30 s window between showings.
- **Volume and brightness** (§14): the output's name or "Display Brightness" /
  "Keyboard Brightness", the level's glyph, a white bar and the number.
- **New track**: the volume pop-up's shape under the notch, with the title
  where the output's name is, the cover where the glyph is, the artist along
  the bar and the equalizer where the number is (`NewTrackAlertLayout`). It
  arrives and folds exactly as the pop-up does and keys on the presented song,
  once per song. Open on Hover does not open the panel over it.
- **Isla update ready** (§15): the version, the release's first sentence,
  "Isla restarts when it is done.", **Later** and **Install** (the default).
  After Install it shows the installer's progress until Isla restarts; a
  failure shows the reason with Later and Try Again (or Settings, or Quit
  Isla). VoiceOver reads it as one container named "Isla %@ is ready". A
  click beside its buttons does nothing.

## 6. The open panel: surfaces and pages

`NotchViewModel.Surface` lists every surface: `player`, `stage`, `tray`,
`drop`, `clipboard`, `translate`, `settings`, `welcome`. The panel shows one
at a time. There are no tabs and no rail. `SurfaceContractTests` holds every
surface and every road to it.

- **Pages.** Music (the player), Shelf (the tray), Clipboard and Translate sit
  side by side in that fixed order (`Surface.pages`). Under every page, four
  dots (`PageDots`) say where you are; a click on a dot turns to its page.
  The order never changes and no page is ever missing: Music with no song
  shows Nothing Playing, an empty Shelf shows one line.
- **Below the pages.** The lyric stage (from Music), Settings (from the gear)
  and the two presented surfaces (the drop surface, the welcome) carry no dots
  and do not page.
- **Sizes.** The player has its own height; Shelf, Clipboard and Translate
  share one (`SurfaceLayout.toolPageHeight`), so turning between them moves
  only the content; the stage and Settings are 400 pt tall at a 38 pt notch.
  Heights move with the notch's height (`SurfaceLayout.y`).
- **The header row** is the notch's height and holds the page's identity on
  the left (the playing app's icon and name on Music; a glyph and title
  elsewhere, the title left out when it would not fit beside the notch) and
  the **gear** in a 26 pt well on the right, with a dot when an update waits.
  The gear opens Settings in place; on Settings it is an X ("Close Settings",
  `HeaderGear`) that goes back to where Settings came from. Remove All (Shelf)
  and History (Translate) are visible buttons beside it. Every control or
  page glyph is one size (`HeaderIcon`, 14 pt); no header tool's hit target
  is under 24 pt.
- **A surface change shows one pane at a time**: the old pane leaves on
  `Theme.swapOut`, the new one arrives after it on `Theme.swapIn`, while the
  outline springs to the new size underneath. Settings builds its form
  `Theme.swapOutDuration` after a swap begins (`SettingsPane.mountsAfter`);
  an open from the shut island builds the outline and header first and the
  body one pass later (`NotchContentView.stagesBody`), so the outline moves in
  the frame after the click.

### Every road to each surface

| Surface | Reached by |
|---|---|
| Music | a click on the Music activity or the new-track alert; ⌃⌥⌘I with a song; its dot; a swipe; Hide Lyrics on the stage |
| Lyric stage | ⌃⌥⌘L; the menu's Lyrics; a click on the player's cover, title or artist line when the song has lyrics |
| Shelf | a click on the Shelf activity or its bubble; the menu's Shelf; its dot; a swipe |
| Clipboard | ⌃⌥⌘V; the menu's Clipboard; its dot; a swipe |
| Translate | ⌃⌥⌘T or the menu's Translate Clipboard (with the clipboard's text); the Services item "Translate in Isla"; a Clipboard row's Translate; its dot; a swipe |
| Settings | the gear on every page and the stage; the menu's Settings…; ⌘, while the panel has the keyboard |
| Drop surface | a file drag reaching the notch |
| Welcome | the first launch |
| The page last shown | a click on the bare notch with no song; ⌃⌥⌘I with nothing live |

A song paused long enough for the island to rest still counts as a song: the
bare notch and ⌃⌥⌘I open the player, paused.

## 7. Interaction

- **Click.** A click opens the panel on what the island shows
  (`NotchViewModel.openTarget`), follows the rank (an alert folds instead of
  opening anything), and never toggles playback. A click on the notch's own
  span of an open header row closes the panel. A click outside closes it.
- **Hover.** A hover only brightens the island. **Open on Hover** (Settings,
  off by default) opens what a click would after the hover delay (default
  `NotchMetrics.openDelay`, 0.05 s).
- **Closing.** A click outside; Escape while the panel has the keyboard or is
  pinned; the pointer leaving a hover-opened surface (`closeDelay`, 0.32 s);
  a two-finger pull up; the notch's span of the header. A panel opened by a
  hot key, the menu, a Shortcut or VoiceOver is pinned and stays until one of
  those. A pinned panel that is not key holds plain Escape through a transient
  Carbon hot key registered only while the pin stands
  (`NotchController.updateEscapeHotKey`), and ends on another app's
  activation.
- **A body that shrinks under the pointer** (a dot to a shorter page) keeps
  holding the panel until the pointer reaches the new body, leaves, heads
  away, or presses or scrolls off the panel (`PointerWatcher.shrunkFromRect`,
  with a global mouse monitor only while the hold stands). The collapse check
  asks `holdsBeyondBody(at:)`, never a copy of the rule.
- **Pointer sampling.** 8 Hz at rest, 60 Hz near the island; a move into the
  top band while idle ticks at once, watched only while the pointer was last
  within 300 pt of it (`NotchGeometry.approachZone`), so a flick-and-click
  never reaches the menu bar behind. Sampling stops while the display sleeps.
- **Swiping pages.** A precise two-finger sideways swipe (trackpad or Magic
  Mouse) over a page turns it (`PageSwipe`): the first 10 pt decide the
  direction; the pages track the fingers 1:1; past Music and Translate the
  travel rubber-bands (constant 0.55); the release's velocity is projected and
  the nearest page at most one away is chosen; the settle is the island's
  spring from the fingers' velocity; momentum events after lift are ignored; a
  new swipe picks a settling page up where it is. `PageTravel` draws every
  frame on the display's clock with animations disabled. Nothing on a page
  scrolls sideways, so sideways is always the pages'. An ordinary wheel never
  turns a page.
- **Pulling open and shut.** Two fingers down over the shut island open what a
  click opens (over the bubble, the tray); two fingers up on the open header,
  or anywhere on the player, close it (`IslandPull`). Precise scrolls only;
  the first 10 pt decide (more vertical is the pull's); the release commits
  when travel plus projected speed reach 32 pt; the outline gives up to 8 pt
  while tracking. Down means the fingers' direction whatever the scrolling
  setting. A list's vertical scroll is never taken. Settings "Swipe to Open and
  Close", on by default. Over the lock screen a pull shakes and opens nothing.
- **Keyboard.** ⌃Tab and ⌃⇧Tab turn the pages while the panel has the keyboard,
  and keep it, onto the Shelf and Music too (`NotchViewModel.turnPageByKey`).
  Clipboard: typing searches, ↑ ↓ select, Return copies and closes, Escape
  clears the search then closes. Translate: Escape clears the text, then
  closes. ⌘, opens Settings.
- **Hot keys** (global, rebindable or clearable in Settings › Shortcuts, held by
  `HotKeyCenter`): ⌃⌥⌘I opens Isla (what a click would), ⌃⌥⌘V Clipboard,
  ⌃⌥⌘T Translate with the clipboard's text, ⌃⌥⌘L the lyric stage. A binding
  another app owns is reported in Settings.
- **The right-click menu** (`IslandMenu`) opens at a right-click or a
  Control-click on the island in any state and on an open header row:
  Clipboard, Translate Clipboard, Shelf, Lyrics (while there is a song),
  Timer ›, Settings…, Quit Isla. Shown keys are the current bindings; the menu
  claims no keys of its own. A row chosen from the shut island opens its
  surface pinned. It is the app's only menu. Over the lock it shakes instead.
- **Services.** "Translate in Isla" (`NSApp.servicesProvider`) opens Translate
  with the selected text, with no Accessibility permission.
- **Shortcuts, Spotlight and Siri** (`IslaIntents`): Show Isla, Show Lyrics,
  Current Track, Current Lyric, Set Lyric Delay, Play/Pause, Next Track,
  Previous Track.
- **Haptics** (`Haptics`) at two moments only, on the drawn frame: a lyric
  click landing on its line (`.alignment`) and an audio output picked on the
  lock card (`.levelChange`).

## 8. Music

### 8.1 The media path

MediaRemote's read path is closed to ordinary processes since macOS 15.4, and
the entitlement that opens it is restricted. So:

- `Sources/IslaMediaHelper/helper.m` builds `libislamedia.dylib`, loaded into
  `/usr/bin/perl` (a platform binary the daemon trusts, signed without library
  validation). It prints one JSON object per line on stdout and takes numeric
  commands on stdin, and exits when stdin closes, so it can never outlive the
  app.
- `NowPlayingFeed` spawns it and parses the stream: `NDJSONBuffer` keeps
  partial lines and bounds runaway ones; every `Snapshot` field is optional,
  and `commands: nil` means unknown, not none.
- `MediaController` layers the position clock over it: seek verdicts, rate,
  and the hold of a foreign session.
- **The Swift app never links MediaRemote.**
- When the helper is unavailable, `PlayerBridge` (AppleScript and distributed
  notifications) covers Music and Spotify only.
- **Music Only** (Settings › Music, on): video in browsers and other non-music
  sources does not take the island from a song.

### 8.2 Error contract

Helper failure, malformed JSON or missing resources never crash the app and
never raise a permission prompt (there is no user-grantable MediaRemote
permission). A malformed line is ignored without corrupting the last good
snapshot. A helper that dies is restarted with a growing delay
(`NowPlayingFailurePolicy`); after three consecutive failures Music falls back
to `PlayerBridge`; a helper that stays alive but silent is noticed within
about fifteen seconds. Music deactivates and the island collapses rather than
showing stale state.

### 8.3 Apple Events

Isla's one entitlement, `com.apple.security.automation.apple-events`, lets it
script Music and Spotify: the fallback, shuffle and repeat, the favourite,
the per-second position correction while lyrics are on, and the player's own
volume on the stage. No background Apple Event is sent to a player unless
macOS already allows it (`AutomationAccess`, checked read-only); the prompt
first appears when the panel opens on Music or Spotify, never at launch and
never over the lock screen. A play, pause or skip tap is the person's own act
and is not gated. A refusal (-1743) stops the background asking and costs
those controls only.

### 8.4 One presented song

Every surface that draws a song (the shut island and its new-track alert, the
player, the stage, the lock card) draws one value, `NowPlayingPresenter`: the
track, its cover, the cover's tint, its length, its app icon. A skip (Isla's
own Next or Previous, Spotify announcing another song, or the first report of
a new one) starts a hold: the old song stays drawn, clock still, until the new
title, artist and cover are in, at the latest 350 ms after the new title and
never later than 700 ms after the hold began. Then everything swaps in one
animation (`Theme.trackSwap`); a cover that is late fades in under the same
key. A skip inside a hold follows the newest song.

### 8.5 The player

- The playing app's icon and name in the header; the cover; the title and
  artist (joined by an en dash when the sung line takes the subtitle); the
  equalizer; elapsed and remaining time around a scrubber; a row of
  Favourite, Previous, Play/Pause, Next and Output. Every control is a 42 pt
  hit target answering on press.
- The cover, title and artist open the lyric stage when the song has lyrics,
  else bring the player app forward.
- **The sung line.** With synced lyrics and the Lyric Band on (Settings ›
  Music, on), the subtitle carries the line being sung, swept; between lines
  it holds the line the voice reaches next, unswept.
- **A long title or artist** that does not fit rests 2.5 s, its far end faded,
  then travels left at 30 pt/s until a copy stands where it began, and rests
  again (`MarqueeLine`, on Core Animation). Under Reduce Motion, or on a page
  not on screen, it truncates.
- **Favourite** shows where Isla can set it: Music (through Apple Events) and
  Spotify while the account is connected and its API answers. A tap on Music's
  star stays as tapped while Music catches up (re-asked over 15 s), because a
  favourite of a song not in the library is a cloud edit that lands seconds
  later. Elsewhere the star is absent and the other controls keep their
  places.
- **Output** opens the audio output menu (Settings › Music › Output Button,
  on). A live stream shows LIVE in place of the times.
- The player draws no volume bar; the stage has the song's volume (§10.3).

## 9. The Shelf

- **Dragging in.** A file drag reaching the notch opens the drop surface with
  two targets, **Keep on Shelf** and **AirDrop**; the one under the pointer is
  lit. Leaving without a drop folds it back. Promised files (Mail, Photos) are
  received without blocking the process (`PromisedDropInbox`). After a drop
  the Shelf is live; a confirmation says "Added to Shelf".
- **What keeps the Shelf live.** A file a person put there (dropped on the
  notch, a promised file from such a drop, kept from the AirDrop target).
  Files Isla collects itself (copied screenshots saved by the vault,
  recordings picked up from the capture folder) make it live for 2 s only.
  At the limit of 60 items (`ShelfStore.limit`), collected cards leave first,
  oldest first.
- **The tray** is Finder's icon view: a grid of tiles (as many to a row as fit
  — five at 480, six at 560 and 620) that scrolls down with fades; the icon or
  thumbnail, the name in two lines cut in the middle, the date added under it.
  A picked tile is a grey rounded square behind the icon with the name on the
  Highlight colour; ⌘ and ⇧ pick several; the remove badge shows on hovered
  or picked tiles. Space opens Quick Look. Remove All asks in place: "Remove
  all %d items? Files are untouched." Notices sit under the grid.
- **Cards are references.** Nothing is copied: a card holds the file where it
  is and follows it when it is renamed or moved. Dragging a card out copies by
  default; ⌘ moves, and the card follows the moved file. A card whose file was
  deleted or put in the Trash is removed when the tray is next opened; one
  that is only unreadable is kept. Files from protected folders raise macOS's
  prompt only when the Shelf is opened or used, never at launch.
- **Delete.** ⌫ and ⌘⌫ remove the selection, never the files, through a
  transient Carbon hot key (`ShelfDeleteKeyHolder`) held only while the panel
  is open on the tray, the pointer is over it, Isla is not active, and the
  selection was made during this opening. A stuck one would eat Delete
  system-wide, so every other state releases it.
- **Screen captures.** With Show Screen Captures on (Settings › Screenshots,
  on), what Screenshot.app saved since Isla first ran (its configured folder,
  the Desktop, any folder it has used) appears on the Shelf when it opens; a
  still counts only with the capture prefix, a movie on its type. Nothing
  watches in the background. With Save Clipboard Screenshots on (off), a
  screenshot copied to the clipboard is saved to `~/Pictures/Isla`, at most
  200 files (`ScreenshotVault.retentionLimit`), and lands on the Shelf.

## 10. Lyrics

### 10.1 Sources

- **Lyrics** (Settings › Lyrics, off by default) turns every lyric surface on.
- Local first: LRC files imported, and folders the person chose
  (`LocalLyricsLibrary`). An indexed folder's lyric is ready before any panel
  opens; a rescan never replaces a shown lyric with a weaker candidate. An
  ambiguous local match always asks. Imports, bindings and timing corrections
  stay on the Mac.
- **Look Up Lyrics Online** (off by default) asks LRCLIB (§17) for a track the
  local library does not match. Answers are cached so a song is asked about
  once; misses are kept for a fortnight; a 429 pauses every lookup for its
  Retry-After or a backoff that doubles to 30 min (`OnlineLyricsPause`). LRCLIB
  is line-level, so word sweep needs an enhanced LRC brought by hand.
- Word timing animates only for a measured player clock (Music and Spotify,
  through Apple Events); every other player is line-level.

### 10.2 One timeline, one renderer

`LyricSweep` owns the clock for every surface (`index`, `centreIndex`, `end`,
`lead`, `position`, `fraction`, `displayed`); `LyricRow` and `KaraokeText` own
what a line looks like. The stage and the lock card keep only their own
containers. Do not add another binary search over lines.

- **Lyric Delay** (Settings › Lyrics, ±3 s) moves every line later or earlier,
  for speakers or headphones that run late; a per-track correction (±45 s)
  sits on top.
- **Show Next Line Early** (Settings › Lyrics, Auto by default): only the shut
  island's one-line caption reads ahead of the voice, 0.30–0.50 s by the
  length of the line turned to, never more than 45 % of the gap
  (`LyricSweep.maximumReadAheadShare`). `LyricSweep.readingMoment` is the one
  function that picks its line and `readAheadStart` the one that says when it
  turns; the boundary wakes ask the same functions.
- **A timeline stamped past the track's end** (`LyricTimeline.overrun`) is timed
  for a longer version: the stage says so and every row offers Sync Here,
  which sets the per-track delay (`LyricSweep.syncDelay`).
- Pauses in a timeline with end stamps of 1.5 s or more
  (`LyricSweep.minimumHonouredGap`) hold the coming line dim.
- Between lines, the stage and the lock card stand still: their bars move on
  Core Animation and nothing redraws on the position tick.

### 10.3 The lyric stage

The one lyric surface in the panel, 400 pt tall. Lines from the top, every line
the same size (the sung line is never larger), up to two rows each and cut
after the second; the sung line swept, others dimmed by distance; scrolling on
`Theme.lyricScroll`; fades at the column's top and bottom. A click on a line
seeks to it. The foot: the cover, title and artist, the transport, and the
tools Show Translation (when a translation is possible), More, Output, Volume
and Hide Lyrics, and a progress bar in the cover's tint.

- **More** holds Lyric Timing, Edit Lyrics…, Search Again, Search Online,
  Import LRC File…, Remove Local Binding, Lyrics Settings…, Shuffle and Repeat.
- **Volume** is the song's own: Music's and Spotify's `sound volume` through
  Apple Events, or the Mac's output for any other source. The first press for
  Music or Spotify is the only thing that can raise macOS's Automation prompt;
  a refusal moves the slider to the Mac's volume with one line, "Allow Isla to
  control Spotify…". The slider folds 3 s after the last touch.
- **Translate Lyrics** (Settings › Lyrics, off) puts a translation under each
  line, all arriving together.
- With no song the stage is not drawn; ⌃⌥⌘L on a silent Mac shows the empty
  player. The stage never folds back to the player on its own.

## 11. Clipboard and Translate

### 11.1 Clipboard

- **History** (Settings › Privacy, on) keeps the last 40 items copied while Isla
  runs (`ClipboardStore`), in memory only: text, links, colours, code, files
  and, with Include Images on, pictures. Items marked concealed or transient
  by the copying app are never recorded. A text is capped at 256 KB.
- Pictures' bytes live in a per-launch file under
  `~/Library/Caches/com.ctimothe.isla`, mapped when pasted back, with a 32 MB
  resident budget; the same picture copied again moves up rather than being
  kept twice.
- **Keep Pinned Items** (off) writes pinned text and file entries, never images,
  to `~/Library/Application Support/Isla/pinned-clipboard.plist` (mode 0600);
  turning it off deletes the file.
- **Reading the pasteboard.** Picture and recording bytes are read off the main
  thread through `PasteboardRead`, one serial queue; a newer copy drops an
  older read's result. While a read is in flight the main actor asks the
  pasteboard for its change counter and nothing else (AppKit's type cache
  crashes when rebuilt on two threads). `PasteboardAccessContractTests` fails
  on any other reach for the general pasteboard. While one of Isla's windows
  is key, reads stay on the main thread, because AppKit's own Paste reaches
  the pasteboard there.
- **Paste from Other Apps.** Isla follows macOS's per-app pasteboard privacy:
  under Ask it reads once per copy and never twice; under Don't Allow the page
  says so and offers Open Privacy Settings.
- The page: a search field and a kind filter (All, Text, Links, Images), rows
  with their age or "Pinned", and row menus (Pin, Paste, Paste as Plain Text,
  Translate, Clear Everything…). A row click copies and shows "Copied"; only
  Return closes.

### 11.2 Translate

- Sixteen languages (`TranslationLanguage.all`). On the Mac, through Apple's
  Translation framework, or the on-device model on macOS 26 and later with
  Apple Intelligence. A pair the Mac can do is never sent online, even when it
  cannot run right now (not downloaded, Apple Intelligence off); the page says
  why and offers Use Online when Translate Online is on.
- **Translate Online** (Settings › Translate, off) sends a pair no engine on the
  Mac offers (Uzbek, Kazakh), or one the person asks for with Use Online, to
  MyMemory (§17). Text the clipboard brings never goes online on a press made
  for other words: Use Online is revoked when ⌃⌥⌘T or the service replaces the
  text. An answer from the network says "Online".
- The source holds 20,000 characters (`Translator.commandInputLimit`); a letter
  past it is refused. Language detection runs letters and scripts first, then
  Apple's recognizer held to the offered languages.
- History (Settings › Translate › Keep History, off) and Speak (on) are
  per-setting; Recent targets are this session's, in memory.

## 12. The lock screen

- `LockScreenPresence` watches `com.apple.screenIsLocked` and
  `com.apple.screenIsUnlocked` and lifts the panel into a SkyLight space of its
  own at absolute level 400, over the lock screen's space at 300. The SPI is
  resolved with `dlsym`; on a macOS that drops a symbol, the island hides while
  locked. Raising the window level past `CGShieldingWindowLevel()` does not
  work.
- **Over the shield the island is visible and inert.** It shows the Locked
  activity; a hover brightens it; a click, a right-click or a pull shakes it
  (`RefusalShake`) and VoiceOver hears "Unlock your Mac to open Isla." Nothing
  opens. Two alerts may take its wings while locked, compact, and fold back:
  the volume and brightness pop-up and the charger. Everything else waits for
  the unlock.
- **The lock card** (Settings › Lock Screen › Show on Lock Screen, on) is a
  separate window, `LockCardWindow`, centred on the island's display, the only
  thing that answers clicks over the shield. With **Rest as Banner** (on), the
  song rests as a slim banner under the clock with play/pause in a progress
  ring; a click grows it into the card in place (`Theme.lockCardMorph`), and
  the chevron shrinks it back.
- **The card**: cover, title, artist, the favourite where available, the sung
  line, a progress bar, the transport, and a foot with Lyrics, the output
  volume and Output. Lyrics opens a lyrics pane, Output a Sound pane listing
  devices (picking one fires the haptic and stays on the pane). **Card Size**:
  Compact (default) or Standard.
- **Material.** Nothing above the shield can sample the wallpaper, so the card
  always draws its own recipe. **Card Style**: Transparent (default; black with
  the least alpha at which the dimmest type clears 4.5:1 over the wallpaper's
  luminance behind the card, from 0.30 up), Automatic (the cover's light at
  an alpha chosen from the wallpaper), Tinted (the cover's light) and Solid.
  Reduce Transparency draws Solid; Increase Contrast draws Transparent as
  Solid. `WallpaperTone` measures the wallpaper for this alone.
- The volume and media keys while locked are taken only while the island is
  over the shield (`MediaKeyGate`); otherwise the system's own OSD shows.

## 13. Settings

Settings is a 400 pt surface with a sidebar of ten sections: General, Privacy,
Shortcuts, Music, Lyrics, Lock Screen, Translate, Connections, Screenshots,
About (`SettingsSection`). Every row, its key and its default live in one pure
table, `SettingsTable`; `NotchViewModel`'s accessors read their defaults back
from it, so a setting is added there, not in a view. It opens on the section
last shown.

- **General**: Launch at Login, Open on Hover (and its delay), Swipe to Open
  and Close, Panel Width; "The island shows": Charger Connected, Low Battery
  Warning, Fully Charged (battery rows only on a Mac with a battery),
  Headphones, New Tracks, Microphone and Camera, Downloads, Volume and
  Brightness, and the Accessibility state when that needs it.
- **Privacy**: Clipboard History, Include Images, Keep Pinned Items; the covers
  for Clipboard rows and Translate text (`PrivacyMode`: covered text shows as
  drifting dots until revealed, and every reveal resets when the panel
  closes); Hide from Screen Recording (on: `sharingType = .none`; Settings says
  it only asks macOS).
- **Shortcuts**: the four hot keys, each recordable or clearable. A shortcut
  field takes the keyboard only while it records.
- **Music**: the Now Playing reader's state and Try Again; Automation state;
  Music Only; Output Button and Lyric Band.
- **Lyrics, Lock Screen, Translate, Screenshots**: their sections' switches.
- **Connections**: every installed player (`PlayerConnections`, icons from the
  installed app at runtime) and the Spotify account.
- **About**: version, Check for Updates, Check for Updates Automatically,
  Update Now, Copy Diagnostics (versions, settings and Isla's log; nothing
  played, copied or translated), Report a Problem…, Acknowledgements, Quit.
- Rows are native: System Settings' row height, 13 pt labels, grey footers,
  System Settings' own icons in the sidebar where the system has the pane
  (read at runtime; nothing is shipped), the accent colour followed live. Every
  switch is one `Toggle` whose label is its icon and title.

## 14. Volume and brightness

**Volume and Brightness** (Settings › General, off by default) replaces the
Mac's own pop-up with the island's: volume, mute, display and keyboard
brightness.

- It needs Accessibility, asked for only when the switch is turned on: the keys
  are read through a session event tap (`MediaKeyTap`), which sees them before
  the system. No key is consumed until the permission is granted, and turning
  the switch off gives the keys back at once. Isla repairs its own stale
  Accessibility entry with `tccutil reset Accessibility com.ctimothe.isla`
  (never another app's), only while the switch is on, Isla is not trusted, and
  the Mac is unlocked with the display awake (`AccessibilityRepair`).
- **The tap's callback is a decode and a write.** A slow or stuck tap eats those
  keys in every app. A press is decided on the tap's thread from a mirror of
  the setting, the lock and the hold table; Isla takes a key only when it can
  apply it, and decides once per hold.
- **Volume is predicted, then written.** The level a press means is stepped
  (1/16, or 1/64 with ⌥⇧) from the intended volume and drawn at once; one
  writer queue writes the newest target, so a slow device costs the write in
  flight and then the newest level. A target from before the default output
  changed is dropped. Only outside changes (the menu-bar slider, another app)
  are adopted as the new intention. Brightness goes through private
  DisplayServices and CoreBrightness entry points resolved with `dlsym`; a
  missing symbol leaves those keys to the system.
- **The look.** Shut, the pop-up is an expanded alert (§5.6) on
  `Theme.hudSpring`, its content fading in over 0.1 s; the bar has no curve
  and sits on each press's level on the frame the press is drawn. Open, it is
  the capsule under the panel (§5.3). It folds 1.5 s after the last press
  (`Theme.hudLinger`). A press redraws only the pop-up (`HUDLiveLevel`).
  VoiceOver hears the level 0.25 s after the last press.
- macOS keeps ⌥+volume (Sound settings) and ⇧+volume (silent step).

## 15. Updates

- **The hourly check.** Every copy asks GitHub's
  `repos/ctimothe/isla-mac/releases/latest` 20 s after launch and then hourly
  (`UpdateCheck`), naming Isla's version and nothing else. **Check for
  Updates Automatically** in Settings › About turns it off; a person's off is
  kept. It is the one network request that is on by default.
- **Update Now** downloads `Isla-<version>.dmg` and its `.dmg.sig` from that
  release only, verifies the Ed25519 signature against `IslaUpdatePublicKey`
  in Info.plist before mounting, validates the staged app (bundle id, newer
  version, greater build, a code signature that satisfies the running copy's
  designated requirement, or a Developer ID build of `com.ctimothe.isla`),
  replaces Isla in place with one atomic exchange and relaunches. The image is
  capped at 100 MB; installing fails after two minutes. A copy that cannot
  write its own location, or a build without a key, offers only the download
  page. An update downloaded this way carries no quarantine.
- **The island's offer** (§5.6) shows each version once, at the first idle
  moment (nothing open, no alert, not locked; delayed under a resting pointer,
  over a full-screen app or a talk, and while the displays are dark). Later,
  or 20 s unanswered (held while the pointer rests on it), folds it; that
  version is not offered again and the gear keeps its badge. A surface opened
  over it takes it down; it returns when the surface closes.
- **The local dev feed** (the owner's Mac only). With `updates.localFeed` in
  Isla's defaults naming an absolute folder the user owns and nobody else can
  write, the update source is that folder's `release.json` (`UpdateSource`),
  and only builds signed by the feed's own key ("Isla Dev Update Signing",
  `IslaDevUpdatePublicKey`) are installed, through the same validator, swap
  and restart. The folder is judged again before every read, watched
  (`UpdateFeedWatcher`) and offered within a second or two of a publish.
  `Scripts/publish-dev-update.sh` publishes the committed checkout to it as
  `VERSION.N`. Public releases carry no feed key.
- **Rehearsal.** `DI_UPDATE_REHEARSAL=<folder>` makes Update Now take its release
  from that folder (`Scripts/rehearse-update.sh`).

## 16. Accessibility

- Each activity is one accessibility element with its label; the island reads
  first, then the bubble, then the open surface. Alerts announce their label
  when shown.
- The page dots are one adjustable element, "Pages, Page 2 of 4, Shelf";
  increment and decrement turn one page.
- The update alert is one container with both buttons. Two-press confirmations
  (Clear, Remove All, Quit) speak "Press again to confirm" and stay armed for
  8 s under VoiceOver; Escape disarms (`Confirmation`).
- Settings' group headers are headings; sliders commit one step per VoiceOver
  increment.
- **Reduce Motion**: every spring becomes `Theme.reducedMotion` (0.24 s
  ease-in-out) with no overshoot; content crossfades with no blur or scale;
  pulses, rings and marquees stand still; swipes still track the fingers.
- **Reduce Transparency**: surfaces and the lock card go opaque.
  **Increase Contrast**: strokes, tracks and secondary text strengthen.
  `SystemAppearance` honours both live.
- Type uses `Theme.tracking(forSize:)`, because SwiftUI applies Apple's tracking
  table to semantic text styles and not to the fixed sizes a fixed panel uses.

## 17. Privacy: what leaves the Mac

Only the update check leaves the Mac on its own. Everything else is off until
the person turns it on, except the Spotify cover fetch, which has no switch.
Every request goes through `PrivateNetwork.session`: no cache, no cookies, no
stored credentials.

| What | Default | Sends | To |
|---|---|---|---|
| Check for Updates Automatically | **on**, hourly | one request naming Isla's version | GitHub API |
| Update Now / Install | on the person's press | downloads the release image and signature | GitHub Releases |
| Look Up Lyrics Online | off | title, artist, album, length | LRCLIB |
| Translate Online | off | the text and its two language codes | MyMemory (translated.net) |
| Spotify account (Connect) | off until Connect | PKCE sign-in; library contains, save and remove; one `/v1/me` after a grant | Spotify |
| Spotify covers | no setting | the cover's address, only when Spotify plays and Now Playing cannot describe it | Spotify's image server |

On the Mac but outside Isla, each opt-in:

- **Recording** (off) watches which apps hold the microphone or a camera; Mute
  changes the Mac's input mute only while a recording lasts.
- **Downloads** (off) lists ~/Downloads and reads the quarantine mark's agent;
  the first scan asks for the folder.
- **Volume and Brightness** (off) needs Accessibility and changes system volume
  and brightness.
- **Output** in the player and on the lock card switches the system's default
  output and its volume. On by default, because the controls only read until
  the person moves them.
- Spotify tokens live in the data-protection keychain on a Developer ID build,
  otherwise in `~/Library/Application Support/Isla/spotify-credentials.json`
  (mode 0600). Spotify sign-in steps are logged under `com.ctimothe.isla` /
  `spotify` with no token, code or verifier.

Anything new that leaves the Mac, touches an account or changes a system-wide
setting is listed here and in the README's Privacy table, and defaults to off.

## 18. Motion

The current curves, by their `Theme` names. islandcn's motion is being adopted
slice by slice (`plans/2026-11-15-islandcn-identical.md`); until a slice lands,
these are what ship.

- **The shut island's changes** use one spring per kind of change, measured by
  islandcn from the iPhone (`IslandMotion`, `IslandMorph`): `appear` 0.483 /
  0.62, `expand` 0.517 / 0.824, `appearExpand` 0.54 / 0.811, `swap` 0.498 /
  0.829, `collapse` 0.479 / 0.894, `alertCollapse` 0.535 / 0.84, `split`
  0.505 / 0.815, `unsplit` 0.487 / 0.794, `dismiss` 0.432 / 1.019, `resize`
  0.5 / 0.82 (response / damping). Content arriving comes into focus from a
  blur, scaled on an expanded shape, scaled in x on a compact one.
- **Opening into a surface, closing, and surface changes** move the outline on
  `Theme.islandSpring` (response 0.5, damping 0.75), the one place the island
  overshoots, because it is an object growing out of the bezel; the close
  waits `Theme.closeShapeDelay` (0.03 s). Content inside a surface keeps
  critically damped curves (`Theme.criticallyDampedSprings`): `paneIn`,
  `paneOut`, `swapOut` (0.08 s), `swapIn` (0.20 s after it), `contentAnimation`.
- **The pop-up and the new-track alert**: `Theme.hudSpring` (0.3 / 1.0).
- **Lyrics**: lines scroll on `Theme.lyricScroll` (0.42 / 0.86, the one
  overshoot inside content: a song carries momentum); the caption turns on
  `captionTurnOut` and `captionTurnIn`.
- **A skip**: `Theme.trackSwap` (0.3 / 1.0), the cover from 0.96.
- **Hover**: `Theme.hoverNudge`. **The lock card**: `Theme.lockCardMorph`
  (0.36 / 1.0).
- **Reduce Motion**: `Theme.reducedMotion`, 0.24 s ease-in-out.
- A transparent window is cut once; morphs never resize it.

## 19. Product rules

- **Identity.** The product is Isla, bundle id `com.ctimothe.isla`. No Cyclop
  name, icon, identifier, path, screenshot or copy anywhere in `Sources`,
  `Resources` or the named scripts, comments included; nor the former product
  name "Dynamic Island" (`Scripts/test-branding.sh`). "Dynamic Island–style"
  is nominative use and lives only in the README.
- **Strings.** Every user-facing string is in `Resources/en.lproj` and
  `Resources/ru.lproj`; the key is the English text
  (`Scripts/test-localizations.sh`).
- **Icons.** Every glyph Isla draws is islandcn's: Hugeicons' free set,
  vendored by `Scripts/vendor-hugeicons.mjs` and drawn by islandcn's recipes
  (`IslandGlyph`, `GlyphRecipe`). App Intents' Shortcuts icons stay SF
  Symbols (the system draws them). Other apps' icons are the installed app's,
  read at runtime (`AppIcons`); Apple products keep Apple's own drawing where
  the Mac has it. No third-party brand asset ships in the bundle. The app
  icon's source is `Resources/AppIcon.icon`.
- **Materials.** Translucent surfaces (menus, the lock card's glass) go through
  `glassSurface(...)`: Apple's `glassEffect` on macOS 26 where there is a
  backdrop to sample, `GlassSurface`'s drawn recipe otherwise; never both
  stacked. `defaults write com.ctimothe.isla drawnGlass -bool true` forces the
  recipe. The island itself is black, not glass.
- **Entitlements.** Exactly one, `com.apple.security.automation.apple-events`.
  A Developer ID build adds `keychain-access-groups` at bundle time. Adding
  any other is a product decision.

## 20. Performance

- **At rest.** Panel shut and idle: CPU at or below 0.1 %, RSS at or below
  88 MB (`Scripts/measure-idle.sh closed-idle`, display held awake). Timers
  run only when their state needs them: the pointer sampler drops to 8 Hz
  after 3 s at rest (`NotchMetrics.restThreshold`), the lyric clock exists
  only while a lyric surface is on screen, and everything stops while the
  display sleeps.
- **Between lyric lines**, the stage, the lock card and the player's sung line
  do not redraw; bars and sweeps run on Core Animation.
- **Against Cyclop 0.6.5**, on the same Mac and session, three-run medians:
  application and helper RSS no higher than the reference; no orphan helper,
  timer growth or sustained RSS growth after 100 open and close cycles
  (`Scripts/measure-performance.sh`, by hand).
- **Frames.** Open, close, alerts and page swipes deliver every frame on an
  idle 120 Hz Mac; the outline moves in the frame after the click. Measure
  SwiftUI under a real `NSApplication.run()` (`Scripts/measure-hitches.sh`),
  never under the test runner's wait, which measures the runner.
- **The volume key** reaches the screen within one frame of the press, however
  slow the output device.
- **Lyric timing.** Word timing at or below 150 ms p95 for a publisher before
  its words sweep (`Scripts/measure-sync.sh`); otherwise it stays line-level.

## 21. Distribution and signing

- Distributed as a direct-download DMG from GitHub Releases, never the App
  Store: the media helper relies on private MediaRemote behaviour.
- `Scripts/bundle.sh` builds the `.app` around the SwiftPM binary (no Xcode
  project) with hardened runtime, in `build/app.noindex/` so Spotlight skips
  it. It signs with the pinned self-signed "Isla Code Signing" certificate
  (`Scripts/signing-identity.sha1`) when present, ad-hoc otherwise, or with a
  Developer ID when given. Without a Developer ID a first download needs the
  README's `xattr` step: under quarantine, `/usr/bin/perl` refuses an
  unnotarized `libislamedia.dylib` and macOS offers to delete it, and Music
  falls back to Music and Spotify only. `Scripts/test-gatekeeper.sh` measures
  this and skips itself on an ad-hoc build.
- Every merge to `main` that changes the app is released by CI
  (`.github/workflows/release.yml`): versioned by `Scripts/next-release.sh`,
  signed, gated by `Scripts/release.sh`, uploaded with its `.sig`, and offered
  on every island within the hour. Merging to `main` is shipping to every user.
- Signing identities, Apple credentials, notarization inputs and update keys
  are release-owner inputs, never committed.

## 22. Removed — never reintroduce

- Tabs and the rail (one surface at a time, reached by pages, dots and roads).
- Tools, its cards and the Tools button (the gear holds that place).
- Notes, Snippets, Calendar and the Teleprompter, with their stores and the tall
  panel body.
- The status item, its menu, a Dock icon, and any main window.
- Changing the activation policy at runtime.
- Stepping aside for Apple's own island on a Mac that has one, and Show on
  Built-in Display (Isla is for notched MacBooks).
- The 300 pt compact island and its 40 pt wings; the luma-faded key line; the
  lyric column and the tall lyrics page; Expand and Collapse per surface.
- The new-track peek that widened the song's pill (it is now the pop-up's
  shape).
- A volume bar in the player (the stage's Volume is the song's).
- Hover-to-switch, and any control on the compact island.
- The amber level and its glow on the pop-up.
- A tab or surface beyond `Surface`'s list without a spec change here and in
  `SurfaceContractTests`.
