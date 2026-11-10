// Checks the Chrome extension's tab handling without Chrome:
// osascript -l JavaScript ChromeExtensionTests.js <path to the ChromeExtension folder>
ObjC.import('Foundation');

function run(argv) {
    const read = name => $.NSString.stringWithContentsOfFileEncodingError(argv[0] + '/' + name, $.NSUTF8StringEncoding, null).js;
    // Defines the extension's functions. With no chrome object here it neither connects nor schedules anything.
    eval(read('background.js'));

    let checks = 0;
    function expect(condition, message) {
        if (!condition) throw new Error('FAILED: ' + message);
        checks += 1;
    }

    const tabs = listed([
        {id: 1, title: 'Mail', url: 'https://mail.example/', pinned: true, groupId: -1, windowId: 5},
        {id: 2, url: '', pendingUrl: 'https://loading.example/', pinned: false, groupId: 9, windowId: 5}
    ]);
    expect(JSON.stringify(tabs) === JSON.stringify([
        {id: 1, title: 'Mail', url: 'https://mail.example/', pinned: true, grouped: false},
        {id: 2, title: '', url: 'https://loading.example/', pinned: false, grouped: true}
    ]), 'Tabs are listed with their title, address, pinning and whether they are grouped');

    const loose = (id, windowId) => ({id, windowId, pinned: false, groupId: -1});
    expect(JSON.stringify(movable([loose(1, 5), null, loose(2, 6), {id: 3, windowId: 5, pinned: true, groupId: -1},
                                   {id: 4, windowId: 5, pinned: false, groupId: 2}, loose(5, 5)], 5)) === '[1,5]',
           'Closed, moved, pinned and already grouped tabs are left alone');

    expect(JSON.stringify(grouped([loose(1, 5), {id: 4, windowId: 5, pinned: false, groupId: 2}, {id: 6, windowId: 5, pinned: true, groupId: 3}])) === '[4,6]',
           'Ungrouping takes every tab that is in a group, and no other');

    const me = 'tabscout';
    const sound = (id, audible, mutedInfo) => ({id, audible, mutedInfo});
    const mine = {muted: true, reason: 'extension', extensionId: me};
    expect(JSON.stringify(muting([sound(1, true, {muted: false}), sound(2, false, {muted: false}), sound(3, true, mine), sound(4, true)], me))
           === JSON.stringify({muted: true, tabIds: [1, 4]}), 'Tabs playing sound are muted; silent and already muted ones are left');
    expect(JSON.stringify(muting([sound(2, false, {muted: false}), sound(3, true, mine), sound(5, false, mine),
                                  sound(6, true, {muted: true, reason: 'user'}), sound(7, true, {muted: true, reason: 'extension', extensionId: 'other'})], me))
           === JSON.stringify({muted: false, tabIds: [3, 5]}),
           'With nothing playing, only the tabs this extension muted get their sound back, not ones muted by hand or by another extension');
    expect(JSON.stringify(muting([sound(2, false, {muted: false})], me)) === JSON.stringify({muted: false, tabIds: []}),
           'With nothing playing or muted there is nothing to do');

    const manifest = JSON.parse(read('manifest.json'));
    expect(manifest.manifest_version === 3 && manifest.background.service_worker === 'background.js',
           'The manifest runs background.js as its service worker');
    expect(read('background.js').includes("const HOST = 'local.tabscout.chrome';"), 'The extension connects to the helper Tab Scout installs');
    expect(manifest.version === '1.1' && ['ungroup', 'mute'].every(type => read('background.js').includes("message.type === '" + type + "'")),
           'The version tells this extension, which also ungroups and mutes, from the first');
    expect(read('background.js').includes("error: 'unknown request'"), 'A request it does not know is answered as such, which Tab Scout reads as an outdated extension');
    return 'Passed ' + checks + ' Chrome extension checks';
}
