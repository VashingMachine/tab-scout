import test from 'node:test';
import assert from 'node:assert/strict';
import { createBackground, validMessage } from '../../SafariExtension/background.mjs';

const root = 'moz-extension://tab-scout/';
const now = 2000000000000;
const event = () => ({ listeners: [], addListener(fn) { this.listeners.push(fn); }, emit(...args) { this.listeners.forEach(fn => fn(...args)); } });
function fixture({ incognito = false, stored = {}, tabs: initialTabs } = {}) {
  const tabs = new Map((initialTabs ?? [
    { id: 1, windowId: 1, title: 'Tab Scout', url: `${root}newtab.html`, active: true, incognito },
    { id: 2, windowId: 2, title: 'Swift docs', url: 'https://swift.org/', active: true, incognito },
    { id: 3, windowId: 1, title: 'Ordinary page', url: 'https://example.com/', incognito },
  ]).map(tab => [tab.id, { ...tab }]));
  const calls = []; const state = structuredClone(stored); let id = 100;
  const browser = {
    runtime: { id: 'tab-scout', getURL: path => root + path, onMessage: event() },
    commands: { onCommand: event() },
    action: { onClicked: event(), setPopup: async details => { calls.push(['setPopup', details]); },
      openPopup: async details => { calls.push(['openPopup', details]); } },
    scripting: { executeScript: async details => { calls.push(['inject', details]); return [{ frameId: 0, documentId: 'document-1' }]; } },
    tabs: {
      query: async query => {
        calls.push(['query', query]);
        return [...tabs.values()].filter(tab => !query.active || (tab.active && tab.windowId === 1)).map(tab => ({ ...tab }));
      },
      get: async id => { calls.push(['get', id]); if (!tabs.has(id)) throw new Error('Private URL in native error'); return { ...tabs.get(id) }; },
      update: async (id, patch) => { calls.push(['update', id, patch]); const tab = tabs.get(id); if (!tab) throw new Error('gone'); Object.assign(tab, patch); return { ...tab }; },
      create: async data => { calls.push(['create', data]); const tab = { id: id++, ...data }; tabs.set(tab.id, tab); return { ...tab }; },
      remove: async id => { calls.push(['remove', id]); tabs.delete(id); },
      sendMessage: async (id, message, options) => { calls.push(['send', id, message, options]); return { ok: true }; },
      onCreated: event(), onRemoved: event(), onUpdated: event(), onMoved: event(), onAttached: event(), onDetached: event(), onReplaced: event(),
      onActivated: event(),
    },
    windows: { update: async (id, patch) => { calls.push(['window', id, patch]); } },
    storage: {
      local: { get: async () => { calls.push(['storage.get']); return structuredClone(state); },
        set: async patch => { calls.push(['storage.set', patch]); Object.assign(state, structuredClone(patch)); } },
      onChanged: event(),
    },
  };
  const suggestions = { calls: [], async get(query, options) { this.calls.push({ query, options }); return options.incognito || !options.enabled ? [] : ['weather today']; }, clear() { this.cleared = true; } };
  const favicons = { calls: [], async get(url, options) { this.calls.push({ url, options }); return options.incognito ? null : 'data:image/png;base64,AA=='; } };
  const background = createBackground({ browser, now: () => now, suggestions, favicons });
  const sender = (surface = 'newtab') => ({ id: 'tab-scout', url: `${root}${surface}.html`,
    ...(surface === 'newtab' ? { tab: { id: 1, windowId: 1, incognito } } : {}) });
  return { background, browser, tabs, calls, state, sender, suggestions, favicons };
}
const mutations = calls => calls.filter(call => ['update', 'create', 'remove', 'window', 'storage.set'].includes(call[0]));
async function openOverlay(f) {
  f.tabs.get(1).url = 'https://example.com/current-page';
  assert.equal((await f.background.overlayController.toggle()).ok, true);
  const overlayToken = f.calls.findLast(call => call[0] === 'send' && call[2].type === 'overlayOpen')[2].token;
  const sender = { id: 'tab-scout', url: f.tabs.get(1).url, frameId: 0, documentId: 'document-1', tab: { ...f.tabs.get(1) } };
  return { overlayToken, sender, send: message => f.background.handle({ ...message, overlayToken }, sender) };
}

