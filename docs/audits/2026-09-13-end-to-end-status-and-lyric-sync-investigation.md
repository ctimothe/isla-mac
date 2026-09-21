# End-to-end status & the lyric-sync investigation

**Date:** 2026-09-13 · **Product build in `/Applications`:** Sep 13 06:35 = `feat/lyrics-accuracy`
@ `eace5e7` · **This document is the single complete picture:** what shipped, what is verified by
measurement, what remains unfinished, and what nobody knew to ask. Companion evidence:
`docs/research/2026-09-12-latent-failure-audit.md` (the audit that drove the fixes) and
`.superpowers/sdd/progress.md` (the task ledger with every review verdict and owed minor).

---

## 1. What is done — with its evidence

### This session's seven fixes (all merged, all reviewed unless noted)

| # | Fix | Commits | Tests | Review |
|---|-----|---------|-------|--------|
| 1 | The in-progress lyric-identity work finished **green**: a refined load (ISRC / exact duration arriving late) upgrades its stale cache entry instead of replaying it; the lyric clock flushes its drift-correction window on a playback-**rate** change | `8f9cb27`, `42bba08` | 338/338 | Approved |
| 2 | **The reported bug:** lyric text arrives decoded everywhere — one shared `HTMLEntities` decoder (amp-last, numeric decimal+hex) at the KRC, TTML, QRC, LRCLIB, QQ-search and Kugou-search boundaries; both duplicated private decoders deleted (also fixed the TTML amp-first double-decode); already-cached bad entries are **decoded on first open, offline, zero requests** and rewritten once (`decoded: true`) | `e5d1351`, `2b60f50`, merge `65d8001` | 346/346 | Approved |
| 3 | The Panel Width slider commits **once when the drag ends** (was: ~140 full panel rebuilds per drag) | `074eeaa`, merge `d9f1ea7` | 349/349 | Approved |
| 4 | ⌥⌘I / ⌥⌘T **refuse at the lock screen** with the pill's shake — no hit region grown over the shield, no key window above the password field | `5000040`, merge `fb00a8b` | 352/352 | Approved |
| 5 | `./scripts/check` at the repo root now runs four real gates (test / provenance / branding / localizations) — was an empty STEPS list printing green | root `b2e5a6d`, `f590042` | gate green, run twice | Approved |
| 6 | The lock-screen card **follows the machine's audio** live: `AudioWatch` (injectable, 6 tests) tracks default-output and volume changes mid-lock; volume listener follows device switches; card's mirror stands down while a finger holds the bar | `fae00ce`, merge `eace5e7` | 358/358 | deferred to final review (user direction) |
| 7 | The per-change loop ran: clean rebuild (`rm -rf .build build`), reinstall to `/Applications`, relaunch, `pgrep` proof (pid 2216 + healthy perl helper) | — | bundle OK | n/a |

**Suite ground truth at HEAD `eace5e7`: 358 tests, 0 failures** (verified twice by fresh runs, not
reports). The installed app binary (Sep 13 06:35, 1,823,920 bytes) is built from exactly this tree.

### Verified by live measurement (Section 3)

- The position clock runs **−0.10s behind** Spotify's own clock in steady play and never ahead —
  every scripted phase (pause, resume, ±seeks) lands inside its gate. The probe used a real cached
  word-tier fixture (31 lines, 529 word edges): **word-edge error median 0.000s**, zero movement
  while paused.

### Cache state after the upgrade (facts from disk)

`~/Library/Application Support/Isla/lyrics`: 4 `.lrc4.json` entries (2 `qq`, 2 `lrclib`), all
carrying the `decoded: true` stamp; 2 word-timed; **0 legacy `.lrc3` remain** — the first write of
the new build repaired what it had words for and pruned the unreadable v3 remainder (by design;
they were dead weight to v4 code). Tracks re-fetch on demand as they are played again.

---

## 2. What is unfinished — and why each matters

Ordered by leverage:

1. **Lyric-lead tuning (opened by this investigation, see §3.4).** The measured clock lag (−0.10s)
   plus the fixed display lead (+0.45s standard / +0.25s precision) puts the **screen ~0.35s ahead**
   on surfaces without precision sync even against a perfectly-timed source — very likely the
   "certain songs track faster than the singing" report. A deliberate re-tune with the probe is the
   next code change, not a guess.
