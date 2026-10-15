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
  2026-10-11 (LY-09): a hit cached before lines carried their ends is shown
  at once and asked about **once more** in the background on its next play —
  one extra request per previously cached song, inside this same switch and
  with the same four fields. Only a found answer replaces it; a miss leaves
  the old words up and settles it. A timed answer the parser cannot read is
  remembered as a miss tied to the parser revision, and asked again only once
  a newer parser ships. Answers stamped past the track's end lose the lines
  that can never show, and a search row that fits the track outranks one that
  does not (`OnlineLyricsTests`, `OnlineLyricsSearchTests`).
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
  keychain. Since 2026-10-11 the heart asks `GET /me/library/contains` and
  saves with `PUT`/`DELETE /me/library`, naming the track as
  `spotify:track:<id>`: Spotify retired the old saved-tracks endpoints for
  Development Mode apps on 2026-03-09. The scopes are unchanged
  (`user-library-read user-library-modify`); whether the new endpoints need
  more for a track is owed to the live run (script S10, step 7), and adding
  a scope would make every connected user consent again, so it is the
  owner's call. A refusal is asked about again after ten minutes, and a
  disconnect or a new grant clears it (`SpotifyAccountTests`).
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
  Since 2026-10-11 (G-023, K-008) it also reads the output's mute and
  **unmutes** it when the bar is raised above zero, as the volume keys do —
  the same system-wide setting, recorded on the same terms. Writes go
  through the virtual main volume first, so a balance set off centre is
  kept; the bar shows only when some volume control is settable, and a drag
  writes only to the device it began on.
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
  explain it, and that installed build keeps the grant (see the amendment of
  2026-10-11 below); denied means the shelf shows what it holds. Nothing
  watches in the background.
  *Amended 2026-10-11 (sp/SH-05, owner decision 17, reversible):* dragging
  out copies by default; ⌘ moves, and a moved file keeps its card. The drag
  still carries the original as its source; only the default operation
  changed, so a same-disk drop into Finder now duplicates the file.
  *Amended 2026-10-11 (ms/MS-20, J-002):* "once" means once per installed
  version, not once ever. While Isla is ad-hoc signed (`Scripts/bundle.sh`
  signs with `-` unless a Developer ID is given), every update is a new
  binary to macOS: TCC keys an ad-hoc grant to the binary's cdhash, which
  every build changes, so each permission — Desktop, Documents and Downloads
  for this scan, Automation for Music and Spotify — is asked once per
  installed version, after an update and after every reinstall alike.
  Developer ID signing would make grants survive updates, because its
  designated requirement names the team rather than the hash; that is an
  owner decision, tracked under the Developer ID gate below. MS-02 already
  brings the re-asked Automation prompt in context, on the first panel open.
  Live check: session S2 (`codesign -d -r-` on two builds shows two cdhash
  requirements, and a reinstall brings the prompt back).
- **Spotify covers** (no setting, recorded 2026-10-11, sp/PV-03, G-030) are
  fetched from Spotify's image server when Spotify is playing and Now
  Playing cannot describe it — the scripting fallback and a held cover —
  because Spotify's scripting dictionary names its artwork only by address.
  The request carries the cover's https address and nothing about the
  listener beyond the IP any request carries. It predates every switch above
  and was never listed: a code comment called it "the one thing the app ever
  fetches" and the README said nothing left the Mac unless turned on. Both
  are corrected and the README's privacy table lists it. Gating it behind a
  switch is left to the owner. Like every request Isla makes, it goes through
  `PrivateNetwork.session`, which keeps no cache, cookies or credentials.
- **Volume and Output in the player** (Settings › Music, **default on**,
  added 2026-10-15, redesign R1) puts the existing output-volume slider and
  sound-output menu from the lock card into the Music player. Both change
  system-wide settings, so by the rule above they would default to off; the
  owner waived the rule for this one feature on 2026-10-15 (redesign decision
  8), because the controls only read until the person moves the slider or
  picks a device — nothing is written on its own. Recorded here as the one
  deliberate exception. Held by the redesign's `PlayerVolumeTests`.
- **Volume and brightness pop-up** (Settings › General, default off, redesign
  R5) replaces the Mac's own pop-up in the island: volume, mute, display and
  keyboard brightness. It needs Accessibility, asked for only when the switch
  is turned on, and consumes the keys through a session event tap only while
  the permission is granted. It sets system volume and brightness — the
  latter through private DisplayServices and CoreBrightness entry points
  resolved with `dlsym`, which degrade to the system's own handling when
  absent. No entitlement is added. The battle plan's "no full HUD
  replacement" line carries the dated reversal.
- **Keep Pinned Items** (Settings › Privacy, default off, redesign R3) writes
  pinned clipboard text and file entries — never images — to one file in
  `~/Library/Application Support/Isla/`, mode 0600, so pins survive a quit.
  Turning it off deletes the file. Nothing leaves the Mac; recorded because
  the clipboard was otherwise memory-only.

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
Amended 2026-10-11 (F-012): the lock card no longer depends on the hatch. It
always draws the recipe, in code, so `drawnGlass` now matters to the panel only.

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

Amended 2026-10-11 (F-008, H-004, J-001): "hidden from screen capture"
promises more than the mechanism is known to deliver. Hide from Screen
Recording sets `sharingType = .none` on the panel and does nothing else,
and whether ScreenCaptureKit capture and sharing apps on macOS 26 and 27
honour it is unproven until live session S7
(`docs/audits/2026-10-11-live-validation-script.md` §7). The switch stays
on by default, because it does hold for the capture paths that respect it,
but Settings now says only that it *asks* macOS, that some sharing apps
may still show Isla, and to cover Clipboard and Translate before sharing.
The covers are titled by what they do (Cover Clipboard Rows, Cover
Translate Text) with a note on how covered text looks, and the Clipboard
History off-note no longer claims copies are not read while Save Clipboard
Screenshots keeps the poll alive. S7 decides whether the capture note
becomes a stronger warning or, if every path honours `.none`, a firmer
sentence.

