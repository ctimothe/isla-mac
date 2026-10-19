# The private update channel and the island's update alert

*Plan, 2026-10-19. Owner's request the same day: "any new changes … should all
be installed through Isla's own update live activity … we can't keep
reinstalling the app all the time." Owner's go-ahead: "build the private dev
update channel and the island's update alert, Tier 3 with reviews."*

Tier 3: it changes where the updater may take a build from, which is the
updater's trust surface. Branch `feat/dev-update-channel` from `main` 9f47c21.

## What exists

- **Update Now** (`UpdateCheck`, `UpdateInstaller`, `UpdateCollaborators`,
  Settings › About through `UpdatePresentation`/`UpdateCard`). It installs only
  what is signed with the owner's Ed25519 key (`IslaUpdatePublicKey` in
  Info.plist, `Resources/update-public-key.txt`), verified before the image is
  mounted; the staged copy must be `com.ctimothe.isla`, the advertised version,
  newer by dotted numbers, a greater build, intact, and — for a
  certificate-signed running copy — satisfy the running copy's designated
  requirement. The swap is one atomic exchange; the relaunch is a shell that
  waits for the old process and runs `/usr/bin/open`.
- It reads GitHub's `releases/latest`, or — only when launched with
  `DI_UPDATE_REHEARSAL=<folder>` — a `release.json` in that folder with
  `file://` assets confined to the folder (`UpdateCheck.isRehearsalFile`).
  The environment is read once at launch, so a rehearsal ends with the first
  relaunch.
- The checks run when someone presses Check for Updates, or daily when the
  opt-in automatic check is on. Nothing on the island says an update is there;
  the Settings gear wears a badge (`UpdateCheck.hasUpdate`).
- The island's update alert is spec §19.5 f, rank 9 in §19.1, planned as R9
  task 4 (`2026-10-17-activities-build-plan.md`), not built.
- Never proven on hardware: Update Now replacing the launched copy in
  `/Applications` (checklist §"Update Now", the rehearsal box is unticked).

## What changes

### A. The private channel

A **local feed**: a folder on this Mac that the updater reads exactly as a
rehearsal reads its folder — the same `release.json`, the same confinement of
`file://` assets to the folder, the same signature, validator, swap and
relaunch. Nothing about what may be installed is relaxed; only where the answer
comes from.

- **Turned on** by one setting, `updates.localFeed` (a string path) in Isla's
  own defaults, read once at launch like the rehearsal variable. The rehearsal
  variable still wins when both are set. With neither, GitHub, as today.
- **Accepted only if** the path is absolute, is a directory once links are
  resolved, is owned by the current user, and is writable by nobody else
  (mode & 022 == 0). Otherwise it is ignored, logged once, and the updater
  stays on GitHub. A process that can write this setting can already rewrite
  `/Applications/Isla.app`, which the user owns, so the setting grants nothing
  new; the folder rule keeps another account from feeding it.
- **Watched.** While on a local feed the app checks 3 s after launch and again
  whenever the folder changes (a `DispatchSource` on the folder, coalesced
  0.5 s), so a build published there reaches the island within a second or
  two. No network; the daily GitHub check does not run on a local feed.
- **Said so.** Settings › About's card says "Updates come from a folder on this
  Mac." under its title, as the rehearsal says it is a rehearsal.

### B. Publishing to it — `Scripts/publish-dev-update.sh`

Run after a change is committed and green, instead of `install.sh`. Never a
gate. It:

1. Finds the feed: `$ISLA_DEV_FEED`, else `<main checkout>/.dev-updates`
   (git-ignored), made 0700 if missing. `--enable` also writes
   `updates.localFeed` into Isla's defaults (once; the app reads it at launch).
2. Picks the version: `<Scripts/version VERSION>.<n>`, `n` one past the
   fourth part of whichever is later of the installed app and the feed's last
   release (on the same base), and a build one past the greater of their
   builds. A fourth part keeps every dev build older than the next real release
   (0.3.1 > 0.3.0.n) while each one is newer than the last.
