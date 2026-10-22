// Lets the Tab Scout app on this Mac group this Chrome profile's tabs. Tab Scout picks the groups with Apple's
// on-device model; this extension only lists the tabs of the window Tab Scout asks about and makes the groups.
// Messages pass through TabScoutChromeHost, the helper in Tab Scout.app that Chrome starts for native messaging.

const HOST = 'local.tabscout.chrome';
// chrome.tabGroups.TAB_GROUP_ID_NONE
const NO_GROUP = -1;
let port = null;

function connect() {
    if (port) return;
    const current = chrome.runtime.connectNative(HOST);
    const opened = Date.now();
    port = current;
    current.onMessage.addListener(message => {
        handle(message).then(reply => {
            try { current.postMessage(reply); } catch (error) { /* Disconnected meanwhile. */ }
        });
    });
    current.onDisconnect.addListener(() => {
        void chrome.runtime.lastError;
        if (port === current) port = null;
        // A helper that ran for a while was replaced or stopped, so a new one starts at once. One that failed
        // straight away, as before Tab Scout is set up, is tried again by the alarm.
        if (Date.now() - opened > 10000) connect();
    });
}

async function handle(message) {
    try {
        if (message.type === 'tabs') return Object.assign({id: message.id}, await windowTabs(message.windowId));
        if (message.type === 'group') return {id: message.id, grouped: await group(message.windowId, message.groups)};
        return {id: message.id, error: 'unknown request'};
    } catch (error) {
        return {id: message.id, error: String((error && error.message) || error)};
    }
}

async function windowTabs(windowId) {
    let window;
    try {
        window = await chrome.windows.get(windowId, {populate: true});
    } catch (error) {
        // A window of another profile, or one this extension may not see, such as an incognito window.
        return {error: 'no-window'};
    }
    return {tabs: listed(window.tabs || [])};
}

// What Tab Scout plans groups from.
function listed(tabs) {
    return tabs.map(tab => ({
        id: tab.id,
        title: tab.title || '',
        url: tab.url || tab.pendingUrl || '',
        pinned: Boolean(tab.pinned),
        grouped: tab.groupId !== NO_GROUP
    }));
}

async function group(windowId, groups) {
    let made = 0;
    for (const planned of groups) {
        const tabs = await Promise.all(planned.tabIds.map(id => chrome.tabs.get(id).catch(() => null)));
        const tabIds = movable(tabs, windowId);
        if (tabIds.length < 2) continue;
        const groupId = await chrome.tabs.group({tabIds, createProperties: {windowId}});
        await chrome.tabGroups.update(groupId, {title: String(planned.title).slice(0, 40)});
        made += 1;
    }
    return made;
}

// Tabs closed, pinned, grouped or moved to another window since Tab Scout listed them stay where they are.
function movable(tabs, windowId) {
    return tabs.filter(tab => tab && tab.windowId === windowId && !tab.pinned && tab.groupId === NO_GROUP).map(tab => tab.id);
}

// Chrome stops an idle extension, but keeps it running while it is connected to the helper.
if (typeof chrome !== 'undefined' && chrome.runtime) {
    chrome.runtime.onStartup.addListener(connect);
    chrome.runtime.onInstalled.addListener(connect);
    chrome.alarms.onAlarm.addListener(connect);
    chrome.alarms.create('connect', {periodInMinutes: 1});
    connect();
}