Amended 2026-10-11 (G-005, J-003, K-014, K-016; ms/MS-02): the Automation
note above promised that nothing is requested at launch, and three paths
broke it. The Spotify track-id lookup ran on every track with the panel
closed, the scripting fallback read every running player the moment it took
over, and the search for a song under a film asked the players whenever a
film appeared. Isla now sends no background Apple Event to a player unless
macOS already allows it (`AutomationAccess`, checked read-only with
`AEDeterminePermissionToAutomateTarget` at launch and on every panel open,
and corrected by every script's outcome). The prompt appears the first time
the panel opens on Music or Spotify, never at launch and never over the lock
screen, where the card asks a player only what is already allowed. A tap on
play, pause or skip is the user's own action and is not gated. Once access is
refused (-1743), the background stops asking, which ends the once-a-second
position poll that logged an error for every refusal. With no Spotify account
connected, no track-id lookup is made at all, since the lock-card heart is the
id's only reader. The id usually comes from Spotify's own playback
announcement, which needs no permission, and a scripted id is accepted only
when its name and artist match the song on screen. No per-track catalogue
request (`GET /v1/tracks/{id}`) is made any more: its ISRC and exact duration
had no reader. Accepted cost: right after a fresh grant, the heart can be
missing on the lock card until Spotify's first play, pause or skip. Live
check: session S2 (`docs/audits/2026-10-11-live-validation-script.md`).

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
  Awake-idle budget, 2026-10-11 (ms/MS-25, F-054): measured with
  `bash Scripts/measure-idle.sh <scenario> [samples]`, which samples the
  running Isla with `top` every 5 s, holds the display awake for the run,
  and takes rates from counter deltas rather than the lifetime total. The
  figure it replaces, about 0.3 idle wake-ups a second, is a lifetime
  average: the installed 0.2.0 (2) build showed 66,360 idle wake-ups over
  59.7 h of uptime, 0.31/s, display sleep included. Owner decision 19 is
  kept: the 8 Hz pointer sampler and the 2 s geometry watchdog stay, and a
  change to either goes back to the owner with these numbers. Budget for the
  panel closed and idle: CPU at or below 0.1 %, RSS at or below 88 MB, and
  the awake idle wake-up and context-switch rates as S17 measures them.
  Before numbers, on a build of the tree before MS-12, MS-13, MS-15 and
  MS-16 land (live session S17; samples default to 60 = 5 min, 12 = 1 min):
  - [ ] Panel closed, idle, 5 min (`closed-idle`): _
  - [ ] Panel closed, music playing, 5 min (`closed-playing`): _
  - [ ] Music tab open, playing, 1 min (`tab-music 12`): _
  - [ ] Settings tab open, playing, 1 min (`tab-settings 12`): _
  - [ ] Shelf tab open, playing, 1 min (`tab-shelf 12`): _
  - [ ] Clipboard tab open, playing, 1 min (`tab-clipboard 12`): _
  - [ ] After MS-12 and MS-13: the four tab rows again, and `closed-idle`
    still inside the budget.
- [ ] Developer ID signing, notarization, stapling, and Gatekeeper validation pass.
  Also what lets a privacy grant survive an update: until this lands, every
  ad-hoc release asks again for Desktop, Documents, Downloads and Automation
  (J-002, ms/MS-20, 2026-10-11), and its release notes say so.

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
  **Amended 2026-10-11 (H-020):** the pane is two columns. One line sits
  level with each rail icon and says what that tab is, with the live lyrics
  and translate shortcuts in their lines. Beside them: Isla is running, no Dock
  or menu-bar icon, click the notch or press the open shortcut to come back,
  nothing leaves your Mac unless you turn it on, Get Started. No rail tab is
  lit or selected while it shows. Measured at the 480 pt minimum against the
  154 pt body: en 150, ru 151 (`FirstRunTests`). The render is owed to the
  owner's eye, and the first-run pass owes a look on hardware that each legend
  sits level with its icon.
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
  **Half closed, 2026-10-11 (F-012):** there is no real glass on the card any
  more. The card and its output popover always draw the recipe
  (`LockScreenCard.glassRouting`, `preferDrawn: true`), as the Lock-screen card
  entry above has always recorded, so the scrim now sits on recipe over recipe.
  That also keeps the card's content one view across a cover appearing or going
  (K-017). The literals remain open. Owed one look on a locked macOS 26 Mac
  with a coverless song; if the system material read better there, amend this
  record, not the code (`GlassRoutingTests`).
- [x] `SettingsPane.choiceRow` is a hand-rolled segmented control; a native
  `Picker(.segmented)` would restore arrow keys and radio-group VoiceOver but
  look like AppKit on a dark pane.
  **Closed 2026-10-11 (ax/SET-02, owner decision 4)** — see the dated section
  "Settings reads cleanly to VoiceOver".
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
- [x] Escape does not disarm a two-press confirmation; it closes the panel.
  **Closed 2026-10-11 (ax/AN-02, owner decision 3)** — see the dated section
  "Two-press confirmations speak, wait and cancel".
- [ ] `Toggle("", isOn:)` with a detached label: clicking the label text does
  not flip the switch, which a native labelled `Toggle` gives for free.
- [x] `TranslatePane`'s font ladder `[27, 20, 15, 11]` shares only its last
  rung with the six type roles. **Closed 2026-10-15 (R4)** — the ladder went
  with the re-lay; card text is 15, and 13.5 on the tall body (spec §11).
- [ ] `NotchMetrics.collapseRectShrinkDelay` (0.45) is tied to the open
  spring's settle by comment only.
- [ ] `Translator.swift:173` uses the deprecated
  `GenerationOptions(sampling:)`; the replacement (`samplingMode:`) exists
  only in the macOS 27 SDK, so switching would break a macOS 26 Xcode build.
- [ ] `scripts/check` is tracked in lowercase while every other script is
  under `Scripts/`; one directory on this Mac's case-insensitive disk, two on
  a case-sensitive one.
- [x] **The detached-label toggle above is closed, 2026-10-11 (SET-01, H-002,
  owner decision 2).** Every Settings switch is one `Toggle` whose label is
  the row's icon and title, drawn by `PanelSwitchStyle` (`Theme.swift`): the
  whole 26 pt row is the target, so a click on the words flips it, and the
  style draws its own on-state — the person's `controlAccentColor` on, a well
  shaded into the card off, a 1 pt white-0.7 outline under Increase Contrast —
  because AppKit's switch only shows one in a key window and this panel is not
  key outside Translate. VoiceOver still finds one AXCheckBox per row, named
  by its title, valued 0 or 1 (`SettingsPaneTests`); on vs off clears 3:1 for
  all eight accents over the card (`ContrastRampTests`). Reversible. Owed on
  the Mac: a click on "Launch at Login" text flips it; VoiceOver's reading of
  the row ("switch" or "toggle button", on or off); Graphite and Yellow
  accents by eye; the visual lab's panel-settings renders reviewed.

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

### Lyric Delay runs the way its label says — 2026-10-11 (ly/LY-01)

- [x] **A positive delay shows lyrics later.** `LyricSweep.lead` added the
  listener's corrections, so Lyric Delay, the Set Lyric Delay action and the
  stage's Lyrics Earlier/Later nudges all ran backwards against their labels
  and the note under the slider — the AirPods listener the 2026-09-21 delay
  was added for followed the note and doubled the error. The lead now
  subtracts them. Every stored correction (defaults, `offsets.json`,
  `unassigned-offsets.json`) is negated once on first launch, so no listener's
  timing moves: the owner's −0.247 s reads +0.247 s at the same effective
  lead, −0.047 s (lab L7 and L8 rerun on the 540-track corpus, unchanged).
  A build from before this change, run after it, reads every correction
  inverted. Design amendment: `docs/superpowers/specs/2026-09-14-line-synced-lyrics-design.md`.
- [ ] **Physical check owed:** on the installed build, Settings → Music shows
  Lyric Delay +0.25 s where it showed −0.25 s, lyrics (and any per-track
  nudge on the lyrics page) sit exactly where they sat before the upgrade,
  and dragging the slider right moves lines later.

### The lock card reads over a pale cover — 2026-10-11 (vt/LC-01)

- [x] **White type holds AA over the palest cover.** The cover that lights
  the Tinted card sat under a fixed 0.34 black wash, which over a near-white
  cover left a 0.66 grey: the artist line measured 1.76:1 and the elapsed
  time and lyric status 1.59:1 (F-003). The wash is now solved per cover by
  `LockCardLegibility`: the 90th-percentile brightness of the part of the
  artwork the card shows (zoomed 1.5× and cropped to the card), drawn at
  8×8, cached once per image, and the least black at or above the old
  value (0.34, Transparent 0.2, Increase Contrast 0.56) at which
  `cardTertiary` clears 4.5:1. A cover whose bright end is at or under 0.3
  keeps exactly the light it had; a white one is washed to about 0.70. The
  card tokens rose with it, rounded up as before: `cardSecondary`
  0.62 → 0.75, `cardTertiary` 0.50 → 0.62 (Increase Contrast unchanged at
  0.85 / 0.75). Over a white cover the artist line is now 5.7:1.
  `ContrastRampTests` holds AA at the brightest cover and at every brightness
  between; `LockCardCoverLightTests` holds the reading. In the visual lab's
  Tinted render (a mid cover with a pale disc) the dimmest label measures
  4.8:1 at the disc's brightest point, where it was 1.9:1. The cost: a cover
  with one pale feature dims the whole card, its dark parts included.
- **Divergence, deliberate:** Transparent guarantees 4.5:1 only over the
  cover's share of the card. The 38% of wallpaper that also shows through is
  behind the login shield, where no window is given a backdrop to measure,
  so it is not modelled. Tinted and Solid guarantee 4.5:1, and Increase
  Contrast already makes Transparent opaque.
- [ ] **Physical check owed:** lock the Mac with a white or pastel cover
  playing, in Tinted and in Transparent: the artist line, the times and the
  lyric status read; then a dark cover looks as it did before.

### Screenshots reach the Shelf on any system language — 2026-10-11 (sp/SH-03)

Amends the **Screen-capture pickup** scope record above.

- [x] **A still counts when the system marked it a capture, or by its
  name.** The localized prefix was asked of ScreenCaptureKit's table, which
  has no such key, so a Russian, German or Ukrainian Mac never sent one
  still to the Shelf (G-001). A still now counts when it carries
  `com.apple.metadata:kMDItemIsScreenCapture` (`CaptureMetadata`) or starts
  with a capture word, and the words are every language's "Screenshot" and
  "Screen Recording" from screencaptureui's own table, read once per launch,
  with the English words, `LWScreenShot` and the custom name kept. A movie
  still counts on its type alone (decision 13, unchanged).
- [x] **The Desktop is scanned only when captures go there.** It is no
  longer appended to every folder list; it arrives only as the default when
  no location is configured. A remembered folder the disk reports as not
  there (not one it refused) leaves the list after the scan, except the
  current one and anything under /Volumes, which is an unplugged disk (J-021).
- [x] **The capture memory holds only what was offered.** A file from before
  the first run is settled by its date and no longer takes one of the 1,000
  remembered names; past the cap the oldest files go first, by date, not by
  `Set` order (K-012).
- [x] **Permission prompts name every reason.** Desktop, Documents and
  Downloads also name lyrics folders, and external-disk and network-volume
  prompts are declared for the first time.
- Tests: `RecordingPickupTests` (testARussianScreenshotIsACapture,
  testTheCaptureAttributeAloneMakesACapture, testPrefixesComeFromTheSystemTable,
  testDesktopIsNotAddedWhenALocationIsConfigured,
  testAFolderThatNoLongerExistsIsForgotten,
  testOldRecordingIsNeverOfferedAndNeverRemembered,
  testTheMemoryForgetsTheOldestCapturesFirst),
  `AppSurfaceContractTests.testInfoPlistDeclaresVolumeUsageStrings`.
- [ ] **Physical check owed (S9):** on a Mac set to Russian, ⇧⌘3 to a file;
  the still arrives on the Shelf the next time it opens.
- [ ] **Physical check owed (S2):** after `tccutil reset`, with captures set
  to ~/Pictures, opening the Shelf raises no Desktop prompt, and each prompt
  that does appear names what triggered it.

### Escape and ⌘-Tab end a panel the keyboard opened — 2026-10-11 (ax/KB-01)

- [x] **Escape folds a pinned panel from any tab.** After ⌃⌥⌘I, Escape went
  to the app underneath, because the panel is key only while Translate asks
  for the keyboard and Escape is read only in `NotchPanel.sendEvent` (F-004).
  While a pin stands and the panel is not key, `NotchController` now holds
  plain Escape through a transient `GlobalHotKey` (Carbon, no permission),
  driven by `isPinnedOpen`, so every way a pin ends gives it back. The press
  runs the panel's own two steps: `consumeEscape()`, then the fold. Not held
  while the panel is key, while Isla is active (Quick Look, AirDrop), or
  locked (`NotchViewModel.claimsEscape`).
- [x] **⌘-Tab ends a pin** like a click in another app:
  `NSWorkspace.didActivateApplicationNotification` for any other pid clears
  the pin and folds the panel (`NotchViewModel.appActivated`).
- **Divergence from the plan, deliberate:** KB-01 as planned made
  keyboard-opened panels key. That would change the Shell invariant in
  `CLAUDE.md` and settle owner decision 1, so key status is unchanged here;
  the plan's key-status tests were dropped. The one Escape pressed while a
  pin stands goes to Isla, not to the frontmost app (a vim user reading
  lyrics loses that keystroke), and closing a Quick Look or AirDrop window
  opened from a pinned panel ends the pin.
- Tests: `PinnedKeyboardTests` (testOnlyAPinnedPanelWithoutTheKeyboardClaimsEscape,
  testThePointerArrivingGivesEscapeBack, testSwitchingToAnotherAppEndsAPin).
- [ ] **Physical check owed (S5):** ⌃⌥⌘I then Escape closes it; ⌃⌥⌘I then
  ⌘-Tab closes it; ⌃⌥⌘L then Escape closes it; with no pin up, Escape in
  TextEdit or Terminal still reaches them; in Translate with text, the first
  Escape clears the field and the second closes; a click-open never steals
  the caret; with Quick Look open from a pinned Shelf, Escape closes Quick
  Look and not the panel. Confirm macOS registers an unmodified
  Escape hot key (a refusal is logged: "macOS refused the transient Escape
  hot key").

### Two-press confirmations speak, wait and cancel — 2026-10-11 (ax/AN-02)

- [x] **Escape disarms an armed confirmation before it closes anything**
  (owner decision 3). `NotchViewModel.consumeEscape()` asks
  `ArmedConfirmations.shared` first: the first Escape turns "Clear
  Everything" back into "Clear", the second folds the panel. Escape reaches
  Isla only where it already did — a key panel, or a pin from ⌃⌥⌘I/⌃⌥⌘L
  through KB-01's transient hot key; a pointer-opened Shelf or Clipboard is
  not key, and Escape there still goes to the frontmost app.
- [x] **Arming is announced** — "Clear Everything. Press again to confirm."
  through `Announcer` — and lapses after 8 s instead of 3 s while VoiceOver
  is on (read at each arming). The lapse waits while the pointer rests on the
  armed word and restarts in full when it leaves.
- [x] **Caption confirmations have a 24x20 floor** (`Theme.minimumHitSize`,
  F-014): Clear measured 27x13 in the probe, now at least 27x20. Shelf's and
  Clipboard's footers are 7 pt taller, which comes out of the list viewport.
- [x] **Copy says Copied** (M-06): while the tick shows, the button's label
  and help are "Copied", and "Copied" is announced once. `CopyButton` takes a
  title for a pane that has to name what it copies.
- Decision 15 kept: the first Escape in Translate still clears the typed text
  (as a search field and Spotlight do); only `consumeEscape`'s comment, which
  called that reversible, was corrected.
- Tests: `ConfirmationTests` (testEscapeDisarmsBeforeItCloses,
  testAWithdrawnConfirmationClaimsNothing,
  testArmingIsAnnouncedAndLastsLongerUnderVoiceOver,
  testCaptionButtonsAreBigEnough, testCopyButtonSaysCopied,
  testCopyButtonTakesATitle).
- [ ] **Physical check owed:** with VoiceOver on, Clear on the Shelf is heard
  as "Clear Everything. Press again to confirm." and stays armed for 8 s;
  without it, a click arms Clear, the word stays red while the pointer rests
  on it and turns back 3 s after the pointer leaves; ⌃⌥⌘I, Shelf, arm Clear,
  Escape disarms and a second Escape closes; Copy in Translate is read as
  "Copied" after a press. Review the visual lab's clipboard and shelf footers.
### Pasteboard privacy: what Isla does under each answer — 2026-10-11 (sp/CB-02)

Records Isla's behaviour under Privacy & Security > Paste from Other Apps
(`NSPasteboard.accessBehavior`, macOS 15.4 and later), which before this was
recorded nowhere (J-001). `ClipboardStore` asks the system on start, on every
copy, and when a read comes back empty; nothing is read to find out.

- [x] **Allow, or `.default`** (Isla has never raised an alert, or a macOS
  before 15.4): the half-second poll runs, the type list decides what is read,
  and only what History or Save Clipboard Screenshots wants is read (sp/CB-01).
- [x] **Ask:** every content read may raise the system's alert, so each copy
  is read at most once per switch that wants it. The change count is spent
  only once a read has answered: if Allow is chosen while the read waits, it
  is read once more and recorded. A refused read is spent, and no alert is
  ever retried for the same copy; the picture wait does not poll under Ask.
- [x] **Don't Allow:** the poll stops itself (at start, or at the first copy
  after the switch) and stays stopped. Copies made while refused are skipped,
  not recorded later. The Clipboard tab says "macOS is not letting Isla read
  what you copy, so nothing new is kept." above the list, with an Open Privacy
  Settings button (`OfferButtonStyle`) that opens
  `x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard`
  and falls back to the Privacy & Security root. What was kept before the
  refusal stays in the list. Said only while History or Save Clipboard
  Screenshots is on: with both off nothing is lost to the refusal.
- [x] **Back to Allow:** opening the Clipboard tab asks the system again
  (`recheckAccess` on appear) and restarts the poll from the pasteboard as it
  is then, without a relaunch.
- [x] **One failure surface:** the tab's inline notice only. Settings carries
  no second banner for the same event.
- [x] **Copy Diagnostics** carries `Paste from Other Apps:` with `default`,
  `ask`, `allowed` or `denied`, read from the system when the report is made.
- Tests: `DiagnosticsTests.testPasteboardAccessIsReported`,
  `ClipboardAccessNoticeTests` (testADeniedPasteboardIsSaidWithAWayToFixIt,
  testAnEmptyDeniedHistoryStillSaysWhy, testAnAllowedPasteboardSaysNothing,
  testOpeningTheTabAfterAllowResumesHistory,
  testTheButtonAimsAtPasteFromOtherApps), `ClipboardStoreTests` (sp/CB-01),
  and the lab's `panel-clipboard/access-denied` renders
  (`VisualLabPanelTests.testClipboard`).
- [ ] **Physical check owed (S1 step 7):** under Don't Allow the Clipboard tab
  shows the sentence, and Open Privacy Settings lands on Paste from Other Apps
  (the `Privacy_Pasteboard` anchor is not documented; if it lands on the
  Privacy & Security root instead, record that here). Set Allow, reopen the
  tab, copy: the copy appears without a relaunch. Copy Diagnostics shows the
  state each time.

### The lyric lead is a sum of named terms — 2026-10-11 (ly/LY-08)

- [x] **The lead is the sum the lyric lab named, not one constant.**
  `LyricLeadModel` holds anchorLag 138 ms, timerWake 0.1 ms, half a frame and
  one compositor frame (120 Hz), the onset crossfade's rise 103.9 ms
  (`Theme.springRiseTime` on `lyricScroll`'s own constants, closing L-09
  without changing the motion), anticipation 40 ms, minus the route's output
  latency, minus `unmeasuredPlayerDelay` 67.2 ms — a named placeholder for
  the part of the shipped 0.20 s nobody has measured, chosen so the built-in
  route sums to 0.200 s. No stored correction moved and no migration ran.
- [x] **The route's output latency is read live and logged, not applied.**
  `OutputLatencyMonitor` re-reads CoreAudio's latency for the default output
  (device + safety offset + buffer + stream latency over the nominal rate)
  when the default output changes, and only while Show Lyrics is on. Reads
  only: nothing leaves the machine and no setting changes. With `DI_MEDIA=1`
  every reading writes the full term list to `/tmp/di-debug.log`.
  `LyricLeadModel.appliesOutputLatency` is `false` and the frame rate stays
  at 120 Hz, so on every route and display the lead is today's 0.20 s:
  applying either would silently move corrections tuned by ear on an
  unrecorded route (the owner's +0.247 s by about 173 ms between AirPods
  and built-in speakers), and a player whose position already includes its
  output latency would count it twice.
- [ ] **Owner session owed (S-LEAD in
  `docs/audits/2026-10-11-live-validation-script.md`):** per player and per
  route, CoreAudio's reported latency from the trail beside the by-ear
  correction. Applying the term (with any migration of stored corrections)
  and wiring the island screen's real refresh rate are a follow-up gated on
  those numbers. `Scripts/measure-sync.sh` is still owed a run to re-measure
  anchorLag after LY-06 and LY-07.
- Tests: `LyricSweepTests.testTheLeadIsTheSumOfItsNamedTerms`,
  `…testTheBuiltInRouteKeepsTheShippedLead`,
  `…testTheMeasuredOutputLatencyIsNotAppliedYet`,
  `…testTheOnsetRiseIsTheLyricSpringsHalfway`,
  `…testAnUnknownFrameRateCountsAsSixtyHertz`,
  `AudioOutputsTests.testOutputLatencyArithmetic`,
  `…testTheMonitorListensOnlyWhileStarted`,
  `…testARouteChangeIsReportedOnceWhenTheLatencyMoves`,
  `LyricsCoordinatorTests.testTheOutputLatencyWatchRunsOnlyWhileLyricsAreOn`,
  `…testAReportedOutputLatencyReachesTheModelButNotTheLead`; the lab's L7 now
  evaluates the production lead with each scenario's latency reported to the
  model (needs the corpus, `Scripts/lyric-lab.sh`).

### The pill folds no slower than it unfolds — 2026-10-11 (vt/MO-03)

Amends **Native motion — 2026-09-21** above, which records the fold at 0.5 s
and the content leaving at 0.22 s.

- [x] **Leaving takes no longer than arriving.** The fold (`Theme.pillFold`)
  settled in 529 ms against the unfold's 444 ms, and its content left on its
  own curve in 233 ms, so for about 296 ms an empty black wing hung past the
  notch (H-013). The fold is now 0.42 s, equal to the unfold and still above
  the 0.4 floor that keeps it from reading as the old 0.28 s snap; the content
  leaves on 0.20 s, the largest hundredth that keeps the cover under a tenth
  opaque when the faster edge reaches it (0.087, was 0.066). Lab re-sample:
  fold settles 444 ms, content-out 212 ms, bare wing about 232 ms. The audit's
  0.32 s / 0.16 s was rejected as within 0.04 s of the snap the owner turned
  down; it is the owner's to revisit after the live look. The peek's end and
  the ambient fold ride the same curve and got quicker by the same amount.
  `PillFoldTests.testLeavingIsNoSlowerThanArriving` and
  `…testTheEmptyWingIsShort` hold it, beside the existing floor and
  edge-versus-cover tests.
- [x] **Decision 18, comments only.** The hover nudge's comment cited
  `MotionValuesTests`; its assertion lives in
  `RestingNotchTests.testTheHoverNudgeIsOneBumpNotAWobble`. The lyric scroll's
  comment called its overshoot enough to read as carried; it is 0.24 pt over
  a 48 pt step, and the hover nudge's is 0.58 pt over 15 pt. Both damping
  values are unchanged until the owner compares them live.
- [ ] **Physical check owed:** pause a song, unlocked and over the lock
  screen, and watch the fold: no bare black wing lingering after the cover
  has gone, and no snap. Then hover the resting island and step a lyric line
  with both bumps in mind for decision 18.

### Settings reads cleanly to VoiceOver — 2026-10-11 (ax/SET-02)

Closes H-009 (row glyphs read by their system names) and H-024 (slider
values without units, section titles that were not headings) in Settings,
and owner decision 4. H-004, the cover switches' titles, belongs to sp/PV-02.

- [x] **No row speaks its glyph.** Every row draws its symbol through
  `RowIcon`, which is hidden from VoiceOver; `ConfirmRow` hides its own, and
  a shortcut row hides its drawn title, which the well already carries. The
  pane's first 1400 pt had five symbol stops ("Rectangle With A Filled
  Top-Third Inset", "Skip Slide", …) and now has none.
- [x] **Nine headings.** Each section title is a heading named in title case
  ("General", not the drawn "GENERAL"), so the rotor can jump between them.
- [x] **Sliders say their unit.** Panel Width speaks "560 points", Hover Delay
  "0.25 seconds", Lyric Delay "+0.00 seconds" (ru "560 пт", "0.25 секунды"),
  as the slider's value description, which is what VoiceOver reads; the
  drawn title and short figure are no longer stops of their own. The three
  rows are one `SettingsSliderRow`.
- [x] **Glass and Card Size are radio groups.** The capsules stay drawn;
  `SettingsChoiceRow` stands a `.radioGroup` picker in for them, so an
  assistive client finds one group named by the row, one radio button per
  option and the selected one on. `.segmented` was tried first and vends a tab
  group of tab buttons with a detached label. The "Glass title equals its
  first option" half of decision 4 was already stale (Transparent, Tinted,
  Solid).
