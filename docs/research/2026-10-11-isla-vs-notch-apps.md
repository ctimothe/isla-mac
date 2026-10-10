# Isla against the field: 10 open-source and 10 paid notch apps

Researched 2026-10-11. Isla is read from `main` at `300f245`. Competitors are read from their repos, vendor pages, changelogs, App Store pages and reviews as of the same day.

## Verdict

- **Isla is the fifth-broadest of 21 apps** on the 34 music, productivity and system rows below (Pulse Island 25.0, MacNotch 22.0, Atoll 21.5, Crest 21.5, Isla 21.0, Sapphire 20.0; a full feature scores 1, a partial one 0.5). The score counts rows Isla removed on purpose (Calendar, Notes, Teleprompter), so it understates how focused the product is.
- **Isla's moat is lyrics plus the lock screen.** Only three other apps ship word-by-word lyrics (Lyrimuse, MacNotch, Dynamic Lyrics). Only Lyrimuse has a local lyric-file workflow (Dynamic Lyrics imports TTML), and none documents an editor like Isla's. As far as the sources show, no other app combines a lock-screen player card with lyrics on it, a Quick Look and AirDrop shelf, and Apple's on-device translation across 16 languages.
- **Isla trails on the front door, not on features.** It has no Developer ID signing or notarization, no auto-updater, a public build stuck at 0.2.0 with a recorded NO-GO release verdict, two UI languages, and about 8 GitHub stars (2026-09-23 baseline) against boring.notch's 10,989. Seven competitors confirm notarized builds, five of them paid; five open-source apps (boring.notch, DynamicNotch, MewNotch, Lyrimuse, OpenYoink) document the same gap Isla has, and boring.notch still has 10,989 stars, so notarization alone does not explain the traction gap.
- **The one feature gap that matters most is the volume and brightness HUD.** Thirteen of 20 competitors replace the system HUD; Isla has not built it.

## Isla today

Everything below is on `main`. The public DMG is 0.2.0 and lacks several recent items (diagnostics, update check, rebindable shortcuts); `checklist.md` lists exactly which. Default state is in brackets where it is not "on".

### Music and media
- Shows the single Now Playing session macOS reports, whichever app owns it, through a helper hosted in `/usr/bin/perl`. The Swift app never links MediaRemote.
- **Music Only filter** [on]: an allowlist of 18 music and podcast apps, sessions the player labels as audio, and Telegram songs. Films and browser video are dropped.
- When Now Playing closes, falls back to AppleScript for Apple Music and Spotify. Four named failure causes are written out in Settings and the empty Music tab, with Try Again. A dead helper restarts with backoff.
- Play and pause, next and previous (previous restarts the song after 3 s), shuffle and repeat indicators, system media-key fallback. Controls dim when the session cannot answer.
- Drag-to-seek scrubber with hover time preview, millisecond seeks, playback-rate-aware clock, VoiceOver support.
- A song loaded in Music or Spotify stays on the island when a film takes Now Playing. A paused stranger cannot take over for 10 s.
- Compact pill with cover, equalizer, paused cover with play badge, and a peek when a new track starts [on].

### Lyrics
- **Show Lyrics** [off]. A one-line caption under the scrubber, and a full lyrics page with reading mode, a Sync pill, click-a-line-to-seek, copy line and copy all.
- Sources: local LRC files (watched folders, automatic matching, bind and unbind per track, word-timed LRC), and LRCLIB online lookup [opt-in, cached]. Online lyrics are line-level only.
- **Word karaoke** [off], for word-timed local files only. Isla never invents word timing and never scrapes lyrics.
- Lyric lead, global delay (±3 s) and per-track nudge (±1.5 s).
- **Local lyric editor** with Save Copy (original untouched), LRC export, and a validation and word-timing guard.

### Spotify and audio
- One-click Spotify connect (PKCE, tokens in the keychain) [opt-in]. Liked Songs heart on the lock card, track lookup. Scope is library only: no playlists, search or queue.
- Sound output picker with live tracking and output volume, on the lock card only.

