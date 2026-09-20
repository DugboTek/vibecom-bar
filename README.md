<div align="center">

<img src="Resources/AppIcon.png" width="104" alt="Vibecom Bar app icon" />

# vibecom bar

**Every Claude Code and Codex account. One native Mac menu.**

Know what is available, what resets next, and which login your CLI will use
before the work gets interrupted.

[![CI](https://github.com/DugboTek/vibecom-bar/actions/workflows/ci.yml/badge.svg)](https://github.com/DugboTek/vibecom-bar/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/DugboTek/vibecom-bar?display_name=tag&sort=semver)](https://github.com/DugboTek/vibecom-bar/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/DugboTek/vibecom-bar/total?label=downloads)](https://github.com/DugboTek/vibecom-bar/releases)
[![GitHub stars](https://img.shields.io/github/stars/DugboTek/vibecom-bar?style=flat&logo=github&label=stars)](https://github.com/DugboTek/vibecom-bar/stargazers)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-111827?logo=apple)](https://support.apple.com/macos)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](Package.swift)
[![MIT](https://img.shields.io/badge/license-MIT-2563EB)](LICENSE)

[Website](https://vibecom.build/bar) · [Get started](docs/getting-started.md) ·
[Security model](docs/security-model.md) · [Troubleshooting](docs/troubleshooting.md) ·
[Request a feature](https://github.com/DugboTek/vibecom-bar/issues/new?template=feature.yml)

</div>

---

<p align="center">
  <a href="https://vibecom.build/bar"><img src="docs/assets/overview.gif" alt="Vibecom Bar showing multiple Claude Code and Codex accounts, usage windows, and the add-account flow" width="620" /></a>
</p>

<p align="center"><sub>Real interface, sample accounts. No credentials or live provider data appear in this recording.</sub></p>

> [!IMPORTANT]
> The source is public now. The first signed and notarized binary release is
> being prepared. Until it appears on the
> [Releases page](https://github.com/DugboTek/vibecom-bar/releases), build the
> app locally using the two commands below.

## The switchboard your CLIs forgot

Claude Code and Codex each understand one active login. That works until you
have a personal account, a work account, a side-project account, and no useful
way to see which one is about to hit a limit.

Vibecom Bar turns that invisible state into a small, deliberate control panel:

| See | Decide | Keep |
|---|---|---|
| Every saved Claude and Codex account | Which account each CLI uses next | Credentials protected by macOS Keychain |
| Five-hour, weekly, and provider reset windows | When to switch before a limit interrupts work | Prompts, responses, and source code on your Mac |
| Live tokens/minute and today/weekly totals | Whether a spike is real work or a runaway session | Provider logins independent from vibecom.build |
| API-equivalent cost by model and tool | Where your local usage is actually going | The last good reading during provider outages |

No browser dashboard. No second copy of your conversations. No background
telemetry service. It is a Swift menu-bar app reading provider usage and the
token counters already present in local CLI transcripts.

## Install

### Build from source today

```bash
git clone https://github.com/DugboTek/vibecom-bar.git
cd vibecom-bar
./scripts/build-app.sh
open "Vibecom Bar.app"
```

You need macOS 14 or newer and at least one of the `claude` or `codex` CLIs.
Open the cloud in your menu bar, choose **Add account**, and follow the guided
login. The first useful screen appears in under a minute.

### Signed release

When `v1.0.0` is published, the release workflow will Developer ID sign the
app, enable the hardened runtime, submit it to Apple for notarization, staple
the ticket, verify Gatekeeper, and publish a SHA-256 checksum beside the ZIP.

The installer will then be:

```bash
curl -fsSL https://raw.githubusercontent.com/DugboTek/vibecom-bar/main/scripts/install.sh | bash
```

Homebrew Cask follows the first notarized release:

```bash
brew install --cask dugbotek/tap/vibecom-bar
```

> [!TIP]
> Want to inspect every step first? Read
> [`scripts/install.sh`](scripts/install.sh), then follow the
> [getting-started guide](docs/getting-started.md).

## What the menu knows

| Capability | Claude Code | Codex |
|---|:---:|:---:|
| Multiple saved accounts | ✓ | ✓ |
| Subscription usage windows | ✓ | ✓ |
| Reset time and countdown | ✓ | ✓ |
| One-click active-account switch | ✓ | ✓ |
| Local token totals and live rate | ✓ | ✓ |
| Model-level API-equivalent cost | ✓ | ✓ |
| Safe token renewal for inactive accounts | ✓ | ✓ |

Claude's *currently active* login is intentionally different: Claude Code
owns and renews that credential. Vibecom Bar does not rotate it behind
Claude's back.

## The Keychain rule that prevents prompt loops

The original bug behind this project mattered: if a second app repeatedly
reads or rewrites Claude Code's live Keychain item, macOS can ask for the
Keychain password over and over while Claude appears to fall out of login.

Vibecom Bar uses a hard boundary instead:

```text
                          normal refresh
app-owned account item ───────────────────────► usage endpoint
          │
          └── encrypted by macOS Keychain

Claude Code-credentials ◄── explicit “Use this account” only
          ▲
          └── owned and renewed by Claude Code
```

- Each saved account gets its own app-owned Keychain item.
- Periodic refresh performs **zero reads** of `Claude Code-credentials`.
- The live Claude item is touched only after you explicitly click **Use**.
- Codex keeps its live login in `~/.codex/auth.json`; unrelated fields survive
  account switches and token renewal.
- Local account metadata and preferences contain no OAuth secrets.

Removing Keychain would not remove the need to protect refresh tokens. It
would only replace an operating-system security boundary with a plaintext file
or an app-specific encryption key that must itself be stored somewhere.

Read the full [security model](docs/security-model.md) and report credential
issues through [private vulnerability reporting](SECURITY.md), not a public
issue.

## Prove the important parts

The default suite is offline. It never contacts Anthropic or OpenAI and never
opens the real Keychain.

```bash
swift test
```

The 171 tests cover more than formatting and happy paths:

- A refresh regression test fails if the app reads Claude's live credential.
- Vault tests prove account secrets and metadata stay in separate stores.
- Switching tests preserve unrelated Claude configuration and Codex auth data.
- Transcript fixtures contain message text that must never enter token output.
- Request tests lock provider endpoints, headers, scopes, and renewal shapes.
- Snapshot tooling uses the real interface, while theme tests lock its brand tokens.

Live integration checks exist, but each one requires an explicit environment
flag because token renewal can rotate a real refresh token. See
[CONTRIBUTING.md](CONTRIBUTING.md) before running one.

## Under the menu

```text
VibecomBar                 SwiftUI + AppKit menu-bar interface
       │
       ├── AccountMonitor  fetches usage and classifies provider failures
       ├── AccountVault    separates account metadata from Keychain secrets
       ├── AccountActivator writes the login selected by the user
       └── TokenLedger     counts local JSONL usage without retaining content

Provider APIs              subscription windows and identity
Local CLI transcripts      token counters, model, timestamp
macOS Keychain             OAuth credentials only
Application Support        labels, preferences, cached non-secret state
```

Vibecom Bar calls the same internal provider endpoints used by the CLIs:

| Purpose | Endpoint |
|---|---|
| Claude usage | `GET api.anthropic.com/api/oauth/usage` |
| Claude renewal | `POST console.anthropic.com/v1/oauth/token` |
| Claude identity | `GET api.anthropic.com/api/oauth/profile` |
| Codex usage | `GET chatgpt.com/backend-api/wham/usage` |
| Codex renewal | `POST auth.openai.com/oauth/token` |

These endpoints are undocumented and can change. The app treats provider
failures as display state, keeps the last good reading, and never turns an
outage into credential destruction.

## Screens, light and dark

| Accounts | Add an account |
|---|---|
| <img src="docs/assets/accounts-light.png" alt="Vibecom Bar account usage in light mode" width="420" /> | <img src="docs/assets/add-account.png" alt="Vibecom Bar guided add-account flow" width="420" /> |

<details>
<summary><b>See the dark appearance</b></summary>

<br />

<p align="center"><img src="docs/assets/accounts-dark.png" alt="Vibecom Bar account usage in dark mode" width="520" /></p>

</details>

## Documentation

| Read this | When you need it |
|---|---|
| [Get started](docs/getting-started.md) | Install the app and save the first Claude or Codex account |
| [Security model](docs/security-model.md) | Understand every storage boundary and Keychain interaction |
| [Troubleshooting](docs/troubleshooting.md) | Fix login, usage, menu visibility, or password-prompt problems |
| [Contributing](CONTRIBUTING.md) | Build, test, snapshot, sign, notarize, or prepare a release |
| [Security policy](SECURITY.md) | Report a vulnerability without publishing credential details |
| [Support](SUPPORT.md) | Pick the right public or private help channel |
| [Changelog](CHANGELOG.md) | See what changed between releases |

## Contributing

Issues, focused pull requests, and security reviews are welcome.

```bash
git clone https://github.com/DugboTek/vibecom-bar.git
cd vibecom-bar
swift test
swift build
```

Before opening a PR, read [CONTRIBUTING.md](CONTRIBUTING.md). CI repeats the
offline suite and a clean release build on macOS. `main` requires that check,
linear history, and resolved review conversations.

---

<div align="center">

Built for the awkward moment when “which account am I on?” becomes
infrastructure.

[vibecom.build/bar](https://vibecom.build/bar) · [MIT](LICENSE) © 2026 DugboTek

</div>
