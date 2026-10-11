# Tab Scout Native Companion

Search your open Safari tabs with Cmd+T. Switch to a match, or open a new tab when there is no match.

Tab Scout is a native macOS menu-bar companion, **not a Safari extension**. It uses Safari's local scripting interface and a keyboard hook. Optional Google predictions and local history ranking make the palette more useful without waiting for a network request. There is no subscription or Apple developer account requirement for a local build.

## Requirements

- macOS 13 or later.
- Safari.
- Xcode or the Xcode Command Line Tools to build from source.
- Device Control and Data Access / Accessibility permission for the Safari-only Cmd+T hook.
- Automation permission to read and control Safari tabs.
- Optional Full Disk Access to include Safari browsing history. Tab switching, ordinary searches, and Google predictions do not require this permission.

The project uses system frameworks only. It has no package dependencies.

## Build And Install

Clone the repository and run the tests and build:

```sh
git clone https://github.com/VashingMachine/tab-scout.git ~/projects/tabs-scout
cd ~/projects/tabs-scout
bash test.sh
bash build.sh
```

The app is written to `../Tab Scout.app`; temporary compiler and test output stays in `.build/build` and `.build/tests`. Move the app to `/Applications` before granting permissions, then open it. The app runs in the menu bar rather than the Dock.

Build and test locations can be overridden, which is useful for CI and isolated builds:

```sh
TAB_SCOUT_OUTPUT_DIR="$PWD/build" TAB_SCOUT_WORK_DIR="$PWD/work" bash build.sh
TAB_SCOUT_WORK_DIR="$PWD/work" bash test.sh
```

Local builds are ad-hoc signed, not notarized. Moving or rebuilding the executable can invalidate macOS's stored permission even when its switch still looks enabled. Quit Tab Scout, remove its existing device-control / Accessibility entry, add the current app, enable it, and relaunch. Use a stable install location; do not run multiple copies.

If you already have a signing certificate, `TAB_SCOUT_SIGN_IDENTITY` can select its identity instead of the default ad-hoc signature. The build does not provision certificates or notarize the app.

## First Run

In Tab Scout's Permissions window:

1. Click **Open Settings** and enable **Tab Scout** under Privacy & Security > Device Control and Data Access (macOS 27+) or Accessibility (earlier macOS). If it is absent, use the + button and choose the installed app.
2. Click **Allow Access** and allow Tab Scout to control Safari. If previously denied, enable Safari under Privacy & Security > Automation > Tab Scout.
3. Click **Open Search**, or switch to Safari and press Cmd+T.

The shortcut hook starts automatically after permission is granted. Permissions are granted by the user through macOS; the app and tests do not bypass them.

**Google Suggestions** and **Use Safari History** are separate menu-bar toggles and are off on a new installation. Enable either feature only after reviewing the privacy details below. Tab Scout's accepted searches and choices are remembered locally; **Clear Tab Scout History** removes those records.

## Usage

- Type part of a tab title or URL. Matching ignores case and Latin diacritics and supports multiple words.
- Enter activates the selected result. Open-tab matches switch tabs; history URLs open a tab; recent searches and predictions run a search. Up/Down skip section headings; clicking an actionable result activates it.
- If there is no match, Enter opens a new tab. Addresses open directly; other queries use Safari's configured search provider.
- Cmd+Enter always opens the query in a new tab. An empty or whitespace-only query uses Safari's native **New Tab** command and configured new-tab page. With **New tabs open with: Start Page** in Safari Settings > General, it shows the native Start Page with its configured sections and background instead of a forced `about:blank`. The native command also handles opening a tab when Safari has no windows.
- Escape or Cmd+T closes the search panel without an action.
- The refresh icon requests updated results. The menu-bar menu provides search, permissions, shortcut capture, **Google Suggestions**, **Use Safari History**, **Clear Tab Scout History**, **Start at Login**, and quit.
- Cmd+T is captured only while Safari is active. Cmd+Shift+T and shortcuts in other apps retain their normal behavior.

## Suggestions And History

Results distinguish **Open Tabs**, **Recent Searches**, **History**, and **Google Suggestions**. Match quality comes first; recent and repeated use improves ordering within comparable local matches. Matching open tabs remain prominent to avoid duplicate tabs. Equivalent history URLs are deduplicated against open tabs, and a locally remembered search is preferred over an identical Google prediction. Clock rows show actual local use dates; generic predictions do not receive invented timestamps.

