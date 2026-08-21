# Dynamic Island — shell-music-mvp Prototype Status

Last verified: 2026-08-18

> **Superseded for the shipping product.** Everything below tracks the
> historical `shell-music-mvp` prototype. The active implementation is the
> `dynamic-island-parity` branch, governed by the approved
> [parity design](docs/plans/2026-08-18-dynamic-island-parity-design.md) and
> tracked in `.worktrees/dynamic-island-parity/checklist.md`. Where the two
> disagree — D7's "never draw a simulated fallback island", and the deferral of
> lock-screen presentation and internationalization, all three of which the
> parity product does — the parity design wins.

This file tracks delivery status only. Binding behavior belongs in the
[`Shell + Music MVP specification`](docs/specs/shell-music-mvp.md), exact
commands belong in the [`runbook`](docs/runbook.md), and supporting evidence
belongs in the [`research archive`](docs/research/technical-feasibility.md).

## Binding MVP decisions

These identifiers are stable because implementation comments refer to them.

- [x] **D1 — Panel:** use public `NSPanel` APIs with the proven
  `.mainMenu + 3` window level and
  `.fullScreenAuxiliary`/`.stationary`/`.canJoinAllSpaces`/`.ignoresCycle`
  behaviors. Do not use private SkyLight APIs in the MVP.
- [x] **D2 — Geometry:** detect the active built-in notch with
  `safeAreaInsets.top`, prefer the auxiliary top areas for exact bounds, and
  fall back to a centered 185 × 32 point rectangle.
- [x] **D3 — Activity:** Music is active when a current track has a title or
  artist, whether it is playing or paused.
- [x] **D4 — Failure mode:** if now-playing observation becomes unavailable,
  deactivate Music and collapse the island without crashing or presenting a
  false permission prompt.
- [x] **D5 — MediaRemote integration:** vendor one pinned copy of
  `ungive/mediaremote-adapter`; use its Perl bridge for observation and its
  command mode for play, pause, next, and previous.
- [x] **D6 — Distribution:** ship outside the Mac App Store as a signed,
  notarized direct download because the Music implementation depends on a
  private framework.
- [x] **D7 — Hardware:** support only Macs with an active built-in camera
  notch. Never draw a simulated fallback island on an unnotched display.
- [x] **D8 — Architecture:** host SwiftUI content in AppKit and route feature
  modules through `IslandModule` and `ModuleRegistry`. The MVP contains exactly
  one feature module: Music.

## Completed implementation

- [x] Create the `IslandCore` Swift package with notch geometry, module
  selection, now-playing decoding, NDJSON buffering, and adapter process
  wrappers.
- [x] Cover the core package with 18 passing tests across six suites.
- [x] Create the macOS 14+ `LSUIElement` application and status-menu exit path.
- [x] Create collapsed, compact, and expanded shell states with hover and click
  transitions.
- [x] Add compact and expanded Music views with play/pause, next, and previous
  controls.
- [x] Vendor `mediaremote-adapter` at commit
  `3ac3d4bdf862c7b5399b4fba4df5689f5c38609a` with its BSD-3-Clause license.
- [x] Build the adapter as a native framework and stage the framework, Perl
  bridge, and license in the app bundle.
- [x] Decode a real adapter payload, including its ISO 8601 timestamp and
  duration field.
- [x] Verify `swift test` and an unsigned Debug `xcodebuild` on 2026-08-18.

## Required before MVP release

- [ ] Make compact and expanded panel content resize without clipping while
  remaining centered on the physical notch.
- [ ] Show a clear unsupported-display state without drawing an island, and
  recover when a supported built-in display becomes active.
- [ ] Complete the manual notch-hardware matrix in the runbook: hover, pin,
  auto-collapse, Spaces, fullscreen, display changes, and menu-bar utilities.
- [ ] Complete the Music matrix in the runbook with Apple Music plus at least
  one third-party player, including paused and unavailable-adapter cases.
- [ ] Confirm the app bundle contains the pinned adapter framework, Perl script,
  and BSD-3-Clause license in both Debug and Archive products.
- [ ] Eliminate or explicitly accept the two dependency-analysis warnings from
  the Xcode run-script phases.
- [ ] Configure Developer ID signing and Hardened Runtime for the app and its
  bundled adapter framework.
- [ ] Produce a notarized, stapled DMG and verify it on a clean user account.
- [ ] Re-run the complete automated and manual release gates and record the
  tested Mac model and macOS versions in this file.

## Deferred beyond the MVP

- Clipboard history, Calendar, Translate, and Shelf modules.
- Private SkyLight/CGSSpace integration and lock-screen presentation.
- App Store distribution.
- Artwork, seeking, shuffle, repeat, preferences, auto-update, and analytics.
- Internationalization and non-notch fallback UI.

## Risks to re-check before every release

- Apple can change or close the `/usr/bin/perl` MediaRemote bridge at any time.
- Private MediaRemote behavior can change in any macOS update.
- Window ordering can conflict with menu-bar managers and new macOS windowing
  behavior.
- A successful build does not replace validation on physical notch hardware.
