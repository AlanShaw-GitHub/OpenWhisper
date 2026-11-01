#!/usr/bin/env bash
# Packages OpenWhisper for a GitHub release: dist/OpenWhisper.zip and dist/OpenWhisper.zip.sha256.
# The asset names carry no version, so https://github.com/<repo>/releases/latest/download/OpenWhisper.zip always
# points at the newest release; script/install.sh downloads from there.
#
#   ./script/package_release.sh
#   ./script/package_release.sh --identity "Developer ID Application: Name (TEAMID)" --notary-profile <profile>
#
# Without options the app is signed ad hoc. That is enough for script/install.sh, because files downloaded with
# curl are not quarantined. With a Developer ID certificate and a notarytool keychain profile (created once with
# `xcrun notarytool store-credentials`), the app is also notarized, so a download from a browser opens normally too.
set -euo pipefail
IDENTITY=""
PROFILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --identity) IDENTITY="${2:?}"; shift 2 ;;
        --notary-profile) PROFILE="${2:?}"; shift 2 ;;
        *) echo "usage: $0 [--identity \"Developer ID Application: …\"] [--notary-profile NAME]" >&2; exit 2 ;;
    esac
done
if [[ -n "$PROFILE" && -z "$IDENTITY" ]]; then echo "Notarization needs --identity with a Developer ID certificate." >&2; exit 2; fi

APP_NAME="OpenWhisper"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Resources/Info.plist)"
APP="$ROOT_DIR/dist/$APP_NAME.app"
ZIP="$ROOT_DIR/dist/$APP_NAME.zip"

./script/build_and_run.sh --build

# Hardened runtime with the microphone entitlement (required for notarization, harmless otherwise).
if [[ -n "$IDENTITY" ]]; then
    codesign --force --options runtime --timestamp --entitlements Resources/OpenWhisper.entitlements --sign "$IDENTITY" "$APP"
else
    # Identity rule = bundle identifier, so macOS keeps microphone and Accessibility permissions across updates.
    codesign --force --options runtime --entitlements Resources/OpenWhisper.entitlements --sign - \
        --requirements "=designated => identifier \"$BUNDLE_ID\"" "$APP"
fi
codesign --verify --deep --strict "$APP"

rm -f "${ZIP:?}" "${ZIP:?}.sha256"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
if [[ -n "$PROFILE" ]]; then
    xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "${ZIP:?}"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
fi
(cd "$ROOT_DIR/dist" && shasum -a 256 "$APP_NAME.zip" > "$APP_NAME.zip.sha256")
echo "Built $ZIP"
cat "$ZIP.sha256"
