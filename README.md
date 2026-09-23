# ReAnime for ShiroX — beta 0.1.1

Unofficial community module for ReAnime, with separate SUB and DUB sources.
Not affiliated with ShiroX, ReAnime, or the video hosts.

## Install or update

Use these **raw JSON URLs** in ShiroX → Settings → Modules:

| Source | Import URL |
| --- | --- |
| SUB | https://raw.githubusercontent.com/KusaPo/Shirox/main/reanime-sub.json |
| DUB | https://raw.githubusercontent.com/KusaPo/Shirox/main/reanime-dub.json |

1. Copy the full URL for the version you want.
2. Open ShiroX → Settings → Modules and use the module-add control.
3. Paste the URL. Install both if you want both audio choices.
4. Select the ReAnime source, search for a title, open its episodes, and play one.

**Already installed 0.1.0?** Use the app's module refresh/update option if available.
Check that the installed version is **0.1.1**. If it remains 0.1.0, remove that
ReAnime module entry and add the same URL again. Reopen the title from the updated
source. Uploading an update to GitHub does not necessarily refresh a cached module.

The repository-root JSON now points to a normal HTTPS JavaScript file beside it.
Keep both the JSON and matching JS hosted. You only import the JSON URL in ShiroX.
Do not paste GitHub file-preview (`github.com/.../blob/...`) URLs into the app.

## What changed in 0.1.1

- Published conventional HTTPS script URLs instead of embedding the entire script
  in the main manifests. `modules/` retains optional embedded copies.
- Flixcloud capture now requests the same `autoPlay=true` option seen on the
  website, waits for a video element, and targets the observed Artplayer Play
  control. It no longer clicks the video element itself, which can toggle pause.
- Progress messages now use ShiroX's General log channel when available.
- Errors report runtime support, server API status, media candidate counts,
  and individual server failures. Final failures are also written as Error logs.
- Diagnostic messages omit URLs so they do not expose signed media links.

This is a compatibility and diagnostics update. It is **not a confirmed fix for
all playback failures**. The original 0.1.0 build was reported to stall while
fetching streams on both audio variants.

## Testing status

**44 local tests pass using synthetic responses.** These validate parsing,
server fallback, audio selection, response validation, packaging, and diagnostics.
They do not prove that an iPhone can play the current video host's streams.

During investigation, the live ReAnime page for Solo Leveling episode 1 loaded
its server choices and a Flixcloud player. The player exposed a blob video source,
but successful video playback was not established in this environment. The
current iPhone import and playback flow still requires device verification.

## If it says fetching streams or no streams

1. Confirm the installed version is 0.1.1 and reopen the episode from that source.
2. Try the same episode and audio choice on ReAnime in your phone's browser.
3. After a failed attempt, inspect ShiroX → Settings → App Logs. Include General
   and Error entries if the app offers log filters. Look for **ReAnime**.
4. Report the anime, episode, SUB/DUB, ShiroX app version, final error text, and
   whether that episode works in your phone's browser. A screenshot is fine.

| Message | What it tells us |
| --- | --- |
| No ReAnime messages at all | The script may not have loaded or been called; confirm the module version and import URL. |
| `networkFetch=false` | This app build lacks the browser capture feature required by this module. |
| Server API HTTP 403 or 429 | A source request was denied or rate limited; complete verification only if ShiroX offers it. |
| Found 0 eligible servers | ReAnime returned no matching audio servers, or its response format changed. |
| Player capture has 0 media candidates | The embedded player did not expose a supported HLS/MP4 link to the app. |
| Media check HTTP error | A captured link was rejected when checked; host headers, expiry, or network access may be involved. |
| Response is not a plain HLS playlist | The host returned another payload; the current native playback integration cannot use it. |
| TVDB artwork request cancelled (`-999`) | An artwork request was cancelled; this alone does not identify a stream failure. |

The module cannot guarantee compatibility with every host, cookie-bound stream,
codec, encrypted/custom playlist response, or future website change. A title
appearing in search does not establish that playback works.

## How it works

Search, details, and episode lists use ReAnime's `/api/v1/` routes. Server lookup
uses `/api/watch/{slug}/{episode}` and, when an AniList ID is available,
`/api/flix/{id}/{episode}`. SUB and DUB are filtered separately.

For each eligible server, ShiroX's `networkFetch` loads the embedded player and
collects its media requests. The module prefers HLS, validates the response, and
returns ShiroX's stream and subtitle result format. It tries HD-2 before HD-1 and
attempts up to three servers. It does not include the host's decryption code or
require a separately deployed API server.

Subtitles are offered when the player exposes suitable tracks. English is
preferred when explicitly labeled. Quality choices depend on the host's playlist;
1080p availability is not guaranteed. Large series currently use a request limit
of 2,000 episode records, and an advertised next page causes an explicit error.

## Files

| File | Purpose |
| --- | --- |
| `reanime-sub.json`, `reanime-dub.json` | Public import manifests. |
| `reanime-sub.js`, `reanime-dub.js` | Hosted scripts used by the main manifests. |
| `reanime-core.js` | Shared source for both audio variants. |
| `modules/` | Generated embedded-script manifests and corresponding JS, retained for tests and optional use. |
| `build.cjs` | Generates the manifests and per-audio scripts. |
| `test.cjs`, `manifest-test.cjs` | Local tests with simulated network responses. |
| `test-results.txt` | Output from the latest local test run. |
| `SOURCES.md` | Upstream interoperability references. |
| `START-HERE.txt` | Short setup instructions. |
| `SHA256SUMS.txt` | SHA-256 file integrity hashes. |

## Build and test

Use Node.js 18 or newer. No npm dependencies are needed.

```sh
node build.cjs
node build.cjs https://raw.githubusercontent.com/KusaPo/Shirox/main
node --check reanime-core.js
node --test test.cjs manifest-test.cjs
```

The first command writes embedded copies to `modules/`. The second writes
conventional files to `hosted/`. Publish the four generated `hosted/` files at
the repository root to maintain the import URLs above. If hosting elsewhere,
replace the base URL with your actual HTTPS folder URL. The build script does
not upload anything. After source edits, rebuild both formats, rerun tests, and
update the published files and hashes together.

## Privacy

The module has no analytics or account login. Requests go to ReAnime and the
player/media/subtitle hosts it returns. Embedded pages may make their own
requests. The module does not intentionally log signed URLs or forward the app's
unscoped browser-cookie collection to unrelated hosts. It is not an ad blocker.
Use content you are authorized to access.
