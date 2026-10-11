import test from 'node:test';
import assert from 'node:assert/strict';
import { createOverlayController, validOverlayToken } from '../../SafariExtension/overlay-controller.mjs';

const event = () => ({ listeners: [], addListener(fn) { this.listeners.push(fn); }, emit(...args) { for (const listener of this.listeners) listener(...args); } });
const deferred = () => { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; };
const flush = async () => { for (let count = 0; count < 20; count += 1) await Promise.resolve(); };

function fixture({ tabs: initialTabs, maxSessions = 16 } = {}) {
  let time = 1000; let nextToken = 0; let nextTimer = 0;
  const timers = new Map(); const calls = [];
  let visiblePopup = null;
  const tabs = new Map((initialTabs ?? [{ id: 1, windowId: 2, url: 'https://example.com/', active: true, incognito: false }]).map(tab => [tab.id, { ...tab }]));
  const browser = {
    runtime: { id: 'tab-scout', getURL: path => `moz-extension://tab-scout/${path}` },
    commands: { onCommand: event() },
    action: { onClicked: event(), setPopup: async details => {
      calls.push(['setPopup', details]); throw new Error('must use manifest default_popup');
    }, openPopup: async details => {
      calls.push(['openPopup', details]);
      const tab = [...tabs.values()].find(tab => tab.active && tab.windowId === details.windowId);
      if (!tab) throw new Error('no active tab');
      visiblePopup = tab.id;
    } },
    tabs: {
      get: async id => { if (!tabs.has(id)) throw new Error('gone'); return { ...tabs.get(id) }; },
      query: async () => [...tabs.values()].filter(tab => tab.active).map(tab => ({ ...tab })),
      sendMessage: async (id, message, options) => { calls.push(['send', id, message, options]); return { ok: true }; },
      create: async () => { throw new Error('must not create tabs'); },
      remove: async () => { throw new Error('must not remove tabs'); },
      onUpdated: event(), onRemoved: event(), onMoved: event(), onAttached: event(), onDetached: event(), onReplaced: event(), onActivated: event(),
    },
    scripting: { executeScript: async details => { calls.push(['inject', details]); return [{ frameId: 0, documentId: 'document-1' }]; } },
  };
  const controller = createOverlayController({ browser, now: () => time,
    createToken: () => (++nextToken).toString(16).padStart(64, '0'), timeoutMs: 100, ttlMs: 1000, maxSessions,
    setTimer: (callback, delay) => { const id = ++nextTimer; timers.set(id, { callback, at: time + delay }); return id; },
    clearTimer: id => timers.delete(id) });
  const sender = (id = 1) => { const tab = tabs.get(id); return { id: 'tab-scout', frameId: 0, documentId: 'document-1', url: tab?.url, tab: { ...tab } }; };
  const activeToken = () => calls.findLast(call => call[0] === 'send' && call[2].type === 'overlayOpen')?.[2].token;
  async function advance(milliseconds) {
    time += milliseconds;
    for (const [id, timer] of [...timers]) if (timer.at <= time) { timers.delete(id); timer.callback(); }
    await flush();
  }
  return { controller, browser, tabs, calls, sender, activeToken, advance, timers, visiblePopup: () => visiblePopup };
}

test('tokens require exactly 256 bits of lowercase hexadecimal', () => {
  assert.equal(validOverlayToken('a'.repeat(64)), true);
  for (const token of ['', 'a'.repeat(63), 'A'.repeat(64), 'z'.repeat(64), null, 123]) assert.equal(validOverlayToken(token), false);
});

test('opening injects only the top frame, focuses renderer, and never changes page or tabs', async () => {
  const f = fixture(); const original = structuredClone([...f.tabs.values()]);
  assert.deepEqual(await f.controller.toggle(), { ok: true });
  assert.deepEqual(f.calls[0], ['inject', { target: { tabId: 1, frameIds: [0] }, files: ['overlay.js'] }]);
  assert.deepEqual(f.calls[1], ['send', 1, { type: 'overlayOpen', token: '1'.padStart(64, '0') }, { frameId: 0 }]);
  assert.deepEqual([...f.tabs.values()], original);
  const context = await f.controller.validate(f.sender(), f.activeToken());
  assert.deepEqual(context, { surface: 'overlay', tabId: 1, windowId: 2, incognito: false, overlayToken: f.activeToken() });
  assert.equal(await f.controller.verify(context), true);
});

