# Isla — what's not Apple-native yet, and what makes it worth switching to

All paths below are relative to **`/Users/ctimothe/code/projects/production/dynamic-island/.worktrees/dynamic-island-parity`**.

---

## THE VERDICT

**Isla is better engineered than every app it competes with, and a worse product than most of them.** Those are different sentences and both are true.

### Where it already beats the paid apps (verified, not aspirational)

| | Isla | The paid field |
|---|---|---|
| **Media durability** | helper dylib in `/usr/bin/perl` survived the 15.4 MediaRemote lockout; AppleScript is only a fallback | Alcove showed no artwork/title for **6 months** after 15.4 and a reviewer dropped it to 1 star; boring.notch closed its Tahoe Apple Music bug **wontfix** |
| **Display determinism** | `NotchGeometry.current()` refuses `NSScreen.main`, remembers each cutout by `CGDirectDisplayID`; a 2 s watchdog re-applies frame + contentView + hosted frame | boring.notch #174 was a year-long bug; NotchDrop's maintainer publicly **gave up** on multi-display |
| **Focus stealing** | structurally impossible — `canBecomeMain` is permanently `false` | NotchNook has "Prevent Window Focus Stealing" as an **open roadmap item** |
| **Idle cost** | ~0.3 % of a core measured | NotchNook 10–15 %, developer-acknowledged, unfixed; boring.notch 26–41 % from 2,243 leaked `NSTimer`s |
| **Lock screen** | real card above `CGShieldingWindowLevel` with output switching + volume | Alcove markets lock-screen presence as its hardest feat; NotchNook ships a Lock *button* |
| **Karaoke lyrics** | one `LyricSweep` timeline, word-level, click-to-seek, shared by island + lock card | **nobody has this at any price** |
| **Clipboard + translate** | both shipping, both privacy-covered | neither exists in NotchNook, Alcove, or MediaMate |
| **Accessibility** | Reduce Motion / Reduce Transparency / Increase Contrast read live from `NSWorkspace` | no competitor's changelog, README, or settings pane mentions accessibility **once** |
| **Release discipline** | 10 scripted gates in CI | boring.notch: 349 open issues; Atoll: 179 |

### Where it is behind

Not on craft. On **install, discover, retain** — and it loses all three.

1. **It cannot be installed cleanly.** Unsigned DMG; the README teaches `xattr -dr com.apple.quarantine`. A downloaded install *also silently kills the media helper* (quarantined nested dylib is refused by `/usr/bin/perl`), so the one thing Isla is best at fails on the Apple-sanctioned path.
2. **It cannot be discovered.** Zero visible change on first launch — no Dock icon, no menu-bar item, no window, and with nothing playing the island renders `Color.clear` at exactly notch size with zero shadow. The two hotkeys appear in no string in the app.
3. **It does not persist.** No ambient states. `CompactMediaActivity` is `hidden | paused | playing` — the island literally does not exist unless music is playing. No battery, no AirPods, no charging. That is the entire "Live Activity" grammar the category is named after, at zero.
4. **It cannot be updated.** No Sparkle, no appcast, no version check. Every v0.1.0 user is stranded on a build a macOS point release will eventually break.

And four correctness defects that read as "this app is broken" rather than "this app is minimal": a **hard crash** on Mail/Photos drops, a click that opens but cannot close, no Escape on 4 of 5 tabs, and three quarters of the drawn island dead on any external display.

---

## (A) NATIVE GAPS — what stops it feeling like Apple built it

Ranked by how likely a user is to notice, not by how interesting the fix is.

