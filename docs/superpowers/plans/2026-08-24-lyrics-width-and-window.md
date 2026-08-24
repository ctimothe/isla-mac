# Lyrics Parity, Panel Width, and the Main Window

**Supersedes** the first draft at this path (2026-08-24, uncommitted). That draft named
`positionSettled` as the cause of the paused-lyrics bug. Evidence refuted it — see Phase 0 §3.

Each phase below is self-contained and may be executed in a fresh context. Read Phase 0 first,
every time: it is the API contract the other phases are written against.

---

## Phase 0 — Discovery output

Gathered inline (subagents are disabled in this session). Every claim below is backed either by
a compile against this machine's SDK or by an Apple documentation page, both cited.

### 0.1 Allowed APIs — verified, safe to use

**SwiftUI custom text rendering** — the instrument for Phase 2.

| API | Availability | Source |
| --- | --- | --- |
| `protocol TextRenderer : Animatable` | macOS 15.0+ | <https://developer.apple.com/documentation/swiftui/textrenderer> |
| `func draw(layout: Text.Layout, in ctx: inout GraphicsContext)` | macOS 14.0+ | <https://developer.apple.com/documentation/swiftui/textrenderer/draw(layout:in:)> |
| `func textRenderer<T>(T) -> some View` | macOS 15.0+ | <https://developer.apple.com/documentation/swiftui/textproxy> (Related APIs) |
| `Text.Layout` conforms to `RandomAccessCollection` of `Text.Layout.Line`; `Line` is a collection of `Text.Layout.Run` | macOS 14.0+ | <https://developer.apple.com/documentation/swiftui/text/layout> |
| `Text.Layout.TypographicBounds` | macOS 14.0+ | same page |
| `GraphicsContext.draw(_:options:)` for a `Line` | macOS 14.0+ | <https://developer.apple.com/documentation/swiftui/graphicscontext/draw(_:options:)> |

`TextRenderer` and `textRenderer(_:)` are macOS **15.0**, and `Package.swift` declares
`platforms: [.macOS(.v15)]`. They need no `@available` guard here, and would not compile on a
lower floor.

**Compile-verified on this machine**, not assumed. The following exact body built clean
(`swift build` → `Build complete!`) as `Sources/DynamicIslandKit/UI/ProbeRenderer.swift`, then
was removed:

```swift
struct ProbeRenderer: TextRenderer, Animatable {
    var fraction: Double
    var accent: Color
    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }
    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let runs = layout.flatMap { $0 }
        let total = runs.reduce(0.0) { $0 + $1.typographicBounds.width }
        guard total > 0 else { return }
        var remaining = total * min(max(fraction, 0), 1)
        for run in runs {
            let bounds = run.typographicBounds
            context.draw(run)
            guard remaining > 0 else { continue }
            let lit = min(remaining, bounds.width)
            remaining -= lit
            var sung = context
            sung.clip(to: Path(CGRect(
                x: bounds.origin.x,
                y: bounds.origin.y - bounds.ascent,
                width: lit,
                height: bounds.ascent + bounds.descent
            )))
            sung.addFilter(.colorMultiply(accent))
            sung.draw(run)
        }
    }
}
```

So these are all real: `layout.flatMap { $0 }` yielding runs, `run.typographicBounds` with
`.width` / `.origin` / `.ascent` / `.descent`, `GraphicsContext.draw(_ run:)`,
`GraphicsContext.clip(to:)`, `GraphicsContext.addFilter(.colorMultiply(_:))`, and
`animatableData` on a `TextRenderer`. **Copy this block** into Phase 2 rather than retyping it.

**AppKit window and activation** — the instrument for Phase 4. Also compile-verified on this
machine as `Sources/DynamicIslandKit/App/ProbeWindow.swift`, built clean, then removed:

- `NSApp.setActivationPolicy(.regular)` / `.accessory` — switching at runtime from an
  `LSUIElement` bundle compiles and is supported; `LSUIElement` sets only the initial policy.
- `NSApp.activate()` — the macOS 14+ form. **No deprecation warning was emitted.**
- `NSWindow(contentRect:styleMask:backing:defer:)` with
  `[.titled, .closable, .miniaturizable, .resizable]`, `contentMinSize`,
  `isReleasedWhenClosed = false`, `NSHostingView` content, `NSWindowDelegate`.

