# App icon

Isla's icon is **A, Live Island**: one black capsule holding a coral content
tile on the left and four coral activity bars on the right, in an Apple Icon
Composer package. The owner chose A on 2026-10-16 and asked for B to be kept
unchanged as a backup that nothing uses.

## Where each piece lives

| Path | What it is | Used by the build |
|---|---|---|
| `Resources/AppIcon.icon/` | A's Icon Composer package (`icon.json` and its two SVG layers). The icon's only source. | Yes, through `Scripts/make-app-icon.sh` |
| `Resources/Assets.car` | A compiled by `actool`: the layered icon macOS 26 draws in every appearance | Yes, copied by `Scripts/bundle.sh` |
| `Resources/AppIcon.icns` | A rendered by Icon Composer's `ictool` at every size from 16 to 1024 px: the flattened fallback | Yes, copied by `Scripts/bundle.sh` |
| `docs/design/app-icon/a-live-island/` | A's editable SVG layers, Icon Composer's own 1024 px default render, and the earlier flat study | No, reference only |
| `docs/design/app-icon/b-two-activities/` | **B, Two Activities**, exactly as delivered: its Icon Composer package, SVG layers, default render and flat study | No, resting |
| `docs/design/app-icon/directions.png` | A beside B, with 16, 32 and 64 px samples | No |

## The two directions

- **A, Live Island:**
  - The capsule carries the recognition at small sizes.
  - The tile stands for what Isla is holding.
  - The bars stand for activity.
- **B, Two Activities:**
  - A shorter capsule with bars, plus a separate circle holding a coral dot.
  - Review during the design work found that the detached circle can read as
    a record or camera control at small sizes, which is why A was preferred.

Both use graphite `#111114` and signal coral `#FF665C` on the system light
fill. These are icon colours only, not app theme tokens.

## Appearances

Rendered with Icon Composer's `ictool` on 2026-10-16 (macOS 27.0.1, Xcode 27.0,
design generation 27), all six of A's macOS renditions draw correctly:
Default, Dark, ClearLight, ClearDark, TintedLight and TintedDark.

In Dark and TintedDark the black capsule sits close to the dark fill. The
system's glass edge outlines it, and the coral marks keep the composition
readable. That is the native renderer's treatment, left as delivered. Recognition
by people who have never seen the icon has not been tested.

## Changing the icon

1. Replace the contents of `Resources/AppIcon.icon/`. For B, copy the
   contents of `b-two-activities/Isla-B-Two-Activities.icon/` into it. Keep
   the package name `AppIcon.icon`: it must equal the `AppIcon` name the
   script passes to `actool` and that the bundle's `CFBundleIconName` and
   `CFBundleIconFile` refer to.
2. Run `bash Scripts/make-app-icon.sh` (needs full Xcode 26 or later).
3. Commit the package, `Resources/Assets.car` and `Resources/AppIcon.icns`
   together, then rebuild and reinstall the app.

## Provenance

- Delivered on 2026-10-15 as `Isla-A-and-B-lossless.zip`, from the owner's
  Codex design session, at
  `~/Documents/Codex/2026-10-15/a-macos-app-icon-for-isla/outputs/`.
  - Archive SHA-256:
    `4dd676db8a3220fab1bf45b6a6316ffdc3dcedcfefc7690c4cf6d1f7c01d97b1`.
  - Every file matched the archive's own `SHA256SUMS.txt` on 2026-10-16.
- Every delivered source file kept here or in `Resources/AppIcon.icon/` is a
  byte-identical copy of the delivered one. That covers the packages, SVG
  layers, renders, studies and `directions.png`. This README and the compiled
  `Resources/Assets.car` and `Resources/AppIcon.icns` are not delivered files.
- The archive's long-form design rationale (`direction.md`) and its own
  README stay in the archive and are summarised above.