- [x] **A VoiceOver step commits.** The plan expected an increment to skip
  the commit, which lives in `onEditingChanged(false)`. On macOS 27 SwiftUI
  brackets each accessibility increment as editing began, one write, editing
  ended, so a step already commits once, at once; no debounce was added.
  `SettingsAccessibilityTests` (`testNoRowSpeaksASymbolName`,
  `testSectionTitlesAreHeadings`, `testSlidersCarryUnits`,
  `testTheHoverDelaySaysSeconds`, `testCardStyleIsARadioGroup`,
  `testAVoiceOverStepCommitsTheWidth`) hold all five.
- [ ] **Physical check owed (VoiceOver on):** VO-Up on Panel Width resizes the
  panel at once; the rotor's Headings list shows nine; Glass reads as a radio
  group, "1 of 3"; Russian VoiceOver reads "560 пт" as points, not a weekday.

### Lyric context lines clear 3:1 — 2026-10-11 (vt/CT-02)

Closes F-051 and owner decision 9 (lyric context-line contrast), which the
plan had split with ly/LY-20; LY-20 was dropped in review and its record is
this one. Supersedes the "Lyric neighbour 0.34/0.44, floor 0.28/0.38" line
of the v0.3 Increase Contrast entry above.

- [x] **Accessibility over the depth preference.** The context floor was
  white 0.28 (2.27:1 over black) and the neighbour 0.34 (2.89:1), under 3:1
  by a recorded choice of depth over contrast. `LyricRow.Ramp.panel` is now
  floor 0.36 (3.13:1), neighbour 0.42 (3.95:1), unswept 0.50, reading 0.46;
  under Increase Contrast 0.42 (3.95:1), 0.46 (4.58:1), 0.50, 0.48. Depth
  still reads as four steps, 0.36 → 0.42 → 0.50 → full white, and stays
  opacity-only: blurring the far lines was weighed and rejected again.
