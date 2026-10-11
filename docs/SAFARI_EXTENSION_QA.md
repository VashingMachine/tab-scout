# Safari Extension Live Acceptance

Use public fixture pages and a throwaway window. Do not close or replace a user's existing tabs/windows to create fixtures. Record Safari/macOS versions and the Git revision. Automated injected-browser tests do not prove Safari's permission UI or focus behavior.

## Installation

1. Open **Tab Scout Safari.app**. Confirm it reports the extension state and opens Safari Settings > Extensions.
2. For a local build without Apple development signing, the user may need to allow unsigned extensions in Safari's Developer settings. Do not automate or bypass that security choice.
3. Enable Tab Scout and allow the website access required for tab titles/URLs and the overlay. Confirm it is visible in the Extensions list and toolbar, and that no new-tab replacement is requested.
4. Disable the older native app's Cmd+T capture or quit it. Quit the new containing app too. The extension must continue working without either app running.

## Search And Actions

1. On a permitted public HTTP(S) fixture page, press physical Cmd+Shift+Y and immediately type a public query without clicking. The existing page must remain behind a horizontally and vertically centered overlay in Safari's content viewport, not the monitor. The query must enter Tab Scout's field rather than Safari's address bar or the webpage. Record a failure or untested case honestly; injected-browser focus assertions are insufficient. Opening search must create no tab. Resize and move the throwaway window, including narrow and short layouts; confirm query/results stay intact and controls remain usable.
2. Search titles, hostnames, paths, multiword queries, mixed case and accents. Cached results should render promptly; arrow navigation and Enter must activate the intended row.
3. Select an existing public fixture tab. Confirm Safari focuses the intended tab and its window, dismisses the overlay, and keeps both the previous webpage and the selected tab open. Tab count must remain unchanged.
4. Click the toolbar button on a permitted webpage and verify Safari's native popup opens with immediately usable input. On Safari's Start Page or another restricted page, and with website access deliberately denied on a fixture site, verify Cmd+Shift+Y opens the same popup instead. Safari controls popup placement near the toolbar; it is not centered. Its underlying browser tab must remain open, even if it has a similar title or URL.
5. Submit a no-match query or a public URL. Exactly one destination tab should open and search should dismiss, leaving the original page intact. Cmd+Enter should intentionally open the query in one new tab rather than activate a selected open-tab match.
6. With empty input, Enter on the explicit **New tab** row must create exactly one Safari default new tab, without supplying an `about:blank` URL or recording a choice. Empty Cmd+Enter must do nothing. Escape must dismiss the overlay without closing a tab and restore the previous webpage focus where applicable. Repeated Cmd+Shift+Y should toggle the overlay without accumulating injected UI or tabs.
7. Close a matching fixture tab while its cached row is visible. Activation should show a recoverable error and refreshed inventory, without closing the underlying webpage or activating an unrelated tab.
8. Press physical Cmd+T. Safari must open its normally configured new-tab page, not Tab Scout search. Close only that fixture tab. Repeat from the address bar and a restricted page; do not expect Tab Scout to intercept a reserved Safari shortcut.
9. Navigate or switch tabs while an overlay is opening or requesting results. Delayed callbacks must not open an overlay on the new document, act on an unrelated tab, or leave the old overlay usable after its session has been revoked. Test a background-worker restart too; stale injected UI must fail closed or require reopening.

## Privacy, Ranking And Network

1. Google predictions are initially off. Enable them explicitly; local tab matches must stay usable while suggestions load or fail. Old queries must not replace new-query results or move a manually chosen selection.
2. Submitted searches use the extension's selected Google/Bing/DuckDuckGo provider, independently of Safari's provider.
3. Successful accepted choices should improve comparable matches. Failed actions and typed-but-unsubmitted prefixes must not enter local history. Clear choices and check the ranking resets.
4. In a private window, allow the extension only when deliberately testing it. Verify no private choices, query caches, or favicon entries persist, and no Google predictions are requested. Public and private tab inventories must not be mixed.
5. Check favicons, missing icons, long titles and URLs, dark/light appearance, loading, denied permissions, and offline states. Icons must not shift row dimensions or land on an unrelated reused row.
6. Compare with the native edition: the normal search panel is 660 by 440, with no brand header, a 21-pixel search field, 58-pixel rows, 23-pixel icons, and refresh/settings controls at the bottom right. Confirm selected titles/details remain readable in both appearances, window labels stay stable while filtering, and resizing does not change the query or selection. Safari may constrain toolbar-popup width; its placement remains Safari-controlled.
7. Restore website permissions only as directed by the user. No Safari new-tab setting change is required. Do not alter other extensions or profile settings.
8. With a controlled fixture webpage that logs its own keyboard events, type a harmless query into the overlay. The webpage must not receive those events or read the extension frame's search-field DOM. Confirm a frame opened without an authorized session cannot query tabs or act on them. A strict fixture `frame-src` policy should cause usable popup fallback, not a blank overlay. Use synthetic fixtures for tokens and malformed frame messages; never log real typed queries or user tab inventory.

## Distribution

Test a production-signed archive separately before publishing. Local developer settings are not a supported App Store installation workflow. See [App Store Preparation](APP_STORE.md).

## Development Run: 2026-10-11

Tested version 1.4.0, build 11, on Safari 27.0.1 and macOS 27.0.1 (26A434). This run used the implementation committed with this record, an Apple Development signature, and a disposable window containing public documentation fixture pages. Unsigned extensions had previously been enabled by the user; this run does not prove that setting is unnecessary for this local bundle. No production-signed archive was tested.

- Tab Scout was visible and enabled in Safari Settings > Extensions and reported enabled in the containing app. Re-signing the same ad-hoc build with Apple Development signing restored the listing after Safari logged a code-signing dictionary failure.
- Cmd+Shift+Y opened `overlay-frame.html` over the existing HTTP(S) page without adding a tab. A screenshot confirmed horizontal and vertical centering within the page viewport in a non-full-screen Safari window.
- Typing `example.com` after the overlay appeared entered the search field without a click or Tab, retaining the first character. Cmd+V also entered this public text without a prior click, with the automation restoring the user's clipboard afterward.
- Escape removed the overlay and restored webpage focus, with the original page and tab count unchanged. Reopening succeeded.
- Enter on the existing public fixture result dismissed search and kept the tab count unchanged. Submitting a different public fixture URL opened exactly one new destination tab and preserved the source tab.
- Cmd+T opened Safari's native Start Page. Cmd+Shift+Y there opened the native popup; typing and Escape worked without closing or adding a tab. The toolbar button also opened the declared popup on an HTTP(S) page.
- Quitting the containing app did not stop the Safari shortcut overlay. Only the owned disposable window was closed at the end; existing user tabs/windows were left intact.

Automated checks passed separately: 138 extension tests (including 9 Xcode project tests), 1,088 UI smoke assertions, and five packaging regression scenarios. Browser fixtures cover strict-CSP fallback, private isolation, navigation/session revocation, focus error handling, and responsive light/dark geometry; those are not equivalent to live Safari acceptance.

Still untested live on this final build: keystrokes sent before the asynchronous UI appears, deliberately denied website access, strict-CSP sites, private windows, window resizing/moving between monitors, stale-result activation, cross-window selection, Google network/ranking behavior, and the oldest supported Safari release. App Store distribution signing and review remain outstanding.
