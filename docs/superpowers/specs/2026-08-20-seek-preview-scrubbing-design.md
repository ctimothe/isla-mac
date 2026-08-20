# Seek-Preview Scrubbing Design

**Status:** approved for planning
**Date:** 2026-08-20
**Scope:** first original (post-parity) feature. Automated parity gates are green;
this feature must not regress them.

## Goal

Hovering the Media pane's progress bar shows a floating time bubble at the
cursor position before any click; dragging shows the same bubble following the
thumb. The user sees exactly where a seek will land before committing it.

## Non-goals

- No relative-delta readout (e.g. `+0:42`) in the bubble.
- No remaining-time toggle on the right label.
- No changes to `MediaController`, the helper, or the seek wire protocol.
- No changes to any file the concurrent compact-pill work has uncommitted
  (`NotchViewModel`, `NotchGeometry`, `NotchMetrics`, `Skeleton`, `Theme`,
  `CompactMediaActivity`, `NotchContentView`).

## Approach

Pure SwiftUI, view-local state in `MediaPane`. `.onContinuousHover` (deployment
target is macOS 15; API needs 13+) supplies the cursor x within the bar's
`GeometryReader`. No AppKit tracking views, no published preview state.

## Components

### `ScrubPreview` (new, `Sources/DynamicIslandKit/UI/ScrubPreview.swift`)

Pure, stateless math so the behavior is unit-testable without a view tree:

```swift
enum ScrubPreview {
    /// Cursor x in the bar's own space → playback fraction, clamped to 0...1.
    /// Returns nil when the bar has no width or the track has no duration —
    /// live streams report duration 0 and must show no preview.
    static func fraction(x: CGFloat, width: CGFloat, duration: Double) -> Double?

    /// Bubble center x, clamped so the bubble never clips the bar's edges:
    /// min(max(x, bubbleWidth / 2), width - bubbleWidth / 2).
    /// When the bar is narrower than the bubble, pins to the bar's center.
    static func bubbleCenterX(x: CGFloat, width: CGFloat, bubbleWidth: CGFloat) -> CGFloat
}
```

### `MediaPane` (edit, scrubber section only)

- New `@State private var hoverX: CGFloat?` set by `.onContinuousHover` on the
  existing bar hit-shape: `.active(location)` stores `location.x`; `.ended`
  clears it. The existing `scrubHover` bool stays (drives bar thickness/knob).
- Bubble is an `overlay(alignment: .topLeading)` on the bar: monospaced
  `formatTime(fraction * media.duration)` in a capsule — `Theme.surface`
  background, `Theme.hairline` stroke, `Color.white.opacity(0.9)` text (same
  emphasis as the filled bar, brighter than the `Theme.tertiary` labels since
  the bubble is the momentary focus) at the scrubber's existing 10 pt
  monospaced size — positioned ~8 pt above the bar at `bubbleCenterX`.
- Precedence: while `scrubbing != nil` (drag in flight) the bubble follows the
  thumb (`filled` x), not the hover x. Drag end seeks (existing behavior,
  untouched) and the bubble returns to hover-driven.
- Visibility: bubble renders only when (`scrubHover` or `scrubbing != nil`)
  and `ScrubPreview.fraction` returns non-nil. Zero/unknown duration → never.
- Animation: opacity-only fade via `Theme.contentAnimation`. Position is
  instant (a preview must sit under the cursor, same rationale as the existing
  unanimated fill). Reduce Motion needs no special casing — nothing moves on a
  curve.
- The bubble is display-only: `.allowsHitTesting(false)` so it never steals
  the bar's hover/drag events.

## Error handling

- `duration <= 0` or `width <= 0`: `fraction` returns nil, bubble hidden —
  same guard family as the existing `progress` computed property.
- Hover exit mid-drag: drag state wins; `.ended` hover clears `hoverX` only.
- Track change mid-hover: bubble recomputes from the new duration on the next
  hover event; no stale-capture risk because nothing is cached.

## Testing

`Tests/DynamicIslandKitTests/ScrubPreviewTests.swift`:

1. `fraction` clamps below 0 and above width to 0 and 1.
2. `fraction` maps midpoint x to 0.5 for a nonzero duration.
3. `fraction` returns nil for zero duration and for zero width.
4. `bubbleCenterX` clamps at the left edge, right edge, and passes through
   mid-bar unchanged.
5. `bubbleCenterX` pins to bar center when the bar is narrower than the bubble.

View wiring is not unit-tested (no view-layer test seam exists in this
codebase); manual QA covers hover-in/out, drag-over-hover precedence, and a
live stream (duration 0) showing no bubble.

## Verification

- `swift test` — full suite stays green, plus the new `ScrubPreviewTests`.
- `swift build` clean.
- Manual: rebuild via `Scripts/bundle.sh`, hover and drag the scrubber against
  a real player; confirm no bubble on a duration-less stream.
