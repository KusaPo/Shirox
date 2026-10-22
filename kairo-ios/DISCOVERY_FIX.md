# Native Animex discovery

The old browse implementation searched two-character seed fragments. The live API rejects these with `query must be at least 3 characters`; the catch block then contacted AniList, whose 403 replaced the original error. The fix uses Animex's native `catalogAnime` operation with no search query, `limit`/`offset`, `hasNextPage`, server-side genre filters and POPULARITY/TRENDING/AVERAGE_SCORE sorting. It no longer falls back to a different source without the user's choice.

Verified against the public Animex GraphQL schema and a live Fantasy catalog page at offset 3 on 2026-10-22 UTC: HTTP 200, 3 native source IDs, Fantasy genres and `hasNextPage: true`. Empty-query search was separately rejected; omitting the query returned catalog entries. Public schema source: https://graphql.animex.one/graphql ; website catalog: https://animex.one/catalog . No login or private API key was used.

Requests include standard JSON, user-agent and Animex site context headers. Search explains the three-character minimum before sending a request. Regression tests simulate the observed short-query rejection and AniList 403, verify that browsing never contacts AniList, and check pagination/filter/sort variables.

The floating navigation now owns the root destinations directly, keeping each visited navigation stack alive. A native TabView no longer sits underneath it, preventing child navigation toolbars from revealing a second tab bar. Hidden tabs cannot receive touches or accessibility focus, and the hidden home carousel stops rotating.
