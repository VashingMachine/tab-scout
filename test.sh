#!/bin/bash
set -euo pipefail
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="${TAB_SCOUT_WORK_DIR:-$SOURCE_DIR/.build}/tests"
mkdir -p "$WORK_DIR"
/usr/bin/xcrun swiftc -swift-version 5 "$SOURCE_DIR/Sources/Core.swift" \
    "$SOURCE_DIR/Tests/CoreTests.swift" -o "$WORK_DIR/CoreTests"
"$WORK_DIR/CoreTests"
for SUITE in Cache Performance; do
    /usr/bin/xcrun swiftc -swift-version 5 -O "$SOURCE_DIR/Sources/Core.swift" \
        "$SOURCE_DIR/Sources/TabStore.swift" "$SOURCE_DIR/Tests/${SUITE}Tests.swift" -o "$WORK_DIR/${SUITE}Tests"
    "$WORK_DIR/${SUITE}Tests"
done
/usr/bin/xcrun swiftc -swift-version 5 "$SOURCE_DIR/Sources/Core.swift" \
    "$SOURCE_DIR/Sources/SearchResults.swift" "$SOURCE_DIR/Tests/SearchResultsTests.swift" -o "$WORK_DIR/SearchResultsTests"
"$WORK_DIR/SearchResultsTests"
/usr/bin/xcrun swiftc -swift-version 5 "$SOURCE_DIR/Sources/Core.swift" \
    "$SOURCE_DIR/Sources/SafariBridge.swift" "$SOURCE_DIR/Tests/BridgeTests.swift" -o "$WORK_DIR/BridgeTests"
"$WORK_DIR/BridgeTests"
/usr/bin/xcrun swiftc -swift-version 5 "$SOURCE_DIR/Sources/Favicon.swift" \
    "$SOURCE_DIR/Tests/FaviconTests.swift" -o "$WORK_DIR/FaviconTests"
"$WORK_DIR/FaviconTests"
/usr/bin/xcrun swiftc -swift-version 5 "$SOURCE_DIR/Sources/ResultCell.swift" \
    "$SOURCE_DIR/Tests/ResultCellTests.swift" -o "$WORK_DIR/ResultCellTests"
"$WORK_DIR/ResultCellTests"
/usr/bin/osacompile -o "$WORK_DIR/SafariBridge.scpt" "$SOURCE_DIR/Resources/SafariBridge.applescript"
/usr/bin/osascript "$SOURCE_DIR/Tests/BridgeSnapshotTests.applescript" "$WORK_DIR/SafariBridge.scpt"
/usr/bin/plutil -lint "$SOURCE_DIR/Resources/Info.plist" "$SOURCE_DIR/Resources/Entitlements.plist"
