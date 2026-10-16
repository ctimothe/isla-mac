# The visual lab — 2026-10-11

A headless photographer for every surface Isla draws, so the design review
against Apple's guidance can look at every screen, state, animation and
transition without a running app — and without touching a Mac that other
sessions are using.

```bash
bash Scripts/visual-lab.sh                       # → build/visual-lab
bash Scripts/visual-lab.sh /some/folder          # → there
bash Scripts/visual-lab.sh /some/folder VisualLabPillTests   # one case, added to what is there
```

The script is `ISLA_VISUAL_OUT=<dir> swift test --disable-sandbox --filter VisualLab`.
Every lab case throws `XCTSkip` unless `ISLA_VISUAL_OUT` is set, so
`./scripts/check` runs the same target and none of this. It is a tool run by
hand, never a gate: the renders are for eyes, and nothing is asserted about
pixels.

## What it never does

Nothing drives the desktop:

- **No window is ever on screen.** Views are hosted in an `NSHostingView`
  inside a borderless `NSWindow` that is created with `defer: true` and never
  ordered in, then drawn into a bitmap with `cacheDisplay(in:to:)`; or drawn by
  SwiftUI's `ImageRenderer`, which needs no window at all.
- **No input.** No `CGEvent`, no `NSEvent` is posted. The three states that
  need a press (an armed Clear, a copied row, an armed Quit) are pressed through
  the element's accessibility press action, in-process — the same call an
  assistive client makes.
- **No screen capture, no Isla launch, no `DI_*` hook, no AppleScript.**
- **No owner state.** Every key a view reads from `UserDefaults.standard` is
  answered from the *argument domain* — a volatile, in-memory domain that sits
  first in the search list and is never written to disk — and put back after
  each case. Stores that take a `UserDefaults` get a private suite that is
  deleted afterwards. Nothing is `set` on the standard defaults.
- **No real pasteboard.** The clipboard history is filled through the store's
  own `record`, with fixed dates; the store is handed a uniquely named private
  pasteboard, which only the "row just copied" state writes to, and which is
  released at the end. The general pasteboard is never read or written.
- **No network.** A `URLProtocol` registered for the process answers every
  request itself: Spotify's Liked Songs check gets the answer the case asks
  for, everything else is refused as offline (which is also how the Translate
  offline error is produced — through the real failure path).
- **No real player.** Every `MediaController` is cut from real players
  (`isolateFromPlayers`), carries no player pid (so no AppleScript, no
  `NSRunningApplication` lookup), and runs on a frozen monotonic clock.
- **No real Spotify account, keychain item or support folder.** A throwaway
  `CredentialStore` in a temporary folder stands in, through the
  `SpotifyAccount.sharedOverride` seam, before anything asks for `shared` — the
  live account is lazy and is never built.
- **No real devices.** The lock card's audio watch reads four fixture outputs
  and installs no Core Audio listener.

## Seams added to `Sources/`

Four, each the smallest that let a whole panel be built hermetically, each
inert unless a test uses it:

| Seam | Why |
| --- | --- |
| `NotchStores.init(…, shelf:, clipboard:, screenshotVault:, translator:, privacy:)` | The defaults built the general-pasteboard clipboard, created `~/Pictures/Isla`, and wrote the standard defaults from `PrivacyMode`/`Translator`. Omitted, each is built exactly as before. |
| `SpotifyAccount.sharedOverride` (and `shared` now a computed property over a lazy `live`) | Settings and the lock card read `SpotifyAccount.shared` from inside the view tree; the live account's first read goes to the owner's keychain and support folder. |
| `ClipboardStore.record(_:)` private → internal | A named pasteboard is still served by the pasteboard daemon, and in a sandboxed session it never changes; the history is filled directly instead. |
| `Translator.capabilitiesOverride` | "Missing language pack" and "Apple Intelligence off" depend on what the rendering Mac has downloaded; stated instead, the obstacles render on any machine. |

## Output

```
<out>/
  manifest.json                   one record per image: surface, state, variant, backend, size, scale, path, a11y, notes
  <surface>/<state>__<variant>.png    2x
  contact-sheets/<surface>[-n].png    32 thumbnails a page, labelled state · variant
  a11y/<surface>/<state>__<variant>.txt
  animation/<curve>.csv           t_ms, value, velocity (and closed form for springs), 1 ms steps
  animation/metrics.json          parameters, settle, overshoot, hand-off, thrown velocity
  animation/refusal-shake-offset.csv
  keyframes-<sequence>/t000ms__frame.png … t500ms__frame.png
```

