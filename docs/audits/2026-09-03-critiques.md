All paths below are under `/Users/ctimothe/code/projects/production/dynamic-island/.worktrees/dynamic-island-parity`.

# Dimensions no auditor was assigned

## 1. Editorial voice — nobody read the copy *as copy*
The i18n audit checked key parity and formatters; nobody applied Apple's writing standards to the 109 English strings in `/Users/ctimothe/.../Resources/en.lproj/Localizable.strings`.

- **Title case is internally inconsistent.** `"Remove from Shelf"` (:34) and `"Back to Player"` (:112) lowercase the short preposition correctly; `"Import Account From Keychain…"` (:106) and `"Hide From Screen Recording"` (:74) capitalize it. Same table, same rule, three spellings.
- **Two names for one thing.** The island says `"No lyrics for this track"` (:118); the lock card says `"No words for this track."` (:143) — one fact, two vocabularies and two punctuation conventions, on two surfaces of the same feature. Same for the output pane: `"Sound Output"` (:135) vs `"Output"` (:147).
- **Terminal punctuation splits on identical message classes.** `"Nothing is playing"` (:37) and :118 have no period; `"Lyrics are switched off in Settings."` (:141), :143, `"No output devices."` (:144) do.
- **Blaming the system.** `"macOS refused to translate this text."` (:71). Apple never personifies or accuses the OS, and never says "refused". `"The translation could not be completed."` (:73) is a passive dead end with no next step.
- **Build internals as user-facing copy.** `"Stored in an owner-only file, because this build is unsigned."` (:108) ships the code-signing state to the user. `"notes.json cannot be read, so nothing is being saved."` (:76) names an on-disk file (and is dead — Notes was removed 2026-08-22).
- **Buttons that ask questions.** `"Clear Everything?"` (:77), `"Delete These Files?"` (:78), `"Quit Isla?"` (:79). A control's title is a verb, not an interrogative; the arming pattern (audited only for its 3 s timeout) puts a question in a slot Apple reserves for an action.
- **`"Selected: %d"`** (:28) is a debugger label; Finder says "3 items selected".
- No `CFBundleSpokenName` in `Scripts/bundle.sh`'s plist — VoiceOver's pronunciation of the product's own name ("Isla" is genuinely ambiguous to TTS) is left to the synthesizer.

## 2. App identity assets — the icon was never opened
The single most-seen Apple-designed asset in any Mac app, and no audit mentions it. `Resources/AppIcon.icns` is a well-formed **legacy** icon: 16/32/128/256/512 @1x/@2x, with the squircle *and its drop shadow baked into the bitmap* on a transparent canvas. There is no Icon Composer `.icon`, no `.xcassets`, no dark/tinted/clear variants anywhere in the tree (`find` for `*.icon`/`*.xcassets`/`*.iconset` returns nothing), and `bundle.sh` only sets `CFBundleIconFile`. On macOS 26 — which this app targets for its Liquid Glass path — every Apple icon carries appearance variants and lets the system own the shape and shadow. Isla's cannot participate. Also absent: `Credits.rtf`, any help book (`NSHelpBookFolder`/`NSHelpBookName`), and a `.VolumeIcon.icns` for the DMG.

## 3. Wall-clock vs monotonic time
Every deadline in the app is `Date()`. `grep` for `ContinuousClock|SuspendingClock|mach_continuous_time|DispatchTime.now` over `Sources/` returns **zero** hits; the only monotonic clock is `CACurrentMediaTime()` inside the equalizer layer (`Sources/IslaKit/UI/Skeleton.swift:207`). Consequences nobody was looking for:

