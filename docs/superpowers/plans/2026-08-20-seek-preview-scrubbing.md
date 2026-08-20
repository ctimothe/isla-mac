# Seek-Preview Scrubbing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A floating time bubble over the Media pane's progress bar previews the seek target during hover and drag.

**Architecture:** Pure math in a new stateless `ScrubPreview` enum (unit-tested); `MediaPane` gains view-local hover state via `.onContinuousHover` and a display-only capsule overlay. No model, controller, or wire-protocol changes.

**Tech Stack:** SwiftUI (macOS 15 deployment target), swift-tools 6.0 in language mode v5, XCTest.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-20-seek-preview-scrubbing-design.md` is binding.
- Working directory: the `.worktrees/dynamic-island-parity` worktree — run all commands from its root.
- A live concurrent session shares this worktree. `git add` exact paths only; commit with an explicit pathspec (`git commit -m "…" -- <paths>`). Never `git add -A`, `git add .`, bare `git commit`, checkout, reset, stash, or clean.
- Do not modify: `NotchViewModel.swift`, `NotchGeometry.swift`, `NotchMetrics.swift`, `Skeleton.swift`, `Theme.swift`, `CompactMediaActivity.swift`, `NotchContentView.swift` (concurrent WIP).
- No new user-visible strings, so no localization-table changes.
- Existing helpers to reuse, not redefine: `formatTime(_:)` (free function, `Sources/DynamicIslandKit/UI/Theme.swift:52`), `Theme.surface`, `Theme.hairline`, `Theme.contentAnimation`.

---

### Task 1: ScrubPreview pure helper

**Files:**
- Create: `Sources/DynamicIslandKit/UI/ScrubPreview.swift`
- Test: `Tests/DynamicIslandKitTests/ScrubPreviewTests.swift`

**Interfaces:**
- Consumes: nothing project-specific (`CoreGraphics.CGFloat`, `Double`).
- Produces (Task 2 relies on these exact signatures):
  - `enum ScrubPreview` with
    `static func fraction(x: CGFloat, width: CGFloat, duration: Double) -> Double?`
    and
    `static func bubbleCenterX(x: CGFloat, width: CGFloat, bubbleWidth: CGFloat) -> CGFloat`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/DynamicIslandKitTests/ScrubPreviewTests.swift`:

```swift
import XCTest
@testable import DynamicIslandKit

final class ScrubPreviewTests: XCTestCase {
    // MARK: fraction

    func testFractionClampsBelowZeroAndAboveWidth() {
        XCTAssertEqual(ScrubPreview.fraction(x: -20, width: 200, duration: 100), 0)
        XCTAssertEqual(ScrubPreview.fraction(x: 250, width: 200, duration: 100), 1)
    }

    func testFractionMapsMidpointToHalf() {
        XCTAssertEqual(ScrubPreview.fraction(x: 100, width: 200, duration: 100), 0.5)
    }

    func testFractionIsNilWithoutDurationOrWidth() {
        // A live stream reports duration 0 and must show no preview.
        XCTAssertNil(ScrubPreview.fraction(x: 50, width: 200, duration: 0))
        XCTAssertNil(ScrubPreview.fraction(x: 50, width: 0, duration: 100))
        XCTAssertNil(ScrubPreview.fraction(x: 50, width: 200, duration: -1))
    }

    // MARK: bubbleCenterX

    func testBubbleCenterClampsAtBothEdges() {
        XCTAssertEqual(ScrubPreview.bubbleCenterX(x: 0, width: 200, bubbleWidth: 40), 20)
        XCTAssertEqual(ScrubPreview.bubbleCenterX(x: 200, width: 200, bubbleWidth: 40), 180)
    }

    func testBubbleCenterPassesThroughMidBar() {
        XCTAssertEqual(ScrubPreview.bubbleCenterX(x: 77, width: 200, bubbleWidth: 40), 77)
    }

    func testBubbleCenterPinsToCenterWhenBarNarrowerThanBubble() {
        XCTAssertEqual(ScrubPreview.bubbleCenterX(x: 3, width: 30, bubbleWidth: 40), 15)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ScrubPreviewTests 2>&1 | tail -5`
Expected: compile error — `cannot find 'ScrubPreview' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/DynamicIslandKit/UI/ScrubPreview.swift`:

```swift
import CoreGraphics

/// Pure math for the scrubber's floating time preview, kept out of the view
/// so hover→time mapping and edge clamping are unit-testable without a view
/// tree.
enum ScrubPreview {
    /// Cursor x in the bar's own space → playback fraction, clamped to 0...1.
    /// Returns nil when the bar has no width or the track has no duration —
    /// live streams report duration 0 and must show no preview.
    static func fraction(x: CGFloat, width: CGFloat, duration: Double) -> Double? {
        guard width > 0, duration > 0 else { return nil }
        return min(max(Double(x / width), 0), 1)
    }

    /// Bubble center x, clamped so the bubble never clips the bar's edges.
    /// When the bar is narrower than the bubble, pins to the bar's center.
    static func bubbleCenterX(x: CGFloat, width: CGFloat, bubbleWidth: CGFloat) -> CGFloat {
        let half = bubbleWidth / 2
        guard width > bubbleWidth else { return width / 2 }
        return min(max(x, half), width - half)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ScrubPreviewTests 2>&1 | tail -5`
