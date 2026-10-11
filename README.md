# Tab Scout

Find an open Safari tab before opening another one.

Tab Scout's **Safari Web Extension** replaces the new-tab page with fast tab search. Cmd+T remains Safari's own shortcut: it opens the extension page rather than a background app intercepting the keyboard. The extension also has a toolbar popup. It is packaged in a small sandboxed macOS containing app for Safari installation and eventual App Store distribution; that app does not need to remain running.

The earlier native menu-bar edition remains available separately. It is not embedded in the extension or its containing app. See [Native Companion](docs/NATIVE_COMPANION.md) for its build instructions and broader permissions.

## Safari Extension

- Search open tab titles and URLs, with case-insensitive, diacritic-insensitive multiword matching.
- Switch to an existing tab instead of creating a duplicate. Only the extension's own temporary new-tab page is closed after switching; a toolbar popup never closes its underlying tab.
- Open addresses or run a search when there is no match. Google is the default; Bing and DuckDuckGo can be selected in extension settings.
- Use locally remembered Tab Scout choices to improve ranking. Remembering choices is optional and records can be cleared.
- Enable optional Google predictions. Local results appear before the network response.
- Load same-origin favicons asynchronously, with bounded caching and a fallback icon.

The search page and popup share the native edition's compact 660-by-440 layout: search at the top, 58-pixel result rows, inline URL/window details, and refresh/settings controls in the footer. Light and dark appearances follow the system. The new-tab panel remains centered within Safari's content viewport and adapts to smaller windows. Browser-rendered translucency approximates the native window material; it cannot show the previous Safari page behind the new-tab page.

Enter activates the selected row; arrow keys move the selection. Cmd+Enter opens the query in another tab. Empty input keeps the search page open instead of navigating to `about:blank`.

The page requests search-field focus, but live Safari testing found that Cmd+T can leave keyboard focus in the address field. Click Tab Scout's search field before typing in that case. Automatic focus handoff remains unverified; the injected-browser tests cannot certify Safari's browser-chrome focus.

## Build And Test

Requires macOS 13.3 or later, Safari 16.4 or later, Xcode, and Node.js 20 or later for build validation and the JavaScript tests. No JavaScript build framework or package installation is required.

```sh
git clone https://github.com/VashingMachine/tab-scout.git ~/projects/tabs-scout
cd ~/projects/tabs-scout
bash test-safari.sh
bash build-safari.sh
```

`test-safari.sh` runs deterministic protocol, ranking, caching, privacy, network-response, UI-helper, performance, and manifest tests. The build verifies sandbox entitlements, signatures, and every packaged resource. With Playwright and its Chromium browser installed, `node Tests/SafariUISmoke.cjs` additionally exercises the actual UI using local browser/network fixtures and captures desktop, narrow-screen, popup, and settings screenshots. Set `TAB_SCOUT_PLAYWRIGHT_MODULE` if Playwright is installed outside this repository. These fixtures do not control real Safari.

The containing app is named **Tab Scout Safari.app** to distinguish it from the older **Tab Scout.app**. The build script accepts `TAB_SCOUT_OUTPUT_DIR`, `TAB_SCOUT_WORK_DIR`, and an optional `TAB_SCOUT_SIGN_IDENTITY`.

Local development builds are not App Store releases. Without an Apple-issued development certificate, Safari may require **Settings > Developer > Allow unsigned extensions** before the extension appears. This setting weakens Safari's normal extension-signing requirement and resets on Safari restart; enable it yourself only for development. Open the containing app, use **Safari Extensions**, and enable **Tab Scout** in Safari Settings > Extensions. Accept the new-tab replacement to use it with Cmd+T.

Quit the older native Tab Scout or disable its Cmd+T capture before testing the extension, so the old keyboard hook does not intercept Safari's shortcut.

## App Store Direction

The extension and containing app use App Sandbox. The Store target does not include the older Accessibility hook, AppleScript bridge, Full Disk Access history reader, or private Safari preferences access. It does not require Accessibility, Safari Automation, or Full Disk Access.

There are deliberate differences from the native edition:

- Cmd+T opens Tab Scout's new-tab page, replacing Apple's native Start Page while the override is selected. The native page cannot simultaneously be the extension's search page.
- Safari does not support the WebExtension history API, so existing Safari browsing history is not imported. Choice-based ranking stays inside Tab Scout.
- Safari does not support the WebExtension search-provider API. The extension's provider setting is independent of Safari Settings > Search.
- Only tabs and windows exposed by Safari's extension APIs are available. Do not assume a complete inventory across inactive Tab Groups or profiles.

Publishing later requires an Apple Developer Program account, production bundle identifiers, Apple-issued signing certificates/profiles, App Store Connect metadata, privacy disclosures, and review. This repository provides a development build and Store-oriented architecture, not a guarantee of Apple approval or a published listing. See [App Store Preparation](docs/APP_STORE.md).

## Privacy

Safari requires website permission to expose tab titles and URLs to web extensions. Tab Scout requests tab/storage access and host access, but includes **no content scripts** and does not inspect webpage bodies. Inventory is cached transiently; accepted choices are local extension data. See [Extension Privacy](docs/EXTENSION_PRIVACY.md) for storage, retention, network requests, and private-browsing behavior.

Google predictions are off by default. Enabling them sends eligible typed search text to Google's public autocomplete endpoint before Enter, without cookies or local history. This endpoint is undocumented and may stop working. Submitting a search sends the query to the selected provider, as normal browsing does.

Lucide tool icons are vendored locally from `lucide-static` 1.55.0; their license is included in `SafariExtension/icons/LICENSE`. No remote JavaScript, fonts, or third-party favicon service is loaded.

## Development Layout

- `SafariExtension/`: new-tab/popup UI, background worker, search/ranking/cache logic, manifest, and local assets.
- `SafariApp/`: sandboxed containing app and Safari extension Xcode project.
- `Tests/WebExtension/`: injected-browser/network tests; no real Safari history or signed-in accounts.
- `Sources/` and `Resources/`: preserved native companion, built separately with `build.sh` and tested with `test.sh`.

GitHub Actions tests both editions and builds/signature-verifies both bundles. Automated browser fixtures are not a substitute for the [Safari live acceptance checklist](docs/SAFARI_EXTENSION_QA.md).
