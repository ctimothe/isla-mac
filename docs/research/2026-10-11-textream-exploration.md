# Textream exploration

Date: 2026-10-11. Input to `docs/specs/prompter.md` and `docs/plans/2026-10-11-prompter-plan.md`.

Textream is an open-source teleprompter (github.com/f/textream, MIT, Copyright (c) 2026 Fatih Kadir Akin), read at commit `2c02f3e` (v1.7.1, 2026-09-07, 174 commits). It shows a script in a Dynamic Island-shaped overlay below the notch and follows the speaker three ways: word tracking (speech recognition highlights each word as it is said), classic (constant-speed scroll) and voice-activated (scrolls while the microphone hears speech). This note records what it does, what its fix history teaches, what it gets wrong, and what was measured on this Mac. It changes nothing in Isla.

## Method and trust

Six read-only Haiku scouts read disjoint slices of a local clone (overlay windows; speech engine; rendering and editor; settings; integrations and entitlements; the iOS matcher and its 85 tests). The driver then read the load-bearing parts itself, because scout summaries drop detail. Tags below: **[verified]** means the driver read the source or ran the command; **[scout]** means a scout reported it with a `file:line` and nothing contradicted it. Paths are relative to the Textream repository root; the Mac target is `Textream/Textream/` (abbreviated `T/`), the iOS target `Textream/TextreamiOS/` (`iOS/`).

Not read: the iOS camera and recording stack (out of scope for Isla), `TextreamService.swift` beyond the scouts' excerpts, the Xcode project beyond build settings. The commit history was read in full for fix commits.

## 1. Product behavior

| Area | What Textream does |
|---|---|
| Guidance modes | Word Tracking (default; mic + Speech), Classic (timer; no permissions), Voice-Activated (scrolls while the mic hears speech; mic only, no Speech) `T/NotchSettings.swift:286-297` [scout] |
| Surfaces | Pinned to notch (default), floating window (resizable, 280 to 500 wide, follow-cursor, glass), fullscreen on any display, separate external/Sidecar display (teleprompter or mirrored), remote browser view, director mode (remote editing) |
| Script | Pages (one per slide or section); `[bracketed]` text is a cue: shown dim and italic, skipped by speech matching; optional paragraph dividers; per-script font family (Sans, Serif, Mono, OpenDyslexic), size (XS..XL), highlight colour (6), cue colour, cue brightness (4) |
| Controls on the overlay | waveform, last spoken words (word tracking), page button (long-press = page picker), pause (classic) or mic toggle, stop; drag handle resizes height 100..400; Esc stops |
| Reading position | Centered (active line in the middle) or Near Top (previous line stays visible) |
| Pages | Auto-next-page with countdown 0/1/3/5 s; "Done!" card; word tracking auto-dismisses 1 s after the end, timer modes stay up until stopped (`cb4a10b`) |
| Input | Editor, `.textream` files, `.pptx` presenter notes import, macOS Service "Read in Textream", `textream://read?text=` URL, dictation into the editor, Director/Remote |
| Privacy claim | "Hide from Screen Sharing" (default on): `sharingType = .none` on every overlay window, read at window creation only `T/NotchOverlayController.swift:277,323,356,394` [verified] |
| Keep awake | Optional (default off): `ProcessInfo.beginActivity([.userInitiated, .idleSystemSleepDisabled, .idleDisplaySleepDisabled])` while a session shows `T/NotchOverlayController.swift:504` [verified] |

## 2. Overlay windows

