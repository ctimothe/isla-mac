# Isla redesign — implementation spec

Date: 2026-10-15. Status: **binding** for releases R1–R5 below. It turns the
approved design canvas (private artifact `JxichKoJQFvMpZ71fSdgqb`, version 33,
188 boards) into measurements, colours, springs, strings and defaults that code
can be held to. Where this spec and a board disagree, this spec wins; where this
spec is silent, the board is the reference.

Upstream of this document:

- the parity design, `docs/plans/2026-08-18-dynamic-island-parity-design.md`,
  amended on 2026-10-15 for the tall body, Settings in the tall body, and the
  volume and brightness pop-up;
- the battle plan, `docs/plans/2026-08-21-music-first-battle-plan.md`, whose
  §5 "no full HUD replacement" line is amended on the same date;
- `checklist.md` §"Redesign — 2026-10-15", which records defaults, the
  owner-waived exception for Volume and Output, and the hardware checks each
  release owes.

## 0. Owner decisions (15 Oct 2026, settled — do not reopen)

| # | Decision |
|---|---|
| 1 | The island's wings hide while the lock banner or card is showing. One surface per activity. |
| 2 | Compact island 300 pt wide: the notch plus two 40 pt wings, even margins. |
| 3 | The new-track peek grows the island to 50 pt tall, two lines. |
| 4 | Lock banner is a rounded rectangle, radius 22, cover radius 10 (concentric), not a capsule. |
| 5 | Automatic lock-card material is mostly solid: opacity floor 0.84. |
| 6 | The current lyric line is the same size as the others; weight 700 and full brightness set it apart. |
| 7 | A tab grows taller by an Expand/Collapse button only; no bottom-edge drag. |
| 8 | Volume and Output in the player are **on** by default — an owner-waived exception to the default-off rule for system-wide settings. Nothing changes until the person moves the slider or picks an output. |
| 9 | Shelf removal: a normal (not red) Remove button, the right-click menu, the Delete key, **and** the hover ⓧ badge. |
| 10 | Clipboard history empties at quit (as today). Keep Pinned Items saves pins to this Mac; off by default. |
| 11 | Translated lyrics are off by default; the switch is Settings › Lyrics. |
| 12 | Clipboard gets the same Expand/Collapse button as Lyrics, Shelf and Translate. |
| 13 | Volume and brightness pop-up in the island: a full replacement of the Mac's pop-up (volume, mute, display and keyboard brightness), opt-in, off by default, needs Accessibility; its own release (R5). |

## 1. Conventions

- All values are points at 1×. "Body coordinates" have their origin at the
  open body's top-left corner, which sits at the top of the screen; the first
  `notchSize.height` points (38 on a 14-inch MacBook Pro) are the header row.
- Boards are drawn at the default body width, **560**. Anything placed against
  the trailing edge is written `bw − n`, where `bw` is the body width
  (480…620); anything written as a plain number is placed against the leading
  edge.
- Colours are on black unless stated. `white α` means `Color.white.opacity(α)`.
- Board names (`Music-Playing`, …) are the canvas frame names.
- Strings are given in English; every new one has a Russian row in §15. Keys
  are the English text, as everywhere in Isla.

## 2. Tokens

### 2.1 Colour

| Token | Value | Use | Theme today |
|---|---|---|---|
| label | white 1.0 | titles, the sung line, button glyphs | `.white` |
| secondary | white 0.55 (0.75 with Increase Contrast) | subtitles, header glyphs, values | `Theme.secondary` |
| tertiary | white **0.50** (0.65) | ages, footnotes, off-state toggles | `Theme.tertiary`, `tertiary(over:)` |
| quaternary | white 0.30 (0.50) | placeholders, character counts — never text a person must read | new `Theme.quaternary` |
| fill | white 0.08 | hover wells, wells behind empty art | — |
| selectedFill | white 0.18 | an on toggle button, the selected rail item | — |
| hairline | white 0.10 | separators | — |
| accent | `#FF453A` | the owner's red: default buttons, the selected output circle, recording field | as today |
| green | `#30D158` | charging bolt and level, "Connected" | — |
| warning | `#FF9F0A` | an alert icon that is a warning | — |
| findHighlight | `#FFD60A` behind `#1D1D1F` text | a search match | new |
| islandHover | `#1C1C1E` | the compact island under the pointer | replaces the white gradient lift |
| keyLineMusic | the cover's tint, α 0.50 | the key line round a music island or panel | new |
| keyLineNeutral | white 0.26 | the key line round any other island or panel | new |

The cover's tint is the colour the equalizer draws in (§3.4); the board's
`#FF8A73` is that tint for the sample cover.

**The contrast floor wins over the boards.** The canvas draws tertiary text at
0.38 and quaternary at 0.24; the app keeps `Theme`'s contrast-held values
(tertiary 0.50 over black, raised per fill by `tertiaryOpacity(over:)`), which
`ContrastRampTests` enforce for WCAG AA. Every colour goes through `Theme`'s
functions so Increase Contrast keeps reaching it; no view writes a raw
opacity for text.

### 2.2 Type

Sizes go through `Theme.TypeRole` and `islandFont(_:)`, so the tracking
table applies. The boards were drawn with ten sizes; the app keeps its roles
and adds exactly two:

| Board size | Role | Size |
|---|---|---|
| 10, 10.5 | `caption` | 10 |
| 11, 11.5 | `body` | 11 |
| 12, 12.5 | **NEW `reading`** | 12.5 |
| 13 | `subhead` | 13 |
| 15, 16 | `title` | 16 |
| 17 | **NEW `lyric`** | 17 |
| 21 / 28 | `display` / `hero` | 21 / 28 |

`TypeRoleTests` is updated with the two roles and the reason (the redesign's
reading text and the tall lyric page). The table below gives board sizes; the
role is what ships.

| Role | Size / weight | Where |
|---|---|---|
| Panel header title | 12 / semibold, secondary, title case | "Music", "Shelf", … at (17, 11) |
| Player title | 16 / semibold, tracking −0.2 | `Music-Playing` |
| Player subtitle | 12.5 / regular, secondary | |
| Lyric band, sung line | 13 / bold, swept | |
| Lyric band, next line | 13 / semibold, white 0.36 | |
| Column lyric lines | 13 / semibold, ramp of opacities | `Music-Column` |
| Column translation | 10.5 / regular (sung line 11.5 / medium) | `Lyrics-Column-Translated` |
| Tall lyric lines | 17 / bold, ramp of opacities | `Lyrics-Tall` |
| Tall translation | 12 / regular (sung line 13 / medium, α 0.66) | |
| Row text (Clipboard, menus) | 12.5 / regular | |
| Small push button | 11 / regular | Settings rows |
| Toolbar push button | 11.5 / regular, 22 tall | Shelf, Translate |
| Footnote | 10.5 / regular, tertiary, wraps at line height 1.3 | Settings |
| Monospaced | `.monospaced` 12 | colours and code in Clipboard, LRC times |

The sung lyric line is never larger than its neighbours (decision 6): it is
weight 700 at full white; the others are weight 600 (column) or 700 (tall)
at lower opacity.

### 2.3 Radii

| Shape | Radius |
|---|---|
| Compact island bottom corners | 12 |
| Peek island (50 tall) | 16 |
| Open body, 208 tall | 22 (bottom) |
| Open body, 400 tall | 26 (bottom) |
| Cover: compact island | 6 |
| Cover: peek | 8 |
| Cover: player (132) | 14 |
| Cover: lyric column (52) | 9 |
| Cover: tall lyrics (34) | 7 |
| Lock banner / its cover | 22 / 10 |
| Lock card standard / its cover | 30 / 10 |
| Lock card compact | 28 |
| 22 pt icon button / 26 pt icon button | 7 / 8 |
| Shelf selection well / hover well | 8 |
| Clipboard row hover / copied well | 7 |
| Translate source card | 12 |
| Settings group | 9 |

Concentricity rule, from the HIG: an inner shape inset by `m` inside an outer
radius `R` gets radius `R − m` (rounded to the table above).

### 2.4 Motion

All springs are `Animation.spring(response:dampingFraction:)`; *response* is
the time to reach the target, not a duration. Existing names keep their
`Theme` values; **NEW** rows are added to `Theme` with a comment naming the
board that motivated them, as the file does today.

