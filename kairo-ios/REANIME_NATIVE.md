# ReAnime native media gateway (prototype)

Kairo's built-in ReAnime catalog lists episodes and HD-1/HD-2 sub/dub servers. The site's API gives FlixCloud **embed pages**, not an iOS media URL. This branch changes playback to the existing `AVPlayer` screen and routes downloads through `AVAssetDownloadURLSession`. It requires the separate HTTPS gateway in `reanime-gateway/` to resolve and serve standard HLS. It is not a finished, device-verified release.

## Deploy the gateway

The service needs Node 20+ (or the supplied Dockerfile), a stable HTTPS origin, and enough bandwidth for video. Deploy the `reanime-gateway` directory to your own persistent Node/Docker hosting, set:

- `PUBLIC_ORIGIN` = the exact public HTTPS origin, such as `https://media.example.com` (no path)
- `GATEWAY_SECRET` = at least 32 random characters, stable across restarts; changing it invalidates in-progress download URLs
- `GATEWAY_ACCESS_KEY` = at least 24 random characters, different from the secret
- `PORT` = the hosting platform's HTTP port (defaults to 8080)

Install with `npm ci`, run `npm test`, then `npm start`. The health route is `/health`. Configure HTTPS at your hosting provider or reverse proxy; do not set `PUBLIC_ORIGIN` to localhost for a phone. The resolver endpoint is `GET /resolve?embed=<encoded FlixCloud URL>`, with the `X-Kairo-Access` header. It returns `{ "url": "https://<same origin>/hls/master.m3u8?t=..." }` only after fetching and checking the first playlist. Ticketed playlist and segment URLs work without a header so iOS background downloads can fetch them.

In Kairo, open **Sources & preferences → ReAnime native media**, paste the HTTPS origin and access key, then choose ReAnime in Discover. Choose an episode and a server; the normal Kairo player opens. The episode download button queues the same provider through the existing offline download manager. A downloaded episode uses the local AVFoundation asset afterward.

## Verification before release

1. Confirm HD-1 and HD-2 resolve for an actual sub and dub episode. The source's WASM/token and playlist formats can change without notice.
2. Confirm each gateway HLS URL has a standard master and child playlist, and that segment bytes play in `AVPlayer` on an iPhone.
3. Download an entire episode on the iPhone, force quit Kairo while downloading, relaunch, and play the saved episode with network disabled.
4. Confirm seek, subtitles/audio, auto-next, and retry after an expired media URL. Some subtitle tracks are external files and are not yet packaged with downloads.

The gateway currently holds signed URLs for four hours; very slow downloads may expire and need a retry. It buffers media segments in memory. Hosting bandwidth and any applicable site permissions are the deployer's responsibility. A native player build should not be distributed as a working ReAnime release until these live checks pass.
