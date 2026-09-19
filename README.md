# vibecom bar

Every Claude Code and Codex account you own, and how much of each plan is left,
in one menu bar drop-down. Switch the account a CLI uses with one click, without
logging anything out.

Part of [vibecom](https://vibecom.build) — the same palette, the same voice.
Unlike the vibecom CLI, this app sends nothing anywhere: account logins stay in
your Mac's keychain and are only ever used to ask the provider about your own
limits.

## What it shows

Per account, whatever that provider reports:

| Provider | Windows |
|---|---|
| Claude Code | 5-hour session, weekly (all models), weekly per model when the plan has one |
| Codex | weekly, and the shorter session window when the plan has one |

Each window shows how much is spent, a countdown to its reset, and the exact
reset time on hover. The account each CLI would use right now is marked **in
use**; the rest are one click away.

The menu bar itself shows either the signed-in accounts (`CC 20% · CX 99%`), the
single account closest to its limit, or just the icon.

## Install

```bash
./scripts/build-app.sh
open "Vibecom Bar.app"          # or move it to /Applications first
```

Requires macOS 14+ and the `claude` and `codex` CLIs on your PATH. The build
script ad-hoc signs the bundle, which is what lets macOS deliver its
notifications and register it as a login item.

## Adding accounts

Two ways, both in **Add account**:

- **Sign in to another account** — opens Terminal and runs the sign-in under its
  own config folder (`CLAUDE_CONFIG_DIR` / `CODEX_HOME`). The account you are
  using right now stays signed in. As soon as the new login lands, vibecom bar
  captures it and the Terminal window can be closed.
- **Capture the account already signed in** — saves whoever the CLI is signed in
  as at this moment. The quickest way to bring in the account you use today.

Repeat per account. Rename or remove any of them by right-clicking its row.

**macOS will ask for keychain access the first time** vibecom bar reads Claude
Code's saved login. That is macOS doing its job: the login belongs to the
`claude` binary, and anything else reading it needs your say-so. Choose **Always
Allow** and it stays quiet after that. Codex keeps its login in a file, so it
never prompts.

### `claude setup-token` logins don't work

Tokens from `claude setup-token` lack the `user:profile` scope, and Anthropic's
usage endpoint rejects them. vibecom bar says so rather than showing a blank
row. Use `/login` instead.

## Switching

Switching writes the chosen account's credentials where the CLI looks for them:
the `Claude Code-credentials` keychain item, or `~/.codex/auth.json`. It is
careful about what it touches:

- MCP server logins live in the same keychain item and are preserved.
- `~/.claude.json` keeps every other setting; only the signed-in account changes.
- The first overwrite of each store is backed up (`auth.json.vibecom-backup`,
  `Claude Code-credentials (vibecom backup)`).

A CLI session already running keeps the account it started with. New sessions
pick up the switch.

## Keeping tokens alive

Saved logins age out, so vibecom bar renews them in the background using each
provider's refresh token, and saves what it gets back. When the renewed account
is the one a CLI is signed in as, the renewed token is written through to the
CLI as well — otherwise the CLI would be left holding a token that was rotated
away, and you would be signed out for no reason.

When a refresh token is dead for real, the account says **Sign in again** and
offers the guided sign-in.

## Alerts

- at 80% and 95% of any window, once per threshold per window
- when a spent window resets — the "you can work again" signal
- when an account needs signing in again

## Where things live

| What | Where |
|---|---|
| Account tokens | login keychain, `build.vibecom.bar.account.<uuid>` |
| Account names and order | `~/Library/Application Support/VibecomBar/accounts.json` |
| Settings | `~/Library/Application Support/VibecomBar/preferences.json` |
| Guided sign-in profiles | `~/Library/Application Support/VibecomBar/profiles/<uuid>` |

No tokens are written to any file by this app, and nothing leaves the machine
except the two usage requests below.

## The endpoints it calls

| Purpose | Endpoint |
|---|---|
| Claude usage | `GET api.anthropic.com/api/oauth/usage` |
| Claude renewal | `POST console.anthropic.com/v1/oauth/token` |
| Codex usage | `GET chatgpt.com/backend-api/wham/usage` |
| Codex renewal | `POST auth.openai.com/oauth/token` |

These are the same endpoints the CLIs use, and none of them are documented
public APIs. Either provider can change them without notice, in which case a row
shows "Couldn't reach the provider" and keeps the last good reading until the
parser is updated.

## Development

```bash
swift test                                   # 105 tests, no network, no keychain writes outside its own items
swift build && swift run VibecomBar          # run without bundling (no notifications or login item)
./scripts/build-app.sh                       # bundle + ad-hoc sign
```

Live checks against the real providers are opt-in:

```bash
VIBECOM_LIVE=1 swift test --filter LiveIntegrationTests   # read-only
VIBECOM_LIVE_RENEW=1 swift test --filter LiveRenewalTests # rotates a real Codex token
```

### Layout

`VibecomBarCore` holds everything worth testing and knows nothing about SwiftUI:

| File | Responsibility |
|---|---|
| `Usage.swift` | provider responses → windows and percentages |
| `Credentials.swift` | the credential formats each CLI stores, and the merges that keep the rest of those files intact |
| `Network.swift` | usage requests, token renewal, typed errors |
| `Vault.swift` | the account store, switching, capturing logins |
| `Monitor.swift` | renew-then-read per account, last-good readings, active-account detection |
| `Preferences.swift` | settings, alert rules, guided sign-in commands |
| `Theme.swift` | vibecom's oklch tokens, converted to sRGB |

`VibecomBar` is the SwiftUI menu bar app on top of it.

## Limits worth knowing

- Usage numbers are whatever the provider reports; there is no local estimate to
  cross-check them against.
- Claude reports `utilization` as a fraction on some plans and a percentage on
  others, so anything above 1 is read as a percentage.
- Cost in dollars is only populated for some plans, so it is not shown.
- The app polls; it does not watch. Default is every 5 minutes, adjustable
  between 1 and 60.