### 0.2 Anti-patterns — do NOT do these

- **Do not call `NSApp.activate(ignoringOtherApps:)`.** Deprecated since macOS 14. The probe
  proves the bare `activate()` compiles warning-free.
- **Do not add `@available(macOS 15, *)` around `TextRenderer`.** The package floor already is 15;
  the guard would be noise and would imply a fallback path that cannot exist.
- **Do not mask a wrapped lyric with a single `Rectangle`.** This was tried and recorded at
  `Sources/DynamicIslandKit/UI/LyricsStage.swift:383-388`: one rectangle spans every visual row,
  so a two-row line lights the left half of *both* rows at once. The renderer must clip per run.
- **Do not sweep by splitting an `AttributedString` at a character index.** Also already tried —
  it is what the stage does today. Text *content* changes cannot interpolate in SwiftUI, so the
  highlight can only jump, at whatever rate the position publishes.
- **Do not resize the panel window.** `NotchGeometry.swift:211` asserts the window equals
  `NotchMetrics.maximumWindow`. Resizing it across a lock is what produced the stretched
  window-server snapshot that `LockCardWindow` was created to avoid (`1118ab3`, `d6b44d5`).
- **Do not use `NSScreen.main`** to pick the island's display. The panel never activates.
- **Do not let `NotchPanel.canBecomeMain` become true.** The new window is a separate `NSWindow`.
- **Do not drop the accessibility labels** when moving to a custom `TextRenderer`. A custom
  renderer replaces default text drawing; the labels on the caption Button
  (`.accessibilityValue(line.text)`) and the stage rows (`.accessibilityLabel(line.text)`) are
  what keep the lyric readable to assistive tech, and they are set on the enclosing view, so they
  survive — but only if left in place.

### 0.3 Root causes, established before any fix

**Bug 1 — the caption vanishes, and the transport moves when it does.**

`MediaPane.lyricsLine` (`Sources/DynamicIslandKit/UI/MediaPane.swift:382`) is a `@ViewBuilder`
behind **three independent gates**: `media.positionSettled`, `case .synced` on `lyrics.state`,
and a line actually covering the current position. Any one of them failing produces *no view at
all* — which is both halves of the bug: nothing to read, and a collapsed slot that lets the
scrubber and transport slide.

*A refuted hypothesis, recorded so nobody re-runs it:* `positionSettled` was the first suspect.
It is **not** the cause. It self-heals on every path that clears it, because
`MediaController.swift:593` sets `lastReadingAt = nil` inside the `playerChanged` branch, and
`describesAMomentAlreadyPast` returns `false` when `lastReadingAt` is nil — so the very next
reading is never judged stale and always reaches `adopt`, which sets the flag true. A test
written against this hypothesis failed at its own intermediate assertion and was deleted.

*Evidence from the running app.* Built the bundle, launched it with `DI_OPEN_LYRICS=1` against a
paused Spotify (Alex G — "Advice", position 29.0s). `/tmp/di-debug.log`:

```text
apply el=29.00 age=1057.41 rate=0.00 play=0 stale=0 steer=0 rep=29.00 pos=0.00 pend=0
stage appeared: loading pos=29 settled=1
synced(11) pos=29 settled=1
```

`settled=1` while paused, so gate 1 is satisfied. Note `pos=0.00` on the first apply, before the
reading landed. That is the paused failure: a paused track's position is frozen — the ticker
stops (`updateTicker` guards on `isPlaying`) and later readings are rejected as stale
(`stale=1` on every subsequent line of that trail) — so a position sitting **before the first
timestamped line** yields `current.line == nil` forever. Press play, the position crosses the
first line, and the words appear. The cached lyric for that track confirms the shape:
`~/Library/Application Support/DynamicIsland/lyrics/6733bf2475fd0393.lrc3.json` has
`times: [1.58, 18.2, 30, …]`, so any frozen position under 1.58 shows nothing.

**Bug 2 — the two surfaces disagree, and the stage lags.** Three copies of one idea:

1. `MediaPane.sweepFraction` and `LockScreenCard.sweepFraction:201` are byte-identical; the stage
   calls the lock card's (`LyricsStage.swift:393`).
