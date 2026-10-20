# Suggestions And History QA

This checklist supplements [core manual QA](../Tests/MANUAL_TESTS.md) and [Safari search research](SAFARI_SEARCH.md). Automated tests use injected network responses and synthetic SQLite databases; they must not inspect a developer's real Safari history. Physical Cmd+T, macOS permission state, live rendering, and perceived responsiveness still require manual verification.

Use a throwaway Safari window and public fixture queries. Record the build revision, macOS/Safari version, active profile, enabled menu settings, and cold/warm cache state. Never clear a user's Safari history to test the app. Tests involving database corruption, large inventories, precise visit dates, or permission errors belong in isolated fixtures.

## Settings And Consent

1. On a clean installation, verify **Google Suggestions** and **Use Browser History** are off. Search open tabs and run an ordinary web search without enabling either feature.
2. Confirm the menu names are explicit: Google predictions are not labeled as automatically using every Safari provider. Verify enabling either option does not enable the other.
3. Enable Google Suggestions using public query text such as `weather`. Confirm local results appear immediately and the Google section appears only when usable predictions arrive.
4. Disable Google Suggestions while a request is pending. Confirm pending results do not appear afterward and later typing causes no Google autocomplete request.
5. Enable Use Browser History without Full Disk Access. The history access error must not block open tabs, accepted Tab Scout searches, query editing, cancellation, or ordinary searches.
6. Explain the broader scope of Full Disk Access before granting it. Grant it manually to the installed app, fully quit/reopen, and confirm the setting is independent of Safari Automation and keyboard-hook permission.
7. Revoke Full Disk Access and refresh. History failures must stay nonblocking and must not be presented as a successful empty history read. Restore only permissions explicitly changed for this test.

## Rows And Selection

1. Populate public fixture data with an open tab, a remembered search, a visited URL, and a Google prediction. Confirm open tabs appear first without a heading and that **Recent Searches**, **History**, and **Google Suggestions** are distinguishable.
2. Press Up/Down across each boundary. Headers must not become selected or perform an action on Enter or mouse click. At the list ends, selection must remain on an actionable row.
3. Before manual navigation, matching open tabs should remain the default action where present. Without a local tab/history/search match, verify the explicit new-search action stays selected rather than silently changing to an arriving prediction. Recent searches and history may be the initial default when they match.
4. Move to a particular result before Google returns or history refreshes. The same logical result must remain selected after rows change. Press Enter and confirm the originally chosen target is activated.
5. Type a new query while a request for the old query is pending. Old suggestions must not appear under the new query. Close the panel during a request; a callback must not reopen it.
6. Check light/dark appearance, Retina icons, long Unicode queries/titles, narrow window dimensions, and scrolling. Headers, clock/search icons, real timestamps, favicons, and truncated text must not overlap or shift row geometry.
7. Clock rows must have real local use dates. A generic Google prediction must not acquire a fabricated visit date.
8. With empty or whitespace-only input, the previous tab is the selected first row, the other open tabs follow it without a heading, and the native new-tab action comes after them, above recent searches. The tab on screen is not listed; with no other tab open, the new-tab action is selected, including after a refresh. Choosing that action and Cmd+Enter must use Safari's native **New Tab** command and open exactly one tab with its configured page. With Start Page configured, its sections and background must render rather than a forced `about:blank`. Repeat with no windows in a throwaway session, comparing with File > New Tab. Nonempty addresses and queries must still open the URL or configured-provider search as before.
9. Switch from fixture tab A to tab B through Tab Scout. Cmd+T must show A first, labelled **Previous tab**, and not repeat it below; Enter returns to A. Cmd+T, Enter again returns to B. Repeat with A and B in different windows. Press Cmd+T, Enter in quick succession right after a switch; the Enter must not be lost.
10. Click from tab B to tab C in Safari itself, then press Cmd+T: B must be first after the in-place refresh. Close B; the row must fall back to the tab viewed before it. Navigate the previous tab to another page; it must no longer be offered as the previous tab. Typing replaces the row with ordinary results.
11. Type a query that matches only the page on screen. That tab must not be listed, and Enter must search the query in a new tab. On an empty Start Page tab, the search must load in that tab instead.

