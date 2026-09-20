# Paid notch apps: what they charge for, and what Isla can give away (2026-09-20)

Scope: what the paid and popular macOS notch apps ship, what sits behind their paywall,
and which of those things Isla could ship free without leaving the machine or adding an
entitlement. Primary sources are the apps' own sites, App Store listings and GitHub
READMEs/releases; review sites are marked as secondary. `lo.cafe` did not resolve from
this machine, so NotchNook's prices are secondary-sourced.

## The field

| App | Model / price | Headline features | Paid-gated | Lyrics |
|---|---|---|---|---|
| NotchNook (Lo.cafe) | $25 one-time (5 devices) or $3/month (2 devices), plus Setapp; macOS 14.6+ | media with artwork + waveform, calendar live activities, file tray + AirDrop, Mirror webcam widget, notes | whole app after trial | none |
| Alcove (Henrik Ruscon — not "Henrique Alves") | $14.99 one-time on site; reviews quote $16.99–$17; v1.7 | live activities, notifications, customizable HUDs, swipe gestures, lock-screen widgets | whole app after trial | none |
| boring.notch (TheBoredTeam) | free, open source, Ko-fi; macOS 14+ | Shelf 2.0, full HUD replacement (screen/keyboard brightness, volume), calendar, webcam, lock-screen display, hidden-from-capture | nothing | synced lyrics, beta (v2.7) |
| not-boring-notch (AllenReder) | free, GPL-3 fork; macOS 14+ | GPU "Liquid Glass" refraction, spectrogram, calendar + reminders, shelf + AirDrop + Quick Look, HUD, camera mirror | nothing | real-time lyrics |
| DynamicLake Pro | one-time, reviews quote $13.99–$16.90 (3 devices, refund); free tier deprecated; v1.9.7.5 | notifications incl. Slack + link previews, calls/meetings, DynaDrop, DynaClip, timers, weather, battery alerts, live activities, Liquid Glass since v1.7 | whole app | none |
| NotchDrop (Lakr233) | free, MIT; also on the App Store | drag files to the notch, AirDrop from the notch, 1-day auto-expiry | nothing | none |
| Dynamic Lyrics (`com.bing.lyrics`, dev 云冰 谭 — the copy installed here, v2.0.3) | free + IAP: $1.49/mo, $4.99/yr, $9.99 lifetime; macOS 14.6+ | lyrics + translation on lock screen, notch, widgets, floating window; Shazam identification; share cards | word-by-word, translation, most surfaces | word-by-word sync, local TTML import, Apple Music + Spotify |
| Lyric Fever (aviwad) | free, open source; macOS 15+ | menu-bar lyrics, Apple-Music-style fullscreen, karaoke popup tinted from artwork, offline CoreData cache | nothing | Spotify → LRCLIB → NetEase, on-device translation, romanization, Connect/AirPlay delay settings |
| LyricsX (ddddxxx) | free, MPL-2.0 | desktop + menu-bar lyrics, LRCX word tags, drag-drop import/export | nothing | per-song offset in the status menu, double-click a line to seek |
| MewNotch (monuk7735) | free, GPL-3 | brightness/volume/input HUDs with step sizes, stock HUD suppression, persistent shelf, power state, HUD on the lock screen | nothing | none |
| DynamicNotch (jackson-storm) | free, GPL-3; macOS 14.6+ | physics animations, HUD interception, AirDrop/downloads/timer/screen-recording/Focus/hotspot/Bluetooth/VPN islands, floating capsule off-notch | nothing | LRCLIB synced lyrics |
| DynamicHorizon | $11.99 one-time, lifetime; macOS 27 Liquid Glass | 20+ notch modules, lock screen with music, lyrics and widgets, system controls, timers | whole app | lyrics on the lock screen |
| Notchy (notchy.dev) | free, donations; macOS 13+ | claims 74 features: camera/mic pill, Focus detection, Shortcuts runner, LRCLIB lyrics, lock-screen widgets, HUDs, AI usage tracker | nothing | LRCLIB, line-synced |
| Notchmeister (The Iconfactory — not Panic) | free; macOS 11+ | cursor effects under the notch, synthetic notch for other Macs | nothing | none |
| TopNotch (CleanShot X team) | free; macOS 11+ | blacks out the menu bar to hide the notch, rounds wallpaper corners | nothing | none |
| Ice (jordanbaird) | free, GPL-3; macOS 14+ | menu-bar manager; the Ice Bar draws hidden items *below* the menu bar, which is the notch-overflow answer Bartender charges for | nothing | n/a |

