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

# A stable local certificate preserves the app's designated requirement across
# edits. Ad-hoc signatures are content hashes and cannot provide that identity.
LOCAL_SIGNING_DIR="${CLIPSHELF_LOCAL_SIGNING_DIR:-$HOME/Library/Application Support/ClipShelf Development Signing}"
if [[ "$DISTRIBUTION" == "development" && -z "${CODESIGN_IDENTITY:-}" && -f "$LOCAL_SIGNING_DIR/identity.txt" ]]; then
    LOCAL_SIGNING_CANDIDATE="$(cat "$LOCAL_SIGNING_DIR/identity.txt")"
    [[ "$LOCAL_SIGNING_CANDIDATE" =~ ^[A-F0-9]{40}$ ]] || { echo "Invalid local signing identity" >&2; exit 1; }
    LOCAL_SIGNING_MATCHES="$(/usr/bin/security find-identity -v -p codesigning "$LOCAL_SIGNING_DIR/development.keychain-db")"
    if [[ "$LOCAL_SIGNING_MATCHES" == *"$LOCAL_SIGNING_CANDIDATE"* ]]; then
        CODESIGN_IDENTITY="$LOCAL_SIGNING_CANDIDATE"
        export CLIPSHELF_SIGNING_KEYCHAIN="$LOCAL_SIGNING_DIR/development.keychain-db"
        export CLIPSHELF_LOCAL_SIGNING=1
        /usr/bin/security unlock-keychain -p "$(cat "$LOCAL_SIGNING_DIR/keychain-password")" "$CLIPSHELF_SIGNING_KEYCHAIN"
        export CODESIGN_IDENTITY
        # codesign also needs this keychain in the search list, even when its
        # --keychain argument is explicit. Restore that list when the build ends.
        exec python3 "$PROJECT_ROOT/scripts/with-local-signing.py" "$PROJECT_ROOT/scripts/build-macos.sh"
    else
        echo "Local signing certificate is not trusted for code signing; using an ad-hoc preview build. Accessibility may require reauthorization." >&2
    fi
elif [[ "$DISTRIBUTION" == "release" ]]; then
    unset CLIPSHELF_LOCAL_SIGNING CLIPSHELF_SIGNING_KEYCHAIN
fi

swift build --disable-keychain --disable-netrc --package-path "$PROJECT_ROOT/native" --scratch-path "$SWIFT_BUILD_PATH" --configuration "$CONFIGURATION" --product ClipShelf
BIN_DIR="$(swift build --disable-keychain --disable-netrc --package-path "$PROJECT_ROOT/native" --scratch-path "$SWIFT_BUILD_PATH" --configuration "$CONFIGURATION" --show-bin-path)"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/ClipShelf" "$APP_DIR/Contents/MacOS/ClipShelf"
cp "$PROJECT_ROOT/native/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_ROOT/native/Sources/ClipShelf/Sparkle-LICENSE.txt" "$APP_DIR/Contents/Resources/Sparkle-LICENSE.txt"
LOCALIZATION_BUNDLE="ClipShelf_ClipShelfLocalization.bundle"
test -d "$BIN_DIR/$LOCALIZATION_BUNDLE"
# The CLI SwiftPM build leaves package resources next to its executable. The
# delivered app resolves this bundle from its own Resources directory.
ditto "$BIN_DIR/$LOCALIZATION_BUNDLE" "$APP_DIR/Contents/Resources/$LOCALIZATION_BUNDLE"
for LANGUAGE in en zh-Hans zh-Hant cs da nl fr de he it ja ko pl pt ru es; do
    ditto "$PROJECT_ROOT/native/Sources/ClipShelf/Resources/$LANGUAGE.lproj" \
        "$APP_DIR/Contents/Resources/$LANGUAGE.lproj"
done
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
python3 "$PROJECT_ROOT/scripts/verify-localization.py" --app "$APP_DIR"
bash "$PROJECT_ROOT/scripts/embed-sparkle.sh" "$BIN_DIR/Sparkle.framework" "$APP_DIR" "${CODESIGN_IDENTITY:--}"
/usr/bin/plutil -lint "$APP_DIR/Contents/Info.plist"
SIGNING_ARGS=(--force --sign "${CODESIGN_IDENTITY:--}")
if [[ "${CLIPSHELF_LOCAL_SIGNING:-}" == "1" ]]; then
    SIGNING_ARGS+=(--keychain "$CLIPSHELF_SIGNING_KEYCHAIN" --timestamp=none)
elif [[ -n "${CODESIGN_IDENTITY:-}" && "$CODESIGN_IDENTITY" != "-" ]]; then
    SIGNING_ARGS+=(--options runtime --timestamp)
fi
if [[ -n "${ENTITLEMENTS_PATH:-}" ]]; then
    SIGNING_ARGS+=(--entitlements "$ENTITLEMENTS_PATH")
fi
/usr/bin/codesign "${SIGNING_ARGS[@]}" "$APP_DIR"
/usr/bin/codesign --verify --deep --strict "$APP_DIR"
echo "Built: $APP_DIR"
/usr/bin/codesign -d -r- "$APP_DIR" 2>&1
echo "This development build is not notarized. Demo: open '$APP_DIR' --args --demo"
