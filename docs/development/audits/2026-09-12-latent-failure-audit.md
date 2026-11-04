# Latent-failure audit — every feature, every edge the eye cannot catch

**Date:** 2026-09-12 · **Branch:** `feat/lyrics-accuracy` at `5d881c5` + working tree · **Method:** full
read of every file under `Sources/` (all 27 services, the helper, the notch shell, the view model, the
UI layer), the full test suite run, on-disk state inspected (app bundle, lyrics cache, running
processes), plus external primary-source research for the platform claims. Companion to the KRC
entity diagnosis reported the same day; that finding is A1 here, restated with its fix.

Failures are graded:

- **A — confirmed failing now.** Evidence in hand: a red test, a state diff, a repro on disk.
- **B — structural risk.** Works today, carries a documented external dependency that can
  silently remove the feature. Each names its tripwire and its native mitigation.
- **C — edge/hardening.** Real but low severity, or reachable only in rare states.
- **D — design-conformance findings**, judged against Apple's fluid-interface and design-principle
  practice (WWDC *Designing Fluid Interfaces* 2018, *Principles of Great Design*; the
  apple-design doctrine this audit carries: springs from current value, interruptibility,
  materials never stacked, haptic causality/harmony/utility, tracking per size).

---

## A — Confirmed failures

### A1. Kugou-served lyrics render HTML entities raw (`I&apos;ve been waiting`)

**Observed:** the lyrics stage showed `I&apos;ve been waiting` for Radiohead — "Go Slowly" while
Spotify showed `I've been waiting`. Not a rendering fault: the cached text itself carries the
entity.

**Evidence chain:**

1. `~/Library/Application Support/Isla/lyrics/849df9640f47986e.lrc3.json`, written 11:26 Sep 11 —
   one minute before the screenshot — stores `I&apos;ve been waiting`, `I didn&apos;t care…`,
   `Written by：Ed O&apos;Brien/…`, plus Kugou's signature metadata block (`Go Slowly (慢慢走) -
   Radiohead (电台司令)`), word-timed.
2. The three word-synced parsers decode entities on two of three paths:
   - TTML/AMLL: `WordSyncedLyrics.parseTTML` calls `decodeEntities` per word and gap
     (`WordSyncedLyrics.swift:57,68`) ✅
   - QQ QRC: `QQLyrics.extractQRCBody` decodes the body before parsing (`QQLyrics.swift:236`) ✅
   - **Kugou KRC: `parseKRCBody` (`WordSyncedLyrics.swift:130-156`) never decodes**, and
     `fetchKugou` goes straight `decryptKRC` → `parseKRCBody` (`LyricsStore.swift:832-833`) ❌
3. Kugou stores lyric text HTML-escaped inside KRC; shipping lyric tools decode after decryption:
   lx-music-desktop carries a dedicated entity map (`&apos;`, `&#039;`, `&nbsp;`, …) applied to lyric
   text, and multiple KRC pipeline implementations run the same decode straight after the KRC
   download (Sources [1],[2]). Note some KRC payloads carry no entities — the correct behavior is
   "decode if present", which a replace-based decode gives for free.

**Also broken by the same omission:** the line text in cache persists the entity, so the caption,
the stage, and the lock card all render it (one `Line.text` everywhere — by design). And `cleaned()`
(`LyricsStore.swift:394`) judges credits by prefix and never decodes either.

**Fix (native-level, one place):**

- Decode once per source at Line construction — the QRC approach generalized: decrypt → decode →
  parse, with one shared helper. Prefer the ampersand-last order (`&quot;/&apos;/&lt;/&gt;` first,
  `&amp;` last, as `QQLyrics.decodeEntities` already does) so `&amp;apos;` cannot double-decode.
  Note `WordSyncedLyrics.decodeEntities` (`:290-296`) currently uses the amp-first order — fold both
  into one correct helper while touching this.
