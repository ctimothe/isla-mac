# Dynamic Island

Dynamic Island is a macOS 15+ utility that expands from the camera notch into
Music, Shelf, Clipboard, Snippets, Calendar, Translate, Notes, Teleprompter,
and Settings tools.

## Build, test, launch

Install Xcode Command Line Tools, then run from the repository root:

```bash
bash Scripts/bundle.sh release
swift test
bash Scripts/test-package.sh
open "build/Dynamic Island.app"
```

The local bundle is ad-hoc signed. It runs on the development Mac, but a build
for another Mac must use Developer ID signing and notarization as described in
[the runbook](docs/runbook.md).

## Product behavior

- Hover at the physical notch, or the centered synthetic notch on a display
  without one, to open the panel.
- Use the left rail for Music, Shelf, Clipboard, Snippets, Calendar, and
  Translate.
- Use the right rail for Notes, Teleprompter, and Settings.
- Calendar permission is requested only after pressing **Allow** in Calendar.
- Clipboard entries marked concealed, transient, or auto-generated are ignored.
- Screenshots are saved under `~/Pictures/DynamicIsland` only when the setting
  is enabled.
- Snippets, notes, and the teleprompter script live under
  `~/Library/Application Support/DynamicIsland`.

## Verification

Run all repository gates:

```bash
swift test
bash Scripts/test-provenance.sh
bash Scripts/test-branding.sh
bash Scripts/test-localizations.sh
bash Scripts/bundle.sh release
bash Scripts/test-helper.sh
bash Scripts/test-package.sh
bash Scripts/dmg.sh
```

Manual and performance checks are tracked in [checklist.md](checklist.md) and
[docs/release-checklist.md](docs/release-checklist.md). The binding behavior and
performance contract is the approved
[Cyclop 0.6.5 parity design](docs/plans/2026-08-18-dynamic-island-parity-design.md).

## Reference and license

The parity foundation is derived from MIT-licensed Cyclop 0.6.5 at pinned commit
`7ab60c8198681ea6c895fa55458448efb6e4c36e`. Dynamic Island keeps the required
attribution in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) while using its
own name, bundle identity, filesystem paths, interface copy, and app icon.

See [LICENSE](LICENSE) for the project license.
