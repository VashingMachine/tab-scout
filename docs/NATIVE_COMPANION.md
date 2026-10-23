# Tab Scout Native App

Search your open Safari and Chrome tabs with Cmd+T. Switch to a match in its own browser, or open a new tab in the browser you were using when there is no match.

Tab Scout is a native macOS menu-bar app, **not a browser extension**. It uses Safari's and Chrome's local scripting interfaces and a keyboard hook. The one exception is grouping Chrome tabs: Chrome lets only extensions make tab groups, so the `group` command uses a small optional extension (see [Chrome Grouping](#chrome-grouping)). Optional Google predictions and local history ranking make the palette more useful without waiting for a network request. There is no subscription or Apple developer account requirement for a local build.

See the [README](../README.md) for the quick start.

## Requirements

- macOS 13 or later.
- Safari, Google Chrome, or both.
- Xcode 26 or later, or its Command Line Tools, to build from source; the build needs the macOS 26 SDK.
- Device Control and Data Access / Accessibility permission for the Cmd+T hook in Safari and Chrome.
- Automation permission to read and control Safari tabs, and separately Chrome tabs.
- Optional Full Disk Access to include Safari and Chrome browsing history and Chrome's site icons. Tab switching, ordinary searches, and Google predictions do not require this permission.

The project uses system frameworks only. It has no package dependencies.

## Build And Install

Follow [Install](../README.md#install) in the README. Its `deploy.sh` builds, signs and installs `/Applications/Tab Scout.app`, or `TAB_SCOUT_INSTALL_APP` when set; later deploys reuse the last location, and a running copy elsewhere is moved to the Trash. It signs with the installed copy's certificate when the keychain has it, otherwise the first Apple Development certificate, otherwise ad hoc; `TAB_SCOUT_SIGN_IDENTITY` overrides the choice. `task deploy` runs the tests first, `task deploy:quick` does not, and `task deploy:plan` only prints the install location and signing.

`bash build.sh` on its own writes the app to `../Tab Scout.app`; temporary compiler and test output stays in `.build/build` and `.build/tests`. Build and test locations can be overridden, which is useful for CI and isolated builds:

```sh
TAB_SCOUT_OUTPUT_DIR="$PWD/build" TAB_SCOUT_WORK_DIR="$PWD/work" bash build.sh
TAB_SCOUT_WORK_DIR="$PWD/work" bash test.sh
```

Local builds are not notarized, and `build.sh` signs ad hoc unless `TAB_SCOUT_SIGN_IDENTITY` names a certificate. Moving or rebuilding the executable can invalidate macOS's stored permission even when its switch still looks enabled. Quit Tab Scout, remove its existing device-control / Accessibility entry, add the current app, enable it, and relaunch. Use a stable install location; do not run multiple copies.

## First Run

In Tab Scout's Permissions window:

1. Click **Open Settings** and enable **Tab Scout** under Privacy & Security > Device Control and Data Access (macOS 27+) or Accessibility (earlier macOS). If it is absent, use the + button and choose the installed app.
2. Click **Allow Access** next to Safari and allow Tab Scout to control Safari. Do the same next to Google Chrome to include its tabs; this opens Chrome. If previously denied, enable the browser under Privacy & Security > Automation > Tab Scout.
3. Click **Open Search**, or switch to Safari or Chrome and press Cmd+T.

The shortcut hook starts automatically after permission is granted. Permissions are granted by the user through macOS; the app and tests do not bypass them.

**Google Suggestions** and **Use Browser History** are separate menu-bar toggles and are off on a new installation. Enable either feature only after reviewing the privacy details below. Tab Scout's accepted searches and choices are remembered locally; **Clear Tab Scout History** removes those records.

## Usage

- Type part of a tab title or URL. Matching ignores case and Latin diacritics and supports multiple words.
- Enter activates the selected result. Open-tab matches switch tabs; history URLs open a tab; recent searches and predictions run a search. Up/Down skip section headings; clicking an actionable result activates it.
- With empty input, the top result is the tab you viewed before the current one, so Cmd+T, Enter flips between two tabs. Tab Scout learns which tab is on screen whenever it reads Safari's tabs: each time the panel opens, after each switch it makes, and periodically while Safari is active. A tab you only passed through between reads may be skipped.
- If there is no match, Enter opens a new tab. Addresses open directly; other queries use Safari's configured search provider.
- When the tab on screen is empty (the Start Page, Favorites or `about:blank`), anything that would open a new tab opens in it instead, and the **New tab** action keeps it. Tab Scout checks that the tab is still empty first; if it has loaded a page meanwhile, a new tab opens as usual.
- Cmd+Enter and Shift+Enter always open the query in a new tab, or in the empty tab on screen. Holding Shift alone lists that row first and selects it at once; typing a capital letter or `?` shows it briefly. An empty or whitespace-only query uses Safari's native **New Tab** command and configured new-tab page. With **New tabs open with: Start Page** in Safari Settings > General, it shows the native Start Page with its configured sections and background instead of a forced `about:blank`. The native command also handles opening a tab when Safari has no windows.
- Escape or Cmd+T closes the search panel without an action.
- The refresh icon requests updated results. The menu-bar menu provides search, permissions, shortcut capture, **Google Suggestions**, **Use Browser History**, **History Profiles**, **Clear Tab Scout History**, **Start at Login**, and quit.
- Cmd+T is captured only while Safari or Chrome is active. Cmd+Shift+T and shortcuts in other apps retain their normal behavior.

## Suggestions And History

Open tabs come first without a heading; **Recent Searches**, **History**, and **Google Suggestions** have their own sections. The tab you are on is never listed, so when it is the only match Enter opens a new tab with your query. Match quality comes first; recent and repeated use improves ordering within comparable local matches. Matching open tabs remain prominent to avoid duplicate tabs. Equivalent history URLs are deduplicated against open tabs, and a locally remembered search is preferred over an identical Google prediction. Clock rows show actual local use dates; generic predictions do not receive invented timestamps.

Turn on **Google Suggestions** for Google's public autocomplete predictions. Requests start after a 180 ms typing debounce and are cancelled when the query changes or the panel closes. Successful responses are kept only in memory for up to 5 minutes, with at most 64 query entries. Predictions arrive after local results and never block tab switching. Late responses cannot replace the query, reopen a closed panel, or silently move a selection the user has already navigated.

These are **Google** suggestions, not automatic discovery of Safari's selected engine. Safari's scripting interface exposes a search command but not provider identity or its Smart Search suggestion rows. Choosing any search result still uses Safari's configured search engine; Google can supply the prediction even if that engine is different. Change Safari's provider in Safari Settings > Search. [Apple: Customize searching](https://support.apple.com/guide/safari/customize-searching-in-safari-ibrwe75c2a3c/mac)

Turn on **Use Browser History** to supplement accepted Tab Scout choices with recent Safari and Chrome visits and recognizable Google searches in visited results URLs. Access is read-only, runs in the background, and is optional. If macOS denies access, tabs, Tab Scout recent searches, and ordinary searches remain usable. To allow it, add the installed app under System Settings > Privacy & Security > Full Disk Access, then fully quit and reopen Tab Scout. Full Disk Access grants broader access to protected app data, not just these history files. macOS also protects Chrome's profile folder, so Chrome history needs the same permission. [Apple: Privacy & Security settings](https://support.apple.com/guide/mac-help/change-privacy-security-settings-mchl211c911f/mac)

Every profile is read: Safari's main `~/Library/Safari/History.db`, each further Safari profile's history in Safari's container, and each Chrome profile listed in Chrome's `Local State`, by the name it has in Chrome. **History Profiles** in the menu turns any of them off; a profile that cannot be read is marked unavailable there while the others still work. Synced history from other devices is not guaranteed to be represented. Each profile's read considers the last 183 days and at most 10,000 visits, and at most 5,000 merged URLs stay in memory; a page visited in several profiles counts every visit. Chrome visits loaded inside another page's frames are left out.

Chrome locks its databases while it runs, so Tab Scout copies `History` and `Favicons`, with any journal or write-ahead log beside them, to a private temporary folder and reads the copy, which is deleted straight after. On APFS the copy is a clone that takes no time or space. Browsers' private database schemas can change; missing or unsupported databases fail without blocking the core workflow. No copy of any browser's database is kept.

See [Safari search research](SAFARI_SEARCH.md) for the documented Safari behavior, primary references, integration limits, and Tab Scout's own ranking policy. Tab Scout does not reproduce Safari's undisclosed ranking algorithm.

## Fast Results And Caching

Tab Scout keeps an indexed tab snapshot in memory. Typing filters that local index; it does not ask Safari for a new inventory on every keystroke.

A usable snapshot appears immediately when the panel opens, and each opening refreshes it in the background so the previous-tab row reflects tab switches made directly in Safari. Background warming treats a snapshot as fresh for 5 seconds. Enter pressed before the first tab list arrives runs once it does. Multiple refresh requests share one inventory read. Tab Scout also warms the snapshot when Safari becomes active and refreshes periodically while Safari remains active after Safari access has been established.

Snapshots older than 2 minutes are not reused when reopening the panel. The tab cache is cleared when Safari quits and does not survive a Tab Scout restart. Cached results can briefly reflect a tab that was renamed, moved, or closed; selecting a tab checks its identity again rather than blindly selecting a stale index. A failed refresh does not silently invent results.

Favicons load asynchronously, with a system icon as the fallback. Icon loading never blocks typing, result selection, or Safari tab discovery. The favicon cache survives app restarts, keeps up to 256 entries, and expires successful entries after 7 days and unsuccessful lookups after 1 hour. With browser history on, the icons Chrome already shows come first: for each site, the icon most of its pages use, in the size closest to 32 pixels. They stay in memory, are read again at most every 10 minutes, and cover sites that refuse an anonymous download, such as signed-in mail. Safari's own icon cache has no documented format and is not read.

## Privacy

Tab Scout reads the titles and URLs of tabs Safari exposes in its open windows. Inventory snapshots stay in memory and are not written to logs. It does not inspect the contents of your current Safari pages.

After a successful action, Tab Scout stores the accepted search phrase or selected URL/title, use count, and last-use date at `~/Library/Application Support/TabScout/History/choices-v1.json`. It does not record every typed prefix, cancelled selection, or failed action. Local records are retained for up to 183 days and bounded to 1,000 visited URLs and 500 search phrases. **Clear Tab Scout History** deletes these accepted-choice records; it does not erase Safari history or a Google Account's activity.

When **Use Browser History** is enabled, imported URLs, titles, counts, and visit dates, and Chrome's icons, remain in memory and are never uploaded to Google. Disable the toggle, or a profile under **History Profiles**, to remove its results from the palette. To delete the original records, use the browser's own Clear History command; that does not clear independently stored Google Account activity. [Apple: Clear Safari history](https://support.apple.com/guide/safari/clear-your-browsing-history-sfri47acf5d6/mac)

When **Google Suggestions** is enabled, eligible typed search text is sent to `https://suggestqueries.google.com/complete/search?client=safari&q=...` before Enter. It is an undocumented, best-effort endpoint, not a supported or versioned Google developer API. Requests use an ephemeral session without cookies, credentials, referrer, or Safari's login session. They do not send local history, tab inventories, or accepted-choice records. Google can still observe the query and your network address. Obvious URLs, addresses, credential-like prefixes, empty input, and oversized text are excluded; this conservative filter is not a guarantee that arbitrary search text contains no sensitive information.

Predictions are generic rather than signed-in Google Account history or personalization. Google documents that signed-in predictions can use account activity; Tab Scout deliberately does not import cookies to reproduce that behavior. [Google: How autocomplete works](https://support.google.com/websearch/answer/7368877?hl=en)

Favicon lookup is a separate network request from Tab Scout to an HTTP(S) site's origin. It may fetch the origin homepage to discover an icon, then a same-origin icon URL or `/favicon.ico`. The current tab's path, query, and fragment are not sent as a homepage request. Cross-origin icons and redirects are rejected. Local/single-label hostnames, literal private IPv4 addresses, IPv6 addresses, and non-web URLs use a fallback; other domain names are not classified by their DNS result. No Google favicon endpoint or other third-party favicon service is used.

Favicon requests use an ephemeral session without cookies, credentials, or an HTTP cache; they do not share Safari's login session or send a tab-URL referrer. A contacted site can still observe the request and your network address.

The favicon cache lives at `~/Library/Caches/local.tabscout.app/Favicons-v1`. It stores PNGs with a maximum 64-pixel dimension for Retina displays and expiration/access timestamps under hashed origin filenames, not tab titles or full tab URLs. Cached data remains until it expires, is evicted, or is removed.

Safari's scripting inventory does not reliably identify private-browsing tabs. If Safari exposes a private-window tab, Tab Scout may list it and cache its site's favicon too. A successful action can also enter Tab Scout's local accepted-choice history, and opted-in suggestions can send typed text to Google. Do not treat Tab Scout, its local records, or its favicon cache as a private-browsing boundary. Disable suggestions and avoid using Tab Scout for private activity that must not be recorded.

Choosing a web search sends the query through Safari's configured provider, or Google in Chrome, as normal browsing does. Choosing a URL opens it in the browser you were using.

## Google Chrome

While Chrome is running, its tabs are listed with Safari's. Each browser is read separately and cached on its own, so a slow Chrome, or Chrome waiting for you to answer its Automation prompt, never delays Safari's tabs; Chrome's arrive a moment later. A browser that cannot be read is named in the footer, and the others still work.

- Picking a tab switches to it in its own browser, so Cmd+T, Enter can flip between a Safari tab and a Chrome tab. Window labels name the browser once tabs from both are listed.
- New tabs, addresses and searches open in the browser most recently in front. In Chrome, **New tab** opens Chrome's own new-tab page, and an empty Chrome new-tab page on screen is reused like Safari's Start Page.
- Searches in Chrome go to Google: Chrome has no scripting command for its own search engine.
- Incognito windows are never read, listed or used; a new tab opens in a normal window, which is made when none exists.
- Every Chrome profile's windows are included, and with **Use Browser History** on, every profile's history and icons too.
- **Search Page Text** reads Chrome pages only with View > Developer > Allow JavaScript from Apple Events turned on in Chrome. Without it, Chrome refuses, and Tab Scout stops asking until the option is turned on again.

The bridge is `Resources/ChromeBridge.js`, JavaScript for Automation compiled into the app. It needs no Chrome scripting dictionary to build, and takes the browser's bundle identifier, so other Chromium browsers that share Chrome's scripting terms could be added.

## Commands

Typing `` ` `` first lists commands instead of tabs; the text after it filters them by name, then by description. Each command names the browsers it works in, and only those of the browser the palette opened over are listed. Enter or Cmd+Enter runs the selected command. Commands are never sent to Google or remembered as searches.

## Chrome Grouping

`` `group `` sorts the loose tabs of the front Chrome window into named tab groups. Pinned tabs, tabs already in a group and empty new-tab pages stay where they are. Apple's on-device model is given the numbered titles and sites of at most 50 tabs and answers with topics, checked like `?` answers: made-up numbers and tabs it placed twice are ignored, and a topic needs two tabs. Greedy sampling makes the same tabs group the same way each time. Without Apple Intelligence, or when the model fails or finds nothing, tabs about the same ticket, pull request, Google document or repository are grouped, then tabs of the same site.

Safari has no such command: its scripting dictionary, its web extension API and its Shortcuts actions offer no way to make tab groups, and doing it through Safari's menus would flash them on screen. Safari's own **Organize Tabs** setting groups tabs with Apple Intelligence.

Chrome lets only extensions make tab groups, so the command goes through Tab Scout's extension:

1. Choose **Set Up Chrome Grouping...** in the menu, or run `` `group `` before the extension is added. Tab Scout installs `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/local.tabscout.chrome.json`, which lets Chrome start `TabScoutChromeHost` for the extension `dofcmbpicogclehjjkobakjbghefaglp` only.
2. **Show Extension** reveals `Tab Scout.app/Contents/Resources/ChromeExtension` in Finder and opens Chrome's Extensions page. Turn on **Developer mode**, then drag the folder onto the page or click **Load unpacked** and choose it. Repeat in each Chrome profile that should group tabs.

The extension asks for `tabs`, `tabGroups`, `nativeMessaging` and `alarms`. It keeps a connection to the helper, which Chrome keeps running alongside it. The helper connects to Tab Scout's socket, `~/Library/Application Support/TabScout/chrome.sock` (only your user can open it), and tries again every second while Tab Scout is not running. Each side checks the other's designated code requirement, so another program cannot pose as either. When Tab Scout is rebuilt with another signature, it turns the old helper away; the helper quits and the extension starts the new one. For `group`, Tab Scout asks every connected profile for the front window's tabs. Only the profile that has the window answers, and that profile makes the groups. Chrome assigns their colors. Tab Scout logs connections under the `chrome` category of `local.tabscout.app` in Console.

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

Preview takes keyboard focus. To check the layout without that, render the preview palette to an image from an invisible window:

```sh
"$PWD/.build/native-output/Tab Scout.app/Contents/MacOS/TabScout" --preview --snapshot /tmp/tab-scout.png
```

Add `--query` with text to type, and `--browser chrome` or `--browser safari` to open the palette over that browser, for example `--browser chrome --query '`'` for Chrome's commands.

Quit preview before launching the normal app. Core live behavior, permissions, rendering, and cold/warm performance checks are documented in [Tests/MANUAL_TESTS.md](../Tests/MANUAL_TESTS.md). The suggestions/history acceptance checklist is in [docs/MANUAL_QA.md](MANUAL_QA.md).

## Limitations

- Only tabs Safari and Chrome expose in open windows can be searched. Inactive Tab Groups and profiles are not a complete searchable inventory; activate the relevant group first.
- Tab inventory timing depends on Safari responsiveness and session size. Cached results improve repeated opens; a cold start still needs a Safari read.
- Authenticated-only, cross-origin, unsupported, or unavailable icons fall back to the system icon.
- Google suggestions may be unavailable or change format without notice. They are not Apple's separate Safari Suggestions and do not reproduce signed-in Google predictions.
- Safari history access uses a private database schema and supports only the main database. Separate profile history and private-browsing isolation are not guaranteed.
- Local ad-hoc builds are intended for the machine that built them. Distribution, notarization, and App Store packaging are not provided.

## Remove

Use **Clear Tab Scout History**, disable **Start at Login**, quit Tab Scout, and remove the app. Remove its device-control / Accessibility, Automation, and optional Full Disk Access entries in System Settings if desired. In-memory tab snapshots, Google predictions, and imported Safari history are discarded on quit. Remove `~/Library/Caches/local.tabscout.app/Favicons-v1` to clear the persistent favicon cache and `~/Library/Application Support/TabScout/History` to remove any remaining local history files. To remove Chrome grouping, remove the Tab Scout extension on Chrome's Extensions page and delete `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/local.tabscout.chrome.json`.
