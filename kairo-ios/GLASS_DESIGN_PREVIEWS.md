# Kairo glass design playground

Question: which floating navigation and content hierarchy should Kairo adopt?

This is an isolated design prototype on `prototype/glass-designs`, based on the download-rate-limit update. Debug launches open the playground by default. Release builds still open the current app. Sample sources, titles, progress and episodes are fixtures; no source fetch, library mutation, playback or download occurs in these preview screens. Background downloading remains the next task after selecting the UI.

## Run in Xcode

From an existing clone of KusaPo/Shirox:

```bash
git fetch origin
git switch --track origin/prototype/glass-designs
open kairo-ios/Kairo.xcodeproj
```

Select the **Kairo** scheme and an iPhone simulator, then Run. If the local branch already exists, use `git switch prototype/glass-designs` instead. To use Canvas, open `GlassDesignPrototype.swift`; its preview chooser contains A, B and C.

- **A — Glass Cinema:** immersive hero artwork, horizontal continue-watching cards, ranked shelves, four tabs inside a wide floating dock and a separate Discover circle. Closest to Shirox's floating bar and separate search role.
- **B — Split Island:** editorial greeting, an inset split-art spotlight, compact icon dock and a separate Discover circle. Settings stays in the header.
- **C — Editorial:** large serif heading, a wide feature card, compact continue rows, and five destinations in one quieter floating pill.

Use the small arrows above the bottom dock to switch designs. Tap its label for details. Try all five destinations, the Discover search field and genre filters, a title's episode sheet, the small source label, and the sun/moon button. Settings also offers **Open the real Kairo app** to compare against the current implementation.

The prototype switcher is separate from the proposed app navigation. `--capture` hides that switcher for clean screenshots. Xcode scheme Run arguments can select a starting state:

```
--glass-style B --glass-page discover
--glass-style B --light
--normal-app
```

## Glass and compatibility

Shirox uses a native SwiftUI TabView with a separate search-role tab, plus availability-gated custom glass chrome. Sources checked at upstream `f234a204d9ab72c4514c25f1f821144e32b5e142` on October 21, 2026:

- https://github.com/xibrox/Shirox/blob/f234a204d9ab72c4514c25f1f821144e32b5e142/Shirox/ShiroxApp.swift
- https://github.com/xibrox/Shirox/blob/f234a204d9ab72c4514c25f1f821144e32b5e142/Shirox/Views/Shared/View%2BGlassChrome.swift
- https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views

The prototype's custom islands use native `glassEffect` when built with Xcode 26+ and run on iOS 26+. Xcode 16 and older supported iOS versions use translucent material, borders and shadows. That fallback demonstrates the layout, not native optical refraction. Reduce Motion suppresses navigation animation. Controls retain labels for VoiceOver; the preview never depends on a gesture alone.

## Preview-only artwork

Bundled promotional art makes Xcode Canvas and simulator screenshots deterministic without live catalog access. These sample images are for evaluating the design, not a replacement catalog or episode-thumbnail implementation. Rights remain with their respective owners. Use source-provided metadata/artwork in the chosen production design.

- Frieren promotional visual: https://ogre.natalie.mu/media/news/comic/2023/0823/frieren_kv0823.jpg?impolicy=pp
- Solo Leveling promotional visual: https://pbs.twimg.com/media/GXkdjufaEAAqPpm.jpg
- DAN DA DAN promotional visual: https://www.anime2you.de/media/2024/03/dandan-scaled.jpg
- Demon Slayer promotional visual: https://p2.bahamut.com.tw/B/2KU/19/c73a395204492fdddc9a1ca6451y38n5.JPG?v=1774857174212

No direction has been selected yet. Keep the losing examples on this prototype branch, then implement the selected design in production code with real data and navigation state preservation.