2. `LyricsStage.lead:69` is `(precisionSync ? 0.25 : 0.45) + lyrics.userOffset`. `MediaPane` uses
   the same two constants **without `userOffset`**. Nudge Sync on the stage and the caption keeps
   pointing at a different line. This is a provable disagreement, not a matter of feel.
3. The caption renders through `KaraokeLine` — a geometry mask, continuous but wrong on wrapped
   lines. The stage renders through `wrappedKaraoke` — correct on wrapped lines but unanimatable,
   stepping at the position's publish rate, `Timer(timeInterval: 0.25)` in `updateTicker`. Four
   steps a second is the reported lag.

That same cached file shows `wordTimes: [[], [], …]` — the LRCLIB tier is line-level only, so
that track sweeps on `LyricsStore.sweepSpan`'s estimate on **both** surfaces. Word-level lag is
visible only on tracks whose source carried word timing. Do not "fix" the estimate; it is not
the complaint.

### 0.4 Global constraints (apply to every phase)

- macOS 15.0 floor; `swift-tools-version: 6.0`, `.swiftLanguageMode(.v5)`; almost everything `@MainActor`.
- Every user-facing string through `localized(_:)`, present in **both** `Resources/en.lproj` and
  `Resources/ru.lproj`. `Scripts/test-localizations.sh` enforces key parity.
- No `cyclop` / `com.cyclop` / `libcyclopmedia` anywhere in `Sources`, `Resources`, or the
  scanned scripts, comments included. `Scripts/test-branding.sh` is case-insensitive.
- Comments explain *why*, naming the failure they prevent. Match the surrounding density.
- Commit subjects: lowercase sentences describing the user-visible result. Branch `feat/…` or
  `fix/…`, merge into `dynamic-island-parity` with `git merge --no-ff`.
- `swift test` green before every merge.

---

## Phase 1 — The caption always has something to say, in a slot that never moves

Branch: `fix/the-lyric-holds-its-place`

### What to implement

**Copy the gate structure from** `Sources/DynamicIslandKit/UI/MediaPane.swift:382-432` and change
exactly two things about it.

1. **A line is always chosen while lyrics exist.** When `LyricsStore.current(in:at:)` returns no
   line — the frozen-position case in Phase 0 §3 — fall back to `lines.first` drawn unswept
   (`fraction: 0`). A lyrics app shows the opening line waiting; showing nothing is the bug.
2. **The slot is always reserved.** Wrap the caption in a fixed
   `.frame(height: MediaPane.captionHeight, alignment: .leading)` at the call site
   (`MediaPane.swift:116`, currently `lyricsLine.padding(.top, 4)`), and delete `lyricsLine`'s own
   `.padding(.top, 5)` so the text cannot escape the slot. `captionHeight` is `17`.

Add the fallback as a **pure static function** so it is testable without a view:

```swift
/// The line to show right now, which is not always the line being sung.
///
/// A paused track's position is frozen — the ticker stops and later readings are
/// rejected as stale — so a track paused before its first timestamp used to leave
/// `current` empty and the caption blank until somebody pressed play. The opening
/// line, unswept, is the honest thing to show: the words are there, the voice has
/// not reached them.
static func displayed(
    lines: [LyricsStore.Line], at: TimeInterval
) -> (line: LyricsStore.Line, swept: Bool)? {
    guard let first = lines.first else { return nil }
    let current = LyricsStore.current(in: lines, at: at)
    guard let line = current.line else { return (first, false) }
    return (line, true)
}
```

### Documentation references

- Gate structure to modify: `Sources/DynamicIslandKit/UI/MediaPane.swift:382-432`
- Fixed-height column this sits inside: `MediaPane.blockHeight` (`122`), `MediaPane.swift:35`
- Binary search it wraps: `LyricsStore.current(in:at:)`, `LyricsStore.swift:238`
- Rendering-test harness to copy: `Tests/DynamicIslandKitTests/LyricsStageRenderTests.swift`

### Verification checklist

- [ ] `swift test --filter MediaPaneLayoutTests` — the transport's y is identical with
      `.synced([…])` and with `.none`, to 0.5 pt.
- [ ] A test asserting `MediaPane.displayed(lines:at:)` returns `(lines[0], false)` for a
      position before the first timestamp, and `(lines[1], true)` for one inside line 1.
      Use the real shape from the cache: `times: [1.58, 18.2, 30]`.
