# Activity gap audit: islandcn vs Isla

Read-only. Nothing built or launched. islandcn source = `.../scratchpad/islandcn-src` (git HEAD `0011a41`), paths below are relative to it; Isla = worktree `/Users/ctimothe/code/personal/isla-mac/.claude/worktrees/islandcn` (HEAD `99a51e7`), paths relative to it. All sizes are CSS px = pt. `theme.ts` = `components/islandcn/theme.ts`.

## 0. Findings that change the brief

1. **The AI-agent preset does not exist in islandcn.** It shipped once and was removed: `components/site/playground/url-state.ts:127-146` says "Kinds the AI task preset had, removed with it" and maps old links to a plain `Sparkle` glyph + `buttons`. git has only 5 commits (no history of it), `registry/presets.json` has no agent entry, `app/play/demos.tsx` (77 lines) and `real-presets.tsx` (346 lines) have no agent. What remains upstream of it: colour `lagoon #46f0c6` ("islandcn's own colour, used by the agent preset", `theme.ts:23-24`), `islandMono` ("For commands and paths in the agent preset", `theme.ts:15-16`), `TerminalGlyph`, `SparkleGlyph`, `WrenchGlyph`, `PencilGlyph`, `SearchGlyph`, `GlobeGlyph`, `GitMergeRequestGlyph` (`glyphs.tsx:398-413`), `ShimmerText`, `TailText` ("an agent's latest output", `tail-text.tsx:23`), `StepProgress`, and two written recipes: "A transcript (live captions, translation, an agent's output)" (`skills/islandcn/references/recipes.md:375`) and "Approval (agent asks...)" (`recipes.md:379-450`). So section 11 below specifies the agent island as islandcn's own primitives and recipes compose it, with the numbers those give, and marks every number that is Isla's to choose.
2. **islandcn has one battery preset, not Low/Full cards.** `battery-activity.tsx` draws the charging pill and the same row expanded; "low" is only a red percentage and battery (label = device name, detail "Low battery"). Isla's Battery Low and Full Battery are iPhone-style cards that islandcn has no equivalent of (section 7).
3. islandcn also has a `split` demo (two activities side by side, `examples/split-demo.tsx`) that is a layout state of the engine, not an activity. Not specified here.
4. islandcn is drawn for an iPhone: 402 pt screen, idle pill 94.85 x 36.84, expanded island width = screen less 2 x 13.83. Isla's expanded body is a different width (480...620, default 560 per CLAUDE.md), so "identical" must be defined as identical element sizes, fonts, colours, spacing inside each slot, and not identical island width. Slot geometry that depends on the island width (`besideSensor`, side insets) is flagged where it matters.

## 1. Shared tokens (`theme.ts`)

Font: `islandFont = '-apple-system, BlinkMacSystemFont, "Inter", "Geist", system-ui, sans-serif'` (`theme.ts:13`) = SF on a Mac. `islandMono = 'ui-monospace, "Geist Mono", "JetBrains Mono", Menlo, Consolas, monospace'` (`theme.ts:16`).

Accents (`theme.ts:22-33`): lagoon `#46f0c6`, green `#32d74b`, red `#ff453a`, orange `#ff9f0a`, yellow `#ffd60a`, blue `#0a84ff`, sky `#64d2ff`, pink `#ff375f`, purple `#bf5af2`.

Ink (`theme.ts:38-50`): primary `#ffffff`; secondary `rgba(235, 235, 245, 0.62)`; tertiary `rgba(235, 235, 245, 0.36)`; track `rgba(255, 255, 255, 0.16)`; fill `rgba(255, 255, 255, 0.14)`; fillPressed `rgba(255, 255, 255, 0.24)`.

Sizes (`theme.ts:52-71`): compactGlyph 22; compactText 15; expandedTile 52; expandedTileRadius 12; expandedValue 34; title 17; subtitle 15; caption 13; button 44.
Line heights (`theme.ts:74-81`): compact 20; title 22; subtitle 20; caption 16; stackGap 1.
Baselines below line-box top (`theme.ts:97-102`): title 17, subtitle 16, value 30, caption 13.
Tracking pt (`theme.ts:192-198`): 13 -> 0; 15 -> 0; 17 -> -0.045; 20 -> -0.11; 34 -> -0.09. `trackingFor` returns 0 for any other size (`theme.ts:203`).
`tint(hex, a)` = `rgba(r, g, b, a)` (`theme.ts:214-223`).

Engine geometry that the content depends on (`lib/island/metrics.ts`): idle 94.85 x 36.84 (`:14`); compact height 36.85, sensorWidth 94.85, edgePadding 7.18, innerPadding leading -0.18 / trailing 0.07, maxSlotWidth 72, balance 0.7475 (`:15-43`); minimal height 36.85, attached outerPadding 7.09 / innerPadding 8.4, detached padding 6.42 / minWidth 36.85, gap 7.82 (`:44-52`); corner smoothing 0.72 (`:90`); expanded: sideInset 13.83, top 13.83, minHeight 84, maxHeight 180, radius 47.9, padding top 18.18 / side 18.5 / trailing 17.81 / bottom 18.35, centerTop 1.33, rowGap 8 (`:91-132`); contentClip radius 34.4 (`:179-189`).
Derived (`theme.ts:89-185`): centerTop = max(0, 13.91 + 36.84 - (13.83 + 18.18)) + 1.33 = 20.07; titleStack 63.07; subtitle 40.07; stackLine 41.57; titleLine 31.07; subtitleLine 30.07; titleBaseline 37.07; subtitleBaseline 59.07; islandSafe.action leading 7.4 / trailing 8.09 / bottom 7.85; lift 13.7; mirror 0.69; drop 4; besideSensor = floor((375 - 27.66 - 94.85)/2 - 18.5) - 4 = 103.

Mac note: on Isla the sensor is the real notch (about 180-200 pt wide, 32 pt tall) and not 94.85 x 36.84. Every number in "compact" (7.18 edge padding, -0.18 inner padding, 36.85 height) was calibrated to that pill; they transfer as slot-internal numbers, not as the pill's own size.

## 2. Primitives

### 2.1 Text styles (`island-text.tsx`)
All text: `font-family islandFont`, `white-space nowrap`, overflow hidden, ellipsis, `-webkit-font-smoothing antialiased`, proportional digits unless stated (`island-text.tsx:19-29`). Titles and subtitles use a one-line `-webkit-line-clamp: 1` so the ellipsis follows the last whole word (`:37-43`).
- `CompactText` 15 / 600 / line 20, tracking 0 (`:86-90`); colour default `#fff`.
- `ExpandedValue` 34 / 700 / line-height 1 (34), tracking -0.09 (`:107-132`). A word unit ("min") follows in 17 / 600 / tracking -0.045, margin-left 3 (`:129`); a sign unit ("%", "deg") is set at the figure's size/weight, margin-left -0.04em (`:126-128`). Overflow `clip visible`.
- `ExpandedTitle` 17 / 600 / line 22 / tracking -0.045 / white (`:135-139`).
- `ContextLabel` 15 / 500 / line 20 / `rgba(235,235,245,0.62)` (`:145-149`).
- `ExpandedSubtitle` 15 / 400 / line 20 / secondary (`:152-156`).
- `Caption` 13 / 500 / line 16 / secondary (`:159-163`).
- `TitleStack` grid gap 1: `ExpandedTitle` over `ExpandedSubtitle` (`:166-194`).
- `NumberText`: tabular-nums, three motions: "live" = engine `IslandNumber` (old digit shrinks+blurs+fades, 0.48 s), "steady", "none" (`:55-83`). Reduced motion = in place.
- `feedTurn = 0.25` s (`:50`).
- `MinimalPair`: flex row gap 7: leading + trailing (`:200-210`).
- `Swap`: `@keyframes icn-swap-in { from { opacity 0; filter blur(4px); transform scale(0.9) } }` 260 ms `cubic-bezier(0.2, 0, 0, 1)` (`:250-254`).
- `BubbleForm`/`withBubble`: alternative content in the split bubble (`:212-248`); not applicable on Mac unless Isla has a split.

### 2.2 Layout (`island-layout.tsx`)
- `ExpandedBottom` grid, one `minmax(0,1fr)` column, gap default 8; `reach`: none / inset (padding-left 13.8-ish `bottomInset.leading`, right 14.5-ish) / lift (padding-bottom 13.7, right 0.69) / action (padding 7.4 / 8.09 / bottom 7.85) (`:75-95`).
- `ExpandedSide` flex frame, default height 52, centred on a `line` (`:240-244`).
- `ValueStack`: value (34 pt) over a `Caption`, value baseline on the title's (37.07) and caption baseline on the subtitle's (59.07); no-caption variant centres the 34 pt value in an `ExpandedSide` height 34 (`:168-187`).
- `CaptionButton`: 13 / 600 / line 16, accent colour, hit area 44 tall x +12 each side (`:200-234`).
- `SensorSide`: flex gap 7, max-width besideSensor (103) (`:250-279`).
- `SensorRow`: height `sensorRowHeight` = 26, gap 7, maxWidth 103, trailing paddingRight 8.09 (`:282-315`). Used by upload / transfer / battery / ride label rows.
- `BottomBar`: padding-left `bottomInset.leading`, right `bottomInset.trailing`, top 4 (`:322-324`).

### 2.3 Buttons (`island-button.tsx`)
- `IslandButton`: height 44, radius 22, padding `0 18px` regular (17 pt/600/tracking -0.045) or `0 12px` compact (15 pt/600/0); gap 6; neutral bg `rgba(255,255,255,0.14)`, fg `#fff`; accent bg = accent, fg `#000` (`:10-90`). Hover brightness 1.12; pressed `scale(0.96)` + brightness 0.9 over 160 ms `cubic-bezier(0.22, 1, 0.36, 1)`; disabled opacity 0.4; focus outline 2 px offset 2 (`:11-24`).
- `IslandRoundButton`: circle, default 44, bg `rgba(255,255,255,0.14)`, icon `#fff`, same press behaviour (`:110-140`).

