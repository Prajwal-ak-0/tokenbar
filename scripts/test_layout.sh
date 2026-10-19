#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/.build"
SOURCE_DIR="$PROJECT_DIR/Sources/TokenBar"

/bin/mkdir -p "$BUILD_DIR/ModuleCache"
/usr/bin/clang \
    -fobjc-arc \
    -fmodules \
    -fmodules-cache-path="$BUILD_DIR/ModuleCache" \
    -mmacosx-version-min=14.0 \
    -framework AppKit \
    -framework Foundation \
    -framework Security \
    -framework LocalAuthentication \
    -framework ServiceManagement \
    -I "$SOURCE_DIR" \
    "$SOURCE_DIR/TBUsageModels.m" \
    "$SOURCE_DIR/TBUsageServices.m" \
    "$PROJECT_DIR/Tests/layout_tests.m" \
    -o "$BUILD_DIR/layout_tests"

"$BUILD_DIR/layout_tests"
