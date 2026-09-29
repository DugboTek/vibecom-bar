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
- Switching back to an account that had been in use signed Claude Code out
  ("Login expired"). Claude Code and Codex rotate refresh tokens as they
  renew, and the saved copy was never updated. vibecom bar now saves the
  rotated tokens into the right account on every refresh and before every
  switch, and renews the incoming login first, refusing the switch if it is
  dead instead of handing the CLI a broken login.
- Auto swap never fired. The active account's usage was read with its stale
  saved token, which failed once that token expired, so the 99% mark was
  never seen. For Codex, the active account was matched by exact token and was
  lost as soon as Codex renewed. Both now use the CLI's live login.
- Usage is checked every minute while an active account is above 90%.
- The active account no longer says "Sign in again" when only the CLI's own
  idle token has lapsed.
- vibecom bar used most of a CPU core around the clock ("significant energy"
  in macOS). The token ticker kept animating, with a blur on every digit,
  while the popover was closed, and the token ledger re-read and re-summed a
  week of transcripts every five seconds. The ticker now runs only while the
  popover is open, transcripts are read every minute in the background, and
  each update no longer copies every event.
- Auto swap skipped switch targets whose last usage reading was rate limited
  or unreachable, which is common when the usage endpoint is polled near a
  limit. Only an account that needs signing in is skipped now; the switch
  itself checks the login. Accounts not in use are read at most every 4.5
  minutes, and App Nap no longer stretches the refresh timer while auto swap
  is on.

### Added

- **Settings → Switch accounts at 99%** says why auto swap is or is not
  switching each provider, and **Show activity log** opens
  `~/Library/Logs/VibecomBar/activity.log`: what every refresh saw and every
  switch it tried. It holds labels and percentages, never tokens.

## [1.0.0] - Unreleased

- Monitor multiple Claude Code and Codex accounts from the macOS menu bar.
- Switch CLI accounts while preserving provider configuration and MCP logins.
- Count local transcript tokens and estimate API-equivalent cost.
- Store saved credentials in macOS Keychain.
- Notify at usage thresholds and when limits reset.