### 2.4 Glyph and tile (`glyph.tsx`, `glyphs.tsx`)
- `Glyph`: box default 22, colour default `#fff` (`glyph.tsx:43-58`). Glyphs are Hugeicons free icons redrawn "at the island's weight, solid where system glyphs are" (`registry/presets.json` island-content description); `glyphFrom` at `glyphs.tsx:186`. Inventory with the Hugeicons source icon: TimerGlyph (StopWatchIcon, heavy+line+cut), PlayGlyph (Triangle01, fill), PauseGlyph (PauseIcon, fill), StopGlyph, CloseGlyph (Cancel01), Next/Previous/Forward/BackwardGlyph, MusicGlyph (MusicNote03), PlayerPause/Play/Forward/BackGlyph (own viewBox), AudioOutputGlyph (VolumeHigh), PhoneGlyph (Call02, fill), HangUpGlyph (CallEnd02, heavy, at [12,16]), CheckGlyph (Tick02), CheckCircleGlyph, WarningGlyph (Alert02), BellGlyph, MessageGlyph, UploadGlyph (custom cloud contour), ArrowUpGlyph (ArrowUp02), DocumentPlusGlyph, PackageGlyph, DownloadGlyph (Download01), TerminalGlyph (ComputerTerminal01), PencilGlyph, SearchGlyph, GlobeGlyph (Globe02), WrenchGlyph, GitMergeRequestGlyph, SparkleGlyph (Sparkles, fill), MicrophoneGlyph (Mic01), ScreenRecordGlyph (Computer), VideoGlyph (Video02), RecordGlyph, HeadphonesGlyph, CarGlyph (custom carBody), PinGlyph (Location01), HouseGlyph, ParcelGlyph (Package02), BicycleGlyph, AirplaneGlyph, CoffeeGlyph, ForkKnifeGlyph, PhoneDeviceGlyph (SmartPhone01), TabletGlyph, LaptopGlyph, DesktopGlyph, BoltGlyph (Flash, fill), BatteryChargingGlyph, AlarmGlyph, HeartGlyph, StarGlyph (`glyphs.tsx:279-502`). These are NOT SF Symbols; Isla uses SF Symbols so a pt-exact match needs either the Hugeicons paths as vector assets or an explicit per-glyph SF Symbol mapping decision.
- `IconTile`: squircle (corner = 12/52 of side, smoothing 0.72) filled with a vertical gradient accent shaded +6% (top) to -6% (bottom); glyph 58% of tile (island glyph) / 54% (foreign); circle tile glyph 50%/48%; ink white, or `rgba(0, 0, 0, 0.82)` when accent luminance > 0.6; glyph drop-shadow `0 0.5px 1px rgba(0,0,0,0.22)` (`glyph.tsx:76-157`).

### 2.5 Avatar (`avatar.tsx`)
Circle, default 22. Monogram gradient `#554f66` (top) to `#36294f` (bottom) (`:31`). Initials: up to 2 letters, white, 600, SVG font size 54 (one letter) / 40 (two, letter-spacing 0.4) in a 100-unit box (`:63-65`); no letters = silhouette: circle (50,39) r18 + ellipse (50,96) rx36 ry30, white (`:71-74`). Photo drawn over, cover.

### 2.6 Artwork (`artwork.tsx`)
Generated cover from a seed: 8 palettes `{deep, mid, light, glow, accent}` (`:34-41`), 4 compositions (arcs, horizon, rings, bands), corner radius default `round(size*0.24)`, continuous corners smoothing 0.72, light radial `#fff` 0.12 -> 0 at (0.2, 0.1) r 0.9, shade radial `#000` 0 -> 0.2 at (0.5, 0.42) r 0.78 from 0.6, grain (70 specks per 20 tile, opacity 0.14) only when size >= 30, keyline `rgba(255, 255, 255, 0.14)` 1 pt (`:245-280`). Palette accents (`:34-41`): `#5fe0c4 #ff7a5c #d68cff #a9e05a #5cb8ff #ffb547 #ff8fb6 #ff7d52`. Never real cover art.

### 2.7 ProgressRing / IconRing (`progress-ring.tsx`)
SVG ring from 12 o'clock, default size 22, thickness 3, track `islandInk.track` (0.16 white) or the caller's, round caps, fill transition `stroke-dashoffset 420ms cubic-bezier(0.22, 1, 0.36, 1)` (`:29`), reduced motion none. Hidden at value 0 (`opacity` 0, `:67`). `IconRing`: track `tint(accent, 0.22)`, thickness 3.5 when > 30 pt else 2.5; inner disc `size-10`, filled `tint(accent, 0.18)` when large; icon size `round(size * 0.42)` large / `0.5` small (`:90-98`).

### 2.8 CountdownRing (`countdown-ring.tsx`)
`ProgressRing` driven by wall time: default size 20, thickness 2.5 up to 24 pt else 3, mode drain (full -> empty) or fill, steps every 250 ms (1000 ms reduced motion), `onEnd` once (`:34, :43-75`).

### 2.9 LinearProgress / TimeProgress (`linear-progress.tsx`)
Capsule, default height 6, track 0.16 white, colour blue `#0a84ff`; round ends use the engine's `IslandProgress`, `ends="square"` clips a full-width fill in the round track and slides it with `transform ${glide}ms linear` (glide 500 default) (`:33-66`). `TimeProgress` refreshes every 500 ms (`:101`).

### 2.10 LevelMeter (`level-meter.tsx`)
Bars default 4, height 16, width 3, gap 2, radius = barWidth, colour white. Each bar scaleY loops lo -> hi -> lo (`icn-level`, ease-in-out infinite, duration `0.42 + hash*0.5` s, negative delay up to 0.8 s) around its centre; hi = `0.55 + hash(index+17)*0.45` (no envelope) or the envelope value (min 0.12); lo = `0.22 + hash(index)*0.12` or `hi * (0.4 + hash*0.1)` (min 0.1). Inactive = scaleY 0.2; reduced motion = scaleY hi, no animation; live `levels` clamp 0.12...1. `core`: inner bar at top 27.5% bottom 27.5%, same radius (`:61-116`).

### 2.11 Metric / MetricRow (`metric.tsx`)
Grey 13/500/line 16 caption over 20 / 600 / line 24 value (tracking -0.11, tabular), unit 13/600 secondary margin-left 3; row = equal columns gap 8, first start / last end / middle centred; grid gap 1 between label and value (`:20-74`).

### 2.12 ShimmerText (`shimmer-text.tsx`)
Default 15 / 600 / line 20, base `rgba(235,235,245,0.62)`, highlight `#fff`; `linear-gradient(90deg, c 0%, c 38%, highlight 50%, c 62%, c 100%)` on 300% background-size, `background-position 100% 0 -> 0% 0` linear infinite 1.8 s; reduced motion = plain base colour (`:26-73`).

### 2.13 Sparkline (`sparkline.tsx`)
Height 16, stroke 2 (1.75 compact), round caps, edge pad = stroke x 1.4, end dot diameter = stroke x 2.6, optional area wash `tint(color, 0.28)` -> `tint(color, 0)`, dashed baseline `rgba(235,235,245,0.36)` 1 pt dash `2 3` (`:39-98`). (Not used by any preset; kit piece.)

### 2.14 Spinner (`spinner.tsx`)
Size 18, thickness 2.25, track = colour at 0.22 opacity, arc dash `0.28 x circumference`, round cap, rotate 360 deg in 0.8 s linear infinite; reduced motion holds still (`:19-50`).

### 2.15 StepProgress (`step-progress.tsx`)
Bar: segments `flex 1`, gap 4, height 5, radius height/2; colours done = colour, active = `tint(color, 0.5)`, failed = `#ff453a`, pending = `rgba(255,255,255,0.16)`. Dots: 7 pt dot, active capsule 16 x 7, gap 5 (`:38-86`).

### 2.16 TailText (`tail-text.tsx`)
One line, 17/600 (or 15, weight 400/500/600), line = round(size x 1.3), tracking per size; when wider than the row the start is cut under `mask-image: linear-gradient(90deg, transparent 0, #000 28px)` and the end stays in view (`:19-72`).

### 2.17 SteadyNumber / TickingTime (`steady-number.tsx`, `ticking-time.tsx`)
TickingTime ticks on whole-second boundaries, `formatClock`: `m:ss` under an hour, `h:mm:ss` from an hour (`ticking-time.tsx:33-40`); countdown rounds up (`:47-53`); digits cross over per place counted from the right. Timings (`steady-number.tsx`): incoming fade over 0 to 0.08 s, outgoing 0.04 to 0.12 s, grow 0 to 0.12 s, scale 0.92 at the far end, blur 0.03 x font size px at peak (0.45 px at 15 pt); smoothstep fades; `feedTurn` 0.25 for the live mode. Total change lasts 0.12 s.

## 3. Timer (and Stopwatch)

### 3.1 islandcn `timer-activity.tsx`
Props: `state` = `{kind:"running", endsAt}` or `{kind:"paused", remaining}`, `duration` (for the ring), `label` (default "Timer"), `accent` (default orange `#ff9f0a`), `onToggle`, `onCancel`, `onEnd` (`:18-37`). Priority default 0.

**Compact** (`:142`): leading `Glyph TimerGlyph` 22 pt in accent (Hugeicons StopWatch, parts heavy+line+cut). Trailing `CompactText` 15 / 600 / line 20 / tracking 0, tabular, text = `TickingTime` countdown `m:ss` (`h:mm:ss` from an hour), colour accent running, `rgba(235, 235, 245, 0.62)` paused (`:107-111`). The countdown is rounded up (`ticking-time.tsx:52`), digits cross over in place (`SteadyNumber`: in 0 to 0.08 s, out 0.04 to 0.12 s, scale 0.92, blur 0.03 px per px of size), ticks on whole-second boundaries.
**Split bubble** (`withBubble`): `TimerRing` alone.
**Minimal** (`:143`): `MinimalPair` (gap 7) = `TimerRing` + the same time text. `TimerRing`: `ProgressRing` size 22, thickness 3, fill = share left (drains, redrawn every 1000 ms with the 420 ms `stroke-dashoffset` transition), track `tint(accent, 0.25)` = `rgba(255, 159, 10, 0.25)`, `TimerGlyph` 12 pt in the middle (`:70-83`).

**Expanded** (`:148-164`), one row, no bottom region; row height `labelLine 18 + expandedValue 34 - valueTrim 2` = 50 (`:57-58`).
- Leading, `ExpandedSide height=50`: two 48 pt circles, gap 10 (`timerRow.button`, `buttonGap`, `:43-55`).
  - Toggle (only if `onToggle`): bg `tint(accent, 0.3)` = `rgba(255, 159, 10, 0.3)`, icon accent, `PauseGlyph` 24 (running) or `PlayGlyph` 24 (paused). Hugeicons Pause / Triangle01, solid.
  - Cancel (only if `onCancel`): neutral `rgba(255, 255, 255, 0.14)`, `CloseGlyph` 20 white (Cancel01).
  - Neither handler: a bare `TimerGlyph` 30 in accent.
  - Press: `scale(0.96)` + brightness 0.9, 160 ms `cubic-bezier(0.22, 1, 0.36, 1)`; hover brightness 1.12.
- Trailing, right-aligned grid, row gap 0: label line then value.
  - Label: `Caption` overridden to 15 / 600, line 18, `padding-right: 8`, text = the label ("Timer") in accent when running, "Paused" in secondary grey when paused (`:158`). Tracking: 15 pt = 0.
  - Value: `ExpandedValue` 34 / 700 / line-height 1, tracking -0.09, tabular, accent running or secondary grey paused, `margin-bottom: -2` (`:113`).