- Decode **words too**, not only line text (word-level entities survive into the karaoke sweep).
- Extend to numeric forms (`&#39;`, `&#039;`, `&#x27;`) — the entity maps in lx-music-desktop and
  the Kugou pipeline decoders cover exactly these (Sources [1],[2]).
- Apply the same decode to LRCLIB's `parseLRC` output: LRCLIB is user-contributed and escaped text
  appears there too (Sources [3]).
- **Cache invalidation:** the entry written before the fix keeps showing entities until refetched.
  The v4 identity mechanism the working tree just added (`isrc`/`durationBucket` per entry,
  `LyricsStore.swift:272-291`) is the model: stamp entries with a `textDecoder` generation (or bump
  the format suffix to `.lrc5.json`, letting the existing v3-prune sweep carry v4 away), so a fixed
  build refetches each track exactly once. The manual escape hatches today are the stage's ↻
  re-search button and Settings → Clear Lyrics Cache.

### A2. QQ/Kugou *search* metadata is not decoded — the matcher judges escaped titles

`QQLyrics.parseSong` (`QQLyrics.swift:119-130`) and the Kugou search mapping
(`LyricsStore.swift:792-810`) take `songname`/`singername`/`filename` raw. QQ's search answers
HTML-escaped text; a catalogue entry filed `Don&apos;t` can never score against the query
`Don't`: `textScore` (`LyricsStore.swift:523-536`) needs equality or containment, and
`I&apos;ve` contains neither `I've` nor its folds. The right hit can lose to a worse-shaped
candidate, or the whole pool can score 0 and answer nil — the "no lyrics for this track" that is
really "no *decoded* lyrics for this track".

**Fix:** decode candidate `title`/`artist` with the same shared helper before `MatchCandidate` is
built. One function, applied at the two search boundaries — matching then judges the same world the
display will.

### A3. The position clock's correction window is not flushed on a rate change (test written, code missing)

`MediaControllerTests.testRateChangeFlushesCorrectionWindow` fails today:

```
MediaControllerTests.swift:617: error: … XCTAssertTrue failed - a rate change must flush the
regression window built at the old rate
```

