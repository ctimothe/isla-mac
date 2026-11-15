# Icon audit: SF Symbols in Isla vs islandcn / Hugeicons free

Sources: islandcn `components/islandcn/glyphs.tsx` (G) and `glyph.tsx` (T) in
`.../scratchpad/islandcn-src`; Isla `.claude/worktrees/islandcn/Sources/IslaKit` (paths below relative to it).
Hugeicons names below come from the imports in glyphs.tsx (verified present: lines 3-54) or from my knowledge of
the free set (marked `?` = not verifiable here, node_modules absent; check each against the package index before use).

## 1. How glyphFrom turns a Hugeicons icon into a glyph

### Data model
- A Hugeicons icon is `IconSvgElement`: an array of `[tag, attrs]` elements (G:55 imports the type; G:178, G:190-192 index it).
  Each attrs object carries the icon's own `d` (or circle/rect attrs), `stroke="currentColor"`, `strokeWidth="1.5"`,
  `strokeLinecap/Join="round"` (shown by the hand-made `pathIcon` at G:181) and a `key`. The icon's grid is 24 x 24 (G:140 `grid = 24`).
- `pick(icon, ...idx)` (G:178) keeps only the listed elements by index; `pathIcon(d)` (G:181) wraps one hand-written path in the same shape.
- `isClosed(tag, attrs)` (G:157-161): any non-`path` tag is closed; a `path` is closed only if `d` ends in `z`/`Z` (regex `/[zZ]\s*$/`).

### Recipe fields (G:124-137)
`parts` (one part for all elements, or a per-element array; missing entries = "line", G:150-154), `place`, `layers[]`
(each `{icon, parts, place}`), `view [x,y,w,h]` (default `[0,0,24,24]`, G:189).

### Parts (G:95 type, G:84-94 doc, G:212-235 behaviour)
Three passes are drawn; "mask" feeds a mask that is applied only to the "fill" pass.
| part | mask pass (cuts) | fill pass (solid, masked) | line pass (not masked) | inlay pass (not masked) |
|---|---|---|---|---|
| `line` | none | none | `fill=none stroke=currentColor strokeWidth=line` (G:226) | none |
| `fill` | none | `fill=currentColor stroke=none` (G:222) | none | none |
| `heavy` | none | `fill=currentColor stroke=currentColor strokeWidth=line` (G:223) | none | none |
| `cut` | closed: `fill=#000 stroke=#000 strokeWidth=0.01`; open: `fill=none stroke=#000 strokeWidth=line` (G:214-217) | none | none | none |
| `gap` | `fill=none stroke=#000 strokeWidth=line*3` (G:218) | none | drawn as outline like `line` (G:226) | none |
| `inlay` | `fill=none stroke=#000 strokeWidth=line*2` (G:219) | none | none | `fill=currentColor stroke=none` (G:229) |
Every element also gets `strokeLinecap/Join = round` (G:211) and the icon's own attrs underneath (the overrides above win because they
are spread later). `cut`/`gap`/`inlay` in ANY layer cut the fill pass of EVERY layer (one shared mask, G:195, G:254-260).

### Draw order and structure (G:243-264)
1. `<svg width=size height=size viewBox="vx vy vw vh" fill=none round caps/joins style=overflow:visible>` (no clipping).
2. If any layer has cut/gap/inlay: a `<mask maskUnits=userSpaceOnUse x=-24 y=-24 width=72 height=72>` = white rect over that area, then the "mask" pass in black (G:254-259).
3. `<g mask>` containing the "fill" pass.
4. "line" pass, then "inlay" pass (unmasked). Each layer is its own `<g transform=...>` (G:238); empty layers are skipped (G:237).
So paint order: solids (with holes) < outlines < inlays. Layers draw in array order, main icon first.

### Stroke width (G:148, G:200)
`strokeAt(s) = round2(2 * (22 / s) ** 0.35)` grid units, where `s = size * 24 / vw` (the box size the whole 24-grid would have at this
scale; with the default view it is just `size`). Examples: 22 pt -> 2.00 units (1.83 pt); 12 pt -> about 2.5; 44 pt -> about 1.6 (G:143-147).
Icons' own 1.5 stroke is ignored for `line`, `heavy`, `gap` and open `cut` (all use `line`).
Rounded to 2 decimals via `Math.round(x*100)/100`.

