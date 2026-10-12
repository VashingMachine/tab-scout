# Safari Search Research

Research checked on 2026-10-11. This document separates documented browser behavior from Tab Scout design decisions. It is not a claim to reproduce Safari's private ranking algorithm.

## What Safari Shows

Safari's Smart Search field combines several sources:

- Search-engine predictions from the selected provider, requested as the user types. This is controlled by **Include search engine suggestions**. Typed prefixes can reach the provider before the user submits a search. [Apple: Customize searching in Safari](https://support.apple.com/guide/safari/customize-searching-in-safari-ibrwe75c2a3c/mac)
- Separate **Safari Suggestions** from Apple, including sources such as Music and Maps. These are not Google autocomplete results. [Apple: Customize searching in Safari](https://support.apple.com/guide/safari/customize-searching-in-safari-ibrwe75c2a3c/mac)
- Matches from bookmarks, browsing history, and open tabs. Safari also stores recent searches; clearing Safari history removes these local records, but does not clear history stored independently by websites or a Google Account. [Apple: Safari Privacy Overview](https://www.apple.com/safari/docs/Safari_White_Paper_Nov_2019.pdf), [Apple: Clear Safari history](https://support.apple.com/guide/safari/clear-your-browsing-history-sfri47acf5d6/mac)
- A **Top Hit** determined using bookmarks and browsing history. With background preloading enabled, Safari starts loading that page before Return. [Apple: Search and Privacy](https://www.apple.com/legal/privacy/data/en/siri-suggestions-search/)

Apple confirms these source categories, but does not disclose an exact scoring formula, recency decay, frequency weighting, or stable cross-source ordering. A recency/frequency model in Tab Scout is our own predictable policy, not a reverse-engineered Safari algorithm.

The supplied screenshots show both magnifying-glass rows and clock rows with relative times under a Google Suggestions heading. The clock and timestamp are consistent with history-derived searches rather than a currently open tab; this is an inference from the images, not a documented API contract. A heading alone does not establish whether every row came from a remote provider. Generic remote autocomplete data must not be assigned fabricated visit timestamps.

## What Google Documents

Google says autocomplete uses matching real searches and word patterns, with factors including query language, location, trending interest, and past searches. Signed-in users may also see predictions personalized using their Google activity. This describes Google's service, not Safari's local result mixer. [Google: How autocomplete predictions work](https://support.google.com/websearch/answer/7368877?hl=en), [Google: How Search uses your activity](https://support.google.com/websearch/answer/10909618?hl=en)

A cookie-free native request does not carry Safari's Google login session. It cannot retrieve or reproduce the user's signed-in Google Account history or Google personalization. Tab Scout must not read Safari cookies or attach credentials to achieve this.

Google's publicly reachable autocomplete endpoint is an implementation endpoint, not a documented, versioned developer API with a stability guarantee. Chromium's own tests reference Google's `/complete/search` endpoint, but that does not establish a third-party service contract. Suggestions therefore need timeouts, cancellation, defensive decoding, bounded caching, and a local-only fallback. [Chromium: Remote suggestion service tests](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/components/omnibox/browser/remote_suggestions_service_unittest.cc)

Google's documented Custom Search JSON API returns search results, not the browser's personalized autocomplete stream. It is not an interchangeable API for the rows in these screenshots. [Google: Custom Search response reference](https://developers.google.com/custom-search/v1/reference/rest/v1/Search)

## Public Integration Limits

The installed Safari scripting dictionary at `/Applications/Safari.app/Contents/Resources/Safari.sdef` was inspected as application metadata, without inspecting user history or preferences. It exposes tabs, URLs, names, and a `search the web` command that uses Safari's current search provider. It does not expose provider identity, browsing history, recent searches, or Smart Search suggestion rows. The dictionary's search command is sufficient to preserve the user's configured engine when executing a search, but not to auto-detect the matching suggestion provider.

Safari WebExtensions do not solve this by using `browser.history` or `browser.search`: Mozilla's current compatibility data marks both unsupported in Safari. Apple's compatibility guide directs extension authors to these compatibility tables and to provide workarounds for unsupported APIs. [Apple: Safari extension compatibility](https://developer.apple.com/documentation/safariservices/assessing-your-safari-web-extension-s-browser-compatibility), [Mozilla: history compatibility data](https://github.com/mdn/browser-compat-data/blob/main/webextensions/api/history.json), [Mozilla: search compatibility data](https://github.com/mdn/browser-compat-data/blob/main/webextensions/api/search.json)

Consequently, the suggestions provider is an explicit Tab Scout setting. Google suggestions must be labeled Google, not described as automatically mirroring every possible Safari search engine. Tab Scout executes submitted searches through Safari's configured provider.

## History Architecture and Privacy

Tab Scout combines Safari history and locally accepted choices as optional ranking inputs:

- Keep Tab Scout's accepted-choice history locally. Record only successful actions, not every typed prefix, cancelled choice, or failed action. Expose a clear-history control.
- Make Safari history access optional and read-only. Safari's `History.db` is a private implementation detail rather than a public, stable API; its schema may change. Use bounded reads, background work, defensive schema handling, and a safe fallback when access fails.
- Explain Full Disk Access before requesting it. It is broader than access to a single history database and includes data from other apps such as Mail, Messages, Safari, and Home. The user must grant it in macOS; Tab Scout should not attempt to bypass the protection. [Apple: Privacy and Security settings](https://support.apple.com/guide/mac-help/change-privacy-security-settings-mchl211c911f/mac)
- Never upload imported URLs, titles, counts, or visit dates to Google. Provider requests should contain only the currently eligible typed prefix and necessary language parameters, without cookies or account credentials.
- Distinguish imported Safari history, Tab Scout choices, open tabs, and Google predictions in the result model. Present actual last-visit dates only where the source supplies them. Do not turn the first observation of an open tab into a supposed historical visit.
- Do not persist a copy of Safari's history database. An in-memory snapshot can provide fast matching, but disabling the feature or clearing its cache should discard it. Refresh from the source so deleted entries do not remain indefinitely in cached results.
- History permissions are independent from Accessibility and Safari Automation. Failure or refusal of history access must not prevent tab switching or ordinary searches.

Tests should use synthetic SQLite databases and fixtures, never a developer's or CI user's actual browsing history.

## Ranking Policy

This is Tab Scout's implemented policy, not Apple's proprietary ranking:

1. Preserve match quality as the dominant signal: exact normalized title, query, or host matches first, then strong prefixes, then weaker token matches. A frequently visited unrelated result must not outrank a relevant match.
2. Keep matching open tabs prominent so the core workflow avoids duplicate tabs. Deduplicate equivalent history URLs against open-tab destinations, retaining available history signals for ranking rather than displaying duplicates.
3. Within comparable matches, boost recently and repeatedly accepted Tab Scout choices and recent/frequent Safari visits. Bound frequency so very old high-count history does not dominate forever. Use deterministic ties.
4. Merge duplicate recent search phrases across imported Google search-result URLs and Tab Scout actions. Prefer local history provenance and a real timestamp over an identical remote prediction.
5. Show remaining Google predictions in provider order after relevant local matches. Keep explicit search/new-tab actions available. Late network responses must not silently move an already navigated selection.
6. Limit recent searches, history URLs, and predictions while keeping all matching open tabs reachable. Avoid remote requests for empty input, obvious URLs, credentials, or local addresses; keep results usable when offline or suggestions are disabled.

Within a local match tier, the history boost is `40 * exp(-ageInDays / 30) + min(20, 4 * log2(useCount + 1))`. Match quality remains the primary ordering key. Stable source order breaks any remaining ties.

### Open-Tab Signals

`TabRanker` scores each open tab as a weighted sum of signals, each between 0 and 1 (`Sources/TabRanking.swift`). Weights are points; typed text and empty input have separate weights.

| Signal | Source | Typed | Empty |
| --- | --- | --- | --- |
| Match quality | Text tier from `TextFields` divided by 100 | 100 | — |
| Usage | Safari history and Tab Scout choices (the boost above, divided by 60) | 4 | 4 |
| Recency | How many tab switches ago the tab was on screen: `exp(-switches / 4)` | 4 | 20 |
| Affinity | Pages chosen before for similar typed text (`QueryAffinity`) | 100 | — |
| Reading time | Seconds on screen while Safari was in front, fading over 14 days (`Engagement`) | 3 | 6 |
| Related | Shared ticket key, pull request, repository, Google document or site with the tab on screen (`RelatedTabs`) | 5 | 18 |
| Next site | How often the tab's site followed the site on screen (`Habits`) | 3 | 10 |
| Hour of week | How much more the tab's site is used around this hour than usual (`Habits`) | 2 | 6 |
| Meaning | A typed word's nearest words in the system word embedding found in the title (`SemanticSearch`) | 40 | — |
| Page text | Typed words found in the page text of viewed tabs, when enabled (`PageTextIndex`) | 45 | — |
| Apple Intelligence | The on-device model's picks for a `?` request (`TabAssistant`) | 200 | — |

Match tiers, best first: host or title equal to the query (100, 95), host or title starting with it (90, 85), the query at a word start in the title, including camelCase words (80), the initials of consecutive title words (75), the query inside a title word (70); then every query word at a word start (65), anywhere (60), as initials (58, or 55 with words skipped), or with one typo, two from nine letters (50). Initials and typos apply to open tabs only.

Usage and recency together can reorder neighbouring tiers but not lift a weak match over a strong one. Affinity can: a page chosen repeatedly for the same text comes first even when the text is not in its title. Meaning and page text stay below every text match. The Enter default stays the typed search or address when the best tab is only a typo or initials guess, a guess by meaning or page text, a weak match for a question or phrase of four or more words, or text that was opened in a new tab before.

### Learned Weights

Each pick of a listed tab logs the signals of the tabs shown with it, as numbers only (`RankingImpression`, at most 500). After every ten picks, `RankTrainer` fits each mode with 30 or more picks by pairwise logistic regression, pulled towards the standard weights, never changing match quality or Apple Intelligence, and keeping each weight between zero and three times its standard size. The learned weights are adopted only when they rank the most recent fifth of picks, held out from training, better than the standard weights; otherwise the standard weights stay. The menu shows how often the picked tab was ranked first.

Everything learned stays in `learning-v1.json` beside the saved choices, private to the user, and Clear Tab Scout History removes it.

For imported Google searches, Google's standard results URL uses `/search` and a `q` query parameter. Chromium's own tests use `https://www.google.com/search?q={searchTerms}`. Extra parameters such as `client=...` are not the query text. Parse with structured URL APIs, require a recognized Google host and search path, decode form-encoded spaces and Unicode correctly, and reject spoofed hosts, empty queries, and unrelated pages. [Chromium: Search template tests](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/components/search_engines/template_url_unittest.cc)

Recognizing a query in a visited Google results URL is a local history extraction technique. It neither establishes which engine is currently selected in Safari nor accesses the user's Google Account history.

Apple's search design guidance also recommends useful recent searches, clearly distinguished predictive text, and controls to remove recent items. [Apple: Design intuitive search experiences](https://developer.apple.com/videos/play/wwdc2026/292/)
