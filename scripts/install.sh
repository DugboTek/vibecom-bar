#!/bin/zsh
# Install the latest signed release without requiring Homebrew.
set -euo pipefail

REPOSITORY="${VIBECOM_REPOSITORY:-DugboTek/vibecom-bar}"
BASE_URL="https://github.com/$REPOSITORY/releases/latest/download"
WORK_DIR="$(mktemp -d)"
ARCHIVE="$WORK_DIR/Vibecom-Bar.zip"
CHECKSUM="$WORK_DIR/Vibecom-Bar.zip.sha256"

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

blue=$'\033[38;5;39m'
yellow=$'\033[38;5;220m'
bold=$'\033[1m'
reset=$'\033[0m'
[[ -t 1 ]] || { blue=""; yellow=""; bold=""; reset=""; }

print -r -- ""
print -r -- "  ${blue}☁${yellow}●${reset}  ${bold}vibecom bar${reset}"
print -r -- "      every account, one glance"
print -r -- ""

spin() {
  local pid="$1" message="$2" frames=("◐" "◓" "◑" "◒") index=1
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r  %s %s" "${frames[$index]}" "$message"
    index=$((index % 4 + 1))
    sleep 0.09
  done
  wait "$pid"
  printf "\r  ✓ %s\n" "$message"
}

curl -fL --retry 3 --silent --show-error "$BASE_URL/Vibecom-Bar.zip" -o "$ARCHIVE" &
spin "$!" "Downloading the latest release"
curl -fL --retry 3 --silent --show-error \
  "$BASE_URL/Vibecom-Bar.zip.sha256" -o "$CHECKSUM"

(
  cd "$WORK_DIR"
  shasum -a 256 -c "${CHECKSUM:t}"
) >/dev/null
print -r -- "  ✓ Checksum verified"

/usr/bin/ditto -x -k "$ARCHIVE" "$WORK_DIR/unpacked"
APP="$WORK_DIR/unpacked/Vibecom Bar.app"
codesign --verify --deep --strict "$APP"
spctl --assess --type execute "$APP"
print -r -- "  ✓ Developer ID signature and Apple notarization verified"

INSTALL_DIR="${VIBECOM_INSTALL_DIR:-/Applications}"
if [[ ! -w "$INSTALL_DIR" ]]; then
  INSTALL_DIR="$HOME/Applications"
fi
mkdir -p "$INSTALL_DIR"
DESTINATION="$INSTALL_DIR/Vibecom Bar.app"

if [[ -e "$DESTINATION" ]]; then
  BACKUP="$HOME/.Trash/Vibecom Bar-$(date +%Y%m%d-%H%M%S).app"
  mv "$DESTINATION" "$BACKUP"
  print -r -- "  • Previous app moved to Trash"
fi

/usr/bin/ditto "$APP" "$DESTINATION"
print -r -- "  ✓ Installed in $INSTALL_DIR"
print -r -- ""
print -r -- "  ${blue}Opening vibecom bar…${reset}"
open "$DESTINATION"
