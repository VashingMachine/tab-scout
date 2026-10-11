#!/bin/bash
set -euo pipefail
if [[ $# -ne 1 ]]; then
    printf 'Usage: %s /path/to/Tab\ Scout\ Safari.app\n' "$0" >&2
    exit 1
fi
APP_DIR="$1"
EXTENSION_DIR="$APP_DIR/Contents/PlugIns/Tab Scout Extension.appex"
SOURCE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NODE_BINARY="${TAB_SCOUT_NODE_BINARY:-node}"
if ! command -v "$NODE_BINARY" >/dev/null 2>&1; then
    printf 'Node.js is required for Safari packaging tests.\n' >&2
    exit 1
fi
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

assert_plist_value() {
    local file="$1" key="$2" expected="$3"
    local actual
    actual="$(/usr/libexec/PlistBuddy -c "Print :$key" "$file")"
    if [[ "$actual" != "$expected" ]]; then
        printf 'Expected %s = %s in %s; got %s\n' "$key" "$expected" "$file" "$actual" >&2
        exit 1
    fi
}

assert_plist_value "$APP_DIR/Contents/Info.plist" CFBundleIdentifier local.tabscout.safari
assert_plist_value "$APP_DIR/Contents/Info.plist" CFBundlePackageType APPL
assert_plist_value "$EXTENSION_DIR/Contents/Info.plist" CFBundleIdentifier local.tabscout.safari.Extension
assert_plist_value "$EXTENSION_DIR/Contents/Info.plist" CFBundlePackageType 'XPC!'
assert_plist_value "$EXTENSION_DIR/Contents/Info.plist" NSExtension:NSExtensionPointIdentifier com.apple.Safari.web-extension
for bundle in "$APP_DIR" "$EXTENSION_DIR"; do
    if /usr/libexec/PlistBuddy -c 'Print :NSAppleEventsUsageDescription' "$bundle/Contents/Info.plist" >/dev/null 2>&1; then
        printf 'Safari package must not request Apple Events permission.\n' >&2
        exit 1
    fi
done
for bundle in "$APP_DIR" "$EXTENSION_DIR"; do
    /usr/bin/codesign --verify --strict "$bundle"
    /usr/bin/codesign -d --entitlements - --xml "$bundle" > "$TEMP_DIR/entitlements.plist" 2>/dev/null
    assert_plist_value "$TEMP_DIR/entitlements.plist" com.apple.security.app-sandbox true
    entitlement_json="$(/usr/bin/plutil -convert json -o - "$TEMP_DIR/entitlements.plist")"
    entitlement_count="$("$NODE_BINARY" -e 'console.log(Object.keys(JSON.parse(process.argv[1])).length)' "$entitlement_json")"
    if [[ "$entitlement_count" != 1 ]]; then
        printf 'Unexpected extra entitlements in %s\n' "$bundle" >&2
        exit 1
    fi
    executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$bundle/Contents/Info.plist")"
    if /usr/bin/nm -u "$bundle/Contents/MacOS/$executable" | /usr/bin/grep -Eq 'AXUIElement|AXIsProcessTrusted|CGEventTapCreate|AEDeterminePermissionToAutomateTarget|NSAppleScript'; then
        printf 'Legacy automation or accessibility symbol in %s\n' "$bundle" >&2
        exit 1
    fi
done
if /usr/bin/find "$APP_DIR" -type f \( -name '*.scpt' -o -name '*.applescript' -o -name 'History.db' \) -print | /usr/bin/grep -q .; then
    printf 'Legacy Safari automation/history resources found in bundle.\n' >&2
    exit 1
fi
if [[ ! -f "$EXTENSION_DIR/Contents/Resources/manifest.json" ]]; then
    printf 'Extension manifest is missing.\n' >&2
    exit 1
fi
while IFS= read -r -d '' source; do
    relative="${source#"$SOURCE_DIR/SafariExtension/"}"
    bundled="$EXTENSION_DIR/Contents/Resources/$relative"
    if [[ ! -f "$bundled" ]] || ! /usr/bin/cmp -s "$source" "$bundled"; then
        printf 'Missing or stale extension resource: %s\n' "$relative" >&2
        exit 1
    fi
done < <(/usr/bin/find "$SOURCE_DIR/SafariExtension" -type f ! -name '.DS_Store' -print0)
assert_plist_value "$APP_DIR/Contents/Info.plist" CFBundleShortVersionString "$(/usr/bin/plutil -extract version raw -o - "$EXTENSION_DIR/Contents/Resources/manifest.json")"
/usr/bin/codesign --verify --deep --strict "$APP_DIR"
printf 'Safari packaging checks passed.\n'