Coexistence: Ice/Bartender own menu-bar overflow, notch apps own the area under and around
the cutout; they are complementary, not rivals. macOS 27 reportedly adds a native overflow
button and breaks Bartender, Ice, Thaw and Hidden Bar (secondary), which makes the notch
layer the more durable surface of the two.

## Feature × apps × paid-gated × Isla

| Feature | Who ships it | Paid-gated at | Isla today |
|---|---|---|---|
| Now Playing + controls | all of them | NotchNook, Alcove, DynamicLake, DynamicHorizon | yes (helper + AppleScript fallback) |
| Synced lyrics | boring.notch (beta), not-boring, DynamicNotch, Notchy, Lyric Fever, LyricsX, Dynamic Lyrics, DynamicHorizon | Dynamic Lyrics (word-level), DynamicHorizon | yes — offline LRC only, no network |
| File shelf | NotchDrop, boring.notch, MewNotch, DynamicLake, Notchy | NotchNook, DynamicLake | yes |
| AirDrop from the shelf | NotchDrop, boring.notch, not-boring, DynamicLake, Notchy | NotchNook, DynamicLake | **no** |
| Volume/brightness HUD replacement | boring.notch, MewNotch, DynamicNotch, not-boring, Notchy | Alcove, DynamicHorizon | volume only, on the lock card |
| Battery / charging / device batteries | boring.notch, MewNotch, DynamicNotch, Notchy | DynamicLake | **no** |
| Camera/mic privacy indicator | Notchy (claimed) | — | **no** |
| Calendar / reminders | boring.notch, not-boring, Notchy | NotchNook, DynamicLake | removed by owner decision (2026-08-20) |
| Timers / Pomodoro | DynamicNotch, Notchy | DynamicLake, DynamicHorizon | **no** |
| Camera mirror | boring.notch, not-boring, Notchy | NotchNook | **no** |
| Clipboard history | Notchy | DynamicLake (DynaClip) | yes |
| Lock-screen presence | MewNotch, DynamicNotch, boring.notch, Notchy | Alcove, DynamicHorizon | yes (own window, card, output + volume) |
| Focus state | DynamicNotch, Notchy | — | **no** |
| Weather | Notchy | DynamicLake | **no** |
| Shortcuts / automation | Notchy | Alcove (secondary) | **no** |
| Notification mirroring | Notchy (claimed) | Alcove, DynamicLake | **no**, and not planned |
| Audio output switching | Notchy | — | yes, lock card only |
| Translation | Lyric Fever (lyrics only), Notchy | Dynamic Lyrics | yes, on-device |
| Hidden from screen capture | boring.notch, Notchy | — | yes, default on |

## Ten free wins, ranked

Ranking = user value × feasibility for a SwiftPM accessory app × "feels like Apple built it".

1. **Camera/mic in-use pill.** Every competitor except Notchy skips it, and the notch is
   exactly where macOS already puts that signal. Path: CoreMediaIO
   `kCMIODevicePropertyDeviceIsRunningSomewhere` and CoreAudio
   `kAudioDevicePropertyDeviceIsRunningSomewhere` listeners — observing "in use" opens no
   stream, so no TCC prompt, no entitlement, nothing leaves the machine.
2. **AirDrop out of the Shelf.** The single most-copied paid feature (NotchNook, DynamicLake)
   and it is one call: `NSSharingService(named: .sendViaAirDrop)` or an
   `NSSharingServicePicker` anchored on the shelf item. No permission outside the sandbox.
3. **Battery, charging and Bluetooth-device batteries.** Path: IOKit
   `IOPSCopyPowerSourcesInfo`/`IOPSGetPowerSourceDescription`, plus the IORegistry
   `BatteryPercent` keys for connected input devices and AirPods. No permission.