- [x] **The lock card has its own ramp.** It drew the panel's greys over a
  cover-lit backdrop, where the floor measured 2.1:1 and the neighbour 2.5:1
  over a white cover. `LyricRow.Ramp.card`: floor 0.50, neighbour
  `cardTertiary` (0.62), unswept `cardSecondary` (0.75); under Increase
  Contrast 0.62, 0.75, 0.85. Over the backdrop `LockCardLegibility` solves
  for a white cover the floor is 3.5:1 (3.6:1 under Increase Contrast) and
  the neighbour 4.5:1, in Tinted and Transparent. The interlude marker takes
  the same surface, so a marker and a line at one depth are one grey.
- [x] **Credits are never bold** (F-051). The credit branch passed the
  caller's `.bold` through under a comment saying it never would; it draws
  at `.medium` now. Its dim state follows the ramp's floor instead of a
  fixed 0.34 that Increase Contrast never moved.
- `ContrastRampTests` (`testLyricContextClearsThreeToOne`,
  `testCardLyricsHoldOverTheBrightestCover`, `testCreditsAreNeverBold`) hold
  all three. Visual lab renders `lock-card/clear-standard-lyrics__light-ir`
  and `glass-standard-lyrics__dark-ir` were re-read: every context line reads,
  and the floor still sits visibly under the neighbour.
- [ ] **Look owed on the Mac:** the lyrics page in a dark room, and the lock
  card over a pale cover, to confirm the narrower floor-to-neighbour step
  (0.06 on the panel) still reads as depth.
### A card dragged out copies, and follows a file it moved — 2026-10-11 (sp/SH-05)

