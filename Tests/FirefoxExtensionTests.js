// Checks the Firefox extension's tab handling without Firefox:
// osascript -l JavaScript FirefoxExtensionTests.js <path to the FirefoxExtension folder>
// What it does in a real Firefox is checked by Tests/FirefoxLive/run.py, which is not part of test.sh.
ObjC.import('Foundation');

function run(argv) {
    const read = name => $.NSString.stringWithContentsOfFileEncodingError(argv[0] + '/' + name, $.NSUTF8StringEncoding, null).js;
    // Defines the extension's functions. With no browser object here it neither connects nor listens to anything.
    eval(read('background.js'));

    let checks = 0;
    function expect(condition, message) {
        if (!condition) throw new Error('FAILED: ' + message);
        checks += 1;
    }
    const same = (value, expected) => JSON.stringify(value) === JSON.stringify(expected);

    const tab = (id, index, title, url, active) => ({id, index, title, url, active: Boolean(active)});
    const back = {id: 4, type: 'normal', incognito: false, tabs: [tab(41, 0, 'Mail', 'https://mail.example/', true)]};
    const frontWindow = {id: 9, type: 'normal', incognito: false,
                         tabs: [tab(91, 0, 'Docs', 'https://docs.example/a'), tab(92, 2, undefined, undefined, true)]};
    const secret = {id: 5, type: 'normal', incognito: true, tabs: [tab(51, 0, 'Secret', 'https://secret.example/', true)]};
    const popup = {id: 6, type: 'popup', incognito: false, tabs: [tab(61, 0, 'Popup', 'https://popup.example/', true)]};

    const windows = ordered([back, secret, popup, frontWindow], 9);
    expect(same(windows.map(window => window.id), [9, 4]), 'The window last in front comes first; private windows and popups are left out');
    expect(same(ordered([back, frontWindow], null).map(window => window.id), [4, 9]) && same(ordered([back, frontWindow], 5).map(window => window.id), [4, 9]),
           'Without a known front window, or with a private one in front, the windows keep their order');
    expect(same(rows(windows), [[9, 1, 'Docs', 'https://docs.example/a', false], [9, 3, '', '', true], [4, 1, 'Mail', 'https://mail.example/', true]]),
           'Rows carry the window, a one-based position, title, address and whether the tab is current; missing values are empty text');
    expect(same(front(windows), [9, 3, '', '']), 'The tab on screen is the current tab of the window in front');
    expect(same(front([]), []) && same(front([{id: 2, tabs: [tab(1, 0, 'A', 'a', false)]}]), []),
           'Without a window, or while the tab on screen is one the browser keeps to itself, no tab is on screen');
    expect(same(rows([{id: 3, tabs: [tab(7, 1, 'Second', 'https://b.example/')]}]), [[3, 2, 'Second', 'https://b.example/', false]]),
           'A position the browser skips, as Zen does for its own empty tab, stays skipped');

    const open = [tab(1, 0, 'Inbox (3)', 'https://mail.example/'), tab(2, 1, 'Plan', 'https://docs.example/plan'),
                  tab(3, 2, 'Plan', 'https://docs.example/plan'), tab(4, 4, 'News', 'https://news.example/')];
    expect(pick(open, 2, 'https://docs.example/plan', 'Plan').id === 2 && pick(open, 3, 'https://docs.example/plan', 'Plan').id === 3,
           'A row still in place picks its own tab, also among tabs alike');
    expect(pick(open, 1, 'https://news.example/', 'News').id === 4, 'A tab that moved is found by its address and title');
    expect(pick(open, 1, 'https://mail.example/', 'Inbox (2)').id === 1, 'A title that changed in the background still picks the tab at its position');
    expect(pick(open, 2, 'https://mail.example/', 'Inbox (2)') === null && pick(open, 9, 'https://gone.example/', 'Gone') === null,
           'A tab that is gone, or moved and renamed, is not guessed at');
    expect(pick(open, 5, 'https://news.example/', 'News').id === 4, 'Positions are the browser\'s own, gaps included');

    expect(unchanged(open, 2, 'https://docs.example/plan').id === 2 && unchanged(open, 2, 'https://other.example/') === null
           && unchanged(open, 4, 'https://news.example/') === null && unchanged([{id: 5, index: 0}], 1, '').id === 5,
           'A tab is closed or reused only while its position still shows its address; a missing address counts as empty');

    const me = 'tabscout@local.tabscout';
    const sound = (id, audible, mutedInfo) => ({id, audible, mutedInfo});
    const mine = {muted: true, reason: 'extension', extensionId: me};
    expect(same(muting([sound(1, true, {muted: false}), sound(2, false, {muted: false}), sound(3, true, mine), sound(4, true)], me), {muted: true, tabIds: [1, 4]}),
           'Tabs playing sound are muted; silent and already muted ones are left');
    expect(same(muting([sound(2, false, {muted: false}), sound(3, true, mine), sound(6, true, {muted: true, reason: 'user'})], me), {muted: false, tabIds: [3]}),
           'With nothing playing, only the tabs this extension muted get their sound back');

    const manifest = JSON.parse(read('manifest.json'));
    const source = read('background.js');
    expect(manifest.manifest_version === 2 && same(manifest.background, {scripts: ['background.js']}),
           'The background page stays loaded, so the connection to Tab Scout stays open');
    expect(same(manifest.permissions.slice().sort(), ['nativeMessaging', 'search', 'tabs']), 'The extension asks only for what it uses, and for no site');
    expect(same(manifest.browser_specific_settings.gecko.data_collection_permissions, {required: ['browsingActivity']}),
           'The extension says that it passes tab titles and addresses on, which Firefox shows before adding it');
    expect(source.includes("const HOST = 'local.tabscout.firefox';"), 'The extension connects to the helper Tab Scout installs');
    expect(['bridge', 'mute', 'version'].every(type => source.includes("message.type === '" + type + "'"))
           && ['list', 'active', 'switch', 'url', 'search', 'new-tab', 'close', 'reopen'].every(command => source.includes("operation === '" + command + "'")),
           'The extension answers the commands Tab Scout\'s browser scripts take');
    expect(source.includes("error: 'unknown request'") && source.includes("throw new Error('unknown request')"),
           'A request it does not know is answered as such, which Tab Scout reads as an outdated extension');
    return 'Passed ' + checks + ' Firefox extension checks';
}