4. **Shortcuts actions via App Intents.** `AppIntent` + `AppShortcutsProvider` in the app
   bundle makes "open the panel", "translate the clipboard", "start a timer", "shelf this
   file" scriptable. No entitlement. This is the cheapest genuinely ecosystem-deep move, and
   only Alcove and Notchy claim it.
5. **Volume HUD and output switcher on the island itself.** Isla already reads and writes the
   default device (`SystemVolume`, `AudioOutputs`) but only from the lock card; promoting them
   to the open panel and a compact HUD costs no new API. Paid at Alcove and DynamicHorizon.
6. **Timer island.** Pure UI plus a `Timer`; DynamicLake and DynamicHorizon both sell it.
   The value is the compact-island presentation Isla already owns.
7. **Camera mirror.** NotchNook sells it as the Mirror widget. `AVCaptureSession` +
   `AVCaptureVideoPreviewLayer`; needs `NSCameraUsageDescription` and the camera TCC prompt,
   so it is off by default and recorded in `checklist.md` under the added-capability rule.
8. **Deepen lyrics where paid apps stop.** Per-track offset in the UI, double-click a line to
   seek (LyricsX has had this for years; Dynamic Lyrics charges for word-level), and honouring
   an imported file's `[offset:]` explicitly rather than silently. All local, all existing code
   paths (`LyricSweep`, `LocalLyricsEditor`).
9. **Downloads and file progress in the Shelf, with Quick Look.** `NSMetadataQuery` over
   `~/Downloads` plus `QLPreviewPanel`; not-boring-notch and DynamicNotch both ship it free
   already, so it is table stakes rather than differentiation. No permission for the query;
   the folder read is the same class of grant the screen-recording pickup already asks for.
10. **Next calendar event.** Highest user value of anything on this list and the reason it is
    last: EventKit `EKEventStore.requestFullAccessToEvents` (macOS 14+) plus
    `NSCalendarsFullAccessUsageDescription`, and Calendar was deliberately removed on
    2026-08-20. Only worth reopening as an owner decision with a design amendment.

Costs more than it returns, for this app:

- **Brightness HUD.** No dependable public read of built-in-display brightness on Apple
  Silicon, and intercepting the brightness keys needs Input Monitoring or Accessibility.
  boring.notch and MewNotch pay that price; Isla's one-entitlement, no-prompt posture does not.
- **Focus state.** `INFocusStatusCenter` requires the Communication Notifications entitlement
  (Apple Developer Forums), and the file-based route is undocumented.
- **Weather.** WeatherKit needs its own service entitlement and a network call per refresh.
- **Notification mirroring.** Needs Accessibility or private notification APIs; Alcove and
  DynamicLake charge for it precisely because it is expensive and brittle.
- **Live Activities.** No third-party API on macOS; everything sold under that name is the
  vendor's own animation layer.

## How paid apps make the price feel earned

- **One-time price with a device count, after a trial.** $11.99–$25, 2–5 devices, a refund
  window. Nobody in this field succeeds with a pure subscription except the lyric apps.
- **HUD replacement as the daily proof.** It is the feature a buyer sees fifty times a day;
  it is what makes the purchase feel present after week one.
- **A named look, dated.** DynamicLake ships "Liquid Glass" as a headline in v1.7 (Sept 2025)
  and keeps extending it; not-boring-notch sells GPU refraction. Isla's `glassSurface` already
  does the honest version — real material where there is a backdrop, drawn recipe otherwise —
  and that distinction is worth stating in the README rather than buried in a design doc.
- **A public changelog as a marketing surface.** DynamicLake's changelog reads as evidence of
  life; an open-source project gets this free from releases if the notes are written for users.
- **Breadth of localization.** NotchNook ships 29 languages, Notchy claims 134. Isla has two.
- **Animation as the review hook.** Reviewers name expansion timing, spring feel and typography
  before they name features (MacUpdate, MacSources, secondary). Isla's critically-damped
  springs and `tracking(forSize:)` are the same argument, unclaimed.

## Lyrics: what the good ones do about timing

- **A lead is normal and must be a number, not a feeling.** The LRC format carries a global
  `[offset:]` tag, and the sign convention is *not* agreed: Wikipedia documents `+` as "appear
  sooner", several format guides document `+` as later. An importer must therefore treat the
  tag as a magnitude plus a heuristic, not as a trusted signed value. Isla fixes its own
  surface lead at 0.25 s (`LyricSweep.standardLead`/`precisionLead`).
