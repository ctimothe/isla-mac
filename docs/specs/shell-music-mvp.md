---
title: Shell + Music MVP Specification
description: Binding product and technical contract for the first Dynamic Island release.
lastModified: 2026-08-18
---

# Shell + Music MVP Specification

Status: accepted for implementation

## Goal

Ship a direct-download macOS utility that presents an unobtrusive island around
the built-in camera notch and exposes now-playing information plus basic media
controls. This release proves the shell and module architecture with exactly
one feature module: Music.

## Product contract

### Supported environment

- Deployment target: macOS 14.0 or newer.
- Hardware: a Mac with an active built-in camera notch.
- Distribution: signed and notarized direct download, outside the Mac App
  Store.
- Application mode: `LSUIElement`; no Dock icon. A status-menu item must expose
  About and Quit actions.

If no notched display is active, the application must not render a simulated
island. It may remain resident so it can explain the unsupported state through
the status menu and recover after a display change.

### Included behavior

- Detect and track the notched display at launch and whenever screen parameters
  change.
- Render collapsed, compact, and expanded shell states.
- Select the highest-priority active `IslandModule`; stable input order breaks
  equal-priority ties.
- Activate Music for a current playing or paused track.
- Show the current title in compact mode.
- Show title, artist, album, play/pause, previous, and next in expanded mode.
- Expand after 150 ms of hover, pin expanded state on click, and collapse 2.5 s
  after activity/hover ends when not pinned.
- Keep expanded content fully visible and center every state on the physical
  notch. Size and animation details may be tuned during hardware QA, but
  clipping, off-screen placement, and input dead zones are release blockers.

### Explicitly excluded

- Clipboard, Calendar, Translate, and Shelf modules.
- Artwork, seeking, shuffle, repeat, preferences, auto-update, and analytics.
- Private SkyLight/CGSSpace calls, lock-screen presentation, and a visual
  fallback for non-notch displays.
- Mac App Store distribution.

## Architecture

### Application layer

`DynamicIsland/App` owns process lifecycle and the status item.
`IslandPanelController` owns display observation and panel lifecycle.
`IslandPanel` is a non-activating AppKit panel, while SwiftUI owns visible
content and interaction.

The panel configuration is fixed for the MVP:

```swift
styleMask = [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow]
isFloatingPanel = true
level = .mainMenu + 3
collectionBehavior = [
    .fullScreenAuxiliary,
    .stationary,
    .canJoinAllSpaces,
    .ignoresCycle,
]
canBecomeKey = false
canBecomeMain = false
```

The panel must remain transparent, shadowless, immovable, and absent from
normal window cycling.

### Notch geometry

Detection accepts a screen when `safeAreaInsets.top > 0`. Geometry uses
`auxiliaryTopLeftArea.maxX` and `auxiliaryTopRightArea.minX` when both are
available. If those areas are unavailable but a notch signal exists, use a
centered 185 × 32 point fallback rectangle.

Never use `NSScreen.main` to choose the target because the non-activating panel
does not become key or main. Recompute on
`NSApplication.didChangeScreenParametersNotification`; hide the panel when no
supported display is active and restore it when one returns.

### Module contract

Every module conforms to `IslandModule` and provides:

```swift
@MainActor
public protocol IslandModule: AnyObject {
    var id: String { get }
    var priority: Int { get }
    var isActive: Bool { get }
    var isActivePublisher: AnyPublisher<Bool, Never> { get }
    func compactView() -> AnyView
    func expandedView() -> AnyView
}
```

`ModuleRegistry` sorts modules by descending priority once, observes their
activity publishers on the main queue, and exposes the first active module.
Music uses priority `100`.

### Music data path

MediaRemote is private and its read path is blocked for ordinary application
processes on current macOS releases. The application therefore bundles a
pinned, unmodified copy of `ungive/mediaremote-adapter` and runs:

```text
/usr/bin/perl mediaremote-adapter.pl MediaRemoteAdapter.framework stream
```

The adapter emits newline-delimited JSON. `NDJSONLineBuffer` must preserve
partial lines across pipe reads. `NowPlayingInfo` decodes all fields as
optional and treats `timestamp` as an ISO 8601 string. A track is active when
its title or artist is present, regardless of the `playing` flag.

Transport controls invoke the same bridge in `send` mode with `play`, `pause`,
`nexttrack`, or `previoustrack`. The Swift application does not link the private
framework directly.

The vendored commit is
`3ac3d4bdf862c7b5399b4fba4df5689f5c38609a`. Its BSD-3-Clause license must ship
with every binary distribution.

## Error handling

- Missing adapter resources, process-launch failure, malformed JSON, or
  adapter termination must not crash or block the application.
- Malformed lines are skipped; later valid lines remain processable.
- When observation ends, Music clears its state, becomes inactive, and allows
  the shell to collapse.
- Do not show a TCC or permission prompt for MediaRemote. No user-grantable
  MediaRemote permission exists.
- Command failures are logged and leave the visible now-playing state intact.
- Unsupported displays never receive a fake island; the status-menu state must
  remain understandable and the app must recover from screen changes.

## Verification contract

### Automated gates

From the repository root on the implementation branch:

```bash
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

The core suite must cover notch rejection and fallback geometry, exact
auxiliary-area geometry, module priority and activity changes, fragmented and
multi-line NDJSON, real now-playing payload decoding, optional fields, and
missing-resource behavior for observation and commands.

### Manual gates

All items in the runbook's hardware, Music, failure, and packaging matrices
must pass. In particular, compact and expanded content must not clip; the panel
must follow Spaces and fullscreen behavior without stealing focus; and the app
must recover after the built-in display disappears and returns.

### Release gates

- All automated and manual checks pass on physical notch hardware.
- The archive contains the adapter framework, Perl script, and license.
- The app and nested framework have valid Developer ID signatures.
- Apple notarization succeeds and the ticket is stapled to the distributed
  DMG.
- A clean user account can open the DMG, launch the app through Gatekeeper,
  control playback, and quit through the status item.

## Source-of-truth policy

This specification is binding. [`../../checklist.md`](../../checklist.md)
tracks its delivery, [`../runbook.md`](../runbook.md) operationalizes its
verification, and [`../research/technical-feasibility.md`](../research/technical-feasibility.md)
preserves the evidence behind it. Research questions do not override an
accepted requirement.
