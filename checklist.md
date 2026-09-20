# Isla parity checklist

This is the live completion view for the approved
[Cyclop 0.6.5 parity design](docs/plans/2026-08-18-dynamic-island-parity-design.md).
Do not mark a manual gate complete without recording evidence in
[the release checklist](docs/release-checklist.md).

## Automated gates

- [x] Swift unit and service tests pass.
- [x] Pinned-source provenance and MIT attribution pass.
- [x] Isla branding and path audits pass.
- [x] English and Russian localization tables validate with matching keys.
- [x] Release bundle builds with executable, helper, icon, localizations,
  licenses, and a valid signature.
- [x] The live media helper returns NDJSON and exits after its input closes.
- [x] Versioned `Isla-<version>.dmg` builds from the verified package, named
  from `Scripts/version` (`0.1.0` today; `0.6.5` is the upstream pin, not
  Isla's own number).
- [x] Lifecycle test leaves no Isla media helper after quit.

## Scope divergence from Cyclop 0.6.5

Snippets and Calendar were removed from the product on 2026-08-20 by
owner decision. They are not deferred and not hidden — the tabs, stores,
panes, privacy sections, and tests are gone, and the calendar entitlement
went with them. The app now claims one entitlement of its own,
`com.apple.security.automation.apple-events` (a Developer ID build adds a
keychain access group at bundle time, see `Scripts/bundle.sh`), which the hardened runtime
requires before the scripting fallback can drive Music or Spotify at all;
macOS asks for that consent at the moment the fallback is first used, and
it is refusable. Nothing is requested at launch. Parity gates below no longer cover either feature, and the parity
claim is explicitly partial as a result. (Two stale section *comments* in
`Resources/en.lproj/Localizable.strings` outlived the removal and were
retitled on 2026-08-21; the keys under them are shared ones that were
always used elsewhere.)

Notes and the Teleprompter were removed on 2026-08-22 by owner decision,
on the same terms: the tabs, panes, stores, privacy sections, strings and
tests are gone, the tall panel body went with the teleprompter, and the
second rail went with the overflow it existed to hold. Five tabs remain —
Music, Shelf, Clipboard, Translate, and Settings at the foot of the one
rail.

Four capabilities were added beyond Cyclop 0.6.5, all of them off or
absent until the user asks. They are recorded here because the parity
design's non-goals rule out "network services" and "accounts", and these
are the exception the design did not anticipate:

- **Lyrics** (Settings, default off) resolves from imported LRC files and
  explicitly selected local folders before any lyric surface opens. It never
  downloads, uploads, scrapes, or sends lyric data. Imported copies, bindings,
  and timing corrections stay on the Mac; ambiguous files always require an
  explicit choice. Enhanced LRC word timing animates only for a measured player
  clock; every other player uses line-level highlighting.
- **Spotify account** (Settings) authorizes through Spotify's PKCE flow
  for Liked Songs, the one feature with no local API. Tokens live in the
  keychain.
- **Lock-screen card** (Settings, default on) presents the player over
  the shield, in a window of its own, finished as Glass or Solid. The
  shield is protected content and no window above it is given a backdrop
  to blur, so the glass is a drawn recipe rather than a sample — the
  system's own lock-screen widgets work the same way.
- **Sound output** (lock card, no setting) lists the Mac's output devices
  and switches the system default. It changes a system-wide setting, so
  it is recorded here even though it needs no permission and no network.
- **Output volume** (lock card, no setting) reads and sets the default
  output device's volume, added 2026-08-25 with the card's rebuild. Another
  system-wide setting, recorded on the same terms. Absent entirely for a
  device that publishes no volume control rather than shown as a slider
  that moves and changes nothing.
- **Screen-recording pickup** (Settings, default on, added 2026-09-11)
  imports movies Screenshot.app saved — its configured location, else the
  Desktop — when the Shelf opens, if they finished after the app first ran.
  Copied recordings already landed through the clipboard; this covers the
  native save-to-disk flow no pasteboard ever sees. The first scan touches a
  folder macOS guards, so the system asks once, with the shelf on screen to
  explain it, and the grant sticks; denied means the shelf shows what it
  holds. Nothing watches in the background.

The status-item menu, and then the whole status item, were removed on
2026-08-25 by owner decision. A window was built first and withdrawn the
same day: the panel's own Settings tab already carried Open Panel, About
and Quit, so both a menu and a window were second front doors to what
the island already does. The app now shows no Dock icon, no menu-bar
item and no window at any time, and its activation policy is
`.accessory` with nothing able to change it. ⌥⌘I is the only route in
that needs no pointer. This is narrower than the parity design's shape,
which assumes a menu-bar item, so it is recorded here.

From 2026-09-10 the first launch of a fresh account is the one exception,
and it is not a second front door: the panel opens itself once and its
own body says the app is running, where it is, what the two hotkeys are,
and that Quit lives in Settings. It is a pane, not a window and not a
sixth tab, and it exists for one launch — `hasCompletedFirstRun` in the
app's defaults. Something had to say it: the app's whole design is
invisible, and `LSUIElement` keeps it out of Force Quit as well, so a
first launch was indistinguishable from a failed one and a user who
could not find the panel could not quit it either.

The panel opens on a click rather than a hover, from 2026-08-26. The
parity design specifies a hover-opened panel and the delays that govern
it; those delays now govern the hover route only, which survives as
**Open on Hover** in Settings and is off by default. The compact island
also lost its one control — the equalizer wing toggled playback, which
gave a single surface two meanings once a click began opening the panel.
Recorded here because it narrows a behaviour the design states.

Translucency became the system's own material on 2026-08-25, through
`glassEffect` where macOS has it, with the hand-drawn recipe standing in
below macOS 26 and anywhere there is no backdrop to sample. With it, the
app now answers **Reduce Transparency** — surfaces go opaque — and
**Increase Contrast** — the lit rim becomes a defined border. Neither is
a divergence so much as a debt paid: an app built on a translucent
material owes those settings an answer. `defaults write
com.ctimothe.isla drawnGlass -bool true` forces the drawn recipe
everywhere, for the one surface whose backdrop cannot be checked from a
build machine.

Haptic feedback was added on 2026-08-25, at two moments only: an output
device chosen, and a click on a lyric landing the song on that line. It
needs no permission, leaves nothing, and is silent on Macs without a
Force Touch trackpad.

The panel's width became a setting on 2026-08-25, `480…620 pt` with a
default of `560`. The parity design fixed it at `620`; it is recorded here
because a person can now change a number the design stated. The window it
is drawn in is untouched at `700 × 444 pt` — the body narrows inside a
frame that never resizes.

Privacy defaults were also corrected on 2026-08-21: the panel is now
hidden from screen capture by default, and clipboard-screenshot saving
is off by default with a 200-file cap once enabled.

## Manual parity gates

- [ ] Every tab passes its workflow on a clean macOS account.
- [ ] The lyrics page scrolls both ways, holds where it is left, and the
  sync pill returns it to the sung line.
- [ ] Compact music and lock-card captions never go blank: exercise disabled,
  settling, finding local lyrics, ready, no local lyrics, invalid local file,
  retry, import, binding removal, and ambiguous-file selection.
- [ ] Validate physical-notch, lock-card, offline behavior, folder changes,
  VoiceOver, Reduce Motion, English, Russian, and local-LRC workflows.
- [ ] Measure Spotify and Apple Music word timing at or below 150 ms p95; keep
  every unmeasured publisher line-level.
- [ ] Run local-library prefetch checks: an already indexed local timeline must
  be available before any panel opens, and a folder rescan must not replace a
  displayed lyric with an ambiguous or lower-confidence candidate.
- [ ] The lock card appears centred at its own size across repeated
  lock/unlock cycles, including after display sleep.
- [ ] Protected Shelf files prompt only when the Shelf is opened or used.
- [ ] Physical-notch behavior passes on a supported MacBook.
- [ ] Synthetic-notch behavior passes on an external/non-notch display.
- [ ] English and Russian layouts have no clipping or untranslated product copy.
- [ ] Quit/relaunch, launch at login, unavailable helper, and
  missing Shelf file scenarios pass.
- [ ] Three-run performance medians meet the approved Cyclop 0.6.5 gates.
  Blocked: CPU peaked at `0.3%` rather than absolute `0.0%`, and helper RSS
  measured `19.05 MiB` versus `19.03 MiB` for Cyclop.
- [ ] Developer ID signing, notarization, stapling, and Gatekeeper validation pass.

## Release verdict

- [ ] All eleven release gates have evidence.
- [ ] The 102-finding audit of 2026-08-21 is closed out: every fix is in
  the tree, `swift test` passes, and every script gate runs green.
- [ ] The release commit is clean and pushed.
- [ ] Release notes exist at `docs/releases/<version>.md`.
- [ ] `Scripts/release.sh` completes without bypassing a gate.

Evidence and remaining blockers are recorded in
[the 2026-08-18 release-candidate report](docs/verification/2026-08-18-release-candidate.md).

## v0.2 — the front door

Closed from the 2026-09-03 audit (`docs/audits/2026-09-03-synthesis.md`):

- [x] A promised file from Mail or Photos no longer trapping the process
  (`ShelfDropTests`).
- [x] The whole drawn island answering a click on synthetic notches
  (`CompactHitAreaTests`).
- [x] A clicked-open panel released by a second click and by the pointer
  leaving. A mouse click no longer pins the panel at all — the pointer that
  clicked is already standing where the panel holds itself open from; only
  ⌥⌘I, the Translate service, and VoiceOver's accessibility action still pin
  (`OpenOnClickTests`, `HoverRectTests`).
- [x] `Scripts/test-gatekeeper.sh` in the gate order and in CI.
- [ ] Developer ID signing, notarization and stapling — blocked on an Apple
  Developer Program membership. Everything else in this list is worth less
  than it looks until this lands: an unsigned build loses the MediaRemote
  path on the user's machine.
- [x] First-run pane shown once per account, until it is answered. The panel
  opens itself about 0.8 s after a launch that finds `hasCompletedFirstRun`
  unset, and the body shows `WelcomePane` instead of a tab: that the app is
  running, that it lives at the notch and opens on a click, both hotkeys, and
  where Quit is. Pressing Get Started — or picking any tab out of the rail —
  sets the flag and lands on Music. Only those two set it: closing the panel,
  locking, sleeping, or dropping a file on the island all take the pane off
  screen with the flag unset, and the next launch offers it again. A display
  change carries it across the rebuild instead, the same way the selected tab is
  carried. Not a window, not a tab, not a status item: the 2026-08-25
  withdrawal stands (`FirstRunTests`, `TabContractTests`). Validated by hand
  on 2026-09-10 - see the run recorded at the foot of this section.
- [x] `PointerWatcher.tick`'s ordinary inside-to-outside transition now
  carries an `isDragging()` guard, so dragging a file *out* of the Shelf no
  longer closes the panel mid-drag. Recorded here as open when Task 3
  shipped; the final review found it had become reachable from the default
  path once a click stopped pinning, so `holdsOpen` had stopped masking it,
  and it was closed in the same release (`PointerWatcherTests`).

### Validation run - 2026-09-10

**Mac16,8**, macOS 26.6.2 (25G83), Apple M4 Pro. From a clean build: `rm -rf .build
build`, then all eleven gates re-run green, then installed to `/Applications`
and launched from there rather than from the worktree.

Exercised on the built-in notched display: the first-run pane on a cleared
`hasCompletedFirstRun`, click-to-open, click-to-close, walking away, and the
drag paths. **Not** exercised: an external display, which is the only place the
`collapsedDepth` change has any effect; and Open on Hover switched on, which is
the mode the final review flagged for a fold-and-reopen. Both remain owed.

## v0.3 — native motion and material (in progress)

From the approved plan `docs/plans/2026-09-10-v0.3-native-motion-and-material.md`,
branch `feat/v0.3-native-motion`:

- [x] Increase Contrast reaches the whole app (2026-09-11,
  `ContrastRampTests` + `AccessibilityDisplayTests`): the `Theme` colour
  tokens are functions of the setting, the selected rail chip carries its own
  fill plus border after `ShelfPane`'s selected tile, the lyric falloff is
  clamped to a floor, and a live change redraws through the one
  `SystemAppearance` observation at `NotchContentView`. The surface raises are
  shape-visibility fixes for everyone, not accessibility variants. Shipped
  2026-09-11: surface base 0.16, surfaceHover base 0.26 — the brief's step-3
  prose said 0.12/0.22, but those compute to 1.27:1/1.79:1 and fail the brief's
  own 1.4/2.0 test floors, so the tests governed. Lyric neighbour 0.34/0.44,
  floor 0.28/0.38; hairline base stays 0.10 by design (1pt edge, not a fill).
- [x] The cover is one object that travels (2026-09-10, `e2c3240`,
  `ArtworkMorphTests`): `matchedGeometryEffect` between the pill's 22 pt cover
  and the pane's 118 pt cover, both ends described once by
  `Theme.artworkMetrics`, the equalizer travelling the same way.
- [x] Play and pause replace each other instead of cutting (2026-09-10,
  `7826630`): `.symbolEffect(.replace)` on every state-driven glyph swap,
  `.identity` under Reduce Motion. Not unit-testable; verified by eye.
- [x] Three timings that fought what they carried (2026-09-10, `1fd2269`,
  `MotionValuesTests`): panel content arrives on `paneIn`/`paneOut` rather
  than the open spring, the lyrics page moves on its own spring (0.42 / 0.86,
  the one overshoot in the app), and the lock card fades in instead of
  appearing in one frame.
- [x] Fifteen font sizes became six roles (2026-09-11, `fc25c89`,
  `TypeRoleTests`): `Theme.TypeRole` — caption 10, body 11, subhead 13,
  title 16, display 21, hero 28 — read through `islandFont(_:)` so the
  tracking table still applies.
- [x] The copy reads like one app wrote it (2026-09-11, `c9af7bb`): the
  editorial pass over both tables, and `Scripts/test-localizations.sh` now
  scrapes `localized("…")` and `Button("…")` call sites against the English
  table in both directions.
- [x] Four one-edit corrections (2026-09-11, `04f4465`, `FormatTimeTests`):
  `formatTime` rolls hours, its duplicate in the lock card is gone, the grain
  tile lands 1:1 on a 2x display, and long names truncate in the middle.
- [x] Merged as `d20c88c` on 2026-09-11.

## Review pass — 2026-09-20

A first-glance pass against Apple's *Designing Fluid Interfaces* rules and the
HIG, on branch `claude/quick-review-macos-design-cd5943`. Everything below
either shipped in that pass or is listed as an open decision for the owner.

Shipped:

- [x] **Press-down feedback everywhere.** `PanelButtonStyle` in `Theme` dims a
  control while it is held, the way `NotchButtonStyle` and
  `TransportGlyphStyle` already did; every `.buttonStyle(.plain)` in the panel
  now uses it. The island's own press lift drew nothing at all — it was
  `.opacity(2.2)`, which the compositor clamps to 1 — and now lays the light
  down a second time while pressed.
- [x] **Hover answers on the content ease, not the open spring.** The lift
  took 0.34 s to arrive; it takes 0.16 s.
- [x] **Reduce Motion reaches the controller.** `NotchController`'s two
  `withAnimation(Theme.openAnimation)` calls read `Theme.open(reduceMotion:)`
  like the view does; the lock card's output popover falls back to a fade.
- [x] **Tooltips and names.** `.help(…)` on the transport, shuffle, repeat, the
  rail, the back button, and the clear/remove glyphs; `accessibilityLabel` on
  the four icon-only buttons that had none; the lock card's seek and volume
  bars are adjustable elements for VoiceOver (they were invisible to it).
  22 pt targets on the copy, reveal, clear and remove glyphs and the lyric
  nudges.
- [x] **The lyrics editor sheet answers Escape and Return.**
- [x] **Tokens where literals had crept back**: `ShelfPane`'s selected tile
  reads `Theme.selectedChip`/`selectedChipBorder` (it was the model for them,
  and had stopped following the contrast ramp), `Theme.success` replaces two
  bare `Color.green`s, `Theme.capsTracking` replaces three hand-typed
  tracking values for one role, and the one raw `.easeInOut` in `MediaPane`
  is `Theme.contentAnimation`.
- [x] **The hover-delay slider commits on release**, like the width slider.
- [x] **The caption chevron no longer re-truncates the lyric under the
  pointer**: it is always in the row and only its alpha moves.
- [x] **Settings icons no longer repeat within a section**: word karaoke,
  import, add/remove folder, rescan and dismiss each carry their own glyph
  (`SettingsIconTests` holds that the set has no duplicates).
- [x] **Accuracy**: `CLAUDE.md` said `main` carried documentation only — it
  has carried the code since the v0.3 merge; the gate order in `README.md`
  had lost `test-gatekeeper.sh`; `NotchMetrics.teleprompterBody` outlived the
  teleprompter by a month and is `tallestBody`, with the reason the window
  keeps its height stated; stale comments in `Theme`, `MediaPane`,
  `SettingsPane` and `LyricsStage` that described removed code are gone; the
  Russian table lost an orphaned `/* Заметки */` and its two spellings of
  "screenshots"; four unit readouts (`0.05s`, `560 pt`, `+0.25s`) are
  localized; three strings joined the Title Case convention and two gained
  their full stop.

- [x] **Lyrics are instant and turn on the beat** (2026-09-20, second
  commit of this pass). No lyric surface waits for `positionSettled` any
  more — the "Syncing playback…" spinner that met every open of the panel is
  gone, and the line shown is the one the clock points at, corrected when a
  reading lands. The clock wakes on the frame a line is due
  (`MediaController.setLyricBoundaries`) instead of on its 250 ms grid, and
  both leads drop from 0.25 s to 0.20 s now that the grid no longer has to be
  covered. `Scripts/measure-sync.sh` has **not** been re-run since; it is the
  arbiter and is owed a run against live Spotify. Amended in
  `docs/superpowers/specs/2026-09-14-line-synced-lyrics-design.md`.
- [x] **The Solid lock card is one surface.** `glassSurface(solid:)` routes
  it through the opaque panel Reduce Transparency already draws; the
  `.ultraThinMaterial` and black scrim that sat *under* the drawn glass are
  gone (`GlassRoutingTests`).

`docs/research/2026-09-20-paid-notch-apps-patterns.md` records what the paid
notch apps charge for and ranks ten things Isla could ship free without a new
entitlement — camera/mic in-use pill, AirDrop from the Shelf, battery, Shortcuts
via App Intents, a volume HUD promoted off the lock card, a timer, a mirror,
deeper lyric offsets, Downloads progress and Quick Look in the Shelf, and a
calendar next-event (which would reverse a 2026-08-20 removal). None is
started; each is the owner's call.

### Lyrics UX — 2026-09-21

- [x] **⌥⌘L opens the lyrics page** and folds it back to the player when
  pressed again. The page's state moved from `MediaPane`'s own `@State` to
  `NotchViewModel.isShowingLyrics`, so it is a place the app can be *sent*
  rather than a toggle only the pane can flip — which is also what the
  `DI_OPEN_LYRICS` hook now uses instead of an `onAppear` reading an
  environment variable. Leaving the Music tab folds it.
- [x] **The global lyric delay has a writer at last** (Settings → Music,
  ±3 s). It existed in `LyricsStore` and no interface wrote to it, so the only
  cure for a catalogue that ran early — or for the delay a pair of AirPods
  adds — was nudging every track one at a time. Named *delay* to keep it
  distinct from the lyrics page's per-track *timing* nudge. Closes item 3 of
  `docs/audits/2026-09-13-…-lyric-sync-investigation.md` §3.4.
- [x] **A lyric can be copied.** Right-click any line on the page: Copy Line,
  or Copy All Lyrics, which leaves out the credits the app inferred. The words
  were readable and not quotable, which for a lyric is most of the point.

### Apple ecosystem — 2026-09-21

- [x] **Shortcuts, Spotlight and Siri** (`Sources/IslaKit/App/IslaIntents.swift`).
  Eight intents — Show Lyrics, Show Isla, Get Current Lyric, Get Current Track,
  Set Lyric Delay, play/pause, next, previous — and four App Shortcut phrases,
  so the first of those answer from Spotlight without anyone building a
  shortcut first. No entitlement, no permission, no network: it adds a
  *surface*, not a capability that leaves the machine, which is why it is
  recorded here and not in the privacy list above.

  The metadata Shortcuts reads is generated at bundle time by
  `appintentsmetadataprocessor` out of the `.swiftconstvalues` SwiftPM already
  emits — there is no Xcode project here to run the usual build phase. It needs
  full Xcode rather than just the Command Line Tools: `Scripts/bundle.sh` warns
  and continues without it, and `Scripts/test-package.sh` refuses a release
  whose bundle lacks the metadata or its App Shortcuts. **Owed:** a human
  opening Shortcuts and Spotlight to confirm the verbs appear and run; Launch
  Services will likely want the app in `/Applications` to register them.

Owed on the lyric path, in order:

- [ ] **Re-run `Scripts/measure-sync.sh`.** The leads moved to 0.20 s and line
  changes are now scheduled on their own boundary; neither has been measured
  against live Spotify. The harness is this repo's arbiter for any sync claim.
- [ ] **Word karaoke is gated on a *measured* clock, which today means Spotify
  alone** (`LyricsPresentation.usesWordTiming` requires `precisionMeasured`).
  An Apple Music listener with a word-timed LRC never sees the sweep, even
  though the MediaRemote helper's clock may well be good enough. Deciding that
  needs the probe pointed at Music, not a guess.
- [ ] **Per-source bias** (`LyricSource.bias`, all zeros) — item 2 of the same
  investigation, and the amplifier behind "certain songs run fast".

Open, for the owner — each is a design decision, not a defect:

- [ ] `LockScreenCard` still carries 22 white/black literals and a scrim over
  real glass on macOS 26 — a second, untracked theme.
- [ ] `SettingsPane.choiceRow` is a hand-rolled segmented control; a native
  `Picker(.segmented)` would restore arrow keys and radio-group VoiceOver but
  look like AppKit on a dark pane.
- [ ] Hovering the rail for 150 ms switches tabs. macOS does not navigate on
  hover outside menus; kept because it is documented and cheap to cancel.
- [ ] The rail icon scales 1.15× on hover on top of the chip fill. macOS fills
  a well and does not grow the glyph.
- [ ] No focus rings and no keyboard shortcuts inside the panel (⌘, ⌘W,
  Return-to-confirm). Escape is handled at the window. An `.accessory` app
  has no menu bar to carry these, so it is a per-panel binding while key.
- [ ] Escape does not disarm a two-press confirmation; it closes the panel.
- [ ] `Toggle("", isOn:)` with a detached label: clicking the label text does
  not flip the switch, which a native labelled `Toggle` gives for free.
- [ ] `TranslatePane`'s font ladder `[27, 20, 15, 11]` shares only its last
  rung with the six type roles.
- [ ] `NotchMetrics.collapseRectShrinkDelay` (0.45) is tied to the open
  spring's settle by comment only.
- [ ] `Translator.swift:173` uses the deprecated
  `GenerationOptions(sampling:)`; the replacement (`samplingMode:`) exists
  only in the macOS 27 SDK, so switching would break a macOS 26 Xcode build.
- [ ] `scripts/check` is tracked in lowercase while every other script is
  under `Scripts/`; one directory on this Mac's case-insensitive disk, two on
  a case-sensitive one.