### Surfaces and states

| Surface | States |
| --- | --- |
| `pill` | resting in the notch, pointer-awake, playing (equalizer), playing + pointer lift, paused with play badge, new-track peek (plain, long title, CJK), charger charging / holding / no level, headphones (plain, long name), charger over music, synthetic notch idle / playing / lift, locked playing / locked with pointer edge / locked nothing playing |
| `panel-music` | nothing playing, playing with lyrics off, lyrics caption, word-sweep caption, finding lyrics, no local lyrics, paused, long title, CJK title, no artwork (skeleton, then placeholder after the 2.5 s wait), live stream (no duration), podcast over an hour |
| `panel-lyrics-stage` | before the first line, line-synced, mid-line sweep, word karaoke, instrumental gap, long wrapping lines, CJK lines, no lyrics (online off / on), loading, resolving (blank on purpose), lyrics off, invalid local file, no artwork |
| `panel-shelf` | empty, drop target, a few cards, two selected, at the 60-card cap, a missing file (pruned on open), Clear armed |
| `panel-clipboard` | empty, empty with history off, populated, privacy-covered, one row revealed, a row just copied, Clear armed |
| `panel-translate` | empty, result, online result, long input, needs online (Uzbek, switch off), offline error, missing language pack, Apple Intelligence off, privacy-covered input |
| `panel-settings` | viewport top, viewport with Open on Hover; every section at full length with defaults, with everything on, and with Spotify connected |
| `panel-welcome` | first run |
| `lock-card` | Transparent / Tinted / Solid × Standard / Compact × player / lyrics / output |
| `lock-card-states` | no lyrics found and lyrics off (both sizes), finding lyrics, long lines, paused, long title, no artwork, heart liked / not liked / asking |
| `confirmation` | copy button idle / copied, Clear idle / armed, the Quit row armed |
| `keyframes-*` | open, close, caption line turn, stage page step, pill unfold, pill fold, hover nudge, refusal shake — at 0, 16, 33, 50, 83, 120, 200, 300, 500 ms |

### Variants

One axis at a time from a base of dark desktop, English, 560 pt body:

| Variant | What changes |
| --- | --- |
| `dark` | the base |
| `light` | a pale wallpaper and light menu bar. Isla's own windows stay dark Aqua — `NotchPanel` forces it — so only what is behind the island changes, which is exactly what a light desktop changes |
| `increase-contrast` | `SystemAppearance` and SwiftUI's `colorSchemeContrast` both say increased |
| `reduce-transparency` | both say reduced |
| `w480`, `w620` | the panel width setting at its two ends |
| `ru` | the Russian table from `Resources/ru.lproj`, swapped in for both `localized(_:)` and SwiftUI's own `Text` lookup |
| `*-ir` | the same state through `ImageRenderer` instead of the hosting view |

The panels take all of them; the pill drops Reduce Transparency and 620; the
lock card takes every accessibility variant twice, once per renderer, because
its cover light is the one place where the renderers disagree most.

## Two renderers, and what each cannot draw

Neither renderer is complete, so the lab uses both and says which drew what
(`backend` in the manifest):

| | `host` — NSHostingView + `cacheDisplay` | `ir` — `ImageRenderer` |
| --- | --- | --- |
| AppKit-backed controls (Toggle, Slider, TextEditor, Picker menus) | drawn | a yellow "unavailable" plate |
| ScrollView content | drawn | **nothing** |
| `NSViewRepresentable` (equalizer, shelf drag source, vibrancy) | drawn (vibrancy as flat grey) | a plate |
| SwiftUI `.blur`, Core Animation filters | **not drawn — content comes out sharp** | drawn |
| `.task` / `onAppear` / `onReceive` state | runs (the lab waits a settle time) | first frame only |
| accessibility tree | yes | no |

What follows from that:

- **Glass.** Neither can snapshot `NSVisualEffectView` or macOS 26's
  `glassEffect`, which sample the live backdrop. Every render uses the drawn
  recipe (`GlassSurface`, forced with `drawnGlass`) over a stand-in wallpaper.
  The lock card with no cover samples the desktop through vibrancy and comes
  out flat grey; that render is labelled so.
- **The lyrics stage** needs both a ScrollView and a 60 pt blur. Its hosting
  renders are given a cover that is already blurred, so the ambience is right;
  the stage shows the cover only as that ambience, so nothing sharp is lost.
