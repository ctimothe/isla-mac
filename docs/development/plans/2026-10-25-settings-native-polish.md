# Settings: native polish (audit and spec)

Date: 2026-10-25. Status: **proposed**, nothing built. Read-only audit, no code changed.
Owner brief (2026-10-25): "the settings needs serious polish; it's trying to be Apple-native but
simply isn't … use Apple's own assets that are available: icons, logos, colors, background
colors, the styling specification, and default support for macOS 27." Settings stays inside the
island (moving it to a window was rejected); the sidebar and grouped form stay.

Binding document this would amend: `docs/development/plans/2026-10-15-redesign-spec.md` §10
(Settings, R4). Every number below that differs from §10 needs a dated amendment there before
code changes, per the source-of-truth policy.

Checkout: `./scripts/source-fresh.sh` → `FRESH: HEAD b1ea653 contains origin/main 2189560`.
Machine: macOS 27.0.1 (26A434), SDK 27.0, dark appearance, **accent colour Red**
(`defaults read -g AppleAccentColor` → `0`).

## 0. Evidence and how it was gathered

- Current renders: 120 headless lab PNGs (every section, top and bottom, en/ru, w480/560/620),
  from `VisualLabSettingsRowsTests`.
- **Native reference**: a scratch probe (not in the repo) hosting SwiftUI
  `Form { Section }.formStyle(.grouped)` and `List(.sidebar)` in a never-ordered borderless
  `NSWindow` with `.darkAqua`, drawn with `cacheDisplay` at 2× (the same method as the lab), plus a
  dump of the AppKit view tree. Variants: plain dark window; black background with
  `.scrollContentBackground(.hidden)`; with and without `.environment(\.appearsActive, true)`;
  a window subclass that returns `true` from `isKeyWindow`. Pixel values read with
  `NSBitmapImageRep.colorAt`. Russian copy at a 316 pt form width.
- **System icons**: `NSWorkspace.shared.icon(forFile:)` on System Settings' extension bundles and
  `NSWorkspace.shared.icon(for: UTType("com.apple.graphic-icon.…"))`, drawn to PNG; the
  `CFBundleIcons.ISGraphicIconConfiguration` of every `/System/Library/ExtensionKit/Extensions/*.appex`.
  IconServices answers only outside Claude's Bash sandbox (inside it every icon draws empty); the
  app itself is not sandboxed, so this does not affect Isla, but a lab run that draws system icons
  must run with the sandbox off.
- Not measured: a screenshot of System Settings itself (it would have meant driving the owner's
  desktop). Values that depend on it are marked **(S)** and are owed as check S-1 in §6.

### What the native form measures on macOS 27.0.1 (dark)

| Element | Native `Form(.grouped)` | Isla today |
|---|---|---|
| Row label | 13 pt regular, `labelColor` (224/255 on black) | 12.5 pt (`TypeRole.reading`), pure white (255) |
| Section header | 13 pt semibold, `labelColor` (223/255) | 12.5 pt semibold, white 0.85 |
| Footer | 11 pt regular (`.subheadline`), `secondaryLabelColor` (157/255 on black) | 10 pt (`caption`), white 0.50 (146/255) |
| Row height | switch 37.5, slider 37, pop-up 38.5, push button 40, segmented 41 | 28 (`SettingsLayout.rowHeight`) |
| Row inset in group | 10 pt; separator inset 10 pt, both sides | 10 / 10 (same) |
| Group inset from form edge | 20 pt each side (`contentMargins(.horizontal, 0)` does not remove it) | 0 |
| Group corner | continuous, corner run 10.5 pt (≈ radius 10) | radius 9 continuous |
| Group fill | on the dark window (40/255) the box is 49/255; on black it drops to 6/255, i.e. almost invisible | white 0.055 (16/255) |
| Separator | 62/255 on the 49/255 box (+13) | white 0.10 hairline, 52/255 on 16/255 (+36) |
| Switch | `NSSwitch` at `.mini`: 36 × 16 pt (Form's default); `.small` 44 × 20 | drawn, 30 × 17 |
| Sidebar `List(.sidebar)` | row 32 pt, cell inset 16 pt, 13 pt label | pitch 26, row 24, 12.5 pt label |

Owner's guess was that native rows are *shorter*; on macOS 27 they are taller (37–41 pt against
28). What reads as "not native" is the 12.5 pt type, the pure-white labels, the bright separators,
and the missing 20 pt group inset, not the row height alone.