Closes F-020 (Move offered by default; a moved file left a dead card) and
F-038 (generic 48 pt drag image at the card's corner, no press feedback).
The M-21 count badge for a group drag was not built: the fan already reads as
a stack, and nothing showed it was needed.

- [x] **Copy unless ⌘.** Outside the app a drag offers Copy and Link; ⌘ adds
  Move, Generic (what AppKit narrows a ⌘-drag to, and what Finder performs as
  a move) and Delete (the Trash). Nothing is offered inside the app.
  `ShelfDropTests.testDragOutCopiesUnlessCommandIsHeld`.
- [x] **A moved card follows its file.** A drag that ends in Move, Generic or
  Delete re-resolves each card's bookmark: a new place updates the card in
  place (same id, still selected) and is saved; the Trash or a file no
  bookmark can find (a move to another disk) removes the card. A file still
  where it was is asked again at 0.3 s and 2 s, because Finder runs the move
  after it accepts the drop. `ShelfStoreTests.testAMovedFileKeepsItsCard`,
  `testAFileDraggedToTheTrashLeavesTheShelf`,
  `testAFileThatCannotBeFollowedLeavesTheShelf`,
  `testAMoveThatLandsAfterTheDragEndsIsStillFollowed`,
  `ShelfDropTests.testOnlyADropThatMayHaveMovedTheFileIsFollowed`.
- [x] **The drag lifts the thumbnail from where it was grabbed.** The image is
  the card's cached preview, never a new QuickLook request, fitted into the
  measured thumbnail box; the session starts from the mouse-down so the
  pointer keeps its point on the picture; a group puts the grabbed card first
  and fans the rest 9 pt behind it. `testDragFrameSitsOverTheThumbnail`,
  `ShelfStoreTests.testAGroupDragLiftsTheGrabbedCardFirst`.
- [x] **The press answers on the way down.** The card settles to
  `Theme.pressScale` (0.97) on mouse-down and back on mouse-up or when the
  drag ends; under Reduce Motion it dims to `Theme.pressDimOpacity` (0.85).
- [ ] **Physical check owed (script S13 step 2):** a Desktop card dragged into
  a Finder folder copies it (the original stays, the "+" badge shows); a
  ⌘-drag moves it and the card's double-click opens the moved file; ⌘-dragging
  onto the Trash removes the card; pressing ⌘ mid-drag turns the copy into a
  move. Film one drag: the thumbnail stays under the pointer where it was
  grabbed.
### Third-party requests keep nothing on disk — 2026-10-11 (sp/PV-03)

Closes G-016 (every request went through `URLSession.shared`, whose disk cache
could keep a Translate Online text, sent in a GET's `q=`, and its answer in
`~/Library/Caches/com.ctimothe.isla/Cache.db`) and G-030 (the Spotify cover
fetch was unlisted and a comment called it the only request).

- [x] **One session that keeps nothing.** `PrivateNetwork.session` is
  ephemeral with no URL cache, no cookie jar, no credential store and
  `.reloadIgnoringLocalCacheData`. LRCLIB, MyMemory, the Spotify Web API and
  token exchange, the cover fetch and the update check all default to it.
  `PrivateNetworkTests.testPrivateSessionKeepsNothing`,
  `testNoSourceUsesTheSharedSession` (no source names `URLSession.shared` or
  builds a session of its own; five uses before).
- [x] **The old cache is emptied once.** The first launch of this build
  removes every response in the shared URL cache and every cookie in the
  shared jar, then sets `network.cachePurged.1` so it never runs again.
  `PrivateNetworkTests.testTheOldCacheIsPurgedExactlyOnce`.
- [x] **The cover fetch is named.** README's privacy table lists Spotify
  covers with no setting; the capability list above records it.
- [ ] **Live check owed:** with Translate Online on, translate one Uzbek
  sentence, quit Isla, then
  `sqlite3 ~/Library/Caches/com.ctimothe.isla/Cache.db "select count(*) from cfurl_cache_response where request_key like '%mymemory%'"`
  answers 0 (or the file is absent). Also confirm the Spotify account still
  connects, refreshes and hearts a track, and an update check still answers.
### Show opens, reopening opens, a second copy hands over — 2026-10-11 (ax/KB-04)

Closes F-024 (the Show Isla and Show Lyrics intents called the hot keys'
toggles, so a Shortcut run on an open panel closed it, and Show Lyrics folded
the words back to the player) and F-023 (no reopen handler and no
single-instance guard: Spotlight → Isla did nothing visible while Isla ran,
and a second copy drew a second island, spawned a second helper and fought the
first for the hot keys and the Spotify callback).

- [x] **Show never closes.** `NotchController.show()` and `showLyrics()` run
  the lock refusal, then open only when `NotchViewModel.showVerdict` /
  `showLyricsVerdict` say `.open`; an open panel keeps its tab and its pin.
  The intents call these; ⌃⌥⌘I and ⌃⌥⌘L keep their toggles.
  `ShowRouteTests`.
- [x] **Reopening opens the panel.** `applicationShouldHandleReopen` calls
  `show()` and returns false.
- [x] **One Isla.** At launch, before the panel, the helper or the hot keys
  exist, `LaunchGuard.olderCopy()` looks for another running process with the
  bundle id. The newer copy (later launch date; equal or missing dates fall to
  the lower pid) hands activation to the older one, posts the distributed
  notification `com.ctimothe.isla.show` and quits; the older one answers with
  `show()`. `ISLA_ALLOW_SECOND_INSTANCE=1` turns the guard off, and
  `Scripts/test-lifecycle.sh` and `Scripts/measure-performance.sh` set it,
  because they launch the build while the installed copy runs.
  `LaunchGuardTests`.
- **New inbound surface, recorded:** any local process can post
  `com.ctimothe.isla.show`. It only opens the panel, through the same lock
  refusal and shake as ⌃⌥⌘I, so it grants nothing a person at the keyboard
  does not already have. It carries no payload and nothing is read from it.
- [ ] **Physical check owed:** with the panel open, run the Show Isla
  Shortcut — the panel stays open (it closed before); with the lyrics page
  up, Show Lyrics leaves it up. Spotlight → Isla while it runs opens the
  panel. With `/Applications/Isla` running, launch the build copy from
  Finder: the build exits within a second, the installed panel opens and
  stays open (the activation hand-over is what keeps the build's exit from
  reading as ⌘-Tab), and `pgrep -x Isla` lists one process. Over the lock
  screen, all three shake the pill and open nothing.
  `./scripts/check lifecycle` stays green with the installed copy running.

### Scope divergence: fixed type sizes (2026-10-11, provisional)

Provisional, pending owner decision 10. The panel and the lock card draw
their type at fixed roles (caption 10 pt, body 11 pt) and do not follow
Dynamic Type or a larger-text setting: the windows are fixed-size and
non-resizing, and a text size that grew would clip rows and the lock card.
This is recorded as a divergence from the platform, not as a settled
decision. The two options the accessibility plan lists are open: keep fixed
sizes and say so in the product notes, or add a larger-text step to Settings
that rescales the type roles and the row heights together. Contrast on the
small labels is held in the meantime by `ContrastRampTests`
(`testLabelsClearAAOnTheFillsTheySitOn`): `tertiaryOpacity` is 0.50, and
labels on a brighter fill are raised per fill with `Theme.tertiary(over:)`.
### Spotify sign-in survives edge cases — 2026-10-11 (kx/KX-02, closes K-015)

- Connect pressed twice keeps one verifier and state for ten minutes
  (`SpotifyAccount.pendingSignInLifetime`); the first approval consumes them
  and the other tab's callback is dropped. The consent URL now always carries
  `show_dialog=true` (documented in Spotify's authorization-code guide), so a
  reconnect after Disconnect offers a way to switch account. Nothing new
  leaves the machine; the authorize URL was already opened in the browser.
- `signInProblem` says when the browser did not open, when the keychain import
  moved no refresh token (the Import row stays), and when Spotify signed in
  but no token could be written anywhere (the account is not claimed as
  connected). One inline note in Settings › Spotify, no toast.
  `SpotifyAccountTests`.
- [ ] **Physical check owed:** press Connect twice, approve the first tab: the
  account connects. Disconnect, then Connect: Spotify's consent page appears
  with its "Not you?" switch.

### Settings › Spotify says what happened, and disconnect asks — 2026-10-11 (ms/MS-09, closes M-32)

- The section is a pure row model (`SettingsPane.spotifyRows`): a revoked
  grant offers "Connect again", a cancelled or unfinished sign-in says so, a
  local failure (`signInProblem`) leads, and one event gets one note. Disconnect
  is a two-press `confirmRow` and says what stays: Isla forgets the account on
  this Mac, the Spotify library is untouched. `SettingsPaneTests`.
- **Account touch, recorded (owner decision 12, keep and disclose):** the
  lock-screen card's heart writes to the connected account's Liked Songs while
  the Mac is locked. Connecting the account is the opt-in and is off until the
  person connects; without an account the heart does not exist. Settings now
  states it while connected ("The heart on the lock screen adds the song to
  your Liked Songs."). No new data leaves the Mac: the call is the same
  `/v1/me/library` write the island's heart already makes.
- Deferred: showing the account's display name, which needs a new
  `GET /v1/me` request.
### The one-line lyric reads ahead — 2026-10-11 (ly/READ-01)

The owner's request: lyric timing is exact when a line lights as the voice
arrives, but a person singing along reads the next line before they sing it.

- [x] **The closed island's caption turns to the next line early.** For a
  transition with no honoured end the caption shows the next line, unswept, at
  `next.at - min(readAhead, 0.45 × (next.at - prev.at))`, never before the
  previous line's final word starts. Honoured gaps, intro, outro, the stage,
  the lock card, the Shortcuts "line playing right now" action (readAhead 0)
  and the word sweep are unchanged. One pure function,
  `LyricSweep.readingMoment`, picks the line; `readAheadStart` decides when,
  and `LyricsCoordinator.registerBoundaries` arms a wake for the same moment.
  `ReadingLeadTests`; lab case L9 in `LyricAccuracyLabSweepTests`.
- [x] **Setting:** Settings > Music, "Show next line early" — Off, 0.25 s,
  0.5 s (default), 0.75 s, stored in `lyrics.readAhead`, snapped to the nearest
  option. **Display only: nothing leaves the machine, no account, no
  system-wide setting.**
- [ ] **Physical check owed:** with a continuous-singing track (no gap between
  lines) closed on the island, the next line is on screen about half a second
  before the voice reaches it and turns with the existing caption turn;
  across a long instrumental it still waits for the end of the previous line.
  Off restores the exact-on-the-voice turn.
- [x] **Amended 2026-10-11 (ly/READ-02): the default is Auto.** Owner's
  listening test: a fixed 0.5 s was perfect on a slow ballad of long lines,
  a bit much elsewhere, and never to go below 0.30 s. The row is now Off,
  Auto (default), 0.3 s, 0.5 s (0.25 s and 0.75 s removed); Auto is
  `clamp(0.30 + 0.004 × characters of the next line, 0.30, 0.50)` and the
  45 percent and final-word limits still apply on top (the 45 percent rule can
  still take one short transition under 0.30 s). `lyrics.readAhead`: absent =
  Auto, 0 = Off, other numbers snap to 0.3 or 0.5. Lab L9 over the 540-track
  corpus: 22,686 of 23,693 transitions turn early; Auto's early time p5/p25/
  p50/p75/p95 = 0.336/0.376/0.412/0.456/0.500 s, 10 percent of turns at the
  0.50 s ceiling, 140 pulled under 0.30 s by the 45 percent rule, 0 before a
  previous line's final word. `ReadingLeadTests`, `SettingsPaneTests`.
- [ ] **Physical check owed (READ-02):** on the ballad, Auto feels like the
  0.5 s that was perfect; on a faster song with shorter lines it turns
  about 0.35 to 0.45 s early and does not feel like too much.

## ly/VERSION-01 (2026-10-11): lyrics timed for a longer version

- [x] **Detection, notice, Sync Here.** An online timeline whose last stamp runs
  more than 3 s past the track's length is flagged (`LyricTimeline.overrun`);
  the lyrics stage then shows one inline notice and every row offers Sync Here
  (context menu and VoiceOver action) that sets the per-track delay so that line
  is current now. The per-track range is now +/-45 s (was +/-1.5 s); the online
  cache is format 3. **Display only: nothing leaves the machine, no account, no
  system-wide setting, and no new request** beyond the one-time background
  refresh of an already-cached hit that the cache already makes for any format
  change. Tests: `LyricVersionMismatchTests`.
- [x] **Lab L10** (`LyricAccuracyLabVersionTests`, 540-track corpus): 61 of 535
  records with a length are stamped more than 3 s past their own end (11.4 %),
  1,236 lines past the end; overrun p50 56 s, p95 284 s.
- [ ] **Physical check owed (VERSION-01):** on *We Are The People* (Empire Of
  The Sun) from Yandex Music, the notice shows on the stage; right-click the
  line being sung, choose Sync Here, and the lines land on the voice, the
  notice goes, and Reset (hold the readout) brings it back. The compact caption
  and the lock card show no notice and are not hidden for a mismatched lyric
  (the owner decides later); they read the same lead, so they follow a sync.

## Redesign — 2026-10-15

Binding spec: `docs/plans/2026-10-15-redesign-spec.md` (from the design
canvas, version 33, and the owner's thirteen decisions of 2026-10-15). Five
releases, each on its own branch cut from the previous one; none is merged
to `main` without the owner.

New settings and their defaults (spec §14):

| Setting | Default | Why that default |
|---|---|---|
| Music › Volume and Output | **on** | owner-waived exception (decision 8), recorded under Scope divergence |
| Music › Lyric Band | on | display only |
| Lyrics › Translate Lyrics | off | decision 11; online only through Translate Online's existing consent |
| Lock Screen › style Automatic | default when unset | display only; a stored choice is kept |
| Lock Screen › Rest as Banner | on | display only |
| Privacy › Include Images | on | memory only, empties at quit |
| Privacy › Keep Pinned Items | off | decision 10; writes a file |
| Translate › Keep History | off | memory only, but it is content |
| Translate › Speak Button | on | sends nothing, changes nothing system-wide |
| General › Volume and Brightness | off | decision 13; needs Accessibility, sets system values |

### R1 — Island, Music, Lyrics (`feat/redesign-r1-island-music-lyrics`)

- [x] Built, `./scripts/check` green, Codex and Opus reviews answered,
  installed — 2026-10-15 at `fa5c466`: 11 of 11 steps, 1401 tests with 30
  skipped and 0 failures. Codex (two passes) and Opus (review and re-review)
  findings fixed in `c76cc89`, `6c28315` and `fa5c466`. Installed in
  /Applications over the Prompter release-1 build. The hardware checks below
  are owed.
- [ ] **R1-H1** On the 14-inch MacBook Pro, the 300 pt island's cover and
  equalizer sit 8 pt from its ends and the wings read as even.
- [ ] **R1-H2** Key line: visible on Aerial and Pro Black, absent on Sonoma;
  1 pt at 0.50 (music) / 0.26 (other) neither glows nor vanishes. Tune here.
- [ ] **R1-H3** The new-track peek's 50 pt growth reads as the island
  growing, not as a window appearing.
- [ ] **R1-H4** Player → lyric column → tall page and back: everything
  travels, nothing pops or disappears.
- [ ] **R1-H5** The player's volume slider follows the volume keys and an
  AirPods switch; the Output menu lists and switches devices.
- [ ] **R1-H6** Translate Lyrics on a Russian or English song: the
  translations arrive together and sit under each line.
- [ ] **R1-H7** The Output menu, the More menu and the translation menu
  (right-click on Show Translation) open under their buttons from the
  non-activating panel; below 540 pt the slider row inside the Output menu
  takes a drag; `.help` tooltips appear.
- [ ] **R1-H8** Translations arriving re-space the column and the tall page
  without a jump that loses the sung line; the tall page's 400 pt growth and
  Collapse leave no click-through gap at the foot.
- [x] **R1-H9** A wallpaper set from Downloads raises no privacy prompt (the
  key line is simply absent there). *Verified off hardware 2026-10-15:* both
  readers of the wallpaper refuse a protected path before opening it —
  `WallpaperToneTests.testAWallpaperBehindAPrivacyGateIsNeverOpened` (Downloads,
  Desktop, Documents, iCloud Drive, other apps' containers, and
  `~/Pictures/../Downloads` folded) and
  `LockCardMaterialTests.testAGatedWallpaperIsNeverOpenedForTheCard`.
  `NSWorkspace.desktopImageURL` only names the file. A live repeat is optional.

### R2 — Lock screen (`feat/redesign-r2-lock`)

- [x] Built, `./scripts/check` green, Codex and Opus reviews answered,
  installed — 2026-10-15 at `4641334`: 11 of 11 steps, 1460 tests with 30
  skipped and 0 failures. Codex (two passes) and Opus (review and re-review)
  findings fixed in `6cfb47e` and `9fa985f`. The hardware checks below are
  owed.
- [ ] **R2-H1** The banner under the clock on Aerial, Pro Black, Sonoma and
  Sky Blue.
- [ ] **R2-H2** Banner → card by a click, card → banner by the chevron; the
  card grows in place.
- [ ] **R2-H3** At Automatic, the lyric reads over Aerial's bright lines.
- [ ] **R2-H4** The output pane switches to AirPods, with the haptic.
- [ ] **R2-H5** No wings at the notch while the banner or card shows; a
  click on the notch still shakes.
- [ ] **R2-H6** A song with no cover (a podcast, a browser tab) at
  Automatic: the card stays mostly solid and every line reads.
- [ ] **R2-H7** Transparent over Sky Blue and a white wallpaper: the black
  rises enough that the artist line and the times read; over Aerial it stays
  at 0.30. This supersedes the 2026-10-11 divergence "Transparent guarantees
  4.5:1 only over the cover's share" — the wallpaper is now measured.
- [ ] **R2-H8** Picking a device on the Output pane stays on the pane; with
  Rest as Banner off the card otherwise behaves as before R2.

### R3 — Shelf and Clipboard (`feat/redesign-r3-shelf-clipboard`)

- [x] Built, `./scripts/check` green, Codex and Opus reviews answered,
  installed — 2026-10-15 at `1d882c3`: 11 of 11 steps, 1668 tests with 30
  skipped and 0 failures. Codex (three passes) and Opus (review and
  re-review) findings fixed in `f5c4d23` and `348bfb6`, the Clipboard's
  filter moved clear of the notch. The hardware checks below are owed.
- [ ] **R3-H1** Three Finder files dragged in land as icons; the same drag
  over AirDrop sends without keeping.
- [ ] **R3-H2** Delete with the pointer on the Shelf removes the selection
  and never the files.
- [ ] **R3-H3** An image copied in Safari appears under Images and pastes
  back.
- [x] **R3-H4** Pins survive a relaunch with Keep Pinned Items on, and the
  file is gone when it is turned off. *Verified off hardware 2026-10-15:*
  `ClipboardPinsTests.testPinsRoundTripThroughTheFile` (a new store over the
  same file is the relaunch), `testTurningTheSwitchOffDeletesTheFileAndOnWritesWhatIsPinned`
  and `testALeftoverFileIsRemovedAtLaunchWhenTheSwitchIsOff`.
- [ ] **R3-H5** With Mail frontmost and the pointer resting on the Shelf,
  ⌫ deletes text in Mail unless a tile was selected during this opening;
  reopening the panel shows no selection.
- [x] **R3-H6** The Clipboard's Kind filter and search field sit below the
  header, clear of the notch, at 480, 560 and 620 and in Russian.
  *Verified off hardware 2026-10-15:* `HeaderNotchBandTests.testNoClipboardControlReachesTheNotch`
  (every width, searching or not, every notch width),
  `testTheClipboardFilterRowIsBelowTheHeaderWithWordsInEnglishAndRussian` and
  `ClipboardPaneTests.testEveryKindHoldsAt480And620InRussian`; the lab's
  renders show the Russian filter in words at 560 and the English symbols at 480,
  both on their own row under the header.
- [ ] **R3-H7** With "Paste from Other Apps" set to Ask, copying a picture
  with history on asks once and never twice. This amends sp/CB-02 (above):
  Include Images, on by default, is a third reason Isla reads a copy's
  contents, beside Clipboard History and Save Clipboard Screenshots.

### R4 — Translate and Settings (`feat/redesign-r4-translate-settings`)

- [x] Built, `./scripts/check` green, Codex and Opus reviews answered,
  installed — 2026-10-15 at `1c5cf4e`: 11 of 11 steps, 1823 tests with 30
  skipped and 0 failures. Opus reviews of both halves and a re-review, and
  five Codex passes; findings fixed in `5887b0e`, `0307eb8`, `7eacad8` and
  `1c5cf4e`, the chief one a Use Online press that used to cover the next
  language pair too. The hardware checks below are owed.
- [x] **R4-H1** Settings at 480 pt in Russian: nothing clipped, the sidebar
  truncates. *Verified off hardware 2026-10-15:*
  `SettingsFormTests.testEverySectionHoldsAtFourEightyAndSixTwentyInEnglishAndRussian`
  (every control of all ten sections inside the form, sliders wide enough
  for a knob, push buttons uncut, at 480 and 620 in both languages); the
  lab's Russian render at 480 shows «Конфиденц…», «Сочетания к…» and «Экран
  блок…» truncated in the sidebar with the form whole.
- [ ] **R4-H2** Speak in a Russian and an English voice; Stop Speaking stops.
- [ ] **R4-H3** The lock-style previews match the lock screen.
- [ ] **R4-H4** Translate's pop-ups open from the panel with the chosen
  item over the button, at 480, 560 and 620; Recent lists this session's
  targets.
- [ ] **R4-H5** With "Paste from Other Apps" set to Ask, opening Translate
  never asks; pressing Paste asks once. Under Don't Allow, Paste is disabled
  and its tooltip says why.
- [ ] **R4-H6** Use Online on a language that is not downloaded sends once;
  changing the target afterwards shows the card again and sends nothing
  (watch with `nettop -p Isla` or a firewall prompt).
- [ ] **R4-H7** Russian at 480: Translate's alert cards fit the card and
  the pop-up labels truncate at the tail.
- [x] **R4-H8** "Lyrics Settings…" opens Settings on Lyrics; reopening
  Settings returns to the last section; Acknowledgements… opens the notices.
  *Verified off hardware 2026-10-15:* `SettingsTableTests.testDeepLinksSelectTheirSection`
  ("Lyrics Settings… opens Lyrics"), `testTheModelRemembersAndRestoresTheSectionShown`
  (a new model over the same defaults opens on the last section), and
  `SettingsReviewFixTests.testAcknowledgementsFallsBackToAboutWhenNothingOpens`;
  the installed bundle carries `Contents/Resources/Licenses/THIRD_PARTY_NOTICES.md`,
  the file `SettingsPane.acknowledgementsURL` opens.
- [ ] **R4-H9** Type into a Translate source holding 20,000 characters: the
  letter is refused and the field does not show it (SwiftUI's `TextEditor`
  may keep a refused letter on screen; untested off hardware). Repeat with a
  Japanese input method.

### R5 — Volume and brightness pop-up (`feat/redesign-r5-hud`)

- [x] Built, `./scripts/check` green, Opus review answered, installed —
  2026-10-15 at `d58d235`: 11 of 11 steps, 1982 tests with 30 skipped and 0
  failures. Opus review and two re-reviews; five Codex passes up to
  `468ebd9`. Findings fixed in `0bff08a`, `140053f`, `468ebd9`, `5d8f23e` and
  `d58d235` (the tap's callback kept cheap, the output latched across a
  write, ⌥/⇧/⌘/⌃ shortcuts left to macOS, one decision per hold). The owner's
  real-icons fix (`fix/redesign-real-app-icons`, merged in `aca4780`) ships
  with this release. The hardware checks below are owed.
- [x] **Codex review of `5d8f23e` and `d58d235`.** Codex's usage limit ran
  out after `468ebd9`, so those two fixes had an Opus review only at first.
  Reviewed 2026-10-15 at 15:27 with `codex exec review --base 468ebd9`
  (gpt-6-luna, high), which read the `MediaKeyHUD` diff and its tests:
  "No actionable bugs found in the changes." Its own focused test run could
  not start inside its sandbox (SwiftPM's cache was not writable), so the
  tests are the closing `./scripts/check`'s.
- [ ] **R5-H1** Turn it on, grant Accessibility: the volume keys show Isla's
  pop-up and never the Mac's.
- [ ] **R5-H2** Mute keeps the level, dimmed; unmute restores it.
- [ ] **R5-H3** Display and keyboard brightness keys on the MacBook Pro.
- [ ] **R5-H4** Turning it off gives the keys back at once.
- [ ] **R5-H5** An external keyboard's volume keys.
- [ ] **R5-H6** Volume down while muted: compare with the Mac's own
  pop-up (Isla keeps the Mac muted).
- [ ] **R5-H7** With the setting on, ⌥+volume opens Sound settings, ⇧+volume
  changes silently, and ⌥⇧ steps in quarters.
- [ ] **R5-H8** With an external display as main, and with the lid closed,
  the brightness keys go to macOS.
- [ ] **R5-H9** AirPods connecting while a volume key is held never jump
  their volume.
- [ ] **R5-H10** Real icons: the Settings sidebar and the Spotify head show
  Spotify's own icon; About's Isla icon matches the tiles; Players on This
  Mac lists Яндекс Музыка and both Telegrams with their icons.
- [x] **R5-H11** The empty player in Russian at 480 shows both Открыть Apple
  Music and Открыть Spotify; in English at 560 Yandex Music joins them.
  *Corrected and verified off hardware 2026-10-15:* the second half was
  wrong, and the build is right. The spec (§4.8, amended for real icons) lets
  a third app join only while the row still fits, and
  `PlayerLayout.openButtonRow` takes the longest prefix that fits. Measured
  with the button's own font (11 pt medium, 0.07 tracking): Apple Music
  142 pt, Spotify 115, Yandex Music 150, so three need 423 against a row of
  260, 340 and 400 pt at 480, 560 and 620. **With Apple Music and Spotify
  installed, Yandex Music never joins at any width**; it is offered on a Mac
  without Spotify (142 + 8 + 150 = 300 fits at 560). A short third name such
  as Deezer joins at 620. The lab's English render at 560, drawn from this
  Mac's installed apps, shows exactly Open Apple Music and Open Spotify with
  their real icons; `RealAppIconPaneTests.testRussianAt480KeepsBothLeadersUntruncated`
  holds the Russian half. Whether Yandex Music should get a way in beside
  the two leaders (a narrower form for the third button, say) is a product
  call for the owner, not a defect.

### Off-hardware pass over the 44 checks — 2026-10-15

Every check above was tried here first, on a 14-inch MacBook Pro (Mac16,8,
M4 Pro) with macOS 27.0.1, without the screen being taken over, without
launching Isla and without a DI_* hook. Three kinds of evidence:

- **Tests** — the named unit tests, all run in the closing `./scripts/check`.
- **Probe** — a read-only Swift probe of this Mac that sets nothing: which
  players are installed and the icons macOS gives them, the displays, whether
  DisplayServices and CoreBrightness answer, the speech voices, the audio
  outputs and the wallpaper's folder.
- **Lab** — `bash Scripts/visual-lab.sh` renders, inspected by eye.

What the probe found on this Mac: Spotify, Music, Podcasts, Яндекс Музыка
(`ru.yandex.desktop.music`), Telegram and Telegram Desktop are installed, each
with an icon up to 2048 px; Tidal, Deezer, YouTube Music, Qobuz and Cider are
not. One display, built-in, main, with a notch. DisplayServices reads the
display at 1.0; CoreBrightness answers with one keyboard backlight. Speech has
1 Russian voice (Milena) and 41 English. Outputs are the built-in speakers and
a Teams virtual device, so no AirPods were connected. The wallpaper is
Radial Sky Blue from `/System/Library/Desktop Pictures`.

| Check | Result here | What is left for the owner |
|---|---|---|
| R1-H1 | measurements held: `CompactIslandLayoutTests.testTheCoverAndTheEqualizerSitOnEightPointMarginsAtEveryNotchWidth` | a glance: the wings read as even |
| R1-H2 | opacities held: `KeyLineTests` (0.50 / 0.26, never at the top edge) | judging it on Aerial, Pro Black, Sonoma |
| R1-H3 | size held: `CompactIslandLayoutTests.testThePeekIsFiveHundredTwentyWideAndFiftyTall` | whether the growth reads as the island |
| R1-H4 | height held: `LyricColumnPaneTests.testTheTallPageSaysCollapseInThePlaceOfExpand` | watching the morphs |
| R1-H5 | no AirPods connected; logic in `PlayerPaneTests`, `OutputMenuTests` | all of it, with AirPods |
| R1-H6 | language rule held: `LyricTranslationTests` | a real song with the network |
| R1-H7 | menu anchor held: `OutputMenuTests.testThePopUpPointIsRightAlignedUnderTheAnchor` | menus from the live panel |
| R1-H8 | spacing held: `LyricTranslationLayoutTests` | the live re-space and the click-through foot |
| R1-H9 | **verified** (ticked above) | nothing |
| R2-H1…H8 | logic held: `LockCardLayoutTests`, `LockedIslandTests`, `LockCardMaterialTests` (no cover stays mostly solid, Transparent at 0.30), `LockCardPaneTests` | all eight need the real lock screen |
| R3-H1 | drop-target words held: `ShelfAccessibilityTests` | a Finder drag and AirDrop |
| R3-H2 | `ShelfDeleteKeyTests.testRemovingTheSelectionNeverTouchesTheFiles`; the app's only `trashItem` calls are its own drop inbox and saved screenshots | the Delete key itself |
| R3-H3 | `ClipboardImageTests.testACopiedPictureBecomesAnEntryAndCopiesBackAsThePicture` | a copy from Safari |
| R3-H4 | **verified** (ticked above) | nothing |
| R3-H5 | `ShelfDeleteKeyTests.testNoSelectionNeverClaims`, `ShelfPaneTests.testAStaleSelectionNeverHoldsTheKeyAcrossAnOpening` | ⌫ in Mail |
| R3-H6 | **verified** (ticked above) | nothing |
| R3-H7 | `ClipboardImageTests` (Include Images gates the read) | macOS's own paste prompt |
| R4-H1 | **verified** (ticked above) | nothing |
| R4-H2 | voices present (probe); `TranslateSpeechTests` | hearing both voices and Stop |
| R4-H3 | `SettingsFormTests.testThePreviewsAskTheCardsOwnMaterialDecision` | comparing with the lock screen |
| R4-H4 | `TranslateMenuTests` (Recent, headers, chosen row over the button) | the pop-ups from the live panel |
| R4-H5 | `TranslatePasteTests`, `TranslateReviewFixTests.testPasteIsDisabledUnderDontAllowWithAReason` | macOS's own paste prompt |
| R4-H6 | `TranslateReviewFixTests.testAPressDoesNotCoverAnotherTarget`, `testAPressDoesNotSurviveASwap` | watching the network |
| R4-H7 | no test lays the alert cards out in Russian at 480; the lab stopped before Translate | all of it (sitting 8) |
| R4-H8 | **verified** (ticked above) | nothing |
| R4-H9 | `TranslateReviewFixTests.testAnInsertionPastTheLimitIsRefused` | `TextEditor` on screen, and a Japanese input method |
| R5-H1 | `MediaKeyHUDTests` (no tap while off, a key consumed only when applied) | the keys and the Accessibility grant |
| R5-H2 | `SystemLevelsTests.testMuteKeepsTheLevelAndUnmuteRestoresIt` | the mute key |
| R5-H3 | both private interfaces answer on this Mac (probe); `SystemLevelsTests` | the four brightness keys |
| R5-H4 | `MediaKeyHUDTests.testTurningTheSettingOffEndsTheTapAtOnce` | the switch, then a key |
| R5-H5 | decoding held: `MediaKeyDecoderTests` | an external keyboard (none attached) |
| R5-H6 | `SystemLevelsTests.testVolumeUpWhileMutedUnmutesAsMacOSDoes` | comparing with the Mac's own pop-up |
| R5-H7 | `MediaKeyHUDTests.testOnlyAPlainPressAndOptionShiftAreConsumed`, `MediaKeyDecoderTests.testOptionShiftTogetherAreTheFineStep` | the three modifier presses |
| R5-H8 | `SystemLevelsTests.testTheApplierPassesBrightnessThroughWhenAnExternalMonitorIsMain` | an external display (none attached) |
| R5-H9 | `SystemLevelsTests.testADefaultOutputThatChangesBetweenReadAndWriteIsNeverWrittenTo` | AirPods mid-hold |
| R5-H10 | every icon resolves from the installed app (probe); `AppIconsTests` | a glance at Settings and About |
| R5-H11 | **verified, expectation corrected** (ticked above): Yandex Music cannot join beside Apple Music and Spotify at any width | a product call, if Yandex Music should be offered there |

Two things the pass turned up besides the checks:

- [ ] **The lab's Shelf case is stale since R3.** `VisualLabPanelTests.testShelf`
  (line 334) still expects the old single pill, "Drop to keep on the Shelf"
  and «Отпустите, чтобы оставить на полке», under a drag over a populated
  Shelf. R3 (`22f2cdf`) replaced it with spec §8's two drop targets, which
  the build draws ("Keep on Shelf" / "Release to add to the Shelf",
  "AirDrop" / "Send to a nearby device") and `ShelfAccessibilityTests` holds
  in the gate. The lab case skips itself in `./scripts/check`, which is why
  it went unseen; its expectations are owed an update, not the app.
- [x] **`./scripts/check` for this pass.** It changes only this file, and
  the code has not changed since the green gate at `d58d235`. Held back while
  the Lyrics Accuracy Lab shared the worktree, then run 2026-10-15 at 15:28
  after the Codex review: 11 of 11 steps in 199 s, 1982 tests with 30
  skipped and 0 failures (`gatekeeper` skips itself on the ad-hoc build).

#### The owner's run sheet

The checks still open, grouped by what each sitting needs, so each setup is
done once. The expected result of every check is its line above.

1. **No setup, Music playing, about 10 minutes** — R1-H1, R1-H3, R1-H4,
   R1-H7, R1-H8, R5-H10. Play a song in Spotify; watch the island's ends and
   the new-track peek; click it open, step Player → lyric column → Expand →
   Collapse; open the Output, More and translation menus at 480 and 620
   (Settings › General › Panel Width); open Settings › Music and About.
2. **Wallpapers, about 5 minutes** — R1-H2, then R2-H1, R2-H3 and R2-H7 in
   sitting 3. Switch the wallpaper between Aerial, Pro Black, Sonoma, Sky Blue
   and a white picture; look at the island's key line on each.
3. **The lock screen, about 10 minutes** — R2-H1…R2-H8. With a song playing,
   lock with ⌃⌘Q on each wallpaper above; click the banner, fold it with the
   chevron, open the Output pane, pick a device; click the notch (it shakes);
   then play a podcast with no cover at Automatic. Turn Lock Screen › Rest as
   Banner off and lock once more.
4. **AirPods, about 5 minutes** — R1-H5, R2-H4, R5-H9. Connect them while the
   player is open and the slider moves with them; switch output from the
   Output menu; hold a volume key while they connect (with Volume and
   Brightness on).
5. **The keys, about 10 minutes** — R5-H1…R5-H4, R5-H6, R5-H7. Settings ›
   General › Volume and Brightness on; grant Accessibility when asked. Press
   volume up/down, mute, mute then volume down (compare with the switch off),
   ⌥+volume, ⇧+volume, ⌥⇧+volume, both display brightness keys and both
   keyboard brightness keys; turn the switch off and press a volume key.
6. **An external display and keyboard** — R5-H5, R5-H8. Volume keys on the
   external keyboard; brightness keys with the external display as main, and
   again with the lid closed.
7. **Shelf and Clipboard, about 10 minutes** — R3-H1, R3-H2, R3-H3, R3-H5,
   R3-H7. Drag three files from Finder onto the island, and one onto the
   AirDrop target; select a tile and press ⌫ with the pointer on the Shelf
   (the files stay in Finder); copy an image in Safari and paste it back;
   with Mail frontmost and the pointer on the Shelf, ⌫ edits Mail's text;
   set System Settings › Privacy & Security › Paste from Other Apps to Ask
   for Isla and copy a picture.
8. **Translate, about 15 minutes** — R4-H2…R4-H7, R4-H9. For R4-H7, set
   Isla to Russian (System Settings › General › Language & Region ›
   Applications) and the panel to 480, then translate into a language that
   is not downloaded so the alert card shows, and open both pop-ups. Speak a Russian and
   an English result and stop one midway; compare Settings › Lock Screen's
   previews with sitting 3; open both language pop-ups at 480, 560 and 620;
   repeat the paste prompt with Ask and then Don't Allow; with
   `nettop -p Isla` running, press Use Online on a language that is not
   downloaded, then change the target; paste 20,000 characters and type one
   more letter, also with a Japanese input method.
9. **Lyrics translation, about 5 minutes** — R1-H6. Settings › Lyrics ›
   Translate Lyrics on; play a Russian song and an English one.
