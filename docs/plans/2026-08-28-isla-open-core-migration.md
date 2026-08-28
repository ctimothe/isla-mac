# Isla Open-Core Migration — Master Plan

> **For agentic workers:** this is a MASTER roadmap spanning several independent
> subsystems. Per the `writing-plans` scope check, each phase below is executed
> from its **own** detailed, bite-sized plan written at the time that phase
> starts (`docs/plans/2026-08-28-isla-<phase>.md`). Do not treat the phase
> summaries here as step-complete; they define scope, deliverable, edge cases,
> and definition-of-done for the per-phase plan that follows.

**Goal:** Rename the product from "Dynamic Island" to **Isla**, and restructure
into an enterprise-grade **open-core** public repository — an MIT free core plus
a commercially-licensed paid folder holding the **lock-screen card** as the first
paid feature, gated at runtime — without ever leaking secrets or letting paid
code become free by license omission.

**Architecture:** One public monorepo (GitLab-EE style). Root and
`Sources/` core are **MIT**; a `Paid/` target is **commercial-licensed** and
carries the lock-screen card. The free product builds and runs with the paid
target absent (lock card simply not present → upsell). A runtime entitlement
(offline signed license key, Keychain-stored) unlocks paid features in the full
build. Identity flows from one `ProductIdentity` enum plus a set of literals in
`Scripts/bundle.sh`/Info.plist.

**Tech stack:** Swift 6 tools / language mode v5, `.macOS(.v15)`, SwiftPM (no
Xcode project), `@MainActor`-heavy. Objective-C helper dylib loaded into
`/usr/bin/perl`. Distribution: signed + notarized DMG (the private MediaRemote
framework rules out the Mac App Store). `gh` CLI, GitHub owner `ctimothe`.

## Global constraints (copied from CLAUDE.md + decisions; every phase inherits these)

- macOS 15+; Swift tools 6.0, language mode v5; almost everything `@MainActor`.
- The Swift app never links MediaRemote. Helper dylib via perl stays.
- Exactly one entitlement today: `com.apple.security.automation.apple-events`.
  Adding one is a product decision, recorded in `checklist.md`, defaulting off.
- Cyclop 0.6.5 MIT attribution stays in `THIRD_PARTY_NOTICES.md` and ships in the
  bundle. `test-branding.sh` keeps banning any case-insensitive `cyclop`.
- Every user-facing string localized in `en.lproj` + `ru.lproj`; keys are the
  English text; `test-localizations.sh` enforces parity.
- Removed tabs stay removed (`TabContractTests`): Music, Shelf, Clipboard,
  Translate, Settings only.
- Secrets are release-owner inputs, never committed. `release.sh` refuses an
  unclean tree / missing notes.
- Decisions locked 2026-08-28: monorepo + commercial-licensed folder; only the
  lock screen is paid (widgets later); public brand = **Isla**; owner =
  `ctimothe`.

## The free/paid boundary (precise)