### Lock screen
- The pill stays over the lock screen, visible but inert (a click shakes).
- **Player card over the shield**: Transparent, Tinted or Solid glass; Standard or Compact size; cover lights the glass; lyrics on the card; output picker; volume; Liked Songs heart. A Show on Lock Screen switch turns it off.

### Shelf, captures, clipboard
- **Shelf**: drop any file, including Mail, Photos and browser drags. 60-card cap, references files instead of copying them, survives relaunch and follows moved files. Multi-select, group drag-out, double-click opens, hover X removes, context menu, **Quick Look**, **AirDrop**, copy back to the pasteboard, Show in Finder, two-press Clear.
- **Screen captures**: Screenshot.app pictures and recordings are picked up onto the Shelf when it opens [on]. A vault for clipboard screenshots keeps 200 [opt-in].
- **Clipboard history**: 40 entries of text and files, memory only. Skips password-manager and machine-made copies, pauses while locked or asleep, has an off switch. No pictures, search, pinning or sync.

### Translate
- Live two-column translator, 16 languages, auto-detect, swap, remembers languages.
- Engines: Apple Translation on device, the on-device Apple Intelligence model, and MyMemory online [opt-in].
- Ctrl-Opt-Cmd-T translates the clipboard; the Services item "Translate in Isla" translates a selection.

### Ambient moments
- The island shows the charger going in and headphones connecting [on]. Moments yield to the open panel and to the pointer.

### Shell and interaction
- Borderless panel that hugs the physical notch and draws a synthetic notch on displays without one. Repairs itself on display changes, sleep and wake.
- A click opens it. A hover only brightens it; **Open on Hover** is opt-in. Walk-away close, Escape, click-through outside the island. Panel width 480 to 620.
- Five tabs on one rail (Music, Shelf, Clipboard, Translate, Settings). No Dock icon, no menu-bar item, no window.
- Hidden from screen recording [on]. Per-section privacy covers for Clipboard and Translate [off].

### Automation and keyboard
- Three global shortcuts, rebindable, needing no permission: open the panel, translate the clipboard, lyrics page.
- App Intents for Shortcuts and Siri: Show Lyrics, Show Isla, Get Current Lyric, Get Current Track, Set Lyric Delay, Play or Pause, Next, Previous.

### Look and accessibility
- Liquid Glass on macOS 26, a drawn glass recipe elsewhere. Reduce Transparency, Increase Contrast and Reduce Motion are honored live. Critically damped springs. Haptics on two moments. VoiceOver labels across the island, tabs and lock card.

### Settings and distribution
- Launch at Login, Open on Hover, hover delay, panel width, lock-card style, privacy switches, update check (manual, or automatic [opt-in]; check-only), Copy Diagnostics, Report a Problem, first-run welcome pane.
- UI in English and Russian. Free, MIT licence. macOS 15 or later, universal build (Intel unvalidated). One entitlement (Apple Events). No telemetry, no Isla account. Ad-hoc signed, not notarized; GitHub Releases DMG.

### Deliberately absent
Snippets and Calendar (removed 2026-08-20), Notes and Teleprompter (2026-08-22), the status-item menu and main window (2026-08-25). Never built: a volume or brightness HUD, timers, a camera and microphone in-use pill, a camera mirror. Also absent by decision: unsynced lyrics, Dynamic Type, cloud sync, an auto-installing updater (until Developer ID exists), Mac App Store distribution.

## The field

Chosen from 111 candidates found by five web sweeps. Selection rule: a general-purpose notch or Dynamic Island app that is alive (release or commit in the last six months), ranked by traction and relevance to Isla's music, shelf and system scope. Left out on purpose: AI-coding-agent monitors (Vibe Notch 2,518 stars, CodeIsland 2,487, Ping Island, notchi), teleprompters (Textream 4,001, notchprompt), novelty apps (Notch Simulator, Notchmeister), libraries (DynamicNotchKit), narrow notes or teleprompter apps (Notchkin, Notchie) and abandoned repos (Peninsula, last push 2025-10). Reserves that nearly made it: SuperIsland (672 stars, no licence file), DynamicHorizon, NotchBay, Notchy.

