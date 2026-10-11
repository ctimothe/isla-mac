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

> **Amended 2026-10-11 — the keyboard can end what the keyboard opened.** A
> pinned panel (⌃⌥⌘I, Show Isla, ⌃⌥⌘L, the welcome, the island's
> accessibility action) promised to close on Escape and did not: the panel is
> key only while Translate asks for the keyboard, so Escape went to the app
> underneath. And ⌘-Tab left it standing over the next app's menu bar. Now,
> while a pin stands and the panel is not key, Isla holds plain Escape through
> a transient Carbon hot key (no permission), registered when the pin starts
> and given up the moment it ends, however it ends. Escape then does what it
> does in a key panel: a pane that wants it first, the fold second. It is not
> held while the panel is key (the panel reads Escape itself, after any input
> method), while Isla is the active app (Quick Look and AirDrop windows answer
> Escape), or over the lock screen. Another app coming to the front ends a pin
> the way a click in another app already did; Isla's own activation does not.
> Key status is unchanged: the panel still never becomes key outside Translate
> and the shortcut recorder. Making keyboard-opened panels key was the other
> route and was not taken here; it is owner decision 1. The cost is that the
> one Escape pressed while a pin stands goes to Isla rather than to the app in
> front, and that a Quick Look or AirDrop window closing ends the pin, because
> macOS hands activation back to the previous app. Held by
> `PinnedKeyboardTests`.

> **Amended 2026-10-11 — arriving at an open panel keeps its tab.** The
> 2026-09-10 arrival rule above both dropped the pin and selected Music, on
> every arrival. Music is the right landing for arriving at the *closed*
> island — it is for glancing at a track, and the other tabs are somewhere to
> go once it is open — and that is unchanged. But ⌃⌥⌘I opens the panel on
> whatever tab was left, with the pointer elsewhere, and the hand then
> reaching for a Clipboard row was an arrival too: the pane swapped to Music
> under it. An arrival on a panel that is already open now only drops the pin
> (which also gives back the Escape it held); the tab stays where it is.
> Dropping the Music landing altogether was rejected, because it would reverse
> the closed-island behaviour. Held by
> `OpenOnClickTests.testArrivingOnAPanelTheKeyboardOpenedKeepsItsTab`.

> **Amended 2026-08-25.** The standard content size is now `480…620 × 208 pt`,
> defaulting to `560`, chosen from Settings. The fixed maximum window is
> unchanged at `700 × 444 pt` and is cut for the widest body: a narrower
> setting leaves more of the window transparent and resizes nothing. That
> property is deliberate — resizing the panel window across a lock is what
> stretched its window-server snapshot, and is why the lock card was given a
> window of its own.

> **Amended 2026-09-21.** The tab-hover dwell in the table above is withdrawn:
> the rail changes tabs on a **click** only. Switching after a 150 ms hover made
> the rail react to a pointer passing through it, and each switch replayed the
> chosen glyph's fill, so a fast pass read as the rail lagging behind the
> cursor. A hover now draws a faint well under the glyph and does nothing else,
> the same division the island itself made on 2026-08-26 — a click is a
> decision, a hover is traffic.

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

> **Amended 2026-09-21.** The tab translates between sixteen languages, chosen
> in its two column headings: English, Russian, Uzbek, Kazakh, Turkish,
> Ukrainian, German, French, Spanish, Italian, Portuguese, Arabic, Hindi,
> Chinese, Japanese and Korean. The source detects by default and can be told;
> a swap exchanges the languages and the text; the choice is remembered.
> Inferring direction from Cyrillic survives as the default rather than the
> whole rule: with the source on Detect and the target on Russian, Russian goes
> to English and everything else to Russian, as before.
>
> Each pair goes to the best engine the Mac has, first that can: Apple's
> Translation framework for a pair it reports installed; the on-device language
> model for the languages it supports, plus Russian; and, only when **Translate
> Online** is switched on in Settings — off by default — MyMemory, for a pair
> neither of those offers at all. A pair the Mac offers is never sent, even
> when it cannot run right now; it is reported instead. English and Russian
> therefore still translate offline. Uzbek
> and Kazakh have no on-device engine at all — measured on 2026-09-21, the
> framework does not offer them and the model answered with nonsense — so for
> them the tab says the language is translated online and offers the switch.
> The online path is the exception recorded in `checklist.md` §"Scope divergence
> from Cyclop 0.6.5", bounded to one file and one service by
> `OnlineTranslationTests`. A pair the framework offers but has not downloaded
> names its language and opens System Settings' Translation Languages.