Turn on **Google Suggestions** for Google's public autocomplete predictions. Requests start after a 180 ms typing debounce and are cancelled when the query changes or the panel closes. Successful responses are kept only in memory for up to 5 minutes, with at most 64 query entries. Predictions arrive after local results and never block tab switching. Late responses cannot replace the query, reopen a closed panel, or silently move a selection the user has already navigated.

These are **Google** suggestions, not automatic discovery of Safari's selected engine. Safari's scripting interface exposes a search command but not provider identity or its Smart Search suggestion rows. Choosing any search result still uses Safari's configured search engine; Google can supply the prediction even if that engine is different. Change Safari's provider in Safari Settings > Search. [Apple: Customize searching](https://support.apple.com/guide/safari/customize-searching-in-safari-ibrwe75c2a3c/mac)

Turn on **Use Safari History** to supplement accepted Tab Scout choices with recent Safari visits and recognizable Google searches in visited results URLs. Access is read-only, runs in the background, and is optional. If macOS denies access, tabs, Tab Scout recent searches, and ordinary searches remain usable. To allow it, add the installed app under System Settings > Privacy & Security > Full Disk Access, then fully quit and reopen Tab Scout. Full Disk Access grants broader access to protected app data, not just this history file. [Apple: Privacy & Security settings](https://support.apple.com/guide/mac-help/change-privacy-security-settings-mchl211c911f/mac)

The reader supports Safari's main `~/Library/Safari/History.db`, not a complete inventory of separate profile databases or synced history. It considers the last 183 days, bounds the database read, and keeps at most 5,000 merged URLs in memory. Safari's private database schema can change; missing or unsupported databases fail without blocking the core workflow. No copy of Safari's database is saved.

See [Safari search research](SAFARI_SEARCH.md) for the documented Safari behavior, primary references, integration limits, and Tab Scout's own ranking policy. Tab Scout does not reproduce Safari's undisclosed ranking algorithm.

## Fast Results And Caching

Tab Scout keeps an indexed tab snapshot in memory. Typing filters that local index; it does not ask Safari for a new inventory on every keystroke.

A snapshot is fresh for 5 seconds. A usable snapshot appears immediately when the panel opens, while an older snapshot refreshes in the background. Multiple refresh requests share one inventory read. Tab Scout also warms the snapshot when Safari becomes active and refreshes periodically while Safari remains active after Safari access has been established.

Snapshots older than 2 minutes are not reused when reopening the panel. The tab cache is cleared when Safari quits and does not survive a Tab Scout restart. Cached results can briefly reflect a tab that was renamed, moved, or closed; selecting a tab checks its identity again rather than blindly selecting a stale index. A failed refresh does not silently invent results.

Favicons load asynchronously, with a system icon as the fallback. Icon loading never blocks typing, result selection, or Safari tab discovery. The favicon cache survives app restarts, keeps up to 256 entries, and expires successful entries after 7 days and unsuccessful lookups after 1 hour.

## Privacy

Tab Scout reads the titles and URLs of tabs Safari exposes in its open windows. Inventory snapshots stay in memory and are not written to logs. It does not inspect the contents of your current Safari pages.

After a successful action, Tab Scout stores the accepted search phrase or selected URL/title, use count, and last-use date at `~/Library/Application Support/TabScout/History/choices-v1.json`. It does not record every typed prefix, cancelled selection, or failed action. Local records are retained for up to 183 days and bounded to 1,000 visited URLs and 500 search phrases. **Clear Tab Scout History** deletes these accepted-choice records; it does not erase Safari history or a Google Account's activity.

When **Use Safari History** is enabled, imported Safari URLs, titles, counts, and visit dates remain in memory and are never uploaded to Google. Disable the toggle to remove imported Safari results from the palette. To delete the original records, use Safari's own Clear History command; that does not clear independently stored Google Account activity. [Apple: Clear Safari history](https://support.apple.com/guide/safari/clear-your-browsing-history-sfri47acf5d6/mac)

When **Google Suggestions** is enabled, eligible typed search text is sent to `https://suggestqueries.google.com/complete/search?client=safari&q=...` before Enter. It is an undocumented, best-effort endpoint, not a supported or versioned Google developer API. Requests use an ephemeral session without cookies, credentials, referrer, or Safari's login session. They do not send local history, tab inventories, or accepted-choice records. Google can still observe the query and your network address. Obvious URLs, addresses, credential-like prefixes, empty input, and oversized text are excluded; this conservative filter is not a guarantee that arbitrary search text contains no sensitive information.

Predictions are generic rather than signed-in Google Account history or personalization. Google documents that signed-in predictions can use account activity; Tab Scout deliberately does not import cookies to reproduce that behavior. [Google: How autocomplete works](https://support.google.com/websearch/answer/7368877?hl=en)

Favicon lookup is a separate network request from Tab Scout to an HTTP(S) site's origin. It may fetch the origin homepage to discover an icon, then a same-origin icon URL or `/favicon.ico`. The current tab's path, query, and fragment are not sent as a homepage request. Cross-origin icons and redirects are rejected. Local/single-label hostnames, literal private IPv4 addresses, IPv6 addresses, and non-web URLs use a fallback; other domain names are not classified by their DNS result. No Google favicon endpoint or other third-party favicon service is used.

Favicon requests use an ephemeral session without cookies, credentials, or an HTTP cache; they do not share Safari's login session or send a tab-URL referrer. A contacted site can still observe the request and your network address.

The favicon cache lives at `~/Library/Caches/local.tabscout.app/Favicons-v1`. It stores PNGs with a maximum 64-pixel dimension for Retina displays and expiration/access timestamps under hashed origin filenames, not tab titles or full tab URLs. Cached data remains until it expires, is evicted, or is removed.

Safari's scripting inventory does not reliably identify private-browsing tabs. If Safari exposes a private-window tab, Tab Scout may list it and cache its site's favicon too. A successful action can also enter Tab Scout's local accepted-choice history, and opted-in suggestions can send typed text to Google. Do not treat Tab Scout, its local records, or its favicon cache as a private-browsing boundary. Disable suggestions and avoid using Tab Scout for private activity that must not be recorded.

Choosing a web search sends the query through Safari's configured provider, as normal browsing does. Choosing a URL opens it in Safari.

## Tests

```sh
bash test.sh
```

The automated suites cover search ranking and normalization, destination parsing, bridge response decoding and timeouts, shortcut decisions, tab-cache freshness and refresh races, and favicon URL selection, network/cache policy, persistence, and eviction. Suggestions checks cover query privacy filters, response validation, debounce, coalescing, cancellation, cache expiration/eviction, offline fallback, and main-thread delivery. Synthetic SQLite fixtures exercise Safari history reads, bounds, denied/unsupported databases, search extraction, local persistence, clearing, merging, and recency/frequency ranking.

Rendering and navigation checks verify fixed row geometry, untinted website icons, section headers, selection retention, and protection against late icons landing on reused rows. A benchmark exercises indexed search over 1,000 fixture tabs and repeated warm cache openings without additional Safari reads.

Favicon and Google network tests use injected responses rather than contacting live sites. History tests never read the developer's or CI user's Safari history. The script also compiles the Safari AppleScript, tests snapshot assembly against fixtures without controlling Safari, and validates the app's property lists.

GitHub Actions runs the tests and builds/signature-verifies the app on macOS. CI does not launch Safari, request permissions, or prove physical keyboard-hook behavior.

For visual testing without Safari access or permission requests:

```sh
open -n "../Tab Scout.app" --args --preview
```

Quit preview before launching the normal app. Core live behavior, permissions, rendering, and cold/warm performance checks are documented in [Tests/MANUAL_TESTS.md](../Tests/MANUAL_TESTS.md). The suggestions/history acceptance checklist is in [docs/MANUAL_QA.md](MANUAL_QA.md).

## Limitations

- Only tabs Safari exposes in open windows can be searched. Inactive Tab Groups and profiles are not a complete searchable inventory; activate the relevant group first.
- Tab inventory timing depends on Safari responsiveness and session size. Cached results improve repeated opens; a cold start still needs a Safari read.
- Authenticated-only, cross-origin, unsupported, or unavailable icons fall back to the system icon.
- Google suggestions may be unavailable or change format without notice. They are not Apple's separate Safari Suggestions and do not reproduce signed-in Google predictions.
- Safari history access uses a private database schema and supports only the main database. Separate profile history and private-browsing isolation are not guaranteed.
- Local ad-hoc builds are intended for the machine that built them. Distribution, notarization, App Store packaging, and a Safari Web Extension are not provided.

## Remove

Use **Clear Tab Scout History**, disable **Start at Login**, quit Tab Scout, and remove the app. Remove its device-control / Accessibility, Automation, and optional Full Disk Access entries in System Settings if desired. In-memory tab snapshots, Google predictions, and imported Safari history are discarded on quit. Remove `~/Library/Caches/local.tabscout.app/Favicons-v1` to clear the persistent favicon cache and `~/Library/Application Support/TabScout/History` to remove any remaining local history files.
