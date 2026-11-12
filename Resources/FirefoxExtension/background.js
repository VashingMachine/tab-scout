// Lets the Tab Scout app on this Mac search and switch this browser's tabs. Firefox and the browsers built on it,
// such as Zen, offer other apps no scripting for tabs, so this extension answers what Safari and Chrome answer
// through theirs: it lists the tabs, says which is on screen, switches to one, opens an address, a search or a
// new tab, and closes or reopens tabs. It also mutes tabs playing sound. Private windows are never read or used.
// Messages pass through TabScoutFirefoxHost, the helper in Tab Scout.app that the browser starts for native
// messaging. Nothing is sent anywhere else.

const HOST = 'local.tabscout.firefox';
let port = null;
let announcing = {};

function connect() {
    if (port) return;
    let current;
    const opened = Date.now();
    try {
        current = browser.runtime.connectNative(HOST);
    } catch (error) {
        return setTimeout(connect, 15000);
    }
    port = current;
    current.onMessage.addListener(message => {
        handle(message).then(reply => {
            try { current.postMessage(reply); } catch (error) { /* Disconnected meanwhile. */ }
        });
    });
    current.onDisconnect.addListener(() => {
        if (port === current) port = null;
        // A helper that ran for a while was replaced or stopped, so a new one starts at once. One that failed
        // straight away, as before Tab Scout is set up, is tried again later.
        setTimeout(connect, Date.now() - opened > 10000 ? 1000 : 15000);
    });
}

// Tells Tab Scout that the tab on screen ('focus') or the set of tabs ('tabs') changed, at most once per moment,
// so it reads them again instead of asking over and over.
function announce(event) {
    if (announcing[event]) return;
    announcing[event] = setTimeout(() => {
        delete announcing[event];
        try { if (port) port.postMessage({type: 'event', event: event}); } catch (error) { /* Disconnected. */ }
    }, 200);
}

async function handle(message) {
    try {
        if (message.type === 'bridge') return {id: message.id, result: await dispatch(message.command, message.args || [])};
        if (message.type === 'mute') return Object.assign({id: message.id}, await mute());
        // Tab Scout asks when it connects, and offers the extension again when it has a newer one.
        if (message.type === 'version') return {id: message.id, version: browser.runtime.getManifest().version};
        return {id: message.id, error: 'unknown request'};
    } catch (error) {
        return {id: message.id, error: String((error && error.message) || error)};
    }
}

// The commands of Tab Scout's Safari and Chrome scripts, with the same arguments and answers.
async function dispatch(operation, args) {
    if (operation === 'list') return JSON.stringify(rows(await normalWindows()));
    if (operation === 'active') return JSON.stringify(front(await normalWindows()));
    if (operation === 'switch') return select(Number(args[0]), Number(args[1]), args[2], args[3]);
    if (operation === 'url') return open(Number(args[0]), {url: args[1]}, Number(args[2] || 0), args[3]);
    if (operation === 'search') return open(Number(args[0]), {search: args[1]}, Number(args[2] || 0), args[3]);
    if (operation === 'new-tab') return open(Number(args[0]), {}, 0, '');
    if (operation === 'close') return close(args);
    if (operation === 'reopen') return reopen(args);
    throw new Error('unknown request');
}

// This browser's normal windows with their tabs, the one last in front first. While Tab Scout's palette has the
// keyboard no window counts as focused, so the browser is asked which one was last.
async function normalWindows() {
    const [windows, last] = await Promise.all([
        browser.windows.getAll({populate: true, windowTypes: ['normal']}),
        browser.windows.getLastFocused().catch(() => null)
    ]);
    return ordered(windows, last ? last.id : null);
}

// Private windows are left out even when the extension is allowed to run in them.
function ordered(windows, frontID) {
    const normal = windows.filter(window => !window.incognito && (window.type || 'normal') === 'normal');
    return normal.filter(window => window.id === frontID).concat(normal.filter(window => window.id !== frontID));
}

// The rows of Safari's script: window id, one-based index, title, address and whether the tab is its window's
// current one. The window in front comes first, so the first marked row is the tab on screen.
function rows(windows) {
    const result = [];
    for (const window of windows) {
        for (const tab of window.tabs || []) {
            result.push([window.id, tab.index + 1, tab.title || '', tab.url || '', Boolean(tab.active)]);
        }
    }
    return result;
}

// Only the tab on screen, or nothing without a window or while the tab on screen is one the browser keeps to
// itself, such as Zen's empty tab.
function front(windows) {
    const tab = windows.length > 0 ? (windows[0].tabs || []).find(candidate => candidate.active) : null;
    return tab ? [windows[0].id, tab.index + 1, tab.title || '', tab.url || ''] : [];
}

async function normalWindow(windowId) {
    if (!windowId) return null;
    try {
        const window = await browser.windows.get(windowId, {populate: true});
        return ordered([window], window.id)[0] || null;
    } catch (error) {
        return null;
    }
}

// The tab meant by a row listed earlier. A title can change in the background (unread counts, timers), so the
// address alone confirms the tab at its position; a tab that moved is found by its address and title.
function pick(tabs, index, url, title) {
    const same = tab => (tab.url || '') === url && (tab.title || '') === title;
    const there = tabs.find(tab => tab.index === index - 1);
    if (there && same(there)) return there;
    return tabs.find(same) || (there && (there.url || '') === url ? there : null);
}

