# Is there a 1:1 open-source clone of Apple's lock-screen player?

**Asked:** 2026-08-25. **Short answer:** no, and the better route is not a clone.

## What was looked for

An open-source, pixel-accurate reimplementation of the iOS Now Playing card as it
appears on the current lock screen, to drop into this app's lock card.

## What exists

| Project | License | Platform | Verdict |
| --- | --- | --- | --- |
| [fruitcoder/lock-screen-player-view](https://github.com/fruitcoder/lock-screen-player-view) | MIT | iOS, SwiftUI | Closest by intent, unusable by fidelity. Its own README says it is "by no means a pixel perfect representation" — it exists to back snapshot tests, and it is pinned to the iOS 14.5-era design. Five major redesigns stale. |
| [jackson-storm/DynamicNotch](https://github.com/jackson-storm/DynamicNotch) | **GPL-3.0** | macOS 14.6+ | Active, and has a real Now Playing surface with artwork and a visualiser. The licence is a hard stop: GPL-3.0 is copyleft, and taking its code would force this whole app to GPL. It ships as a direct-download DMG under its own licence with MIT attribution to Cyclop; that cannot survive linking GPL code. **Do not copy from it.** |
| [aisultanios/MyPlaylists](https://github.com/aisultanios/MyPlaylists) | — | iOS | An Apple Music *app* clone, not the lock-screen card. |
| SwiftUI-Music-Player, NeoMusic-SwiftUI, musicPlayerSwiftUI, LGAudioPlayerLockScreen | mixed | iOS | Generic players. `LGAudioPlayerLockScreen` is about lock-screen *controls* — `MPNowPlayingInfoCenter` wiring — not the card's appearance. |

No project was found that reproduces the current card. That is not surprising:
the lock screen is not a public control, nobody can call it, and the design has
moved twice since the last serious attempt.

## The better route, and it is available right now

Apple shipped the material itself. Liquid Glass arrived across iOS 26, macOS 26
Tahoe and the rest at WWDC 2025, with first-class SwiftUI API — `glassEffect`,
`GlassEffectContainer`, `glassEffectID`.

**Verified on this machine, not assumed.** Host is macOS **26.5.2**, Xcode
**26.6**, macOS 26.5 SDK. The following compiled clean inside this package —
which still declares `platforms: [.macOS(.v15)]`, so the floor does not have to
move:

```swift
if #available(macOS 26.0, *) {
    GlassEffectContainer {
        Text("probe")
            .padding()
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}
```

So the app can use Apple's real material where the OS has it and keep the drawn
`GlassSurface` recipe underneath as the macOS 15 fallback. That is closer to
"Apple ecosystem level" than any clone could be: it is not an imitation of the
material, it is the material, and it will follow Apple's future tuning — 26.2
already added a user control for how clear or frosted the glass reads.

## The catch, which is specific to our lock card

`GlassSurface`'s own documentation records why it is drawn rather than sampled:
above the login shield there is nothing to sample. The shield is protected
content and no window over it is given a backdrop, which is why real vibrancy
was abandoned there and why the system's own lock-screen widgets are built the
same way.

`glassEffect` samples what is behind it. On the lock card it will very likely
degrade exactly as vibrancy did. So the split is:

- **Inside the panel** (media pane, lyrics stage, sync pill, output picker):
  adopt `glassEffect` behind `if #available(macOS 26, *)`. There is a real
  backdrop to sample and this is where it will show.
- **Above the shield** (the lock card): keep the drawn recipe until measured
  otherwise. Test it; do not assume either way.

## Recommendation

1. Do not hunt further for a clone. None is close, and the one that is closest
   in function is GPL and would take the whole app with it.
2. Adopt `glassEffect` for in-panel surfaces, availability-gated, `GlassSurface`
   as the fallback. One measured experiment on the lock card decides that one.
3. Match the current card's *layout* from Apple's shipping design — centred
   artwork, controls beneath — by observation, not by copying anyone's source.

## A note on 1:1

Reproducing Apple's interface exactly is a trade-dress question, not just a
technical one, and this app's own rules already say product identity must stay
original. Using Apple's own APIs raises none of that: the glass is Apple's,
drawn by Apple, on Apple's terms.

## Sources

- <https://github.com/fruitcoder/lock-screen-player-view>
- <https://github.com/jackson-storm/DynamicNotch>
- <https://github.com/conorluddy/LiquidGlassReference>
- <https://getskyscraper.com/blog/apple-liquid-glass-ios-26-swiftui-guide>
- <https://www.macrumors.com/2025/11/04/ios-26-2-liquid-glass-slider/>
