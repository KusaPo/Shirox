# Subtitle appearance

Open the player CC menu, then **Subtitle appearance**.

- Turn Subtitle background off for words with a small readability shadow.
- Adjust text size from 50% to 200% in 5% steps with a live preview.
- Changes apply immediately and persist between episodes and app launches.
- Reset appearance restores the background and 100% size.
- Streamed and downloaded external captions share the same preferences. Native text caption tracks receive AVPlayerItem text style rules; exact rendering depends on the track and iOS.
- Burned-in captions remain part of the video and cannot be restyled.

The existing `.github/workflows/kairo-ios.yml` workflow builds the device IPA and runs the simulator tests. `testSubtitleAppearanceChangesExistingCaptionWithoutReplacingPlayer` checks background removal, live font scaling, resetting defaults, caption visibility, and retaining the same player. No new repository, hosted service, or separate build system is required.
