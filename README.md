# Minyra for Mac

**Minyra for Mac** (Mini 酱) is a native SwiftUI/AppKit AI coding agent.
This repository is a **source-development preview** targeting Intel Macs
with macOS 12 or later. It is not a certified, stable Mac release.

## Source and download

- Source: https://github.com/CyberRoberts/Minyra
- Public preview downloads, when published:
  https://github.com/CyberRoberts/Minyra/releases
- Continuous integration:
  https://github.com/CyberRoberts/Minyra/actions

The `v1.0.0-preview.1` prerelease contains an **unsigned** Mac `.app` in a
ZIP archive, built on GitHub's Intel macOS runner. It is **not** notarized
with Apple Developer ID. macOS may display security warnings. Download and
open the app only if you trust its source; do not disable Gatekeeper
system-wide. The ZIP's SHA256 digest is provided separately.

## Build from source (Intel Mac)

Requirements: Xcode, Python 3 and Pillow 11.3.0.

```bash
git clone https://github.com/CyberRoberts/Minyra.git
cd Minyra
python3 -m pip install Pillow==11.3.0
bash Scripts/build_public.sh
```

Alternatively, open `MinyraForMac.xcodeproj` in Xcode and select the
`MinyraForMac` scheme. The public build generates a **generic** MIT-licensed
code-brackets icon rather than using the private Mini character artwork.

The build script compiles an `x86_64` app and executes `--self-test` and
`--agent-e2e-test`. The E2E test uses **mock AI responses** and does not
call a live model API or read your private API key.

## Known limitations and safety

- GitHub Actions runs on `macos-15-intel`, **not** a real Intel macOS 12
  desktop session.
- Interactive macOS 12 GUI testing and real-model API acceptance are still
  outstanding.
- The app has **not** completed Apple App Sandbox certification.
- The preview is unsigned and not Apple-notarized. Treat it as test software.
- The agent can perform local project operations under user-granted
  permissions. Use only with projects you trust and review permission scope.
- Version 1.0 feature scope is frozen: no desktop/browser control, diff
  review, or undo features are included in this public release.

See [Security and Release Gate](SECURITY_AND_RELEASE_GATE.md),
[Security Policy](SECURITY.md) and [Release Notes](RELEASE_NOTES.md)
for the exact verification boundary.

## License, source boundary and contributions

Source code and public build scripts are under the [MIT license](LICENSE).
The official purple cat-ear Mini mascot, Minyra artwork/branding,
Live2D models, personal settings, private projects, compiled private builds,
and original private Git history are **not included** and are **not**
MIT-licensed. See [Asset Licensing](ASSETS_LICENSE.md).

No personal API keys are distributed. Users configure their own API
credentials locally. See [Contributing](CONTRIBUTING.md) for contribution
guidelines.

中文：Minyra for Mac（Mini 酱）公开 Swift/Xcode 程序源码，采用 MIT 代码许可。
角色原画、紫色猫耳少女形象和 Live2D 模型不随源码开放。
此处提供的是未经 Apple 签名、公证及 macOS 12 实机验收的开发预览版。
