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

## Test with AltStore

The **Kairo iOS** GitHub Actions workflow also builds an arm64 iPhone IPA. Open a successful run for this branch and download **Kairo-AltStore-IPA** from Artifacts. Unzip it to get `Kairo.ipa`; save that file to your iPhone's Files app and import it using **AltStore Classic → My Apps → +**. Use your normal AltStore signing setup (AltServer if required by your setup).

This is an unsigned development IPA for AltStore to sign, not an App Store or TestFlight release. Requires iOS 17 or newer. It includes the latest HLS session fix; complete the device acceptance checklist below to verify actual downloads and offline playback.

To make the same IPA on a Mac with Xcode installed, run `bash kairo-ios/scripts/build_ipa.sh` from the repository root. Output: `kairo-ios/build/ipa/Kairo.ipa`. No signing credentials are needed to package it; AltStore handles signing during installation. The build checks the device platform, arm64 executable, package layout, and ZIP integrity, and includes a SHA-256 checksum.

## Implemented paths

- The approved purple K/play mark is installed as the app icon and displayed in Sources & preferences.
- Settings → Appearance offers System, Light and Dark modes. The choice takes effect immediately and persists between launches without changing existing library/history data.
- Preview artwork fills its bounds. Wide banner frames reduce cropping, and portrait-only headers use a complete poster over a blurred full-bleed backdrop. Trending titles/actions remain below the artwork.
- Episode rows show AniList episode previews when available and Jikan/MyAnimeList titles. For missing images, Kairo tries to extract a frame from that episode's video (from a local download or a resolved stream), with at most two previews resolving at once. Some HLS streams lack the I-frame data needed for extraction, so those rows show an episode-number placeholder, never the same show cover for every episode. Missing external IDs trigger an exact-title metadata lookup. Long series use 100-episode ranges with cached, rate-spaced paginated requests. Episode titles depend on external coverage and may be unavailable.
- Episode rows reflect download state directly. Ready episodes say “Downloaded · Available offline,” and both the row and play icon open the saved copy. Queued/downloading rows show status instead of another download button; paused and interrupted rows offer resume or retry.
- Top-10 AniList trending fetch, artwork, cached trending data with last-update time, six-second rotation and manual navigation. Automatic motion is disabled for Reduce Motion and VoiceOver.
- Discover uses an endless poster grid with genre and sort filters, plus a small source-name menu in the top left. AniList supports actual paginated browsing. Animex does not expose a verified paginated browse feed: the app uses working catalog searches to show samples, and full-title search for specific shows. If Animex browsing fails, it shows AniList listings with a visible explanation and checks for Animex episodes when opened. These listings are not a promise of stream availability. Imported module titles resolve through their own source; AniList titles still match through the native Animex adapter.
- Episode provider lookup with Sub/Dub selection and visible HTTP/API errors. Only HTTPS HLS/MP4 media links are accepted; HTML embeds are not presented as video files.
- Full-screen native AVPlayerViewController opens with a black loading screen and no intermediate navigation bar. The close and playback-settings buttons appear over the video when controls are summoned, toggle with a tap, and fade after four seconds; iOS does not allow interactive third-party buttons inside the native transport bar. System audio/subtitle controls, progress persistence, resume and saved-title library remain available.
- Player settings offer auto-play of the next known episode (off by default), preferring a ready offline copy and otherwise the current audio language/provider. AniSkip intro/recap timestamps show a Skip button or auto-skip when enabled; missing timestamps simply leave normal playback. Both preferences persist.
- A Sub/Dub menu in the player switches the current episode while keeping its position. Auto-play retains the selected language and uses an offline copy only when its language matches. Unavailable dubs show an error; switching to audio that is not downloaded needs a connection. For streams with labeled alternate tracks, playback and new downloads select the requested language when available. Provider labels cannot guarantee that an incorrectly tagged source actually contains that language.
- Downloads are grouped by show and sorted by numeric episode, regardless of when each was added or finished. Anime episode rows and Downloads share a watch-progress bar, elapsed/total time, time left, and “Almost finished” or “Watched” labels.
- Single or next-three episode downloads, two concurrent transfers, queue/pause/retry/remove, separate Wi-Fi/cellular background sessions, restored task records, local offline playback, and file deletion that preserves history.
- HLS downloads use Apple's current AVAssetDownloadConfiguration API. Preparation checks whether the asset is playable, protected, and has a finite duration; failures include the native error domain/code when available. Embedded English subtitles are selected when offered. Direct video downloads use background URLSession transfers. Readiness includes a local playable-media check.
- Install compatible Luna/Sora JavaScript source manifests in Sources, then select them from the small source-name menu in Discover.