test('runtime protocol validates type, structure, sizes, engines and safe targets', () => {
  for (const message of [null, [], {}, { type: 'unknown' }, { type: 'state', extra: true }, { type: 'query', query: 'x'.repeat(2049) },
    { type: 'query', query: '\0' }, { type: 'query', query: '', force: 'yes' }, { type: 'settings', settings: { engine: '__proto__' } },
    { type: 'settings', settings: { googleSuggestions: 'true' } }, { type: 'settings', settings: { unknown: true } },
    { type: 'activate', target: { kind: 'url', url: 'javascript:alert(1)' } }, { type: 'activate', target: { kind: 'tab', tabId: -1 } },
    { type: 'activate', target: { kind: 'newtab', url: 'https://evil.example/' } }, { type: 'activate', target: { kind: 'newtab', tabId: 1 } },
    { type: 'popupClosed', tabId: 1 }, { type: 'popupClosed', tabId: -1, popupToken: 'a'.repeat(64) },
    { type: 'popupClosed', tabId: 1, popupToken: 'invalid' }, { type: 'popupClosed', tabId: 1, popupToken: 'a'.repeat(64), extra: true },
    { type: 'activate', target: { kind: 'tab', tabId: 2, url: 'https://other.com' } }, { type: 'activate', target: { kind: 'query', query: '' }, forceNew: 'true' }]) assert.equal(validMessage(message), false);
  for (const message of [{ type: 'state' }, { type: 'query', query: '', force: true }, { type: 'suggest', query: 'weather' },
    { type: 'settings', settings: { engine: 'bing' } }, { type: 'activate', target: { kind: 'query', query: '' } },
    { type: 'activate', target: { kind: 'newtab' } }, { type: 'clearChoices' }]) assert.equal(validMessage(message), true);
});

test('fallback uses the static toolbar popup and exposes no lifecycle credentials', async () => {
  const f = fixture(); f.tabs.get(1).url = 'favorites://';
  assert.deepEqual(await f.background.overlayController.toggle(), { ok: true, fallback: true });
  const state = await f.background.handle({ type: 'state' }, f.sender('popup'));
  assert.equal(state.ok, true);
  assert.deepEqual(state.context, { surface: 'popup', incognito: false, tabId: 1, windowId: 1 });
  const options = await f.background.handle({ type: 'state' }, f.sender('options'));
  assert.equal(Object.hasOwn(options.context, 'popupToken'), false);
  assert.equal(f.calls.some(call => call[0] === 'create' || call[0] === 'remove'), false);
  assert.deepEqual(f.calls.filter(call => ['setPopup', 'openPopup'].includes(call[0])), [['openPopup', { windowId: 1 }]]);
});

test('removed dynamic popup lifecycle requests cannot change Safari configuration', async () => {
  const f = fixture(); f.tabs.get(1).url = 'favorites://'; await f.background.overlayController.toggle();
  const message = { type: 'popupClosed', tabId: 1, popupToken: 'a'.repeat(64) };
  const before = f.calls.length;
  for (const sender of [f.sender('popup'), f.sender('options'), f.sender('newtab'),
    { id: 'tab-scout', url: 'https://example.com/popup.html' }]) {
    assert.equal((await f.background.handle(message, sender)).ok, false);
  }
  assert.equal(f.calls.length, before);
});

test('only exact trusted extension pages and extension ID can invoke background', async () => {
  const f = fixture();
  for (const sender of [{ url: 'https://example.com/newtab.html' }, { url: `${root}newtab.html?evil=1` },
    { url: `${root}other.html` }, { url: `${root}newtab.html`, id: 'other-extension' }, {}]) {
    assert.equal((await f.background.handle({ type: 'state' }, sender)).ok, false);
  }
  assert.equal(f.calls.length, 0);
  assert.equal((await f.background.handle({ type: 'state' }, f.sender())).ok, true);
});

test('local state defaults and strict surface/current-tab context are returned', async () => {
  const f = fixture(); const result = await f.background.handle({ type: 'state' }, f.sender());
  assert.deepEqual(result.settings, { engine: 'google', googleSuggestions: false, rememberChoices: true });
  assert.deepEqual(result.context, { surface: 'newtab', incognito: false, tabId: 1, windowId: 1 });
  assert.equal((await f.background.handle({ type: 'state' }, f.sender('options'))).context.surface, 'options');
});

