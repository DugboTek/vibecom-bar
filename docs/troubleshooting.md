# Troubleshooting vibecom bar

## Repeating Keychain prompts

Routine refreshes should never request Claude's live Keychain credential.

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

## A source build prompts after every rebuild

Ad-hoc code signatures change when the binary changes. Build with a stable
Developer ID or Apple Development certificate:

```bash
VIBECOM_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  ./scripts/build-app.sh
```

Official releases use a stable Developer ID signature and Apple notarization.