| App | Kind | Price (2026-10-11) | Licence | Traction | Latest release | Min macOS |
|---|---|---|---|---|---|---|
| boring.notch | open-source | Free | GPL-3.0 | 10,989 stars; v2.7.3 DMG about 909k downloads | v2.7.3 2025-11-24 (v2.8-rc.2 pre-release 2026-10-10) | 14 |
| Atoll | open-source | Free | GPL-3.0 | 4,902 stars; v2.3.3 DMG about 72k downloads | v2.3.3 2026-07-24 | 14 |
| coucou | open-source | Free | MIT (name and mascot reserved) | 4,679 stars; repo created 2026-09-27 | 0.2.3 2026-10-08 | 15 |
| NotchDrop | open-source | Free (App Store $0, or build from source) | MIT | 2,125 stars | App Store 2.16 2024-11-25; 0 GitHub releases | 13 |
| DynamicNotch | open-source | Free (donations) | GPL-3.0 | 586 stars | v1.6.3 2026-10-05 | 14.6 |
| MewNotch | open-source | Free | GPL-3.0 | 556 stars | 2.2.3 2026-10-07 | 14 |
| Cyclop | open-source | Free | MIT | 360 stars; Isla's parity base | 0.8.3 2026-10-06 | 15 |
| Sapphire | open-source code, paid tiers | Free; Basic $15.99/mo, Pro $25.99/mo, Ultra $30.99/mo | AGPL-3.0 | 293 stars; v3.0 about 35k downloads | v3.0 2026-09-15 | not stated (15.5 mentioned) |
| Lyrimuse | open-source | Free (donations) | GPL-3.0 | 219 stars; repo created 2026-07-10 | v1.10.0 2026-10-08 | 14 |
| OpenYoink | open-source | Free | MIT | 212 stars; repo created 2026-08-18 | v1.7.2 2026-10-10 | 15 |
| NotchNook | paid | $25 lifetime (5 Macs) or $3/mo; last documented, vendor page returned 402 | Proprietary | AlternativeTo 10 likes; press 2024 | 1.6.2 2026-06-25 | 14 |
| Alcove | paid | $14.99 one-time, 72 h trial | Proprietary | AlternativeTo 11 likes (5.0 from 3 ratings); Homebrew 3,176 installs a year | 1.7.7 (date not shown) | 15 |
| DynamicLake Pro | paid | One-time, $13.99 to $16.90 depending on source; not confirmed | Proprietary | AlternativeTo 6 likes | 1.9.8, Oct 2026 | 14 (unverified) |
| MediaMate | freemium | About EUR 7 one-time; not confirmed | Proprietary | 133 stars on its releases repo; MacStories review | 3.8.4 (2026) | 13 |
| MacNotch | paid, also Setapp | $22.99 once (3 Macs) or $3.99/mo, 14-day trial | Proprietary | Setapp 97% from 33 ratings; Product Hunt 198 upvotes | 1.9.9.7 2026-10-08 | 14 |
| Islet | paid | $5.99 launch price, one-time | Proprietary | Product Hunt 129 upvotes | 2.4.1 2026-08-01 | 15 |
| Pulse Island | paid | $7 one-time (launch offer), 7-day trial | Proprietary | Product Hunt 112 upvotes | 1.3.2 2026-09-26 | 14 |
| Crest | freemium | Free tier; Pro $19.99 one-time, with Take and Minutes $24.99; or $2.99/mo | Proprietary | Product Hunt 139 upvotes | 6.4.1 2026-10-07 | 14 |
| Dynamic Lyrics | freemium | Free; Premium $1.49/mo, $4.99/yr or $9.99 lifetime | Proprietary | App Store 4.3 from 9.1K ratings | 2.0.5 2026-09-17 | 14.6 |
| NotchFlow | paid | $20 lifetime (monthly plan also) | Proprietary | Product Hunt 166 upvotes | launched 2025; no version found | 14 |


