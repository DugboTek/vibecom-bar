# Security policy

vibecom bar handles OAuth credentials, so credential exposure, unexpected
Keychain prompts, account switching mistakes, and unsafe release artifacts are
security issues.

## Report privately

Use GitHub's **Report a vulnerability** button in the repository Security tab.
Do not include access tokens, refresh tokens, Keychain exports, or complete
diagnostic archives in a public issue.

Include:

- the vibecom bar version and macOS version;
- whether the problem affects Claude Code, Codex, or both;
- the action that triggered it;
- redacted logs or screenshots; and
- whether the issue repeats after quitting vibecom bar.

We will acknowledge a report within three business days and keep the report
private until a fix and release plan are ready.

## Supported versions

Security fixes target the newest released version. Until version 1.0 is
published, the `main` branch is the only supported build.

## Release trust

Official binaries are Developer ID signed, notarized by Apple, and published
through GitHub Releases. Each release includes a SHA-256 checksum. Do not
install binaries attached to issues, discussion posts, or third-party mirrors.

For the storage and trust boundaries, read
[How credentials and privacy work](docs/security-model.md).