// The tab at a one-based position while it still shows `url`, for closing it or opening a page in it.
function unchanged(tabs, index, url) {
    const there = tabs.find(tab => tab.index === index - 1);
    return there && (there.url || '') === url ? there : null;
}

async function select(windowId, index, url, title) {
    const window = await normalWindow(windowId);
    const target = window ? pick(window.tabs || [], index, url, title) : null;
    if (!target) throw new Error('TAB_SCOUT_STALE');
    await browser.tabs.update(target.id, {active: true});
    await browser.windows.update(window.id, {focused: true});
    return 'ok';
}

// Opens an address, a search with the browser's own search engine, or the new-tab page, in a new tab of the
// given window. The empty tab at `reuseIndex` is used instead while it still shows `reuseURL`. Without a normal
// window, a new one is made.
async function open(windowId, what, reuseIndex, reuseURL) {
    let window = await normalWindow(windowId) || (await normalWindows())[0];
    let tab = null;
    if (!window) {
        // A new window starts with one new-tab page.
        window = await browser.windows.create({});
        tab = (window.tabs || []).find(candidate => candidate.active) || (window.tabs || [])[0] || null;
    } else if (reuseIndex > 0) {
        tab = unchanged(window.tabs || [], reuseIndex, reuseURL);
    }
    if (tab && what.url) {
        await browser.tabs.update(tab.id, {url: what.url, active: true});
    } else if (tab) {
        await browser.tabs.update(tab.id, {active: true});
    } else {
        tab = await browser.tabs.create(what.url ? {windowId: window.id, url: what.url, active: true} : {windowId: window.id, active: true});
    }
    if (what.search) await browser.search.search({query: what.search, tabId: tab.id});
    await browser.windows.update(window.id, {focused: true});
    return 'ok';
}

// Closes the tabs given as window id, position and address. A tab no longer at its position with its address
// stays open. Answers the places in the list of the tabs it closed.
async function close(args) {
    const closed = [];
    const windows = new Map();
    for (let position = 0; position < Math.floor(args.length / 3); position++) {
        const windowId = Number(args[position * 3]);
        // Each window is read once, before any of its tabs goes, so the positions are those Tab Scout listed.
        if (!windows.has(windowId)) windows.set(windowId, await normalWindow(windowId));
        const window = windows.get(windowId);
        const tab = window ? unchanged(window.tabs || [], Number(args[position * 3 + 1]), args[position * 3 + 2]) : null;
        if (!tab) continue;
        try {
            await browser.tabs.remove(tab.id);
            closed.push(position);
        } catch (error) { /* Closed by someone else meanwhile. */ }
    }
    return JSON.stringify(closed);
}

// Opens addresses, given as window id and address pairs, in background tabs of their window, or of the window
// in front when theirs is gone. The tab on screen stays. A page the browser lets no extension open stays closed.
async function reopen(args) {
    const count = Math.floor(args.length / 2);
    for (let pair = 0; pair < count; pair++) {
        const url = args[pair * 2 + 1];
        const window = await normalWindow(Number(args[pair * 2])) || (await normalWindows())[0];
        try {
            if (window) await browser.tabs.create({windowId: window.id, url: url, active: false});
            else await browser.windows.create({url: url});
        } catch (error) { /* One of the browser's own pages. */ }
    }
    return String(count);
}

// Mutes the tabs that are playing sound. With none playing, the tabs it muted get their sound back.
async function mute() {
    const plan = muting(await browser.tabs.query({}), browser.runtime.id);
    await Promise.all(plan.tabIds.map(id => browser.tabs.update(id, {muted: plan.muted})));
    return plan.muted ? {muted: plan.tabIds.length, unmuted: 0} : {muted: 0, unmuted: plan.tabIds.length};
}

// The tabs to change: those playing sound are muted. When none is, the ones this extension muted are unmuted;
// a tab the person muted in the browser stays muted.
function muting(tabs, extensionId) {
    const silenced = tab => Boolean(tab.mutedInfo && tab.mutedInfo.muted);
    const sounding = tabs.filter(tab => tab.audible && !silenced(tab));
    if (sounding.length > 0) return {muted: true, tabIds: sounding.map(tab => tab.id)};
    const own = tabs.filter(tab => silenced(tab) && tab.mutedInfo.reason === 'extension' && tab.mutedInfo.extensionId === extensionId);
    return {muted: false, tabIds: own.map(tab => tab.id)};
}

if (typeof browser !== 'undefined' && browser.runtime) {
    browser.tabs.onActivated.addListener(() => announce('focus'));
    browser.windows.onFocusChanged.addListener(id => { if (id !== browser.windows.WINDOW_ID_NONE) announce('focus'); });
    // The tab on screen went to another page, or its page got its title.
    browser.tabs.onUpdated.addListener((id, change, tab) => { if (tab.active && (change.url || change.title)) announce('focus'); });
    for (const event of [browser.tabs.onCreated, browser.tabs.onRemoved, browser.tabs.onMoved, browser.tabs.onAttached, browser.tabs.onDetached]) {
        event.addListener(() => announce('tabs'));
    }
    connect();
}