The working-tree diff exposed `correctionWindow` for tests and documented the intent
(`MediaController.swift:200-207`: "A rate change is the same kind of discontinuity… so the window
flushes there too") — but no production code flushes on a rate change. The window *does* flush on
loop restart, on a ≥1.0 s correction, and on track change (`:503`, `:607-609`, `:755`); it does not
flush when `snapshot.rate` changes (e.g. 1×→2× in a podcast app, or the transient 0→1× at resume
that is *not* a loop restart when the poll gap is short). `regressedAnchorPosition`
(`:521-531`) recomputes every origin at the current rate, so origins measured at the old rate lean
the mean — the bar drifts against the voice for up to five polls after every speed change. The
failure the file already fixed twice (pause flush, seek flush) in a third guise.

**Fix:** where `snapshot.rate > 0` is adopted (`:825`), flush `correctionWindow` when the sign or
value of the rate changes materially (e.g. `abs(new - old) > 0.01`). One line plus the test that
already exists. This is exactly the TDD state CLAUDE.md's loop warns about — *a red build is not a
change to commit.*

### A4. The branch carries two red tests right now

`swift test` (full run, this day): **338 tests, 2 failures** — A3's rate-change test, and
`LyricsStoreTests.testIsrcRefinementSkipsStaleCacheHit:261` ("the ISRC refinement should have
settled, got none"). Both belong to the uncommitted lyric-accuracy WIP. The first is
specified-but-unbuilt (A3); the second means the new stale-cache-skip path does not settle through
the QQ fixture yet. Neither should ride along with unrelated commits; the per-change loop
(commit → clean rebuild → reinstall → relaunch) is blocked until they are green.

### A5. The running app is behind the code it is supposed to be running

- Installed & running: `/Applications/Isla.app` binary dated **Sep 11 09:26**, pid 17002, still
  writing **`.lrc3.json`** cache files (one written 02:03 today by the live process).
- The branch writes **`.lrc4.json`** (`LyricsStore.swift:996`) and last committed at **12:25**
  Sep 11, with further uncommitted work after.

So the app the user sees is missing the entire final stretch of the lyric-accuracy work — including
the cache-format bump and the KRC/QQ tier changes — while looking, from the notch, like it has
them. This is the exact state CLAUDE.md's "After each change" section exists to prevent (commit →
`rm -rf .build build && bash Scripts/bundle.sh release` → reinstall to /Applications → relaunch →
`pgrep -fl Isla`). The 09:26 build also predates the v0.3 motion/contrast work merged that morning.

**Fix:** run the loop. Until then, every observation of "the app's behavior" is an observation of a
superseded binary.

### A6. `./scripts/check` — the declared single verification gate — verifies nothing

Root branch `chore/scripts-check` added the runner with:

```bash
STEPS=(
)
```

and the script itself states the consequence: "a green result here proves nothing." The commit
subject ("chore: make ./scripts/check the single verification gate") and the actual state disagree.
Anyone — human, agent, hook, CI — running the gate gets a green light over an empty step list.

**Fix (native-level):** populate STEPS from the worktree's real gate order, e.g.
`test|cd .worktrees/dynamic-island-parity && swift test`,
`provenance|cd .worktrees/dynamic-island-parity && bash Scripts/test-provenance.sh`, and so on
through the eleven gates — or, if the empty state is intentional for a docs-only root, make the
script say so on stdout *and* exit nonzero when STEPS is empty, so green always means something.

### A7. Dragging the Panel Width slider rebuilds the whole panel per point of travel

`SettingsPane.bodyWidthBinding.set` (`SettingsPane.swift:349-362`) calls
`AppDelegate.refreshGeometry()` → `NotchController.rebuild()` on **every** binding write, and a
SwiftUI `Slider` writes continuously during a drag. One drag across 480→620 is ~140 full teardowns:
panel ordered out, view model discarded and rebuilt, pointer watcher stopped, rects re-cut, panel
re-fronted — each point of travel. The rebuild-not-nudge choice is correct for *committing* a width
(the comment documents why: it is the display-change path, the only one known to leave every rect
consistent); paying it per tick is not.

**Fix (the native shape):** `Slider` has `onEditingChanged:` precisely for this. Keep the live
`@State` preview per tick; write defaults and call `refreshGeometry()` once, when editing ends
(`onEditingChanged: { if !$0 in … }`). Same pattern already correct for the hover-delay slider,
whose per-tick update is genuinely cheap (`refreshPointerTuning` sets one var).

---

## B — Structural risks

### B1. The entire Now-Playing path hangs off `/usr/bin/perl` — a file Apple can remove

The helper (`helper.m:1-15`) exists because MediaRemote's read path is closed to ordinary processes
since macOS 15.4 and the `com.apple.mediaremote.external-access` entitlement is restricted —
verified by the reference adapter's documentation, the 15.4 breakage reports across shipping apps,
and a direct experiment showing a self-claimed entitlement is still denied (Sources [4],[5],[6]).
`mediaremoted` grants the `com.apple.*` bundle-id prefix, which is how `/usr/bin/perl`
(`com.apple.perl`, platform binary, `flags=0x0` — no hardened runtime, no library validation,
verified locally on 26.6.2) gets through. **Current state: perl 5.34 still ships on macOS
26.6.2 (verified on this disk), and the adapter author confirms the bridge still works on macOS
26** (Sources [6],[7]). The Catalina release-notes warning — "Future versions of macOS won't
include scripting language runtimes by default" — remains the operative notice, and Python 2.7's
removal in 12.3 shows Apple executes it. So the risk is not the mechanism breaking silently — the
watchdog (`NowPlayingFeed.swift:137-181`) catches a mute helper and the failure policy is honest —
it is **Apple removing Perl from macOS**, which kills the *primary* route for every user at once,
leaving the two-app fallback as the product.

**Tripwires to watch:** macOS release notes mention `/usr/bin/perl`; the helper's
`mediaremote-symbols-missing` / `mediaremote-unavailable` error lines (`helper.m:265,365`);
`test-gatekeeper.sh` in CI. **Native mitigation already in place:** scripted fallback. **Worth
doing:** a Launch-Diagnostics note in Settings when `feedAvailable == false`, so a user on a future
macOS knows the island is running degraded rather than broken (today the only signal is a missing
compact island — indistinguishable from "nothing is playing", which is the same invisibility
failure the first-run pane was built to answer).

### B2. Quarantined helper dylib is refused on machines that did not build it

The checklist records "an unsigned build loses the MediaRemote path on the user's machine"; the
research pins the exact mechanism with a first-hand experiment on this OS (26.6.2, Sources [8]):
**quarantine on the dylib is what blocks the load** — an ad-hoc-signed dylib *without* the
quarantine xattr loads into `/usr/bin/perl` fine, while the same dylib *with* `com.apple.quarantine`
fails with `code signature … not valid for use in process: library load disallowed by system
policy` — a system-wide quarantine policy on library loads, not perl-specific and not AMFI library
validation (perl has none, `flags=0x0`). Unsigned dylibs never load on Apple Silicon at all. A
normal download-and-install path quarantines the archive *and* what Archive Utility extracts from
it — including the nested `libislamedia.dylib` — which is precisely why the README's
`xattr -dr com.apple.quarantine /Applications/Isla.app` (recursive, reaching the dylib) is the
load-bearing instruction. **Consequences, in priority order:**

1. **Notarization remains the real unlock** — it fixes both the Gatekeeper "Open Anyway" dance and
   (Developer ID + notarized + stapled) makes the whole conversation disappear. Still blocked on
   the Apple Developer Program membership (checklist, v0.2).
2. **Interim hardening worth shipping now:** the app *detects* this state instead of silently
   degrading — the helper's error lines already distinguish `mediaremote-unavailable`; a Settings
   note ("Now Playing is running through the scripting fallback; if you installed Isla from a
   download, clear quarantine: `xattr -dr com.apple.quarantine /Applications/Isla.app`") turns the
   B2 failure from invisible into self-serviceable, the same way the first-run pane answered
   "the app is invisible by design."

### B3. Lock-screen presentation rides private SkyLight SPI

`LockScreenPresence.apply` (`LockScreenPresence.swift:103-114`) creates a compositor space at
absolute level 400 via `SLSSpaceCreate`/`SLSSpaceSetAbsoluteLevel` — the same symbol set and the
same 300/400 level map shipped by boring.notch, mew-notch, and Lakr233's SkyLightWindow; five
independent implementations agree on the map, and the nocta project verified all five calls
succeed on this exact build (26.6.2 / 25G83) (Sources [9],[10],[11]). The public route (raise past
`CGShieldingWindowLevel()` + `canBecomeVisibleWithoutLogin`) was tried first and *lost*, exactly as
the file documents. The `SkyLight` wrapper degrades to "pill hidden while locked" if any symbol
disappears — the failure is honest and bounded. One operational warning from the field research
applies here: **display sleep/wake at the lock screen makes WindowServer rebuild the shown space
set, so the show + re-adopt steps must be re-issued after wake** (Sources [11]) — Isla's wake
handler already re-runs the lock path when locked (`NotchController.swift:100-112`), which is the
right shape; the physical lock/sleep matrix in the manual checklist is what proves it.

### B4. QQ and Kugou lyric tiers are unofficial, keyless endpoints

`QQLyrics` and `fetchKugou` ride desktop-client endpoints with browser headers
(`QQLyrics.swift:21-28`, `LyricsStore.swift:768-825`). They can change or start refusing any day.
The architecture already contains the blast radius: AMLL exact-ID first, QQ/Kugou arbitrated
against each other, LRCLIB as the line floor, and a *failed tier is not cached* (only LRCLIB's own
200/404 are treated as answers, `LyricsStore.swift:866-924`). No action; this is the designed
posture.

### B5. Spotify's Web API gates on Premium — the heart hides instead of lying

`SpotifyAccount.apiBlocked` (`SpotifyAccount.swift:26-29`) records that Spotify gates the whole Web
API behind Premium as of 2026, and the heart hides when blocked. This is the correct
degradation (the alternative is a button that always fails). Note it in the audit for
completeness: Liked Songs is a Premium-only feature for as long as that gate stands.

### B6. `toggle()` and `translate()` have no locked-screen guard

`NotchController.toggle()` (`:567-586`) and `translate(_:)` (`:452-475`) run their full open paths
without checking `isLockedPresentation`, unlike `presentWelcome()` (`:606`), `sneakPeek()` (`:1139`)
and `islandClicked()` (`:501-504`), which all guard. The external research found **no primary
source supporting hotkeys firing at the lock screen** — the consensus among global-hotkey authors
is the opposite: at the lock screen the session's input context belongs to loginwindow, and
session-scoped registrations do not fire (Sources [12]) — so today this is very likely unreachable.
It stays in the audit as cheap defense in depth: if a future macOS ever delivers a hotkey (or an
automation, or the URL-scheme callback for the Spotify flow during an unlock race) into these
paths, `setOpen(true)` would grow `activeRect` from the deliberate pill-sized locked region to the
open-body rect over the shield, and `translate` would additionally `makeKey()` the panel — a key
window above the password field, the precise hazard `panel.onPress` already guards against in the
other direction (`NotchController.swift:781-792`).

**Fix (defense in depth, three lines):** early-return (or route to the refusal nudge) in both when
`viewModel.isLockedPresentation`. Costs nothing in the normal path; removes a whole class of
lock-screen state leaks regardless of what loginwindow decides to deliver.

### B7. Translate is dead weight on the platform floor the package itself declares

`Translator` requires macOS 26 + Apple Intelligence (`Translator.swift:106-120`); the package
targets macOS 15 (`Package.swift:6`). On 15.x — and on any Apple-Intelligence-less Mac — the tab
exists to display "Translation needs macOS 26 or newer." The comment documents why the Translation
framework was rejected on *26* (stale language-asset generation reporting `.supported` forever,
`translate()` failing opaquely). But the two facts compose badly in the other direction, and the
research confirms the native alternative exists well below 26: **`TranslationSession` is available
from macOS 15.0, is explicitly on-device, and needs no entitlement** (Sources [13]) — the same
mechanism, on the platforms where the foundation model does not exist. Native-level options, in
preference order: (a) Translation-framework path on 15.0–26 with the FoundationModels path on 26+
(keeping the documented status caveat as the reason for the split) — each platform gets the Apple
mechanism that actually functions there; (b) hide the Translate tab on unsupported systems (the
app's own doctrine: no dead front doors — the welcome pane, the heart, and the volume slider all
*disappear* rather than explain themselves). Today's message-at-least-tells-you state is defensible
but is the only tab in the app that can be permanently dead.

---

## C — Edge cases & hardening (real, low severity)

- **C1. Lock card audio state can go stale while presented.** `LockScreenCard` reads outputs and
  volume on appear and on pane change; nothing listens for
  `kAudioHardwarePropertyDefaultOutputDevice` or volume changes mid-lock (AirPods connect,
  someone changes volume with keys → bar drifts). Native fix:
  `AudioObjectAddPropertyListenerBlock` while the card is up, exactly the System Settings-grade
  behavior the card imitates. The design constraint (sampler stopped while locked) does not apply —
  CoreAudio listeners are event-driven, not polling.
- **C2. Sneak peek fires on a player restart.** `MediaController.apply` keys peek on
  `track.key` identity, and the key embeds the pid (`:733`) — Spotify updating itself mid-track
  re-keys, so the pill re-peeks for an unchanged song. Cosmetic. Cheapest fix: key peek on
  title|artist|album only.
- **C3. Sweep fraction is character-space; the renderer is width-space.**
  `wordFraction` (`WordSyncedLyrics.swift:220-248`) divides character counts while `KaraokeRenderer`
  measures typographic width — for CJK-vs-latin mixed lines the lit edge leads/trails the true
  word boundary slightly. Hard to fix exactly (per-word widths would need measuring per line);
  worth a note, not a sprint.
- **C4. `reportedPosition` ages readings on the wall clock** (`MediaController.swift:1087-1103`)
  while the rest of the clock is monotonic deliberately. An NTP step mid-play ages one reading
  wrongly once; the anchor machinery absorbs it. Documented tradeoff; fine.
- **C5. `NotchGeometry.rememberedNotches` grows one entry per display id ever seen.** Bytes per
  session; ignorable, listed for completeness.
- **C6. Double-decode hazard in the TTML entity order.** `WordSyncedLyrics.decodeEntities` decodes
  `&amp;` first (`:291`), so `&amp;apos;` over-decodes to `'`. Fixed free as part of A1's shared
  helper.
- **C7. Root checkout's uncommitted `CLAUDE.md` edit** (rebuild/reinstall/relaunch loop + contrast
  paragraph) is exactly the loop A5 shows was skipped — worth committing on
  `chore/scripts-check` together with A6's STEPS fix, since both say "how this repo is verified."

---

## D — Apple-design conformance (what the audit checked the app against)

The motion/interaction layer was scored against the fluid-interface doctrine: respond on
pointer-down; springs from the current value, critically damped by default with bounce reserved
for momentum-carrying gestures; interruptibility everywhere; velocity handoff; symmetric paths;
materials never stacked, "materialize don't fade"; haptic causality/harmony/utility; Reduce
Motion/Transparency/Contrast answered; size-specific tracking.

**Conformant to an unusual degree — these are the standouts, kept as record:**

- **Response:** the island lights on mouse-down via `DragGesture(minimumDistance: 0)` + `isPressed`
  (`NotchContentView`), and Open-on-Hover's floor is 50 ms. Scrubber fill is *deliberately
  unanimated* so a seek lands under the cursor at once — response over beauty, the right call.
- **Springs:** `openAnimation` 0.34/1.0 and `compactAnimation` 0.28/1.0 — critically damped, per
  doctrine; the single under-damped spring (`lyricScroll` 0.42/0.86) is listed in code as the one
  allowed overshoot and pinned by `MotionValuesTests`. SwiftUI springs re-target from the
  presentation value with velocity, so interruption is native.
- **Interruptibility:** scroll-wheel takeover of the lyric stage (`ScrollWheelWatch` distinguishing
  a hand from the app's own animation) is exactly "the gesture and the animation stay parallel."
- **Materials:** one glass recipe, three call sites, never stacked, scrim-under-glass forbidden,
  `materialize` transition (blur+scale+opacity together) on glass arrival — a literal
  implementation of the doctrine's "materialize, don't just fade."
- **Haptics:** two moments only, on `.drawCompleted` so the tap lands *with* the frame that shows
  the result — harmony done better than most first-party apps manage.
- **Accessibility:** the whole Theme ramp is a function of Increase Contrast with WCAG ratios
  pinned by tests; Reduce Motion replaces springs with 0.12 s eases and freezes shimmer/dust/
  equalizer; Reduce Transparency goes opaque. Tracking re-implements SF's per-size table because
  fixed-size windows cannot use semantic styles.
- **Craft:** the equalizer freezes mid-bar on pause (layer clock), artwork morph never fades while
  travelling, `formatTime` rolls to hours instead of clipping podcasts — detail-work that reads as
  care.

**The two genuine design findings are A7 (slider commits should happen at gesture end —
feedback continuous, commit at rest) and B6 (over the shield, *nothing* may grow a hit region or
take the keyboard — predictability/safety).** Both are small; both are the difference between
"conformant" and "Apple-built" at exactly the moments the app is at its most exposed.

---

## E — Priority order

1. **A5 — run the per-change loop** (commit green, clean rebuild, reinstall, relaunch). Everything
   else is measured against a moving binary until this happens.
2. **A1+A2+C6 — one shared entity decoder** applied at KRC, QRC-already-done, TTML (order fix),
   LRCLIB, and both search-candidate boundaries; cache re-fetch via a decoder generation stamp.
3. **A3 — implement the rate-change window flush** its own test already specifies.
4. **A4 — get the tree green** (`testIsrcRefinementSkipsStaleCacheHit`).
5. **A7 — slider commits on editing end.**
6. **B6 — lock guards on `toggle`/`translate`.**
7. **A6 — give `./scripts/check` its STEPS (or make empty loud).**
8. **C1 — CoreAudio listeners behind the lock card.**
9. **B7 — decide Translate's posture below macOS 26.**
10. **B2 — ship the degraded-mode note now** (Settings surfacing `feedAvailable == false` with the
    `xattr -dr` instruction), and notarization when the membership lands — the experiment shows the
    quarantined dylib is the precise failure, so until notarization every fresh install needs the
    workaround and deserves to be told so.

## Sources

Code evidence cites `file:line` in `.worktrees/dynamic-island-parity` throughout. External claims
were collected against primary sources on 2026-09-12 (Apple documentation JSON, WWDC session
pages, Apple support articles, and the actual sources of the reference projects); where marked
**[LOCAL]**, verified first-hand on this machine — macOS 26.6.2 (Tahoe), build 25G83, the same OS
the installed app runs on.

**MediaRemote & the perl bridge**

- [4] MediaRemote closure on 15.4 — BetterTouchTool forum breakage thread
  https://community.folivora.ai/t/now-playing-is-no-longer-working-on-macos-15-4/42802 ;
  boring.notch issue #417 https://github.com/TheBoredTeam/boring.notch/issues/417 (further
  breakage links in the adapter README's motivation section).
- [5] Why the bridge works — `com.apple.*` bundle-id grant, `com.apple.perl`; entitlement
  self-claim denied: ungive/mediaremote-adapter README https://github.com/ungive/mediaremote-adapter
  and akalikbergenov/cyclop https://github.com/akalikbergenov/cyclop . **[LOCAL]** `codesign -dv
  /usr/bin/perl` → `Identifier=com.apple.perl`, `Platform identifier=26`, `flags=0x0(none)`.
- [6] Bridge still works on macOS 26 — ungive, issue #7 "Test on macOS 26.0.0" → "Still works."
  https://github.com/ungive/mediaremote-adapter/issues/7 . **[LOCAL]** `/usr/bin/perl` 5.34.1
  present on 26.6.2; Tahoe 26 release notes mention no scripting-runtime changes
  https://developer.apple.com/documentation/macos-release-notes/macos-26-release-notes ; the
  operative deprecation remains Catalina's
  https://developer.apple.com/documentation/macos-release-notes/macos-catalina-10_15-release-notes

**Quarantine / notarization**

- [8] **[LOCAL EXPERIMENT]** ad-hoc dylib without quarantine loads into perl on 26.6.2; the same
  dylib with `com.apple.quarantine` fails ("library load disallowed by system policy"); unsigned
  never loads on arm64. Gatekeeper/Open-Anyway:
  https://support.apple.com/en-us/102445 ; library-validation model:
  https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation

**Lock screen**

- [9] mew-notch `WindowManager.swift` — the exact SkyLight call set and 300/400 map:
  https://github.com/monuk7735/mew-notch/blob/main/MewNotch/Utils/Managers/WindowManager.swift
- [10] boring.notch `CGSSpace.swift` + lock-space commit 594396b; Lakr233/SkyLightWindow
  `SkyLightOperator.swift` (same constants):
  https://github.com/TheBoredTeam/boring.notch/blob/main/boringNotch/private/CGSSpace.swift ,
  https://github.com/Lakr233/SkyLightWindow/blob/main/Sources/SkyLightWindow/SkyLightOperator.swift
- [11] Level map documented and verified on 26.6.2/25G83; wake-at-lock requires re-issuing
  show + adopt: aNasiusA/nocta `docs/LOCK_SCREEN.md`
  https://github.com/aNasiusA/nocta/blob/main/docs/LOCK_SCREEN.md
- [12] Hotkeys at the lock screen — Keyboard Maestro author on session scoping
  https://forum.keyboardmaestro.com/t/triggers-not-recognized-at-mac-locked-screen/34025 ; lock
  notifications undocumented but long-stable:
  https://www.raygesualdo.com/posts/building-a-macos-locked-status-notifier-in-swift/ ; public
  alternative `kCGSSessionScreenIsLocked` (CGSession.h) per [11].

**Lyrics providers**

- [1] KRC entity decoding in shipping tools — lx-music-desktop entity map (`&apos;`, `&#039;`,
  `&nbsp;`, …): https://github.com/lyswhut/lx-music-desktop/blob/master/src/common/utils/lyricUtils/util.ts ;
  KRC-pipeline decode after download: https://github.com/JS1Lan/Lanote/blob/master/server.js
- [2] QRC is XML; consumers unescape after decryption — Lyricify-Lyrics-Helper `XmlUtils.cs`
  https://github.com/WXRIW/Lyricify-Lyrics-Helper/blob/master/Lyricify.Lyrics.Helper/Decrypter/Qrc/XmlUtils.cs ;
  reference 3DES/QMC decoder jixunmoe-go/qrc https://github.com/jixunmoe-go/qrc
- [3] LRCLIB API — endpoints `/api/get`, `/api/get/{id}`, `/api/search`, `/api/publish`,
  `/api/flag`, `/api/request-challenge`; "generous rate limiting"; line-synced `syncedLyrics`
  only, no documented word-synced support: https://lrclib.net/docs

**Translation, launch-at-login, platform**

- [13] Translation framework — macOS 14.4 framework / `TranslationSession` macOS 15.0,
  on-device verbatim, no entitlement:
  https://developer.apple.com/documentation/translation ,
  https://developer.apple.com/documentation/translation/translationsession
- SMAppService (macOS 13+, `mainApp`, `register()` subject to approval):
  https://developer.apple.com/documentation/servicemanagement/smappservice
- Liquid Glass — `glassEffect` / `NSGlassEffectView` macOS 26.0+; HIG materials rules
  ("Don't use Liquid Glass in the content layer", accessibility settings change or remove it):
  https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:) ,
  https://developer.apple.com/documentation/appkit/nsglasseffectview ,
  https://developer.apple.com/design/human-interface-guidelines/materials ,
  https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass
- **[LOCAL]** `CGWindowLevelForKey(.statusWindow)` = 25 on 26.6.2, unchanged; shipping notch apps
  use `.mainMenu + 1/+3` (mew-notch, boring.notch); no window-level changes in the Tahoe release
  notes.

**Confidence:** A-section findings rest on artifacts in hand (red tests, cache files, binary
timestamps) and are certain. KRC/QRC entity behavior is certain (multiple independent shipping
implementations + our own on-disk artifact). The B-section risks are graded by source strength:
perl/MediaRemote/SkyLight claims are rock-solid (first-hand or verbatim primary sources); lock
notification and hotkey-while-locked behavior are community-consistent with no Apple statement,
which is exactly why B6 is framed as defense in depth rather than a bug.
