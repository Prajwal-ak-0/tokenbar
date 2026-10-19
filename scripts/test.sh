#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/.build"
SOURCE_DIR="$PROJECT_DIR/Sources/TokenBar"
MODULE_CACHE="$BUILD_DIR/ModuleCache"

/bin/mkdir -p "$BUILD_DIR" "$MODULE_CACHE"
/usr/bin/clang \
    -fobjc-arc \
    -fmodules \
    -fmodules-cache-path="$MODULE_CACHE" \
    -mmacosx-version-min=14.0 \
    -framework Foundation \
    -I "$SOURCE_DIR" \
    "$SOURCE_DIR/TBUsageModels.m" \
    "$PROJECT_DIR/Tests/parser_tests.m" \
    -o "$BUILD_DIR/parser_tests"

"$BUILD_DIR/parser_tests"

/usr/bin/clang \
    -fobjc-arc \
    -fmodules \
    -fmodules-cache-path="$MODULE_CACHE" \
    -mmacosx-version-min=14.0 \
    -framework Foundation \
    -framework Security \
    -framework LocalAuthentication \
    -I "$SOURCE_DIR" \
    "$SOURCE_DIR/TBUsageModels.m" \
    "$SOURCE_DIR/TBUsageServices.m" \
    "$PROJECT_DIR/Tests/claude_service_tests.m" \
    -o "$BUILD_DIR/claude_service_tests"

"$BUILD_DIR/claude_service_tests"
