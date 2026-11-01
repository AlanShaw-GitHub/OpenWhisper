#!/usr/bin/env bash
# Installs or updates OpenWhisper from the latest GitHub release:
#
#   curl -fsSL https://raw.githubusercontent.com/AlanShaw-GitHub/OpenWhisper/main/script/install.sh | bash
#
# It downloads OpenWhisper.zip with curl, checks it against the published SHA-256, puts OpenWhisper.app into
# /Applications (or ~/Applications when /Applications is not writable) and opens it. Run it again to update.
# Optional: OPENWHISPER_INSTALL_DIR=<folder> installs elsewhere; OPENWHISPER_NO_OPEN=1 skips opening the app;
# OPENWHISPER_DOWNLOAD_BASE=<url> downloads from another place (used to test a release before publishing it).
set -euo pipefail

REPO="AlanShaw-GitHub/OpenWhisper"
APP_NAME="OpenWhisper"
BUNDLE_ID="com.alan.wisper"
BASE_URL="${OPENWHISPER_DOWNLOAD_BASE:-https://github.com/$REPO/releases/latest/download}"

fail() { echo "Error: $*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "OpenWhisper runs on macOS only."
[[ "$(uname -m)" == "arm64" ]] || fail "OpenWhisper needs a Mac with Apple silicon (M1 or later)."
MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
(( MACOS_MAJOR >= 14 )) || fail "OpenWhisper needs macOS 14 Sonoma or later (this Mac has $(sw_vers -productVersion))."

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT

echo "Downloading $APP_NAME…"
curl -fL --progress-bar -o "$TMP/$APP_NAME.zip" "$BASE_URL/$APP_NAME.zip" || fail "Download failed. Check your internet connection."
curl -fsSL -o "$TMP/$APP_NAME.zip.sha256" "$BASE_URL/$APP_NAME.zip.sha256" || fail "Could not download the checksum."

EXPECTED="$(awk '{print $1}' "$TMP/$APP_NAME.zip.sha256")"
ACTUAL="$(shasum -a 256 "$TMP/$APP_NAME.zip" | awk '{print $1}')"
[[ -n "$EXPECTED" && "$EXPECTED" == "$ACTUAL" ]] || fail "The download does not match its checksum. Nothing was installed."

mkdir -p "$TMP/unpacked"
ditto -x -k "$TMP/$APP_NAME.zip" "$TMP/unpacked"
[[ -d "$TMP/unpacked/$APP_NAME.app" ]] || fail "The download does not contain $APP_NAME.app."
codesign --verify --deep --strict "$TMP/unpacked/$APP_NAME.app" || fail "The app's signature is broken. Nothing was installed."

if [[ -n "${OPENWHISPER_INSTALL_DIR:-}" ]]; then
    DEST="$OPENWHISPER_INSTALL_DIR"
elif [[ -w "/Applications" ]]; then
    DEST="/Applications"
else
    DEST="$HOME/Applications"
fi
mkdir -p "$DEST"

# Quit a running copy so it can be replaced.
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x "$APP_NAME" >/dev/null 2>&1 || break; sleep 0.3; done
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi

rm -rf "${DEST:?}/${APP_NAME:?}.app"
ditto "$TMP/unpacked/$APP_NAME.app" "$DEST/$APP_NAME.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/$APP_NAME.app/Contents/Info.plist" 2>/dev/null || echo "")"
echo "Installed $APP_NAME $VERSION in $DEST."

if [[ "${OPENWHISPER_NO_OPEN:-0}" != "1" ]]; then
    open "$DEST/$APP_NAME.app"
    echo "OpenWhisper is in your menu bar (the waveform icon). Click it to allow the microphone and Accessibility, then add your API key."
fi