- `/Users/ctimothe/.../Sources/IslaKit/Services/MediaController.swift:1119` extrapolates position as `anchor.position + Date().timeIntervalSince(anchor.at) * playbackRate`. An NTP step or a manual clock change jumps the scrubber and the lyric sweep instantly.
- `/Users/ctimothe/.../Sources/IslaKit/Services/NowPlayingFeed.swift` gates its 12 s silence watchdog on `Date().timeIntervalSince(lastLineAt)` (`silenceTimeout` at :83, checked in `checkForSilence`). Timers do not fire during system sleep, so **the first watchdog tick after every wake sees hours of "silence", terminates the media helper and relaunches it**, spending a strike from the three-strike budget that leads to the permanent scripting fallback. It self-corrects on the next successful publish, but the helper is being killed on every wake for a clock artifact.
- Same class in seek settle (`MediaController.swift:206`, `:504-505`) and in `PointerWatcher`'s dwell/grace windows.

Apple's rule is simple and unimplemented here: wall clock for calendar dates, monotonic for durations.

## 4. Session and power states other than screen sleep
`NotchController.install()` registers exactly four observers (`Sources/IslaKit/Notch/NotchController.swift:47, :54, :66, :81`). `grep` for `sessionDidResignActive|sessionDidBecomeActive|willSleep|didWake|willPowerOff` over `Sources/` returns **nothing**.

- **Fast user switching is unhandled.** Switch users and Isla keeps a `/usr/bin/perl` helper doing a MediaRemote round trip every 2 s, an 8 Hz `NSEvent.mouseLocation` sampler, a 2 s geometry watchdog and a 2 Hz pasteboard poll — for a session nobody is looking at. `NSWorkspace.sessionDidResignActiveNotification` exists precisely for this and `NotchStores.suspendForIdleScreen` is already the right hook.
- **System sleep** (lid closed) is distinct from display sleep and is not observed at all; see the watchdog above.
- **Logout/shutdown.** `NSSupportsSuddenTermination` and `NSSupportsAutomaticTermination` are both `false` (`Scripts/bundle.sh:68-69`) in an app that owns no unsaved document state, so a logout waits on it for nothing.
- Screensaver-without-lock is a fourth state with no handling (`LockScreenPresence` watches lock only).

## 5. Coexistence with the menu bar the island covers
Every audit treated the notch region as unowned space. It isn't — the island draws opaque black over live menu-bar content and takes clicks there. The team reasoned about this carefully for *synthetic* notches (`Sources/IslaKit/Notch/NotchGeometry.swift:273-283`, which is why `collapsedDepth` is 8 pt there) and never for *physical* ones, where the pill is **wider than the hole**:

- On a physical notch `collapsedDepth == notchSize.height` (NotchGeometry.swift:283), so the full menu-bar height is claimed.
- A peek widens the pill to `min(notchWidth + 300, bodyWidth)` (`NotchMetrics.swift:63`, `Sources/IslaKit/Model/CompactMediaActivity.swift:36-43`) — up to 560 pt at the default width, ~38% of a 13" MacBook's menu bar — covering app menu titles on one side and status items on the other, and blocking clicks to both for the peek's duration. Peeks fire on every track change and are on by default.
- Auto-hidden menu bar: the panel is at `CGWindowLevelForKey(.statusWindow) + 1` (`Sources/IslaKit/Notch/NotchPanel.swift:66`), so a revealed menu bar slides down *underneath* the island. Nothing detects the reveal.

## 6. File-system citizenship
- **Regenerable network data is in a backed-up location.** The lyrics cache (500 tracks) is `AppPaths.live.supportFile("lyrics")` — `Sources/IslaKit/Services/LyricsStore.swift:90` — i.e. Application Support, not `~/Library/Caches`. `grep isExcludedFromBackup` over `Sources/` returns **nothing**, so Time Machine backs up every cached lyric and every copy of a dropped file.
- **The app puts folders in the user's Trash.** `AppPaths.pruneDropInbox` calls `fm.trashItem` on UUID-named internal drop folders (`Sources/IslaKit/Services/AppPaths.swift:71`), so a week after any Mail/Photos drag the user finds mystery UUID directories in their Trash from an app with no Dock icon. Internal temp belongs in the temp directory and gets deleted, not recycled into a user-visible bin.
- Credit where due: security-scoped bookmarks are used (`ShelfStore.swift:91, :288`) and every write is `.atomic` — both already right, and both unremarked.

