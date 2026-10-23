# Tab Scout

Find an open Safari or Chrome tab before opening another one.

Tab Scout is a **native macOS menu-bar app**. Press **Cmd+T in Safari or Google Chrome** to open a focused search palette over the current page. It searches the tabs of both browsers at once: picking a tab switches to it in its own browser, and when nothing matches a new tab opens in the browser you were using. No browser extension is required; an optional one adds grouping of Chrome tabs.

## Install

```sh
git clone https://github.com/VashingMachine/tab-scout.git ~/projects/tabs-scout && bash ~/projects/tabs-scout/deploy.sh
```

This builds Tab Scout, installs it in `/Applications` and opens it. Grant the permissions its window asks for, then press Cmd+T in Safari or Chrome.

Requirements:

- Xcode 26 or later, or its Command Line Tools (`xcode-select --install`).
- Recommended: a free Apple Development certificate, so macOS keeps the permissions across updates. In Xcode, open **Settings > Accounts**, add your Apple Account, then **Manage Certificates... > + > Apple Development**.

To update: `cd ~/projects/tabs-scout && git pull && bash deploy.sh`

## Features

- Search tab titles and URLs with case-insensitive, diacritic-insensitive multiword matching. Matches at the start of a word rank first; the initials of title words (`gh` for GitHub, `pr` for a pull request) and one typo in longer words also find tabs.
- Switch to an existing tab instead of creating a duplicate.
- Offer the previously viewed tab first, so Cmd+T, Enter flips between your two most recent tabs.
- Search Safari and Chrome tabs together while Chrome is running. Window labels name the browser once tabs from both are listed. Chrome's incognito windows are never read.
- Open an address or search in the browser you were using: Safari searches with its configured search engine, Chrome with Google, because Chrome offers no scripting command for its own engine.
- Show cached tab results immediately while refreshing them in the background.
- Load favicons asynchronously and cache them across app restarts.
- Include optional Google autocomplete predictions without delaying local results.
- Rank results using locally remembered Tab Scout choices and optional Safari and Chrome browsing history, from every profile.
- Learn which tab you choose for what you type, so the same letters lead there again, even when the page title does not contain them.
- With empty input, list the other tabs in the order you last viewed them. Tab switches are followed as they happen through the keyboard permission's accessibility access, and how long you read each page breaks ties.
- Bring tabs about the same work as the current page forward and label them, such as the Jira ticket named by the pull request on screen. Ticket keys, pull and merge requests, repositories and Google document IDs in titles and addresses connect tabs.
- Find tabs by meaning when few match the typed text: each typed English word is widened to similar words with the system's on-device word embedding, so "email" finds an inbox and "cooking" a recipe. These guesses are labeled with the connecting word and listed below text matches; Enter keeps searching the typed text.
- Optionally search page text (off by default): pages you have viewed for a few seconds are read through the browser's scripting interface, so typing finds tabs that mention your words, with a snippet. Chrome allows this only with View > Developer > Allow JavaScript from Apple Events turned on. Pages you have not viewed are not read, so sleeping tabs stay asleep.
- Ask in plain language by starting with `?`, such as `?the pull request I was reviewing before lunch`. On Macs with Apple Intelligence, the on-device model picks tabs from their titles, sites and when you last viewed them; picks come first and are labeled. Requests are never sent to Google or anywhere else.
- Run commands by starting with `` ` ``: the palette lists the commands of the browser it opened over instead of tabs. `group` sorts the front Chrome window's loose tabs into named tab groups by topic. Apple Intelligence picks the topics on this Mac; without it, tabs about the same ticket, pull request, repository or site are grouped. Chrome lets only extensions make tab groups, so this uses Tab Scout's small Chrome extension. Safari lets no other app make tab groups, so it has no commands yet.
- Learn how you pick: Tab Scout logs the signals behind each picked tab, as numbers only, and relearns its ranking weights every ten picks. Learned weights are used only when they rank your recent picks better than the standard ones. The menu shows how often your pick was ranked first.
- Learn habits: which site usually follows the one on screen, and which sites belong to this hour of a weekday or weekend. Habits nudge empty-input order and break ties between equally good matches; glances while flicking through tabs do not count.
- Center the native palette on the focused window of the browser in front when its geometry is available, with a screen-based fallback.

## Setup

Tab Scout runs in the menu bar rather than the Dock. Its **Set Up Tab Scout** window opens on first launch, or from the menu, and ticks off each step once it is done:

1. **Device Control and Data Access** (**Accessibility** before macOS 27), for the Cmd+T keyboard hook. Required.
2. **Automation** for Safari and for Google Chrome, to read, select, and open their tabs. Each browser asks separately; a browser you do not allow is left out.
3. Optionally the Chrome extension for the `group` command. **Add to Chrome** opens Chrome's Extensions page and shows the extension's folder in Finder: turn on Developer mode and drag the folder onto the page.
4. Optionally browser history, which needs **Full Disk Access**, to rank with Safari and Chrome history.
5. Optionally **Start Tab Scout at login**.

The menu-bar menu also has **Google Suggestions**, **Use Browser History** and **History Profiles**; suggestions and history are off on a fresh installation. The app must keep running for Cmd+T, which it captures only while Safari or Chrome is active.

If Cmd+T stops working after an update although its switch looks on, remove Tab Scout from Device Control and Data Access, add `/Applications/Tab Scout.app` again and relaunch it. [Native App Details](docs/NATIVE_COMPANION.md) has every setup step, the build options, and how to remove the app.

With [Task](https://taskfile.dev) installed, `task deploy` runs the tests before deploying, `task deploy:plan` shows where it installs and which certificate signs it, and `task` lists the rest.

## Usage

- Type a tab title, URL, or search phrase. The search field is focused when the palette opens.
- Use Up/Down to select a result, then Enter to activate it. Clicking an actionable result works too.
- With empty input, the first result is the tab you viewed before the current one. Cmd+T, Enter switches to it; Cmd+T, Enter again returns to where you started.
- Cmd+Enter or Shift+Enter opens the query in a new tab even when an existing tab matches, or in the tab on screen when it is empty. Holding Shift lists that row first, so you see what Enter will open. Doing that, or choosing the search row, teaches Enter to prefer a new tab for that text.
- Questions and phrases of four or more words search by default unless a tab title holds the whole phrase. Guesses from typos or initials are listed below the typed search, which stays the default.
- With empty input, the other open tabs follow the previous tab and the New tab action comes after them; Cmd+Enter also opens a new tab. In Safari it uses the native new-tab command and configured page, not a forced `about:blank` URL; in Chrome, Chrome's own new-tab page.
- The tab you are on is never listed. When it is the only match, Enter opens a new tab with your query.
- On an empty tab, such as the Start Page, an address, search, history page or suggestion opens in that tab instead of a second one beside it, and the New tab action keeps it.
- Start with `?` to ask Apple Intelligence for a tab in your own words. While it answers, the request is also matched as ordinary text, and Enter on the search row searches it without the `?`.
- Start with `` ` `` to list commands instead of tabs, and type to filter them; Enter runs the selected one. Only commands the browser you opened the palette over supports are listed.
- Escape or Cmd+T dismisses the palette without changing tabs.
- The refresh button updates results. Preferences and permission checks are available from the menu bar.

