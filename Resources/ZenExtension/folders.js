// The one part of Tab Scout's extension that runs inside Zen itself rather than beside it. Zen has folders where
// other browsers have tab groups, and gives extensions no way to make or remove one, so this asks Zen's own
// folder code, as its New Folder and Unpack Folder menu items do. Zen loads this file only while its
// extensions.experiments.enabled setting is on. Without it the rest of the extension works as before, and Tab
// Scout says what `group needs. It takes tab ids, a folder's name and a folder's id, and nothing else.
/* global ExtensionAPI, ExtensionUtils, getExtTabGroupIdForInternalTabGroupId */

this.tabScoutFolders = class extends ExtensionAPI {
    getAPI(context) {
        const {ExtensionError} = ExtensionUtils;
        const {tabManager, windowManager} = context.extension;

        // The id extensions know a folder by. The browser's own function is used where this file can reach it;
        // otherwise its rule is followed: a folder's id is the moment it was made and a number, as "<13 digits>-<n>".
        const groupId = folder => {
            if (typeof getExtTabGroupIdForInternalTabGroupId === 'function') return getExtTabGroupIdForInternalTabGroupId(folder.id);
            const parts = /^(\d{13})-(\d{1,3})$/.exec(folder.id);
            return parts ? Number(parts[1]) * 1000 + Number(parts[2]) : -1;
        };
        const isPlaceholder = tab => tab.hasAttribute('zen-empty-tab');
        // The browser window a tab is in, by the name newer and older versions of the browser give it.
        const windowOf = tab => tab.documentGlobal || tab.ownerGlobal;

        return {
            tabScoutFolders: {
                async create(tabIds, title) {
                    const tabs = [];
                    for (const id of tabIds) {
                        // A tab closed meanwhile, or one this extension may not use, is left out.
                        try { tabs.push(tabManager.get(id).nativeTab); } catch (error) { /* Gone. */ }
                    }
                    if (tabs.length === 0) return 0;
                    const window = windowOf(tabs[0]);
                    const folders = window.gZenFolders;
                    if (!folders || typeof folders.createFolder !== 'function') throw new ExtensionError('This browser has no folders');
                    // Pinned tabs, essentials and tabs already in a folder or a split view stay where they are.
                    const loose = tabs.filter(tab => windowOf(tab) === window && !tab.closing && !tab.pinned && !tab.group
                        && !tab.hasAttribute('zen-essential') && !isPlaceholder(tab));
                    if (loose.length === 0) return 0;
                    folders.createFolder(loose, {label: title});
                    return loose.length;
                },

                async unpack(wanted) {
                    for (const {window} of windowManager.getAll()) {
                        const groups = (window.gBrowser && window.gBrowser.tabGroups) || [];
                        const folder = groups.find(group => group.isZenFolder && groupId(group) === wanted);
                        if (!folder) continue;
                        const space = folder.getAttribute('zen-workspace-id');
                        const front = window.gZenWorkspaces && window.gZenWorkspaces.activeWorkspace;
                        if (folder.isLiveFolder || (space && front && space !== front)) return {found: true, tabIds: null};
                        // The tabs directly in the folder; those of a folder or split view inside it move with that.
                        const tabs = folder.allItems.filter(item => window.gBrowser.isTab(item) && !isPlaceholder(item));
                        const tabIds = tabs.map(tab => tabManager.getWrapper(tab).id);
                        await folder.unpackTabs();
                        return {found: true, tabIds};
                    }
                    return {found: false, tabIds: null};
                }
            }
        };
    }
};
