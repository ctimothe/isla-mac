# Dynamic Island for macOS

A notch-only macOS utility that hosts a compact, expandable island above the
built-in camera housing. The first shippable slice is the shell plus one Music
module.

## Project status

**The active implementation is the `dynamic-island-parity` branch**, at
`.worktrees/dynamic-island-parity` in this checkout. It is a full macOS 15+
utility — Music, Shelf, Clipboard, Translate, Notes, Teleprompter and Settings
— built to the approved
[Cyclop 0.6.5 parity design](docs/plans/2026-08-18-dynamic-island-parity-design.md),
with its own README, runbook, checklist and release scripts. Start there.

The earlier `shell-music-mvp` branch (`.worktrees/shell-music-mvp`) is the
original shell-plus-Music prototype. It is kept as historical work: the parity
design lists treating it as the production implementation among its non-goals.
The documents in this directory describe that prototype unless they say
otherwise.

## Documentation map

For the active implementation, read
[`.worktrees/dynamic-island-parity/README.md`](.worktrees/dynamic-island-parity/README.md)
and the
[parity design](docs/plans/2026-08-18-dynamic-island-parity-design.md), which is
its binding contract.

The documents below describe the historical `shell-music-mvp` prototype, in
order:

1. [`docs/specs/shell-music-mvp.md`](docs/specs/shell-music-mvp.md) — binding
   product and technical contract *for that prototype*.
2. [`checklist.md`](checklist.md) — completed work and remaining gates.
3. [`docs/runbook.md`](docs/runbook.md) — exact build, test, and manual QA flow.
4. [`docs/research/technical-feasibility.md`](docs/research/technical-feasibility.md)
   — supporting research and historical questions; non-binding.

When documents disagree, the specification wins. Update the specification
first when a product or architecture decision changes, then update the
checklist and implementation in the same change.

## Quick verification

For the active parity implementation:

```bash
cd .worktrees/dynamic-island-parity
swift test
bash Scripts/bundle.sh release
bash Scripts/test-package.sh
```

For the historical prototype:

```bash
cd .worktrees/shell-music-mvp
swift test --package-path Packages/IslandCore
xcodebuild \
  -project DynamicIsland.xcodeproj \
  -scheme DynamicIsland \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/xcode \
  CODE_SIGNING_ALLOWED=NO \
  build
```

See the runbook before launching or preparing a distributable build.