3. Builds with `bundle.sh` (the existing version overrides), packs with
   `dmg.sh`, signs with `update-signing.swift sign` (the key in the login
   keychain; macOS may ask once to allow the read), verifies against the
   committed public key. *Amended 2026-10-19, after review:* the feed's own
   key, `sign --dev`, never the release key — see "After review" below.
4. Writes the image and signature into the feed, then `release.json` last
   (written beside and renamed in), so the watcher never reads half a file.
   Notes are the commit subjects since the last published commit (at most ten),
   newest first. Older images in the feed are removed, keeping the newest two.
5. Removes the build from `build/` and unregisters it from LaunchServices, as
   the rehearsal does: one copy of Isla on the Mac, in `/Applications`.

Leaving the channel: `defaults delete com.ctimothe.isla updates.localFeed`,
relaunch. A dev build's build number may then be above the next public
release's, which the validator would refuse; leaving is one `install.sh`.

### C. The island's update alert (§19.5 f, R9 task 4, built early)

- `IslandActivity.update(UpdateOffer)`, rank 9, an alert that queues. Its policy
  in `IslandAlertQueue` is the two exceptions §19.1 names: it outlives the
  one-second patience, and a higher alert that replaces it sends it back to
  wait.
- **When:** `UpdateCheck.lastAvailable` becomes a version not offered before
  (`updates.offeredVersion`), at the first idle moment — nothing open, no other
  alert, not locked, displays awake, not a quiet moment. Open on Hover does not
  open the panel over it.
- **Draws** §19.5 f: 335.4 × 158, radii 24 / 36, white 0.14 stroke,
  `arrow.down.circle.fill` in the blue gradient, "Isla %@ is ready", the
  release's first sentence, "Isla restarts when it is done.", Later and
  Install.
- **Later**, or 20 s with no answer, folds it and remembers the version; the
  gear keeps its badge. **Install** remembers the version and runs
  `UpdateInstaller.install` — the one Update Now runs.
- **After Install** (the spec is silent; proposed): the alert stays, untimed,
  and its line under the title follows the installer — "Downloading… 42%",
  "Verifying…", "Installing…", "Restarting…" — with no buttons, until Isla
  restarts. A failure shows the reason Settings would give, with Later and Try
  Again; "can't update itself from here" shows with Later and Settings (opens
  Settings, where the card offers the download page); "restart needed" shows
  with Quit Isla.
- **Opened over.** A surface opened while it shows takes it down; it comes back
  at the next idle moment, with a fresh 20 s if it had not been answered.
- **VoiceOver** hears "Isla %@ is ready" when it shows; the alert is one
  container with its buttons inside.
- Strings in `en` and `ru`.

## Tasks (test-first, one commit each)

1. **Feed resolution.** `UpdateFeed` (new, `Services/UpdateFeed.swift`):
   the folder from the rehearsal variable, else the setting, else nil; the
   ownership and mode rule; whether it is a rehearsal or the local feed. Tests:
   precedence, each refusal (relative, missing, a file, another owner through
   an injected owner function, group-writable, world-writable).
   `DebugTrail.updateRehearsal` stays the environment's reader; `UpdateCheck`,
   `UpdateEnvironment.live()` and `URLSessionUpdateDownloader` take the feed's
   folder instead.
2. **Watching.** `UpdateFeedWatcher` (a `DispatchSource` on the folder,
   coalesced) → `UpdateCheck.check()`; started from `AppDelegate` on a local
   feed, with the launch check. Tests: a write to `release.json` in a temporary
   folder fires once per burst; a stopped watcher fires nothing.
3. **Settings note.** `UpdatePresentation`'s rehearsal note becomes the source
   note: the rehearsal's text for the variable, the new line for the setting.
   `UpdatePresentationTests`. Strings en/ru.
