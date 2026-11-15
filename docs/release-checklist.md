# Isla release checklist

A release candidate is the commit CI is about to release (every merge to
`main` that changes the app). Copy this list into the pull request, or keep it
beside the release, and fill it in. Record for each gate the date, the Mac
model, the macOS version and a short result, evidence path or issue link
([runbook.md §9](runbook.md#9-evidence)). A checkbox without evidence is not a
pass.

- Release candidate: `<version>` (`Scripts/version`)
- Commit: `<sha>`
- Tester / date:
- Mac / macOS:
- Artifact SHA-256:

## Gates

1. [ ] **Unit and service tests** — `swift test` passes.
2. [ ] **Script gates** — `./scripts/check` passes all twelve steps:
   provenance, branding, localizations, bundle, identity, helper (one line of
   JSON for `get`), package, gatekeeper (skipped on an ad-hoc build, and says
   so), lifecycle (no helper outlives the app), dmg, next-release.
3. [ ] **Smoke pass** — every surface, nothing but the island, panel width
   ([runbook.md §3–3b](runbook.md#3-every-surface-smoke-pass)).
4. [ ] **Displays** — physical-notch and synthetic-notch passes, display
   changes and the lock screen ([runbook.md §4](runbook.md#4-display-passes)).
5. [ ] **Permissions and network** — on a fresh account, no launch-time
   prompting; protected-folder prompts only in the context of a Shelf action;
   with the default switches, nothing written to `~/Pictures/Isla` and no
   request but the update check leaves the Mac
   ([runbook.md §5](runbook.md#5-permission-and-network-passes-on-a-clean-account)).
6. [ ] **Localization** — English and Russian: key parity passes, and no
   clipping or untranslated copy on screen.
7. [ ] **Recovery and lifecycle** — quit and relaunch, launch at login, an
   unreadable lyrics cache, an unreadable credentials file, an unavailable
   helper, a silent-but-running helper, and a missing Shelf file
   ([runbook.md §6](runbook.md#6-failure-and-persistence-passes)).
8. [ ] **Performance** — at rest within budget (CPU ≤ 0.1 %, RSS ≤ 88 MB), and
   the Cyclop comparison when it is run
   ([runbook.md §7](runbook.md#7-performance-comparison)).
9. [ ] **Original identity** — the branding scan passes and the icon is Isla's.
10. [ ] **License and attribution** — `LICENSE` and `THIRD_PARTY_NOTICES.md`
    ship in the bundle and the provenance check passes.

## Final release controls

- [ ] Release notes exist at `docs/releases/<version>.md`, or the release job
  writes them from the `feat`/`fix`/`perf` subjects since the last tag.
- [ ] Developer ID certificate and Apple notarization credentials are
  configured, or the release is `ISLA_ADHOC=1` and says so.
- [ ] The update key ("Isla Update Signing") and the pinned certificate
  (`~/Isla Code Signing.p12`) are the same ones the last release used, and both
  are backed up in the password manager. A new key or certificate makes every
  installed copy fall back to the download page.
- [ ] The release carries `Isla-<version>.dmg.sig` beside the image.
- [ ] A copy of the previous release, on a real Mac, took this one through
  the island's offer (or Check for Updates → Update Now), kept its
  Accessibility permission, and relaunched as the new version.
- [ ] The release commit is clean, reviewed, pushed, and has no existing version
  tag.
- [ ] On a Developer ID release, the stapled DMG passes Gatekeeper on a second
  clean Mac.
- [ ] `Scripts/release.sh` produced the tag, checksum, and GitHub release URL.
- [ ] An ad-hoc release (`ISLA_ADHOC=1`) says in its release notes, under
  Install, that macOS asks again for the permissions Isla had — Desktop,
  Documents, Downloads, Automation for Music and Spotify — because an ad-hoc
  update is a new binary to macOS. Suggested line: "macOS treats each Isla
  update as a new app until Isla is signed with a Developer ID, so it asks once
  more for the folders and players Isla had access to."

Verdict: **GO** / **NO-GO**, and why.
