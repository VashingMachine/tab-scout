# Tab Scout

Find an open tab in Safari, Chrome, Firefox or Zen before opening another one.

Tab Scout is a **native macOS menu-bar app**. Press **Cmd+T in Safari, Google Chrome, Firefox or Zen** to open a focused search palette over the current page. It searches the tabs of the browser you are in, or of one Chrome profile, and a sideways swipe moves to another browser or profile: picking a tab switches to it, and when nothing matches a new tab opens where you are. Safari and Chrome need no browser extension; an optional one adds grouping, ungrouping and muting of Chrome tabs. Firefox and Zen let no other app list their tabs, so they are reached through Tab Scout's small extension, added once to each.

## Install

```sh
git clone https://github.com/VashingMachine/tab-scout.git ~/projects/tabs-scout && bash ~/projects/tabs-scout/deploy.sh
```

This builds Tab Scout, installs it in `/Applications` and opens it. Grant the permissions its window asks for, then press Cmd+T in your browser.

Requirements:

- Xcode 26 or later, or its Command Line Tools (`xcode-select --install`).
- Recommended: a free Apple Development certificate, so macOS keeps the permissions across updates. In Xcode, open **Settings > Accounts**, add your Apple Account, then **Manage Certificates... > + > Apple Development**.

To update: `cd ~/projects/tabs-scout && git pull && bash deploy.sh`

## Features

