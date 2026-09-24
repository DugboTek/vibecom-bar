# Changelog

All notable changes follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Public documentation, sample-data screenshots, and security policy.
- CI and notarized-release scaffolding.
- Versioned build metadata and a repository-owned app icon.

### Fixed

- **Use** and auto swap failed for every Claude credential over 1 KB, which
  is any login with MCP servers signed in. The switch wrote through the
  `security` password prompt, which keeps only 128 bytes and stalls on longer
  lines. It now writes the way Claude Code does (`-X` hex over `security -i`,
  arguments beyond 4 KB) and verifies the stored bytes afterwards.
- A failed switch is now shown on the accounts page instead of silently
  doing nothing, and a failed auto swap posts a notification.
- Auto swap retries a failed switch every ten minutes instead of giving up
  until the spent account reset.

## [1.0.0] - Unreleased

- Monitor multiple Claude Code and Codex accounts from the macOS menu bar.
- Switch CLI accounts while preserving provider configuration and MCP logins.
- Count local transcript tokens and estimate API-equivalent cost.
- Store saved credentials in macOS Keychain.
- Notify at usage thresholds and when limits reset.
