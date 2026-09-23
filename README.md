# ReAnime for ShiroX — beta 0.1.0

Created September 22, 2026. Unofficial community module; not affiliated with
ShiroX, ReAnime, or the video hosts.

## What is included

`modules/reanime-sub.json` is the Japanese-audio/subtitle source.
`modules/reanime-dub.json` is the English-dub source. Install either or both.
Each JSON includes its own JavaScript, so the one-file installation method does
not require hosting a separate JavaScript file. The `.js` files are also included
for inspection and conventional hosting.

The module implements search, title details, episode lists, automatic server
fallback, HLS/MP4 discovery, media-link validation, and subtitle metadata. A
subtitle track can only be offered when the player exposes it. English is
selected when a track is clearly labeled English; other tracks remain available
in ShiroX's subtitle menu.

## Important testing status

This is a **beta**, not a confirmed-working live release. The module was checked
against ShiroX's public module/runtime source and a current public ReAnime
integration. The included local tests use **invented, simulated API and player
responses**. They check code behavior, not ReAnime's availability, real browser
capture, or video playback on an iPhone.

I could not make a successful live ReAnime API request from the research
environment, and did not run ShiroX on an iOS device. That does not establish that
the website is down. An installed app build or a changed website/player can
require adjustments.

## Install: one hosted JSON file

**A ChatGPT download link is not a ShiroX import URL.** ShiroX's documented import
flow is Settings → Modules, using a URL to raw JSON. The download has not been
published or uploaded to an account for you.

1. Extract this ZIP. Choose `modules/reanime-sub.json` or
   `modules/reanime-dub.json`.
2. Upload that JSON file to your own GitHub repository or another HTTPS host that
   serves the file itself, without login. On GitHub, open the uploaded file and
   use **Raw** to obtain its direct URL. Do not use the GitHub `blob` page URL.
3. In ShiroX, open **Settings → Modules**, use the module-add control, and paste
   that raw JSON URL. Select the installed ReAnime source, then search for a
   title. Repeat with the other JSON to install both audio choices.

The one-file manifests deliberately use `scriptContent` plus a `data:`
`scriptUrl` containing the identical code. Current ShiroX source accepts the
cached-script field and runs it; no fake public JavaScript hosting URL or
placeholder is used. This convenience packaging is **not device-tested** and
is ShiroX-specific. A module appearing in the list alone does not establish that
its script or playback works.

## Conventional two-file installation (more portable)

Use this route when your ShiroX build does not accept the embedded manifest, or
when maintaining a conventional hosted module repository.

On a computer with Node.js, run this in the extracted directory, replacing the
example folder URL with the actual public folder where you will upload files:

```sh
node build.cjs https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPOSITORY/main
```

The command creates `hosted/reanime-sub.json`, `hosted/reanime-sub.js`,
`hosted/reanime-dub.json`, and `hosted/reanime-dub.js`. It prints the JSON URLs
that will work **after** you upload those files to the specified location.
It does not create a repository, upload files, or publish anything.

Upload the desired JSON and its matching JS, then import the JSON's raw URL in
ShiroX. Both audio variants can be installed. Rebuilding without a URL recreates
the one-file manifests:

```sh
node build.cjs
```

## How playback is implemented

Search and metadata use ReAnime's `/api/v1/` interfaces. Episode server discovery
uses its `/api/watch/` route and, when an AniList ID is available, its `/api/flix/`
route. SUB and DUB are never silently substituted for each other.

The resolver loads an eligible embedded video player through ShiroX's built-in
`networkFetch` browser bridge. It collects HLS/MP4 URLs exposed by the player's
normal execution, verifies a candidate, and returns ShiroX's stream/subtitle
JSON shape. It does **not** implement the third-party host's changing decryption
algorithm or require a separately deployed API server.

It prioritizes HD-2, then HD-1, and attempts up to three eligible servers. It
returns the first verified usable server rather than populating every server in
the player. HLS master playlists are preferred; quality availability is whatever
the server provides, not a guaranteed resolution. Sources with extensionless
media URLs, players that do not expose a supported video request, or unsupported
codecs can fail. Media verification does not prove every segment can be played.

## Troubleshooting

- **Import fails:** confirm the URL opens raw JSON, not an HTML file-preview page
  or login page. Use the conventional two-file build when embedded-script
  packaging is not accepted by your installed app.
- **Search reports HTTP 403 / 429 or a non-JSON response:** complete a source
  verification flow only when ShiroX offers it; otherwise check the site in your
  browser and retry later. This module does not solve verification challenges.
- **Titles load but playback fails:** the embedded player, app's browser bridge,
  or CDN requirements may have changed. Verify that the same episode and audio
  choice play on the site. Check **Settings → App Logs** for `[ReAnime ...]`
  messages. The logs do not intentionally print signed video URLs or cookies.
- **No English subtitles:** check the subtitle menu. Not all servers publish an
  external English track. Hard-subbed video does not need a separate subtitle
  track. Subtitle parsing and URL delivery are implemented; every subtitle format
  has not been device-tested.
- **Dub has fewer episodes:** the source filters by ReAnime's reported dub count;
  it does not assume that every subbed episode has a dub.
- **Large series:** the source requests up to 2,000 episode records, matching the
  inspected integration. It raises an error when the response advertises another
  page. A changed/undocumented server-side cap may still require updating it.
- **Switching audio for a saved show:** select the other source and choose that
  source's title/episode result. A saved episode URL preserves its audio choice.

## Privacy and limitations

The module has no analytics, user-account access, paid dependency, or additional
proxy/API service. Direct API requests go to ReAnime; player, video, and subtitle
requests go to the hosts exposed by that site. Embedded pages may make their own
requests, including advertising requests. The module filters obvious ad media
from playback candidates, but it is **not** a browser ad blocker.

It does not forward ShiroX's unscoped browser-cookie collection to unrelated
hosts. Some cookie- or user-agent-bound streams may therefore need app-specific
support. It does not intentionally bypass ShiroX's host/content filters or a
site's user-verification prompts. Use it only for content you are authorized to
access.

## Reproduce the checks

No npm installation is required. Tests need Node.js 18+ with `node:test`.

```sh
node --check reanime-core.js
node --test test.cjs manifest-test.cjs
```

See `test-results.txt` for the run included with this package. See `SOURCES.md`
for the public technical references. These checks are intentionally separated
from a live, end-to-end device test, which has not been performed.
