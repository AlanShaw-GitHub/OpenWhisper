#!/usr/bin/env bash
# Builds dist/OpenWhisper.app from source and, by default, launches it.
#
#   ./script/build_and_run.sh              build the optimized app and launch it
#   ./script/build_and_run.sh --install    build it and copy it to /Applications (or ~/Applications)
#   ./script/build_and_run.sh --build      build only
#   ./script/build_and_run.sh --diagnostics  development build with test entry points (OPENWHISPER_DIAGNOSTICS)
#   ./script/build_and_run.sh --fixture    build the accessibility test window used by the diagnostics
#   ./script/build_and_run.sh --logs | --telemetry | --verify | --debug
#
# Everything is built locally and signed ad hoc, so macOS does not quarantine the app.
set -euo pipefail
MODE="${1:-run}"
APP_NAME="OpenWhisper"
# The app's identity for macOS: permissions, settings and logs are keyed to it.
BUNDLE_ID="com.alan.wisper"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
USAGE="usage: $0 [run|--install|--build|--diagnostics|--fixture|--logs|--telemetry|--verify|--debug]"
case "$MODE" in run|--install|--verify|--build|--logs|--telemetry|--diagnostics|--fixture|--debug) ;; *) echo "$USAGE" >&2; exit 2 ;; esac
if ! command -v swift >/dev/null 2>&1; then
    echo "Swift was not found. Install Xcode, or run: xcode-select --install" >&2
    exit 1
fi

if [[ "$MODE" == "--fixture" ]]; then
    # A small AppKit text editor that the diagnostics type into (modes: --plain, --delayed-caret, --move-caret, ...).
    FIXTURE="$ROOT_DIR/.build/OpenWhisperAXFixture.app"
    mkdir -p "$FIXTURE/Contents/MacOS"
    swiftc -O -framework AppKit "$ROOT_DIR/script/AXInputFixture.swift" -o "$FIXTURE/Contents/MacOS/AXInputFixture"
    /usr/libexec/PlistBuddy -c "Clear dict" \
        -c "Add :CFBundleExecutable string AXInputFixture" -c "Add :CFBundleIdentifier string $BUNDLE_ID.axfixture" \
        -c "Add :CFBundleName string OpenWhisperAXFixture" -c "Add :CFBundlePackageType string APPL" \
        -c "Add :NSHighResolutionCapable bool true" "$FIXTURE/Contents/Info.plist" >/dev/null 2>&1 || true
    codesign --force --sign - "$FIXTURE"
    echo "Built $FIXTURE"
    exit 0
fi
pkill -x "$APP_NAME" >/dev/null 2>&1 || true

BUILD_CONFIG="release"
BUILD_PATH="$ROOT_DIR/.build"
EXTRA_FLAGS=()
case "$MODE" in
  --diagnostics) BUILD_CONFIG="debug"; BUILD_PATH="$ROOT_DIR/.build/diagnostics"; EXTRA_FLAGS+=(-Xswiftc -DOPENWHISPER_DIAGNOSTICS) ;;
  --debug) BUILD_CONFIG="debug" ;;
esac
mkdir -p "$ROOT_DIR/.build/module-cache" "$ROOT_DIR/.build/clang-cache"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/clang-cache"
SWIFT_OPTIONS=(--disable-sandbox --build-path "$BUILD_PATH" --cache-path "$ROOT_DIR/.build/swift-cache" --config-path "$ROOT_DIR/.build/swift-config" --security-path "$ROOT_DIR/.build/swift-security")
swift build -c "$BUILD_CONFIG" "${SWIFT_OPTIONS[@]}" ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} -Xswiftc -module-cache-path -Xswiftc "$ROOT_DIR/.build/module-cache"
BIN_DIR="$(swift build -c "$BUILD_CONFIG" --show-bin-path "${SWIFT_OPTIONS[@]}")"

APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
rm -rf "${APP_BUNDLE:?}"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
if [[ ! -f "$ROOT_DIR/Resources/AppIcon.icns" ]]; then
    swift "$ROOT_DIR/script/generate_icon.swift" "$ROOT_DIR/.build/AppIcon.iconset"
    iconutil -c icns "$ROOT_DIR/.build/AppIcon.iconset" -o "$ROOT_DIR/Resources/AppIcon.icns"
fi
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
# String tables ship as binary property lists: smaller and parsed faster than the text source.
for lproj in "$ROOT_DIR"/Resources/*.lproj; do
    target="$APP_BUNDLE/Contents/Resources/$(basename "$lproj")"
    mkdir -p "$target"
    for strings in "$lproj"/*.strings; do plutil -convert binary1 -o "$target/$(basename "$strings")" "$strings"; done
done
if [[ "$BUILD_CONFIG" == "release" ]]; then
    # Keep the symbols beside the app for crash reports, then drop them from the shipped binary.
    rm -rf "${ROOT_DIR:?}/dist/${APP_NAME:?}.dSYM"
    dsymutil "$APP_BUNDLE/Contents/MacOS/$APP_NAME" -o "$ROOT_DIR/dist/$APP_NAME.dSYM" 2>/dev/null || true
    strip -x "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null
fi
# Ad-hoc signature whose designated requirement is the identifier alone, so macOS keeps the microphone and
# Accessibility permissions across rebuilds instead of asking again after every build.
codesign --force --sign - --identifier "$BUNDLE_ID" --requirements "=designated => identifier \"$BUNDLE_ID\"" "$APP_BUNDLE"

case "$MODE" in
  --build) echo "Built $APP_BUNDLE ($BUILD_CONFIG)" ;;
  --diagnostics) echo "Built $APP_BUNDLE with diagnostics" ;;
  --install)
    DEST="/Applications"
    [[ -w "$DEST" ]] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
    rm -rf "${DEST:?}/${APP_NAME:?}.app"
    ditto "$APP_BUNDLE" "$DEST/$APP_NAME.app"
    echo "Installed $DEST/$APP_NAME.app"
    /usr/bin/open "$DEST/$APP_NAME.app" ;;
  --debug) lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ;;
  --logs) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\"" ;;
  --telemetry) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\"" ;;
  --verify) /usr/bin/open -n "$APP_BUNDLE"; sleep 1; pgrep -x "$APP_NAME" >/dev/null; echo "$APP_NAME launched successfully" ;;
  run) /usr/bin/open -n "$APP_BUNDLE" ;;
esac