## Capability matrix

● has it · ◐ partial, opt-in, paid-tier only, or only some players · ○ a source says it is absent or removed · · sources are silent (read as "not found", not "no"). Isla's column is from its own code, so its ○ rows are certain.

| Capability | Isla | boring.notch | Atoll | coucou | NotchDrop | DynamicNotch | MewNotch | Cyclop | Sapphire | Lyrimuse | OpenYoink | NotchNook | Alcove | DynamicLake Pro | MediaMate | MacNotch | Islet | Pulse Island | Crest | Dynamic Lyrics | NotchFlow |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| M1 Any Now Playing source | ● | ◐ | ◐ | ◐ | · | · | ◐ | ● | ● | ◐ | ◐ | ◐ | ◐ | ◐ | ◐ | ● | · | ● | ● | ◐ | ◐ |
| M2 Transport controls | ● | ● | ● | ● | · | ● | ● | ● | ● | ◐ | ◐ | ● | ● | ● | ● | ● | ● | ● | ◐ | · | ● |
| M3 Scrubber / seek | ● | ◐ | ◐ | ◐ | · | · | ● | ● | ● | ● | ◐ | · | · | · | ◐ | ◐ | ● | ● | ● | · | · |
| M4 Synced lyrics (line) | ● | ● | ◐ | · | · | ● | · | · | ◐ | ● | · | · | · | · | · | ● | · | ● | ● | ● | · |
| M5 Word-by-word lyrics | ◐ | · | ◐ | · | · | · | · | · | · | ● | · | · | · | · | · | ● | · | · | · | ● | · |
| M6 Online lyrics lookup | ● | · | ● | · | · | ● | · | · | · | ● | · | · | · | · | · | ◐ | · | ● | ● | ● | · |
| M7 Local lyrics import / editor | ● | · | · | · | · | · | · | · | · | ● | · | · | · | · | · | · | · | · | · | ◐ | · |
| M8 Lyrics translation | ○ | · | · | · | · | · | · | · | · | ● | · | · | · | · | · | · | · | · | · | ● | · |
| M9 Spotify account integration | ◐ | ◐ | ◐ | · | · | · | · | · | ◐ | · | · | · | · | ◐ | · | · | ◐ | · | · | ◐ | · |
| M10 Audio output switcher | ◐ | ◐ | ◐ | · | · | · | · | · | ◐ | · | · | · | · | · | · | ◐ | ● | ● | ● | · | · |
| M11 Volume control in island | ◐ | ● | ◐ | ◐ | · | · | ◐ | · | ● | ◐ | · | ○ | · | ◐ | ◐ | ◐ | · | ● | ● | ◐ | · |
| M12 Artwork colour / visualizer | ◐ | ● | ● | · | · | ● | · | · | ◐ | ● | ◐ | ● | · | ◐ | · | ● | · | ● | ● | · | · |
| M13 Lock-screen media card | ● | ◐ | ● | · | · | ● | · | · | ● | · | · | · | · | · | ◐ | ○ | · | · | · | ◐ | · |
| S1 File shelf | ● | ● | ● | ◐ | ● | ● | ● | ● | ● | · | ● | ● | ○ | ● | · | ● | ● | ● | ● | ○ | · |
| S2 AirDrop / share from shelf | ● | ● | ◐ | ◐ | ● | ○ | · | · | ● | · | · | ● | · | ● | · | ● | · | ● | ● | ○ | · |
| S3 Quick Look | ● | ◐ | ● | · | · | · | · | ◐ | · | · | ● | · | · | · | · | · | · | · | · | · | · |
| S4 Clipboard history | ● | · | ● | · | · | · | · | ● | ● | · | ◐ | · | · | · | · | ○ | ● | ● | ● | ○ | · |
| S5 Translate | ● | · | · | · | · | · | · | ● | · | ◐ | · | · | · | · | · | ● | · | · | ● | ◐ | · |
| S6 Screenshot / recording pickup | ● | · | · | · | · | ○ | · | ● | · | · | · | · | · | · | · | ◐ | · | ● | ● | · | · |
| S7 Privacy cover / hide from screen share | ● | ● | · | · | · | · | · | ● | · | ◐ | · | · | · | · | · | · | · | ● | ◐ | · | · |
| S8 Notes / to-do | ○ | · | ● | · | · | · | · | ● | ● | · | · | ◐ | · | · | · | ● | ● | ● | ◐ | · | · |
| S9 Calendar / meetings | ○ | ● | ● | ◐ | · | ○ | · | ● | ● | · | ◐ | ◐ | ● | ● | · | ● | ● | ● | ◐ | · | · |
| S10 Timer / Pomodoro | ○ | · | ● | · | · | ● | · | · | ◐ | · | ● | · | · | ● | · | ● | ● | ● | ◐ | · | ● |
| S11 Weather | ○ | ○ | ● | · | · | · | · | · | ● | · | · | · | · | ● | · | ● | ● | ● | ◐ | · | · |
| S12 Camera mirror / teleprompter | ○ | ● | · | · | · | ○ | ◐ | ● | ● | · | · | ● | · | · | · | · | · | ● | ● | · | · |
| S13 Other utilities | ○ | ● | ● | ● | · | · | ● | ● | ● | · | ● | ● | · | ● | · | ● | ● | ● | ◐ | · | ● |
| H1 Volume / brightness HUD replacement | ○ | ● | ● | · | · | ◐ | ● | · | ◐ | · | · | ● | ● | ◐ | ● | ● | ● | · | ◐ | ● | · |
| H2 Charging peek | ● | ● | ● | · | · | ● | ◐ | · | · | · | ● | · | ◐ | ◐ | · | ◐ | ● | ● | ◐ | · | · |
| H3 Bluetooth / headphones peek | ● | ○ | ● | · | · | ● | ◐ | · | ● | · | · | · | ◐ | ● | ◐ | ● | ● | ● | ◐ | ◐ | · |
| H4 Other live activities | ○ | ◐ | ● | ◐ | · | ● | ◐ | · | ● | · | ● | ◐ | ◐ | ● | · | ● | ● | ● | ◐ | · | · |
| H5 Lock-screen presence | ● | ● | ● | ◐ | · | ● | ● | · | ● | · | · | · | ● | ● | ◐ | ◐ | · | · | · | ● | · |
| H6 Notchless-Mac support | ● | ◐ | ○ | ● | · | ● | ◐ | ● | · | ● | ● | ● | ◐ | ● | ● | ● | ○ | ● | ● | · | · |
| H7 Multi-display | ◐ | ◐ | · | ● | · | ● | ● | ● | ◐ | ◐ | ● | ◐ | · | ● | ● | ● | · | ● | ● | · | · |
| H8 AI coding-agent monitor | ○ | · | ◐ | ● | · | · | · | · | ◐ | · | ○ | · | · | · | · | ◐ | ○ | ● | ● | · | · |
| P1 Global hotkeys | ● | ◐ | ● | ● | · | · | · | · | ● | ◐ | ● | · | · | ● | ◐ | ● | · | ◐ | ● | · | · |
| P2 Shortcuts / App Intents | ● | · | · | ◐ | · | · | · | · | ● | ◐ | · | ● | · | · | ● | ● | · | ○ | ● | · | · |
| P3 Extensions / plugins / widgets | ○ | ○ | ◐ | ◐ | ◐ | · | ◐ | · | ◐ | · | ○ | ◐ | · | ● | · | ◐ | · | · | · | ◐ | · |
| P4 Gestures (swipe / scroll) | ○ | ● | ● | ◐ | · | ● | · | · | ◐ | · | ◐ | ● | ● | ● | ● | ◐ | · | ● | ● | · | · |
| P5 Liquid Glass (macOS 26) | ● | · | · | · | · | · | ◐ | · | ● | · | · | · | · | ◐ | ◐ | ● | ● | ◐ | · | · | · |
| P6 Accessibility (VoiceOver, reduce motion) | ● | · | ◐ | · | · | · | · | ◐ | · | ◐ | ◐ | · | · | ◐ | · | · | · | ◐ | ◐ | · | · |
| P8 Auto-update | ◐ | ● | ● | ◐ | ◐ | ● | ● | ○ | ● | ● | ● | ● | ● | ● | ◐ | ● | ● | ● | ● | ◐ | ◐ |


