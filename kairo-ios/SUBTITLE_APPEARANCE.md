# Subtitle appearance update

Open the player CC menu, then Subtitle appearance.

- Turn Subtitle background off for words with a small readability shadow.
- Adjust text size from 50% to 200% in 5% steps with a live preview.
- Changes apply immediately and persist between episodes and app launches.
- Reset appearance restores the background and 100% size.
- The settings apply to streamed and downloaded external captions. Native text captions receive AVPlayerItem text style rules; exact rendering depends on the track and iOS.
- Burned-in captions are part of the video and cannot be restyled.

This archive contains updated source, not a newly built IPA. Apple Xcode and simulator tools are unavailable in the editing environment. The new XCTest case is included but has not been executed. Build and run the tests on macOS before distributing a new IPA. Existing scripts/build_ipa.sh builds the unsigned device IPA for sideload signing.
