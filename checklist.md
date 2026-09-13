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
- [x] Versioned `Isla-0.6.5.dmg` builds from the verified package.
- [x] Lifecycle test leaves no Isla media helper after quit.

## Scope divergence from Cyclop 0.6.5

Snippets and Calendar were removed from the product on 2026-08-20 by
owner decision. They are not deferred and not hidden — the tabs, stores,
panes, privacy sections, and tests are gone, and the calendar entitlement
went with them. The app now claims exactly one entitlement,
`com.apple.security.automation.apple-events`, which the hardened runtime
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

- **Lyrics** (Settings, default off) resolves once per Now Playing session
  through the Isla broker before any lyric surface opens. It sends only player
  class, title, artist, album, duration, optional Spotify or recording ID,
  locale, and an anonymous installation token. It never sends audio, playback
  position, library data, Spotify credentials, or a user identifier. Results
  use a v5 cache only when licensed cache rights remain valid; local LRC
  overrides take precedence and never leave the installation. QQ, Kugou, AMLL,
  and LRCLIB are not invoked by the shipping lyric path. A licensed provider
  agreement and Cloudflare broker release remain required before a provider
  adapter can be enabled.
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
  settling, resolving, ready, unavailable, offline, rate-limited, and service
  failure states, including retry and local-LRC removal.
- [ ] Validate physical-notch, lock-card, slow-network, denied-territory,
  VoiceOver, Reduce Motion, English, Russian, and local-LRC workflows.
- [ ] Measure Spotify and Apple Music word timing at or below 150 ms p95; keep
  every unmeasured publisher line-level.
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