2. **Task 7 — helper-degraded surfacing (audit B2 interim).** When the MediaRemote helper cannot
   load (quarantined dylib on a fresh download; measured failure: "library load disallowed by
   system policy"), the app silently degrades to scripting. Settings should say so and print the
   one-line `xattr -dr com.apple.quarantine /Applications/Isla.app` fix.
3. **Final whole-branch review** of the audit-fixes work (SDD process), which also sweeps the owed
   minors recorded in the ledger: `writeCache` nil-default params; ISRC force-unwrap style; the
   weak file-exists pin; the 200ms ordering sleep; task-2 report's `<0,142,0>` claim to correct;
   sourceless-entry re-decode; `HTMLEntities` `try!` style; NotchViewModel triple blank lines;
   call-site comment redundancy; slider commit reads `@State`; unchanged-width commit writes
   defaults.
4. **Release gates have not been re-run this session.** `swift test` + `bundle.sh` are green, but
   the full eleven-gate order (provenance → … → dmg) runs before a release, not per change.
5. **Notarization** — blocked on the Apple Developer Program membership; until it lands, every
   fresh-machine install needs the quarantine workaround (audit B2; the experiment that pinned the
   exact mechanism is in the audit's Sources).
6. **B7 product decision (owner):** Translate is permanently dead below macOS 26 / without Apple
   Intelligence. Apple's Translation framework (`TranslationSession`) exists from macOS 15.0,
   on-device, no entitlement — options: use it below 26, or hide the tab there.
7. **Manual validation matrix** (checklist §"Manual parity gates"): external-display behavior,
   Open-on-Hover fold-and-reopen, the physical lock/sleep cycle for the new audio watch and the
   refusal shake, RU layout pass, three-run performance medians (still blocked on CPU/RSS deltas).
8. **Housekeeping:** `feat/lyrics-accuracy` is 52+11 commits ahead of GitHub (`isla-mac`) — unpushed;
   the stale Xcode `xctest` process from Sep 12 still holds an old bundle path (kill pid 50771);
   root `chore/scripts-check` (f590042) is also unpushed.

### Things you did not know to ask (still true, from the audit)

- **B1:** the whole Now-Playing path rides `/usr/bin/perl` (verified still shipping on macOS
  26.6.2; the bridge still works) — Catalina's removal notice is the standing threat; the scripted
  fallback and the failure-policy backoff are the containment.
- **B3:** lock-screen presence rides private SkyLight SPI — the same 300/400 space map five
  shipping apps use; wake-at-lock requires re-adopting the space (the wake handler already re-runs
  the lock path; the physical matrix in item 7 is what proves it).
- **C-items** accepted as low severity: peek re-fires on a player restart (pid re-key); sweep
  fraction is character-space vs the renderer's width-space on mixed-script lines;
  `rememberedNotches` grows one entry per display id.
- **CI gap:** `.github/workflows/build.yml` exists but the local `./scripts/check` and CI can drift
  apart; both should eventually run the same step list.

---

## 3. The investigation: "for some songs the lyrics track faster than the singing"

### 3.1 Method — measurement, not opinion

`Scripts/measure-sync.sh` runs the **real shipped pipeline in-process** — the perl-hosted helper,
`NowPlayingFeed`, `MediaController`'s anchor/adopt/seek-verdict/tick logic — and samples it at 5 Hz
against **Spotify's own scriptable player position** (the clock Spotify's UI renders), through
scripted pause / resume / ±seek events. The harness's own header states the rule this repo now
lives by: *"Claims about sync accuracy are made from this harness's numbers or not at all."* Run
2026-09-13, 145 samples, real cached word-tier fixture (QQ-sourced, 31 lines, 529 word edges).

### 3.2 Measured result (verbatim from the run; delta = ours − truth, negative = behind)

```
145 samples  (delta = ours - truth; negative = we run behind)
  steady play      median=-0.103  mean=-0.104  min=-0.222  max=-0.018
  paused           median=+0.000  mean=-0.019  min=-0.221  max=+0.000
  resumed          median=-0.129  mean=-0.128  min=-0.337  max=-0.031
  after SEEK+30    median=-0.143  mean=-3.591  min=-30.099  max=-0.033
  after SEEK-10    median=-0.126  mean=+0.257  min=-0.357  max=+10.060
  after SEEK-1.5   median=-0.125  mean=-0.101  min=-0.416  max=+1.301
  word-edge steady median=0.000  max=1.330
  paused words: 1 distinct word(s), fraction drift=0.0000
  PASS  (steady within [-0.5,+0.2]; every phase within [-0.6,+0.6]; word-edge < 0.3; no paused movement)
```

The extreme min/max values in the seek windows are the pre-seek readings racing the jump — the
medians show every phase settling inside a tenth of a second.

### 3.3 Conclusion the numbers force

**The clock cannot be the cause.** In steady play ours is −0.10s *behind* truth and the maximum
recorded value is −0.018s — the pipeline never once ran ahead. Therefore "lyrics ahead of the
voice" is produced **downstream of the clock**, and there are exactly three contributors, ranked:

1. **The display lead (`LyricSweep.lead`): `+0.45s` standard, `+0.25s` precision.** Its comment
   justifies it as the sum of ticker quantization (250 ms) + crossfade (160 ms) + "the pipeline's
   own readings run slightly behind the audio." That third term was measured **this run at 0.10s**
   — the lead's pipeline share is over-budgeted by roughly its own size. The arithmetic of what
   the screen shows: `screen = truth − 0.10 + lead` → **≈ +0.35s ahead** on the caption and lock
   card (standard lead; precision sync runs only while the open panel shows Spotify), **≈ +0.15s
   ahead** on the open panel. A third of a second is clearly audible on word-level karaoke — this
   alone reproduces "faster than the singing" on *every* track, mildly, before any source error.
2. **Per-source timing bias (`LyricSource.bias` — all zeros today).** The Kugou/QQ catalogues are
   timed against their own masters; a re-release or MV cut can sit 0.2–0.8s off Spotify's audio.
   The architecture anticipates exactly this ("when a whole source proves consistently hot or cold
   the fix is one literal") but no source has been measured against a large enough sample to set
   one. **This is the "certain songs" amplifier:** same lead, plus a hot master, reads as badly
   fast.
3. **Per-track offset (exists, is the user's tool, and is under-discoverable).** The lyrics-stage
   header has ∓0.25s nudge buttons and a long-press reset (range ±1.5s, persisted per track inside
   the v4 cache entry). **For a track that tracks fast today, nudging minus until it sits right is
   the shipped remedy** — and that correction now survives refetches, re-searches, and relaunches.
   Note: the **global** `userOffset` has had no UI writer since the offsets rework (ledger,
   lyrics-accuracy Task 4) — a deliberate re-exposure decision is owed (§2 item 1).

### 3.4 What to do next (the plan, in order — analysis only; nothing was changed blind)

1. **Re-derive the leads from measured numbers, per surface.** With the pipeline share now
   measured at ~0.10s, candidates are: standard `0.45 → ~0.25`, precision `0.25 → ~0.15` — then
   **re-run the probe and read the word-edge column before/after**; the gate stays the arbiter.
   The leads are constants in one file with a comment that already names this exact re-measurement
   as the maintenance move.
2. **Measure per-source bias with data.** Extend the probe (or a one-off script) to sample N tracks
   per source against Spotify's clock *and* the audio itself (ear test on 3–5 known-good masters),
   then set `LyricSource.bias` literals from medians — never from one track.
3. **Re-expose `userOffset`** (Settings slider, ±3s) so a listener with consistently-hot sources
   can fix the whole catalogue in one move, leaving `trackOffset` for the outlier track.
4. **Word-timestamp semantics check** (pending the research companion): confirm QRC/KRC stamps mark
   word *starts* (the parser assumes starts; if any source marks ends, that source's words read one
   word ahead — would masquerade as "fast tracking" only on that source, i.e. exactly "certain
   songs").

### 3.5 External evidence (research companion, running alongside this document)

A research pass on lead conventions in shipping systems (AMLL's players, lyricify, LRCLIB-player
practice), word-timestamp semantics in QRC/KRC tooling, and MediaRemote-latency precedents in
boring.notch/mew-notch was dispatched with this investigation; its citations land beside this file
as `docs/research/2026-09-13-lead-conventions.md` when it returns, and any number it contradicts
here wins — same amendment rule as the design doc. *(If the file is absent, the pass had not
returned when this status was cut; treat §3.4 as the plan regardless — it proceeds from this
repo's own measurements.)*

---

## 4. How to reproduce every number in this document

```bash
cd .worktrees/dynamic-island-parity
swift test                                   # 358 / 0 (suite ground truth)
bash Scripts/measure-sync.sh                 # §3.2 (needs Spotify + bundle.sh once; pauses/seeks music)
ls ~/Library/Application\ Support/Isla/lyrics/  # §1 cache facts
cd .. && ./scripts/check                     # root gate: 4 steps
```

Every claim above traces to one of: a commit hash, a fresh command output in this session, an
on-disk artifact, or a cited external source in the 2026-09-12 audit. Nothing rests on memory or
intention.
