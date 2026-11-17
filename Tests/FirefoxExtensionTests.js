// Checks the Firefox extension's tab handling without Firefox:
// osascript -l JavaScript FirefoxExtensionTests.js <path to the FirefoxExtension folder> <path to the ZenExtension folder>
// What it does in a real Firefox or Zen, folders included, is checked by Tests/FirefoxLive/run.py, which is not
// part of test.sh.
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

    const page = (id, windowId, pinned, groupId) => ({id, windowId, pinned, groupId, title: 'Page ' + id, url: 'https://p.example/' + id});
    expect(same(listed([page(1, 5, false, -1), page(2, 5, true, -1), page(3, 5, true, 1794900990166082), {id: 4}]),
                [{id: 1, title: 'Page 1', url: 'https://p.example/1', pinned: false, grouped: false},
                 {id: 2, title: 'Page 2', url: 'https://p.example/2', pinned: true, grouped: false},
                 {id: 3, title: 'Page 3', url: 'https://p.example/3', pinned: true, grouped: true},
                 {id: 4, title: '', url: '', pinned: false, grouped: false}]),
           'Tabs are listed for sorting as the Chrome extension lists them; a tab in a folder counts as grouped');
    expect(same(movable([page(1, 5, false, -1), null, page(2, 6, false, -1), page(3, 5, true, -1), page(4, 5, true, 1794900990166082),
                         page(5, 5, false, undefined)], 5), [1, 5]),
           'Only tabs still loose in the window go into a folder: not one closed, pinned, in a folder or in another window');

    const manifest = JSON.parse(read('manifest.json'));
    const source = read('background.js');
    const zenFile = name => $.NSString.stringWithContentsOfFileEncodingError(argv[1] + '/' + name, $.NSUTF8StringEncoding, null).js;
    const zen = JSON.parse(zenFile('manifest.json'));
    expect(zen.version === manifest.version && same(zen.browser_specific_settings, manifest.browser_specific_settings)
           && same(zen.background, manifest.background) && zen.manifest_version === manifest.manifest_version,
           'Zen\'s package is the same extension: one ID, one version, one background script');
    expect(same(zen.permissions.slice().sort(), ['nativeMessaging', 'search', 'storage', 'tabs']),
           'In Zen it also remembers which folders it made, and asks for nothing else');
    const piece = zen.experiment_apis.tabScoutFolders;
    expect(manifest.experiment_apis === undefined && same(Object.keys(zen.experiment_apis), ['tabScoutFolders'])
           && piece.schema === 'folders.json' && piece.parent.script === 'folders.js' && same(piece.parent.paths, [['tabScoutFolders']]),
           'Only Zen\'s package carries the piece that runs inside the browser; Firefox would turn the whole extension away for it');
    const schema = JSON.parse(zenFile('folders.json'));
    expect(schema.length === 1 && schema[0].namespace === 'tabScoutFolders'
           && same(schema[0].functions.map(entry => [entry.name, entry.async, entry.parameters.map(parameter => parameter.type)]),
                   [['create', true, ['array', 'string']], ['unpack', true, ['integer']]]),
           'That piece offers two things: making a folder from tab ids and a name, and unpacking a folder by its id');
    const inside = zenFile('folders.js');
    expect(inside.includes('this.tabScoutFolders = class extends ExtensionAPI') && inside.includes('folders.createFolder(loose, {label: title})')
           && inside.includes('await folder.unpackTabs()'),
           'It asks Zen\'s own folder code, as Zen\'s New Folder and Unpack Folder do');
    expect(!/\beval\b|new Function|Services\.|ChromeUtils|\.prefs\b|fetch\(|XMLHttpRequest|nsIFile|IOUtils/.test(inside),
           'Running inside the browser, it touches nothing but tabs and folders');
    expect(source.includes("browser.tabScoutFolders.create(") && source.includes("browser.tabScoutFolders.unpack(")
           && source.includes("return Boolean(browser.tabScoutFolders)") && source.split("error: 'no-folders'").length === 4,
           'Without that piece, as in Firefox or in Zen before its setting is on, sorting into folders is answered as unavailable');
    expect(manifest.manifest_version === 2 && same(manifest.background, {scripts: ['background.js']}),
           'The background page stays loaded, so the connection to Tab Scout stays open');
    expect(same(manifest.permissions.slice().sort(), ['nativeMessaging', 'search', 'tabs']), 'The extension asks only for what it uses, and for no site');
    expect(same(manifest.browser_specific_settings.gecko.data_collection_permissions, {required: ['browsingActivity']}),
           'The extension says that it passes tab titles and addresses on, which Firefox shows before adding it');
    expect(source.includes("const HOST = 'local.tabscout.firefox';"), 'The extension connects to the helper Tab Scout installs');
    expect(['bridge', 'mute', 'version', 'tabs', 'group', 'ungroup'].every(type => source.includes("message.type === '" + type + "'"))
           && ['list', 'active', 'switch', 'url', 'search', 'new-tab', 'close', 'reopen'].every(command => source.includes("operation === '" + command + "'")),
           'The extension answers the commands Tab Scout\'s browser scripts take');
    expect(source.includes("error: 'unknown request'") && source.includes("throw new Error('unknown request')"),
           'A request it does not know is answered as such, which Tab Scout reads as an outdated extension');
    return 'Passed ' + checks + ' Firefox extension checks';
}
