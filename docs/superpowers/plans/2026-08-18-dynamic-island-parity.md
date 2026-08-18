# Dynamic Island Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a production-ready Dynamic Island macOS application with Cyclop 0.6.5 feature and performance parity, original identity, preserved MIT attribution, and reproducible release evidence.

**Architecture:** Import the pinned Cyclop 0.6.5 foundation, preserve its AppKit `NSPanel` plus SwiftUI behavior and MediaRemote helper, and repackage it as a small executable over a testable `DynamicIslandKit` library. Add dependency seams only where they are required for deterministic tests, then validate the resulting release side by side with the pinned reference.

**Tech Stack:** Swift 6 toolchain in Swift 5 language mode, Swift Package Manager, AppKit, SwiftUI, Combine, EventKit, Translation, QuickLookThumbnailing, Objective-C MediaRemote helper hosted by `/usr/bin/perl`, XCTest, Bash, Python 3, codesign, and hdiutil.

**Spec:** `docs/plans/2026-08-18-dynamic-island-parity-design.md`

## Global Constraints

- Pin the behavioral source to Cyclop 0.6.5 commit `7ab60c8198681ea6c895fa55458448efb6e4c36e`.
- Target macOS 15 or later and keep Swift language mode 5 for the imported application code.
- Product name is `Dynamic Island`; executable is `DynamicIsland`; bundle identifier is `dev.dynamicisland.app`.
- Application support is `~/Library/Application Support/DynamicIsland`; saved screenshots are `~/Pictures/DynamicIsland`.
- Do not read, migrate, modify, or delete data under Cyclop's support or screenshot paths.
- Preserve upstream MIT attribution in `LICENSE` and `THIRD_PARTY_NOTICES.md`.
- Do not ship Cyclop's icon, screenshots, website, marketing copy, bundle identifier, or product-facing name.
- Preserve the fixed `700 × 444 pt` window, `620 × 208 pt` standard body, and `620 × 400 pt` teleprompter body.
- Preserve `50 ms` open delay, `320 ms` close delay, `150 ms` tab dwell, `60 Hz` active pointer sampling, `8 Hz` idle sampling, and the three-second rest threshold.
- Keep clipboard and media state transient; request Calendar access only from an explicit button action; touch protected Shelf files only when Shelf is visible.
- Do not add cloud sync, accounts, analytics, network services, or new permissions during parity work.
- Use test-first changes, run the scoped test before and after each implementation step, and make one focused commit per task.

---

## File structure

The completed implementation has these ownership boundaries:

```text
Package.swift                              SwiftPM products, library, app, and test target
Sources/DynamicIsland/main.swift           minimal process entry point
Sources/DynamicIslandKit/App/              app lifecycle, status item, product identity
Sources/DynamicIslandKit/Model/            tab orchestration and privacy state
Sources/DynamicIslandKit/Notch/            geometry, panel, pointer, and shell controller
Sources/DynamicIslandKit/Services/         feature state, persistence, and OS adapters
Sources/DynamicIslandKit/UI/               SwiftUI panes and shared visual components
Sources/DynamicIslandMediaHelper/helper.m  MediaRemote newline-JSON bridge
Resources/*.lproj/                         English and Russian localized strings
Resources/AppIcon.icns                     generated original Dynamic Island icon
Tests/DynamicIslandKitTests/               deterministic unit and service tests
Scripts/bundle.sh                          release app assembly and signing
Scripts/dmg.sh                             reproducible local disk image
Scripts/test-helper.sh                     helper response and shutdown contract
Scripts/test-branding.sh                   forbidden identity and path scan
Scripts/test-localizations.sh              localization key parity
Scripts/test-package.sh                    bundle metadata/resource/signature checks
Scripts/measure-performance.sh             reference-versus-product resource sampling
Scripts/version                            single release version source
UPSTREAM_CYCLOP_VERSION                    pinned provenance record
THIRD_PARTY_NOTICES.md                     upstream copyright and MIT notice
docs/runbook.md                            build, permission, UI, and release procedure
docs/release-checklist.md                  human release gates
docs/performance/                          generated comparison evidence
```

The imported feature files retain their focused upstream responsibilities. Do
not combine panes or stores while establishing parity.

### Task 1: Import the pinned, attributed foundation

**Files:**
- Create: `Package.swift`
- Create: `Sources/Cyclop/App/AppDelegate.swift`
- Create: `Sources/Cyclop/App/Strings.swift`
- Create: `Sources/Cyclop/Model/NotchViewModel.swift`
- Create: `Sources/Cyclop/Model/PrivacyMode.swift`
- Create: `Sources/Cyclop/Notch/NotchController.swift`
- Create: `Sources/Cyclop/Notch/NotchGeometry.swift`
- Create: `Sources/Cyclop/Notch/NotchPanel.swift`
- Create: `Sources/Cyclop/Notch/NotchRootView.swift`
- Create: `Sources/Cyclop/Notch/PointerWatcher.swift`
- Create: `Sources/Cyclop/Services/CalendarStore.swift`
- Create: `Sources/Cyclop/Services/ClipboardStore.swift`
- Create: `Sources/Cyclop/Services/DebouncedWrite.swift`
- Create: `Sources/Cyclop/Services/MediaController.swift`
- Create: `Sources/Cyclop/Services/NoteStore.swift`
- Create: `Sources/Cyclop/Services/NowPlayingFeed.swift`
- Create: `Sources/Cyclop/Services/PlayerBridge.swift`
- Create: `Sources/Cyclop/Services/ScreenshotVault.swift`
- Create: `Sources/Cyclop/Services/ShelfStore.swift`
- Create: `Sources/Cyclop/Services/SnippetStore.swift`
- Create: `Sources/Cyclop/Services/Support.swift`
- Create: `Sources/Cyclop/Services/TeleprompterStore.swift`
- Create: `Sources/Cyclop/Services/Translator.swift`
- Create: `Sources/Cyclop/UI/CalendarPane.swift`
- Create: `Sources/Cyclop/UI/ClipboardPane.swift`
- Create: `Sources/Cyclop/UI/Confirmation.swift`
- Create: `Sources/Cyclop/UI/MediaPane.swift`
- Create: `Sources/Cyclop/UI/NotchContentView.swift`
- Create: `Sources/Cyclop/UI/NotchShape.swift`
- Create: `Sources/Cyclop/UI/NotesPane.swift`
- Create: `Sources/Cyclop/UI/SettingsPane.swift`
- Create: `Sources/Cyclop/UI/ShelfDragSource.swift`
- Create: `Sources/Cyclop/UI/ShelfPane.swift`
- Create: `Sources/Cyclop/UI/Skeleton.swift`
- Create: `Sources/Cyclop/UI/SnippetsPane.swift`
- Create: `Sources/Cyclop/UI/SpoilerField.swift`
- Create: `Sources/Cyclop/UI/TeleprompterPane.swift`
- Create: `Sources/Cyclop/UI/Theme.swift`
- Create: `Sources/Cyclop/UI/TranslatePane.swift`
- Create: `Sources/Cyclop/main.swift`
- Create: `Sources/CyclopMediaHelper/helper.m`
- Create: `Resources/en.lproj/Localizable.strings`
- Create: `Resources/ru.lproj/Localizable.strings`
- Create: `Scripts/bundle.sh`
- Create: `Scripts/dmg.sh`
- Create: `Scripts/release.sh`
- Create: `Scripts/test-helper.sh`
- Create: `Scripts/version`
- Create: `LICENSE`
- Create: `THIRD_PARTY_NOTICES.md`
- Create: `UPSTREAM_CYCLOP_VERSION`
- Create: `Scripts/test-provenance.sh`

**Interfaces:**
- Consumes: The approved design and the public Git repository at the pinned commit.
- Produces: A buildable, unmodified behavioral baseline plus explicit provenance; it intentionally is not yet a distributable Dynamic Island build.

- [ ] **Step 1: Write the failing provenance test**

Create `Scripts/test-provenance.sh` with executable mode:

```bash
#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIN="$ROOT/UPSTREAM_CYCLOP_VERSION"
NOTICE="$ROOT/THIRD_PARTY_NOTICES.md"

grep -qx 'UPSTREAM_VERSION=0.6.5' "$PIN"
grep -qx 'UPSTREAM_COMMIT=7ab60c8198681ea6c895fa55458448efb6e4c36e' "$PIN"
grep -qx 'UPSTREAM_URL=https://github.com/akalikbergenov/cyclop' "$PIN"
grep -q 'MIT License' "$NOTICE"
grep -q 'Copyright (c) 2026 akalikbergenov' "$NOTICE"
test ! -e "$ROOT/docs/panel.png"
```

- [ ] **Step 2: Run it and verify the missing provenance fails**

Run: `bash Scripts/test-provenance.sh`

Expected: FAIL because `UPSTREAM_CYCLOP_VERSION` does not exist.

- [ ] **Step 3: Import exactly the permitted upstream files**

Use a disposable clone and copy the source, localization, build scripts, and
license. Do not copy the upstream icon, website, screenshots, funding file, or
release history.

