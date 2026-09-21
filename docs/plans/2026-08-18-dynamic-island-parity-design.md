# Dynamic Island — Cyclop 0.6.5 Parity Design

**Status:** Approved

**Date:** 2026-08-18

**Reference:** Cyclop 0.6.5, upstream commit `7ab60c8198681ea6c895fa55458448efb6e4c36e`

**Reference repository:** <https://github.com/akalikbergenov/cyclop>

## Objective

Build Dynamic Island as a production-ready macOS utility with functional and
performance parity with Cyclop 0.6.5, then use that stable base for original
features. Parity covers behavior, interaction, reliability, and resource use. It
does not mean copying Cyclop's product identity, icon, screenshots, website, or
marketing language.

Cyclop is MIT-licensed. Dynamic Island will preserve the required copyright and
license notice in `THIRD_PARTY_NOTICES.md` and retain an MIT license where the
derived code requires it. This design does not grant rights to Cyclop trademarks
or visual identity, so all product-facing assets and copy must be original.

## Foundation and architecture

Implementation will begin in a new `dynamic-island-parity` worktree created from
`main`. The current `shell-music-mvp` branch and its prototype remain untouched
as historical work. Cyclop 0.6.5 at the pinned upstream commit is the behavioral
and implementation reference.

The parity build preserves Cyclop's proven architecture until the parity gates
pass:

- Swift Package Manager application targeting macOS 15 or later.
- AppKit `NSPanel` shell with SwiftUI feature content.
- A fixed maximum window whose internal panel animates between collapsed,
  standard, and teleprompter sizes.
- A private MediaRemote adapter compiled as a helper dylib and hosted by
  `/usr/bin/perl`, communicating through newline-delimited JSON.
- Demand-driven services and timers so inactive features do not consume
  continuous CPU.
- Native macOS frameworks for pasteboard, calendar, translation, login items,
  filesystem interaction, and window management.

Core parity code will not be refactored merely for style while behavior is still
being established. Original extension seams may be introduced only after the
reference test and performance baselines exist, and every change must be compared
against those baselines.

### Product identity

The imported foundation is mechanically rebranded before it becomes a deliverable:

| Concern | Dynamic Island value |
| --- | --- |
| Product name | `Dynamic Island` |
| Executable | `DynamicIsland` |
| Bundle identifier | `dev.dynamicisland.app` |
| Application support | `~/Library/Application Support/DynamicIsland` |
| Saved screenshots | `~/Pictures/DynamicIsland` |

Cyclop's name may remain only where required for attribution, historical notes,
or a clearly identified test reference. Dynamic Island will use an original app
icon, screenshots, interface copy, website content, and release presentation.

