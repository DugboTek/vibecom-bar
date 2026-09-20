# vibecom bar

Every Claude Code and Codex account you own, and how much of each plan is left,
in one menu bar drop-down. Switch the account a CLI uses with one click, without
logging anything out.

Part of [vibecom](https://vibecom.build) — the same palette, the same voice.
Unlike the vibecom CLI, this app sends nothing anywhere: account logins stay in
your Mac's keychain and are only ever used to ask the provider about your own
limits.

## What it shows

**Tokens, live.** Today's tokens across every Claude Code and Codex session on
this Mac, what they would cost at API list prices, the rate right now, an
hour-by-hour chart, the split between the two CLIs, the last seven days and the
busiest model. It is read from the transcripts the CLIs already write, using a
port of vibecom's own counter (`cli/src/transcripts.ts` and `pricing.ts`) —
checked token-for-token against it on real transcripts. Nothing is uploaded.

**Limits, per account.** Whatever each provider reports:

| Provider | Windows |
|---|---|
| Claude Code | 5-hour session, weekly (all models), weekly per model when the plan has one |
| Codex | weekly, the shorter session window when the plan has one, and how many limit resets the account can spend |

Claude limits come from the same `limits` list Claude Code's `/usage` screen
renders, so the two always agree. Each window shows how much is spent and a
countdown to its reset (exact time on hover); each account also says when its
most pressing limit resets, or when a spent account is usable again. The account each CLI would use right now is marked **in
use**; the rest are one click away.

The menu bar itself shows the signed-in accounts (`CC 20% · CX 99%`), the single
account closest to its limit, today's tokens (`1.3B`), or just the icon.

## Install

```bash
./scripts/build-app.sh
open "Vibecom Bar.app"          # or move it to /Applications first
```

Requires macOS 14+ and the `claude` and `codex` CLIs. The build script signs
with your Developer ID (or Apple Development) certificate when one is installed.
That matters: the keychain ties "Always Allow" to the app's signing identity. An
ad-hoc signature changes on every build, so each rebuild would look like a new
app and every saved login would prompt again. Set `VIBECOM_SIGN_IDENTITY` to
choose a certificate.

## Adding accounts

Two ways, both in **Add account**:

- **Sign in to another account** — opens Terminal and runs the sign-in under its
  own config folder (`CLAUDE_CONFIG_DIR` / `CODEX_HOME`). The account you are
  using right now stays signed in. As soon as the new login lands, vibecom bar
  captures it and the Terminal window can be closed.
- **Capture the account already signed in** — saves whoever the CLI is signed in
  as at this moment. The quickest way to bring in the account you use today.

Repeat per account. Rename or remove any of them by right-clicking its row.

**macOS asks for keychain access once per saved login** — choose **Always
Allow**. vibecom bar reads each of its own saved logins once per launch and keeps
it in memory, and checks Claude Code's signed-in login once per refresh, so
there is nothing to keep prompting about. Reading Claude Code's own login
prompts once too: it belongs to the `claude` binary, and anything else reading
it needs your say-so. Codex keeps its login in a file, so it never prompts.

### `claude setup-token` logins don't work

Tokens from `claude setup-token` lack the `user:profile` scope, and Anthropic's
usage endpoint rejects them. vibecom bar says so rather than showing a blank
row. Use `/login` instead.

## Switching

Switching writes the chosen account's credentials where the CLI looks for them:
the `Claude Code-credentials` keychain item, or `~/.codex/auth.json`. It is
careful about what it touches:

- Claude Code must create its own live keychain item first. vibecom bar only
  updates an existing item's secret bytes; it never creates or relabels that
  item, so Claude remains trusted to read it without prompts.
- MCP server logins live in the same keychain item and are preserved.
- `~/.claude.json` keeps every other setting; only the signed-in account changes.
- The first overwrite of each store is backed up (`auth.json.vibecom-backup`,
  `Claude Code-credentials (vibecom backup)`).

A CLI session already running keeps the account it started with. New sessions
pick up the switch.

## Keeping tokens alive

Saved inactive logins age out, so vibecom bar renews them in the background
using each provider's refresh token and saves what it gets back. It never
renews the Claude login currently in use. Claude refresh tokens rotate, and a
failed write back to Claude Code's keychain after rotation would sign the CLI
out. Recapture the active Claude account when vibecom says its saved login has
expired. Codex uses a normal file, so its active login can be renewed safely.

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
except the provider requests below.

## The endpoints it calls

| Purpose | Endpoint |
|---|---|
| Claude usage | `GET api.anthropic.com/api/oauth/usage` |
| Claude renewal | `POST console.anthropic.com/v1/oauth/token` |
| Claude account name (only when unknown) | `GET api.anthropic.com/api/oauth/profile` |
| Codex usage | `GET chatgpt.com/backend-api/wham/usage` |
| Codex renewal | `POST auth.openai.com/oauth/token` |

These are the same endpoints the CLIs use, and none of them are documented
public APIs. Either provider can change them without notice, in which case a row
shows "Couldn't reach the provider" and keeps the last good reading until the
parser is updated.

## Development

```bash
swift test                                   # 159 tests, no network, no keychain writes outside its own items
swift build && swift run VibecomBar          # run without bundling (no notifications or login item)
./scripts/build-app.sh                       # bundle + sign
```

Live checks against the real providers are opt-in:

```bash
VIBECOM_LIVE=1 swift test --filter LiveIntegrationTests   # read-only
VIBECOM_LIVE_RENEW=1 swift test --filter LiveRenewalTests # rotates a real Codex token
```

Layout snapshots render a page to PNG using sample accounts, so they never touch
the keychain (`--tokens` adds this Mac's real token count):

```bash
.build/release/VibecomBar --snapshot accounts out.png [--dark] [--tokens]
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
| `Pricing.swift` | list prices, mirrored from vibecom's `pricing.ts` and its tests |
| `TokenLedger.swift` | incremental, parallel transcript reading; today / week / hourly / live totals |

`VibecomBar` is the SwiftUI menu bar app on top of it.

## Limits worth knowing

- Usage numbers are whatever the provider reports; there is no local estimate to
  cross-check them against.
- Token cost is an API-equivalent figure, not a bill: subscriptions are not
  charged per token. It is the same number vibecom.build shows.
- Cost in dollars is only populated for some plans, so it is not shown.
- The app polls; it does not watch. Default is every 5 minutes, adjustable
  between 1 and 60.
