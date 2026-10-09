#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
APP_DIR="$PROJECT_ROOT/build/ClipShelf.app"

swift build --package-path "$PROJECT_ROOT/native" --configuration "$CONFIGURATION" --product ClipShelf
BIN_DIR="$(swift build --package-path "$PROJECT_ROOT/native" --configuration "$CONFIGURATION" --show-bin-path)"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/ClipShelf" "$APP_DIR/Contents/MacOS/ClipShelf"
cp "$PROJECT_ROOT/native/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${BUNDLE_IDENTIFIER:-io.github.bestbbb.clipshelf.dev}" "$APP_DIR/Contents/Info.plist"
if [[ -n "${ICLOUD_CONTAINER_IDENTIFIER:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Add :ClipShelfCloudKitContainerIdentifier string $ICLOUD_CONTAINER_IDENTIFIER" "$APP_DIR/Contents/Info.plist"
fi
if [[ -n "${PROVISIONING_PROFILE_PATH:-}" ]]; then
    cp "$PROVISIONING_PROFILE_PATH" "$APP_DIR/Contents/embedded.provisionprofile"
elif [[ -f "$APP_DIR/Contents/embedded.provisionprofile" ]]; then
    rm "$APP_DIR/Contents/embedded.provisionprofile"
fi
bash "$PROJECT_ROOT/scripts/build-app-intents.sh" "$BIN_DIR" "$APP_DIR/Contents/Resources"
/usr/bin/plutil -lint "$APP_DIR/Contents/Info.plist"
SIGNING_ARGS=(--force --sign "${CODESIGN_IDENTITY:--}")
if [[ -n "${CODESIGN_IDENTITY:-}" && "$CODESIGN_IDENTITY" != "-" ]]; then
    SIGNING_ARGS+=(--options runtime --timestamp)
fi
if [[ -n "${ENTITLEMENTS_PATH:-}" ]]; then
    SIGNING_ARGS+=(--entitlements "$ENTITLEMENTS_PATH")
fi
/usr/bin/codesign "${SIGNING_ARGS[@]}" "$APP_DIR"
/usr/bin/codesign --verify --strict "$APP_DIR"
echo "Built: $APP_DIR"
echo "This development build is not notarized. Demo: open '$APP_DIR' --args --demo"
