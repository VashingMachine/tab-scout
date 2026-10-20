# Manual QA

Automated tests exercise deterministic cache, matching, and favicon behavior. These checks cover macOS permissions, real Safari interaction, keyboard-hook behavior, visual rendering, and perceived performance.

Use a throwaway Safari window and public fixture pages. Record the macOS/Safari version, build revision, tab count, whether caches are cold or warm, and the result of each section. Close only tabs created for the test.

## Setup And Permissions

1. Run `bash test.sh` and `bash build.sh`. Install the app in a stable location and launch one copy.
2. Before granting permissions, verify that the menu and Permissions window remain usable and show the missing access. A failed Safari read should offer a useful error without hanging the UI.
3. Grant device-control / Accessibility and Safari Automation access. On macOS 27+, confirm that setup refers to Device Control and Data Access; on older systems, Accessibility.
4. Open search and confirm that real Safari tabs load. Check that preview mode does not ask for permission, contact sites, or change Safari.
5. Disable Safari Automation access and try a refresh. Confirm that an error is shown and unavailable data is not treated as a successful empty session. Restore permission.
6. For a rebuilt ad-hoc binary, check whether macOS retained the old executable's permission. Remove/re-add the current app when required. A toggled Settings switch alone is not proof that the event hook is authorized.

## Shortcuts And Actions

1. Physically press Cmd+T with Safari frontmost. Confirm one search panel opens and no blank Safari tab is created. UI-automation key events may target an app directly and bypass the session hook, so they are not a substitute for this test.
2. Hold Cmd+T briefly. Confirm repeat events do not create multiple panels or Safari tabs.
3. Press Escape, then open and cancel with Cmd+T. Confirm neither cancellation changes Safari tabs.
4. Type a distinctive part of an existing title. Check case-insensitive, diacritic-insensitive, multiword, hostname, and URL-path queries. Use Up/Down and Enter to select the intended tab; check mouse selection too.
5. Confirm that selecting an existing tab changes Safari's active tab/window without increasing the tab count.
6. Enter a unique no-match query. Confirm a single new tab opens with Safari's configured search provider, not a hard-coded engine.
7. Enter `https://example.com/`, a bare hostname, and an empty query's **New tab** row. Confirm respectively a URL tab, an HTTPS URL tab, and one native tab using Safari's **New tabs open with** setting. With Start Page configured, its sections and background should render instead of a forced `about:blank`. Repeat with whitespace-only input and Cmd+Enter. In a throwaway setup, test another new-tab preference and restore it afterward.
8. Use Cmd+Enter while matching tabs exist. Confirm one additional tab opens rather than switching to a match.
9. Confirm Cmd+Shift+T still reopens Safari's last closed tab. In another app, confirm Cmd+T retains that app's normal behavior.
10. Disable **Capture Cmd+T in Safari**. Confirm Safari's normal new-tab command returns; re-enable it and repeat the physical-key test.
11. Test a minimized Safari window and a fullscreen Safari window. The selected tab's window should become usable and the panel should not remain stranded behind it.
12. In a throwaway session with no Safari windows, choose the empty-query action. Confirm Safari's native **New Tab** command opens one window with one tab, without an extra empty tab. Compare its page with Safari's own File > New Tab command. With two windows, verify the action opens in the palette's target window. Do not close or replace the user's existing windows to create these fixtures.
13. Switch from tab A to tab B with Tab Scout, then press Cmd+T, Enter. Confirm Safari returns to A; repeat and confirm it returns to B. Confirm the empty-input first row is labelled **Previous tab** and that Down, Enter still opens a native new tab.
14. Open a new tab showing the Start Page and press Cmd+T. Enter an address, then repeat with a search and with a history or suggestion row. Each must load in that tab, leaving the tab count unchanged; the address row reads **This empty tab**. Choosing **New tab** or Cmd+Enter with empty input must keep the empty tab without adding another. On a tab showing a page, the same actions must still open a new tab.
15. Restart Tab Scout from a script (for example `task deploy`) while Safari is frontmost, without clicking Tab Scout's menu-bar icon. The first physical Cmd+T must open the palette with the search field focused, and Safari must remain the active app.

## Native Panel Placement

1. Move and resize a throwaway Safari window away from the screen center. Open search and confirm the floating panel is centered on that window, with no vertical offset. Close it, move Safari again, and reopen; placement must follow the current window.
2. With two Safari windows, focus each in turn and reopen the panel. Placement must follow the focused window, not the other window or the pointer's display.
3. On multiple displays, test Safari on each display, including displays left of or above the primary display. Leave the pointer on another screen; the panel must still follow Safari.
4. Place Safari near display edges or partly offscreen. The panel should stay within the usable display area, avoiding the menu bar and Dock. A spanning window uses the display containing the greatest part of Safari.
5. Test fullscreen Safari and unavailable window geometry. Fullscreen uses the actual window center; unavailable or wholly offscreen bounds fall back to a usable screen center. The Safari window itself must never move or resize.

## Tab Cache And Refresh Races