- **The lock card's** cover light is a 44 pt blur. Its hosting renders show
  the cover sharp behind the glass and are kept for the accessibility tree;
  the `-ir` renders are the faithful look.
- **The panel's `-ir` renders** show yellow plates for the equalizer and the
  shelf's drag overlay, and empty Settings and Clipboard lists. They exist to
  show blur where the hosting render cannot; read the hosting render for
  everything else.

## Keyframes

The keyframes are **reconstructions**, not captures: SwiftUI exposes no clock
a test can scrub, and an animation in a window that is never on screen does not
tick. Each frame is composed from the real end-state views (rendered by the
hosting renderer on a clear ground) and the real modifiers where they are
reachable (`NotchShape`, `LyricLineTurn`, `KaraokeText`, `LyricRow`,
`PillPresence.appearance`, `NotchContentView.restingShape/awakeShape`), placed
at the values the sampled curves give at that millisecond:

- **Open / close.** Shape size and radii on `Theme.openAnimation`; the body on
  `Theme.paneIn` (open) or `Theme.paneOut` (close), the header strip on the
  open spring, the pill's header leaving with opacity and a 0.9 scale; all
  clipped to the body's interpolated frame. The cover is drawn twice along its
  matched-geometry path — the pill's copy fading with the compact header, the
  pane's copy fading with the body — because that is what a matched pair inside
  two fading containers does. Its two ends are measured, not assumed: each end
  is rendered with a magenta cover and the bounding box read back.
- **Caption line turn** — both lines through `LyricLineTurn` on the lyric spring.
- **Stage page step** — real `LyricRow`s offset by the spring's travel, the
  outgoing and incoming current rows crossfading on the same spring.
- **Pill unfold / fold** — shape on the pill spring, content on its own
  spring and delay with `PillPresence`'s blur, scale and opacity ends.
- **Hover nudge** — resting → awake shape on `Theme.hoverNudge`.
- **Refusal shake** — the locked pill offset by `RefusalShake`'s decaying sine
  (mirrored, since `ShakeOffset` is private; its duration and swing count are
  read from the source line).

Layout interpolation is modelled as SwiftUI's per-view frame lerp. That is the
honest limit of the keyframes: they show what the curves and the end states
imply, and a reviewer who wants the real thing frame by frame still needs a
screen recording of the app.

## Animation sampler

`VisualLabAnimationTests.testCurvesSampledAtOneMillisecond` reads every
curve's parameters back from the `Animation` value the app uses — SwiftUI's
description of a spring carries its response and damping, and a timing curve
carries its exact cubic-bezier coefficients — and samples it at 1 ms:

- **Springs** through the SDK's own `Spring(response:dampingRatio:)
  .value(target:initialVelocity:time:)` and `.velocity(…)`, with the textbook
  closed form (mass 1, stiffness (2π/response)²) alongside; the two agree to
  2e-16.
- **Timing curves** by solving the bezier SwiftUI reports. The lock card's
  fade is read from a real `CAMediaTimingFunction(.easeOut)`.
- **Literals inside views** that a test cannot reach (the karaoke sweep, the
  button press, the refusal shake, the skeleton shimmer, the lock card fade
  duration) are read from the source line by pattern; the case fails if the
  line stops matching.

Per curve: settle to within 1 %, time to 90 %, peak overshoot (in percent and
in points where the travel is known), whether critically damped, initial and
peak velocity, a reversal at 50/100/150/200 ms (springs merge and carry
velocity; timing curves do not merge and are modelled additively), and for
springs what a thrown start at 2–40 units/s would do.

## First run — 2026-10-11

634 renders in 233 s on the lab's sandboxed agent session (no window server,
no screens: the geometry stood on an allocated `NSScreen` stand-in, which no
view reads), 13 cases, all passing. Per surface: lock card 180, Music 73,
pill 68, lyrics stage 64, Translate 49, Clipboard 33, lock-card states 31,
Shelf 27, Settings 17, confirmation 12, welcome 8, keyframes 72 (8 × 9).
Accessibility dumps: one per hosting render.

### Curves

From `animation/metrics.json`. Settle is to within 1 % of the travel;
"reversal" is the panel shut 100 ms into an open (or the equivalent for each
curve).

| Curve | Definition | 90 % | Settle 1 % | Overshoot | Reversal at 100 ms |
| --- | --- | --- | --- | --- | --- |
| open / close | spring 0.34 s, ζ 1.0 | 211 ms | 360 ms | none | velocity carried (5.38/s), no undershoot, settles 346 ms later |
| compact | spring 0.28 s, ζ 1.0 | 174 ms | 296 ms | none | carried |
| pill unfold | spring 0.42 s, ζ 1.0 | 261 ms | 444 ms | none | carried |
| pill fold | spring 0.50 s, ζ 1.0 | 310 ms | 529 ms | none | carried |
| pill content in | spring 0.36 s, ζ 1.0, +70 ms | 293 ms | 451 ms | none | carried |
| pill content out | spring 0.22 s, ζ 1.0 | 137 ms | 233 ms | none | carried |
| lyric scroll | spring 0.42 s, ζ 0.86 | 216 ms | 307 ms | **0.5 % = 0.24 pt of 48 pt** at 412 ms | carried, 0.3 % undershoot |
| hover nudge | spring 0.34 s, ζ 0.72 | 146 ms | 358 ms | **3.8 % = 0.58 pt of 15 pt** at 245 ms | carried, 2.8 % undershoot |
| content, artwork | ease-out 0.16 s | 119 ms | 148 ms | — | not merged: a −10.8/s kink |
| pane | ease-out 0.18 s | 134 ms | 167 ms | — | kink −9.6/s |
| pane in | ease-out 0.20 s +40 ms | 189 ms | 225 ms | — | kink −8.6/s |
| pane out | **ease-in** 0.12 s | 113 ms | 120 ms | — | starts at 0/s |
| reduce motion (open, lyric, press) | ease-out 0.12 s | 89 ms | 111 ms | — | — |
| reduce motion (pill) | ease-out 0.15 s | 112 ms | 139 ms | — | — |
| karaoke sweep | linear 0.25 s | 226 ms | 248 ms | — | — |
| refusal shake | ease-out 0.50 s driving 11 pt × 3 decaying swings | 371 ms | 463 ms | — | — |
| lock card fade | CA ease-out 0.22 s | 163 ms | 204 ms | — | — |
| skeleton shimmer | linear 1.15 s, repeating | — | — | — | — |

SwiftUI's solver and the closed form agree to 2e-16 on every spring. A thrown
start shows where the critically damped springs stop being overshoot-free:
the open spring needs more than ω = 2π/0.34 ≈ 18.5 units/s (at 40/s it
overshoots 18 %); the fold overshoots 4 % from 20/s.

### What the renders show

Found by looking, with the file that shows it. Model-based findings (from
keyframes, which are reconstructions) say so.

1. **The lyric page's overshoot is invisible.** `Theme.lyricScroll` is the one
   spring allowed to overshoot, "enough that the page reads as having been
   carried". At ζ 0.86 it overshoots 0.5 % of a 48 pt step: 0.24 pt, under a
   pixel even at 2×. Either the overshoot is not doing what the comment says,
   or the damping is not what the comment wants (ζ ≈ 0.6–0.7 gives 2–5 pt).
   `animation/metrics.json` → `lyric-scroll`; `keyframes-stage-page-step/`.
2. **The hover nudge's "single visible bump" is about half a point.** ζ 0.72
   over a 15 pt growth peaks 0.58 pt past the awake size.
   `metrics.json` → `hover-nudge`; `keyframes-hover-nudge/t200ms…t300ms`.
3. **Close slices the body while it is still mostly opaque (model-based).**
   The body leaves on `paneOut`, an *ease-in* 0.12 s, which starts at zero
   velocity: at 50 ms it is still ~86 % opaque while the shape (open spring)
   has already shrunk the clip, so the rail and the right-hand time label are
   cut mid-glyph. The open was fixed for exactly this with a delayed
   `paneIn`; the close was not. `keyframes-close/t033ms__frame.png`,
   `t050ms__frame.png`.
4. **Lock card: dim lyric lines vanish over a bright cover light.** Context
   lines at white 0.28–0.34 sit on the lit corner of the card and are barely
   legible, most of all on a pale wallpaper; the elapsed time at
   `cardTertiary` has the same problem.
   `lock-card/clear-standard-lyrics__light-ir.png`,
   `lock-card/glass-standard-lyrics__dark-ir.png`.
5. **The lyrics stage guillotines its bottom row.** A wrapped line at the
   bottom of the stage is cut through the middle of its second row; the edge
   mask fades but does not reach the clip.
   `panel-lyrics-stage/long-lines-wrapping__w480.png`.
6. **An instrumental break shows nothing.** With the current line an empty
   LRC line, the reading centre is blank between two dim lines for the whole
   break (28 s in the fixture): no glyph, no progress, no sign the stage is
   still following. `panel-lyrics-stage/instrumental-gap__dark.png`.
7. **Remedy buttons do not look like buttons.** Translate's "Turn On
   Translate Online", "Translation Languages…", "Apple Intelligence
   Settings…" and "Retry" are bare bold caption text, where the same kind of
   one-action offer elsewhere ("Show Lyrics", "Open Spotify") is a capsule.
   `panel-translate/offline-error__dark.png`, `needs-online__dark.png`.
8. **Empty states without words.** Shelf and Clipboard (history on) are a
   single grey glyph; the Translate source box has no placeholder.
   `panel-shelf/empty__dark.png`, `panel-clipboard/empty__dark.png`,
   `panel-translate/empty__dark.png`.
9. **Settings switches read as inactive.** The panel never becomes key, so
   every `Toggle` draws in AppKit's inactive style: on and off differ only by
   knob position and a lighter grey track. (The hosting renderer draws the
   window as the app's is — not key.)
   `panel-settings/all-sections-defaults__dark.png`.
10. **Settings' Music group mixes kinds.** A "Local Lyrics Library" subheading
    appears as body-sized grey text inside the group, and "Peek at New
    Tracks" — a pill behaviour — sits at the end of the lyric actions.
    `panel-settings/all-sections-defaults__dark.png`.
11. **Lock card with lyrics off is a dead end.** "Lyrics are off." with no
    way to turn them on, where the panel's stage offers "Show Lyrics".
    `lock-card-states/lyrics-off-standard__dark-ir.png`.

### Accessibility

From `a11y/`:

- **Reading order interleaves the rail and the pane.** The rail's buttons and
  the pane's text are siblings sorted by position: Music, "Isla is running.",
  Shelf, "It lives at the notch…", Clipboard, … A VoiceOver user hears the
  tabs and the content shuffled. `a11y/panel-welcome/first-run__dark.txt`,
  `a11y/panel-music/playing-lyrics-caption__dark.txt`.
- **The compact pill's element is the whole window.** "Playing: Waiting Room,
  Halcyon Static" reports a 700 × 84 frame — the window — not the pill, so a
  VoiceOver cursor would outline the menu bar. `a11y/pill/playing-equalizer__dark.txt`.
- **Scrubbers expose no value or slider role.** "Playback Position" (panel
  and card) and "Volume" (card) come through as `AXUnknown` with no value,
  although the panel declares a value and an adjustable action.
  `a11y/panel-music/…`, `a11y/lock-card/glass-standard-player__dark.txt`.
- **Unlabelled images.** The cover is an `AXImage` with no label in the pane
  and on the card, and the card's cover light (690 × 690) and grain (460 ×
  300) surface as two more unlabelled images.
- **The headphones and charger moments** are `AXUnknown` with a good label
  ("AirPods Pro connected") but no role a screen reader announces as status.

### What the lab cannot draw

- **System glass** (`glassEffect`, `NSVisualEffectView`) — no backdrop to
  sample offscreen. Drawn recipe everywhere; the lock card with no cover comes
  out flat grey.
- **Reading mode with the Sync pill** — `following` is the stage's private
  state, set only by a scroll-wheel event. Needs a seam (an initial
  `following: false` and a reading line) or an event the lab will not post.
- **Hover-only states** — a hovered rail chip, a hovered shelf card's remove
  button, a hovered clipboard row's reveal eye and remove button, the
  scrubber's hover knob and time preview, the caption chevron, a pressed
  island. They live in private `@State` set by `onHover`.
- **The update-available badge and Settings row** — `UpdateCheck.shared` is
  a singleton whose state only a real check sets.
- **Shuffle and repeat** — their buttons appear only for a scriptable player
  that answered, and the lab never asks one.
- **"Translating…"** — a moment inside an `async` call with no seam to hold it.
- **Real shelf previews** — QuickLook is unreachable from the sandboxed
  session the first run used, so cards show file-type icons.
- **Relative ages and language names in Russian** — the shelf's age formatter
  is a static built once in the language the process started in; the lab's
  Russian swap comes later, so those few strings stay English in `ru` renders.
- **The source badge** shows the letter fallback ("M") because the lab's
  players have no pid and so no app icon.
- **The Open-player buttons** on "Nothing is playing" list whichever players
  the rendering Mac has installed.