## 7. Drag *feedback* fidelity (the outbound half of drag and drop)
The interaction audit measured the drop target and never looked at what the drag itself looks like. `Sources/IslaKit/UI/ShelfDragSource.swift:60-70` builds each `NSDraggingItem` from `NSWorkspace.shared.icon(forFile: url.path)` — the generic file-*type* icon — at a fixed 48×48 offset by index. The store already holds a real QuickLook preview in `ShelfItem.icon` (`ShelfStore.swift:11-16`) and throws it away at drag time, so a shelf of visually distinct screenshots collapses into a fan of identical PNG icons the instant you grab it. There is no item-count badge, no `imageComponentsProvider` (so nothing animates back on a failed drop), and `setDraggingFrame` uses an origin-relative rect rather than the card's own frame, so the image does not lift from where the pointer grabbed. Finder does all three.

## 8. Feedback modality coverage — the app is silent
`grep NSSound|NSBeep|AudioServicesPlay` over `Sources/` returns **zero** hits. Haptics fire at exactly two sites and only on Force Touch trackpads, so a Magic Mouse or external-keyboard user receives no confirmation at all where the design intends one. The lock-screen refusal (`RefusalShake`) is visual-only, where macOS's convention for a refused input is a beep. And the lock card changes *system output volume* with no feedback tick, while macOS's own volume keys play one when the user has asked for it in Sound settings — a preference nothing here reads.

## 9. Appearance — the app is permanently dark and never asks
`Sources/IslaKit/Notch/NotchPanel.swift:141` forces `NSAppearance(named: .darkAqua)` on the window and every SwiftUI child inherits it. Correct for the island (it must match the cutout), unexamined for the panel body, the 524-line Settings form and the lock card. It is also inconsistent at the one seam: `NSApp.orderFrontStandardAboutPanel` (`SettingsPane.swift:245`) renders in the *system* appearance, so the app's only other surface is light on a light Mac. Nothing observes an appearance change — `Sources/IslaKit/Services/SystemAppearance.swift:35` watches only `accessibilityDisplayOptionsDidChangeNotification`. No auditor rendered the app on a Light-mode Mac, which is most of the install base.

## 10. Presentation and mirroring etiquette, as distinct from capture exclusion
`sharingType = .none` removes the panel from screen *capture*. It does nothing for a mirrored projector or an HDMI-shared display, where the peek still animates over the presentation. Nothing reads Focus / Do Not Disturb, which is the signal macOS itself uses to suppress transient UI while presenting. The most frequently fired transient animation in the product — a peek on every track change, default on — has no "not right now" condition beyond the panel already being open.

## 11. The app is unscriptable, and its Services declaration uses pre-UTI types
System integration audited App Intents; nobody audited the two older halves. `Scripts/bundle.sh:59` declares `NSSendTypes` as `NSStringPboardType` — the legacy pasteboard name, not `public.utf8-plain-text` — which risks the "Translate in Isla" item not appearing in apps that advertise UTIs only. There is no `NSReturnTypes`, so the service can never do the standard thing and replace the selection. And there is no `.sdef` and no `NSAppleScriptEnabled`: the app *sends* Apple Events (its only entitlement) but cannot receive one, which is the inverse of the usual bargain for a Mac utility.

---

