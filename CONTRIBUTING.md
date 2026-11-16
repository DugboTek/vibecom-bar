# Contributing to vibecom bar

## Set up

You need macOS 14 or newer and Xcode 16 or newer. The Command Line Tools
alone cannot build the app because SwiftUI's macros ship only with Xcode.

```bash
git clone https://github.com/DugboTek/vibecom-bar.git
cd vibecom-bar
swift test
swift run VibecomBar
```

`swift run` is useful for UI work but has an ad-hoc identity. Use
`./scripts/build-app.sh` when testing Keychain behavior so macOS sees a stable
signature.

## Tests

Run the offline suite before every pull request:

```bash
swift test
```

Live checks are opt-in because they use the current machine's provider login:

```bash
VIBECOM_LIVE=1 swift test --filter LiveIntegrationTests
VIBECOM_LIVE_RENEW=1 swift test --filter LiveRenewalTests
VIBECOM_PARITY_CLAUDE=/path/to/vibecom swift test --filter LiveParityTests
```

`VIBECOM_LIVE_RENEW` may rotate a real refresh token. Never enable it in CI.

## Keychain rules

- Never log credential data, even in debug builds.
- Never read `Claude Code-credentials` from a timer or ordinary refresh.
- Never create or relabel Claude Code's live Keychain item.
- Store saved accounts only under `build.vibecom.bar.v2.account.<uuid>`.
- Store Compass tokens only under `build.vibecom.bar.v2.servetoken.<uuid>`, and
  never write anything but a setup-token to the served file: no refresh
  token, no OAuth JSON, never Claude Code's live item.
- Add a regression test for every Keychain prompt or logout bug.

## Screenshots

The snapshot mode uses sample data and does not read credentials:

```bash
swift build -c release
.build/release/VibecomBar --snapshot accounts docs/assets/accounts-light.png
.build/release/VibecomBar --snapshot accounts docs/assets/accounts-dark.png --dark
.build/release/VibecomBar --snapshot add docs/assets/add-account.png
```

## Pull requests

Keep changes focused, describe user-visible behavior, and include the exact
test command and result. Never commit `.build`, the app bundle, credentials,
provider responses containing personal data, or local diagnostic traces.

## Releases

1. Update `VERSION` and `CHANGELOG.md`.
2. Run `swift test` and `./scripts/build-app.sh` locally.
3. Merge to `main`.
4. On a Mac with the Developer ID Application certificate, run
   `./scripts/release.sh --publish`. It builds a universal (Apple silicon and
   Intel) app with the hardened runtime, notarizes and staples it when
   notarization credentials are set (see the script header), zips it, writes
   the SHA-256, and creates the `v$VERSION` GitHub release.
   `VIBECOM_ALLOW_UNNOTARIZED=1` ships a signed-only build; `install.sh`
   installs it without Gatekeeper prompts because curl downloads are not
   quarantined.
5. Check that `curl -fsSL https://vibecom.build/bar/install.sh | bash`
   installs the new version.

Pushing a `v*` tag also runs `.github/workflows/release.yml`, which signs,
notarizes, and publishes from CI once the secrets it lists are set; without
them it only runs the tests. Fork pull requests never receive the secrets.