### Placement (G:101-112, G:163-175)
Per layer: `at=[x,y]` (default 12,12; where the icon's grid centre lands), `scale` (1), `turn` clockwise degrees (0), `mirror` (false), `stretch` (height factor, 1).
SVG transform, unless it is the identity (`plain` = at is 12,12 and sx==1 and scale*stretch==1 and turn==0):
`translate(x y) scale(sx, scale*stretch) rotate(turn) translate(-12 -12)` with `sx = scale * (mirror ? -1 : 1)`.
Note the order: the rotate is applied before the non-uniform scale in the matrix product, i.e. the stretch is applied after the turn (screen-space Y).
Widths keep the glyph weight:
- not stretched: `width(units) = units / scale` (G:207) so a 0.3-scaled record dot or 0.55 arrow still has the same absolute stroke;
- stretched: `vectorEffect="non-scaling-stroke"` (G:208) and `width(units) = units * size / vw` in screen px (G:207). In Swift: stroke the path after the transform, in device points, with width `units*size/vw`.
Mirror does not change widths (scale is positive).

### View (G:132-136, G:247-248, G:319, G:326, G:342)
`viewBox = [vx vy vw vh]`; a smaller window draws the ink larger. `centredView(inkUnits, share)` (G:270-274): `side = round2(inkUnits/share)`,
`start = round2(12 - side/2)`, returns `[start, start, side, side]`. Used by: PlayerPause/Play (`centredView(16, 27.6/30)`, G:319), PlayerForward/Back
(`centredView(17.5, 31.5/34)`, G:326), AudioOutput (`centredView(21, 21/27.5)`, G:342).

### Component wrappers (glyph.tsx, T)
- `Glyph` (T:43-58): island glyphs render in a `size x size` (default 22 = `islandSize.compactGlyph`) block, colour via CSS `color`, no scaling. Foreign icons are drawn `size*1.1` with a -5% margin (T:40, T:54-55): ink about 80% of box.
- `IconTile` (T:127-157): tile `size` (default `islandSize.expandedTile` = 52), squircle path (corner `expandedTileRadius/expandedTile` = 12/52, T:85) or circle; glyph box = `round(size * share)` with share squircle 0.58 / circle 0.50 for island glyphs (T:76-79, 139); gradient from `shade(accent, +0.06)` top to `shade(accent, -0.06)` bottom (T:149-150); ink white or `rgba(0,0,0,0.82)` when relative luminance > 0.6 (T:110-119); glyph drop shadow `0 0.5px 1px rgba(0,0,0,0.22)` (T:155).

### Preset recipes worth copying exactly (G:276-502)
Play = `pick(Triangle01Icon,0)`, parts fill, place `{at:[12.4,12], scale:0.8, turn:90}` (G:286-288); Pause = PauseIcon fill; Stop = StopIcon fill; Close = Cancel01Icon line;
Next/Previous = NextIcon/PreviousIcon parts `[fill,line]`; Forward = FastForwardIcon fill; Backward = same, `place {mirror:true}`; Music = MusicNote03Icon `[fill,fill,line,line]`;
AudioOutput = `pick(VolumeHighIcon,0)` fill + layer `pick(VolumeHighIcon,1,2)` (line) with `stretch 1.35`; Video = Video02Icon `[cut,fill,fill]`; Pin = Location01Icon `[fill,cut]`;
Upload = hand-made cloud contour (fill) + ArrowUp02Icon cut at `[12,13.6]` scale 0.55; Mic = Mic01Icon `[fill,line]`; Bolt = FlashIcon fill; Star = StarIcon fill; Heart = FavouriteIcon fill;
Timer = StopWatchIcon `[heavy,line,cut]`; Car = hand-made body fill + windows cut + `pick(Car03Icon,0,1)` inlay.

### Swift reimplementation sketch (exact)
Render each glyph to one CGPath-per-role bucket. Build `fillPaths` (solid roles), `maskPaths` (cut/gap/inlay with stroke widths above), `linePaths`, `inlayPaths`.
Draw in a `Canvas`/`CGContext`: scale 24-grid by `size/vw` after translating by `-vx,-vy`; `ctx.beginTransparencyLayer`, fill `fillPaths`, then for the mask use `.blendMode(.destinationOut)` with closed cuts filled + stroked 0.01 and open cuts / gaps / inlay-gaps stroked at the widths above; end layer; stroke `linePaths` (round caps/joins) at `line`; fill `inlayPaths`. Per-layer transform and the stretched case (stroke in device space: `path.applying(transform)` then stroke at `units*size/vw`) as above. Need an SVG path-d parser (M L H V C S Q T A Z, relative forms), plus circle/rect/ellipse/line/polyline for non-path elements.

## 2. SF Symbols in Isla (static names found by grep of `systemName:`, `systemSymbolName`, `symbol:` and string tables)
Legend. G = existing islandcn glyph (name in `islandGlyphs`, G:505). H = other Hugeicons free icon (recipe suggested; `?` = name unverified). N = no good match (see notes).
`.fill` variants map to the same icon with a solid recipe (`parts: "fill"` where the icon is closed) or the plain outline; the SF outline/fill pair collapses to one glyph unless noted.
Counts at the bottom. Line numbers relative to `Sources/IslaKit/`.

### Transport and media
| SF symbol | Where | Map | Kind |
|---|---|---|---|
| play.fill | UI/NotchContentView.swift:1328; UI/LockScreenCard.swift:718; UI/LiveActivityViews.swift:254; UI/TransportGlyphButton.swift:35 | PlayGlyph / PlayerPlayGlyph | G |
| pause.fill | UI/LockScreenCard.swift:718; UI/LiveActivityViews.swift:254; UI/TransportGlyphButton.swift:35 | PauseGlyph / PlayerPauseGlyph | G |
| backward.fill | UI/TransportGlyphButton.swift:34 | PreviousTrackGlyph (skip) or PlayerBackGlyph (seek: BackwardGlyph) | G |
| forward.fill | UI/TransportGlyphButton.swift:36 | NextTrackGlyph / PlayerForwardGlyph | G |
| music.note | UI/LyricsStage.swift:663; UI/MediaPane.swift:866; UI/LockScreenCard.swift:651; UI/NotchContentView.swift:1305; UI/SurfaceHeader.swift:285; UI/LyricRow.swift:509; UI/SettingsPane.swift:1162; UI/SettingsTable.swift:84,314; UI/SettingsIcon.swift:43; App/IslaIntents.swift:271 | MusicGlyph | G |
| speaker.wave.2 / .wave.2.fill | UI/TranslatePane.swift:766; UI/OutputMenu.swift:133; UI/SettingsIcon.swift:74; UI/SettingsTable.swift:319; Model/HUDMoment.swift:55; Services/AudioOutputs.swift:154; Services/AudioOutputGlyph.swift:162,181,183,239; Services/PlayerVolume.swift:282,287 | AudioOutputGlyph (VolumeHighIcon) | G |
| speaker.wave.3.fill | UI/SystemVolumeSlider.swift:250; UI/StageVolumeControl.swift:61; Model/HUDMoment.swift:55; Services/PlayerVolume.swift:288 | AudioOutputGlyph or VolumeHighIcon | G |
| speaker.wave.1.fill | Model/HUDMoment.swift:55; Services/PlayerVolume.swift:286 | VolumeLowIcon ? (recipe fill on element 0, line on waves) | H |
| speaker.fill | UI/SystemVolumeSlider.swift:237; UI/StageVolumeControl.swift:52; Model/HUDMoment.swift:56; Services/PlayerVolume.swift:285 | `pick(VolumeHighIcon,0)` alone (the solid speaker, no waves) | G (derived) |
| speaker.slash.fill | UI/SystemVolumeSlider.swift:233,237; Model/HUDMoment.swift:57; Services/PlayerVolume.swift:283 | VolumeMute01Icon ? / VolumeOffIcon ? | H |
| mic.fill | UI/LiveActivityViews.swift:91,351; UI/SettingsTable.swift:317 | MicrophoneGlyph | G |
| mic.slash.fill | UI/LiveActivityViews.swift:91,351 | MicOff01Icon ? (same fill recipe as Mic) | H |
| video.fill | UI/LiveActivityViews.swift:90 | VideoGlyph | G |
| video.slash | UI/SettingsIcon.swift:111 | VideoOffIcon ? | H |
| video.badge.plus | UI/SettingsIcon.swift:37 | VideoGlyph + small plus layer (Add01Icon at scale 0.4) or Video02Icon alone | H (composed) |
| stopwatch.fill | UI/LiveActivityViews.swift:88 | TimerGlyph | G |
| timer | UI/HUDViews.swift:271; UI/LiveActivityViews.swift:422 | TimerGlyph or Timer02Icon ? / AlarmGlyph | G |
| waveform | UI/LiveActivityViews.swift:210; Services/AudioOutputGlyph.swift:183 | AudioWave01Icon ? | H |
| shuffle | UI/LyricHeaderTools.swift:102 | ShuffleIcon ? | H |
| repeat | UI/LyricHeaderTools.swift:103 | RepeatIcon ? | H |
| metronome | UI/SettingsIcon.swift:73 | none; nearest Clock01Icon ? / Timer02Icon ? | N |
| quote.bubble / .fill | UI/LyricsStage.swift:838,842,845; UI/LockScreenCard.swift:1050,1453; UI/LyricsStageSurface.swift:308; UI/SettingsIcon.swift:45; UI/SettingsTable.swift:85; App/IslaIntents.swift:253 | QuoteDownIcon ? (or MessageGlyph + quote) ; lyrics glyph | H |
| text.quote | UI/SettingsIcon.swift:30; App/IslaIntents.swift:262 | QuoteUpIcon ? / TextQuoteIcon ? | H |
| text.alignleft | UI/SettingsIcon.swift:76; UI/ClipboardLayout.swift:205; Services/ClipboardKinds.swift:88; Services/ClipboardStore.swift:97 | TextAlignLeft01Icon ? | H |
| text.bubble | UI/SettingsIcon.swift:78 | Message01Icon ? / MessageGlyph | H |
| text.word.spacing | UI/SettingsIcon.swift:47 | none (TextIcon ? approximates) | N |
| text.append | UI/SettingsIcon.swift:49 | none (Add01Icon + lines) | N |
| character.bubble / .fill | UI/SettingsIcon.swift:105; UI/LyricHeaderTools.swift:498; Model/Surface.swift:56 | TranslateIcon ? (also `translate` below) | H |
| translate | UI/SettingsIcon.swift:35; UI/SettingsTable.swift:88 | TranslateIcon ? | H |
| lyrics.lrc, lyrics.translate, translate.source/target, island.*, outline.path, etc. | not SF Symbols: UserDefaults / identifier strings | n/a | n/a |

### Arrows, chevrons, status
| SF symbol | Where | Map | Kind |
|---|---|---|---|
| arrow.down.circle / .fill | Notch/ExpandedAlertShape.swift:137; UI/LiveActivityViews.swift:92; UI/TranslateLayout.swift:396; UI/SettingsIcon.swift:118; UI/SettingsTable.swift:318; Model/IslandConfirmation.swift:55 | DownloadGlyph | G |
| arrow.down.to.line | UI/SettingsIcon.swift:120 | DownloadGlyph | G |
| tray.and.arrow.down / .fill | UI/WelcomePane.swift:181; UI/SettingsIcon.swift:35 (`square.and.arrow.down`); Model/IslandConfirmation.swift:53 | DownloadGlyph | G |
| arrow.up.forward.app | UI/SettingsIcon.swift:16 | ArrowUpRight01Icon ? | H |
| arrow.left.arrow.right | UI/TranslatePane.swift:327 | ArrowDataTransferHorizontalIcon ? / ArrowLeftRightIcon ? | H |
| arrow.left.and.right | UI/SettingsIcon.swift:20; UI/WelcomePane.swift:180 | ArrowHorizontalIcon ? | H |
| arrow.right | UI/SettingsIcon.swift:80 | ArrowRight01Icon ? | H |
| arrow.up (ArrowUp02 is in glyphs) | none in Isla | ArrowUpGlyph (unused here) | n/a |
| arrow.clockwise | UI/SettingsIcon.swift:57; UI/LyricHeaderTools.swift:101 | Refresh... : RefreshIcon ? / ReloadIcon ? | H |
| arrow.counterclockwise | UI/SettingsIcon.swift:68; UI/LiveActivityViews.swift:259 | Undo02Icon ? / RotateLeft01Icon ? | H |
| arrow.uturn.backward | UI/SettingsIcon.swift:32 | Undo02Icon ? | H |
| arrow.triangle.2.circlepath | UI/SettingsIcon.swift:59 | RepeatIcon ? / RefreshIcon ? | H |
| chevron.right | UI/SettingsPane.swift:954 | ArrowRight01Icon ? | H |
| chevron.left | UI/LockScreenCard.swift:879,1219 | ArrowLeft01Icon ? | H |
| chevron.up | UI/LockScreenCard.swift:781 | ArrowUp01Icon ? | H |
| chevron.up.chevron.down | UI/SettingsPane.swift:2231; UI/TranslateMenus.swift:146 | UnfoldMoreIcon ? | H |
| checkmark | UI/LockScreenCard.swift:1302; UI/Confirmation.swift:69 | CheckGlyph | G |
| checkmark.circle.fill | UI/ClipboardPane.swift:655,879; Model/IslandConfirmation.swift:51 | CheckCircleGlyph | G |
| xmark | UI/ClipboardPane.swift:678,856; UI/SurfaceHeader.swift:162; UI/LiveActivityViews.swift:259 | CloseGlyph | G |
| xmark.circle / .fill | UI/TranslatePane.swift:561; UI/ShelfPane.swift:480; UI/ClipboardControls.swift:97; UI/SettingsIcon.swift:61 | CancelCircleIcon ? (line) | H |
| exclamationmark.circle | UI/LyricsStage.swift:216 | AlertCircleIcon ? | H |
| exclamationmark.bubble | UI/LyricsStage.swift:884; UI/TranslateLayout.swift:401,414; UI/SettingsIcon.swift:117 | WarningGlyph (Alert02Icon) or MessageGlyph + mark | G (approx) |
| info.circle | UI/MediaPane.swift:826; UI/TranslateLayout.swift:405; UI/SettingsIcon.swift:114 | InformationCircleIcon ? | H |
| plus | UI/LocalLyricsEditorView.swift:96; UI/SettingsPane.swift:2037; UI/LyricHeaderTools.swift:97 | Add01Icon ? | H |
| minus | UI/LocalLyricsEditorView.swift:97; UI/SettingsPane.swift:2037; UI/LyricHeaderTools.swift:96 | MinusSignIcon ? | H |
| plus.circle | UI/LocalLyricsEditorView.swift:111 | AddCircleIcon ? | H |
| minus.circle | UI/LyricHeaderTools.swift:99 | MinusSignCircleIcon ? | H |
| ellipsis | UI/LyricHeaderTools.swift:232 | MoreHorizontalIcon ? | H |
| magnifyingglass | UI/ClipboardPane.swift:342; UI/ClipboardControls.swift:84 | SearchGlyph | G |
| clock.arrow.circlepath | UI/NotchContentView.swift:1146; UI/LyricsStage.swift:218 | TimeQuarterPassIcon ? / Clock... History: `Time...` ; closest GlyphRecipe: ClockIcon ? | H |

### Objects, files, clipboard, shelf
| SF symbol | Where | Map | Kind |
|---|---|---|---|
| doc.on.clipboard / list.clipboard / .fill / list.bullet.clipboard | UI/TranslatePane.swift:515; UI/ClipboardPane.swift:287; UI/SettingsIcon.swift:29,102,104; Model/Surface.swift:55 | Clipboard / ClipboardIcon ? (recipe line; `.fill` = fill) | H |
| doc.on.doc / .fill | UI/Confirmation.swift:69; UI/ClipboardLayout.swift:211; Services/ClipboardStore.swift:103; Model/IslandConfirmation.swift:52 | Copy01Icon ? | H |
| doc / doc.text | Services/ClipboardKinds.swift:90; Services/ClipboardStore.swift; UI/SettingsTable.swift:322 | File01Icon ? / File02Icon ? | H |
| doc.badge.plus | UI/SettingsIcon.swift:52; UI/LyricHeaderTools.swift:100 | DocumentPlusGlyph (FilePlusCornerIcon) | G |
| folder / .badge.plus / .badge.minus | UI/SettingsIcon.swift:36,53,56 | Folder01Icon ? / FolderAddIcon ? / FolderRemoveIcon ? | H |
| tray / tray.full / tray.full.fill | UI/ShelfPane.swift:78; Services/ShelfLayout.swift (UI/ShelfLayout.swift:520); UI/IslandBubble.swift:118; UI/NotchContentView.swift:1041,1111; Model/Surface.swift:58; Model/IslandConfirmation.swift:54 | InboxIcon ? / Archive02Icon ? (best), or PackageGlyph | H |
| trash | UI/ShelfPane.swift:156; UI/SurfaceHeader.swift:336; UI/SettingsIcon.swift:40 | Delete02Icon ? | H |
| photo | UI/ClipboardLayout.swift:209; Services/ClipboardKinds.swift:89; Services/ClipboardStore.swift:101; UI/SettingsIcon.swift:107 | Image01Icon ? | H |
| link | Services/ClipboardKinds.swift:89; Services/ClipboardStore.swift:100 | Link01Icon ? | H |
| curlybraces | Services/ClipboardStore.swift:99 | SourceCodeIcon ? / CodeIcon ? | H |
| square.fill | Services/ClipboardStore.swift:98 (colour kind swatch) | PaintBoardIcon ? / draw a plain rounded rect | H |
| square.grid.2x2 | Services/ClipboardKinds.swift:87 | GridViewIcon ? / Layout... | H |
| pin / pin.fill | UI/ClipboardPane.swift:675,796,853; UI/SettingsIcon.swift:108 | PinGlyph (Location01Icon is a location pin: wrong meaning; use PinIcon ?/PinLocation01Icon ?; keep PinGlyph only if the map-pin look is accepted) | H |
| eye / eye.slash | UI/SpoilerField.swift:180; UI/SettingsIcon.swift:70 | ViewIcon ? / ViewOffIcon ? | H |
| hand.raised / .fill | UI/ClipboardPane.swift:372; UI/SettingsIcon.swift:90; UI/SettingsTable.swift:80 | RaisedHandIcon ? / HandPrayerIcon ? (weak) | N (weak) |
| lock.fill / lock.display | UI/TranslatePane.swift:734; UI/SettingsIcon.swift:81; UI/SettingsTable.swift:89 | LockIcon ? / ComputerIcon + lock | H |
| key | UI/SettingsIcon.swift:97 | Key01Icon ? | H |
| keyboard / keyboard.fill | UI/WelcomePane.swift:183; UI/SettingsTable.swift:81 | KeyboardIcon ? | H |
| gearshape / .fill | UI/SurfaceHeader.swift:162; UI/SettingsIcon.swift:84; UI/SettingsTable.swift:79; Model/Surface.swift:57 | Settings01Icon ? / Settings02Icon ? | H |
| power | UI/LiveActivityViews.swift:359; UI/SettingsIcon.swift:121 | PowerSocket... : ShutDownIcon ? | H |
| star / star.fill | UI/MediaPane.swift:681; UI/LockScreenCard.swift:1592 | StarGlyph (fill) / StarIcon line for the off state | G |
| stethoscope | UI/SettingsIcon.swift:116 | none (Activity01Icon ? / Pulse... ) | N |
| person.crop.circle.badge.plus / .minus | UI/SettingsIcon.swift:95,96 | UserAdd01Icon ? / UserRemove01Icon ? | H |
| at | UI/SettingsTable.swift:97 (fallback) | AtIcon ? | H |
| camera.viewfinder | UI/SettingsTable.swift:98 (fallback) | Camera01Icon ? / ScreenshotIcon ? | H |
| globe | UI/SettingsIcon.swift:66; UI/TranslateLayout.swift:405 | GlobeGlyph | G |
| bolt / bolt.fill | UI/ChargingActivityView.swift:198,234,237; Model/AmbientActivity.swift:93; UI/SettingsIcon.swift:21 | BoltGlyph | G |
| powerplug.fill | Model/AmbientActivity.swift:92 | PowerSocket01Icon ? | H |
| battery.25percent | UI/SettingsTable.swift:315 | BatteryLowIcon ? | H |
| battery.100percent.bolt | UI/SettingsTable.swift:316 | BatteryChargingGlyph | G |
| headphones | UI/SettingsIcon.swift:22; Services/AudioOutputGlyph.swift (many lists) | HeadphonesGlyph | G |
| sun.max.fill | Model/HUDMoment.swift:52 | Sun01Icon ? (fill) | H |
| light.max | Model/HUDMoment.swift:53 (keyboard backlight) | none; Sun01Icon variant or custom | N |
| cursorarrow.rays | UI/SettingsIcon.swift:18 | none exact; CursorPointer01Icon ? | N (weak) |
| cursorarrow.motionlines | UI/SettingsIcon.swift:19 | none exact | N |
| cursorarrow.click | UI/WelcomePane.swift:176 | CursorPointer02Icon ? / Cursor... | H (weak) |
| rectangle.topthird.inset.filled | UI/SettingsIcon.swift:27 | none (LayoutTop... ? e.g. LayoutTopIcon ?) | N (weak) |
| rectangle.compress.vertical | UI/SettingsIcon.swift:82 | UnfoldLessIcon ? | H |
| menubar.rectangle | UI/SettingsIcon.swift:84 | none (LayoutTopIcon ?) | N (weak) |
| circle.lefthalf.filled | UI/SettingsIcon.swift:87 | ContrastIcon ? / ContrastDropIcon ? | H |
| dot.radiowaves.up.forward | UI/ShelfLayout.swift:440; Model/IslandConfirmation.swift:56 (AirDrop fallback) | Wifi01Icon ? / BroadcastIcon ? | H (weak) |
| square.and.arrow.down | UI/SettingsIcon.swift:35 | DownloadGlyph | G |
| transform.scale.y, bounds.size.*, marquee.*, karaoke.sweep, playback.fill | not SF Symbols (animation keyPaths / identifiers) | n/a | n/a |

### Device / output symbols (dynamic, chosen by name at run time; Services/AudioOutputGlyph.swift:16-243, UI/OutputMenu.swift:130-133, UI/NotchContentView.swift:1010, UI/LockScreenCard.swift:1289)
| SF symbol | Lines | Map | Kind |
|---|---|---|---|
| laptopcomputer | AudioOutputGlyph.swift:18 | LaptopGlyph | G |
| desktopcomputer, macmini, macstudio, macpro.gen3 | :19-21 | DesktopGlyph | G |
| headphones, earbuds, earpods | :133-148 | HeadphonesGlyph (earbuds/earpods: HeadphonesIcon, no earbud icon in the free set) | G |
| airpods, airpods.pro, airpods.pro.gen3, airpods.gen3, airpods.gen4, airpods.max | :190-201 | HeadphonesGlyph (AirPods Max); no AirPods icon | N (use Headphones) |
| beats.* (headphones, earphones, powerbeats(.pro), studiobuds(.plus), fitpro, solobuds, pill) | :229-243 | HeadphonesGlyph / speaker | N (use Headphones) |
| homepod, homepod.mini, hifispeaker | :134, :152 | Speaker01Icon ? | H |
| appletv, tv | :135, :174 | Tv01Icon ? | H |
| display | :137, :176 | ComputerIcon / DesktopGlyph | G |
| airplayaudio | :173 | AirplayLineIcon ? / Cast... | H |
| car | :166 | CarGlyph | G |
| waveform | :183 | AudioWave01Icon ? | H |

Note: `HUDSymbol.personalDevices` (Model/HUDMoment.swift:64) and `AudioOutputs.outputFallbackSymbol` are device lists too; every case collapses to the glyphs above.

## Counts (distinct SF Symbol names; `.fill`/outline pairs counted separately; non-symbol identifier strings excluded)
Table rows (one row = one symbol or an outline/fill/variant family, about 140 distinct names in total): about 32 map to an islandcn glyph (G), about 64 to another Hugeicons icon (H, names marked ? are unverified), about 12 have no good match (N: metronome, text.word.spacing, text.append, hand.raised, stethoscope, light.max, cursorarrow.rays, cursorarrow.motionlines, rectangle.topthird.inset.filled, menubar.rectangle, airpods.*, beats.*). Device symbols fall back to HeadphonesGlyph.

## 3. Obtaining the Hugeicons path data for vendoring
Evidence from the repo: `package.json` pins `@hugeicons/core-free-icons` 4.4.0 and `@hugeicons/react` 1.1.10; `pnpm-lock.yaml:787-788` records
`@hugeicons/core-free-icons@4.4.0` with integrity `sha512-7Mz8bmGoY6tZ6l3C2TXwNMLVSr0I8HPwjjFIERAuJFj3rWwLxdF2ZLkDqdrVuEE1dx5b/VXyIsP4WoSU6Q40KQ==` (no dependencies, lock line 6659).
glyphs.tsx imports named, tree-shakable exports (`import { StarIcon, ... } from "@hugeicons/core-free-icons"`, G:3-54) typed as `IconSvgElement`
(type from `@hugeicons/react`, G:55) = `Array<[tag, attrs]>` with the attrs carrying `d`, `stroke`, `strokeWidth`, `strokeLinecap`, `strokeLinejoin`, `key` (as `pathIcon` mimics at G:181).
Inferred layout (not verified, nothing downloaded): the package ships ESM/CJS bundles with one `export const <Name>Icon = [...]` per icon plus `.d.ts`; each icon is a literal array, so the data can be read by importing the module in Node.

Plan (to run later, in a fresh empty scratch dir, not in this task):
1. `npm pack @hugeicons/core-free-icons@4.4.0` (checks the sha512 above with `npm view ... dist.integrity`), untar into its own empty directory.
2. A small Node script (run with `node --input-type=module`, kept outside the extracted directory) imports the named icons used in the recipes
   (`Triangle01Icon`, `PauseIcon`, `StopIcon`, `NextIcon`, `PreviousIcon`, `FastForwardIcon`, `VolumeHighIcon`, `MusicNote03Icon`, `StopWatchIcon`, `Cancel01Icon`, ... plus the `?` names from section 2),
   and writes JSON `{ "Name": [["path", {"d": "..."}], ...] }`, keeping `tag` and every geometric attr (`d`, `cx`, `cy`, `r`, `x`, `y`, `width`, `height`, `rx`, `points`, `fillRule`, `clipRule`, `opacity`).
   The key list printed at step 2 is also the check that each `?` name exists in 4.4.0.
3. Vendor as a Swift table (`[String: [Element]]` of SVG path strings, parsed once at launch into CGPath) or a JSON resource; keep the MIT license text from the package (`LICENSE`) in `THIRD_PARTY_NOTICES.md`, and note the Hugeicons source and version in the notice. Add the hand-made `cloudContour`, `carBody`, `carWindows` paths from G:376-378, 440-448 verbatim (they are islandcn's own, not Hugeicons').
4. Alternative with no npm: the same package's data is also on unpkg/jsDelivr (`https://cdn.jsdelivr.net/npm/@hugeicons/core-free-icons@4.4.0/`) as static files; the file list there shows the exact layout before choosing. A `pnpm install` in `islandcn-src` would also populate `node_modules/@hugeicons/core-free-icons`.
Caveat for the Swift parser: non-`path` tags (`circle`, `rect`, `ellipse`, `line`, `polyline`) count as closed (G:158) and `cut` treats them as holes.
