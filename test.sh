#!/bin/bash
set -euo pipefail
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="${TAB_SCOUT_WORK_DIR:-$SOURCE_DIR/.build}/tests"
mkdir -p "$WORK_DIR"
# Everything that decides which results appear and in what order.
RANKING=("$SOURCE_DIR/Sources/Core.swift" "$SOURCE_DIR/Sources/History.swift" "$SOURCE_DIR/Sources/SearchResults.swift"
    "$SOURCE_DIR/Sources/HistoryRanking.swift" "$SOURCE_DIR/Sources/TabRanking.swift")
/usr/bin/xcrun swiftc -swift-version 5 "$SOURCE_DIR/Sources/Core.swift" \
    "$SOURCE_DIR/Tests/CoreTests.swift" -o "$WORK_DIR/CoreTests"
"$WORK_DIR/CoreTests"
for SUITE in Cache Performance; do
    /usr/bin/xcrun swiftc -swift-version 5 -O "$SOURCE_DIR/Sources/Core.swift" \
        "$SOURCE_DIR/Sources/TabStore.swift" "$SOURCE_DIR/Tests/${SUITE}Tests.swift" -o "$WORK_DIR/${SUITE}Tests"
    "$WORK_DIR/${SUITE}Tests"
done
/usr/bin/xcrun swiftc -swift-version 5 "$SOURCE_DIR/Sources/Core.swift" \
    "$SOURCE_DIR/Sources/History.swift" "$SOURCE_DIR/Sources/SearchResults.swift" \
    "$SOURCE_DIR/Tests/SearchResultsTests.swift" -lsqlite3 -o "$WORK_DIR/SearchResultsTests"
"$WORK_DIR/SearchResultsTests"
/usr/bin/xcrun swiftc -swift-version 5 "$SOURCE_DIR/Sources/History.swift" \
    "$SOURCE_DIR/Tests/HistoryTests.swift" -lsqlite3 -o "$WORK_DIR/HistoryTests"
"$WORK_DIR/HistoryTests"
/usr/bin/xcrun swiftc -swift-version 5 -O "${RANKING[@]}" "$SOURCE_DIR/Tests/HistoryRankingTests.swift" \
    -lsqlite3 -o "$WORK_DIR/HistoryRankingTests"
"$WORK_DIR/HistoryRankingTests"
/usr/bin/xcrun swiftc -swift-version 5 "$SOURCE_DIR/Sources/Core.swift" \
    "$SOURCE_DIR/Sources/TabFocusHistory.swift" "$SOURCE_DIR/Tests/TabFocusHistoryTests.swift" -o "$WORK_DIR/TabFocusHistoryTests"
"$WORK_DIR/TabFocusHistoryTests"
/usr/bin/xcrun swiftc -swift-version 5 "$SOURCE_DIR/Sources/ResultKeyboard.swift" \
    "$SOURCE_DIR/Tests/ResultKeyboardTests.swift" -o "$WORK_DIR/ResultKeyboardTests"
"$WORK_DIR/ResultKeyboardTests"
/usr/bin/xcrun swiftc -swift-version 5 "$SOURCE_DIR/Sources/PanelPlacement.swift" \
    "$SOURCE_DIR/Tests/PanelPlacementTests.swift" -o "$WORK_DIR/PanelPlacementTests"
"$WORK_DIR/PanelPlacementTests"
/usr/bin/xcrun swiftc -swift-version 5 -O "${RANKING[@]}" "$SOURCE_DIR/Tests/HistoryPerformanceTests.swift" \
    -lsqlite3 -o "$WORK_DIR/HistoryPerformanceTests"
"$WORK_DIR/HistoryPerformanceTests"
/usr/bin/xcrun swiftc -swift-version 5 "$SOURCE_DIR/Sources/GoogleSuggestions.swift" \
    "$SOURCE_DIR/Tests/GoogleSuggestionsTests.swift" -o "$WORK_DIR/GoogleSuggestionsTests"
"$WORK_DIR/GoogleSuggestionsTests"
/usr/bin/xcrun swiftc -swift-version 5 "$SOURCE_DIR/Sources/Core.swift" \
    "$SOURCE_DIR/Sources/SafariNativeNewTab.swift" "$SOURCE_DIR/Tests/SafariNativeNewTabTests.swift" \
    -o "$WORK_DIR/SafariNativeNewTabTests"
"$WORK_DIR/SafariNativeNewTabTests"
/usr/bin/xcrun swiftc -swift-version 5 "$SOURCE_DIR/Sources/Core.swift" \
    "$SOURCE_DIR/Sources/SafariBridge.swift" "$SOURCE_DIR/Sources/SafariNativeNewTab.swift" \
    "$SOURCE_DIR/Tests/BridgeTests.swift" -o "$WORK_DIR/BridgeTests"
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
