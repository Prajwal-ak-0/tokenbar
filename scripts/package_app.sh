#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="TokenBar"
BUILD_DIR="$PROJECT_DIR/.build"
DIST_DIR="$PROJECT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
SOURCE_DIR="$PROJECT_DIR/Sources/TokenBar"
MODULE_CACHE="$BUILD_DIR/ModuleCache"

/bin/mkdir -p "$BUILD_DIR" "$MODULE_CACHE" "$DIST_DIR"

/usr/bin/clang \
    -fobjc-arc \
    -fmodules \
    -fmodules-cache-path="$MODULE_CACHE" \
    -mmacosx-version-min=14.0 \
    -framework AppKit \
    -framework Foundation \
    -framework ServiceManagement \
    "$SOURCE_DIR/TBUsageModels.m" \
    "$SOURCE_DIR/TBUsageServices.m" \
    "$SOURCE_DIR/main.m" \
    -o "$BUILD_DIR/$APP_NAME"

if [[ -d "$APP_DIR" ]]; then
    /bin/rm -rf "$APP_DIR"
fi

/bin/mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
/bin/cp "$BUILD_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
/bin/cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
/usr/bin/codesign --force --deep --sign - "$APP_DIR"

echo "$APP_DIR"