- Paused is the only other state: grey time, "Paused" label, Play glyph on the toggle. Compact keeps the TimerGlyph in accent.
- **Done**: none. `onEnd` is a callback only (`:168-174`); islandcn draws no "Timer done" view (the host is expected to `alert()` it, `recipes.md:92`).
- **Stopwatch**: no preset. `TickingTime` has an `elapsed` source (`ticking-time.tsx:9-12`) so the same layout counts up; there is no stopwatch-specific design.

### 3.2 Isla today
- Model: `LiveActivity.timer` / `.stopwatch` (`Sources/IslaKit/Model/LiveActivity.swift:15-17`), values from `IslandTimerState` (`Model/IslandTimer.swift:13`: kind, `runningSince`, `banked`, `isPaused`).
- Compact: `LiveCompactHeader` (`UI/LiveActivityViews.swift:55-70`): `HStack`, glyph padded 14 from the leading edge, value padded 14 from the trailing edge (`wingInset 14`, `:48`). Body width = notch + 100 (countdown under an hour) or +140 (an hour or more, and always for a stopwatch) (`:19-28`), no bubble form.
- Glyph (`LiveGlyph`, `:73-104`): SF Symbol `timer` (stopwatch: `stopwatch.fill`), `.system(size: 17, weight: .semibold)`, hierarchical rendering, colour `#FF9F0A` (`timerOrange`, `:8`), frame height 19.
- Time (`TimerText`, `:141-158`): `.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit()`, `timerOrange` at opacity 0.6 when paused, `contentTransition(.numericText(countsDown:))` + `.snappy(duration: 0.25)`, once-a-second `TimelineView`, no `.tracking`.
- Bubble (`LiveBubbleContent`, `:197-217`): `HStack(spacing: 4)`, glyph size 12, time size 12 for a timer only; bubble 62 wide (`bubbleWidth`, `:46`).
- Expanded (`TimerControlsView`, `:222-279`): a 335.4 x 120 card (`controlsShape`, radii 24 / 36, `:32-34`), padding top `notchHeight + 6`, bottom 14, horizontal `shape.x(40)`; `HStack` spacing 12: glyph 22, then a stack (spacing 2) of the kind label 13 medium white 0.55 and the time at 28 semibold rounded, `Spacer(minLength: 8)`, then two 44 pt circles (`RoundControlStyle`, `:396-411`) filled with the colour at 0.25 (pressed 0.25 x 1.6), symbol 16 bold in the colour: pause/play in orange, cancel (`xmark`) or reset (`arrow.counterclockwise`) in white.
- Done: a separate alert `TimerDoneView` (`:414-444`, rank 4, 10 s hold): `timer` 26 semibold orange, "Timer" 14 semibold white 0.86 over "Done" 11 medium white 0.45, and the duration at 22 semibold rounded orange; card = `ExpandedAlertShape.batteryFull` 305.5 x 108.

### 3.3 Differences (Isla to islandcn)
1. Controls are on the LEFT in islandcn (two 48 pt circles) and the label/time on the right; Isla has glyph + label + time on the left and 44 pt buttons on the right. Mirror it.
2. Isla's expanded card is the iPhone update-alert card (335.4 x 120, radii 24/36); islandcn's is the engine's expanded island at its minimum 84 pt height with a 50 pt row (island `minHeight` 84, `metrics.ts:96`).
3. Button size 48 vs 44; glyph sizes 24 (play/pause) and 20 (close) vs 16 bold SF symbols; toggle fill `rgba(255, 159, 10, 0.3)` vs orange at 0.25; cancel fill `rgba(255, 255, 255, 0.14)` + white glyph vs white at 0.25 + white symbol.
4. Time text: islandcn expanded 34 / 700 (tracking -0.09), label 15 / 600 above it; Isla 28 semibold rounded with a 13 medium 0.55-white label. Compact: islandcn 15 / 600 SF proportional-default with tabular digits; Isla 15 semibold **rounded**. Rounded design is not in islandcn at all (`islandFont` is the plain system face).
5. Paused colour: islandcn `rgba(235, 235, 245, 0.62)` grey (and a "Paused" label); Isla keeps orange at 0.6 opacity.
6. Compact glyph: islandcn 22 pt Hugeicons stopwatch (outlines 1.83 pt); Isla 17 pt SF `timer`; islandcn 22 pt box sits 7.18 from the pill end, Isla's 14 from the body end.
7. Minimal/bubble: islandcn minimal = 22 pt draining ring (glyph 12 inside) + time (gap 7), bubble = ring alone (time would be cut to "4..."); Isla's bubble shows a 12 pt glyph + a 12 pt time in a 62 wide capsule. islandcn's ring is not drawn anywhere in Isla for a timer.
8. Timer Done: Isla has an alert; islandcn has none (keep Isla's, but it should be redrawn in islandcn's expanded language: 15/600 "Timer" label in accent, 34/700 time, 48 pt button row).
9. Stopwatch: not in islandcn; design as the timer with an `elapsed` source, label "Stopwatch"/"Paused", `StopwatchGlyph`; reset button replaces cancel.
10. Digit motion: islandcn `steady` crossfade 0.12 s for a feed; Isla uses `numericText` + `.snappy(0.25)`. Close enough in spirit, not frame-identical.
## 4. Recording

### 4.1 islandcn `recording-activity.tsx`
Props: `kind` "audio" | "screen" | "camera" (default audio), `state` = `{recording, since}` or `{paused, elapsed}`, `title` (defaults "Voice memo", "Screen recording", "Video", `:115-119`), `accent` red `#ff453a`, `onStop`, `onTogglePause`, `levels` (live 0..1) (`:92-113`). Priority 0.

**Compact** (`:342-349`):
- Leading (audio): `CompactWave` = `LevelMeter` 13 bars, barWidth 1.4, gap 1.35, height 22 (`compactWave`, `:80`), envelope `[0.12, 0.25, 0.7, 0.48, 0.55, 0.22, 0.18, 0.7, 1, 0.6, 0.8, 0.28, 0.1]` (`:236`), red while recording, `rgba(235, 235, 245, 0.62)` paused, bars move only while live (inactive = scaleY 0.2).
- Leading (screen/camera): `RecordingDot` in a 22 box: dot = round(22 x 0.5) = 11 pt circle in accent, pulsing `opacity 1 -> 0.7 -> 1` over 1.6 s ease-in-out infinite (`:123-127`); paused: 11 pt square with radius 2, secondary grey, no pulse.
- Trailing: `CompactText` 15 / **400** (not 600: "the recorder's compact time reads as a clock", `:336`), `TickingTime` elapsed, `motion="none"` (digits replace in place), `m:ss` / `h:mm:ss`, red or grey paused.
- Split bubble: the waveform in `smallWave` = 5 bars, width 2, gap 2, height 16 (`:82`), or the dot, alone.
**Minimal**: `MinimalPair(small, time)`.

**Expanded** (`:351-383`), one row 47.47 pt (`row.height` = 84 - 18.18 - 18.35, `:27`):
- Leading (audio): optional pause button, then `RecordingWave`:
  - Waveform: 15 bars (13 with the pause button), slot pitch 5.3, bar width 2.9, radius 2.9, min height 4 (`floor`), peak 40 (`row.peak`), height = 4 + 36 x level; colour red / grey paused; bar strip scrolls left one slot every 120 ms (`row.tick`) with a linear `transform` transition of 120 ms; built-in speech-like levels (`builtInLevel`: 55 % of bars loud 0.72..1.0, others 0.3..0.57) or live `levels` (newest on the right).
  - After the bars, grey dots 2.7 pt diameter (`row.dot`), 11 of them (6 with pause), colour `rgba(235, 235, 245, 0.42)` (`dotColor`, `:85`), same pitch 5.3 (`gap = pitch - dot`).
  - Pause button (only with `onTogglePause`): 36 pt neutral round, `PauseGlyph`/`PlayGlyph` 16, moved in by `pauseInset` so it is concentric with the left corner (= 42 - 18.5 - 18 = 5.5 pt), gap 10 to the waveform.
- Leading (screen/camera): `Glyph` (ScreenRecordGlyph / VideoGlyph) 22 in accent + `CompactText` title, gap 7, max width = 5.3 x (15 + 11) = 137.8 (or 5.3 x (13 + 6) = 100.7 with pause), ellipsis.
- Trailing (`RecordingTrailing`, `:280-304`): elapsed time 22 / **400** / line-height 1, tracking -0.11, tabular, `formatRecorder` forces two minute digits ("02:50", "1:02:09"), `motion="none"`, red when recording, grey when paused; gap 10; then (with `onStop`) the stop button: 49 pt circle button (`row.stop`), transparent fill, drawn as one SVG: ring stroke `#fff` 3 pt (`row.ring`, r = (49 - 3)/2) and a 25 x 25 square (`row.square`) radius 6.5 in accent, pushed out by `stopOverhang` (= 24.5 - (42 - 17.81) = 0.31 pt) so its centre is the island corner's.
- States: recording (red, scrolling), paused (grey time and bars, still bars, pause glyph becomes Play, dot becomes square). No error state.

### 4.2 Isla today
- Model: `LiveActivity.recording(CaptureState)` (`Model/LiveActivity.swift:13`): `microphoneApps: [String]`, `cameraInUse`, `microphoneMuted` (`Services/CaptureWatch.swift:7-19`). No start time, no level, no title.
- Compact (`LiveCompactHeader`, `UI/LiveActivityViews.swift:55-70`, width = notch + 75, `NotchMetrics.compactShelfExtension`): glyph SF `mic.fill` / `mic.slash.fill` (muted) / `video.fill` at 17 semibold hierarchical, orange `#FF9F0A` for a microphone and `Theme.chargingGreen` (`#30D158`) for a camera alone (`:96-103`); trailing the owning app's icon at 20 x 20 (`:117-123`) or an 8 pt dot in the same colour when no app is known. No time, no waveform, no pulse.
- Expanded (only when a microphone app exists, `LiveActivity.hasControls`): `MicrophoneControlsView` (`:285-380`), same 335.4 x 120 card as the timer: the app's icon 34 x 34 (button, brings the app forward) or the 22 pt glyph; stack = "Microphone"/"Microphone Muted" 13 medium white 0.55 (orange when muted) over the app names 15 semibold white; two 44 pt circles: Mute (`mic.slash.fill` orange at 0.25) and Quit (`power`, white at 0.25).