- Search tab titles and URLs with case-insensitive, diacritic-insensitive multiword matching. Matches at the start of a word rank first; the initials of title words (`gh` for GitHub, `pr` for a pull request) and one typo in longer words also find tabs.
- Switch to an existing tab instead of creating a duplicate.
- Offer the previously viewed tab first, so Cmd+T, Enter flips between your two most recent tabs.
- Search Safari, Chrome, Firefox and Zen tabs. Chrome's incognito windows and Firefox's and Zen's private windows are never read.
- Open an address or search in the browser you were using: Safari, Firefox and Zen search with their configured search engine, Chrome with Google, because Chrome offers no scripting command for its own engine.
- Show cached tab results immediately while refreshing them in the background.
- Load favicons asynchronously and cache them across app restarts.
- Include optional Google autocomplete predictions without delaying local results.
- Rank results using locally remembered Tab Scout choices and optional Safari, Chrome, Firefox and Zen browsing history, from every profile.
- Learn which tab you choose for what you type, so the same letters lead there again, even when the page title does not contain them.
- With empty input, list the other tabs in the order you last viewed them. Tab switches are followed as they happen through the keyboard permission's accessibility access, and how long you read each page breaks ties.
- Bring tabs about the same work as the current page forward and label them, such as the Jira ticket named by the pull request on screen. Ticket keys, pull and merge requests, repositories and Google document IDs in titles and addresses connect tabs.
- Find tabs by meaning when few match the typed text: each typed English word is widened to similar words with the system's on-device word embedding, so "email" finds an inbox and "cooking" a recipe. These guesses are labeled with the connecting word and listed below text matches; Enter keeps searching the typed text.
- Optionally search page text (off by default): pages you have viewed for a few seconds are read through the browser's scripting interface, so typing finds tabs that mention your words, with a snippet. Chrome allows this only with View > Developer > Allow JavaScript from Apple Events turned on. Firefox and Zen pages are not read. Pages you have not viewed are not read, so sleeping tabs stay asleep.
- Ask in plain language by starting with `?`, such as `?the pull request I was reviewing before lunch`. On Macs with Apple Intelligence, the on-device model picks tabs from their titles, sites and when you last viewed them; picks come first and are labeled. Requests are never sent to Google or anywhere else.
- Switch between Safari, each Chrome profile, Firefox and each of Zen's spaces from the palette: swipe sideways with two fingers anywhere over it. Safari or Firefox comes forward, Chrome brings that profile's window forward, or opens one, as its own Profiles menu does, Zen goes to that space as its own Spaces menu does, and the palette stays open. Each place is shown in its own color and woven pattern: Safari with its compass and ripples, Firefox with a flame, Zen with rings, a Chrome profile in the color Chrome gives it when it has one, a Zen space in its theme's color with its emoji, otherwise a color Tab Scout picks. Its name sits at the end of the search field, a dot per place in the footer, grouped by browser. In **Settings** each place can be hidden from swiping and given its own look: up to three colors that blend across the palette, how strongly they wash it, a pattern, and how much pattern and grain show.
- Move between places from the keyboard too: Tab goes to the next place and Shift+Tab to the one before. With Option held, Tab or a swipe takes the tab on screen along, as the `move` command does.
- Close a tab without leaving the palette: Command+W closes the selected tab in its browser, and the palette stays open on the next row. While nothing is typed, Command+Delete does the same.
- Keep each browser, Chrome profile and Zen space to itself: with more than one place to go, the palette lists only Safari's tabs over Safari, only the tabs of the profile in front over Chrome and only the tabs of the space in front over Zen, and anything picked opens there. Zen's spaces are named from the session file Zen keeps, which needs Full Disk Access; without it Zen is one place. Telling a profile's windows apart needs Tab Scout's Chrome extension in each profile; without it, every Chrome tab is listed and the footer says so. History and recent searches are still shared by all profiles.
- Run commands by starting with `` ` ``: the palette lists the commands of the browser it opened over instead of tabs, and each row says what it would do now.
  - `move` sends the tab on screen to another place, with a row per place: the page opens there first, then the original closes. Option+Enter keeps the original. The page is opened again there, so scroll position, form input and sign-in do not travel.
  - `copy` copies the tab's address, and `copy link` a Markdown link with its title.
  - `dupes` closes the extra tabs of pages open more than once and keeps the one on screen or viewed last. `sweep` closes tabs not viewed for 7 days, or for the number typed after it. `undo` reopens what a command or Command+W closed, in background tabs of the same window.
  - In Chrome, `group` sorts the front window's loose tabs into named tab groups by topic: Apple Intelligence picks the topics on this Mac; without it, tabs about the same ticket, pull request, repository or site are grouped. `ungroup` takes the window's tabs out of their groups, and `mute` silences the profile's tabs that are playing sound, or gives the ones it muted their sound back. Chrome lets only extensions do these, so they use Tab Scout's small Chrome extension, and Safari lets no other app do them. `mute` also works in Firefox and Zen, for all of the browser's tabs.
- Learn how you pick: Tab Scout logs the signals behind each picked tab, as numbers only, and relearns its ranking weights every ten picks. Learned weights are used only when they rank your recent picks better than the standard ones. The menu shows how often your pick was ranked first.
- Learn habits: which site usually follows the one on screen, and which sites belong to this hour of a weekday or weekend. Habits nudge empty-input order and break ties between equally good matches; glances while flicking through tabs do not count.
- Center the native palette on the focused window of the browser in front when its geometry is available, with a screen-based fallback.

## Setup

Tab Scout runs in the menu bar rather than the Dock. **Settings** opens on its **Setup** page on first launch, and whenever Cmd+T still needs something; the page ticks off each step once it is done, and a badge beside it counts what is missing:

1. **Device Control and Data Access** (**Accessibility** before macOS 27), for the Cmd+T keyboard hook. Required.
2. **Automation** for Safari and for Google Chrome, to read, select, and open their tabs. Each browser asks separately; a browser you do not allow is left out.
3. Optionally the Chrome extension for the `group`, `ungroup` and `mute` commands. **Add to Chrome** opens Chrome's Extensions page and shows the extension's folder in Finder: turn on Developer mode and drag the folder onto the page.
4. Optionally Firefox and Zen, each listed when installed. **Add to Zen** or **Add to Firefox** makes the browser ask whether to add Tab Scout's extension; once it is added, Cmd+T there opens the palette, and until then Cmd+T stays the browser's own. Zen first needs `xpinstall.signatures.required` set to `false` in `about:config`, because the extension is not signed by Mozilla; Firefox adds it for good only once it is signed, and otherwise loads it until it quits. See [Firefox And Zen](docs/NATIVE_COMPANION.md#firefox-and-zen).
5. Optionally browser history, which needs **Full Disk Access**, to rank with Safari, Chrome, Firefox and Zen history.
6. Optionally **Start Tab Scout at login**.

**Settings…** in the menu-bar menu (Cmd+, while a Tab Scout window is open) holds **Google Suggestions**, **Use Browser History** and its sources, **Search Page Text**, **Start at Login**, **Clear Tab Scout History**, and the palette's places and swipe: whether a swipe carries as far as a flick goes or moves **one place at a time**, and a sensitivity slider for how far a swipe has to travel and how far a flick carries. Suggestions and history are off on a fresh installation. The app must keep running for Cmd+T, which it captures only while Safari or Chrome is active, or Firefox or Zen with Tab Scout's extension connected.

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
- With more than one browser open, or Chrome with more than one profile, swipe sideways with two fingers, turn a mouse wheel sideways, or click the name or a dot to switch between the browsers and Chrome's profiles. Swiping up and down still scrolls the results. After a switch the list fades once to the new place's tabs and stays put until the palette closes; Enter pressed meanwhile waits for it.
- Press Tab or Shift+Tab to switch place as a swipe does. Hold Option with Tab, or as a swipe ends, to move the tab on screen to that place; the footer names the place before you let go.
- Command+W closes the selected tab and keeps the palette open; with nothing typed, Command+Delete does too. Typed text is still cleared by Command+Delete.
- Start with `` ` `` to list commands instead of tabs, and type to filter them; Enter runs the selected one. Words after a command's name narrow it: `` `move work ``, `` `copy md ``, `` `sweep 14 ``. Only commands the browser you opened the palette over supports are listed. After `dupes`, `sweep`, `undo`, `ungroup` and `mute` the palette stays open and its footer says what was done.
- Escape or Cmd+T dismisses the palette without changing tabs.
- The refresh button updates results. Settings and permission checks are available from the menu bar.

