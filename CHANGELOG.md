# Changelog

All notable changes follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- One-line install that needs no Xcode:
  `curl -fsSL https://vibecom.build/bar/install.sh | bash`. It verifies the
  release checksum and the Developer ID team, quits a running copy, swaps the
  app in place, and opens it. Running it again updates.
- Releases are universal binaries for Apple silicon and Intel Macs, and
  `scripts/release.sh --publish` cuts one locally.

- Public documentation, sample-data screenshots, and security policy.
- CI and notarized-release scaffolding.
- Versioned build metadata and a repository-owned app icon.

### Fixed

- Source builds on a Mac with only the Command Line Tools failed with
  "plugin for module 'SwiftUIMacros' not found". `build-app.sh` now uses an
  installed Xcode automatically, or explains what is missing and points to
  the installer.

- Only one menu bar instance can run per user, even when launching app copies
  from different folders or starting them simultaneously.
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

- Running Claude sessions did not move after auto swap switched accounts:
  - A Codex update rewrote `~/.local/bin/codex`, and the app treated the relay
    as uninstalled and turned Live Handoff off for Claude too. Each provider is
    now checked on its own, and while Live Handoff is on, a link a CLI updater
    replaced is put back, with the updater's newer command kept as the original.
  - Started as `claude` from PATH (how Xirp and terminals start it), the relay
    looked for its lifecycle plugin relative to the working directory, so
    sessions ran without the hooks that report idle turns and could never be
    handed off. It now finds the plugin from its own executable path, and takes
    the conversation ID from `--session-id`/`--resume` up front.
  - The relay kept starting the Claude Code version current when it was
    installed (2.1.280 while 2.1.311 was installed); it now starts the newest.
  - Files left by exited relays are cleared during handoff.
- Sessions started with `CLAUDE_CODE_OAUTH_TOKEN` ignore the Keychain, so no
  switch can move them. The relay prints a warning at launch, Settings names
  where the variable is set, and the activity log records it on every handoff.

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
