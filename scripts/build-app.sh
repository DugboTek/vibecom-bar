#!/bin/zsh
# Builds "Vibecom Bar.app", signed with a real certificate when one exists.
#
# The signature matters more than it looks: the keychain ties "Always Allow" to
# the app's signing identity. An ad-hoc signature changes on every build, so
# each rebuild looks like a new app and every saved login prompts again. A
# Developer ID (or Apple Development) certificate keeps the identity stable.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/Vibecom Bar.app"
ICON_SOURCE="${VIBECOM_ICON:-$HOME/Desktop/DEV/vibeland/src/app/icon.png}"

echo "› Building release binary"
swift build -c release --product VibecomBar

echo "› Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/VibecomBar" "$APP/Contents/MacOS/VibecomBar"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Vibecom Bar</string>
  <key>CFBundleDisplayName</key><string>vibecom bar</string>
  <key>CFBundleExecutable</key><string>VibecomBar</string>
  <key>CFBundleIdentifier</key><string>build.vibecom.bar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>vibecom.build</string>
</dict>
</plist>
PLIST

if [[ -f "$ICON_SOURCE" ]]; then
  echo "› Rendering icon from $ICON_SOURCE"
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 64 128 256 512; do
    sips -z $size $size "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$ICON_SOURCE" \
      --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
else
  echo "› No icon source found; bundling without a custom icon"
fi

IDENTITY="${VIBECOM_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY=$(security find-identity -v -p codesigning | grep -m1 "Developer ID Application" | sed -E 's/.*"(.*)"/\1/' || true)
fi
if [[ -z "$IDENTITY" ]]; then
  IDENTITY=$(security find-identity -v -p codesigning | grep -m1 "Apple Development" | sed -E 's/.*"(.*)"/\1/' || true)
fi

if [[ -n "$IDENTITY" ]]; then
  echo "› Signing as $IDENTITY"
  codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
else
  echo "› No signing certificate found; signing ad-hoc."
  echo "  macOS will ask for keychain access again after every rebuild."
  codesign --force --sign - --timestamp=none "$APP"
fi
codesign --verify --strict "$APP"

echo "✓ Built $APP"