```bash
reference_checkout="$(mktemp -d)"
trap 'rm -rf "$reference_checkout"' EXIT
git clone --quiet https://github.com/akalikbergenov/cyclop.git "$reference_checkout/source"
git -C "$reference_checkout/source" checkout --quiet 7ab60c8198681ea6c895fa55458448efb6e4c36e
cp "$reference_checkout/source/Package.swift" Package.swift
cp -R "$reference_checkout/source/Sources" Sources
mkdir -p Resources Scripts
cp -R "$reference_checkout/source/Resources/en.lproj" Resources/
cp -R "$reference_checkout/source/Resources/ru.lproj" Resources/
cp "$reference_checkout/source/Scripts/bundle.sh" Scripts/
cp "$reference_checkout/source/Scripts/dmg.sh" Scripts/
cp "$reference_checkout/source/Scripts/release.sh" Scripts/
cp "$reference_checkout/source/Scripts/test-helper.sh" Scripts/
cp "$reference_checkout/source/Scripts/version" Scripts/
cp "$reference_checkout/source/LICENSE" LICENSE
```

Create `UPSTREAM_CYCLOP_VERSION` exactly as:

```text
UPSTREAM_VERSION=0.6.5
UPSTREAM_COMMIT=7ab60c8198681ea6c895fa55458448efb6e4c36e
UPSTREAM_URL=https://github.com/akalikbergenov/cyclop
UPSTREAM_LICENSE=MIT
```

Create `THIRD_PARTY_NOTICES.md` with the upstream project name, URL, pinned
version and commit, the copyright line from `LICENSE`, and the complete MIT
license text copied from the pinned checkout.

- [ ] **Step 4: Prove the import is pinned and buildable**

Run:

```bash
chmod +x Scripts/*.sh
bash Scripts/test-provenance.sh
swift build -c debug
```

Expected: provenance PASS and Swift build succeeds for the imported baseline.

- [ ] **Step 5: Commit the reference foundation**

```bash
git add Package.swift Sources Resources Scripts LICENSE THIRD_PARTY_NOTICES.md UPSTREAM_CYCLOP_VERSION
git commit -m "chore: import Cyclop 0.6.5 parity foundation"
```

### Task 2: Establish the Dynamic Island package and identity

**Files:**
- Modify: `Package.swift`
- Move: `Sources/Cyclop/` to `Sources/DynamicIslandKit/`
- Move: `Sources/CyclopMediaHelper/` to `Sources/DynamicIslandMediaHelper/`
- Create: `Sources/DynamicIsland/main.swift`
- Create: `Sources/DynamicIslandKit/App/DynamicIslandApplication.swift`
- Create: `Sources/DynamicIslandKit/App/ProductIdentity.swift`
- Modify: `Sources/DynamicIslandKit/App/AppDelegate.swift`
- Modify: `Sources/DynamicIslandKit/Services/NowPlayingFeed.swift`
- Modify: `Sources/DynamicIslandKit/Services/PlayerBridge.swift`
- Modify: `Sources/DynamicIslandKit/Services/ShelfStore.swift`
- Modify: all imported files containing user-visible `Cyclop` log or copy strings
- Modify: `Sources/DynamicIslandMediaHelper/helper.m`
- Modify: `Scripts/bundle.sh`
- Modify: `Scripts/dmg.sh`
- Modify: `Scripts/release.sh`
- Modify: `Scripts/test-helper.sh`
- Create: `Scripts/test-branding.sh`
- Create: `Tests/DynamicIslandKitTests/ProductIdentityTests.swift`

**Interfaces:**
- Consumes: The attributed imported baseline from Task 1.
- Produces: `DynamicIslandApplication.run()`, `ProductIdentity`, executable target `DynamicIsland`, library target `DynamicIslandKit`, helper resource `libdynamicislandmedia.dylib`, and a Swift test target.

- [ ] **Step 1: Add the identity test before defining the identity**

Create `Tests/DynamicIslandKitTests/ProductIdentityTests.swift`:

```swift
import XCTest
@testable import DynamicIslandKit

final class ProductIdentityTests: XCTestCase {
    func testCanonicalIdentity() {
        XCTAssertEqual(ProductIdentity.displayName, "Dynamic Island")
        XCTAssertEqual(ProductIdentity.executableName, "DynamicIsland")
        XCTAssertEqual(ProductIdentity.bundleIdentifier, "dev.dynamicisland.app")
        XCTAssertEqual(ProductIdentity.supportDirectoryName, "DynamicIsland")
        XCTAssertEqual(ProductIdentity.screenshotDirectoryName, "DynamicIsland")
        XCTAssertEqual(ProductIdentity.helperResourceName, "libdynamicislandmedia")
        XCTAssertEqual(ProductIdentity.internalPasteboardType, "dev.dynamicisland.internal")
        XCTAssertEqual(ProductIdentity.statusSymbolName, "capsule.fill")
    }
}
```

- [ ] **Step 2: Repackage and run the test to verify it fails**

Move all imported application files except `main.swift` into
`Sources/DynamicIslandKit`, move the helper directory, and create this package
shape:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DynamicIsland",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "DynamicIsland", targets: ["DynamicIsland"])],
    targets: [
        .target(
            name: "DynamicIslandKit",
            path: "Sources/DynamicIslandKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "DynamicIsland",
            dependencies: ["DynamicIslandKit"],
            path: "Sources/DynamicIsland",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "DynamicIslandKitTests",
            dependencies: ["DynamicIslandKit"],
            path: "Tests/DynamicIslandKitTests"
        ),
    ]
)
```

Run: `swift test --filter ProductIdentityTests`

Expected: FAIL because `ProductIdentity` and the executable entry point are absent.

- [ ] **Step 3: Add the identity and library entry point**

Create `Sources/DynamicIslandKit/App/ProductIdentity.swift`:

```swift
enum ProductIdentity {
    static let displayName = "Dynamic Island"
    static let executableName = "DynamicIsland"
    static let bundleIdentifier = "dev.dynamicisland.app"
    static let supportDirectoryName = "DynamicIsland"
    static let screenshotDirectoryName = "DynamicIsland"
    static let helperResourceName = "libdynamicislandmedia"
    static let internalPasteboardType = "dev.dynamicisland.internal"
    static let statusSymbolName = "capsule.fill"
}
```

Create `Sources/DynamicIslandKit/App/DynamicIslandApplication.swift`:

```swift
import AppKit
import ObjectiveC

public enum DynamicIslandApplication {
    @MainActor public static func run() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        objc_setAssociatedObject(app, "dynamic-island.delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
        app.run()
    }
}
```

Create `Sources/DynamicIsland/main.swift`:

```swift
import DynamicIslandKit

MainActor.assumeIsolated {
    DynamicIslandApplication.run()
}
```

Delete the imported `Sources/DynamicIslandKit/main.swift`. Update the app,
helper, scripts, localizations, logger labels, pasteboard marker, queue labels,
bundle metadata, executable names, and helper filename to the `ProductIdentity`
values. `AppDelegate` uses `ProductIdentity.statusSymbolName` rather than the
Cyclop eye symbol. `Scripts/bundle.sh` must assemble:

```text
build/Dynamic Island.app/Contents/MacOS/DynamicIsland
build/Dynamic Island.app/Contents/Resources/libdynamicislandmedia.dylib
CFBundleDisplayName = Dynamic Island
CFBundleIdentifier = dev.dynamicisland.app
CFBundleExecutable = DynamicIsland
LSMinimumSystemVersion = 15.0
```

- [ ] **Step 4: Add and run the branding gate**

Create `Scripts/test-branding.sh` so it searches product source, resources, and
build scripts while excluding attribution files and design/history documents:

```bash
#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
targets=(
    "$ROOT/Sources"
    "$ROOT/Resources"
    "$ROOT/Scripts/bundle.sh"
    "$ROOT/Scripts/dmg.sh"
    "$ROOT/Scripts/release.sh"
    "$ROOT/Scripts/test-helper.sh"
)
if [ -f "$ROOT/Scripts/make-icon.swift" ]; then
    targets+=("$ROOT/Scripts/make-icon.swift")
fi

if rg -n -i 'cyclop|com\.cyclop|libcyclopmedia' "${targets[@]}"; then
    echo "forbidden Cyclop product identity remains" >&2
    exit 1
fi

