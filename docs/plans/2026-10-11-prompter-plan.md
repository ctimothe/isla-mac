# Prompter implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax. The binding behavior is `docs/specs/prompter.md`; this plan only says how and in what order. If the two disagree, the spec wins; amend the plan.

**Goal:** an optional Prompter — a script shown in the island and moved along as the speaker reads — absent when off, shipped in releases that never mix risk.

**Status:** release 1 (Classic) is built on `feat/prompter-core`, held: T0-T13 done, `./scripts/check` green (11 steps) twice, adversarial review done (Opus refutation, 7 confirmed defects fixed test-first; Codex found nothing but could not run the build in its own sandbox, so it is not independent verification), installed to /Applications with the switch off. Open: T-V1 (owner hardware validation), the editor's cue styling and RTL direction, typing latency on 500 KB pages, the mirrored-Keynote keyboard question. Releases 2-5 not started; release 3 stays gated (D3).

## Tier and process

Tier 3: it adds a tab (a public contract asserted by `TabContractTests`), touches the hot-key registry, the panel's hold logic, entitlements (release 2) and a privacy surface. Per the working agreement: brainstorm (done: the spec), isolated worktree, written plan (this), test-first, adversarial review including one reviewer from another model family, verify with `./scripts/check`, finish the branch.

- One branch and one worktree per release, cut from `main` (verify with `git worktree list` and `git merge-base`; the existing `.worktrees/dynamic-island-parity` sits on `feat/lyrics-accuracy`, which 0.3.0 already merged): `feat/prompter-core`, then `feat/prompter-voice`, `feat/prompter-follow`, `feat/prompter-import`. A fresh worktree has no build products; run `swift build` first.
- Commit after every task. Commit subjects are lowercase sentences about the result, bodies name the mechanism and the tests, no attribution trailers (personal repo, enforced by the global hooks). Merge each release back with an explicit merge commit.
- Release 2 (entitlement) ships **alone**; release 3 (speech) ships alone. Release 1 may ship with copy or styling but never with releases 2 or 3.
- After each code change: commit, then `bash Scripts/bundle.sh release` and `bash Scripts/install.sh`, then `pgrep -x Isla` to prove the installed copy runs (project `CLAUDE.md`). Never `open` the build copy.
- `./scripts/check` is the only definition of done and the owner must see its output. Run `Scripts/test-lifecycle.sh` once per release, not per batch: it runs the app against the real Application Support folder.
- Subagents never run the live app, never set `DI_*` hooks, never `dlopen` (standing rule: the owner is using the app while agents work). Hardware checks are the owner's or the driver's.
- Tests are one-shot (`swift test`, never watch). Tests that could touch a real microphone, recognizer or `UserDefaults.standard` are forbidden; the seams below exist for that.

## Architecture

```
PromptScript (pure value)  ──►  PromptMatcher (pure)            ─┐
PromptClock  (pure, fake time)                                    ├─► PrompterSession (@MainActor, state machine, generation)
VoiceActivityDetector (pure)                                      │      │ owns: clock, engine?, follower?, countdown, keep-awake
AudioLevelSource (protocol)  ◄── AVAudioEngine impl (R2)         ─┤      ▼
SpeechSource     (protocol)  ◄── SFSpeechRecognizer impl (R3)    ─┘   NotchViewModel.prompter (published) ──► holdsOpen
PrompterLibrary (store)  ◄── PrompterFileIO (protocol, atomic, debounced)           │
PrompterSettings (typed, clamped)  ◄── Defaults (protocol)                          ▼
PrompterFeature (switch) ── gates tab, hot keys, settings rows, all of the above   PrompterTab / PrompterStage (SwiftUI)
```

Rules the structure enforces: the session is created only when the switch is on and owns no UI; views observe it; the controller's rebuild of the panel never touches it; every deferred closure carries the session generation.

## File structure

