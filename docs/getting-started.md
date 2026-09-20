# Get started with vibecom bar

This tutorial takes you from installation to seeing limits for your first
Claude Code or Codex account.

## What you need

- macOS 14 or newer;
- Claude Code, Codex, or both installed; and
- at least one CLI already signed in.

## Step 1: Install and open the app

For a source build:

```bash
git clone https://github.com/DugboTek/vibecom-bar.git
cd vibecom-bar
./scripts/build-app.sh
open "Vibecom Bar.app"
```

A cloud icon appears in the menu bar. Click it to open vibecom bar.

## Step 2: Add the account you already use

1. Click **Add Account…**.
2. Choose **Claude Code** or **Codex**.
3. Under **Add the signed-in account**, click **Add**.
4. If macOS asks whether vibecom bar may read a Claude credential, verify the
   requesting app is vibecom bar and choose **Always Allow**.

The account appears with its usage windows and reset times.

## Step 3: Add another account

1. Return to **Add Account…**.
2. Choose the provider and click **Sign In…**.
3. Complete the sign-in in Terminal and the browser.
4. Return to vibecom bar when Terminal reports success.

The guided sign-in uses a separate provider configuration directory, so it
does not log out the account your normal CLI session uses.

## Switch accounts

Click **Use** beside an inactive account. New CLI sessions use the selected
account; a session that is already running keeps the login it started with.

The first Claude switch can produce one Keychain authorization prompt. A
repeating prompt is not expected; follow the
[Keychain troubleshooting steps](troubleshooting.md#repeating-keychain-prompts).

## What you built

You now have one menu bar view for account limits and local token activity.
Next, read [how credentials and privacy work](security-model.md) or configure
alerts and refresh timing from the gear button.