rg -q 'dev.dynamicisland.app' "$ROOT/Scripts/bundle.sh"
rg -q 'Dynamic Island.app' "$ROOT/Scripts/bundle.sh"
rg -q 'libdynamicislandmedia.dylib' "$ROOT/Scripts/bundle.sh"
```

Run:

```bash
swift test --filter ProductIdentityTests
bash Scripts/test-branding.sh
bash Scripts/bundle.sh debug
codesign --verify --deep --strict "build/Dynamic Island.app"
```

Expected: all commands PASS and the bundle contains the renamed executable and helper.

- [ ] **Step 5: Commit the package identity**

```bash
git add Package.swift Sources Resources Scripts Tests
git commit -m "feat: establish Dynamic Island application identity"
```

### Task 3: Isolate Dynamic Island persistence and privacy state

**Files:**
- Create: `Sources/DynamicIslandKit/Services/AppPaths.swift`
- Modify: `Sources/DynamicIslandKit/Services/Support.swift`
- Modify: `Sources/DynamicIslandKit/Services/SnippetStore.swift`
- Modify: `Sources/DynamicIslandKit/Services/NoteStore.swift`
- Modify: `Sources/DynamicIslandKit/Services/TeleprompterStore.swift`
- Modify: `Sources/DynamicIslandKit/Services/ScreenshotVault.swift`
- Modify: `Sources/DynamicIslandKit/Services/ShelfStore.swift`
- Modify: `Sources/DynamicIslandKit/Model/PrivacyMode.swift`
- Modify: `Sources/DynamicIslandKit/Model/NotchViewModel.swift`
- Modify: `Sources/DynamicIslandKit/UI/NotchContentView.swift`
- Modify: `Sources/DynamicIslandKit/UI/SettingsPane.swift`
- Modify: `Sources/DynamicIslandKit/UI/SnippetsPane.swift`
- Create: `Tests/DynamicIslandKitTests/AppPathsTests.swift`
- Create: `Tests/DynamicIslandKitTests/PersistenceTests.swift`
- Create: `Tests/DynamicIslandKitTests/PrivacyModeTests.swift`

**Interfaces:**
- Consumes: `ProductIdentity.supportDirectoryName`, `ProductIdentity.screenshotDirectoryName`.
- Produces: `AppPaths.live`, `AppPaths.supportFile(_:)`, injectable file URLs/defaults for stores, and `PrivacyMode(defaults:)`.

- [ ] **Step 1: Write isolation and persistence tests**

Create `AppPathsTests.swift`:

```swift
import XCTest
@testable import DynamicIslandKit

final class AppPathsTests: XCTestCase {
    func testLivePathsUseOnlyDynamicIslandDirectories() {
        XCTAssertEqual(AppPaths.live.supportDirectory.lastPathComponent, "DynamicIsland")
        XCTAssertEqual(AppPaths.live.screenshotDirectory.lastPathComponent, "DynamicIsland")
        XCTAssertFalse(AppPaths.live.supportDirectory.path.contains("/Cyclop"))
        XCTAssertFalse(AppPaths.live.screenshotDirectory.path.contains("/Cyclop"))
    }
}
```

Create `PrivacyModeTests.swift` with a unique defaults suite:

```swift
import XCTest
@testable import DynamicIslandKit

@MainActor
final class PrivacyModeTests: XCTestCase {
    func testRevealResetsWhenPanelCollapses() {
        let suite = "PrivacyModeTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let privacy = PrivacyMode(defaults: defaults)
        privacy.setCovering(.notes, true)
        privacy.reveal("note-1")
        XCTAssertFalse(privacy.hides(.notes, "note-1"))
        privacy.coverEverything()
        XCTAssertTrue(privacy.hides(.notes, "note-1"))
    }
}
```

Create `PersistenceTests.swift` covering these exact cases:

```swift
import XCTest
@testable import DynamicIslandKit

@MainActor
final class PersistenceTests: XCTestCase {
    func testMalformedSnippetsAreNotOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("snippets.json")
        try Data("{broken".utf8).write(to: file)
        let store = SnippetStore(fileURL: file, pasteboard: NSPasteboard(name: .init(UUID().uuidString)))
        store.reload()
        store.add(label: "Never", text: "overwrite")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "{broken")
        XCTAssertTrue(store.fileBroken)
    }

    func testBlankNotesAreRemovedAndFlushPersists() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("notes.json")
        let store = NoteStore(fileURL: file)
        store.add()
        store.leave()
        store.flush()
        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
}
```

- [ ] **Step 2: Run the new tests and verify missing injection points fail**

Run: `swift test --filter 'AppPathsTests|PersistenceTests|PrivacyModeTests'`

Expected: FAIL because `AppPaths` and injectable initializers do not exist.

- [ ] **Step 3: Implement one path authority and injectable stores**

Create `AppPaths.swift`:

```swift
import Foundation

struct AppPaths: Sendable {
    let supportDirectory: URL
    let screenshotDirectory: URL

    static let live: AppPaths = {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ProductIdentity.supportDirectoryName, isDirectory: true)
        let screenshots = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures", isDirectory: true)
            .appendingPathComponent(ProductIdentity.screenshotDirectoryName, isDirectory: true)
        return AppPaths(supportDirectory: support, screenshotDirectory: screenshots)
    }()

    func ensureSupportDirectory(using fm: FileManager = .default) throws {
        try fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
    }

    func supportFile(_ name: String, using fm: FileManager = .default) -> URL {
        try? fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        return supportDirectory.appendingPathComponent(name)
    }
}
```

Make `Support` delegate only to `AppPaths.live`. Add explicit defaults that
preserve production call sites:

```swift
SnippetStore(fileURL: URL = AppPaths.live.supportFile("snippets.json"), pasteboard: NSPasteboard = .general)
NoteStore(fileURL: URL = AppPaths.live.supportFile("notes.json"))
TeleprompterStore(fileURL: URL = AppPaths.live.supportFile("teleprompter.txt"), defaults: UserDefaults = .standard)
ShelfStore(defaults: UserDefaults = .standard)
PrivacyMode(defaults: UserDefaults = .standard)
ScreenshotVault(paths: AppPaths = .live)
```

Store each dependency in an instance property and replace static path/defaults
lookups with that property. `NotchViewModel` owns one `ScreenshotVault` instance,
passes it and its `SnippetStore` through `NotchContentView` to `SettingsPane`,
and passes live defaults to the stores. Convert Snippets' reveal action and the
vault's save/reveal/usage/clear actions to instance methods so they use those
same injected paths. Do not add a Cyclop migration lookup.

- [ ] **Step 4: Run persistence and full tests**

Run:

```bash
swift test --filter 'AppPathsTests|PersistenceTests|PrivacyModeTests'
swift test
```

Expected: all tests PASS; no test writes to the user's Application Support or Pictures folders.

- [ ] **Step 5: Commit isolated persistence**

```bash
git add Sources/DynamicIslandKit Tests/DynamicIslandKitTests
git commit -m "test: isolate persistence and privacy state"
```

### Task 4: Lock the shell geometry and interaction timing

**Files:**
- Create: `Sources/DynamicIslandKit/Notch/NotchMetrics.swift`
- Modify: `Sources/DynamicIslandKit/Notch/NotchGeometry.swift`
- Modify: `Sources/DynamicIslandKit/Notch/PointerWatcher.swift`
- Modify: `Sources/DynamicIslandKit/UI/NotchContentView.swift`
- Modify: `Sources/DynamicIslandKit/Model/NotchViewModel.swift`
- Create: `Tests/DynamicIslandKitTests/NotchMetricsTests.swift`
- Create: `Tests/DynamicIslandKitTests/TabContractTests.swift`

**Interfaces:**
- Consumes: The imported `NotchGeometry`, `PointerWatcher`, and tab rails.
- Produces: Pure `NotchMetrics` constants used by both runtime code and tests.

- [ ] **Step 1: Write exact metric and rail tests**

```swift
import XCTest
@testable import DynamicIslandKit

final class NotchMetricsTests: XCTestCase {
    func testApprovedGeometryAndTiming() {
        XCTAssertEqual(NotchMetrics.standardBody, CGSize(width: 620, height: 208))
        XCTAssertEqual(NotchMetrics.teleprompterBody, CGSize(width: 620, height: 400))
        XCTAssertEqual(NotchMetrics.maximumWindow, CGSize(width: 700, height: 444))
        XCTAssertEqual(NotchMetrics.openDelay, 0.05)
        XCTAssertEqual(NotchMetrics.closeDelay, 0.32)
        XCTAssertEqual(NotchMetrics.tabDwell, 0.15)
        XCTAssertEqual(NotchMetrics.fastPointerInterval, 1.0 / 60.0)
        XCTAssertEqual(NotchMetrics.idlePointerInterval, 1.0 / 8.0)
        XCTAssertEqual(NotchMetrics.restThreshold, 3.0)
        XCTAssertEqual(NotchMetrics.warmZoneHeight, 260)
        XCTAssertEqual(NotchMetrics.coolMargin, 80)
    }
}

@MainActor
final class TabContractTests: XCTestCase {
    func testRailsAndKeyboardTabsMatchParityContract() {
        XCTAssertEqual(NotchViewModel.Tab.leftRail, [.media, .shelf, .clipboard, .snippets, .calendar, .translate])
        XCTAssertEqual(NotchViewModel.Tab.rightRail, [.notes, .teleprompter, .settings])
        XCTAssertEqual(NotchViewModel.Tab.allCases.filter(\.needsKeyboard), [.snippets, .translate, .notes])
    }
}
```

- [ ] **Step 2: Run and verify the missing metric type fails**

Run: `swift test --filter 'NotchMetricsTests|TabContractTests'`

Expected: FAIL because `NotchMetrics` does not exist.

- [ ] **Step 3: Implement the single metric source**

Create `NotchMetrics.swift`:

```swift
import CoreGraphics
import Foundation

