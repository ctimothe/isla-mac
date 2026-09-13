# Isla lyrics broker

Cloudflare Worker contract for licensed timed lyrics. It is intentionally
unconfigured until Isla has a signed provider agreement and sandbox
credentials.

The worker exposes POST /v1/installations to issue a signed anonymous
installation token, and POST /v1/lyrics/resolve to accept only player class,
title, artist, album, duration, optional Spotify or recording ID, locale,
and that token.

It rejects playback position, audio, library data, account data, user
identifiers, and unknown fields before a provider adapter sees a request.
Metrics contain only outcome, provider, error class, and latency. The worker
does not log or cache lyric text or track metadata.

Run npm ci followed by npm run verify for the independent gate.

Release needs a signed provider agreement covering macOS display, timing,
territory, attribution, device cache duration, rate limits, and takedowns;
a provider adapter with mocked integration tests; configured Cloudflare
rate-limit and Analytics Engine bindings; an INSTALLATION_TOKEN_SECRET Worker
secret; and production-environment approval for the manual release workflow.

Without every prerequisite, leave the adapter and bindings absent. The worker
fails closed; it never falls back to community sources.

Before a configured broker is released, run the client latency harness
`LyricsCoordinatorTests/testLatencyHarnessPublishesACachedTimelineBeforePanelOpenAndNetworkResultsUnderBudget`
and capture aggregate Worker resolve latency. The client gate is cache-ready
within 150ms before panel open and mocked-resolver p95 below 2s; the production
gate is aggregate first validated resolve p95 below 2s. Never add track fields
to obtain that measurement.
