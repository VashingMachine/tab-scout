#!/bin/bash
set -euo pipefail
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${TAB_SCOUT_OUTPUT_DIR:-$(dirname "$SOURCE_DIR")}"
APP_DIR="$OUTPUT_DIR/Tab Scout.app"
WORK_DIR="${TAB_SCOUT_WORK_DIR:-$SOURCE_DIR/.build}/build"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$WORK_DIR"
cp "$SOURCE_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
/usr/bin/osacompile -o "$APP_DIR/Contents/Resources/SafariBridge.scpt" "$SOURCE_DIR/Resources/SafariBridge.applescript"
/usr/bin/xcrun swiftc "$SOURCE_DIR/Resources/MakeIcon.swift" -o "$WORK_DIR/MakeIcon"
"$WORK_DIR/MakeIcon" "$WORK_DIR/TabScout.iconset"
/usr/bin/iconutil -c icns "$WORK_DIR/TabScout.iconset" -o "$APP_DIR/Contents/Resources/TabScout.icns"
/usr/bin/xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx13.0" \
    -module-cache-path "$WORK_DIR/ModuleCache" \
    "$SOURCE_DIR"/Sources/*.swift -lsqlite3 -o "$APP_DIR/Contents/MacOS/TabScout"
/usr/bin/codesign --force --sign "${TAB_SCOUT_SIGN_IDENTITY:--}" --identifier local.tabscout.app \
    --entitlements "$SOURCE_DIR/Resources/Entitlements.plist" "$APP_DIR"
/usr/bin/codesign --verify --strict "$APP_DIR"
printf 'Built %s\n' "$APP_DIR"
