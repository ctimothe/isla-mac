# R8d — the island's outline on Core Animation (plan)

2026-10-18. Tier 3 (it touches the shell and every surface that sits in it).
Branch `feat/redesign-r8d-outline-layer`, cut from `feat/redesign-r8c-polish`
(43e90e4). Nothing merges. Spec amendment: §19.12, in place, dated.

## What the owner reported

Second hardware review, finding 4: the island's open, close and pill morph
stutters when the Mac is saturated; the owner runs many agents compiling.
R8c cut the re-renders of a swipe, moved the volume keys off the main thread
and the pointer monitor out of the way. What was left on the list is that the
outline is a main-thread SwiftUI animation: `NotchShape` and `IslandStrokeShape`
animate `animatableData`, `.frame` animates the width and height, the shadow
is `.shadow(radius:)`, and the content is masked by a SwiftUI `.mask`, so every
frame's path, layout and shadow raster is produced on the main thread.

## Measure first

`Scripts/measure-hitches.sh <label>` (`OutlineHitchLab`) builds the shipped
view stack in a throwaway panel at the notch — alpha 0.02, mouse events
ignored, Isla itself never launched or signalled — drives the morphs from the
view model, and records the display link's callbacks (a gap is a vsync the
main thread did not answer: Apple's hitch time), the main thread's CPU time and
the longest gap, with the CPU idle, with one `yes` per core (the brief's
recipe), and with three per core. Release build; it runs outside the shell
sandbox because a display link needs a window server.

Numbers are in `docs/verification/` and in §19.12; the shape of them decided
the scope below.

## Design

The outline becomes three `CAShapeLayer`s, driven by animations the render
server runs. SwiftUI keeps deciding *what* the outline is and *on which curve*
it moves; Core Animation does the moving.

| Piece | Where | Why there |
|---|---|---|
| fill + shadow (`shadowPath`) | `IslandOutlineHost.backdrop`, a layer view under the hosting view | black under the content, shadow with no offscreen pass |
| content mask | the hosting view's own layer (`layer.mask`) | the R8c hard rule: nothing draws outside the island, on any frame, whatever state SwiftUI's layout is in |
| 2 pt stroke | `IslandOutlineHost.overlay`, a layer view over the hosting view | the border is drawn after the content; a pane's edge never lies over it |

- `OutlineState` is everything the outline is at an instant (size, radii,
  fill, stroke with its shown-ness folded into alpha, shadow opacity).
  `NotchContentView.outlineState` computes it from the properties that drew the
  outline before; a zero-size `IslandOutlineBridge` (an `NSViewRepresentable`)
  hands it to the host.
- The bridge's `updateNSView` runs once per *change*, with that change's
  transaction in `context.transaction`. `OutlineCurve.of` reads the animation
  from it (`Theme.island`, `Theme.close`'s delay, `hudSpring`, `hoverNudge`,
  Reduce Motion's 0.24 ease-in-out — none of them named in the new code) and
  samples it with SwiftUI's own `Spring` into keyframes. A `CAKeyframeAnimation`
  per layer property, all from the same progress array, so fill, shadow, mask
  and stroke cannot disagree by a frame.
- Retargeting mid-flight starts from where the outline is *now* (the host keeps
  the flight it started, and evaluates it) and, for a spring, carries the
  velocity into the new one.
- The Shelf's bubble draws outside the island and cannot be under the island's
  mask, so it moves to a small hosting view of its own above the island's.
  VoiceOver reads the island first and the bubble second, as §19.12 says; the
  bubble never coexists with an open surface. That view's layer is masked by
  the window less the outline (even-odd) on the same keyframes, so a bubble the
  main thread has not yet taken away cannot lie over a growing island.
- An outline that is already moving is turned round without `Theme.close`'s
  30 ms head start: standing still for it and then going on at the old speed
  was the one motion bug the adversarial review found.
- `NotchContentView(vm:)` without a host still draws everything itself. The
  visual lab, the layout tests and any future preview keep their SwiftUI
  render, and the equivalence tests hold the two to the same picture.
- The lock screen's pill stays SwiftUI: it never animates the outline but for a
  fold, over a window the lock path already owns. The host is hidden while the
  shell is not on screen.

## Not in this change

The content inside the island is still laid out by SwiftUI on every frame of
a morph: the frame it sits in animates, and the header, the cover and
the pages travel with it by design. That layout, not the outline, is what the
baseline shows dropping frames on a player ⇄ Settings change; the numbers are
in §19.12 and the follow-up is in the checklist. Snapping the content to its
final layout and letting the mask reveal it was considered and not done: the
compact content is pinned to the island's edges and has to travel with them
(`compactMediaHeader`), which is a design decision, not a cleanup.

## Tests

`OutlineCurveTests` (the curves are read, not defaulted; the spring follows
SwiftUI's solver; the close keeps its delay; Reduce Motion never overshoots),
`IslandOutlineHostTests` (layers and keyframes, one clock, retargeting,
hide/show, the mask), `IslandOutlineEquivalenceTests` (the layer outline and the
SwiftUI outline are the same picture, shadow included), the updated
`MotionValuesTests` shell checks, and the hitch lab as the before/after.
