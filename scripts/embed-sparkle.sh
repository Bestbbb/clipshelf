#!/bin/bash
set -euo pipefail

# Official Sparkle binary copied into an already-created app bundle. Preserve the
# versioned framework's symlinks; signing the outer app alone is not sufficient.
SOURCE_FRAMEWORK="${1:?Pass the resolved Sparkle.framework}"
APP_DIR="${2:?Pass the destination .app bundle}"
SIGNING_IDENTITY="${3:--}"
FRAMEWORKS_DIR="$APP_DIR/Contents/Frameworks"
FRAMEWORK="$FRAMEWORKS_DIR/Sparkle.framework"

fail() { echo "Sparkle embedding failed: $*" >&2; exit 1; }
[[ "$APP_DIR" == *.app && -d "$APP_DIR/Contents/MacOS" ]] || fail "invalid app bundle"
[[ ! -L "$APP_DIR" && ! -L "$APP_DIR/Contents" && ! -L "$FRAMEWORKS_DIR" ]] || fail "bundle destination must not be a symlink"
[[ -d "$SOURCE_FRAMEWORK/Versions/B" && -L "$SOURCE_FRAMEWORK/Versions/Current" ]] || fail "missing versioned framework"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE_FRAMEWORK/Resources/Info.plist")" == "2.10.0" ]] || fail "expected pinned Sparkle 2.10.0"
[[ "$(readlink "$SOURCE_FRAMEWORK/Versions/Current")" == "B" ]] || fail "unexpected framework version link"

mkdir -p "$FRAMEWORKS_DIR"
STAGING="$(mktemp -d "$FRAMEWORKS_DIR/.sparkle-embed.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
/usr/bin/ditto "$SOURCE_FRAMEWORK" "$STAGING/Sparkle.framework"
STAGED_FRAMEWORK="$STAGING/Sparkle.framework"

SIGNING_ARGS=(--force --sign "$SIGNING_IDENTITY")
if [[ "${CLIPSHELF_LOCAL_SIGNING:-}" == "1" ]]; then
    SIGNING_ARGS+=(--keychain "$CLIPSHELF_SIGNING_KEYCHAIN" --timestamp=none)
elif [[ "$SIGNING_IDENTITY" != "-" ]]; then
    SIGNING_ARGS+=(--options runtime --timestamp)
fi
# Follow Sparkle's documented inside-out order. Do not pass the host app's
# entitlements to helper code or use --deep to sign different nested targets.
for NESTED in XPCServices/Installer.xpc XPCServices/Downloader.xpc Autoupdate Updater.app; do
    [[ -e "$STAGED_FRAMEWORK/Versions/B/$NESTED" ]] || fail "missing helper $NESTED"
    if [[ "$NESTED" == "XPCServices/Downloader.xpc" ]]; then
        /usr/bin/codesign "${SIGNING_ARGS[@]}" --preserve-metadata=entitlements "$STAGED_FRAMEWORK/Versions/B/$NESTED"
    else
        /usr/bin/codesign "${SIGNING_ARGS[@]}" "$STAGED_FRAMEWORK/Versions/B/$NESTED"
    fi
done
/usr/bin/codesign "${SIGNING_ARGS[@]}" "$STAGED_FRAMEWORK"
/usr/bin/codesign --verify --deep --strict "$STAGED_FRAMEWORK"
[[ -L "$STAGED_FRAMEWORK/Sparkle" && -L "$STAGED_FRAMEWORK/Resources" ]] || fail "framework links were not preserved"

# Replace only this generated framework after its staged copy has passed checks.
rm -rf "$FRAMEWORK"
mv "$STAGED_FRAMEWORK" "$FRAMEWORK"
echo "Embedded Sparkle 2.10.0: $FRAMEWORK"
