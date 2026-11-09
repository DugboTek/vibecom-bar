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
ICON_SOURCE="${VIBECOM_ICON:-$ROOT/Resources/AppIcon.png}"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
BUILD_NUMBER="${VIBECOM_BUILD_NUMBER:-1}"
BUNDLE_ID="build.vibecom.menubar"

# SwiftUI's macros (@State, @Entry, ...) ship only inside Xcode. Command Line
# Tools alone has the Swift compiler but not those plugins, so a build there
# fails with "plugin for module 'SwiftUIMacros' not found". Use an installed
# Xcode even when xcode-select points at Command Line Tools.
has_swiftui_macros() {
  local dev="$1"
  [[ -e "$dev/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ||
     -e "$dev/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ]]
}
ACTIVE_DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}"
if [[ -z "$ACTIVE_DEVELOPER_DIR" ]] || ! has_swiftui_macros "$ACTIVE_DEVELOPER_DIR"; then
  FOUND_XCODE=""
  for candidate in /Applications/Xcode*.app/Contents/Developer(N) "$HOME"/Applications/Xcode*.app/Contents/Developer(N); do
    if has_swiftui_macros "$candidate"; then
      FOUND_XCODE="$candidate"
      break
    fi
  done
  if [[ -n "$FOUND_XCODE" ]]; then
    export DEVELOPER_DIR="$FOUND_XCODE"
    echo "› Using $FOUND_XCODE (the active developer tools cannot build SwiftUI apps)"
  else
    cat >&2 <<'MESSAGE'
✗ Building Vibecom Bar needs Xcode, not only the Command Line Tools.

  SwiftUI's macros ship inside Xcode, so Command Line Tools alone fails with
  "plugin for module 'SwiftUIMacros' not found".

  You do not need to build it yourself. Install the signed release instead:

    curl -fsSL https://vibecom.build/bar/install.sh | bash

  To build from source, install Xcode from the App Store, open it once, then
  run ./scripts/build-app.sh again.
MESSAGE
    exit 1
  fi
fi

# VIBECOM_UNIVERSAL=1 builds one binary for Apple silicon and Intel Macs.
ARCH_FLAGS=()
if [[ "${VIBECOM_UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

echo "› Building release binary"
swift build -c release "${ARCH_FLAGS[@]}" --product VibecomBar
swift build -c release "${ARCH_FLAGS[@]}" --product VibecomRelay
BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"

echo "› Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/VibecomBar" "$APP/Contents/MacOS/VibecomBar"
cp "$BIN_DIR/VibecomRelay" "$APP/Contents/MacOS/VibecomRelay"
cp -R "$ROOT/Resources/VibecomRelayClaudePlugin" "$APP/Contents/Resources/VibecomRelayClaudePlugin"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Vibecom Bar</string>
  <key>CFBundleDisplayName</key><string>vibecom bar</string>
  <key>CFBundleExecutable</key><string>VibecomBar</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 DugboTek</string>
</dict>
</plist>
PLIST

ACTUAL_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")
if [[ "$ACTUAL_BUNDLE_ID" != "$BUNDLE_ID" ]]; then
  echo "✗ Bundle identity mismatch: expected $BUNDLE_ID, got $ACTUAL_BUNDLE_ID"
  exit 1
fi

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
  if [[ "$IDENTITY" == Developer\ ID\ Application:* ]]; then
    codesign --force --options runtime --timestamp --sign "$IDENTITY" \
      "$APP/Contents/MacOS/VibecomRelay"
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
  else
    codesign --force --options runtime --timestamp=none --sign "$IDENTITY" \
      "$APP/Contents/MacOS/VibecomRelay"
    codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
  fi
else
  echo "› No signing certificate found; signing ad-hoc."
  echo "  macOS will ask for keychain access again after every rebuild."
  codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/VibecomRelay"
  codesign --force --sign - --timestamp=none "$APP"
fi
codesign --verify --strict "$APP"

echo "✓ Built $APP"