**Created (`Sources/IslaKit/`):**
- `Prompter/PromptScript.swift` — tokenizer, words, cues, non-speech tokens, direction, offsets, UTF-16 conversion, paragraph breaks
- `Prompter/PromptClock.swift` — Classic/Voice progress, speed, dt cap
- `Prompter/PrompterSession.swift` — state machine, generations, countdown, auto-close, keep-awake, page advance
- `Prompter/PrompterLibrary.swift` — scripts and pages, limits, corrupt-file policy; `PrompterFileIO` seam; `DebouncedWriter`
- `Prompter/PrompterSettings.swift` — typed keys, clamp on load, `Defaults` seam; `PrompterFeature` (the switch)
- `Prompter/PromptMatcher.swift` (R3), `Prompter/VoiceActivityDetector.swift` (R2), `Prompter/AudioLevelSource.swift` (R2), `Prompter/SpeechSource.swift` (R3), `Prompter/SpeechLocales.swift` (R3), `Prompter/ScriptImport.swift`, `Prompter/ZipEntryReader.swift` (R4)
- `UI/PrompterTab.swift`, `UI/PrompterStage.swift`, `UI/PrompterFlowLayout.swift`, `UI/PrompterEditor.swift`

**Modified:** `Model/NotchViewModel.swift` (Tab, visible tabs, `holdsOpen`, session publisher), `Model/PrivacyMode.swift` (section), `Notch/NotchController.swift` (start/stop, hooks for lock, sleep, display change, keep-awake lease), `App/HotKeys.swift`, `App/AppDelegate.swift` (conditional registration, wiring), `UI/NotchContentView.swift` (rail and body switch), `UI/SettingsPane.swift` (section), `UI/WelcomePane.swift` (legend), `UI/Theme.swift` (stage tokens if any are missing), `Resources/{en,ru}.lproj/*.strings`, `Scripts/bundle.sh` (R2/R3 plist keys), `Resources/Isla.entitlements` (R2), `Scripts/test-*.sh`, `THIRD_PARTY_NOTICES.md` (D6), `docs/plans/2026-08-18-dynamic-island-parity-design.md` (dated amendment), `checklist.md`, `docs/release-checklist.md`.

**Created tests (`Tests/IslaKitTests/`):** `PrompterScriptTests`, `PrompterClockTests`, `PrompterSessionTests`, `PrompterStoreTests`, `PrompterSettingsTests`, `PrompterGatingTests`, `PrompterHoldTests`, `PrompterStageRenderTests`, `PrompterAccessibilityTests`, `PrompterTabLayoutTests` (R1); `VoiceActivityTests`, `PrompterAudioTests` (R2); `PrompterMatcherTests`, `PrompterSpeechFollowerTests`, `SpeechLocaleTests` (R3); `PrompterImportTests`, `ZipEntryReaderTests` (R4).

## Delegation (token discipline)

Per the working agreement: nothing runs on Fable except the driver; every `Agent` call names model and effort. **Opus, high** (judgement across files, silent-wrongness risk): T2, T4, T6, T8, T13, T17. **Sonnet, medium** (spelled out, verifiable by running): T1, T3, T5, T9, T10, T12, T14, T15, T16. The design pass (T7) and the final adversarial review are driver-level. Haiku does not edit, review or gate. Review: `codex exec review --base main` (second family) plus an Opus refutation pass over the diff; default to "not proven" when uncertain. Fan-out only for the review, on a small slice first.

---

## Release 0 — decisions and paper (docs only)

- [x] **T0 (driver).** After the owner answers D1: add the dated **Reinstated** amendment under "Notes and Teleprompter" in the design doc (leave the Withdrawn text), a `checklist.md` entry listing the new capabilities (Prompter switch off by default; display-awake assertion; later: microphone, Speech, Apple processing, all off), and the Textream MIT notice to `THIRD_PARTY_NOTICES.md` if D6 is yes. Commit `docs: the prompter is reinstated as an optional feature, off by default`.

## Release 1 — Prompter core, Classic mode (no permissions, no entitlement)

Done when: switch off means absent (tested); with it on, a script can be written, a session runs in Classic mode on the island with pages, cues, RTL and CJK, survives focus changes, display changes and tab changes, pauses on lock and sleep, and ends cleanly; `./scripts/check` is green; the owner has run the manual list in spec 18.2 items 1 (partly: capture matrix), 2, 3, 6, 7, 8.