### Three findings that change the brief

1. **The red switches already use the system accent.** `Theme.switchOnFill` is
   `Color(nsColor: .controlAccentColor)`, and this Mac's accent is Red. The probe's native slider
   draws red too. What *is* Isla's red in Settings is the shortcut recorder's ring and fill
   (`Theme.accent`, `Theme.recordingFill`) and the Lock Screen style preview's ring
   (`SettingsLockStyle.swift:62`). The Update Now button and the update card use a fixed blue
   (`Theme.SettingsTint.blue`), not the accent.
2. **Native switches cannot draw "on" in this panel.** In a non-key window, `NSSwitch` draws its
   inactive look (on track 56/255 grey, the same as off), with or without
   `.environment(\.appearsActive, true)` and with a window that claims `isKeyWindow`. This is H-002
   again, and it is why `PanelSwitchStyle` exists. It stays. Sliders, segmented controls and pop-ups
   are different: with `appearsActive = true` the slider draws its accent fill (243,122,116 here)
   in a plain non-key window.
3. **The red folder on About is a lab artefact.** `NSApplication.shared.applicationIconImage` in
   the xctest host is the generic folder, tinted by the red accent. In the app it is Isla's icon.
   The lab should inject the real icon (`Resources/AppIcon.icon`) so renders stop misleading.

## 1. Can Isla simply use `Form { }.formStyle(.grouped)`?

Yes for the form column, with three adjustments, and it is the recommended path (option A):
every row, header, footer, separator, slider, segmented control, pop-up and push button becomes
Apple's own and follows macOS 27's metrics, and any later macOS change, without Isla re-measuring.

What the probe showed:

- `.scrollContentBackground(.hidden)` + the panel's black works. The group box then nearly
  vanishes (6/255), so each section needs `.listRowBackground(groupFill)`. The probe confirmed
  `listRowBackground` is honoured by the grouped form on macOS.
- `.environment(\.appearsActive, true)` on the form makes sliders, segmented controls and pop-ups
  draw in the active style. `appearsActive` is settable in the macOS 27 SDK; it writes
  `controlActiveState` (SwiftUICore interface).
- At 316 pt with Russian copy, the native form wraps labels at word boundaries and moves a push
  button that does not fit under its label, then truncates the button. That is what
  `SettingsRowChrome`/`SettingsRowLayout` hand-build today (2026-10-17 "Accessibilit / y" fix).
  The truncated button is a regression against that fix, so long Russian button titles still need
  shorter copy or a second line (see §4.4).
- The form's own 20 pt horizontal margin stays. Place the `Form` at x = 130 (body coordinates), not
  150, so the groups land where they land today, with their right edge at `bw − 20` (today `bw − 14`).

Risks that need to be measured before option A is committed:

- **Main-thread cost.** The grouped form is `NSTableView`-backed on macOS (the probe found
  `PlatformGroupContainer` and hosting views per row). Settings is already the heaviest tree
  (`SettingsPane.mountsAfter`, F-015, R8e). Run the hitch lab's `worstFrameCPUMs` on the
  player ⇄ Settings swap, before and after.
- **Pop-ups from a non-key, non-activating panel.** `Picker(.menu)` is an `NSPopUpButton`. Today
  `SettingsPopUpRow` uses SwiftUI's button `Menu` because that is known to open from this panel.
  Needs a hardware check (H-3 in §6). If it fails, keep the `Menu`, restyled as the native pop-up
  (label + `chevron.up.chevron.down` in the circle the probe draws).
- **Segmented control and VoiceOver.** The comment on `SettingsChoiceRow` records that SwiftUI's
  segmented picker reads as a tab group. Keep the `.accessibilityRepresentation` radio group on the
  native picker.