4. **Alert model.** `UpdateOffer` (version, summary = first sentence of the
   notes), `UpdateOfferMemory` (offered version in defaults), the policy for
   `.update` in `IslandAlertQueue`, `IslandActivity` rank and kind, the click
   (nothing outside its buttons), `pointerCrossed` standing still over it.
   Tests in `IslandActivityTests` and a new `UpdateOfferTests`.
5. **Alert drawing and wiring.** `ExpandedAlertShape.update`,
   `UpdateAlertLayout`, the header view, `NotchViewModel.updateOffer`, body
   size, radii, hit rects; the controller presents it through `postAlert`,
   times it, folds it, re-queues it on open; Install, Later, Try Again,
   Settings and Quit routed to the installer and the app. Tests: the layout
   against §19.5 f, the controller's offer → show → Later/timeout → remembered
   path with a fake installer, a surface opening over it and it returning.
6. **The publish script** and `.gitignore`, with `--dry-run` printing the
   version, build and notes it would publish, without building.
7. **Docs.** Spec §19.5 f and §19.1 dated amendments; checklist §"Update Now"
   (the local feed), §R9 (task 4 built early), hardware checks DU-H1…H5;
   runbook §7a; CLAUDE.md "After each change" and Commands; this plan's
   outcome.
8. **Gate and reviews.** `./scripts/check`; Codex review of the branch; Opus
   review (high) of the trust surface and the alert. Fixes test-first.
9. **Bootstrap and first update.** Merge to `main` (PR, CI). The last
   `install.sh`: the build that knows the channel. `--enable`, one relaunch,
   then `publish-dev-update.sh` — the owner presses Install on the island. That
   first update is the hardware proof of the swap and relaunch in
   `/Applications`; if macOS refuses it (App Management), say so and fall back
   to `install.sh` until it is solved.

## Hardware checks owed

- DU-H1: a published build shows the alert within about two seconds; Install
  downloads and restarts as the new version; `hdiutil info` shows nothing
  mounted and there is no `.Isla-update-*` beside the app.
- DU-H2: Accessibility (the Volume and Brightness pop-up), Spotify and the
  Settings choices survive it.
- DU-H3: Later folds it, the gear keeps its badge, and the same version is not
  offered again; a newer one is.
- DU-H4: open the panel while it shows; it returns when the panel closes.
- DU-H5: what macOS said about App Management on the first update.

## Outcome (2026-10-19)

Built on `feat/dev-update-channel`, test-first where the tests could come
first, one commit per task:

- `41c2ed2` — tasks 1 and 3. The feed resolution became `UpdateSource`
  (`Services/UpdateSource.swift`: `.github`, `.rehearsal`, `.localFeed`)
  rather than the planned `UpdateFeed`, because the check, the downloader and
  the installer environment all needed one value saying where releases come
  from, not only a folder. Settings' note became `sourceNote`.
  `UpdateSourceTests`.
- `7d1caf2` — task 2. `UpdateFeedWatcher`, the launch check, and
  `UpdateCheck.checksAgainWhenDone` so a publish that lands during a check of
  the folder is not lost. `UpdateFeedWatcherTests`.
- `ad9faa4` — tasks 4 and 5. `UpdateOffer`, `UpdateOfferMemory`,
  `UpdateAlertStage`, `IslandActivity.update`, the queue policy,
  `UpdateAlertLayout`, `UpdateAlertView` and the controller's
  `considerUpdateOffer`. `UpdateOfferTests`; four mutations of its rules were
  each caught.
- Task 6, `Scripts/publish-dev-update.sh` and `.gitignore`. It records
  `isla_build` and `isla_commit` in `release.json` (Isla's decoder ignores
  them) so the next publish counts from them.
- Task 7, these docs: spec §19.1 and §19.5 f amended, checklist §"Update Now"
  and DU-H1…H5, runbook §7a, CLAUDE.md "After each change".

Decided while building, beyond the plan: an offer the island cannot show yet
under a still pointer, over a quiet moment or a dark display is delayed, not
dropped (§19.5 f amendment); an older version counts as answered with a newer
one; and the stages after Install are untimed.

### After review (2026-10-19)