test('queries show local rows without extension pages, isolate private tabs, and warm cache', async () => {
  const f = fixture({ stored: { choices: [{ kind: 'query', value: 'swift programming', title: '', count: 2, lastUsed: now }] } });
  f.tabs.set(4, { id: 4, windowId: 3, title: 'Swift private', url: 'https://private.example.com', incognito: true });
  const first = await f.background.handle({ type: 'query', query: 'swift' }, f.sender());
  assert.equal(first.rows[0].target.tabId, 2); assert.equal(first.rows[1].kind, 'recent'); assert.equal(first.rows.at(-1).kind, 'action');
  assert.deepEqual(first.inventory, { tabCount: 2, windowCount: 2 });
  const second = await f.background.handle({ type: 'query', query: '' }, f.sender());
  assert.deepEqual(second.rows[0].target, { kind: 'newtab' }); assert.deepEqual(second.rows.filter(row => row.kind === 'tab').map(row => row.target.tabId), [2, 3]);
  assert.deepEqual(second.inventory, first.inventory);
  assert.equal(f.calls.filter(call => call[0] === 'query' && !call[1].active).length, 1);
});

test('inventory counts and tab window ordinals isolate private tabs and exclude extension pages', async () => {
  for (const incognito of [false, true]) {
    const f = fixture({ incognito });
    f.tabs.set(4, { id: 4, windowId: 40, title: 'Other privacy', url: 'https://private.example.com/', incognito: !incognito });
    f.tabs.set(5, { id: 5, windowId: 50, title: 'Options', url: `${root}options.html`, incognito });
    f.tabs.set(6, { id: 6, windowId: 60, title: 'Internal', url: `${root}assets/private.html`, incognito });
    f.tabs.set(7, { id: 7, windowId: 2, title: 'Other docs', url: 'https://other.example.com/', incognito });
    f.tabs.set(8, { id: 8, windowId: 70, title: 'Another window', url: 'https://another.example.com/', incognito });
    f.tabs.set(-1, { id: -1, windowId: 80, title: 'Invalid ID', url: 'https://invalid.example.com/', incognito });
    const result = await f.background.handle({ type: 'query', query: 'ordinary' }, f.sender());
    assert.equal(result.ok, true);
    assert.deepEqual(result.inventory, { tabCount: 4, windowCount: 3 });
    assert.deepEqual(result.rows.filter(row => row.kind === 'tab').map(row => [row.target.tabId, row.windowNumber]), [[3, 2]]);
    const empty = await f.background.handle({ type: 'query', query: '' }, f.sender());
    assert.deepEqual(empty.inventory, result.inventory);
    assert.deepEqual(empty.rows.filter(row => row.kind === 'tab').map(row => [row.target.tabId, row.windowNumber]), [[2, 1], [3, 2], [7, 1], [8, 3]]);
  }
});

test('inventory excludes invalid window IDs without changing tab activation identity', async () => {
  const f = fixture();
  for (const [index, windowId] of [undefined, null, -1, 0.5, Infinity, '7', Number.MAX_SAFE_INTEGER + 1].entries()) {
    f.tabs.set(10 + index, { id: 10 + index, windowId, title: `Unknown ${index}`, url: `https://unknown.example.com/${index}`, incognito: false });
  }
  const result = await f.background.handle({ type: 'query', query: '' }, f.sender());
  assert.deepEqual(result.inventory, { tabCount: 9, windowCount: 2 });
  assert.equal(result.rows.filter(row => row.kind === 'tab' && Object.hasOwn(row, 'windowNumber')).length, 2);
  const row = result.rows.find(row => row.target.tabId === 2);
  assert.equal(row.windowNumber, 1);
  assert.deepEqual(row.target, { kind: 'tab', tabId: 2 });
  assert.equal((await f.background.handle({ type: 'activate', target: row.target }, f.sender())).ok, true);
  assert.deepEqual(mutations(f.calls).slice(0, 3), [['update', 2, { active: true }], ['window', 2, { focused: true }], ['remove', 1]]);
});

test('choosing existing tab activates then focuses then closes only source extension newtab', async () => {
  const f = fixture(); const result = await f.background.handle({ type: 'activate', target: { kind: 'tab', tabId: 2 } }, f.sender());
  assert.equal(result.ok, true); assert.equal(result.closePopup, false);
  assert.deepEqual(mutations(f.calls).slice(0, 3), [['update', 2, { active: true }], ['window', 2, { focused: true }], ['remove', 1]]);
  assert.equal(f.tabs.has(1), false); assert.equal(f.state.choices[0].value, 'https://swift.org/');
});

