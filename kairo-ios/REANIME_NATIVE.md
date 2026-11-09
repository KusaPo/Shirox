# ReAnime on-device native media

ReAnime now works without the former external media gateway. No Mac, Tailscale, Node server, gateway address, or access key is part of normal app use. Select ReAnime, open a title, choose Sub/Dub and an available server, and use Kairo's normal player or download button. Retry an old interrupted download to resolve fresh media URLs.

## Pipeline

- The native catalog API returns FlixCloud episode embeds.
- `ReAnimeNativeResolver` fetches the embed and token response with native URLSession requests. A bundled MIT-licensed JSON5 parser parses serialized metadata as data, not executable page code. A disposable, time-limited WebKit process evaluates only the player's WASM key transform; it never displays or operates a website player. Native CommonCrypto/CryptoKit complete PBKDF2/AES URL resolution. No external resolver is contacted.
- `ReAnimeMedia` decodes encoded playlists and unwraps image-disguised segment payloads. The known FlixCloud, rundowncdn.top, kineticcdn.top, and ignitecdn.top hosts are allowlisted; credentials, insecure URLs, unexpected ports, and lookalike hosts are rejected.
- `ReAnimePlaybackServer` adapts the media on loopback inside the iPhone for AVPlayer. Opaque registered resource IDs and a random per-process capability prevent arbitrary URLs from being requested through this listener. Playlist URLs and HLS key URLs are rewritten; only GET/HEAD and bounded byte ranges are served. Native audio selection, seeking, progress, and existing player controls remain in Kairo.
- Downloads do not point at the loopback listener. Preflight decodes manifests and retrieves HLS keys, then submits original CDN resource URLs to iOS background sessions. Each journaled resource records whether it needs unwrapping. When delivered, the app unwraps first and then applies standard HLS AES-128 decoding before publishing the local episode. This instruction survives app recreation. Existing ordinary HLS jobs decode without the new optional field.

## Validation

Tests cover complete catalog→embed→JSON5→WASM→PBKDF2/AES→native URL resolution with no gateway configured, using synthetic metadata and an independent Node-generated crypto vector. Playback and offline tests use a real short H.264 TS fixture wrapped and encrypted like the site: AVFoundation must recognize the on-device streaming adapter and final offline episode. Host/range rejection and existing background/HLS regressions are included.

A live source probe on November 8, 2026 confirmed that HD-1 returns an encoded master, English/Japanese audio tracks, AES-128 media playlists, and image-wrapped segments on rundowncdn.top. HD-2 used kineticcdn.top; its first segment was also decoded successfully. H-SUB used ignitecdn.top and its first segment decoded successfully as well. Sub prefers the site's H-SUB server (variant 3) when listed, to keep burned-in subtitles in the native player and download. HD-1/HD-2 remain selectable. Earlier gateway code allowed only FlixCloud hosts and therefore rejected those CDN segments. The legacy `reanime-gateway/` folder is retained for diagnostics and is not required by Kairo.

Still verify on a physical iPhone after sideloading: both HD-1/HD-2 and available Sub/Dub tracks, seeking, a full episode download, switching apps/locking during a submitted transfer, and offline playback. Source URLs can expire; retry resolves them again. Force-quitting remains subject to iOS background session rules. Source preparation requires the app in the foreground. Separate ASS subtitle files are not newly packaged or rendered by this change; use H-SUB when available for burned-in subtitles; auto-skip remains dependent on available timestamps. A source/site format change may require an adapter update.
