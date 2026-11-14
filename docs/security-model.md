# How credentials and privacy work

vibecom bar needs provider credentials to read subscription usage and switch
accounts. The design keeps those credentials in platform or CLI-owned storage
and keeps message content out of the app's data model.

## Storage boundaries

```text
Provider CLI                    vibecom bar
────────────                    ───────────
Claude live Keychain item  ← explicit switch only
Codex ~/.codex/auth.json   ← explicit switch or safe token renewal
                                │
                                ├─ app-owned Keychain item per saved account
                                └─ accounts.json: labels and provider identity only
```

| Data | Location | Contents |
|---|---|---|
| Saved account secret | Login Keychain, `build.vibecom.bar.v2.account.<uuid>` | OAuth credentials |
| Claude's active login | Login Keychain, `Claude Code-credentials` | Claude-owned credential payload |
| Codex's active login | `~/.codex/auth.json` | Codex credential payload |
| Account metadata | `~/Library/Application Support/VibecomBar/accounts.json` | Labels, provider, non-secret identity |
| Preferences | `~/Library/Application Support/VibecomBar/preferences.json` | Refresh interval, display, alerts |
| Guided profiles | `~/Library/Application Support/VibecomBar/profiles/<uuid>` | Provider configuration, not app-exported tokens |
| Compass token (optional) | Login Keychain, `build.vibecom.bar.v2.servetoken.<uuid>` | One `claude setup-token` token per saved Claude account |
| Served token file (optional, off by default) | `/Users/Shared/compass-auth/claude.token` or the configured path | The active account's Compass token and nothing else, mode 640 |
| Served file record | `~/Library/Application Support/VibecomBar/served-file.json` | Path, device, inode, size and modification time of the token file vibecom bar last wrote; nothing derived from the token |

## Why Claude keeps ownership

macOS Keychain associates an item with trusted applications. If vibecom bar
creates Claude's live item, Claude Code can be forced to ask for permission on
every access. Therefore vibecom bar refuses to create or relabel that item. It
only replaces the secret bytes of an existing Claude-owned item during an
explicit account switch.

That replacement goes through Apple's `/usr/bin/security` helper exactly the
way Claude Code writes the item itself: `add-generic-password -U … -X <hex>`,
sent over `security -i` stdin when the command fits the helper's 4 KB line and
passed as arguments otherwise (Claude Code makes the same choice). A direct
`SecItemUpdate` would move the item from Claude's `apple-tool:` partition to
vibecom bar's team and make every Claude process prompt. The helper's
interactive password prompt is never used: it keeps only 128 bytes and cannot
accept a line longer than 1,023 bytes, while a real Claude credential with MCP
logins is several kilobytes. After writing, vibecom bar reads the item back
and reports a failure unless it holds exactly the bytes that were sent.

Periodic refreshes never read `Claude Code-credentials` through the Keychain
API, which is what once produced repeated password prompts. They read it once
per refresh through `/usr/bin/security`, the helper Claude's item already
trusts, to keep saved logins current (see below). Regression tests lock both
behaviors down.

## Keeping saved logins current

Claude Code and Codex rotate refresh tokens whenever they renew a login, so a
saved copy goes stale as soon as its account is used. On every refresh and
before every switch, vibecom bar reads the login each CLI is using, works out
which saved account it belongs to, and saves the rotated tokens into that
account's Keychain item. Ownership comes from the tokens, or the provider's
profile endpoint for a token it has not seen, never from `~/.claude.json`. A
login it cannot identify is never saved under any account.

Before switching, the incoming account's saved login is renewed. That proves
its refresh token still works. If the provider says the login is dead, the
switch stops before anything the CLI uses is touched, and the account asks to
be signed in again.

## Token renewal

Inactive saved accounts can be renewed in the background. The active Claude
account is never renewed by vibecom bar because Claude refresh tokens rotate:
if rotation succeeded remotely but a Keychain write failed locally, Claude
Code would be left with a dead token. Claude Code renews its active login.

Codex stores its live credential in a normal private file, so vibecom bar can
safely write a renewed active Codex token back to that file.

## Serving another local user

**Settings → Serve Another User** lets a second macOS user on the same Mac (for
example a `compass` service account that never signs in to the desktop) use
the same Claude accounts and follow every switch. It is off by default.

