# Prompter

Status: draft for owner review, 2026-10-11. Nothing here is built. Evidence: `docs/research/2026-10-11-textream-exploration.md`. Execution: `docs/plans/2026-10-11-prompter-plan.md`.

The Prompter is an optional feature that shows a script in the island and moves it along as the speaker reads, so the eyes stay near the camera during a call, a recording or a talk. It is modelled on Textream (MIT, github.com/f/textream) and keeps its behavior where that behavior is sound, and fixes it where Textream's history or code shows it is not. Where this document says **must**, an implementation or a test is non-compliant without it.

## 1. Scope

In: a feature switch (off by default); a Prompter tab to hold and edit scripts; a session that runs on the island in three guidance modes; hot keys; privacy cover; settings; import of plain text, `.textream` and PowerPoint notes; localization (en, ru); accessibility.

Out of the first releases (see section 17): floating window, fullscreen and external-display prompters, the Remote browser view, Director mode, URL scheme, dictation into the editor, camera or recording. They are specified where useful so the decision is informed, and deferred for stated reasons.

## 2. Policy compliance

| Rule (source) | How this spec meets it |
|---|---|
| Removed features stay removed (`CLAUDE.md`) | The Teleprompter and Notes were withdrawn on 2026-08-22 by owner decision; the design doc says they are neither deferred nor hidden. This feature reverses that for a new, optional Prompter. The owner asked for it on 2026-10-11. The design doc gets a dated **Reinstated** amendment under "Notes and Teleprompter" (the Withdrawn text stays); `checklist.md` gets a dated entry; `TabContractTests` is rewritten, not deleted (section 5.1). The old implementation is in git at `57650e0^` (`TeleprompterStore`, `TeleprompterPane`) and is a reference, not a base: it had no speech, no pages, no cues and held the panel through a special tall body. |
| Anything that leaves the machine, touches an account or changes a system setting is recorded in `checklist.md` and defaults off | Prompter switch defaults off. Microphone, Speech and Apple-server processing are separate, each recorded and off until the user acts (section 14). The display-awake assertion is scoped to a running session. |
| Exactly one entitlement unless the owner decides otherwise | Release 1 adds none. Voice modes need `com.apple.security.device.audio-input` (release 2): a product decision (D2). |
| Every user-facing string in en and ru, keys are the English text | Section 15. `Scripts/test-localizations.sh` gates it. |
| `test-branding.sh` bans the former names; MIT attribution of the upstream stays | Extend the script to ban `textream` in `Sources`, `Resources` and the named scripts, exactly as it bans `cyclop`; the notice lives only in `THIRD_PARTY_NOTICES.md` (D6). |
| One failure surface per event (global rules) | Section 14.4 names the surface for each failure. |
| Tokens only, `glassSurface`, critically damped springs, Reduce Motion/Transparency/Contrast from `SystemAppearance` | Section 10.5. |
| Tests never reach a real device (`isla-test-machine-leaks`) | The audio engine and the recognizer sit behind protocols; tests use fakes. No test opens a microphone, a recognizer, or the real `UserDefaults.standard` domain. |
| The window is cut once and never resized | The stage uses the standard body (section 5.2). A taller stage is a separate, later decision (D5). |

## 3. Vocabulary

- **Script**: a titled, ordered list of **pages**. A page is plain text. A script has no other structure.
- **Cue**: bracketed text such as `[smile]` or `[pause]`. Shown, never spoken, never matched.
- **Collapsed text**: the words of a page joined by single spaces. **Offset**: a `Character` index into the collapsed text. Every progress value in the engine is an offset. Conversions to the editor's UTF-16 are explicit (section 6.4).
- **Session**: one run of one script from a start position until it ends. **Stage**: the session's view in the panel.
- **Guidance mode**: Classic, Voice-Activated or Word Tracking (section 8).

## 4. Feature switch

`prompter.enabled`, default false, one row at the top of a new **Prompter** section in Settings with a note: "Show a script in the island and move it along as you read."

When off, the feature must be **absent, not hidden**:

- No Prompter tab, no rail slot, no Welcome legend row.
- Prompter hot keys are not registered (`HotKeyCenter` registers only actions whose feature is on; a key bound while off is free for other apps).
- Settings shows the switch row and its note, nothing else from this section.
- No library file is read at launch, no engine, recognizer, audio object, timer or observer exists, no permission prompt can occur, and no `prompter.*` default is written except the switch itself.
- A test constructs the app model with the switch off and asserts each of the above (`PrompterGatingTests`).

Turning it off while a session runs stops the session first (the same path as Stop), then removes the surfaces. Turning it on shows the tab immediately; it does not select it. Scripts stay on disk across off and on. Removing them is a separate, confirmed action in the tab.

## 5. Surfaces

### 5.1 The tab

A sixth rail tab, `prompter`, placed after Translate in the content group and shown only while the switch is on. The rail already fits six icons (`NotchGeometry.railIconHeight` is written for six: 24 pt icons, 4 pt gaps, rounded down); a test must assert the icon height stays at least 20 pt on the smallest notch body.

Glyph: a system symbol that is not in `Tab.retiredSymbols` and resolves on macOS 15 (candidate `scroll`; the existing "every rail glyph resolves" test decides).

`needsKeyboard` is true for this tab, as for Translate: arriving hands it the keyboard and the editor handles ⌘A/X/C/V/Z through `NotchPanel.sendEvent` exactly as Translate does, including layout-independent key handling (Cyrillic ⌘C was a bug once). Leaving the tab gives the keyboard back.

`TabContractTests` becomes: with the switch off the visible tabs are exactly `clipboard, media, settings, shelf, translate`; with it on they are those plus `prompter`; `PrivacyMode.Section` gains `prompter` and the test lists both configurations. The statement "dropped features are absent entirely" stays true of the default configuration.

Contents of the tab, top to bottom (visual design is the `apple-design` pass in the plan, not specified in points here):

