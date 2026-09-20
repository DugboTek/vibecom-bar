#!/bin/zsh
# Build, sign, notarize, staple, and package a production release.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
VERSION="$(tr -d '[:space:]' < VERSION)"
TAG="${GITHUB_REF_NAME:-v$VERSION}"
DIST="$ROOT/dist"
ARCHIVE="$DIST/Vibecom-Bar.zip"

if [[ "${TAG#v}" != "$VERSION" ]]; then
  echo "Tag $TAG does not match VERSION $VERSION" >&2
  exit 1
fi

for name in VIBECOM_SIGN_IDENTITY APPLE_ID APPLE_APP_PASSWORD APPLE_TEAM_ID; do
  if [[ -z "${(P)name:-}" ]]; then
    echo "Missing required environment variable: $name" >&2
    exit 1
  fi
done

./scripts/build-app.sh
codesign --verify --deep --strict --verbose=2 "Vibecom Bar.app"

mkdir -p "$DIST"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "Vibecom Bar.app" "$ARCHIVE"

echo "› Submitting $TAG to Apple's notary service"
xcrun notarytool submit "$ARCHIVE" \
  --apple-id "$APPLE_ID" \
  --password "$APPLE_APP_PASSWORD" \
  --team-id "$APPLE_TEAM_ID" \
  --wait

echo "› Stapling notarization ticket"
xcrun stapler staple "Vibecom Bar.app"
xcrun stapler validate "Vibecom Bar.app"
spctl --assess --type execute --verbose=2 "Vibecom Bar.app"

# Package again so the downloadable app contains the stapled ticket.
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "Vibecom Bar.app" "$ARCHIVE"
(
  cd "$DIST"
  shasum -a 256 "${ARCHIVE:t}" > "${ARCHIVE:t}.sha256"
)

echo "✓ Release ready in $DIST"
