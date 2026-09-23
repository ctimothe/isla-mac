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
requires before Isla can script Music or Spotify at all. That covers the
fallback, and also shuffle, repeat, the Spotify track id behind the heart,
and, while lyrics are on, the per-second position correction. So macOS asks
the first time the panel opens on Music or Spotify, not only when the
fallback is used; the consent is refusable, and refusing it costs those
controls and nothing else. Corrected 2026-09-23: this note and the prompt's
own text used to say the access was only for the fallback. Nothing is
requested at launch. Parity gates below no longer cover either feature, and the parity
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
  explicitly selected local folders before any lyric surface opens. Imported
  copies, bindings, and timing corrections stay on the Mac; ambiguous files
  always require an explicit choice. Enhanced LRC word timing animates only for
  a measured player clock; every other player uses line-level highlighting.
- **Look Up Lyrics Online** (Settings, default off, added 2026-09-21) is the
  only part of the lyric path that reaches the internet. A streamed track has no file
  on this Mac, so the offline-only rule approved on 2026-09-13 meant a Spotify
  listener saw "No local lyrics" on every song. With the switch on, a track the
  local library does not match is looked up at LRCLIB — free, community-run, no
  account, no key — sending the title, artist, album and duration and nothing
  about the listener. When the exact record misses — a streaming service
  rarely names the album the catalogue does — LRCLIB's search is asked with
  the title and artist alone, and a timed match within three seconds of the
  length is taken. Answers are cached so a song is asked about once, misses
  for a fortnight; a lookup that cannot reach the service is asked again on
  its own after 5s, 30s and 2min rather than offered as a Retry button. A
  local file always wins; an ambiguous local result still asks. Timelines
  from it are line-level, so the word sweep stays off for them. The design
  doc carries the dated amendment and `OfflineLyricsIsolationTests` bounds
  the exception to one file and one service.
- **Translate Online** (Settings › Translate, default off, added 2026-09-21)
  sends a pair no engine on this Mac offers at all — Uzbek and Kazakh — to
  MyMemory (translated.net): free, no account, no key. It receives the text and
  its two language codes, over an ordinary web request. A pair Apple's
  Translation framework or the on-device model offers is never sent, even when
  it cannot run right now — not downloaded, Apple Intelligence off, or a
  refusal — and is reported instead (fixed in review the same day: online had
  been the fallback for all three). An answer that came from the network
  carries a globe in its heading. `OnlineTranslationTests` bounds the exception
  to `OnlineTranslation.swift` and the one host; `TranslatorTests` holds that no
  on-device pair ever lists the online engine.
- **Check for Updates** (Settings › Application, added 2026-09-23) asks
  GitHub's `releases/latest` for the newest Isla and, if it is newer than the
  running one, offers its release page. It sends the request and nothing else:
  GitHub sees an IP address and a User-Agent naming the Isla version. Pressing
  the row is the consent for one request. **Check for Updates Automatically**
  (default off) asks once a day and marks the Settings tab when there is
  something new. It exists because nothing else could tell a 0.1.0 user that
  0.2.0 was out. Sparkle replaces it once there is a Developer ID to sign the
  feed with. `UpdateCheckTests` holds the default and the request.
- **Spotify account** (Settings) authorizes through Spotify's PKCE flow
  for Liked Songs, the one feature with no local API. Tokens live in the
  keychain.
- **Lock-screen card** (Settings › Lock Screen, default on) presents the
  player over the shield, in a window of its own, finished as Transparent,
  Tinted or Solid and sized Standard or Compact. The
  shield is protected content and no window above it is given a backdrop
  to blur, so the glass is a drawn recipe rather than a sample — the
  system's own lock-screen widgets work the same way. Since 2026-09-21
  the Glass card is lit by the song's own cover, blurred and dimmed, the
  way Apple Music's player is; lit by nothing it read as a grey slab. It
  carries previous, play and next only, the volume in its foot rail, and
  its lyrics stay open from one song to the next.
- **Sound output** (lock card, no setting) lists the Mac's output devices
  and switches the system default. It changes a system-wide setting, so
  it is recorded here even though it needs no permission and no network.