**A1. Dropping a Mail attachment, Photos item, or Safari image kills the app** — blocker / **S**
`Sources/IslaKit/Notch/NotchRootView.swift:229` — `MainActor.assumeIsolated` runs inside `receivePromisedFiles`'s reader block on a background `OperationQueue` (the queue is deliberate, per the comment at :222-226). Verified: the identical pattern SIGTRAPs, exit 133. Reached only via promises — which `:74-76` registers for *on purpose*, naming Mail and Photos.
→ Replace with `Task { @MainActor [weak self] in … }`; capture `self` weakly (today it's strong at :237). Add a `ShelfDropTests` case that invokes the reader from a background queue — nothing tests `performDragOperation` today.

**A2. Three quarters of the island is dead on every external display** — blocker / **S**
`Sources/IslaKit/Notch/NotchGeometry.swift:283` — `collapsedDepth` is `8` on synthetic notches while the pill is *drawn* at `notchSize.height` (24–38 pt, `NotchContentView.swift:227`). `activeRect`, `interactiveRect`, `collapsedHoverRect` and `collapsedIslandRect` all cut from `collapsedDepth`, so clicking or hovering the middle of a visible black pill does nothing. Directly contradicts the app's own shipped invariant (`d160909`, "every point of the compact island opens it").
→ Keep the 8 pt strip for the *empty* band beside the pill (the status-item concern at :273-282 is real there); give the pill's own footprint its full `notchSize.height`. `Tests/IslaKitTests/CompactHitAreaTests.swift:19` passes `collapsedDepth` in as the height and only asserts `.width` — add a height assertion with `isPhysical` forced false.

**A3. The click that opens cannot close, and the pointer never takes the panel back** — major / **S**
Three sites, one behavior: `NotchContentView.swift:119` (`guard !isOpen else { return }`), `NotchController.swift:500` (same guard), and `NotchController.swift:732` — the `if inside, !opensOnHoverEnabled { return }` sits **above** the pin-clear at `:735`, so with Open-on-Hover off (the default) the pointer arriving never clears `isPinnedOpen`. Net: a 620×208 black panel sits over your screen, a second click is swallowed with no acknowledgement, and moving away does nothing.
→ (1) Drop the guard, restrict the open-state hit test to the collapsed notch strip, toggle in `islandClicked()`. (2) Move the pin clear above the early return — the comment at :734-735 already states that intent. (3) Extend `OpenOnClickTests` with a toggle case.

**A4. Escape does nothing on 4 of 5 tabs, and the panel takes no keyboard input at all** — major / **M**
`Sources/IslaKit/Notch/NotchPanel.swift:28` `canBecomeKey` is `acceptsKeyboard`, raised only where `NotchViewModel.swift:32` `needsKeyboard` is true (Translate alone). So `sendEvent`'s Escape branch (`NotchPanel.swift:82-95`) never fires, and Escape is delivered to the frontmost app — cancelling a Finder rename, exiting full screen. No Tab traversal, no Space, no ⌘Q, no focus ring (`Theme.swift:95-97` is documented "focus-free"). `docs/runbook.md:112` asserts the opposite and is wrong.
→ Two parts, do the first now: install a global `.keyDown` monitor beside `pinnedClickMonitor` (`NotchController.swift:558`) closing on keyCode 53 while `holdsOpen`; a passive monitor checking one keycode needs no permission. Then set `acceptsKeyboard = true` for a deliberate open (⌥⌘I / click), add `@FocusState` order rail → pane → footer, `⌘1`…`⌘5` on the rail, and a focus overlay on `NotchButtonStyle`. **This also closes the VoiceOver reachability gap** — but note the audit's stated mechanism is wrong: VoiceOver walks `AXWindows` and doesn't need key status. The real blocker is that a never-activating `.accessory` app is never `AXFocusedApplication` and posts no AX notification when the panel appears. Fix: set `panel.title` + `setAccessibilityTitle`, post `.windowCreated` on open, and KVO `NSWorkspace.shared.isVoiceOverEnabled` (there is **no** `voiceOverStatusDidChangeNotification` on macOS — that name is iOS-only).

**A5. The container morphs; its contents crossfade** — major / **L**
`grep matchedGeometryEffect|@Namespace Sources/` → **0 hits, verified.** The 22 pt cover at `NotchContentView.swift:370` shrinks and fades in place while a *different* 118 pt cover at `MediaPane.swift:203` fades up 120 pt left and 60 pt down. Same album, two objects. This is precisely the thing Apple's island is famous for not doing, and it is the first sentence any reviewer writes.
→ `@Namespace private var island` on `NotchContentView`; shared `matchedGeometryEffect(id: "artwork")` on `compactArtwork` (:335) and `MediaPane.artwork(for:)` (:165), `id: "equalizer"` on both `EqualizerBars` (:380, :398). Hoist the namespace into `MediaPane` as a parameter and lift the artwork out of the `if isOpen` branch so source and destination coexist for one frame — cleanest is one `artworkView` whose frame and radius are driven by `isOpen`. **Do not add `bounce` to `openAnimation`.** A click carries no momentum; `Theme.swift:4-16` states Apple's own rule and `MotionValuesTests` enforces it.

**A6. Play/pause hard-cuts** — polish / **S**
`grep symbolEffect|contentTransition Sources/` → **0 hits, verified.** `MediaPane.swift:341-343` swaps `pause.fill`/`play.fill` bare. The two most-watched pixels in the app are the two least native.
→ `.contentTransition(reduceMotion ? .identity : .symbolEffect(.replace.downUp))` at `MediaPane.swift:342` and its lock-card twin; `.replace` on `ModeToggle.swift:21` and the compact badge glyph at `NotchContentView.swift:359`. macOS 15 target, no availability check.

**A7. Two-hour podcasts render as `120:…`** — major / **S**
`Theme.swift:121-125` never rolls into hours, duplicated verbatim at `LockScreenCard.swift:665-669`. Gutters pinned at 32 pt (`MediaPane.swift:226`, `:304`); measured, "120:45" is 36.11 pt and draws as `120:…`. Every podcast episode.
→ Roll hours in `Theme.formatTime`, **delete** `LockScreenCard.formatTime` and call the shared one (the design doc's "one timeline, one renderer" rule applies to timecodes), and size the gutter `duration >= 3600 ? 52 : 32`.

**A8. Long titles die in an ellipsis while 128 pt of pill sits empty** — major / **M**
`grep marquee Sources/` → nothing. The peek gives the title 111 pt (measured; "Everything In Its Right Place" needs 141 pt) while the right wing holds a 10 pt equalizer pinned trailing in 150 pt of black (`NotchContentView.swift:206-213`).
→ **Rebalance the wings first** — move the artist line into the trailing wing, or raise `NotchMetrics.sneakPeekExtension`. Then one shared `MarqueeText` used by all three sites (`NotchContentView.swift:192`, `MediaPane.swift:110`, `LockScreenCard.swift:157`) with a hard bypass under Reduce Motion.

**A9. Increase Contrast reaches two `strokeBorder` calls and nothing else** — major / **M**
`grep increaseContrast Sources/` → 5 lines: 3 in `SystemAppearance.swift`, 2 in `GlassSurface.swift` (:267, :298). The 0.46-white tertiary stays 0.46, the 0.18-white lyric context lines stay 1.54:1, and CLAUDE.md claims both settings are "honored live". Same edit fixes the non-text contrast: `Theme.swift:88-90` `surface`/`surfaceHover`/`hairline` are 1.14:1 / 1.35:1 / 1.20:1 over black, so the selected tab chip and the empty scrubber track are invisible as shapes (`NotchContentView.swift:576-579`, `MediaPane.swift:234`). Not universal — `ShelfPane.swift:153` and the played scrubber at white 0.9 are fine — but the chrome is.
→ Make `Theme.secondary`/`tertiary`/`hairline`/`surface`/`surfaceHover` functions of `SystemAppearance.shared.increaseContrast`; inject it once at `NotchContentView` via `@EnvironmentObject`; clamp `LyricRow.swift:78`'s falloff floor. Raise `surface` 0.08→0.12 and `surfaceHover` 0.14→0.22 unconditionally, and give the *selected* rail chip its own token + `strokeBorder` (`ShelfPane.swift:157` already does this correctly). Extend `AccessibilityDisplayTests`.

**A10. Nine Settings switches have no name; every clipboard row is "Copy Entry"** — minor / **S**
`SettingsPane.swift:413` `Toggle("", isOn:)` — Voice Control has nothing to match. `ClipboardPane.swift:100-106` combines children then replaces the merged label with a constant, and the ✕ is hover-gated so Delete is unreachable.
→ `Toggle(title, isOn:).labelsHidden()` (the empty string is the cause, not `labelsHidden`). For clipboard: label the row with `item.preview`, move the verb to `.accessibilityAction(named:)`, add a `Remove Entry` action so deleting doesn't need hover. Add `.accessibilityLabel` to the four bare glyph buttons (`TranslatePane.swift:63`, `SpoilerField.swift:178`, `Confirmation.swift:33`, `ShelfPane.swift:186`) and grow them to the repo's **own** 22 pt floor from `ClipboardPane.swift:78` — there is no 28 pt macOS minimum; that number is iOS touch guidance.

**A11. The Panel Width slider destroys and rebuilds the panel once per point** — major / **M**
`SettingsPane.swift:337` calls `refreshGeometry()` → `NotchController.swift:575-598`, which does `orderOut`, `contentView = nil`, `panel = nil`, `viewModel = nil`, `cancellables.removeAll()` and rebuilds. Range 480…620 = up to **140 full teardowns in one drag**, each destroying the `NSHostingView` that owns the `@State` driving the drag.
→ Stop rebuilding for width: the window is already cut to `maximumBodyWidth` and never resized (`NotchGeometry.swift:206-219`), so width only needs `applyActiveRect` + the four `pointer.*Rect` assignments. Add `NotchController.refreshWidth()`. Debounce via the existing `DebouncedWrite` if you want the one-line version.

**A12. Every deadline is wall-clock** — major / **M**
`grep ContinuousClock|SuspendingClock|mach_continuous_time Sources/` → **0 hits.** `MediaController.swift:1119` extrapolates position from `Date()`, so an NTP step jumps the scrubber and the lyric sweep. Worse: `NowPlayingFeed`'s 12 s silence watchdog gates on `Date().timeIntervalSince(lastLineAt)`, and timers don't fire during sleep — so **the first tick after every wake sees hours of silence, kills the media helper and spends a strike** from the three-strike budget that leads to the permanent scripting fallback.
→ `ContinuousClock` for every duration (`MediaController.swift:206, 504-505, 1119`, `NowPlayingFeed.swift:83`, `PointerWatcher`'s dwell/grace). Wall clock only for calendar dates.

**A13. No session or system-sleep handling** — minor / **S**
`NotchController.install()` registers four observers (:47, :54, :66, :81). `grep sessionDidResignActive|willSleep|didWake Sources/` → nothing. Fast user switching leaves a perl helper, an 8 Hz sampler, a 2 s watchdog and a 2 Hz pasteboard poll running for a session nobody is looking at. System sleep (lid closed) is unobserved entirely — see A12.
→ Observe `sessionDidResignActive`/`BecomeActive` → the existing `NotchStores.suspendForIdleScreen`/`resume`. Observe `willSleep`/`didWake` → rebuild geometry on wake. Set `NSSupportsSuddenTermination` true in `Scripts/bundle.sh:68` — the app owns no unsaved document state and currently stalls logout for nothing.

**A14. The island covers a live menu bar and nobody reasoned about it on physical notches** — minor / **M**
The team got this right for *synthetic* notches (`NotchGeometry.swift:273-283`) and never for physical ones, where the pill is **wider than the hole**: a peek widens to `min(notchWidth + 300, bodyWidth)` — up to 560 pt, ~38 % of a 13" menu bar — covering app menu titles and status items and eating clicks for the peek's duration. Peeks fire on every track change and are on by default. An auto-hidden menu bar also slides down *underneath* the panel (`NotchPanel.swift:66`) with nothing detecting the reveal.
→ Cap the peek's claimed `activeRect` to the notch footprint even while the pill is wide (draw wide, claim narrow). Suppress peeks while the menu bar is revealed.

**A15. The copy is not Apple's copy** — minor / **S**
`Resources/en.lproj/Localizable.strings`, 109 keys: `"Remove from Shelf"` vs `"Import Account From Keychain…"` (three title-case spellings, same table); `"No lyrics for this track"` vs `"No words for this track."` (one fact, two vocabularies, two punctuation rules, two surfaces of one feature); `"macOS refused to translate this text."` (Apple never accuses the OS); `"Stored in an owner-only file, because this build is unsigned."` (build internals as UI); `"Clear Everything?"` / `"Quit Isla?"` as **button titles** — a control's title is a verb; `"Selected: %d"` is a debugger label where Finder says "3 items selected". Plus 10 dead keys including two from features removed 2026-08-22, and a duplicate `"Done"` that `plutil -lint` silently collapses.
→ One editorial pass. Then harden `Scripts/test-localizations.sh`: parse keys as a *list* (catch duplicates), scrape `localized("…")`/`Text("…")` from `Sources` and fail on either direction of drift, and compare `%`-specifier order between locales. That gate would have caught the `"%lld pt"` and `"%.2fs"` C-locale readouts (`SettingsPane.swift:68, :96`) too.

**A16. The app icon cannot participate in macOS 26** — minor / **M**
`Resources/AppIcon.icns` is a legacy `.icns` with the squircle **and its drop shadow baked into the bitmap**. No `.icon`, no `.xcassets`, no dark/tinted/clear variants (`find` confirms). On the OS whose Liquid Glass path this app implements, the icon is the one asset that can't. No `Credits.rtf`, no `CFBundleSpokenName` (VoiceOver's pronunciation of "Isla" is genuinely ambiguous), and `NSHumanReadableCopyright` is the string `MIT License` (`Scripts/bundle.sh:72`) — which is what the About panel prints on the copyright line.

**A17. Shelf filenames tail-truncate; clipboard prose middle-truncates** — polish / **S**
The two modes are swapped. `ShelfPane.swift:144` renders "Screenshot 2026-09-03 at…" so every screenshot reads identically; `SpoilerField.swift:166` puts a hole in the middle of copied prose.
→ `.truncationMode(.middle)` on the first, `.tail` on the second. Two one-line changes, no layout consequence.

**A18. The grain tile is upscaled 2× on every Retina display** — polish / **S**
`GlassSurface.swift:139-143` builds a 96 px bitmap and gives it a 96 **pt** `NSImage` size, then tiles it with default interpolation. The one mark the recipe calls "worth more than any amount of tuning the gradients" is a low-pass-filtered mottle.
→ `rep.size = NSSize(side/2, side/2)` and `.interpolation(.none)` at `:128`.

**A19. Lock card pops in and out with no transition; lyrics page yanks 48 pt in 160 ms** — polish / **S**
`LockCardWindow.swift:99` puts a 484×324 window on screen at full opacity in one frame. `LyricsStage.swift:301` borrows the generic 0.16 s ease for a 48 pt travel, so the page motion is *faster* than the 0.25 s word sweep it is supposed to be carrying.
→ `alphaValue` fade in `NSAnimationContext` (alpha doesn't change the frame, so the stretched-snapshot bug the type guards against doesn't apply). Add `Theme.lyricScroll = .spring(response: 0.42, dampingFraction: 0.86)` — a bounce is defensible *here*, the page is carried by the song's momentum.

**A20. Panel content enters and leaves on the same spring as the container** — polish / **S**
`NotchContentView.swift:98` is a symmetric `.transition(.opacity)` resolved against the open spring, so content is visible at partial alpha while the panel is half-height and clipped mid-glyph. The file already ships the correct asymmetric pattern one screen down (`:446-453`, `Theme.paneIn`/`paneOut`) and uses it only for tab swaps — `Theme.swift:22-23` even states the rule.
→ Use `Theme.paneIn`/`paneOut` at `:98` and `:146-156`. Exclude the matched artwork from A5.

**A21. The app is silent, permanently dark, and unscriptable** — polish / **S each**
`grep NSSound|NSBeep Sources/` → **0**. The lock-screen refusal (`RefusalShake`) is visual-only where macOS beeps; haptics fire at two sites and only on Force Touch trackpads. `NotchPanel.swift:141` forces `.darkAqua` on the panel, the 524-line Settings form and the lock card — correct for the island, unexamined for the rest, and inconsistent at the one seam (`orderFrontStandardAboutPanel` renders in the *system* appearance). `Scripts/bundle.sh:59` declares `NSSendTypes` as the legacy `NSStringPboardType` rather than `public.utf8-plain-text`, with no `NSReturnTypes` — so the Translate service can never replace the selection, and may not appear in UTI-only apps.

---

## (B) WORTH-PAYING GAPS — what stops someone leaving a $25 app

**B1. It cannot be installed, and the install path silently breaks the best feature** — blocker / **S in code, $99 + an afternoon in practice**
`Scripts/bundle.sh:113` defaults to ad-hoc; the shipped app is `flags=0x10002(adhoc,runtime)`, `TeamIdentifier=not set`, `spctl` **rejected**, and the DMG is `not signed at all`. Verified independently: a quarantined nested dylib is refused by `/usr/bin/perl` with *"library load disallowed by system policy"* — so a user who takes the System Settings → Open Anyway route gets ~40 s of dead media per launch and then permanent Music/Spotify-only coverage, plus an Apple Events prompt they never asked for, with **no UI anywhere saying so**. `TokenStore.backing` also resolves to `.file` for every shipped user *because* there's no team identity, putting a live Spotify refresh token in plaintext JSON. The README's Control-click advice was removed by Apple in macOS 15 — this app's own minimum OS.
→ `Scripts/release.sh:62-94` **already does the whole sequence correctly** (notarize app → staple → package around the stapled app → sign + notarize DMG → tag). It has never run: `git tag -l` is empty and `docs/releases/` does not exist, so `release.sh:19` aborts on its second check. Create `docs/releases/0.2.0.md`, buy the cert, run the script. Rewrite `README.md:21-34` to "download, drag, open." Add `Scripts/test-gatekeeper.sh` (`spctl -a -vv` + `stapler validate` on both artifacts) after line 94.
**Also verified: the shipped binary is `arm64` only** while `README.md:10` promises Intel. One-line fix in `bundle.sh:28` (`--arch arm64 --arch x86_64`, same for the `clang -dynamiclib`) plus a `lipo` assertion in `test-package.sh`.

**B2. No updater** — blocker / **M** (gated on B1)
`grep -i sparkle|appcast|SUFeed .` → only the `sparkles` SF Symbol. In a category whose defining event is "an OS update kills media detection", every installed copy is permanently stranded.
→ Sparkle 2 (needs a Developer ID signature to be safe), `SUFeedURL`/`SUPublicEDKey` in the `bundle.sh` plist heredoc, one "Check for Updates…" `actionRow` in `SettingsPane`'s Application section, appcast generation in `release.sh` after line 148. **`CFBundleVersion` must stop equalling `CFBundleShortVersionString`** (`bundle.sh:63-64`) — Sparkle compares it.

**B3. First launch produces zero visible change, and there is no way to learn the app exists or to quit it** — blocker / **M**
`.accessory` + `LSUIElement`, and with no track `CompactMediaActivity.swift:36` returns `notchSize` exactly, `NotchContentView.swift:78` zeroes the shadow, and `:153-155` renders `Color.clear`. `grep -i onboard|firstRun|hasLaunched Sources/` → nothing. The hotkeys appear in no user-facing string. `LSUIElement` apps are absent from ⌥⌘Esc, so a user who can't open the panel can't quit it — `docs/runbook.md:82-84` says so outright.
→ `hasCompletedFirstRunKey` in `NotchViewModel`; on first launch open the panel after ~0.8 s to a `WelcomePane` inside the existing 560×208 body (no new window — the 2026-08-25 amendment holds): what the island is, ⌥⌘I / ⌥⌘T rendered as glyphs, "click the island", one Get Started button. Add `applicationShouldHandleReopen` → `controller?.toggle()` and a single-instance guard. Move About/Quit **out** of the `ScrollView` into a pinned footer (`SettingsPane.swift:31, 243-254`) and drop `showsIndicators: false` — Quit is currently the last row of the sixth section of a ~4-screen scroll in a 157 pt viewport.

**B4. The island has no reason to exist when music isn't playing** — major / **L**
`CompactMediaActivity` is three cases, all media. No IOKit, no CoreBluetooth, no AppIntents anywhere. This is *the* identity gap: for most of a workday the app appears not to be running, which is the most common review complaint in the category.
→ Generalize `CompactMediaActivity` into an `IslandActivity` protocol with a priority queue in `NotchViewModel`, re-expressing media as one conformer so the existing pill can't regress. Then ship the three that are **fully public, zero-prompt, zero-entitlement** (all independently verified running unsigned on this Mac):
- **Battery / charging** — `IOPSNotificationCreateRunLoopSource` + `IOPSGetPowerSourceDescription`. ~1 day. Highest delight-per-line in the whole document, and it's NotchNook's #1 unshipped request (21 votes, "Planned").
- **Bluetooth connect/disconnect** — `IOBluetoothDevice.pairedDevices()` / `registerForConnectNotifications:` (confirmed **not** deprecated in the macOS 26 SDK). `AudioOutputs.swift` already classifies AirPods for glyphs; a `kAudioHardwarePropertyDefaultOutputDevice` listener is the free 80 % version.
- **Mic in use, with the app's name** — `kAudioHardwarePropertyProcessObjectList` + `kAudioProcessPropertyBundleID` + `kAudioProcessPropertyIsRunningInput`. **Apple's own orange dot won't tell you who without a click.** This is a feature Apple could plausibly have shipped, no competitor advertises it, and it needs no permission.

**B5. No AirDrop from the shelf** — major / **S**
`grep NSSharingService|AirDrop Sources/` → **0 hits, verified.** MacStories singled out the tray + AirDrop as NotchNook's standout; it's the most-cited "I use this daily" feature in the category and the stated reason people left paid NotchNook for free boring.notch. `ShelfDragSource` already computes `dragURLs(startingAt:)`.
→ `NSSharingServicePicker(items: shelf.dragURLs(...))` anchored on the card, plus Quick Look on space (`QLPreviewPanel`) and rename-in-place. Best return-per-hour in this entire document.

**B6. The scrubber lies on browser video; podcasts get no 15/30 s skip** — major / **S + M**
`NowPlayingFeed.Command` is four codes (`play/pause/next/previous`, `:45`). There is no `canSeek`, so `MediaPane.swift:265` drags and seeks unconditionally — on a session that never advertised seek the bar jumps, sits ~3–4 s, then snaps back. Clicking a lyric line does the same. Separately, a session advertising only skip-intervals gets both arrows dimmed to 0.35 with nothing offered (note: only when the helper *reports* a command set lacking 4/5 — `offers` returns true when `commands` is nil).
→ Add `case seek = 24` (`helper.m:74` already reports it) and publish `canSeek`; render the capsule without gesture/hover/adjustable-action when false, in `MediaPane`, `LockScreenCard.seekBar` and `LyricsStage`. For skip intervals: read the real codes off a live podcast session, carry `preferredIntervals` through `refreshCommands` (`helper.m:172-179`), publish `skipInterval`, render `gobackward.15`/`goforward.30` in the same two slots. Note `handleCommand` sends `cmd` with nil options (`:333-336`) — an interval skip needs an options dict the way `seek` does.

**B7. When the media route dies, the app says "Nothing is playing" over audible audio** — major / **S**
`switchToScriptingFallback()` only `NSLog`s (`MediaController.swift:859`); `feedAvailable` is private and nothing about the route is `@Published`. `helper.m:265` emits `mediaremote-symbols-missing` **specifically** so a symbol rename is visible, and `NowPlayingFeed.swift:358-364` throws that information away. On the day Apple closes the private route, every user concludes the app is broken. Worse: the fallback is **one-way** — `feedAvailable` returns true only in `stop()`, i.e. app termination, so three 12 s silences at login (see A12: one is manufactured by every wake) demote the app permanently.
→ `@Published private(set) var route: MediaRoute { .system, .scriptedOnly, .unavailable }`. Branch `MediaPane.emptyState` on it. Schedule a backed-off probe (5 → 15 → 60 min) out of `switchToScriptingFallback()` and one on `screensDidWake`, skipping only when the failure was `mediaremote-symbols-missing`. **This one change closes four separately-reported findings.**

**B8. The lock screen permits account writes and a system-wide setting change** — major / **S**
`LockScreenCard.swift:191/647` puts the Spotify heart on the locked card; `spotify.toggleSaved` PUTs/DELETEs `/v1/me/tracks`. `:339/415` → `AudioOutputs.select` writes `kAudioHardwarePropertyDefaultOutputDevice` on `kAudioObjectSystemObject` — system-wide, persistent, not restored on unlock. Anyone standing at your locked Mac. Apple's model is that the lock screen is read-and-transport; iOS gates each capability individually.
→ Give `LockScreenCard` an `isLocked: Bool` (default true — `LockCardWindow.present` is the only production caller), return `EmptyView()` from `heart`, drop the output glyph from `footer` and never allow `pane = .output`. Keep transport, scrubber and volume — that's exactly the macOS media-key contract. Pass `isLocked: false` from `DI_LOCK_PREVIEW` and the render tests. Add a `LockedIslandIsInertTests` case asserting no account-mutating control exists.

**B9. Two owners share one SkyLight space and the wrong one destroys it** — major / **S**
`LockScreenPresence.swift:151` holds one `space`; `lift` creates it once and both the notch panel (`NotchController.swift:223`) and the card (`LockCardWindow.swift:98`) land in it. On unlock the card is dismissed **first** (`:269`), and `lower` removes the card, hides, destroys and zeroes — so the panel's own `lower` hits `guard space != 0` and `SLSRemoveWindowsFromSpaces` is never called for it. The class's own comment at :99-102 says that removal is what rebinds the window. No proven symptom (v0.1.0 shipped through manual lock/unlock validation, and `orderFrontRegardless()` evidently recovers it), but it is the exact shape of the "island disappeared after I unlocked" reports the whole category generates.
→ Ref-count: `private var members: Set<Int>`; `lower` destroys only when the set empties. Also lower the outgoing panel in `rebuild()` before discarding it. Delete the dead `lockedLevel` and the three `LockScreenPresenceTests` cases that certify a contract the shipping code abandoned.

**B10. Translate is unusable for anyone outside ru↔en, and mislabels the source** — major / **M**
`Translator.swift:83-86` routes on a Cyrillic-scalar test: no Cyrillic → "you are English, here is Russian." A German user gets Russian under a header reading "ENGLISH", with the model *instructed* it's translating English. And the tab is dark on every Intel Mac and every macOS < 26.
→ Store a target (`Locale.current.language` default), detect the source with `NLLanguageRecognizer`, invert when source == target (that's what the Cyrillic test is actually expressing), surface the target as a `Menu` in the column header, and say "Detect Language" when confidence is low. Update `TranslatorTests:6-11`. **Do not cut the tab** — see the contradiction note below.

**B11. Privacy-consequential switches carry no caption; the Spotify connect flow is a black box** — minor / **S**
`SettingsPane.swift:489` defines `noteRow` ("it states something the user would otherwise have to guess") and calls it **once**. Meanwhile `NotchViewModel.swift:245-249` documents internally that Show Lyrics "sends listening history off the machine" to three services including an unofficial keyless Chinese endpoint. And `SpotifyAccount.beginAuthorization` publishes nothing — cancel at Spotify's page and the row is byte-identical to before.
→ Four `noteRow`s (lyrics, clipboard screenshots, screen-recording, lock screen). Add `authorizationState { idle | waitingForBrowser | exchanging | failed(String) }` and render a `ProgressView` + a Try Again row. Note `guard let clientID else { return }` can never fail — `:103-107` falls back to the non-optional built-in — so that specific silent no-op doesn't exist.

**B12. Empty states are bare glyphs; a failed lyric lookup lies** — minor / **S**
`ShelfPane.swift:73-90` is a dashed rect with a tray glyph and **no `Text` at all**, so the Shelf's core gesture is never stated anywhere in the app. `LyricsStore.swift:485` catches a network failure into the same `.none` state as a catalogue miss, and the retry button lives in `controls`, which only exists in the success branch.
→ One `Text` under each glyph, matching `MediaPane.swift:447-477`'s pattern (which does this correctly and says why). Add `case unreachable` to `LyricsStore.State` and hoist the retry button into `unavailable`. `LockScreenCard.swift:292-295` already distinguishes the causes — copy it.

**B13. Two hardcoded global hotkeys, silently taken from every app** — minor / **M**
⌥⌘I is Web Inspector; ⌥⌘T is Apple's standard Show/Hide Toolbar. `RegisterEventHotKey` claims them before the frontmost app sees them, `GlobalHotKey.swift:82` returns nil on conflict, and `AppDelegate.swift:34-39` never checks. No rebinding UI, no shortcut shown anywhere.
→ A recorder row in Settings (`GlobalHotKey.unregister()` at :86 exists for exactly this and is only used at quit), defaults moved to ⌃⌥⌘I/⌃⌥⌘T, and the nil return surfaced as "⌥⌘I is already in use."

**B14. No display picker; no fullscreen suppression; no App Intents** — minor / **M each**
`NotchGeometry.swift:138-142` always picks the notched display — correct default, but no override for the laptop-under-a-monitor setup. Nothing observes fullscreen, so on a synthetic notch a `bodySize.width × 8` strip eats clicks aimed at a video player's top edge. And `grep AppIntent Sources/` → nothing, so the app is invisible to Shortcuts and Spotlight.
→ Ship the **picker** (built-in / follow the pointer), not all-displays. Observe `didActivateApplicationNotification` + the space change already observed at `:54-60`; add `hideInFullScreen`, defaulting on for synthetic notches. Add `Sources/IslaKit/Intents/` with `OpenIsla`, `Translate(text:)`, `AddToShelf(files:)`, `NowPlaying` and an `AppShortcutsProvider` — **and `SetFocusFilterIntent`**, which is the single most Apple-native integration available here: public, no entitlement, no prompt, and nobody in the category has it.

---

## SEQUENCED PLAN

The order is: **make it installable → make it correct → make it exist → make it worth switching.** Anything else is polish on an app macOS refuses to launch.

### v0.2 — "It installs, and it doesn't lie"
Nothing here is a feature. Everything here is a reason someone deletes the app in the first sixty seconds.

1. **B1** Developer ID + notarization + universal binary + `docs/releases/`. *Everything downstream depends on it: Sparkle needs the signature, TCC grants are keyed to it, the keychain path needs a team identity, and the media helper is Gatekeeper-blocked without it.*
2. **A1** the `assumeIsolated` crash. *A hard crash on an advertised input path.*
3. **A2** `collapsedDepth` on synthetic notches. *Every external-display user thinks the app is broken.*
4. **A3 + A4(part 1)** click-to-close, pin clear, global Escape monitor. *Four reported findings, ~20 lines.*
5. **B7** `MediaRoute` + a fallback exit. *Closes four findings and stops A12's wake bug from being permanent.*
6. **A12/A13** monotonic clocks + `willSleep`/`didWake`/`sessionDidResignActive`. *Ship with #5 — same bug.*
7. **A7** `h:mm:ss` + delete the duplicate formatter. **A17** truncation swap. **B12** empty states. *Hours each.*
8. **B3** first-run welcome + pinned Quit + `applicationShouldHandleReopen`.

### v0.3 — "It feels like Apple built it"
Now the craft is visible to someone who got past the install.

1. **A5** the artwork morph (no bounce). *The single most-noticed native gap.*
2. **A6** symbol replace + **A20** asymmetric content transition + **A19** lock-card fade and lyric spring.
3. **A9** the contrast ramp — Increase Contrast *and* the non-text tokens in one edit.
4. **A4(part 2)** real keyboard operability + the AX window title/notification/`isVoiceOverEnabled` KVO. *These are one job.*
5. **A11** stop rebuilding the panel per slider point.
6. **B9** ref-count the SkyLight space. **B8** make the locked card inert to account and system writes.
7. **A8** rebalance the peek wings, then `MarqueeText`.
8. **A15** the copy pass + the hardened localization gate. **A16** the icon. **A10** the AX labels and 22 pt targets.
9. **B6** `canSeek` (the skip-interval half can slip to v1.0).

### v1.0 — "There is a reason to switch"
Only now does adding capability make sense.

1. **B2** Sparkle + appcast + monotonic `CFBundleVersion`.
2. **B4** the `IslandActivity` queue, then battery/charging → Bluetooth connect → mic-in-use-with-attribution. *In that order: cheapest, most recognizable, most differentiated.*
3. **B5** AirDrop + Quick Look + rename on the shelf.
4. **B14** display picker, fullscreen suppression, App Intents + `SetFocusFilterIntent`.
5. **B10** real language detection in Translate. **B13** rebindable hotkeys. **B11** the `noteRow`s and the Spotify auth states.
6. Surface the output picker that **already exists** in `AudioOutputs.swift` into `MediaPane` — it currently requires locking your Mac to change output. Cheapest "we have more than they do" win left.
7. Publish the idle-CPU number. `Scripts/measure-performance.sh` exists; make it emit an idle figure, gate a regression threshold in CI, and put it in the README next to NotchNook's developer-acknowledged 10–15 %. **That is a marketing claim no competitor can make**, and it costs a day.

---

## TRAPS — do not build these

**Private-API or permission traps:**
- **Volume/brightness/keyboard HUD replacement.** The market's #1 retention feature and the worst trade in this document. Needs a `CGEventTap` on `NX_SYSDEFINED` → **Accessibility TCC**, private `DisplayServices` + `CoreBrightness`, and an unsanctioned suppression of Apple's own HUD. It spends Isla's best genuine advantage — one entitlement, zero launch prompts — to reimplement a surface Apple *just* redesigned in Tahoe. If you want any of it: a CoreAudio-listener volume readout that appears **alongside** the system HUD, no interception.
- **Notification mirroring / incoming calls.** `~/Library/Group Containers/group.com.apple.usernotifications/db2/db` returns `Operation not permitted` on 26.5.2 — it now costs Full Disk Access on top of an undocumented SQLite schema, or an AX scrape of Notification Center. Make it a **stated non-goal in the design doc**, not a gap.
- **Named Focus mode.** `~/Library/DoNotDisturb/DB/Assertions.json` is TCC-protected as of macOS 26 (verified). The legal `INFocusStatusCenter` needs an Apple-approved entitlement and returns a bare `Bool` with no change notification. Do `SetFocusFilterIntent` instead — different API, public, free.
- **Mirroring Apple's Clock timers.** `com.apple.mobiletimerd.plist` already reads `MTTimerStorageMigratedToCoreData = true` — state moved to a live WAL-mode CoreData store one release ago. Ship your own timer or none.
- **AirPods battery %.** Undocumented KVC (`batteryPercentLeft` etc.) — still responds on 26.5.2, but design the UI to *hide* the percentage when the selector vanishes, not show 0 %.

**Design traps — these would cost the native bar, not win it:**
- **Artwork tint / cover bloom on the panel.** The finding's own rationale is "the most-screenshotted thing about them." That's competitor envy. Apple's island is achromatic black in every iOS release including 26, and `LockScreenCard.swift:108-110` already reached the right answer in writing.
- **Giving the panel body a material + a "Panel Style" setting.** `NotchShape`'s concave shoulders exist to melt into a physical black cutout. Translucency destroys the illusion the shape exists to sell — and it adds a knob.
- **A bespoke Text Size picker.** macOS Control Center doesn't scale either. Raise the 13 sites at 9 pt to 10 pt (AppKit's caption floor) and wire Increase Contrast in. Adding a knob to solve an accessibility problem the platform solves differently is the fastest way to look third-party.
- **`Scripts/test-typography.sh` + routing 87 sites through `islandFont`.** A gate protecting a ≤0.35 pt/glyph difference that rests on a premise the audit *disproved* (macOS applies no tracking table on top of `.system(size:)`). Correct fix: **delete** `Theme.tracking(forSize:)` and match the platform. Keep the deliberate uppercase tracking as one shared constant.
- **Scrubber precision falloff, rubber-band, haptic detents; scroll-to-volume.** All iOS affordances. macOS clamps rather than rubber-bands, ships no variable-speed scrub, and `NSHapticFeedbackManager` produces nothing on a Magic Mouse. Only **live seek** survives — and mainly because `LockScreenCard.swift:521-532`'s volume bar already writes live 25 lines away.
- **Re-adding Calendar / Notes / Timer / Mirror, or a widget board.** Violates "removed features stay removed" and `TabContractTests`. The board also invalidates the never-resize invariant that exists because resizing across a lock produced stretched window-server snapshots.
- **"Uninstall Isla and Quit."** macOS's uninstall convention is drag-to-Trash. A self-deleting app that trashes `~/Pictures/Isla` is a foot-gun. Ship a `noteRow` stating where data lives, next to the two clear buttons that already exist.
- **`idle`/`resume` verbs on the media helper; rewriting `PointerWatcher` to be event-driven; Low Power Mode branching; the `NotchController` XL refactor.** All four trade a proven invariant for ~0.1 % of a core or a hazard nobody could find a trigger for. The proportionate fix for the helper is **one line**: give the `NSTimer` at `helper.m:414` a tolerance — the only Apple-guidance miss actually established.

---

## THINGS THE AUDIT CONTRADICTED ITSELF ON — your call, but decide once

- **"Cut Translate, demote Clipboard"** vs. **five market sections naming them as the only capabilities no competitor has at any price.** These cannot both be executed. My read: keep both, fix Translate's language routing (B10), and *lead with them* — the README's "What Isla does" doesn't mention lyrics, translate, or clipboard as differentiators at all.
- **"Move Settings into a small window"** reverses the dated 2026-08-25 amendment that withdrew the window, Dock icon and status item. Don't. Pin the footer instead (B3).
- **The "no Dynamic Type because the window cannot grow" premise** (`Theme.swift:60-65`) is disproven by the app's own geometry: `NotchGeometry.swift:39` still pins `maximumWindow` to 700×444 via `teleprompterBody` for a tab removed 2026-08-22, leaving **192 pt of allocated, transparent window** below the panel. Fix the ghost geometry and the comment together.
- **`CLAUDE.md` is stale about the product it describes.** Lines 15, 63, 115, 191 and 220 still say `DynamicIsland` / `Dynamic Island.app` / `dev.dynamicisland.app`; the code says `Isla` / `com.ctimothe.isla` (`ProductIdentity.swift:4`). Per the repo's own source-of-truth policy the binding doc wins — so fix the doc first, in its own commit.
- **Treat every "best notch apps 2026" comparison as marketing.** notchy.dev, macnotch.io, getseam, brow-app, notchbay and crestnotch all sell competing notch apps; their MediaMate prices contradict MediaMate's own store. No priority in this document rests on them alone.

---

## THE ONE THING

**Get a Developer ID, create `docs/releases/0.2.0.md`, and run `Scripts/release.sh`.**

Not because signing is glamorous, but because it is the only item that is simultaneously:

- **already written** — `Scripts/release.sh:62-94` notarizes the app, staples it, packages the DMG *around the stapled app*, signs and notarizes the image, tags only after success, and rolls the tag back on failure. It is correct and it has never executed once;
- **the gate on four other things** — Sparkle needs the signature to be safe, TCC grants (Accessibility, Downloads) are keyed to it, `TokenStore` moves off plaintext JSON the moment there is a team identity, and a Homebrew cask needs a stable notarized URL;
- **and the thing that is silently breaking the app's single best feature right now.** A user who installs the documented Apple way gets a Gatekeeper-blocked helper dylib, ~40 s of dead media per launch, permanent Music-and-Spotify-only coverage, an unexplained Apple Events prompt, and no message anywhere explaining any of it. Isla's most defensible technical advantage over Alcove and NotchNook — a media path that survived the 15.4 lockout — does not reach a single user who installs it correctly.

Every native-bar item in list (A) is invisible to someone who never gets the app open. Fix the front door, then fix the motion.