Open tabs come first without a heading; Recent Searches, History, and Google Suggestions have their own sections. Match quality comes first; recent and repeated local use, and how recently you viewed a tab, improve comparable matches. A tab you chose repeatedly for the same text comes first. See [Ranking Policy](docs/SAFARI_SEARCH.md#ranking-policy) for every signal and weight. Open tabs stay prominent to reduce duplicates, and arriving predictions do not move a selection you have already navigated.

## Privacy And Limits

Tab titles and URLs are read through Safari's and Chrome's local scripting interfaces, and through Tab Scout's extension in Firefox and Zen. Chrome's incognito windows and Firefox's and Zen's private windows are skipped entirely. Tab Scout does not read webpage bodies or form fields unless **Search Page Text** is enabled; then it reads the visible text of pages you have viewed, keeps at most 30,000 characters of each in memory only, never saves or sends it, and drops it when a tab closes, the option is turned off, or history is cleared. Tab snapshots, imported Safari history, and Google prediction caches stay in memory. Accepted choices, what Tab Scout learned from them (typed text per page, reading time, site habits), when each open page was first seen and last viewed (for `sweep`), and the bounded favicon cache are stored locally; Clear Tab Scout History removes them. The addresses of tabs a command closed stay in memory for `undo` until Tab Scout quits.

Enabling Google Suggestions sends eligible typed search text to Google's public autocomplete endpoint before Enter. Requests use an ephemeral session without cookies, credentials, Safari's login session, or local history. Predictions are generic, not signed-in Google Account personalization. The undocumented endpoint is best-effort and may be unavailable. Submitted searches still use Safari's configured provider, or Google in Chrome.

History import is optional and read-only. It reads every Safari, Chrome, Firefox and Zen profile, each of which can be left out under **Settings › Browser History**; synced history from other devices is not guaranteed to be represented. Chrome's, Firefox's and Zen's history and icons are read from a private copy that is deleted right away, because these browsers lock them while they run. **Clear Tab Scout History** removes accepted Tab Scout choices, not browser history or Google Account activity.

Chrome's profiles are read from its Profiles menu through the keyboard permission's accessibility access, and their names and colors from Chrome's Local State file when Full Disk Access allows it. Switching presses the profile's item in that menu. Zen's spaces, their colors and which pages each holds are read from `zen-sessions.jsonlz4` and `prefs.js` in Zen's profile folder when Full Disk Access allows it, only to name the spaces and tell which is in front; switching presses the space's item, or the next and previous commands, in Zen's Spaces menu. Which profile a window belongs to is asked of Tab Scout's extension in each profile, which can see only its own profile's windows.

Tab Scout's optional Chrome extension may read the titles and addresses of its profile's tabs, which Chrome describes as reading your browsing history. It uses them only when Tab Scout asks: one window's tabs to group or ungroup them, and which of the profile's tabs play sound to mute them. It talks only to `TabScoutChromeHost`, the helper inside Tab Scout.app that Chrome starts for it. The helper talks only to the running Tab Scout, through a socket only your user can open, and each checks the other's code signature. Topics are picked by Apple's on-device model; nothing is sent anywhere else.

Tab Scout's extension for Firefox and Zen reads the titles and addresses of the browser's tabs, which the browser describes as access to browser tabs and, before adding it, as collecting browsing activity. It passes them only to `TabScoutFirefoxHost`, the helper inside Tab Scout.app that the browser starts for it, and does what Tab Scout asks: switch to a tab, open an address, a search or a new tab, close or reopen tabs, mute tabs. The helper talks only to the running Tab Scout, through a socket only your user can open, and each checks the other's code signature. The extension asks for no access to any site, so it cannot read pages.

The native scripting interface does not reliably identify private-browsing tabs. **Do not treat this app or its caches as a private-browsing boundary.** Avoid using it for activity that must not be recorded, and disable suggestions when typed text must remain local.

See [Native App Details](docs/NATIVE_COMPANION.md) for permissions, cache bounds, data locations, and removal instructions.

## Verification

`bash test.sh` covers search, ranking, previous-tab tracking, Safari and Chrome history fixtures (including a locked Chrome database), keyboard decisions, palette placement, cache races, Google response handling, favicons, Safari bridge fixtures, the Chrome script against a stand-in for Chrome, commands, tab grouping, which tabs each place lists, closing and reopening tabs, duplicate and unviewed tabs, Chrome profiles from their menu and Local State, the profile swipe, Zen's session file, spaces and Spaces menu, the links to the Chrome and Firefox extensions against stand-in extensions, the Firefox extension's own tab handling, and Firefox and Zen history fixtures. With Apple Intelligence available, one grouping check asks the on-device model. Tests do not request permissions, touch a real browser, or read the user's real Safari history. Physical shortcut behavior needs a live check in each browser. `/usr/bin/python3 Tests/FirefoxLive/run.py`, which is not part of `test.sh`, runs the Firefox extension's commands in a hidden second copy of Firefox, or of Zen when given its path, on a throwaway profile.

## Repository Layout

- `Sources/` and `Resources/`: native app and the Safari (AppleScript) and Chrome (JavaScript for Automation) scripting bridges.
- `Resources/ChromeExtension/` and `Sources/ChromeHost/`: the optional Chrome extension for grouping tabs and the helper a browser starts for Tab Scout's extension.
- `Resources/FirefoxExtension/`: the extension Firefox and Zen are reached through. `sign-firefox.sh` has Mozilla sign it.
- `Tests/`: automated suites and manual test notes.
- `build.sh` and `test.sh`: build and test entry points.
- `docs/`: native app details, manual QA checklists, and Safari search research.