- **Line versus word is a data question before it is a design one.** Enhanced LRC (A2) carries
  `<mm:ss.xx>` word tags; Apple-style TTML carries `itunes:timing="Word"|"Line"`, background
  vocals as `ttm:role="x-bg"`, and translations/romanizations as `x-translation`/`x-roman`.
  Apple's own Sing animates "beat-by-beat" and animates background vocals independently.
  Isla's rule — word animation only when the player clock is measured, lines otherwise — is
  the same conclusion reached from the other end.
- **The player's clock, not the file, is usually what is wrong.** Lyric Fever ships explicit
  Spotify Connect and AirPlay delay modes; LyricsX puts an offset adjustment in the status
  menu. Both concede that a remote or buffered player reports position late.
- **Joining mid-song is a seek, and should be treated as one.** LyricsX makes a double-click
  on a line seek the player — the user drives the clock instead of waiting for it. Lyric Fever
  cancels stale network requests when the user skips quickly. Isla's equivalent is the single
  `LyricSweep` binary search with `centreIndex`, which exists because three copies of that
  search once disagreed about the line before the first timestamp.

## Uncertainty

`lo.cafe` did not resolve from this machine; NotchNook's $25/$3 prices come from a MacSources
review and Setapp's listing, and Setapp's own page quoted a third figure that is not repeated
here. Alcove's site says $14.99 while reviews say $16.99–$17. DynamicLake's price is not on the
pages fetched; $13.99 and $16.90 both appear in secondary reviews. notchy.dev, macnotch.io,
tryonenotch.com and getdroppy.app are vendor-operated comparison sites — their feature counts
are claims, not verified behaviour. The prompt's attributions were wrong in three places:
Alcove is by Henrik Ruscon, Notchmeister is by The Iconfactory, and the "Dynamic Lyrics"
installed on this Mac is `com.bing.lyrics` v2.0.3 by 云冰 谭, not Fetch.

## Sources

- https://github.com/TheBoredTeam/boring.notch/blob/main/README.md
- https://github.com/TheBoredTeam/boring.notch/releases
- https://github.com/AllenReder/not-boring-notch
- https://github.com/Lakr233/NotchDrop/blob/main/README.md
- https://github.com/monuk7735/mew-notch
- https://github.com/jackson-storm/dynamicnotch
- https://github.com/jordanbaird/Ice
- https://github.com/aviwad/LyricFever/blob/main/README.md
- https://github.com/aviwad/LyricFever/releases
- https://github.com/ddddxxx/LyricsX
- https://tryalcove.com
- https://tryalcove.com/changelog
- https://www.dynamiclake.com/
- https://www.dynamiclake.com/changelog
- https://www.dynamichorizon.app/
- https://notchy.dev/
- https://topnotch.app/
- https://setapp.com/apps/notchnook
- https://apps.apple.com/us/app/dynamic-lyrics/id6476125287
- https://apps.apple.com/us/app/notchmeister/id1599169747?mt=12
- https://www.apple.com/newsroom/2022/12/apple-introduces-apple-music-sing/
- https://amll.dev/en/guides/lyric/ttml.html
- https://github.com/amll-dev/amll-ttml-db/blob/main/instructions/ttml-specification-en.md
- https://en.wikipedia.org/wiki/LRC_(file_format)
- https://easylrc.com/blog/lrc-format-complete-guide
- https://developer.apple.com/forums/thread/682143
- https://macsources.com/notchnook-mac-app-review/ (secondary)
- https://macsources.com/dynamiclake-pro-app-review/ (secondary)
- https://thesweetbits.com/tools/dynamiclake-review/ (secondary)
- https://www.macupdate.com/comparisons/notchnook-vs-alcove-whats-the-best-macbook-notch-app-in-2026 (secondary)
- https://www.macobserver.com/tips/round-ups/notchbook-vs-alcove-what-macbook-notch-app-is-actually-worth-using-in-2026/ (secondary)
- https://www.macbartender.com/B5blog/Access-Apps-Hidden-by-Notch/ (secondary)
- https://support.apple.com/en-us/118449
