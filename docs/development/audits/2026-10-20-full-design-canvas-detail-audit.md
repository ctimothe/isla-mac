# Full Design canvas — detail audit (2026-10-20)

Read-only comparison of the "Isla - Full Design" canvas (https://claude.ai/artifact/MdfKViVLiVn4iTRc5RNbqw,
version 1792494654-125c, built 2026-10-19 by a Sonnet 5.5 session) against `Sources/IslaKit` at
origin/main c38ea2a. Five Opus reviewers, one per area. Layout and geometry largely match; the
mismatches are icons, colours, type weights and runtime imagery.

Root causes, across every area:

1. Every SF Symbol was hand-drawn as an SVG stroke approximation, often the wrong symbol, outline
   instead of fill, missing knock-outs, or too thin for the app's semibold/medium weights.
2. Runtime imagery the app takes from the Mac (source app icons, Spotify/Music icons, the Isla
   icon, Finder document icons, AirDrop artwork, album art) was faked with tinted tiles.
3. Device-dependent symbols (output device, headphones) were drawn generically instead of the
   symbol `AudioOutputs` picks (`laptopcomputer`, `airpods.pro`, …).
4. A handful of colours/values were guessed or used light-mode system colours in a forced-dark panel.
5. Native controls (ProgressView, mini Slider, switch accent, NSMenu) were redrawn as custom shapes.
6. Motion-shaped details (equalizer centred growth, spoiler dust) were drawn as static guesses.


---

## Audit 1: island and shell, detail level (canvas vs shipped Swift)

Paths: Swift = `Sources/IslaKit/` in worktree `dynamic-island-upgrade-screens-e14359`. Canvas = `scratchpad/canvas/project/`.
NotchContentView.swift line numbers are absolute file lines.
Severity = how visible to a designer looking at the canvas.

## Mismatches