test('the same shortcut dismisses an existing session without another injection', async () => {
  const f = fixture(); await f.controller.toggle(); const token = f.activeToken();
  assert.deepEqual(await f.controller.toggle(), { ok: true, closed: true }); await flush();
  assert.equal(f.calls.filter(call => call[0] === 'inject').length, 1);
  assert.deepEqual(f.calls.at(-1), ['send', 1, { type: 'overlayDismiss', token }, { frameId: 0 }]);
  assert.equal(await f.controller.validate(f.sender(), token), null);
  assert.equal(f.tabs.size, 1);
});

test('forged tokens, senders, frames, documents, URLs, windows and privacy cannot use a session', async () => {
  const f = fixture(); await f.controller.toggle(); const token = f.activeToken(); const original = f.sender();
  for (const sender of [{ ...original, id: 'another-extension' }, { ...original, id: undefined },
    { ...original, frameId: 1 }, { ...original, frameId: undefined }, { ...original, documentId: 'old-document' },
    { ...original, url: 'https://example.com/other' }, { ...original, url: 'about:blank' },
    { ...original, tab: { ...original.tab, windowId: 8 } }, { ...original, tab: { ...original.tab, incognito: true } },
    { ...original, incognito: true }]) assert.equal(await f.controller.validate(sender, token), null);
  assert.equal(await f.controller.validate(original, '2'.padStart(64, '0')), null);
  assert.ok(await f.controller.validate(original, token));
});

test('protected iframe requires a top-frame-authorized live session and binds its frame identity', async () => {
  const f = fixture(); await f.controller.toggle(); const token = f.activeToken();
  const child = { ...f.sender(), frameId: 7, url: 'moz-extension://tab-scout/overlay-frame.html', documentId: 'child-document' };
  assert.equal(await f.controller.validate(child, token), null);
  assert.ok(await f.controller.validate(f.sender(), token));
  assert.ok(await f.controller.validate(child, token));
  for (const sender of [{ ...child, frameId: 8 }, { ...child, documentId: 'another-child-document' },
    { ...child, url: 'moz-extension://tab-scout/overlay-frame.html?evil=1' }, { ...child, url: 'https://example.com/' },
    { ...child, url: 'moz-extension://tab-scout/popup.html' }, { ...child, frameId: 0 }]) {
    assert.equal(await f.controller.validate(sender, token), null);
  }
  assert.ok(await f.controller.validate(child, token));
  await f.controller.dismiss(1, token); assert.equal(await f.controller.validate(child, token), null);
});

test('protected iframe cannot authorize when source has lost focus or changed privacy', async () => {
  for (const patch of [{ active: false }, { incognito: true }, { url: 'https://example.com/navigated' }]) {
    const f = fixture(); await f.controller.toggle(); const token = f.activeToken();
    assert.ok(await f.controller.validate(f.sender(), token));
    const child = { ...f.sender(), frameId: 4, url: 'moz-extension://tab-scout/overlay-frame.html', documentId: 'child-document' };
    Object.assign(f.tabs.get(1), patch);
    assert.equal(await f.controller.validate(child, token), null);
  }
});

test('unsolicited protected iframe without a session cannot read extension data', async () => {
  const f = fixture();
  const child = { ...f.sender(), frameId: 4, url: 'moz-extension://tab-scout/overlay-frame.html', documentId: 'child-document' };
  assert.equal(await f.controller.validate(child, 'a'.repeat(64)), null);
  assert.deepEqual(f.calls, []);
});

test('readiness routes only from its authorized child through runtime messaging to the top frame', async () => {
  const f = fixture(); await f.controller.toggle(); const token = f.activeToken();
  const top = await f.controller.validate(f.sender(), token);
  assert.equal(await f.controller.ready(top), false);
  const sender = { ...f.sender(), frameId: 7, url: 'moz-extension://tab-scout/overlay-frame.html', documentId: 'child-document' };
  const child = await f.controller.validate(sender, token);
  assert.equal(await f.controller.ready({ ...child, frameId: 8 }), false);
  assert.equal(await f.controller.ready({ ...child, overlayToken: 'b'.repeat(64) }), false);
  assert.equal(await f.controller.ready(child), true);
  assert.deepEqual(f.calls.at(-1), ['send', 1, { type: 'overlayReady', token }, { frameId: 0 }]);
  await f.controller.dismiss(1, token); assert.equal(await f.controller.ready(child), false);
});