1. Quit and reopen Tab Scout to start with a cold in-memory tab cache. Open the panel. While Safari responds, typing and canceling must stay responsive.
2. Close and reopen within 5 seconds. Results should be immediately available from the fresh snapshot, without an empty-list flash or a loading-only screen.
3. After 5 seconds but before 2 minutes, reopen. Cached results should be available during the background refresh and then update in place.
4. While the panel is closed, create, rename, move, and close fixture tabs in Safari. On reopening, verify that refreshed results reflect those changes. Type during the refresh; the current query must not be reset.
5. Close or reorder a tab after it appears in cached results, then select it. A moved tab should be located by identity; a closed tab must not accidentally activate whichever tab inherited its index.
6. Open the panel, immediately cancel it, and reopen with a different query while a Safari read is still in flight. Late callbacks must not reopen the old panel, restore an old query, or overwrite a newer result.
7. Trigger refresh repeatedly during a slow inventory read. Confirm one logical read is shared and the app remains responsive. Use instrumented test builds if subprocess counts need to be measured.
8. Make Safari unresponsive long enough for a refresh to fail. A bounded, still-usable cached snapshot may remain visible with an error, but a snapshot beyond the 2-minute stale limit must not be shown as current results.
9. Leave Safari inactive for more than 2 minutes and reopen. Confirm expired tab data is not offered as an indefinitely reusable snapshot.
10. Quit Safari. Confirm the previous snapshot is cleared. Relaunch Safari and verify a fresh inventory is used, including when the new session's tab ordering differs.
11. Switch between Safari and other apps. Background prewarming should only occur under the documented active-Safari/permission conditions and should not generate unexpected permission prompts.

## Favicons And Layout

1. With a cold favicon cache, open tabs on public sites with declared PNG/ICO icons. The rows should appear immediately with fallback icons and update without shifting titles or row heights.
2. Check declared root-relative and same-origin absolute icon URLs. Test a site that only provides `/favicon.ico`, and one with no usable icon. The latter must keep the fallback without endless retries.
3. Open multiple tabs on the same origin. Verify they use the same icon and share the lookup rather than starting one request per tab.
4. Filter quickly between unrelated sites while icons load. An image response for a previous row must not appear beside a different site's tab.
5. Close and reopen the panel, then restart Tab Scout. Cached icons should render without repeated network requests until their cache entry expires.
6. Test offline mode and failed/invalid image responses. Typing, selection, and tab switching must remain usable, and the fallback must remain visible.
7. Check SVG-only, very large, malformed, and non-image responses. These must not crash the app or cause unbounded loading. Supported images should preserve their aspect ratio rather than being stretched.
8. Verify icon visibility in light/dark appearance and on a Retina display. Test long titles, long hostnames, and untitled tabs; text must truncate cleanly without colliding with icons or neighboring rows.
9. Check a non-web tab and a local/private-address fixture. The fallback should render without favicon requests to that address.
10. If Safari exposes a private-window fixture, confirm the documented behavior and privacy caveat. Do not claim the app can distinguish private tabs when the scripting interface does not provide that distinction.

## Favicon Network And Disk Policy

Use an injected local transport in automated tests for private addresses; do not relax production address restrictions to perform these checks.

1. Inspect request URLs for a public fixture tab whose URL includes a path, query, and fragment. The homepage discovery request must use only the origin root, not the current tab's full URL.
2. Confirm that requests contain no Safari cookies, authorization, or full-tab-URL referrer. The fixture site's logged-out icon should be used rather than reading Safari's login state.
3. Offer a cross-origin declared icon or redirect. Confirm it is rejected, including attempts to redirect to a private/local address.
4. Verify discovery does not contact third-party favicon aggregators. Inspect origin metadata and disk output: tab titles and complete browsing URLs must not be written as cache records.
5. Use a controlled clock to exercise the 7-day positive and 1-hour negative expiration boundaries. Requests should resume after expiration, not on every panel open.
6. Populate more than 256 cache entries in automated fixtures. Verify eviction keeps disk and memory bounded and retains valid remaining records.
7. Corrupt or remove a cached image/metadata file between launches. The app must recover with a fallback or a new lookup, not crash or display another site's icon.
8. Confirm a request failure is negatively cached and does not create a request storm when several matching rows redraw.

## Performance

Measure rather than asserting a universal latency target. Safari inventory cost varies by Mac and session size.

1. Record time from physical Cmd+T to the first usable result for a cold launch, a fresh warm reopen, and a stale-but-usable reopen. Repeat each case at least 10 times and record median and slowest values.
2. Repeat with a small session and a large fixture session. Warm first-result latency should stay independent of favicon downloads and should not wait for a Safari subprocess.
3. Type a query rapidly with hundreds of fixture tabs. The input must track typing smoothly; result ranking should be stable and the UI should not issue one Safari read per keystroke.
4. Compare requests on the first favicon display, repeated panel opens, and an app restart. Repeated opens should use the memory/disk cache rather than refetching every icon.
5. Observe activity with Safari inactive and the panel closed. There must not be continuous favicon fetching or uncontrolled tab-inventory processes.

## Startup And Cleanup

1. Enable **Start at Login**. Verify its menu state matches macOS's login item state, then disable it and confirm the reverse.
2. Relaunch Tab Scout with Safari already running. Confirm caches and permission state initialize without reopening old search text.
3. Quit the app. Verify Cmd+T returns to Safari immediately and no helper inventory process remains indefinitely.
4. Remove only the fixture tabs and any fixture favicon data. Keep the user's existing Safari session and permissions intact unless the test explicitly changed them.