test('popup switching never closes the user tab even if active tab is extension newtab', async () => {
  for (const sourceURL of [`${root}newtab.html`, 'https://example.com/user']) {
    const f = fixture(); f.tabs.get(1).url = sourceURL;
    const result = await f.background.handle({ type: 'activate', target: { kind: 'tab', tabId: 2 } }, f.sender('popup'));
    assert.equal(result.closePopup, true); assert.equal(f.tabs.has(1), true); assert.equal(f.calls.some(call => call[0] === 'remove'), false);
  }
});

test('late source navigation, movement, and incognito change prevent cleanup', async () => {
  for (const patch of [{ url: 'https://example.com/user' }, { windowId: 9 }, { incognito: true }]) {
    const f = fixture(); f.browser.windows.update = async () => { Object.assign(f.tabs.get(1), patch); };
    assert.equal((await f.background.handle({ type: 'activate', target: { kind: 'tab', tabId: 2 } }, f.sender())).ok, true);
    assert.equal(f.calls.some(call => call[0] === 'remove'), false); assert.equal(f.tabs.has(1), true);
  }
});

test('stale searchpage sender cannot update an already navigated or moved user tab', async () => {
  for (const patch of [{ url: 'https://example.com/user' }, { windowId: 9 }]) {
    const f = fixture(); Object.assign(f.tabs.get(1), patch);
    const result = await f.background.handle({ type: 'activate', target: { kind: 'query', query: 'weather' } }, f.sender());
    assert.equal(result.ok, false); assert.deepEqual(mutations(f.calls), []);
  }
});

test('switch failure never removes source or remembers failed action and errors stay generic', async () => {
  const f = fixture(); f.browser.windows.update = async () => { throw new Error('private-user-history-and-token'); };
  const result = await f.background.handle({ type: 'activate', target: { kind: 'tab', tabId: 2 } }, f.sender());
  assert.equal(result.ok, false); assert.ok(!JSON.stringify(result).includes('private-user'));
  assert.equal(f.tabs.has(1), true); assert.equal(f.state.choices, undefined);
});

test('nonempty query updates current searchpage and explicit engine provider is respected', async () => {
  const f = fixture({ stored: { settings: { engine: 'bing' } } });
  assert.equal((await f.background.handle({ type: 'activate', target: { kind: 'query', query: 'swift programming' } }, f.sender())).ok, true);
  const updated = f.tabs.get(1); assert.equal(new URL(updated.url).hostname, 'www.bing.com');
  assert.equal(new URL(updated.url).searchParams.get('q'), 'swift programming');
  assert.equal(f.calls.some(call => call[0] === 'create' || call[0] === 'remove'), false);
  assert.equal(f.state.choices[0].kind, 'query');
});

test('direct and bare addresses update searchpage and are remembered as URL choices', async () => {
  for (const target of [{ kind: 'url', url: 'https://example.com/docs' }, { kind: 'query', query: 'example.com/docs' }]) {
    const f = fixture(); assert.equal((await f.background.handle({ type: 'activate', target }, f.sender())).ok, true);
    assert.equal(f.tabs.get(1).url, 'https://example.com/docs'); assert.equal(f.state.choices[0].kind, 'url');
  }
});

test('popup opens one new tab without changing current user page; CmdEnter creates exactly one extra', async () => {
  for (const [surface, forceNew] of [['popup', false], ['newtab', true]]) {
    const f = fixture(); const original = f.tabs.get(1).url;
    assert.equal((await f.background.handle({ type: 'activate', target: { kind: 'query', query: 'weather' }, forceNew }, f.sender(surface))).ok, true);
    assert.equal(f.calls.filter(call => call[0] === 'create').length, 1); assert.equal(f.tabs.get(1).url, original);
    assert.equal(f.calls.some(call => call[0] === 'remove'), false);
    assert.equal(f.calls.find(call => call[0] === 'create')[1].windowId, 1);
  }
});

test('blank activation is a no-op in either surface and does not persist or open aboutblank', async () => {
  for (const surface of ['newtab', 'popup']) {
    const f = fixture(); const result = await f.background.handle({ type: 'activate', target: { kind: 'query', query: ' \n ' }, forceNew: true }, f.sender(surface));
    assert.equal(result.ok, true); assert.equal(result.closePopup, false); assert.deepEqual(mutations(f.calls), []);
  }
});

