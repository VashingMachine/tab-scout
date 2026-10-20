// Runs ChromeBridge.js against a scripted stand-in for Chrome, so no browser is touched:
// osascript -l JavaScript ChromeBridgeTests.js <path to ChromeBridge.js>
ObjC.import('Foundation');

function run(argv) {
    const source = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null).js;
    // Defines the script's functions. Its run, which looks the real Chrome up, is never called:
    // every check goes through dispatch with the stand-in.
    eval(source);
    let current = null;
    const call = (operation, ...args) => dispatch(current.app, operation, args);
    const byId = (fake, id) => fake.state.windows.find(w => w.id === id);

    let checks = 0;
    function expect(condition, message) {
        if (!condition) throw new Error('FAILED: ' + message);
        checks += 1;
    }
    function expectStale(action, message) {
        try { action(); } catch (error) { return expect(String(error).includes('TAB_SCOUT_STALE'), message); }
        expect(false, message);
    }
    function chrome(windows, running = true) {
        current = fakeChrome(windows, running);
        return current;
    }
    const sample = () => [
        {id: '7', mode: 'normal', active: 2, tabs: [{title: 'Mail (3)', url: 'https://mail.example/'}, {title: 'New Tab', url: 'chrome://newtab/'}]},
        {id: '8', mode: 'incognito', active: 1, tabs: [{title: 'Secret', url: 'https://secret.example/'}]},
        {id: '9', mode: 'normal', active: 1, tabs: [{title: 'Docs', url: 'https://docs.example/'}, {title: null, url: 'https://docs.example/'}]}
    ];

    chrome(sample());
    const listed = JSON.parse(call('list'));
    expect(JSON.stringify(listed) === JSON.stringify([
        [7, 1, 'Mail (3)', 'https://mail.example/', false], [7, 2, 'New Tab', 'chrome://newtab/', true],
        [9, 1, 'Docs', 'https://docs.example/', true], [9, 2, '', 'https://docs.example/', false]
    ]), 'List normal windows front to back with one-based indices and the current tab marked');
    expect(!JSON.stringify(listed).includes('secret'), 'Never list incognito tabs');
    chrome([{id: 'odd', mode: 'normal', active: 1, tabs: [{title: 'Odd', url: 'https://odd.example/'}]}].concat(sample()));
    expect(JSON.parse(call('list')).length === 4 && call('active') === '[]',
           'A window whose id is not a number is left out instead of breaking the list');
    expect(chrome(sample(), false) && call('list') === '[]', 'A closed Chrome lists no tabs without launching');
    expect(!stable([1, 2], ['normal', 'normal'], [1, 1], [['a'], ['b']], [['a'], ['b', 'c']]), 'Notice a tab added between reads');
    expect(!stable([1, 2], ['normal'], [1, 1], [['a'], ['b']], [['a'], ['b']]), 'Notice a window closed between reads');

    chrome(sample());
    expect(call('active') === JSON.stringify([7, 2, 'New Tab', 'chrome://newtab/']), 'Read the tab on screen');
    const incognitoFront = sample();
    incognitoFront.unshift(incognitoFront.splice(1, 1)[0]);
    chrome(incognitoFront);
    expect(call('active') === '[]', 'An incognito window in front reveals no tab');

    let fake = chrome(sample());
    fake.state.windows[2].minimized = true;
    expect(call('switch', '9', '1', 'https://docs.example/', 'Docs') === 'ok', 'Switch to a listed tab');
    expect(fake.state.windows[0].id === '9' && fake.state.windows[0].active === 1 && !fake.state.windows[0].minimized
           && fake.state.activated, 'Switching selects the tab, restores and raises its window and activates Chrome');
    fake = chrome(sample());
    call('switch', '9', '2', 'https://docs.example/', '');
    expect(byId(fake, '9').active === 2, 'Of two tabs with one address, pick the listed one');
    fake = chrome(sample());
    call('switch', '7', '1', 'https://mail.example/', 'Mail (2)');
    expect(fake.state.windows[0].active === 1, 'A title changed in the background still finds the tab at its index');
    fake = chrome(sample());
    fake.state.windows[0].tabs.unshift({title: 'Inserted', url: 'https://other.example/'});
    call('switch', '7', '1', 'https://mail.example/', 'Mail (3)');
    expect(fake.state.windows[0].active === 2, 'A tab that moved is found by its address and title');
    chrome(sample());
    expectStale(() => call('switch', '7', '1', 'https://gone.example/', 'Gone'), 'A closed tab is stale');
    expectStale(() => call('switch', '8', '1', 'https://secret.example/', 'Secret'), 'An incognito window cannot be targeted');
    expectStale(() => call('switch', '99', '1', 'https://mail.example/', 'Mail (3)'), 'A closed window is stale');

    fake = chrome(sample());
    call('url', '9', 'https://example.org/');
    let docs = fake.state.windows[0];
    expect(docs.id === '9' && docs.tabs.length === 3 && docs.tabs[2].url === 'https://example.org/' && docs.active === 3,
           'An address opens in a new, selected tab of the requested window');
    fake = chrome(sample());
    call('url', '7', 'https://example.org/', '2', 'chrome://newtab/');
    expect(fake.state.windows[0].tabs.length === 2 && fake.state.windows[0].tabs[1].url === 'https://example.org/'
           && fake.state.windows[0].active === 2, 'An address replaces the empty tab on screen instead of opening beside it');
    fake = chrome(sample());
    call('url', '7', 'https://example.org/', '1', 'chrome://newtab/');
    expect(fake.state.windows[0].tabs.length === 3 && fake.state.windows[0].tabs[0].url === 'https://mail.example/',
           'A tab that is no longer empty is left alone and a new tab opens');
    fake = chrome(sample());
    call('url', '8', 'https://example.org/');
    expect(byId(fake, '8').tabs.length === 1 && fake.state.windows[0].id === '7'
           && fake.state.windows[0].tabs.length === 3, 'An incognito window is never used; the front normal window is');
    fake = chrome([{id: '8', mode: 'incognito', active: 1, tabs: [{title: 'Secret', url: 'https://secret.example/'}]}]);
    call('url', '0', 'https://example.org/');
    expect(fake.state.windows.length === 2 && fake.state.windows[0].mode === 'normal' && fake.state.windows[0].tabs.length === 1
           && fake.state.windows[0].tabs[0].url === 'https://example.org/', 'Without a normal window, one is made and its first tab used');
    fake = chrome(sample());
    call('new-tab', '9');
    docs = fake.state.windows[0];
    expect(docs.id === '9' && docs.tabs.length === 3 && docs.tabs[2].url === 'chrome://newtab/' && docs.active === 3 && fake.state.activated,
           'The New Tab action opens Chrome\'s own new-tab page');
    fake = chrome([]);
    call('new-tab', '0');
    expect(fake.state.windows.length === 1 && fake.state.windows[0].tabs.length === 1, 'With no windows, New Tab makes exactly one tab');

    fake = chrome(sample());
    fake.state.windows[0].tabs[0].text = 'x'.repeat(40000);
    expect(call('text', '7', '1', 'https://mail.example/').length === 30000, 'Page text is cut to 30,000 characters');
    expectStale(() => call('text', '7', '1', 'https://elsewhere.example/'), 'A page that navigated away is not read');
    expectStale(() => call('text', '7', '5', 'https://mail.example/'), 'A closed tab is not read');
    return `Passed ${checks} Chrome script checks`;
}

