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

## Shell and interaction contract

Dynamic Island uses a borderless, always-on-top panel attached to the physical
notch. Displays without a hardware notch receive a synthetic centered notch so
the full product remains available rather than silently disabling itself.

The shell contract is:

| Property | Value |
| --- | --- |
| Standard content size | `620 × 208 pt` |
| Teleprompter content size | `620 × 400 pt` |
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
transitions. The teleprompter is the only tall panel and keeps the panel open
while scrolling.

The left rail contains Music, Shelf, Clipboard, Snippets, Calendar, and Translate.
The right rail contains Notes, Teleprompter, and Settings. Translate, Snippets,
and Notes explicitly request keyboard focus when active.

## Feature parity contract

### Music

- Show artwork, title, artist, elapsed time, duration, and progress.
- Support seeking plus previous, play/pause, and next controls.
- Follow the current macOS Now Playing client rather than a single named app.
- Send commands to the active client when the operating system exposes that
  capability.
- Fall back to Music and Spotify scripting/media controls after three consecutive
  helper failures.

### Shelf

- Accept files dragged into the panel and allow files to be dragged back out.
- Support single selection, modifier-based multi-selection, deselection, open,
  copy, reveal in Finder, remove, and clear.
- Store file references rather than duplicate user files.
- Validate filesystem entries only when the Shelf is opened, so permission
  prompts appear in context and startup remains quiet.
- Accept screenshots copied to the pasteboard and optionally save durable PNGs.
- Load previews lazily and avoid eager reads for every stored file.

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

### Notes

- Provide a scratch-note list and editor with add, copy, and delete actions.
- Move keyboard focus into the editor when the tab is opened.
- Use the first line as the note's list title.
- Debounce persistence and remove blank notes when leaving the tab.

### Teleprompter

- Persist a plain-text script.
- Scroll smoothly at a configurable speed from `0.3×` through `3×`.
- Support a font size from `18 pt` through `64 pt`.
- Keep the panel open while the script is running.
- Stop scrolling and release the hold-open state when the user leaves the tab or
  the panel is otherwise closed.

### Settings and app menu

- Provide launch-at-login control.
- Control whether clipboard screenshots are saved as files.
- Expose relevant application-support and screenshot folders/files.
- Manage selected calendars and feature privacy covers.
- Provide panel-open, version/about, and quit actions through the app menu.

### Privacy mode

Privacy covers apply independently to Clipboard, Snippets, Calendar, and Notes.
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
| Bundle payload | Target the reference's approximately 2.1 MB; document only unavoidable original-asset variance |

Inactive tabs must not retain high-frequency work. Pointer monitoring drops to its
idle rate after three seconds; polling, translation work, calendar refreshes,
previews, and animations run only when their state requires them.

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