- Class `PrompterPanel: NSPanel`, `canBecomeKey = true`, style `[.borderless, .nonactivatingPanel]`, **level `.screenSaver`**, collection `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]` (pinned) [verified for level, sharing, ignoresMouse].
- The notch is **not detected**. The pinned panel is `notchWidth` wide (setting, default 340, 310..500) and anchored `x = screen.midX - w/2`, `y = screen.maxY - (menuBarHeight + textAreaHeight)` where `menuBarHeight = frame.maxY - visibleFrame.maxY`; the collapsed shape is a hard-coded 200x37 `T/NotchOverlayController.swift:232-261,710-711` [scout]. Isla's notch geometry is far more careful; nothing here should be ported.
- Open animation: shape grows with `easeOut(0.4)`, content fades in at +0.35 s with `easeOut(0.25)`; close is `easeIn(0.15)` content, then `easeIn(0.3)` shape, window removed at +0.4 s. No Reduce Motion handling in the overlay [scout].
- Follow-mouse display (pinned): 0.3 s timer moves the panel to the display under the cursor. Follow-cursor window: 60 Hz timer, offset 8, edge margin 5, `ignoresMouseEvents = true`, separate stop-button window.
- No handler for display changes, sleep/wake or lock anywhere in the repo (grep for `didChangeScreenParameters`, `didWake`, `willSleep`, `screensDidSleep` found nothing) [scout].
- Esc: a **local** key monitor (`addLocalMonitorForEvents`), installed per overlay. It consumes Esc and ends the session. No global hot keys exist in the app.
- `applicationShouldTerminate` cancels an Apple-Event quit from another process while the overlay shows (`805882a`) [scout].

## 3. Speech engine

All from `T/SpeechRecognizer.swift` (1119 lines) unless noted; [verified] marks lines the driver grepped.

- **Audio:** a fresh `AVAudioEngine` per session; tap on bus 0 with the hardware sample rate. More than one channel gives a mono Float32 tap format **at the hardware sample rate**; asking for another rate raises an uncatchable AVFAudio exception (fix `7b082fd`, `fcaa54c`). Tap buffer `max(1024, sampleRate/40)` frames. Waveform updated at 20 Hz from RMS of the first channel: `level = min(rms*5, 1)`; ring of 30 levels.
- **Mic choice:** `selectedMicUID` set on the engine's audio unit via `kAudioOutputUnitProperty_CurrentDevice`, then `AudioUnitUninitialize/Initialize`; configuration-change notifications are suppressed for 1.0 s afterwards. A missing device silently falls back to the system default.
- **Speech:** `SFSpeechRecognizer(locale:)`; a nil recognizer (unsupported locale) is a permanent failure. `shouldReportPartialResults = true`, `taskHint = .dictation`, `contextualStrings` = unique lowercased letter/digit words of 5+ characters from the unread text, first 50 of an unordered `Set` [verified]. **`requiresOnDeviceRecognition` is never set** [verified by grep across `T/`], so audio may go to Apple. `isFinal` is never examined.
- **Task lifetime:** pre-emptive soft restart every **55 s** (`Timer`, repeats) swapping the request under an `NSLock` while the engine keeps running, so no audio gap (`29b203e`) [verified]. Expected-timeout error codes **1110** and **216** restart immediately, uncounted [verified]. Other errors retry up to **10** times with delay `min(n*0.5, 1.5)` s; a transcript resets the counter; exhaustion calls `failListening` and stops the engine. An unavailable recognizer retries the same way instead of going deaf (`5f4f94f`, observed with a USB mic renegotiating its sample rate 100 ms after start).
- **Jumps** (tap on a word): the task keeps running; the transcript so far becomes an anchor prefix, trimmed by its surviving common prefix minus 24 characters; results within **0.3 s** of the jump are dropped; a jump of more than **500** characters, or a dead engine, restarts the task so `contextualStrings` is rebuilt; `retryCount` is not reset by jumps (`79bbc47`, `de4e891`) [verified].
- **Permissions:** `AVCaptureDevice.authorizationStatus(.audio)` then `requestAccess`; Speech is requested only in word tracking. Denied/restricted fails with a message and opens `x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone` or `...Privacy_SpeechRecognition`. A denial in the `.notDetermined` branch does not open Settings (inconsistent).
- **Voice-activated** needs no recognizer: `VoiceActivityDetector` thresholds are activation 0.012, immediate 0.04, 2 frames, hangover 0.75 s on a 20 Hz level feed [verified, `iOS/Speech/VoiceActivityDetector.swift:95-128`; the Mac copy is `T/VoiceActivityDetector.swift`].

