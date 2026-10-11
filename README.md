# Tab Scout

Find an open Safari tab before opening another one.

Tab Scout's **Safari Web Extension** opens fast tab search over your current webpage with **Cmd+Shift+Y**. The centered overlay accepts typing without opening a tab. Its Safari toolbar button opens the same search interface in Safari's native popup, also used when the shortcut cannot inject into a restricted or permission-denied page. Cmd+T remains Safari's normal New Tab shortcut and native Start Page behavior is preserved. The extension is packaged in a small sandboxed macOS containing app for Safari installation and eventual App Store distribution; that app does not need to remain running.

The earlier native menu-bar edition remains available separately. It is not embedded in the extension or its containing app. See [Native Companion](docs/NATIVE_COMPANION.md) for its build instructions and broader permissions.

## Safari Extension

- Search open tab titles and URLs, with case-insensitive, diacritic-insensitive multiword matching.
- Switch to an existing tab instead of creating a duplicate. Opening or dismissing search never closes the underlying webpage or creates a temporary tab.
- Open addresses or run a search when there is no match. Google is the default; Bing and DuckDuckGo can be selected in extension settings.
- Use locally remembered Tab Scout choices to improve ranking. Remembering choices is optional and records can be cleared.
- Enable optional Google predictions. Local results appear before the network response.
- Load same-origin favicons asynchronously, with bounded caching and a fallback icon.

The overlay and fallback popup share the native edition's compact 660-by-440 layout: search at the top, 58-pixel result rows, inline URL/window details, and refresh/settings controls in the footer. Light and dark appearances follow the system. On permitted HTTP(S) webpages, the overlay is centered in Safari's content viewport with the existing page behind it and adapts to smaller windows. The protected frame uses opaque panels matching the native edition's colors and layout, not its macOS translucent material. Safari controls the fallback popup's position near the toolbar; it is not a centered native window.

Enter activates the selected row; arrow keys move the selection. A submitted address or search opens a new tab; Cmd+Enter opens a nonempty query in a new tab regardless of the selected result. With empty input, the explicit **New tab** row opens Safari's default new-tab page; empty Cmd+Enter does nothing. Escape dismisses search and returns to the existing page. Opening search requests input focus. Safari may initially focus the protected frame before its field, so the first real keystroke focuses the field and is retained without an extra click or Tab. Physical shortcut typing must also pass the live Safari acceptance checklist, not just browser fixtures.

## Build And Test

Requires macOS 13.3 or later, Safari 17 or later, Xcode, and Node.js 20 or later for build validation and the JavaScript tests. A generated self-contained overlay bundle is checked in, so the app build can use it without installing JavaScript packages. When editing overlay source or its bundled UI/assets, install the pinned development dependency and regenerate/check the bundle:

```sh
git clone https://github.com/VashingMachine/tab-scout.git ~/projects/tabs-scout
cd ~/projects/tabs-scout
npm ci
npm run build:overlay
npm run check:overlay
bash test-safari.sh
bash build-safari.sh
```

The overlay bundler is pinned in `package-lock.json`; its generated JavaScript contains the overlay host code and styling, while the protected frame loads its UI and assets from the extension bundle. No executable code is downloaded at runtime. `npm run check:overlay` verifies that the checked-in bundle matches its source. `test-safari.sh` runs deterministic protocol, ranking, caching, privacy, network-response, UI-helper, performance, and manifest tests. The build verifies sandbox entitlements, signatures, and every packaged resource. With Playwright and its Chromium browser installed, `node Tests/SafariUISmoke.cjs` additionally exercises the actual UI using local browser/network fixtures and captures desktop, narrow-screen, popup, and settings screenshots. Set `TAB_SCOUT_PLAYWRIGHT_MODULE` if Playwright is installed outside this repository. These fixtures do not control real Safari.

The containing app is named **Tab Scout Safari.app** to distinguish it from the older **Tab Scout.app**. The build script accepts `TAB_SCOUT_OUTPUT_DIR`, `TAB_SCOUT_WORK_DIR`, and an optional `TAB_SCOUT_SIGN_IDENTITY`.