Row notes: P-rows (min macOS, price, licence, last release) are in the field table, not the grid. "Other utilities" covers window snapping, launchers, terminals, system monitors and similar.

## Where Isla leads

| Row | Competitors with it (of 20) | Note |
|---|---|---|
| Local lyrics import or editor | 2 | Lyrimuse; Dynamic Lyrics (TTML import, partial). Isla alone has a validated editor with Save Copy and LRC export. |
| Word-by-word lyrics | 3, plus Atoll partial | Lyrimuse, MacNotch, Dynamic Lyrics. Isla's are local files only, off by default. |
| Quick Look on shelf cards | 4 | Atoll, OpenYoink; boring.notch and Cyclop partial. |
| Screenshot or recording pickup | 4 | Cyclop, Pulse Island, Crest; MacNotch partial. |
| Translate | 5 | Cyclop (on-device, English and Russian only), MacNotch (OpenAI or Ollama), Crest (about 115 languages, engine not stated). Isla: 16 languages, Apple's on-device engines, online opt-in. |
| Privacy cover or hide from screen share | 5 | boring.notch, Cyclop, Pulse Island. |
| Lock-screen media card | 6 | Atoll, DynamicNotch, Sapphire. Isla's carries lyrics, output picker, volume and a Liked Songs heart. |
| Shortcuts and App Intents | 7 | Isla ships eight intents with Siri phrases. |
| Liquid Glass, accessibility | 7 each | Isla honors Reduce Transparency, Increase Contrast and Reduce Motion live. |