What crosses the user boundary is deliberately narrow:

- **Only a setup-token.** Each saved Claude account can hold an optional
  Compass token, the long-lived token `claude setup-token` prints, which the
  other user passes as `CLAUDE_CODE_OAUTH_TOKEN`. It is pasted by the user;
  vibecom bar never runs a login to get one. It is stored in its own Keychain
  item, `build.vibecom.bar.v2.servetoken.<uuid>`, apart from the account's
  OAuth pair, and it is never sent to the usage endpoint (setup-tokens lack the
  `user:profile` scope).
- **Never a refresh pair.** Claude refresh tokens rotate. If the other user
  held one, a renewal on either side would sign the other out. A paste that is
  a refresh token (`sk-ant-ort…`), anything that is not an `sk-ant-oat…` token,
  or the saved login's own access or refresh token is refused. Claude Code's
  live `Claude Code-credentials` item is never read or written for this.
- **Nothing else in the file.** The file holds the token bytes only, with no
  newline, JSON, or account details.

On launch and after every change of the active Claude account, manual or
automatic, the file is brought in line:

| Situation | File |
|---|---|
| Setting on, active account has a Compass token | Written with that token |
| Setting on, active account has no Compass token | Removed; the other user pauses |
| Setting on, no saved Claude account is active | Removed |
| Setting off | Removed, only if vibecom bar wrote it; otherwise nothing is done |
| Path changed | Old file removed, new one written |
| Write fails | Old file removed, failure shown in Settings |

**Only its own file is ever replaced or removed.** Every "written" and
"removed" above applies only to the file vibecom bar itself wrote. After each
write it records that file's path, device, inode, size and modification time
in `served-file.json`. Before replacing or deleting anything it checks the path
with `lstat` and acts only if a plain file with exactly that record is there.
Anything else is left untouched and Settings says "A file vibecom bar did not
write is at <path>; not touching it". That includes a file you made, a file
swapped in after vibecom bar wrote, a symlink (never followed), or a folder.
The file name must also end in `.token`, so a mistyped path such as
`~/.zshrc` is refused before anything is touched. If vibecom bar is killed
between writing the file and saving the record, it treats the file as
someone else's. Delete it by hand once and serving resumes.

Writes are atomic: a temp file is created in the same folder with
`O_EXCL|O_NOFOLLOW`, set to mode 640 regardless of umask, written, `fsync`ed,
and renamed over the target, so a reader sees the old token or the new one and
never a partial file. A failed write deletes its temp file. An unchanged
token is not rewritten on every refresh.

vibecom bar does not create users, groups, folders, or ACLs. The expected
layout, created once with `sudo`, is a folder owned by the menu bar user with
group `compassauth` (the menu bar user and `compass`), mode 750. A file created
in it takes the folder's group, so with mode 640 only the owner and that group
can read it. Before writing, vibecom bar refuses a folder that is missing, not
owned by the menu bar user, writable by everyone, or not writable, and shows
why in Settings.

The activity log and Settings name the account and the path, never the token.
Tests check every log line and on-screen status for token text. The file is
left in place when vibecom bar quits, so the other user keeps working on the
last active account until the next change.

## Transcript privacy

The token ledger scans the JSONL transcripts already written by Claude Code
and Codex. It extracts timestamps, model identifiers, and numeric usage fields.
It does not retain prompts, responses, tool output, or file contents. The
resulting totals stay in memory and are not uploaded.

For screen sharing, **Settings → Privacy → Blur account names** obscures account
labels throughout the popover. The preference changes presentation only; it
does not alter the account metadata stored on disk.

## Network access

The app contacts only Anthropic and OpenAI/ChatGPT endpoints needed for usage,
identity, and OAuth renewal. There is no vibecom telemetry endpoint.

The provider endpoints are internal and undocumented. Compatibility can break
when providers change them; this is an availability risk, not permission to
send credentials elsewhere.

## Trade-offs

- Keychain prompts once when one signed application first reads another
  application's item. Removing Keychain would mean weaker token storage.
- Direct provider APIs offer accurate limits but can change without notice.
- Direct distribution allows rapid releases, but every public binary must be
  Developer ID signed and notarized to preserve user trust.
