# Contributing to vibecom bar

## Set up

You need macOS 14 or newer and the Swift toolchain included with current Xcode.

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
3. Merge to `main` and create a matching tag such as `v1.0.0`.
4. The release workflow imports the Developer ID certificate, builds with the
   hardened runtime, submits the ZIP to Apple's notary service, staples the
   ticket, verifies Gatekeeper acceptance, and publishes the ZIP plus checksum.
5. Update the Homebrew tap with the released version and SHA-256 checksum.

The GitHub repository needs the secrets documented in
`.github/workflows/release.yml`. Fork pull requests never receive them.
