<!-- Produced 2026-08-21 by a 7-agent research workflow: live teardowns of
     Alcove, NotchNook, boring.notch, MewNotch, Sleeve 2, Tuneful, NepTunes,
     Apple's Dynamic Island / Live Activities grammar, and this codebase.
     80 sources consulted; staleness flags are inline. -->

# Music-First Battle Plan — DynamicIslandKit vs. the Field

*(Grounded in the 2026-08-21 teardowns. Stale/conflicting source data is flagged inline.)*

---

## 1. Where we already win

Features **no competitor ships at all**, verified against every teardown:

- **Word-synced karaoke lyrics.** Our `KaraokeLine` mask-sweep with real per-word timing is unique in the entire field. Alcove: zero lyrics mentions across the complete 1.0→1.7.9 changelog, confirmed by Droppy's matrix. NotchNook: no lyrics anywhere. boring.notch has only *line-level* beta lyrics (LRCLIB/AppleScript) — and its own tracker begs for exactly what we have (#1400 "word-level karaoke Enhanced-LRC/YRC fill in the closed notch"). Sleeve, Tuneful, NepTunes: all explicitly no-lyrics. This is the moat.
- **Three-tier lyrics sourcing with a disciplined cache.** amll-ttml-db → Kugou KRC → LRCLIB with 404-only miss caching, LRU at 500, versioned format, user-visible clear and kill-switch. boring.notch has one fallback (LRCLIB); nobody else has any.
- **Millisecond-class position truth.** Precision Spotify sync (2s AppleScript clock correction with RTT/2 compensation, monotonic anchoring) plus the `com.spotify.client.PlaybackStateChanged` distributed-notification anchor (10–30ms). Everyone else rides MediaRemote's 0.9–1.1s staleness — Alcove's changelog shows *three* rounds of "seeker accuracy" churn (v1.6.11, 1.7.3, 1.7.7) fighting the same physics we solved.
- **A UI that never lies.** Seek-intent gating (no post-seek yank-back), the PlaybackIntent reconciliation model (no icon repaint-backwards), the 10s foreign-session hold (paused browser video can't steal the island), capability-aware dimmed skip buttons. Alcove only got "skips to be accurate for all media" in 1.7.9; boring.notch's tracker is full of source-stealing and stale-artwork issues (#1289, #1404).
- **Karaoke + heart + seek on the lock screen.** Alcove's lock-screen player is its acknowledged category differentiator ("one of the few notch apps to support the lock screen" — Seam), but ours adds the karaoke line, a PKCE-OAuth Liked Songs heart (no developer-credential friction — Tuneful and Sleeve both make users paste their own Spotify API credentials), and elapsed/remaining seek. Note: Alcove *does* show loved/like state (v1.7.3/1.7.7), so the heart itself is rare, not unique — its lock-screen placement and zero-setup OAuth are.
- **Render-server equalizer with mid-beat pause freeze** and full Reduce Motion coverage across the music surface. NotchNook merely stops its spectrograph; nobody documents accessibility-grade motion fallbacks. Apple's grammar makes these mandatory, and we're the only ones already compliant.
- **Resilience by design**: MediaRemote with an automatic AppleScript fallback (`switchToScriptingFallback`). boring.notch and MewNotch depend on the same mediaremote-adapter with no fallback ("Till Apple breaks it"); Alcove discloses the private-API risk with no stated mitigation.

---

## 2. Table stakes we lack

Every one of these exists in at least one paid competitor and is absent from our build (per our own weaknesses teardown):

| Gap | Bar-setter | Effort |
|---|---|---|
| Shuffle + repeat (incl. repeat-one) | Alcove (v1.2.0, repeat-one AM v1.7.3, Spotify v1.7.7) | **S** — AppleScript for AM/Spotify, MediaRemote commands elsewhere |
| Collapsed-pill direct transport (play/pause without expanding; our paused badge is decorative) | NotchNook (play/pause from collapsed activity) | **S** |
| Swipe gestures on the notch (skip, dismiss) | Alcove (swipe-to-skip v1.2.2) + NotchNook (track swiping) | **M** — needs the 10pt-hysteresis gesture layer from §4 |
| Music-app volume control | Alcove (per-output, mute, dB) ; boring.notch v2.7 (in-widget volume) | **S–M** |
| Playback speed (podcasts) | Alcove (v1.3.6, Spotify podcasts v1.7.9) | **S–M** |
| Configurable hover-to-expand delay | Alcove; MewNotch (0.1–2.0s) | **S** |
| Notchless-Mac fallback (pill/handle on external displays) | Category-wide: Alcove forced-notch v1.7.0, NotchNook handle, MewNotch per-display | **M** |
| Explicit / Lossless / Atmos badges | Alcove (v1.6.15–1.7.7) | **M** — metadata plumbing |
| Last.fm scrobbling | Sleeve/Tuneful/NepTunes (the non-notch trio's shared table stake; no notch app has it — cheap flank) | **M** |
| Empty state with an affordance (ours is a bare "Nothing is playing") | Everyone hides or offers a launch action | **S** |
| Lyric-mismatch recovery (bad Kugou/LRCLIB match is cached until full cache clear) | Nobody — but it's *our* feature's Achilles heel | **S** |

Do the S items in one sweep before any move below; they're the objections a reviewer comparing us to Alcove will raise first.

---

## 3. The five moves that beat them (ranked)

### Move 1 — The Lyrics Stage: full scrolling word-synced karaoke
**What.** Grow the single `KaraokeLine` into a scrolling multi-line lyrics view in the expanded pane: current line word-sweeping, next line visible and pre-dimmed, tap-a-line-to-seek, user lyric-offset nudge (±250ms steps), and a "wrong lyrics? re-search" action that busts the cached match.
**Why nobody matches it.** Word-sync requires exactly the stack only we have: precision position (±50ms via Spotify anchors) *plus* per-word timing data (amll/KRC). boring.notch's line-level beta can't sweep words; its tracker's top lyric asks (#1105, #1384, #1400) are our shipped substrate. Alcove would need to build lyrics from zero — and its roadmap is publicly stuck on a tray promised since Sep 2025.
**Builds on.** `LyricsStore.fetch` three-tier sourcing, `WordSyncedLyrics`, the `positionSettled` 150ms gate, the 250ms precision lyric lead, the lrc2 cache (add per-track invalidation — fixes our stated weakness).
**Design treatment.** iOS 26's lock-screen grammar: artwork tints the surrounding interface, controls float translucent over it. Render lyrics on the Clear Liquid Glass variant over blurred artwork with the mandated ~35% dimming layer; lines *materialize* in/out by modulating blur ("elements never fade… gradually modulating the light bending"), current line at medium weight or heavier per island typography rules; the whole stage is "an enlarged version of the compact presentation" — the compact karaoke caption must travel into position, not be replaced.

### Move 2 — Kill Alcove's crown jewel: real audio-reactive, artwork-tinted waveform
**What.** A Core Audio process-tap-driven waveform replacing our decorative Core Animation equalizer in the compact pill and the decorative sine waveform on the lock card, budgeted at ≤1% CPU.
**Why.** Alcove's live waveform ("0–1% Total CPU", "truly 1:1 with iOS", v1.7.3) is its single most-marketed music feature and the thing that made Seam's July table look stale. NotchNook's spectrograph and boring.notch's Metal visualizer are unmeasured and battery-suspect (NotchNook's defining complaint is drain). Matching Alcove's tap *plus* HIG-correct artwork tinting ("the trailing waveform is live and tinted to match the dominant colors of the album artwork") beats it, because Alcove tints sliders from artwork but not the waveform per its changelog.
**Builds on.** The CA-layer equalizer architecture (render-server, zero SwiftUI timeline cost) keeps its role as the Reduce-Motion/fallback path and the mid-beat freeze behavior; `ArtworkPalette`'s vivid-gated accent supplies the tint; the compact pill's +104pt wing layout already reserves the trailing slot per HIG compact grammar (artwork leading, waveform trailing, "two elements designed to read as one piece of information").
**Effort note.** This is the riskiest move (audio tap permissioning, per-app tap routing) — timebox it; the decorative equalizer is an acceptable shipping state, an eternally-promised waveform is not (see Alcove's tray).

### Move 3 — One material system: bring the lock card's glass into the notch
**What.** Port the lock card's ambience stack (artwork-dominant gradient, specular sheen, gradient-stroke edge, palette-tinted accents) into the expanded MediaPane and compact pill: tinted equalizer/waveform, artwork-accent karaoke and scrubber fill, Liked Songs heart in the pane (not just lock screen), low-opacity ambience behind the pane content on the opaque black ground.
**Why.** Our stated weakness is that "the in-notch experience is visibly plainer than the locked one." Alcove's premium read comes from exactly this coherence (adaptive min-contrast slider colors v1.7.5–1.7.8, gradient progress, wallpaper-sampled outlines). We beat it by tinting from *artwork* (the music's identity) rather than wallpaper — which is Apple's own rule: island backgrounds stay opaque black; identity is expressed only through bold content color, the tinted key line, and heavy typography.
**Builds on.** `ArtworkPalette` (8×8 downsample, isVivid gate, off-main-actor), the lock card's full glass recipe in `LockScreenCard.swift`, the Theme token stack (extend it with a `tint` token derived per-track). Mostly composition, not new engineering: **S–M** effort for the biggest visible delta.

### Move 4 — True-time everywhere: extend the precision engine beyond Spotify
**What.** Apple Music gets the same 2s AppleScript clock-correction loop (player position is scriptable) with the same RTT compensation; browsers/others get honest staleness handling (wider lyric lead, softer scrubber snapping). Then *market it*: "the only Mac island whose scrubber and lyrics never lie."
**Why.** Our weaknesses teardown says precision is Spotify-only while "Apple Music and browsers ride MediaRemote's 0.9–1.1s staleness." No competitor even frames position accuracy as a feature — Alcove patches seeker symptoms release after release; boring.notch has open slider bugs (#736). Caveat: Apple Music AppleScript is fragile on macOS 26 Tahoe (boring.notch #779, wontfix, non-library tracks) — gate the loop per-track-type and fall back gracefully, which our `switchToScriptingFallback` architecture already anticipates.
**Builds on.** The entire position-clock apparatus: anchor + 4Hz open-only ticker, asymmetric adoption rules, stale-reading rejection, `pendingSeek`. This is generalization, not invention: **M**.

### Move 5 — The AirPlay slot: output routing and volume in the expanded island
**What.** An output-device button in the expanded pane (public `AVRoutePickerView` / CoreAudio default-device switching) plus a per-output volume slider with mute.
**Why.** Apple's own expanded media widget includes "an AirPlay output-routing button" — it is part of the canonical grammar, and **no notch app has it**: the Alcove teardown is explicit ("No documented output-device SWITCHER — it displays and controls the active output, it doesn't route audio"). Only Tuneful (non-notch, menu bar) does switching. Shipping the HIG-complete expanded widget makes us the only island that is actually *Apple's* island. Bundles the volume table-stake from §2.
**Builds on.** `NotchButtonStyle` control row in `MediaPane`, the per-player capability model (dim routing when the route isn't controllable — same "dim, don't lie" doctrine as our skip buttons). **M**.

---

## 4. Design-language upgrade — reading more premium than Alcove

Alcove's signature is iPhone-parity restraint; we beat it by executing Apple's *motion* grammar more literally than they do. Concrete changes:

1. **Morph, never swap.** HIG: "the expanded view is explicitly an enlarged version of the compact presentation… elements must move to their new homes." The compact 22pt artwork must travel (matchedGeometryEffect idiom) into the 118pt pane artwork, the compact equalizer into the scrubber region, frame and corner radius interpolating **together** with continuous-curvature corners throughout the flight. Alcove repeatedly patches "notch radius logic" and "corner-radius frame-skips" — a single-source-of-truth radius interpolation in `NotchShape` (collapsed 6/9 → open 12/22, animated as one animatable pair, targeting the 44pt-equivalent island radius at full scale) is the tell that separates "drawn" from "alive."
2. **Spring policy per WWDC18: damping + response, never duration; 100% damping by default, overshoot only to reward gesture momentum.** Keep hover-open at response 0.27 but raise damping to ~0.95 (hover has no momentum to reward); reserve the current 0.82 damping for gesture-initiated opens, projecting drag velocity into the spring's initial velocity. All springs interruptible and redirectable — a mid-flight close must retarget, not restart.
3. **Gesture physics for the swipe layer (Move-adjacent, §2).** ~10pt hysteresis before committing, one-to-one tracking during the drag, momentum projection to pick the endpoint, rubber-banding at the pill's edges. Alcove has HUD overshoot rubber-banding; putting it on the *music* surface (over-scrub past 0:00/end compresses and snaps back) out-details them.
4. **Materialize via lensing, not fades.** Replace the flat 0.16s content crossfades with the Liquid Glass entrance: blur 8→0pt + scale 0.96→1 + opacity, 0.20s easeOut in / 0.12s easeIn out (keeping our proven asymmetric pane-swap timings, adding the blur modulation). Elements "materialize in and out by gradually modulating the light bending."
5. **Artwork-sampled tinted key line.** HIG: in dark contexts a hairline ring separates the island, and it "must match your content's color." Ours samples the `ArtworkPalette` accent at hairline 0.10-equivalent opacity. Alcove samples the *wallpaper* (v1.7.5–1.7.6); artwork-sampling is both more correct to the grammar and more musical.
6. **Hover presence and depth.** On hover the pill scales ~1.02 with a deepening shadow ("larger glass simulates a physically thicker material — deeper shadows"); press compresses to 0.98 with an illumination-from-within glow spreading from the cursor. NotchNook's "lightly pulse outward with a drop shadow" is the category benchmark here — this matches and grounds it in the material spec.
7. **Concentricity audit.** Every inset element takes radius = parent radius − padding; controls become capsules (half-height); run the HIG blur test ("blur the object and check the resultant shape is concentric with the outer border") on the pane, scrubber, and lock card.
8. **Sneak peek = alerting grammar.** Spring to the widened state, settle back — and trim our 2.2s to Apple's **2.0s** custom-animation cap.
9. **Keep our accessibility discipline as a hard gate** (Reduce Motion → fades, Reduce Transparency fallbacks) — Liquid Glass's public legibility backlash makes these table stakes Apple itself was forced to honor with the transparency slider.

---

## 5. What NOT to build

- **File shelf / tray / AirDrop / clipboard.** NotchNook's core, boring.notch's second tab — and Alcove's tray has been "coming" since Sep 2025 and is still unshipped at 1.7.9. Even the design leader can't land it without derailing. Not music; skip.
- **Widget grids** (calendar, timer, mirror, notes, to-do) and **lock-screen widget zoo** (battery/weather/calendar — Alcove's non-music lock differentiators). Our lock surface is the media card, full stop.
- **Mirrored system notifications.** boring.notch's top-reacted open issue (#592) — real demand, wrong app. It drags in permission sprawl and failure modes (Alcove pulled banner suppression "temporarily" in 1.7.9 because it needs a rework).
- **Per-app long-tail integrations** (Tidal, Plexamp, Amazon Music, QQ Music, companion-app bridges like Pear Desktop). boring.notch's maintainers resist these for good reason; Pear keeps breaking (#1457, #659). Universal MediaRemote + our AppleScript fallback covers the field.
- **HTML/CSS theming platform** (NepTunes Pro's direction). The island's ground is non-customizable opaque black in Apple's grammar; theming breaks the one thing that makes it read as native.
- **Full HUD replacement** (brightness etc.). Alcove's requires Accessibility permission and still fights native HUDs reappearing (#562, 46 comments). At most, a volume HUD as part of Move 5's volume work — brightness is off-mission.
- **Per-app EQ.** Nobody ships it, no tracker demands it.
- **Duo mode / multi-activity.** Alcove's v1.7.0 flagship, but Apple's own grammar calls two-activity handling crude (two minimal slots; HIG suggests one rotating activity). For a music-first island there is no second activity class yet — defer until one exists.

**Source-quality flags carried into this plan:** Seam's "Alcove lacks a visualizer" is stale (waveform shipped 12 Jun 2026) — never cite it; Alcove pricing is $14.99 (site) not Droppy's $13.99; NotchNook is $25 (site) not Brow's $30; NotchNook battery magnitudes (10–15% CPU) come from competitor marketing and are unverified; boring.notch's dev branch (music grid, artwork fixes) is unreleased and could ship as v2.8 anytime; Alcove's 1.8 tray could reshape its scope story at any moment — but nothing on any competitor's visible roadmap touches lyrics, position truth, or output routing, which is exactly where Moves 1, 4, and 5 land.
