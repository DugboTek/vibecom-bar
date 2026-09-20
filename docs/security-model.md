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

## Why Claude keeps ownership

macOS Keychain associates an item with trusted applications. If vibecom bar
creates Claude's live item, Claude Code can be forced to ask for permission on
every access. Therefore vibecom bar refuses to create or relabel that item. It
only replaces the secret bytes of an existing Claude-owned item during an
explicit account switch.

Periodic refreshes determine the active Claude account from `~/.claude.json`.
They perform zero reads of `Claude Code-credentials`. A regression test locks
this behavior down.

## Token renewal

Inactive saved accounts can be renewed in the background. The active Claude
account is never renewed by vibecom bar because Claude refresh tokens rotate:
if rotation succeeded remotely but a Keychain write failed locally, Claude
Code would be left with a dead token. Claude Code renews its active login.

Codex stores its live credential in a normal private file, so vibecom bar can
safely write a renewed active Codex token back to that file.

## Transcript privacy

The token ledger scans the JSONL transcripts already written by Claude Code
and Codex. It extracts timestamps, model identifiers, and numeric usage fields.
It does not retain prompts, responses, tool output, or file contents. The
resulting totals stay in memory and are not uploaded.

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