| # | Canvas file / element | Canvas has | App has (Swift file:line, value) | Sev |
|---|---|---|---|---|
| 1 | Island + Equalizer: equalizer bar alignment | `align-items: flex-end`. Bars stand on the bottom edge | Bars are **centred vertically**. Each CAGradientLayer sits at `position.y = box / 2` (`UI/CompactEqualizer.swift:166`), so its height grows both ways from the middle. The Reduce Motion HStack also centres by default (`:77`) | HIGH |
| 2 | Island `volume`, muted | Speaker plus a two-stroke **X** (`M12 5.5l6 5M18 5.5l-6 5`) | `speaker.slash.fill`: a diagonal slash through the speaker (`Model/HUDMoment.swift:57`, picked at `:73`) | HIGH |
| 3 | Island `headphones` glyph | Hand-drawn over-ear headphones: stroked band, filled cups, one opacity of 0.85 | The device's own SF Symbol. "AirPods Pro" maps to `airpods.pro` (`Services/AudioOutputs.swift:135`). Drawn `.resizable().symbolRenderingMode(.hierarchical)` in white 0.85 at 43×34 (`UI/NotchContentView.swift:833-839`, `Notch/ExpandedAlertShape.swift:93-94`). Wrong object, and no hierarchical layer opacities | HIGH |
| 4 | Island `update` glyph | Blue circle (#4d9bff→#0a84ff) with a **white** stroked arrow, width 3 | `arrow.down.circle.fill` (`Notch/ExpandedAlertShape.swift:130`), monochrome, styled `Theme.updateBlue.gradient` (`UI/UpdateAlertView.swift:50-53`). The arrow is a **knock-out**, so the island's black shows through, not white. The SwiftUI `.gradient` stops are system-defined and subtler than #4d9bff (stops UNVERIFIED) | HIGH |
| 5 | Surface: player/stage header glyph and name | Hand-drawn note, 14 px in an 18×16 box, then "Music" | The playing app's **own icon** when the source is known (Spotify, Music, a browser): `Image(nsImage:)` in a 32.3 pt frame (`toolSide / (824/1024)`) inside a 26 pt box, named by the app (`UI/SurfaceHeader.swift:52-58, 235-239, 263-267`; `Services/MediaController.swift:63`). `music.note` 14 medium plus "Music" is only the fallback | HIGH |
| 6 | Update buttons "Later" / "Install" | 14 px, weight 400 | 14 **semibold** (`UI/UpdateAlertView.swift:178`, `UpdateAlertButtonStyle`) | MED |
| 7 | Surface: tool gear glyph | Custom stroked ring, inner ring and 8 round spokes | `gearshape` (outline cog), 14 **medium** (`UI/SurfaceHeader.swift:115, 135-136`) | MED |
| 8 | Surface: Settings header glyph | Filled disc, 8 spokes, black hole | `gearshape.fill`, 14 medium, white (`Model/Surface.swift:57`; `UI/SurfaceHeader.swift:260-262`) | MED |
| 9 | Surface: Clipboard header glyph | Filled board, black clip outlined in white, two black lines | `list.clipboard.fill`: a clipboard with a **bulleted list** knocked out (dots plus lines), 14 medium (`Model/Surface.swift:55`) | MED |
| 10 | Surface: Translate header glyph | Filled speech bubble with a stroked black "A" | `character.bubble.fill`, 14 medium (`Model/Surface.swift:56`). The character inside comes from the symbol. Whether it changes per locale, for example Cyrillic under ru, is UNVERIFIED | MED |
| 11 | Island `shelf` glyph, and the Surface tray glyph | Custom tray. The two paper bars use **fill-opacity 0.55 and 0.8**, and the lip cut-out is painted **black 0.55** | `tray.full.fill`, monochrome solid white with real knock-outs (`UI/NotchContentView.swift:864-868` at 26×20 resizable; header at `:984` via `UI/SurfaceHeader.swift:260-262` at 14 medium). No partial opacities, and the knock-outs show the island fill | MED |
| 12 | Island `volume` speaker waves | Always two **stroked** arcs (1.6 wide) while level > 0 | `speaker.wave.1/2/3.fill` by thirds of the level (`Model/HUDMoment.swift:55, 74-77`). The waves are filled glyph arcs. At the default 62 % it is wave.2, at 70 % and up wave.3. With AirPods as output the glyph is the device symbol (`:72`) | MED |
| 13 | Island `volume`: brightness variants | Missing | Display brightness `sun.max.fill`, keyboard `light.max`, with the matching title (`Model/HUDMoment.swift:52-53`) | MED |
| 14 | Island: Shelf **bubble** beside the music pill | Missing state | Its own black NotchShape with a white 0.14 stroke. `tray.full.fill` 18×14, then the count in 13 **semibold** monospaced **blue #0A84FF**, spacing 5 (`UI/IslandBubble.swift:76-86, 101-108`; layout `:31-34`) | MED |
| 15 | Island `charging`: level text and battery fill | Flat `rgb(48,209,88)` | `Theme.chargingGreen.gradient`: SwiftUI's subtle vertical gradient on #30D158 (`UI/NotchContentView.swift:792, 812, 815`) | LOW-MED |
| 16 | Island `held`: plug | Hand-drawn 16×16 plug with rounded rects | `powerplug.fill`, `.system(size: 14 × glyphScale, weight: .semibold)`, white (`Model/AmbientActivity.swift:44`; `UI/NotchContentView.swift:802-804`) | LOW-MED |
| 17 | Island music: note in the empty cover well | Hand-drawn note: filled head, stroked stem, 11 px (14 px on peek), fixed white 0.55 | `music.note` at `islandFont(.body, weight: .regular)` = 11 regular, tracking 0.07, at **every** size, the 34 pt peek included. Colour `Theme.secondary` = 0.55, or **0.75 under Increase Contrast** (`UI/NotchContentView.swift:1172-1174`). The canvas never lifts it to 0.75 and draws 14 on peek | LOW-MED |
| 18 | Update title "Isla [version] is ready" | letter-spacing −0.2 | `islandFont(14, .semibold)`, whose tracking is `tracking(forSize: 14)` = **0** (`UI/UpdateAlertView.swift:58`; `UI/Theme.swift:476`) | LOW |
| 19 | Update buttons under Increase Contrast | No ring | 1 pt `Capsule().strokeBorder(title.opacity(0.6))` (`UI/UpdateAlertView.swift:184-186`) | LOW |
| 20 | Surface gear: update badge | Missing; there is no tweak for it | A 5 pt red dot (`Theme.accent` #FF453A) at the top trailing corner, offset (−3, 3), whenever an update waits and the gear is not on Settings (`UI/SurfaceHeader.swift:117, 147-153`) | LOW |
| 21 | Surface tool buttons: hover, on and pressed states | Only the rest state: fill 0.08, glyph at secondary | Hover fill 0.14. On (History open) fill 0.18 with a white glyph. Pressed: label opacity 0.55 (`UI/SurfaceHeader.swift:137, 145`; `UI/Theme.swift:1400`). Remove All goes white on hover (`UI/SurfaceHeader.swift:300, 305`) | LOW |
| 22 | Surface: Remove All trash and History glyphs | Hand-drawn trash (16 box, stroke 1.4); hand-drawn clock-arrow | `trash` and `clock.arrow.circlepath`, both 14 **medium** (`UI/SurfaceHeader.swift:292-293`; `UI/NotchContentView.swift:1019`) | LOW |
| 23 | Page dots: hover | Missing | The other dots go 0.30→**0.45** under the pointer (`UI/Theme.swift:1185`; `UI/PageDots.swift` `opacity(index:current:hovering:)`) | LOW |
| 24 | Paused play glyph on the cover | SVG triangle 9 px with sharp corners | `play.fill`, 9 **bold** (rounded corners), white, shadow black 0.35 r1.5 y0.5, x +0.5 (`UI/NotchContentView.swift:1192-1196`). Shadow and offset match; only the glyph shape differs | LOW |
| 25 | Corners: cover, battery, header buttons, volume bar | CSS circular `border-radius` | `RoundedRectangle(style: .continuous)` (squircle) everywhere: cover `UI/NotchContentView.swift:1200`, battery `UI/IslandBattery.swift` bodyShape, buttons `UI/SurfaceHeader.swift:144`, bar `UI/NotchContentView.swift:907` | LOW |
| 26 | Shadow on tall shapes | CSS `drop-shadow(0 0 14px rgba(0,0,0,0.22))` | CALayer `shadowRadius 14`, `shadowOpacity 0.22`, offset 0 (`Notch/IslandOutlineHost.swift:139-142`). CSS blur radius and CA shadowRadius do not map 1:1, so the spread differs (exact factor UNVERIFIED) | LOW |
| 27 | Edge-NoNotch `awake` stroke | strokeShown forced to 0 when not physical | The stroke shows when `restsInNotch && isAwake` (`UI/NotchContentView.swift:164`). Whether a no-notch display counts as `restsInNotch` is UNVERIFIED (geometry, out of scope) | LOW |
| 28 | Main.dc.html token sheet: tokens missing from "Colours" | Not listed | `updateInstallTitle` #3E8EF7 (`UI/Theme.swift:1148`); SettingsTint rose #FF375F, orange #FF9F0A, indigo #5E5CE6 (`:1279-1281`); `coverWell` white 0.14 (`:678`); page dots 0.90 / 0.30 / 0.45 (`:1183-1185`); `switchOnFill = NSColor.controlAccentColor`, a **dynamic system accent**, not a fixed hex (`:984`); `success = Color.green`, the system green, #30D158 dark (`:1100`) | LOW |
| 29 | Main.dc.html type roles | Only roles, all at weight 500 except title | Bare `islandFont(_ size:)` defaults to **.regular** (`UI/Theme.swift:1727`), and most island text uses it (Charging, Connected, device name, HUD title). The sheet implies medium is the house default for island text | LOW |

## Icons inventory (island and shell area)

| Symbol | Where (file:line) | Size / weight | Rendering / colour |
|---|---|---|---|
| `music.note` | `UI/NotchContentView.swift:1172` (cover well) | 11 regular (`.body`) | monochrome, `Theme.secondary` 0.55 / 0.75 |
| `music.note` | `UI/SurfaceHeader.swift:238` (player header fallback), drawn `:260` | 14 medium | white |
| `play.fill` | `UI/NotchContentView.swift:1192` | 9 bold | white, shadow black 0.35 r1.5 y0.5 |
| `tray.full.fill` | `UI/NotchContentView.swift:864` (compact Shelf) | resizable 26×20 | white |
| `tray.full.fill` | `UI/NotchContentView.swift:984` (tray header) | 14 medium in an 18×16 box | white |
| `tray.full.fill` | `UI/IslandBubble.swift:76` | resizable 18×14 × glyphScale | white |
| `powerplug.fill` / `bolt.fill` | `Model/AmbientActivity.swift:44-45`; drawn `UI/NotchContentView.swift:802` (plug only; the bolt is never drawn here) | 14 × scale, semibold | white |
| `airpods`, `airpods.pro`, `airpods.max`, `beats.headphones`, `headphones` | `Services/AudioOutputs.swift:134-156`; drawn `UI/NotchContentView.swift:833` | resizable 43×34 | hierarchical, white 0.85 |
| `speaker.wave.1.fill` / `.2.fill` / `.3.fill`, `speaker.fill`, `speaker.slash.fill`, `sun.max.fill`, `light.max` | `Model/HUDMoment.swift:52-57`; drawn `UI/NotchContentView.swift:901` | resizable 22×16 | monochrome white |
| `arrow.down.circle.fill` | `Notch/ExpandedAlertShape.swift:130`; drawn `UI/UpdateAlertView.swift:50` | resizable 38×38 | monochrome, `updateBlue.gradient` (#0A84FF base) |
| `gearshape` / `xmark` | `UI/SurfaceHeader.swift:115`; drawn `:135` | 14 medium | `Theme.secondary`, or white when on |
| `clock.arrow.circlepath` | `UI/NotchContentView.swift:1019` | 14 medium | secondary |
| `trash` | `UI/SurfaceHeader.swift:292` | 14 medium in a 16 wide frame | secondary, white on hover |
| `list.clipboard.fill`, `character.bubble.fill`, `gearshape.fill` | `Model/Surface.swift:55-57`; drawn `UI/SurfaceHeader.swift:260` | 14 medium in an 18×16 box | white |
| App icon (runtime) | `Services/MediaController.swift:63` `sourceIcon`; drawn `UI/SurfaceHeader.swift:264-267` | 32.3 pt frame in a 26 pt box | the app's own bitmap |

## Confirmed correct

- Island fill black, `#1C1C1E` under the pointer when not open; open panel always black (`UI/NotchContentView.swift:156`; `UI/Theme.swift:782`).
- Stroke 2 pt: white 0.14 / 0.30, charging green 0.21 / 0.42; never on the bare resting notch (`UI/Theme.swift:805-809`; `UI/IslandStroke.swift`).
- Shadow only on shapes taller than 68, black 0.22 (`UI/Theme.swift:814-816`).
- Cover well white 0.14; cover edge 0.5 pt white 0.14; sizes 22 r5, 16 r4 short, 34 r8 peek (`UI/Theme.swift:665, 678`; `UI/NotchContentView.swift:1203`).
- Paused cover darkened to 0.55 by multiply; the canvas `brightness(0.55)` is equivalent on the well.
- Equalizer: 6 bars, 2.2 wide, radius 1.1, spacing 0.96, 18 box; heights [7,13,9,16,11,14] / 3; gradient lifted 16 % toward white at the top; paused tertiary 0.50 / 0.65 (`UI/CompactEqualizer.swift`).
- Peek title 13 semibold white, tracking 0; artist 11 regular, secondary, +0.07; spacing 1 (`UI/NotchContentView.swift:1074-1083`).
- Shelf count: SF Pro Rounded 16, regular, tabular, white (`UI/NotchContentView.swift:872`).
- "Charging" 14 regular white 0.88; level 14 regular tabular; battery 28×16 r6, cap 2×6 r1.5, gap 1.5, track 0.30 (`Notch/CompactIslandLayout.swift:139-158`).
- Headphones text: "Connected" 13 regular white 0.40; name 15 regular, −0.2, white 0.82 (`Notch/ExpandedAlertShape.swift:104-110`).
- Volume: title 15 regular 0.90; track white 0.18, fill 0.92, muted 0.32, bar 8 tall r4; number rounded 14 at 0.80 (`Model/HUDMoment.swift:90-141`).
- Update: detail 11 medium white 0.55 on a 14 pt pitch; Later grey #8E8E93 at 0.22; Install #0A84FF at 0.22 with a #3E8EF7 title (`Notch/ExpandedAlertShape.swift:148-165`; `UI/Theme.swift:1145-1150`).
- Header title 13 semibold white, tracking 0, min scale 0.82 (`UI/SurfaceHeader.swift:206-210`).
- Header tool button 26×26, radius 8, fill white 0.08, glyph at secondary (`UI/SurfaceHeader.swift:142-145`).
- Remove All "All" 13 medium; padding 9; gap 4 (`UI/ShelfLayout.swift:174-177`).
- Tray header count 13 semibold tabular white (`UI/NotchContentView.swift:989`; `UI/ShelfLayout.swift:217`).
- Page dots 6 pt on a 14 pt pitch, 0.90 current and 0.30 others (`UI/PageDots.swift:8-9`; `UI/Theme.swift:1183-1184`).
- Main.dc.html: the type-role sizes and tracking, the contrast ramp (secondary, tertiary, quaternary, surface, hover, hairline, chip and the card values) and the listed colour hexes all match `UI/Theme.swift`.

---

## Audit 2: Player and lyrics stage, detail mismatches

Source checked: `Sources/IslaKit` at HEAD c38ea2a (`./scripts/source-fresh.sh` said FRESH; contains origin/main).
Paths below are relative to `Sources/IslaKit/`. Canvas files: `PlayerBody.dc.html`, `StageBody.dc.html`,
`Player-States.dc.html`, `Stage-States.dc.html` (the last two only host the first two, plus 11 px captions that are canvas notes, not app UI).

Severity is how visible the difference is to a designer looking at the canvas: high, med, low.

## Mismatches

| # | Canvas file + element | Canvas has | App has (Swift file:line, quoted) | Sev |
|---|---|---|---|---|
| 1 | StageBody: Hide Lyrics tool (rightmost foot tool, on) | White filled speech bubble with **two black horizontal lines** (reads as `text.bubble.fill`) | `HeaderIconButton(symbol: "quote.bubble.fill", … isOn: true …)` UI/LyricsStageSurface.swift:244; drawn `.font(.system(size: 13, weight: .medium))` UI/LyricHeaderTools.swift:26. The glyph is a bubble with two **quotation marks** knocked out (transparent, so the 0.18 chip shows through), not lines and not black ink. | high |
| 2 | PlayerBody: Output button glyph (and StageBody Output tool) | Hand-drawn **filled** speaker body with two arcs (a `speaker.wave.2.fill` look) | The glyph is the current device's symbol: `AudioOutputs.symbol(...)` Services/AudioOutputs.swift:120-167. On a MacBook's built-in speakers that is `"laptopcomputer"` (:150, :155); AirPods give `"airpods"`/`"airpods.pro"`/`"airpods.max"` (:134-136); the fallback before the watch reads is `"speaker.wave.2"` (:183), which is the **outline** speaker, not filled. Player draws it resizable into 28 × 27 (UI/MediaPane.swift:939-942, UI/PlayerLayout.swift:127) at white 0.50 (UI/MediaPane.swift:642); stage draws it at `.system(size: 13, weight: .medium)` (UI/MediaPane.swift:944-945) in `Theme.secondary`. | high |
| 3 | PlayerBody: equalizer bars | Bars **bottom-aligned** (`align-items: flex-end`), growing up from a baseline | Bars are **vertically centred** in the 18 pt box and grow both ways: `bar.position = CGPoint(…, y: box / 2)` UI/CompactEqualizer.swift:164-166; the Reduce Motion path is a default-centred `HStack` (:77). Applies to playing (7/13/9/16/11/14) and paused (3 pt dashes on the midline, not on the floor). | high |
| 4 | PlayerBody empty state: icons on "Open Apple Music" / "Open Spotify" | Grey 16 px rounded square, white 0.25 | The installed app's real icon at runtime: `AppIconImage(image: app.icon, side: PlayerLayout.openButtonIconSide)` UI/MediaPane.swift:810, side 16 (UI/PlayerLayout.swift:171), drawn at `side * Theme.appIconOpticalScale` (= 16 × 1024/824 ≈ 19.9 pt, unclipped, its own drop shadow spilling) Services/AppIcons.swift:182-189, Theme.swift:1358. Music's red-pink note squircle and Spotify's green squircle should be shown, not a grey tile. | high |
| 5 | PlayerBody + StageBody: cover art | Linear gradient `145deg, tint → #2a1a3a` as the "art" | The real album artwork, `Image(nsImage: media.artwork).resizable().aspectRatio(contentMode: .fill)` UI/MediaPane.swift:227-229, UI/LyricsStageSurface.swift:254-256. A fake is expected in a canvas, but the gradient's purple end has no source in the app; a placeholder photo would read truer. | med |
| 6 | StageBody "looking" state: spinner | An SVG **arc** on a 0.25 ring, 16 px, stroke 1.6 | Native `ProgressView().controlSize(.small).tint(.white)` at 16 × 16 UI/LyricsStage.swift:837-840: on macOS this is AppKit's small spinning indicator (spoked), not an arc ring. Spoke look is from macOS behaviour, not from repo code: UNVERIFIED in-source. | med |
| 7 | StageBody status glyph for off / notFound | Empty speech-bubble outline, nothing inside | `statusGlyph("quote.bubble")` UI/LyricsStage.swift:843, :847, :850: the bubble carries two **quotation marks**; drawn `.font(.system(size: 22, weight: .light))` in `Theme.tertiary` (:904-906). | med |
| 8 | PlayerBody: sung line sweep, lit part | Lit part at white **0.82** (gradient hard-stop 0.82 / 0.45) | The renderer draws the whole run at `base` first, then the lit part **on top of it** at `accent` (UI/KaraokeText.swift:69-71, :77-89). With accent 0.82 (Theme.swift:752) over base 0.45 (:753) the lit words composite to 0.82 + 0.45 × 0.18 ≈ **0.90** white. Canvas lit part is about 9 % too dim. (Stage is unaffected: accent 1.0 over 0.50 stays 1.0.) | med |
| 9 | PlayerBody: equalizer / StageBody progress fill colour when cover is missing | Still coral `#e8604c` | No cover ⇒ `CoverTint.fallback` = sRGB 0.82 grey (#D1D1D1; lifted top ≈ #D8D8D8) Services/CoverTint.swift:34, :59; used as `coverTint` default UI/MediaPane.swift:45, UI/LyricsStageSurface.swift:106. The `cover="missing"` cell in Player-States should show grey bars. Also: a real tint is the cover's most saturated pixel lifted to ≥ 0.65 brightness (CoverTint.swift:62-89), so the tweak's default is only an example. | med |
| 10 | StageBody: Show Translation tool, on state | Filled bubble with a **black** "A" stroke drawn on it | `"character.bubble.fill"` / `"character.bubble"` UI/LyricHeaderTools.swift:494-496, 13 medium (:26). In `.fill` the character is knocked out (transparent onto the 0.18 chip), not painted black. Which character the en symbol shows: UNVERIFIED. | low |
| 11 | PlayerBody: Favourite "on" | Star filled at white **0.55** (0.75 IC) with a separate 0.50 stroke | `"star.fill"` single shape, white **0.50** for fill and edge alike: `.foregroundStyle(.white.opacity(Theme.playerSecondaryControlOpacity))` UI/MediaPane.swift:682-686, Theme.swift:762. No Increase Contrast variant exists for this opacity. | low |
| 12 | PlayerBody: star, transport, music-note glyphs (shape) | Hand-drawn SVG approximations: sharp-pointed star stroke 1.8; skip triangles with 1.6 px round join; pause bars rx 2.6; note as polyline flag | SF Symbols `"star"`, `"backward.fill"`, `"forward.fill"`, `"play.fill"`, `"pause.fill"`, `"music.note"` (UI/MediaPane.swift:624, :629, :635, :682, :867), all `.resizable().aspectRatio(.fit)` into 28 × 27 / 35 × 22 / 29 × 34 (UI/PlayerLayout.swift:125-131). SF corners are rounder and `music.note` has a curved filled flag; the canvas shapes are close but not the glyphs. | low |
| 13 | StageBody: foot transport glyph size | Skip SVG 14 × 10; play/pause 12 × 13 | SF symbols at `.font(.system(size: 13, weight: .semibold))` UI/LyricsStageSurface.swift:274-275: no resizing, natural 13 pt semibold metrics. Canvas skip glyph is probably narrower than SF's 13 pt `backward.fill`: UNVERIFIED (needs a render). | low |
| 14 | StageBody: status line tracking | `letter-spacing: 0.07px` | `.islandFont(12, weight: .medium)` UI/LyricsStage.swift:912 → `Theme.tracking(forSize: 12)` = **0** (12 falls in `..<15`) Theme.swift:475-476. | low |
| 15 | StageBody: foot artist tracking | `letter-spacing: 0.07px` | `.tracking(Theme.tracking(forSize: 12))` UI/LyricsStageSurface.swift:206 → **0**. | low |
| 16 | StageBody: Sync pill label tracking | `letter-spacing: 0px` | `.islandFont(11.5, weight: .semibold)` UI/LyricsStage.swift:675 → tracking **0.07** (`..<12`) Theme.swift:475. | low |
| 17 | StageBody: Sync pill shadow | `0 2px 4px rgba(0,0,0,0.5)` | `.shadow(color: .black.opacity(0.5), radius: 4, y: 2)` UI/LyricsStage.swift:681. SwiftUI radius 4 is a softer blur than CSS blur 4 px (roughly CSS 8 px): UNVERIFIED conversion. Edge is `Capsule().stroke(Theme.hairline, lineWidth: 0.5)` (:680), a centred stroke, canvas uses inset; negligible. | low |
| 18 | StageBody: progress fill end | Square right end (only the track is rounded) | Fill is its own `RoundedRectangle(cornerRadius: 1.5, style: .continuous)` UI/LyricsStageSurface.swift:300-302, StageLayout.progressRadius 1.5 (:77). | low |
| 19 | PlayerBody / StageBody: corner style | CSS circular `border-radius` | All wells, covers, chips are `style: .continuous` squircles (e.g. UI/MediaPane.swift:245, :256; UI/LyricsStageSurface.swift:261, :280; UI/LyricHeaderTools.swift:30). | low |
| 20 | Stage-States "unreadable" copy | Curly apostrophe "can’t" | Straight "can't": `localized("Line %d of this file has a time Isla can't read.", line)` UI/LyricsPageModel.swift:68; Resources/en.lproj/Localizable.strings:338. | low |
| 21 | PlayerBody: long title / artist overflow | `text-overflow: ellipsis` | `MarqueeLine` UI/MediaPane.swift:272, :396: no ellipsis while live; the far end fades over 14 pt (UI/MarqueeLine.swift:36, :72-94) and the line scrolls. Only shows with a long title. | low |
| 22 | StageBody: wrapped sung line | One gradient across the whole block (both wrapped rows lit to the same x) | Sweep clipped per run in reading order, so row 1 fills before row 2 starts (UI/KaraokeText.swift:56-62, :78-87). Visible only on a two-row sung line. | low |
| 23 | PlayerBody: footnote icon (reader down) | SVG circle-i 12 px, stroke 1.3 | `Image(systemName: "info.circle")` inheriting `.islandFont(.body, weight: .regular)` = 11 pt regular UI/MediaPane.swift:827-830. | low |

### Present in the app, missing from the canvas (detail level)

| # | Element | App (file:line) | Sev |
|---|---|---|---|
| M1 | Scrubber hover: an 11 pt white knob with `.shadow(color: .black.opacity(0.4), radius: 3)` and the elapsed time brightening to white 0.9 during the hover preview | UI/MediaPane.swift:518-523, :475-476 | low |
| M2 | Disabled skip buttons at opacity 0.35 when the source cannot skip (player and stage) | UI/MediaPane.swift:663-664; UI/LyricsStageSurface.swift:286-287 | low |
| M3 | Spotify star at 0.45 while the library has not answered | UI/MediaPane.swift:690 | low |
| M4 | Cover loading skeleton (surface 0.16 with a white 0.10 shimmer) for up to 2.5 s before the missing-cover well | UI/MediaPane.swift:236-243; UI/Skeleton.swift:15-25 | low |
| M5 | Stage cover missing: `MissingCoverWell(noteSize: 16)`; canvas stage always shows the gradient | UI/LyricsStageSurface.swift:258 | low |
| M6 | Stage notice row above the lines (version mismatch or notice): 40 tall, white 0.07, radius 9, 0.5 hairline, `exclamationmark.circle` or `clock.arrow.circlepath` 12 regular in secondary, 11 regular white text | UI/LyricsStage.swift:210-217, :794-819; Theme.swift:605-607 | med |
| M7 | Stage states `cannotLookUp` (quote.bubble + sentence, no button) and `chooseLocal` (candidate list, 10 regular) | UI/LyricsStage.swift:846-848, :868-884 | low |
| M8 | Credit lines on the stage: italic, medium, 0.68 when current / floor otherwise, never swept | UI/LyricRow.swift:207, :212-217, :311-320 | low |
| M9 | Player sung line of a credit drawn italic | UI/MediaPane.swift:379 | low |

## Icons inventory (this area)

| Symbol | Where (file:line) | Size / weight | Rendering / colour |
|---|---|---|---|
| `backward.fill` | Player UI/MediaPane.swift:624 | resizable, fit into 35 × 22 (UI/PlayerLayout.swift:128) | monochrome, white 0.90 (Theme.swift:761); 0.35 when disabled |
| `forward.fill` | Player UI/MediaPane.swift:635 | resizable 35 × 22 | white 0.90 |
| `play.fill` / `pause.fill` | Player UI/MediaPane.swift:629 | resizable 29 × 34 (UI/PlayerLayout.swift:129) | white 0.90, `.symbolEffect(.replace.downUp)` swap (Theme.swift:1704-1707) |
| `star` / `star.fill` | Player UI/MediaPane.swift:682 | resizable 28 × 27 | white 0.50; 0.45 opacity while Spotify unknown |
| current output device: `laptopcomputer`, `airpods`, `airpods.pro`, `airpods.max`, `beats.headphones`, `homepod`, `appletv`, `display`, `headphones`, `hifispeaker`, `airplayaudio`, `tv`, `waveform`, fallback `speaker.wave.2` | Services/AudioOutputs.swift:134-166, :183; drawn UI/MediaPane.swift:939-945 | Player: resizable 28 × 27, white 0.50 (UI/MediaPane.swift:642). Stage: 13 medium, `Theme.secondary` 0.55 (0.75 IC) | monochrome |
| `music.note` (missing cover well) | UI/MediaPane.swift:867 | `.system(size: noteSize)` regular; 22 in player (:233, :779), 16 on stage (UI/LyricsStageSurface.swift:258) | `Theme.quaternary` white 0.30 (0.50 IC) Theme.swift:713-719; well white 0.08 (:723) |
| `info.circle` | UI/MediaPane.swift:827 | 11 regular (inherits `.islandFont(.body, .regular)`) | `Theme.tertiary` 0.50 (0.65 IC) |
| `music.note` (Sync pill) | UI/LyricsStage.swift:672 | 10 bold | white |
| `music.note` (interlude track style, not used on stage: stage uses `.dots`) | UI/LyricRow.swift:509 | inline in Text at row font | white at ramp opacity |
| `quote.bubble` | UI/LyricsStage.swift:843, :847, :850 | 22 light (:905) | `Theme.tertiary` |
| `exclamationmark.bubble` | UI/LyricsStage.swift:886 | 22 light | `Theme.tertiary` |
| `exclamationmark.circle` / `clock.arrow.circlepath` | UI/LyricsStage.swift:211, :213 (notice row :796) | 12 regular | `Theme.secondary` |
| `quote.bubble.fill` (Hide Lyrics, on) | UI/LyricsStageSurface.swift:244 | 13 medium (UI/LyricHeaderTools.swift:26) | white on `Theme.selectedChip` 0.18 (0.30 IC), radius 7 continuous |
| `character.bubble` / `character.bubble.fill` | UI/LyricHeaderTools.swift:494-496 | 13 medium | off: `Theme.secondary`, no well; on: white on selectedChip |
| `ellipsis` (More) | UI/LyricHeaderTools.swift:229 | 13 medium | `Theme.secondary`, no well |
| `backward.fill`, `play.fill`/`pause.fill`, `forward.fill` (stage foot) | UI/LyricsStageSurface.swift:214-225, drawn :274-275 | 13 semibold, not resizable | white on white 0.10 well, radius 8 continuous |
| More menu items (NSMenu, not on canvas): `minus`, `plus`, `pencil`, `minus.circle`, `doc.badge.plus`, `arrow.clockwise`, `shuffle`, `repeat` | UI/LyricHeaderTools.swift:93-104 | system menu size | system menu appearance |
| Output menu rows (NSMenu, not on canvas): device symbol, fallback `speaker.wave.2.fill` | UI/OutputMenu.swift:91, :129-130 | menu image | n/a |
| App icons (not SF): Apple Music, Spotify in empty-state buttons | UI/MediaPane.swift:810; Services/AppIcons.swift:176-190 | 16 frame, drawn ≈ 19.9 | full-colour runtime icon from the installed app |

## Confirmed correct

- Player title 16 medium, tracking -0.2, white 0.80; artist after " – " at 0.50 (UI/MediaPane.swift:275-284, :296; Theme.swift:749-750).
- Player artist-only subtitle 14 regular, tracking 0, white 0.50 (UI/MediaPane.swift:399-401).
- Sung line 14 semibold, tracking 0, base 0.45, hard-edged sweep (UI/MediaPane.swift:374-377; UI/KaraokeText.swift:80-87).
- Paused sung line 0.7 (UI/MediaPane.swift:413; Theme.swift:696); paused cover 0.8 multiply (UI/MediaPane.swift:249; Theme.swift:693), CSS `brightness()` is an equivalent multiply.
- Cover 60 × 60, radius 10, 0.5 pt white 0.14 edge (UI/PlayerLayout.swift:65-67; UI/MediaPane.swift:255-258; Theme.swift:776).
- Times: SF Rounded 11 medium, monospaced digits, white 0.40, "-" prefix on remaining (UI/MediaPane.swift:460, :473-484; Theme.swift:755).
- Progress 7 tall, radius 3.5, track 0.15, fill 0.50, fill min width = height (UI/PlayerLayout.swift:99-103; UI/MediaPane.swift:509-517; Theme.swift:757-758).
- LIVE badge 9 bold, tracking 0.4, white on rgb(255,69,58) = #FF453A, radius 3, 12 tall, 4 pt padding (UI/MediaPane.swift:489-496; Theme.swift:686).
- Equalizer: 6 bars 2.2 wide, 0.96 gap, 18 box, heights 7/13/9/16/11/14 playing and 3 at rest, top lifted 16 % toward white, rest bars white 0.50 (Notch/CompactIslandLayout.swift:71-75; UI/CompactEqualizer.swift; Theme tertiary).
- Transport white 0.90, Favourite and Output 0.50; control centres at -133/-69/0/69/133 (Theme.swift:761-762; UI/PlayerLayout.swift:114-121).
- Empty state: well white 0.08 with quaternary 22 pt note, headline 14 semibold white, caption 12.5 regular secondary, all three message texts (UI/MediaPane.swift:712-737, :779-791).
- Empty-state buttons: 22 tall capsules, surface 0.16 (0.28 IC), 1 pt hairline 0.10 (0.55 IC), 11 medium tracking 0.07, 10 pt padding, 6 pt icon gap, 8 pt spacing; labels "Open Apple Music", "Open Spotify", "Open Settings" (Theme.swift:1506-1526; UI/PlayerLayout.swift:160-172; Services/PlayerBridge.swift:16-20).
- Footnote text 11 regular tertiary, "Settings › Music says why, with Try Again." (UI/MediaPane.swift:734, :830-831).
- Stage lines: 22 bold, line height 28, tracking -0.35, pitch 38 (56 translated), 2-line limit, reading centre 114 (UI/LyricsStage.swift:57-60; UI/LyricsStageSurface.swift:22).
- Stage sung line white over unswept 0.50 (UI/LyricsStage.swift:138; UI/LyricRow.swift:142-143, :357).
- Stage context ramp: max(board, floor 0.36 / neighbour 0.42), reading 0.46; IC 0.42 / 0.46 / 0.48 (UI/PlayerLayout.swift:305-327; UI/LyricRow.swift:140-144).
- Translation rows 13 regular, gap 2, 0.66 sung / max(0.45, tertiary) others (UI/PlayerLayout.swift:331-343; UI/LyricRow.swift:258, :271-277).
- Interlude dots 7 pt, 6 apart, 0.9 / 0.55 / 0.3 (Theme.swift:618-620; UI/LyricRow.swift:484-491).
- Edge fade 24 pt top and bottom (UI/LyricsStage.swift:549-565).
- Sync pill 74 × 24, rgb(58,58,60) at 0.96, white text and glyph (Theme.swift:599-600; UI/LyricsStage.swift:664-681).
- Status: text 12 medium secondary; buttons 24 tall, 10 pt padding; LRCLIB disclosure 10 regular tertiary; copy for looking/off/notFound (UI/LyricsStage.swift:836-867, :910-925).
- Stage foot: hairline white 0.12 at 0.5; cover 40, radius 8, 0.14 edge; title 13 semibold white; artist 12 regular 0.55; transport wells 32/34/32 × 30, 6 apart, white 0.10, radius 8; tools 28 square, 6 apart, radius 7; More and Output with no well in secondary; Hide Lyrics on the 0.18 chip; progress 3 tall, track 0.18, fill = cover tint (UI/LyricsStageSurface.swift:9-77, :190-306; Theme.swift:767-773; UI/LyricHeaderTools.swift:6-10).
- Panel background behind both bodies is black (UI/NotchContentView.swift:296).

---

## Audit 3: Shelf, Shelf drop and Clipboard (canvas vs. shipped Swift)

Source checked: `Sources/IslaKit` at HEAD c38ea2a (`./scripts/source-fresh.sh` said FRESH: it contains origin/main).
Paths below are relative to `Sources/IslaKit/`. Canvas files are in `scratchpad/canvas/project/`.
The panel is forced into dark mode (`Notch/NotchPanel.swift:400` `appearance = NSAppearance(named: .darkAqua)`), so adaptive system colours resolve to their dark values.
Out of scope: the header strips (Shelf's `tray.full.fill` plus count plus Remove All, Clipboard's title) are drawn by `SurfaceHeader` and are not in these six files.

## Mismatches

| # | Canvas file + element | Canvas has | App has (Swift file:line, quoted value) | Sev |
|---|---|---|---|---|
| 1 | ClipboardBody: Kind filter | 5 segments: All, Text, Links, Images, **Files**. `filter` enum and the `kindEmpty` state both use `files`. | 4 segments: `Model/ClipboardBrowser.swift:40` `static let filters: [ClipFilter] = [.all, .text, .links, .images]`. `UI/ClipboardControls.swift:5` says "Files show under All". The Files segment and the "No Files" state cannot be reached in the app. The segment width also changes: 4 segments share 246 pt at 560. | high |
| 2 | ShelfBody: tile caption | 6 of 7 tiles show the **file name** in 2 lines. Only the screenshot tile shows day/time. | Every card shows **day over time**. `UI/ShelfPane.swift:400-406`: `if let date = item.date` gives `added.day` (11.5 semibold, white 0.86) over `added.time` (11.5 medium, secondary, `.monospacedDigit()`). Every new card gets a date: `Services/ShelfStore.swift:772` `item.date = dates[url] ?? now`. The name appears only on pre-date legacy cards (`ShelfPane.swift:407-412`) and as the tooltip. | high |
| 3 | ShelfBody: document icons (PDF, KEY, TXT, ZIP, DOC, XLS, FLAC) | Hand-drawn page (#ececf0, fold #c4c4ca) with a **coloured filled band** and a white bold extension. | The real system icon: `Services/ShelfStore.swift:771` `NSWorkspace.shared.icon(forFile: url.path)`, drawn bare at 42×42 (`UI/ShelfPane.swift:378-381`). On current macOS a document icon is a white page with a folded top-right corner. Usually it carries the owning app's small glyph in the middle and the extension in small grey caps at the foot, with no coloured band. Some types use the app's own document art instead: Keynote, Archive Utility's zip, Music for FLAC. These look are general macOS knowledge, not read from the repo, so mark them UNVERIFIED. Every tile in the canvas looks alike; real ones differ by app. | high |
| 4 | ShelfDropBody: AirDrop well glyph | White stroked "wifi" arcs plus a dot, 22×22, monochrome. | `UI/ShelfLayout.swift:427` `NSSharingService(named: .sendViaAirDrop)?.image`, drawn `.renderingMode(.original)` and **not tinted** (`ShelfLayout.swift:455-461`, comment `ShelfPane.swift:543-544` "AirDrop's real icon is full-colour"), 22×22. This is the full-colour AirDrop icon macOS share menus show (blue roundel with white concentric arcs, UNVERIFIED exact art). Fallback when no service: SF `dot.radiowaves.up.forward` (`ShelfLayout.swift:410`). | high |
| 5 | ShelfDropBody: Keep well glyph | Custom drawing: two pill bars over an open box outline, 22×17, with mixed 0.55/0.8 fills. | SF Symbol `tray.full` (`UI/ShelfLayout.swift:490`) at `.system(size: 22, weight: .regular)` (`ShelfLayout.swift:454`, `glyphSize` 22 at `:511`), solid white (`ShelfPane.swift:546`). It is a single-colour outline tray with two stacked sheet lines inside, all at 1.0 white. | med |
| 6 | ClipboardBody: empty-state glyph ("Nothing copied yet", "Clipboard History") | A single clipboard (board plus clip), stroke 0.9 on a 16 box at 26 px. | `doc.on.clipboard` (`UI/ClipboardPane.swift:281`), `.system(size: 26, weight: .regular)`, tertiary. That is a clipboard with a document overlapping its corner, not a bare clipboard. | med |
| 7 | ClipboardBody: covered rows (privacy dots) | A regular 4×4 px grid of 0.9 px dots at white 0.55 **on a white 0.06 plate**, radius 3, 12 tall. | `UI/SpoilerField.swift:75-111`: **random** seeded dots, density 0.4 per pt² (about 6× denser than a 4 px grid), radius 0.45–0.95, 5 alpha steps from 0.085 to 0.765 (`alpha*0.85`), twinkling and drifting at 20 fps. There is **no background fill**, only the clip to radius 3 (`ClipboardPane.swift:587`). The width fractions per kind match (`Services/ClipboardKinds.swift:40-50`). | med |
| 8 | ClipboardBody: hover pin button (rows) | Diagonal push-pin outline drawn as SVG, stroke 1.4, 11 px. | SF `pin` / `pin.fill` (`UI/ClipboardPane.swift:672`) at `.system(size: 11, weight: .regular)` (`:711`). Tint is secondary, or **white when pinned** (`:673`). The SF pin is an upright thumbtack (round head, needle down), not diagonal. The canvas also never shows the pinned (filled, white) variant on hover. | med |
| 9 | ClipboardBody: image grid pin badge + hover pin | Same diagonal pin path, filled for the badge (9 px) and stroked for hover (10 px, stroke 1.6). | Badge: `pin.fill` `.system(size: 9, weight: .regular)` in white, padding 4, on black 0.55, padding 3 (`ClipboardPane.swift:793-798`). Hover: `pin`/`pin.fill` `.system(size: 10, weight: .semibold)` white on a 22 pt black 0.6 circle (`:850,861-864`). Same symbol-shape problem as #8. | med |
| 10 | ClipboardBody: reveal eye | 22×22 SVG with an eye about 14 px wide, stroke 1.3. The slash runs **bottom-left to top-right** (`M5 17L17 5`). | `eye` / `eye.slash` (`UI/SpoilerField.swift:180`) at `islandFont(.caption, weight: .semibold)` = **10 pt semibold** (`Theme.swift:539`), secondary, in a 22 frame. The real glyph is about 10 pt wide and heavier, and SF's `eye.slash` slash runs top-left to bottom-right (UNVERIFIED direction, from SF Symbols). | med |
| 11 | ClipboardBody: copied tick colour | `rgb(52,199,89)` = #34C759 (systemGreen **light**). | `Theme.success = Color.green` (`UI/Theme.swift:1100`), used at `ClipboardPane.swift:654,878`. On the darkAqua panel this resolves to systemGreen dark **#30D158**. | med |
| 12 | ClipboardBody: copied tick shape | Green disc with a **black stroked** check on top. | `checkmark.circle.fill` 12 pt regular (`ClipboardPane.swift:652-653`, `:876-877`). The check is knocked out (transparent) and shows the row's 0.08 well, not black. A `.symbolEffect(.replace.downUp)` swap runs on appear (`Theme.swift:1705`). | low |
| 13 | ShelfBody: Remove All question text | `font-weight: 500`. | `islandFont(.body, weight: .regular)` = 11 **regular** (`UI/ShelfPane.swift:131`), Theme.secondary. | med |
| 14 | ShelfBody "many" state: `Demo.mov` | Drawn as a Quick Look **preview** (gradient with white border and shadow). | Only images get a preview: `Services/ShelfStore.swift:849-852` `type.conforms(to: .image)`. A .mov shows its type icon bare (system QuickTime movie icon), with no border or shadow. | med |
| 15 | ShelfBody: remove badge | Disc r7 black 0.28, then a full white 0.62 disc r8.5 on top, then a **solid #1c1c1e** X stroke 1.6. | `UI/ShelfPane.swift:433-440`: 14 pt disc of black 0.28 (`Theme.swift:1164`) under `xmark.circle.fill` resized to 17×17 in white 0.62 (`Theme.swift:1163`). The X is a cut-out, so it shows the black-0.28 disc over the tile, a dark translucent X rather than an opaque #1c1c1e one. | low |
| 16 | ClipboardBody: multi-file stack mark | 3 faked pages in a 20 px box. Front page at the **left**, back pages offset **right**, opacities 0.56/0.78/1. | `ClipboardPane.swift:563-571`: up to 3 **real** file icons (`NSWorkspace.icon(forFile:)`, `:1108`), each **18×18**. The first file is on top at `offset x +3`, the second at +1.5 with opacity 0.78, the third at 0 with 0.56. So the front icon sits to the right, mirroring the canvas. The icons are the real types, not three identical pages. | low |
| 17 | ClipboardBody: single file mark | Fake page with a red band, 20 px. | Real `NSWorkspace.shared.icon(forFile:)` at 20×20 (`ClipboardPane.swift:558-560`, `:1105-1110`). Same notes as #3. | low |
| 18 | ClipboardBody: image row thumbnail / image grid tiles | Gradient placeholders. | Real pasteboard thumbnails: `Image(decorative: image.thumbnail, scale: 2)` `.scaledToFill()` (`ClipboardPane.swift:551-556`, `:842-844`), 176×132 px source (`Services/ClipboardImage.swift:92`). Placeholders are acceptable for a canvas; flagged as fake. | low |
| 19 | ClipboardBody: image grid age | Left-aligned under the tile. | Centred: `.frame(width: 88, height: 14)` with the default centre alignment (`ClipboardPane.swift:802-806`). Comment `:235`: "the age centred under each". `.caption` 10 regular tertiary matches. | low |
| 20 | ClipboardBody: search clear ⓧ | 12 px disc at tertiary with a **black** stroked X. | `xmark.circle.fill` 12 regular tertiary (`UI/ClipboardControls.swift:97-99`), frame 22×24 (`clearSide + 6`). The X is a cut-out showing the field fill. | low |
| 21 | ClipboardBody: search ring | Ring only in the `search` state. | The ring shows whenever the field is focused (`ClipboardControls.swift:116-122`), and the field is focused as soon as Clipboard is **summoned** (`:126` `focused = wantsKeyboard`). The usual summoned rest state (empty query) already wears the 1.5 pt blue 0.70 ring. Not on a page reached by a swipe or a dot. | low |
| 22 | All push buttons (Cancel, Remove All, Clear History, Turn On, Open Privacy Settings) | Top highlight `inset 0 0.5px 0 rgba(255,255,255,0.18)`. | A 0.5 pt `Rectangle` of white **0.12** along the top, clipped to radius 6 (`UI/Theme.swift:1448-1452`). | low |
| 23 | ShelfDropBody: caption tracking | `letter-spacing: 0.07px` at 12 px. | `Theme.tracking(forSize: 12)` = **0** (`Theme.swift:474-477`: `..<12` → 0.07, `..<15` → 0), applied at `ShelfPane.swift:556`. Caption `lineLimit(2)`. | low |
| 24 | ShelfBody: preview thumbnail shadow | `box-shadow: 0 2px 3px rgba(0,0,0,0.5)` (3 px CSS blur). | `.shadow(color: .black.opacity(0.5), radius: 3, x: 0, y: 2)` (`ShelfPane.swift:388`). A SwiftUI radius of 3 is roughly a 6 px CSS blur, so the canvas shadow is tighter. The canvas also fixes previews at 42×30; the app fits each preview to its own aspect, long side 42 (`ShelfLayout.swift:201-205`). | low |
| 25 | ClipboardBody: filter symbol `photo` and row mark `photo` (covered image) | A rounded rect with a mountain line and **no sun**. | SF `photo` (`Services/ClipboardKinds.swift:90`, `UI/ClipboardLayout.swift:209`). It has a rounded frame, a mountain and a **sun disc** top-left. | low |
| 26 | ClipboardBody: segment symbol size | 12 px SVG icons. | `.system(size: 11, weight: isSelected ? .medium : .regular)` (`ClipboardControls.swift:26-27`). | low |
| 27 | ClipboardBody: row kind marks size | 13 px SVGs (14 px for docs). | `islandFont(.reading, weight: .regular)` = **12.5 pt** regular, secondary (`ClipboardPane.swift:534-536`, `Theme.swift:540`). | low |
| 28 | ClipboardBody: denied-alert hand | Custom hand path, 20×16, stroke 1.2. | SF `hand.raised` 14 regular in `Theme.warning` #FF9F0A, frame width 20 (`ClipboardPane.swift:369-372`). This is an outline open palm; the custom path differs in shape. | low |
| 29 | ClipboardBody: empty caption width | `max-width: 360px`. | No max width, only `.padding(.horizontal, 16)` inside the list viewport (`ClipboardPane.swift:310`). At 560 the caption can run about 496 wide and may wrap differently. | low |

## Icons inventory (this area)

| Symbol | Where | Size / weight | Colour / rendering |
|---|---|---|---|
| `trash` | `UI/ShelfPane.swift:143` (Remove All in the question) | 11 regular | inherits `Theme.danger` (1.0, 0.45, 0.40), monochrome |
| `xmark.circle.fill` | `UI/ShelfPane.swift:437` (tile remove badge) | `.resizable()` 17×17 | white 0.62 over a 14 pt black 0.28 disc, monochrome |
| `tray.full` | `UI/ShelfLayout.swift:490`, drawn `:454` (Keep well) | 22 regular | white (`ShelfPane.swift:546`) |
| AirDrop image (`NSSharingService .sendViaAirDrop`) | `UI/ShelfLayout.swift:427`, drawn `:456-461` | 22×22 resizable | `.renderingMode(.original)`, full colour, never tinted |
| `dot.radiowaves.up.forward` (AirDrop fallback) | `UI/ShelfLayout.swift:410` | 22 regular | white |
| `magnifyingglass` | `UI/ClipboardControls.swift:84` (search) | 12 regular | Theme.secondary |
| `xmark.circle.fill` | `UI/ClipboardControls.swift:97` (Clear Search) | 12 regular | Theme.tertiary |
| `square.grid.2x2`, `text.alignleft`, `link`, `photo` (`doc` defined, unused: no Files segment) | `Services/ClipboardKinds.swift:87-91`, drawn `UI/ClipboardControls.swift:26` | 11; medium when selected, else regular | white when selected, else secondary |
| `text.alignleft`, `curlybraces`, `link`, `photo`†, `doc`†, `doc.on.doc`† (†covered only) | `UI/ClipboardLayout.swift:205-211`, drawn `UI/ClipboardPane.swift:534` | 12.5 regular (`.reading`) | Theme.secondary |
| `pin` / `pin.fill` (row hover) | `UI/ClipboardPane.swift:672`, `:710-711` | 11 regular | secondary, white when pinned |
| `xmark` (row hover) | `UI/ClipboardPane.swift:675`, `:711` | 9 semibold | secondary |
| `checkmark.circle.fill` (copied) | `UI/ClipboardPane.swift:652`, `:876` | 12 regular | `Color.green` resolves to #30D158 on dark; `.symbolEffect(.replace.downUp)` |
| `eye` / `eye.slash` | `UI/SpoilerField.swift:180` | 10 semibold (`.caption`) | secondary; `.replace.downUp` swap |
| `pin.fill` (image tile badge) | `UI/ClipboardPane.swift:793` | 9 regular | white on a black 0.55 circle |
| `pin` / `pin.fill`, `xmark` (image tile hover) | `UI/ClipboardPane.swift:850-861` | 10 semibold (xmark 9 semibold) | white on a 22 pt black 0.6 circle |
| `doc.on.clipboard` (empty, history off) | `UI/ClipboardPane.swift:281` | 26 regular | tertiary |
| kind symbol (kind-empty) | `UI/ClipboardPane.swift:318` | 26 regular | tertiary |
| `magnifyingglass` (no results) | `UI/ClipboardPane.swift:339` | 26 regular | tertiary |
| `hand.raised` (denied) | `UI/ClipboardPane.swift:369` | 14 regular | `Theme.warning` #FF9F0A |

No `.symbolRenderingMode`, `.symbolVariant` or palette is used anywhere in this area, so every symbol is monochrome.
Runtime system images that the canvas fakes:
- Shelf file icons (`ShelfStore.swift:771`)
- Shelf Quick Look image thumbnails (`ShelfStore.swift:322-329`, 96×96 @2x)
- the AirDrop icon
- Clipboard file icons (`ClipboardPane.swift:1108`)
- Clipboard image thumbnails

## Confirmed correct

- Shelf tile 80×94, radius 16 continuous, pitch 90/104, first row at 9.5, side margin ≥ 14 (`ShelfLayout.swift:23-34`).
- Tile plates: white 0.10 rest, 0.14 hover, 0.18 selected with a 1.5 blue ring, kept with blue 0.18 and a 2 pt ring (`Theme.swift:1154-1170`). Blue is #0A84FF (`Theme.swift:1278`).
- Badge appears on hover or selection (`ShelfLayout.swift:251`). Position 57.75/5.5, size 17, disc 14 (`ShelfLayout.swift:197-198`).
- Icon box 42 at (19,9). Name 11.5 semibold, white 0.86, tracking 0.07, line height 14, width 72 at (4, 60.4) (`ShelfLayout.swift:188-194`).
- Offline: saturation 0, opacity 0.4, caption tertiary (`ShelfPane.swift:389-390,420`, `Theme.swift:1115`).
- Preview border: white 1.5 pt, radius 2 (`ShelfPane.swift:384-385`).
- Empty line: 13 regular, white 0.55, tracking 0, padding 16 (`ShelfPane.swift:71-76`, `Theme.swift:1177`).
- Notice: 11 regular, secondary, padding 18, 14 tall, `noticeTop` formula (`ShelfPane.swift:165-174`, `ShelfLayout.swift:115-119`).
- Grid edge fade 16 (`ShelfLayout.swift:37`).
- Remove All question layout: VStack spacing 10, buttons 8 apart, padding 24, trash/text gap 5 (`ShelfPane.swift:129-151`).
- Push button: 22 tall, radius 6, padding 10, white 0.14, 11 regular with tracking 0.07; danger is rgb(255,115,102) (`Theme.swift:1097,1424-1446`).
- Drop wells: (bw−48)/2 × 114 at x 16, gap 16, top 8 in content, radius 14. White 0.07 at rest; lit is blue 0.18 with a 2 pt ring. VStack spacing 4, glyph bottom padding 4, horizontal padding 12 (`ShelfLayout.swift:505-519`, `ShelfPane.swift:542-567`).
- Drop text: title 15 semibold, tracking −0.2, white. Caption 12 regular at 0.55 rest, 0.75 lit (`ShelfPane.swift:549-557`, `Theme.swift:1172-1173`).
- Search field: 270×28 at (16,8), radius 8, white 0.10, padding 9/3, gap 6, 13 pt text. Placeholder "Search" tertiary. Ring 1.5 blue 0.70 (`ClipboardLayout.swift:134-141`, `ClipboardControls.swift:83-121`).
- Filter: from x 298 to bw−16, 28 tall, padding 2, radius 8. Well 0.08 (0.18 with Increase Contrast). Selected plate radius 6 at surfaceHover 0.26/0.38 with shadow black 0.25 r1 y1. Words 12, medium when selected, white or secondary. Symbols used below the fit width (`ClipboardControls.swift:20-50`, `ClipboardLayout.swift:145-172`).
- Rows: 30 tall, gap 4, radius 7, inset 8, mark box 20, text at 36. Well 0.08/0.18 on hover, selection or copied (`ClipboardLayout.swift:15-35`, `ClipboardPane.swift:479`, `Theme.swift:1199-1205`).
- Row text: 12.5 regular white. Code and colour use 12 monospaced. Link host is 12.5 medium white, the rest secondary. Two-part rows put the detail after two spaces in tertiary (`ClipboardPane.swift:600-639,1003-1005`).
- Swatch 14, radius 4, white 0.3 edge at 0.5. Neutral swatch white 0.18. Thumbnail 20, radius 4, edge white 0.25 at 0.5 (`ClipboardPane.swift:540-556`).
- Trailing slot: Copied is 11 medium white with gap 5. "↩ Copy" 11 regular secondary. "Pinned" and ages 11 regular tertiary. Hover buttons 22 pt, 2 apart (`ClipboardPane.swift:651-701`). Age strings match (`ClipboardKinds.swift:369-387`).
- Pinned separator: 7 tall, 1 pt hairline 0.10/0.55, inset 8 (`ClipboardPane.swift:203-209`, `ClipboardLayout.swift:39-40`).
- Covered-kind fractions: text 0.9, code 0.8, link 0.75, colour 0.3, image 0.55, files 0.6, file 0.45 (`ClipboardKinds.swift:40-50`). Covered colour shows the neutral swatch (`ClipboardLayout.swift:208`).
- Image grid: 88×66, radius 8, column pitch 100, row pitch 93. Edge white 0.2, 0.45 on hover, at 0.5. Age 10 regular tertiary. Footer 11 regular tertiary, 14 above (`ClipboardLayout.swift:88-94`, `ClipboardPane.swift:259-264,786-806`).
- Denied alert: (16, 46) at row width × 44, radius 9. Orange #FF9F0A fill 0.12, ring 0.35 at 0.5 pt. Padding 12, gap 10. Text 11 regular white. List starts 8 below (`ClipboardLayout.swift:79-84`, `ClipboardPane.swift:363-394`, `Theme.swift:1263`).
- Confirm bar: 34 tall, foot inset 8, 0.5 pt hairline inset 8, black background, gap 6. Text 11 regular secondary (`ClipboardLayout.swift:67-75`, `ClipboardPane.swift:402-424`).
- Empty and no-results text: title 13 semibold white, caption 11 regular secondary, spacing 6, glyph padding 4. Turn On button padding top 6 (`ClipboardPane.swift:280-354`).
- List fade 26 and bottom inset 10 (`ClipboardLayout.swift:48-49`).
- Secondary 0.55/0.75 and tertiary 0.50/0.65 opacities (`Theme.swift:834-851`).

---

## Audit 4: Translate, Welcome, Settings (canvas vs shipped Swift)

Swift root: `Sources/IslaKit/` in worktree `dynamic-island-upgrade-screens-e14359`. Canvas root: `scratchpad/canvas/project/`.
`Translate-States`, `Welcome-States`, `Settings-Sections` and `Settings-Changed` only import `TranslateBody`, `WelcomeBody` and `SettingsBody` (plus captions), so every finding below lives in those three body files.

Type roles (`UI/Theme.swift:521-531`): caption 10, body 11, reading 12.5, subhead 13, title 16. Default weight is medium except title, which is semibold (`:536-541`). Tracking (`:473-481`): under 12 pt 0.07, 12–15 pt 0, 15–18 pt -0.2. Opacity ramps (`:834-935`): secondary 0.55/0.75, tertiary 0.50/0.65, quaternary 0.30/0.50, surface 0.16/0.28, surfaceHover 0.26/0.38, hairline 0.10/0.55.

## Mismatches (ranked by visibility)

| # | Canvas file + element | Canvas has | App has (Swift file:line, value) | Sev |
|---|---|---|---|---|
| 1 | SettingsBody: About head icon (56 pt) and the About sidebar tile (18 pt) | Hand-drawn SVG: a #161618 rounded square with a black pill and a white dot | The real app icon at runtime, `AppIconImage(image: NSApplication.shared.applicationIconImage, side:)` (`UI/SettingsSidebar.swift:93`, sides 56 `UI/SettingsPane.swift:878` and 18). It is scaled ×1024/824 so the squircle fills the frame (`Services/AppIcons.swift:181`, `Theme.swift appIconOpticalScale`). The source is `Resources/AppIcon.icon` (Live Island A). Export it; don't redraw it. | high |
| 2 | SettingsBody: Lock Screen › Card Style, preview wallpaper | `linear-gradient(135deg, #4a6fa5, #c77d5a)`, two stops | Three bands, `#F2745A → #3F8F5B → #6F7BE8`, topLeading→bottomTrailing (`Theme.swift settingsPreviewWallpaper`, about line 1371; `UI/SettingsLockStyle.swift:121-123`) | high |
| 3 | SettingsBody: Card Style, the card material in each preview | Automatic `rgba(122,62,51,0.55)`, Tinted `rgba(122,62,51,0.30)`, Transparent black 0.40 | Automatic: coverLight #7A3E33 at 0.84, from `automaticAlpha(unknownLuminance 0.36)` (`UI/LockCardMaterial.swift:20,29,35-40`). Tinted: 0.88 (`tintedAlpha`, about line 55). Transparent: black at `transparentWash(0.36)`, at least 0.30, solved by bisection (`UI/LockCardLegibility.swift:69`). Exact value UNVERIFIED. Solid #1C1C1E matches. | high |
| 4 | SettingsBody: Music › Players on This Mac, the row icons | 18×18 grey `rgba(255,255,255,0.25)` squares, r4 | The installed app's real icon, 18 pt, optically scaled (`UI/SettingsPane.swift:1355`, `AppIconImage`; list from `icons.installedPlayers()` `:1111`) | high |
| 5 | SettingsBody: sidebar tile, Lyrics | Filled white speech bubble with **no** quote marks | `quote.bubble.fill`: a filled bubble with the quote marks knocked out, on orange #FF9F0A (`UI/SettingsTable.swift:66`; tile `UI/SettingsSidebar.swift:75-85`) | med-high |
| 6 | SettingsBody: sidebar tile, General | A circle with 8 stroked spokes, which reads as a sun | `gearshape` (toothed gear) on #8E8E93 (`UI/SettingsTable.swift:62`) | med-high |
| 7 | SettingsBody: sidebar tiles, glyph weight and size (all 7 symbol tiles) | 11 px SVGs, strokes 1.2–2.2 on a 16 viewBox (about 0.8–1.5 px drawn), so they look thin and hairline | `Image(systemName:)` at `.system(size: side*0.58 = 10.44, weight: .semibold)`, white (`UI/SettingsSidebar.swift:82-84`). Semibold SF glyphs are heavier and more solid. | med |
| 8 | SettingsBody: sidebar tile, Spotify, and the Spotify head (40 pt) | Drawn green disc rgb(29,185,84) with three dark arcs (stroke 1.5) | The real Spotify.app icon from this Mac (`InstalledAppIcon(bundleID: PlayerApp.spotify.bundleID…)` `UI/SettingsSidebar.swift:89`). The drawn `SpotifyMark` (stroke 1.6, padding 3/4, `:113-123`) appears only when Spotify is not installed. | med |
| 9 | SettingsBody: slider rows (Panel Width, Hover Delay, Lyric Delay) | Custom track: 4 px at white 0.18, fill at white 0.55, 10 px white thumb | Native `Slider` `.controlSize(.mini)`, `.tint(Theme.secondary)`, white 0.55 (`UI/SettingsPane.swift:1755-1761`). Width min 56 / ideal 130 / max 150. Real AppKit mini-slider track and knob shapes; exact pixels UNVERIFIED. | med |
| 10 | TranslateBody: "Translating…" spinner and the alert spinner | An SVG arc on a 0.25 ring, 16 px | Native `ProgressView().controlSize(.small)` (`UI/TranslatePane.swift:689`, `:801`, `:665`), which draws the system tick spinner, not an arc | med |
| 11 | TranslateBody: covered state, the dust | A static, regular 5 px grid of r0.9 dots at white 0.5 | `SpoilerField`: random seeded positions, r 0.45–0.95, alpha twinkling 0.18–1.0 ×0.85, drifting at 20 fps (`UI/SpoilerField.swift:60-108`) | med |
| 12 | TranslateBody: answer text line height | `line-height: 20.25px` (1.35×) on the answer | Only the source editor gets the 1.35 lineSpacing (`UI/TranslatePane.swift:399-400`). The answer is `.font(.system(size: 15, weight: .semibold))` at natural leading with no `.lineSpacing` (`:639`), about 18 px. | med |
| 13 | SettingsBody: Card Style ring | `box-shadow: 0 0 0 2px` accent at r7, hugging the preview | 2 pt accent stroke on a rect of radius 10 (`previewRadius + 3`), padded out by -3, so a 1 pt gap separates the ring from the preview (`UI/SettingsLockStyle.swift:61-63`). Accent #FF453A matches. | low-med |
| 14 | SettingsBody: Card Style preview marks | Cover, title, artist and scrubber track only | Also the scrubber's fill, a capsule of ink 0.9 at w×0.40 on top of the track (`UI/SettingsLockStyle.swift:178-180`), and three transport dots of ink 0.9, h×0.08, at y = h×0.78 (`:182-188`). Bars are `Capsule()`, not radius 2. | low-med |
| 15 | SettingsBody: switch, off state | Track black 0.30 with no edge (an edge only under Increase Contrast) | Black 0.30 plus a 1 pt `Theme.hairline` (white 0.10) strokeBorder when off (`UI/Theme.swift:1623-1625`) | low-med |
| 16 | SettingsBody: switch, on colour | Fixed `rgb(10,132,255)` | `Color(nsColor: .controlAccentColor)` (`UI/Theme.swift:984`), the viewer's own accent. Blue only under the default accent. | low (note) |
| 17 | SettingsBody: toggle-row icons, Volume and Brightness | A speaker with **one** wave | `speaker.wave.2` (two waves), 11 pt medium, secondary, frame 16 (`UI/SettingsTable.swift:277`; `RowIcon` `UI/SettingsPane.swift:1664-1668`) | low-med |
| 18 | SettingsBody: toggle-row icons, New Tracks | The note head is a stroked outline circle | `music.note` has a filled head (`UI/SettingsTable.swift:276`) | low |
| 19 | SettingsBody: row icons, size and weight (bolt, headphones, note, speaker, stethoscope, exclamationmark.bubble, doc.text) | 13 px SVG at stroke 1.3 | SF symbol at `islandFont(.body)`, 11 pt **medium**, secondary (`UI/SettingsPane.swift:1665`) | low |
| 20 | SettingsBody: sidebar tile, Lock Screen | A display with a filled rectangle and no shackle | `lock.display` (display with a padlock and shackle) on indigo #5E5CE6 (`UI/SettingsTable.swift:67`) | low-med |
| 21 | SettingsBody: sidebar tile, Translate | Hand-drawn 文/A strokes | SF `translate` on blue #0A84FF (`UI/SettingsTable.swift:68`) | low-med |
| 22 | SettingsBody: sidebar tile, Privacy and Screenshots | Hand-drawn outline hand and stacked photo rectangles | `hand.raised` blue #0A84FF and `photo.on.rectangle` grey #8E8E93 (`UI/SettingsTable.swift:63,70`) | low |
| 23 | SettingsBody, TranslateBody: push-button plate top highlight (Settings buttons, Quit, Paste, alert actions) | `inset 0 0.5px 0 rgba(255,255,255,0.18)` | A 0.5 pt line of white **0.12** (`UI/Theme.swift:1450`). The plate's 0.14, r6, 22 tall and 10 pt padding all match. | low |
| 24 | SettingsBody: Update Now (prominent) | weight 500 | `islandFont(.body, weight: .semibold)`, 600 (`UI/Theme.swift:1477`). Press opacity 0.7. | low |
| 25 | SettingsBody: choice row, unselected option label | White 0.50 (tertiary) | `Theme.tertiary(over: [.surface, .surface])` (`UI/SettingsPane.swift:2076`), raised until it clears 4.5:1 over the stacked fills. That works out to about **0.62**; my recomputation is UNVERIFIED to the exact percent. | low |
| 26 | SettingsBody: switch knob shadow | `0 1px 2px rgba(0,0,0,0.3)` | `.shadow(color: black 0.3, radius: 1, y: 0.5)` (`UI/Theme.swift:1631`) | low |
| 27 | SettingsBody: pop-up chevron (Translate To) | 7×11 SVG chevrons, stroke 1.5 | `chevron.up.chevron.down` at caption 10 **semibold**, secondary (`UI/SettingsPane.swift:2149-2151`) | low |
| 28 | TranslateBody: pair-bar pop-up chevrons | 7×11 SVG | `chevron.up.chevron.down`, `.system(size: 8, weight: .semibold)`, secondary (`UI/TranslateMenus.swift:146-148`) | low |
| 29 | TranslateBody: swap button | Stroked SVG, right arrow on top and left arrow below | `arrow.left.arrow.right`, 12 pt medium, secondary (`UI/TranslatePane.swift:324-326`). Which arrow sits on top in the real glyph is UNVERIFIED. | low |
| 30 | TranslateBody: Copy Translation | 12 px stroked two-squares SVG | `doc.on.doc` at `islandFont(.caption, weight: .semibold)` (10 pt), secondary. It becomes `checkmark` in `Theme.success` once copied (`UI/Confirmation.swift:69-71`). | low |
| 31 | TranslateBody: Paste button glyph | A single clipboard outline | `doc.on.clipboard` (clipboard with a document), `.system(size: 11, weight: .regular)` (`UI/TranslatePane.swift:514-515`) | low |
| 32 | TranslateBody: Clear (×) | A tertiary disc with a **black** stroked × | `xmark.circle.fill` 13 regular, monochrome tertiary (`UI/TranslatePane.swift:565-567`). The × is knocked out, so it shows the card through it, not black. | low |
| 33 | TranslateBody: Speak glyph | Custom speaker SVG with two waves | `speaker.wave.2.fill`, 12 pt medium; secondary, or white on accent #FF453A while speaking (`UI/TranslatePane.swift:770-776`) | low |
| 34 | TranslateBody: alert glyphs (download, globe, info, warn) | 20×18 SVGs, stroke 1.2 | `arrow.down.circle`, `globe`, `info.circle`, `exclamationmark.bubble` at `.system(size: 18, weight: .regular)`; secondary, or #FF9F0A for the warning (`UI/TranslatePane.swift:805-807`; `UI/TranslateLayout.swift:389-407`) | low |
| 35 | TranslateBody: source, placeholder and answer tracking | `letter-spacing: -0.2px` at 15 px | `.font(.system(size: 15…))` with no `.tracking` (`UI/TranslatePane.swift:399,478,619,639`). Per Theme's own note, SwiftUI applies no tracking table to `.system(size:)`, so this is 0. Whether browser text matches anyway is UNVERIFIED. | low |
| 36 | WelcomeBody: the four legend glyphs | Hand-drawn SVGs at 14 px, stroke 1.2–1.4 | `cursorarrow.click`, `arrow.left.and.right`, `tray.and.arrow.down` and `keyboard` at `.system(size: 14, weight: .regular)`, tertiary, frame 18 (`UI/WelcomePane.swift:174-181, 213-216`). The shapes are approximations; the canvas cursor-click is the weakest. | low-med |
| 37 | SettingsBody: Shortcuts tile and Welcome keyboard | Hand-drawn keyboard | `keyboard` (`UI/SettingsTable.swift:64`) | low |

## Icons inventory (this area)

| Symbol | Where (file:line) | Size / weight | Rendering | Colour / tile |
|---|---|---|---|---|
| gearshape | SettingsTable.swift:62 | 10.44 semibold (side×0.58, SettingsSidebar.swift:83) | monochrome | white on #8E8E93 tile, r5 continuous, 18 pt, 0.5 pt top edge white 0.25 (SettingsSidebar.swift:75-80, Theme settingsIconEdge) |
| hand.raised | SettingsTable.swift:63 | same | mono | white on #0A84FF |
| keyboard | SettingsTable.swift:64 | same | mono | white on #8E8E93 |
| music.note | SettingsTable.swift:65 | same | mono | white on #FF375F (`rose`) |
| quote.bubble.fill | SettingsTable.swift:66 | same | mono | white on #FF9F0A |
| lock.display | SettingsTable.swift:67 | same | mono | white on #5E5CE6 |
| translate | SettingsTable.swift:68 | same | mono | white on #0A84FF |
| photo.on.rectangle | SettingsTable.swift:70 | same | mono | white on #8E8E93 |
| (Spotify app icon) | SettingsSidebar.swift:89 | 18 / 40 pt | runtime NSWorkspace image | fallback `SpotifyMark` #1DB954 + ink #191414 |
| (Isla app icon) | SettingsSidebar.swift:93 | 18 / 56 pt | runtime `applicationIconImage` ×1.2427 | n/a |
| bolt, headphones, music.note, speaker.wave.2 | SettingsTable.swift:274-277 | 11 medium (`RowIcon`, SettingsPane.swift:1664-1668) | mono | secondary, frame 16 |
| stethoscope, exclamationmark.bubble, doc.text | SettingsTable.swift:278-280 (SettingsIcon.swift:116-117) | 11 medium | mono | secondary |
| xmark.circle | SettingsPane.swift:1145 (`SettingsIcon.dismiss`) | 11 medium | mono | secondary |
| minus / plus (Lyric Delay steppers) | SettingsPane.swift:1938-1941 | 8 bold | mono | white, 22 pt `NotchButtonStyle` |
| chevron.up.chevron.down (Settings pop-up) | SettingsPane.swift:2149-2151 | 10 semibold | mono | secondary |
| (installed player icons) | SettingsPane.swift:1355 | 18 pt | runtime | n/a |
| chevron.up.chevron.down (Translate pop-ups) | TranslateMenus.swift:146-148 | 8 semibold | mono | secondary |
| arrow.left.arrow.right | TranslatePane.swift:324-326 | 12 medium | mono | secondary |
| doc.on.clipboard (Paste) | TranslatePane.swift:514-515 | 11 regular | mono | white (push plate) |
| xmark.circle.fill (Clear) | TranslatePane.swift:565-567 | 13 regular | mono | tertiary |
| speaker.wave.2.fill (Speak) | TranslatePane.swift:770-772 | 12 medium | mono | secondary, white on #FF453A plate r7 while speaking |
| doc.on.doc / checkmark (Copy) | Confirmation.swift:69-71 | 10 semibold | mono | secondary / Theme.success |
| lock.fill / globe (origin) | TranslatePane.swift:737-749 | 9 regular | mono | tertiary |
| arrow.down.circle, globe, info.circle, exclamationmark.bubble (alert) | TranslateLayout.swift:389-407; TranslatePane.swift:805-807 | 18 regular | mono | secondary; warning #FF9F0A |
| cursorarrow.click, arrow.left.and.right, tray.and.arrow.down, keyboard | WelcomePane.swift:174-181, 213-216 | 14 regular | mono | tertiary, frame 18 |

No `.symbolRenderingMode`, `.symbolVariant` or palette is used anywhere in these panes; every symbol is monochrome through `foregroundStyle`.

## Confirmed correct

- The five section tints match `Theme.SettingsTint` hex exactly: #8E8E93, #0A84FF, #FF375F, #FF9F0A, #5E5CE6 (`UI/Theme.swift:1272-1290`).
- Sidebar tile: 18 pt, r5, 0.5 pt top edge at white 0.25. Row: 122×24, pitch 26, label 12.5 at medium/regular, selected fill white 0.12/0.24, r6 (`UI/SettingsLayout.swift:28-46`, `UI/SettingsSidebar.swift:36-48`).
- Divider at x 143, 0.5 pt, hairline (`UI/SettingsPane.swift:389-392`).
- Group: r9, fill 0.055/0.14, 0.5 pt edge 0.06; rows 28; hairline inset 10 at 0.5 pt (`UI/SettingsPane.swift:556-572`).
- Header: 12.5 semibold, white 0.85/1.0, 2 pt leading, 4 pt bottom (`UI/SettingsPane.swift:510-515`).
- Footnote: 10 regular, tertiary, 10 pt inset, -2 top, 8 bottom (`UI/SettingsPane.swift:521-528`).
- Switch geometry: 30×17 track, 13 pt knob, black-0.30 well, 0.7 outline under Increase Contrast (`UI/Theme.swift:1008-1021`).
- Choice row capsules: 11 medium, 9/3 padding, r6, selected surfaceHover; group r8 surface (`UI/SettingsPane.swift:2065-2101`).
- Pop-up plate: 11 medium white, 8/3 padding, r6, surface (`UI/SettingsPane.swift:2144-2155`).
- Shortcut well: 96×20, r6, surface, 1 pt hairline, 11 medium (`UI/ShortcutRecorder.swift:42-56`).
- Slider value: 10 pt monospacedDigit, tertiary, width 38/52 (`UI/SettingsPane.swift:1742-1746`).
- Push button: white 0.14 plate, 22 tall, r6, 10 pt padding, 11 regular (`UI/Theme.swift:1421-1452`).
- Spotify head: 13 semibold; status 12.5, #30D158 or secondary (`UI/SettingsPane.swift:858-865`).
- About head: 16 semibold; version 12.5 secondary; 12 pt gap (`UI/SettingsPane.swift:877-887`).
- Update card: 13 semibold title, 12.5 secondary subtitle, group fill (`UI/UpdateCard.swift:64-97`).
- Quit row: 10 pt tertiary line and a push button (`UI/SettingsPane.swift:900-910`).
- Preview geometry: 80×52 shrinking to fit, r7, 0.5 pt edge white 0.2, labels 11 medium/regular, white/secondary (`UI/SettingsLockStyle.swift:64-69`).
- Preview edges on Solid and Transparent only; Solid #1C1C1E (`UI/SettingsLockStyle.swift:132-137`).
- Translate pair bar: 26 tall, 9/6 padding, white 0.12/0.24 plate with a 0.12 top line, 11 regular (`UI/TranslateMenus.swift:138-162`; `Theme.swift popUpOpacity`).
- Translate cards: r14, white 0.07/0.16, 0.5 pt edge 0.08/0.35 (`UI/TranslatePane.swift:349-353`; `Theme.swift translateCard*`).
- Source 15 medium white; placeholder 15 regular tertiary; "Translation" 15 regular quaternary; answer 15 semibold (`UI/TranslatePane.swift:399,478,619,639`).
- Counter: 10 pt monospacedDigit, quaternary (`UI/TranslatePane.swift:553-556`).
- Footer: speak plate 26×24 r7, footer spacing 4, origin 6 pt leading, 10 pt tertiary (`UI/TranslateLayout.swift:60-61`; `UI/TranslatePane.swift:723-751`).
- Alert: message 12.5 white, 8 pt stack spacing (`UI/TranslatePane.swift:796-816`).
- History: "Recent" 11 semibold secondary; rows 40 tall with 8 pt inset; source 12.5 medium; result 11 secondary; pair 10 semibold, tracking 0.4, tertiary; age 10 tertiary; hover well 0.08/0.18 at r7; hairline rule (`UI/TranslatePane.swift:872-1027`).
- Welcome: columns (20 pt margins, 16 pt gap, 0.55 share); legend 11 regular secondary; "Isla is running." 16 semibold; come-back line 11 secondary; note 10 tertiary; Get Started 11 medium in a surfaceHover capsule with a 1 pt hairline and 14/6 padding (`UI/WelcomePane.swift:147-261`; `UI/Theme.swift:1508-1528`).

---

## Audit 5: lock card and menus, canvas against Swift

Read-only. Swift paths are relative to `Sources/IslaKit/`. Canvas files are in `scratchpad/canvas/project/`.
`islandFont(role)` with no weight uses the role's own weight. That is **medium** for every role except `title`, which is semibold (Theme.swift:532-537). Role sizes: caption 10, body 11, reading 12.5, subhead 13, title 16, display 21, hero 28 (Theme.swift:521-530).

## Mismatches

| # | Canvas file and element | Canvas has | App has (file:line, value) | Sev |
|---|---|---|---|---|
| 1 | LockCard: foot rail, right button (output) | Hand-drawn speaker with two waves | `outputSymbol` is the current device's symbol, from `AudioOutputs.symbol(outputs:current:fallback: "airplayaudio")` (LockScreenCard.swift:1515-1516). For "MacBook Pro Speakers", the device the canvas marks as current, it is **`laptopcomputer`** (AudioOutputs.swift:150,155). 13 pt medium, cardSecondary (LockScreenCard.swift:1489-1490) | high |
| 2 | LockCard: Sound pane, every output row's glyph | The same generic speaker on every row | Each row draws `device.symbol` (LockScreenCard.swift:1259): `laptopcomputer` for built-in speakers, `airpods.pro` for AirPods Pro, `display` for Studio/Pro Display, `tv` for HDMI/DisplayPort, `airplayaudio`, `headphones`, `speaker.wave.2` for USB (AudioOutputs.swift:134-166). Body 11 **medium** (no weight given) | high |
| 3 | LockCard: foot rail, left button (Lyrics) | Speech bubble with two text lines inside (reads as `text.bubble`) | `quote.bubble`, which has quotation marks, not lines (LockScreenCard.swift:1435). 13 pt medium, cardSecondary | high |
| 4 | LockCard: Lyrics pane, Hide Lyrics button | White filled bubble with two **black** lines painted on it | `quote.bubble.fill` (LockScreenCard.swift:1009): quotation marks knocked out of the fill, so the well shows through them. They are not black. White, on a cardFill well (0.16, or 0.28 with Increase Contrast). With Increase Contrast it also gets a 1 pt cardHairline ring (LockScreenCard.swift:1463-1469, 1495-1505) | med |
| 5 | Light-Menus / LightMenu `output`: current device disc | `#ff3b30` (light systemRed) | `Theme.accentNSColor` sRGB 255,69,58 = **#FF453A**, fixed and not appearance-aware (OutputMenu.swift:136, Theme.swift:687) | med |
| 6 | Light-Menus / LightMenu `output`: other device discs | `rgba(0,0,0,0.30)`, caption says "a darker disc" | `NSColor.white.withAlphaComponent(0.16)` on every appearance (OutputMenu.swift:136). Over a light menu that is an almost invisible pale disc, not a dark one. The glyph is white palette, 13 pt medium (OutputMenu.swift:132-133), so on a light menu the white glyph sits on near-white | high |
| 7 | Light-Menus / LightMenu `output`: device glyphs | Hand paths for laptop, headphones, speaker; Studio Display drawn as a speaker | SF Symbols from `device.symbol`: `laptopcomputer`, `airpods.pro`, and **`display`** for "Studio Display" (AudioOutputs.swift:135,140,150). 13 pt medium white, in a 26 pt disc image (OutputMenu.swift:91, 127-149) | med |
| 8 | Light-Menus (all 10 tiles): appearance | Light menu chrome | The menus are popped up inside views of the notch panel, and `NotchPanel` forces `appearance = NSAppearance(named: .darkAqua)` (NotchPanel.swift:400). Pop-up sites: `menu.popUp(positioning:at:in: rootView)` (NotchController.swift:887), `in: anchor` (TranslateMenus.swift:80, LyricHeaderTools.swift:178-186, OutputMenu.swift:175). SwiftUI `.contextMenu` (ClipboardPane.swift:488, ShelfPane.swift:290) is in the same panel. The code comments say "system's own appearance, nothing forced" (OutputMenu.swift:80, LyricHeaderTools.swift:113), but an NSMenu with a nil appearance usually takes the effective appearance of the view it pops up in. So on a light-mode Mac these menus may well render **dark**. **UNVERIFIED**: needs one look on hardware | high (if true) |
| 9 | LightMenu: selection highlight | `#0a84ff` on both appearances | That is dark-mode systemBlue. Light-mode systemBlue is #007AFF, and AppKit draws the menu selection from the user's accent / `selectedContentBackgroundColor`. The app sets no colour (no code). Exact Tahoe value **UNVERIFIED** | med |
| 10 | LockCard (all materials): card rim | `inset 0 0 0 1px rgba(255,255,255,0.14)` plus a top `inset 0 1px 0 rgba(255,255,255,0.30)` | Drawn glass is a 1 pt **gradient** stroke, top to bottom: white **0.72 → 0.20 → 0.08** (GlassSurface.swift:30, 323-333). The top edge is much brighter than the canvas draws it | med |
| 11 | LockCard: Solid / Transparent rim | 0.14 (0.55 with Increase Contrast), 1 px | Opaque route: 1 pt white **0.18**. With Increase Contrast: **1.5 pt white 0.85** (GlassSurface.swift:288-291) | low |
| 12 | LockCard: Increase Contrast on Automatic/Tinted | Rim stays 0.14 / 0.30 | **1.5 pt white 0.85** stroke replaces the gradient rim (GlassSurface.swift:320-321) | med |
| 13 | LockCard: base under the cover light | `rgba(0,0,0,0.20)` with `backdrop-filter: blur(30px) saturate(1.4)`, which blurs the wallpaper | The drawn recipe has no backdrop when there is artwork (`samplesBackdrop: !solid && !hasArtwork`, LockScreenCard.swift:212). No window above the shield gets a blur. The recipe is a horizontal black gradient **0.34 → 0.16**, a white sheen 0.10 → 0.03, a plus-lighter specular band (white 0.14 at 16 %) and grain 0.035 overlay (GlassSurface.swift:41, 96, 115, 49). The 8-16 % of wallpaper that shows through is **unblurred** | med |
| 14 | LockCard: cover light | Flat 145° gradient from `tint` to `#2a1a3a` | The real artwork scaled ×1.5, `blur(radius: 44, opaque: true)`, `saturation(1.3)`, under the solved black wash and a top-to-bottom gradient from clear to black 0.22 (LockScreenCard.swift:488-507, LockCardLegibility `coverZoom` 1.5). It is a runtime image, faked by the canvas. Without a cover it is #1C1C1E at the same alpha (`neutralFill`, LockScreenCard.swift:478-485), and the canvas has no such state | med |
| 15 | LockCard: shadow under the marks | CSS `text-shadow` on text only. SVG icons, bars and the ring get none | One `.shadow(black × 0.35/0.5/0, radius 3, y 1)` on the whole shape content (LockScreenCard.swift:420), so every glyph, bar and the ring carries it. CSS blur equivalent of SwiftUI radius 3 is **UNVERIFIED** (likely about 6 px) | med |
| 16 | LockCard: source badge on the 64 pt cover | 20×20 **#000** circle with "S", 10 px / 700 | Primary: the source app's real icon, 20×20, with a `shadow(black 0.45, r 2, y 1)` (LockScreenCard.swift:1126-1130). This is a runtime image, faked. The letter is only a fallback: **17×17** circle, black **0.75**, 0.5 pt cardHairline, caption 10 bold (LockScreenCard.swift:1133-1138) | med |
| 17 | LockCard: big transport | SVG approximations: skip glyphs 22×14, pause 22×26 with rx 2 bars | `backward.fill` / `forward.fill` at display **21 pt medium**, `pause.fill` / `play.fill` at hero **28 pt medium**, each in a 36 pt target, white (LockScreenCard.swift:1398, 1408, 1416; ModeToggle.swift:57-60). Exact glyph metrics **UNVERIFIED**. Skip buttons drop to opacity 0.35 when the player cannot skip (LockScreenCard.swift:1402,1420), which the canvas does not show | med |
| 18 | LockCard: lyrics-pane small transport | Skip glyphs 14×9, pause 12×14 | `backward.fill` / `forward.fill` subhead **13 medium**, play/pause title **16 semibold**, three 24 pt targets, HStack spacing 2 (LockScreenCard.swift:1018-1036) | low |
| 19 | LockCard: banner ring glyph | Pause bars 3.4×11 and a play path | `pause.fill` / `play.fill` subhead **13 medium** white (LockScreenCard.swift:677-679) | low |
| 20 | LockCard: heart | Hand path, 1.6 stroke | `heart` / `heart.fill`, title **16 medium**, 28×28 frame. Off is cardSecondary, on is white. Before the library answers, a dimmed heart at opacity **0.45** and disabled (LockScreenCard.swift:1535-1543). The canvas has no 0.45 pending state | low |
| 21 | LockCard: chevrons | Hand SVG chevrons, 1.6 stroke | `chevron.up` (player) and `chevron.left` (lyrics, output), caption **10 semibold**, cardSecondary on a cardFill 24 pt circle (LockScreenCard.swift:718-722, 740, 838, 1189) | low |
| 22 | LockCard: rail volume glyphs | 9×9 speaker, 12×9 speaker with stroked waves | `speaker.fill` (`speaker.slash.fill` when muted) and `speaker.wave.3.fill`, caption **10 regular**, cardSecondary, spacing 8 (SystemVolumeSlider.swift:227-251, 267). No muted state on the canvas | low |
| 23 | LockCard: Sound pane volume | Glyphs 12×12 and 14×11. Knob shadow `0 1px 3px rgba(0,0,0,0.35)` | Glyphs body **11 regular**, each in a **12 pt** slot (SystemVolumeSlider.swift:216, 234-252). Knob 14 pt white, `shadow(black 0.5, r 3, y 0.5)` (SystemVolumeSlider.swift:214, 287). Muted: the fill becomes the track colour and the knob drops to 0.6 | low |
| 24 | LockCard: Sound pane rows | No hover or press state | Rows highlight on a radius-**9** rounded rect, white 0.10 on hover and 0.16 pressed, inset 8 (ModeToggle.swift:79-83) | low |
| 25 | LockCard: lyric translation tracking | 0 px on all translation sizes | `islandFont` applies `tracking(forSize:)`, so the 11 pt row gets **+0.07** (Theme.swift:475; LockScreenCard.swift:815) | low |
| 26 | LightMenu: menus with no checkmark (island, clipboard, shelf) | Title starts at 10 px from the row edge, no state column | NSMenu and SwiftUI context menus reserve the state column on macOS by default, so titles are indented by it. Tahoe behaviour **UNVERIFIED** | med |
| 27 | LightMenu: destructive items ("Clear Everything…", "Remove from Shelf") | Normal label colour | `role: .destructive` (ClipboardPane.swift:975, ShelfPane.swift:305). Whether macOS 26 draws these red in a SwiftUI context menu is **UNVERIFIED** | low/med |
| 28 | LightMenu: Translate From/To placement | Menu placed at fixed offsets | `popUp(positioning: selected, …)`: a pop-up-button menu, opened with the **checked item over the control** (TranslateMenus.swift:80) | low |
| 29 | LightMenu: Lyrics More icons | Hand paths: shuffle, repeat, minus, plus, pencil, a circle with minus, a doc with an inner plus, an arrow loop | SF Symbols via `NSMenuItem.image`: `shuffle`, `repeat`, `minus`, `plus`, `pencil`, `minus.circle`, **`doc.badge.plus`** (the plus is a badge outside the bottom-right corner, not inside the page), `arrow.clockwise` (LyricHeaderTools.swift:95-102, 131). They are template images at AppKit's menu size, with no configuration | med |
| 30 | LockScene: card position | Card top at 190 in a 580 px scene | The lock window is centred on the screen vertically and horizontally (LockCardWindow.swift:53-59). The banner hangs at the top of that window (LockCardLayout `shapeFrame` y 0) | low |
| 31 | LightMenu: key equivalents | 13 px, letter-spacing 1 px, secondary colour | AppKit draws them from `keyEquivalent` + `keyEquivalentModifierMask` (IslandMenu.swift:141-144) and SwiftUI `.keyboardShortcut` (ClipboardPane.swift:961, ShelfPane.swift:294-306). The 1 px tracking and the exact colour are AppKit's own. **UNVERIFIED** | low |

## Icons inventory

| Symbol | Where (file:line) | Size / weight | Rendering / colour |
|---|---|---|---|
| `pause.fill` / `play.fill` | banner ring, LockScreenCard.swift:677 | subhead 13 / medium | white, monochrome, `symbolSwap` |
| `pause.fill` / `play.fill` | big transport, :1407 | hero 28 / medium | white (TransportGlyphStyle, ModeToggle.swift:57) |
| `backward.fill`, `forward.fill` | big transport, :1398, :1416 | display 21 / medium | white; 0.35 when the player cannot skip |
| `pause.fill` / `play.fill` | small transport, :1028 | title 16 / semibold | white |
| `backward.fill`, `forward.fill` | small transport, :1020, :1036 | subhead 13 / medium | white; 0.35 when the player cannot skip |
| `chevron.up` | Collapse, :740 (drawn :718) | caption 10 / semibold | cardSecondary on a cardFill circle |
| `chevron.left` | Back, lyrics :838, output :1189 | caption 10 / semibold | the same |
| `heart` / `heart.fill` | :1535 | title 16 / medium | cardSecondary / white; 0.45 while pending |
| `quote.bubble` | rail Lyrics, :1435 (drawn :1488) | subhead 13 / medium | cardSecondary (white when open) |
| `quote.bubble.fill` | Hide Lyrics, :1009 | subhead 13 / medium | white on a cardFill well |
| `laptopcomputer` / `airpods.pro` / `airpods` / `airpods.max` / `beats.headphones` / `homepod` / `appletv` / `display` / `headphones` / `hifispeaker` / `airplayaudio` / `tv` / `speaker.wave.2` / `waveform` | rail output button :1446/1516 (fallback `airplayaudio`); Sound rows :1259; AudioOutputs.swift:134-166 | rail: subhead 13 / medium. Rows: body 11 / medium | rail: cardSecondary. Rows: white on #FF453A (current), or cardTertiary on cardFill |
| `checkmark` | Sound row, :1272 | caption 10 / semibold | white |
| `music.note` | cover placeholder, :610 | side/3, light | cardTertiary on cardFill |
| `speaker.fill` / `speaker.slash.fill` | SystemVolumeSlider.swift:233-238 | card: caption 10 / regular. Sound: body 11 / regular | cardSecondary |
| `speaker.wave.3.fill` | SystemVolumeSlider.swift:250 | the same | cardSecondary |
| `minus`, `plus`, `pencil`, `minus.circle`, `doc.badge.plus`, `arrow.clockwise`, `shuffle`, `repeat` | Lyrics More, LyricHeaderTools.swift:95-102, set at :131 | AppKit menu default (no config) | template, follows the menu |
| device symbol (above) | Output menu, OutputMenu.swift:128-133 | 13 / medium in a 26 pt disc image | palette white, non-template image; disc #FF453A or white 0.16 |
| `speaker.wave.2.fill` | Output menu fallback, OutputMenu.swift:130 | 13 / medium | palette white |
| Open With app icons | ShelfPane.swift:486-488 | runtime `NSImage` | runtime, not on the canvas |
| Island, Clipboard row, Shelf tile, Translate, Lyrics Translate menus | IslandMenu.swift:129-148; ClipboardPane.swift:957-977; ShelfPane.swift:290-307; TranslateMenus.swift:33-54; LyricHeaderTools.swift:359-385 | none | no images. Text, state checkmarks and key equivalents only |

## Confirmed correct

- Banner 360×64 r22; card 460×300 r30 / 420×236 r28 (LockCardLayout.swift).
- Header type: banner title 13 semibold / artist 11 regular; card 16 semibold (−0.2) / 13 regular; lyrics pane 13 / 11 (LockCardLayout header, LockScreenCard.swift:541-552).
- Card ramp: secondary 0.75/0.85, tertiary 0.62/0.75, fill 0.16/0.28, track 0.22/0.36, hairline 0.25/0.55 (Theme.swift:1044-1078).
- Seek row: caption 10 medium monospacedDigit, +0.07 tracking, cardTertiary, 4 pt track, fill white 0.9, min widths 26 and 30 (LockScreenCard.swift:1331-1381).
- Lyric ramp on the card: floor 0.50 (0.62), neighbour = tertiary, unswept = secondary; rows 16 bold, 19 tall, spacing 7; translated pitch 44 / +10 (LyricRow.swift:159-174, LockCardLayout).
- Translation type: sung 12.5 medium secondary, others 11 regular tertiary (LockScreenCard.swift:813-816).
- Accent = white for sweep and seek; output selection = #FF453A (LockScreenCard.swift:320, Theme.swift:686).
- Solid = #1C1C1E (Theme.swift:782-788); text-shadow 0 / 0.5 / 0.35 by layer (LockCardMaterial textShadowOpacity).
- The Automatic alpha formula, the Tinted 0.88, the Transparent solved wash with a 0.30 floor and Increase Contrast making it Solid, and the cover wash floor 0.34/0.56 all match LockCardMaterial / LockCardLegibility.
- Wash layer order: cover, then the solved black wash, then the 0 → 0.22 gradient on top.
- Cover shadow black 0.4 r8 y3; cover radii 10 / 10 / 8.
- Sound pane: "Sound" 16 semibold, "Output" 11 semibold secondary, 8 pt track / 14 pt knob, 26 pt circles, 36 pt pitch, half-row cut, name 13 semibold/regular (LockScreenCard.swift:1184-1290).
- Rail card volume: 4 pt track, fill white 0.8, no knob, 12 pt padding (SystemVolumeSlider.swift:267; LockScreenCard.swift:1440-1441).
- Island menu items, order, ⌃⌥⌘ shortcuts, Lyrics disabled without a song (IslandMenu.swift:34-46).
- Clipboard row entries and the ⌘C shortcut (ClipboardPane.swift:937-948, 961).
- Shelf tile menu: disabled header, ⌘Y/⌘C/⌘R/⌫, separators, Open With submenu disabled offline (ShelfPane.swift:290-307, 477-492).
- Translate From/To entries: Detect, Recent (3), On this Mac, Translation Languages…, (Online) suffix, localized sort (TranslateLayout TranslateMenuModel; TranslationLanguage.swift:60-63).
- Lyrics More entries and order, min width 244; Lyrics Translate entries, min width 214, provenance disabled (LyricsPageModel.swift:109-150; LyricHeaderTools.swift:82, 348).
- Output menu: "Output" section header, current device first with a checkmark, Sound Settings…, min width 262 (OutputMenu.swift).
- Section headers are `NSMenuItem.sectionHeader` in every NSMenu that has one.
- Every Russian menu string in the LightMenu TABLE matches Resources/ru.lproj/Localizable.strings.


---

# Second pass: self-review against the code and the running app (2026-10-20, evening)

The first pass above was fixed and published as versions 54–57 (real SF Symbols exported from macOS as
vectors, runtime icons taken from a real Mac, the bodies clipped to the island's rounded bottom). The owner
saw no issue at a glance and asked for a second look at every detail. Five Opus reviewers took one area
each, again against `Sources/IslaKit` at origin/main c38ea2a (`./scripts/source-fresh.sh`: FRESH), and this
time also against screenshots of the installed Isla on the owner's MacBook Pro (Dark appearance, panel
width 480, Spotify): the player, the Shelf with 60 files, Clipboard, Translate, Settings › General and the
right-click menu. Where a screen showed the owner's settings rather than the defaults, the code won.

They found 112 further mismatches, 12 of them high, and fixed every one that a file:line could settle.
Published as versions 59–60. Highlights:

- **Menus are dark on every Mac.** The canvas, the spec (§13 "Menus follow the system appearance") and
  two code comments (OutputMenu.swift:80, LyricHeaderTools.swift:113) all said menus follow the system.
  They do not. An `NSMenu` with no appearance of its own takes the effective appearance of the view it
  pops up in, and every menu in the app pops up in a `NotchPanel` view (the lock card's window is one
  too, LockCardWindow.swift:224), which forces `.darkAqua` (NotchPanel.swift:400). Measured: a test
  panel forced to `.aqua` on a Dark Mac popped a Light menu, and one forced to `.darkAqua` popped a dark
  one; the real right-click menu over the island is dark. The "Light menus" board is now "Menus: dark on
  every Mac", its ten menus redrawn dark, and the spec carries a dated amendment.
- **The island's stroke was half hidden.** The 2 pt line was drawn under the bodies, so their black
  covered its inner half. The app lays the stroke over the content (NotchStage.swift:18, 52). The shadow
  is cast by the fill only, at about 28 px CSS blur for a Core Animation radius of 14 (measured σ ≈ 13.5).
- **A sung line is lit whole, not swept,** while Word Karaoke is off (its default):
  `LyricSweep.drawnFraction`. Both the player and the stage drew it half swept.
- **Clipboard's first row is always the selection** (lit, "↩ Copy" in place of its age) until the arrows
  move it (ClipboardBrowser.swift:82-86), as the running app shows. The canvas never drew it.
- **Settings › Lyrics:** with Show Lyrics off (the default) its dependent rows are dimmed to 0.4
  (SettingsPane.swift:603 and on), and the Translation footnote was missing. Russian Settings is now
  generated from the English script and a 129-entry table from ru.lproj, so the two cannot drift.
- **Translate's result side has no card** (TranslatePane.swift:343-353); only the source card has a fill
  and an edge. Welcome in Russian had two English strings.
- **The lock screen's island rests** while the card holds the song (LockedIsland.swift), and the card's
  rail speaker was an empty symbol.
- **The star** shows only for Apple Music or a connected Spotify account; the Surface board's Spotify and
  unknown sources now draw none, as the owner's Mac does.
- **Tokens board:** the switch colour is the Mac's accent (`NSColor.controlAccentColor`; the owner's is red),
  not a fixed blue; page sizes include the 16 pt dots band (player 357.4 × 214); about ten missing
  contrast pairs, colours and radii added; the board grew to 3040 pt, since its bottom was clipped.

Tooling fault found on the way: the PDF-to-SVG converter that turns exported symbols into vectors dropped
a compressed stream's last byte whenever that byte was 0x0D, which left `speaker.wave.3.fill` at 10 pt
empty. It now reads exactly `/Length` bytes; the library holds 162 symbols, none empty.

**Not fixable on a canvas,** and stated in the canvas notes: `.continuous` (squircle) corners are drawn
as circular CSS corners; macOS 26 `glassEffect` is approximated; SwiftUI's `.gradient` stops are not
published; springs, the marquee and the spinners do not move; cover art and Quick Look thumbnails are
placeholders; the no-notch island's height depends on the Mac's menu bar.

**Left for the app, not the canvas:** in Russian the player's reader-down footnote and the Music Only
headline are cut by the app itself; the Shelf's place names and file sizes follow the system's language
and region, not the app's; the two code comments above still say menus follow the system.

**States listed, not drawn** (no free grid cell): the update alert while downloading, failed, manual
and restart-needed; covered and copied image tiles in Clipboard; the AirDrop-lit drop well; the lock
card with no cover, no output devices, muted, and its Copy Line menu.

The five reviewers' reports follow, as written (S = the session scratchpad, W = this worktree).


---

## Pass 2, Reviewer 1: island, shell, Surface, Main tokens board

Source: W/Sources/IslaKit at c38ea2a (FRESH; no Sources change since a092542). Checked the screens in S/real/ (top, p1, p2, p4, p5, m1). I did not open p3 and quote nothing from it. Every edited file passed the node harness (S/review/r1/check.js). It ran renderVals for every enum option crossed with each boolean, every int/range at its min and max, and the no-notch/ru/480 combination: Island 122 combos, Surface 710. Result: no undefined hole, no NaN or null, tags balanced, no data: URI, no `style` prop, support.js line intact. No prop renamed and no default changed.

## Findings

| Board / element | Canvas had | App has (file:line) | Sev | Fixed? |
|---|---|---|---|---|
| Surface: island stroke | Stroke in the same svg as the fill, **under** the body. The bodies' black roots covered the inner 1 pt, so only half of the 2 pt line showed | Stroke layer drawn **over** the content (`Notch/NotchStage.swift:18,52`; `UI/NotchContentView.swift:483-499`). The capture p1/p2 shows the full 2 pt line | HIGH | yes: separate stroke svg after the body |
| Island: stroke | Same order (under the content) | Same | MED | yes |
| Island + Surface: shadow | `drop-shadow(0 0 14px)`, and it was cast by the stroke too | CA `shadowRadius 14` on the fill layer only (`Notch/IslandOutlineHost.swift`, init: shadowPath = fill). I measured CALayer radius 14 rendered: Gaussian σ ≈ 13.5, and CSS σ = blur/2, so about 28 px | MED | yes: 28 px, fill only |
| Island: cover edge | `inset` 0.5 box-shadow, painted under the well (so hidden under a real cover) | 0.5 pt stroke, centred on the rounded rect, in an overlay **above** the picture and outside the clip (`UI/NotchContentView.swift:1200-1204`) | LOW | yes: overlay ring at -0.25 |
| Island: music states | A missing-cover well with **coral** bars. The app never draws this combination | With no artwork the tint is `CoverTint.fallback` grey 0.82 (`Services/CoverTint.swift:34,168`; `Model/NotchViewModel.swift:905`) | MED | yes: new prop `artwork` (default true). True draws the cover as a swatch of its tint. False draws the well and note, with bars at #D1D1D1 |
| Island: battery on a short island | Fixed 28×16, r6, cap 2×6, gap 1.5 | Every part × glyphScale 0.75 (`UI/IslandBattery.swift`, `UI/NotchContentView.swift:791,815`) | MED (no-notch) | yes |
| Island: update title and detail | Unbounded, no truncation | `frame(width: textWidth)`, tail truncation (`UI/UpdateAlertView.swift:41-46,79-84`; `Notch/ExpandedAlertShape.swift` `textWidth`) | LOW | yes |
| Island: volume title and device name | `overflow:hidden` at line-height 1 clipped descenders (the "p" in "MacBook Pro Speakers") | No clipping of glyphs | LOW | yes: padding-bottom 0.25em inside the clip |
| Island: peek text, no notch | Always the wing rule | `islandWidth - leading - 34` when not physical (`Notch/CompactIslandLayout.swift` `peekTextWidth`) | LOW | yes |
| Surface: Remove All width | "All" at 17 | `ceil` of NSString width at 13 medium = 16 (measured 15.79). Russian "Все" 24 is correct (`UI/ShelfLayout.swift:178-183`) | LOW | yes |
| Edge-NoNotch: synthetic notch | `notch-w 180` | `syntheticNotchWidth = 200` since 2026-10-15 (`Notch/NotchGeometry.swift:162`) | MED | yes: all 8 imports |
| Main: subtitle | a092542 | c38ea2a; same Sources | LOW | yes; also notes that CSS corners are circular |
| Main: page sizes | Player "425.4 x 198"; Shelf/Clipboard/Translate "panel width x 300" | 357.4 × 214 and width × 316: the 16 pt dots band is part of the body (`Model/Surface.swift` `SurfaceLayout.bodySize`, `pageDotsBand`) | MED | yes |
| Main: caption role sample | "Tab titles…" | There are no tabs since R8 | LOW | yes: "Counters, scrubber times, section headers, footnotes" |
| Main: subhead sample | "Header titles" | Header titles are 13 **semibold** (`UI/SurfaceHeader.swift` `SurfaceHeaderTitle`), not subhead medium | LOW | yes: own "header title" row added; subhead sample is now the code's |
| Main: motion "open 0.34" / "expand 0.40" | Read as the open and the body growing | The outline opens and grows on `islandSpring`. 0.34 is only the player layout change, 0.40 only the Settings update card (`UI/Theme.swift:51-55,214-219`) | MED | yes, relabelled. Added the artwork fade, the swap scales 0.97/0.98, the pop-up's 0.94, and the pointer open/close delays 0.05/0.32 |
| Main: ramp incomplete | 14 pairs | Added clipboard well 0.08/0.18, search 0.10/0.20, translate card 0.07/0.16 and edge 0.08/0.35, pop-up 0.12/0.24, settings group 0.055/0.14 and edge 0.06/0.55, sidebar selection 0.12/0.24, group header 0.85/1.0 (`UI/Theme.swift:1199-1346`). Grid is now 6 columns | LOW | yes |
| Main: colours | Switch on was shown only as "Switch on"; no-cover tint, switch well, recording ring, find text and Spotify fallback were missing | `switchOnFill = controlAccentColor` is the **system accent** (red on the owner's Mac per p5; #0A84FF only as macOS's default) (`UI/Theme.swift:984`). Also `CoverTint.fallback`, `switchWellOpacity` black 0.30/0.50, `recordingFill` accent 0.18 with a 1.5 ring, `findHighlightText` #1D1D1F, `spotifyMark` #1DB954/#191414. Accent #FF453A is fixed, never the system accent; the Shelf/update blue is fixed SettingsTint.blue | MED | yes |
| Main: radii and sizes | Bubble, short cover, header button and push button were missing; the no-notch island, the 0.75 glyph scale, Welcome 208 and the dots centre were missing | `IslandBubbleLayout` 8.67/14, 58 +8 per digit, 16 gap; cover 16 r4; tool button 26 r8; push button 22 r6; `syntheticNotchSize`; `glyphScale`; `PageDotsLayout.centreAboveBottom 10` | LOW | yes |
| Island-States: paused caption | "cover at 0.55, bars 3 pt tall" | Paused holds only `pausedLinger` 0.4 s, then folds into the notch (`Notch/NotchMetrics.swift:99`); the bars are white 0.50 | LOW | yes |
| Equalizer caption | Implied the still heights are the playing look | The still heights are what Reduce Motion draws. Playing, each bar beats between low [4,7,5,8,6,5] and high [14,18,12,17,15,13] (`UI/CompactEqualizer.swift`) | LOW | yes |

Verified correct with no change needed: NotchShape quadratic paths (fill closed, stroke open along the top) for every state. Radii per IslandShapeRadii. Body sizes for every activity and surface at 480/560/620. Rest (−2 × −1) and awake (+8/+3) shapes. The no-notch island has no stroke and no nudge (`IslandStroke.isShown` needs `restsInNotch`, which needs `isPhysical`, so audit #27 is closed). Fill #1C1C1E under the pointer. Cover inset 8.63, equalizer trailing 10.63. Bars centred, spacing 0.96, gradient direction. Bubble geometry and colours. Headphones, volume and update coordinates (x − topR, y − 38 + notch), sizes, opacities and weights. HUD symbol thirds. Page dots positions and opacities. Gear at w − 46, badge at (18, 3). History at w − 76. Header title room and the showsName rule (my NSString widths match the fixer's). Tray glyph at 20 and count at 44. All en/ru header strings. Surface caption claims. Edge-Widths claims (Clipboard: segments become symbols and ages shorten below 540; Settings form 316 below 540).

## Not fixable here
- Squircle corners (`.continuous`) on the cover, battery, buttons and bar: CSS draws circular. Noted on Main.
- `Theme.chargingGreen.gradient` and `updateBlue.gradient`: SwiftUI's system gradient stops are not published, so both stay flat.
- Hierarchical airpods.pro: the canvas applies one 0.85 group opacity over the per-layer opacities. Where layers overlap this differs very slightly from SwiftUI's per-layer alpha.
- No-notch height is `max(menu bar, NSStatusBar thickness, 24)`; the canvas draws the floor of 24. The real value depends on the Mac (the code comment cites 22 vs 30 on a 13" M1). Not verifiable without the display.
- Welcome pane on a 24 pt notch: the app gives it 208 − 24 = 184 tall; the canvas import stays 170, because WelcomeBody is not my file.
- Missing states with no free grid slot, listed rather than added: update alert while working (progress bar #3E8EF7 on 0.18, words "Downloading Isla %@…"), failed (Try Again), manual (Settings), restart needed (Quit Isla); brightness kinds on Island-States (tweakable on Island via `kind`); AirPods as the volume glyph; pressed states (opacity 0.55; the bubble turns #1C1C1E).
- PlayerBody/PlayerBodyRU equalizer alignment was flagged last pass. Those files belong to another reviewer.

## Symbols to export
None. Every symbol used already exists in symbols.json.

## Board size changes needed (driver edits canvas.json)
- **Main.dc.html: h 1560 → 3040.** By line-height arithmetic the content was already about 2550 tall before this pass, so the bottom was clipped (motion, then sizes). It is about 2980 now. I set `$preview` and the root `min-height` to 3040. Nothing sits below Main at x 0.
- No other frame changes.

## Captions corrected
- Island-States: "Music, playing… (the cover here is a swatch of that tint)"; "Music, paused: cover at 0.55, bars 3 pt in white 0.50; held 0.4 s, then folds into the notch".
- Edge-NoNotch: resting "a drawn 200 x 24 island (the menu bar's height, never under 24), no stroke"; awake "#1C1C1E, no nudge and no stroke"; music "cover 16 at r4, glyphs and bars at three quarters"; charging "the battery at three quarters, the words full size".
- Equalizer: "Drawn still, as under Reduce Motion; playing, each bar beats between its own low and high".
- Main: subtitle, role samples, motion labels, size rows (above).

Files edited (S/canvas/project): Main, Equalizer, Island, Island-States, Surface, Edge-NoNotch. Unchanged: Surfaces, Edge-Widths, Edge-Contrast, Edge-RU (their claims check out against the code).


---

## Pass 2, Reviewer 2: player and lyrics stage (en + RU, both states boards)

Source: W/Sources/IslaKit at c38ea2a (`source-fresh.sh`: FRESH). Paths are relative to `Sources/IslaKit/`. I measured text widths and
line heights with AppKit's own fonts (`NSFont.systemFont`, `NSLayoutManager.defaultLineHeight`), and pixels on S/real/p1.png
(a 2x crop). Files edited: PlayerBody, PlayerBodyRU, StageBody, StageBodyRU, Player-States, Stage-States. Pre-edit copies are in
S/review/w2/; the edit scripts are w2/player_edit.py, player_edit2.py and stage_edit.py. Checks: tags balanced, no `data:`,
no prop named `style`, and every hole defined across 239 player and 375 stage prop combinations (w2/eval.js: 0 undefined, 0 NaN).
I kept every prop name and default. All new props default to the look the boards had before, except where a row below says otherwise.

## Findings

| Board / element | Canvas had | App has (file:line) | Sev | Fixed |
|---|---|---|---|---|
| Player + Stage: sung line | Half-swept at the `sweep` default of 0.45 | A line-timed line, which is every line while Word Karaoke is off (its default), is lit **whole**. Only a word-timed line sweeps: `LyricSweep.drawnFraction` Services/LyricSweep.swift:389-396; `usesWordTiming` UI/LyricsPresentation.swift:99-105; SettingsTable.swift:341 (default off) | high | yes: new `wordKaraoke` prop (default false). The board now draws the line lit whole; `sweep` works only with `wordKaraoke` on |
| Player: subtitle between lines (p1.png item 4) | Not shown | Between lines the subtitle holds the coming line, unswept at 0.45 (× 0.7 when paused): MediaPane.swift:316-331. p1 measures about 0.39, which is 0.45 × 0.7 plus the screen's lift | med | yes: new `coming` prop |
| Player: cover `art` | The missing-cover well, the same picture as `missing` | The real artwork (MediaPane.swift:224-229). The well reads as "no cover" | med | yes: a flat swatch of the cover's tint, marked in the HTML as a stand-in. Player and stage both |
| Player: cover while loading | Missing | `SkeletonBox` for up to 2.5 s: surface 0.16 (0.28 with Increase Contrast) and a white 0.10 band (MediaPane.swift:235-244; Skeleton.swift:15-25) | low | yes: `cover="loading"` |
| Player + Stage: tint with no artwork | Grey only for `missing` | `CoverTint.fallback` #D1D1D1 whenever there is no artwork, loading included (CoverTint.swift:166-169; NotchViewModel.swift:905) | low | yes. Stage progress gets it too, through the new stage `cover` prop |
| Player: times | `fmt` floored the minutes and rounded the seconds separately, so 59.6 s printed "0:60" | `formatTime` rounds the whole number of seconds first (Theme.swift:1710-1718) | med | yes |
| Player: fill at 0 % | A 7 pt dot | Fill opacity 0 when nothing is filled (MediaPane.swift:517) | low | yes |
| Player: scrubber hover | Missing | Knob 11 pt white, shadow 0.4 r3, clamped inside the bar (MediaPane.swift:518-523); elapsed time at white 0.9 (:475-476) | low | yes: `scrubHover` prop |
| Player: subtitle box | 18 tall | `textBox`: ceil(ascender) 14 + ceil(descender) 3 = 17 for SF 14 semibold (MediaPane.swift:178-186) | low | yes |
| Player: long sung line | Clipped with no ellipsis | KaraokeText lineLimit 1, tail (KaraokeText.swift) | low | yes: ellipsis |
| Player: Favourite star (p1.png item 2) | Star by default | The star shows only for an Apple Music song (`musicFavorite`, read by scripting only when the app is `.music`, MediaController.swift:793), or a Spotify song when the account is connected, not API-blocked, with a token (MediaPane.swift:600-615). p1 is Spotify with no account linked, so it has no star | med | caption corrected. The default stays `off`: it is right for Apple Music, and the brief keeps defaults. See "not fixable" for Surface.dc.html |
| Player: star while Spotify's library has not answered | Missing | Opacity 0.45, disabled (MediaPane.swift:672-693) | low | yes: `favourite="asking"` |
| Player + Stage: skips when the source cannot skip | Missing | Opacity 0.35 (MediaPane.swift:663-664; LyricsStageSurface.swift:286-287) | low | yes: `canSkip` prop |
| Player empty: headline and caption | Line heights 17 / 16, never cut | Natural line heights 17 / 15; headline cut at lineLimit 2, caption at 3 (MediaPane.swift:784-791). The RU Music Only headline measures 3 lines at 242 pt, so the app cuts it | med (RU) | yes: 15 pt lines, clamps 2 and 3 |
| Player empty: footnote | Ran past the body in RU | lineLimit 1, tail (MediaPane.swift:828). The RU line measures 359.5 pt against about 299 of room, so the app cuts it with "…" | med (RU) | yes: ellipsis |
| Player: paused equalizer (p1.png item 3) | 6 bars, 3 pt, centred, tertiary | Same: restingHeights 3 (CompactEqualizer.swift:10, :40-46, :160-168). The "dots" on p1 are these | — | matches |
| Player: progress (p1.png item 5) | 7 tall, radius 3.5, track 0.15, fill 0.50 | Same (PlayerLayout.swift:97-103; MediaPane.swift:509-517; Theme.swift:757-758). p1 measures 14 px at 2x, so 7 pt. Every grey on p1 is brighter than its alpha (fill 0.64, track 0.20, artist 0.58, time 0.47, transport 0.92), which is the capture's colour handling and applies to all of them, not the code | — | matches; nothing to change |
| Stage: rows | Line height 28; translated rows 9 pt low | No line height is set: SF 22 bold sets a 26 pt line, and each row is centred in a 38 pt slot (56 pt translated) on the reading centre 114 (LyricsStage.swift:337-366, :428, :746; StageLayout.readingCentre). Translated: 26 + 2 + 16 centred in 56, so the sung line's top is at 92, not 100 | med | yes: rows are placed by slot arithmetic |
| Stage: reading by hand | Sync pill shown with the sung line still centred | The pill appears only once the page is 2 or more rows from the sung line (LyricsStage.swift:514-519, :646-655) | med | yes: the reading state sits two rows ahead |
| Stage: notice row | Missing | 40 tall, white 0.07, radius 9, 0.5 hairline, `clock.arrow.circlepath` 12 regular in secondary, 11 regular white with 1.5 line spacing, 2 lines; the viewport and reading centre move down by 40 (LyricsStage.swift:210-224, :538-546, :794-819) | med | yes: `notice` prop, mismatch text en and ru |
| Stage: states `cannotLookUp`, and No Lyrics with online already on | Missing | `quote.bubble` + "No lyrics for live audio." with no button; noneFound with only Import LRC… and no disclosure when online is on (LyricsStage.swift:846-857; LyricsPageModel.swift) | low | yes: `cannotLookUp`, `notFoundOnline` |
| Stage: status text and disclosure | max-width 360 / 300 (RU unreadable line and RU disclosure wrapped) | No cap; the column is the lines' width less 12 (LyricsStage.swift:894-896). RU measures 398 / 356 pt, so one line in the app | low (RU) | yes |
| Stage: unreadable copy | "Line [n] …" | Always an integer (LyricsPageModel.swift `unreadableSentence`) | low | yes: "Line 12" / "В строке 12" |

## Not fixable here
- Header on p1.png (item 1): it is not on my boards. The rule is `PlayerSourceTitle.showsName(room:)` (UI/SurfaceHeader.swift:242-246, used at NotchContentView.swift:976-979). The player body is a fixed 357.4 pt (the panel width does not change it), and the room depends on the **notch** width. Under a wide notch, room for the icon only, the name is dropped, never cut. The shell/header boards' owner should check it.
- Surface.dc.html imports PlayerBody with defaults, so it shows a star. If that board stands for a Spotify song with no account linked, it should pass `favourite="none"` (the driver's file).
- Squircle (`.continuous`) corners on the cover, wells, chips and capsules: CSS draws circular corners.
- The AppKit small spinner in "looking": the board draws an arc. The spokes are AppKit's appearance, which no repo code traces.
- The marquee on a long title, and the per-row sweep of a wrapped word-timed line: these are behaviours.
- Sync pill: a 0.5 centred stroke drawn as an inset ring, and the shadow radius conversion. Negligible.
- Screen greys brighter than alpha × 255 on p1: colour handling in the capture, see the progress row.
- App-side findings for the owner, not canvas bugs: in Russian, the player's reader-down footnote is cut with "…", and the Music Only headline is cut at 2 lines.

## Symbols to export
None. Every symbol used exists in sym.py; the notice uses `clock.arrow.circlepath@12-regular`.

## Board size changes needed
None.

## Captions corrected
- Player-States: "Playing, the sung line in the subtitle" became "Playing: the sung line in the subtitle, lit whole (line-timed)". "No star and Output off: …" became "No star (Spotify with no account linked), Output off: the rest stay put".
- Stage-States: "…the sung line swept…" became "…lit whole…". "Reading by hand: …" became "Reading by hand, two rows ahead: context at 0.46, the Sync pill offers the way back". "No lyrics found: …" became "No lyrics found, online lookups off: Import LRC, Search Online and its disclosure".


---

## Pass 2, Review 3: Shelf, drop surface, Clipboard (en + RU) and their state boards

Source: W/Sources/IslaKit at c38ea2a. Paths below are relative to it. Files edited, all in S/canvas/project:
ClipboardBody, ClipboardBodyRU, ShelfBody, ShelfBodyRU, ShelfDropBody, Shelf-States, Clipboard-States. Drop-States is unchanged.
Backups taken before editing: S/review/r3/orig/ (identical to S/canvas-v57-baseline). Edit scripts: S/review/r3/clip_edit.py, plus inline Python.
Checks I ran: every state × filter × width (480/510/520/560/620) × Increase Contrast in node (S/review/r3/run.js) gives 0 undefined, NaN or unresolved holes.
Tags balance, no data: URIs, no prop named `style`, support.js present. Text widths were measured with NSFont (a `swift` script, S/review/r3/m.swift).

## Findings

| Board / element | Canvas had | App has (file:line) | Sev | Fixed? |
|---|---|---|---|---|
| Clipboard list, every list state | No row selected at rest. Row 0 said "Pinned" | When nothing has been moved to, the first listed row is the selection (`ClipboardBrowser.selectedIndex` → 0, Model/ClipboardBrowser.swift:82-86, used at UI/ClipboardPane.swift:162,178). It gets well 0.08 and "↩ Copy" (:479, :678-685). The owner's capture p3 confirms this | high | yes: selIdx is 0 by default, 1 in `selected` |
| Clipboard filter words/symbols switch | segW 48 (EN), 88 (RU). Words from 510 | widest name in 12 medium + 8 (UI/ClipboardLayout.swift:150-159). NSFont: "Images" 42 → 50, so words need bw ≥ 518 (510 is symbols). "Изображения" 84 → 92, so Russian never fits | med | yes. The driver's fix is re-verified: words XOR symbols at every width |
| Clipboard search | Matches not marked | Every match drawn yellow rgb(255,214,10) on rgb(29,29,31) (ClipboardPane.swift:1010-1013, Theme.swift:1257-1258) | med | yes, first match per row (enough for this data) |
| Clipboard search scope | Searched the whole history whatever the filter | Search narrows within the chosen kind (ClipboardBrowser.swift:66-71) | low | yes |
| Clipboard filter = Images outside the `images` state | Drew a list of image rows | Images without a search is always the grid (ClipboardPane.swift:148-149) | low | yes |
| Clipboard trailing slot | eye and age 8 apart (row gap) | One HStack, spacing 2 (ClipboardPane.swift:662). 8 from the content | low | yes, wrapper with 2 px gap |
| Clipboard ages at < 540 | "Monday" at every width | narrow ages: weekday becomes EEE, "Mon" / "пн" (ClipboardLayout.swift:164-166, ClipboardKinds.swift:383) | med | yes, list and grid |
| Clipboard covered dot widths | one guessed content width for every row | fraction × the width the row leaves for its content, which depends on each row's own trailing word (ClipboardPane.swift:468-475,584-586) | low | yes, per row, from NSFont widths |
| Clipboard search ring | only in `search` | ring whenever the field has focus: summoned, or typed into (ClipboardControls.swift:116-130). So also `noResults` | low | yes, plus new state `summoned` |
| Clipboard hover on a pinned row | not drawable | `pin.fill` 11 regular in white, xmark secondary (ClipboardPane.swift:671-677) | low | yes, new state `pinnedHover` |
| Clipboard eye while copied | the eye could show with "Copied" | the copied flash replaces the whole trailing slot (ClipboardPane.swift:645-660) | low | yes |
| Clipboard selected segment shadow | 0 1px 1px | radius 1, y 1 (ClipboardControls.swift:40), about a 2 px blur | low | yes |
| Clipboard denied alert / confirm bar | text could run to 10 / 6 px from the buttons | Spacer(minLength 6) between 10-gaps = 26 (ClipboardPane.swift:368-383). Spacer(min 8) between 6-gaps = 20 (:404-410) | low | yes, via margin-right |
| ShelfBody Remove All buttons | top highlight 0.18 (the fix report said 0.12, but the file still had 0.18) | 0.12 (Theme.swift:1448-1452) | low | yes, EN + RU |
| ShelfBody Remove All question | max-width 320 | no max width, only padding 24 (ShelfPane.swift:129-152) | low | yes |
| ShelfBody tile caption overflow | an overflowing line was start-aligned ("Dec 12, 2025" is 75.4 > 72; "12 дек. 2025 г." is 86.3) | `.fixedSize()` text centred in a 72 frame overflows both sides equally (ShelfPane.swift:416-424, 349) | low | yes, flex centring |
| ShelfBody `kept` | flash only | a drop it already held also shows "Already on the Shelf" / "Уже на полке" under the grid for 1.2 s (ShelfStore.swift:719-730,739) | med | yes |
| ShelfBody notice text | "[A notice from the Shelf]" placeholder | real notices (ShelfStore.swift:232-246). The `notice` state now reads "A file from the drag could not be received." / RU from ru.lproj | low | yes |
| ShelfBody full Shelf | missing | the eviction notice at the viewport's foot over the fade (ShelfLayout.swift:116-119) | low | yes, new state `full` |
| ShelfDropBody RU | English only. Surface in RU falls back to English | ru.lproj: Оставить на полке / Отпустите, чтобы положить на полку / Отправить на устройство поблизости | med | new `lang` prop (en default). Surface must pass `lang="ru"` (not my file) |
| ShelfDropBody text limits | no clamp | title lineLimit 1, caption lineLimit 2 (ShelfPane.swift:553,559) | low | yes |

Confirmed correct (re-checked against the code and capture p2/p3):
- Shelf: 5 columns at 480 and 6 at 560/620. Tile 80×94 r16, pitch 90/104, first row 9.5.
- Shelf: plates 0.10/0.14/0.18 + 1.5 ring; kept is blue 0.18 + 2 ring. Badge 57.75/5.5, xmark.circle.fill 17 over a 14 pt black-0.28 disc.
- Shelf: day/time captions 11.5 semibold/medium with tabular digits. Offline is grey 0.4 with the caption in tertiary.
- Shelf: the 16 pt bottom fade appears only when the grid scrolls (the `many` and `full` states do fade; p2 shows the same). Empty line, notice geometry.
- Drop wells: geometry, glyphs (tray.full 22, real AirDrop image).
- Clipboard: geometry; all marks and sizes; covered dust; eye/eye.slash semantics (hidden → eye); copied tick #30D158; image grid and pin badge; denied alert; empty/kind-empty/no-results copy.
- Every en/ru string is verbatim from the tables, including “…” and «…».

## Not fixable here
- Shelf previews are gradients at 42×30. The app shows Quick Look thumbnails at their own aspect, long side 42 (ShelfLayout.swift:201-205), with a white 1.5 border. p2 shows landscape screenshots of about 42×27. No asset fits, so this is a placeholder. Same for the Clipboard image thumbnails.
- Times use the Mac's 12/24-hour setting (ShelfStore.swift:113-118, `.autoupdatingCurrent`). The board draws 24 h, matching p2. On a 12-hour Mac it would read "10:52 AM".
- "2.4 MB" comes from ByteCountFormatter (ClipboardLayout.swift:227), which uses the system locale, not the app language. RU keeps "2.4 MB"; a Russian-region Mac would show "2,4 МБ".
- Drop-States lacks the AirDrop-lit well and the AirDrop fallback symbol. A third cell needs a second row (h 210 → 420), which would overlap ShelfBody at y 2110. The tweakable ShelfDropBody has `lit=airDrop`.
- Clipboard with covered images (the dust plus the eye on a tile, ClipboardPane.swift:836-840) and a copied image tile overlay (:872-886) are not drawn. There is no free cell left; Clipboard-States is now full at 14.
- Legacy pre-date Shelf cards (name in two lines, ShelfPane.swift:407-412) and the pressed tile (scale 0.97) are not drawn.
- Corners: tile r16, rows r7, wells r14 and buttons r6 are `.continuous` squircles in the app; CSS draws circular arcs. Nothing pokes outside the island: these bodies sit inside Surface's clip.
- Repeated rows reuse the sym.py mask ids (eye.slash, xmark.circle.fill) from the earlier pass. This renders fine in browsers, but the ids are not unique.
- Notice `minimumScaleFactor(0.85)` cannot be done in CSS; the canvas cuts the tail with an ellipsis instead.

## Symbols to export
None. pin.fill|11|regular was already in the set.

## Board size changes needed
None. The new cells use the empty last slot of Shelf-States (slot 10) and Clipboard-States (slot 14).
Driver to-do: wire `lang` into Surface's ShelfDropBody import for RU.

## Captions corrected
- Clipboard-States list: "Reached by a swipe or a dot: the first row is the selection (↩ Copy), pinned above a hairline".
- Clipboard-States selected: "↓ moved the selection…". hover: wording tightened. search: "…every match is lit yellow" (it was "the field rings blue", which applies only once summoned).
- Clipboard-States new cell: "Summoned (⌃⌥⌘V, the menu)…".
- Shelf-States kept: now names the 1.2 s line. notice: "for 4 s". many: "scrolls down and fades over its last 16 pt".
- Shelf-States new cell: "Full at 60…".


---

## Pass 2, Review 4: Translate, Welcome, Settings (en + RU) and their state boards

Source: W/Sources/IslaKit at c38ea2a. Paths below are relative to it. All edited files are in S/canvas/project:
SettingsBody, SettingsBodyRU, TranslateBody, TranslateBodyRU, WelcomeBodyRU, Settings-Sections and Settings-Changed.
WelcomeBody, Welcome-States and Translate-States are unchanged.

Backups: S/review/r4/orig/ (identical to S/canvas-v57-baseline). Notes and string tables: S/review/r4/ (ru.json, en.json).

SettingsBodyRU is now generated from SettingsBody:
- one script with a strings table `L`, built from Resources/ru.lproj. It holds 129 entries, and every key the EN script asks for at runtime is in it;
- a canvas-only table `C` for the player's Finder name «Музыка», «12,4 МБ» and the placeholders.

So en and RU cannot drift again. SettingsBody's script was rewritten in place. No prop names, defaults or blob ids changed.

Checks:
- S/review/r4/tools/holes.js renders every hole of every board against renderVals for all enum, boolean and range combinations. Results:
  - Settings: 120 combinations per language;
  - Translate: 78;
  - Welcome: 12;
  - 0 undefined, NaN or missing holes.
- The checker was proven on the stale script, where it reported 72 issues.
- Tags balance, there are no data: URIs and no prop is named `style`, support.js is intact.
- Text widths were measured with NSFont (a `swift` script).

## Findings

| Board / element | Canvas had | App has (file:line) | Sev | Fixed? |
|---|---|---|---|---|
| Settings › Lyrics, default | Word Karaoke, Lyric Delay, Translate Lyrics, Translate To and Look Up Lyrics Online at full strength | Show Lyrics is off by default. Each of those rows is `disabledWithReason` at opacity 0.4 (UI/SettingsPane.swift:603, 707, 723-724, 729, 749-750, 755, 1602) | high | yes. The delay group dims as one; Translate To dims unless Translate Lyrics is on |
| Settings › Music › Lyric Band | full strength | It also needs Show Lyrics, so it is dimmed (SettingsPane.swift:602, 700-701) | med | yes |
| Settings › Lyrics › Translation | no footnote | `.footnote(LyricTranslation.settingsNote)` (UI/SettingsTable.swift:682, Services/LyricTranslation.swift:708): "Translated on this Mac. Nothing is sent over the internet." | high | yes, en + RU |
| Settings › Lyrics › Show next line early | capsules "0.3", "0.5" | "0.3 s", "0.5 s" (Services/LyricSweep.swift:830-831). RU: "0,3 с", "0,5 с" | med | yes |
| Settings › Music, changed (Music Only off) | players' note still shown | `playersNote` is nil while Music Only is off (SettingsTable.swift:656-662) | med | yes |
| Settings › Shortcuts, changed | note named ⌃⌥⌘L, the default binding, so Restore had no cause | The note names the refused binding (SettingsPane.swift:418). Restore shows only when a binding differs from its default | med | yes. Show the lyrics is now ⌃⌘L, refused |
| Settings › Spotify, connected | Disconnect only | Three notes (SettingsPane.swift:262, 277-278): stored in the keychain, what Disconnect keeps, the heart | med | yes |
| Settings › Screenshots, default | Clear enabled | Disabled when the folder has 0 files (SettingsPane.swift:1038). Its size suffix uses ByteCountFormatter (:1173-1175), so RU reads "12,4 МБ" | med | yes, dimmed 0.4. RU size corrected |
| Settings › About, default | "Isla is up to date" / "Isla 0.3.0" | Before any check: title "Isla %@", no subtitle, then the Check for Updates button (UI/UpdatePresentation.swift:134, SettingsTable.swift:252) | med | yes |
| Settings › General + Increase Contrast | no line | "Following your Mac: %@" as the last footnote (SettingsPane.swift:1305-1312) | low | yes, "Following your Mac: Increase Contrast" / «Как на вашем Mac: Увеличение контраста» |
| Settings slider (Panel Width and others) | the slider took half the free width | `.frame(min 56, ideal, max 150)` (SettingsPane.swift:1728, 1741). The slider fills to 150 before the spacer gets anything; p5.png shows about 148 pt at 480 | med | yes: `flex: 0 1 150px; min-width: 56px` |
| Slider fill and knob | fixed 114 px travel | travel scales with the track width (AppKit mini slider) | low | yes, via calc() of the track |
| Slider and stepper value text | weight 400, tracking 0.07 | 10 medium, monospacedDigit, no tracking (`TypeRole.font()`) | low | yes |
| Choice row (capsules) | always on the title's line. Unselected 0.50 | ViewThatFits wraps the capsules under the title. Unselected is tertiary(over:) 0.62/0.65. Increase Contrast gives a 1 pt hairline and no fill | low | yes |
| Push row | the button could be cut at 480 / RU | the row stacks when the longest word plus the control do not fit (SettingsRowLayout) | low | yes (flex-wrap) |
| Shortcut well | tracking 0.07 | `TypeRole.body.font()` = 11 medium, no tracking | low | yes |
| Lock Screen › Card Style | previews inside a group card | `.free(.cardStyle)`: no group fill or edge; padding 4/6/4 | med | yes, its own block |
| Settings form and divider | 340 tall | proxy height − top = 354 (SettingsPane.swift:391, 395). ScrollEdgeFade is 10 at the clipped edge | low | yes |
| Settings footnote | line height 13 | 14 (measured on p5.png at 2×) | low | yes |
| Translate result card | fill 0.07 plus a 0.5 pt edge | `resultCard` draws no background in any state. Only `sourceCard` has the fill and edge (UI/TranslatePane.swift:343-353 against 577-625). Matches p4.png | high | yes, en + RU |
| Translate 15 pt texts (source, placeholder, answer, "Translation") | tracking −0.2 | `.font(.system(size: 15, …))` carries no tracking (TranslatePane.swift:399, 454, 478, 619, 639) | low | yes, 8 places |
| Translate origin, online | sentence always, clipped | ViewThatFits falls back to the glyph alone (TranslatePane.swift:735-752). NSFont 10 pt: EN 155.5, RU 191.5. Measured fit: EN fits at 560 and up, RU only at 620 | med | yes, `originWords` hole |
| Translate RU counter | "/ 20,000" | `formatted(.number.locale(ru))` (TranslatePane.swift:174, 194), so "/ 20 000" | low | yes (NBSP) |
| Welcome RU, come-back line (key bound) | English sentence | «Значка в Dock и строке меню нет. Нажмите на вырез или ⌃⌥⌘I, чтобы вернуться.» (ru.lproj, UI/WelcomePane.swift `comeBack`) | high | yes |
| Welcome RU, shortcut legend | "Clipboard · Translate · Lyrics" in English | names come from `Copy.fromTables` (WelcomePane.swift `liveShortcuts`): «Буфер обмена · Перевод · Текст песни» | high | yes |
| Welcome EN (fonts, columns 0.55, margins 8/20/14, Get Started capsule) | — | matches WelcomePane.swift and Theme.swift:1506-1527 | — | no change needed |

Screenshot items checked against the code:
- Translate pop-ups (p4) show the owner's chosen pair. The canvas empty state shows "Detect Language", which is what the code shows with no source chosen (UI/TranslateLayout.swift:235-238).
- The chevrons, swap arrows, "Type or paste text" and Paste with doc.on.clipboard already match.
- Settings "The island shows" icons (bolt, headphones, music note, speaker) and the Volume and Brightness footnote already match. The Panel Width slider at 480 reads "480 pt".
- Switches use the system accent. The `switchAccent` prop defaults to #0A84FF only because that is macOS's default; the script now says so. No caption on my boards claims blue.
- Translate's Speak plate is `Theme.accent`, a fixed rgb(255,69,58) and not the system accent, so its "lit red" caption is right.

## Not fixable here

- Settings title row (gear + "Settings") and the X in a rounded square (p5): these are header or shell elements, not SettingsBody (reviewer 1's header board).
- Sidebar tiles and the About Isla icon: these are `.continuous` squircles in the app. CSS border-radius is circular. Noted, not faked.
- m1.png (right-click menu over Settings) belongs to the menus board (reviewer 5).
- The RU Translate notice uses an ASCII space in "20 000" where Foundation writes NBSP. It is invisible and left as is.

## Symbols to export

None. Every glyph on these boards already comes from sym.py output.

## Board size changes needed

None. Every frame size is unchanged:
- SettingsBody 560×362;
- TranslateBody 560×262;
- WelcomeBody 560×170.

## Captions corrected

- Settings-Changed, music: "Music Only off: the footnote changes" → "…the footnote changes and the players’ note goes".
- Settings-Changed, spotify: "Spotify: connected" → "Spotify connected: Disconnect, and the keychain, library and heart notes".
- Settings-Changed, shortcuts: → "Show the lyrics set to ⌃⌘L, which macOS refused: its note and Restore Default Shortcuts".
- Settings-Changed, lyrics: → "Show Lyrics on, so nothing is dimmed: a delay set, a library folder, online lookup".
- Settings-Sections, lyrics: → "Lyrics: with Show Lyrics off, the rows that need it are dimmed".
- Settings-Sections, screenshots: → "Screenshots: Clear is dimmed while the folder is empty".
- Settings-Sections, about: → "About: version, the update card before a check, diagnostics, quit".


---

## Pass 2, Reviewer 5: lock card, lock scene, menus

Swift paths are relative to `Sources/IslaKit/` (checkout FRESH at c38ea2a). Files edited, all in `S/canvas/project/`:
LockCard, LockScene, LockCard-States, LightMenu, Light-Menus. Untouched: LockCard-Materials (every caption and value checked
true). Edge-* compose only Surface and Island; their captions were spot-checked (Settings at 480 = 316,
SettingsLayout.swift:62), and their content belongs to the Surface/Island reviewers. Originals: `S/review/r5/*.dc.html`.
Checks run: renderVals over 769 LockCard, 25 LockScene and 145 LightMenu prop combinations, all clean (no NaN, no
undefined, every hole and list-item hole has a key; `S/review/r5/eval.js`). Tags balanced, no `data:`, support.js line
kept, no prop renamed. One default changed on purpose: LightMenu `appearance` is now `dark` (below).

## Menu appearance: settled

- Every menu in the app pops in a view of a `NotchPanel`, and `NotchPanel.init` forces `appearance = .darkAqua`
  (Notch/NotchPanel.swift:400). Pop sites: island menu `menu.popUp(positioning: nil, at: point, in: rootView)`
  (Notch/NotchController.swift:887); Translate From/To `popUp(positioning: selected, at: (0,0), in: anchor)`
  (UI/TranslateMenus.swift:80); Lyrics More and Lyrics Translate `popUp(positioning: nil, …, in: anchor)`
  (UI/LyricHeaderTools.swift:180, 416); Output `popUp(positioning: nil, …, in: anchor)` (UI/OutputMenu.swift:175);
  SwiftUI `.contextMenu` on clipboard rows and tiles (UI/ClipboardPane.swift:488, 811), shelf tiles
  (UI/ShelfPane.swift:290, Open With submenu :482) and lyric rows (UI/LyricRow.swift:239).
- No code sets `NSMenu.appearance` (grep: the only `appearance =` is NotchPanel.swift:400; `NSApp.appearance` is never set).
  The comments that say "the system's own appearance, nothing forced" (OutputMenu.swift:79-80, LyricHeaderTools.swift:113)
  describe the menu object, not what it inherits.
- Reading A (before the experiment): an NSMenu with nil appearance takes the effective appearance of the view it pops in,
  so dark everywhere. Reading B: it follows the system, so Light on a Light Mac. m1.png (Dark system) is dark under both.
- Driver's experiment (aqua panel → Light menu, darkAqua panel → dark menu) proves Reading A. **Every menu Isla shows is
  dark on every Mac.** Spec 2026-10-15-redesign-spec.md:1412 ("Menus follow the system appearance … Stress-Light-Menus")
  is wrong against the code; for the driver to record, repo not edited.
- Lock card: `LockCardWindow` builds its window as `NotchPanel(contentRect:)` (Notch/LockCardWindow.swift:224), so it is
  darkAqua too, and `LockScreenCard` adds `.environment(\.colorScheme, .dark)` (UI/LockScreenCard.swift:326). Its one
  menu is the lyric row's "Copy Line" context menu (LyricRow.swift:239-246; the card passes no `allText` and no `syncHere`,
  so it holds that single row). The output picker on the card is a pane, not a menu. **No menu anywhere can be Light.**

## Findings

| Board / element | Canvas had | App has (file:line) | Sev | Fixed |
|---|---|---|---|---|
| LightMenu, every menu | Light by default; comment said "nothing is forced" | dark: darkAqua inherited (above) | high | yes: `appearance` default `dark`; `light` kept as a lever only, comment says so |
| Light-Menus, 10 captions | presented the Light look as the app's | dark on a Light Mac | high | yes: each caption says dark, the first says why; every import passes `appearance="dark"` |
| LightMenu chrome | padding 6 all round | m1.png: 4 pt above the first row and below the last (menu 220 x 163 pt for 6 rows + 1 separator) | med | yes: `4px 6px` |
| LightMenu rows | titles 16 pt in, right 16 | m1.png: titles 15 in, key equivalents end 16 from the edge | low | yes: row padding `0 10px 0 9px`, headers too |
| LightMenu separator | inset 14, white 0.12 | m1.png: inset 15 each side, ~white 0.15, 5 + 1 + 5 pt | low | yes |
| LightMenu dark text / keys | text 0.92, keys 0.55 | m1.png samples: titles ~0.86, key glyphs ~0.30 over the panel black | med | yes: text 0.86, new `key` colour 0.30 |
| LightMenu state column | shown only when a row is ticked | m1.png confirms: island menu has no column (showsStateColumn default YES did not reserve one on Tahoe) | — | kept, comment added |
| LightMenu light selection | #0A84FF on both | light systemBlue is #007AFF | low | yes (light lever only) |
| LightMenu dead hand-drawn icon paths (`ICON`, `iconPath`) and `dev_speaker` naming the `display` glyph | present | real symbols only | low | removed / renamed `dev_display` |
| LockCard rail, loud speaker | empty `<svg>`: nothing drawn | `speaker.wave.3.fill` caption 10 regular (SystemVolumeSlider.swift:250-252) | high | yes: the library's 10-regular entry is empty, so the real 11-regular vector is drawn scaled 10/11 into the 16x12 box; export owed |
| LockCard Sound rows | circle at x 12 | row 12 + OutputRowStyle 8 = 20 (LockScreenCard.swift:1278-1280, ModeToggle.swift:82) | med | yes: padding 20 |
| LockCard Sound row name | could run into the tick | `Spacer(minLength: 6)` + 10 spacing (LockScreenCard.swift:1267) | low | yes: margin-right 16 |
| LockCard artist lines (banner, player, lyrics) | no tail cut | `lineLimit(1)` (LockScreenCard.swift:550) | low | yes |
| LockCard sung line, lyric rows, translations | overflowed uncut | `lineLimit(1)`, tail (:797, :817-818) | low | yes |
| LockCard seek labels | fixed 1:24 / -2:07 whatever `progress` | elapsed and remaining from the clock, `formatTime` rounds (:1324-1374, Theme.swift:1710) | low | yes: derived from `progress` over a 3:31 song (default unchanged) |
| LockCard heart | no pending state | hollow heart at 0.45, disabled, until the library answers (:1532-1543) | low | yes: `heart` option `pending` |
| LockCard skips | never dimmed | 0.35 when the player cannot skip (:1402, 1420, 1024, 1040) | low | yes: new `canSkip` prop, default true |
| LockScene island | compact music wings beside the card | while the card holds the song the island shows no wings and rests; a hover still nudges it (Model/LockedIsland.swift:3-30, used NotchContentView.swift:278) | high | yes: `music`/`paused` draw `rest`, `awake` stays; prop and default kept |
| LockScene card | top 190 | window centred on the screen (LockCardWindow.swift:53-59): top 128 in the 580 scene | low | yes |
| LockScene paused | card always playing | card follows the song | low | yes: `paused` passes `playing=false` |
| LockCard-States captions | "four rows, 44 apart"; "Paused, song liked: heart filled" | sung translated row is 54 (LockCardLayout.swift:241-242); paused swaps the glyph | low | yes |

Confirmed correct (re-checked against code): banner/card frames, header, ring (r 15.5, 2 pt, dash 97.4), cover badge
(68,68), transport and rail frames, lyric ramp and pitches, Sound pane volume (12 pt slots, 8 track, 14 knob, shadow),
the material decision, washes, rim (gradient 0.72/0.20/0.08, opaque 0.18, IC 1.5 @ 0.85), layer order (recipe under the
cover light under the marks), text shadow 0/0.5/0.35, every menu's items, order, separators, ⌃⌥⌘ order, ⌘Y/⌘C/⌘R/⌫,
ticks, disabled rows, min widths 244/214/262, `%+.2f с` with a dot in Russian (String(format:) has no locale), Russian
strings, language sort in both languages. m1.png's six rows, keys and "Settings…" ellipsis match the island menu.

## Not fixable here

- `.continuous` corners (card 30/28, banner 22, row highlight 9) are squircles; CSS radius is circular.
- Cover light: real artwork ×1.5, blur 44, saturation 1.3 (LockScreenCard.swift:488-507) is runtime; the tint gradient stays.
- Grain (0.035 overlay) and the specular band's `plusLighter` (GlassSurface.swift:96-115): no CSS blend for background layers.
- SwiftUI shadow radius 3 → CSS blur factor unmeasured; kept at 3 px.
- Menu radius, row highlight inset and menu row height for the 26 pt output images, destructive-role red, and the
  checkmark/submenu chevron glyph sizes are AppKit's; m1.png shows none of them.
- States that need new board cells: no cover (#1C1C1E light + `music.note` placeholder), "No output devices.", the lyric
  pane's status line, muted volume, Sound row hover/press, the lock card's "Copy Line" menu, the letter source badge.
- Light-Menus menu placement against each button (Output and More: right edge on the button's, 2 pt under, OutputMenu.swift:167;
  Translate: the ticked row over the pop-up, TranslateMenus.swift:80) needs the Surface board's coordinates; not re-measured.
- Shelf header place name: `FileManager.displayName` follows the system language, not the app's (ShelfStore.swift:146).

## Symbols to export

- Follow-up 2026-10-20: LockCard rail now draws the real `speaker.wave.3.fill` 10 regular (16x12) in place of the scaled 11-regular stopgap; renderVals re-run, 769/25/145 combinations clean. The list below is now in the library.

- speaker.wave.3.fill|10|regular (library entry exists but is empty; LockCard rail uses the 11-regular vector scaled)
- speaker.slash.fill|11|regular (Sound pane muted state)
- music.note|21.33|light, music.note|13.33|light, music.note|11.33|light (cover placeholder, side/3)
- checkmark|13|regular and chevron.right|13|regular (AppKit menu state and submenu glyphs; weight unverified)

## Board size changes needed

None.

## Captions corrected

- Light-Menus: all ten captions now say the menu is dark; the first: "dark on a Light Mac too, as the panel forces darkAqua".
- LockCard-States: "four rows, 44 apart, the sung one 54"; "heart filled, play glyph in place of pause".
- For the driver: the canvas.json title "Menus in the system Light look" is now false. Suggested: "Menus on a Light Mac
  (still dark)". Board not renamed, as asked.