1. **Script row**: the script's title (tap to switch, rename, duplicate, delete after arm-then-confirm, new) and page chips (add, delete after arm-then-confirm if non-empty, reorder by drag, tap to select). A chip shows its number and, when the page has been read this session, a read mark.
2. **Editor**: the page text. Cues in `[brackets]` are styled secondary and italic, including `[]`. Right-to-left text sets the base writing direction (section 6.3). A live count of words and an estimated reading time at the current speed (Classic) are shown as one quiet line.
3. **Control row**: a mode picker (Classic, Voice, Follow), a speed stepper (timer modes), and **Start** (or Resume / Pause / Stop while a session exists). Start is disabled with a stated reason when no page has content ("Nothing to read yet"). A status chip reads "Hidden from screen sharing" or "Visible when sharing" from the existing `hideFromCapture` setting and, when visible, is a button to Settings.
4. **Empty state** on first enable: one sample script (en and ru, with `[smile]` and `[pause]` cues) and a one-line hint. Not re-seeded when emptied (Textream re-seeds on every appearance; that is a bug).

### 5.2 The stage

While a session exists the panel body shows the stage instead of the tab content. It occupies the whole body, the rail is hidden (the lyrics page sets the precedent for a pane that owns the body), and it uses the standard 208 pt body at the user's panel width. Layout: the physical notch row keeps its place; elapsed time (optional) sits on the right wing; below it the text region, then a 24 pt control row. The text column is its own width, centered under the camera: `prompter.columnWidth` 280...560, default 360, never wider than the body less margins. A shorter line is faster to read near the lens, which is the point of the feature.

Controls (always visible; the panel never relies on hover):

| Control | Modes | Action |
|---|---|---|
| Waveform (80x24) | Voice, Follow | Level history, lit up to the progress fraction |
| Status / error text | all | Last three recognized words (Follow, if enabled) or the single current error |
| Page button | pages > 1 | Next page; long-press opens the page picker |
| Play/Pause | Classic, Voice | Toggles the clock |
| Mic toggle | Voice, Follow | Pauses and resumes listening (engine off while paused) |
| Stop | all | Ends the session and returns to the tab |

Tap on a word jumps there (section 8.5). A click anywhere else on the stage does nothing. The stage never takes key status.

### 5.3 Settings section

Under **Prompter**, shown only while the switch is on. Keys all start `prompter.`; each row names its default and range in section 12. Rows: guidance mode default, speed, text size, font, highlight colour, cue colour, cue brightness, reading position, column width, paragraph dividers, last spoken words, elapsed time, keep display awake, auto-next page and its delay, microphone (release 2), speech language and the Apple-server switch (release 3), hot keys (the shared Keyboard Shortcuts section gains the Prompter actions while the switch is on), Cover Prompter Text (privacy), Reset Prompter Settings (does not touch scripts).

### 5.4 Hot keys

`HotKeyAction` gains `prompterToggle` (default ⌃⌥⌘P: start, pause or resume) and `prompterStop` (default ⌃⌥⌘S). Release 2 adds `prompterFaster` and `prompterSlower` (⌃⌥⌘↑ / ⌃⌥⌘↓, 0.5 words/s). Same rules as the existing three: two of ⌘ ⌃ ⌥ required, rebindable, clearable, conflicts reported. Pressing `prompterToggle` with no session starts one on the current script and page; with the panel in any state it opens the panel (pinned, like ⌃⌥⌘L). It refuses over the lock shield and with screens asleep, as `admitsCommandedOpen` already does.

Plain Escape is **never** claimed by a session. A session claiming Esc globally would eat Escape from the app in front, and the realistic use is a Keynote or Zoom presentation where Escape ends a slideshow. Stop is the control, the hot key, or Esc while the panel itself is key (typing in the tab).

## 6. Script model

### 6.1 Tokenizing

`PromptScript` is an immutable value computed once per page text, off the main thread for large pages:

1. Normalize line endings; replace each newline with a space; split on whitespace, dropping empties.
2. A token containing a CJK scalar is split to one word per CJK character. CJK ranges: 4E00-9FFF, 3400-4DBF, 20000-2A6DF, F900-FAFF, 3040-309F, 30A0-30FF, AC00-D7AF, and **3000-303F** (CJK punctuation stays its own word instead of fusing to the previous character as in Textream). Non-CJK runs inside a token stay together.
3. Collapsed text is the words joined by one space. Word `i` has an id and a `Character` range in the collapsed text.

### 6.2 Cues and non-speech tokens

