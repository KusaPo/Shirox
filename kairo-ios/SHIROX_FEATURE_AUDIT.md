# Shirox feature audit for Kairo

Reference: xibrox/Shirox at `1164c7a0d3f61e28a1ea1d448a5c43910090047f` (September 27, 2026). This is a feature comparison, not an import of Shirox code or assets. Its source is PolyForm Noncommercial 1.0.0. Kairo remains a separate iPhone app with a purple theme and its own data model.

| Area | Shirox | Kairo after this update | Remaining work |
| --- | --- | --- | --- |
| Home and browse | Hero, cached artwork, continuation, shelves, richer provider feeds | Trending carousel, continuing, shelves, paginated AniList grid, module and Animex search, cached covers | Provider-specific recommendations and search aliases |
| Artwork and layout | Image memory/disk cache, textless fan art, dynamic title logos, fit/fill in suitable contexts, tablet layouts | Full poster over blurred card fill, memory cache, banner/portrait handling, dark/light | Disk image cache, logos, tablet-specific layouts and image request headers from search results |
| Title and episodes | Detailed pages, lists, metadata, season chains, multi-season progress | Title banner/cover, synopsis, episode names/thumbs when available, progress and download state | Season chaining, special/decimal episodes, alternative order and metadata coverage |
| Sources | JS modules, local files, Jellyfin, other extension adapters, Cloudflare recovery | Supported Luna/Sora JS manifest subset, native Animex, AniList catalog | Local-file and Jellyfin integrations, other extension dialects, Cloudflare challenge handling |
| Player | Custom controls, double tap, skip, source/quality/audio menus, PiP, AirPlay, Chromecast, next-stream prefetch, adjustable subtitles | Custom seek/timeline/speed/Sub-Dub/fit, double-tap seek, intro skip, auto-next, near-end next-stream prefetch, AirPlay, iOS-controls path for PiP and embedded subtitle tracks | Native PiP in custom controls, external subtitle sidecars and styles, Chromecast, HLS quality/source switching during playback, sequel chaining, stall recovery |
| Downloads | Background HLS, manga chapters, provider integration | Background HLS/direct video, queue/retry, offline playback, numeric episode order | Manga, quality choice, watched-item cleanup, account/cloud sync |
| Accounts and library | AniList, MAL and Simkl tracking, offline write queue, statuses, social activity | Device-only library, history and local watch progress | OAuth accounts, bidirectional tracking, offline write queue, social UI and conflict resolution |
| Other platforms | iPhone, iPad and Mac targets | iPhone build and AltStore IPA | Dedicated iPad and Mac layouts/targets |

## Playback and crop behavior

- The player opens with aspect-fit video, showing the whole frame. Fill is an explicit setting/button and can crop edges; its choice persists.
- Cover cards show the complete poster with a blurred backdrop so there are no blank bars. Hero banners deliberately fill their large frame, which may crop artwork. Episode previews remain specific to an episode when the source or frame extraction allows it.
- Double tap seeks by the configured short amount; the long seek button is configurable. A cached next-stream request starts after 80% progress only when the next episode is known, no matching offline copy exists and the current stream is online. If prefetch fails, next episode retries normal lookup.
- Shirox's entire feature set is not installed by this pass. Several areas require their own data model, authentication, provider integration, and device testing; successful compilation is not playback verification for any individual source.
