# Offline local lyrics release validation

Date: 2026-09-14

## Automated evidence

- `bash Scripts/validate-lrc.sh Tests/Fixtures/local-word-timed.lrc` accepted
  the bundled non-copyrighted fixture and reported `granularity: word`.
- `bash Scripts/test-localizations.sh` passed for English and Russian.
- `../../scripts/check` passed all four repository gates.
- `swift test --filter OfflineLyricsIsolationTests` passed: lyric sources have
  no network client, broker, or legacy provider reference.
- `bash Scripts/bundle.sh release` completed and
  `codesign --verify --deep --strict build/Isla.app` passed.
- The release build launched and presented the Now Playing control.

## Live sync probes

No timing report is recorded for Spotify. Spotify was running, but no enhanced
LRC fixture verified to belong to the current track was available. Running the
probe with the bundled sample would pause and seek a user track while producing
meaningless timing evidence, so it was intentionally not run.

Apple Music had no active track. Its probe is blocked until a user selects a
playing track and supplies that exact track's enhanced local LRC fixture.

Before release, run both probes separately with the same exact local fixture:

```bash
SYNC_PLAYER=spotify SYNC_LRC_FIXTURE=/absolute/path/exact-track.lrc bash Scripts/measure-sync.sh
SYNC_PLAYER=music SYNC_LRC_FIXTURE=/absolute/path/exact-track.lrc bash Scripts/measure-sync.sh
```

Keep each generated report only when its word-timing steady p95 is at most
`0.150s`. Then perform the remaining physical-notch, lock-card, folder-change,
import/export, ambiguity, invalid-file, VoiceOver, Reduce Motion, English, and
Russian checks against the bundled app.
