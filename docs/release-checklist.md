# Isla release checklist

- Release candidate: `0.6.5 local RC`
- Measured implementation commit: `2a454aa154ae505e603073f65244427fcb711a88`
- Tester/date: `Codex / 2026-08-18`
- Mac/macOS: `Mac16,8 / macOS 26.5.2 (25F84)`
- Artifact SHA-256: `a70ddc5d93e8c4d1c81675ad129e24c88c6cdb5eb2e76caff89987a2131e8594`

Complete the commands and manual flows in [runbook.md](runbook.md). Add a short
result, evidence path, or issue link to every gate.

> 2026-10-20: the gates and the verdict below are the 0.6.5 parity RC's record,
> dated 2026-08-18. Since then 0.1.0, 0.2.0 and 0.3.0 have shipped without the
> gates being refreshed. The controls under "Final release controls" apply to
> every release. How a release reaches users, and what keeps Update Now working,
> is in [runbook.md §8](runbook.md#8-releasing).

1. [x] **Unit and service tests** — every test passes (29 on the day this line was first
   written; 520 or so as of 2026-09-23 — trust the run, not this number). Evidence:
   [release-candidate report](development/verification/2026-08-18-release-candidate.md)
2. [x] **Media-helper contract** — live NDJSON response and shutdown pass;
   numeric commands and restart/fallback pass unit tests. Evidence:
   [release-candidate report](development/verification/2026-08-18-release-candidate.md)
3. [x] **Release packaging** — release bundle, ad-hoc signature, package test,
   and versioned local DMG pass. Evidence:
   [release-candidate report](development/verification/2026-08-18-release-candidate.md)
4. [ ] **UI coverage** — automated smoke coverage and Computer Use validation
   pass for every tab. Blocked: Computer Use returned `cgWindowNotFound` for
   the borderless panel after three isolated discovery attempts. Evidence:
   [release-candidate report](development/verification/2026-08-18-release-candidate.md)
5. [ ] **Permissions and network** — on a fresh account, no launch-time
   prompting; protected-folder prompts appear only in the context of a Shelf
   action; with the default switches, nothing is written to
   `~/Pictures/Isla` and no request leaves the machine. Reworded on
   2026-08-21: this gate named the removed Calendar flow and so could never be
   completed as written. Clean-account manual flow is not run. Evidence:
   [release-candidate report](development/verification/2026-08-18-release-candidate.md)
6. [ ] **Displays** — physical-notch and synthetic-notch passes complete.
   Physical notch detected, but UI workflow not completed; no synthetic display
   is connected. Evidence: [release-candidate report](development/verification/2026-08-18-release-candidate.md)
7. [ ] **Localization** — English and Russian key checks plus visual review
   key parity passes; visual review is blocked with UI coverage. Evidence:
   [release-candidate report](development/verification/2026-08-18-release-candidate.md)
8. [ ] **Recovery and lifecycle** — quit/relaunch, launch at login, an
   unreadable lyrics cache, an unreadable credentials file, an unavailable
   helper, a silent-but-running helper, and a missing Shelf file all pass.
   Reworded on 2026-08-21: this gate named the removed snippets file, and again
   on 2026-08-24, when the notes file and the teleprompter script went with
   their features. Automated persistence and helper lifecycle pass; remaining
   manual scenarios are not run. Evidence: [release-candidate report](development/verification/2026-08-18-release-candidate.md)
9. [ ] **Performance** — three-run medians meet the pinned Cyclop CPU, RSS,
   responsiveness, lifecycle, and bundle gates. The two thresholds that blocked
   this were themselves wrong and were corrected on 2026-08-21: idle CPU is now
   compared against the reference rather than against an absolute 0.0%, and a
   helper that was not running is no longer recorded as using 0 KB. Needs a
   re-run. Evidence: [performance report](development/performance/2026-08-18-cyclop-0.6.5-baseline.md)
10. [x] **Original identity** — branding scan and generated-icon visual review
    find no Cyclop
    icon, identifier, paths, screenshots, marketing copy, or unintended visible
    product strings. Evidence: [release-candidate report](development/verification/2026-08-18-release-candidate.md)
11. [x] **License and attribution** — packaged `LICENSE`,
    `THIRD_PARTY_NOTICES.md`, and pinned provenance pass. Evidence:
    [release-candidate report](development/verification/2026-08-18-release-candidate.md)

## Final release controls

- [ ] Release notes exist at `docs/releases/<version>.md` and describe user-visible
  changes.
- [ ] Developer ID certificate and Apple notarization credentials are configured,
  or the release is `ISLA_ADHOC=1` and says so (see below).
- [ ] The update key ("Isla Update Signing") and the pinned certificate
  (`~/Isla Code Signing.p12`) are the same ones the last release used, and both
  are backed up in the password manager. A new key or certificate makes every
  installed copy fall back to the download page.
- [ ] The release carries `Isla-<version>.dmg.sig` beside the image.
- [ ] A copy of the previous release, on a real Mac, took this one through
  Check for Updates → Update Now, kept its Accessibility permission, and
  relaunched as the new version. Added 2026-10-20.
- [ ] The release commit is clean, reviewed, pushed, and has no existing version
  tag.
- [ ] The stapled DMG passes final Gatekeeper validation on a second clean Mac.
- [ ] `Scripts/release.sh` produced the tag, checksum, and GitHub release URL.
- [ ] An ad-hoc release (`ISLA_ADHOC=1`) says in its release notes, under
  Install, that macOS asks again for the permissions Isla had — Desktop,
  Documents, Downloads, Automation for Music and Spotify — because an ad-hoc
  update is a new binary to macOS and its grants do not carry over. Suggested
  line: "macOS treats each Isla update as a new app until Isla is signed with
  a Developer ID, so it asks once more for the folders and players Isla had
  access to." Added 2026-10-11 (J-002, ms/MS-20).

Verdict: **NO-GO** — UI, clean-account permission, synthetic-display,
performance, Developer ID, and notarization gates remain open.

Signed: `Codex, 2026-08-18`
