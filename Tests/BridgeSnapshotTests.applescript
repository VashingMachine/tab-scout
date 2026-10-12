on run argv
    set bridge to load script (POSIX file (item 1 of argv))
    set urls to {"https://example.org/A", "https://example.org/A", missing value}
    set titles to {"A quoted title", "Second title", missing value}
    my expect(bridge's snapshotIsStable(titles, urls, urls), "A consistent snapshot is accepted")
    my expect(not (bridge's snapshotIsStable({"A"}, urls, urls)), "A title/URL count mismatch is rejected")
    my expect(not (bridge's snapshotIsStable(titles, urls, {"https://example.org/A", missing value})), "A closed tab invalidates the snapshot")
    my expect(not (bridge's snapshotIsStable(titles, urls, {missing value, "https://example.org/A", "https://example.org/A"})), "Reordering invalidates the snapshot")
    my expect(not (bridge's snapshotIsStable({"A"}, {"https://example.org/A"}, {"https://example.org/a"})), "URL verification is case sensitive")
    my expect(bridge's snapshotIsStable({}, {}, {}), "An empty window is a consistent snapshot")

    set rows to bridge's rowsFromSnapshot(42, titles, urls, 2)
    my expect((count of rows) is 3, "Duplicate URLs remain separate tabs")
    my expect((item 1 of rows) is {42, 1, "A quoted title", "https://example.org/A", false}, "Rows retain the window ID and one-based index")
    my expect((item 2 of rows) is {42, 2, "Second title", "https://example.org/A", true}, "Enumerate indices locally without Apple events")
    my expect((item 3 of rows) is {42, 3, "", "", false}, "Missing title and URL become JSON-compatible strings")
    my expect((count of (bridge's rowsFromSnapshot(42, titles, urls, 7))) is 3, "An out-of-range current index still lists every tab")
    my expect((bridge's jsonText(rows)) contains "\"Second title\",\"https:\\/\\/example.org\\/A\",true]", "The current-tab marker serializes as a JSON boolean")
    my expect((bridge's rowsFromSnapshot(99, {}, {}, 1)) is {}, "An empty window produces no rows")
    set rejected to false
    try
        bridge's rowsFromSnapshot(42, {"A"}, urls, 1)
    on error messageText
        set rejected to messageText contains "TAB_SCOUT_SNAPSHOT_CHANGED"
    end try
    my expect(rejected, "Never return partial rows from a mismatched snapshot")
    set active to bridge's activeRow(7, 3, missing value, "https://example.org/B")
    my expect(active is {7, 3, "", "https://example.org/B"}, "The active tab row has no missing values")
    my expect((bridge's jsonText(active)) is "[7,3,\"\",\"https:\\/\\/example.org\\/B\"]", "The active tab serializes as one JSON row")
    return "Passed 16 AppleScript snapshot checks"
end run

on expect(condition, messageText)
    if not condition then error messageText
end expect