Local development builds are not App Store releases. Without an Apple-issued development certificate, Safari may require **Settings > Developer > Allow unsigned extensions** before the extension appears. This setting weakens Safari's normal extension-signing requirement and resets on Safari restart; enable it yourself only for development. Open the containing app, use **Safari Extensions**, and enable **Tab Scout** in Safari Settings > Extensions. Grant website access for the overlay and tab metadata, or use the popup fallback. No new-tab replacement is requested.

If an updated local build disappears from the list or retains a stale popup, avoid replacing the bundle while testing it. Quit the containing app before replacing it, reopen the installed bundle, and restart Safari after saving any work. In our Safari 27.0.1 test, an ad-hoc build failed Safari's code-signing registration even with unsigned extensions allowed; signing the same build with an existing Apple Development identity restored its listing. `TAB_SCOUT_SIGN_IDENTITY` supports that workflow without committing certificates or private keys. Development signing is still not App Store distribution.

Quit the older native Tab Scout or disable its Cmd+T capture before testing the extension, so the old keyboard hook does not intercept Safari's shortcut.

## App Store Direction

The extension and containing app use App Sandbox. The Store target does not include the older Accessibility hook, AppleScript bridge, Full Disk Access history reader, or private Safari preferences access. It does not require Accessibility, Safari Automation, or Full Disk Access.

There are deliberate differences from the native edition:

- The extension uses Cmd+Shift+Y, not the native edition's Cmd+T interception. In a Safari 27 live probe, assigning Cmd+T to an extension action still opened Safari's New Tab; the nonconflicting shortcut opened a popup with immediate typing focus.
- A centered overlay is available only on permitted HTTP(S) webpages. Restricted pages and denied website access use Safari's toolbar-positioned popup. This is not universal native-window parity.
- Safari does not support the WebExtension history API, so existing Safari browsing history is not imported. Choice-based ranking stays inside Tab Scout.
- Safari does not support the WebExtension search-provider API. The extension's provider setting is independent of Safari Settings > Search.
- Only tabs and windows exposed by Safari's extension APIs are available. Do not assume a complete inventory across inactive Tab Groups or profiles.

Publishing later requires an Apple Developer Program account, production bundle identifiers, Apple-issued signing certificates/profiles, App Store Connect metadata, privacy disclosures, and review. This repository provides a development build and Store-oriented architecture, not a guarantee of Apple approval or a published listing. See [App Store Preparation](docs/APP_STORE.md).

## Privacy

Safari requires website permission to expose tab titles and URLs to web extensions. Tab Scout requests `tabs`, `storage`, `scripting`, `activeTab`, and host access. Bundled code is injected only to display and operate the overlay; it does not collect webpage text, form values, passwords, or page bodies. The search UI lives in an extension-origin iframe, separate from the webpage's DOM and keyboard events. Only `overlay-frame.html` is exposed for HTTP(S) embedding; there are no automatically registered content scripts or remote executable assets. Strict website policies can prevent embedding and trigger popup fallback. Inventory is cached transiently; accepted choices are local extension data. See [Extension Privacy](docs/EXTENSION_PRIVACY.md) for storage, retention, network requests, and private-browsing behavior.

Google predictions are off by default. Enabling them sends eligible typed search text to Google's public autocomplete endpoint before Enter, without cookies or local history. This endpoint is undocumented and may stop working. Submitting a search sends the query to the selected provider, as normal browsing does.

Lucide tool icons are vendored locally from `lucide-static` 1.55.0; their license is included in `SafariExtension/icons/LICENSE`. No remote JavaScript, fonts, or third-party favicon service is loaded.

## Development Layout

- `SafariExtension/`: injected overlay, popup/settings UI, background worker, search/ranking/cache logic, manifest, and local assets. Older new-tab files remain for compatibility but are not registered as a new-tab override.
- `SafariApp/`: sandboxed containing app and Safari extension Xcode project.
- `Tests/WebExtension/`: injected-browser/network tests; no real Safari history or signed-in accounts.
- `Sources/` and `Resources/`: preserved native companion, built separately with `build.sh` and tested with `test.sh`.

GitHub Actions tests both editions and builds/signature-verifies both bundles. Automated browser fixtures are not a substitute for the [Safari live acceptance checklist](docs/SAFARI_EXTENSION_QA.md).