- **Owner decision 4** (segmented control drawn by hand because native "looks like AppKit on the
  dark pane") is in direct conflict with this brief. Taking the native control needs the owner's
  explicit yes, recorded as an amendment to decision 4.

Option B, if A fails on cost or pop-ups: keep the hand-laid form and retune it to the native values
in §3. Every number in §3 applies to both options; under A most of them come from the system.

## 2. Apple's own icons at runtime (nothing shipped)

System Settings' sidebar icons are described, not shipped as images: each extension's
`Info.plist` carries `ISGraphicIconConfiguration` (symbol, enclosure colour), or an
`ISTypeIdentifier` naming a `com.apple.graphic-icon.*` type declared in CoreTypes. IconServices
renders both through public API. This follows the `AppIcons` rule: read from the system at
runtime, cache once per refresh, ship nothing.

| Isla section | Source (in order of preference) | How to load |
|---|---|---|
| General | `com.apple.graphic-icon.gear` (System Settings' General gear) | `NSWorkspace.shared.icon(for: UTType("com.apple.graphic-icon.gear")!)` |
| Privacy | `com.apple.graphic-icon.privacy` (the Privacy & Security hand) | same, by UTI |
| Shortcuts | `com.apple.graphic-icon.keyboard` (Keyboard pane) | same, by UTI |
| Music | Recommended: drawn fallback (rose `music.note`), because the section governs every player, not only Apple Music. Owner's alternative: Music.app's own icon, `com.apple.Music` through `AppIcons` | `AppIcons.icon("com.apple.Music")` |
| Lyrics | none in the system | drawn fallback, orange `quote.bubble.fill` |
| Lock Screen | System Settings' Lock Screen pane (black enclosure, `dots.below.lock.fill`) | `icon(forFile: "/System/Library/ExtensionKit/Extensions/LockScreen.appex")`, only after checking that bundle's `CFBundleIdentifier == "com.apple.Lock-Screen-Settings.extension"`; fallback `com.apple.graphic-icon.auto-lock` is wrong in meaning, so fall back to the drawn tile |
| Translate | none (no Translate app on macOS; `graphic-icon.language` is Language & Region's globe and would mislead) | drawn fallback, blue `translate` |
| Spotify | the installed app (unchanged) | `InstalledAppIcon` with `SpotifyMark` fallback (unchanged) |
| Screenshots | `com.apple.graphic-icon.screenshots` (the Screenshot app's viewfinder) | by UTI; second choice `AppIcons.icon("com.apple.screenshot.launcher")` |
| About | Isla's own icon | `NSApplication.shared.applicationIconImage` (unchanged); the lab injects it |

Bundle identifiers of `.appex` do not resolve through `urlForApplication(withBundleIdentifier:)`
(probe: `nil` for all of them), so the Lock Screen icon is loaded by path. A `UTType` that does
not exist on an older macOS returns `nil` from `UTType(_:)`, and `icon(for:)` of an unknown type
returns a generic document; treat both as "not available" and use the fallback. Verify the
graphic-icon types on macOS 15 and 26 before relying on them there (check S-2).

**Fallback tile, drawn the System Settings way**: the same grid as the system icons, which
measured 104/128 of the frame at 128 pt and 26/32 at 32 pt (an 832/1024 grid on macOS 27;
`Theme.appIconOpticalScale` assumes 824, about 1 % off). A continuous rounded rect with the
enclosure colour as a top-to-bottom gradient, as IconServices draws (General's grey measured
153→177 from 20 pt to 128 pt), and a white SF Symbol. Enclosure colours by semantic name, never
hex: `NSColor.systemGray`, `.systemBlue`, `.systemPink`, `.systemOrange`, `.systemIndigo` (the
`ISEnclosureColor` names System Settings uses: gray, blue, black, cyan, …). This replaces the hex
values in `Theme.SettingsTint`.

Loader: extend `AppIcons` with `systemPaneIcon(_ section: SettingsSection) -> NSImage?`, cached like
app icons, injected in tests so a render never depends on the runner's Mac. `SettingsSection.Glyph`
gains `.systemType(String)` and `.systemBundle(path:id:)`, each carrying its fallback symbol and tint.

## 3. The spec, element by element

Each item: current → target · API · files and symbols. "Keep" means it stays as it is.

### Accent and colour

1. **Accent rule.** Everything in Settings that means "selected, on, active, default" uses the
   system accent: `Color.accentColor` / `NSColor.controlAccentColor`. Isla's red
   (`Theme.accent`, #FF453A) is only for marks of Isla's own (LIVE, the playing output) and never
   appears in Settings. Changes: `ShortcutRecorder.swift:49–55` (`recordingFill`, ring) → accent at
   0.18 / accent ring; `SettingsLockStyle.swift:62` ring → accent; `ProminentPushButtonStyle` and
   `UpdateCard.swift:115,189,195` (`SettingsTint.blue`) → accent (under option A, the native
   `.buttonStyle(.borderedProminent)`, which is accent already). Keep `Theme.switchOnFill`.
2. **Label colours**: labels white → `Color(nsColor: .labelColor)` resolved under `.darkAqua`
   (≈ white 0.85); headers same; footers white 0.50 → `.secondaryLabelColor`; values → `.secondary`.
   Under Increase Contrast these semantic colours brighten by themselves. `ContrastRampTests` must
   re-measure: `secondaryLabelColor` on the group fill has to clear 4.5:1 at 11 pt; if it does not,
   keep `Theme.tertiaryOpacity` for footers and say why in the comment.
3. **Group fill on black**: native boxes vanish on black (6/255). Keep a drawn fill, re-derived
   from the native step instead of the board: System Settings' box is +9/255 over its window and its
   separator +13 over the box. On black: fill white 0.065 (≈ 17/255), separator
   `Color(nsColor: .separatorColor)` checked to land within ±4/255 of +13 over the fill, and no
   outer stroke (`settingsGroupEdge` goes; native boxes have none). Increase Contrast keeps today's
   0.14 fill plus `.separatorColor` (which itself strengthens). Under A, the fill goes through
   `.listRowBackground`. Files: `Theme.settingsGroupOpacity`, `settingsGroupEdge*`,
   `SettingsPane.groupCard`, `rowDivider`.
4. **Panel stays black and dark.** `NotchPanel` already sets `.darkAqua` (`NotchPanel.swift:400`),
   which is what makes AppKit-backed controls and their menus resolve dark. Add
   `.environment(\.colorScheme, .dark)` on `SettingsPane` too, so `ImageRenderer` and the lab agree
   with the panel. No light variant: the island is always dark.

### Type and rows

5. **Row label** 12.5 → 13 pt regular: `.font(.body)` under option A (native); under B a new
   `TypeRole.settingsRow` = 13. Files: `SettingsPane.switchRow`, `linkRow`, `SettingsRowChrome`,
   `SettingsSliderRow`, `SettingsChoiceRow`, `SettingsPopUpRow`.
6. **Section header** 12.5 semibold white 0.85 → 13 pt semibold `labelColor`, `.isHeader` kept.
   `SettingsPane.blockView(.header)`; under A, `Section { } header: { Text }`.
7. **Footer** 10 → 11 pt (`.subheadline`) `secondaryLabelColor`, wrapping. Under A,
   `Section { } footer: { }`. A footer that is only a row's explanation stays a footer; one that
   carries an action (the Quit row on About, which sits beside a footnote) becomes its own row.
8. **Row height** 28 → native: 38 for a switch, 40 for a button or pop-up (§0 table). Under B:
   `SettingsLayout.rowHeight` 28 → 38 with a 40 floor for rows with a bordered control, and
   `SettingsRowArrangement.stackedInset` re-derived. Sections will scroll more; that is how System
   Settings behaves, and the scroll edge fade is already there.
9. **Group geometry**: radius 9 → 10 continuous; 20 pt between form edge and group (A gives it;
   under B, `formLeading` 150 stays and groups are inset by nothing, so B keeps today's position);
   the gap between groups follows the native form (under B, header-to-group 4 → 6 and
   group-to-next-header 6 → 18, to be read from the probe render, not guessed).

### Controls

10. **Switch** stays drawn (`PanelSwitchStyle`, H-002, proven again in §0), retuned to the
    native mini switch: 30 × 17 → 36 × 16 track (check S-1 for knob diameter). Off well: today
    black 0.30 inset with a hairline. That is what vanishes on black. Target: off track =
    `Color(nsColor: .quaternaryLabelColor)` fill (the system's own off track is a light fill, not a
    recess; the probe's native off track measured 43/255 on black). Verify ≥ 3:1 against the group fill for the off state in `ContrastRampTests`; on keeps
    `controlAccentColor`; Increase Contrast keeps `switchContrastOutline`. Files:
    `Theme.switchTrackSize`, `switchKnobDiameter`, `switchOffFill`, `switchWellOpacity`.
11. **Slider**: native already. `.tint(Theme.secondary)` → remove the tint and set
    `.environment(\.appearsActive, true)` on the form, so the fill is the accent (proven in the
    probe). `.controlSize(.mini)` → `.small`, or the form's default under A. `SettingsSliderRow`.
12. **Segmented choice** (Show Next Line Early, Card Size): hand-drawn capsules → native
    `Picker(...).pickerStyle(.segmented)` with `appearsActive`, keeping the radio-group
    `accessibilityRepresentation`. **Needs the owner to withdraw decision 4.** Keep the
    `ViewThatFits` fallback to a second line for four Russian options at w480.
    `SettingsChoiceRow`, `Theme.choiceOptionFills`.
13. **Pop-up** (Translate To, Translation Languages): hand-drawn capsule → native
    `Picker(.menu)` if H-3 passes; otherwise keep `Menu` and draw the label as the probe's native
    pop-up (value text + chevrons in a 16 pt circle, no plate). `SettingsPopUpRow`.
14. **Push buttons** (`ToolbarPushButtonStyle` in Settings): white 0.14 plate with lit edge →
    native `Button` with `.buttonStyle(.bordered)` and `.controlSize(.regular)`, and
    `.borderedProminent` for Update Now; destructive confirmations get `role: .destructive`. The
    Shelf's toolbar keeps `ToolbarPushButtonStyle`; this is Settings only. `SettingsPane.push`,
    `pushButton`, `UpdateCard`.
15. **Link rows** (Copy Diagnostics, Report a Problem…, Acknowledgements…): rows with a grey
    glyph and a label → native button rows: plain label with the trailing `chevron.right` in
    `.tertiaryLabel` when it opens something, as System Settings draws navigation rows; the
    leading glyph goes (System Settings' action rows carry none). `SettingsPane.linkRow`, `RowIcon`.
16. **Row glyphs** before switch labels (charger, headphones, note, speaker in "The island shows"):
    keep, but draw them the System Settings way, `.foregroundStyle(.secondary)` at 13 pt in a
    20 pt column, so the labels in a group align. `RowIcon` width 16 → 20.
17. **Shortcut recorder**: keep the field; plate → native `.bordered` look, recording state in the
    accent (item 1). `ShortcutRecorder.swift`.

### Sidebar

18. **Row**: pitch 26 / height 24 → pitch 32 / height 28 with a 4 pt gap (the native sidebar list is
    32). Ten rows end at y = 46 + 320 = 366, inside the 386 the body allows.
    `SettingsLayout.sidebarRowPitch`, `sidebarRowHeight`, `sidebarFrame`.
19. **Icon**: 18 pt tile → 20 pt visible tile (S), system images from §2 drawn on the native grid,
    the drawn fallback on the same grid, so drawn and system tiles line up to ±0.5 pt (lab check).
    Remove the 0.5 pt lit top edge (`Theme.settingsIconEdge`): IconServices' own tiles carry their
    gradient, and the drawn ones copy that instead. `SettingsSectionIcon`, `SettingsLayout.sidebarIcon*`.
20. **Label**: 12.5 → 13 pt, `labelColor`; selected row medium → regular (System Settings does not
    bolden the selection).
21. **Selection**: white 0.12 → `Color(nsColor: .selectedContentBackgroundColor)` (the accent
    selection, white label), as System Settings draws it while you use it. Under Increase Contrast it
    stays the accent; the label stays white. Alternative if the owner prefers the unfocused look:
    `.unemphasizedSelectedContentBackgroundColor`. Decide in review. `Theme.settingsSidebarSelection`.
22. **Keep** the hand-drawn sidebar rather than `List(.sidebar)`: a native outline view in a
    non-key panel draws its selection unemphasized (the same cause as H-002), and the sidebar's
    geometry is pinned by `SettingsLayoutTests`.

### Page title and duplication

23. **"General" said twice** (header row "Settings" + first group header "General"): System
    Settings puts the pane's name in the toolbar and does not repeat it as the first group header.
    Target: the header row's title is the selected section's icon and name (`HeaderGlyph` already
    accepts an app icon), and the first `.header` of each section that equals the section's title is
    dropped from `SettingsTable` (General, Music, Lyrics, Lock Screen, Translate, Spotify,
    Screenshots). VoiceOver: the header row stays the page's first heading. Files:
    `SettingsTable.blocks(for:)` (lines 510, 621, 672, 708, 725, 743, 753), `SurfaceHeader`, and
    `SettingsWayfindingTests`, which must assert the new rule (no first header equal to the title).
24. **About**: the 56 pt icon, name and version head stays; drop the "Isla 16.0" group that
    repeats the version (top-about render). Check for Updates becomes a row in the update group.

### Accessibility and stress

25. **Increase Contrast**: native controls and semantic colours handle themselves; the drawn parts
    (group fill 0.14, switch outline, sidebar selection) keep their variants. `ContrastRampTests`
    covers the new fills.
26. **Reduce Transparency**: Settings draws no material of its own. Under A, `scrollContentBackground(.hidden)`
    removes the form's `NSVisualEffectView` (seen in the probe tree), so nothing changes with the setting.
27. **Reduce Motion**: unchanged (the switch's knob travel already honours it).
28. **VoiceOver**: under A each `Section` is a group with its header; native rows lose the
    `accessibilityRepresentation` stand-ins except the switch (drawn) and the segmented picker (tab
    group problem). Re-run `SettingsAccessibilityTests` and the lab's a11y dump; the slider-commit
    behaviour (`testAnIncrementOnTheRowCommits`) must still hold.
29. **Russian at w480**: at 13 pt the sidebar's label room (86 pt) truncates «Конфиденциальность»,
    «Сочетания клавиш», «Экран блокировки» (all three already truncate at 12.5). Options for the
    owner: shorter titles («Приватность», «Клавиши», «Блокировка»), or a 132 pt sidebar at w480 with
    the form at 306. Long Russian push buttons («Открыть «Конфиденциальность и безопасность»…»)
    truncate in the native form at 316 (probe); shorten the copy («Открыть настройки…»). Check
    every section with the lab at ru-w480 after the change.

### macOS 27 notes

30. `EnvironmentValues.appearsActive` is settable and maps to `controlActiveState`; it makes
    SwiftUI-hosted sliders, segmented controls and pop-ups draw active in a non-key window, but not
    `NSSwitch`. No macOS 27 API was found that draws an active switch in a non-key window.
31. The grouped form's switch defaults to `.mini` (36 × 16) on 27, and rows are 37–41 pt. These are
    the values to match under option B.
32. `TabsPickerStyle` (`.tabs`) is new in the 27 SDK; not for this surface.
33. No Liquid Glass on groups: System Settings' groups are fills, not glass. `glassSurface` stays for
    the panel only.
34. Build floor: the app targets macOS 15. `appearsActive` (15+), `listRowBackground`,
    `scrollContentBackground` and `formStyle(.grouped)` are all available there; the graphic-icon
    types need S-2.

## 4. What stays

The panel inside the island, black; the 400 pt body; the sidebar + grouped form; `SettingsTable` as
the single source of rows, defaults and order; `PanelSwitchStyle` (drawn, whole row clickable,
owner decision 2); the staged mount; `disabledWithReason`; `Spotify` and app icons from the
installed apps; scroll-edge fade; no status item, no window.

## 5. Files that change (summary)

`Sources/IslaKit/UI/SettingsPane.swift`, `SettingsSidebar.swift`, `SettingsLayout.swift`,
`SettingsTable.swift` (glyphs, first headers), `SettingsLockStyle.swift`, `ShortcutRecorder.swift`,
`UpdateCard.swift`, `Theme.swift` (Settings tokens, switch tokens, `SettingsTint` → semantic
colours, `appIconOpticalScale`), `Services/AppIcons.swift` (system pane icons). Tests:
`SettingsLayoutTests`, `SettingsIconTests`, `SettingsRowChromeTests` (retired under A),
`SettingsWayfindingTests`, `SettingsAccessibilityTests`, `ContrastRampTests`, `AppIconsTests`,
`VisualLabSettingsRowsTests` (inject Isla's icon; system icons injected). Docs: amend §10 of
`2026-10-15-redesign-spec.md` (dated), withdraw decision 4 if the owner agrees,
`docs/development/checklist.md` for the hardware checks.

## 6. Checks owed

- **S-1** Screenshot of System Settings on this Mac (owner, or computer use with permission):
  sidebar icon visible size and pitch, switch knob diameter, the gap between groups. Replace every
  **(S)** with the measured value.
- **S-2** The `com.apple.graphic-icon.*` types and `LockScreen.appex` on macOS 15 and 26.
- **H-1** Sidebar selection in the accent on hardware with Blue, Graphite and Red accents.
- **H-2** Off switch visible on the panel over a bright wallpaper and in a dark room.
- **H-3** Native `Picker(.menu)` opens from the non-key panel, pointer and VoiceOver.
- **H-4** Hitch lab: player ⇄ Settings swap, worst frame and missed frames, before/after option A.
- **L-1** Lab: all ten sections, en/ru, w480/560/620, top and bottom, and the a11y dump.