enum NotchMetrics {
    static let standardBody = CGSize(width: 620, height: 208)
    static let teleprompterBody = CGSize(width: 620, height: 400)
    static let maximumWindow = CGSize(width: 700, height: 444)
    static let openDelay: TimeInterval = 0.05
    static let closeDelay: TimeInterval = 0.32
    static let tabDwell: TimeInterval = 0.15
    static let fastPointerInterval: TimeInterval = 1.0 / 60.0
    static let idlePointerInterval: TimeInterval = 1.0 / 8.0
    static let restThreshold: TimeInterval = 3.0
    static let warmZoneHeight: CGFloat = 260
    static let coolMargin: CGFloat = 80
}
```

Replace duplicated literals in geometry, pointer scheduling, and rail hover
handling with these constants. Keep the physical-notch calculation and the
synthetic `180 pt` notch with a minimum `24 pt` menu-bar height unchanged.
Assert in `NotchGeometry.windowSize` that the calculated result equals
`NotchMetrics.maximumWindow`.

- [ ] **Step 4: Run shell tests and build**

Run:

```bash
swift test --filter 'NotchMetricsTests|TabContractTests'
swift test
bash Scripts/bundle.sh debug
```

Expected: all tests PASS and the app bundle builds without geometry warnings.

- [ ] **Step 5: Commit the shell contract**

```bash
git add Sources/DynamicIslandKit/Notch Sources/DynamicIslandKit/Model Sources/DynamicIslandKit/UI Tests/DynamicIslandKitTests
git commit -m "test: lock notch shell parity metrics"
```

### Task 5: Harden the Now Playing helper contract

**Files:**
- Create: `Sources/DynamicIslandKit/Services/NowPlayingPayloadDecoder.swift`
- Create: `Sources/DynamicIslandKit/Services/NDJSONBuffer.swift`
- Create: `Sources/DynamicIslandKit/Services/NowPlayingFailurePolicy.swift`
- Modify: `Sources/DynamicIslandKit/Services/NowPlayingFeed.swift`
- Modify: `Sources/DynamicIslandKit/Services/MediaController.swift`
- Modify: `Sources/DynamicIslandMediaHelper/helper.m`
- Modify: `Scripts/test-helper.sh`
- Create: `Tests/DynamicIslandKitTests/NowPlayingPayloadDecoderTests.swift`
- Create: `Tests/DynamicIslandKitTests/NowPlayingCommandTests.swift`
- Create: `Tests/DynamicIslandKitTests/NowPlayingLifecycleTests.swift`

**Interfaces:**
- Consumes: Newline-delimited helper JSON and `NowPlayingFeed.Command` numeric values.
- Produces: `NowPlayingPayloadDecoder.decode(_:sourceName:) -> NowPlayingPayloadDecoder.Event?`, `NDJSONBuffer.append(_:)`, `NowPlayingFailurePolicy`, bounded snapshots, helper failure events, and verified child shutdown.

- [ ] **Step 1: Write flat-payload and command tests**

```swift
import XCTest
@testable import DynamicIslandKit