- [x] **T1 (Sonnet/medium) `PromptScript`.** Test first: `PrompterScriptTests` — collapse and CJK split (including 3000-303F), cue rule (closed pair, `[]`, unclosed, stray, adjacent, embedded, multi-word), non-speech tokens, direction (leading cue ignored), paragraph breaks (blank line only), offsets and `NSRange` round trip with emoji, combining marks, surrogate pairs, content hash. Port the cases in research note section 11. Done: all pass; no `Foundation`-only file imports AppKit.
- [x] **T2 (Opus/high) `PromptClock` and `PrompterSession`.** Test first with a fake clock: dt cap 0.25 s, speed range, pause/resume, end reached, countdown 0/1/3/5, auto-close cancelled when progress changes, next-page rebuild, every row of the spec 7.1 table, generation: a closure scheduled by session A does nothing after session B starts (the Start/Stop/Start within 0.4 s test). The session takes `now`, a timer factory and a keep-awake lease as injected dependencies. Done: spec 8.1 and 8.6 and 7.1/7.2 satisfied by tests.
- [x] **T3 (Sonnet/medium) `PrompterLibrary`.** Test first: round trip, atomic write, debounce flush, version 1 schema, unknown higher version read-only, unreadable/undecodable file is never overwritten and is copied to `library.corrupt-<ts>.json`, read-only file, size limits (200 pages, 1,000,000 characters, 500 scripts), duplicate titles. Create the small `DebouncedWriter`. `PrompterFileIO` seam so no test touches Application Support.
- [x] **T4 (Opus/high) switch, settings, hot keys.** Test first: `PrompterGatingTests` (off ⇒ no tab, no hot-key registration, no library read, no timers/observers/engines created, no `prompter.*` key written but the switch itself), `PrompterSettingsTests` (clamp on load, NaN and infinity ⇒ default, unknown enum ⇒ default, wrong type ⇒ default), `HotKeyTests` updates (new actions have unique defaults, are registered only while enabled, are rebindable and clearable). `HotKeyCenter` learns a "feature enabled" predicate per action. Done: toggling the switch registers and unregisters live.
- [x] **T5 (Sonnet/medium) tab plumbing.** `Tab.prompter`, a `visibleTabs(prompterEnabled:)` function used by the rail, `WelcomePane` legend and `NotchGeometry.railIconHeight`; `needsKeyboard`; `PrivacyMode.Section.prompter` with its cover row; rewrite `TabContractTests` to the two configurations; `NotchMetricsTests` for six icons (at least 20 pt on the smallest notch body). Keep `Tab.retiredSymbols` honest for the chosen glyph.
- [x] **T6 (Opus/high) the hold seam.** Test first: `PrompterHoldTests` — `holdsOpen` true while the session is running, paused or finished; false after Stop; pointer departure, outside click, another app's activation and a Space change do not end a session; ending a pin does not end a session; a session does not extend a pin; lock and sleep pause with the right reason and do not resume; a display change keeps the session; commanded start routes through `admitsCommandedOpen`; start retires the Welcome pane; mirrored display produces the arm-then-confirm step; keep-awake lease begins and ends on every path. Then wire `NotchController.startPrompter/stopPrompter/togglePrompter`, the `NSWorkspace` and screen-parameter observers, and the lease. Done: behavior holds without a pointer (`DI_OPEN_PANEL`-style verification is the owner's).
- [x] **T7 (driver, with the `apple-design` skill) design pass.** Mockups in `.pen` or throwaway SwiftUI previews for the tab and the stage at 480, 560 and 620 pt, both languages, light and dark backgrounds, Reduce Motion/Transparency/Increase Contrast; token additions proposed, not hand-mixed values. Output: a short design note appended to this plan, owner sees it before T8/T9 are built. This is the "Apple built it" bar the owner set.
- [x] **T8 (Opus/high) `PrompterStage` and layout.** Test first: `PrompterStageRenderTests` (word states, cue styling, RTL alignment, divider dots, column width, font fallback with OpenDyslexic absent), scroll-target unit tests (centered and near-top targets; forward-only rule; one armed backward update; manual-scroll resume position; end clearance above the control row; re-anchor by offset after width change), a performance test (100,000-word page lays out and scrolls inside a stated frame budget with culling), accessibility value and labels. Layout cache keyed by content hash. Wheel handling through the existing `ScrollWheelWatch`.
- [x] **T9 (Sonnet/medium) settings section, strings, glossary.** Every string in `en` and `ru`; sample script in both; `LocalizationGlossaryTests` entries; `Scripts/test-localizations.sh` green; settings rows with `disabledReason` where a row depends on another.
- [x] **T10 (Sonnet/medium) tab UI.** Script row, page chips, editor (reuse the Translate editor's key handling and `textInputRect` I-beam), control row, empty state, status chip tied to `hideFromCapture`, library-unreadable inline alert. `PrompterTabLayoutTests`.
- [x] **T11 (driver) integrate, run the gate, install, relaunch, prove with `pgrep`.**
- [x] **T12 (Sonnet/medium) docs and scripts.** `test-branding.sh` bans `textream`; `test-provenance.sh` extension if D6; `checklist.md` and `docs/release-checklist.md` updated; README feature line.
- [x] **T13 (Opus/high + Codex) adversarial review.** `codex exec review --base main` plus an Opus pass told to refute: session identity, hold seam, switch-off absence, library never overwriting, per-event failure surface, forward-only scrolling, memory (`NotchMemoryTests` extended: a session start and stop leaks nothing). Findings fixed or recorded with a reason.
- [ ] **T-V1 (owner) hardware validation**, spec 18.2 list; results into `checklist.md` with the Mac model and macOS version.

## Release 2 — Voice-Activated (microphone; needs D2)

Done when: a Developer ID build shows the microphone prompt on first Voice start, never earlier; the microphone is live only while running; Classic still needs nothing.

- [ ] **T14 (Sonnet/medium) `VoiceActivityDetector` and audio helpers.** Port the detector (0.012, 0.04, 2 frames, 0.75 s), the RMS meter (`min(rms * 5, 1)`, 20 Hz gate, 30-entry ring), `speechCaptureFormat` (mono Float32 at the hardware rate) and buffer size (`max(1024, rate / 40)`). Tests: Textream's cases (`:990`, `:1001`, `:1062`, `:1161`) plus 48/96/192 kHz and 8-channel formats built without hardware.
- [ ] **T15 (Sonnet/medium) `AudioLevelSource` implementation.** A fresh `AVAudioEngine` per session, tap, device selection by UID with the 1 s configuration-change suppression, route-change restart with one 0.5 s retry, teardown order from spec 8.7, `NSLock`-guarded request swap not needed here (no request). Behind the protocol; the fake drives all session tests. No test touches the real implementation.
- [ ] **T16 (Sonnet/medium) permission flow and packaging.** `AVCaptureDevice` status/request on first Voice Start; denied/restricted/revoked ⇒ inline alert with System Settings deep link (`x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone`); always re-check on Resume. Add `NSMicrophoneUsageDescription` to `bundle.sh`'s plist and to both `InfoPlist.strings`; add `com.apple.security.device.audio-input` to `Isla.entitlements` with the file's explanatory comment style; extend `test-identity.sh`, `test-package.sh`, `test-localizations.sh`. Voice mode in the tab and stage (waveform, "Mic is silent" status); faster/slower hot keys.
- [ ] **T17 (Opus/high) session integration and review.** `paused(silence)` is internal; mic released on every pause path; generation covers permission callbacks arriving after Stop. Adversarial review as T13. Owner validates on a Developer ID build with built-in mic, USB interface and AirPods (spec 18.2 item 4, Voice only).

## Release 3 — Word Tracking (speech; needs D2, D3)

**Gate (D3):** the Terminal probe ran on 2026-10-11: `en-US` is on-device, `ru-RU` and the other locales tried are not, `uz` and `kk` have no recognizer. Do not start until the owner confirms they present in a language with an on-device model (US English today; Russian after the Dictation model is installed and the probe is rerun in Terminal, outside the agent sandbox, whose own reading was wrong). Otherwise Follow would exist only behind the Apple-processing opt-in: do not build it.

Done when: Russian and English scripts follow a reader through a 20-minute read, including a mic change and the 55 s restarts, with Apple processing off unless the user turned it on; Follow is disabled with a reason for unsupported languages (Uzbek, Kazakh).

- [ ] **T18 (Sonnet/medium) `PromptMatcher`.** Port the iOS matcher and the tests listed in research section 11; add the changes in spec 8.4 (per-word folding, apostrophe/modifier-letter removal, ё/е, bounded window) with tests for each, the 40 gaps the research note lists, and the 1,000,000-character cost budget. Pure, no I/O.
- [ ] **T19 (Opus/high) `SpeechSource` and the follower.** Protocol plus the real `SFSpeechRecognizer` implementation; fake-driven tests for the 55 s soft restart, codes 1110/216, backoff `min(n * 0.5, 1.5)`, 10 retries, exhaustion stops the engine, unavailable-recognizer retry, jump anchor (`anchor.count - 24`), 0.3 s stale window, 500-character restart, route change, recognizer nil ⇒ permanent failure, stale-generation callbacks, contextual strings in reading order. `requiresOnDeviceRecognition` policy per D3.
- [ ] **T20 (Sonnet/medium) locales and language suggestion.** Supported/closest locale scoring, unsupported-language reason, `NLLanguageRecognizer` suggestion with the thresholds in spec section 9. Tests with an injected supported-locale list (including a list without `uz`).
- [ ] **T21 (Sonnet/medium) packaging and UI.** `NSSpeechRecognitionUsageDescription` (en, ru), the Apple-processing switch (default off), last-spoken-words line, Follow in the picker with its disabled reasons.
- [ ] **T22 (Opus/high + Codex) review.** Adversarial pass on privacy (nothing leaves the Mac unless the user opted in), hot-mic paths, retry loops, and the matcher's monotonicity. Owner validation: spec 18.2 items 4, 5, 6.

## Release 4 — Import and reach

- [ ] **T23 (Sonnet/medium) text and `.textream`.** Encoding detection, `---` page split, JSON array import and export, drag onto the tab, arm-then-confirm before replacing unsaved edits.
- [ ] **T24 (Opus/high) `ZipEntryReader` and `.pptx` notes.** Central-directory reader over `Compression`, entries by name only, limits (5,000 entries, 5 MB part, 100 MB archive, 10 s), slide order from `presentation.xml` relationships with filename fallback, `XMLParser` with external entities off and CDATA handled. Fixtures including a zip bomb, deeply nested XML, an entity-expansion document, a truncated archive, and a deck with no notes. No `Process`.
- [ ] **T25 (Sonnet/medium) Shortcuts.** An `AppIntent` "Start Prompter" gated by the switch; `IslaIntents` metadata check in `test-package.sh`.

## Release 5 — optional, later

External or Sidecar display prompter with mirror axes (horizontal, vertical, both) for glass rigs: its own spec amendment, window class and geometry tests. Networked features only after a separate security design (spec section 17).

---

## Risks

| Risk | Mitigation |
|---|---|
| `sharingType = .none` does not hide the panel from some capture apps on this macOS | Never claim it; the validation matrix writes the truth into the tab's help; the chip shows the setting, not the outcome |
| Follow unavailable for the owner's language | Said before Start; Classic and Voice are the product for Uzbek; do not build release 3 first |
| On-device recognition models absent | Follow unavailable with a path to Keyboard > Dictation, or the opt-in switch; measure outside the sandbox before promising |
| The panel gets rebuilt under a live session | Session state lives in the model; a hold test and a rebuild test |
| Hot-key registry change regresses the existing three keys | `HotKeyTests` extended before the change; the three keep their defaults |
| Tab contract change hides a real regression | Both configurations asserted; the default configuration is exactly the old five |
| Six rail icons crowd small notch bodies | Computed height asserted; fall back to the shorter ceiling the formula already allows |
| Textream-derived code and the attribution rule | D6 decided before T18; the provenance check enforces whichever is chosen |
| Cost of review fan-out | Review once per release, on the release diff, small slice first; no parallel agents on one host |

## Definition of ready

D1–D7 are resolved (spec section 19), so T0 and releases 1 and 2 are ready on the owner's "go". Release 3 additionally waits on the D3 gate above. The Textream notice (D6) lands in T0, before any derived code exists.

## T7 design note (2026-10-12, driver; binds T8, T9, T10)

The stage is the lyrics page's sibling: it owns the whole body, the rail is gone, the type is the system face, and every value below is a token or a function of the existing contrast ramp, never a hand-mixed number. White opacities are measured over black, the island's backdrop, with `Theme.contrast` as `ContrastRampTests` does (0.40 gives 3.7:1, 0.50 gives 5.28:1, 0.55 gives 6.27:1, 0.75 gives 11.45:1).

**Word ladder (replaces the figures in spec 10.1 where they differ).** Textream dims the active word to 0.6 and the spoken words to 0.3. Both fail as reading text, and a current word dimmer than the words ahead of it points the eye backwards.
- Unread: 1.00 of the highlight colour. Current: 1.00, plus a 2 pt underline in the highlight colour (underline, not weight, so the line never reflows as the word changes). Read: 0.40 normally, 0.55 with Increase Contrast (3.7:1 and 6.27:1, both over the 3:1 non-text floor, because a spoken word may still be glanced at).
- Timer modes draw uniformly at the unread value; no read or current distinction, as in the spec.
- Highlight colour is `prompter.tint`; white is the default and the only value that is certain to clear contrast on every backdrop. Non-white tints are measured against the stage background in `PrompterStageRenderTests` at 3:1 minimum and any that fails is lightened until it passes.

**Cue ladder.** A cue is a note to the speaker, so it never competes with the script and never drops under the floor. It is italic, one opacity per brightness whatever its state: dim 0.45 (4.0:1), low 0.55, medium 0.70, bright 0.90; Increase Contrast adds 0.15, capped at 1.00. This replaces the unread/read pairs of spec 10.1, which made the unread cue 0.2 (1.9:1), unreadable.

**Type.** System face (`.system`, never `.largeTitle`-style semantic styles, as `Theme.tracking(forSize:)` explains), medium weight, sizes from `PrompterFontSize` (18, 22, 26, 32), tracking from `Theme.tracking(forSize:)`, line spacing 8 pt. Serif, mono and OpenDyslexic come from the family setting; OpenDyslexic absent falls back to the rounded system face, silently, with the option annotated "not installed" in Settings.

**Layout at the standard 208 pt body.** The physical notch row keeps its place. Below it the text column (default 360 pt, 280 to 560, never wider than the body less 24 pt margins), centered under the camera, with `ScrollEdgeFade` at top and bottom (5 percent; the one primitive, not a second gradient). Under the text a 24 pt control row: page chip ("2 / 5"), play or pause, slower, faster, and a stop control that is the only red-free destructive action (it ends a session, nothing is lost, so no confirmation). Controls are 24 pt hit targets with `secondaryOpacity`, brightening to full on pointer-down per the Apple Design response rule. The elapsed time (optional) sits in the right wing of the notch row at `tertiaryOpacity`; the status chip ("Hidden from screen sharing" or "Visible in screen sharing", tied to `hideFromCapture`) sits in the left wing at the same level, and neither is tappable.

**Mirrored or shared display question.** Inline, in the stage's body, never an alert: one line of text ("Your display is being shared. Start anyway?") and an arm-then-confirm control ("Start Anyway") built on `ConfirmationArming`, with Cancel beside it. It replaces the text column only while pending.

**Motion.** Pane in uses `Theme.paneIn`; scroll, Follow and timer modes use the spec 10.3 curves; Reduce Motion replaces every move with an immediate one. Springs are critically damped, nothing overshoots, because there is no gesture momentum here. A manual scroll hands control back when the wheel stops (spec 8.5); the resume position is the line where the wheel stopped, not the old target.

**The tab (T10).** Script row with title and a disclosure for the library; page chips; an editor reusing Translate's key handling and I-beam rect; one primary "Start" button that becomes "Resume" when a session is paused; empty state with a single sentence and a "Add a script" control. Everything on `glassSurface`, labels at `tertiaryOpacity` or above.

**Not decided here, left to the owner's hardware pass:** whether 208 pt shows enough lines at the 32 pt size (expect two to three) and whether the highlight underline needs to be heavier at distance. Both are tokens (`PrompterStageStyle`), not structure.
