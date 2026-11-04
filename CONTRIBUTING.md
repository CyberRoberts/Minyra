# Contributing to Minyra for Mac

Thanks for your interest in Minyra (Mini 酱)!

## Current scope

Minyra 1.0 is **feature-frozen**. Contributions should focus on reproducible
bug fixes, macOS 12 Intel compatibility, tests, performance, build reliability,
translations, and documentation. Please do not add desktop computer control,
browser DOM automation, diff-review tools or undo systems without first
discussing a deliberate scope change.

## Development

- Native SwiftUI/AppKit project: `MinyraForMac.xcodeproj`
- Product name: **Minyra for Mac**; mascot nickname: **Mini 酱**
- Primary support target: Intel Macs, macOS 12+
- The existing local project and API credentials must never be uploaded in
  bug reports or tests.
- Keep new tests deterministic; mock external DeepSeek responses for CI.
- Do not describe CI checks as proof of real macOS 12 GUI reliability.

## Pull requests

Please include a brief problem description, steps to reproduce, the changed
files, testing evidence and any known limitations. Avoid introducing third-party
artwork, model binaries or other nonredistributable assets.

Source contributions are proposed under the repository's MIT code license;
character artwork, branding and third-party components remain outside that
license per [ASSETS_LICENSE.md](ASSETS_LICENSE.md).

## Reporting security issues

Please do not file public issues containing API keys, secrets, or exploit
details. See [SECURITY.md](SECURITY.md).