final class NowPlayingPayloadDecoderTests: XCTestCase {
    func testDecodesFlatHelperSnapshot() throws {
        let line = Data(#"{"playing":true,"title":"Track","artist":"Artist","album":"Album","duration":240.0,"elapsed":12.5,"rate":1.0,"timestamp":1760000000.0,"pid":42,"commands":[0,1,4,5]}"#.utf8)
        let event = NowPlayingPayloadDecoder.decode(line) { pid in pid == 42 ? "Player" : nil }
        guard case .some(.snapshot(let value)) = event else { return XCTFail("expected snapshot") }
        XCTAssertTrue(value.isPlaying)
        XCTAssertEqual(value.title, "Track")
        XCTAssertEqual(value.source, "Player")
        XCTAssertEqual(value.commands, Set([0, 1, 4, 5]))
    }

    func testRejectsEnvelopeAndRecognizesHonestError() {
        XCTAssertNil(NowPlayingPayloadDecoder.decode(Data(#"{"type":"update","payload":{}}"#.utf8)))
        guard case .some(.unavailable) = NowPlayingPayloadDecoder.decode(Data(#"{"error":"closed"}"#.utf8)) else {
            return XCTFail("expected unavailable")
        }
    }

    func testBoundsUntrustedMetadata() {
        let longTitle = String(repeating: "a", count: 600)
        let data = try! JSONSerialization.data(withJSONObject: [
            "playing": false, "title": longTitle, "duration": 0.0,
            "elapsed": 0.0, "rate": 0.0, "timestamp": 1.0,
        ])
        guard case .some(.snapshot(let value)) = NowPlayingPayloadDecoder.decode(data) else {
            return XCTFail("expected snapshot")
        }
        XCTAssertEqual(value.title.count, 512)
    }
}

final class NowPlayingCommandTests: XCTestCase {
    func testPerClientCommandCodes() {
        XCTAssertEqual(NowPlayingFeed.Command.play.rawValue, 0)
        XCTAssertEqual(NowPlayingFeed.Command.pause.rawValue, 1)
        XCTAssertEqual(NowPlayingFeed.Command.next.rawValue, 4)
        XCTAssertEqual(NowPlayingFeed.Command.previous.rawValue, 5)
    }
}

final class NowPlayingLifecycleTests: XCTestCase {
    func testBufferPreservesFragmentsAndReturnsEveryCompleteLine() {
        var buffer = NDJSONBuffer()
        XCTAssertEqual(buffer.append(Data(#"{"title":"one""#.utf8)), [])
        XCTAssertEqual(
            buffer.append(Data("}\n{\"title\":\"two\"}\npartial".utf8)).map { String(decoding: $0, as: UTF8.self) },
            [#"{"title":"one"}"#, #"{"title":"two"}"#]
        )
        XCTAssertEqual(
            buffer.append(Data("-line\n".utf8)).map { String(decoding: $0, as: UTF8.self) },
            ["partial-line"]
        )
    }

    func testThirdConsecutiveFailureFallsBackAndSuccessResetsCount() {
        var policy = NowPlayingFailurePolicy()
        XCTAssertEqual(policy.recordFailure(), .restart(after: 2))
        XCTAssertEqual(policy.recordFailure(), .restart(after: 2))
        XCTAssertEqual(policy.recordFailure(), .fallback)
        policy.recordSuccess()
        XCTAssertEqual(policy.recordFailure(), .restart(after: 2))
    }
}
```

- [ ] **Step 2: Run the tests and verify the decoder is missing**

Run: `swift test --filter 'NowPlayingPayloadDecoderTests|NowPlayingCommandTests|NowPlayingLifecycleTests'`

Expected: FAIL because the decoder, buffer, and failure policy are undefined.

- [ ] **Step 3: Extract the bounded decoder and preserve lifecycle behavior**

Implement:

```swift
import AppKit

enum NowPlayingPayloadDecoder {
    enum Event {
        case snapshot(NowPlayingFeed.Snapshot)
        case unavailable
    }

    static func decode(
        _ line: Data,
        sourceName: (pid_t) -> String? = {
            NSRunningApplication(processIdentifier: $0)?.localizedName
        }
    ) -> Event? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return nil
        }
        if object["error"] != nil { return .unavailable }
        guard object["playing"] is Bool,
              object["duration"] is NSNumber,
              object["elapsed"] is NSNumber,
              object["rate"] is NSNumber,
              object["timestamp"] is NSNumber else { return nil }

        var snapshot = NowPlayingFeed.Snapshot()
        snapshot.isPlaying = object["playing"] as? Bool ?? false
        snapshot.title = text(object["title"])
        snapshot.artist = text(object["artist"])
        snapshot.album = text(object["album"])
        snapshot.duration = (object["duration"] as? NSNumber)?.doubleValue ?? 0
        snapshot.elapsed = (object["elapsed"] as? NSNumber)?.doubleValue ?? 0
        snapshot.rate = (object["rate"] as? NSNumber)?.doubleValue ?? 0
        if let seconds = (object["timestamp"] as? NSNumber)?.doubleValue, seconds > 0 {
            snapshot.takenAt = Date(timeIntervalSince1970: seconds)
        }
        if let base64 = object["artwork"] as? String,
           base64.count <= maxArtworkBytes / 3 * 4 + 4,
           let artwork = Data(base64Encoded: base64),
           artwork.count <= maxArtworkBytes {
            snapshot.artwork = artwork
        }
        if let pid = (object["pid"] as? NSNumber)?.int32Value, pid > 0 {
            snapshot.source = sourceName(pid_t(pid))
        }
        if let commands = object["commands"] as? [Int] {
            snapshot.commands = Set(commands)
        }
        return .snapshot(snapshot)
    }

    private static let maxTextLength = 512
    private static let maxArtworkBytes = 4 * 1024 * 1024
    private static let bidiControls = CharacterSet(
        charactersIn: "\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}"
    )

    private static func text(_ value: Any?) -> String {
        guard let string = value as? String else { return "" }
        let scalars = string.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !bidiControls.contains($0)
        }
        return String(String.UnicodeScalarView(scalars.prefix(maxTextLength)))
    }
}

struct NDJSONBuffer {
    private var pending = Data()
    private let maximumPendingBytes = 4_000_000

    mutating func append(_ chunk: Data) -> [Data] {
        pending.append(chunk)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = Data(pending[..<newline])
            pending = Data(pending[pending.index(after: newline)...])
            if !line.isEmpty { lines.append(line) }
        }
        if pending.count > maximumPendingBytes { pending.removeAll() }
        return lines
    }
}

struct NowPlayingFailurePolicy {
    enum Action: Equatable {
        case restart(after: TimeInterval)
        case fallback
    }

    private(set) var consecutiveFailures = 0

    mutating func recordFailure() -> Action {
        consecutiveFailures += 1
        return consecutiveFailures >= 3 ? .fallback : .restart(after: 2)
    }

    mutating func recordSuccess() {
        consecutiveFailures = 0
    }
}
```

Place each of the three top-level types in its correspondingly named source
file. `NDJSONBuffer.swift` and `NowPlayingFailurePolicy.swift` import
`Foundation`; the decoder imports `AppKit`.

Move the existing bounded parsing code from `NowPlayingFeed` into the decoder
and replace its raw `Data`/failure counters with `NDJSONBuffer` and
`NowPlayingFailurePolicy`; do not duplicate either behavior. Feed `.snapshot`
to `onUpdate`, and on `.unavailable` close stdin, terminate the helper, and
invoke `onUnavailable`. Set
`readabilityHandler = nil`, close the input handle, and terminate the process in
`stop()` so no handler or Perl process survives the app.

- [ ] **Step 4: Extend the helper test and run the full media gate**

Update `Scripts/test-helper.sh` to use
`build/Dynamic Island.app/Contents/Resources/libdynamicislandmedia.dylib`. It
must send `get`, validate the first JSON object as it already does, close the
FIFO writer, and fail unless the Perl PID exits within three seconds:

```bash
for _ in $(seq 1 30); do
    kill -0 "$PERL_PID" 2>/dev/null || break
    sleep 0.1
done
if kill -0 "$PERL_PID" 2>/dev/null; then
    fail "helper outlived closed stdin"
fi
wait "$PERL_PID"
PERL_PID=""
```

Run:

```bash
swift test --filter 'NowPlayingPayloadDecoderTests|NowPlayingCommandTests|NowPlayingLifecycleTests'
bash Scripts/bundle.sh release
bash Scripts/test-helper.sh
pgrep -fl 'libdynamicislandmedia' && exit 1 || true
```

Expected: tests PASS, helper returns valid flat JSON, and no helper process remains.

- [ ] **Step 5: Commit the media contract**

```bash
git add Sources/DynamicIslandKit/Services Sources/DynamicIslandMediaHelper Scripts/test-helper.sh Tests/DynamicIslandKitTests
git commit -m "fix: harden now playing helper lifecycle"
```

### Task 6: Verify Shelf, Clipboard, and screenshot behavior

**Files:**
- Modify: `Sources/DynamicIslandKit/Services/ClipboardStore.swift`
- Modify: `Sources/DynamicIslandKit/Services/ShelfStore.swift`
- Modify: `Sources/DynamicIslandKit/Services/ScreenshotVault.swift`
- Modify: `Sources/DynamicIslandKit/Model/NotchViewModel.swift`
- Create: `Tests/DynamicIslandKitTests/ClipboardStoreTests.swift`
- Create: `Tests/DynamicIslandKitTests/ShelfStoreTests.swift`
- Create: `Tests/DynamicIslandKitTests/ScreenshotVaultTests.swift`

**Interfaces:**
- Consumes: `AppPaths`, isolated `UserDefaults`, named `NSPasteboard` instances.
- Produces: `ClipboardStore(pasteboard:)`, internal `pollNow()`, `ShelfStore(defaults:)`, and instance-based `ScreenshotVault` methods.

- [ ] **Step 1: Write deterministic feature-store tests**

```swift
import XCTest
@testable import DynamicIslandKit

@MainActor
final class ClipboardStoreTests: XCTestCase {
    func testKeepsFortyNewestUniqueEntries() {
        let board = NSPasteboard(name: .init("ClipboardStoreTests.\(UUID())"))
        let store = ClipboardStore(pasteboard: board)
        for index in 0..<45 {
            board.clearContents()
            board.setString("entry-\(index)", forType: .string)
            store.pollNow()
        }
        XCTAssertEqual(store.items.count, 40)
        XCTAssertEqual(store.items.first?.preview, "entry-44")
        XCTAssertEqual(store.items.last?.preview, "entry-5")
    }

    func testConcealedPasteboardTypeIsIgnored() {
        let board = NSPasteboard(name: .init("ClipboardStoreTests.\(UUID())"))
        let store = ClipboardStore(pasteboard: board)
        board.clearContents()
        board.setString("secret", forType: .string)
        board.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        store.pollNow()
        XCTAssertTrue(store.items.isEmpty)
    }
}

@MainActor
final class ShelfStoreTests: XCTestCase {
    func testLoadUsesStoredPathsWithoutRemovingInaccessibleEntries() {
        let suite = "ShelfStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["/protected/example.txt"], forKey: "shelf.urls")
        let store = ShelfStore(defaults: defaults)
        store.load()
        XCTAssertEqual(store.items.map(\.url.path), ["/protected/example.txt"])
    }
}

final class ScreenshotVaultTests: XCTestCase {
    func testCollisionCreatesNumberedPNGWithoutDeletingEitherFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = AppPaths(supportDirectory: root.appendingPathComponent("support"), screenshotDirectory: root.appendingPathComponent("pictures"))
        let vault = ScreenshotVault(paths: paths)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try XCTUnwrap(vault.save(Data([1]), at: date))
        let second = try XCTUnwrap(vault.save(Data([2]), at: date))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: first), Data([1]))
        XCTAssertEqual(try Data(contentsOf: second), Data([2]))
    }
}
```

- [ ] **Step 2: Run tests and verify injection points fail**

Run: `swift test --filter 'ClipboardStoreTests|ShelfStoreTests|ScreenshotVaultTests'`

Expected: FAIL because the stores still bind directly to global pasteboard/defaults and vault static state.

- [ ] **Step 3: Inject dependencies without changing feature behavior**

Add these initializers and route every existing global access through the
stored dependency:

```swift
ClipboardStore(pasteboard: NSPasteboard = .general)
ShelfStore(defaults: UserDefaults = .standard)
ScreenshotVault(paths: AppPaths = .live)
```

Rename private `poll()` to internal `pollNow()` and have the timer call it. Keep
the `0.5 s` polling interval and `0.2 s` tolerance, 40-entry limit, sensitive
type opt-out, self-write marker, file-before-image precedence, Continuity image
retry, and duplicate promotion. Keep Shelf's 60-item limit, lazy `load()`,
permission-aware `refreshFromDisk()`, selection semantics, and reference-only
persistence. `ScreenshotVault.clear()` continues using Trash.

- [ ] **Step 4: Run store and full tests**

Run:

```bash
swift test --filter 'ClipboardStoreTests|ShelfStoreTests|ScreenshotVaultTests'
swift test
```

Expected: all tests PASS with no changes to the general pasteboard or live defaults.

- [ ] **Step 5: Commit productivity I/O behavior**

```bash
git add Sources/DynamicIslandKit/Services Sources/DynamicIslandKit/Model Tests/DynamicIslandKitTests
git commit -m "test: cover shelf clipboard and screenshots"
```

### Task 7: Verify Snippets, Notes, and Teleprompter behavior

**Files:**
- Modify: `Sources/DynamicIslandKit/Services/SnippetStore.swift`
- Modify: `Sources/DynamicIslandKit/Services/NoteStore.swift`
- Modify: `Sources/DynamicIslandKit/Services/TeleprompterStore.swift`
- Modify: `Sources/DynamicIslandKit/Model/NotchViewModel.swift`
- Create: `Tests/DynamicIslandKitTests/SnippetStoreTests.swift`
- Create: `Tests/DynamicIslandKitTests/NoteStoreTests.swift`
- Create: `Tests/DynamicIslandKitTests/TeleprompterStoreTests.swift`

**Interfaces:**
- Consumes: Injected files/defaults from Task 3.
- Produces: Tested JSON/plain-text persistence, search, blank cleanup, clamped preferences, scroll lifecycle, and `holdsOpen` behavior.

- [ ] **Step 1: Write behavioral tests**

```swift
import XCTest
@testable import DynamicIslandKit

@MainActor
final class SnippetStoreTests: XCTestCase {
    func testSearchMatchesLabelAndTextCaseInsensitively() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SnippetStore(fileURL: file, pasteboard: NSPasteboard(name: .init(UUID().uuidString)))
        store.add(label: "Office Address", text: "42 Example Road")
        store.query = "example"
        XCTAssertEqual(store.filtered.map(\.label), ["Office Address"])
    }
}

@MainActor
final class NoteStoreTests: XCTestCase {
    func testFirstLineIsTitleAndBlankNotesLeaveTheStore() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = NoteStore(fileURL: file)
        store.add()
        let id = store.notes[0].id
        store.update(id, text: "Heading\nBody")
        XCTAssertEqual(store.notes[0].title, "Heading")
        store.add()
        store.leave()
        XCTAssertEqual(store.notes.count, 1)
    }
}