### 4.3 Differences
1. The whole expanded design is different: islandcn is a waveform + time + stop ring with an optional pause; Isla is a Mute/Quit control card with the app's name. Isla has no waveform, no time, no stop ring.
2. Compact: islandcn leads with a 13-bar red waveform (22 tall) or an 11 pt pulsing red dot and trails with a 15 / 400 red elapsed time; Isla shows an orange mic (green camera) glyph + app icon. Colour is the biggest delta: islandcn is always red (`#ff453a`); Isla uses orange (mic) and green (camera) to match macOS's menu-bar dots (deliberate, `LiveActivityLayout.microphoneOrange`/`cameraGreen`).
3. No elapsed time anywhere in Isla: needs a start timestamp (the hub must record when the app began capturing; `CaptureState` has none).
4. No levels: a real waveform needs the microphone input level, which Isla cannot read from another app's capture without opening the device (permission, and it could disturb the other app). The honest options: the built-in loop (`builtInLevel`, islandcn does this by default) driven only while `microphoneMuted == false`, or no waveform.
5. Stop ring (49 pt, red 25 pt square r6.5, white ring 3) has no Isla counterpart. On a Mac Isla can only offer Quit app (the existing control); a real "stop recording" is not possible for another app's recording. If kept, relabel Quit with the same ring+square art only if the action truly stops the recording; otherwise keep Quit as a neutral round button.
6. Pause button (36 pt) has no Isla counterpart (Mute is the nearest: use the 36 pt neutral circle with the mic.slash glyph at 16).
7. Dot pulse 1.6 s, 1 -> 0.7: Isla has none (recording dot is a static 8 pt).
8. Time font weights: islandcn deliberately uses 400 (compact 15, expanded 22); Isla would default to 600 if copied from the timer.
9. Data needed to match: capture start time (per app), mute state, optionally `levels` (0..1 array), title/app name, and for screen recording a "screen" kind (Isla has no screen-capture detection; CoreAudio/CoreMediaIO give mic and camera only).
## 5. Upload (new in Isla) and Downloads (Isla's nearest)

### 5.1 islandcn `upload-activity.tsx` + `media-row.tsx`
Props (`upload-activity.tsx:9-36`): `fileName`, `progress` 0..1, `src` (thumbnail), `totalBytes`, `destination`, `title`, `doneTitle`, `accent` (blue `#0a84ff`), `onCancel`. Priority 0.

Words (`uploadWords`, `:78-89`): white sentence = `title` ?? "Uploading" + (" to " + destination); done: `doneTitle` ?? "Uploaded to X". Grey line = `fileName` + " · " + detail where detail = "2.5 of 6 MB" (one decimal under 10, "of" with the unit once if both match, decimal SI units 1000), "6 MB" when done, or "42%" when the ring is a stop button and there is no size (`:51-58, :87`).

**Compact** (`:123-127`):
- Leading `Thumbnail` 24 pt (`mediaCompact.thumb`), corner radius 5.5 (continuous, smoothing 0.72), keyline `rgba(255, 255, 255, 0.14)` 1 pt on the outline, fallback = tile of `tint(accent, 0.2)` with `UploadGlyph` at round(24 x 0.55) = 13 pt accent; 22 pt in the split bubble.
- Trailing `ShareRing mark="count"` = `CountRing` 20 pt, thickness 2.6 (`mediaCompact.ring`, `ringThickness`), track `tint(accent, 0.22)`, percentage inside: **9 pt / 600 / line-height 1 white**, `NumberText motion="none"` (no digit animation) (`:166-187`). At 1 the ring becomes `DoneDisc`: 20 pt disc in accent with white `CheckGlyph` round(20 x 0.62) = 12 pt.
**Minimal**: the ring alone.

**Expanded** (`:129-144`), one row 47 pt (`mediaRow.row`), island stays 84 pt:
- Leading `MediaLead`: 50 x 47 slot, margin-left `16.3 - 18.5` = -2.2; `Thumbnail` 44 pt, radius 16 (`mediaRow.photo`, `photoRadius`; "a 50 pt square would lose its corners to the island's content clip").
- Center `MediaText` (`:141-146`): box width 640 capped at the column, height 27, margin-left -1.4. Grey line: `ExpandedSubtitle` overridden to **14 pt / 400 / line 18**, secondary grey, `margin-top: -4.5`. White line: `ExpandedTitle` 17 / 600 / line 22 / tracking -0.045, `margin-top: -2`. The text overflows its 27 pt box downward without growing the island. Baselines 47.7 and 66.2 below the island's top.
- Trailing `MediaTrail`: 47 pt tall flex, margin-right `17.1 - 17.81` = -0.71; `ShareRing` 48 pt, thickness 4 (`mediaRow.ringThickness`), track `tint(accent, 0.22)`, percentage 17 / 600 white (`ringFigure`), `NumberText motion="steady"`. With `onCancel`: mark "stop" = a 15 pt square (radius 3.5) in accent inside the ring, the whole ring is a transparent 48 pt `IslandRoundButton`; percentage moves to the grey line.
- Ring fill animates with `stroke-dashoffset` 420 ms `cubic-bezier(0.22, 1, 0.36, 1)`; ring hidden at 0 (no stray dot).
- States: uploading, done (disc + check, "Uploaded to X", grey line = size only), stopped (host ends it). No error state in the preset.

