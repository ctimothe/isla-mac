# islandcn, identical: every look, icon and motion, tweaked only for the notch

Owner request, 2026-11-15, after Leo's announcement of islandcn
(<https://github.com/opencoredev/islandcn>, MIT, still at
`0011a41ea4882f3818caf35c98f3ee46b80c4a2c` — nothing changed upstream since
the first port, `2026-11-14-islandcn-activities.md`): copy it "fully and
completely, with every edge case, every design, every icon, every look and
everything identically", and every motion too ("the current ones are old"),
changing only what a notched MacBook forces.

The gap is measured in `docs/development/audits/2026-11-15-islandcn-identical/`
(`motion.md`, `activities.md`, `icons.md`; Sonnet, read-only, every islandcn
number quoted with file:line). This plan only orders that work.

## Owner decisions (2026-11-15)

1. **Island identical, panels restyled.** The island and every activity copy
   islandcn exactly. The player, lyric stage, Shelf, Clipboard, Translate and
   Settings keep their layouts and take islandcn's colours, type, icons and
   buttons.
2. **Real where possible, the rest through Shortcuts.** A Call activity from
   call apps (FaceTime, Zoom, Teams, Meet, Telegram, WhatsApp) holding the
   microphone, with the call's length. ETA, Upload and an Agent activity that
   any app, script or Shortcut can start (App Intents and an `isla://` URL).
3. **islandcn's icons everywhere.** Hugeicons free 4.4.0 (MIT, verified from
   the npm tarball) replaces every SF Symbol Isla draws; other apps' icons stay
   the real app's.

## What the notch forces (and nothing else)

- The island hangs from the bezel: no top edge, no `top` property or its
  tails, no `collapseLift`, no keyline along the top, and the idle shape is
  the screen's own notch rect, not islandcn's 94.85 × 36.84 cutout.
- A press swells from the top edge, not about the centre.
- Sizes scale by the notch's height over islandcn's 36.67 pt pill.
Everything else — bottom corners, wings, the bubble gap, every spring — is
islandcn's number.

## Still to decide (owner), recommendation first

a. **Reduce Motion.** islandcn tweens 0.2 s ease-out; on Isla that gives a
   38.6 pt first-frame jump (F-055). Recommend: keep Isla's 0.24 s ease-in-out.
b. **Volume and brightness pop-up.** islandcn's `appearExpand` (0.54 and
   content delays) is slower than the "no delaying" pop-up chosen 2026-10-25.
   Recommend: islandcn's shape and look, the current speed.
c. **The outline's line.** islandcn's 1.5 pt keyline fades with the
   wallpaper's brightness; the owner chose one line for every wallpaper on
   2026-10-17. Recommend: islandcn's width, alpha and collapse dip, kept on
   every wallpaper.
d. **The fold after a click.** `wasAlert` is never passed, so every fold
   uses `alertCollapse`. Recommend: fix it, so a click-fold uses islandcn's
   `collapse`.
e. **Recording's waveform** needs the microphone's level, which only a
   permission prompt gives. Recommend: islandcn's pulsing-dot variant, no
   prompt; keep Mute and Quit in its expanded view.

## Slices (each test-first, its own commit, `swift test` green)

Branch `feat/islandcn-identical`, cut from `feat/islandcn-activities`
(99a51e7), worktree `.claude/worktrees/islandcn`.

- **S1 Icons.** Vendor the Hugeicons element arrays Isla uses as a Swift table
  (`IslandGlyphs`), and a renderer that follows `glyphs.tsx`'s recipes (part
  roles fill/line/heavy/cut and their draw order, stroke `2·(22/s)^0.35`,
  `place`, `view`). Replace every SF Symbol (`icons.md`, ~140 names; six need
  substitutes, about twelve have no good match and are drawn from the nearest
  icon). Attribution in `THIRD_PARTY_NOTICES.md`.
- **S2 Theme.** islandcn's ink, accents, type (sizes, weights, tracking 0 at
  15 pt, no rounded digits) and insets (`theme.ts`) as Isla's tokens.
- **S3 Shape.** Continuous corners (0.72), compact radius `height/2`,
  content-derived compact widths, islandcn's expanded minimum (84 pt), press
  swell, shadow and keyline.
- **S4 Motion core.** Per-property springs (height, corner, each edge, body),
  the idle detour, lean-and-settle tails, `pressExpand`, `collapseSplit`,
  `appearWide`; content enter/exit per transition (springs, delays, blur,
  scale, fade exponents, region stagger, blur skirt) — `motion.md` C1–C2.
  The outline host already samples at 120 Hz, so this stays off the main
  thread.
- **S5 Bubble.** Island and bubble as one animated path with islandcn's edge
  springs, pinch-off, absorb slide and rest gap 7.82 (`motion.md` B1–B4).
- **S6 Every activity identical.** Music (meter, type, scrubber, transport),
  Timer (mirrored layout), Stopwatch, Recording, Downloads and AirDrop as
  islandcn's nearby-transfer with a real progress view, Battery
  (`activities.md` §1–8).
- **S7 New activities.** Call (from the capture watch, call apps only, the
  call's length; a Mac shows no incoming ring, so no accept or decline), ETA,
  Upload, Agent (composed from islandcn's agent pieces: lagoon, mono type,
  shimmer and tail text, step progress), started by App Intents and `isla://`.
  New watchers default off and are recorded in `checklist.md`.
- **S8 Panels.** The surfaces take S1–S3's icons, tokens and buttons.
- **S9 Every other motion** (`motion.md` §B, ~45 entries: the new-track
  change, panel open and close, alerts, the HUD, lyric lines, pages, the
  Shelf), each on its islandcn equivalent or the nearest islandcn family.

Then: Codex review of the branch, a Claude Opus review of the motion core,
`./scripts/check`, the dev feed, and the owner's hardware checks (to be
written per slice, IC2-H…), then ask before merging to `main`.

## Cost

This is the largest change since the R8 redesign: about nine slices, likely
several sessions. Each slice lands on the feed on its own so the owner sees it
grow.