test('readiness after source navigation or focus loss never sends a delayed ready event', async () => {
  for (const patch of [{ active: false }, { url: 'https://example.com/other' }]) {
    const f = fixture(); await f.controller.toggle(); const token = f.activeToken();
    await f.controller.validate(f.sender(), token);
    const child = await f.controller.validate({ ...f.sender(), frameId: 7, url: 'moz-extension://tab-scout/overlay-frame.html', documentId: 'child-document' }, token);
    Object.assign(f.tabs.get(1), patch);
    assert.equal(await f.controller.ready(child), false);
    assert.equal(f.calls.some(call => call[0] === 'send' && call[2].type === 'overlayReady'), false);
  }
});

test('live tab navigation, movement, removal, or unknown privacy revoke even without events', async () => {
  for (const patch of [{ url: 'https://example.com/navigated' }, { windowId: 3 }, { incognito: true }, { incognito: undefined }]) {
    const f = fixture(); await f.controller.toggle(); const sender = f.sender(); const token = f.activeToken();
    Object.assign(f.tabs.get(1), patch);
    assert.equal(await f.controller.validate(sender, token), null);
    Object.assign(f.tabs.get(1), sender.tab);
    assert.equal(await f.controller.validate(sender, token), null);
  }
  const f = fixture(); await f.controller.toggle(); const sender = f.sender(); const token = f.activeToken();
  f.tabs.delete(1); assert.equal(await f.controller.validate(sender, token), null);
});

test('expiry dismisses idle sessions while valid requests renew bounded lifetime', async () => {
  const f = fixture(); await f.controller.toggle(); const token = f.activeToken();
  await f.advance(900); assert.ok(await f.controller.validate(f.sender(), token));
  await f.advance(900); assert.ok(await f.controller.validate(f.sender(), token));
  await f.advance(1000); assert.equal(await f.controller.validate(f.sender(), token), null);
  assert.equal(f.calls.at(-1)[2].type, 'overlayDismiss'); assert.equal(f.timers.size, 0);
});

test('restricted pages and denied injection open the static toolbar popup without creating a tab', async () => {
  for (const restricted of [true, false]) {
    const f = fixture();
    if (restricted) f.tabs.get(1).url = 'favorites://';
    else f.browser.scripting.executeScript = async () => { throw new Error('website access denied'); };
    assert.deepEqual(await f.controller.toggle(), { ok: true, fallback: true });
    assert.deepEqual(f.calls.filter(call => ['setPopup', 'openPopup'].includes(call[0])), [['openPopup', { windowId: 2 }]]);
    assert.equal(f.visiblePopup(), 1); assert.equal(f.tabs.size, 1); assert.equal(f.timers.size, 0);
  }
});

test('a subsequent website shortcut injects its overlay without changing native popup configuration', async () => {
  const f = fixture(); f.tabs.get(1).url = 'favorites://'; await f.controller.toggle();
  f.tabs.get(1).url = 'https://example.com/'; const before = f.calls.length;
  assert.deepEqual(await f.controller.toggle(), { ok: true });
  assert.equal(f.calls[before][0], 'inject');
  assert.equal(f.calls.some(call => call[0] === 'setPopup'), false);
});

test('a failed popup or already-open native popup does not alter Safari configuration', async () => {
  const f = fixture(); f.tabs.get(1).url = 'about:blank';
  f.browser.action.openPopup = async () => { throw new Error('cannot show popup'); };
  assert.deepEqual(await f.controller.toggle(), { ok: false, fallback: true });
  assert.deepEqual(f.calls, []); assert.equal(f.timers.size, 0);
});

test('missing popup API fails closed without opening another tab', async () => {
  const f = fixture(); f.tabs.get(1).url = 'favorites://'; delete f.browser.action.openPopup;
  assert.deepEqual(await f.controller.toggle(), { ok: false, fallback: true });
  assert.deepEqual(f.calls, []); assert.equal(f.tabs.size, 1); assert.equal(f.timers.size, 0);
});