## 4. Matching algorithm (the heart of word tracking)

Textream has two copies: `T/SpeechRecognizer.swift` (macOS, inline) and `iOS/Speech/PromptMatcher.swift` (iOS, a pure struct with 85 tests around it). The iOS one is the cleaner base; its `shouldCommit` and `bestOffset` are copied from the Mac one. [verified: the driver read all 280 lines of `PromptMatcher.swift` and the 25 lines of commit rules.]

```
match(transcript):                       # progress is a Character offset into the collapsed script
  if transcript empty or matchStart >= N: return recognized
  c = charLevel(transcript)              # relative to matchStart
  w = wordLevel(transcript)              # relative to matchStart
  best = |c-w| <= 20 ? (c+w)/2 : max(c,w)
  raw  = min(matchStart + best, N)
  cand = advancePastAnnotations(raw)
  if cand <= recognized: return recognized            # monotonic
  recent.append(cand); keep last 3
  confirmed = #{p in recent : |p-cand| <= 10} >= 2
  commit if min(c,w) > 0 or cand > raw or confirmed or cand - recognized <= 15
```

- `charLevel`: lowercase source, normalise spoken (`lowercased`, keep letters, digits, whitespace); equal characters advance both; on mismatch look up to **5** ahead in the spoken stream, then up to 5 ahead in the source, else drop one spoken character; `[` jumps to the next `]`; non-alphanumeric source characters are skipped without moving the "last good" index; the tail loop consumes trailing brackets and punctuation. Returns the last good source index.
- `wordLevel`: split source on single spaces, spoken via the tokenizer; annotation words (`[`..`]` spans, or tokens with no letter or digit) are skipped and counted; equal-or-fuzzy words advance both; mismatch searches up to **5** spoken words ahead, then up to 5 source words ahead (adding skipped lengths), else consumes the spoken word.
- `isFuzzyMatch(a, b)` (letters/digits only): equal; shorter >= 3 and one is a prefix of the other; shorter >= 3 and shared prefix >= max(3, shorter*3/5); then Levenshtein: shorter <= 2 exact only, <= 4 distance 1, <= 8 distance 2, else distance <= max/3. The `contains` clause was removed in `29b203e` because "and" matched "demand".
- **No word count before commit:** gates are character distances. **No digit-to-word conversion, no diacritic folding, no apostrophe handling beyond dropping non-alphanumerics.**
- Quirk: shared-prefix rule makes `hello` match `helpx` (shorter 5, shared 3). Worth a test and a decision.

## 5. Script model and rendering

