#!/bin/bash
set -euo pipefail
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
node --test "$SOURCE_DIR/Tests/SafariManifestTests.mjs" "$SOURCE_DIR/Tests/SafariProjectTests.mjs" "$SOURCE_DIR"/Tests/WebExtension/*.test.mjs
for source in "$SOURCE_DIR"/SafariExtension/*.mjs; do
    node --check "$source"
done
/usr/bin/plutil -lint "$SOURCE_DIR/SafariApp/Entitlements.plist"
bash -n "$SOURCE_DIR/build-safari.sh"
printf 'Safari extension tests and source validation passed\n'
