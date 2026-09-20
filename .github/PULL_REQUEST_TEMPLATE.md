## What changed

<!-- Describe the user-visible outcome, not only the files changed. -->

## Why

<!-- What problem does this solve? Link an issue when one exists. -->

## Verification

- [ ] `swift test`
- [ ] `swift build -c release`
- [ ] I tested affected Keychain or account-switching behavior manually, if applicable
- [ ] I updated screenshots or documentation for user-visible changes

## Security checklist

- [ ] No credential, token, account email, or private path appears in this diff
- [ ] Normal refresh still avoids Claude Code's live Keychain item
- [ ] New network calls have tests for URL, headers, and failure behavior

## Screenshots

<!-- Add before/after images for interface changes. Remove this section otherwise. -->