@MainActor
final class TeleprompterStoreTests: XCTestCase {
    func testPreferencesClampAndRunningStateSuspends() {
        let suite = "TeleprompterStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(99.0, forKey: "teleprompter.speed")
        defaults.set(2.0, forKey: "teleprompter.fontSize")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? "Read me".write(to: file, atomically: true, encoding: .utf8)
        let store = TeleprompterStore(fileURL: file, defaults: defaults)
        XCTAssertEqual(store.speed, 3.0)
        XCTAssertEqual(store.fontSize, 18.0)
        store.contentHeight = 500
        store.viewportHeight = 100
        store.start()
        XCTAssertTrue(store.isRunning)
        store.suspend()
        XCTAssertFalse(store.isRunning)
    }
}
```

- [ ] **Step 2: Run and confirm uncovered title/test seams fail**

Run: `swift test --filter 'SnippetStoreTests|NoteStoreTests|TeleprompterStoreTests'`

Expected: FAIL if the injected dependencies or `Note.title` contract are missing.

- [ ] **Step 3: Implement the minimal test seams and preserve parity values**

Add this computed title to `Note`:

```swift
var title: String {
    text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        .first.map(String.init) ?? ""
}
```

Use the Task 3 dependency properties in every read, atomic write, reveal, and
copy action. Preserve the `0.8 s` debounced writes, flush-on-quit, Snippets
reload-on-entry, blank-note removal-on-leave, teleprompter `22 pt/s` base rate,
`0.3...3.0` speed, `18...64 pt` type, 60 Hz scrolling, rewind behavior, and
hold-open only while the teleprompter tab is running.

- [ ] **Step 4: Run feature and full tests**

Run:

```bash
swift test --filter 'SnippetStoreTests|NoteStoreTests|TeleprompterStoreTests'
swift test
```

Expected: all tests PASS.

- [ ] **Step 5: Commit text-tool behavior**

```bash
git add Sources/DynamicIslandKit Tests/DynamicIslandKitTests
git commit -m "test: cover snippets notes and teleprompter"
```

### Task 8: Verify Calendar, Translate, Settings, localization, and original icon

**Files:**
- Modify: `Sources/DynamicIslandKit/Services/CalendarStore.swift`
- Modify: `Sources/DynamicIslandKit/Services/Translator.swift`
- Modify: `Sources/DynamicIslandKit/UI/SettingsPane.swift`
- Modify: `Sources/DynamicIslandKit/App/AppDelegate.swift`
- Modify: `Resources/en.lproj/Localizable.strings`
- Modify: `Resources/ru.lproj/Localizable.strings`
- Create: `Sources/DynamicIslandKit/Services/CalendarAuthorizationClient.swift`
- Create: `Tests/DynamicIslandKitTests/CalendarStoreTests.swift`
- Create: `Tests/DynamicIslandKitTests/MeetingLinkTests.swift`
- Create: `Tests/DynamicIslandKitTests/TranslatorTests.swift`
- Create: `Scripts/test-localizations.sh`
- Create: `Scripts/make-icon.swift`
- Create: `Resources/AppIcon.icns`

**Interfaces:**
- Consumes: EventKit, Translation, ServiceManagement settings, `ProductIdentity`.
- Produces: `CalendarAuthorizationClient`, explicit permission behavior, meeting-provider recognition, offline route detection, localization parity, and an original generated icon.

- [ ] **Step 1: Write Calendar and translation tests**

```swift
import EventKit
import XCTest
@testable import DynamicIslandKit

@MainActor
final class CalendarStoreTests: XCTestCase {
    func testStartNeverRequestsPermission() {
        let auth = CalendarAuthorizationSpy(status: .notDetermined)
        let store = CalendarStore(authorization: auth)
        store.start()
        XCTAssertEqual(auth.requestCount, 0)
    }

    func testButtonActionRequestsPermissionOnce() {
        let auth = CalendarAuthorizationSpy(status: .notDetermined)
        let store = CalendarStore(authorization: auth)
        store.requestAccess()
        XCTAssertEqual(auth.requestCount, 1)
    }
}

final class MeetingLinkTests: XCTestCase {
    func testSupportedProviders() {
        let cases = [
            ("https://meet.google.com/abc-defg-hij", "Google Meet"),
            ("https://zoom.us/j/123", "Zoom"),
            ("https://teams.microsoft.com/l/meetup-join/abc", "Teams"),
            ("https://example.webex.com/meet/a", "Webex"),
            ("https://whereby.com/room", "Whereby"),
            ("https://meet.jit.si/room", "Jitsi"),
        ]
        for (raw, provider) in cases {
            let url = URL(string: raw)!
            XCTAssertTrue(MeetingLink.isJoinable(url))
            XCTAssertEqual(MeetingLink.provider(for: url), provider)
        }
    }
}

@MainActor
final class TranslatorTests: XCTestCase {
    func testRouteUsesCyrillicToChooseDirection() {
        XCTAssertEqual(Translator.route(for: "hello").source, Translator.english)
        XCTAssertEqual(Translator.route(for: "привет").source, Translator.russian)
        XCTAssertEqual(Translator.route(for: "hello").target, Translator.russian)
        XCTAssertEqual(Translator.route(for: "привет").target, Translator.english)
    }
}
```

Add this spy below the Calendar tests:

```swift
@MainActor
private final class CalendarAuthorizationSpy: CalendarAuthorizationClient {
    var status: EKAuthorizationStatus
    private(set) var requestCount = 0

    init(status: EKAuthorizationStatus) {
        self.status = status
    }

    func requestFullAccess(completion: @escaping (Result<Bool, Error>) -> Void) {
        requestCount += 1
        completion(.success(true))
    }
}
```

- [ ] **Step 2: Run tests and verify the authorization seam fails**

Run: `swift test --filter 'CalendarStoreTests|MeetingLinkTests|TranslatorTests'`

Expected: FAIL because `CalendarAuthorizationClient` and injectable Calendar initialization are absent.

- [ ] **Step 3: Add explicit-only authorization and localization checks**

Create:

```swift
import EventKit

@MainActor
protocol CalendarAuthorizationClient: AnyObject {
    var status: EKAuthorizationStatus { get }
    func requestFullAccess(completion: @escaping (Result<Bool, Error>) -> Void)
}

@MainActor
final class EventKitCalendarAuthorizationClient: CalendarAuthorizationClient {
    private let store: EKEventStore

    init(store: EKEventStore) {
        self.store = store
    }

    var status: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    func requestFullAccess(completion: @escaping (Result<Bool, Error>) -> Void) {
        store.requestFullAccessToEvents { granted, error in
            if let error { completion(.failure(error)) }
            else { completion(.success(granted)) }
        }
    }
}
```

Initialize `CalendarStore` with an `EKEventStore` and an optional authorization
client; when the client is absent, construct
`EventKitCalendarAuthorizationClient(store: store)` so both paths use the same
EventKit store. `start()` and tab selection may read `status` and reload
previously authorized data but must never call `requestFullAccess`; only
`requestAccess()` does so.

Create `Scripts/test-localizations.sh`:

```bash
#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for locale in en ru; do
    test -s "$ROOT/Resources/$locale.lproj/Localizable.strings"
    plutil -lint "$ROOT/Resources/$locale.lproj/Localizable.strings"
done
python3 - "$ROOT" <<'PY'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
def keys(locale):
    text = (root / "Resources" / f"{locale}.lproj" / "Localizable.strings").read_text()
    return set(re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=', text, re.M))
assert keys("en") == keys("ru"), sorted(keys("en") ^ keys("ru"))
PY
```

Rewrite product-specific localization values for Dynamic Island while retaining
the same functional key set.

- [ ] **Step 4: Generate a reproducibly original icon**

Create `Scripts/make-icon.swift`. It uses a black hardware pill and concentric
signal capsules rather than Cyclop's eye motif:

```swift
#!/usr/bin/env swift
import AppKit
import Darwin

let output = CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.icns"
let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("DynamicIsland-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

func capsule(_ rect: CGRect) -> CGPath {
    CGPath(
        roundedRect: rect,
        cornerWidth: rect.height / 2,
        cornerHeight: rect.height / 2,
        transform: nil
    )
}

func bitmap(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    context.addPath(CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil))
    context.clip()
    let bodyGradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 0.17, green: 0.18, blue: 0.22, alpha: 1),
            CGColor(red: 0.035, green: 0.04, blue: 0.055, alpha: 1),
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        bodyGradient,
        start: CGPoint(x: 512, y: 924),
        end: CGPoint(x: 512, y: 100),
        options: []
    )

    context.setFillColor(CGColor(gray: 0.005, alpha: 1))
    context.addPath(capsule(CGRect(x: 347, y: 838, width: 330, height: 86)))
    context.fillPath()

    let outer = CGRect(x: 282, y: 380, width: 460, height: 180)
    context.saveGState()
    context.addPath(capsule(outer))
    context.clip()
    let signalGradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 0.27, green: 0.84, blue: 1, alpha: 1),
            CGColor(red: 0.55, green: 0.36, blue: 1, alpha: 1),
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        signalGradient,
        start: CGPoint(x: outer.minX, y: outer.midY),
        end: CGPoint(x: outer.maxX, y: outer.midY),
        options: []
    )
    context.restoreGState()

    context.setFillColor(CGColor(red: 0.07, green: 0.08, blue: 0.11, alpha: 1))
    context.addPath(capsule(CGRect(x: 352, y: 416, width: 320, height: 108)))
    context.fillPath()
    context.setFillColor(CGColor(red: 0.96, green: 0.97, blue: 1, alpha: 1))
    context.addPath(capsule(CGRect(x: 427, y: 448, width: 170, height: 44)))
    context.fillPath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let variants: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]