> **Amendment 2026-10-11 — the one-line lyric reads ahead.** A lyric line lit
> exactly as the voice arrives is exact to the clock and late to a person: a
> singer reads a line before they sing it. The island's closed one-line
> caption therefore turns to the next line about 0.5 s before it is sung,
> drawn unswept like any upcoming line, for a transition with no honoured end
> (continuous singing). The turn is `min(readAhead, 0.45 × the line it leaves)`
> early and never before that line's final word starts; a transition with an
> honoured end (a silence of 1.5 s or more), an intro, an outro, the stage,
> the lock card, the Shortcuts "line playing right now" action and every
> word-timed highlight are unchanged. It is a pure function of the clock
> position — `LyricSweep.readingMoment` — so a seek or a pause gives the answer
> playing through would have, and the boundary wakes
> (`LyricsCoordinator.registerBoundaries`) are armed for it so the caption
> turns on time. **Settings > Music > Show next line early** (Off, 0.25 s,
> 0.5 s default, 0.75 s; `lyrics.readAhead`) sets it. Display only; nothing
> leaves the machine. The lab's L9 case measures it over the corpus.
>
> **Amended 2026-10-11 (ly/READ-02) — the default is Auto, not a fixed 0.5 s.**
> After trying the fixed 0.5 s the owner found it perfect on a slow ballad of
> long lines and a bit much elsewhere, and asked that it never go below 0.30 s.
> The setting is now Off, **Auto (default)**, 0.3 s, 0.5 s (0.25 s and 0.75 s
> are withdrawn). Auto turns `clamp(0.30 + 0.004 × n, 0.30, 0.50)` seconds
> early, `n` being the visible characters (`Character` count, trimmed) of the
> line turned *to*: 0.30 s for a few words, 0.42 s for thirty characters,
> 0.50 s from fifty. Every limit above still applies on top of it, so the 45
> percent cap may pull a single transition under 0.30 s when the line it
> leaves is under about 0.67 s long — the cap protects the line being sung and
> outranks the floor. `lyrics.readAhead`: an absent key is Auto, a stored 0 is
> Off, and any other stored number snaps to the nearer of 0.3 and 0.5 (an old
> 0.25 reads as 0.3, 0.75 as 0.5, 0.5 as a fixed 0.5).

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

> **Amended 2026-09-23 — shortcuts.** The three global shortcuts move from
> ⌥⌘I, ⌥⌘T and ⌥⌘L to ⌃⌥⌘I, ⌃⌥⌘T and ⌃⌥⌘L, and each can be rebound or
> cleared in a **Keyboard Shortcuts** section of Settings. macOS binds none of
> the old keys system-wide, but apps bind all three: ⌥⌘I is Web Inspector and
> Developer Tools in every browser, ⌥⌘L is Downloads in Safari, Chrome and
> Finder, and ⌥⌘T hides Finder's toolbar. A Carbon hot key wins over the app in
> front, so Isla took those keys without saying so. Recording a shortcut uses
> the same keyboard claim as Translate. A combination macOS refuses is named in
> Settings, not swallowed. The welcome prints the live bindings, and its second
> row is the lyrics shortcut; Translate's is listed in Settings with the others.
> Held by `HotKeyTests`, `FirstRunTests` and `LyricRoutesTests`.

> **Amended 2026-10-11 — the welcome names the tabs (H-020).** The welcome
> named none of the five tabs, said "click it to open" on a panel that had
> already opened itself, left ⌃⌥⌘T out, and the rail lit Music over it, so
> VoiceOver read "Music, selected" on a pane that is not a tab. It is two
> columns now. On the left, one line level with each rail icon, in the rail's
> own row height, gap and footer gap: what's playing with the lyrics shortcut,
> the shelf, the clipboard kept in memory, the translate shortcut, and privacy,
> shortcuts and Quit beside Settings. On the right: Isla is running; there is
> no Dock or menu-bar icon, and a click on the notch or the open shortcut
> brings it back; nothing leaves the Mac unless it is turned on; Get Started.
> Every shortcut is the live binding, and a cleared one is left out of its
> line rather than printed as a gap. While the welcome shows no rail tab is
> lit or selected — `tab` still sits on Music underneath, so Get Started lands
> there. The second paragraph of the 2026-09-23 shortcuts amendment, that the
> welcome lists the lyrics shortcut and not Translate's, is withdrawn by this
> one. Held by `FirstRunTests`, which measures both columns in both languages
> at the narrowest panel against the 154 pt body.