## Ranking And Deduplication

1. Use comparable fixture matches with different recency and use counts. Recent/repeated local use should improve their order, while a relevant exact or strong prefix match must beat an unrelated popular item.
2. Keep one fixture URL open and include the same destination in history. It should appear once as an open-tab action rather than as a duplicate history URL. Selecting it must not create another tab.
3. Remember a search phrase that Google also predicts. Confirm one locally sourced recent-search row remains, with its genuine last-use date, rather than duplicate recent/remote rows.
4. Import a fixture Google search URL with form-encoded spaces, Unicode, and extra parameters. Confirm only its actual `q` phrase becomes a recent search. Spoofed hosts, empty queries, and unrelated paths must not become search history.
5. Repeatedly accept a fixture search and tab. Reopen the app and verify accepted choices persist and ranking remains deterministic for equal signals.
6. Cancel the panel or force a failed Safari action. These events must not create accepted-choice history. Use **Clear Tab Scout History** and confirm those records disappear without changing Safari's database or unrelated tabs.

## Network And Caching

Use an injected transport or controlled proxy for precise network assertions. Do not send real credentials or private URLs to a live service to test filtering.

1. Rapidly type several prefixes. Verify a short debounce and cancellation/coalescing prevent one request per keystroke. Requests must be tied to the current normalized query.
2. Repeat a successful public query within 5 minutes. Verify an immediate memory-cache hit without another request; restart the app or advance an injected clock past expiry and confirm a new request is required.
3. Exercise more than 64 query entries with fixtures. Verify bounded eviction and no persistent suggestion-query cache is written to disk.
4. Confirm requests target only the fixed Google HTTPS completion endpoint, contain only eligible typed search text and endpoint parameters, and include no Safari cookies, account credentials, referrer, tab list, or local history.
5. Verify empty input, obvious URLs/local addresses, credential-like prefixes, control characters, and text over the query limit cause no autocomplete request.
6. Simulate offline mode, timeout, HTTP 429/500, wrong content type, malformed/mismatched JSON, oversized streamed responses, and redirects. Local results and explicit search actions must remain usable without endless spinners, crashes, or old-query results.
7. Change Safari's configured search engine to another provider in a throwaway test setup. Google predictions should remain labeled Google; choosing one must execute the phrase using Safari's configured engine. Restore the original provider afterward.

## History Bounds And Refresh

1. Verify Safari access is read-only and limited to its main `~/Library/Safari/History.db`. Tab Scout must not copy the database into its application-support folder.
2. With synthetic fixtures, verify the 183-day retention boundary, bounded database reads, and at most 5,000 merged URL results. Future, invalid, or malformed dates and unsupported schemas must fail safely.
3. While history loads or refreshes, type, navigate, and cancel. Matching open tabs and already usable local results must not wait for a database read.
4. Disable Use Browser History. Imported rows must disappear from the palette; local accepted choices and tab search must keep working.
5. Delete a public fixture visit using Safari's own history UI, then refresh after the history-cache window. The deleted visit must not remain indefinitely imported. Do not clear unrelated Safari history.
6. Test a separate Safari profile and document which main-database records are visible. Do not claim support for every profile database or complete iCloud history.
7. Check the private-window caveat using a harmless public fixture. Safari's scripting interface may expose private tabs without identifying them: Tab Scout must not promise automatic private isolation. Successful actions can still be locally remembered and opted-in suggestions can still send typed text.

## Performance And Cleanup

1. Measure cold/warm panel opens and rapid typing with large synthetic tab/history inventories. Record median and slowest times; first local results must not wait for Google or favicons.
2. Observe the app with the panel closed. Suggestion requests must be cancelled, and history/network activity must stay bounded.
3. Close only fixture tabs, clear fixture Tab Scout accepted-choice records, and restore settings explicitly changed during testing. Keep the user's Safari database, existing tabs, and permissions intact.

Report each section as passed, failed with reproduction, or not exercised. Automated test success does not prove live Full Disk Access or the physical keyboard hook.
