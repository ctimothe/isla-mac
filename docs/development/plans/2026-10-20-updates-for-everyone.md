# Every merge to `main` reaches every Isla user — plan, 2026-10-20

Owner, 2026-10-20: Isla is an open-source app for everyone, and from today
"whatever we ship to main should instantly give the Update activity on the
island every time". 0.3.0 users are left as they are; they download once by
hand. Decisions taken the same day, so do not ask again:

1. The automatic check is **on by default and hourly**. This is a dated
   exception to the rule that anything leaving the Mac defaults to off. It
   sends one GitHub request an hour (24 a day, against GitHub's limit of 60 an
   hour per address). The switch in Settings › About still turns it off.
2. **CI cuts the release** on every merge to `main` that changes the app.
   No person runs `release.sh` for it any more.
3. A **Developer ID is coming**. The builds shipped before it must accept a
   Developer ID update without a manual reinstall.

## Tasks

**T1. The check is on, every hour** (`UpdateCheck`, `SettingsTable`).
`automaticEnabled` reads an absent key as on; the table's default is `.on`.
`automaticInterval` is one hour with a ten-minute tolerance, and the first
check still waits 20 s after launch. A finished check already raises the
island's update offer (`NotchController.considerUpdateOffer`), so a new
release is on the island within an hour of being published.
Tests: `UpdateCheckTests` (default on, interval), `SettingsTableTests`.
Docs: the README privacy table, the `checklist.md` record, and the CLAUDE.md
hard constraint, which gains this as its one named exception.

**T2. The bridge to a Developer ID** (`BundleUpdateValidator`). A running app
signed with the pinned self-signed certificate also accepts an update that
satisfies the Developer ID Application requirement for `com.ctimothe.isla`:
anchor apple generic, the Developer ID CA's marker on the intermediate, and
the Developer ID Application marker on the leaf. Any team qualifies, because
these builds ship before the Team ID exists. The Ed25519 signature is checked
first and is the gate. The requirement only keeps TCC's identity and refuses
a copy signed by someone outside Apple's program. An ad-hoc running app is
unchanged (it accepts any valid signature). A running Developer ID app is held
to its own requirement, and that requirement includes its team.
Tests: `UpdateValidatorTests`, through the requirement-text seam.

**T3. The release job** (`.github/workflows/release.yml`,
`Scripts/next-release.sh`).
- **Trigger.** `workflow_run` of "Build and verify" on `main`, only when it
  concluded `success` and was a `push`. It releases the run's `head_sha` only
  if that is still the tip of `main`; otherwise a newer run will release it.
- **Isolation.** It runs in the `release` environment, so the secrets are
  usable only from `main`. Its concurrency group is `release` with no
  cancelling, because a run cut off between the tag and the upload strands
  the tag.
- **Version.** `next-release.sh` decides whether there is anything to release
  and what to call it. The answer is nothing when no file under `Sources/`,
  `Resources/`, `Package.swift`, `Package.resolved`, `Scripts/bundle.sh` or
  `Scripts/dmg.sh` changed since the newest tag.
  - VERSION is the next patch after the newest tag, unless `Scripts/version`
    already names an untagged, higher one, which is how a person picks 0.4.0.
  - BUILD is the greater of `Scripts/version`'s and the newest tag's plus one.
- **Notes.** If `docs/releases/<version>.md` is missing, it is written from
  the `feat`/`fix`/`perf` subjects since the tag: "What's new" first, since
  the island's summary reads the first prose line, then Install, with the
  `xattr` step while the build is ad-hoc.
- **Commit and release.** It commits `chore: release <version>` to `main` as
  the owner's identity. A push from `GITHUB_TOKEN` starts no workflow, so it
  cannot loop. It pushes, then runs `ISLA_ADHOC=1 bash Scripts/release.sh`, or
  the Developer ID path once its secrets exist. `release.sh` already gates,
  signs, uploads the image and `.sig`, and rolls back the tag on failure.
- **Signing.** A throwaway keychain holds the pinned `.p12` and the update key
  ("Isla Update Signing" / `ed25519`, created with `-A`), and is deleted at
  the end.
- **Secrets.** These are set by the owner, never by an agent:
  `ISLA_SIGNING_P12_BASE64`, `ISLA_SIGNING_P12_PASSWORD` and
  `ISLA_UPDATE_SIGNING_KEY`. With a Developer ID:
  `DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD`,
  `DEVELOPER_ID_APPLICATION`, `APPLE_ID`, `APPLE_TEAM_ID` and
  `APPLE_APP_SPECIFIC_PASSWORD`. `Scripts/setup-release-secrets.sh` reads the
  keychain and the `.p12` and sends them with `gh secret set --env release`;
  the owner runs it.

**T4. Docs.** Runbook §8 says CI releases, and how to pick a minor version.
The release checklist and CLAUDE.md "After each change" follow.

**T5. Pin the team (owed, as soon as the Team ID exists).** The bridge accepts
any team (review, 2026-10-20), so the update key is the only secret between an
attacker and every self-signed copy. Ship one self-signed release whose
`developerIDRequirement` adds `certificate leaf[subject.OU] = "<TEAM>"`, then
the first Developer ID release.

## Verification
- `./scripts/check` passes. `next-release.sh` has a shell test against a
  scratch repository (`Scripts/test-next-release.sh`), which joins the gate.
- After the merge: the first CI release appears, and the owner's copy of the
  previous public build shows the island offer and installs it. That is
  release-checklist control "Update Now from the previous release".
- Codex review and an Opus review of T2 and T3, since both are update trust
  and a deploy gate.