## Where Isla trails

| Row | Competitors with it (of 20) | Read |
|---|---|---|
| Volume and brightness HUD | 13 | The most common system feature. Isla: not built. |
| Other live activities (downloads, recording indicator, Focus, hotspot) | 14 | Isla shows only track, charger and headphones. |
| Other utilities | 14 | Window snapping, terminals, system monitors, menu-bar tidy. Mostly out of Isla's lane. |
| Calendar and meeting join | 13 | Removed on purpose 2026-08-20. |
| Gestures (swipe, scroll) | 13 | Withdrawn on purpose 2026-09-21. |
| Timer or Pomodoro | 10 | Not built. |
| Extensions or widgets | 9 | Mostly partial. Only DynamicLake Pro is a clear yes; Atoll's plugin host is an open pull request. No public plugin API anywhere. |
| Notes or to-do | 8 | Removed 2026-08-22. |
| Camera mirror or teleprompter | 7 | Removed or not built. |
| Weather | 7 | Not built. |
| AI coding-agent monitor | 6 | A fast-growing category; out of Isla's lane. |
| Lyrics translation | 2 | Lyrimuse (17 languages) and Dynamic Lyrics (paid). A natural extension of Isla's lyric stack. |
| Auto-update | 14 yes, 5 partial | Isla is check-only. Blocked on Developer ID. |
| Notarized distribution | 7 confirmed, 2 partial | Confirmed: coucou, Cyclop, NotchNook, DynamicLake Pro, Islet, Pulse Island, Crest. Partial: Atoll (Developer ID), MacNotch (notarized via Setapp). Isla is ad-hoc signed. |
| UI languages | | Isla 2. DynamicNotch 38+, MacNotch 11, coucou 10, Dynamic Lyrics 8. |
| Traction | | boring.notch 10,989 stars and ~909k DMG downloads; Atoll 4,902; coucou 4,679 in two weeks. Isla about 8 stars. |

