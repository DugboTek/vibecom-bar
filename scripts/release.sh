#!/bin/zsh
# Build, sign, (notarize,) and package a release into dist/.
#
#   ./scripts/release.sh             build dist/Vibecom-Bar.zip + .sha256
#   ./scripts/release.sh --publish   also create the GitHub release for v$VERSION
#
# The app is a universal binary (Apple silicon + Intel) signed with a
# Developer ID Application certificate, which install.sh pins by team ID.
#
# Notarization runs when credentials are present, in any of these forms:
#   NOTARY_KEYCHAIN_PROFILE                       (xcrun notarytool store-credentials)
#   APPLE_API_KEY_PATH + APPLE_API_KEY_ID + APPLE_API_ISSUER   (App Store Connect key)
#   APPLE_ID + APPLE_APP_PASSWORD + APPLE_TEAM_ID              (app-specific password)
# Without them the release is refused unless VIBECOM_ALLOW_UNNOTARIZED=1.
# An unnotarized build installs fine with install.sh (curl downloads are not
# quarantined) but a browser-downloaded copy is blocked by Gatekeeper.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
VERSION="$(tr -d '[:space:]' < VERSION)"
TAG="${GITHUB_REF_NAME:-v$VERSION}"
DIST="$ROOT/dist"
ARCHIVE="$DIST/Vibecom-Bar.zip"
TEAM_ID="${APPLE_TEAM_ID:-N9S23BFMU4}"
PUBLISH=0
[[ "${1:-}" == "--publish" ]] && PUBLISH=1

if [[ "${TAG#v}" != "$VERSION" ]]; then
  echo "Tag $TAG does not match VERSION $VERSION" >&2
  exit 1
fi

NOTARY_ARGS=()
if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  NOTARY_ARGS=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
elif [[ -n "${APPLE_API_KEY_PATH:-}" && -n "${APPLE_API_KEY_ID:-}" && -n "${APPLE_API_ISSUER:-}" ]]; then
  NOTARY_ARGS=(--key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER")
elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" ]]; then
  NOTARY_ARGS=(--apple-id "$APPLE_ID" --password "$APPLE_APP_PASSWORD" --team-id "$TEAM_ID")
elif [[ "${VIBECOM_ALLOW_UNNOTARIZED:-0}" != "1" ]]; then
  echo "No notarization credentials. Set NOTARY_KEYCHAIN_PROFILE (or see the header" >&2
  echo "of this script), or VIBECOM_ALLOW_UNNOTARIZED=1 to ship signed-only." >&2
  exit 1
fi

if [[ -z "${VIBECOM_SIGN_IDENTITY:-}" ]]; then
  VIBECOM_SIGN_IDENTITY="$(security find-identity -v -p codesigning |
    grep -m1 "Developer ID Application: .*($TEAM_ID)" | sed -E 's/.*"(.*)"/\1/' || true)"
fi
if [[ "$VIBECOM_SIGN_IDENTITY" != Developer\ ID\ Application:* ]]; then
  echo "A release needs a Developer ID Application certificate for team $TEAM_ID." >&2
  exit 1
fi
export VIBECOM_SIGN_IDENTITY
export VIBECOM_UNIVERSAL=1

./scripts/build-app.sh
codesign --verify --deep --strict --verbose=2 "Vibecom Bar.app"
for binary in VibecomBar VibecomRelay; do
  ARCHS="$(lipo -archs "Vibecom Bar.app/Contents/MacOS/$binary")"
  [[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]] || {
    echo "$binary is not universal ($ARCHS)" >&2
    exit 1
  }
done

rm -rf "$DIST"
mkdir -p "$DIST"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "Vibecom Bar.app" "$ARCHIVE"

NOTARIZED=0
if (( ${#NOTARY_ARGS} )); then
  echo "› Submitting $TAG to Apple's notary service"
  xcrun notarytool submit "$ARCHIVE" "${NOTARY_ARGS[@]}" --wait
  echo "› Stapling notarization ticket"
  xcrun stapler staple "Vibecom Bar.app"
  xcrun stapler validate "Vibecom Bar.app"
  spctl --assess --type execute --verbose=2 "Vibecom Bar.app"
  # Package again so the downloadable app contains the stapled ticket.
  rm -f "$ARCHIVE"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "Vibecom Bar.app" "$ARCHIVE"
  NOTARIZED=1
else
  echo "› Skipping notarization (VIBECOM_ALLOW_UNNOTARIZED=1)"
fi

(
  cd "$DIST"
  shasum -a 256 "${ARCHIVE:t}" > "${ARCHIVE:t}.sha256"
)
echo "✓ Release ready in $DIST"

if (( PUBLISH )); then
  if (( NOTARIZED )); then
    NOTE="Signed with Developer ID and notarized by Apple."
  else
    NOTE="Signed with Developer ID (team $TEAM_ID); not yet notarized. Install with the command below, which verifies the checksum and signature. A copy downloaded through a browser is blocked by Gatekeeper until a notarized release ships."
  fi
  NOTES_FILE="$DIST/notes.md"
  {
    print -r -- "## Install"
    print -r -- ""
    print -r -- '```sh'
    print -r -- "curl -fsSL https://vibecom.build/bar/install.sh | bash"
    print -r -- '```'
    print -r -- ""
    print -r -- "$NOTE Universal binary for Apple silicon and Intel, macOS 14 or newer."
    print -r -- ""
    print -r -- "Running the same command again updates an existing install."
  } > "$NOTES_FILE"
  gh release create "$TAG" "$ARCHIVE" "$ARCHIVE.sha256" \
    --title "Vibecom Bar $TAG" --notes-file "$NOTES_FILE" --generate-notes
  echo "✓ Published $TAG"
fi