- [ ] `grep -n "padding(.top, 5)" Sources/DynamicIslandKit/UI/MediaPane.swift` returns nothing.
- [ ] `swift test` fully green.

### Anti-pattern guards

- Do **not** touch `positionSettled` or `MediaController`. Phase 0 §3 proves it self-heals; a
  change there fixes nothing and risks the clock.
- Do **not** make the slot conditional on "has lyrics". Its whole purpose is to be there when
  they are absent.
- Do **not** sweep the fallback line. `swept: false` means `fraction: 0` — a filled sweep across
  a line nobody has reached says the voice is there.

---

## Phase 2 — One sweep, one lead, one renderer

Branch: `fix/one-karaoke-clock`

### What to implement

**Step A — collapse three copies into one.** Create
`Sources/DynamicIslandKit/Services/LyricSweep.swift` holding `standardLead = 0.45`,
`precisionLead = 0.25`, `lead(precisionSync:userOffset:)`,
`position(_:precisionSync:userOffset:)`, and `fraction(line:at:end:)`. **Copy the body of
`fraction` verbatim** from `Sources/DynamicIslandKit/UI/LockScreenCard.swift:201-207` — it is
already correct; the bug is that there are three of it. Then delete
`MediaPane.sweepFraction`, `MediaPane.lyricsLead`, `MediaPane.precisionLyricsLead`, and
`LockScreenCard.sweepFraction`, and point all three surfaces at `LyricSweep`.

The caption gains `lyrics.userOffset` by doing this, which is the fix for divergence 2.

**Step B — one renderer.** Create `Sources/DynamicIslandKit/UI/KaraokeText.swift`. **Copy the
compile-verified `ProbeRenderer` body from Phase 0 §1 exactly**, rename it `KaraokeRenderer`, add
a `base: Color`, and wrap it in a `KaraokeText: View` that applies
`.textRenderer(KaraokeRenderer(...))` and
`.animation(reduceMotion ? nil : .linear(duration: 0.25), value: fraction)` — one tick of the
0.25 s ticker, so the interpolation exactly spans the gap between position updates.

Then delete `struct KaraokeLine` from `MediaPane.swift` and `wrappedKaraoke` from
`LyricsStage.swift`, and have the caption, the stage row, and the lock card all build
`KaraokeText` at their own font, accent, and `lineLimit`.

### Documentation references

- The verified renderer body: **Phase 0 §1 of this document**. Copy it; do not retype it.
- `TextRenderer`: <https://developer.apple.com/documentation/swiftui/textrenderer>
- `Text.Layout`: <https://developer.apple.com/documentation/swiftui/text/layout>
- The fraction body to copy: `Sources/DynamicIslandKit/UI/LockScreenCard.swift:201-207`
- Why not a rectangle mask: `Sources/DynamicIslandKit/UI/LyricsStage.swift:383-388`
- Publish rate the animation spans: `MediaController.updateTicker`, `MediaController.swift:1034`
- Bitmap-assertion helper to copy: `Tests/DynamicIslandKitTests/GlassSurfaceTests.swift`

### Verification checklist

- [ ] `KaraokeRenderer(fraction: 0.25, …).animatableData == 0.25`, and setting
      `animatableData = 0.75` moves `fraction`. This is the wiring that makes the sweep
      interpolate instead of step; assert it rather than the pixels.
- [ ] A wrapped line at half fraction lights ~half its glyphs, contiguously from the first —
      the assertion the rectangle mask would fail.
- [ ] `grep -rn "sweepFraction" Sources/` returns **only** `LyricSweep.swift`.
- [ ] `grep -rn "KaraokeLine\|wrappedKaraoke" Sources/` returns nothing.
- [ ] `LyricSweep.lead(precisionSync: true, userOffset: -0.4) == -0.15` — proof the listener's
      correction now reaches every surface.
- [ ] `swift test` green. `LyricsStageRenderTests` and `LockScreenCardRenderTests` assert pixels;
      if a fixture changes, say so in the commit body rather than quietly rewriting it.

### Anti-pattern guards

- Do **not** reintroduce a `Rectangle` mask or an `AttributedString` split. Both are recorded
  failures; see Phase 0 §2.