## Explicitly unfinished

- Other extension formats (Lua, Node packages, extensions needing custom native helpers), external subtitle sidecars, decimal episode specials, and source-specific paginated recommendation APIs are not supported yet.
- Exact per-resolution selection, external subtitle file downloads, multi-season mapping, optional account sync, and background PiP lifecycle polish.
- Live video decoding, actual offline audio/subtitle availability, background completion, interrupted-URL recovery, and device accessibility have not been verified merely by compiling this project.
- Provider request headers use AVURLAsset's widely used `AVURLAssetHTTPHeaderFieldsKey` option, whose portability must be tested. A provider requiring an unsupported transport may need a different integration.
- Retrying an interrupted transfer with no surviving OS task resolves a fresh media link and starts again; it does not promise byte-level resume across changed URLs.
- HLS download support on Simulator is not a substitute for device testing. No backend or proxy is deployed.

## Episode-image contract

Episode previews accept either a public HTTPS URL or an object containing `url` and `headers`:

```json
{
  "thumbnail": {
    "url": "https://images.example.com/episode-3.jpg",
    "headers": {
      "Referer": "https://video.example.com/",
      "User-Agent": "Source-required user agent"
    }
  }
}
```

Metadata and optional Animex episode/source response thumbnails preserve this object through to the native URLSession image loader. A plain thumbnail URL may also carry a sibling `thumbnailHeaders` dictionary. Only explicit image headers are attached: video headers are not copied to unrelated metadata image servers. Cache entries include both URL and headers; redirects do not forward credentials to another origin. Failed/forbidden image URLs now continue to source thumbnails and frame capture rather than blocking fallback. Episode rows keep their numbered placeholder if all preview paths fail.

These lookups run when episode rows appear in a series detail page, not while browsing the library. Header support cannot invent an absent episode image or guarantee that an HLS video supports frame extraction. Imported episode objects also preserve `thumbnail`/`image` headers through this pipeline.

## Device acceptance checklist

Downloaded HLS packages stay at the location supplied by iOS. Kairo resolves filesystem aliases and the system's `/.nofollow/` path form before recording a container-relative path. Packages are used from Downloads inside Kairo; they are not exported as regular videos to Files or Photos. If a previous build saved a failed HLS location in an interrupted queue item, Kairo checks that package at startup and restores the episode only after confirming it is playable offline. If iOS removed the package or its offline check fails, retry the episode.

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


## Installing community sources

1. Open **Sources & preferences → Library source links**.
2. Paste a public HTTPS JSON manifest (for example the Miruro manifest from your source library), then tap **Add source**.
3. Kairo downloads the manifest and script, checks the four supported functions, and saves a validated installation. Discover automatically selects it. Search a title if the module does not return a browse feed for an empty search.
4. Open a title, choose its episode and Sub/Dub provider, then play or download. Download support follows the manifest. Import the same URL again to update; an invalid update preserves the installed code. Remove deletes the source, not your downloads or history.

The supported module interface is `searchResults(keyword)`, `extractDetails(href)`, `extractEpisodes(href)` and `extractStreamUrl(episodeHref)`. Functions may return values or JSON strings synchronously or as promises. Search items use `{title,image,href}`; episodes use `{number,title,href,thumbnail?}`; streams use `{streams:[{title,streamUrl,headers?}]}`. Custom scheme identifiers such as `miruro://` are passed back unchanged, never opened as network addresses. Duplicate episode numbers are collapsed and integer episodes are sorted numerically; unsupported decimal specials are omitted. Multiple seasons sharing episode numbers require a module-specific adapter.

The runner provides browser JavaScript plus `fetch` and `fetchv2(url, headers, method, body)` returning `status`, `ok`, `data`, `text()` and `json()`. Native HTTPS requests preserve explicit headers and use an ephemeral session without app credentials or cookies. A disposable WebKit page blocks direct networking/navigation; request count/size limits and a 65-second operation deadline keep failures bounded. Validation does not allow network calls. Modules execute their own downloaded code and may contact author-operated analytics endpoints; install sources you trust. Installation confirms the interface, not availability of the source's live servers.

Miruro 1.0.4 and Animex 1.1.26 scripts were inspected for this interface. Miruro does not expose a dedicated discovery/pagination function and supplies separate subtitle URLs that the native player does not yet attach; embedded HLS subtitle tracks continue to work. No claim of universal Luna/Sora compatibility or live device playback is implied by a successful installation. Unsupported formats show an error instead of silently appearing installed.
