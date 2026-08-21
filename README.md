# Dynamic Island

Dynamic Island is a macOS 15+ utility that expands from the camera notch into
Music, Shelf, Clipboard, Translate, Notes, Teleprompter, and Settings tools.

## Build, test, launch

Install Xcode Command Line Tools, then run from the repository root:

```bash
bash Scripts/bundle.sh release
swift test
bash Scripts/test-package.sh
open "build/Dynamic Island.app"
```

The local bundle is ad-hoc signed, with the hardened runtime enabled so local
testing exercises what ships. It runs on the development Mac, but a build for
another Mac must use Developer ID signing and notarization as described in
[the runbook](docs/runbook.md).

## Product behavior

- Hover at the physical notch, or the centered synthetic notch on a display
  without one, to open the panel. ⌥⌘I opens it from the keyboard and keeps it
  open until a command closes it; ⌥⌘T translates the clipboard.
- Use the left rail for Music, Shelf, Clipboard, and Translate.
- Use the right rail for Notes, Teleprompter, and Settings.
- Clipboard entries marked concealed, transient, or auto-generated are ignored.
- The panel is excluded from screen recordings by default; Settings turns that
  off for anyone who wants to photograph their own island.
- Notes and the teleprompter script live under
  `~/Library/Application Support/DynamicIsland`.

### What leaves the machine, and when

Nothing, until a switch in Settings is turned on. Both are **off by default**,
because both send something the user owns somewhere they cannot see.

- **Save clipboard screenshots** writes a copy of every image that reaches the
  pasteboard to `~/Pictures/DynamicIsland`. Kept to the most recent 200; the
  folder is otherwise the user's, and clearing goes to the Trash.
- **Lyrics** sends the current title, artist, album and — for Spotify — the
  track id to `lrclib.net`, `raw.githubusercontent.com` and `lyrics.kugou.com`
  to look words up. That is listening history leaving the Mac, so it is asked
  for rather than assumed. Results are cached on disk, capped at 500 tracks.
- **Connecting a Spotify account** (Settings → Spotify) authorizes this app
  through Spotify's own PKCE flow in the browser, for one feature the local
  APIs do not expose: Liked Songs. There is no client secret; tokens live in
  the keychain, `WhenUnlockedThisDeviceOnly`, and Disconnect deletes them.
  Translation itself is on-device and never uses the network.

The app claims one entitlement, `com.apple.security.automation.apple-events`.
It is what lets the scripting fallback drive Music or Spotify when the
MediaRemote helper is unavailable; macOS asks for that consent the first time
it is used, and refusing it costs only that fallback.

### Where the Spotify tokens are kept

Nothing here ever asks for your login password, in any build. That is a
deliberate property, and it is why the storage differs by signature:

| Build | Store | Why |
| --- | --- | --- |
| Developer ID (every release) | data-protection keychain | Scoped to the team identity in the entitlements, so the app can read what it wrote across updates and nothing else can. |
| Unsigned local build | `spotify-credentials.json`, mode `0600`, in Application Support | An ad-hoc signature has no stable identity, so the login keychain's per-binary ACL can never be satisfied twice — it would ask for your password on every rebuild while protecting the token from nothing. |

The login keychain is read in exactly one situation: you press **Import Account
From Keychain…** in Settings, which appears only when an older build left an
account there. Detecting that asks the keychain for attributes and never for
contents, so the offer itself costs no prompt; pressing it is what asks, once,
after which the account is stored where this build can read it silently.

Settings states which of the two is in use rather than leaving you to guess.
See `Sources/DynamicIslandKit/Services/TokenStore.swift`.

## Verification

Run all repository gates:

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

`Scripts/release.sh` runs exactly this list before it tags anything.

Two measurement harnesses are run by hand rather than as gates, because each
needs something the machine cannot be assumed to have:

- `Scripts/measure-performance.sh` compares idle CPU, memory and bundle size
  against a Cyclop build produced by `Scripts/build-reference.sh`.
- `Scripts/measure-sync.sh` measures position-sync accuracy against a live
  Spotify, using the probe in `Scripts/sync-probe/`. It pauses and seeks the
  music, and it fails when any phase drifts outside its stated bounds.

Manual and performance checks are tracked in [checklist.md](checklist.md) and
[docs/release-checklist.md](docs/release-checklist.md). The binding behavior and
performance contract is the approved
[Cyclop 0.6.5 parity design](docs/plans/2026-08-18-dynamic-island-parity-design.md).

## Reference and license

The parity foundation is derived from MIT-licensed Cyclop 0.6.5 at the commit
pinned in [UPSTREAM_CYCLOP_VERSION](UPSTREAM_CYCLOP_VERSION). Dynamic Island
keeps the required attribution in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) while using its own name,
bundle identity, filesystem paths, interface copy, and app icon.

See [LICENSE](LICENSE) for the project license.