test('incognito excludes remembered rows, persistence and network services, retaining private window context', async () => {
  const f = fixture({ incognito: true, stored: { settings: { googleSuggestions: true }, choices: [{ kind: 'query', value: 'secret choice', count: 1, lastUsed: now }] } });
  const rows = (await f.background.handle({ type: 'query', query: '' }, f.sender())).rows;
  assert.equal(rows.some(row => row.kind === 'recent' || row.kind === 'history'), false);
  assert.deepEqual((await f.background.handle({ type: 'suggest', query: 'weather' }, f.sender())).suggestions, []);
  assert.equal(f.suggestions.calls[0].options.incognito, true);
  assert.equal((await f.background.handle({ type: 'favicon', url: 'https://example.com' }, f.sender())).image, null);
  assert.equal((await f.background.handle({ type: 'clearChoices' }, f.sender())).ok, false);
  assert.equal((await f.background.handle({ type: 'settings', settings: { engine: 'bing' } }, f.sender())).ok, false);
  assert.equal((await f.background.handle({ type: 'activate', target: { kind: 'query', query: 'private weather' }, forceNew: true }, f.sender())).ok, true);
  assert.equal(f.calls.some(call => call[0] === 'storage.set'), false);
  assert.equal(f.calls.find(call => call[0] === 'create')[1].windowId, 1);
});

test('private and regular tabs cannot be switched across contexts', async () => {
  const f = fixture(); f.tabs.get(2).incognito = true;
  assert.equal((await f.background.handle({ type: 'activate', target: { kind: 'tab', tabId: 2 } }, f.sender())).ok, false);
  assert.deepEqual(mutations(f.calls), []);
});

test('remember preference hides local choices and disables accepted choice writes', async () => {
  const f = fixture({ stored: { settings: { rememberChoices: false }, choices: [{ kind: 'query', value: 'weather old', count: 2, lastUsed: now }] } });
  const rows = (await f.background.handle({ type: 'query', query: 'weather' }, f.sender())).rows;
  assert.equal(rows.some(row => row.kind === 'recent'), false);
  await f.background.handle({ type: 'activate', target: { kind: 'query', query: 'weather new' } }, f.sender());
  assert.equal(f.calls.some(call => call[0] === 'storage.set'), false);
});

test('clear removes only extension choices and settings updates are strict and persistent', async () => {
  const f = fixture({ stored: { choices: [{ kind: 'query', value: 'weather', count: 1, lastUsed: now }] } });
  assert.equal((await f.background.handle({ type: 'clearChoices' }, f.sender('options'))).ok, true); assert.deepEqual(f.state.choices, []);
  const result = await f.background.handle({ type: 'settings', settings: { engine: 'duckduckgo', googleSuggestions: true } }, f.sender('options'));
  assert.equal(result.settings.engine, 'duckduckgo'); assert.equal(result.settings.googleSuggestions, true);
  await f.background.handle({ type: 'settings', settings: { googleSuggestions: false } }, f.sender('options')); assert.equal(f.suggestions.cleared, true);
  assert.equal(f.calls.some(call => call[0] === 'remove'), false);
});

test('settings storage error is reported safely while failed choice persistence cannot undo navigation', async () => {
  const f = fixture(); f.browser.storage.local.set = async () => { throw new Error('filesystem-secret'); };
  const settings = await f.background.handle({ type: 'settings', settings: { engine: 'bing' } }, f.sender('options'));
  assert.equal(settings.ok, false); assert.ok(!settings.error.includes('filesystem-secret'));
  assert.equal((await f.background.handle({ type: 'activate', target: { kind: 'query', query: 'weather' } }, f.sender())).ok, true);
});

test('event listeners invalidate inventory and respond to external option/choice changes', async () => {
  const f = fixture(); f.background.install(); assert.equal(f.browser.runtime.onMessage.listeners.length, 1);
  await f.background.handle({ type: 'query', query: 'swift' }, f.sender());
  f.browser.tabs.onUpdated.emit(); const stale = await f.background.handle({ type: 'query', query: 'swift' }, f.sender());
  assert.equal(stale.refreshing, true);
  f.browser.storage.onChanged.emit({ settings: { newValue: { engine: 'bing' } }, choices: { newValue: [] } }, 'local');
  assert.equal((await f.background.handle({ type: 'state' }, f.sender())).settings.engine, 'bing');
});

