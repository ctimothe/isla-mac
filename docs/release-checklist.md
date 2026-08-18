# Dynamic Island release checklist

- Release candidate: `0.6.5 local RC`
- Measured implementation commit: `2a454aa154ae505e603073f65244427fcb711a88`
- Tester/date: `Codex / 2026-08-18`
- Mac/macOS: `Mac16,8 / macOS 26.5.2 (25F84)`
- Artifact SHA-256: `a70ddc5d93e8c4d1c81675ad129e24c88c6cdb5eb2e76caff89987a2131e8594`

Complete the commands and manual flows in [runbook.md](runbook.md). Add a short
result, evidence path, or issue link to every gate.

1. [x] **Unit and service tests** — 29 tests pass. Evidence:
   [release-candidate report](verification/2026-08-18-release-candidate.md)
2. [x] **Media-helper contract** — live NDJSON response and shutdown pass;
   numeric commands and restart/fallback pass unit tests. Evidence:
   [release-candidate report](verification/2026-08-18-release-candidate.md)
3. [x] **Release packaging** — release bundle, ad-hoc signature, package test,
   and versioned local DMG pass. Evidence:
   [release-candidate report](verification/2026-08-18-release-candidate.md)
4. [ ] **UI coverage** — automated smoke coverage and Computer Use validation
   pass for every tab. Blocked: Computer Use returned `cgWindowNotFound` for
   the borderless panel after three isolated discovery attempts. Evidence:
   [release-candidate report](verification/2026-08-18-release-candidate.md)
5. [ ] **Permissions** — fresh-user Calendar and protected-file flows pass
   without launch-time prompting. Unit seam passes; clean-account manual flow
   is not run. Evidence: [release-candidate report](verification/2026-08-18-release-candidate.md)
6. [ ] **Displays** — physical-notch and synthetic-notch passes complete.
   Physical notch detected, but UI workflow not completed; no synthetic display
   is connected. Evidence: [release-candidate report](verification/2026-08-18-release-candidate.md)
7. [ ] **Localization** — English and Russian key checks plus visual review
   key parity passes; visual review is blocked with UI coverage. Evidence:
   [release-candidate report](verification/2026-08-18-release-candidate.md)
8. [ ] **Recovery and lifecycle** — quit/relaunch, launch at login, corrupt
   snippets, unavailable helper, and missing file pass. Automated persistence
   and helper lifecycle pass; remaining manual scenarios are not run. Evidence:
   [release-candidate report](verification/2026-08-18-release-candidate.md)
9. [ ] **Performance** — three-run medians meet the pinned Cyclop 0.6.5 CPU,
   RSS, responsiveness, lifecycle, and bundle gates. Blocked by the strict CPU
   and helper-RSS thresholds. Evidence: [performance report](performance/2026-08-18-cyclop-0.6.5-baseline.md)
10. [x] **Original identity** — branding scan and generated-icon visual review
    find no Cyclop
    icon, identifier, paths, screenshots, marketing copy, or unintended visible
    product strings. Evidence: [release-candidate report](verification/2026-08-18-release-candidate.md)
11. [x] **License and attribution** — packaged `LICENSE`,
    `THIRD_PARTY_NOTICES.md`, and pinned provenance pass. Evidence:
    [release-candidate report](verification/2026-08-18-release-candidate.md)

## Final release controls

- [ ] Release notes exist at `docs/releases/<version>.md` and describe user-visible
  changes.
- [ ] Developer ID certificate and Apple notarization credentials are configured.
- [ ] The release commit is clean, reviewed, pushed, and has no existing version
  tag.
- [ ] The stapled DMG passes final Gatekeeper validation on a second clean Mac.
- [ ] `Scripts/release.sh` produced the tag, checksum, and GitHub release URL.

Verdict: **NO-GO** — UI, clean-account permission, synthetic-display,
performance, Developer ID, and notarization gates remain open.

Signed: `Codex, 2026-08-18`
