#!/bin/bash
set -euo pipefail
if [[ $# -ne 1 ]]; then
    printf 'Usage: %s /path/to/Tab\ Scout\ Safari.app\n' "$0" >&2
    exit 1
fi
SOURCE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHECKER="$SOURCE_DIR/Tests/SafariPackagingTests.sh"
ORIGINAL_APP="$1"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
CANDIDATE="$TEMP_DIR/Tab Scout.app"

copy_fixture() {
    if [[ -d "$CANDIDATE" ]]; then
        rm -rf "$CANDIDATE"
    fi
    /usr/bin/ditto "$ORIGINAL_APP" "$CANDIDATE"
}

sign_fixture() {
    /usr/bin/codesign --force --sign - --timestamp=none \
        --entitlements "$SOURCE_DIR/SafariApp/Entitlements.plist" \
        "$CANDIDATE/Contents/PlugIns/Tab Scout Extension.appex" >/dev/null 2>&1
    /usr/bin/codesign --force --sign - --timestamp=none \
        --entitlements "$SOURCE_DIR/SafariApp/Entitlements.plist" "$CANDIDATE" >/dev/null 2>&1
}

expect_failure() {
    local expected="$1"
    if "$CHECKER" "$CANDIDATE" > "$TEMP_DIR/result.log" 2>&1; then
        printf 'Packaging regression was incorrectly accepted: %s\n' "$expected" >&2
        exit 1
    fi
    if ! /usr/bin/grep -Fq "$expected" "$TEMP_DIR/result.log"; then
        printf 'Wrong packaging rejection; expected %s\n' "$expected" >&2
        /bin/cat "$TEMP_DIR/result.log" >&2
        exit 1
    fi
}

"$CHECKER" "$ORIGINAL_APP"

copy_fixture
/usr/bin/plutil -replace CFBundleIdentifier -string local.tabscout.wrong "$CANDIDATE/Contents/Info.plist"
sign_fixture
expect_failure 'Expected CFBundleIdentifier = local.tabscout.safari'

copy_fixture
/bin/cp "$SOURCE_DIR/SafariApp/Host/AppDelegate.swift" "$CANDIDATE/Contents/Resources/SafariBridge.applescript"
sign_fixture
expect_failure 'Legacy Safari automation/history resources found'

copy_fixture
/bin/cp "$SOURCE_DIR/SafariApp/Entitlements.plist" "$TEMP_DIR/broad-entitlements.plist"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.automation.apple-events bool true' "$TEMP_DIR/broad-entitlements.plist"
/usr/bin/codesign --force --sign - --timestamp=none --entitlements "$TEMP_DIR/broad-entitlements.plist" "$CANDIDATE" >/dev/null 2>&1
expect_failure 'Unexpected extra entitlements'

copy_fixture
/usr/bin/plutil -replace name -string 'Stale Test' "$CANDIDATE/Contents/PlugIns/Tab Scout Extension.appex/Contents/Resources/manifest.json"
sign_fixture
expect_failure 'Missing or stale extension resource: manifest.json'

printf 'Safari packaging regression tests passed (5 scenarios).\n'