| Transition | Curve | Reduce Motion | Theme name |
|---|---|---|---|
| Panel opens | spring 0.34 / 1.0; content in easeOut 0.20 after 0.04 | easeInOut 0.24, no travel | `openAnimation`, `paneIn` |
| Panel closes | content out easeOut 0.10; the shape 30 ms later on 0.34 / 1.0 | easeInOut 0.24, no delay | `closeAnimation`, `paneOut` |
| Tab switch | old pane out 0.10, new pane in 0.20; height springs 0.34 / 1.0 when it differs | crossfade 0.24 | `paneOut`, `paneIn` |
| Expand / Collapse, 208 ↔ 400 | spring **0.40 / 1.0**; cover, title and transport travel with the body | crossfade 0.24, no travel | **NEW `expandAnimation`** |
| Player ↔ lyric column | spring 0.34 / 1.0, one morph (cover 132 → 52, title 16 → 13, controls fold left) | crossfade 0.24 | `openAnimation` |
| Island appears / folds | spring 0.42 / 1.0; content out 0.20, in 0.36 after 0.07 | easeInOut 0.24 | `pillUnfold`, `pillFold`, `pillContent` |
| New-track peek, 300 → 520 wide and 38 → 50 tall | spring 0.28 / 1.0; text in on `pillContentIn` after the shape; holds 2.2 s; folds 0.42 / 1.0 | crossfade, no growth travel | `compactAnimation`, `sneakPeekDuration` |
| Charging, headphones | same beat as the peek | crossfade | `compactAnimation`, `ambientDuration` |
| Volume / brightness pop-up (R5) | spring **0.28 / 1.0** to open; the level bar easeOut **0.12** per press; folds 0.42 / 1.0 after **1.5 s** idle | appears and folds by crossfade; the bar steps | **NEW `hudAnimation`, `hudLevel`, `hudLinger`** |
| Lyric line advances | spring 0.42 / 0.86 (the one overshoot: the song carries momentum) | crossfade 0.24 | `lyricScroll` |
| Lyric band turns | old line out 0.18, new line in 0.29 | crossfade 0.24 | `captionTurnOut`, `captionTurnIn` |
| Lock banner ↔ card | spring **0.36 / 1.0**, grows in place (same centre, same top) | crossfade 0.24 | **NEW `lockCardMorph`** |
| Hover over the resting notch | spring 0.34 / 0.72; 8 pt each side, 3 pt down | easeInOut 0.24 | `hoverNudge` |
| Refusal shake (locked) | three swings in 0.5 s, decaying from 11 pt | content dims to 0.45 and back in 0.36 s | `RefusalShake` |
| Copied, Already on the Shelf | easeOut 0.16; holds 1.2 s | same, no scale | `contentAnimation` |
| Menus, sheets, tooltips | system | system | — |

## 3. The compact island

### 3.1 Geometry (decision 2)

- Width **300** while music plays: the notch (220 on a 14-inch MacBook Pro)
  plus **40** on each side. `NotchMetrics.compactMediaExtension` becomes
  **80** (it is 104 today, 52 per wing). On a notch of another width the wings
  stay 40; the island is `notch.width + 80`.
- Height is the notch height. Bottom corners 12; the shoulders where the
  island meets the menu bar are the existing concave 12 pt fillets.
- Left wing: the cover, 24 × 24, radius 6, **8** from the island's left edge
  and **7** from its bottom.
- Right wing: the equalizer, four bars 2.5 wide with 2 between them (16.5 in
  all), its last bar ending **8** from the island's right edge, vertically
  centred on the cover.

### 3.2 States

| State | Board | Left wing | Right wing |
|---|---|---|---|
| Playing | `Island-Playing` | cover | equalizer in the cover's tint, bars moving |
| Paused | `Island-Paused` | cover at brightness 0.55 with a 9 pt `play.fill` centred on it | four bars at rest, 3 tall, tertiary |
| No artwork | `Island-NoArtwork` | a 24 × 24 well, white 0.14, radius 6, `music.note` 11 pt secondary centred | as playing |
| Pointer over it | `Island-Hover` | — the surface turns `#1C1C1E`; nothing moves or grows | — |

The paused badge already exists (`showsArtworkPlayBadge`); this changes its
size and the cover's dim (0.58 opacity today → brightness 0.55, so the cover
darkens rather than turning see-through on a bright wallpaper).

### 3.3 Key line

A black island disappears on a black wallpaper (the owner's Aerial measures a
mean of 8/255 behind the notch). Apple's answer for the Dynamic Island is a
*key line*: a thin stroke tinted to the content.

- A **1 pt** stroke just outside the black, along the two shoulders, both
  sides and the bottom — never along the top edge, which is the bezel.
