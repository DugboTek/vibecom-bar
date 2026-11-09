#!/usr/bin/env bash
# Install or update Vibecom Bar from the latest signed GitHub release.
#
#   curl -fsSL https://vibecom.build/bar/install.sh | bash
#
# No Xcode, Homebrew, or Swift toolchain needed. The script downloads the
# release archive, checks its SHA-256, checks that the app is signed by the
# Vibecom Developer ID (team N9S23BFMU4), and installs it in /Applications
# (or ~/Applications when /Applications is not writable).
#
# Environment overrides:
#   VIBECOM_BAR_VERSION      release tag to install, e.g. v1.0.0 (default: latest)
#   VIBECOM_INSTALL_DIR      folder to install into
#   VIBECOM_BAR_NO_OPEN=1    install without launching the app
#   VIBECOM_BAR_BASE_URL     download folder holding Vibecom-Bar.zip (testing)
#   VIBECOM_BAR_TEAM_ID      expected signing team (forks)
#
# Runs with the bash 3.2 that ships with macOS.
set -euo pipefail

REPOSITORY="${VIBECOM_REPOSITORY:-DugboTek/vibecom-bar}"
TEAM_ID="${VIBECOM_BAR_TEAM_ID:-N9S23BFMU4}"
BUNDLE_ID="build.vibecom.menubar"
APP_NAME="Vibecom Bar.app"
ASSET="Vibecom-Bar.zip"

if [ -n "${VIBECOM_BAR_BASE_URL:-}" ]; then
  BASE_URL="$VIBECOM_BAR_BASE_URL"
elif [ -n "${VIBECOM_BAR_VERSION:-}" ]; then
  BASE_URL="https://github.com/$REPOSITORY/releases/download/$VIBECOM_BAR_VERSION"
else
  BASE_URL="https://github.com/$REPOSITORY/releases/latest/download"
fi

if [ -t 1 ]; then
  blue=$'\033[38;5;39m'; yellow=$'\033[38;5;220m'; red=$'\033[31m'
  dim=$'\033[2m'; bold=$'\033[1m'; reset=$'\033[0m'
else
  blue=""; yellow=""; red=""; dim=""; bold=""; reset=""
fi

say() { printf '  %s\n' "$*"; }
ok() { printf '  ✓ %s\n' "$*"; }
fail() {
  printf '\n  %s✗ %s%s\n' "$red" "$1" "$reset" >&2
  shift
  for line in "$@"; do printf '    %s\n' "$line" >&2; done
  printf '\n' >&2
  exit 1
}

printf '\n  %s☁%s●%s  %svibecom bar%s\n' "$blue" "$yellow" "$reset" "$bold" "$reset"
printf '      %severy account, one glance%s\n\n' "$dim" "$reset"

[ "$(uname -s)" = "Darwin" ] || fail "Vibecom Bar is a macOS app." "This machine is $(uname -s)."

MACOS_VERSION="$(sw_vers -productVersion)"
MACOS_MAJOR="${MACOS_VERSION%%.*}"
if [ "$MACOS_MAJOR" -lt 14 ]; then
  fail "Vibecom Bar needs macOS 14 Sonoma or newer." "This Mac runs macOS $MACOS_VERSION."
fi

for tool in curl ditto codesign shasum; do
  command -v "$tool" >/dev/null 2>&1 || fail "Missing $tool, which macOS normally includes."
done

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vibecom-bar.XXXXXX")"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

download() {
  # $1 = file name, $2 = destination
  curl -fL --retry 3 --silent --show-error --proto '=https,file' \
    "$BASE_URL/$1" -o "$2"
}

say "Downloading ${VIBECOM_BAR_VERSION:-the latest release}…"
if ! download "$ASSET" "$WORK_DIR/$ASSET"; then
  fail "Could not download $BASE_URL/$ASSET" \
    "Check your connection, or see https://github.com/$REPOSITORY/releases"
fi
download "$ASSET.sha256" "$WORK_DIR/$ASSET.sha256" ||
  fail "Could not download the release checksum."
ok "Downloaded"

EXPECTED_SUM="$(awk '{print $1; exit}' "$WORK_DIR/$ASSET.sha256")"
ACTUAL_SUM="$(shasum -a 256 "$WORK_DIR/$ASSET" | awk '{print $1}')"
[ -n "$EXPECTED_SUM" ] && [ "$EXPECTED_SUM" = "$ACTUAL_SUM" ] ||
  fail "The download's checksum does not match the release." "Nothing was installed."
ok "Checksum verified"

ditto -x -k "$WORK_DIR/$ASSET" "$WORK_DIR/unpacked" ||
  fail "Could not unpack the release archive."
APP="$WORK_DIR/unpacked/$APP_NAME"
[ -d "$APP" ] || fail "The release archive does not contain $APP_NAME."

