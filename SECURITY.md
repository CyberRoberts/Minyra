# Security policy

Minyra for Mac can execute AI-proposed changes and project commands after
user authorization. **Only use the coding agent with projects you trust,
and review the permission scope.** The native GUI app has not been certified
as fully protected by Apple's App Sandbox.

## Supported status

Current releases are development/test candidates. CI has simulated model
interactions and local command tests. A successful mock test is not a guarantee
against harmful generated commands or arbitrary third-party project scripts.

## Report a vulnerability

If GitHub's private vulnerability reporting is enabled for this repository,
use its **Security → Report a vulnerability** function. Otherwise contact the
repository maintainer privately through an available nonpublic channel rather
than posting exploit details in a public issue.

Never include real API keys, account identifiers, or sensitive project files
in bug reports. Rotate exposed credentials immediately. Historical Git commits
and GitHub Actions logs can remain visible after content is deleted from the
latest branch.

See [SECURITY_AND_RELEASE_GATE.md](SECURITY_AND_RELEASE_GATE.md) for known
technical limitations.
