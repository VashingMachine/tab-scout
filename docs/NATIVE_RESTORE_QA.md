# Native App Restore Verification

Verified on 2026-10-12 with Safari 27.0.1 and macOS 27.0.1 (26A434).

The existing native Tab Scout installation, version 1.2 build 3, was reused without rebuilding, re-signing, or moving it. Native source in `Sources/`, `Resources/`, `build.sh`, and `test.sh` was unchanged. The Safari extension's containing app was quit; it reported that the extension was not enabled in Safari.

## Confirmed

- The native bundle's code signature verified.
- The app reported Ready, with Device Control and Data Access, Safari Automation, and optional Safari-history access allowed.
- Existing Google Suggestions and Use Safari History preferences remained enabled.
- Open Search displayed the original native palette with a focused search field and open-tab, recent-search, and history rows.
- Google Suggestions appeared for a public test query. No searches or tab choices were submitted during this check.
- Escape dismissed the palette. Browser tabs created by automated shortcut tests were closed, leaving the original page and tab count intact.
- The user confirmed that pressing physical Cmd+T in Safari opens the native Tab Scout palette over the page.

## Limits

Automated Cmd+T events opened Safari's native new tab during this session; they did not establish that the global keyboard hook worked. The physical-key confirmation above is the live acceptance result. No new permission grant or signing change was needed.

This was a restore check, not a complete new acceptance run for every cache, ranking, multi-monitor, or private-browsing scenario. Native private-browsing limitations remain as documented in [Native App Details](NATIVE_COMPANION.md).
