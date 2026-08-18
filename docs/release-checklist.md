# Dynamic Island release checklist

Release candidate: `________________`  
Commit: `________________`  
Tester/date: `________________`  
Mac/macOS: `________________`  
Artifact SHA-256: `________________`

Complete the commands and manual flows in [runbook.md](runbook.md). Add a short
result, evidence path, or issue link to every gate.

1. [ ] **Unit and service tests** — `swift test` passes. Evidence: `__________`
2. [ ] **Media-helper contract** — valid response, numeric commands,
   restart/fallback, and parent-child shutdown pass. Evidence: `__________`
3. [ ] **Release packaging** — clean release bundle, signature, package test,
   and versioned DMG pass. Evidence: `__________`
4. [ ] **UI coverage** — automated smoke coverage and Computer Use validation
   pass for every tab. Evidence: `__________`
5. [ ] **Permissions** — fresh-user Calendar and protected-file flows pass
   without launch-time prompting. Evidence: `__________`
6. [ ] **Displays** — physical-notch and synthetic-notch passes complete.
   Evidence: `__________`
7. [ ] **Localization** — English and Russian key checks plus visual review
   pass. Evidence: `__________`
8. [ ] **Recovery and lifecycle** — quit/relaunch, launch at login, corrupt
   snippets, unavailable helper, and missing file pass. Evidence: `__________`
9. [ ] **Performance** — three-run medians meet the pinned Cyclop 0.6.5 CPU,
   RSS, responsiveness, lifecycle, and bundle gates. Evidence: `__________`
10. [ ] **Original identity** — branding scan and visual review find no Cyclop
    icon, identifier, paths, screenshots, marketing copy, or unintended visible
    product strings. Evidence: `__________`
11. [ ] **License and attribution** — packaged `LICENSE`,
    `THIRD_PARTY_NOTICES.md`, and pinned provenance pass. Evidence: `__________`

## Final release controls

- [ ] Release notes exist at `docs/releases/<version>.md` and describe user-visible
  changes.
- [ ] Developer ID certificate and Apple notarization credentials are configured.
- [ ] The release commit is clean, reviewed, pushed, and has no existing version
  tag.
- [ ] The stapled DMG passes final Gatekeeper validation on a second clean Mac.
- [ ] `Scripts/release.sh` produced the tag, checksum, and GitHub release URL.

Verdict: **GO / NO-GO**  
Signed: `________________`