- Do **not** "improve" `LyricsStore.sweepSpan`. Phase 0 §3 shows the estimate is shared by both
  surfaces already and is not the complaint.
- Do **not** give the two surfaces different leads "because the stage is bigger". One clock.

---

## Phase 3 — The panel comes in, and you pick how far

Branch: `feat/the-panel-comes-in`

Default **560 pt**, adjustable **480…620**, from Settings. The window stays `700 × 444`.

### What to implement

1. In `NotchMetrics`: `minimumBodyWidth = 480`, `maximumBodyWidth = 620`,
   `defaultBodyWidth = 560`, `standardBodyHeight = 208`, `body(width:) -> CGSize`, and
   `standardBody` redefined as the **widest** body so the window arithmetic is unchanged.
2. In `NotchViewModel`: `bodyWidthKey = "bodyWidth"` and `bodyWidth(in: UserDefaults) -> CGFloat`,
   clamped **on read** — the value can also arrive from `defaults write`. **Copy the shape of
   `NotchViewModel.hoverOpenDelay`** (`NotchViewModel.swift:288-297`), which already does exactly
   this for the hover delay.
3. In `NotchGeometry:27`: `expandedSize` becomes `NotchMetrics.body(width: NotchViewModel.bodyWidth)`.
   At `:205`, the window size uses `NotchMetrics.maximumBodyWidth`, **not** `expandedSize.width`,
   so the assert at `:211` still holds at every setting.
4. In `SettingsPane`, General section: a `Slider`. **Copy the hover-delay row at
   `SettingsPane.swift:51`** — it is the working example of a `Slider` bound to a clamped
   preference in this pane. Strings: `"Panel width"` / `"Ширина панели"`.
5. In `NotchController`: `func refreshGeometry() { rebuild() }`, reached from the slider the same
   way the Settings tab's "Open Panel" row reaches `togglePanel()` — through `NSApp.delegate`.
   Rebuild rather than nudge: it is the path a display change already takes, and the only one
   known to leave every rect consistent.

### Documentation references

- Clamped-preference pattern to copy: `Sources/DynamicIslandKit/Model/NotchViewModel.swift:288-297`
- Slider row to copy: `Sources/DynamicIslandKit/UI/SettingsPane.swift:51`
- The window-size assert that must keep holding: `Sources/DynamicIslandKit/Notch/NotchGeometry.swift:205-212`
- Existing size assertions to update: `Tests/DynamicIslandKitTests/NotchMetricsTests.swift:7-9`
- Compact-pill clamp that reads the body width: `Sources/DynamicIslandKit/Model/CompactMediaActivity.swift:34`

### Verification checklist

- [ ] `bodyWidth` returns `560` unset, `620` for a stored `9000`, `480` for a stored `10`.
- [ ] `NotchMetrics.maximumWindow == CGSize(width: 700, height: 444)` still asserts, and
      `NotchGeometry.current()?.windowSize` still equals it at the **narrowest** setting.
- [ ] `bash Scripts/test-localizations.sh` → `✓`.
- [ ] `swift test` green, `CompactMediaActivityTests` included.
- [ ] The binding design is amended in place, dated, under the metrics table at
      `docs/plans/2026-08-18-dynamic-island-parity-design.md:76` — the way Snippets, Calendar,
      Notes and the Teleprompter were amended, never by rewriting the row. Record it in
      `checklist.md` under "Scope divergence from Cyclop 0.6.5" too.

### Anti-pattern guards

- Do **not** change `NotchMetrics.maximumWindow` or make the window follow the body.
- Do **not** clamp only on write.
- Do **not** edit the design doc's `620 × 208 pt` row. Add a dated amendment beneath it.

---

## Phase 4 — A window, and the menu's work moves into it

Branch: `feat/a-window-of-its-own`

Chosen shape: menu-bar icon with **no dropdown**; clicking it opens the window; the app is
`.accessory` while the window is shut and `.regular` while it is open, so the Dock icon and the
app menu appear with the window and leave with it.

### What to implement

1. `Sources/DynamicIslandKit/App/MainWindowController.swift`. **Copy the compile-verified
   `ProbeWindowController` from Phase 0 §1**: same style mask, same `contentMinSize`, same
   `isReleasedWhenClosed = false`, same `NSApp.activate()`. Add `dismiss()`, `isPresented`, and
   keep `static func policy(windowOpen:)` pure so the switch is testable without a window.
