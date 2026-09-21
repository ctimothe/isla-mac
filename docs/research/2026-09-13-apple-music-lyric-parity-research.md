# Apple Music lyric parity research (2026-09-13)

## Findings

### 1. Apple public API surface

- MusicKit's public Song model exposes hasLyrics: Bool, only a presence flag: [Song.hasLyrics](https://developer.apple.com/documentation/musickit/song/haslyrics). The documented Song properties include metadata, artwork, play parameters, preview assets, and URL, but no lyric text, line timestamps, word timestamps, or lyric download endpoint: [Song](https://developer.apple.com/documentation/musickit/song).
- Apple describes MusicKit as enabling catalog search, playback, library actions, playlists, and recommendations—not lyric retrieval: [MusicKit overview](https://developer.apple.com/musickit/), [Apple Music API](https://developer.apple.com/documentation/applemusicapi).
- MusicKit playback exposes current playbackTime, enough to drive an independently sourced timing track, but it does not expose Apple's lyric timing data: [MusicPlayer](https://developer.apple.com/documentation/musickit/musicplayer).
- Conclusion: a third-party macOS app can identify a song, ask whether lyrics exist, and read playback position; it cannot obtain Apple Music lyric text or synchronized timings through documented public APIs. This is a documentation-surface conclusion; Apple could add APIs later.

### 2. Restrictions

- Apple Media Services terms grant personal, noncommercial use and state that delivery does not transfer commercial/promotional rights: [Apple Media Services Terms](https://www.apple.com/legal/internet-services/itunes/gb/terms.html).
- The terms describe Services and Content—including editorial content, clips, and software—as proprietary material owned by Apple, licensors, or providers; they prohibit use outside the agreement and reproduction except as expressly permitted, plus unauthorized modifying, sharing, distribution, or exploitation: [Intellectual Property / Content restrictions](https://www.apple.com/legal/internet-services/itunes/gb/terms.html).
- iCloud Music Library terms permit use only for lawfully acquired content and do not grant a third-party app a right to export or republish catalogue lyrics: [iCloud Music Library terms](https://www.apple.com/legal/internet-services/itunes/gb/terms.html).
- Do not scrape Apple Music pages, inspect private client traffic, extract cached lyric payloads, or ship a copied Apple lyric database. Exact legal outcomes depend on jurisdiction, licenses, and implementation; not legal advice.

### 3. Viable capabilities

- Licensed provider: require contract coverage for display, synchronization, caching, territory, attribution, and macOS distribution. Store provider IDs/ISRC mappings and enforce license responses.
- User-supplied timed files: support local .lrc or another user-owned format, with explicit import and per-file storage; do not bundle a catalogue.
- Community/open API: LRCLIB publicly documents plain and synchronized lyrics and publishes its server source: [LRCLIB](https://www.lrclib.net/), [source repository](https://github.com/tranxuanthang/lrclib), [API client docs](https://lrclib.js.org/classes/Client.html). Verify current terms, provenance, takedown policy, rate limits, and commercial caching/redistribution rights; free access is not itself a copyright license.
- Kugou has an official developer portal advertising copyright cooperation, but it does not document a general lyric API/license: [Kugou Open Platform](https://open.kugou.com/docs). QQ/Kugou endpoint repositories are predominantly unofficial reverse engineering and are unsafe absent direct written permission.
- On-device alignment: for audio the app is licensed to play (especially local files), derive timestamps locally or let users correct them. Keep generated timings tied to the local asset; alignment does not authorize reproducing or redistributing Apple's lyric text.

## Recommended boundary for Isla

Use MusicKit only for catalog identity, authorization/playback, and playbackTime; use provider adapters for licensed/community lyrics; support local .lrc import; cache only where licensed; retain source/attribution/takedown metadata; and treat no lyrics as normal because hasLyrics is only a Boolean and availability varies.

## Uncertainty

Apple docs do not state that hasLyrics == true guarantees text/timing access to an app. Lyric rights may belong to publishers/licensors rather than Apple. Obtain counsel/provider licenses before commercial release, especially for caching, user sharing, and community API data.
