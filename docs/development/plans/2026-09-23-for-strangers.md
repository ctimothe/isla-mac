# For strangers — everything the 2026-09-23 exploration found, except notarization

On 2026-09-23 the owner asked for everything found in that day's exploration to
be done, except the Apple Developer ID and notarization. The exploration covered
the code, the market and the install path. Its baseline: 8 stars, 5 of them the
owner's own accounts, 5 DMG downloads, and no issues from outside. The craft is
ahead of the product's reach. The items below are what hits a person the owner
has never met, and what they would need to get the app working or tell the
owner that it didn't.

Branch `feat/front-door`, cut from `github/main` (GitHub's rewritten history).
Two pull requests: the first carries sections 1–6, the second section 7.

## 1. Nothing takes a shortcut another app owns

- The defaults ⌥⌘I, ⌥⌘T and ⌥⌘L are Web Inspector / DevTools, the Finder
  toolbar, and Downloads in Safari, Chrome and Finder. A Carbon hot key wins
  over the frontmost app, so Isla silently took them. The new defaults are
  ⌃⌥⌘I, ⌃⌥⌘T and ⌃⌥⌘L.
- All three can be rebound or cleared in a new **Keyboard Shortcuts** section
  in Settings. Recording makes the panel key, the same way Translate does.
  Registration failures are shown instead of swallowed.
- The welcome shows the live bindings, and its second row is now the lyrics
  shortcut. Translate stays reachable from Settings.
- Test: binding storage round-trips, and the formatter produces the glyphs.

## 2. The media path says when it has fallen back, and comes back

- The perl one-liner exits with status 3 when `dl_load_file` fails, instead of
  sleeping forever. The feed maps that status straight to the fallback,
  skipping about 45 s of silence-watchdog cycles and ending the orphaned perl.
- `MediaController.route` is published: Now Playing, or the scripting fallback
  and why (reader refused, route closed, kept stopping, perl missing).
- The fallback is retried on screen wake and from Settings, **Try Again**.
- The Music empty state and the Settings Music section both say when only
  Music and Spotify can be seen.
- Precision sync, the per-second AppleScript poll, runs only while lyrics are
  on. It was running whenever the panel was open on Spotify or Music, which
  put up the Apple Events prompt on the ordinary path. The usage string now
  says what the access is for, and it is localized (InfoPlist.strings).
- Test: exit-status mapping, route transitions, retry resets the fallback,
  precision off with lyrics off.

## 3. A user can tell the owner what went wrong

- `Log` wraps `os.Logger`, subsystem `com.ctimothe.isla`, and replaces every
  `NSLog`. Error descriptions are public and user content stays private.
- **Copy Diagnostics** in Settings copies: version and build, macOS, model,
  architecture, displays and notches, media route and reason, the quarantine
  state of the app and helper, the non-content settings, hot key registration,
  lock-screen SPI availability, and the last 30 minutes of Isla's own log.
- GitHub issue forms for bugs (which ask for the diagnostics) and for ideas.
- Test: the report contains every section and no track title.

## 4. A user hears about a new version

- **Check for Updates** in Settings asks GitHub's `releases/latest` and
  compares it against the running version. **Check Automatically** is off by
  default, per the rule that anything leaving the Mac defaults to off. It is
  recorded in `checklist.md` and in the README privacy table.
- `CFBundleVersion` becomes a monotonic `BUILD` number from `Scripts/version`,
  so a future Sparkle feed has something to compare. `test-identity.sh` checks
  it is an integer.
- Test: version comparison, including pre-release tags and a malformed tag.

## 5. The headline feature can be found

- The lyrics page, reached from the Music tab's caption, offers **Show
  Lyrics** when lyrics are off. When no local file matched and online lookup
  is off, it offers **Look Up Online**, with the disclosure beside the button.
- Clipboard history can be turned off (Settings → Privacy). Off stops the poll
  and empties the list.
- Spotify: a refused library call says why in Settings, instead of hiding the
  heart without explanation.

## 6. Smaller truths

- `NSDesktopFolderUsageDescription`, so the Shelf's Desktop scan explains itself.
- App Intents titles are localized, and the localization gate reads
  `IslaIntents.swift`.
- The `TokenStore` comment stops claiming the file store never ships.
- `CLAUDE.md`'s NotchController line count and the release checklist's
  "29 tests" are corrected.
- The lock-screen SkyLight space is reference-counted per window. Before, the
  card's `lower` destroyed the space the panel was still in (audit B9). Tested
  with fake SPI.
- The screen-wake decision in `NotchController` becomes a pure function
  (`WakePlan`) with tests. The lock and wake path is where 17 fixes have landed.
- README: the Apple silicon or universal statement, new shortcuts, the update
  check in the privacy table. Repository topics.
- Architecture: universal if the Intel slice builds and links. Otherwise the
  README says Apple silicon.

## 7. Features people ask for (second pull request)

- Charging: plugging in shows a short peek with the battery level, from IOKit
  power-source notifications. Public, no permission.
- Headphones: a Bluetooth audio output appearing shows a short peek with its
  name, from the CoreAudio device list `AudioOutputs` already watches. No
  Bluetooth permission.
- Shelf: AirDrop (`NSSharingService`) and Quick Look on a card.
- Each has a Settings switch, on by default. None leaves the Mac.

## Not done here, and why

- Developer ID and notarization, as the owner excluded them.
- Splitting `MediaController`. It is well tested and has no failing
  behaviour, and a split without a bug to motivate it is the trap the
  2026-09-03 audit named. Section 2 moves route state out of it.
- README screenshots and the launch posts. Screenshots need the live app on
  the owner's screen, and posting is the owner's to do. The drafts were handed
  over outside the repository, because marketing stays local
  (`marketing/`, never GitHub).