- Colour `keyLineMusic` (the cover's tint at 0.50) while the island or panel
  shows music; `keyLineNeutral` (white 0.26) for every other tab and moment.
- It shows **only on a dark wallpaper**, decided by `WallpaperTone` (below),
  and on **every** wallpaper while Increase Contrast is on.
- The open panel draws the same line, following the body's height as it
  springs.

`WallpaperTone` (new, `Services/WallpaperTone.swift`): reads
`NSWorkspace.shared.desktopImageURL(for:)` for the island's screen, makes a
thumbnail no larger than 256 px with `CGImageSourceCreateThumbnailAtIndex`,
and averages relative luminance over the region behind the island (the
notch's centre ± 310 pt, the top 60 pt, mapped through aspect-fill). The
result is cached by URL and file modification date. It is recomputed on
`NSWorkspace.activeSpaceDidChangeNotification`, on
`NSApplication.didChangeScreenParametersNotification`, on wake, and when the
island unfolds (a cache hit costs nothing). A wallpaper is **dark** below a
mean luminance of **0.20** (Aerial 0.03, Pro Black 0.09, Sonoma 0.36, Sky Blue
0.41). Anything that fails — no URL, a folder, an unreadable file — answers
"not dark", so the key line is absent rather than wrong. No permission is
involved: the wallpaper file is readable, the screen is never captured. The
1.0 pt width and 0.50 / 0.26 strengths are to be confirmed on notch hardware
(owed check R1-H2).

> **Amended 2026-10-15 (R1 review).** "No permission is involved" was wrong
> for a wallpaper kept in a protected place: opening a picture in
> `~/Downloads`, `~/Desktop`, `~/Documents`, iCloud Drive, a cloud-storage
> mount, another app's container or the Photos library makes macOS ask for
> access, with nothing on screen to explain why. `WallpaperTone` therefore
> decides on the URL's text, before any file call, whether it may read it:
> `/System/Library`, `/Library` and the home folder outside those places are
> read; everything else, `/Volumes` included, answers "not dark" unopened.

### 3.4 The cover's tint

The equalizer and `keyLineMusic` take one colour from the cover: the most
saturated of the cover's bright colours, lifted to at least 0.65 HSB
brightness so it reads on black, falling back to white 0.82 when the cover is
greyscale or missing. Computed once per artwork, off the main actor, on a
24 × 24 downsample. If the lock card already derives a cover colour, this
reuses that code; there is one tint per track.

### 3.5 New-track peek (decision 3)

`Island-Peek`, `Island-Peek-Long`.

- **520** wide (notch + `sneakPeekExtension` 300, as today) and **50** tall,
  radius **16**.
- Cover 34 × 34, radius 8, inset 8 from the left and 8 from the top.
- Title at (52, 9), 13 / semibold, white; artist at (52, 26), 11.5 / regular,
  secondary. Both truncate at the tail before the equalizer, which sits 8
  from the right edge, centred at y 25.
- Holds `sneakPeekDuration` (2.2 s), then folds back to 300 × notch height on
  `pillFold`.
- The extra 12 pt of height is below the menu bar; the active rect grows with
  it for the hold and shrinks after.

### 3.6 Charging and headphones

| Moment | Board | Width | Left wing | Right wing |
|---|---|---|---|---|
| Charging | `Island-Charging` | 300 | `bolt.fill` 13 pt, green, centred where the cover sits | the level, "82%", 12 / semibold, green, tabular digits, right-aligned 8 from the edge |
| Power adapter, no battery | `Island-Charger-NoLevel` | 300 | `bolt.fill` 13 pt, white | nothing |
| Headphones connected | `Island-Headphones` | 220 + 2 × **104** = 428 | the device's symbol (`airpods.pro`, `headphones`, …) 13 pt white | the device name, 12 / semibold, right-aligned, truncating at its tail |

Both hold `ambientDuration` (2.2 s) and use `keyLineNeutral`.
`ambientNameExtension` becomes **208** (two 104 pt wings, shared with the
volume pop-up in R5). The existing settings that switch each moment off stay.

### 3.7 Over the lock screen (decision 1)

While the lock banner or the lock card is on screen, the island shows **no
wings**: it rests in the notch exactly as when nothing plays. Hover still
nudges it and a click still refuses with `RefusalShake` and "Unlock your Mac
to open Isla." (existing string). With Show on Lock Screen off, the island
behaves as today.

### 3.8 A display without a notch

`Stress-No-Notch`, `Stress-No-Notch-Open`. The synthetic island is **200 × 24**
at rest (the menu bar's height; today it is 180 wide), centred, and grows and
opens exactly like the physical one. The open panel hangs from the menu bar's
bottom edge.

## 4. The Music player (208 tall)

`Music-Playing`, `Music-Paused`, `Music-NoLyrics`, `Music-Output`,
`Music-Shuffle-Repeat`, `Music-Long-Title`, `Music-NoArtwork`,
`Music-Live-Stream`.

### 4.1 Layout at 560

| Element | Frame (body coords) | Notes |
|---|---|---|
| Header title "Music" | (17, 11) | 12 / semibold, secondary |
| Source tag | trailing: equalizer 4 bars ending at `bw − 43`, then the player's app icon 18 × 18 at (`bw − 35`, 10) | the app's real icon (Music, Spotify, …) instead of a second "Music"; bars at rest when paused |
| Rail | (14, 37 + 28·i), 30 × 26 per item | Music, Shelf, Clipboard, Translate; Settings at the foot, (14, h − 39) |
| Cover | (58, 54), 132 × 132, radius 14, hairline white 0.14 at 0.5 pt | brightness 0.8 while paused |
| Title | (206, 52), 16 / semibold | one line, tail truncation, max width `bw − 220`, the full title as its tooltip |
| Subtitle | (206, 73), 12.5 / regular, secondary | "Artist — Album" (the existing `subtitle(for:)` rule) |
| Lyric band, sung line | (206, 99), 13 / bold, swept | see 4.3 |
| Lyric band, next line | (206, 117), 13 / semibold, white 0.36 | |
| Progress | (206, 141), width `bw − 220`, 12 tall: elapsed 26 wide, a 4 pt track, remaining 30 wide right-aligned | 10 / medium, tabular, secondary |
| Shuffle | (206, 160), 24 × 24 | see 4.4 |
| Transport | (236, 158), 100 × 28: previous 16 pt, play/pause 20 pt, next 16 pt | |
| Repeat | (342, 160), 24 × 24 | |
| Volume | (384, 166), width `96 + (bw − 560)`, 12 tall: `speaker.fill` 10 pt secondary, a 4 pt track with a 12 pt knob | hidden below 540, see 4.5 |
| Output | (`bw − 68`, 159), 26 × 26, `airplay.audio` 14 pt | opens the Output menu |
| Lyrics | (`bw − 40`, 159), 26 × 26, `quote.bubble` 14 pt | opens the lyric column (§5); `quote.bubble.fill` on selectedFill when open |

With **no lyric** for the song (`Music-NoLyrics`) the band folds away and the
block below moves up by 20: title 70, subtitle 91, progress 121, transport
138, volume 146, buttons 139.

### 4.2 Paused

The cover at brightness 0.8; the sung line at α 0.7; the source tag's bars at
rest; the play glyph replaces pause. Nothing else moves.

### 4.3 Lyric band

The player shows **the sung line and the next one** (decision 6 applies:
same 13 pt, the sung line bold and swept, the next line semibold at 0.36). It
replaces today's single caption line under the subtitle. The band turns with
`captionTurnOut` / `captionTurnIn` and reads ahead exactly as the caption does
today (`LyricSweep.readingMoment`, `lyrics.readAhead`). The **Lyric Band**
setting (Settings › Music, **on**) hides it; the layout then takes the
no-lyric positions. With Show Lyrics off the band is never drawn.

### 4.4 Shuffle and Repeat

Kept, flanking the transport, shown only when the source reports them (as
today). Off: tertiary glyph 12 pt. On: white glyph with a 3 pt white dot 2 pt
below it. Repeat One adds a 7.5 pt heavy "1" at the glyph's top right. The
tooltip reads "Shuffle", "Repeat: Off", "Repeat: All Tracks", "Repeat: This
Track" (the value strings exist; the "Repeat: %@" format is new).

### 4.5 Volume and Output (decision 8)

- **Volume and Output** setting, Settings › Music, **on** by default — the
  owner-waived exception recorded in `checklist.md`. Off hides both controls
  and the band keeps its place.
- The slider drives the default output device's volume through the existing
  `SystemVolume`; it reads the device's volume live and moves only when the
  person drags it. Nothing is written until they do.
- The Output button opens an **NSMenu** anchored under the button: header
  "Output"; one row per device from the existing `AudioOutputs`, each with
  its symbol inside a 26 pt circle (the accent fill on the current device,
  white 0.16 on the rest), the name, and a checkmark on the current one; a
  separator; "Sound Settings…", which opens System Settings › Sound.
- **Below a body width of 540** (`Stress-Music-480`) the slider is not drawn
  in the player — it would be narrower than its knob — and the Output menu
  gains a "Volume" header and a slider row above "Output".
- At 620 (`Stress-Music-620`) the trailing controls ride the edge and the
  slider takes the extra 60.

### 4.6 Live stream

`Music-Live-Stream`. No duration: the progress row keeps its place and shows a
**LIVE** mark (9 / bold, tracking 0.4, white on accent, radius 3, 4 pt side
padding) followed by a full-width static track at white 0.16. No elapsed or
remaining time; dragging does nothing.

### 4.7 Cover missing

`Music-NoArtwork`. The 132 pt well at white 0.08 with `music.note` at 35 pt,
white 0.30, centred. Never a stretched app icon. The shimmer that waits for
artwork today keeps its timeout and then shows this.

### 4.8 Nothing playing, reader down, Music Only

`Music-NotPlaying`, `Music-Reader-Down`, `Music-MusicOnly`. The empty player
keeps the playing layout's frame: a 132 pt well (white 0.07, radius 14,
hairline 0.10) with `music.note` 40 pt at white 0.26 in place of the cover. No
transport.

| State | Title at (206, 80) 16 / semibold | Body at (206, 103) 12 / regular secondary, wraps at 330 | Buttons at (206, 132), 22 tall, 8 apart |
|---|---|---|---|
| Nothing playing | "Nothing is playing." | "Start a song in Music or Spotify, or open one here." | Open Apple Music · Open Spotify (installed players only) |
| Reader down | "Nothing is playing." (at 70) | "Only Music and Spotify can be seen right now." (at 93) | Open Apple Music · Open Spotify (at 120); below them, at 153, `info.circle` 11 pt and "Settings › Music says why, with Try Again." 11 / tertiary |
| Music Only | "Something is playing that Music Only keeps off the island." (15 / semibold at 72, wraps) | "Videos and films stay off the island." (at 115) | Open Settings (at 140), which opens Settings at Music |

The reader-down reason and Try Again live in Settings › Music (§10.4) and
nowhere else — one failure surface.

## 5. Lyrics

### 5.1 Three views of one model

The player, the lyric column and the tall page are **one view whose elements
travel** (`matchedGeometryEffect` in the existing `morph` namespace), not
three panes swapped by a transition. Today's `LyricsStage` page is replaced by
the column and the tall page; its behaviours (Sync, read-ahead, line menu,
mismatch notice, editor) move with it.

| | Player `P` | Column `C` | Tall `T` |
|---|---|---|---|
| Body height | 208 | 208 | 400 |
| Cover | (58, 54) 132, r14 | (58, 50) 52, r9 | (58, 46) 34, r7 |
| Title | (206, 52) 16 | (122, 53) 13 | (102, 46) 13 |
| Subtitle → artist only | (206, 73) 12.5 | (122, 71) 11 | (102, 63) 11 |
| Lyric lines | the band, 2 lines | x 268, 13 / semibold; sung line 13 / bold | x 58, 17 / bold |
| Progress | (206, 141) `bw − 220` | (58, 116) 190 | (158, 358) 218 |
| Transport | (236, 158) 100 | (84, 136) 138 | (60, 350) 92 |
| Shuffle, Repeat | flanking | hidden | hidden |
| Volume | (384, 166) | (58, 176) 128 | (388, 358) 78 |
| Output | (`bw − 68`, 159) | (197, 169) | (`bw − 75`, 351) |
| Lyrics button | (`bw − 40`, 159) off | (225, 169) on | (`bw − 45`, 351) on |
| Header right | source tag | Show Translation, More (`bw − 91`, 8); Expand (`bw − 39`, 8) | the same; Collapse in place of Expand |

- **P ↔ C** on the Lyrics button, `openAnimation`. The column replaces the
  band: lines centred on the sung line at y 96, line pitch 23, opacities
  0.22, 0.36, **1.0**, 0.5, 0.32, 0.18 above and below.
- **C ↔ T** on Expand / Collapse, `expandAnimation` (§6). In the tall page the
  sung line sits at y 166, pitch 34 (17 pt lines), opacities 0.16, 0.30,
  **1.0**, 0.50, 0.32, 0.20, 0.12.
- With a translation (`Ct`, `Tt`) each line carries its translation under it
  (§5.3) and the pitch grows: column 23 → 46 for a translated pair, tall
  34 → 52.
- ⌃⌥⌘L opens the panel on the column (today it opens the stage page).
- A new track returns to the player only if the column is open with no
  lyrics for the new song; otherwise the column stays (it is where the person
  chose to be). The tall state persists per session (§6).

### 5.2 Header tools in the column and tall page

- **Show Translation** (`character.bubble`, 22 × 22): toggles the
  translation; `character.bubble.fill` on selectedFill when shown. Hidden
  while Translate Lyrics is off in Settings.
- **More** (`ellipsis`, 22 × 22, "More Lyrics Options"): one NSMenu
  (`Lyrics-More-Menu`, `Lyrics-More-Menu-Local`):

  ```
  Lyric Timing                       (header)
  − Lyrics Earlier
  + Lyrics Later
  +0.2 s                             (disabled: the current offset)
  Reset Lyric Timing
  ─────
  Up Here.lrc                        (header, only with a local file bound)
  ✎ Edit Lyrics…
  ⊖ Remove Local Binding
  ─────
  Import LRC File…
  ↻ Search Again
  ─────
  Lyrics Settings…
  ```

  "Search Again" only when Look Up Lyrics Online is on. "Lyrics Settings…"
  opens Settings at Lyrics.
- **Translation menu** (`Lyrics-Translate-Menu`): a right-click (or a long
  press) on Show Translation opens: "Show Translation" (checked when on),
  separator, header "Translate To", the five most recent target languages
  plus the current one with a check, separator, "Translated on this Mac"
  (disabled) — or "Translated online by MyMemory" when that is where it went.

### 5.3 Lyric translation (decision 11)

- **Translate Lyrics**, Settings › Lyrics, **off** by default, with
  **Translate To** (pop-up of the Translate tab's languages, default the
  system language when it differs from the lyric's, else English).
- When on, the whole timeline is translated once per track through the
  existing `Translator` (Apple's on-device Translation first; MyMemory only if
  Translate Online is on and the language needs it — the Translate tab's
  rules, unchanged). Lines are sent in one batch; the result is cached in
  memory for the session, keyed by the timeline's identity and the target.
- A line whose language is already the target gets no translation row.
- Until the batch arrives the lines show without translations; they appear
  together with a 0.16 crossfade, never one by one.
- The lock card (§7) shows the sung line's translation when this is on.
- Bilingual LRC files (two lines at one time stamp, merged today with a
  newline) keep working and are drawn the same way, their second line as the
  translation.

> **Amended 2026-10-15 (R1 review).** Translation is made **on demand**, not
> per track: a batch starts only while a surface shows translations (the lyric
> column or tall page with Show Translation on; R2 adds the lock card). Each
> distinct line is sent once and its answer reused for every repeat. A batch
> the online engine cut short is shown but not cached, so the missing lines
> are asked for again later. When MyMemory answers that the day's allowance is
> spent, lyric batches stop until the next UTC midnight (`OnlineAllowance`).
> Turning Translate Online off ends an online batch before its next line.
> Below macOS 26 neither on-device engine exists, so every pair would go
> online; these rules are what keep that inside MyMemory's free allowance.
> The Settings footnote states where translation happens in the current state
> (the Translate tab's own wording), not a fixed "on this Mac". Two keys the
> table below lacked: `lyrics.showTranslation` (absent means on; the header
> button's state) and `lyrics.translateRecents` (the menu's recent targets,
> on this Mac only).

### 5.4 States inside the column and tall page

| State | Board | What shows |
|---|---|---|
| Looking | `Lyrics-Finding` | a 16 pt spinner and "Looking for lyrics…" (12 / medium, secondary) centred in the lyric area |
| None found | `Lyrics-NotFound` | `quote.bubble` 22 pt tertiary, "No lyrics found for this song." (existing), buttons Import LRC… · Search Online (Search Online only when Look Up Lyrics Online is off; it turns it on) |
| Instrumental gap | `Lyrics-Instrumental` | three 7 pt dots at α 0.9, 0.55, 0.3 where the sung line goes |
| Read ahead | `Lyrics-Sync` | the page stays where the person scrolled; a 74 × 24 capsule "♪ Sync" (solid `#3A3A3C` α 0.96, hairline, shadow) centred near the bottom brings the sung line back (existing behaviour, new look) |
| Line menu | `Lyrics-Line-Menu` | Copy Line ⌘C · Copy All Lyrics · separator · Sync Here (existing) |
| Version mismatch | `Lyrics-Version-Mismatch` | one notice above the lines, 488 wide × 40, radius 9, fill 0.07, hairline 0.10, `clock.arrow.circlepath` 12 pt, existing text (11 pt, wraps) |
| Unreadable local file | `Lyrics-Invalid-File` | `exclamationmark.bubble` 22 pt, "Line %d of this file has a time Isla can’t read." (new, from the parser's line number; falls back to the existing "Can't read the lyrics file for this song."), buttons Edit Lyrics… · Import LRC… |

### 5.5 Edit Lyrics sheet

`Lyrics-Editor`. The existing `LocalLyricsEditorView`, laid out as a Mac form
sheet, 420 × 352, radius 14, background `#2A2A2C`: title "Edit Lyrics for %@"
(existing); a "Lyrics Metadata" group of four labelled fields in two columns
(Title, Artist, Album, Duration); a "Local Lyrics" list of rows — a 74 pt
monospaced time field, a 236 pt text field, 22 pt round Insert Line After (+)
and Remove Lyric Line (−) buttons; "Add Lyric Line"; a hairline; Export LRC…
at the leading edge; Cancel and **Save Copy** (accent, default button) at the
trailing edge. Behaviour and strings are today's; only the layout changes.

## 6. Shell: Expand and the tall body (decision 7, 12)

- The window is already cut for a 620 × 400 body (`NotchMetrics.tallestBody`,
  `maximumWindow` 700 × 444) and is not resized. The body height is now a
  per-tab value: **208** standard, **400** expanded.
- `NotchViewModel` gains `expandedTabs: Set<Tab>` (in memory for the session;
  a relaunch starts collapsed). `openBodySize` returns
  `(bodyWidth, expandedTabs.contains(tab) ? 400 : 208)`; Settings always
  returns 400 (§10). `activeRect`, `hoverRect` and the close hit area follow
  that size.
- The **Expand / Collapse** button: 22 × 22 at (`bw − 39`, 8) in the header,
  `rectangle.expand.vertical` / `rectangle.compress.vertical` 12 pt,
  secondary, tooltip and accessibility label "Expand" / "Collapse". It
  appears on the lyric column, Shelf, Clipboard and Translate. The player
  (P) does not expand; it reaches the tall page through the column.
- The body animates its height on `expandAnimation` (0.40 / 1.0); the bottom
  radius goes 22 → 26 with it; content elements travel (they are matched or
  positioned against the body). Reduce Motion: the height changes without
  travel and the content crossfades 0.24.
- The rail's four top items do not move when the body grows; the Settings
  item rides the foot at `h − 39`.
- Escape and a pointer leaving close the panel as today; they do not
  collapse it. A tab change keeps each tab's own expansion.
- No bottom-edge drag, no grabber (decision 7).

## 7. Lock screen (R2)

### 7.1 The banner (new) and the card, one object

`Lock-Banner*`, `Lock-Card*`, `Lock-Frames`, `Lock-Live`.

- **Rest as Banner**, Settings › Lock Screen, **on** by default. When on,
  the song rests on the lock screen as a slim banner under the clock; a click
  on the banner grows it into the card **in place** (same centre x, same top
  edge) on `lockCardMorph` (0.36 / 1.0); the card's chevron (top right)
  shrinks it back. When off, the card shows directly, as today.
- The banner and the card are drawn by one view with two states, so the
  cover, title and artist travel rather than crossfade.

| | Banner `B` | Card `K` (standard) |
|---|---|---|
| Size / radius | 360 × 64 / 22 | 460 × 300 / 30 |
| Cover | (12, 12) 40, r10 | (20, 20) 64, r10 |
| Title | (64, 14) 13 / semibold | (98, 28) 16 / semibold, −0.2 |
| Artist | (64, 32) 11.5 / regular, secondary | (98, 50) 13 / regular, secondary |
| Control | play/pause inside a 34 pt **progress ring** at (314, 15): track white 0.18, progress white, 2 pt, round cap, from 12 o'clock | heart (384, 18) 28 pt when Spotify is connected; Collapse chevron (420, 20) 24 pt on white 0.12 |
| Lyric | — | sung line (20, 104) 15 / bold, swept; its translation (20, 125) 11.5 / medium α 0.62 when §5.3 is on |
| Progress | — | (20, 158) 420 wide |
| Transport | — | (150, 190) 160 × 36: 20 / 26 / 20 pt glyphs |
| Footer | — | (20, 252): Lyrics button 28, volume slider (40…380) with `speaker.fill` and `speaker.wave.3.fill`, Output button at 392 |

Title and artist truncate at the tail before the control at their right
(banner 240 wide, card 276 wide with the heart, 300 without).

**Card Size: Compact** (`Lock-Card-Compact`): 420 × **236**, radius 28 — the
standard card without its lyric: cover (20, 20) 64; progress (20, 110) 380;
transport (130, 132); footer at 188. (Compact is 420 × 244 today.)

**Liked Songs** (`Lock-Card-Liked`): the heart on the title row — `heart`
secondary when not liked, `heart.fill` white when liked, a 14 pt spinner while
Spotify is asked. Existing behaviour and strings.

### 7.2 Material

Nothing above the login shield can sample the wallpaper, so the card draws
its own material.

| Style | Material | Setting label |
|---|---|---|
| **Automatic** (new, default) | the cover's light (today's Tinted recipe) at an opacity chosen from the wallpaper: `α = clamp(0.84 + 0.06·max(0, (0.30 − L)/0.27) + 0.12·max(0, (L − 0.36)/0.30), 0.84, 0.92)`, where L is `WallpaperTone`'s mean luminance behind the card (Aerial 0.90, Pro Black 0.88, Sonoma 0.84, Sky Blue 0.86) | Automatic |
| Transparent | black α 0.30, hairline | Transparent (existing) |
| Tinted | the cover's light at 0.88 | Tinted (existing) |
| Solid | `#1C1C1E`, hairline | Solid (existing) |

The floor (decision 5) is what keeps the lyric legible over Aerial's bright
lines. With Reduce Transparency every style draws as Solid. Existing users who
chose a style keep it; only the default (no stored value) becomes Automatic.

> **Amended 2026-10-15 (R2 review).** Transparent's black 0.30 is a floor,
> not a fixed value: the card's existing contrast solver raises it to the
> least black at which the dimmest type clears 4.5:1 over the wallpaper's
> luminance behind the card, and an unmeasured wallpaper counts as white.
> Automatic and Tinted with no cover lay the Solid colour at the chosen
> alpha, so a podcast or a browser tab keeps decision 5's floor. Under
> Increase Contrast Transparent draws as Solid, as before. Picking a device on
> the Output pane stays on that pane, as the system's Sound module does.

### 7.3 Panes inside the card

- **Lyrics** (`Lock-Card-Lyrics`): header (cover 34, title, artist, a Back
  chevron "Back to Player"); four lines at 15 / bold with their translations;
  footer: Hide Lyrics (selected), progress 300, small transport.
- **Output** (`Lock-Card-Output`): the macOS Sound module, not a sheet with a
  now-playing header: "Sound" 15 / semibold and a Back chevron; a volume
  slider 380 wide (8 pt track, knob); header "Output"; devices as 26 pt
  circles (accent on the current one) with names at 13, 36 pt apart. Picking
  one fires the existing `.levelChange` haptic on the drawn frame.

### 7.4 Locked island

As §3.7: no wings while the banner or card shows. `Lock-Refusal`: a hover
nudges the resting notch (+8 / +3, surface `#1C1C1E`); a click shakes it
(left −9, right +6, …) and VoiceOver hears "Unlock your Mac to open Isla."

## 8. Shelf (R3)

`Shelf-Icons`, `Shelf-Hover`, `Shelf-One-Selected`, `Shelf-Two-Selected`,
`Shelf-Context-Menu`, `Shelf-Drag-Keep`, `Shelf-Drag-AirDrop`, `Shelf-Empty`,
`Shelf-Confirm-Clear`, `Shelf-Disk-Missing`, `Shelf-Full`, `Shelf-Already`,
`Shelf-Tall`.

### 8.1 Finder's icon view

- Replaces the horizontal strip of card plates. A grid of tiles **78 × 100**,
  **4** apart horizontally and 8 vertically, starting at (58, 44); six fill a
  560 body (`(bw − 72) / 82` columns, at least five at 480).
- A tile: the icon or thumbnail 52 × 52 at (13, 5) — a real Quick Look
  thumbnail for images (white 1.5 pt border, soft shadow, as Finder draws
  them), the file's real icon otherwise; the name below at (−6, 65), 11 pt,
  centred, two lines, **truncated in the middle** so the extension survives;
  the age under it, 10 pt tertiary ("Just now", "5 min ago", "Yesterday",
  "Monday", "12 Oct" — the existing relative formatter).
- Newest first, scrolling vertically at 208 (two rows show, the third fades
  under a 26 pt mask); Expand shows everything (`Shelf-Tall`, up to five rows
  at 400, then it scrolls).
- Header trailing: the count, "%d items" (11 / medium, secondary), then
  Expand.

### 8.2 Selection, actions, removal (decision 9)

- Click selects; ⌘-click toggles; ⇧-click selects a range (as today). The
  selected tile shows a 60 × 60 well (white 0.14, radius 8) behind its icon,
  and its name is highlighted line by line in the accent colour (radius 4),
  the way Finder highlights a selected name.
- Hover: a 60 × 60 well at white 0.07 and the **ⓧ remove badge**, 18 pt,
  `xmark` 8 pt semibold on `#505054` α 0.96, at the tile's top left (4, −3).
- With a selection, the bar at the bottom (y 171) reads: "%d selected"
  (11.5 / medium, secondary) and a 16 pt round Deselect All ⓧ on the left;
  on the right, push buttons 22 tall, 6 apart: **Quick Look · AirDrop · Copy ·
  Show in Finder · Remove**. Remove is a normal button, not red.
- Without a selection the bar reads "Drag an item out to use it anywhere."
  (11.5 / tertiary) and a Clear button.
- **Delete** (and ⌘⌫) removes the selection while the panel is key or the
  pointer is on the Shelf. Removal never touches the file.
- Right-click: Quick Look ⌘Y (or Space) · Open · Open With ▸ · separator ·
  AirDrop · Copy ⌘C · Show in Finder ⌘R · separator · Remove from Shelf ⌫. A
  menu is as wide as its longest item.
- Below 540 (`Stress-Shelf-RU-480`) the bar keeps Quick Look and Remove and
  moves the rest into a "…" More menu (`ellipsis`, 22 × 22).

### 8.3 Dragging in

`Shelf-Drag-Keep`, `Shelf-Drag-AirDrop`. While files are dragged over the
panel, two drop targets name their action: **Keep on Shelf**
(`tray.and.arrow.down`) and **AirDrop** ("Send to a nearby device"). The one
under the pointer lights (accent ring 2 pt, fill accent α 0.18) and its
caption becomes "Release to add to the Shelf" / "Release to send with
AirDrop". AirDrop sends without keeping (the existing `ShelfSharing`).

### 8.4 Other states

| State | Board | What shows |
|---|---|---|
| Empty | `Shelf-Empty` | `tray` 26 pt tertiary, "Drop files here to keep them" (existing), "From Finder, Mail, Photos or a browser. Holds %d." (existing) |
| Clear | `Shelf-Confirm-Clear` | asked once, in place, at the bar: "Remove all %d items? Files are untouched." with Cancel and Remove All |
| Disk missing | `Shelf-Disk-Missing` | the tile at α 0.4 greyscale, "Disk not connected" in place of the age (existing) |
| Full | `Shelf-Full` | at 60 the oldest leaves; the bar says "The Shelf holds %d, so the oldest card left it. Its file is untouched." (existing) for 4 s |
| Already kept | `Shelf-Already` | no duplicate; the existing tile shows its selection well for 1.2 s and the bar says "Already on the Shelf" (existing) |

## 9. Clipboard (R3)

`Clip-All`, `Clip-All-Tall`, `Clip-Text`, `Clip-Links`, `Clip-Images`,
`Clip-Files`, `Clip-Hover`, `Clip-Copied`, `Clip-Context`, `Clip-Search`,
`Clip-No-Results`, `Clip-Covered`, `Clip-Empty`, `Clip-History-Off`,
`Clip-Clear-Everything`, `Clip-Denied`.

### 9.1 Kinds

| Kind | Detected from | Leading mark (at x 66–86) | Content (x 94) | Filter |
|---|---|---|---|---|
| Text | plain or rich text | `text.alignleft` 12 secondary | the text, one line, 12.5 | Text |
| Colour | text that is one CSS/hex/rgb/hsl colour and nothing else | a 14 pt swatch, radius 4, hairline | the value, monospaced 12 | Text |
| Code | text with code shape (two or more of: `;` line ends, `{`/`}`, `=>`/`->`, leading indentation, a keyword like `func`/`let`/`const`/`def`) and no sentence punctuation | `curlybraces` 12 | monospaced 12 | Text |
| Link | text that is one URL and nothing else | `link` 12 | host in white 500, path in secondary | Links |
| Image | an image on the pasteboard (new, needs Include Images) | the picture, 20 × 20, radius 4 | "Image" + "  W × H · Source app" in tertiary | Images |
| File / Files | file URLs | the real icon 20 pt; for several, three stacked icons | the name (or "%d files") + size or "A, B and %d more" in tertiary | Files |

Colour and code are subtypes of Text: detection is a pure function with
tests; when unsure, a row is plain Text.

### 9.2 List

- Rows 28 tall, 2 apart, from (58, 44), 488 wide at 560 (`bw − 72`).
- **Pinned rows sort first**, above a hairline (472 wide, inset 8), and show a
  `pin.fill` 10 pt tertiary where the age goes.
- Trailing: the age, 11 / tertiary, right-aligned ("Now", "4 min", "1 hr",
  "Yesterday", "Monday" — the relative formatter, short style).
- Hover (`Clip-Hover`): a well (white 0.08, radius 7) and two 22 pt buttons
  replace the age: **Pin** / **Unpin** (`pin` / `pin.fill`) and **Remove
  Entry** (`xmark`).
- A click copies (as today); the row confirms in place: the well,
  `checkmark.circle.fill` 12 pt green and "Copied" for 1.2 s (`Clip-Copied`).
- Right-click (`Clip-Context`): Copy ⌘C · Paste as Plain Text ⌥⇧⌘V (text kinds
  only) · separator · Pin / Unpin · Translate (text kinds: opens Translate
  with the text) · separator · Remove Entry · Clear Everything… (red, the
  NSMenu destructive style).
- Images filter (`Clip-Images`): a grid of 88 × 66 thumbnails, radius 8, 12
  apart, the age centred below; a footnote "Images are kept in memory, like
  the rest of the history."
- The list scrolls with a 26 pt fade at its foot; Expand (`Clip-All-Tall`)
  shows 400 tall.

### 9.3 Header

Trailing, at 560: a **segmented** filter "Kind" — All · Text · Links · Images
· Files — 270 × 20 at (212, 9); **Search** (`magnifyingglass`) 22 pt at
(`bw − 67`, 8); **Expand** at (`bw − 39`, 8).
Below 540 (`Stress-Clip-RU-480`) the segments become symbols
(`square.grid.2x2`, `text.alignleft`, `link`, `photo`, `doc`) with the names
as tooltips, 150 wide, and ages use the narrow style.

**Search** (`Clip-Search`, `Clip-No-Results`): the field replaces the filter
while it is open — 294 × 22 at (250, 8), radius 7, fill 0.10, a magnifier, the
caret in accent, a Clear Search ⓧ. Matches are highlighted in
`findHighlight`. Escape or the ⓧ closes it. No match: `magnifyingglass` 26 pt,
"No Results for “%@”", "Check the spelling or try a new search." Typing needs
keyboard focus: the panel becomes key while the search field is focused, the
way it does for Translate, and gives it back when the field closes.

### 9.4 Persistence and privacy (decision 10)

- History stays **in memory** and empties at quit (today's behaviour; the
  footnote now says so).
- **Keep Pinned Items** (Settings › Privacy, **off**): when on, pinned
  entries — text kinds and file URLs, never images — are saved to
  `~/Library/Application Support/Isla/pinned-clipboard.plist`, written
  atomically, readable only by the user (0600), and loaded at launch. Turning
  it off deletes the file. Pins never leave the Mac.
- **Include Images** (Settings › Privacy, **on**): images copied while
  history is on are kept in memory as entries. At most **12** images; a
  thirteenth drops the oldest image entry. Each keeps its original pasteboard
  data up to 25 MB (larger images are kept as a 2048 px PNG) and a 176 × 132
  thumbnail. Off: images are not kept (Save Clipboard Screenshots still
  works as today).
- The 40-entry cap stays; pins do not count against it.
- Covered (`Clip-Covered`): the kind's mark stays readable; the content is a
  row of moving dots at a width proportional to the kind (existing
  `PrivacyMode`).
- **Clear Everything…** (menu) asks once, in place, at the foot of the list
  (`Clip-Clear-Everything`): "Clear %d entries? Pinned items stay." with
  Cancel and **Clear History** (destructive style). Pins survive a clear; a
  pinned entry is removed only by Unpin then Remove, or Remove on the pinned
  row itself.
- Denied (`Clip-Denied`): the existing inline notice, restyled as an inline
  alert: 488 × 44, radius 9, warning fill α 0.12 and ring α 0.35,
  `hand.raised` in warning, the existing text, and Open Privacy Settings. The
  history below it stays.
- Empty, History off: `doc.on.clipboard` 26 pt; "Nothing copied yet" with
  "Text, links, images and files you copy appear here. Copies from password
  managers are skipped." (new wording of the existing line); history off:
  "Clipboard History", "Clipboard history is off in Settings." (existing) and
  a Turn On button.

## 10. Settings (R4): the tall body with a sidebar

`Settings-*`. Settings always opens 400 tall. A sidebar of ten sections
(122 wide at (58, 46), rows 26 apart, 18 pt rounded-square icons in the
section's colour, label 12.5, the selected row on white 0.12, radius 6; long
names truncate at the tail) and a grouped form at (192, 46), 354 wide at 560
(`bw − 206`). Groups: fill white 0.055, radius 9, rows 28 tall separated by
inset hairlines; group headers 12 / semibold at white 0.85, title case;
footnotes 10.5 tertiary, wrapping. Switches are the mini size; actions are
push buttons on trailing rows, never red text rows. The last section shown is
restored on the next open (HIG). Below 540 the form is 274 wide, labels wrap
before controls, and sliders shrink first (`Stress-Settings-RU-480`).

| Section | Icon (colour) | Rows (new in **bold**, default in brackets) |
|---|---|---|
| General | `gearshape` (`#8E8E93`) | Launch at Login · Open on Hover [off] · Panel Width (slider, "560 pt") · *The island shows:* Charging [on] · Headphones Connecting [on] · New Tracks [on] · **Volume and Brightness** [off] (R5; hidden until R5 ships) |
| Privacy | `hand.raised` (`#0A84FF`) | *Clipboard:* Clipboard History [on] · **Include Images** [on] · **Keep Pinned Items** [off] · *Cover:* Cover Clipboard Rows · Cover Translate Text · Hide from Screen Recording [on] |
| Shortcuts | `keyboard` (`#8E8E93`) | the three shortcut recorders (96 pt fields) · Restore Default Shortcuts |
| Music | `music.note` (`#FF375F`) | Music Only [on] · *In the player:* **Volume and Output** [on] · **Lyric Band** [on] · *Automation* (only when a player is not allowed) · *Now Playing* (only when the reader is down) |
| Lyrics | `quote.bubble.fill` (`#FF9F0A`) | Show Lyrics · Word Karaoke · Show next line early (Off · Auto · 0.3 s · 0.5 s) · Lyric Delay (slider, "+0.00 s" in 52 pt) · *Translation:* **Translate Lyrics** [off] · **Translate To** · *Online:* Look Up Lyrics Online [off] · *Local Lyrics Library:* push buttons |
| Lock Screen | `lock.display` (`#5E5CE6`) | Show on Lock Screen [on] · *Card Style:* four real previews (Automatic · Transparent · Tinted · Solid), the chosen one ringed in accent · **Rest as Banner** [on] · Card Size (Standard · Compact) |
| Translate | `translate` (`#0A84FF`) | Translate Online [off] · **Keep History** [off] · **Speak Button** [on] · Translation Languages… |
| Spotify | the Spotify icon | not connected: Connect Spotify Account… · Import Account from Keychain…; connected: "Connected" in green, Liked Songs · Disconnect Spotify Account (normal push button; its confirmation carries the destructive style) |
| Screenshots | `photo.on.rectangle` (`#8E8E93`) | Save Clipboard Screenshots [off] · Show Screen Captures [on] · Show Screenshots Folder · Clear Screenshots Folder |
| About | Isla's icon | name and version · "Isla %@ is the latest version." with Check for Updates · Check for Updates Automatically [off] · Copy Diagnostics · Report a Problem… · Acknowledgements… · "Nothing leaves your Mac unless you turn it on." and Quit Isla |

The Music section's failure groups (`Settings-Music-Reader`,
`Settings-Music-Automation`) carry the only Try Again and the only "Open
Automation Settings…" in the app (one failure surface). Settings' existing
footer (`Isla %@`, About, Quit) moves into the About section.

Rows that move but keep their meaning keep their `UserDefaults` key. The two
renamed labels ("Show Charging" → "Charging", "Show Headphones Connecting" →
"Headphones Connecting", "Peek at New Tracks" → "New Tracks", under the
header "The island shows") get new keys; the old keys stay in both tables
until nothing uses them, then go.

## 11. Translate (R4)

`Translate-*`.

- **Pair bar** at y 46: two pop-up buttons (NSPopUpButton style), 210 × 22,
  "Translate From" at x 58 and "Translate To" at x 336, with Swap Languages
  (`arrow.left.arrow.right`, 24 pt) centred between them at 290. A pop-up's
  menu opens with the chosen item over the button (`Translate-Language-Menu`):
  header "Recent" with the last three targets, separator, header "On this
  Mac" with installed languages, online-only ones suffixed " (Online)"
  (existing), separator, "Translation Languages…". "Detect Language" stays the
  source's first item; a detected source reads "English (Detected)".
- **Source card**: (58, 76), 240 × 116, radius 12, fill 0.07, hairline 0.08;
  text 15 / medium, wraps at 200; a Clear ⓧ at its top right; "%d / 5,000"
  (10 / quaternary) at its foot. Empty: the placeholder "Type or paste text"
  (existing) and a **Paste** push button (`doc.on.clipboard`), enabled when
  the pasteboard holds text.
- **Result**: plain text at (318, 85), 15 / semibold, wraps at 212. Its footer
  at the card's foot: **Speak** (`speaker.wave.2.fill`, 24 pt) and Copy
  Translation, then where it came from — `lock.fill` "On this Mac" or `globe`
  "Translated online by MyMemory" (existing), 10 / tertiary. Speak reads the
  translation with `AVSpeechSynthesizer` in the target language's system
  voice; while speaking the button is accent-filled ("Stop Speaking") and
  the spoken words sweep like a lyric (`Translate-Speaking`). Hidden when
  Speak Button is off.
- **Header trailing**: **History** (`clock.arrow.circlepath`, 22 pt; on =
  selectedFill) at (`bw − 67`, 8) and Expand at (`bw − 39`, 8).
- **History** (`Translate-History`, Keep History **off** by default; the
  button is hidden while it is off): the last **20** translations in memory,
  newest first — source (12.5 / medium), result (11.5 secondary), "EN → RU"
  (10.5 / semibold tertiary, tracking 0.4) and the age; a click restores the
  pair. Empties at quit; never written to disk.
- **States in the result card**: Translating (spinner and "Translating…"),
  Language not downloaded (`arrow.down.circle`, the existing sentence,
  Translation Languages… · Use Online), Online only and off (`globe`, the
  existing sentence, Turn On Translate Online), unreachable
  (`exclamationmark.bubble` in warning, the existing sentence, Try Again),
  Apple Intelligence off (`info.circle`, existing, Apple Intelligence
  Settings…), model downloading (spinner, existing). One alert at a time, in
  the result card, never a toast as well.
- **Covered** (`Translate-Covered`): both cards become moving dots.
- **Expanded** (`Translate-Tall`): both cards 308 tall, text 13.5.

## 12. Volume and brightness pop-up (R5, decision 13)

`Island-HUD-*`, `Settings-General-HUD`, `Motion-HUD`.

- **Volume and Brightness**, Settings › General › The island shows, **off**
  by default. Turning it on asks for Accessibility permission
  (`AXIsProcessTrustedWithOptions` with the prompt); until it is granted the
  row shows the group "Accessibility" with "Open Privacy & Security…" and the
  footnote "Isla can’t see the volume keys yet. Until it can, the Mac shows
  its own pop-up." Nothing is intercepted until both are true.
- When on and trusted, a `CGEventTap` (session, head-insert, listen-and-modify)
  watches `NX_SYSDEFINED` media-key events for volume up/down/mute and
  brightness up/down and keyboard illumination up/down. Isla consumes the
  event, applies the change itself, and shows the pop-up; the system's own
  pop-up therefore never appears.
  - Volume: the existing `SystemVolume` (CoreAudio). Steps of 1/16; ⌥⇧ gives
    quarter steps, as macOS does. Mute toggles the device's mute.
  - Display brightness: `DisplayServicesGetBrightness/SetBrightness`
    resolved with `dlsym` from the private DisplayServices framework, for the
    built-in display. If the symbol is missing, brightness keys are **not**
    consumed (the Mac shows its own pop-up) — the lock screen's rule: a
    missing SPI degrades, never breaks.
  - Keyboard brightness: CoreBrightness's `KeyboardBrightnessClient`, also
    through `dlsym`/`NSClassFromString`; same degradation.
  - The tap is re-enabled on `kCGEventTapDisabledByTimeout`; if it cannot be
    created, nothing is consumed.
- The pop-up (`Island-HUD-Volume`): same height as the closed island; wings
  widen to **104** each (428 wide) on `hudAnimation`; the symbol
  (`speaker.wave.2.fill`, the output device's own symbol for AirPods,
  `speaker.slash.fill` when muted, `sun.max.fill`, `light.max`) in the left
  wing, 13 pt; the level as a bar in the right wing — track 80 × 6 at
  (220 + 104 + 12, 16), radius 3, white 0.18; fill white (white 0.32 when
  muted, keeping the level it will return to); no number. The bar moves on
  `hudLevel` (easeOut 0.12) with each press; the pop-up folds 1.5 s after the
  last press on `pillFold`. Key line `keyLineNeutral` on dark wallpapers.
- It takes priority over the peek and the ambient moments while shown, then
  hands back whatever was showing. Over the lock screen it is not shown (the
  tap passes events through while the screen is locked).
- No new entitlement. Accessibility is a TCC permission the person grants;
  the hardened runtime needs nothing for a session event tap.

## 13. Stress rules

| Rule | Board |
|---|---|
| Below 540 the player's volume folds into the Output menu; a long title truncates with its tooltip | `Stress-Music-480` |
| At 620 the trailing controls ride the edge and the slider takes the extra width | `Stress-Music-620` |
| Below 540 the Shelf bar keeps Quick Look and Remove, the rest go into More | `Stress-Shelf-RU-480` |
| Below 540 the Clipboard filter becomes symbols with tooltips; ages shorten | `Stress-Clip-RU-480` |
| Below 540 the Settings sidebar truncates, labels wrap before controls, sliders shrink first | `Stress-Settings-RU-480` |
| Menus follow the system appearance (NSMenu does this by itself); the island stays black | `Stress-Light-Menus` |
| Reduce Motion: nothing travels; 0.24 s crossfades | `Stress-Reduce-Motion` |
| Reduce Transparency: menus and the lock card opaque; the island unchanged | `Stress-Reduce-Transparency` |
| Increase Contrast: the key line on every wallpaper; text and hairlines step up through `Theme`'s existing contrast functions (secondary 0.75, tertiary 0.65) | `Stress-Increase-Contrast` |
| Without a notch: a 200 × 24 island at the menu bar's height; the panel hangs from the menu bar | `Stress-No-Notch`, `Stress-No-Notch-Open` |

Every layout in this spec must hold at 480 and 620 and in Russian; tests
render each new view at both widths with the Russian table loaded and assert
no truncation of controls (text truncation is allowed where this spec says
so).

## 14. Settings keys and defaults

| Key | Default | Section | Release | Leaves the Mac / system-wide? |
|---|---|---|---|---|
| `player.volumeAndOutput` | **true** | Music | R1 | changes system volume and output **when used** — owner-waived exception (decision 8) |
| `player.lyricBand` | true | Music | R1 | no |
| `lyrics.translate` | false | Lyrics | R1 | through Translate Online only if that is on (existing consent) |
| `lyrics.translateTarget` | system language, else `en` | Lyrics | R1 | no |
| `lockCardStyle` | `automatic` when unset | Lock Screen | R2 | no |
| `lock.restAsBanner` | true | Lock Screen | R2 | no |
| `clipboard.includeImages` | true | Privacy | R3 | no (memory only) |
| `clipboard.keepPinned` | false | Privacy | R3 | no (writes one file in Application Support) |
| `translate.keepHistory` | false | Translate | R4 | no (memory only) |
| `translate.speakButton` | true | Translate | R4 | no |
| `settings.lastSection` | General | — | R4 | no |
| `island.showHUD` | false | General | R5 | **yes**: replaces the system pop-up, sets volume and brightness, needs Accessibility |

> **Amended 2026-10-15 (R1).** Added `lyrics.showTranslation` (true when
> unset, Lyrics header, no) and `lyrics.translateRecents` (empty, Lyrics
> header, no). The default target with nothing stored is the system language,
> or English when the song is already in the system language.

## 15. New strings

Existing keys reused by this spec are not listed. Format specifiers keep their
order in Russian.

| English (key) | Russian |
|---|---|
| Expand | Развернуть |
| Collapse | Свернуть |
| Repeat: %@ | Повтор: %@ |
| LIVE | ЭФИР |
| Sound Settings… | Настройки звука… |
| Start a song in Music or Spotify, or open one here. | Включите песню в Музыке или Spotify либо откройте одно из приложений здесь. |
| Videos and films stay off the island. | Видео и фильмы на острове не показываются. |
| Settings › Music says why, with Try Again. | Причина — в Настройках › Музыка, там же кнопка «Повторить». |
| Hide Lyrics | Скрыть текст |
| Show Translation | Показать перевод |
| Hide Translation | Скрыть перевод |
| More Lyrics Options | Другие параметры текста |
| Lyric Timing | Синхронизация текста |
| Remove Local Binding | Отвязать локальный файл |
| Import LRC File… | Импортировать файл LRC… |
| Search Again | Искать снова |
| Search Online | Искать в интернете |
| Lyrics Settings… | Настройки текста… |
| Translate To | Переводить на |
| Translated on this Mac | Переведено на этом Mac |
| Looking for lyrics… | Ищем текст… |
| Line %d of this file has a time Isla can’t read. | В строке %d этого файла время, которое Isla не может прочитать. |
| Edit Lyrics… | Изменить текст… |
| Lyrics Metadata | Данные песни |
| Local Lyrics | Локальный текст |
| Insert Line After | Вставить строку ниже |
| Remove Lyric Line | Удалить строку |
| Add Lyric Line | Добавить строку |
| Export LRC… | Экспортировать LRC… |
| Save Copy | Сохранить копию |
| Back to Player | Назад к плееру |
| Sound | Звук |
| Automatic | Автоматически |
| Rest as Banner | Показывать полоской |
| The card waits as a slim banner under the clock; click it to open. | Карточка ждёт тонкой полоской под часами; нажмите, чтобы открыть. |
| Card Style | Стиль карточки |
| Automatic tints the card with the cover and reads the wallpaper behind it. With Reduce Transparency it is Solid. | «Автоматически» окрашивает карточку в цвет обложки и учитывает обои за ней. При уменьшении прозрачности она сплошная. |
| %d items | Объектов: %d |
| Deselect All | Снять выбор |
| Drag an item out to use it anywhere. | Перетащите объект, чтобы использовать его где угодно. |
| Keep on Shelf | Оставить на полке |
| Send to a nearby device | Отправить на устройство поблизости |
| Release to send with AirDrop | Отпустите, чтобы отправить через AirDrop |
| Remove all %d items? Files are untouched. | Убрать все объекты (%d)? Сами файлы не затрагиваются. |
| Remove All | Убрать все |
| Open With | Открыть в приложении |
| More | Ещё |
| Kind | Тип |
| All | Все |
| Text | Текст |
| Links | Ссылки |
| Images | Изображения |
| Files | Файлы |
| Image | Изображение |
| %d files | Файлов: %d |
| %@, %@ and %d more | %@, %@ и ещё %d |
| Pin | Закрепить |
| Unpin | Открепить |
| Paste as Plain Text | Вставить как простой текст |
| Clear Everything… | Очистить всё… |
| Clear %d entries? Pinned items stay. | Очистить записи (%d)? Закреплённые останутся. |
| Clear History | Очистить историю |
| Search | Поиск |
| Clear Search | Очистить поиск |
| No Results for “%@” | Нет результатов для «%@» |
| Check the spelling or try a new search. | Проверьте написание или попробуйте другой запрос. |
| Text, links, images and files you copy appear here. Copies from password managers are skipped. | Здесь появляются скопированные тексты, ссылки, изображения и файлы. Копии из менеджеров паролей пропускаются. |
| Images are kept in memory, like the rest of the history. | Изображения хранятся в памяти, как и вся история. |
| Turn On | Включить |
| Include Images | Сохранять изображения |
| Keep Pinned Items | Хранить закреплённые |
| History is kept in memory and empties when Isla quits. Keep Pinned Items saves only your pins, on this Mac. | История хранится в памяти и очищается при выходе из Isla. «Хранить закреплённые» сохраняет только закреплённое и только на этом Mac. |
| Cover | Скрытие |
| Paste | Вставить |
| Speak | Произнести |
| Stop Speaking | Остановить |
| History | История |
| Recent | Недавние |
| On this Mac | На этом Mac |
| Use Online | Перевести онлайн |
| Keep History | Хранить историю |
| Speak Button | Кнопка «Произнести» |
| History keeps your last 20 translations in memory. Speak reads a translation aloud with the system voice. | История хранит последние 20 переводов в памяти. «Произнести» читает перевод вслух системным голосом. |
| %@ → %@ | %@ → %@ |
| Settings sections | Разделы настроек |
| Shortcuts | Сочетания клавиш |
| About | О программе |
| The island shows | Остров показывает |
| Charging | Зарядку |
| Headphones Connecting | Подключение наушников |
| New Tracks | Новые треки |
| Click the notch to open the panel. Open on Hover also opens it when the pointer rests there. | Нажмите на вырез, чтобы открыть панель. «Открывать при наведении» открывает её, когда указатель задерживается на нём. |
| In the player | В плеере |
| Volume and Output | Громкость и выход |
| Lyric Band | Строка текста |
| Volume and Output put the system volume and the AirPlay menu in the player. Lyric Band is the sung line and the next one, under the title. | «Громкость и выход» добавляют в плеер системную громкость и меню AirPlay. «Строка текста» — исполняемая и следующая строки под названием. |
| Translate Lyrics | Переводить текст |
| Translated on this Mac. Languages it cannot translate itself use Translate Online, if it is on. | Перевод выполняется на этом Mac. Языки, которые он не переводит сам, переводятся онлайн, если это включено. |
| Translation | Перевод |
| Online | Онлайн |
| Now Playing | Сейчас играет |
| Now Playing reader | Чтение «Сейчас играет» |
| Permission | Разрешение |
| Isla %@ is the latest version. | Isla %@ — последняя версия. |
| Acknowledgements… | Благодарности… |
| Nothing leaves your Mac unless you turn it on. | Ничего не покидает ваш Mac, пока вы это не включите. |
| Quit Isla | Завершить Isla |
| Volume and Brightness | Громкость и яркость |
| Volume and Brightness replaces the Mac’s own pop-up and needs Accessibility permission. | «Громкость и яркость» заменяет системное окно Mac и требует разрешения универсального доступа. |
| Accessibility | Универсальный доступ |
| Open Privacy & Security… | Открыть «Конфиденциальность и безопасность»… |
| Isla can’t see the volume keys yet. Until it can, the Mac shows its own pop-up. | Isla пока не видит клавиши громкости. До тех пор Mac показывает своё окно. |

Each release adds only the rows it uses, in both tables, with
`test-localizations.sh` green.

## 16. Releases

Each release is its own branch, cut from the previous one; Tier 3 pipeline;
tests first; `./scripts/check` green with its output shown; a Codex review and
an Opus review; commit; `Scripts/bundle.sh release`; `Scripts/install.sh`.
None merges to `main` without the owner.

### R1 — Island, Music, Lyrics (`feat/redesign-r1-island-music-lyrics`)

In: §2 tokens and new `Theme` values; §3 (except 3.7, which is R2); §4; §5;
§6; the Settings rows Volume and Output, Lyric Band, Translate Lyrics and
Translate To added to today's single-list Settings (R4 moves them).
Tests: `PlayerVolumeTests` (Volume and Output defaults on and writes nothing until the slider moves or a device is picked); compact width and wing margins at notch widths 180/200/220; key line
shown only for dark tones and always under Increase Contrast;
`WallpaperTone` luminance on fixture images and failure → not dark; peek
geometry; ambient widths; tint extraction (saturated, greyscale, missing);
player layout positions at 480/560/620 and the 540 volume fold; no-lyric
shift; LIVE row; empty states' strings; P/C/T element frames; expanded state
per tab and `openBodySize`; active rect at 400; lyric translation batching,
caching and the same-language skip (with a fake translator — tests never
reach the network or a real player); More menu contents with and without a
binding.
Owed on hardware: R1-H1 the 300 pt island and its margins on the 14-inch
notch; R1-H2 key-line width and strength on Aerial and Pro Black, and absence
on Sonoma; R1-H3 the peek's 50 pt growth reads as the island, not a window;
R1-H4 player → column → tall travel with nothing popping; R1-H5 the volume
slider follows the keys and an AirPods switch; R1-H6 lyric translation on a
Russian/English song.

### R2 — Lock screen (`feat/redesign-r2-lock`)

In: §3.7; §7. Tests: banner and card frames, the morph keeps centre x and
top; Automatic alpha at the four reference luminances and the clamps; Reduce
Transparency → Solid; default Automatic only when unset; island wings hidden
while the banner or card shows; compact 420 × 236.
Owed on hardware: R2-H1 the banner on Aerial, Pro Black, Sonoma and Sky
Blue; R2-H2 banner → card → banner by click and chevron; R2-H3 the lyric
legible on Aerial at Automatic; R2-H4 the output pane switches to AirPods
with the haptic; R2-H5 no wings at the notch while locked.

### R3 — Shelf and Clipboard (`feat/redesign-r3-shelf-clipboard`)

In: §8; §9. Tests: grid columns per width; middle truncation; selection bar
contents per width; Delete removes the selection and not the files; drop
target choice; colour, code and link detection tables; pins sort first and
survive Clear Everything; Keep Pinned Items round-trips through the file and
deleting the setting deletes the file; image cap 12 and the 25 MB rule;
search filters and highlights; the filter's symbol mode below 540.
Owed on hardware: R3-H1 dragging three Finder files in, and over AirDrop;
R3-H2 Delete with the pointer on the Shelf; R3-H3 an image copied from
Safari appears and pastes back; R3-H4 pins survive a relaunch with Keep
Pinned Items on and vanish with it off.

### R4 — Translate and Settings (`feat/redesign-r4-translate-settings`)

In: §10; §11. Tests: every section's rows and defaults; last section
restored; the renamed keys; failure groups only in Music; pop-up recents;
Paste enabled only with text; Speak toggles and stops; history cap 20 and
memory-only; one alert at a time.
Owed on hardware: R4-H1 Settings at 480 in Russian; R4-H2 Speak in Russian
and English voices; R4-H3 the lock-style previews match the lock screen.

### R5 — Volume and brightness pop-up (`feat/redesign-r5-hud`)

In: §12; the Settings › General row. Tests: the event decoding for each key
(pure function over `NX_SYSDEFINED` data); volume step arithmetic including
quarter steps; the SPI resolver degrades when a symbol is missing; nothing is
tapped while the setting is off or the app is untrusted; priority over the
peek; not shown while locked.
Owed on hardware: R5-H1 granting Accessibility, then the volume keys show
Isla's pop-up and never the Mac's; R5-H2 mute keeps the level; R5-H3 display
and keyboard brightness on a MacBook Pro; R5-H4 turning it off gives the keys
back at once; R5-H5 an external keyboard's volume keys.

## 17. Calls made in this spec

Decided here without asking, as the conventional Apple answer; reverse any
of them by amending this section.

- The key line's dark threshold (mean luminance 0.20) and the Automatic
  material formula, fitted to the four boards' wallpapers.
- `ambientNameExtension` 220 → 208 so headphones and the volume pop-up share
  one width.
- The synthetic island grows from 180 to 200 wide to match the board.
- Expanded state is remembered per tab for the session, not across launches.
- Clipboard image cap (12 images, 25 MB each) and pinned-file location.
- Translate history is 20 entries, memory only, and off by default (the board
  showed the toggle without a default, and history is content).
- The Speak button is on by default: it sends nothing anywhere and changes
  nothing system-wide.
- Rest as Banner is on by default: display only.
- Include Images is on by default: memory only, empties at quit like the
  rest of the history.
