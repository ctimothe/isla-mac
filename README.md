# Isla

**A Dynamic Island–style companion for the Mac notch.** Isla expands from your
MacBook's camera notch into music, a drop shelf, clipboard history, and
translation — free and open source.

> "Dynamic Island" is Apple's term, used here only to describe what Isla is like.
> Isla is an independent project, not affiliated with or endorsed by Apple.

- **macOS 15+** (Sequoia), Apple Silicon or Intel.
- Free and **MIT-licensed** — every feature you see is open source.
- Site: `islamac.app` *(coming soon)*

## Install

Isla is distributed directly — **no App Store**.

1. Download `Isla.dmg` from the
   [latest release](https://github.com/ctimothe/isla-mac/releases/latest).
2. Open the DMG and drag **Isla** into your Applications folder.
3. The build is **not yet notarized by Apple**, so macOS quarantines it on first
   download. Clear that once (Isla is open source — you can read or build every
   line in this repo):

   ```bash
   xattr -dr com.apple.quarantine /Applications/Isla.app
   ```

   Then open **Isla** from Applications. That's it.

*(A notarized, one-click-to-open build may come later. Until then the command
above, or right-click → Open, is the way in.)*

Prefer to compile it yourself? See [Build from source](#build-from-source).

## What Isla does

- **Click the island** — at the physical notch, or the centered synthetic notch
  on a display without one — to open the panel. Anywhere on it works: the artwork
  side, the cutout between, the equalizer side, both shoulders. The compact island
  carries no controls at all; opening is the only thing it does.
- **Hovering does not open it.** The surface brightens slightly under the pointer
  and nothing else, because the cursor crosses the top of the screen constantly
  and an island that unfolded every time would interrupt what is under it.
  **Open on Hover** in Settings restores the old behavior, off by default.
- **⌥⌘I** opens it from the keyboard and keeps it open until a command closes it;
  **⌥⌘T** translates the clipboard.
- Over the **lock screen** the island shows what is playing and answers nothing:
  hovering brightens it, clicking shakes it off. It never opens there.
- The island **is** the whole app — no Dock icon, no menu-bar item, no window.
  Settings inside the panel carries Open Panel, About and Quit.
- One rail carries **Music, Shelf, Clipboard, and Translate**, with **Settings**
  at its foot. Settings sets how wide the panel opens (480–620 pt).
- Translucent surfaces use the system's own material where macOS has it, and a
  hand-drawn recipe otherwise. **Reduce Transparency** replaces them with opaque
  panels and **Increase Contrast** gives them a border, both followed live.

## Privacy — what leaves the machine, and when

Nothing, until a switch in Settings is turned on. Each is **off by default**,
because each sends something you own somewhere you cannot see.

- **Save clipboard screenshots** writes a copy of every image that reaches the
  pasteboard to `~/Pictures/Isla` (most recent 200; clearing goes to the Trash).
- **Lyrics** sends the current title, artist, album and — for Spotify — the track
  id to `lrclib.net`, `raw.githubusercontent.com` and `lyrics.kugou.com` to look
  words up. That is listening history leaving the Mac, so it is asked for rather
  than assumed. Results are cached on disk, capped at 500 tracks.
- **Connecting a Spotify account** (Settings → Spotify) authorizes Isla through
  Spotify's own PKCE flow in the browser, for one feature the local APIs do not
  expose: Liked Songs. There is **no client secret**; tokens live in the keychain
  (`WhenUnlockedThisDeviceOnly`), and Disconnect deletes them. Translation itself
  is on-device and never uses the network.

Isla claims exactly one entitlement,
`com.apple.security.automation.apple-events` — what lets the scripting fallback
drive Music or Spotify when the MediaRemote helper is unavailable. macOS asks for
that consent the first time it is used; refusing it costs only that fallback.

Isla never asks for your login password, in any build. Spotify tokens go to the
data-protection keychain in a **signed & notarized** build (scoped to the team
identity) and to a `0600` file under `~/Library/Application Support/Isla` in an
**unsigned** build (including today's direct-download releases), because an
ad-hoc signature has no stable identity a keychain ACL could trust. Settings
states which is in use. See
[`Sources/IslaKit/Services/TokenStore.swift`](Sources/IslaKit/Services/TokenStore.swift).

## Build from source

Install the Xcode Command Line Tools, then from the repository root:

```bash
swift test                    # unit tests
bash Scripts/bundle.sh release  # assemble + ad-hoc-sign build/Isla.app
open "build/Isla.app"
```

The local bundle is ad-hoc signed with the hardened runtime, so local testing
exercises what ships. It runs on the machine that built it; a build for another
Mac needs Developer ID signing and notarization, described in
[the runbook](docs/runbook.md).

There is no Xcode project — SwiftPM builds the binary and `Scripts/bundle.sh`
assembles the `.app` around it. The full release-gate order:

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
bash Scripts/dmg.sh
```

`Scripts/release.sh` runs exactly this list before it tags anything. Manual and
performance checks are tracked in [checklist.md](checklist.md) and
[docs/release-checklist.md](docs/release-checklist.md).

## Why direct download, not the App Store

Isla reads Now Playing through a small helper loaded into a platform binary,
because MediaRemote's read path is closed to ordinary apps since macOS 15.4 and
its entitlement is restricted. That approach is incompatible with the App Store,
so Isla is distributed as a direct download instead. The MediaRemote framework is
never linked into the app itself.

## License and attribution

Isla is **MIT-licensed** — see [LICENSE](LICENSE). Its foundation derives from
MIT-licensed **Cyclop 0.6.5** at the commit pinned in
[UPSTREAM_CYCLOP_VERSION](UPSTREAM_CYCLOP_VERSION); the required attribution is
kept in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Isla uses its own name,
bundle identity, filesystem paths, interface copy, and app icon.
