# Favourites per player: which services let Isla's star work (2026-10-25)

Researched 2026-10-25. Question: the player's star adds the current song to the user's favourites or library in the app that is playing it. Today it works for Apple Music (AppleScript `favorited`) and Spotify (PKCE OAuth, `user-library-read` and `user-library-modify`). Which other services can offer the same, with no sign-in (local control) or with a sign-in in Settings, and for which should the star stay hidden?

Verdict words used below: **works locally**, **works with sign-in**, **no sanctioned way**.

What was checked on this Mac, read-only and without launching any app: `Info.plist` and bundled `.sdef` files of `/Applications/Spotify.app`, `/Applications/Яндекс Музыка.app`, `/System/Applications/Music.app` and `/System/Applications/Podcasts.app`. TIDAL, Deezer, SoundCloud, Amazon Music and YouTube Music are not installed here, so their desktop apps were not inspected. Web pages were read on 2026-10-25; a page that renders only in a browser (Deezer's developer pages, TIDAL's developer portal) could not be read, and the tables say when a claim therefore rests on a secondary source.

## Summary

| Service | Local way (no sign-in) | Official web API a third-party app may use | Verdict |
|---|---|---|---|
| Apple Music | AppleScript `favorited` of the current track (`pLov`, read and write) | MusicKit exists but is not needed | works locally |
| Spotify | `Spotify.sdef` has only a read-only `starred` property; no like command | `PUT/DELETE /v1/me/library`, `GET /v1/me/library/contains` (the `/me/tracks` paths are removed); PKCE; Development Mode capped at 5 users | works with sign-in |
| TIDAL | None documented | TIDAL API v2: authorization code + PKCE, `collection.read` / `collection.write` at the THIRD_PARTY tier; app registration open, non-commercial terms | works with sign-in (live test owed) |
| SoundCloud | None (web only, no desktop app) | `POST/DELETE /likes/tracks/{urn}`, `user_favorite` on the track, OAuth 2.1 + PKCE; registering an app now needs an Artist Pro subscription | works with sign-in, gated on the owner's account |
| Deezer | None found (app has hotkeys only) | OAuth with `manage_library` exists, but new app creation has been switched off since mid-2025 and Deezer's staff statement of 2025-10-19 gives no reopening date | no sanctioned way (today) |
| Yandex Music | None: Electron app, no `.sdef`, URL scheme `yandexmusic` registered | None. Only reverse-engineered endpoints with the official app's borrowed client id | no sanctioned way |
| YouTube Music (browser) | None (browser tab) | YouTube Data API `videos.rate`, 50 units, default 10,000 units a day per project, shared by every Isla user | no sanctioned way in practice |
| Amazon Music | None found | Web API is a closed beta, approved developers only | no sanctioned way |
| Apple Podcasts | No scripting dictionary on this Mac | None | no sanctioned way |
| Any player, through MediaRemote | Like / ban commands exist in headers but a test against a real player on 2026-10-25 found they do not arrive | n/a | not a route |

## 1. Apple Music: works locally (already shipped)

- `/System/Applications/Music.app/Contents/Resources/com.apple.Music.sdef` (Music 1.7, this Mac) declares on the track class `favorited` (`pLov`, boolean, "is this track favorited?") and `disliked` (`pHat`), and the same pair on playlists, plus `album favorited`. No sign-in. Isla's `PlayerBridge` already reads and writes it.
- Identity: the current track is the one the script asks, so there is no mapping problem.

## 2. Spotify: works with sign-in (already shipped; two facts worth knowing)

