#!/bin/bash
set -euo pipefail
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$SOURCE_DIR/SafariApp/Tab Scout/Tab Scout.xcodeproj"
CONFIGURATION="${TAB_SCOUT_CONFIGURATION:-Debug}"
APP_VERSION="$(/usr/bin/plutil -extract version raw -o - "$SOURCE_DIR/SafariExtension/manifest.json")"
BUILD_NUMBER="${TAB_SCOUT_BUILD_NUMBER:-1}"
WORK_DIR="${TAB_SCOUT_WORK_DIR:-$SOURCE_DIR/.build/safari}"
OUTPUT_DIR="${TAB_SCOUT_OUTPUT_DIR:-$SOURCE_DIR/.build/safari-output}"
APP_DIR="$OUTPUT_DIR/Tab Scout Safari.app"
EXTENSION_DIR="$APP_DIR/Contents/PlugIns/Tab Scout Extension.appex"

if [[ "$CONFIGURATION" != Debug && "$CONFIGURATION" != Release ]]; then
    printf 'TAB_SCOUT_CONFIGURATION must be Debug or Release.\n' >&2
    exit 1
fi
if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
    printf 'TAB_SCOUT_BUILD_NUMBER must be a positive integer.\n' >&2
    exit 1
fi
if [[ ! -d "$PROJECT" ]]; then
    printf 'Missing Safari Xcode project: %s\n' "$PROJECT" >&2
    exit 1
fi
"${TAB_SCOUT_NODE_BINARY:-node}" --test "$SOURCE_DIR/Tests/SafariProjectTests.mjs"
if [[ -e "$APP_DIR" ]]; then
    printf 'Refusing to overwrite %s. Choose an empty TAB_SCOUT_OUTPUT_DIR.\n' "$APP_DIR" >&2
    exit 1
fi
mkdir -p "$WORK_DIR" "$OUTPUT_DIR"

/usr/bin/xcrun xcodebuild -quiet -project "$PROJECT" -scheme 'Tab Scout' \
    -configuration "$CONFIGURATION" -derivedDataPath "$WORK_DIR/DerivedData" \
    -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO \
    MARKETING_VERSION="$APP_VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" clean build
/usr/bin/ditto "$WORK_DIR/DerivedData/Build/Products/$CONFIGURATION/Tab Scout.app" "$APP_DIR"

# Sign nested code first; the outer seal then includes the final extension signature.
IDENTITY="${TAB_SCOUT_SIGN_IDENTITY:--}"
SIGNING_OPTIONS=(--options runtime)
if [[ "$IDENTITY" == - ]]; then
    SIGNING_OPTIONS+=(--timestamp=none)
fi
/usr/bin/codesign --force --sign "$IDENTITY" "${SIGNING_OPTIONS[@]}" \
    --entitlements "$SOURCE_DIR/SafariApp/Entitlements.plist" "$EXTENSION_DIR"
/usr/bin/codesign --force --sign "$IDENTITY" "${SIGNING_OPTIONS[@]}" \
    --entitlements "$SOURCE_DIR/SafariApp/Entitlements.plist" "$APP_DIR"
/usr/bin/codesign --verify --deep --strict "$APP_DIR"
"$SOURCE_DIR/Tests/SafariPackagingTests.sh" "$APP_DIR"
printf 'Built sandboxed Safari extension: %s\n' "$APP_DIR"
if [[ "$IDENTITY" == - ]]; then
    printf 'Ad-hoc build for local testing only; App Store submission needs Apple signing and provisioning.\n'
fi
