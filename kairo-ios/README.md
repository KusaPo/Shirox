# Kairo for iPhone — first native implementation

Purple accents, a top-10 AniList trending carousel, Animex catalog and provider integration, AVPlayer playback, a local library/history, and a persistent native download queue.

**Development build. Do not treat source availability or offline playback as verified until the device checklist passes.** The implementation environment has no Xcode, and direct catalog requests returned HTTP 403 here. Check the branch's build workflow for compiler/test results.

## Open on your Mac

1. Download or clone this branch, then open `kairo-ios/Kairo.xcodeproj` in Xcode 16 or newer.
2. Select the **Kairo** app target → **Signing & Capabilities** → your Apple development team. If necessary choose a unique bundle identifier. Do not share account credentials in chat.
3. Select your connected iPhone (iOS 17+) as the run destination. Complete any device trust or Developer Mode setup Xcode requests.
4. Run with **⌘R**. Start with Home or search a title in Discover.
5. Run unit tests with **⌘U**. The checked-in project has no third-party package dependencies.

The Python project generator is only for maintainers; you do not need to run it to open the checked-in Xcode project.

## Implemented paths

- Top-10 AniList trending fetch, artwork, cached trending data with last-update time, six-second rotation and manual navigation. Automatic motion is disabled for Reduce Motion and VoiceOver.
- Animex search using its documented-in-module GraphQL contract; exact AniList ID matching for trending titles, avoiding guessed source slugs.
- Episode provider lookup with Sub/Dub selection and visible HTTP/API errors. Only HTTPS HLS/MP4 media links are accepted; HTML embeds are not presented as video files.
- Native AVPlayerViewController, supported system audio/subtitle controls, progress persistence, resume and saved-title library.
- Single or next-three episode downloads, two concurrent transfers, queue/pause/retry/remove, separate Wi-Fi/cellular background sessions, restored task records, local offline playback, and file deletion that preserves history.
- HLS downloads use Apple's asset download APIs. Embedded English subtitles are selected when offered. Direct video downloads use background URLSession transfers. Readiness includes a local playable-media check.
- Source-link manifest inspection. It does **not** execute arbitrary imported JavaScript.

## Explicitly unfinished

- Additional community-module runtimes and a second verified catalog provider. Importing a library link does not install an operational provider yet.
- Exact per-resolution selection, external subtitle file downloads, configurable autoplay-next, multi-season mapping, optional account sync, background PiP lifecycle polish, and production app artwork.
- Live video decoding, actual offline audio/subtitle availability, background completion, interrupted-URL recovery, and device accessibility have not been verified merely by compiling this project.
- Provider request headers use AVURLAsset's widely used `AVURLAssetHTTPHeaderFieldsKey` option, whose portability must be tested. A provider requiring an unsupported transport may need a different integration.
- Retrying an interrupted transfer with no surviving OS task resolves a fresh media link and starts again; it does not promise byte-level resume across changed URLs.
- HLS download support on Simulator is not a substitute for device testing. No backend or proxy is deployed.

## Device acceptance checklist

1. Search a known title, select the expected episode and language, and try its listed providers. Confirm actual video and audio play; record which provider worked.
2. Play for 30 seconds, leave, reopen and confirm resume. Finish an episode and verify it is not offered as an unfinished resume point.
3. Download one episode. Confirm the required audio/subtitles exist in the local asset. Wait for **Available offline**, relaunch the app, enable airplane mode and play from Downloads.
4. Download a batch, pause/resume, lose and restore network access, background the app, and separately force-quit/relaunch. Confirm the UI reports interrupted transfers accurately.
5. Remove one download and verify watch history is preserved. Test low-storage behavior before claiming readiness for general use.
6. Test source errors, missing dubs, an unavailable episode, Reduce Motion, VoiceOver, large text and landscape player controls.

Do not declare the new app functional until steps 1–3 pass on an iPhone. Do not claim multiple-provider support until a second independent source completes the same path.

## Architecture

`CatalogAPI` isolates the first source contract. `Anime.id` anchors saved state independently of changing source URLs. `AppStore` writes Codable state atomically and preserves an unreadable existing store. `DownloadManager` owns native background tasks and relative local paths. `PlaybackController` manages the player and progress. SwiftUI views use real state and show errors instead of sample success states.

The original ReAnime/ShiroX module files elsewhere in this repository remain a separate project.
