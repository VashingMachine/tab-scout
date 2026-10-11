# Safari Extension Live Acceptance

Use public fixture pages and a throwaway window. Do not close or replace a user's existing tabs/windows to create fixtures. Record Safari/macOS versions and the Git revision. Automated injected-browser tests do not prove Safari's permission UI or focus behavior.

## Installation

1. Open **Tab Scout Safari.app**. Confirm it reports the extension state and opens Safari Settings > Extensions.
2. For a local build without Apple development signing, the user may need to allow unsigned extensions in Safari's Developer settings. Do not automate or bypass that security choice.
3. Enable Tab Scout and allow the website access required for tab titles/URLs. Accept the new-tab replacement. Confirm it is visible in the Extensions list and toolbar.
4. Disable the older native app's Cmd+T capture or quit it. Quit the new containing app too. The extension must continue working without either app running.

## Search And Actions

1. Press physical Cmd+T. Confirm exactly one Tab Scout new-tab page opens and the search input receives focus. The search surface must be horizontally and vertically centered in Safari's content viewport, not the monitor. Resize and move a throwaway window, including narrow and short layouts; confirm query/results stay intact and controls remain usable. Toolbar popup placement is controlled by Safari.
2. Search titles, hostnames, paths, multiword queries, mixed case and accents. Cached results should render promptly; arrow navigation and Enter must activate the intended row.
3. Select an existing public fixture tab. Confirm Safari focuses its window and closes only the temporary Tab Scout new-tab page. User tab count must return to the pre-Cmd+T count.
4. Repeat from the toolbar popup. Its underlying browser tab must remain open, even if it has a similar title or URL.
5. Submit a no-match query or a public URL. New-tab mode should navigate the temporary search tab, not leave an extra empty tab. Popup mode should create one new tab. Cmd+Enter should intentionally create another tab.
6. Empty/whitespace input must stay on the search page, never open `about:blank` or loop through new-tab creation. Escape must not close a normal user's tab.
7. Close a matching fixture tab while its cached row is visible. Activation should show a recoverable error and refreshed inventory, without closing the search tab or activating an unrelated tab.

## Privacy, Ranking And Network

1. Google predictions are initially off. Enable them explicitly; local tab matches must stay usable while suggestions load or fail. Old queries must not replace new-query results or move a manually chosen selection.
2. Submitted searches use the extension's selected Google/Bing/DuckDuckGo provider, independently of Safari's provider.
3. Successful accepted choices should improve comparable matches. Failed actions and typed-but-unsubmitted prefixes must not enter local history. Clear choices and check the ranking resets.
4. In a private window, allow the extension only when deliberately testing it. Verify no private choices, query caches, or favicon entries persist, and no Google predictions are requested. Public and private tab inventories must not be mixed.
5. Check favicons, missing icons, long titles and URLs, dark/light appearance, loading, denied permissions, and offline states. Icons must not shift row dimensions or land on an unrelated reused row.
6. Restore website permissions and normal new-tab settings only as directed by the user. Do not alter other extensions or profile settings.

## Distribution

Test a production-signed archive separately before publishing. Local developer settings are not a supported App Store installation workflow. See [App Store Preparation](APP_STORE.md).
