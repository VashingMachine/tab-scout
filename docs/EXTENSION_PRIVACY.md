# Extension Privacy

This describes the Safari Web Extension, not the separate native menu-bar edition.

## Permissions And Boundaries

The extension requests `tabs`, `storage`, `scripting`, `activeTab`, and host access. Safari requires website permission to expose tab titles and URLs. `scripting` and permitted website access let Tab Scout insert its centered search overlay into the current HTTP(S) webpage following the Cmd+Shift+Y command. The toolbar button opens a statically declared extension popup without injecting into the webpage. `activeTab` allows temporary access associated with an explicit extension action; it is not a permanent grant to every website.

Safari's permission screen may describe broad webpage access. The injected, bundled code creates and operates Tab Scout's own UI; it does not collect webpage text, form values, passwords, or page bodies. There are no automatically registered `content_scripts` or remote executable assets. `web_accessible_resources` exposes only `overlay-frame.html` for HTTP(S) embedding, not the background worker or other executable resources.

The overlay host is inserted into the webpage, but the search UI runs in a separate extension-origin iframe so the website cannot inspect its DOM or receive its query keyboard events. A closed shadow host provides style isolation; that alone is not a security boundary for typed text. A per-session token is sent directly to the iframe, not placed in a URL or DOM attribute, and the background validates its tab, window, frame, and session before granting requests. A website can still interfere with the outer host or block embedding through its content security policy; injection or embedding failure uses the popup fallback. Website access remains a meaningful permission even with these narrower implementation uses.

The extension does not send tab inventory or existing page contents to a server. Optional Google predictions send only eligible text typed into Tab Scout's own field as described below.

Opening or dismissing search does not create or close a browser tab. On restricted pages or when access is denied, the extension opens its bundled Safari toolbar popup instead. Cmd+T is left to Safari; no new-tab override is registered. Older new-tab resources remain bundled for compatibility but are not the shortcut entry point.

The containing app and extension are sandboxed. They do not request Accessibility, Safari Automation, or Full Disk Access. There is no native messaging bridge, private Safari database reader, analytics service, remote JavaScript, or remotely loaded font.

## Local Data

`browser.storage.local` holds:

- Settings: selected search engine, Google-prediction consent, and whether to remember choices.
- Accepted choices: successful searches or opened/switched HTTP(S) destinations, their display titles, use counts, and last-used timestamps. Merely typing, cancelling, or failing an action does not record a choice. There are at most 1,000 URL records and 500 search records; records older than 183 days are excluded.
- Favicon cache: up to 128 SHA-256 origin identifiers, raster image data or a negative result, expiry, and last-used timestamps, bounded to 4 MiB of image string storage. Successful icons expire after seven days; negative results after one hour. The hash is not an anonymity guarantee: known origins can be guessed, and icons can identify sites.

Tab inventory stays in background-worker memory. A snapshot is fresh for five seconds; a stale snapshot may be shown for up to two minutes while Safari is queried again. Tab events invalidate it. Google predictions use a memory-only LRU cache of up to 64 queries for five minutes. Neither cache survives worker termination.

Expired stored records are filtered when read and removed from subsequent bounded writes. The extension does not guarantee immediate physical erasure of expired bytes from Safari's storage or backups. Storage is local, not extension sync storage.

Turning off remembering hides choices and stops new choice records; it does not erase existing records. **Clear** in settings removes Tab Scout's accepted choices only, not Safari history, settings, or favicon data. Removing Safari's extension data clears all stored extension records.

## Network Requests

With Google Suggestions enabled, eligible typed searches are sent after a 180 ms debounce to `https://suggestqueries.google.com/complete/search?client=safari&q=...`. Predictions are off by default and require confirmation when enabled. Obvious addresses, email-like input, local paths, and some secret-shaped input are excluded, but filtering cannot recognize every sensitive search. Avoid enabling predictions if typed text must stay local.

Google receives the eligible query and normal connection information, such as the IP address. Tab Scout does not attach cookies, a referrer, tab titles, URLs from local choices, or local history. Requests use a three-second timeout and a 64 KiB response limit. The endpoint is undocumented and best-effort; its JSON is parsed as data, never executed.

For favicons, Tab Scout requests only `https://<origin>/favicon.ico` from public-looking HTTPS hostnames. It excludes literal IPs, localhost, common internal suffixes, credentials, and non-default ports. It never sends the page's path or query, never scrapes its HTML, and does not use a third-party favicon aggregator. A public-looking hostname can still resolve to a private address; these checks are not a DNS/network security boundary. Fetches omit cookies and referrers, reject redirects, allow at most four concurrent requests, and accept only bounded raster images up to 256 KiB. Missing, unsupported, or denied icons show a bundled fallback.

Activating a search navigates Safari to Google, Bing, or DuckDuckGo, according to Tab Scout settings. Normal browser cookies and the chosen provider's policies then apply. Opening an address is likewise normal Safari browsing.

## Private Browsing

When Safari identifies the current context as private, Tab Scout lists only private tabs, hides accepted choices, records no choices, and does not fetch or consult favicon or Google-prediction caches. Tab creation remains in that private window, and switching between regular and private contexts is rejected. Settings/choice changes from an identified private context are rejected.

This depends on Safari's extension API context signals and its separate permission to run extensions in private browsing. The extension does not bypass Safari permissions or promise visibility across every profile or inactive Tab Group.

## Store Disclosures

Before release, re-check these behaviors against the final build, review the search providers' terms, and complete App Store Connect disclosures for the actual distribution. This document is an implementation description, not a substitute for those disclosures or a guarantee of App Store approval.
