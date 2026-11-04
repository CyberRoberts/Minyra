# Security and Release Gate

This repository is a **public source preview** of Minyra for Mac. It is not a
certified or notarized production release.

## Confirmed automated checks

The GitHub Actions workflow runs on `macos-15-intel`, builds the app for
`x86_64` with code signing disabled, and executes `--self-test` and
`--agent-e2e-test` on the resulting executable. The E2E test uses simulated
AI replies and local test commands; it does **not** access a real API account.

A green CI run supports only those specific claims, not general application
correctness or safety.

## Outstanding acceptance checks

- [ ] Run the GUI interactively on a real Intel Mac with macOS 12.
- [ ] Test first launch, settings, project selection, file permissions, task
      completion/stop, recovery from errors, and CPU/memory use.
- [ ] Verify live API connectivity with an owner's test credentials, without
      recording or publishing keys, responses, or personal projects.
- [ ] Review permission and command-execution boundaries. This app has **not**
      completed Apple App Sandbox certification.
- [ ] Apple Developer ID signing, notarization and Gatekeeper verification are
      **not** included in this preview.
- [ ] Review current security/privacy statements before any stable release.

## Public-code and asset boundary

The source tree intentionally excludes private Git history, personal settings,
API credentials, official Mini mascot images and Live2D assets. The public
build generates an MIT-licensed generic placeholder icon. The official
character/brand artwork is **not** covered by the MIT source-code license.

Do not upload personal project trees, API keys, screenshots that disclose keys,
or crash logs with secrets to GitHub issues. A credential exposed in Git history
or CI logs should be rotated; deleting the current file is insufficient.

## Unsigned preview distribution

The preview ZIP contains an unsigned `Minyra for Mac.app` built on GitHub's
Intel macOS runner. It is **not** a notarized Mac installer. macOS may warn or
block execution. Users should inspect the source and only open software they
trust; do not turn off Gatekeeper system-wide. Check the accompanying SHA256
checksum before relying on a downloaded file.

## Release labels

- `v1.0.0-preview.1`: unsigned source-built **prerelease**, NOT stable.
- Future stable releases require the outstanding acceptance checks above.
- Feature scope is frozen; release engineering does not add product features.
