#!/bin/zsh
# Builds "Vibecom Bar.app" — a menu bar app bundle, ad-hoc signed so macOS
# grants it a stable identity for notifications and login items.
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

echo "› Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || {
  echo "  ad-hoc signing failed; the app still runs, but notifications may not appear"
}

echo "✓ Built $APP"
