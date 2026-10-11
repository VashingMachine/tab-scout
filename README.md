# Tab Scout

Search your open Safari tabs with Cmd+T. Switch to a match, or open a new tab when there is no match.

Tab Scout is a native macOS menu-bar companion, **not a Safari extension**. It uses Safari's local scripting interface and a keyboard hook. There is no subscription, third-party search service, or Apple developer account requirement for a local build.

## Requirements

- macOS 13 or later.
- Safari.
- Xcode or the Xcode Command Line Tools to build from source.
- Device Control and Data Access / Accessibility permission for the Safari-only Cmd+T hook.
- Automation permission to read and control Safari tabs.

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

## Usage

- Type part of a tab title or URL. Matching ignores case and Latin diacritics and supports multiple words.
- Enter switches to the selected match. Up/Down change selection; clicking a result selects that tab.
- If there is no match, Enter opens a new tab. Addresses open directly; other queries use Safari's configured search provider.
- Cmd+Enter always opens the query in a new tab. An empty query opens a blank tab.
- Escape or Cmd+T closes the search panel without an action.
- The refresh icon requests an updated tab list. The menu-bar menu provides search, permissions, shortcut capture, **Start at Login**, and quit.
- Cmd+T is captured only while Safari is active. Cmd+Shift+T and shortcuts in other apps retain their normal behavior.

## Fast Results And Caching

Tab Scout keeps an indexed tab snapshot in memory. Typing filters that local index; it does not ask Safari for a new inventory on every keystroke.

A snapshot is fresh for 5 seconds. A usable snapshot appears immediately when the panel opens, while an older snapshot refreshes in the background. Multiple refresh requests share one inventory read. Tab Scout also warms the snapshot when Safari becomes active and refreshes periodically while Safari remains active after Safari access has been established.

Snapshots older than 2 minutes are not reused when reopening the panel. The tab cache is cleared when Safari quits and does not survive a Tab Scout restart. Cached results can briefly reflect a tab that was renamed, moved, or closed; selecting a tab checks its identity again rather than blindly selecting a stale index. A failed refresh does not silently invent results.

Favicons load asynchronously, with a system icon as the fallback. Icon loading never blocks typing, result selection, or Safari tab discovery. The favicon cache survives app restarts, keeps up to 256 entries, and expires successful entries after 7 days and unsuccessful lookups after 1 hour.

## Privacy

Tab Scout reads the titles and URLs of tabs Safari exposes in its open windows. Those tab snapshots stay in memory; they are not saved as browsing history or written to logs. It does not inspect the contents of your current Safari pages.

Favicon lookup is a separate network request from Tab Scout to an HTTP(S) site's origin. It may fetch the origin homepage to discover an icon, then a same-origin icon URL or `/favicon.ico`. The current tab's path, query, and fragment are not sent as a homepage request. Cross-origin icons and redirects are rejected. Local/single-label hostnames, literal private IPv4 addresses, IPv6 addresses, and non-web URLs use a fallback; other domain names are not classified by their DNS result. No Google favicon endpoint or other third-party favicon service is used.

Favicon requests use an ephemeral session without cookies, credentials, or an HTTP cache; they do not share Safari's login session or send a tab-URL referrer. A contacted site can still observe the request and your network address.

The favicon cache lives at `~/Library/Caches/local.tabscout.app/Favicons-v1`. It stores PNGs with a maximum 64-pixel dimension for Retina displays and expiration/access timestamps under hashed origin filenames, not tab titles or full tab URLs. Cached data remains until it expires, is evicted, or is removed.

Safari's scripting inventory does not reliably identify private-browsing tabs. If Safari exposes a private-window tab, Tab Scout may list it and cache its site's favicon too. Do not treat the favicon cache as a private-browsing boundary.

Choosing a web search sends the query through Safari's configured provider, as normal browsing does. Choosing a URL opens it in Safari.

## Tests

```sh
bash test.sh
```

The automated suites cover search ranking and normalization, destination parsing, bridge response decoding and timeouts, shortcut decisions, tab-cache freshness and refresh races, and favicon URL selection, network/cache policy, persistence, and eviction. Rendering checks verify fixed row geometry, untinted website icons, and protection against late icons landing on reused rows. A benchmark exercises indexed search over 1,000 fixture tabs and repeated warm cache openings without additional Safari reads.

Favicon network tests use injected responses rather than contacting live sites. The script also compiles the Safari AppleScript, tests snapshot assembly against fixtures without controlling Safari, and validates the app's property lists.

GitHub Actions runs the tests and builds/signature-verifies the app on macOS. CI does not launch Safari, request permissions, or prove physical keyboard-hook behavior.

For visual testing without Safari access or permission requests:

```sh
open -n "../Tab Scout.app" --args --preview
```

Quit preview before launching the normal app. Live behavior, permissions, rendering, and cold/warm performance checks are documented in [Tests/MANUAL_TESTS.md](Tests/MANUAL_TESTS.md).

## Limitations

- Only tabs Safari exposes in open windows can be searched. Inactive Tab Groups and profiles are not a complete searchable inventory; activate the relevant group first.
- Tab inventory timing depends on Safari responsiveness and session size. Cached results improve repeated opens; a cold start still needs a Safari read.
- Authenticated-only, cross-origin, unsupported, or unavailable icons fall back to the system icon.
- Local ad-hoc builds are intended for the machine that built them. Distribution, notarization, App Store packaging, and a Safari Web Extension are not provided.

## Remove

Disable **Start at Login**, quit Tab Scout, and remove the app. Remove its device-control / Accessibility and Automation entries in System Settings if desired. The in-memory tab snapshot is discarded on quit; remove `~/Library/Caches/local.tabscout.app/Favicons-v1` to clear the persistent favicon cache.
