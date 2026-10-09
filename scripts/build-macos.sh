#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
APP_DIR="${CLIPSHELF_APP_OUTPUT:-$PROJECT_ROOT/build/ClipShelf.app}"
SWIFT_BUILD_PATH="${CLIPSHELF_SWIFT_BUILD_PATH:-$PROJECT_ROOT/native/.build}"
DISTRIBUTION="${CLIPSHELF_DISTRIBUTION:-development}"
case "$DISTRIBUTION" in
    development) ;;
    release)
        SIGNING_PATTERN='^Developer ID Application: .+ \([A-Z0-9]{10}\)$'
        if [[ ! "${CODESIGN_IDENTITY:-}" =~ $SIGNING_PATTERN ]]; then
            echo "Release configuration requires an explicit Developer ID Application signing identity." >&2
            exit 1
        fi
        python3 "$PROJECT_ROOT/scripts/configure-release.py" --validate
        ;;
    *) echo "Unsupported CLIPSHELF_DISTRIBUTION: $DISTRIBUTION" >&2; exit 1 ;;
esac

swift build --disable-keychain --disable-netrc --package-path "$PROJECT_ROOT/native" --scratch-path "$SWIFT_BUILD_PATH" --configuration "$CONFIGURATION" --product ClipShelf
BIN_DIR="$(swift build --disable-keychain --disable-netrc --package-path "$PROJECT_ROOT/native" --scratch-path "$SWIFT_BUILD_PATH" --configuration "$CONFIGURATION" --show-bin-path)"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/ClipShelf" "$APP_DIR/Contents/MacOS/ClipShelf"
cp "$PROJECT_ROOT/native/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_ROOT/native/Sources/ClipShelf/Sparkle-LICENSE.txt" "$APP_DIR/Contents/Resources/Sparkle-LICENSE.txt"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${BUNDLE_IDENTIFIER:-io.github.bestbbb.clipshelf.dev}" "$APP_DIR/Contents/Info.plist"
if [[ "$DISTRIBUTION" == "release" ]]; then
    python3 "$PROJECT_ROOT/scripts/configure-release.py" --plist "$APP_DIR/Contents/Info.plist"
fi
if [[ "$DISTRIBUTION" == "development" && -n "${ICLOUD_CONTAINER_IDENTIFIER:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Add :ClipShelfCloudKitContainerIdentifier string $ICLOUD_CONTAINER_IDENTIFIER" "$APP_DIR/Contents/Info.plist"
fi
if [[ -n "${PROVISIONING_PROFILE_PATH:-}" ]]; then
    cp "$PROVISIONING_PROFILE_PATH" "$APP_DIR/Contents/embedded.provisionprofile"
elif [[ -f "$APP_DIR/Contents/embedded.provisionprofile" ]]; then
    rm "$APP_DIR/Contents/embedded.provisionprofile"
fi
bash "$PROJECT_ROOT/scripts/build-app-intents.sh" "$BIN_DIR" "$APP_DIR/Contents/Resources"
bash "$PROJECT_ROOT/scripts/embed-sparkle.sh" "$BIN_DIR/Sparkle.framework" "$APP_DIR" "${CODESIGN_IDENTITY:--}"
/usr/bin/plutil -lint "$APP_DIR/Contents/Info.plist"
SIGNING_ARGS=(--force --sign "${CODESIGN_IDENTITY:--}")
if [[ -n "${CODESIGN_IDENTITY:-}" && "$CODESIGN_IDENTITY" != "-" ]]; then
    SIGNING_ARGS+=(--options runtime --timestamp)
fi
if [[ -n "${ENTITLEMENTS_PATH:-}" ]]; then
    SIGNING_ARGS+=(--entitlements "$ENTITLEMENTS_PATH")
fi
/usr/bin/codesign "${SIGNING_ARGS[@]}" "$APP_DIR"
/usr/bin/codesign --verify --deep --strict "$APP_DIR"
echo "Built: $APP_DIR"
echo "This development build is not notarized. Demo: open '$APP_DIR' --args --demo"