**If I had to rank these by how much each moves the two bars:** copy (#1) and the icon (#2) are the cheapest and most visible native-bar wins and are pure craft with zero API risk; monotonic time (#3) and session/power states (#4) are correctness debt that is already costing a helper restart on every wake; menu-bar coexistence (#5) is the one that will generate "this app broke my menu bar" reports on physical notch hardware, which is exactly the audience. #7, #8 and #9 are polish. #10 and #11 are small but are the kind of thing a reviewer names as "not quite a Mac app".

---

## A. Findings that are factually wrong — delete them, don't triage them

These survived into the report with a "corrected:" tail but are still listed as findings. Each one should be struck, not downgraded.

| Finding | Why it's wrong |
|---|---|
| **motion / hover-lift stretched wash** | Refuted three times in its own challenge chain and still present. Verified: `hoverLift` is only in the tree while `!isOpen` (`NotchContentView.swift:92`), and `bodySize` returns `openBodySize` only when `isOpen` (`NotchViewModel.swift:219-221`). SwiftUI freezes a removed subtree at its last layout, so the departing wash is pill-sized and the hardcoded radii 6/9 are the *correct* silhouette. There is no 560×208 box wearing collapsed corners. The residual (a 340 ms fade) is documented deliberate behavior at `NotchController.swift:512-513`. |
| **materials / ambient+key shadow pair** | The standard is invented. Paired ambient+key elevation is Material Design. macOS composites one window-server shadow per window; AppKit and SwiftUI ship no two-layer convention and the HIG defines no elevation scale. `LockScreenCard.swift:124-130`'s conclusion (draw no shadow, let the material define its edge) is closer to Apple than the proposed fix. Only the missing `Theme` token and the menu-bar tail are real, and both are polish. |
| **a11y / 28 pt hit-target floor** | No such macOS floor exists — 44 pt is iOS touch guidance, and Apple's own traffic lights are 12 pt. The repo's actual precedent is 22×22 (`ClipboardPane.swift:78`). The finding invents a standard, then charges the 20 pt lyric buttons, the 26 pt `NotchButtonStyle` default and the 30×24 rail against it. Only the four frame-less glyph buttons (~9–10 pt) are real. |
| **a11y / VoiceOver blocked by `canBecomeKey`** | Wrong mechanism and a nonexistent API. VoiceOver walks `AXWindows` and dispatches `AXPress`; key status is irrelevant. And `voiceOverStatusDidChangeNotification` is iOS-only — it does not exist in the macOS SDK (KVO on `NSWorkspace.shared.isVoiceOverEnabled` is the real one). The gap is real; the diagnosis and the fix are both wrong, and the proposed fix ("make the panel key and force-pin it under VoiceOver") would break the non-activating invariant for no benefit. |
| **materials / "every selection and affordance surface"** | Universal quantifier is false. `ShelfPane.swift:153` fills selected tiles at white 0.18 plus a 1.5 pt white-0.55 border and a checkmark; `MediaPane.swift:238` fills the played scrubber at white 0.9; `SettingsPane.swift:414` is a native `.switch` on the system accent; `LockScreenCard.swift:427` uses `controlAccentColor`. Also: Apple's own dark-mode unemphasized selection sits ~1.8–2.5:1, not 3:1. |
| **a11y / "ten identical off, switch elements"** | Count is 9, and the sibling `Text(title)` at `SettingsPane.swift:409` is its own unignored AX element, so VO alternates name/switch. `labelsHidden()` is not the cause — the empty string in `Toggle("")` is. Real loss is Voice Control name matching only. |
| **a11y / shelf cards "cannot be read, selected, opened or removed"** | `Text(item.name)` at `ShelfPane.swift:137` *is* read, and the `.contextMenu` at `:190-196` is VO-reachable via VO-Shift-M. The parenthetical claiming those literals are unlocalized is flatly wrong — all four keys are in both `.lproj` tables. |
| **materials / lock card "only remedy is an undocumented defaults write"** | `SettingsPane.swift:170` ships a user-facing Card Style → Solid picker that bypasses `glassEffect` for that surface alone, and `LockScreenCard.swift:102` puts a 0.55/r4/y1 shadow on every mark precisely for a bright wallpaper. Also, the quoted domain `dev.dynamicisland.app` is stale — `NotchViewModel.swift:332` says `com.ctimothe.isla`. **CLAUDE.md carries the same stale bundle id; that divergence is itself worth fixing.** |
| **media / podcasts get "two dead grey arrows"** | Conditional, not default. `offers` returns true when `commands` is nil (`NowPlayingFeed.swift:32-34`), so arrows only dim when the helper reads a command set lacking 4/5. And "already deliverable without touching the dylib" is unproven — `handleCommand` sends `cmd` with nil options (`helper.m:333-336`); an interval skip needs an options dict the way `seek` does. |
| **perf / 130 MB spike from `GlassSurface`'s 52 pt light blur** | Named owner is dead code. Verified: `grep "light:\|tint:"` outside `GlassSurface.swift` returns only two tests passing `nil`. All three real call sites (`LyricsStage.swift:336`, `LockScreenCard.swift:105`, `:381`) omit it. The measurement also used `DI_OPEN_LYRICS=1`, which opens the lyrics stage — whose own `blur(radius: 60)` at `LyricsStage.swift:168` is the plausible owner. And "does not return to closed footprint" was never measured on one process. |
| **perf / pointer sampler "runs forever overnight"** | `pointer.stop()` runs on `screensDidSleepNotification` (`NotchController.swift:77`) and both lock branches. The 8 Hz floor exists only while the screen is awake, with `tolerance = interval/2`. |
| **perf / helper "parses a line every 2 s"** | `emitPayload` dedupes behind a 5 s heartbeat (`helper.m:52, 100-108`), so an idle session writes ~1 line per 6 s. Measured cost 0.1 % of a core. |
| **product-shape / "sticky tab, identical whether a file is being dragged"** | Both false. `islandClicked()` calls `vm.select(.media)` at `NotchController.swift:511` and the hover path does the same at `:747` — only ⌥⌘I preserves the last tab. And `onDragEntered` sets `vm.tab = .shelf` before the drop (`:633`). |
| **code-health / glitched notch "sticks for the session"** | `NotchGeometry.decide` (`:113-121`) rescues a zero reading whenever the screen frame is unchanged, which covers plugging in a monitor and closing the lid. And `matches()` includes `isPhysical` (`:201`), so the next clean parameters notification recovers it. |
| **i18n / no `.stringsdict`** | The finding's own evidence proves no live bug — none of the six format keys puts a countable noun after the number. It is a backlog note, not a finding. |

---

## B. Redundant clusters — 9 root causes reported as ~26 findings

Fixing the left column closes everything on the right.

1. **`canBecomeKey` is false outside Translate** (`NotchPanel.swift:28`, `NotchViewModel.swift:32`) → a11y blocker #2, system-integration "⌥⌘I opens a panel that accepts no keyboard", interaction "Escape does not close on four of five tabs", and half of a11y blocker #1. **Four findings, one line.**
2. **The click that opens can't close, and the pin never clears** → motion "click cannot close", interaction "Escape", system-integration "only exit is ⌥⌘I". Same three edits.
3. **`SkyLight` holds one `space` field for two windows** (`LockScreenPresence.swift:151, 194-200`) → lockscreen-privacy `major/S` and code-health `major/S` are verbatim the same bug and the same fix.
4. **`collapsedDepth` = 8 on synthetic notches** (`NotchGeometry.swift:283`) → interaction and code-health, identical.
5. **The media route has no published state** (`MediaController.swift:48, 854, 859`) → media-fidelity "Nothing is playing", media-fidelity "one-way fallback", onboarding "dead media path", distribution "no health surface". One `@Published enum MediaRoute` closes all four.
6. **Increase Contrast reaches only two `strokeBorder` calls** → materials `major/M` and typography `minor/S`. One contrast-aware `Theme` ramp.
7. **Unsigned build** → distribution ×2, lockscreen-privacy (plaintext token is a *consequence*, not a separate finding — `TokenStore.backing` resolves to `.file` only because `TeamIdentifier=not set`), plus five market sections.
8. **No updater** → distribution, system-integration, market ×4.
9. **Dead `tint:`/`light:` parameters** → materials "dead parameters", materials "nothing takes colour from the cover", perf "130 MB spike". One unused parameter, three findings.

Also: **the "no Dynamic Type because the window cannot grow" premise (`Theme.swift:60-65`) is disproven by the code-health finding about the teleprompter ghost geometry** — `NotchGeometry.swift:39` still pins `maximumWindow` to 700×444 for a tab removed 2026-08-22. Same fact, two findings, opposite conclusions.

---

## C. Feature creep dressed as polish — do not build these

**Ranked by how much each would cost the native bar.**

**1. Artwork tint / cover bloom on the panel.** The finding's own stated rationale is *"the cheapest available answer to 'why use this over the $25 app'"* and *"the most-screenshotted thing about them."* That is competitor envy, not Apple. Apple's Dynamic Island is achromatic black in every iOS release including 26. `LockScreenCard.swift:108-110` already reached the correct answer in writing. Building this deletes a documented restraint decision to win a screenshot.

**2. Giving the panel body a material + a "Panel Style" setting.** The shape's entire job is to read as a continuation of a physical black cutout (`NotchShape.swift:3-5` — concave shoulders that melt into the top edge). A translucent body showing wallpaper through it destroys the illusion the shape exists to sell. The proposed fix also adds a knob. Both wrong.

**3. Adding `bounce: 0.15` to `openAnimation`.** This is a rider on an otherwise-correct finding (the `matchedGeometryEffect` morph — verified, grep returns zero hits). `Theme.swift:4-16` states Apple's actual rule from *Designing Fluid Interfaces* and `MotionValuesTests.testNothingWithoutMomentumOvershoots` enforces it. A click carries no momentum. macOS surfaces don't bounce on open. **Ship the morph; drop the bounce.**

**4. A bespoke Text Size setting (Small/Default/Large).** The finding's own evidence says macOS Control Center doesn't scale and macOS 15 has no global Dynamic Type for accessory surfaces. Apple's answer is not a per-app text-size picker — it's honoring the system settings that *do* exist. The restrained fix is: raise the 13 sites at 9 pt to 10 pt (AppKit's caption floor) and wire Increase Contrast into the ramp. Adding a knob to a five-tab panel to solve an accessibility problem the platform solves differently is the fastest way to look like a third-party utility.

**5. `Scripts/test-typography.sh` + routing all ~87 text sites through `islandFont`.** A new release gate protecting a difference the finding *proved* is ≤0.35 pt/glyph and rests on a premise it *proved* is false (macOS applies no tracking table on top of `.system(size:)`). The correct fix is option (a): delete `Theme.tracking(forSize:)` and match the platform exactly. Building a gate around a wrong idea is worse than the wrong idea.

**6. Scrubber precision falloff, rubber-band, and haptic detents.** All three are iOS affordances. macOS ships no variable-speed scrub in AppKit, AVKit or any Apple app; media scrubbers clamp rather than rubber-band; and `NSHapticFeedbackManager` produces *nothing* on a Magic Mouse or any non-Force-Touch pointer, so a detent would be felt by some users and not others. Only live-seek survives — and it survives mainly because `LockScreenCard.swift:521-532`'s volume bar already writes live 25 lines away, so the app contradicts itself.

**7. Scroll-over-notch for volume, and swipe-to-skip.** No Apple macOS surface does this. Menu-bar extras don't take scroll to change system state. This is the competitor grammar (Alcove, MediaMate, DynamicLake), imported wholesale. Swipe-down-to-dismiss on the *expanded* panel has an iOS analogue and is defensible; scroll-to-volume is creep, and the finding concedes it collides with the critically-damped-spring rule.

**8. Volume / brightness / keyboard-backlight HUD replacement.** This is the single largest trade in the report and the report never prices it. It requires a `CGEventTap` on `NX_SYSDEFINED` → **Accessibility TCC**, plus private `DisplayServices` and `CoreBrightness` for brightness, plus an unsanctioned suppression of Apple's own HUD. That spends the app's best *genuine* Apple-native property — one entitlement, zero prompts at launch, exactly one private dependency — to reimplement a surface Apple itself just redesigned in Tahoe. If anything is worth doing here it's a CoreAudio-listener volume readout that appears *alongside* the system HUD, no interception, no Accessibility.

**9. Notification mirroring and incoming-call alerts.** The research proves the route is closed: `~/Library/Group Containers/group.com.apple.usernotifications/db2/db` returns `Operation not permitted` on 26.5.2, so it now costs Full Disk Access on top of an undocumented SQLite schema, or an AX scrape of Notification Center. For an app whose thesis is restraint, this should be a *stated non-goal in the design doc*, not a gap.

**10. Named Focus mode.** Same: `~/Library/DoNotDisturb/DB/Assertions.json` is now TCC-protected, and the legal `INFocusStatusCenter` needs an Apple-approved entitlement and returns only a bool. **Note the contradiction:** `SetFocusFilterIntent` (the mediamate finding) is a *different, public, entitlement-free* API and is the one genuinely Apple-native integration on the whole list. Do that; don't do this.

**11. Mirroring Apple's Clock timers.** `com.apple.mobiletimerd.plist` already reads `MTTimerStorageMigratedToCoreData = true` on this machine — the schema moved one release ago. Polling another daemon's live WAL-mode CoreData store is a support-ticket generator.

**12. Re-adding Calendar / Notes / Timer / Mirror, or a user-arrangeable widget board.** Direct violation of CLAUDE.md's "removed features stay removed" and of `TabContractTests.swift`, which exists precisely to stop this. The board also invalidates the never-resize invariant that exists because resizing across a lock produced stretched window-server snapshots.

**13. Webcam mirror.** A permanent camera TCC entry and a green indicator light, for a feature the competition demonstrably cannot keep working (two open bugs in boring.notch, MacStories: NotchNook's won't accept external cameras).

**14. "All displays" mode.** A *display picker* is defensible. N panels on N screens is chasing NotchNook — and MacStories already called their synthetic notch on an external "visually jarring."

**15. Notch appearance knobs (custom GIF, corner style, height fine-tune).** The market research names these correctly: "the fastest way to lose the native bar." Apple would ship the width control and none of the rest.

**16. "Uninstall Isla / Delete Everything and Quit."** macOS's uninstall convention is drag-to-Trash. A self-deleting app that trashes `~/Pictures/Isla` is a foot-gun, not restraint. The Apple-shaped version is a `noteRow` stating where data lives, next to the two clear buttons that already exist.

**17. `idle`/`resume` verbs on the media helper.** Adds a protocol state machine to a helper whose entire virtue is that it has four verbs and dies when stdin closes (`test-lifecycle.sh` gates that). For 0.1 % of a core. The proportionate fix is one line: give the `NSTimer` at `helper.m:414` a tolerance — which is the *actual* Apple-guidance miss and the only one the challenge chain identified.

**18. Rewriting `PointerWatcher` to be event-driven.** `tick()` is the sole source of `panel.ignoresMouseEvents` (`NotchController.swift:758-759`), and `NotchController.swift:756-757` documents why a `nil` hitTest can't forward. The poll is load-bearing for click-through correctness. Trading a proven invariant for 8 coalescable wake-ups/second while the screen is on is a bad trade at any price.

**19. Low Power Mode / thermal branching.** Every path it would gate (`SpoilerField`, `KaraokeRenderer`, the 4 Hz ticker) only runs while the panel is open — `SpoilerField.swift:57-59` says so in its own header. Near-zero saving, and it makes the app behave differently in ways the user can't predict.

**20. The `NotchController` XL state-machine refactor.** The finding admits it could not name a reachable trigger for the `setOpen` race. Rewriting the most hand-validated file in the app on a theoretical hazard, when the concrete defects it's meant to prevent (Escape, click-to-close, pin clearing) are 5–20 lines each, inverts the risk.

**21. `NotchShape` quadratic → continuous-corner rewrite.** A ~2.5 pt silhouette difference at radius 22, on the *bottom* corners, in a `Shape` that carries `animatableData` (`NotchShape.swift:10-16`) and is the most-watched object in the app. Nobody has named it. Low priority at best.

**22. DMG background art.** Apple stopped shipping DMGs. Signing the image and using a stable `-volname "Isla"` are real; the arrow-and-background is marketing decoration, and an unstyled Finder window is arguably the more honest artifact.

**23. Marquee — half creep.** iOS's island and Control Center do scroll a title, so this isn't pure envy. But the same finding identifies the better fix: **128 pt of empty right wing sits opposite a title that ran out of room** (`NotchContentView.swift:206-213`). Rebalance the wings first. A marquee on a 2-second peek is motion for its own sake and must bypass under Reduce Motion anyway.

---

## D. Contradictions the report never resolves

- **product-shape says cut Translate and demote Clipboard.** All five market sections say Translate and Clipboard are the two capabilities *no* competitor has at any price and the strongest answers to "why not NotchNook." These cannot both be executed.
- **product-shape proposes moving Settings into "a small window."** That reverses the dated 2026-08-25 amendment that withdrew the window, the Dock icon and the status item. It would give the app a window it deliberately does not have.
- **materials wants the panel translucent; interaction and product-shape both rely on it being an opaque continuation of the cutout.**
- **The audit's own "market" sections repeatedly cite competitor-owned SEO pages** (notchy.dev, macnotch.io, getseam, brow-app, notchbay, crestnotch) — the category-truth section says so explicitly, and their MediaMate prices disagree with MediaMate's own store. No finding sourced only to those should set a priority.

---

## E. What actually survives, in order

**Blocking:**
1. `MainActor.assumeIsolated` inside the `receivePromisedFiles` reader on a background `OperationQueue` — **verified at `NotchRootView.swift:229-238`**, and reachable by the exact input path `:74-76` registers for (Mail, Photos, Safari). Hard crash. One-line fix.
2. Developer ID + notarization. `Scripts/release.sh:62-94` is already written and correct. It gates the keychain path, Sparkle, TCC grant stability, and every worth-paying claim.
3. Click-to-close + Escape + clearing the pin when the pointer arrives (`NotchContentView.swift:119`, `NotchController.swift:500`, `:731` vs `:734-736`, `NotchPanel.swift:28`). Three small edits close four reported findings.
4. `collapsedDepth` on synthetic notches (`NotchGeometry.swift:283`) — three quarters of the drawn island is dead on every external display, contradicting the app's own shipped invariant from `d160909`.

**High value, small:** the artwork `matchedGeometryEffect` (no bounce); `.contentTransition(.symbolEffect(.replace.downUp))` on play/pause (grep confirms zero uses anywhere); `formatTime` rolling to `h:mm:ss` plus deleting the duplicate at `LockScreenCard.swift:665`; `preferDrawn: true` at `LockScreenCard.swift:105`; the grain tile's point size (`GlassSurface.swift:139-143`); the truncation-mode swap (`ShelfPane.swift:144` / `SpoilerField.swift:166`); locale-aware slider readouts; universal binary + the `NSHumanReadableCopyright` line; `.accessibilityLabel` on the four bare glyph buttons and the clipboard rows.

**Medium, genuinely Apple-shaped:** Increase Contrast reaching the type ramp; fullscreen suppression; the lock card refusing account writes and system output changes above the shield; `Theme` semantic type roles (6 sizes, not 15); AirDrop via `NSSharingServicePicker` on the shelf; `SetFocusFilterIntent`; a battery/charging live activity (public IOKit, zero prompts); surfacing the output picker that already exists in `AudioOutputs.swift` into `MediaPane`; and the first-run welcome pane, which is the necessary counterweight to having no Dock icon and no menu-bar item.

**Under-weighted and real:** the Panel Width slider tears down the panel, hosting view and view model **per point of travel** — verified, `SettingsPane.swift:337` → `NotchController.swift:575-598` — up to 140 full rebuilds in one drag, destroying the `NSHostingView` that owns the `@State` driving the drag.