- `splitTextIntoWords`: newline becomes a space, split on whitespace, a token containing CJK scalars is split to one word per character (ranges: 4E00-9FFF, 3400-4DBF, 20000-2A6DF, F900-FAFF, 3040-309F, 30A0-30FF, AC00-D7AF); the script is the words joined by single spaces. All progress offsets index this **collapsed** string.
- Annotations: a token starting `[` is an annotation if a later token contains `]`; everything through the closing token is one. An unclosed `[` stays readable. Emoji or punctuation-only tokens are annotations too. The iOS editor styles `[...]` spans but not `[]`, while its speech ranges include `[]` (tests at `iOS Tests:783` and `:853` disagree) [verified by the scout's test catalogue].
- Direction: first strong letter outside brackets decides RTL or LTR (ranges 0590..08FF, FB1D..FDFF, FE70..FEFF, 10800..10FFF, 1E800..1EEFF; the Mac list is slightly different).
- Rendering: one SwiftUI `Text` per word in a hand-built flow layout; per-word state unread / current / read (underline on the current word); colours `highlight.opacity(0.6)` for current, `0.3` once read; cues italic at the cue opacities; culling with a 400 pt buffer; word midY reported through a preference key for scrolling and tap-to-jump. Line spacing 8 pt (2 pt for fonts whose line height exceeds 1.5x size); paragraph extra spacing 14 pt with three 3 pt dots at 0.16 white.
- Scrolling: centered tracking keeps the active word at 50% of the viewport; smooth/timer modes pin the line 20 pt above the bottom and interpolate between word midYs by the fractional word progress. Tracking only moves text forward (a backward target is ignored unless a tap or manual scroll armed `allowsNextBackwardTrackingUpdate`). Animations: word tracking `easeOut(0.5)`, timer modes `linear(0.06)`, manual offset `easeOut(0.15)`.
- Wheel/trackpad: precise deltas as is, mouse wheel x10; in timer modes scrolling is allowed only while listening and pauses the timer, ending the gesture resumes from the new position; in word tracking it is allowed only while paused; overshoot is damped to 20 %.
- Mask: 5 % gradient fades at the viewport edges.
- Mid-session resize re-anchors tracking after a width change (`8876683`) and live setting changes apply to a running session (`6c2c7d6`).

## 6. Settings (35 keys, all `UserDefaults.standard`, applied on every assignment)

Defaults worth knowing: width 340 (310..500), height 150 (100..400), mode wordTracking, speed 3.0 words/s (0.5..8, step 0.5, timer modes only), font LG = 20 pt (XS 14, SM 16, LG 20, XL 24), reading position centered, paragraph dividers off, last spoken words on, elapsed time on, **keep awake off**, **hide from screen sharing on**, glass opacity 0.15 (0..0.6), transparency amount 0.85 (0.2..0.95), cue brightness dim (unread/read opacity 0.2/0.5, low 0.35/0.6, medium 0.5/0.7, bright 0.8/1.0), colours: yellow (1.0, 0.84, 0.04), green (0.2, 0.84, 0.29), blue (0.31, 0.55, 1.0), pink (1.0, 0.38, 0.57), orange (1.0, 0.62, 0.04), auto-next delay 3 (choices 0/1/3/5), Remote port 7373 and Director port 7575 (WebSocket = port + 1), both servers off. [scout, with the constants at `T/NotchSettings.swift:490-552` partly verified by grep]

Persistence quirks: bools use `object(forKey:) as? Bool ?? default`; enums fall back on an unknown raw value; doubles use `> 0 ? saved : default`, so a saved glass opacity of 0 returns as 0.15; no clamping on load; `Reset All` writes every default through the same `didSet` hooks, so the keep-awake and both server hooks fire.

## 7. Integrations

- **Remote** (read-only mirror): `NWListener` HTTP on 7373, WebSocket on 7374, binds all interfaces, **no authentication, no Origin/Host check, no connection cap**; the full word list is re-sent every 0.1 s to every client. Page JS uses `textContent`, so DOM XSS is not present as written. Mirror toggle per browser in localStorage.
- **Director** (remote editing): HTTP 7575 / WebSocket 7576. A 32-byte token is generated per start and **embedded in the HTML served by the same unauthenticated HTTP port**, so it only stops a client that skips the page; clients must send `{"type":"auth","text":<token>}` first within 5 s; commands `setText`, `updateText` (with `readCharCount`), `stop`; max 5 connections; identical state is not resent (`3b8eabc`, `a1551f7` closed a published advisory).
- **File format:** `.textream` is a bare JSON array of page strings (no version), atomic write. Opening one by double-click or URL skips the unsaved-changes prompt.
- **PowerPoint notes:** copies the `.pptx` to a temp directory, runs `/usr/bin/unzip -o -q`, reads `ppt/notesSlides/notesSlide*.xml` sorted by filename digits, concatenates `a:t` runs per `a:p`, skips `sldNum/sldImg/dt/hdr/ftr` placeholders, drops empty pages and pages that are only an integer. No size limits or timeout; XML parse errors are ignored; CDATA is dropped.
- **URL scheme** `textream://read?text=` starts a session with no confirmation and no length limit. **Service** "Read in Textream" (`NSSendTypes public.utf8-plain-text`).
- **Update checker:** GitHub releases API, once per launch, compares numeric components only; no opt-out except App Store builds.

## 8. Entitlements, permissions, privacy

- Developer ID build signs with exactly one entitlement: `com.apple.security.device.audio-input` [verified]. The App Store target adds sandbox, user-selected files, network client and server.
- Usage strings (generated from build settings) [verified]: microphone "...listen to your speech and highlight words as you read them."; speech "...Microphone audio may be processed by Apple."; local network "...nearby devices view or control your teleprompter over your local network."
- `PrivacyInfo.xcprivacy`: no tracking, no collected data; UserDefaults and system boot time reasons only.
- **Documentation contradicts code:** `SECURITY.md:34` says speech recognition "runs locally"; `docs/privacy.html:236`, the usage string and the code (no `requiresOnDeviceRecognition`) say audio may go to Apple. `SECURITY.md:42` names port 8080; the code uses 7373. `SECURITY.md:49` says the servers have no authentication; Director has a token.

## 9. What the fix history teaches (each is an edge case Isla must cover)

| Commit | Lesson |
|---|---|
| `29b203e` | The speech task silently dies at about 60 s; restart at 55 s while the engine keeps running; loose fuzzy matching ("and" in "demand") made the highlight leap; require agreement before big forward jumps |
| `fcaa54c`, `7b082fd` | Multi-channel USB audio returns no results; downmix, but keep the hardware sample rate or AVFAudio throws an uncatchable exception |
| `5f4f94f`, `de4e891`, `79bbc47` | Transient recognizer unavailability must retry, not go deaf; a jump must not tear the task down; stale results after a jump are discarded; far jumps restart; exhausted retries must stop the engine (no hot mic) |
| `b83e18e` | Bracketed notes must not stall the highlight; commit multi-word phrases; Voice-Activated must not need Speech recognition |
| `cb4a10b` | Timer modes must not dismiss when the scroll ends: speakers finish 10-20 s later |
| `8876683`, `6c2c7d6` | Width changes and live setting changes must re-anchor a running session |
| `75822e2` | Mouse-follow windows must stay inside the screen |
| `ce11831` | RTL scripts need right alignment and layout direction |
| `3970d1a` | CJK has no spaces: split per character |
| `befbdbb` | PPTX import must work without an unrestricted shell |
| `588e6fd`, `805882a`, `a399fc3`, `248f232` | Controls must work while the app is inactive; an outside quit must not end a live session; play starts from the selected page |
| `3b8eabc`, `a1551f7` | Remote control channels need authentication, a connection cap, and rate limits |

## 10. Defects in Textream that Isla must not copy

1. Speech may leave the Mac and the project's own security document says it does not.
2. Director's token is served over the unauthenticated port it protects; no Host/Origin check, so DNS rebinding applies; Remote has no access control at all.
3. `unzip` without entry-path validation, size or time limits; parse errors swallowed.
4. Dismiss-then-show within 0.4 s: the pending teardown closure is not tied to a session, so it tears down the new one. `isDismissing` stays true after the observer-path teardown. The 1 s auto-dismiss is not cancelled if `isDone` flips back.
5. Static layout cache keyed by word count, first word, last word, font and width: editing a middle word keeps the stale layout; the cache is shared by every instance.
6. Editor and dictation code mix UTF-16 and `Character` offsets (emoji, combining marks).
7. Every hard newline draws a paragraph divider although the comment says only blank lines do.
8. `NSScreen.screens[0]` unguarded; no display-change, sleep or lock handling.
9. `DictationManager` restarts on any error at 0.3 s with no limit.
10. Hide-from-screen-share is read at window creation only and the external window never sets it.
11. `lowercased()` is applied to the whole remaining script and indexed by `Character`; Unicode lowercasing can change character counts. The matcher copies the entire unread script on every partial result (O(N) at 5-10 Hz).
12. No Reduce Motion in the overlay, no accessibility labels on the controls, fixed point sizes.
13. `textream://read` and a `.textream` double-click act with no confirmation.
14. Docs say the countdown has Off/On/3/5; the code has 0/1/3/5.

## 11. Test inventory worth porting (iOS `PromptCoreTests.swift`, 85 tests)

Port as-is or adapted: tokenizer collapse and CJK split (`:765`), balanced vs unmatched cues (`:773`), annotation ranges including `[]`, stray `]`, unclosed `[` (`:783`), adjacent and embedded cues (`:793`), UTF-16 safety after emoji (`:804`), whole-cue styling (`:814,853,861,876,922`), matcher cue skip with fuzzy transcript and never-backward (`:960,972`), word-progress round trip (`:981`), VAD activation frames and hangover (`:990`), RMS meter (`:1001,1062`), speaking state from levels (`:1161`), fractional progress (`:1141,1176`), end-of-prompt clearance (`:1200`), reading position (`:1248,1270`), follow-near-camera mapping with annotations, emoji and CJK (`:1293,1341`), tap mapping (`:1419`), animated retarget (`:1464`), speed clamp (`:1892`), language suggestion thresholds, short text and brackets (`:447-532`), RTL direction ignoring leading cue (`:1667`). Not covered by Textream's tests and needed for Isla: `isFuzzyMatch` boundaries, the 500-character jump rule, the 0.3 s stale window, codes 1110/216, retry back-off, the 55 s timer, contextual strings, anchor trimming, repeated phrases, skips beyond 5 words, numbers, diacritics, apostrophes.

## 12. Measured on this Mac (2026-10-11, macOS 27.0.1, probe run inside the agent sandbox)

`SFSpeechRecognizer.supportedLocales()` returns 62 identifiers. **Uzbek (`uz`, `uz-UZ`) and Kazakh (`kk-KZ`) are not supported; no recognizer can be made.** Russian (`ru-RU` only), English (US, GB), Turkish, Arabic, Hebrew, Chinese and Japanese are. `supportsOnDeviceRecognition` returned `false` for every locale tried, so on-device recognition may be unavailable here until the system's on-device models are present. That value came from a process inside the agent sandbox; re-measure in Terminal before relying on it (snippet below). Consequence: with the owner's default locale `uz`, Word Tracking cannot work for Uzbek scripts at all, and Classic and Voice-Activated are the modes that serve them.

```swift
import Speech
for id in ["uz-UZ", "ru-RU", "en-US"] {
    if let r = SFSpeechRecognizer(locale: Locale(identifier: id)) {
        print(id, "onDevice:", r.supportsOnDeviceRecognition, "available:", r.isAvailable)
    } else { print(id, "unsupported") }
}
```

Web check, same day: `NSWindow.sharingType = .none` and ScreenCaptureKit is a known soft spot. Apple Developer Forums thread 808016 reports windows with `NSWindowSharingNone` missing from the initial stream until the capture type is toggled, and Electron's fix excludes such windows explicitly through `SCContentFilter`; Zoom shipped a fix for a flicker in its "auto" capture mode in 5.14.7. Nothing found confirms that macOS 15+ honours `.none` for every capture path. This is why the spec requires a physical test matrix (Zoom, Meet, Teams, QuickTime, OBS) before the feature claims to be hidden from screen sharing.

## 13. Open questions this exploration could not answer

- Whether `sharingType = .none` hides the panel from each capture app on this macOS (needs hardware).
- Whether on-device Speech models exist on the owner's Mac, and for Russian specifically.
- Whether `NSPanel` clicks land on first click when another app is active, at Isla's window level, over a full-screen Keynote or Zoom share.
- The Mac classic-mode timer's driver (`smoothWordProgress`) lives in `TextreamService`/view code the scouts did not read; the iOS controller shows the intended rule: `words/s * elapsed`, `elapsed` capped at 0.25 s, 50 ms tick.
