#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="${1:?Pass the SwiftPM binary directory}"
OUTPUT_DIR="${2:?Pass the app Resources directory}"
STAGING="$PROJECT_ROOT/build/AppIntents"
TOOLCHAIN_DIR="$(dirname "$(dirname "$(dirname "$(xcrun --find swiftc)")")")"
SDK_ROOT="$(xcrun --sdk macosx --show-sdk-path)"
XCODE_BUILD="$(xcodebuild -version | awk '/Build version/{print $3}')"
TARGET_TRIPLE="$(uname -m)-apple-macosx14.0"
SOURCE="$PROJECT_ROOT/native/Sources/ClipShelf/ClipboardIntents.swift"
mkdir -p "$STAGING" "$OUTPUT_DIR"

# The SDK catalog wraps the protocol list; Swift's frontend accepts the array.
plutil -extract constValueProtocols json -o "$STAGING/protocols.json" \
    "$TOOLCHAIN_DIR/usr/share/swift/SwiftConstantValues/AppIntents.json"
xcrun swiftc -c -parse-as-library -swift-version 5 -module-name ClipShelf \
    -target "$TARGET_TRIPLE" -sdk "$SDK_ROOT" \
    -I "$BIN_DIR/Modules" -I "$PROJECT_ROOT/native/Sources/CSQLite" \
    "$SOURCE" -o "$STAGING/ClipboardIntents.o" \
    -Xfrontend -emit-const-values-path -Xfrontend "$STAGING/intents.swiftconstvalues" \
    -Xfrontend -const-gather-protocols-file -Xfrontend "$STAGING/protocols.json"
printf '%s\n' "$SOURCE" > "$STAGING/sources.list"
printf '%s\n' "$STAGING/intents.swiftconstvalues" > "$STAGING/values.list"
xcrun appintentsmetadataprocessor --output "$OUTPUT_DIR" \
    --toolchain-dir "$TOOLCHAIN_DIR" --module-name ClipShelf --sdk-root "$SDK_ROOT" \
    --xcode-version "$XCODE_BUILD" --platform-family macOS --deployment-target 14.0 \
    --target-triple "$TARGET_TRIPLE" --source-file-list "$STAGING/sources.list" \
    --swift-const-vals-list "$STAGING/values.list"
test -d "$OUTPUT_DIR/Metadata.appintents"
