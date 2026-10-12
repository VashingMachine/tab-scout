# Tab Scout

Find an open Safari tab before opening another one.

Tab Scout is a **native macOS menu-bar app**. Press **Cmd+T in Safari** to open a focused search palette over the current page. Switch to an existing tab, or open a new tab when there is no match. **No Safari extension is required.**

The native app is the primary workflow again. It keeps the original compact interface, keyboard shortcut, fast local results, favicons, optional Google suggestions, and Safari-history ranking. The Safari extension experiment remains in the repository but is not needed for everyday use.

## Features

- Search tab titles and URLs with case-insensitive, diacritic-insensitive multiword matching.
- Switch to an existing tab instead of creating a duplicate.
- Open an address or search using Safari's configured search engine.
- Show cached tab results immediately while refreshing older snapshots in the background.
- Load favicons asynchronously and cache them across app restarts.
- Include optional Google autocomplete predictions without delaying local results.
- Rank results using locally remembered Tab Scout choices and optional Safari browsing history.
- Center the native palette on the focused Safari window when its geometry is available, with a screen-based fallback.

## Build And Run

Requires macOS 13 or later, Safari, and Xcode or the Xcode Command Line Tools. The native app uses system frameworks and has no package dependencies; Node.js is not required.

```sh
git clone https://github.com/VashingMachine/tab-scout.git ~/projects/tabs-scout
cd ~/projects/tabs-scout
bash test.sh
bash build.sh
open "../Tab Scout.app"
```

The default build writes `Tab Scout.app` beside the repository. Choose a stable install location before granting macOS permissions. If an existing signed installation already works, keep using it in its approved location rather than rebuilding or moving it unnecessarily. Run only one native copy at a time.

Build paths and signing can be selected explicitly:

```sh
TAB_SCOUT_OUTPUT_DIR="$PWD/.build/native-output" \
  TAB_SCOUT_WORK_DIR="$PWD/.build/native-work" \
  bash build.sh
```

`TAB_SCOUT_SIGN_IDENTITY` selects an existing signing identity. The default build is ad-hoc signed; the script does not provision certificates or notarize the app. This is not an App Store release.

## Setup

Tab Scout runs in the menu bar rather than the Dock. Its Permissions window provides these checks:

1. Allow **Device Control and Data Access** on macOS 27+, or **Accessibility** on earlier versions, for the Safari-only Cmd+T keyboard hook.
2. Allow **Safari Automation** so Tab Scout can read, select, and open tabs.
3. Optionally allow **Full Disk Access** to read Safari history. This is a broad permission; tab search, local choices, and Google suggestions work without it.

Use the menu-bar menu to check **Capture Cmd+T in Safari**, enable **Google Suggestions** or **Use Safari History**, and optionally enable **Start at Login**. Google suggestions and Safari-history import are off on a fresh installation; an existing installation retains its preferences.

The app must remain running for Cmd+T search. The shortcut is captured only while Safari is active; other apps and Cmd+Shift+T keep their normal behavior.

## Usage

- Type a tab title, URL, or search phrase. The search field is focused when the palette opens.
- Use Up/Down to select a result, then Enter to activate it. Clicking an actionable result works too.
- Cmd+Enter opens the query in a new tab even when an existing tab matches.
- With empty input, the New tab action uses Safari's native new-tab command and configured page, not a forced `about:blank` URL.
- Escape or Cmd+T dismisses the palette without changing tabs.
- The refresh button updates results. Preferences and permission checks are available from the menu bar.

Results distinguish Open Tabs, Recent Searches, History, and Google Suggestions. Match quality comes first; recent and repeated local use improve comparable matches. Open tabs stay prominent to reduce duplicates, and arriving predictions do not move a selection you have already navigated.

## Privacy And Limits

Tab titles and URLs are read through Safari's local scripting interface. Tab Scout does not read webpage bodies or form fields. Tab snapshots, imported Safari history, and Google prediction caches stay in memory. Accepted choices and the bounded favicon cache are stored locally.

Enabling Google Suggestions sends eligible typed search text to Google's public autocomplete endpoint before Enter. Requests use an ephemeral session without cookies, credentials, Safari's login session, or local history. Predictions are generic, not signed-in Google Account personalization. The undocumented endpoint is best-effort and may be unavailable. Submitted searches still use Safari's configured provider.

Safari-history import is optional, read-only, and limited to the main Safari history database. Inactive Tab Groups, separate profiles, and synced history are not guaranteed to be fully represented. **Clear Tab Scout History** removes accepted Tab Scout choices, not Safari history or Google Account activity.

The native scripting interface does not reliably identify private-browsing tabs. **Do not treat this app or its caches as a private-browsing boundary.** Avoid using it for activity that must not be recorded, and disable suggestions when typed text must remain local.

See [Native App Details](docs/NATIVE_COMPANION.md) for permissions, cache bounds, data locations, and removal instructions.

## Verification

`bash test.sh` covers search, ranking, history fixtures, keyboard decisions, palette placement, cache races, Google response handling, favicons, and Safari bridge fixtures. Tests do not request permissions or read the user's real Safari history. Physical shortcut behavior needs a live check in Safari.

The native installation was restored on 2026-10-12 without rebuilding or changing permissions. Google predictions appeared in the native palette, and the user confirmed that physical Cmd+T opens Tab Scout over the page. See [Native Restore Verification](docs/NATIVE_RESTORE_QA.md).

## Repository Layout

- `Sources/` and `Resources/`: native app and Safari scripting bridge.
- `Tests/`: native automated suites and separate extension fixtures.
- `build.sh` and `test.sh`: native build and test entry points.
- `SafariApp/` and `SafariExtension/`: separate Safari extension experiment, not required by the native app.

Keep the experimental Safari extension disabled when using this native workflow. Its containing app is named `Tab Scout Safari.app`; the native app is `Tab Scout.app`. Extension-specific preparation and privacy notes remain in [App Store Preparation](docs/APP_STORE.md) and [Extension Privacy](docs/EXTENSION_PRIVACY.md).