codesign --verify --deep --strict "$APP" 2>/dev/null ||
  fail "The app's code signature is not valid." "Nothing was installed."
SIGNATURE="$(codesign -dv "$APP" 2>&1 || true)"
SIGNED_TEAM="$(printf '%s\n' "$SIGNATURE" | sed -n 's/^TeamIdentifier=//p')"
SIGNED_ID="$(printf '%s\n' "$SIGNATURE" | sed -n 's/^Identifier=//p')"
[ "$SIGNED_TEAM" = "$TEAM_ID" ] ||
  fail "The app is signed by team '${SIGNED_TEAM:-none}', expected $TEAM_ID." "Nothing was installed."
[ "$SIGNED_ID" = "$BUNDLE_ID" ] ||
  fail "The app's bundle identifier is '$SIGNED_ID', expected $BUNDLE_ID." "Nothing was installed."
if spctl --assess --type execute "$APP" >/dev/null 2>&1; then
  ok "Developer ID signature and Apple notarization verified"
else
  ok "Developer ID signature verified (team $TEAM_ID)"
fi
# This download did not come through a browser, so macOS has not flagged it.
# Clear the flag anyway in case a proxy or archive tool added one.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

# Pick the folder: an explicit choice, else wherever it is already installed,
# else /Applications, else ~/Applications.
if [ -n "${VIBECOM_INSTALL_DIR:-}" ]; then
  INSTALL_DIR="$VIBECOM_INSTALL_DIR"
elif [ ! -e "/Applications/$APP_NAME" ] && [ -e "$HOME/Applications/$APP_NAME" ]; then
  INSTALL_DIR="$HOME/Applications"
elif [ -w "/Applications" ]; then
  INSTALL_DIR="/Applications"
else
  INSTALL_DIR="$HOME/Applications"
fi
mkdir -p "$INSTALL_DIR"
DESTINATION="$INSTALL_DIR/$APP_NAME"
STAGING="$INSTALL_DIR/.$APP_NAME.staging"

# $1 = folder prefix to match ("" matches a copy anywhere)
app_is_running() {
  pgrep -f "$1/$APP_NAME/Contents/MacOS/VibecomBar\$" >/dev/null 2>&1
}

# Ask a running copy to quit. Only one copy may run per user, so a new
# version launched beside the old one would exit immediately. With
# VIBECOM_BAR_NO_OPEN=1 only a copy running from the destination is quit.
QUIT_SCOPE=""
[ "${VIBECOM_BAR_NO_OPEN:-0}" = "1" ] && QUIT_SCOPE="$INSTALL_DIR"
if app_is_running "$QUIT_SCOPE"; then
  say "Quitting the running Vibecom Bar…"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 40); do
    app_is_running "$QUIT_SCOPE" || break
    sleep 0.25
  done
  app_is_running "$QUIT_SCOPE" && fail "Vibecom Bar is still running." \
    "Quit it with the power button in its menu, then run this command again."
fi

# Stage next to the destination and swap with renames, so the app is never
# half-copied. Claude and Codex sessions already running through Vibecom
# Relay keep their open copy of the old binary and are not interrupted.
rm -rf "$STAGING"
ditto "$APP" "$STAGING" || fail "Could not copy the app into $INSTALL_DIR."
codesign --verify --deep --strict "$STAGING" 2>/dev/null ||
  { rm -rf "$STAGING"; fail "The copied app failed its signature check."; }

if [ -e "$DESTINATION" ]; then
  OLD_VERSION="$(defaults read "$DESTINATION/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo unknown)"
  mkdir -p "$HOME/.Trash"
  BACKUP="$HOME/.Trash/Vibecom Bar $OLD_VERSION $(date +%Y%m%d-%H%M%S).app"
  mv "$DESTINATION" "$BACKUP" ||
    { rm -rf "$STAGING"; fail "Could not move the previous app out of $INSTALL_DIR."; }
  say "Previous version ($OLD_VERSION) moved to the Trash"
fi
mv "$STAGING" "$DESTINATION"
NEW_VERSION="$(defaults read "$DESTINATION/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo unknown)"
ok "Installed Vibecom Bar $NEW_VERSION in $INSTALL_DIR"

if [ "${VIBECOM_BAR_NO_OPEN:-0}" = "1" ]; then
  printf '\n  Open it any time: %sopen "%s"%s\n\n' "$bold" "$DESTINATION" "$reset"
  exit 0
fi

# Right after the old copy quits, Launch Services can briefly refuse with
# error -600. Retry for a few seconds.
for attempt in 1 2 3 4 5 6; do
  if open "$DESTINATION" 2>/dev/null; then
    printf '\n  %sVibecom Bar is running. Look for it in your menu bar.%s\n\n' "$blue" "$reset"
    exit 0
  fi
  sleep "$attempt"
done
fail "Installed, but macOS would not open it yet." "Run: open \"$DESTINATION\""