test('realistic private options sender.tab is verified and cannot mutate normal settings or choices', async () => {
  const f = fixture(); f.tabs.set(4, { id: 4, windowId: 1, url: `${root}options.html`, incognito: true });
  const sender = { id: 'tab-scout', url: `${root}options.html`, tab: { id: 4, windowId: 1, incognito: true } };
  const state = await f.background.handle({ type: 'state' }, sender); assert.equal(state.context.incognito, true);
  assert.equal((await f.background.handle({ type: 'settings', settings: { engine: 'bing' } }, sender)).ok, false);
  assert.equal((await f.background.handle({ type: 'clearChoices' }, sender)).ok, false);
  assert.equal(f.calls.some(call => call[0] === 'storage.set'), false);
  f.tabs.get(4).url = 'https://example.com'; assert.equal((await f.background.handle({ type: 'state' }, sender)).ok, false);
});

test('private sender.tab signal is fail-closed even if retrieved tab omits incognito property', async () => {
  const f = fixture({ incognito: true }); delete f.tabs.get(1).incognito;
  const state = await f.background.handle({ type: 'state' }, f.sender()); assert.equal(state.context.incognito, true);
  assert.deepEqual((await f.background.handle({ type: 'suggest', query: 'weather' }, f.sender())).suggestions, []);
  assert.equal(f.suggestions.calls.at(-1).options.incognito, true);
});

test('popup without a known active tab privacy context refuses action and network requests', async () => {
  for (const unknown of ['missing', 'privacy']) {
    const f = fixture();
    if (unknown === 'missing') f.tabs.clear(); else delete f.tabs.get(1).incognito;
    for (const message of [{ type: 'suggest', query: 'weather' }, { type: 'favicon', url: 'https://example.com' },
      { type: 'activate', target: { kind: 'query', query: 'weather' } }, { type: 'settings', settings: { engine: 'bing' } }]) {
      assert.equal((await f.background.handle(message, f.sender('popup'))).ok, false);
    }
    assert.equal(f.suggestions.calls.length, 0); assert.equal(f.favicons.calls.length, 0); assert.deepEqual(mutations(f.calls), []);
  }
});

test('overlay protocol allows only authorized read/search/activation/close messages', () => {
  const overlayToken = 'a'.repeat(64);
  for (const message of [{ type: 'state' }, { type: 'query', query: '' }, { type: 'suggest', query: 'weather' },
    { type: 'favicon', url: 'https://example.com/' }, { type: 'activate', target: { kind: 'tab', tabId: 2 } },
    { type: 'overlayClose' }, { type: 'overlayReady' }]) {
    assert.equal(validMessage({ ...message, overlayToken }), true);
  }
  for (const message of [{ type: 'overlayClose' }, { type: 'overlayReady' }, { type: 'overlayReady', overlayToken, extra: true }, { type: 'overlayClose', overlayToken, extra: true },
    { type: 'state', overlayToken: 'invalid' }, { type: 'settings', settings: { engine: 'bing' }, overlayToken },
    { type: 'popupClosed', tabId: 1, popupToken: overlayToken, overlayToken },
    { type: 'clearChoices', overlayToken }, { type: 'query', query: '', overlayToken, extra: true }]) assert.equal(validMessage(message), false);
});

test('overlay state and inventory are authorized without exposing session credentials', async () => {
  const f = fixture(); const overlay = await openOverlay(f);
  const result = await overlay.send({ type: 'state' });
  assert.deepEqual(result.context, { surface: 'overlay', incognito: false, tabId: 1, windowId: 1 });
  assert.equal(JSON.stringify(result).includes(overlay.overlayToken), false);
  const query = await overlay.send({ type: 'query', query: '' });
  assert.deepEqual(query.inventory, { tabCount: 3, windowCount: 2 });
  assert.equal(query.rows.some(row => row.target?.tabId === 1), true);
  assert.deepEqual(mutations(f.calls), []);
});

test('overlay activation switches existing tabs without closing or navigating its user page', async () => {
  const f = fixture(); const overlay = await openOverlay(f); const original = f.tabs.get(1).url;
  const result = await overlay.send({ type: 'activate', target: { kind: 'tab', tabId: 2 } });
  assert.deepEqual(result, { ok: true, closePopup: false, closeOverlay: true });
  assert.equal(f.tabs.get(1).url, original); assert.equal(f.tabs.has(1), true);
  assert.deepEqual(mutations(f.calls).slice(0, 2), [['update', 2, { active: true }], ['window', 2, { focused: true }]]);
  assert.equal(f.calls.some(call => call[0] === 'remove' || call[0] === 'create'), false);
  assert.equal((await overlay.send({ type: 'state' })).ok, false);
});