## What the field is doing

- **Lyrics are everywhere but shallow.** Nine of 20 apps show synced lines; only Lyrimuse does word timing across 12 sources with translation and romanization, and Dynamic Lyrics sells lyrics through in-app Premium ($1.49 a month, $4.99 a year, $9.99 lifetime). Isla's no-scraping rule means online lyrics stay line-level, which is the ceiling to push against.
- **Paid apps win on polish and notarization, not on features.** Alcove (4 yes, 5 partial) is praised as the most native-feeling and charges $14.99; NotchNook (8 yes) charges $25 and its download path is currently broken (Homebrew cask disabled 2026-09-19, vendor site returned 402). Pulse Island, the broadest app found, costs $7.
- **AI-agent monitoring is the new axis.** coucou, Pulse Island and Crest ship it fully; Sapphire, MacNotch and Atoll in part. Isla has chosen not to follow.
- **Nobody has solved extensibility.** Nine apps have some form of it, mostly partial; only DynamicLake Pro is a clear yes, and no public plugin API is documented.
- **Cyclop, Isla's parity base, kept moving.** Isla pins 0.6.5. Cyclop is now 0.8.3: all-display panels (0.7.0), Shelf watching the screenshot folder (0.7.1), Developer ID signing and notarization plus a Currency tab and per-tab switches (0.8.0), fixes through 2026-10-06.

## Suggested next moves

These are judgment calls from the data, not findings.

1. **Developer ID and notarization.** Unblocks the Gatekeeper alert on the helper dylib, a Sparkle updater, and a first public release that is not NO-GO. It closes the two largest trailing rows at once.
2. **Decide the HUD on purpose.** Thirteen of 20 ship it. It usually costs a permission, which cuts against Isla's no-permission stance, so write down the trade-off in the parity design instead of leaving it as "not built".
3. **Extend the lyrics lead.** Lyrics translation (2 competitors) and a word-timed online source (3) are the two cheapest ways to widen a moat nobody else is near. Check each against the no-scraping rule first.
4. **Re-baseline against Cyclop 0.8.3.** Two Cyclop changes, all-display panels and Shelf watching the screenshot folder, overlap Isla's shell and capture code.
5. **Leave the removed rows removed.** Calendar, Notes and Teleprompter gaps are a breadth score, not a user complaint, and `TabContractTests` guards them.

## Method and confidence

- Isla inventory: four Haiku readers (max effort) over code and docs, 344 features each with file:line evidence; the clusters above are mine.
- Field: 20 apps, one Haiku researcher then one separate Haiku verifier each (max effort), 40 agents, 4.7M subagent tokens (7.1M with the scouting pass). The verifier re-fetched sources and applied 115 corrections: 25 raised a cell, 17 lowered one, 73 reworded a note or moved a cell between "absent" and "not found". Researchers filled a fixed 47-row taxonomy; every yes, partial or absent needs an opened source URL.
- **Limits.** This is Haiku research, not a human audit. The verifier checked load-bearing rows, not every cell. "Silent" (·) means the sources did not mention it, so a few competitor cells are probably understated, especially for apps with thin public docs (Alcove, NotchFlow, NotchBay). Several prices were not confirmable on 2026-10-11 (NotchNook, MediaMate, DynamicLake Pro) and are the last documented figures. Nothing was installed or run: no competitor was tested hands-on, and Isla's rows reflect code, not a physical-notch validation.
- Raw outputs: `~/.claude/projects/-Users-ctimothe-code-projects-production-dynamic-island/48ae4d81-9edf-4a35-a3fd-12960e5f9d5e/subagents/workflows/wf_e845b101-3f0/journal.jsonl` (inventory and discovery) and `.../wf_3a8d3012-f85/journal.jsonl` (per-app matrix).