// Enough of Chrome's scripting objects for the bridge: windows front to back, each with its tabs. Window ids
// are text, as in Chrome's dictionary, and byId matches them exactly.
function fakeChrome(windows, running) {
    const state = {windows: windows, activated: false, made: 0};
    windows.forEach(w => { w.minimized = Boolean(w.minimized); });
    const tab = t => ({
        title: () => t.title,
        get url() { return () => t.url; },
        set url(value) { t.url = value; },
        execute: () => t.text || ''
    });
    const tabs = w => new Proxy({}, {
        get(_, key) {
            if (key === 'url') return () => w.tabs.map(t => t.url);
            if (key === 'title') return () => w.tabs.map(t => t.title);
            if (key === 'length') return w.tabs.length;
            if (key === 'push') return properties => { w.tabs.push({title: '', url: properties.url || 'chrome://newtab/'}); };
            if (typeof key === 'string' && /^\d+$/.test(key)) return tab(w.tabs[Number(key)]);
        }
    });
    const browserWindow = w => ({
        id: () => w.id,
        mode: () => w.mode,
        exists: () => state.windows.includes(w),
        tabs: tabs(w),
        get activeTabIndex() { return () => w.active; },
        set activeTabIndex(value) { w.active = value; },
        get activeTab() { return tab(w.tabs[w.active - 1]); },
        get minimized() { return () => w.minimized; },
        set minimized(value) { w.minimized = value; },
        set index(value) { state.windows.splice(state.windows.indexOf(w), 1); state.windows.splice(value - 1, 0, w); }
    });
    const all = new Proxy(() => {}, {
        apply: () => state.windows.map(browserWindow),
        get(_, key) {
            if (key === 'length') return state.windows.length;
            if (key === 'id') return () => state.windows.map(w => w.id);
            if (key === 'mode') return () => state.windows.map(w => w.mode);
            if (key === 'activeTabIndex') return () => state.windows.map(w => w.active);
            if (key === 'tabs') return {url: () => state.windows.map(w => w.tabs.map(t => t.url)),
                                        title: () => state.windows.map(w => w.tabs.map(t => t.title))};
            if (key === 'byId') return id => {
                const found = state.windows.find(w => w.id === id);
                return found ? browserWindow(found) : {exists: () => false};
            };
            if (typeof key === 'string' && /^\d+$/.test(key)) return browserWindow(state.windows[Number(key)]);
        }
    });
    const app = {
        running: () => running,
        windows: all,
        activate: () => { state.activated = true; },
        Tab: (properties = {}) => properties,
        Window: () => ({make: () => {
            state.windows.unshift({id: String(900 + state.made++), mode: 'normal', active: 1, minimized: false,
                                   tabs: [{title: 'New Tab', url: 'chrome://newtab/'}]});
        }})
    };
    return {app: app, state: state};
}
