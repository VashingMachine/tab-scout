# App Store Preparation

The Safari edition is a sandboxed Safari Web Extension with a small containing app. It does not reuse the native companion's Accessibility keyboard hook, AppleScript bridge, Safari history database reader, or preferences reader. The containing app only reports extension state and opens Safari's extension settings; quitting it does not stop the extension.

## Supported Architecture

Safari handles Cmd+T normally. With Tab Scout selected as the new-tab override, Safari opens `newtab.html`. The extension uses the tabs/windows APIs to search and select exposed tabs. A toolbar popup provides the same search without opening a temporary tab. The background worker is nonpersistent and can be restarted by Safari.

This deliberately replaces the native Start Page. The user can restore Apple's page in Safari Settings > General; the toolbar popup remains available. Existing Safari history is not imported, and search-provider selection is an explicit Tab Scout setting rather than reading Safari's private preferences.

Apple documents the [containing app and distribution model](https://developer.apple.com/documentation/safariservices/distributing-your-safari-web-extension), [new-tab overrides](https://developer.apple.com/videos/play/wwdc2021/10027/), and [App Sandbox requirements](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox). See also [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), especially 2.4.5 and privacy sections. Safari API compatibility is documented in the [Apple compatibility guide](https://developer.apple.com/documentation/safariservices/assessing-your-safari-web-extension-s-browser-compatibility) and MDN's [history](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/history) and [search](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/search) compatibility data.

## Before Uploading

1. Enroll in the Apple Developer Program. Local testing does not itself require enrollment, but production distribution does.
2. Replace the development `local.tabscout.safari` bundle identifiers with identifiers registered to the chosen Apple developer team. Keep host and extension identifiers distinct.
3. Configure the Xcode team, App Store distribution signing and provisioning profiles. The shell build's ad-hoc or local-certificate signing is not a Store archive.
4. Validate an Archive in Xcode and test the distribution-signed build through TestFlight where available. Never depend on **Allow unsigned extensions** in a release.
5. Supply the App Store listing, screenshots, support and privacy-policy URLs, age rating, and accurate privacy disclosures. Explain why Safari host permission is needed for tab metadata; there are no injected webpage scripts.
6. Review the Google autocomplete endpoint before release. It is undocumented, generic, and best-effort. Do not advertise signed-in personalization or guaranteed service availability. Keep consent off by default and explain pre-submission query transmission.
7. Verify private-browsing isolation, storage/retention controls, denied website permissions, offline operation, stale tab races, and the live acceptance checklist on the oldest supported Safari and a current release.
8. Confirm the release bundle contains only the Safari edition, never the unsandboxed native companion, local signing keys, test fixtures, or browser/account data.

App Review remains Apple's decision. A sandboxed development build is a useful starting point, not certification that every distribution requirement has been met.

## Local Signing

`build-safari.sh` compiles without Xcode provisioning, then signs the embedded extension before the containing app and verifies both. This is for local development only. A self-signed certificate does not become an Apple developer identity and does not remove Safari's unsigned-extension restriction.

Do not modify Safari's extension registries, signing databases, or privacy permissions to bypass its install UI. Any developer-setting approval and extension enablement must be completed by the user.
