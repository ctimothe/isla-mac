# A level indicator while the panel is open: volume and brightness keys over the open island

Researched 2026-10-25. Question: with Volume and Brightness on, a key press on a shut island draws the pop-up (symbol, bar, percent). With the panel open the key still changes the level and nothing is drawn. The owner floated, as an idea and explicitly not a direction, a thin strip opening under the island with a little spacing, in the same design. What is the cleanest, most Apple-native answer?

## What the code says today (this is a real gap, not a taste question)

- `NotchController.hudAllowed` refuses the pop-up whenever `isOpen`. Its comment gives the reason: "the player has its own volume slider". That is no longer true. Volume left the island on 2026-10-16 (owner; `docs/development/plans/2026-10-15-redesign-spec.md` §4.5 amendment, and `SystemVolumeSlider`'s own header comment: the lock card keeps it, the player and the Output menu lost it). `MediaPane` has no volume control. An open panel therefore has no volume bar and, for brightness, never did.
- `NotchViewModel.isOpen`'s `didSet` sets `hud = nil` when the panel opens, for the same stale reason.
- `presentHUD` already announces the level to VoiceOver before it checks `hudAllowed`, so the only people left with no feedback are sighted ones. Whichever option below is built, the comments and spec §12 need correcting in the same change.
- Geometry that bounds the options: the window is cut once to `NotchMetrics.maximumWindow` 700 x 444 and never resized; the tallest body is Settings at 400 (`tallestBody`); the player is 208 plus a 16 pt dots band, Clipboard, Translate and the tray are 300 plus the band (`SurfaceLayout`). Open radii are 34 top / 44 bottom, 24 / 34 for the tray. The header strip is the notch's height; the title sits at x 20 and ends 8 pt before the notch, the gear sits at `bw - 46` and Translate's History at `bw - 76`.
- The shut pop-up (`HUDLayout`, spec §19.5 d): 245.4 x 103 expanded alert, title line, symbol, 8 pt bar (track white 0.18, fill white 0.92), SF Pro Rounded 14 percent. It arrives on `Theme.hudSpring` (response 0.3, damping 1.0) with opacity plus 0.94 scale about the top edge, the bar follows on `Theme.hudLevel` (0.2 s spring), it lingers `Theme.hudLinger` 1.5 s after the last press, and under Reduce Motion it crossfades in 0.24 s and the bar steps.
- Precedent for a detached element inside Isla already exists: while Music holds the island, files on the Shelf wait as a bubble beside it with its own hit region (`NotchRootView.bubbleRect`), and the gap between the two stays click-through.

## What the references show, and what they do not

**Mobbin does not carry the system volume or brightness HUD.** System overlays are not part of app screenshots, so no search over iOS or web returned one (searched: iPhone volume change over a music player, video player with a level readout after a hardware button, Control Center sliders, Dynamic Island expanded, toast over a sheet). Everything below about how iOS and macOS draw their own HUD is from my own knowledge and was not verified in this session; it is marked as such.

What Mobbin does give:

1. Where apps put a volume level when the player is open. Always as part of the card, never as a transient pop-up: Sonos has a slider with a 0-100 number on its now-playing card ([Sonos now playing](https://mobbin.com/screens/c24a58f4-ed5c-4265-beb0-947dadc64673)); Apple Music, Apple Podcasts and Particle News keep a speaker-icon slider as the last row of the player ([Apple Music](https://mobbin.com/screens/b166b10a-4ed4-4ed1-8a8a-1446dad381a9), [Apple Podcasts](https://mobbin.com/screens/2070aaf4-77d3-42a5-9129-67b6e851866c), [Particle News](https://mobbin.com/screens/9065ab0a-5260-47f0-9fc5-3e44bd42fa12)). That is the pattern Isla withdrew on 2026-10-16, so it is evidence for why the gap exists, not for a fix. (From knowledge, unverified here: on iPhone the system HUD stays out of the way while an in-app volume view is on screen and the app's own slider moves with the buttons.)
2. A docked strip attached below a card, carrying one slider: HBO Max's "Bedroom TV Volume" strip under the player ([HBO Max](https://mobbin.com/screens/4be56b59-799e-4d20-ad61-0d6a6ef7a92e)), Sonos's mini player pinned under the settings sheet with a slider and a number ([Sonos settings](https://mobbin.com/screens/f3b1f248-03f4-411a-be35-ce90e8270fe9)), YouTube's Volume sheet ([YouTube](https://mobbin.com/screens/613282cf-a09e-4f70-9ef0-8c562f476ab0)), Deezer's output sheet ([Deezer](https://mobbin.com/screens/428fa9fd-a917-4518-bba8-42836180fb98)). These are flush and persistent. They support "a slim band below the content" as a shape; none is transient, and none has a gap.
3. A detached element beside the island: NFL shows the island plus a separate round bubble with a gap between them ([NFL](https://mobbin.com/screens/8019f311-5b4c-46a9-a7f7-26fee5dc4996)), which is Apple's detached minimal Live Activity. Expanded presentations to compare size and density against: [Forest](https://mobbin.com/screens/1b152fab-1bc7-4e4e-b778-64645acdebcb), [Citizen](https://mobbin.com/screens/99eba79c-29fa-4caf-bae4-420911f1caaf), [Tolan](https://mobbin.com/screens/8b570236-6c4f-4fe4-8424-e7984d913a6f). All three are black, tightly packed, large type.
4. Transient confirmations drawn over a card or sheet, which is what the other two options below would be: [Lyft](https://mobbin.com/screens/70928e98-c3b5-4b21-a039-6b810514bb1f), [Fabric](https://mobbin.com/screens/6abaa9ea-d89b-4c7e-b456-eee8fe5eb6b8) and [Jomo](https://mobbin.com/screens/7153a154-2347-42e4-b911-b008368d528c) float a pill over the top of the content and cover it. A value-in-a-pill readout beside a level scale: [IKEA Home smart](https://mobbin.com/screens/fc8741b4-c93f-4804-8986-77da1ae9bc58).

Apple, fetched from the HIG data (the `/the-dynamic-island` page returns 404; its content is folded into Live Activities):

- [Live Activities](https://developer.apple.com/design/human-interface-guidelines/live-activities), Dynamic Island and system UI: "other items can appear in the Dynamic Island when your app is open." The island is expected to share its space with other things. Minimal presentation: "One appears attached to the Dynamic Island, while a second ... appear detached on one or both sides." A detached satellite is the sanctioned way to show a second thing next to the island.
- Same page, layouts: "Use consistent margins and concentric placement" and "Don't draw content all the way to the edge of the Dynamic Island." Animations "with a maximum duration of two seconds" (the pop-up's 1.5 s linger is inside it). "Update a Live Activity only when new content is available" and "Alert people only for essential updates" (a level change after a key press is essential and wanted). "Dynamically change the height" is about the Live Activity itself, and argues against growing the panel for a 1.5 s readout.
- [Sliders](https://developer.apple.com/design/human-interface-guidelines/sliders): iOS and iPadOS: "Don't use a slider to adjust audio volume" (use the system volume view). macOS: give live feedback as the value changes, and show the value of the thumb. Speaker or sun glyphs at the ends are the sanctioned way to say what a level is.
- [Playing audio](https://developer.apple.com/design/human-interface-guidelines/playing-audio): "People expect their volume settings to affect all sound in the system ... regardless of the method they use to adjust the volume." "Avoid repurposing audio controls." It says nothing about a HUD. Isla's panel must not offer a competing volume control and does not.
- [Feedback](https://developer.apple.com/design/human-interface-guidelines/feedback): "match the significance of the information to the way it's delivered", and status feedback "near the items it describes". A passive, transient readout near the thing that changed, not an alert.

From my own knowledge, unverified here: Apple's HUD is a separate system layer in both OSes. It never edits the app's chrome and fades after a moment. On iPhone it is a vertical glass pill at the screen edge; the macOS 26 version I did not check. The common thread is "a short-lived layer of its own, same material every time", not "the app's UI changes".

## Options

All three reuse `HUDMoment` (symbol, level, muted, percent, accessibility label) and the existing key path; only where and how it is drawn differs. One drawn indicator per event: the shut pill and the open-panel indicator are never on screen together, and `hudAllowed` keeps refusing while a drag is over the panel, on the lock screen and while the screens sleep.

### A. A detached strip under the open panel (the owner's idea, tightened)

What the person sees. A black capsule 32 pt tall appears 6 pt below the panel's bottom edge, centred on the notch's axis. Width about 220 pt (never wider than the body minus twice the bottom radius, so it sits inside the panel's curve, concentric with it as the HIG asks). Inside, one row: the symbol (the same `HUDSymbol` rules, so AirPods show their glyph), a 6 pt bar on a white 0.18 track with a white 0.92 fill, the percent in SF Pro Rounded 14 tabular. No title line: the glyph says what it is, and the line was only there because the shut pop-up has the height. It carries the island's 2 pt stroke so it reads as a satellite of the same island (spec §19.3).

Motion. It emerges from under the panel on `Theme.hudSpring`: opacity plus 0.94 scale about its top edge, response 0.3, damping 1.0, no overshoot. The bar follows each press on `Theme.hudLevel`. It lingers 1.5 s after the last press (`Theme.hudLinger`). A repeated or held press only moves the bar and restarts the timer; the strip does not re-animate, the same as the shut pop-up. It folds on the same spring. Reduce Motion: 0.24 s crossfade, bar steps (`Theme.hudLevel(reduceMotion:)` is already nil).

Panel changes: none. The window already has the room: 400 (Settings, the tallest body) + 6 + 32 = 438 of 444, 6 pt to spare for the stroke. Verify on a notch of a different height before relying on it; the arithmetic is body-relative, so a test on `NotchViewModel`'s metrics would hold it.

Supports: the NFL detached bubble and HIG minimal presentation (a detached satellite beside the island), Isla's own Shelf bubble (a separate element with its own hit region and a click-through gap), the Sonos and HBO Max docked strips (one slider in a slim band below a card), HIG concentric margins.

Trade-offs.
- Covers no panel content on any surface, including Settings, the stage and the welcome.
- Clickable region: unchanged. The strip is never hit-tested; it is not added to `activeRect`, so the 6 pt gap and the strip are click-through like the transparent window around them. Check `PointerWatcher` and the collapse logic: the strip is below the body, so it must not count as the pointer leaving or arriving.
- Does not fight a volume control: the player has none since 2026-10-16. If one ever returns to the open panel, this option would double up and the strip should be suppressed on that surface.
- Costs: a second element on screen next to the panel, which is a small departure from "one surface at a time" (spec R8). It is a transient indicator rather than a surface, and Isla already draws the Shelf bubble beside the island, so I rate the departure small. If the panel closes while the strip stands, fold it with the panel and let the next key use the shut pop-up.

### B. The level takes over the dots band inside the panel

What the person sees. For 1.5 s the four page dots under the page cross-fade into one 16 pt row: symbol, a 3 pt bar, the percent. Nothing is added; the band that already exists carries it.

Motion. A 0.2 s cross-fade of the band's content, bar follows on `hudLevel`, 1.5 s linger restarting on each press. Reduce Motion: cut, bar steps.

Supports: Hatch Sleep and Ladder show sliders as the last row of a card ([Hatch Sleep](https://mobbin.com/screens/a59a0aa5-5e53-4d1e-99c2-9f84fad7641c), [Ladder](https://mobbin.com/screens/18aae5d3-46cc-4c0b-bd8a-cb34b48abe2e)); HIG "status feedback near the items it describes". No Apple precedent for chrome that swaps itself for a system level.

Trade-offs.
- Covers no content (the band is chrome) and changes no geometry or hit region, but the dots are also controls (click to turn, VoiceOver adjustable), so for 1.5 s a control is replaced; a tap in that window lands on a bar.
- Exists only on the four pages. The stage, Settings, drop and welcome have no band and would need a second answer, so this option cannot stand alone.
- A 16 pt row is too small to read at a glance for a thing the person is looking for the moment they press a key.
- The system's own HUD is never made of the app's controls; this one is.

### C. The header's title slot becomes the readout

What the person sees. The page title (glyph plus name, the left wing of the header strip, x 20 to 8 pt before the notch) cross-fades into symbol, bar and percent for 1.5 s. At 560 wide with a 185 pt notch the slot is about 167 pt, enough for a 16 pt symbol, a 90 pt bar and the percent. The right wing keeps the gear and History.

Motion. 0.2 s cross-fade, same linger and bar spring. Reduce Motion: cut.

Supports: the compact Dynamic Island's idea of using the wings beside the camera (HIG Compact: content "snug against the TrueDepth camera"), Isla's own `SurfaceHeaderLayout`. No screen on Mobbin does this.

Trade-offs.
- Covers no content and changes no hit region, but loses the page's name for 1.5 s, and the header is where the person looks least when pressing a key.
- The title's width varies by language ("Буфер обмена" at 480 is already tight); the readout has to fit the narrowest slot, so it shrinks at 480 wide.
- It edits the app's chrome to show a system level, the opposite of how Apple draws its HUD.
- Works on every surface that has a header row; the drop surface and welcome need checking.

## Recommendation: A

Option A is the only one that does what Apple's own HUD does: a separate, short-lived layer in a consistent material that never edits the content or controls it appears over. It is also the only one that is the same on every surface (the player, the Shelf, Clipboard, Translate, the stage, Settings), needs no change to the panel's layout, hit region or window, and reuses the pop-up's data, curves and linger unchanged, which is what "in the same design" asks for. B and C each spend a piece of the panel's own chrome and leave surfaces uncovered.

Adopted from the owner's idea: a strip under the island with a little spacing, same design. Changed: single row without the title line, 32 pt rather than the 103 pt shut pop-up so it is a strip and not a second card, 6 pt gap and concentric width, the island's stroke, no new window size.

If the owner finds a second element beside the panel too much, C is the fallback because it needs no extra space; B only as a supplement on pages.

## Build notes for whoever picks it up (not done here)

1. Replace `hudAllowed(isOpen:...)`'s refusal with a placement choice: shut pill when shut, strip when open; keep the other three refusals.
2. Remove `hud = nil` from `isOpen`'s `didSet`, or make it fold the pill rather than drop it, and drop the "the player has its own volume slider" comments in both places.
3. Add the strip's metrics to `NotchMetrics` (height 32, gap 6, width 220) with a test that tallest body + gap + height fits `maximumWindow`.
4. Tests: placement per state (pure, like `hudAllowed`), repeated presses do not restart the arrival, the strip is not in `activeRect`, Reduce Motion path.
5. Amend spec §12 and the checklist in place, dated; add a hardware check: hold a volume key with the panel open on a notched and an unnotched display, at 480 and 620 wide.

## Not verified

- The look of the system volume and brightness HUD on iOS 16 to 26 and macOS Tahoe: no Mobbin capture exists, and I did not run anything on a device or the app (told not to).
- Whether the strip's 2 pt stroke and a soft shadow fit in the 6 pt of slack under Settings on every notch height.
- The `PointerWatcher` and collapse behaviour with a non-interactive element just below the body.