### 5.2 Isla today: Downloads (`LiveActivity.downloads`)
- Model: `[DownloadProgress]` (`Services/DownloadWatch.swift:5-17`): `name`, `bytesSoFar`, `totalBytes?`, `fraction?` (nil = unknown, as Chrome's `.crdownload`).
- Compact (`LiveCompactHeader`): body width = notch + 75; glyph SF `arrow.down.circle.fill` 17 semibold hierarchical, blue `#0A84FF` (`downloadBlue`, `LiveActivityViews.swift:10`), padded 14; trailing `IslandProgressRing` 18 x 18, line width 3, track = blue at 0.22, fill blue round-capped from 12 o'clock, `max(0.02, fraction)`, spring response 0.97 / damping 0.74 (`:160-195`); unknown size = 0.28 arc rotating 1.2 s linear (Reduce Motion: still).
- No percentage, no file name, no expanded view (`hasControls` false, `LiveActivity.swift:46-52`); a click does nothing. Finish = confirmation pill "Downloaded" (section 6.2).

### 5.3 Differences
1. Isla has no Upload activity. Whatever is built (Shortcuts/script-fed) should be the islandcn upload exactly: 24 pt thumbnail + 20 pt count ring compact; 44 pt thumbnail, 14/17 text pair, 48 pt ring expanded.
2. Isla's Downloads compact is a *glyph + bare 18 pt ring* (3 pt line, no number); islandcn's equivalent pair is thumbnail 24 + ring 20 (2.6 pt line) with a 9 pt percentage inside. Sizes, line weights and the inner figure all differ. Direction: islandcn has no download preset; the right translation is the upload layout with `DownloadGlyph` as the fallback tile glyph, mark "down" (20 pt arrow, rotated 180 deg `ArrowUp` in accent) inside the 48 pt ring in expanded (`media-row.tsx:241-274`), exactly as the nearby transfer's receive state does.
3. Expanded: Isla has none; islandcn expanded would read "<file name> · 2.5 of 6 MB" in grey over "Downloading from <site>" in white (needs `totalBytes`, a host; Safari's `.download` Info.plist carries both a URL and a total, Chromium's `.crdownload` carries neither).
4. Done state: islandcn keeps the activity mounted at 1 (ring becomes a 20/48 pt accent disc with a white check, sentence becomes "Downloaded"); Isla swaps to a separate "Downloaded" confirmation pill.
5. Unknown size: islandcn has no indeterminate form for the ring (`Spinner` is 18 pt, 2.25 line, 0.28 arc, 0.8 s linear, track 0.22 of the colour, `spinner.tsx`); Isla's spinner is 18 pt/3 pt/1.2 s. Use `Spinner` numbers.
6. Blue is the same hue family (`#0a84ff` = islandAccent.blue, Isla `downloadBlue` 10/132/255 = `#0A84FF`): equal.
7. Data needed for parity: file name, `bytesSoFar`, `totalBytes`, thumbnail or file icon (`NSWorkspace.icon(forFile:)` is available), source host (Safari only), cancel handler (not possible for another app's download; omit the stop square and use the arrow mark).
## 6. Nearby transfer (Isla: AirDrop) and Isla's other confirmations

### 6.1 islandcn `nearby-transfer-activity.tsx`
Props (`:11-34`): `direction` "send" | "receive", `deviceName`, `device` phone/tablet/laptop/desktop, `itemName`, `src` (badge thumbnail), `avatar`, `progress`, `accent` blue `#0a84ff`, `onCancel`.
Words (`nearbyTransferWords`, `:58-70`): grey = "Sending <item>" / "Sent <item>" / "Receiving <item>" / "Received <item>"; white = "To <device>" / "From <device>".

**Compact** (`:109`): leading `SharePicture` 22 pt: the device glyph (PhoneDevice / Tablet / Laptop / Desktop, 22 pt) in accent, **bare, no disc** at <= 30 pt (`media-row.tsx:322-325`), or an `Avatar` 22 when a person photo is given. Trailing `ShareRing` 20 pt (thickness 2.6, plain ring, **no mark inside in compact**, `:266, :276`). At 1: 20 pt accent disc + white check (12 pt).
**Minimal** (`:104`): `IconRing`: 22 pt ring, thickness 2.5, track `tint(accent, 0.22)`, device glyph at round(22 x 0.5) = 11 pt; done = the ring/disc.
**Expanded** (`:111-131`), same one-row 47 pt as the upload:
- Leading `MediaLead` 50 slot: `SharePicture` 50: device glyph at round(50 x 0.52) = 26 pt in accent on a 50 pt disc filled `tint(accent, 0.2)`; or `Avatar` 50 (monogram `#554f66` -> `#36294f`, white 600 initials). When `src` is given a **badge** hangs on the picture's lower trailing corner: a 26 pt `Thumbnail` radius 6.5 inside a black `#000` ring 2 pt thick (padding 2, radius 6.5 + 2), offset right/bottom -(3 + 2) = -5 pt (`badge`, `:292-299`).
- Center `MediaText(line=action, title=party)`: 14 / 400 grey over 17 / 600 white as in the upload.
- Trailing: `ShareRing` 48 pt, thickness 4, mark = "up" (send) or "down" (receive) = `ArrowUpGlyph` 20 pt in accent (rotated 180 deg for down); with `onCancel`: mark "stop" = 15 pt accent square r3.5 and the ring becomes the stop button. At 1: 48 pt accent disc with a 30 pt white check (round(48 x 0.62)).

### 6.2 Isla today
- AirDrop is **not an activity**: it is the confirmation `IslandConfirmation.Kind.airDropped(name:)` (`Model/IslandConfirmation.swift:50`) and "Downloaded" (`:48`), rank 5 alerts held 1.5 s (`holdDuration`), drawn by `NotchContentView.confirmationHeader` (`UI/NotchContentView.swift:949-967`): symbol `dot.radiowaves.up.forward` (downloaded: `arrow.down.circle.fill`) at `ConfirmationLayout.symbolSize` 14 (x glyphScale) semibold white, inset `CompactIslandLayout.chargingTextInset` (18.5 - 8.67 = 9.83) from the left; title ("AirDrop" / "Downloaded") at 14 medium white 0.88 with `Theme.tracking(14)` = 0 (`:105-114`), right-aligned ending `batteryTrailing - shoulder` = 19.3 - 8.67 = 10.63 from the right; the pill is the charger's width (notch + 180 minimum, `compactChargingExtension`); a click reveals the file in Finder. The file name is only in the VoiceOver label.
- It fires when a file whose quarantine agent is `sharingd` appears in `~/Downloads` (`NotchController.swift:1121, :1287`), i.e. only on arrival: there is no progress, no sender, no thumbnail.

### 6.3 Differences
1. Different species: a 1.5 s text pill vs islandcn's progressive activity (picture + ring, then expanded row). Matching islandcn means an `.live`-style AirDrop activity with the 22 pt device glyph + 20 pt ring compact and the 50 pt picture / 14-17 text / 48 pt ring expanded row.
2. Glyph: Isla's `dot.radiowaves.up.forward` 14 pt white vs islandcn's device glyph 22 pt in accent blue (`#0a84ff`); there is no AirDrop glyph in islandcn's set (its sharing preset uses the device the data goes to). For a received AirDrop the picture should be the sender: macOS gives the sender's device name through `com.apple.quarantine`/`sharingd` only partially (the sharing UI shows a contact name; not reliably readable). The device glyph to use must be chosen from a name heuristic, or the generic `PhoneDeviceGlyph`.
3. Text: islandcn grey 14/400 "Receiving 3 photos" over white 17/600 "From Maya's iPhone"; Isla only "AirDrop" 14 medium.
4. Progress/done: islandcn needs `progress`; a Mac cannot read AirDrop progress from `sharingd` without private API. What the Mac can observe: a growing partially written file in `~/Downloads` (or `~/Library/Caches/...`), which gives bytes but no total, so only the unknown-size state exists. An honest port draws the ring as a `Spinner`-style arc until the file lands, then the 20/48 pt disc + check and "Received <name>" (the grey line = name, white = "From <device>" when known).
5. Data needed: direction (receive only on Mac, unless Share Sheet sends are tracked), device name, device kind, item name/count, optional thumbnail (`QLThumbnailGenerator`), progress (optional), cancel (not possible).
6. Isla's other confirmations ("Copied", "Lyrics imported", "Added to Shelf", "Already on the Shelf", `IslandConfirmation.swift:44-52`) have no islandcn counterpart (islandcn has no notice preset: "There is no notification preset", `recipes.md:441`); keep as Isla's.
## 7. Battery (Isla: Charging, Battery Low, Full Battery)

### 7.1 islandcn `battery-activity.tsx`
One preset, three looks (charging, low, plain). Props (`:104-139`): `level` 0..1, `charging`, `timeToFull` ms, `lowThreshold` default 0.2, `name` (default "Battery"), `alertOnStart` (false), `dismissAfter` ms, `onDismiss`. `chargingIndicatorHold = 3300` ms (`:145`). Priority 0.

Colours: charging green text `#53fa6d` (`chargingGreen`, `:148`); battery fill while charging gradient `#5afeb6` (0) -> `#62fd6b` (0.5) -> `#63ff39` (1), empty part and nub `#2e7124` (`chargeFill`, `:155`); not charging: fill = white `#ffffff`, low (< 0.2 and not charging) = red `#ff453a`; empty part/nub = fill colour at 0.42 alpha (`:239`). Label always white.

**Battery glyph** (`BatteryGlyph`, `:212-267`): proportions 36.1 wide in all: body `(width - nub.w - nub.gap)` x 17 x scale, radius 5 x scale, nub 1.9 x 5.8 (radius = half its width) at gap 1.2, scale = width / 36.1; no outline, no bolt; fill is a left-anchored `scaleX(max(0.06, level))` with transition 600 ms `cubic-bezier(0.22, 1, 0.36, 1)`; on appear it fills in from empty (`scaleX(0.06)` -> level) over 1000 ms `cubic-bezier(0.45, 0, 0.25, 1)` after a 300 ms delay (`fillIn`, `:163-170`).

**Compact** (`:492-498`): the pill is two 72 pt slots (`pill.side`, the engine's `maxSlotWidth`) + the sensor.
- Leading `ChargingLabel`: `CompactText` 15 / 600 white, text = "Charging" / "Charged" (level >= 1) / `name` (not charging), ink 14.5 from the pill end (`labelInset 13.7` + the engine's 7.18 - the C's side bearing 0.76; implemented as a 6.52 flexible spacer that gives way first).
- Trailing `ChargingLevel`: percentage `CompactText` 15 / 600 (sign at the figure's size, `NumberText motion="steady"`) in `#53fa6d` while charging, accent (white / red) otherwise; gap 4 (`pill.gap`, Apple's 5.7), then the 35.5 pt battery (`measured.glyph`; 27 when the level is 100 %, `glyphFull`; min 22), then inset 2 (`glyphInset`) so the nub ends ~9.2 from the pill end.
- Split bubble: the battery alone (default width 27). **Minimal**: `MinimalPair(battery 27, percent)`.
**Expanded** (`:502-505`), the same row in an 84 pt island (row height = 84 - 18.18 - 18.35 = 47.47), no bottom region:
- Leading `ChargingRowLabel`: label `CompactText` 15 / 600 white, shifted -0.76 so its ink sits on the 18.5 padding, max width = (402 - 27.66 - 94.85)/2 - 18.5 - 6 = 115.2; with a detail: `Caption` 13 / **400** secondary under it (gap 1): while charging "Full in 55 min" (`minutes < 60 ? "N min" : "H h M min"`, `:512`), else the device name if not the default "Battery"; not charging: "Low battery" or "Not charging".
- Trailing `ChargingRowLevel`: percentage 15 / 600 + gap 5.7 + the 35.5 pt battery, right edge moved in so the nub ends 18.5 from the island's end (`glyphShift` = 0.69).
- Low: red percentage + red battery, label = device name, detail "Low battery"; no card, no pulse, no separate alert (islandcn has none).
- Done/full: label "Charged", percentage 100 %, battery 27 pt wide (`glyphFull`) in compact.

### 7.2 Isla today
- **Charging** (`AmbientActivity.charging`, `UI/ChargingActivityView.swift`, `Notch/CompactIslandLayout.swift:136-175`): body = notch + 180 (`compactChargingExtension`), held 3 s. Left wing: source + status in one `Text`, `chargingTextSize` 14 / regular (`islandFont`, tracking 0), source in white 0.88, status in white 0.55, starting 9.83 from the body edge (`chargingTextLeading 18.5 - shoulder 8.67`); examples "MagSafe", "61 W On Hold", "Charged". Right wing: level `"%d%%"` 14 regular monospaced digit tinted (green `#30D158` gradient while charging, red `#FF453A` at <= 20 %, white held/full), 6 pt gap (`levelToBatteryGap`), then either `MagSafeRing` (18 pt ring, 3 pt line, 8 pt bolt, track = tint at 0.30, draws from empty on the island spring) or `IslandBattery` (body 28 x 16 r6, cap 2 x 6 r1.5, gap 1.5, track = tint 0.30, with a white-on-black bolt 10 pt over it while charging), ending 19.3 - 8.67 = 10.63 from the right.
- **Battery Low** and **Full Battery** (`UI/BatteryAlertView.swift`): the iPhone's cards (`ExpandedAlertShape.batteryLow` 325.4 x 113 radii 22/40; `.batteryFull` 305.5 x 108 radii 18/36): title 14 semibold white 0.86 + level 13 regular tinted (gap 8), detail 11 medium white 0.45 ("Connect a charger soon, or turn on Low Power Mode." / "You can unplug the charger."), at right a 70 x 40 (low) or 75 x 45 (full) capsule filled with the tint at 0.20 holding a battery drawn from a body 40 x 23 (44 x 24) r10, cap 2.5 x 7.5 (3 x 8), level block 8 x 14 (34 x 14) r4, body opacity 0.45 (0.40); the low level pulses 1 <-> 0.3 on a 1 s ease-in-out repeat.

### 7.3 Differences
1. Compact charging text: islandcn 15 / 600 white "Charging" + 15 / 600 `#53fa6d` percentage; Isla 14 / 400 white 0.88 with a dimmer status word and a 14 / 400 tinted level. Colour: `#53fa6d` vs `#30D158`. The islandcn compact does not name the source ("MagSafe", "61 W") at all (no `port`/`watts` props).
2. Battery drawing: islandcn 35.5 x 16.6 (36.1 x 17 body) with a mint-to-lime gradient fill on a deep green `#2e7124` empty part, no bolt, fill-in animation 1 s; Isla 28 x 16 r6, cap 2 x 6, gradient from the system green, white bolt overlay, track 0.30 tint. MagSafe ring has no counterpart in islandcn (keep as Isla's, or drop for strict identity).
3. Level text: islandcn percentage, then 4 pt, then battery whose nub ends ~9.2 from the pill end; Isla level, 6 pt, battery ending 10.63 from the right.
4. Expanded: islandcn expands the same row to an 84 pt island with a 13 / 400 grey detail ("Full in 55 min"); Isla has no expanded charging view (a click does nothing) and uses separate iPhone-style cards for Low/Full, which islandcn does not have. Under "identical to islandcn", Battery Low = red percentage + red battery pill with label = device name and detail "Low battery"; the 113 pt card is Isla's own.
5. Low colour: islandcn `#ff453a` (islandAccent.red), Isla `lowBatteryRed` 255/69/58 = `#FF453A` (same).
6. Trailing-state wording: islandcn "Charged" when `charging` and level 1; Isla "Charged" / "Charging On Hold" / "Not Charging" (Mac-specific states islandcn has no words for).
7. Data already available in Isla: level, charging, hold, port, watts. Missing: time to full (`IOPSGetTimeRemainingEstimate` gives time to empty; time to full is `AvgTimeToFull` in the power source dictionary) for the "Full in N min" line, and a device name for peripherals (`Battery` default).
## 8. Now playing (Isla: Music)

### 8.1 islandcn `now-playing-activity.tsx`
Props (`:254-276`): `title`, `artist`, `duration`, `playback` = `{playing, startedAt}` | `{paused, position}`, `artwork`, `accent` (default = the generated cover's palette accent), `onToggle/onPrevious/onNext/onOutput` (a button shows only if its handler is set). Priority 0.

**Compact** (`:311-314`): leading `Artwork` 22 pt, radius 6 (`:304`; continuous, smoothing 0.72, keyline `rgba(255,255,255,0.14)` 1 pt, no grain under 30 pt); trailing `PlayerMeter size="compact"` = `LevelMeter` 6 bars, barWidth 2.4, gap 1.9, height 17 (width 6 x 2.4 + 5 x 1.9 = 23.9), colour = cover accent, `active` only while playing (paused: every bar `scaleY(0.2)` = 3.4 pt, same colour), each bar loops `scaleY lo -> hi -> lo` ease-in-out infinite with its own period 0.42 + hash x 0.5 s and a negative delay up to 0.8 s; hi = 0.55 + hash x 0.45, lo = 0.22 + hash x 0.12; 160 ms transform transition; reduced motion = fixed `hi`.
**Minimal** (`:315`): `MinimalPair(art 22, meter 4 bars)` (gap 7).
**Expanded** (`:316-330`, `player` table `:24-76`), island up to 180 pt:
- Leading `PlayerCover`: `Artwork` 59.5 pt, radius 14, padding-left 3.2, padding-top 3.72 (generated cover gets grain, size >= 30).
- Center `PlayerTitle`: width 640 capped, padding-left 4.8, margin-top -5.1. Title: 16 / 600 / line 20 / tracking 0 white. Artist: 16 / **400** / line 20, colour `#898989`, `margin-top: 16.2 - 20 = -3.8`. (Title baseline 47.3 below the island top; artist baseline 17.1 below the title's.)
- Trailing `PlayerMeter size="expanded"`: 6 bars, 2.4 wide, gap 1.9, **20 tall**, envelope `[0.5, 1, 0.7, 0.4, 0.6, 0.35]`, padding-right 8.2, padding-top 8.3, cover accent.
- Bottom `PlayerControls` (`:169-252`): `ExpandedBottom` gap 16.3, padding-top 6.3 (`timeTop`):
  - Time row: grid `minmax(33px, max-content) 1fr minmax(36px, max-content)`, padding-left 3.9 / right 5.2; elapsed and remaining 11 / 400 / line 14 tabular `#898989`, gaps 8; remaining uses a real minus sign U+2212 ("−1:23"); scrubber = `TimeProgress` height **6**, fill `#ffffff`, track `rgba(255, 255, 255, 0.2)`, **square** playhead edge (`ends="square"`, linear 500 ms glide), refresh 500 ms.
  - Transport row: container height 36; five slots placed by centre: previous at -73.5 from the island's centre line (+ 0.35 centre shift), play/pause at 0, next at +73.5, output button's centre 40.2 from the trailing edge; each is a 36 pt transparent round button (touch 44); glyphs: pause/play 30, skip 34, output 27.5 (`PlayerPauseGlyph` / `PlayerPlayGlyph` / `PlayerBackGlyph` / `PlayerForwardGlyph` = Hugeicons Pause, Triangle01, FastForward mirrored; `AudioOutputGlyph` = VolumeHigh), all white; `bottomPad` 0.
  - With no buttons the time row is last and gets `reach="inset"`.
- Paused: meter rests (not recoloured), toggle shows Play. No error state. No lyrics, no favourite button.

### 8.2 Isla today
- Compact music: `compactMediaHeader` + `compactPlaybackState` (`UI/NotchContentView.swift:1296-1380`), geometry `Notch/CompactIslandLayout.swift`: body = notch + 70 (`compactMediaExtension`, two 35 pt wings); cover 22 pt, radius 5 (`Theme.artworkMetrics(isOpen:false)` `Theme.swift:692`), 17.3 from the shape edge = 8.63 from the body edge, vertically centred, hairline stroke white 0.14 at **0.5 pt**; paused: cover darkened to 0.55 brightness with a 9 pt bold `play.fill` badge. Right wing: `CompactEqualizer` = 6 bars, 2.2 wide, in an 18 pt box (gap 0.96), ending 10.63 from the right; resting heights `[3, 3, 3, 3, 3, 3]`, playing loops between low `[4, 7, 5, 8, 6, 5]` and high `[14, 18, 12, 17, 15, 13]` with durations `[0.48, 0.37, 0.43, 0.41, 0.46, 0.39]` s (`CompactEqualizer.swift:10-19`), gradient from the cover's tint lifted 0.16, paused = tertiary white.
- Peek (a new track): 34 pt cover radius 8 + two lines, pill 50 tall.
- Expanded: `PlayerLayout` (`UI/PlayerLayout.swift`) from a 425.4 x 198 iPhone board (`Surface.swift:165`): cover 60 x 60 radius 10; title 16 (`titleSize`, `.medium` weight, white 0.80, `MediaPane.swift:353`) and artist/subtitle 14 regular white 0.50, text leading 129.2 - 34; equalizer 23 x 18; times 11 medium **rounded** monospaced white 0.40 (`MediaPane.swift:540`); progress bar 231.3 x **7** radius 3.5, track white 0.15 / fill white 0.50 (`Theme.swift:792-793`); five controls at centre offsets -133, -69, 0, +69, +133 (favourite, previous, play/pause, next, output), each a 42 x 42 target, glyphs 28 x 27 / 35 x 22 / 29 x 34 / 35 x 22 / 28 x 27 (SF), secondary controls white 0.50; plus lyric rows under the title, the Open-in-app buttons and the page dots (`PageDots`).

### 8.3 Differences
1. Cover radius 6 (islandcn compact) vs 5; keyline 1 pt (half clipped, i.e. 0.5 visible) vs 0.5 stroke: same visual; expanded cover 59.5 r14 vs 60 r10.
2. Meter: 6 bars **2.4** wide gap **1.9** height **17** (compact) / 20 (expanded) vs Isla 2.2 wide, gap 0.96, 18 tall box; heights animate 0.2..1.0 of 17 (3.4 to 17) vs 3..18 pt; colour: islandcn single flat cover accent (palette accents `#5fe0c4 #ff7a5c #d68cff #a9e05a #5cb8ff #ffb547 #ff8fb6 #ff7d52`) vs Isla's gradient from the real cover's tint; the expanded meter sits top-trailing at 20 pt tall with a fixed envelope vs Isla 23 x 18.
3. Paused: islandcn keeps the cover untouched and rests the bars at 0.2; Isla dims the cover to 0.55 and adds a play badge, bars 3 pt tertiary.
4. Title/artist: islandcn 16 / 600 white and 16 / 400 `#898989`; Isla 16 medium 0.80-white and 14 regular 0.50-white.
5. Time row: islandcn 11 / 400 `#898989` proportional-default tabular, remaining with a minus sign, bar 6 pt white on `rgba(255,255,255,0.2)` with square ends and 500 ms linear glide; Isla 11 medium **rounded**, bar 7 pt r3.5 with 0.50 fill / 0.15 track.
6. Controls: islandcn 3 transport buttons + output (36 pt targets, 30/34/27.5 pt Hugeicons glyphs, 73.5 apart, nothing for favourite); Isla 5 controls 42 pt targets at +/-69 and +/-133 with SF glyphs. Isla's layout is a deliberate iPhone-board copy; matching islandcn means dropping the favourite button, moving to 73.5 spacing and changing glyph sizes.
7. Island height: islandcn expanded player is up to 180 pt tall x 374.34 wide; Isla's panel is 198 tall on a 425.4 board and the width follows the user's setting (480..620).
8. Glyph set (Hugeicons vs SF) as noted in section 2.4.
9. Data already in Isla: title, artist, cover, duration, position, playing. Not needed: nothing new.
## 9. Incoming call (new in Isla)

### 9.1 islandcn `call-activity.tsx`
Props (`:24-44`): `caller`, `subtitle` (default "Audio call", the grey line while ringing: "mobile", "Video call"), `avatar` (photo src; default monogram), `state` = `{ringing}` | `{active, since}`, `onAccept`, `onDecline` (end while active). **Priority default 2.** A ringing call calls `expand()` and holds the island open until answered or declined; once answered it `collapse()`s to compact (`:259-270`).

Colours (`:46-57, :121-122`): decline `#fe4345`, accept `#31d259` (measured button fills); answered text/glyph/meter-near `#76fb73` (`talkGreen`); meter far half `#ff9f0a` (orange); meter core `#fffde0`; grey line `rgba(235, 235, 245, 0.62)`.

**Compact ringing** (`:213`): leading `Avatar` 22 pt, trailing `PhoneGlyph` 22 in `#31d259`. Split bubble: the green phone alone.
**Compact answered** (`:215-228`, `compactCall :99`): both slots are 66 pt wide in the compact pill only (`answeredCss`, so the pill is ~241 pt wide, and the split keeps content width):
- Leading: `PhoneGlyph` **18** in `#76fb73`, gap 2.5, `CompactText` 15 / 600 `#76fb73` with `TickingTime` elapsed (`m:ss`).
- Trailing: right-aligned `LevelMeter`, **14 bars**, barWidth 2.25, gap 1.13, height 17.3 (`compactCall`), padding-right 2.8, envelope `[0.2, 0.55, 0.9, 1, 0.85, 0.65, 0.4, 0.35, 0.65, 0.85, 1, 0.95, 0.75, 0.45]` (`voiceEnvelope`, `:22`), first half `#76fb73`, second half `#ff9f0a`, each with a `#fffde0` core (inner bar top/bottom 27.5 %, i.e. 45 % of the bar, same radius).
**Minimal**: ringing = green phone 22; answered = `MinimalPair(phone `#76fb73`, time)`.

**Expanded ringing** (`:233-243`), one row 47 pt, island 84:
- Leading `CallAvatar` (`:132-141`): height 47 flex-centre, margin-left `16.3 - 18.5` = -2.2; `Avatar` **50** pt (monogram: white 600 initials, one letter = 54 % of the disc, two = 40 %, gradient `#554f66` -> `#36294f`; no letters: silhouette).
- Center `CallText` (`:147-161`): width 640 capped at the column, height 27, margin-left -1.4. Line 1: `ExpandedSubtitle` overridden **14 / 400 / line 18**, secondary grey, `margin-top: -4.5`; line 2: `ExpandedTitle` 17 / 600 / line 22 / tracking -0.045 white, `margin-top: -2` = the caller. (Measured baselines 47.7 and 66.2 below the island top.)
- Trailing `CallButtonRow`: flex, gap **10.5**, height 47, margin-right `16.1 - 17.81` = -1.71; two 50 pt round buttons: decline `#fe4345` with `HangUpGlyph` 28 (Hugeicons CallEnd02, heavy) white, accept `#31d259` with `PhoneGlyph` 28 (Call02, fill) white. Press scale 0.96.
**Expanded answered** (`:244-255`): same row: avatar; line 1 = the call time (`TickingTime elapsed`, 14 / 400 line 18) in `#76fb73`, line 2 = caller 17 / 600 white; trailing = an 8-bar `LevelMeter` (same colours and core, height 17.3, bar 2.25, gap 1.13) then the 50 pt red decline (end call) button, gap 10.5; no accept.
States: ringing, answered; a decline/end removes the activity. No missed/failed state.

### 9.2 Isla today
Nothing. The closest things: microphone/camera `Recording` (a call app holding the microphone shows the orange mic and the app icon) and the Timer card's two round buttons. The plan excluded calls: "incoming call and ride ETA (a Mac has no source for them)" (`docs/development/plans/2026-11-14-islandcn-activities.md:34-36`).

### 9.3 Data needed and what a Mac can supply
`caller` (string), `avatar` (image), `subtitle` ("FaceTime Audio", "Video call", app name), `state` (ringing | active + `since`), actions accept/decline/end.
- **FaceTime / Phone (iPhone relay) calls on macOS**: the incoming-call banner is a Notification Center item; no public API gives caller name, state or accept/decline. Realistic sources: the `com.apple.FaceTime` / `Phone` app activation, the NSAccessibility tree of the call banner (needs Accessibility permission, fragile), or the user's own Shortcuts automation ("When I receive a call") posting caller/state to Isla through an App Intent (the same road the timer uses).
- **Zoom / Teams / Meet**: only "app holds mic/camera" (already `CaptureState`) plus `since`. They give no caller or ringing state.
- Accept/decline can only be performed by clicking the app's banner (AX action) or are no-ops; if the control cannot act, the round buttons must not be shown (islandcn shows them only because `onAccept`/`onDecline` are required props).
- A voice meter needs levels; without them use the envelope loop (`LevelMeter` default animation).
## 10. Ride and delivery ETA (new in Isla)

### 10.1 islandcn `eta-activity.tsx`
Props (`:18-58`): `kind` "ride" | "delivery", `arrivesAt` (epoch ms), `title`, `subtitle` (older "plate · car" form), `driverName`, `plate`, `vehicle`, `rating` (halves, 0..5), `service` (short word in compact), `onContact`, `contactLabel`, `accent` (ride green `#32d74b`, delivery yellow `#ffd60a`, `:421`); `progress` is accepted and ignored (no route bar in the preset; `RouteBar` is exported unused, `:75-110`). Priority 0.
Glyphs (`:60-63`): ride = `CarGlyph` (custom body path), destination `PinGlyph`; delivery = `ParcelGlyph` (Package02), destination `HouseGlyph`.

**Compact** (`:439-445`):
- Leading: vehicle glyph 22 pt in accent, or with `service`: `CompactText` overridden to 18 / 400, max-width 42, clipped (not ellipsised), white (`serviceText`, `:363`).
- Trailing: `CompactText` 15 with weight **400**, colour accent, text = whole minutes rounded up + " min"/" mins" ("6 mins"; `withUnit(count, "min", "mins")`, `:429`), `TickingTime remaining`, steady digit crossfade.
- Split bubble: the vehicle glyph alone. **Minimal** (`:446`): `MinimalPair(glyph 22 accent, CompactText accent "6m")` (default weight 600).
**Expanded** (`:447-458`): a top row + a bottom region; island height is whatever the rows add up to (>= 84).
- Leading `EtaVehicle`: frame height `topRow` = 22 + 1 + 20 = 43; the glyph is moved by `left/top` (not margin) inside it: ride box 44 pt at (1.4, 0.9), delivery 42 pt at (0.7, 1.9) (`layout.glyph`, `:142-145`), accent colour; ink starts 21.5 from the island's edge, centre 40.95 below the top.
- Trailing `EtaDriver` (`:277-295`): grid gap 1, right-aligned, max-width `besideSensor` (103), padding-right `trailingInset` = **7.7** (the least that clears the corner arc, `:152`): name (`driverName ?? plate ?? title`) in `ExpandedTitle` 17 **/ 400** / line 22 / tracking -0.045, white; under it the plate in `ExpandedSubtitle` 15 / 400 / line 20 secondary, or with `rating`: five 12 pt `StarGlyph`s, gap 3, row height 14, filled = accent (halves via `clip-path inset`), unfilled = accent at 0.33 opacity (`StarRating`, `:375-390`).
- Bottom `EtaArrival` (`:301-341`), margin-top `rowLift` = 61.7 - 17 - 43 - 8 = **-6.3**:
  - Arrival row: flex, `align-items: baseline`, `space-between`, gap 12, padding-left `rowStart` 3, padding-right 7.7: left = what is coming ("Silver estate", "3 items") `ExpandedTitle` 17 / 400 white (gives way first, ellipsis); right = "Arriving in " (white) + minutes in accent: `ExpandedTitle` 17 / 400, minutes = `TickingTime remaining` with `formatArrivalMinutes` ("6 minutes", "1 minute").
  - With `onContact`: a full-width capsule `ContactCapsule` (`:220-251`) below, row gap 11 (`capsuleGap`): height 44, radius 22, fill `tint(accent, 0.27)` (green `rgba(50, 215, 75, 0.27)`, yellow `rgba(255, 214, 10, 0.27)`), text accent 20 / 600 / line-height 1 / tracking -0.11, `MessageGlyph` 28 in accent, gap 6.6 (9.7 - 3.1), padding `0 18px`; side insets `capsuleSide` leading 2.3 / trailing 2.99 (20.8 from the island edge), `margin-bottom: capsuleRise` = 2.45; hover brightness 1.15, press scale 0.97 + brightness 0.9. Label default "Message <first name>" ("Message driver" / "Message courier").
  - With no capsule the arrival row rises `footLift` = **4.1** so the bottom-left arc clears it.
- States: en route only; arrival ends the activity (no "arrived" view). `title` is not drawn when a name or plate exists (a11y label only).

### 10.2 Isla today
Nothing (plan: "incoming call and ride ETA (a Mac has no source for them)", `docs/development/plans/2026-11-14-islandcn-activities.md:34-36`).

### 10.3 Data needed
`kind`, `arrivesAt` (a timestamp, so the minutes tick on their own), driver name, plate, vehicle/items text, optional rating (0..5), optional service word, optional "message" action (a URL or shortcut Isla opens), accent. A Mac has no native source: the realistic feed is a Shortcut/script/URL that sets and updates these fields (e.g. from a ride or delivery app's email/notification parsing) with the island ending the activity on arrival. Isla needs an input channel (App Intent / `isla://` URL / CLI) and a persistence-free in-memory store keyed by `id`.
## 11. AI agent (new in Isla; **no islandcn preset to copy**)

### 11.1 What exists upstream
Section 0 item 1: islandcn removed its "AI task preset" and left only pieces and two recipes. The spec below is therefore *composed* from islandcn's own primitives and recipes. Everything marked (islandcn) is a number or rule found in the source; everything marked (Isla decision) is not specified upstream and must be chosen once and recorded.

Accent: lagoon `#46f0c6` ("islandcn's own colour, used by the agent preset", `theme.ts:23-24`), contrast 14.5:1 on `#000` (`app/globals.css:54`); `design.md:38` ("lagoon for agents"). Mono face for commands and paths: `islandMono = 'ui-monospace, "Geist Mono", "JetBrains Mono", Menlo, Consolas, monospace'` (`theme.ts:16`) = SF Mono on a Mac; the size/weight of mono text is not specified (Isla decision; suggest 13 pt regular to match `Caption` 13).
Glyphs (islandcn set, `glyphs.tsx:398-413`): `TerminalGlyph` (ComputerTerminal01), `SparkleGlyph` (Sparkles, fill; what the old preset links fell back to, `url-state.ts:132`), `PencilGlyph`, `SearchGlyph`, `GlobeGlyph`, `WrenchGlyph`, `GitMergeRequestGlyph`, plus `CheckCircleGlyph`, `WarningGlyph`, `CloseGlyph`.

### 11.2 Presentations (composition)
- **Working, compact** (`recipes.md:375`: "the task's glyph and a LevelMeter"; `recipes.md:180`: "A build is the same shape: TerminalGlyph, "3/5" in the pill with a ProgressRing in the capsule"): leading `Glyph` 22 in lagoon (the current tool's glyph: Terminal / Pencil / Search / Globe / Wrench, else Sparkle); trailing either a `LevelMeter` (default 4 bars, 3 wide, gap 2, height 16, lagoon, "fits the capsule as it is") or `CompactText` 15 / 600 "3/5" in lagoon; split bubble: `ProgressRing` 20 (thickness 2.5, track `tint(lagoon, 0.25)`) or the glyph alone.
- **Thinking**: `ShimmerText` (15 / 600, base `rgba(235, 235, 245, 0.62)`, sweep `#fff`, 1.8 s linear, 90-degree gradient 0/38/50/62/100 %, plain grey under Reduce Motion), optionally beside a `Spinner` (18, 2.25, 0.8 s).
- **Minimal**: `MinimalPair(glyph 22 lagoon, "3/5" or elapsed time)`.
- **Expanded, working** (`recipes.md:375`): label-led top row: leading `SensorRow glyph={Glyph 18}` + `ContextLabel` (15 / 500 secondary; ~8-9 characters, e.g. "Claude", "Agent"); trailing `SensorRow align="end"` with elapsed time (`Caption` 13 / 500 secondary or `TickingTime`) and a small meter. Bottom `ExpandedBottom reach="lift"` (padding-bottom 13.7, right 0.69): `TailText` source line 15 / 400 grey (`secondary`), result/command line 17 / 600 white (`TailText` default; 28 pt fade at the cut start, line height = size x 1.3 = 22 / 19.5); the newest words stay in view; command text in `islandMono`. Optional `BottomBar` with `StepProgress` (bar: segments gap 4, height 5, done = lagoon, active `tint(lagoon, 0.5)` = `rgba(70, 240, 198, 0.5)`, failed `#ff453a`, pending `rgba(255, 255, 255, 0.16)`; or dots: 7 pt, active capsule 16 x 7, gap 5), placed under the stage title 17 / 600 + detail 15 / 400 (`recipes.md:96-180` stages layout: title and "N min"-style value on one baseline row, `ExpandedBottom gap={4}`).
- **Approval** (`recipes.md:379-433`, verbatim structure): the island must stay open until answered: `island.expand(id)`; compact leading `WarningGlyph` 22 in orange `#ff9f0a`, trailing `CompactText` "Approve?" in orange (it stays so a collapsed approval can be reopened by a tap). Expanded: leading `SensorRow glyph={WarningGlyph 18 orange}` + `ContextLabel` "Needs approval"; bottom `ExpandedBottom reach="action" gap={12}` (padding 7.4 / 8.09 / bottom 7.85): `TitleStack title=<the command or question> subtitle="Waiting for you"` (17 / 600 over 15 / 400 grey, gap 1), then a row, gap 10, of two `IslandButton`s (44 tall, radius 22, 17 / 600 / tracking -0.045, padding `0 18px`, `flex 1 1 0`): **Deny** neutral (`rgba(255, 255, 255, 0.14)` fill, white text), **Approve** accent = lagoon fill `#46f0c6`, text `#000`.
- **Done**: `CheckCircleGlyph` in green `#32d74b` (the design rule: "green for ... arrival", `design.md:38`), `CompactText` "Done"; a 5.975 s alert hold (`motion.alertHold`, `design.md`) if it should expand.
- **Failed**: red `#ff453a` failed step in `StepProgress`, `IslandButton`s "Re-run" and "View logs" in `ExpandedBottom reach="action"` (`recipes.md:180`).

### 11.3 Data model Isla needs (Shortcuts / scripts feed)
`id`, `agent` (name/label), `state` (thinking | running | needs approval | done | failed), `step` index and `total`, `stageTitle`, `detail`, `tool` (terminal | edit | search | web | other, picks the glyph), `output` (growing text, a few updates per second), `startedAt`, `approval` {question/command, approve/deny callback}, `result` summary. Inputs: an App Intent action ("Update Agent Activity", the way the timer's Shortcuts action already exists), a URL scheme, or a CLI that posts to Isla's local socket so Claude Code hooks and shell scripts can call it. An approval needs a reply channel back to the script (a one-shot file/pipe/exit code).
Current Isla analogue: none. The nearest are `LiveActivity` (timers, recording, downloads) and Confirmations; `LiveActivity` needs a new `.agent(AgentState)` case with a rank (islandcn gives no ranks; its `priority` defaults: call 2, everything else 0; `recipes.md:436` "Start with `priority: 2`" for anything that rings, which an approval is).
## 12. Isla activities with no islandcn counterpart

islandcn has no preset, primitive or recipe for any of these; "identical to islandcn" cannot be checked against them. Recommendation: keep them, but redraw their type, colours and spacing from the section 1 tokens so they do not look like a different product beside the new activities.
- **Volume / brightness HUD** (`Model/HUDMoment.swift:86-130`, `UI/HUDViews.swift:14-65`): expanded alert on the iPhone volume shape (`ExpandedAlertShape.volume`): title 15 regular white 0.90 at x 34, symbol 22 x 16 SF, bar **8** tall radius 4, track white 0.18, fill white 0.92 (muted 0.32), percent in rounded monospaced digits. The closest islandcn primitive is `LinearProgress` (height 6 default, track `rgba(255, 255, 255, 0.16)`, round fill springing 0.97 / 0.74) + `Glyph`; islandcn would also add a 17 / 600 title and 15 / 400 grey subtitle. No numbers exist upstream for a HUD.
- **Headphones connected** (`NotchContentView.swift:1006-1032`, `HeadphonesAlertLayout`): glyph + "Connected" over the name; closest upstream pattern is the nearby transfer's `SharePicture` + `MediaText` (14 grey over 17 white) with a `PhoneDeviceGlyph`-style 50 pt disc (`tint(accent, 0.2)`), not a battery ring.
- **Update choice** (`UI/UpdateAlertView.swift`), **Shelf** (tray glyph 26 x 20, count 16 rounded, `CompactIslandLayout.swift:119-134`; bubble 58 wide `IslandBubble.swift`), **Confirmations** ("Copied", "Lyrics imported", "Added to Shelf", `IslandConfirmation.swift`), **Lock card**, **Music peek**.
- **Charging variants** (MagSafe ring), see section 7.

## 13. Cross-cutting differences (affect every activity)

1. **Type tracking.** islandcn: 13 -> 0, 15 -> 0, 17 -> -0.045, 20 -> -0.11, 34 -> -0.09, other sizes 0 (`theme.ts:192-203`). Isla `Theme.tracking(forSize:)` (`UI/Theme.swift:515-523`): < 12 -> +0.07, < 15 -> 0, < 18 -> **-0.2**, < 23 -> -0.35, else -0.5. At 15 and 17 pt (every compact value and every title) Isla tightens 0.2 pt more than islandcn; at 34 pt it is -0.5 vs -0.09. Several Isla activity views (e.g. `TimerText`) set no tracking at all. These are web-browser numbers (Chrome vs the simulator); take them as a delta to test on-device, not as native truth. Needs a decision.
2. **Rounded digits.** Isla uses `design: .rounded` for timers, percentages, counts, times (`TimerText`, HUD number, Shelf count, `MediaPane.timeFont`). islandcn never uses rounded; digits are the default system face with `font-variant-numeric: tabular-nums`.
3. **Icons.** islandcn: Hugeicons free set redrawn at 1.83 pt stroke, solid where SF is solid (`glyph.tsx`, `glyphs.tsx`; 22 pt box). Isla: SF Symbols at 17 pt semibold hierarchical. Identical look requires shipping the Hugeicons vector paths (MIT) as SwiftUI `Shape`s/`Path`s, with the per-glyph `parts` weights; a name-for-name SF mapping (timer, stopwatch.fill, mic.fill, video.fill, arrow.down.circle.fill, bolt.fill, phone.fill, phone.down.fill, car.fill, shippingbox.fill, mappin, house.fill, message.fill, star.fill, sparkles, terminal.fill, exclamationmark.triangle.fill, checkmark.circle.fill) is close but not pt-identical.
4. **Compact insets and widths.** islandcn: content 7.18 from the pill end, text 0.07 from the sensor, slots max 72, pill width fits content with a 0.7475 balance rule (`metrics.ts:15-43`). Isla: music 8.63 from the body edge (`CompactIslandLayout.coverInset`), charger/confirmation text 9.83, live activities (timer/recording/downloads) **14** (`LiveActivityLayout.wingInset`), right side 10.63; widths fixed per activity (70 / 75 / 100 / 140 / 180 over the notch). Not equal to each other, nor to islandcn.
5. **Compact glyph size.** islandcn 22 pt box for every leading glyph/ring; Isla live activities 17 pt, cover 22, MagSafe ring 18, battery 28 x 16, download ring 18, recording dot 8.
6. **Colours.** islandcn orange `#ff9f0a`, green `#32d74b`, red `#ff453a`, blue `#0a84ff`, charging text `#53fa6d`, call green `#31d259` / `#76fb73`. Isla: orange `#FF9F0A` (match), `chargingGreen` `#30D158`, red `#FF453A` (match), blue `#0A84FF` (match), camera green `#30D158`, no `#53fa6d`. Secondary text: islandcn `rgba(235, 235, 245, 0.62)`; Isla uses white at 0.45 / 0.50 / 0.55 / 0.86 / 0.88 depending on the screen (not one token).
7. **Number motion.** islandcn: `live` roll = old digit shrinks to 0.7 and blurs (0.14 px per px) over 0.03-0.21 s, fades 0.19-0.26 s, new digit starts 0.2 s later, scale 0.72 -> 1 over 0.25 s, sharp by 0.48 s (`primitives.tsx:30-62`, `numberMotion`); `steady` for clocks (0.12 s crossfade); `none` for the recorder's time and compact ring figures. Isla: SwiftUI `numericText` + `.snappy(0.25)`; the HUD uses a hard cut. Fine for most; not frame-identical.
8. **Progress motion.** islandcn ring 420 ms `cubic-bezier(0.22, 1, 0.36, 1)`; bar = `IslandProgress` spring 0.97 / 0.74 (also Isla's `IslandProgressRing.spring`, matched); scrubber 500 ms linear.
9. **Expanded geometry.** islandcn expands to the engine island: width screen - 27.66 (374.34 on 402), minimum 84 pt, content padding 18.18 / 18.5 / 17.81 / 18.35, radius 47.9, content clipped to an arc of radius 34.4, side columns capped at `besideSensor` = 103 pt, rows top-aligned with the centre region 20.07 below the content top. Isla's expanded cards are fixed iPhone-board shapes (`ExpandedAlertShape`: timer/mic 335.4 x 120 r24/36; Battery Low 325.4 x 113 r22/40; Full 305.5 x 108 r18/36; update; HUD volume). To be identical, either rebuild the new activities on a body that lays out like `ExpandedBottom`/`ExpandedSide` at the Mac island's real width, or choose one reference width and scale the 18.5 / 17.81 / 18.18 / 18.35 insets and 52 / 50 / 48 / 44 sizes against it. The notch is not a 94.85 pill: on the Mac the leading/trailing columns beside the notch are wider (about 90 pt each on a 14-inch), so `besideSensor` 103 must be re-derived.
10. **Bubble / minimal.** islandcn: attached pill = full compact pair; detached bubble 62.18 wide with the per-activity `withBubble` form; `minimal` is only the fallback when both pairs exceed 290 pt (`metrics.ts:53-82`). Isla: bubble 62 (`LiveActivityLayout.bubbleWidth`), content = a 12 pt glyph + time (`LiveBubbleContent`), Shelf 58. Per-activity bubble forms to adopt: timer = 22 pt draining ring; upload = 22 pt thumbnail then 20 pt ring; transfer = the whole pair (22 + 20); recording = 5-bar wave (2 wide, gap 2, 16 tall) or dot; battery = 27 pt battery alone; call = green phone alone; ETA = vehicle glyph alone; now playing = no bubble form (art + 4-bar meter, "minimal").
11. **Buttons.** islandcn: 44 tall capsule or round buttons, neutral `rgba(255, 255, 255, 0.14)` / pressed 0.24; accent buttons use `#000` text; press `scale(0.96)` 160 ms; hover brightness 1.12. Isla: `RoundControlStyle` 44 circles filled with the tint at 0.25 (pressed 0.40); update alert capsules; no neutral-white 0.14 token.

## 14. Suggested order (from the gaps above)
1. Add the shared kit in Swift once: tokens (`islandAccent`, `islandInk`, sizes), text styles (section 2.1), `ProgressRing`/`CountRing`/`DoneDisc`/`StopSquare`, `Thumbnail`, `Avatar`, `LevelMeter`, `StepProgress`, `TailText`, `ShimmerText`, `Spinner`, `IslandButton`/`RoundButton`, the one-row `MediaRow` (50 / 47 / 48) and the label-led `SensorRow`, so each activity is a table of those pieces.
2. Rebuild existing: Timer (controls left, 48 pt buttons, 34/700 time), Recording (waveform + time + stop/Quit), Downloads and AirDrop as Upload/Transfer, Battery (label + percentage + 35.5 pt battery) and decide whether Battery Low/Full cards stay Isla's own.
3. Then the new: Upload (fed from Shortcuts/scripts), Agent (largest design gap; needs a decision on mono size and a reply channel for approvals), ETA, Call (needs a real source or a Shortcuts feed).