test('overlay search and direct addresses create one destination tab in its window, preserving source', async () => {
  for (const target of [{ kind: 'url', url: 'https://example.com/docs' }, { kind: 'query', query: 'weather' }]) {
    const f = fixture(); const overlay = await openOverlay(f); const original = f.tabs.get(1).url;
    const result = await overlay.send({ type: 'activate', target });
    assert.equal(result.ok, true); assert.equal(result.closeOverlay, true);
    assert.equal(f.tabs.get(1).url, original); assert.equal(f.calls.some(call => call[0] === 'update' || call[0] === 'remove'), false);
    const creations = f.calls.filter(call => call[0] === 'create'); assert.equal(creations.length, 1); assert.equal(creations[0][1].windowId, 1);
    assert.equal((await overlay.send({ type: 'state' })).ok, false);
  }
});

test('closing an overlay changes no tab or choices and invalidates its token', async () => {
  const f = fixture(); const overlay = await openOverlay(f); const original = structuredClone([...f.tabs.values()]);
  assert.deepEqual(await overlay.send({ type: 'overlayClose' }), { ok: true, closeOverlay: true });
  assert.deepEqual([...f.tabs.values()], original); assert.deepEqual(mutations(f.calls), []);
  assert.equal((await overlay.send({ type: 'query', query: 'weather' })).ok, false);
});

test('blank overlay activation stays open without navigating or persisting', async () => {
  const f = fixture(); const overlay = await openOverlay(f);
  assert.deepEqual(await overlay.send({ type: 'activate', target: { kind: 'query', query: '  ' } }), { ok: true, closePopup: false, closeOverlay: false });
  assert.deepEqual(mutations(f.calls), []); assert.equal((await overlay.send({ type: 'state' })).ok, true);
});

test('explicit newtab action opens Safari default page with no URL or choice record', async () => {
  for (const surface of ['overlay', 'popup', 'newtab']) {
    for (const incognito of [false, true]) {
      const f = fixture({ incognito });
      const overlay = surface === 'overlay' ? await openOverlay(f) : null;
      const original = f.tabs.get(1).url;
      const result = overlay ? await overlay.send({ type: 'activate', target: { kind: 'newtab' } })
        : await f.background.handle({ type: 'activate', target: { kind: 'newtab' } }, f.sender(surface));
      assert.equal(result.ok, true);
      assert.equal(result.closePopup, surface === 'popup');
      if (overlay) assert.equal(result.closeOverlay, true);
      assert.deepEqual(f.calls.filter(call => call[0] === 'create'), [['create', { active: true, windowId: 1 }]]);
      assert.equal(f.tabs.get(1).url, original);
      assert.equal(f.calls.some(call => ['update', 'remove', 'storage.set'].includes(call[0])), false);
    }
  }
});

test('explicit newtab cannot use a stale overlay session or the options page', async () => {
  const f = fixture(); const overlay = await openOverlay(f); f.tabs.get(1).url = 'https://example.com/navigated';
  assert.equal((await overlay.send({ type: 'activate', target: { kind: 'newtab' } })).ok, false);
  assert.equal((await f.background.handle({ type: 'activate', target: { kind: 'newtab' } }, f.sender('options'))).ok, false);
  assert.deepEqual(mutations(f.calls), []);
});

test('overlay cannot change settings or clear choices even with a valid session', async () => {
  const f = fixture(); const overlay = await openOverlay(f);
  assert.equal((await overlay.send({ type: 'settings', settings: { engine: 'bing' } })).ok, false);
  assert.equal((await overlay.send({ type: 'clearChoices' })).ok, false);
  assert.deepEqual(mutations(f.calls), []);
});

test('private overlay isolates ranking, external suggestions, favicons and choice persistence', async () => {
  const f = fixture({ incognito: true, stored: { settings: { googleSuggestions: true },
    choices: [{ kind: 'query', value: 'secret regular choice', count: 1, lastUsed: now }] } });
  f.tabs.set(4, { id: 4, windowId: 4, title: 'Regular secret', url: 'https://regular.example.com/', incognito: false });
  const overlay = await openOverlay(f); const rows = (await overlay.send({ type: 'query', query: '' })).rows;
  assert.equal(rows.some(row => row.kind === 'recent' || row.kind === 'history' || row.target?.tabId === 4), false);
  assert.deepEqual((await overlay.send({ type: 'suggest', query: 'private weather' })).suggestions, []);
  assert.equal(f.suggestions.calls.at(-1).options.incognito, true);
  assert.equal((await overlay.send({ type: 'favicon', url: 'https://example.com/' })).image, null);
  assert.equal(f.favicons.calls.at(-1).options.incognito, true);
  assert.equal((await overlay.send({ type: 'activate', target: { kind: 'tab', tabId: 4 } })).ok, false);
  assert.equal((await overlay.send({ type: 'activate', target: { kind: 'query', query: 'private weather' } })).ok, true);
  assert.equal(f.calls.some(call => call[0] === 'storage.set'), false);
  assert.equal(f.calls.find(call => call[0] === 'create')[1].windowId, 1);
});