test('private restricted page fallback stays in its private Safari window', async () => {
  const f = fixture({ tabs: [{ id: 1, windowId: 42, url: 'favorites://', active: true, incognito: true }] });
  assert.deepEqual(await f.controller.toggle(), { ok: true, fallback: true });
  assert.deepEqual(f.calls, [['openPopup', { windowId: 42 }]]);
  assert.equal(f.tabs.size, 1); assert.equal(f.timers.size, 0);
});

test('navigation or lost focus before fallback lookup settles cannot open delayed popup UI', async () => {
  for (const patch of [{ url: 'https://example.com/other' }, { active: false }, { incognito: true }, { windowId: 9 }]) {
    const f = fixture(); const gate = deferred(); const get = f.browser.tabs.get;
    f.tabs.get(1).url = 'favorites://'; let lookups = 0;
    f.browser.tabs.get = async id => { if (++lookups === 1) await gate.promise; return get(id); };
    const pending = f.controller.toggle(); await flush(); Object.assign(f.tabs.get(1), patch);
    gate.resolve(); assert.deepEqual(await pending, { ok: false, fallback: true });
    assert.deepEqual(f.calls, []);
  }
});

test('late popup acknowledgement after timeout does not trigger retry or configuration changes', async () => {
  const f = fixture(); const gate = deferred(); f.tabs.get(1).url = 'favorites://';
  f.browser.action.openPopup = async details => { f.calls.push(['openPopup', details]); await gate.promise; };
  const pending = f.controller.toggle(); await flush(); await f.advance(100);
  assert.deepEqual(await pending, { ok: false, fallback: true });
  gate.resolve(); await flush();
  assert.deepEqual(f.calls, [['openPopup', { windowId: 2 }]]);
  assert.equal(f.tabs.size, 1); assert.equal(f.timers.size, 0);
});

test('renderer failure dismisses with the original token before falling back to its popup', async () => {
  const f = fixture(); const send = f.browser.tabs.sendMessage;
  f.browser.tabs.sendMessage = async (...args) => { await send(...args); return { ok: args[1].type !== 'overlayOpen' }; };
  assert.deepEqual(await f.controller.toggle(), { ok: true, fallback: true });
  const token = f.activeToken();
  assert.deepEqual(f.calls.find(call => call[0] === 'send' && call[2].type === 'overlayDismiss'),
    ['send', 1, { type: 'overlayDismiss', token }, { frameId: 0 }]);
  assert.equal(f.calls.some(call => call[0] === 'openPopup'), true);
  assert.equal(await f.controller.validate(f.sender(), token), null);
});

test('toggle during pending injection cancels only that session and allows a fresh token', async () => {
  const f = fixture(); const gate = deferred(); const inject = f.browser.scripting.executeScript;
  f.browser.scripting.executeScript = () => gate.promise;
  const pending = f.controller.toggle(); await flush();
  assert.deepEqual(await f.controller.toggle(), { ok: true, closed: true });
  f.browser.scripting.executeScript = inject;
  assert.deepEqual(await f.controller.toggle(), { ok: true }); const freshToken = f.activeToken();
  gate.resolve([{ frameId: 0, documentId: 'document-1' }]); assert.deepEqual(await pending, { ok: false });
  assert.ok(await f.controller.validate(f.sender(), freshToken));
  assert.equal(f.calls.filter(call => call[0] === 'send' && call[2].type === 'overlayOpen').length, 1);
});

test('injection timeout prevents any later overlay or fallback from opening', async () => {
  const f = fixture(); const gate = deferred();
  f.browser.scripting.executeScript = () => gate.promise;
  const pending = f.controller.toggle(); await flush(); await f.advance(100);
  assert.deepEqual(await pending, { ok: false });
  gate.resolve([{ frameId: 0, documentId: 'document-1' }]); await flush();
  assert.equal(f.calls.some(call => call[0] === 'send' && call[2].type === 'overlayOpen'), false);
  assert.equal(f.calls.some(call => call[0] === 'openPopup'), false);
});