- A **cue** is the span from a `[` to the next `]`, not nested, including the empty `[]`. An unclosed `[` and a stray `]` are ordinary text. Words overlapping a cue are cue words. Editor styling and speech skipping use one function so they cannot disagree (Textream's iOS tests disagree about `[]`).
- A **non-speech token** has no letter or digit (`--`, `...`, `•`, an emoji). It is skipped by matching and advanced over by progress. Unlike Textream it is **not** drawn as a dim italic cue: a dash in a script is not a stage direction.
- Cues are drawn secondary and italic; their opacities follow cue brightness (section 12).

### 6.3 Direction

Base direction comes from the first strong letter outside cues. RTL ranges: 0590-08FF, FB1D-FDFF, FE70-FEFF, 10800-10FFF, 1E800-1EEFF. A page with no strong letter is LTR. The stage sets alignment and layout direction from this; the editor sets `baseWritingDirection`. Mixed-direction lines keep logical word order.

### 6.4 Offsets and ranges

Offsets are `Character` offsets into collapsed text. A helper converts an offset to an `NSRange` in the *original* page text for the editor and back, tested with emoji, combining marks, surrogate pairs and CJK. Nothing else converts. Anything that stores an offset (jump target, resume point) stores it with the page's content hash and drops it if the hash changes.

### 6.5 Paragraph dividers

Only a blank line (one or more empty or whitespace-only lines between two content lines) is a paragraph break, and consecutive blank lines collapse to one. A single newline is a space. With the setting on, a break draws three 3 pt dots at white 0.16 with 14 pt extra spacing above the next line.

## 7. Session

### 7.1 State machine

States: `idle`; `preparing` (permissions, engine warm-up; only for voice modes); `running`; `paused(reason)` with reason one of `user`, `silence` (Voice mode between phrases; not a user-visible pause), `lock`, `sleep`, `interruption` (route change, error awaiting retry), `permission`; `finished` (end reached, waiting for the user, a countdown, or auto-close); `ended`.

| Event | From | To | Notes |
|---|---|---|---|
| Start | idle | preparing, then running | Classic skips preparing. Start begins at the selected page and, if the user placed a position, there |
| Pause / mic off | running | paused(user) | Voice and Follow stop the audio engine, so no hot microphone while paused |
| Resume | paused(user) | running | Follow resumes matching from the recognized offset with a fresh task |
| End reached | running | finished | Section 8.6 |
| Next page | running, finished | running (new page) | Resets progress to 0, rebuilds the script, keeps the engine |
| Stop | any live state | ended | Releases everything; panel returns to the tab |
| Screen lock | running | paused(lock) | Not resumed on unlock |
| Display sleep or system sleep | running | paused(sleep) | Engine torn down; not resumed on wake |
| Audio route change | running | paused(interruption), then running | One bounded retry (section 8.7) |
| Permission revoked | any | paused(permission) | Inline alert; Resume re-checks |
| Switch turned off | any | ended | Before surfaces are removed |
| App quit | any | ended | After a confirmation (section 11.7) |

### 7.2 Identity

Every session has a generation number. Every closure, timer, notification handler, delayed dismissal and countdown that outlives the call that created it must capture the generation and do nothing if it is stale. Textream's teardown closures are not tied to a session and, started within 0.4 s of a new session, tear the new one down; its dismiss flag also stays set after one path and a one-second auto-dismiss survives the state that scheduled it.

### 7.3 Survival

Session state lives in the app model, not in the panel or its views. A display change makes the controller rebuild the panel (the documented path for setting and display changes); the session, its clock and its engine must continue across that and the stage must re-anchor by offset, not by scroll position. Changing tabs in the panel is impossible during a session (the stage owns the body); the rail is hidden.

## 8. Guidance

### 8.1 Classic

Progress is fractional word progress `p`, `0...N`. A 20 Hz timer (50 ms) adds `speed * min(dt, 0.25)` to `p` while `running`, where `dt` is the time since the previous tick and `speed` is words per second. A long stall (sleep, a blocked main thread) cannot jump the text. Range 0.5...8, step 0.5, default 3.0 (a starting value; calibrate on hardware, ordinary speech is about 2 to 2.7 words per second). Speed changes apply to the running session. No microphone, no permission.

### 8.2 Voice-Activated

Classic's clock gated by a speaking flag from a microphone level, with **no speech recognition and no Speech permission**. The engine delivers a mono Float32 tap at the hardware rate; the level is `min(rms(first channel) * 5, 1)` computed at 20 Hz; a `VoiceActivityDetector` turns levels into `isSpeaking` with activation 0.012, immediate-activation 0.04, two consecutive frames, and a 0.75 s hang-over, so the text keeps moving through a breath and stops after the speaker does. Not speaking pauses the clock, not the session (`paused(silence)` is internal and shown only as a dimmed waveform). A muted or silent microphone looks identical to silence; the status line says "Listening" or "Mic is silent" after 10 s of nothing at session start.

### 8.3 Word Tracking

Speech recognition drives progress. Pipeline: tap buffers to a recognition request; partial transcripts to the matcher; the matcher's committed offset becomes the highlight and the scroll target. Release 3 (needs D2 and D3).

### 8.4 Matching (normative)

The matcher is a pure value type (`PromptMatcher`) with no I/O so it can be tested exhaustively. It is Textream's iOS matcher plus these deliberate changes.

```
match(transcript):
  if transcript empty or matchStart >= N: return recognized
  c = charLevel(transcript);  w = wordLevel(transcript)       # both relative to matchStart, over a bounded window
  best = |c - w| <= 20 ? (c + w) / 2 : max(c, w)
  raw  = min(matchStart + best, N)
  cand = advancePastCues(raw)
  if cand <= recognized: return recognized                    # never moves backward
  recent.append(cand); keep the last 3
  confirmed = #{p in recent : |p - cand| <= 10} >= 2
  commit when min(c, w) > 0  or  cand > raw  or  confirmed  or  cand - recognized <= 15
```

Constants (all from Textream, each with a test): resync look-ahead 5 characters or 5 words in each direction; agreement tolerance 20; small step 15; confirmation window 3 within 10; fuzzy words: equal, or both at least 3 and one a prefix of the other, or at least 3 and shared prefix >= max(3, shorter*3/5), else Levenshtein with shorter <= 2 exact only, <= 4 distance 1, <= 8 distance 2, otherwise <= longer/3.

Changes from Textream:

1. **Folding per word, not per script.** Fold with `lowercased()` per word on a precomputed table of folded words with their collapsed-text offsets, so a character whose lowercase has a different `Character` count (for example `İ`) cannot shift every later offset.
2. **Apostrophes and modifier letters.** Before comparing, remove `'`, `` ` ``, U+00B4, U+2018, U+2019, U+02BC and U+02BB from both sides. `isLetter` is true for U+02BB and U+02BC, so without this "oʻzbek" and "o'zbek" never match.
3. **ё and е.** Fold `ё` to `е` on both sides (Russian prose is routinely printed without ё). No other diacritic stripping; the fuzzy tier absorbs a single missing accent in a word of 3 or more letters.
4. **Bounded window.** Only the next 3000 characters after `matchStart` (extended to the end of an open cue) are scanned per result. Textream copies and lowercases the whole unread script for every partial result, which is quadratic over a long script. A test runs a 1,000,000-character script through 1,000 results inside a stated budget.
5. **Known limits, kept and recorded:** spoken numbers against written digits ("twenty" against "20") do not match unless the recognizer returns digits; repeated phrases advance greedily; a skip of more than 5 words resyncs only through the fuzzy tier or a tap. These are documented in the tab's help, not hidden.
6. `hello` matches `helpx` through the shared-prefix clause. Kept for parity; covered by a test so a change is deliberate.

### 8.5 Jumps

A tap on a word, or the end of a manual scroll, jumps. Offset is clamped, moved past a cue, and in Follow mode:

- The recognition task keeps running. The current transcript becomes an **anchor prefix**; later transcripts have the common prefix with the anchor removed, keeping `anchor.count - 24` characters of slack for the recognizer revising earlier words.
- Results arriving within **0.3 s** of the jump are ignored (they were computed against the old position).
- A jump of more than **500** characters, or a jump when the engine is not running, restarts the task so contextual strings are rebuilt for the new region.
- A jump never resets the retry counter (otherwise tapping words could keep a failing loop alive).
- A jump moves progress backward on purpose and arms exactly one backward scroll update.

In timer modes a jump sets `p`; scrolling by wheel or trackpad pauses the clock while the gesture lasts and resumes from the position under the guide when it ends; Classic allows it only while running, Follow only while paused (Textream's rule, kept).

### 8.6 End of script

- **Follow:** finished when the recognized offset reaches N (the tail loops consume trailing punctuation and cues). With a next page and auto-next on, a countdown (0, 1, 3 or 5 s, default 3) advances; with no next page the stage shows "Done" and closes after 1 s, a close that is cancelled if progress changes.
- **Classic and Voice:** at the last word the text stays visible and nothing dismisses; the speaker finishes 10 to 20 s after the scroll does (Textream `cb4a10b`). With auto-next and a following page, the same countdown. Otherwise the session waits for Stop.
- The countdown is cancelled by Stop, a page change, and leaving `finished`. Delay 0 advances on the next main-queue tick.

### 8.7 Engine robustness (Follow and Voice)

- Tap format: hardware sample rate, mono Float32 when the hardware has more than one channel (downmixed by the engine). Requesting a different sample rate raises an exception Swift cannot catch; a test pins the helper that builds the format. Buffer size `max(1024, sampleRate / 40)`.
- Zero sample rate or zero channels: retry as below, then fail with "Audio input is unavailable".
- Recognizer: `SFSpeechRecognizer(locale:)`; nil means the language is unsupported, permanent, no retry. Partial results on; `taskHint` dictation; `contextualStrings` from the unread text (unique words of 5 or more characters, first 50 in reading order, not set order); never `isFinal`-driven.
- **Soft restart every 55 s** without stopping the engine, swapping the request under a lock; expected-timeout errors (codes 1110 and 216) restart immediately and are not counted; other errors retry up to 10 times with delay `min(n * 0.5, 1.5)` s; any transcript resets the count; exhaustion fails, **stops the engine**, and shows the error. An unavailable recognizer retries by the same rule instead of going silent.
- Route or configuration change: restart once with a 0.5 s delay; suppress the notifications Isla itself causes for 1 s after selecting a device.
- Teardown order: invalidate generations, cancel pending restarts and timers, remove observers, end audio, nil the request under the lock, cancel the task, stop the engine, remove the tap, reset the detector.
- Microphone selection (release 2): system default or a device by UID; a missing device falls back to the default and the status line says so (Textream falls back silently).

## 9. Language

The speech locale defaults to the closest supported locale to the system language. Scoring: +200 equal script, +100 region equals the preferred region, +50 region equals the target's. If the system language has no recognizer, Follow is disabled with the reason "Apple's speech recognition does not support <language>", and the picker shows the supported list. **Measured on this Mac: Uzbek and Kazakh have no recognizer** (research note section 12), so for the owner's default locale Follow cannot work and Classic and Voice are the answer; the product must say so rather than fail late.

A script-language suggestion (NaturalLanguage `NLLanguageRecognizer`): the first 6000 characters with cues removed, at least 20 letters, dominant language with confidence >= 0.75, not matching the current locale, a supported locale exists, debounced 2.5 s and re-checked against the same page, text and locale before showing; dismissible per detected language; reset when the page or locale changes. Shown only in Follow mode, as an inline notice in the tab, never auto-applied.

## 10. Stage rendering and scrolling

### 10.1 Words

Each word is in one of three states: **unread**, **current** (the next non-cue, non-speech word not yet fully lit, or a partly lit one), **read**. Colours default to Textream's ladder: unread at the highlight colour, current at 0.6 with an underline, read at 0.3; cues at cue opacity (unread, read) by brightness: dim 0.2/0.5, low 0.35/0.6, medium 0.5/0.7, bright 0.8/1.0. Timer modes draw uniformly (no read/unread distinction) because progress is a smooth fraction. Final values come from the design pass; contrast must meet the existing `ContrastRampTests` floor on the stage background.

### 10.2 Layout

A flow layout over the words (line break when the running width plus the next word exceeds the column width); line height `ceil(ascender - descender + leading)`; line spacing 8 pt, 2 pt for fonts whose line height exceeds 1.5x their size (OpenDyslexic). Layout is cached by a **content hash** of the page text, font, size and column width, per view model, never by word count, first and last word, and never shared across views (Textream's key reuses a stale layout after a middle-word edit). Large pages cull lines outside the viewport plus a 400 pt buffer and report word positions only for rendered lines.

### 10.3 Scroll targets

Centered: the active word's line centers in the text region. Near Top: the active line sits one line below the top with the previous line visible above. Timer modes interpolate between the midpoints of the active and next word by the fractional progress. Motion is **forward only**: a target behind the current offset by more than 1 pt is ignored, unless a tap, a manual scroll end or a page change armed a single backward update (prevents recognizer revisions from bouncing the text). Animations: Follow `easeOut 0.5`, timer modes `linear 0.06`, manual offset `easeOut 0.15`, reading-position change `smooth` over 0.28 s; Reduce Motion replaces every one with an immediate move.

### 10.4 Start and end positions

Start: centered puts the first line at the vertical center minus half a line; near top puts it at the top. End: the last line may reach the anchor, and a floor keeps it above the control row (a test pins the clearance as Textream's does). Manual scroll is clamped to `[-maxDown, maxUp]` with 20 % rubber-band overshoot.

### 10.5 Surface

The stage background is `glassSurface` (never a hand-mixed gradient), 5 % fades at the top and bottom of the text region, Reduce Transparency and Increase Contrast honored live through `SystemAppearance`. Springs critically damped; there is no momentum here, so nothing overshoots.

### 10.6 Live changes

Width, text size, font, column width, reading position, cue brightness and colours apply to a running session. A layout change re-anchors by offset, not by pixel (Textream `8876683`, `6c2c7d6`). Mode and microphone do not change mid-session; their controls are disabled with a stated reason.

## 11. Panel integration

1. **Hold.** `NotchViewModel.holdsOpen` becomes `isPinnedOpen || session.holdsPanel`. A session holds the panel in `running`, `paused` and `finished`. It holds through pointer departure, outside clicks, another app activating, Mission Control and Space changes. `updatePinnedClickMonitor`, `appActivated` and the pin's Escape claim keep reading `isPinnedOpen` only; the session is a separate flag so ending a pin cannot end a session and a session cannot be ended by the pin's rules.
2. **Opening.** Start from the tab, from the hot key or from a Shortcuts intent (release 4) selects the Prompter tab's stage and opens through the same pinned path as `openOnLyrics`. It routes through `admitsCommandedOpen`, so it refuses over the lock shield and with screens asleep.
3. **Lock and sleep.** Pause with the matching reason; never show the stage over the shield; do not resume on unlock or wake. The lock card is unchanged.
4. **Display change.** The panel is rebuilt; the session continues (section 7.3).
5. **Capture hiding.** The stage lives in `NotchPanel`, whose `sharingType` is already driven by the global **Hide from Screen Sharing** setting (default on). The tab shows its state. If it is off when a session starts, the session starts anyway and the chip says "Visible when sharing". Capture hiding is **not** a guarantee: it hides the panel from software capture only when the capture app honors it, never from a hardware mirror. The text on the tab says so and the validation matrix tests it (section 18).
6. **Mirrored or sole external display.** If any active display is in a mirror set (`CGDisplayIsInMirrorSet`, the check `momentsAreQuiet` already makes), starting a session asks once, inline in the tab's control row through the arm-then-confirm control: "Your display is mirrored. People watching the mirror will see your script." Start Anyway arms and confirms; leaving the row cancels. The prompter is exempt from `momentsQuiet`, which suppresses transient moments only.
7. **Quit.** Quit from Settings during a session asks first, through the panel's arm-then-confirm control (`ConfirmationArming` in `Confirmation.swift`; the island has no alert sheets, so every "ask once" in this document means that control, inline). Textream also cancels a quit Apple Event from another process while a session runs (`805882a`); Isla does not: it is `.accessory` with no Dock or menu-bar item to quit from, so an outside quit is a deliberate act, and refusing it would be the surprising behavior.
8. **Keep display awake.** Default on, session-scoped: `ProcessInfo.beginActivity([.userInitiated, .idleSystemSleepDisabled, .idleDisplaySleepDisabled])` while `running` or `paused`, ended in every exit path. Recorded in `checklist.md`.
9. **Welcome and first run.** A commanded start during the first-run welcome retires it via `chooseTab`, like lyrics.
10. **Menu bar, Dock.** None. The activation policy stays `.accessory`.
11. **Window.** The window is not resized. No new window class is introduced in releases 1 to 3.

## 12. Persistence and settings

### 12.1 Library

`~/Library/Application Support/Isla/Prompter/library.json` via `AppPaths.supportFile`: `{"version": 1, "currentScriptID": "...", "scripts": [{"id": "uuid", "title": "...", "updatedAt": "ISO-8601", "pages": ["...", "..."]}]}`. Writes are atomic, debounced 0.5 s, and flushed on session start, when the switch turns off, and at termination. The debounced writer the removed stores used (`DebouncedWrite`) left with them; the plan recreates a small one rather than copying `ShelfStore` or `LocalLyricsLibrary`'s private `persist()` patterns. A file that exists but cannot be read or decoded is **never overwritten**: it is copied to `library.corrupt-<timestamp>.json`, the tab shows an inline alert "Couldn't read your scripts" with Reveal in Finder, and writing stays disabled until the user starts a fresh library (the old `TeleprompterStore` learned this the hard way). Limits: 200 pages per script, 1,000,000 characters per script, 500 scripts. Over a limit, the edit or import is refused with a field error. No migration is needed for version 1; an unknown higher version is read-only.

### 12.2 Settings

All in `UserDefaults.standard`, read through a typed wrapper that clamps on **load** as well as on write, and treats non-finite numbers as the default (a NaN in a hand-edited plist once overflowed the stack in the old store).

| Key | Type | Default | Range / options |
|---|---|---|---|
| `prompter.enabled` | Bool | false | |
| `prompter.mode` | enum | classic | classic, voice, follow |
| `prompter.speed` | Double | 3.0 | 0.5...8, step 0.5 |
| `prompter.fontSize` | enum | lg | xs 18, sm 22, lg 26, xl 32 pt (starting values; tune on hardware) |
| `prompter.fontFamily` | enum | sans | sans, serif, mono, dyslexia (OpenDyslexic, SIL OFL 1.1, license text ships in the bundle) |
| `prompter.highlight` | enum | white | white, yellow, green, blue, pink, orange |
| `prompter.cueColor` | enum | white | same six |
| `prompter.cueBrightness` | enum | dim | dim, low, medium, bright |
| `prompter.readingPosition` | enum | centered | centered, nearTop |
| `prompter.columnWidth` | Double | 360 | 280...560 |
| `prompter.paragraphDividers` | Bool | false | |
| `prompter.showLastSpoken` | Bool | true | |
| `prompter.showElapsed` | Bool | true | |
| `prompter.keepAwake` | Bool | true | |
| `prompter.autoNext` | Bool | false | |
| `prompter.autoNextDelay` | Int | 3 | 0, 1, 3, 5 |
| `prompter.micUID` | String | "" (system default) | release 2 |
| `prompter.speechLocale` | String | closest to system | release 3 |
| `prompter.allowAppleSpeech` | Bool | false | release 3, D3 |
| `prompter.lastDocumentFolder` | bookmark | none | import and export panel memory |

Colours: yellow (1.0, 0.84, 0.04), green (0.2, 0.84, 0.29), blue (0.31, 0.55, 1.0), pink (1.0, 0.38, 0.57), orange (1.0, 0.62, 0.04), through the design tokens, not literal values in views.

## 13. Import and export (release 4)

- **Plain text and Markdown**: one page per file, or split on a line containing only `---`; UTF-8, UTF-16 with BOM and Latin-1 are detected; anything else is refused with the reason.
- **`.textream`**: a bare JSON array of page strings. Import reads it; export writes the same shape, so scripts move between the apps. Opening by drag or Finder asks before replacing an unsaved script (Textream's double-click path skips the prompt).
- **PowerPoint notes (`.pptx`)**: read **in process**, never by launching `unzip`. A small central-directory reader opens the archive, reads only entries named `ppt/notesSlides/notesSlide<N>.xml` (and `ppt/presentation.xml` plus its relationships to order slides by deck order rather than by filename digits), never writes archive entries to disk (so there is no path traversal to defend), and enforces limits: 5,000 entries, 5 MB per XML part, 100 MB archive, 10 s. Parse with `XMLParser`, external entities off, CDATA handled, parse errors reported, namespace-prefix agnostic. Concatenate `a:t` runs per `a:p`, `a:br` as newline, skip placeholders of type `sldNum`, `sldImg`, `dt`, `hdr`, `ftr`. Pages that are empty or only a slide number are dropped, and each kept page remembers its slide number for its chip label. Keynote files are refused with "Export from Keynote to PowerPoint first."
- Nothing is imported silently: the result is shown as a new script the user can discard.

## 14. Permissions, entitlements and privacy

### 14.1 Release 1 (Classic)

No entitlement, no usage string, no prompt. Scripts never leave the Mac and there is no network use.

### 14.2 Release 2 (Voice)

`com.apple.security.device.audio-input` and `NSMicrophoneUsageDescription` (en and ru in `InfoPlist.strings`): "Isla listens to the microphone while the Prompter runs, only to tell when you are speaking. Nothing is recorded or sent anywhere." The prompt appears the first time a voice mode is started by the user, never at launch and never when the switch is flipped. The microphone is live only in `running`; Pause, Stop, lock and sleep release it. `Scripts/test-package.sh` and `test-identity.sh` gain the key; `Isla.entitlements` gains the entitlement with the comment style that file uses; the hardened-runtime build is tested for a working prompt on a Developer ID build (an ad-hoc build behaves differently).

### 14.3 Release 3 (Follow)

`NSSpeechRecognitionUsageDescription`: "Isla uses speech recognition on your Mac to follow your script as you read it. Nothing is sent to Apple unless you allow it in Settings." Policy: `requiresOnDeviceRecognition = true` whenever `supportsOnDeviceRecognition` is true. When the locale has no on-device model, Follow is unavailable with the reason and a path to System Settings > Keyboard > Dictation, **unless** the user turned on `prompter.allowAppleSpeech` ("Let Apple process my speech when this Mac cannot", default off, with a plain note that audio then goes to Apple). Textream does not set the flag and its own documents contradict each other; Isla must not. Measured outside the agent sandbox on 2026-10-11 (research note section 12): US English is on-device on the owner's Mac, Russian is not, so under this policy Follow serves US English out of the box and Russian only after the Dictation model is installed or the user opts in to Apple processing. The sandbox's own reading (false everywhere) was wrong; never trust a recognizer capability read from inside one.

### 14.4 Failure surfaces (one per event)

| Event | Surface |
|---|---|
| Microphone or Speech denied, restricted, or revoked mid-session | Inline alert in the stage control row and the tab's control row (section scope), with "Open System Settings"; no toast |
| Recognizer unavailable and retrying | Status text in the control row; no alert until retries are exhausted, then one inline alert |
| Unsupported speech language | Disabled mode with a reason on the mode picker (field scope) |
| Library unreadable | Inline alert at the top of the tab (section scope) |
| Over a size limit on edit or import | Field error on the editor or the import row |
| Import failure | Toast (action scope), once |
| Session start refused (lock, asleep) | Quiet refusal, same as `admitsCommandedOpen`; a shake only over the shield |

### 14.5 Data

No analytics, no accounts, no network in releases 1 to 4. Scripts are plain files under Application Support; diagnostics (`Diagnostics`) report the switch state and counts, never script text.

## 15. Localization and accessibility

- Every string added in `Resources/en.lproj/Localizable.strings` and `ru.lproj`, plus `InfoPlist.strings` for usage descriptions; keys are the English text; `Scripts/test-localizations.sh` passes. The sample script ships in both languages. Glossary entries (`LocalizationGlossaryTests`): "Prompter" / "Суфлёр", "Script" / "Сценарий", "Cue" / "Ремарка"; the owner approves the Russian terms.
- Stage text is selectable only by assistive technology: the stage exposes the current line as the accessibility value and the progress as a percentage; controls have labels; the waveform is hidden from VoiceOver; Start announces "Prompter started" through `Announcer`; completion announces once. Reduce Motion: no animated scroll. Increase Contrast and Reduce Transparency: honored. The tab is keyboard-operable end to end except where the never-key panel rule applies (Start is also a hot key).
- Dynamic type is not available on the island (fixed panel); the text-size setting is the substitute and the stage's size is independent of other text.
- Right-to-left scripts, CJK and combining marks are tested (section 18).

## 16. Edge cases

Each row is a required behavior with a test or a named manual step. "T" cites Textream.

**Audio and speech**

- E-01 USB interface with 2 or more channels: mono tap at the hardware rate; no results is a bug (T `fcaa54c`).
- E-02 Hardware rate above 48 kHz: no sample-rate mismatch exception (T `7b082fd`); a unit test pins `speechCaptureFormat`.
- E-03 Input reports 0 Hz or 0 channels (device just switched): bounded retry, then "Audio input is unavailable".
- E-04 Mic changes mid-session (AirPods connect, USB unplugged, Bluetooth profile switch 48 kHz to 16 kHz): one restart after 0.5 s, status "Microphone changed", session continues; never a crash.
- E-05 Selected microphone missing: fall back to the default and say so.
- E-06 Recognition task ends near 60 s: soft restart at 55 s with no audio gap and no change in progress (T `29b203e`).
- E-07 Recognizer briefly unavailable after a cancellation or device change: retry, do not go deaf (T `5f4f94f`).
- E-08 Locale has no recognizer: Follow disabled before Start with the reason; no retry loop (T `de4e891`).
- E-09 Retries exhausted: engine stopped, microphone released, one error shown.
- E-10 Jump then silence: no stale transcript commits; the 0.3 s window, the anchor and the 500-character restart hold (T `79bbc47`, `de4e891`).
- E-11 Recognizer revises earlier words after a jump: the anchor's slack keeps post-jump speech and drops the old transcript.
- E-12 Speaker reads fast, skips a clause, adds an ad-lib, repeats a sentence: forward-only, no regression, resync within 5 words or by tap.
- E-13 Fuzzy over-matching ("and"/"demand", "the"/"other"): the minimum-length rules hold (T `29b203e`).
- E-14 Numbers and abbreviations: documented limit; does not stall (a stuck word is passed by the next confirmed phrase).
- E-15 Speech returns apostrophe or modifier-letter variants: folded (section 8.4).
- E-16 Mic permission denied, then granted in System Settings while the app runs: Resume re-checks; no relaunch.
- E-17 Permission prompt for an accessory app appears behind other windows: validated on hardware; the stage shows "Waiting for permission" with a way to re-trigger.
- E-18 Voice mode with a muted or silent mic: status after 10 s, no spurious scrolling.
- E-19 Very quiet or very loud speaker: the thresholds are fixed in release 2; if hardware testing shows they are wrong, a sensitivity setting is added then, not guessed now.

**Script and rendering**

- E-20 Empty script, all pages blank, or whitespace only: Start disabled with a reason; a blank current page jumps to the first non-empty page (T `ContentView:765`).
- E-21 Page with only cues or only punctuation: finishes immediately without hanging; the stage shows it and completes.
- E-22 Unclosed `[`, stray `]`, `[]`, adjacent `[a][b]`, embedded `hello[pause]world`, a cue spanning words `[look at camera]`: one cue rule everywhere (T iOS tests `:773-:804`).
- E-23 Emoji, combining marks, surrogate pairs, flags: offsets convert without drift (section 6.4).
- E-24 Hebrew or Arabic page; mixed RTL and LTR; a leading cue before the first strong letter: direction decided outside cues.
- E-25 Chinese, Japanese, Korean: per-character words; CJK punctuation separate.
- E-26 Page of 100,000 words: tokenization off the main thread, culled layout, matcher windowed; scrolling stays at frame rate; a time budget test.
- E-27 Edit a middle word to a same-length word: layout re-computed (content hash).
- E-28 Panel width, column width or font changes mid-session: re-anchor by offset, text does not jump.
- E-29 Single newline vs blank line: only blank lines draw a divider.
- E-30 Highlight at the very first and last word; progress 0; progress N; clamped everywhere.
- E-31 A dash or bullet token alone on a line: normal style, skipped by matching.
- E-32 Fonts missing (OpenDyslexic not found): rounded system fallback; test with the font absent.
- E-33 Text longer than the column with no spaces (a URL): breaks at the column width, never overflows the panel.

**Session and panel**

- E-34 Start, Stop, Start within 0.4 s: no stale closure from the first affects the second (generation).
- E-35 Stop during preparing: permission prompt result arriving later is ignored.
- E-36 Auto-close scheduled, then progress changes: close cancelled.
- E-37 Countdown running, user presses Stop or changes the page: countdown cancelled; delay 0 behaves.
- E-38 Display change, unplug of the notch display, display scale change during a session: panel rebuilt, session continues, text re-anchored.
- E-39 Lock during a session: paused(lock), mic released; unlock leaves it paused.
- E-40 Sleep or lid close: paused(sleep); wake leaves it paused; the audio engine is rebuilt on Resume.
- E-41 Another app activates (Zoom, Keynote): session unaffected.
- E-42 Pointer leaves the panel: session unaffected.
- E-43 Panel opened with ⌃⌥⌘I during a session: nothing changes (already open).
- E-44 ⌃⌥⌘P with the switch off: key not registered.
- E-45 Switch turned off during a session: session stopped, microphone released, surfaces removed, hot keys unregistered.
- E-46 Quit during a session: confirmation.
- E-47 Full-screen Keynote or a Zoom share in front: the stage still shows (the panel joins all spaces and is full-screen auxiliary); hide-from-capture validated per app.
- E-48 Display mirrored: confirmation before start (section 11.6).
- E-49 A second Isla launched mid-session: `LaunchGuard` makes the newer copy ask the running one to show itself and quit; the running session is untouched (the panel is already open).
- E-50 First click on stage controls while another app is active: lands on the first click (validated on hardware).
- E-51 Welcome pane showing: commanded start retires it.
- E-52 VoiceOver running: ⌃⌥ is VoiceOver's modifier; the known overlap with the existing hot keys is recorded; Prompter keys follow the same rule.

**Files and storage**

- E-53 Library missing: created empty on first write, no alert.
- E-54 Library unreadable, wrong encoding, read-only, volume gone: never overwritten; corrupt copy kept; inline alert; writing disabled until the user chooses a fresh library.
- E-55 Disk full or write failure: logged, inline alert once; in-memory edits kept.
- E-56 Hand-edited plist: NaN, out-of-range, wrong type, unknown enum: defaults, no crash, no feedback loop.
- E-57 Over the size limits: refused with a field error, nothing truncated silently.
- E-58 Import of a missing, huge, malformed or hostile `.pptx` (zip bomb, deeply nested XML, entity expansion, thousands of entries): refused at the limits with a reason; the app stays responsive; parse errors reported.
- E-59 `.textream` with `[]`, a non-array, or non-strings: a clear error; nothing replaced.
- E-60 Duplicate script titles: allowed; identity is the id.

**Hide from capture**

- E-61 `sharingType = .none` is honored differently by capture apps; this is *measured, not assumed* (section 18) and the UI never claims more than the measurement supports.
- E-62 Switching the hide setting during a session: applies live (Isla already re-applies through `applyCaptureExclusion`; a test covers it).

## 17. Out of scope and why

| Item | Reason |
|---|---|
| Floating window, fullscreen prompter, external or Sidecar display, mirror axes | Isla's product is the notch; each is a new window class and a new geometry problem. External display and mirrored output for beam-splitter rigs is a coherent later release with its own design. |
| Remote browser view and Director | A network listener on all interfaces. Textream's version has no access control (Remote) or a token served by the unauthenticated page it protects (Director) and had a published advisory. Isla's rule makes anything networked a separate, default-off release with its own security review; it must bind loopback or require a per-session secret in a URL fragment plus Origin and Host checks, and a connection cap. |
| `isla://read?text=` URL | Any web page could put text on a presenter's screen with no confirmation. If wanted later: confirmation sheet, length cap. |
| macOS Service "Read in Prompter" | A static Services-menu entry appears in every app even when the switch is off, which breaks "absent when off". Revisit with a handler that explains itself, or skip. |
| Dictation into the editor | The system already provides dictation in text fields. |
| Camera, recording | Different product. |
| Update checker | Isla has its own `UpdateCheck`. |
| Sensitivity setting, per-script settings | Add when hardware testing shows the need. |

## 18. Verification

### 18.1 Automated (all through `./scripts/check`)

New test files: `PrompterScriptTests` (tokenizer, cues, direction, offsets, UTF-16, CJK, RTL, dividers), `PrompterMatcherTests` (port of Textream's cases plus the 40 gaps listed in the research note, plus folding, apostrophes, ё, window cost), `PrompterClockTests` (fake clock: dt cap, speed, pause), `VoiceActivityTests`, `PrompterSessionTests` (state machine with fake engine and clock, generations, countdown, auto-close, all table rows), `PrompterSpeechFollowerTests` (fake recognizer and engine: 55 s restart, 1110/216, backoff, exhaustion stops the engine, jump anchor, stale results, route change), `PrompterStoreTests` (round trip, corrupt file, read-only, atomic, limits), `PrompterSettingsTests` (clamp on load, NaN, enum fallback), `PrompterGatingTests` (off means absent), `PrompterHoldTests` (holdsOpen, unaffected by app activation and pointer, lock, sleep), `PrompterStageRenderTests` (word states, cues, RTL, reduce motion, contrast), `PrompterAccessibilityTests`, `PrompterImportTests` (txt, `.textream`, `.pptx` fixtures including hostile ones). Updated: `TabContractTests`, `PrivacyModeTests`, `HotKeyTests`, `NotchMetricsTests` (rail height for six), `AppSurfaceContractTests`, `LocalizationGlossaryTests`. Scripts: `test-branding.sh` (ban `textream`), `test-provenance.sh` (Textream notice present if any code is derived), `test-package.sh` and `test-identity.sh` (usage strings and entitlement from release 2), `test-localizations.sh`.

### 18.2 Manual (a physical notch Mac; record model and macOS version in `checklist.md`)

1. Hide-from-capture matrix: Zoom (window and screen share), Google Meet in Chrome and Safari, Microsoft Teams, QuickTime screen recording, OBS (display and window capture), macOS screenshot and Cmd-Shift-5, an HDMI mirror. For each: is the stage visible to the viewer? Record the result in the tab's help text, not a promise.
2. Full-screen Keynote slideshow and full-screen Zoom share: stage visible to the presenter; Esc in Keynote still ends the slideshow.
3. First click on the stage while another app is active.
4. Speech: Russian and English scripts read at normal, fast and slow pace with a built-in mic, a USB interface and AirPods; unplug mid-read; read past 55 s, 5 min, 20 min.
5. On-device availability for the owner's locales; measure `supportsOnDeviceRecognition` in Terminal.
6. Lock, sleep, lid close, display unplug, and mirror during a session.
7. Visual and motion review against the `apple-design` skill; contrast measured.
8. 100,000-word script scroll at frame rate.

## 19. Decisions

Resolved 2026-10-11. The owner asked for the most optimal choice on each open decision, considering everything, and left it to the driver. Each line records the choice and the reason; the owner can reopen any of them before the task it gates starts.

- **D1. Reverse the 2026-08-22 withdrawal: yes**, as an optional feature that is absent when off. The owner asked for the feature by name, the default configuration still shows exactly the five tabs the withdrawal left, and the design doc gets a dated **Reinstated** amendment with the Withdrawn text left in place (plan T0).
- **D2. Microphone entitlement: yes, in release 2 only.** Release 1 adds none. Voice-Activated needs no Speech permission, so it is the mode that serves the owner's `uz` scripts; this is the release that matters most to them. The entitlement raises no prompt for anyone who never starts a voice session.
- **D3. Speech policy: on-device only**; `prompter.allowAppleSpeech` stays off by default with a plain note that audio then goes to Apple. Follow unavailable for Uzbek and Kazakh is accepted. **Release 3 is gated**: it does not start until the owner says they present in a language that has an on-device model. Reason: it is the largest and riskiest part (matcher, engine, five Opus tasks) and serves none of the owner's default locale. The Terminal probe ran on 2026-10-11 and met the measurement half: `en-US` is on-device, `ru-RU` and every other locale tried are not, and `uz`/`kk` have no recognizer. So the open half is whether the owner presents in US English (or installs the Russian Dictation model and re-runs the probe); without that, Follow would exist only behind the Apple-processing opt-in and should not be built.
- **D4. Placement: sixth tab shown only while the switch is on.** The library and editor need a keyboard pane that Settings is too cramped to hold, and absent-when-off keeps the default five-tab contract.
- **D5. Stage height: standard 208 pt body** for release 1. A taller stage is a geometry change that touches the lock-transition invariants; reopen it only if the hardware reading test in release 1 shows four to five lines is too few.
- **D6. Attribution: add the Textream MIT notice** to `THIRD_PARTY_NOTICES.md` with a provenance check (plan T0 and T12). The matcher and its constants were read from the source, so a clean-room claim could not be defended; the notice costs one paragraph and one grep.
- **D7. Surfaces after the notch**: the external-display prompter stays release 5, optional, and not scheduled until releases 1 and 2 are in use. Remote, Director and the URL scheme never ship in Isla: they need a network listener, which breaks the rule that nothing leaves the machine by default and adds a security surface Textream itself has not secured.
