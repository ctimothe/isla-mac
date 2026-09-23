# Isla

A Dynamic Island–style panel for the Mac notch: what's playing, synced lyrics,
a file shelf, clipboard history and translation. Click the notch to open it.

Requires macOS 15 or later, on Apple silicon or Intel. On a display without a
notch, Isla draws one.

"Dynamic Island" is Apple's term and is used here only to describe the idea.
Isla is an independent project and is not affiliated with Apple.

## Install

1. Download `Isla-<version>.dmg` from the
   [latest release](https://github.com/ctimothe/isla-mac/releases/latest).
2. Open it and drag **Isla** to **Applications**.
3. The build is not notarized, so remove the download quarantine once:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Isla.app
   ```

4. Open Isla from Applications.

Isla has no Dock icon, menu bar item or window: it lives in the notch. Click the
notch to open it. **Settings** in the panel has Launch at Login, About and Quit.

To update, repeat the steps with the new release. **Settings → Check for Updates**
says whether there is one.

## Features

- **Music.** The current track from any Now Playing source, with controls,
  artwork and a scrubber. Music and Spotify also get shuffle, repeat and, with
  a connected Spotify account, Liked Songs.
- **Lyrics.** Time-synced lyrics from LRC files you import or keep in a folder,
  and optionally from [LRCLIB](https://lrclib.net). Click a line to jump to it.
- **Lock screen.** While the Mac is locked, a player card with lyrics, volume
  and audio output.
- **Shelf.** Drop files onto the notch to keep them at hand and drag them out
  again, Quick Look them, or AirDrop them. Screenshots and screen recordings
  appear here too.
- **Charging and headphones.** Plugging in shows the battery level on the
  island for a moment; AirPods and other Bluetooth headphones show their name
  when they connect.
- **Clipboard.** The last 40 items copied while Isla runs. Click one to copy
  it again. It can be turned off in Settings.
- **Translate.** Sixteen languages, translated on the Mac by Apple's
  Translation framework or Apple Intelligence (macOS 26 or later). Uzbek and
  Kazakh need Translate Online.
- **Shortcuts.** ⌃⌥⌘I opens Isla, ⌃⌥⌘L opens the lyrics, ⌃⌥⌘T translates the
  clipboard. Each can be changed or cleared in Settings. Shortcuts, Spotlight and
  Siri can read the current track and lyric.

## Privacy

Nothing leaves the Mac unless you turn it on in Settings. Each of these is off
by default:

| Setting | What is sent | Where |
| --- | --- | --- |
| Look Up Lyrics Online | Track title, artist, album and length | [LRCLIB](https://lrclib.net) |
| Translate Online | The text and its two languages, only for languages the Mac cannot translate itself | [MyMemory](https://mymemory.translated.net) |
| Connect Spotify Account | Spotify sign-in, to read and change Liked Songs | Spotify |
| Check for Updates Automatically | A request for the latest version, naming Isla's version | [GitHub](https://github.com) |

Spotify tokens are stored in a file readable only by your user account in
`~/Library/Application Support/Isla`. Signed builds use the Keychain instead.
macOS asks before Isla controls Music or Spotify through Apple Events, the
fallback used when Now Playing is unavailable.

## When something is wrong

- **The Music tab says only Music and Spotify can be seen.** macOS refused Isla's
  Now Playing reader, usually because the download quarantine is still on the
  app. Run the `xattr` command from Install, then **Settings → Music → Try Again**.
- **A shortcut does nothing.** Another app may own it. Settings → Keyboard
  Shortcuts says so and lets you pick another.
- **Anything else.** **Settings → Copy Diagnostics**, then **Report a Problem…**
  and paste it into the form. The report lists versions, settings and Isla's own
  log, and nothing you played, copied or translated.

## Build from source

Needs Xcode 26 or later.

```bash
git clone https://github.com/ctimothe/isla-mac.git
cd isla-mac
bash Scripts/bundle.sh release   # builds and ad-hoc signs the app
bash Scripts/install.sh          # installs it to /Applications and opens it
```

`./scripts/check` runs the unit tests and every release check, the same way CI
does. There is no Xcode project: SwiftPM builds the binary and
`Scripts/bundle.sh` assembles the app. [docs/runbook.md](docs/runbook.md)
covers signing, releases and troubleshooting.

Isla reads Now Playing through a small helper library loaded into
`/usr/bin/perl`, because macOS 15.4 closed the MediaRemote read path to
ordinary apps. The App Store does not allow this, so Isla is distributed here.

## Uninstall

Quit Isla from Settings, then delete `/Applications/Isla.app` and
`~/Library/Application Support/Isla`. If you turned on screenshot saving, also
delete `~/Pictures/Isla`.

## License

MIT, see [LICENSE](LICENSE). Isla began from
[Cyclop](https://github.com/akalikbergenov/cyclop) 0.6.5, also MIT; its notice is
in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
