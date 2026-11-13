# islandcn port: iPhone motion, new activities, any activity as the bubble

Owner request, 2026-11-14: bring the open-source islandcn
(<https://github.com/opencoredev/islandcn>, MIT, commit
`0011a41ea4882f3818caf35c98f3ee46b80c4a2c`) into Isla: its features, its
UI and motion, "and more a real dynamic island has and should have".

islandcn is a React component, so none of its code can run in Isla. What
ports is its measured design: the springs it fitted frame by frame to the
iPhone simulator (`lib/island/motion.ts`), its content crossfade, its
in-place number and progress motion, its split with a metaball neck
(`lib/island/path.ts`), and its activity presets. The numbers and the neck's
geometry are carried over with attribution in `THIRD_PARTY_NOTICES.md`.

## Owner decisions (2026-11-14)

1. New activities: **Timer**, **Recording**, **Downloads**, **Battery Low /
   Full**, and more an iPhone island has. Added from "more": **Stopwatch**
   (beside the timer) and **AirDrop arrivals** (beside Downloads). Left out:
   incoming call and ride ETA (a Mac has no source for them), Focus (needs a
   new entitlement, which is a product decision of its own).
2. **Adopt the iPhone-measured motion**: per-transition springs instead of
   one outline spring. Amends spec §19.3.
3. **Any live activity can be the bubble**, with the gooey pinch-off.
   Amends spec §19.1 and §19.7.

## Tier and pipeline

Tier 3 (changes the motion contract, adds activities that read the system,
generalises the split): worktree `feat/islandcn-activities` cut from
`origin/main` 48b0606 → this plan → test-first slices → Codex review →
`./scripts/check` → dev feed → owner's hardware checks → merge.

## Slices (each its own commit, gate green before the next)

### S1 Motion (`IslandMotion`)
- One table of islandcn's shape springs (`appear`, `expand`, `appearExpand`,
  `swap`, `collapse`, `alertCollapse`, `split`, `unsplit`, `dismiss`,
  `resize`), and `IslandMotion.transition(from:to:)` picking one from the
  activity the island leaves and the one it goes to, as islandcn's
  `geometry.ts` does. `Theme.island(reduceMotion:)` stays the fallback and
  Reduce Motion's ease is unchanged.
- The content crossfade's blur peaks follow islandcn's round-14 values (the
  phone's leaving content is far less blurred than Isla's 30 / 15).
- Not ported: the retarget through the idle shape, the tails (lean and
  settle) and the per-property springs. Core Animation draws one curve per
  part (`OutlineCurve`); a second leg would need a keyframed path of its own.
- `IslandProgress`: a fill that springs to a new value (0.97 / 0.74), for
  every ring and bar the new activities draw. Digits use SwiftUI's
  `numericText` turnover, which is the same motion.

### S2 Battery Low and Full Battery (spec §19.5 a, b, as written)
Ranks 4 and 8. Once per discharge at 20 % and 10 % on battery; once per
charge at full, reset by unplugging or falling below 95 %. Settings
General › Low Battery Warning, Fully Charged, both on. No permission.

### S3 Timer and Stopwatch
Started from the right-click menu (Timer ▸ 1, 3, 5, 10, 15, 25, 30, 60
minutes; Stopwatch) and from Shortcuts (App Intents). Live while running or
paused. Compact: the orange `timer` / `stopwatch` symbol and the time in
orange, tabular. A click expands it in place with Pause / Resume and Cancel.
When a timer ends: an alert at rank 4, "Timer Done", the system sound once,
held 10 s or until dismissed. Local only, nothing to switch on.

### S4 Recording (microphone and camera in use)
CoreAudio's process objects (macOS 14.2+, public:
`kAudioHardwarePropertyProcessObjectList`, `kAudioProcessPropertyIsRunningInput`,
`kAudioProcessPropertyBundleID`) name the apps using the microphone; CoreMediaIO's
`kCMIODevicePropertyDeviceIsRunningSomewhere` says whether a camera runs.
Live while either is true. Compact: an orange microphone or green camera
symbol, and the app's icon. A click brings that app forward. Setting:
General › Microphone and Camera, **off** (privacy-adjacent: it watches other
apps). Isla's own process is never counted.

### S5 Downloads and AirDrop
A file-system source on `~/Downloads`. In-progress files: Safari's
`.download` bundles (progress from its `Info.plist`), `.crdownload`,
`.part`, `.opdownload`, `.download` files. Live while one is in progress:
the download symbol and a ring (determinate when the browser says how big,
a spinner otherwise). When it finishes: a confirmation "Downloaded" with the
name; a click reveals it in Finder. A new file whose quarantine agent is
AirDrop (`sharingd`) is announced as "AirDrop" instead. Setting:
General › Downloads, **off** — reading `~/Downloads` raises macOS's own
folder permission prompt the first time.

### S6 Any live activity as the bubble, with the neck
Live ranks become: recording 11, timer 12, stopwatch 13, music 14,
downloads 15, Shelf 16 (peek stays 10). The second live activity waits as
the bubble beside the first, in its minimal form (glyph plus a short value).
It pinches off the island with islandcn's metaball neck (`path.ts`
`bridgePath`, thinning to nothing at a 5 pt gap) on the `split` spring, and
merges back on `unsplit`. A click on the bubble does what a click on that
activity does.

## Docs owed with the code
- Spec §19.1, §19.3, §19.5, §19.7: dated amendments in place.
- `docs/development/checklist.md`: Recording and Downloads under Scope
  divergence (they read other apps' state; both default off), and the
  hardware checks below.
- `THIRD_PARTY_NOTICES.md`: islandcn's MIT notice.

## Hardware checks owed (IC-H1…)
- IC-H1 the new springs on the owner's notch: appear, expand, fold, dismiss.
- IC-H2 Battery Low at 20 % and 10 % on battery; Full Battery once at 100 %.
- IC-H3 a 1-minute timer: wings, pause, cancel, the Done alert and its sound.
- IC-H4 a FaceTime call: microphone and camera activity, the app's icon.
- IC-H5 a Safari and a Chrome download: the ring, Downloaded, Reveal; an
  AirDrop from an iPhone.
- IC-H6 timer beside music: the bubble pinches off and merges back.