The lock screen splits. **Free core keeps** the inert locked island (the island
stays at the notch while locked, is a picture, lifts on hover, shakes on click —
`RefusalShake`) and `LockScreenPresence` (knowing locked/unlocked via
`com.apple.screenIsLocked`/`…Unlocked`). **Paid** is the interactive
**lock-screen card**: `LockCardWindow` + `LockScreenCard` — the rich media/lyrics
card that answers clicks over the shield, output switching, and volume. The
shared `LyricSweep`/`MediaController` timeline stays in the **free** core (the
island's own lyrics are free; the card only renders from that shared clock).

Everything else ships free: Music, Shelf, Clipboard, Translate, Settings, lyrics
on the island, Spotify sign-in, audio-output switching in the app, output volume.

---

## Phase 0 — Safety & foundations (non-destructive; nothing public)

**Deliverable:** a provably-clean starting point and a machine-checkable license
boundary, before any public exposure.

- **Secrets-history audit (blocking gate before publish).** Scan *all* branches'
  full history for tokens, keys, signing identities, Spotify client secrets,
  notarization creds, `.p8`/`.p12`, `Bearer`, `client_secret`, `BEGIN … PRIVATE
  KEY`, app-specific passwords. Tool: `gitleaks detect` (or `trufflehog git`).
  If anything is found → it must be scrubbed (git-filter-repo) or the public repo
  seeded from fresh history (see Phase 1). Output: a report committed to
  `docs/security/2026-08-28-history-audit.md`.
- **Paid-folder license.** Add `LICENSE-COMMERCIAL` (default: proprietary "all
  rights reserved, use requires a paid license" — pending owner confirm; FSL/BSL
  is the source-available alternative). Keep root `LICENSE` (MIT). Add
  `LICENSING.md` explaining: MIT core, commercial `Paid/`, Cyclop MIT attribution.
- **SPDX gate.** Add `// SPDX-License-Identifier: MIT` to every core source file
  and `LicenseRef-Commercial` to every paid file. New `Scripts/test-licenses.sh`
  fails if any `Sources/**` or `Paid/**` file lacks a header or a paid file
  carries MIT. Wire into the gate order alongside `test-branding.sh`.

**Definition of done:** audit report clean (or scrub plan written);
`test-licenses.sh` passes; `swift test` still green.

## Phase 1 — Repo topology → a normal public project

**Deliverable:** a repository shaped the way a public project is expected —
code on `main`, README/LICENSE/CONTRIBUTING at root.

Today `main` is docs-only and code lives on the `dynamic-island-parity` worktree
branch; `shell-music-mvp` is kept history. Target public layout puts the code at
the root of `main`.

**Approach (recommended):** seed the PUBLIC repo's history **fresh** from the
finished, renamed, restructured tree — a curated initial commit, not a push of
the existing local dev history. This sidesteps secrets-in-history entirely and
gives a professional first commit. The local bare repo
(`/Users/ctimothe/code/remotes/dynamic-island.git`) stays as the private dev
history. (Alternative: filter-repo the existing history onto `main` — only if the
owner wants the full history public and Phase 0 came back clean.)

**Definition of done:** decision recorded; a scripted, repeatable way to produce
the clean public tree from the dev worktree.

## Phase 2 — Rename: Dynamic Island → Isla  (mechanical, wide, gate-driven)

**Deliverable:** the product is Isla everywhere; identity gates prove it.

**Linchpin:** `Sources/DynamicIslandKit/App/ProductIdentity.swift` — one enum:
`displayName "Dynamic Island"→"Isla"`, `executableName "DynamicIsland"→"Isla"`,
`bundleIdentifier "dev.dynamicisland.app"→"com.ctimothe.isla"`,
`supportDirectoryName`/`screenshotDirectoryName "DynamicIsland"→"Isla"`,
`helperResourceName "libdynamicislandmedia"→"libislamedia"`,
`internalPasteboardType "dev.dynamicisland.internal"→"com.ctimothe.isla.internal"`.

**Literal touchpoints (not driven by the enum):**
- `Scripts/bundle.sh`: `CFBundleName`/`CFBundleDisplayName` → Isla; `CFBundleIdentifier`
  → `com.ctimothe.isla`; app path `build/Dynamic Island.app` → `build/Isla.app`;
  URL scheme `dynamicisland` → `isla` and `CFBundleURLName dev.dynamicisland.oauth`
  → `com.ctimothe.isla.oauth`; service `Translate in Dynamic Island` → `Translate in
  Isla`; `NSPortName`; the AppleEvents usage string; dylib output name
  `libdynamicislandmedia.dylib` → `libislamedia.dylib`; keychain access group
  `$TEAM_ID.dev.dynamicisland.app` → `$TEAM_ID.com.ctimothe.isla`.
- Swift: `AppDelegate` URL-scheme check `url.scheme == "dynamicisland"` → `"isla"`.
- Package/product name `DynamicIsland` in `Package.swift`, and the executable
  target — retarget `Scripts/*.sh` that reference it.
- Gates: `test-identity.sh` (Info.plist name/id/executable), `test-package.sh`
  (dylib + app names), `test-lifecycle.sh` / `test-helper.sh` (`pkill -x
  DynamicIsland` → `Isla`; helper resource name). `test-branding.sh`: teach it the
  Isla identity, keep the `cyclop` ban, and forbid the literal product name
  "Dynamic Island" in `Sources`/Info.plist while allowing it as a descriptive
  tagline in README/marketing only.
- Localizations: `en.lproj`/`ru.lproj` strings that embed the name (e.g. "Quit
  Dynamic Island?", "About %@" via `displayName`) updated symmetrically.
- Docs: `CLAUDE.md` "After each change" loop references `pkill -x DynamicIsland`
  and `build/Dynamic Island.app` — update; runbook/release-checklist likewise.

**Definition of done:** full gate order green (`swift test`, provenance, branding,
localizations, bundle, identity, helper, package, lifecycle, dmg) with Isla
identity; app launches as `Isla.app`.

**Edge cases:** URL-scheme change breaks Spotify OAuth until the redirect URI is
updated **both** in `Info.plist` and in the Spotify developer app; bundle-id
change moves the UserDefaults domain and keychain group → existing local
settings/tokens reset (acceptable pre-public, note in first release notes).

## Phase 3 — Extract the lock-screen card behind a seam  (the risky refactor; TDD)

**Deliverable:** free core builds and runs without the paid card; the card lives
in `Paid/` under the commercial license.

- Define `LockCardProviding` in core; the core presents a card over the shield
  only when a provider is registered **and** entitled (Phase 4). With no
  provider, the locked island stays inert (free behavior, unchanged).
- Move `LockCardWindow`, `LockScreenCard` (+ card-only helpers and their tests:
  `LockCardWindowTests`, `LockCardPaneTests`, `LockCardRenderTests`,
  `LockScreenCardRenderTests`) into a new `Paid/Sources/IslaLockScreen` target,
  SPDX `LicenseRef-Commercial`. Keep `LockScreenPresence` and the inert-locked
  island (`LockedIslandIsInertTests`, `LockedShellLayoutTests`,
  `LockedClockTests`) in the free core.
- SwiftPM separation: two products — a free app and a full app that links the
  paid target — or a build trait. Detail in the phase plan. A new test asserts the
  **free** product contains no lock-card symbols (leak guard), mirroring how
  `TabContractTests` asserts removed tabs are absent.

**Definition of done:** free product builds without `Paid/`; full product links it;
leak-guard test passes; all moved tests pass in their new home.

**Edge cases:** `NotchController` owns the lock transition and reads
`NotchPanel.normalLevel`; those primitives stay in core and the seam calls into
them — the paid target must not duplicate window-level logic.

## Phase 4 — Entitlement / licensing runtime  (net-new subsystem)

**Deliverable:** paid features locked in the free build, unlockable with a valid
license in the full build.

- `Entitlements` store answering `isUnlocked(.lockScreen)`. Free build → always
  false → upsell UI when the locked feature is reached.
- Offline signed license keys: sign with an ed25519 private key (release-owner
  secret, never committed), verify with the public key baked into the app — **no
  network, no account** required, so no new capability leaves the machine. Keys
  sold/delivered via Gumroad/Paddle/LemonSqueezy. Store the key in Keychain,
  reusing the `TokenStore`/`SpotifyAccount` pattern.
- Record in `checklist.md` as a capability (Keychain, default locked).

**Definition of done:** free build shows upsell and cannot present the card; a
signed test key unlocks it in the full build; tampered/absent key stays locked.

## Phase 5 — OSS scaffolding & publish

**Deliverable:** a professional public repo and the first notarized Isla release.

- `README.md` (what Isla is, screenshots, DMG install, build-from-source,
  free-vs-paid table, the "Dynamic Island–style companion for the Mac notch"
  tagline), `CONTRIBUTING.md` (+ DCO/CLA: contributions to `Paid/` restricted or
  require a CLA so the owner keeps commercial rights), `SECURITY.md`,
  `CODE_OF_CONDUCT.md`, `CHANGELOG.md`, `.github/` issue/PR templates. Keep and
  rename CI in `.github/workflows/build.yml`. Document that the private
  MediaRemote framework is why distribution is a notarized DMG, not the App Store.
- `gh repo create ctimothe/isla-mac --private`; add as a second remote (do not
  replace the local `origin`); push the clean renamed tree.
- Flip to **public** only after: Phase 0 audit clean, `test-licenses.sh` +
  `test-branding.sh` green, build + notarize succeed.
- First tag: notarized `Isla.dmg`.

**Definition of done:** private repo green on CI; publish checklist all ticked;
repo flipped public; v0 release published.

---

## Ordering

Phase 0 (safety) underpins all and its audit **gates** publish. Then 2 (rename) →
3 (seam, needs 2) → 4 (gating, needs 3). Phase 1 (topology) + Phase 5 (publish)
come last. Nothing is pushed to a public remote until Phase 5's checklist passes.

## Cross-cutting landmines ("do not make mistakes")

1. **Secrets in history** → scrub or fresh-history before public. Hard gate.
2. **URL scheme rename** `dynamicisland`→`isla` breaks Spotify OAuth unless the
   Spotify app redirect URI + Info.plist are both updated.
3. **Bundle-id change** moves UserDefaults domain + keychain group → local
   settings/tokens reset (fine pre-public).
4. **Name references in tooling/docs**: `pkill -x DynamicIsland`, `build/Dynamic
   Island.app`, dylib name, keychain group — sweep Scripts, CLAUDE.md, runbook.
5. **Leak guard**: a free build must contain **no** paid binary code, not merely
   a disabled feature — assert absence in tests.
6. **Branding gate nuance**: keep the `cyclop` ban; add Isla identity; allow
   "Dynamic Island" only as a descriptive tagline (README/marketing), never as
   product identity in `Sources`/Info.plist.
7. **Provenance stays**: Cyclop MIT attribution + `THIRD_PARTY_NOTICES.md` remain.
8. **CLA/DCO for `Paid/`**: without it, external contributions to paid code can't
   be relicensed/sold — restrict `Paid/` to the owner or require a CLA.
9. **Localization parity** must stay green through the rename.

## Open confirmations (recommend-and-proceed; not blockers to Phase 0)

- Paid-folder license: **proprietary "all rights reserved"** (recommended) vs
  source-available FSL/BSL (auto-opens after ~2 years).
- Repo slug: **`isla-mac`** (recommended) vs `isla-notch` vs bare `isla`.
- Domain: grab `isla.app` / an alternative to anchor the brand? (optional)
- CLA vs owner-only `Paid/` contributions.

## Execution

Each phase runs from its own detailed `writing-plans` document written when the
phase begins. Recommended first move: **Phase 0** — it is safe, non-destructive,
and its secrets audit must precede anything public regardless of later choices.
