# Troubleshooting vibecom bar

## Repeating Keychain prompts

Routine refreshes read Claude's live Keychain credential only through Apple's
`/usr/bin/security` helper, which Claude's item already trusts, so they should
never cause a prompt.

1. Quit vibecom bar from its power button.
2. Confirm the prompts stop.
3. Open Terminal and run:

   ```bash
   claude auth status --json
   ```

4. If Claude itself still prompts or reports logged out, run:

   ```bash
   claude auth logout
   claude auth login
   ```

5. Reopen the newest signed release of vibecom bar.

Do not delete arbitrary Keychain items. If the prompts continue, file a private
security report with the app version, macOS version, and the name displayed in
the prompt. Never attach tokens or a Keychain export.

## Use or auto swap does not switch accounts

A failed switch is shown in an orange banner at the top of the accounts list,
and auto swap also posts a notification. The banner names the cause:

- **Claude Code isn't signed in on this Mac** — run `claude` once and sign in,
  so Claude Code creates its own Keychain item. vibecom bar never creates it.
- **macOS Keychain didn't respond in time** — unlock the login keychain in
  Keychain Access, then try again.
- **Keychain didn't confirm the new login** — run `claude auth status` to check
  Claude Code is still signed in before trying again.
- **Its saved login has expired** — the account was signed in elsewhere or
  its tokens were rotated before vibecom bar could save them. Sign in to it again
  from **Add Account**. The account in use is left alone.

Auto swap checks usage every minute once the active account passes 90%, and
retries a failed switch every ten minutes while it stays at or above 99%.

**Settings** shows, for Claude Code and Codex, why auto swap is or is not
switching right now: for example "sola@example.com is at 75%; switches at 99%"
or "no other account is ready". **Show activity log** opens
`~/Library/Logs/VibecomBar/activity.log`, which records each account's usage at
every refresh, which account each CLI is signed in to, and every switch
attempted with its result. It never contains tokens; attach it to a bug report
if auto swap misbehaves.

## A running session stayed on the old account

The activity log records, after each switch, how many running sessions were
asked to move (`Live Handoff: asked N running … sessions to move`). If a
session did not move:

- **Live Handoff is off** — turn it on in Settings. Only sessions started after
  it is on go through the relay; resume older ones with **Adopt an existing
  session**.
- **`CLAUDE_CODE_OAUTH_TOKEN` is set** — Claude Code then uses that token and
  ignores the Keychain, so no switch can move the session. Settings shows where
  it is set. Remove the `export` line from your shell profile, run
  `launchctl unsetenv CLAUDE_CODE_OAUTH_TOKEN`, then reopen your terminal app
  (Xirp, Terminal) and start new sessions.
- A session moves only between turns, after it next goes idle.

## Claude says "Not logged in"

Run `claude auth login`, then use **Add the signed-in account** again. Avoid
`claude setup-token`; those credentials lack the profile scope needed by the
usage endpoint.

## The menu bar icon is missing

Open the app again:

```bash
open -a "Vibecom Bar"
```

The app owns its status item directly and restores an item hidden by a previous
build. If the process is running but the icon remains hidden, check macOS menu
bar settings and temporarily hide another menu bar item to make room.

## Usage is stale or unavailable

- Click the refresh button once.
- Confirm the provider CLI is online and signed in.
- A rate-limited or unreachable provider keeps the last good reading visible.
- If only one saved account says **Sign in again**, use its sign-in action to
  recapture that account.

Provider usage endpoints are undocumented and may change before vibecom bar is
updated.

## Token totals are empty

Token totals come from local CLI transcripts. Use Claude Code or Codex once on
this Mac, then wait a few seconds. The app ignores transcripts older than its
seven-day lookback and incomplete lines that a CLI is still writing.

## A source build fails with "plugin for module 'SwiftUIMacros' not found"

The Mac has the Command Line Tools but not Xcode. The Command Line Tools
include the Swift compiler but not SwiftUI's macro plugins, so `@State` and
`@Entry` cannot expand. The errors that follow (`cannot assign to property:
'self' is immutable`, `extensions must not contain stored properties`) are
side effects of the same thing.

Either install the signed release, which needs no developer tools:

```bash
curl -fsSL https://vibecom.build/bar/install.sh | bash
```

or install Xcode 16 or newer from the App Store, open it once, and run
`./scripts/build-app.sh` again. The script uses an installed Xcode even when
`xcode-select` still points at the Command Line Tools.

## The installer says the signature or checksum does not match

Nothing was installed. The download was incomplete or was not the official
build. Run the command again; if it repeats, open an issue with the output.

## A source build prompts after every rebuild

Ad-hoc code signatures change when the binary changes. Build with a stable
Developer ID or Apple Development certificate:

```bash
VIBECOM_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  ./scripts/build-app.sh
```

Official releases use a stable Developer ID signature.
