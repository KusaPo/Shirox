# Technical references

Inspected September 22, 2026. These URLs point to upstream source that can change.
API paths and interface shapes were used as interoperability references. The
module is an original integration, not a copied or modified upstream extractor.

## ShiroX: installation and module contract

- Project README; Settings → Modules and raw JSON manifest import:
  https://github.com/xibrox/Shirox
- Manifest decoding, including `scriptContent` and `scriptUrl`:
  https://raw.githubusercontent.com/xibrox/Shirox/refs/heads/main/Shirox/Models/ModuleDefinition.swift
- Module import and cache handling:
  https://raw.githubusercontent.com/xibrox/Shirox/refs/heads/main/Shirox/Services/ModuleManager.swift
- JS context, cached-script execution, `fetchv2` positional arguments:
  https://raw.githubusercontent.com/xibrox/Shirox/refs/heads/main/Shirox/Services/JSEngine.swift
- Secondary module runner, search/episode fields, and Promise handling:
  https://raw.githubusercontent.com/xibrox/Shirox/refs/heads/main/Shirox/Services/ModuleJSRunner.swift
- Stream and subtitle result parsing:
  https://raw.githubusercontent.com/xibrox/Shirox/refs/heads/main/Shirox/Services/JSEngine%2BStreams.swift
- Title details and episode parsing:
  https://raw.githubusercontent.com/xibrox/Shirox/refs/heads/main/Shirox/Services/JSEngine%2BDetails.swift
- Built-in browser-based network capture, its options, and returned request list:
  https://raw.githubusercontent.com/xibrox/Shirox/refs/heads/main/Shirox/Services/NetworkFetch.swift

## ReAnime integration behavior

- Public Anivexa ReAnime provider: search, details, episodes, server paths, audio
  labels and server priorities:
  https://raw.githubusercontent.com/walterwhite-69/Anivexa-API/main/providers/reanime.js
- Public host extractor, inspected to understand why a static HTML-only stream
  scraper is insufficient. Its crypto/decryption implementation is NOT bundled
  or reimplemented in this module:
  https://raw.githubusercontent.com/walterwhite-69/Anivexa-API/main/extractors/flixcloud.js

## Evidence boundaries

The ShiroX runtime contracts were read directly from its source code. ReAnime's
response schemas were inferred from the maintained integration above, not from a
successful fresh API response in this environment. The host player runs inside
ShiroX's native browser capture, not in the module's JavaScriptCore context.
A successful local mock test is not evidence of a currently functioning website
endpoint or iOS playback.