for (size, name) in variants {
    let data = bitmap(size: size).representation(using: .png, properties: [:])!
    try data.write(to: iconset.appendingPathComponent("\(name).png"), options: .atomic)
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
```

- [ ] **Step 5: Run feature, localization, icon, and build gates**

Run:

```bash
swift test --filter 'CalendarStoreTests|MeetingLinkTests|TranslatorTests'
bash Scripts/test-localizations.sh
swift Scripts/make-icon.swift Resources/AppIcon.icns
test -s Resources/AppIcon.icns
bash Scripts/bundle.sh release
```

Expected: all tests PASS and the app bundle contains the generated icon.

- [ ] **Step 6: Commit permissions, localization, and original identity**

```bash
git add Sources/DynamicIslandKit Resources Scripts/make-icon.swift Scripts/test-localizations.sh Tests/DynamicIslandKitTests
git commit -m "feat: complete localized settings and permissions"
```

### Task 9: Make packaging, documentation, and CI release-ready

**Files:**
- Modify: `Scripts/bundle.sh`
- Modify: `Scripts/dmg.sh`
- Modify: `Scripts/release.sh`
- Create: `Scripts/test-package.sh`
- Create: `.github/workflows/build.yml`
- Create or replace: `README.md`
- Create or replace: `checklist.md`
- Create or replace: `docs/runbook.md`
- Create: `docs/release-checklist.md`
- Modify: `docs/specs/shell-music-mvp.md`

**Interfaces:**
- Consumes: Version, executable, helper, resources, identity, tests, and notices.
- Produces: `build/Dynamic Island.app`, `build/DynamicIsland-<version>.dmg`, packaging verification, current documentation, and CI checks.

- [ ] **Step 1: Write the package contract test**

Create `Scripts/test-package.sh`:

```bash
#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Dynamic Island.app"
PLIST="$APP/Contents/Info.plist"

test -x "$APP/Contents/MacOS/DynamicIsland"
test -f "$APP/Contents/Resources/libdynamicislandmedia.dylib"
test -f "$APP/Contents/Resources/AppIcon.icns"
test -f "$APP/Contents/Resources/en.lproj/Localizable.strings"
test -f "$APP/Contents/Resources/ru.lproj/Localizable.strings"
test -f "$APP/Contents/Resources/Licenses/LICENSE"
test -f "$APP/Contents/Resources/Licenses/THIRD_PARTY_NOTICES.md"
grep -q 'Copyright (c) 2026 akalikbergenov' \
    "$APP/Contents/Resources/Licenses/THIRD_PARTY_NOTICES.md"
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$PLIST")" = "dev.dynamicisland.app"
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$PLIST")" = "DynamicIsland"
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleDisplayName' "$PLIST")" = "Dynamic Island"
test "$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$PLIST")" = "15.0"
codesign --verify --deep --strict "$APP"
```

- [ ] **Step 2: Run it against the current bundle**

Run:

```bash
bash Scripts/bundle.sh release
bash Scripts/test-package.sh
```

Expected: FAIL until all bundle resource, metadata, notice, and signing details are correct.

- [ ] **Step 3: Finish deterministic packaging and CI**

Make `Scripts/bundle.sh` regenerate the icon before assembly, compile the helper
as `libdynamicislandmedia.dylib`, include both localizations, include
`LICENSE` and `THIRD_PARTY_NOTICES.md` under `Contents/Resources/Licenses`, strip
extended attributes, and fail on a codesign error. It uses ad-hoc signing when
`DEVELOPER_ID_APPLICATION` is unset and the named Developer ID when set.

Make `Scripts/dmg.sh` always rebuild, stage `Dynamic Island.app` plus the
`/Applications` link, name the image `DynamicIsland-<version>.dmg`, and verify
the version inside the app matches `Scripts/version`.

The GitHub workflow runs on macOS and executes exactly:

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

Release publishing remains a separate explicit action. `Scripts/release.sh`
must require a clean tree, an existing release-notes file, green local gates,
and configured GitHub/Apple credentials before it tags or uploads anything.

- [ ] **Step 4: Replace obsolete MVP documentation with the parity workflow**

Write `README.md` so its first path is build → test → launch and its source of
truth is the approved parity design. Rewrite `checklist.md` as the live parity
gate list. Rewrite `docs/runbook.md` with exact commands from this task plus the
hardware-notch, synthetic-notch, permissions, every-tab, performance, signing,
notarization, and clean-account flows. Create `docs/release-checklist.md` from
the eleven release gates in the design.

Keep `docs/specs/shell-music-mvp.md` only as a clearly marked historical
prototype spec that points to the current parity design and cannot be mistaken
for a binding contract.

- [ ] **Step 5: Run documentation and package gates**

Run:

```bash
bash Scripts/test-provenance.sh
bash Scripts/test-branding.sh
bash Scripts/test-localizations.sh
bash Scripts/bundle.sh release
bash Scripts/test-helper.sh
bash Scripts/test-package.sh
bash Scripts/dmg.sh
git diff --check
```

Expected: every command PASS and the DMG exists at the versioned path.

- [ ] **Step 6: Commit the release surface**

```bash
git add .github README.md checklist.md docs Package.swift Resources Scripts Sources Tests LICENSE THIRD_PARTY_NOTICES.md UPSTREAM_CYCLOP_VERSION
git commit -m "build: make Dynamic Island release-ready"
```

### Task 10: Measure parity and complete end-to-end validation

**Files:**
- Create: `Scripts/measure-performance.sh`
- Create: `Scripts/test-lifecycle.sh`
- Create: `Scripts/build-reference.sh`
- Create: `docs/performance/2026-08-18-cyclop-0.6.5-baseline.md`
- Modify: `checklist.md`
- Modify: `docs/release-checklist.md`

**Interfaces:**
- Consumes: Release-built Cyclop 0.6.5 reference, release-built Dynamic Island, Computer Use, and every automated gate.
- Produces: Machine-readable CPU/RSS/bundle measurements, orphan-process validation, completed UI evidence, and a release-candidate verdict.

- [ ] **Step 1: Write the lifecycle failure test**

Create `Scripts/test-lifecycle.sh`:

```bash
#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Dynamic Island.app"

open "$APP"
for _ in $(seq 1 50); do
    pgrep -x DynamicIsland >/dev/null && break
    sleep 0.1
done
pid="$(pgrep -x DynamicIsland | head -n 1)"
test -n "$pid"
kill -TERM "$pid"
for _ in $(seq 1 50); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
done
if pgrep -fl 'libdynamicislandmedia' >/dev/null; then
    echo "orphan Dynamic Island media helper" >&2
    exit 1
fi
```

- [ ] **Step 2: Run the lifecycle test before hardening**

Run: `bash Scripts/test-lifecycle.sh`

Expected: PASS only if app termination closes the helper; otherwise FAIL with the orphan process line.

- [ ] **Step 3: Add the repeatable performance sampler**

`Scripts/measure-performance.sh` accepts two `.app` paths and an output Markdown
path. For each app independently it launches the app, waits three seconds,
samples `%CPU` and RSS from `ps` once per second for 60 seconds, records helper
RSS by matching the helper dylib path, records uncompressed bundle bytes with
`du -sk`, then terminates the app and verifies the helper exits. It repeats each
application three times and uses Python's `statistics.median` for comparisons.

Create the script with this implementation:

```bash
#!/bin/bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "usage: $0 <Cyclop.app> <Dynamic Island.app> <report.md>" >&2
    exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REFERENCE_APP="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
PRODUCT_APP="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
REPORT="$3"
RAW="$(mktemp)"
trap 'rm -f "$RAW"' EXIT
echo 'label,run,sample,cpu,rss_kb,helper_rss_kb,bundle_kb,icon_bytes' > "$RAW"

