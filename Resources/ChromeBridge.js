// Reads and changes Chrome's tabs for Tab Scout: osascript ChromeBridge.scpt <bundle id> <command> [arguments].
// Chromium browsers share Chrome's scripting terms, so the bundle identifier picks the browser. JavaScript
// needs no scripting dictionary to compile, so the app builds where Chrome is not installed.
// Incognito windows are never read or used.

function run(argv) {
    return dispatch(Application(argv[0]), argv[1], argv.slice(2));
}

// Separate from run so tests can pass a stand-in for Chrome.
function dispatch(app, operation, args) {
    if (operation === 'list') return list(app);
    if (operation === 'active') return active(app);
    if (operation === 'text') return text(app, Number(args[0]), Number(args[1]), args[2]);
    if (operation === 'switch') return select(app, Number(args[0]), Number(args[1]), args[2], args[3]);
    if (operation === 'url') return open(app, Number(args[0]), args[1], Number(args[2] || 0), args[3]);
    if (operation === 'new-tab') return open(app, Number(args[0]), null, 0, '');
    throw new Error('Unknown command');
}

function list(app) {
    if (!app.running()) return '[]';
    for (let attempt = 0; attempt < 2; attempt++) {
        // One Apple event per property for every window at once, never one per tab.
        const ids = app.windows.id();
        const modes = app.windows.mode();
        const current = app.windows.activeTabIndex();
        const titles = app.windows.tabs.title();
        const urls = app.windows.tabs.url();
        if (stable(ids, modes, current, titles, urls)) return JSON.stringify(rows(ids, modes, current, titles, urls));
    }
    throw new Error('TAB_SCOUT_SNAPSHOT_CHANGED');
}

// A window opened or a tab closed between the reads leaves the arrays out of step.
function stable(ids, modes, current, titles, urls) {
    return [modes, current, titles, urls].every(values => values.length === ids.length)
        && titles.every((windowTitles, window) => windowTitles.length === urls[window].length);
}

// The rows of Safari's script: window id, one-based index, title, URL and whether the tab is its window's
// current one. Windows come front to back, so the first marked row is the tab on screen.
function rows(ids, modes, current, titles, urls) {
    const result = [];
    ids.forEach((id, window) => {
        const windowID = numericID(id);
        if (modes[window] !== 'normal' || windowID === null) return;
        urls[window].forEach((url, tab) => {
            result.push([windowID, tab + 1, titles[window][tab] || '', url || '', tab + 1 === current[window]]);
        });
    });
    return result;
}

// Chrome's window ids are text holding a number, while Tab Scout's rows carry numbers as Safari's do.
function numericID(id) {
    const number = Number(id);
    return Number.isSafeInteger(number) && number > 0 ? number : null;
}

// Only the tab on screen, cheap enough to read after every tab switch.
function active(app) {
    if (!app.running() || app.windows.length === 0) return '[]';
    const front = app.windows[0];
    const windowID = numericID(front.id());
    if (front.mode() !== 'normal' || windowID === null) return '[]';
    const tab = front.activeTab;
    return JSON.stringify([windowID, front.activeTabIndex(), tab.title() || '', tab.url() || '']);
}

// The visible text of one tab. Chrome runs page scripts only with View > Developer > Allow JavaScript
// from Apple Events, and refuses otherwise.
function text(app, windowID, index, url) {
    const browserWindow = normalWindow(app, windowID);
    if (!browserWindow || index > browserWindow.tabs.length) throw new Error('TAB_SCOUT_STALE');
    const tab = browserWindow.tabs[index - 1];
    if (tab.url() !== url) throw new Error('TAB_SCOUT_STALE');
    const page = tab.execute({javascript: 'document.body ? document.body.innerText : ""'});
    return String(page || '').slice(0, 30000);
}

// A title can change in the background (unread counts, timers), so the URL alone confirms the tab at its index.
function select(app, windowID, index, url, title) {
    const browserWindow = normalWindow(app, windowID);
    if (!browserWindow) throw new Error('TAB_SCOUT_STALE');
    // Missing values become empty text, as in the listed rows.
    const urls = browserWindow.tabs.url().map(value => value || '');
    const titles = browserWindow.tabs.title().map(value => value || '');
    let target = urls[index - 1] === url && titles[index - 1] === title ? index : 0;
    if (target === 0) target = urls.findIndex((candidate, offset) => candidate === url && titles[offset] === title) + 1;
    if (target === 0 && urls[index - 1] === url) target = index;
    if (target === 0) throw new Error('TAB_SCOUT_STALE');
    browserWindow.activeTabIndex = target;
    bringForward(app, browserWindow);
    return 'ok';
}

// Opens `destination`, or the new-tab page when it is null, in a new tab of the given window. The empty tab at
// `reuseIndex` is used instead while it still shows `reuseURL`. Without a normal window, a new one is made.
function open(app, windowID, destination, reuseIndex, reuseURL) {
    let browserWindow = normalWindow(app, windowID) || app.windows().find(candidate => candidate.mode() === 'normal');
    let tab = null;
    if (!browserWindow) {
        app.Window().make();
        browserWindow = app.windows[0];
        // A new window starts with one new-tab page.
        tab = browserWindow.activeTab;
    } else if (reuseIndex > 0 && reuseIndex <= browserWindow.tabs.length
               && browserWindow.tabs[reuseIndex - 1].url() === reuseURL) {
        browserWindow.activeTabIndex = reuseIndex;
        tab = browserWindow.tabs[reuseIndex - 1];
    }
    if (!tab) {
        browserWindow.tabs.push(destination === null ? app.Tab() : app.Tab({url: destination}));
        browserWindow.activeTabIndex = browserWindow.tabs.length;
    } else if (destination !== null) {
        tab.url = destination;
    }
    bringForward(app, browserWindow);
    return 'ok';
}

function normalWindow(app, windowID) {
    if (!windowID) return null;
    // An id of the wrong type matches no window, so the number goes back to Chrome as text.
    const candidate = app.windows.byId(String(windowID));
    return candidate.exists() && candidate.mode() === 'normal' ? candidate : null;
}

function bringForward(app, browserWindow) {
    if (browserWindow.minimized()) browserWindow.minimized = false;
    browserWindow.index = 1;
    app.activate();
}