test('late renderer acknowledgements after timeout receive only token-specific dismissal', async () => {
  const f = fixture(); const gate = deferred();
  const send = f.browser.tabs.sendMessage;
  f.browser.tabs.sendMessage = async (...args) => { const result = await send(...args); return args[1].type === 'overlayOpen' ? gate.promise : result; };
  const pending = f.controller.toggle(); await flush(); const token = f.activeToken(); await f.advance(100);
  assert.deepEqual(await pending, { ok: false });
  gate.resolve({ ok: true }); await flush();
  assert.equal(await f.controller.validate(f.sender(), token), null);
  assert.equal(f.calls.at(-1)[2].type, 'overlayDismiss');
  assert.equal(f.calls.some(call => call[0] === 'openPopup'), false);
});

test('navigation or focus changes while injecting never open delayed UI', async () => {
  for (const patch of [{ url: 'https://example.com/other' }, { active: false }]) {
    const f = fixture(); const gate = deferred(); f.browser.scripting.executeScript = () => gate.promise;
    const pending = f.controller.toggle(); await flush(); Object.assign(f.tabs.get(1), patch);
    gate.resolve([{ frameId: 0 }]); assert.deepEqual(await pending, { ok: false });
    assert.equal(f.calls.some(call => call[0] === 'send' && call[2].type === 'overlayOpen'), false);
    assert.equal(f.calls.some(call => call[0] === 'openPopup'), false);
  }
});

test('document IDs are pinned from the first request when executeScript omits them', async () => {
  const f = fixture(); f.browser.scripting.executeScript = async () => [{ frameId: 0 }]; await f.controller.toggle();
  const token = f.activeToken(); assert.ok(await f.controller.validate(f.sender(), token));
  assert.equal(await f.controller.validate({ ...f.sender(), documentId: 'new-document' }, token), null);
});

test('session capacity evicts and dismisses the oldest overlay', async () => {
  const f = fixture({ maxSessions: 1, tabs: [1, 2].map(id => ({ id, windowId: id, url: `https://example.com/${id}`, incognito: false, active: true })) });
  await f.controller.toggle({ id: 1 }); const firstToken = f.activeToken();
  await f.controller.toggle({ id: 2 }); await flush();
  assert.equal(await f.controller.validate(f.sender(1), firstToken), null);
  assert.equal(f.calls.some(call => call[0] === 'send' && call[1] === 1 && call[2].type === 'overlayDismiss'), true);
});

test('navigation, replacement and activity events revoke sessions; irrelevant updates do not', async () => {
  for (const name of ['onRemoved', 'onMoved', 'onAttached', 'onDetached', 'onReplaced', 'onUpdated', 'onActivated']) {
    const f = fixture(); f.controller.install(); await f.controller.toggle(); const token = f.activeToken();
    if (name === 'onReplaced') f.browser.tabs[name].emit(9, 1);
    else if (name === 'onUpdated') f.browser.tabs[name].emit(1, { status: 'loading' });
    else if (name === 'onActivated') f.browser.tabs[name].emit({ windowId: 2, tabId: 9 });
    else f.browser.tabs[name].emit(1);
    assert.equal(await f.controller.validate(f.sender(), token), null, name);
  }
  const f = fixture(); f.controller.install(); await f.controller.toggle();
  f.browser.tabs.onUpdated.emit(1, { title: 'New title' }); assert.ok(await f.controller.validate(f.sender(), f.activeToken()));
});

test('unknown or inactive tab context fails closed without opening any UI', async () => {
  for (const patch of [{ incognito: undefined }, { windowId: undefined }, { active: false }]) {
    const f = fixture(); Object.assign(f.tabs.get(1), patch);
    assert.deepEqual(await f.controller.toggle(), { ok: false }); assert.deepEqual(f.calls, []);
  }
});

test('supported command toggles the overlay while toolbar remains the manifest native popup', async () => {
  const f = fixture(); f.controller.install();
  f.browser.commands.onCommand.emit('unrelated'); await flush(); assert.deepEqual(f.calls, []);
  assert.equal(f.browser.action.onClicked.listeners.length, 0);
  f.browser.commands.onCommand.emit('toggle-search', f.tabs.get(1)); await flush();
  assert.equal(f.calls.filter(call => call[0] === 'inject').length, 1);
  f.browser.commands.onCommand.emit('toggle-search', f.tabs.get(1)); await flush();
  assert.equal(f.calls.at(-1)[2].type, 'overlayDismiss');
  assert.equal(f.calls.some(call => call[0] === 'setPopup'), false);
});