> **Amended 2026-09-23 — what can be found, and switched off.** The lyrics page
> offers the way out of its own dead ends. With lyrics off it offers **Show
> Lyrics**. When no local file matched and the online lookup is off it offers
> **Look Up Online**, with the LRCLIB disclosure beside the button. Both write
> the same keys the Settings switches do, so turning one on from the page is
> the same informed choice. Clipboard history has an off switch (Settings →
> Privacy, default on). Off, copies are neither read nor kept and the list is
> emptied. The pasteboard is polled only while history or clipboard
> screenshots want it. When Spotify refuses the library, Settings shows
> Spotify's reason: an account not admitted while the app is in development
> mode, Premium required, or other. Before, the heart vanished without a
> word. Held by `FindabilityTests`.
>
> **Amended 2026-10-11 — a Spotify refusal is not for life, and Premium is
> not the listener's.** The sentence above stands with two corrections.
> Spotify's February 2026 rules put the Premium requirement on the
> developer who registered a Development Mode app, so the Premium reason
> now reads "Spotify refused Liked Songs and named Premium. Spotify asks
> this of Isla's own registration, so your plan may not be the cause."
> instead of telling the listener to upgrade. And a refusal no longer lasts
> until relaunch: the account asks again ten minutes after a 403, and a
> disconnect or a new grant clears it, so the note never outlives the
> account it was about. The heart's lookup moved to Spotify's
> `/me/library` endpoints with track URIs on the same day, because the old
> saved-tracks endpoints were retired for Development Mode apps on
> 2026-03-09. Held by `SpotifyAccountTests` and `FindabilityTests`.
>
> **Amended 2026-10-11 — lyrics off means off.** "Lyrics are off" and its
> Show Lyrics offer now mean only that the switch is off. A track that
> cannot be looked up by any source says so instead, with no offer: a
> stream, radio station or browser tab with no length reads "No lyrics for
> live audio." once it has played for 1.5 s without one (players publish
> the title before the length, so every ordinary song passes through "no
> length" on its way in), and a blank title reads "This track has no title
> to look up." Before, both said "Lyrics are off." beside a Show Lyrics
> button that rewrote an already-true switch and could not work. The miss
> copy is one plain vocabulary that still says what was searched: "No
> lyrics on this Mac." with the online lookup off (Look Up Online is still
> offered beside it on the page), "No lyrics found for this song." with it
> on, and "Can't read the lyrics file for this song." for a file that is
> there but unreadable. The lock card shows the same copy and offers
> nothing: a network switch is not turned on over the shield. Held by
> `LyricsCoordinatorTests`, `LyricCaptionCopyTests` and `FindabilityTests`.

> **Amended 2026-09-23 — the island without music.** The charger going in
> and a Bluetooth audio output appearing each grow the pill out of the notch
> for 2.2 s. The glyph sits in the left wing and the level or device name in
> the right, white on black. It has the track peek's restraint (never open,
> under the pointer, mid-drag, locked or dark), and each has a switch in
> Settings → General, on by default. Sources: IOKit power-source
> notifications and the CoreAudio device list, with no permission and no
> polling. Shelf cards gain Quick Look (the system panel) and AirDrop (the
> system sheet) in their context menu. Both act on the selection like a
> drag does. Both activate the app, because each opens a window the user
> must work in, and both hand activation back to the app that had it when
> that window closes. Quick Look is driven through `AppDelegate` as its
> controller, the documented way. Headphones are tracked by device UID and
> stay quiet for 30 s after being announced, and the owner's name is taken
> off the device name. Held by `AmbientMomentTests` and
> `ShelfSharingTests`. Quick Look, AirDrop and the two moments have not
> been checked on hardware yet (see `checklist.md`).

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
