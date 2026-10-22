# Episode names and previews

Kairo now asks Anira's mapped episode endpoint using a verified AniList ID (or MAL ID when AniList is absent), before falling back to existing AniList streaming metadata and Jikan episode titles. This follows the public API strategy observed in xibrox/Shirox at f234a204d9ab72c4514c25f1f821144e32b5e142, Services/AniListService.swift. The adapter is original Kairo code; it does not copy upstream API credentials or require a TMDB/TVDB key.

Episodes match the explicit relative `episode` field, never array position or cross-season absolute numbers. Generic titles remain eligible for title fallback. Available names and images survive an optional provider failure; an error banner is shown only when no usable details could be recovered. Successful mapped responses are cached for 15 minutes, including when another provider is down. Missing mappings and failed requests are not cached as successful responses.

Offline HLS frame capture now uses the same protected loopback playback route as the player. An episode-specific still is preferred; source/video frame capture remains the fallback. No series cover is passed off as an episode still. Playback/source download behavior and source episode counts are unchanged.

Live investigation, October 22, 2026: Animex identifies Firefly Wedding as AniList 205909 / MAL 63293. Anira returns episode 1, “An Unwanted Repayment”, and episode 2, “Tennyo Island”; both image endpoints returned HTTP 200 image/jpeg. Its episodes 3 and 4 have null names/images and October 23/30 airdates. Jikan returned HTTP 503. Thus the first two rows can be enriched independently; future entries correctly retain placeholders. No metadata is invented and metadata does not imply an episode is playable.

Regression tests cover independent-provider outage, shuffled relative/absolute numbering, unpublished details, malformed episode numbers, generic titles, and preserving artwork while filling titles. CI builds the device IPA and runs simulator tests. Physical-device preview rendering still requires checking after sideloading.