- Endpoints. [Save Items to Library](https://developer.spotify.com/documentation/web-api/reference/save-library-items) is `PUT /me/library?uris=spotify:track:...`, at most 40 URIs; the page lists scopes `user-library-modify`, `user-follow-modify`, `playlist-modify-public`. [Check User's Saved Items](https://developer.spotify.com/documentation/web-api/reference/check-library-contains) is `GET /me/library/contains?uris=...` with `user-library-read`, `user-follow-read`, `playlist-read-private`. The page does not say whether those scope lists are alternatives or all required; Isla requests only the first pair and `SpotifyAccount.swift` already carries the `/me/library` migration, so that is a live-test question, not a research gap.
- The old per-type paths are gone: the [February 2026 changelog](https://developer.spotify.com/documentation/web-api/references/changes/february-2026) and the [migration guide](https://developer.spotify.com/documentation/web-api/tutorials/february-2026-migration-guide) remove `PUT/DELETE /me/tracks` and `GET /me/tracks/contains` in favour of the library endpoints and say the new ones take URIs, not ids.
- Development Mode limits ([Spotify blog, 2026-02-06](https://developer.spotify.com/blog/2026-02-06-update-on-developer-access-and-platform-security)): a Premium account is required, one Development Mode Client ID per developer, up to five authorized users per Client ID; new Client IDs from 2026-02-11, existing ones from 2026-03-09. Extended Quota Mode apps are not affected. For an MIT app that ships one built-in client id this means only five listeners can sign in until Spotify grants extended quota; the owner's open item is `docs/development/checklist.md` line 924.
- Local: `/Applications/Spotify.app/Contents/Resources/Spotify.sdef` (Spotify 1.3.6) has six commands (`next track`, `previous track`, `playpause`, `pause`, `play`, `play track`) and a read-only `starred` property ("Is the track starred?", code `spSt`). There is no way to set it. Whether it reports anything useful today is untested and the property predates the Liked Songs library, so do not rely on it. The track's `id` and `spotify url` give the URI for the Web API, which is how the heart avoids any matching.

## 3. TIDAL: works with sign-in, live test owed

Source: TIDAL's [OpenAPI document](https://tidal-music.github.io/tidal-api-reference/tidal-api-oas.json) (version 1.10.206, read 2026-10-25). The developer portal itself is a script-rendered page and could not be read, so registration, quota and terms rest on a secondary source.

- Auth. "Authorization-code + PKCE flow (user context; authorize at `https://login.tidal.com/authorize`)", tokens at `https://auth.tidal.com/v1/oauth2/token`. Security scheme `Authorization_Code_PKCE`; the client-credentials flow is for server use and needs a secret, so an open-source desktop app cannot use it.
- Scopes: `collection.read` ("Read access to a user's 'My Collection'") and `collection.write`, both with `x-scopes-required-access-tier: THIRD_PARTY`. `r_usr` and `w_usr` are tier INTERNAL.
- Save: `POST /userCollectionTracks/me/relationships/items` (up to 50 items), security `collection.write` or `w_usr`. Remove: `DELETE` on the same path. Read: `GET /userCollectionTracks/me/relationships/items` (cursor paging). The spec lists the scope pairs without saying whether they are alternatives; because `w_usr` is INTERNAL, a third-party token only works if they are alternatives. Unverified.
- There is no "is this track in my collection" check. The only filter on the collection read, `filter[query]`, is marked "Internal clients only". Reading the star's state means paging the collection, or keeping a local cache of what Isla itself added.
- Mapping. Catalogue lookup by ISRC exists (`GET /tracks?filter[isrc]=`), but Now Playing carries no ISRC. Text search is `GET /searchResults?filter[query]=...&include=tracks`; with a user token its security reads `r_usr` plus `search.read` and `r_usr` is INTERNAL, so third-party search from a user token is unverified; client-credentials needs a secret. This is the weak link.
- Local: nothing found. No TIDAL scripting dictionary or URL scheme is documented; the one search for it returned only a third-party script listing.
- Secondary source ([Sonovault, updated 2026-10-19](https://sonovault.now/tidal-api)): free registration at developer.tidal.com, ten apps per account, PKCE (S256) enforced, new apps start with quota limits, staff said in 2025 they were not raising quota, limits not published, Developer Terms v3.0 allow "non-commercial applications", business products need written approval. Read the Developer Terms on developer.tidal.com before building.

## 4. SoundCloud: works with sign-in, gated

- Spec: [soundcloud/api openapi/api.yaml](https://github.com/soundcloud/api) (OpenAPI 3.0.4, terms at https://developers.soundcloud.com/docs/api/terms-of-use). `POST /likes/tracks/{track_urn}` likes, `DELETE` unlikes (responses 200, 400, 401, 404, 429). The track object carries `user_favorite` (boolean), so the state comes with any track fetch made with the user's token. `/me/likes/tracks` lists likes. `GET /tracks` accepts `q`, `urns`, `duration`, which is enough to match a Now Playing title and length. The track object has `isrc` as well.
- Auth: SoundCloud's blog and guide describe OAuth 2.1 with PKCE, access tokens of about an hour and single-use refresh tokens (from search snippets of [the guide](https://developers.soundcloud.com/docs/api/guide); the host reset my connection, so the pages themselves were not read).
- Registration: closed for years; [SoundCloud's developer blog](https://developers.soundcloud.com/blog/vibe-coding-ai-agent-docs-self-serve-api-keys) announced self-service credentials in May 2026 for Artist Pro subscribers, and the ["Get an API key"](https://developers.soundcloud.com/docs/api/register-app) page says an Artist Pro subscription is required to register an app. The subscription is the developer's, not the listener's. GitHub issue [#554](https://github.com/soundcloud/api/issues/554) shows developers objecting to that requirement.
- Not read: the API terms of use (host unreachable). Read them before shipping.
- Local: there is no desktop app; SoundCloud plays in a browser, so Isla sees only what the page publishes to Now Playing (title, uploader, artwork, duration).

## 5. Deezer: no sanctioned way today

- The OAuth model exists: app registration at developers.deezer.com/myapps, authorization at connect.deezer.com, a `perms` parameter, `manage_library` for library writes and `offline_access` for a non-expiring token (secondary sources: [yvasyliev/deezer-api](https://github.com/yvasyliev/deezer-api), [minim docs](https://minim.readthedocs.io/en/dev/api-ref/minim.api.deezer.UsersAPI.html)). Deezer's own permission and OAuth pages sit behind a login and could not be read; whether a PKCE-only public client works is not documented anywhere I could reach, and the classic flow needs an app secret.
- Registration is off. Deezer's community manager wrote on 2025-10-19, in [the "API Auth impossible" thread](https://en.deezercommunity.com/features-feedback-44/api-auth-impossible-80857), that Deezer chose to "disable the possibility of creating new accesses enabling the use of our API by private individuals", citing misuse against its agreements with rights holders, with no timeline. The thread shows users still unable to create apps on 2025-11-24, 2026-01-12 and 2026-03-09. An earlier thread, [Deezer developer apps](https://en.deezercommunity.com/features-feedback-44/deezer-developer-apps-80863) (2025-06-21), has a community answer that "Deezer has turned off My apps". The PyPI page of [deezer-oauth-cli](https://pypi.org/project/deezer-oauth-cli/) (release 1.8.0, 2026-08-07) quotes the portal: "We're not accepting new application creation at this time." I could not log in to confirm the current state of the portal; treat it as closed until Deezer says otherwise.
- Even if it reopens, the [developer terms](https://developers.deezer.com/termsofuse) limit use to "a non-commercial purpose and in a non-commercial environment", let Deezer "modify, restrict or remove Developer access" without notice, and forbid reverse engineering; the [guidelines](https://developers.deezer.com/guidelines) forbid exposing full-length track URLs and local audio storage. None of that blocks a like button, but it is a revocable permission.
- Local: [Deezer's support page](https://support.deezer.com/hc/en-gb/articles/115005516009-Deezer-Desktop-App) (updated 2025-10-13) describes a Mac desktop app (macOS 12 or later) with hotkeys for play, pause and skip, and nothing about scripting or a like shortcut. Not installed here, so its bundle was not inspected.

## 6. Yandex Music: no sanctioned way

- Official surface. The Mac app on this machine is `ru.yandex.desktop.music` 5.123.4, an Electron app (`app.asar` integrity entry in `Info.plist`), with no `OSAScriptingDefinition` and no `NSAppleScriptEnabled`. Its only hook is the registered URL scheme `yandexmusic`; no source documents what that scheme accepts, so it is not a like route. [Yandex's developer index](https://yandex.ru/dev/) lists no Yandex Music API; the [Yandex ID OAuth page](https://yandex.ru/dev/id/doc/ru/codes/screen-code-oauth) shows only `login:*` scopes and says granted scopes are fixed at app registration.
- Unofficial surface. Every client library is reverse-engineered: [MarshalX/yandex-music-api](https://github.com/MarshalX/yandex-music-api) says "Это неофициальная библиотека" ("this is an unofficial library") and calls the API undocumented and made "только для себя" (only for the vendor's own use); [p0rterB/YM-API](https://github.com/p0rterB/YM-API) says "it is impossible to register own application for now on oauth.yandex.ru" and that its client id and secret "were borrowed from the Yandex Music official application at Microsoft Store". Using another product's client secret is impersonation of the official client.
- Governing terms. [Yandex Music terms of use](https://yandex.ru/legal/music_termsofuse/) (Russia and Belarus, effective 25.08.2025), clause 2.7: the Service, Materials, Player and Database "предназначены исключительно для личного некоммерческого использования в рамках технических возможностей, предоставляемых Сервисом" and any use of the Service or its components other than as the Service provides is forbidden without Yandex's consent; clause 2.8: Yandex may set "любые правила, лимиты и ограничения" (any technical, legal or organisational rules and limits) on use "без предварительного уведомления". Nothing in the text names third-party clients, which is exactly the problem: there is no grant for them, and a client built on a borrowed secret sits outside "the technical capabilities provided by the Service". The CIS version (2.6, effective 03.02.2025) is the same in substance.
- Risk. Yandex may change or block the endpoints at any time (clause 2.8). One user reports an account-level block with HTTP 403 "API access restricted" since November, unresolved after four months ([Habr post by @walker](https://habr.com/ru/posts/993408/), dated 6 February, year not shown on the page); one anecdote, not proof the cause was a third-party client. The risk to Isla is the user's account and a brittle dependency, not a legal one in Uzbekistan or elsewhere that I can assess.
- Verdict: do not ship a star for Yandex Music. If the owner decides otherwise it is a separate product decision: opt-in, off by default, documented as unofficial, token kept in the keychain, with the 2.7/2.8 risk written in `docs/development/checklist.md` as the capabilities rule in `CLAUDE.md` requires.

## 7. YouTube Music: no sanctioned way in practice

- YouTube Music has no API of its own. The [YouTube Data API `videos.rate`](https://developers.google.com/youtube/v3/docs/videos/rate) takes `id` and `rating=like|dislike|none`, scopes `youtube`, `youtube.force-ssl` or `youtubepartner`, returns 204, quota 50 units. `videos.getRating` costs 1. The [quota page](https://developers.google.com/youtube/v3/determine_quota_cost) (updated 2026-10-15) gives every project 10,000 units a day, plus 100 `search.list` calls a day. Quota belongs to the Google Cloud project, i.e. to the one built-in client, so the whole user base shares roughly 200 likes a day and 100 searches a day.
- Whether a `videos.rate` like appears in YouTube Music's Liked Music playlist is not stated by Google. [YouTube Music Help](https://support.google.com/youtubemusic/answer/6313542) says liked songs go into a pinned "Liked Music" playlist and that likes feed recommendations in both products; the link between the two is plausible, unverified.
- Mapping fails first: a browser tab gives Now Playing a title, an artist and artwork, no video id. The tab URL would need Apple Events access to the browser, a permission prompt Isla does not otherwise use. Google's [API Services Terms](https://developers.google.com/youtube/terms/api-services-terms-of-service) (updated 2026-09-14) allow YouTube to audit and set quotas at any time (sections 6 and 15).
- Verdict: leave the star hidden. A quota extension audit would be needed before it could work at all.

## 8. Amazon Music: no sanctioned way

- The [Web API v2 overview](https://developer.amazon.com/docs/music/API_web_overview_v2.html) says v2 is "in closed Beta (preview) status" and "access is limited to already approved developers", requested through an Amazon business development contact. The [v1 track page](https://developer.amazon.com/docs/music/API_web_track.html) documents `PUT /me/library/tracks/{id}` with scope `music::library` but carries the same closed-beta and preview notices. Login with Amazon is the identity provider. Not open to an independent open-source app.
- No local scripting for the desktop app was found; the app is not installed here.

## 9. Apple Podcasts: no sanctioned way

- `/System/Applications/Podcasts.app` (1.1.0) has no `OSAScriptingDefinition` and no `NSAppleScriptEnabled`. MusicKit's documented scope is music; I found no podcast library write API for third parties. "Favourite" is not even a podcast concept (it is "follow a show" or "save an episode"). Hide the star.

## 10. MediaRemote like / ban commands: not a route

- The commands exist as names. WebKit's PAL SPI header ([MediaRemoteSPI.h](https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebCore/PAL/pal/spi/mac/MediaRemoteSPI.h)) lists an `MRMediaRemoteCommand` enum with `RateTrack`, `LikeTrack`, `DislikeTrack` and `BookmarkTrack` after `ChangePlaybackRate`; entries have no explicit values, so `LikeTrack` is ordinal 21 if the order matches the framework (the first 14 entries match the numbering used by [ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter#send-command)). The header has no `BanTrack` and no "add to library" command. An older iOS-era dump ([ios-reversed-headers MediaRemote.h](https://github.com/davidmurray/ios-reversed-headers/blob/master/MediaRemote/MediaRemote.h), undated) defines a different set with explicit values: `kMRLikeTrack = 0x6A`, `kMRBanTrack = 0x6B`, `kMRAddTrackToWishList = 0x6C`, `kMRRemoveTrackFromWishList = 0x6D`, taking a `userInfo` dictionary with track, station and station-hash ids. I found nothing that settles which numbering today's macOS uses.
- Reading state is documented in the same dumps: Now Playing keys `IsLiked`, `IsBanned`, `IsInWishList` and the capability flags `SupportsIsLiked` and `SupportsIsBanned`. `mediaremote-adapter` passes `isLiked`, `isBanned`, `supportsIsLiked` through in its `get` and `stream` output. Isla's helper does not read them today (no match in `Sources`).
- Nobody honours the commands in practice, as far as the evidence goes. The [ztomer/mediaremote-adapter v0.1.0 release](https://github.com/ztomer/mediaremote-adapter/releases/tag/v0.1.0), published 2026-10-25, says it removed `likeTrack`, `banTrack`, `addToWishList` and `removeFromWishList` because, "recorded against a real player: none of them reached its target, and one arrived as 'next track'". It does not name the player or macOS version. `ungive/mediaremote-adapter` itself whitelists only commands 0 to 13 in `send.m`. The public counterpart, `MPRemoteCommandCenter.likeCommand` ([Apple](https://developer.apple.com/documentation/mediaplayer/mpremotecommandcenter)), is what a player would implement to receive a like; the one Apple Developer Forums thread on it ([740555](https://developer.apple.com/forums/thread/740555), 2023, no replies) shows nobody knows when the system shows it. I found no source naming a Mac player that responds to a like command.
- Isla's helper already asks each player which commands it offers (`refreshCommands` in `Sources/IslaMediaHelper/helper.m` keeps only commands that are listed and enabled). That is the right gate if a like route is ever tried: show a star only for a player whose list contains the like command, and prove with a state change. It has not been done.

## Matching the playing track to the service's id

| Service | What Now Playing gives | How to get the id | Cost and risk |
|---|---|---|---|
| Apple Music | not needed | AppleScript acts on the current track | none |
| Spotify | `id` / `spotify url` over AppleScript | read directly; checked to be 22 base62 characters before use | none |
| TIDAL | title, artist, album, duration | `GET /searchResults` then match title, artist, duration within 2 s; or ISRC if a player ever supplies one | search auth for third-party tokens unverified; wrong-song risk on remasters and live versions |
| SoundCloud | title, uploader, duration, from the web page | `GET /tracks?q=...&duration=...`, compare title and uploader | wrong-song risk on reuploads; rate limit 429 |
| YouTube Music | title, artist; no id | `search.list`, 100 a day per project | blocks the feature |
| Deezer, Amazon, Yandex | n/a | n/a | n/a |

Rule for any search-matched id: require an exact normalised title and artist match plus duration within 2 seconds, show the star only when exactly one catalogue result qualifies, and never write when two do. A wrong like is worse than no star.

## What this means for Isla

1. Keep Apple Music and Spotify. Nothing here changes them. The Spotify five-user Development Mode cap is the real ceiling on how many people can use the heart without their own client id.
2. If one more service is built, TIDAL is the only one with an open registration, a documented PKCE flow and a user-library write at the third-party tier. The two open questions are whether `collection.write` alone authorizes the write and whether a user token can search. Both can be answered in one session with a registered dev-mode app and a TIDAL account, before any UI. SoundCloud is second: the API is complete and has `user_favorite`, but registration needs the owner's Artist Pro subscription, and the player is a browser tab.
3. Hide the star for Deezer, Yandex Music, YouTube Music, Amazon Music, Apple Podcasts and any unknown player. Show it only when the player is identified and has a verified route, which is what the current Music and Spotify code already does.
4. The capabilities rule in `CLAUDE.md` applies to anything new: any account sign-in is added to `docs/development/checklist.md` and defaults to off.

## Not verified

- Deezer's permissions and OAuth pages (login-gated), and whether the developer portal is still closed today.
- TIDAL Developer Terms and rate limits (the portal is script-rendered); whether `collection.write` is sufficient without `w_usr`; whether search works with a third-party user token; the TIDAL Mac app's scripting.
- SoundCloud's terms of use and guide pages (host reset the connection).
- Whether `videos.rate` populates YouTube Music's Liked Music.
- Which numbering today's MediaRemote uses for `LikeTrack`, and whether any player responds to it.
- Spotify's `starred` property: whether it returns real data.
- Amazon Music, Deezer and TIDAL desktop apps: not installed, bundles not inspected.
- The Yandex Music app was not launched and its `app.asar` was not opened; what the `yandexmusic` URL scheme does is unknown.
- Not legal advice. The Yandex reading rests on clauses 2.7 and 2.8 of the Russian text; a lawyer would need to say whether a user's own token in a user's own app breaches them.