- **Output volume** (lock card, no setting) reads and sets the default
  output device's volume, added 2026-08-25 with the card's rebuild. Another
  system-wide setting, recorded on the same terms. Absent entirely for a
  device that publishes no volume control rather than shown as a slider
  that moves and changes nothing.
- **Screen-capture pickup** (Settings, default on, added 2026-09-11; widened
  to stills and to every folder captures have been sent on 2026-09-21) shows
  what Screenshot.app saved — its configured location, the Desktop, and any
  location it has pointed at since — on the Shelf when it opens, if the capture
  finished after the app first ran. **Nothing is copied:** the card holds the
  file where macOS put it, so dragging it out drags the original and deleting
  it there removes the card. A movie counts on its type alone; a still must
  also carry the capture prefix (`com.apple.screencapture name` when set,
  else the system's), because the capture folder is so often the Desktop and a
  folder of somebody's own pictures must not be swept up wholesale.
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

- [x] **Measured, 2026-09-21** (`Scripts/measure-sync.sh`, live Spotify,
  Mac16,8 / macOS 26.6.2, word-timed fixture spanning the track). The first run
  **failed** the harness's own 150 ms word-timing gate at p95 0.167 s — and the
  bias was near zero, so the failure was entirely the *spread*. The cause was
  not the lead: `position` republished only on a 250 ms ticker, so any surface
  drawing between two ticks read a number up to a quarter-second stale. At a
  100 ms tick the same run measured **p95 0.074 s and 0.083 s, PASS**, with
  steady-play delta a median 0.188 s behind truth — which the 0.20 s lead
  centres to within 12 ms. Every phase median sits inside its gate.

  `Scripts/measure-sync.sh` and `Scripts/validate-lrc.sh` had stopped working
  entirely: both linked IslaKit by enumerating one `.o` per source under
  `$BUILD/IslaKit.build`, and the current toolchain emits a single merged
  `IslaKit.o` and no per-source objects. They handle both layouts now. The
  harness had been unrunnable for as long as that toolchain has been in use,
  which is why "re-run the probe" had stayed owed.

### Track changes — 2026-09-21

- [x] **A skip draws no loading state while the answer is quick.** Every track
  change used to publish "Finding lyrics…" at once, so a cached hit flashed a
  spinner for a frame and a run of skips strobed. `LyricsAvailability.resolving`
  is drawn as nothing — the slot already holds its height — and is promoted to
  `findingLocalLyrics` only after `LyricsCoordinator.quietGrace` (0.35 s).
- [x] **A skip cancels the request the skip before it started.** Ten fast skips
  used to leave ten requests running against a free service for nine answers
  nobody would see. The generation counter only discarded the *results*.
- [x] **The cache write left the main thread.** It encoded and wrote
  synchronously on every answer, which during a run of skips was a file write
  per skip on the thread the panel, the scrubber and the lyric sweep draw from.
  Coalesced to one write per 400 ms, written off-main.
- [ ] **Prefetching the *next* track is not possible today, and is not
  pretended to be.** Spotify's `next track` is a command, not a readable
  property; MediaRemote publishes now-playing only, with no queue. The one real
  route is Spotify's Web API `/v1/me/player/queue`, which needs the
  `user-read-playback-state` scope — Isla currently requests only
  `user-library-read`/`user-library-modify` — and a connected account, so it
  would help only those who have one. Worth doing behind the existing account
  connection; it would make a skip inside a known queue genuinely pre-warmed.

Owed on the lyric path, in order:

- [x] **The faster ticker costs nothing while the panel is shut** (measured
  2026-09-21). `updateTicker` guards on `isActive`, which is panel-open, so
  the 10 Hz clock does not exist in the state the CPU gate measures. Sampled
  with a track playing and the panel closed: **mean 0.12%, peak 0.30%** over
  20 seconds, helper RSS 19.61 MiB — the same neighbourhood as the blocked
  gate's 0.3% / 19.05 MiB, and not made worse by this change.
- [ ] **A full `Scripts/measure-performance.sh` run is still owed**, because
  the approved gates are a *comparison* against a Cyclop 0.6.5 build from
  `Scripts/build-reference.sh`, which this has not produced. What is measured
  above is Isla alone, which answers whether the ticker hurt and not whether
  parity holds.
- [x] **Word karaoke is not Spotify-only** — checked 2026-09-21, having
  claimed otherwise. `MediaController.precisionPlayer` resolves to
  `displayedPlayerApp`, which is Music *or* Spotify, and
  `PlayerBridge.precisePosition` scripts either by bundle id. So an Apple
  Music listener with a word-timed LRC and the switch on does get the sweep.
  What genuinely has no measured clock is a browser tab or any non-scriptable
  player, and there the line-level highlight is the honest answer.
- [ ] **Fetched lyrics never animate word by word**, which is a *source*
  question rather than a gate one: LRCLIB carries line-level LRC only. Word
  timing today means an enhanced LRC imported by hand. Closing that means
  either a word-level catalogue — which is what the removed QQ/KRC providers
  were — or accepting that karaoke is for files you bring.
- [ ] **Per-source bias** (`LyricSource.bias`, all zeros) — item 2 of the same
  investigation, and the amplifier behind "certain songs run fast".

Open, for the owner — each is a design decision, not a defect:

- [ ] `LockScreenCard` still carries 22 white/black literals and a scrim over
  real glass on macOS 26 — a second, untracked theme.
- [ ] `SettingsPane.choiceRow` is a hand-rolled segmented control; a native
  `Picker(.segmented)` would restore arrow keys and radio-group VoiceOver but
  look like AppKit on a dark pane.
- [x] Hovering the rail for 150 ms switches tabs. macOS does not navigate on
  hover outside menus; kept because it is documented and cheap to cancel.
  **Decided by the owner, 2026-09-21: a click only.** A fast pass across the
  rail flipped panes and replayed each glyph's fill behind the cursor.
- [x] The rail icon scales 1.15× on hover on top of the chip fill. macOS fills
  a well and does not grow the glyph. **Gone with the hover switch,
  2026-09-21:** a hover draws the well and nothing else.
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

### Native motion — 2026-09-21

Filmed on 2026-09-21 over the lock screen: a pause folded the pill into the
notch in a single frame, "too intense, too raw".

- [x] **The pill folds into the notch and grows back out, locked or not.** The
  locked branch refuses every animation from outside, and the pill was mounted
  only while something played, so a pause removed it in one frame. It now stays
  mounted for the whole lock and answers its own change on its own curve. The
  wings contract on `Theme.pillFold` (0.5 s, critically damped) and grow on
  `Theme.pillUnfold` (0.42 s), where every pill resize used to share 0.28 s.
- [x] **The cover and the bars ride the wings and dissolve ahead of the edge.**
  Unlocked, the header left the tree the moment the pill folded and kept its
  old width, so the contracting clip swept across a cover that sat still. It
  now stays laid out while the panel is shut and fades, blurs and shrinks on
  `Theme.pillContentOut` (0.22 s); arriving, it waits 0.07 s for a wing to
  exist. `PillFoldTests` holds both halves against the springs' closed forms.
- [x] **No flash of "playing" on the way in.** A settled pause is `.hidden`, and
  only `.paused` drew the badge, so every fold began by brightening the cover.
- [x] **No fading outline at the start of a fold.** A second black layer over
  the wings faded on its own 0.12 s at the old width; it was plain black by
  then and went.
- [x] **A peek ends on the fold curve**, not the 0.16 s content ease.
- [x] **The lock card's lyrics glide a line at a time.** The window of lines
  jumped a slot per line; the leaving line now goes up and out and the next
  rises in from below on the lyric spring, one row each way
  (`LockCardLyricGlideTests`). A seek is still a cut.
- [x] **Scrolling the lyrics by hand lifts every line to reading brightness**
  (0.46, still under the sung line's 0.5), and they settle back to depth when
  the page follows the song again.
- [x] **The stage's follow is a real spring** — measured, not assumed: a
  `ScrollView` driven through `scrollPosition` inside `withAnimation` honours
  the spring on macOS 27 (a 0.4-damped probe overshot 76 → 88 pt and settled).
- [x] **The rail wears its own glyphs.** Its five were, glyph for glyph, the
  upstream project's (`music.note`, `tray.full.fill`, `list.clipboard.fill`,
  `translate`, `gearshape.fill`). Now `music.note`, `rectangle.stack`,
  `doc.on.clipboard`, `character.bubble` and `slider.horizontal.3`, filled when
  chosen, as a tab bar does; the Settings privacy rows and the two empty states
  follow. `TabContractTests` keeps the old four out. Music tried `play.circle`
  (read as a button) and `music.quarternote.3` (read as busy), and at the
  owner's word keeps the plain `music.note` — the system's own glyph, and the
  rail as a whole is no longer the upstream's. The replace effect on the fill
  went too: a third of a second behind every click.
- [x] **The rail changes tabs on a click only**, and its well and selection
  land on the frame they happen. The 150 ms hover dwell is withdrawn (design
  amendment 2026-09-21) and `NotchMetrics.tabDwell` with it.
- [x] **Translate chooses its languages.** Sixteen, in the column headings as
  menus: the source detects (Uzbek by its own letters and words, since Apple's
  recognizer does not know it — `LanguageDetectionTests`) or is told; a swap
  exchanges languages and text; the choice is remembered. Engines by pair:
  Apple's Translation framework when installed (en↔ru, en→tr, en→ko measured at
  0.3–1.2 s on this Mac, and it translates "Delete all my files", which the
  model refused), the on-device model for its own languages, MyMemory only with
  Translate Online on. Uzbek verified live both ways ("Bugungi yordamingiz
  uchun katta rahmat."); `TRANSLATOR_LIVE=1` reruns the whole matrix.
- [x] **The model can no longer run away.** Uncapped, one English sentence into
  Uzbek generated for 218 s until the 8,192-token context was full. Responses
  are capped at three tokens per source character (128–4,096).
- [x] **A menu no longer folds the panel.** A language list hangs below the
  panel, and moving down it read as the pointer leaving. An open menu now holds
  the panel the way a drag does, and closing it gives the pointer 1.2 s to come
  back (`MenuTrackingTests`). The lyric and shelf context menus get the same.

### Translate, as used — 2026-09-21

- [x] **"salom" no longer comes back as "Google TRANSLEÓN".** MyMemory's
  default answer is the best match from its public translation memory, which
  held that entry at 0.98, above the right "Привет". Requests now ask for
  machine translation only (`onlyprivate=1`): "salom" → "привет", verified live.
- [x] **One Uzbek word is recognised on its own** when only Uzbek writes it —
  "salom", "rahmat", "yaxshimisiz" — where it used to fall back to English.
  Words Uzbek shares with English ("men", "ham") still need company.
- [x] **The message names the language the Mac lacks.** Uzbek into Russian said
  "Russian is translated online"; it names Uzbek.
- [x] **Choosing a language clears the answer in the old one** at once, rather
  than leaving it under the new heading for the debounce and the engine's time.

### One Isla on the Mac — 2026-09-21

- [x] **Spotlight listed three Isla apps.** Builds in `build/`, an old copy in
  `~/Applications` and a stale temporary build were all registered. Removed,
  leaving `/Applications/Isla.app` as the only registration. The bundle is now
  assembled in `build/app.noindex/` (Spotlight skips a folder named `.noindex`;
  `.metadata_never_index` was tried and is ignored), `Scripts/install.sh` is the
  one way to install and relaunch and unregisters the built copy, and
  `test-lifecycle.sh` unregisters the copy it launches when it exits.

### 0.2.0 — 2026-09-21

- [x] Released ad-hoc signed through `ISLA_ADHOC=1 ISLA_RELEASE_REMOTE=github
  bash Scripts/release.sh`: every gate runs, only Developer ID signing and
  notarization are skipped, and the release notes carry the one quarantine
  command a downloaded build needs. The tag must name a commit already on the
  remote, checked against the remote's branches rather than an upstream, so a
  release can be cut from a detached checkout of the merge commit.
- [x] README rewritten for people installing it: install, features, privacy,
  building, uninstalling. Release notes in `docs/releases/0.2.0.md`.

### For strangers — 2026-09-23

Everything the 2026-09-23 exploration found, except Developer ID and
notarization, which the owner excluded. Plan: `docs/plans/2026-09-23-for-strangers.md`.
The baseline it answered: 8 stars, 5 of them the owner's own accounts, 5 DMG
downloads in total, and no outside issues.

- [x] Shortcuts default to ⌃⌥⌘I / ⌃⌥⌘L / ⌃⌥⌘T. The old ⌥⌘ keys took Web
  Inspector, Downloads and Finder's toolbar away from their apps. All three
  are rebindable in Settings, and a refused one is named.
- [x] A refused helper load exits perl at once (status 3) and goes straight to
  the fallback, instead of 45 s of silence and an orphaned perl. The fallback
  names its reason in Settings and on the Music tab, retries on wake (a
  refused load only on Try Again), and precision polling waits for lyrics.
- [x] The Apple Events prompt says what the access is for. It and the Desktop,
  Documents and Downloads prompts are localized, and the localization gate
  checks them.
- [x] Copy Diagnostics and Report a Problem in Settings. Every log line goes
  through `Log` (os.Logger). GitHub has issue forms.
- [x] Check for Updates, with automatic checking off by default (see the
  capability list above). CFBundleVersion is a monotonic BUILD.
- [x] The lyrics page offers Show Lyrics and Look Up Online. Clipboard history
  has an off switch. Spotify refusals say why.
- [x] The lock-screen space is reference-counted per window (audit B9). The
  wake decision is `NotchController.wakePlan`, tested.
- [x] Universal binary and helper. App Intents strings are localized.
- [ ] **Physical check owed:** lock and unlock with the card on and with it
  off, and plug in a display while locked. The space change is unit-tested
  against stand-in SkyLight calls only.
- [ ] **Physical check owed:** the Intel slice has only been built, never run.
  No Intel Mac was available.
- [ ] **Owner:** check whether the Spotify app is still in development mode
  (dashboard, "Users and Access"). If it is, only listed accounts can use
  Liked Songs. Settings now says so when Spotify refuses.
- [ ] README screenshots: they need the live app on the owner's screen.
- [ ] **Physical check owed:** with VoiceOver on, press ⌃⌥⌘L and ⌃⌥⌘T. They
  are also VO-⌘-L and VO-⌘-T (next link, next table). Record which one wins.
- [x] Review of 2026-09-23, fixed the same day. The shortcut recorder had
  leaked its key monitor across rows; `HotKeyCenter` now owns the only one.
  Recording now needs two of ⌘⌃⌥, since a ⌘V shortcut would have broken
  paste Mac-wide. A clipboard switch turned back on starts from the
  pasteboard as it is now. A wake retry keeps the fallback until the helper
  speaks. File names and paths stay private in the log, and displays are
  reported by kind. release.sh compares BUILD against every tag. Tests no
  longer send real Apple Events (`PlayerBridge.isRunningTests`). The
  "taken by another app" wording became "macOS would not register", because
  non-exclusive Carbon registrations cannot see another app's claim.
- [x] The island shows the charger going in and headphones connecting
  (`AmbientWatch`), each with a switch. Shelf cards offer Quick Look and
  AirDrop.
- [ ] **Physical check owed:** plug in a charger, connect AirPods, and use
  Quick Look and AirDrop from a Shelf card. The moments are rendered
  offscreen in tests (`SHOT_OUT`); the two system panels have not been
  opened from the app yet.
- [x] Review of the features, fixed the same day. Quick Look and AirDrop gave
  the keyboard back to the app that had it. Quick Look got a real controller
  (`AppDelegate`). The AirDrop row is checked on the click, not on every
  card redraw. A lid closed mid-moment no longer wakes to it. Headphones are
  tracked by UID, stay quiet for 30 s and survive a failed read, and lose the
  owner's name. A holding battery shows the plug, not the bolt. The moment
  is refused where the grown pill would land under a still cursor. Show
  Charging appears only on Macs with a battery. Every refusal has a test
  (`NotchController.ambientAllowed`).