> **Amendment 2026-08-28 — renamed to Isla.** "Dynamic Island" is Apple's
> trademark, and moving to an open-core model with a paid tier raises that
> exposure, so the product is renamed **Isla**. The identity table above is
> superseded: product name `Isla`, executable `Isla`, bundle identifier
> `com.ctimothe.isla`, Application Support `~/Library/Application Support/Isla`,
> saved screenshots `~/Pictures/Isla`, URL scheme `isla`, internal pasteboard
> `com.ctimothe.isla.internal`, helper dylib `libislamedia.dylib`; the SwiftPM
> modules became `Isla`/`IslaKit`/`IslaMediaHelper`. "Dynamic Island" survives
> only as a descriptive tagline ("a Dynamic Island–style companion for the Mac
> notch"), never as product identity — `Scripts/test-branding.sh` now bans the
> old identity the way it bans Cyclop's. Rationale and full migration in
> `docs/plans/2026-08-28-isla-open-core-migration.md`.

## Shell and interaction contract

Dynamic Island uses a borderless, always-on-top panel attached to the physical
notch. Displays without a hardware notch receive a synthetic centered notch so
the full product remains available rather than silently disabling itself.

The shell contract is:

| Property | Value |
| --- | --- |
| Standard content size | `620 × 208 pt` |
| Fixed maximum window | `700 × 444 pt` |
| Open delay | `50 ms` |
| Close delay | `320 ms` |
| Tab-hover dwell | `150 ms` |
| Active pointer sampling | `60 Hz` |
| Idle pointer sampling | `8 Hz` |
| Idle threshold | `3 s` |
| Warm pointer zone | `260 pt` high |
| Cool-zone margin | `80 pt` |

The collapsed panel is click-through. The outer window stays at its maximum frame
while internal content changes size, preventing window-level jumps during tab
transitions.

> **Amended 2026-08-22.** Every tab now uses the standard body; the tall
> panel went with the teleprompter. One rail carries Music, Shelf,
> Clipboard and Translate, with Settings held at its foot below a gap —
> the second column existed to hold an overflow that no longer exists.
> Translate is the only tab that requests keyboard focus.

> **Amended 2026-08-26.** The panel opens on a **click**, not on a hover.
> Every point of the compact island opens it and the compact island carries no
> controls; the delays in the table above still govern the hover route, which
> survives as **Open on Hover** in Settings, off by default. The pointer
> machinery, the warm and cool zones and the dwell are unchanged — what changed
> is which gesture commits. A hover now brightens the island's surface and does
> nothing more. Over the lock screen neither gesture opens anything: a hover
> brightens, a click refuses with a shake.
>
> The reason is the one the design's own hardware section implies. The cursor
> crosses the top of the screen constantly — the menu bar, the traffic lights, a
> tab — and a panel that unfolded at each pass interrupts whatever is beneath
> it. A click is a decision; a hover is traffic.

> **Amended 2026-09-10.** "Every point of the compact island opens it," above,
> held only on a physical notch. `collapsedDepth` was `8 pt` on synthetic
> ones — a strip left over so menu-bar status items underneath stayed
> reachable — while `NotchShape` fills black at the full drawn height
> whether or not anything is playing, so the pill was visible at all times
> and roughly three quarters of it was dead to clicks on every non-notched
> display. Reversed: the collapsed target is the drawn shape everywhere.
> Those status items are already hidden under that same shape, so a visible
> target that works is worth more than an invisible one that is merely
> clickable. Held by `CompactHitAreaTests`.

> **Amended 2026-09-10.** The click above opened the panel and said nothing
> about closing it. In practice it pinned itself, and nothing in the default
> configuration un-pinned it: the pointer arriving is what was meant to clear
> the pin, but the controller asked whether Open on Hover was enabled
> *before* clearing it, so with the setting off — the default — the early
> return left the pin standing and the pointer leaving was refused by
> `holdsOpen`. A second click was separately guarded out. Moving the pin-clear
> above that guard and letting a second click close fixed the guard, but not
> the walk-away: the pin is cleared only by an outside→inside pointer
> *transition*, and by the time a click on the island is possible that
> transition has always already happened, so there was no arrival left to
> clear it. The actual fix is that a click delivered by the mouse no longer
> pins at all — `hoverRect(for: openBodySize)` already contains the whole
> clickable island, so the pointer that clicked is already standing where the
> panel holds itself open from, the same fact a hover relies on.
> `NotchViewModel.clickOpened(pointerIsOnPanel:)` decides this from where the
> pointer actually is; ⌥⌘I, the Translate service, and VoiceOver firing the
> island's accessibility action still pin, because none of those routes puts
> the pointer on the panel. The close target itself is a dedicated tap region
> on the open header, not the gesture that spans the whole body — that
> gesture fills the window, and letting it close the panel would close it out
> from under every control pressed inside it. The same arrival rule was also
> flipping the pane off the Shelf the instant a dragged file's pointer crossed
> the island; arrivals during a drag are no longer counted. Held by
> `OpenOnClickTests` and `HoverRectTests`.

> **Amended 2026-08-25.** The standard content size is now `480…620 × 208 pt`,
> defaulting to `560`, chosen from Settings. The fixed maximum window is
> unchanged at `700 × 444 pt` and is cut for the widest body: a narrower
> setting leaves more of the window transparent and resizes nothing. That
> property is deliberate — resizing the panel window across a lock is what
> stretched its window-server snapshot, and is why the lock card was given a
> window of its own.

## Feature parity contract

> **Amended 2026-08-20.** The Snippets and Calendar sections below are
> **withdrawn**: both features were removed from the product by owner
> decision. Their requirements no longer bind, the calendar entitlement
> and its usage strings are gone, and `snippets.json` is no longer read
> or written. The rails, privacy covers, and Settings contract stated
> elsewhere in this document are superseded accordingly. Everything else
> stands.
>
> **Amended 2026-09-14.** Lyrics are entirely offline and local-file-only.
> The session-owned coordinator reads only LRC files the listener imports or
> files in folders the listener explicitly selects; it never downloads,
> uploads, scrapes, or sends lyric data. Imported copies, local bindings, and
> timing corrections remain on that Mac and may be cleared independently.
> Ambiguous metadata never auto-matches. Enhanced LRC word animation requires
> word timestamps plus a measured player position; every other publisher uses
> line-level highlighting. Apple Music lyric text or timing is never scraped.
>
> The optional **Spotify account** remains separate, connected through
> Spotify's own PKCE flow for Liked Songs. The **lock-screen card** remains a
> local presentation feature. Neither changes the offline lyric boundary.

### Music

- Show artwork, title, artist, elapsed time, duration, and progress.
- Support seeking plus previous, play/pause, and next controls.
- Follow the current macOS Now Playing client rather than a single named app.
- Send commands to the active client when the operating system exposes that
  capability.
- Fall back to Music and Spotify scripting/media controls after three consecutive
  helper failures.

> **Amended 2026-09-10.** "Show artwork," above, was being honoured twice. The
> pill drew a 22 pt cover and the open panel drew a 118 pt one, in two files,
> with no relationship between them beyond both reading the same image — so
> opening the panel crossfaded one album past itself: the small cover shrinking
> and fading where it stood while a different, larger cover faded up somewhere
> else. The contract is now that the cover is **one object that travels**. The
> pill and the pane share a geometry identity (`NotchContentView.MorphID`), and
> both ends of the travel are described by one function, `Theme.artworkMetrics`,
> rather than by two hardcoded pairs — an interpolated frame cannot notice that
> its two ends disagree about what shape they are. The equalizer travels the
> same way, from the pill's right wing to the open header's right end, instead of
> switching off on one side of the notch and on again on the other.
>
> One consequence worth stating because it was tried and withdrawn the same
> day. The corner was briefly made proportional — `side / 5.5`, the proportion
> `LockScreenCard` draws its own cover at — which would have moved the open
> cover's radius from 14 pt to 21.5 and the pill's from 6 pt to 4. That
> proportion is right for the 42–62 pt thumbnail it was set on and wrong at
> 118 pt, where 18 per cent reads as a chip rather than a picture; Apple's small
> artwork is proportionally rounder than its large artwork, never the same. Both
> ends keep the radius their own size wants — 6 pt and 14 pt, as they shipped —
> and the morph interpolates the frame between them. The motion is unchanged:
> the travel rides
> `Theme.open(reduceMotion:)`, critically damped, because a click carries no
> momentum to spend on an overshoot; Reduce Motion shortens the travel to a
> 0.12 s ease rather than leaving the cover stranded mid-flight.
>
> Held by `ArtworkMorphTests` — the shared identity, the single description of
> both ends, and the clip that a resizable cover must not lose (a 16:9 thumbnail
> is 211 pt wide in a 118 pt slot). What no unit test can hold is the
> interpolation itself: that one object is seen to move is on the manual pass.

### Shelf

- Accept files dragged into the panel and allow files to be dragged back out.
- Support single selection, modifier-based multi-selection, deselection, open,
  copy, reveal in Finder, remove, and clear.
- Store file references rather than duplicate user files.
- Validate filesystem entries only when the Shelf is opened, so permission
  prompts appear in context and startup remains quiet.
- Accept screenshots copied to the pasteboard and optionally save durable PNGs.
- Load previews lazily and avoid eager reads for every stored file.

> **Amended 2026-09-21.** Cards read newest first by the moment each belongs
> to — when a capture was taken, or when a file was dropped — not by the order
> they arrived, since a capture is found when the Shelf opens rather than when
> it is taken. Each card shows its age under its name ("Just now", "5 min.
> ago"), in the app's language, with the full date on hover. A file moved to a
> Trash counts as removed, and its card leaves.

### Clipboard

- Keep the latest 40 entries for the running session.
- Restore an entry to the public pasteboard when clicked.
- Avoid recording writes made by Dynamic Island itself as duplicate history.
- Conceal entries carrying sensitive pasteboard types.

### Snippets

- Add, edit, remove, search, and copy reusable text entries.
- Reload `snippets.json` whenever the tab opens so external edits become visible.
- Refuse to overwrite an existing unreadable or malformed snippets file.

### Calendar

- Ask for full calendar access only after an explicit user action.
- Allow the user to select which calendars appear.
- Show upcoming events and recognize meeting URLs in event URL, location, and
  notes fields.
- Recognize Google Meet, Zoom, Microsoft Teams, Webex, Whereby, and Jitsi links.

### Translate

- Translate offline between English and Russian with installed macOS translation
  assets.
- Infer direction from the presence of Cyrillic text.
- Explain when a required language pack is missing rather than failing silently.

### Notes and Teleprompter

> **Withdrawn 2026-08-22.** Both features were removed from the product by
> owner decision — tabs, panes, stores, privacy sections, strings and
> tests. They are not deferred and not hidden. The parity claim is
> partial in the same way it already was for Snippets and Calendar.

### Settings and app menu

- Provide launch-at-login control.
- Control whether clipboard screenshots are saved as files.
- Expose relevant application-support and screenshot folders/files.
- Manage selected calendars and feature privacy covers.
- Provide panel-open, version/about, and quit actions through the app menu.

> **Amended 2026-09-10.** These actions live in the Settings tab, not in a menu —
> the status item and its menu went on 2026-08-25 (recorded in `checklist.md`)
> on the grounds that the panel was already the front door. That left nothing at
> all to see on a first launch: `.accessory` with `LSUIElement` means no Dock
> icon, no menu-bar item and no window, the compact header draws `Color.clear`
> while nothing is playing, and neither hotkey appeared in a single user-facing
> string — so a fresh install was indistinguishable from the app having failed to
> start, and `LSUIElement` keeps it out of Force Quit, so somebody who could not
> find the panel could not quit it either. The app now opens its own panel once,
> about 0.8 s into the first launch of an account, onto `WelcomePane`: the app is
> running, it lives at the notch and opens on a click, ⌥⌘I and ⌥⌘T, and Quit is
> in Settings at the bottom left. A pane inside the existing body — not a
> window, not a status item, and not a sixth tab, since something that exists for
> one launch is not somewhere to navigate to. `hasCompletedFirstRun` in the app's
> own defaults is written by an *answer* and by nothing else — Get Started, or a
> tab picked out of the rail — so the contract is **once per account until it is
> answered**, not once per account outright. Everything else that takes the pane
> off screen leaves the flag alone and the next launch offers it again: Escape, a
> click in another app, the screen sleeping or locking, the pointer leaving a
> panel it had been handed, and a file dragged onto the island, which must show
> the shelf it lands on but is not the user answering anything. A display change
> is not any of those — the panel is rebuilt, not ended, so the pane is carried
> across it the same way the selected tab is. Held by `FirstRunTests`, which also
> measures the pane against the shallowest body any Mac can give it in both
> languages, on a machine with no display as well, and by `TabContractTests`,
> which still asserts five tabs.

> **Amended 2026-09-10 (review follow-up).** The 0.8 s open above is skipped
> entirely — pane and all — when the panel is already open, which a file dragged
> onto the island or a click on it inside that delay makes possible. The flag *is*
> the pane, so raising it over a panel opened for something else drew the welcome
> on top of what the user had just asked for and cost `ShelfPane` its drop
> highlight with the file still in the air. The moment goes to the next launch
> instead, which the contract above already allows: nothing was answered, so
> nothing is written. And while the pane shows, the open header names no tab — it
> labels the pane below it, the welcome is deliberately not a tab, and `tab` sits
> on Music underneath, so the strip used to read "MUSIC" over it. Neither is unit
> tested: nothing in the suite builds a panel, so both are on the manual
> first-run pass.

### Privacy mode

Privacy covers apply independently to Clipboard and Translate (Snippets,
Calendar and Notes withdrew with their features).
Rows may be revealed individually, and all temporary reveals reset whenever the
panel collapses. Logs must never contain the concealed user content.

### Localization

English and Russian behavior is preserved, but product-specific wording is
rewritten for Dynamic Island. Localization keys must not depend on the Cyclop
product name.

## Data and permission boundaries

Dynamic Island does not silently import, read, mutate, or delete Cyclop data.
This keeps the installed reference application safe and lets both applications
run independently.

Persistent files are:

- `~/Library/Application Support/DynamicIsland/snippets.json`
- `~/Library/Application Support/DynamicIsland/notes.json`
- `~/Library/Application Support/DynamicIsland/teleprompter.txt`
- `~/Pictures/DynamicIsland/*.png` when screenshot saving is enabled

Shelf file paths, teleprompter speed and font, privacy choices, selected calendars,
launch behavior, and other preferences live in Dynamic Island's bundle-specific
`UserDefaults`. Clipboard history, media state, and translation input remain
transient.

Calendar access is the only explicit application permission and is requested from
inside Calendar. Files in protected Desktop, Documents, or Downloads locations
may prompt through normal macOS filesystem access only when the Shelf needs them.
No accessibility, screen-recording, network account, or background data-upload
permission is introduced for parity.

## Failure handling

Failures stay scoped to the affected feature:

- The media helper emits one bounded JSON object per line and accepts validated
  numeric commands on standard input. It restarts after unexpected termination,
  switches to the fallback after three consecutive failures, and exits as soon
  as the parent closes its input.
- A malformed helper line is ignored without corrupting the last valid media
  snapshot. Runaway lines are bounded.
- An unreadable `snippets.json` is reported and never overwritten.
- Notes, snippets, and teleprompter writes are atomic; note and teleprompter writes
  are debounced where appropriate.
- Shelf entries are removed only after the app can distinguish a missing file from
  denied access.
- Calendar denial disables Calendar only.
- Missing translation assets produce an actionable in-panel state.
- UI and file errors must not crash the shell or disclose private content in logs.

## Performance contract

Performance is compared with signed release builds of Dynamic Island and Cyclop
0.6.5 on the same Mac, account, display, and test session. Each result uses the
median of three equivalent runs to reduce operating-system noise.

| Metric | Release gate |
| --- | --- |
| Closed-panel CPU | `0.0%` throughout a 60-second idle sample |
| Application RSS | Equal to or lower than the Cyclop reference median |
| Helper RSS | Equal to or lower than the Cyclop helper median |
| Interaction responsiveness | Open, close, tab switching, media commands, and scrolling no slower than the reference |
| Lifecycle stability | No orphan helper, growing timer population, or sustained RSS growth after 100 open/close cycles |
| Bundle payload | No larger than the measured reference bundle, plus unavoidable original-asset variance |

Inactive tabs must not retain high-frequency work. Pointer monitoring drops to its
idle rate after three seconds; polling, translation work, previews, and
animations run only when their state requires them. Polling stops entirely
while the display sleeps.

## Verification and release gates

A release is blocked until all of the following pass and the evidence is recorded
in the repository:

1. Swift unit tests for models, persistence, parsing, privacy, and feature services.
2. A media-helper contract test proving valid JSON output, valid numeric command
   handling, restart/fallback behavior, and parent-child shutdown.
3. A clean release build, application bundle, code-signing check, and DMG build.
4. Automated UI smoke coverage followed by Computer Use validation of every tab.
5. Fresh-user Calendar and protected-file permission tests.
6. Physical-notch and synthetic-notch display tests.
7. English and Russian localization review.
8. Quit/relaunch, launch-at-login, corrupt-data, unavailable-helper, and missing-file
   scenarios.
9. Side-by-side performance measurements against the pinned Cyclop reference.
10. A branding scan confirming that Cyclop's icon, identifier, support paths,
    screenshots, marketing copy, and unintended user-visible product strings are
    absent.
11. `LICENSE` and `THIRD_PARTY_NOTICES.md` checks preserving upstream attribution.

> **Amended 2026-09-10.** Item 3's "code-signing check" reads as release
> mechanics; it is a behaviour contract. An ad-hoc-signed `libislamedia.dylib`
> is refused by `/usr/bin/perl` under quarantine, so an unsigned build
> silently loses the MediaRemote path and falls back to AppleScript — Music
> and Spotify only — while telling the user nothing. `Scripts/test-gatekeeper.sh`
> now measures the outside view directly: Developer ID on the bundle and the
> nested dylib, `spctl` acceptance, a stapled ticket, and a quarantined
> `dlopen`. It skips loudly on an ad-hoc build rather than blocking the
> development loop, and runs from CI and from `Scripts/release.sh` after
> `Scripts/test-package.sh`, where `DEVELOPER_ID_APPLICATION` is already
> required — so a release can no longer skip it.

## Delivery sequence

1. Create the isolated parity worktree and capture a pristine Cyclop 0.6.5
   reference baseline.
2. Import the pinned MIT-licensed foundation and add attribution before modifying
   derived files.
3. Rebrand identifiers, paths, user-visible text, and assets without behavioral
   refactoring.
4. Repair build, helper, persistence, and packaging contracts under the new
   identity.
5. Establish automated tests and the side-by-side performance harness.
6. Verify every parity feature, failure mode, permission path, and display mode.
7. Produce the signed release artifact and complete the release checklist.
8. Begin original product features only after the parity baseline is green.

## Explicit non-goals for the parity phase

- Adding cloud sync, accounts, analytics, network services, or new permissions.
- Importing the user's Cyclop data without a separately approved migration design.
- Reusing Cyclop's icon, website, screenshots, or marketing copy.
- Large architectural rewrites before parity and performance are demonstrated.
- Treating the earlier shell/music prototype as the production implementation.