test('forged and stale overlay sessions cannot invoke network or mutations', async () => {
  for (const mutate of [overlay => { overlay.overlayToken = 'b'.repeat(64); },
    overlay => { overlay.sender.frameId = 1; }, overlay => { overlay.sender.documentId = 'old-document'; },
    (overlay, f) => { f.tabs.get(1).url = 'https://example.com/navigated'; },
    (overlay, f) => { f.tabs.get(1).windowId = 9; }, (overlay, f) => { f.tabs.get(1).incognito = undefined; }]) {
    const f = fixture(); const overlay = await openOverlay(f); mutate(overlay, f);
    for (const message of [{ type: 'suggest', query: 'weather' }, { type: 'favicon', url: 'https://example.com/' },
      { type: 'activate', target: { kind: 'query', query: 'weather' } }]) {
      const result = await f.background.handle({ ...message, overlayToken: overlay.overlayToken }, overlay.sender);
      assert.equal(result.ok, false);
    }
    assert.equal(f.suggestions.calls.length, 0); assert.equal(f.favicons.calls.length, 0); assert.deepEqual(mutations(f.calls), []);
  }
});

test('navigation while resolving an activation target prevents later overlay mutations', async () => {
  const f = fixture(); const overlay = await openOverlay(f); const get = f.browser.tabs.get;
  f.browser.tabs.get = async id => { const tab = await get(id); if (id === 2) f.tabs.get(1).url = 'https://example.com/navigated'; return tab; };
  assert.equal((await overlay.send({ type: 'activate', target: { kind: 'tab', tabId: 2 } })).ok, false);
  assert.deepEqual(mutations(f.calls), []);
});

test('protected iframe receives authorized search data but rejects unsolicited embedding and frame reuse', async () => {
  const f = fixture(); const overlay = await openOverlay(f);
  const child = { ...overlay.sender, url: `${root}overlay-frame.html`, frameId: 8, documentId: 'protected-frame-document' };
  assert.equal((await f.background.handle({ type: 'state', overlayToken: overlay.overlayToken }, child)).ok, false);
  assert.equal((await overlay.send({ type: 'state' })).ok, true);
  const message = { type: 'query', query: 'swift', overlayToken: overlay.overlayToken };
  assert.equal((await f.background.handle(message, child)).rows[0].target.tabId, 2);
  for (const sender of [{ ...child, frameId: 9 }, { ...child, documentId: 'reloaded-frame' },
    { ...child, url: `${root}overlay-frame.html?fake=1` }]) assert.equal((await f.background.handle(message, sender)).ok, false);
  assert.equal((await f.background.handle({ type: 'settings', settings: { engine: 'bing' }, overlayToken: overlay.overlayToken }, child)).ok, false);
  assert.deepEqual(await f.background.handle({ type: 'overlayClose', overlayToken: overlay.overlayToken }, child), { ok: true, closeOverlay: true });
  assert.equal((await f.background.handle(message, child)).ok, false);
});

test('overlayReady accepts only an authorized protected child and not website content or arbitrary pages', async () => {
  const f = fixture(); const overlay = await openOverlay(f);
  const message = { type: 'overlayReady', overlayToken: overlay.overlayToken };
  const child = { ...overlay.sender, url: `${root}overlay-frame.html`, frameId: 8, documentId: 'protected-frame-document' };
  assert.equal((await f.background.handle(message, child)).ok, false);
  assert.equal((await f.background.handle(message, overlay.sender)).ok, false);
  await overlay.send({ type: 'state' });
  assert.deepEqual(await f.background.handle(message, child), { ok: true });
  assert.equal(f.calls.findLast(call => call[0] === 'send')[2].type, 'overlayReady');
  assert.equal((await f.background.handle(message, { ...child, frameId: 9 })).ok, false);
  assert.equal((await f.background.handle(message, { ...child, url: `${root}popup.html` })).ok, false);
});