An Opus review of the branch found one blocker and several should-fix items,
each fixed test-first in its own commit:

- **Blocker, `b2b8a71`.** The script named the commit's page as the
  release's `html_url`; `UpdateCheck.isTrustedReleasePage` (G-027) refuses
  anything off Isla's GitHub releases, so the feed never offered a build. The
  writer is now `Scripts/dev-feed-release.py` (page `releases/tag/v<version>`),
  and `testTheReleaseThePublishScriptWritesIsOffered` runs it through the check.
- **`798dbaf`.** With the lock card off nothing marks the island locked, and
  an offer shown under the shield folded unseen and counted as answered. The
  timing now answers `atUnlock`, and the unlock asks again.
- **`0db85bf`, beyond the plan.** Dev builds are signed with a key pair of
  their own — "Isla Dev Update Signing" in the login keychain,
  `Resources/update-dev-public-key.txt`, `IslaDevUpdatePublicKey` in every
  build — not the release key. `UpdateSignature.trustedKey` gives the feed
  that key and nothing else; GitHub and a rehearsal keep the release key. Made
  on the owner's Mac on 2026-10-19; losing it costs one `install.sh` after a
  new pair.
- **`95e45a5`, `01a7fcf`.** The feed folder is judged again before every read
  (`UpdateSource.stillHolds`), by the check and by Update Now's own download,
  and every folder above it must be root's or the user's and writable by
  others only when sticky.
- **`a2befa3`.** A feed folder removed or renamed is watched again
  (`UpdateFeedWatcher` reopens the path, 1 s doubling to 30 s).
- **`e8af354`.** The script makes the feed with a `.isla-dev-feed` marker,
  refuses a folder that already holds other files, and prunes only four-part
  dev images.
- **`1c79dec`.** An offer that waited behind the pop-up or an open panel is
  asked again before it shows, so an overtaken release never flashes back; the
  download line names the release actually downloading; VoiceOver reads the
  title once; the controller hears installer steps, not progress ticks.

Not changed: the island's press highlight over the alert, which the review
asked to drop — it is the hover's colour, which the alert under the pointer
already shows, so there is nothing to see.

### Second round (2026-10-19)

Codex reviewed the whole branch and an Opus reviewer tried to refute the fixes
above; it confirmed the blocker, the dev key, the folder re-checks, the script
marker and the nits, and found the rest each closed for its case but leaving a
smaller path:

- **`f7b2025` (Codex P1).** A checkout that does not contain the feed's last
  published commit — another worktree's branch — was published over it, and
  installing it took those changes out of the running app. The script now
  refuses unless that commit is an ancestor of HEAD; `--replace` publishes over
  it on purpose. The prune can no longer fail a finished publish under
  `pipefail`.
- **`66b98ab`.** Behind the screen saver inside its password grace, or with
  another user switched in, the Mac is not locked but nobody sees the island;
  the offer now waits through both, as through a lock.
- **`39ef761`.** While the feed is gone the watcher watches the folder above
  it instead of retrying every 30 s all night; the timer remains only as a net,
  at up to five minutes.
- **`ea2e49d`.** A public release leaves `IslaDevUpdatePublicKey` out
  (`release.sh` sets `ISLA_OMIT_DEV_UPDATE_KEY=1`); `test-package.sh` checks
  both ways.
- **`8a5b970`.** An access-control entry that lets anyone else add to or
  remove from the feed, or a folder above it, counts as a write bit.

A final Codex pass over the finished branch found two more, fixed the same way:

- **`0f4fe7b`.** With one build installing and a newer one published, a
  pop-up taking the alert's place brought it back as the newer build over the
  older one's progress. While an install runs the island now owes the release
  being installed (`owedRelease`).
- **`a56fb5b`.** The script refused feed paths with a space in them; the
  writer percent-encodes its file URLs instead.

Left as is: a check that fails while the feed folder is briefly missing keeps
`lastAvailable` (`UpdateCheck.apply` changes it only on an answer), so a shown
offer is not withdrawn by it.