Open tabs come first without a heading; Recent Searches, History, and Google Suggestions have their own sections. Match quality comes first; recent and repeated local use, and how recently you viewed a tab, improve comparable matches. A tab you chose repeatedly for the same text comes first. See [Ranking Policy](docs/SAFARI_SEARCH.md#ranking-policy) for every signal and weight. Open tabs stay prominent to reduce duplicates, and arriving predictions do not move a selection you have already navigated.

## Privacy And Limits

Tab titles and URLs are read through Safari's and Chrome's local scripting interfaces. Chrome's incognito windows are skipped entirely. Tab Scout does not read webpage bodies or form fields unless **Search Page Text** is enabled; then it reads the visible text of pages you have viewed, keeps at most 30,000 characters of each in memory only, never saves or sends it, and drops it when a tab closes, the option is turned off, or history is cleared. Tab snapshots, imported Safari history, and Google prediction caches stay in memory. Accepted choices, what Tab Scout learned from them (typed text per page, reading time, site habits) and the bounded favicon cache are stored locally; Clear Tab Scout History removes them.

Enabling Google Suggestions sends eligible typed search text to Google's public autocomplete endpoint before Enter. Requests use an ephemeral session without cookies, credentials, Safari's login session, or local history. Predictions are generic, not signed-in Google Account personalization. The undocumented endpoint is best-effort and may be unavailable. Submitted searches still use Safari's configured provider, or Google in Chrome.

History import is optional and read-only. It reads every Safari and Chrome profile, each of which can be left out under **History Profiles**; synced history from other devices is not guaranteed to be represented. Chrome's history and icons are read from a private copy that is deleted right away, because Chrome locks them while it runs. **Clear Tab Scout History** removes accepted Tab Scout choices, not browser history or Google Account activity.

Tab Scout's optional Chrome extension may read the titles and addresses of its profile's tabs, which Chrome describes as reading your browsing history. It uses them only when Tab Scout asks for one window's tabs to group them, and it talks only to `TabScoutChromeHost`, the helper inside Tab Scout.app that Chrome starts for it. The helper talks only to the running Tab Scout, through a socket only your user can open, and each checks the other's code signature. Topics are picked by Apple's on-device model; nothing is sent anywhere else.

The native scripting interface does not reliably identify private-browsing tabs. **Do not treat this app or its caches as a private-browsing boundary.** Avoid using it for activity that must not be recorded, and disable suggestions when typed text must remain local.

See [Native App Details](docs/NATIVE_COMPANION.md) for permissions, cache bounds, data locations, and removal instructions.

## Verification

`bash test.sh` covers search, ranking, previous-tab tracking, Safari and Chrome history fixtures (including a locked Chrome database), keyboard decisions, palette placement, cache races, Google response handling, favicons, Safari bridge fixtures, the Chrome script against a stand-in for Chrome, commands, tab grouping, and the link to the Chrome extension against stand-in extensions. With Apple Intelligence available, one grouping check asks the on-device model. Tests do not request permissions, touch a real browser, or read the user's real Safari history. Physical shortcut behavior needs a live check in Safari and Chrome.

## Repository Layout

- `Sources/` and `Resources/`: native app and the Safari (AppleScript) and Chrome (JavaScript for Automation) scripting bridges.
- `Resources/ChromeExtension/` and `Sources/ChromeHost/`: the optional Chrome extension for grouping tabs and the helper Chrome starts for it.
- `Tests/`: automated suites and manual test notes.
- `build.sh` and `test.sh`: build and test entry points.
- `docs/`: native app details, manual QA checklists, and Safari search research.