Expected: `Executed 6 tests, with 0 failures`.

- [ ] **Step 5: Commit (pathspec only)**

```bash
git add Sources/DynamicIslandKit/UI/ScrubPreview.swift Tests/DynamicIslandKitTests/ScrubPreviewTests.swift
git commit -m "feat: add pure scrub-preview math

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" -- Sources/DynamicIslandKit/UI/ScrubPreview.swift Tests/DynamicIslandKitTests/ScrubPreviewTests.swift
```

---

### Task 2: MediaPane bubble wiring

**Files:**
- Modify: `Sources/DynamicIslandKit/UI/MediaPane.swift` (scrubber section, lines ~92–146)

**Interfaces:**
- Consumes: `ScrubPreview.fraction(x:width:duration:)` and
  `ScrubPreview.bubbleCenterX(x:width:bubbleWidth:)` from Task 1;
  existing `formatTime(_:)`, `Theme.surface`, `Theme.hairline`,
  `Theme.contentAnimation`; existing `@State scrubHover: Bool` and
  `@State scrubbing: Double?`.
- Produces: nothing consumed elsewhere — view-internal only.

- [ ] **Step 1: Add hover-position state**

In `MediaPane`, directly under the existing `@State private var scrubbing: Double?` (line ~8), add:

```swift
    /// Cursor x inside the bar while hovering, for the floating time preview.
    @State private var hoverX: CGFloat?
```

- [ ] **Step 2: Track the cursor and render the bubble**

Inside `scrubber`'s `GeometryReader` closure, the existing `ZStack` chain ends with `.animation(Theme.contentAnimation, value: scrubHover)`. Insert `.onContinuousHover` right after the existing `.onHover { scrubHover = $0 }` line, and add the bubble as an `.overlay` after the `.animation` modifier:

```swift
                .onHover { scrubHover = $0 }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location): hoverX = location.x
                    case .ended: hoverX = nil
                    }
                }
```

and after `.animation(Theme.contentAnimation, value: scrubHover)`:

```swift
                .overlay(alignment: .topLeading) {
                    previewBubble(width: width, filled: filled)
                }
```

- [ ] **Step 3: Implement the bubble view**

Add below the `scrubber` property (after line ~146, before `// MARK: - Transport`):

```swift
    /// Bubble width is fixed rather than measured: formatTime yields "m:ss"
    /// through "mm:ss" in the 10 pt monospaced ramp, which all fit in 44 pt,
    /// and a constant keeps ScrubPreview's clamping deterministic.
    private static let bubbleWidth: CGFloat = 44

    /// Floating time preview above the bar. Drag wins over hover: while a
    /// drag is in flight the bubble follows the thumb, not the cursor.
    @ViewBuilder
    private func previewBubble(width: CGFloat, filled: CGFloat) -> some View {
        let anchorX: CGFloat? = scrubbing != nil ? filled : hoverX
        if let anchorX,
           scrubbing != nil || scrubHover,
           let fraction = ScrubPreview.fraction(x: anchorX, width: width, duration: media.duration) {
            Text(formatTime(fraction * media.duration))
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.9))
                .frame(width: Self.bubbleWidth, height: 18)
                .background(Theme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
                .position(
                    x: ScrubPreview.bubbleCenterX(x: anchorX, width: width, bubbleWidth: Self.bubbleWidth),
                    y: -17
                )
                .allowsHitTesting(false)
                .transition(.opacity)
                .animation(Theme.contentAnimation, value: scrubHover)
        }
    }
```

Notes for the implementer:
- `width` and `filled` are the `GeometryReader` closure's existing local
  constants — pass them in; do not recompute.
- `y: -17` places the 18 pt-tall bubble's center 17 pt above the bar strip's
  top (~8 pt clearance above the 6 pt hovered bar). The overlay parent is the
  14 pt-tall bar frame, so a negative y renders above it; the pane has
  vertical room (blockHeight 122 with Spacers above the scrubber).
- During drag the anchor is `filled` (`width * progress`, and `progress`
  returns `scrubbing` while dragging), so the bubble follows the thumb exactly.
- `.allowsHitTesting(false)` keeps the bubble from stealing the bar's
  hover/drag events (spec requirement).

- [ ] **Step 4: Build and run the full suite**

Run: `swift build 2>&1 | tail -2 && swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`
Expected: `Build complete!` and `Executed 60 tests, with 0 failures` (54 existing + 6 from Task 1).

- [ ] **Step 5: Manual smoke check (bundle + hover)**

```bash
bash Scripts/bundle.sh release
```

Then relaunch the app and, with a real track playing: hover the Media tab's progress bar (bubble appears at cursor with the target time), drag (bubble follows thumb), release (seek lands, bubble returns to hover), and confirm a duration-less source (live stream / some browser tabs) shows no bubble.

- [ ] **Step 6: Commit (pathspec only)**

```bash
git add Sources/DynamicIslandKit/UI/MediaPane.swift
git commit -m "feat: preview the seek target while hovering or dragging the scrubber

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" -- Sources/DynamicIslandKit/UI/MediaPane.swift
```
