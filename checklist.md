# Dynamic Island parity checklist

This is the live completion view for the approved
[Cyclop 0.6.5 parity design](docs/plans/2026-08-18-dynamic-island-parity-design.md).
Do not mark a manual gate complete without recording evidence in
[the release checklist](docs/release-checklist.md).

## Automated gates

- [x] Swift unit and service tests pass.
- [x] Pinned-source provenance and MIT attribution pass.
- [x] Dynamic Island branding and path audits pass.
- [x] English and Russian localization tables validate with matching keys.
- [x] Release bundle builds with executable, helper, icon, localizations,
  licenses, and a valid signature.
- [x] The live media helper returns NDJSON and exits after its input closes.
- [x] Versioned `DynamicIsland-0.6.5.dmg` builds from the verified package.
- [x] Lifecycle test leaves no Dynamic Island media helper after quit.

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

- **Lyrics** (Settings, default off) fetches words from `lrclib.net`,
  `raw.githubusercontent.com` and `lyrics.kugou.com`, sending the current
  track's metadata.
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

The status-item menu, and then the whole status item, were removed on
2026-08-25 by owner decision. A window was built first and withdrawn the
same day: the panel's own Settings tab already carried Open Panel, About
and Quit, so both a menu and a window were second front doors to what
the island already does. The app now shows no Dock icon, no menu-bar
item and no window at any time, and its activation policy is
`.accessory` with nothing able to change it. ⌥⌘I is the only route in
that needs no pointer. This is narrower than the parity design's shape,
which assumes a menu-bar item, so it is recorded here.

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
dev.dynamicisland.app drawnGlass -bool true` forces the drawn recipe
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
