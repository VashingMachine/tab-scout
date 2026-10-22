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

    const manifest = JSON.parse(read('manifest.json'));
    expect(manifest.manifest_version === 3 && manifest.background.service_worker === 'background.js',
           'The manifest runs background.js as its service worker');
    expect(read('background.js').includes("const HOST = 'local.tabscout.chrome';"), 'The extension connects to the helper Tab Scout installs');
    return 'Passed ' + checks + ' Chrome extension checks';
}
