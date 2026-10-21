# Background episode downloads

Start a download in Kairo. Once its status changes from Resolving/Preparing to Downloading, the app has submitted the episode's complete media batch to iOS. You can switch apps or lock the phone. The existing Wi-Fi-only preference applies to that batch. iOS controls scheduling and may wait for connectivity.

Force-quitting is not supported. Episodes still queued without a resolved media batch wait until Kairo is active to resolve their source links. If a provider expires a signed link, tap retry in Kairo to obtain a new one. Completed segments are reused when their URL, range, encryption and sequence identity still match.

The app uses two stable background URLSession identifiers (Wi-Fi-only and cellular-allowed), with delegate downloads rather than async in-process data tasks. Before submitting tasks, it saves the episode manifests, request headers, encryption information, resource identities and task tokens. It restores those sessions on launch and acknowledges background events only after delegate file handling finishes. Download folders, journal and media use protection that remains accessible after the first device unlock.

All episode resources are submitted in one batch to avoid depending on an app wakeup for each successive segment. Per-host connection limits and earliest start dates pace requests. HTTP 429/503 reschedules outstanding requests for that host after the server cooldown; no error response is written as media. Pausing cancels pending requests while retaining completed segments. Removing also deletes the job. Local manifests are published only when all required video/audio resources are present.

Apple references:
- https://developer.apple.com/documentation/foundation/downloading-files-in-the-background
- https://developer.apple.com/documentation/foundation/urlsessiontask/earliestbegindate

Validation covers durable job encoding, video/audio batch planning, byte ranges, incomplete downloads and rejected error responses, alongside the existing retry/offline-playback tests. A physical iPhone lock/switch test is still required: start an episode, wait for Downloading, lock for several minutes, then reopen and check that progress increased or it finished. Test offline playback afterward. Simulator checks do not prove locked-device behavior with a live provider.

The CI iOS simulator reports “remote session unavailable” when creating a system background download. The same complete-episode delegate/journal integration test runs with an ephemeral session and real local HTTP transfers in CI. A separate background-service test runs on physical iPhones and is explicitly skipped in Simulator; a green simulator run is not evidence of locked-device behavior.

Downloads show a percentage alongside their status, including paused/interrupted progress. Ready episodes show 100%; HLS percentages count completed media resources rather than exact byte totals.
