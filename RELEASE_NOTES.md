# Minyra for Mac — v1.0.0 Preview 1

Development **prerelease** of the public Swift/Xcode source build for
Intel Macs. This is **not** the branded private build and is not a
macOS-certified production release.

- Build target: Intel `x86_64`, macOS 12+ deployment target.
- Build verification: GitHub Actions on `macos-15-intel`.
- Automated checks: `--self-test` and mock-model `--agent-e2e-test`.
- Packaging: an unsigned `.app` inside a ZIP, plus SHA256 checksums.
- License: MIT for public code and generic icon only; official purple
  cat-ear Mini artwork and Live2D models are excluded.

**Not yet verified:** interactive GUI on macOS 12, real-model API sessions,
Apple App Sandbox certification, Developer ID signing and notarization.

To run from source, see [README](README.md).
For limitations, see [Security and Release Gate](SECURITY_AND_RELEASE_GATE.md).