2. `Sources/DynamicIslandKit/UI/MainWindowView.swift`: a `NavigationSplitView` whose sidebar is
   driven by an enum, not hand-built rows — the point of this phase is a shell a later feature
   drops into. Ship exactly two sections, **Settings** and **About**; invent no features.
3. `AppDelegate.installStatusItem` keeps the button and its template image, drops `item.menu`
   entirely, and sets `item.button?.action` to a new `@objc func openWindow()`. Delete
   `privacyItem`, `privacyAllItem`, `privacySectionItems`, the `NSMenuDelegate` conformance, and
   `menuNeedsUpdate(_:)` — all four exist only to keep menu state in sync.
4. Rehome all four menu functions, losing none: the version line → About; **Open Panel** → a
   button in the window's Settings section calling the existing `togglePanel()`; **Hide
   Contents** → an "All" toggle plus one per `PrivacyMode.Section`, bound to the same
   `PrivacyMode` the menu drove; **Quit** → the standard app menu, which exists now that the app
   is `.regular` while the window is open. Keep `@objc func quit()` for the ⌘Q equivalent.

### Documentation references

- The verified window and policy body: **Phase 0 §1 of this document.**
- The menu being replaced, all four functions: `Sources/DynamicIslandKit/App/AppDelegate.swift`,
  `installStatusItem()`
- Sections to reuse in the window: `Sources/DynamicIslandKit/UI/SettingsPane.swift:31-201`
- Privacy model the toggles bind to: `Sources/DynamicIslandKit/Model/PrivacyMode.swift`

### Verification checklist

- [ ] `MainWindowController.policy(windowOpen: false) == .accessory` and
      `policy(windowOpen: true) == .regular`.
- [ ] Presenting twice reuses one window; `dismiss()` clears `isPresented`.
- [ ] `grep -n "item.menu\|NSMenuDelegate\|menuNeedsUpdate" Sources/DynamicIslandKit/App/AppDelegate.swift`
      returns nothing.
- [ ] `bash Scripts/test-localizations.sh` → `✓`; `swift test` green.
- [ ] By hand: click the status icon → window opens and a Dock icon appears; close it → the Dock
      icon goes and the island still opens on hover; toggle a privacy section in the window and
      confirm the panel covers that tab; ⌘Q with the window focused quits.

### Anti-pattern guards

- Do **not** use `activate(ignoringOtherApps:)`.
- Do **not** set the policy from anywhere but the window's open/close path — a policy flipped
  while no window is visible leaves a Dock icon for an app with nothing to show.
- Do **not** give `NotchPanel` any part in this. It stays `.nonactivatingPanel`, never main.
- Do **not** drop a menu function "for now". Four go in, four come out.

---

## Phase 5 — Final verification

- [ ] `grep -rn "sweepFraction" Sources/` → only `LyricSweep.swift`.
- [ ] `grep -rn "KaraokeLine\|wrappedKaraoke" Sources/` → nothing.
- [ ] `grep -rn "activate(ignoringOtherApps" Sources/` → nothing.
- [ ] `grep -rn "NSScreen.main" Sources/` → nothing.
- [ ] `grep -rn "item.menu" Sources/DynamicIslandKit/App/AppDelegate.swift` → nothing.
- [ ] Full gate order, in order:

```bash
swift test
bash Scripts/test-provenance.sh
bash Scripts/test-branding.sh
bash Scripts/test-localizations.sh
bash Scripts/bundle.sh release
bash Scripts/test-identity.sh
bash Scripts/test-helper.sh
bash Scripts/test-package.sh
bash Scripts/test-lifecycle.sh
```

- [ ] Re-run the Phase 0 §3 reproduction and confirm it is dead: launch with `DI_OPEN_LYRICS=1`
      against a **paused** track sitting before its first timestamp, and confirm the caption shows
      the opening line rather than nothing.
- [ ] Docs updated: `README.md` (the window, the icon that opens it), `docs/runbook.md` §3 and §4,
      and `checklist.md` for the width and the window — both are beyond the parity design's shape.
- [ ] Manual pass on notch hardware; record Mac model and macOS version in `checklist.md`.
      A green build is not a pass.
