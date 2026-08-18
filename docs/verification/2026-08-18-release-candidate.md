# Dynamic Island 0.6.5 local release-candidate evidence

## Verdict

**NO-GO for public release.** The implementation and local packaging gates are
green, but UI automation, clean-account permission flows, synthetic-display
coverage, strict performance thresholds, Developer ID signing, and notarization
remain blocking release gates.

## Environment

- Date: 2026-08-18
- Machine: `Mac16,8`
- macOS: `26.5.2 (25F84)`
- Display: one internal `1512 × 982 pt` Liquid Retina XDR display
- Notch evidence: `safeAreaInsets.top = 32`, left auxiliary area
  `663 × 32 pt`, right auxiliary area `664 × 32 pt`
- Synthetic display: unavailable; no external/non-notch display connected
- Measured implementation commit: `2a454aa154ae505e603073f65244427fcb711a88`
- Cyclop reference commit: `7ab60c8198681ea6c895fa55458448efb6e4c36e`
- DMG SHA-256: `8b0d40ae3a9cccd661fb4399d68b41157a1816e190ce49205da8303d884169c3`

## Automated gates

| Gate | Result | Evidence |
| --- | --- | --- |
| Swift tests | PASS | 29 tests, 0 failures |
| Pinned provenance | PASS | `Scripts/test-provenance.sh` |
| Product branding | PASS | `Scripts/test-branding.sh` |
| English/Russian tables | PASS | 69 matching keys; both plists lint clean |
| Release bundle | PASS | `Scripts/bundle.sh release` |
| Package contract | PASS | executable, helper, icon, localizations, licenses, entitlement, signature |
| Live helper | PASS | snapshot returned for “Be Like a Woman”; helper exited after stdin closed |
| Parent/child lifecycle | PASS | app and exact-path helper terminated together |
| Versioned DMG | PASS | `build/DynamicIsland-0.6.5.dmg` built from the release bundle |
| Internal documentation links | PASS | every local Markdown target resolves |

The installed local copy at `/Applications/Dynamic Island.app` was restored to
the ordinary, uninstrumented release bundle after testing.

## Performance

See the full reproducible
[Cyclop comparison](../performance/2026-08-18-cyclop-0.6.5-baseline.md).

| Metric | Cyclop 0.6.5 | Dynamic Island | Gate |
| --- | ---: | ---: | --- |
| Peak idle CPU | 0.3% | 0.3% | FAIL: absolute product gate is 0.0% |
| Median app RSS | 50.83 MiB | 49.95 MiB | PASS |
| Median helper RSS | 19.03 MiB | 19.05 MiB | FAIL: product is one 16 KiB page higher |
| Bundle payload | 3.07 MiB | 1.44 MiB | PASS |

Each value comes from three 60-second runs per app after a three-second warm-up.
Every sampled parent shut down without leaving its helper. No tolerance was
introduced after measurement.

## Computer Use result

The verified release app was installed at `/Applications/Dynamic Island.app` and
launched with the requested Computer Use backend. The backend returned
`cgWindowNotFound` for both the build and installed paths while the app and its
media helper were verifiably running.

Three isolated discovery attempts were made and then stopped under the debugging
gate:

1. An environment-only test launch opened the real panel.
2. An invisible accessibility title and label were applied to the borderless
   `NSPanel`.
3. The test-only panel was brought to normal window level and made key/shareable.

Computer Use still returned `cgWindowNotFound`. All temporary UI-test changes
were removed, and the installed app was restored from the ordinary release
bundle. No tab or 100-cycle workflow is marked passed from this run.

## Open release blockers

- Exercise all nine tabs and the 100 open/close cycles through a backend that can
  control the borderless panel, or record an equivalent supervised manual run.
- Run Calendar and protected-file permission flows on a clean macOS account.
- Run the synthetic-notch display flow; only a physical-notch display is present.
- Resolve or explicitly revise the contradictory absolute-idle CPU gate: Cyclop
  and Dynamic Island both peaked at `0.3%` under the approved sampler.
- Resolve the one-page helper RSS delta under the strict no-greater-than gate.
- Run Developer ID signing, Apple notarization, stapling, and second-Mac
  Gatekeeper validation with owner credentials.
- Add committed release notes and publish only after every blocker is closed.