sample_app() {
    local label="$1"
    local app="$2"
    local plist="$app/Contents/Info.plist"
    local executable
    local binary
    local helper
    local bundle_kb
    local icon_bytes
    executable="$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$plist")"
    binary="$app/Contents/MacOS/$executable"
    helper="$(find "$app/Contents/Resources" -maxdepth 1 -name 'lib*media.dylib' -print -quit)"
    bundle_kb="$(du -sk "$app" | awk '{print $1}')"
    icon_bytes="$(stat -f '%z' "$app/Contents/Resources/AppIcon.icns" 2>/dev/null || echo 0)"

    for run in 1 2 3; do
        "$binary" >/dev/null 2>&1 &
        local app_pid=$!
        sleep 3
        for point in $(seq 1 60); do
            kill -0 "$app_pid" 2>/dev/null || {
                echo "$label exited during sampling" >&2
                exit 1
            }
            local cpu
            local rss
            local helper_pid
            local helper_rss=0
            cpu="$(ps -p "$app_pid" -o %cpu= | tr -d ' ')"
            rss="$(ps -p "$app_pid" -o rss= | tr -d ' ')"
            helper_pid="$(pgrep -f "$helper" | head -n 1 || true)"
            if [ -n "$helper_pid" ]; then
                helper_rss="$(ps -p "$helper_pid" -o rss= | tr -d ' ')"
            fi
            echo "$label,$run,$point,$cpu,$rss,$helper_rss,$bundle_kb,$icon_bytes" >> "$RAW"
            sleep 1
        done
        kill -TERM "$app_pid"
        wait "$app_pid" 2>/dev/null || true
        sleep 1
        if pgrep -f "$helper" >/dev/null; then
            echo "$label helper survived its parent" >&2
            exit 1
        fi
    done
}

sample_app reference "$REFERENCE_APP"
sample_app product "$PRODUCT_APP"
mkdir -p "$(dirname "$REPORT")"

python3 - "$RAW" "$REPORT" "$REFERENCE_APP" "$PRODUCT_APP" "$ROOT" <<'PY'
import csv
import pathlib
import platform
import statistics
import subprocess
import sys

raw, report, reference_app, product_app, root = sys.argv[1:]
rows = list(csv.DictReader(open(raw, newline="")))

def values(label, key):
    return [float(row[key]) for row in rows if row["label"] == label]

ref_cpu = values("reference", "cpu")
product_cpu = values("product", "cpu")
ref_rss = statistics.median(values("reference", "rss_kb"))
product_rss = statistics.median(values("product", "rss_kb"))
ref_helper = statistics.median(values("reference", "helper_rss_kb"))
product_helper = statistics.median(values("product", "helper_rss_kb"))
ref_bundle = int(values("reference", "bundle_kb")[0])
product_bundle = int(values("product", "bundle_kb")[0])
ref_icon = int(values("reference", "icon_bytes")[0])
product_icon = int(values("product", "icon_bytes")[0])
icon_variance_kb = max(0, product_icon - ref_icon + 1023) // 1024
bundle_limit = ref_bundle + icon_variance_kb

checks = {
    "Dynamic Island idle CPU is 0.0% for all samples": max(product_cpu) == 0.0,
    "Dynamic Island application RSS is no greater than Cyclop": product_rss <= ref_rss,
    "Dynamic Island helper RSS is no greater than Cyclop": product_helper <= ref_helper,
    "Bundle difference is limited to original icon variance": product_bundle <= bundle_limit,
}

try:
    model = subprocess.check_output(["sysctl", "-n", "hw.model"], text=True).strip()
except Exception:
    model = "unknown"
commit = subprocess.check_output(["git", "-C", root, "rev-parse", "HEAD"], text=True).strip()
lines = [
    "# Cyclop 0.6.5 / Dynamic Island performance comparison",
    "",
    f"- Machine: `{model}`",
    f"- macOS: `{platform.mac_ver()[0]}`",
    f"- Cyclop commit: `7ab60c8198681ea6c895fa55458448efb6e4c36e`",
    f"- Dynamic Island commit: `{commit}`",
    f"- Samples: 3 runs × 60 one-second samples after 3 seconds warm-up",
    "",
    "| Metric | Cyclop 0.6.5 | Dynamic Island |",
    "| --- | ---: | ---: |",
    f"| Peak idle CPU | {max(ref_cpu):.1f}% | {max(product_cpu):.1f}% |",
    f"| Median app RSS | {ref_rss / 1024:.2f} MiB | {product_rss / 1024:.2f} MiB |",
    f"| Median helper RSS | {ref_helper / 1024:.2f} MiB | {product_helper / 1024:.2f} MiB |",
    f"| Bundle payload | {ref_bundle / 1024:.2f} MiB | {product_bundle / 1024:.2f} MiB |",
    f"| App icon | {ref_icon} bytes | {product_icon} bytes |",
    "",
    "## Gates",
    "",
]
lines.extend(f"- [{'x' if passed else ' '}] {name}" for name, passed in checks.items())
pathlib.Path(report).write_text("\n".join(lines) + "\n")
if not all(checks.values()):
    raise SystemExit(1)
PY
```

The script exits nonzero unless:

```text
Dynamic Island closed-panel CPU samples are all 0.0 after warm-up.
Dynamic Island median application RSS <= Cyclop median application RSS.
Dynamic Island median helper RSS <= Cyclop median helper RSS.
No helper remains after either parent exits.
Dynamic Island bundle payload is approximately 2.1 MB; original icon variance is itemized.
```

Write exact measured values, Mac model, macOS version, commit hashes, commands,
and pass/fail results to `docs/performance/2026-08-18-cyclop-0.6.5-baseline.md`.

- [ ] **Step 4: Build the pinned reference and run all automated gates**

Create `Scripts/build-reference.sh`:

```bash
#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REFERENCE_CHECKOUT="$(mktemp -d)"
trap 'rm -rf "$REFERENCE_CHECKOUT"' EXIT
git clone --quiet https://github.com/akalikbergenov/cyclop.git "$REFERENCE_CHECKOUT/source"
git -C "$REFERENCE_CHECKOUT/source" checkout --quiet 7ab60c8198681ea6c895fa55458448efb6e4c36e
bash "$REFERENCE_CHECKOUT/source/Scripts/bundle.sh" release
mkdir -p "$ROOT/build/reference"
rm -rf "$ROOT/build/reference/Cyclop.app"
cp -R "$REFERENCE_CHECKOUT/source/build/Cyclop.app" "$ROOT/build/reference/Cyclop.app"
```

Then run:

```bash
bash Scripts/build-reference.sh
swift test
bash Scripts/test-provenance.sh
bash Scripts/test-branding.sh
bash Scripts/test-localizations.sh
bash Scripts/bundle.sh release
bash Scripts/test-helper.sh
bash Scripts/test-package.sh
bash Scripts/test-lifecycle.sh
bash Scripts/dmg.sh
bash Scripts/measure-performance.sh \
  "build/reference/Cyclop.app" \
  "build/Dynamic Island.app" \
  "docs/performance/2026-08-18-cyclop-0.6.5-baseline.md"
git diff --check
```

Expected: every command PASS and the performance report contains no failed gate.

- [ ] **Step 5: Perform the complete Computer Use UI run**

Load the `computer-use:computer-use` skill before operating macOS UI. Install the
release build locally, then exercise and record:

```text
physical or synthetic notch opens after dwell and closes after exit delay
all six left-rail and all three right-rail tabs switch after 150 ms dwell
Music metadata, artwork, previous, play/pause, next, and seek work with a live player
Shelf drag in/out, select, multi-select, copy, open, reveal, remove, and screenshot ingest work
Clipboard records, deduplicates, restores, caps at 40, and conceals marked content
Snippets add, search, copy, remove, persist, and external-file reload work
Calendar asks only on its button, lists selected calendars, and opens a meeting URL
Translate selects English/Russian direction and reports a missing pack if unavailable
Notes focus, add, edit, copy, delete, autosave, and blank cleanup work
Teleprompter persists text, changes speed/type, scrolls smoothly, and holds the panel open
Settings, privacy covers/reveal reset, launch at login, folders, version, and Quit work
relaunch restores persistent state while clipboard/media remain transient
100 open/close panel cycles leave no orphan helper, growing timer activity, or sustained RSS increase
```

Repeat shell geometry on one hardware-notch display and one synthetic-notch
display when both are available. If only one display class is connected, record
the missing hardware class as a release blocker rather than marking it passed.
For the 100-cycle gate, automate pointer entry, wait at least `50 ms`, pointer
exit, and wait at least `320 ms` per cycle. Record `ps -p <pid> -o rss=,%cpu=`
before the loop and after a 30-second settling period; pass only when CPU returns
to `0.0%`, RSS is no more than 1 MiB above the starting sample, and the helper
count remains exactly one while the app is running and zero after Quit.

- [ ] **Step 6: Record the release verdict and commit evidence**

Update `checklist.md` and `docs/release-checklist.md` with the tested Mac model,
macOS version, display classes, media clients, permission state, automated command
results, and performance report link. Every unchecked item remains an explicit
release blocker.

```bash
git add Scripts/measure-performance.sh Scripts/test-lifecycle.sh docs/performance checklist.md docs/release-checklist.md
git commit -m "test: record Dynamic Island parity verification"
```

Run one final clean-tree gate:

```bash
git status --short
swift test
bash Scripts/test-branding.sh
bash Scripts/test-helper.sh
bash Scripts/test-package.sh
```

Expected: empty status and every command PASS. The resulting DMG is a local
release candidate; publishing, notarization credential use, and GitHub release
creation require the repository owner's separate explicit authorization.
