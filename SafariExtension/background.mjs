import { DEFAULT_SETTINGS, ENGINES, address, buildRows, destination, rememberChoice, sanitizeChoices, sanitizeSettings, webURL } from './core.mjs';
import { FaviconService, PersistentFaviconCache, SuggestionsService, TabCache } from './services.mjs';

const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const keys = (value, allowed) => object(value) && Object.keys(value).every(key => allowed.includes(key));
const validID = value => Number.isSafeInteger(value) && value >= 0;
const validQuery = value => typeof value === 'string' && value.length <= 2048 && !/[\u0000\u007f]/.test(value);

export function validMessage(message) {
  if (!object(message) || typeof message.type !== 'string') return false;
  switch (message.type) {
    case 'state': case 'clearChoices': return keys(message, ['type']);
    case 'query': return keys(message, ['type', 'query', 'force']) && validQuery(message.query)
      && (message.force === undefined || typeof message.force === 'boolean');
    case 'suggest': return keys(message, ['type', 'query']) && validQuery(message.query);
    case 'favicon': return keys(message, ['type', 'url']) && typeof message.url === 'string' && message.url.length <= 4096;
    case 'settings': return keys(message, ['type', 'settings']) && keys(message.settings, Object.keys(DEFAULT_SETTINGS))
      && Object.entries(message.settings).every(([key, value]) => key === 'engine' ? Object.hasOwn(ENGINES, value) : typeof value === 'boolean');
    case 'activate': {
      if (!keys(message, ['type', 'target', 'forceNew']) || (message.forceNew !== undefined && typeof message.forceNew !== 'boolean')) return false;
      const target = message.target;
      return (keys(target, ['kind', 'tabId']) && target.kind === 'tab' && validID(target.tabId))
        || (keys(target, ['kind', 'query']) && target.kind === 'query' && validQuery(target.query))
        || (keys(target, ['kind', 'url']) && target.kind === 'url' && !!webURL(target.url));
    }
    default: return false;
  }
}

export function createBackground({ browser, fetch = globalThis.fetch, now = Date.now,
  suggestions = new SuggestionsService({ fetch, now }), favicons = new FaviconService({ fetch, now,
    persistence: new PersistentFaviconCache({ storage: browser.storage.local, now }) }) }) {
  const tabCache = new TabCache(browser, { now });
  let settings = { ...DEFAULT_SETTINGS }; let choices = []; let initialized = null; let mutations = Promise.resolve();
  const pageURLs = Object.fromEntries(['newtab', 'popup', 'options'].map(surface => [surface, browser.runtime.getURL(`${surface}.html`)]));
  const extensionRoot = browser.runtime.getURL('');

  function trustedSurface(sender) {
    if (sender?.id && browser.runtime.id && sender.id !== browser.runtime.id) return null;
    return Object.keys(pageURLs).find(surface => sender?.url === pageURLs[surface]) ?? null;
  }
  async function load() {
    if (!initialized) initialized = (async () => {
      try {
        const stored = await browser.storage.local.get(['settings', 'choices']);
        settings = sanitizeSettings(stored.settings); choices = sanitizeChoices(stored.choices, now());
      } catch { settings = { ...DEFAULT_SETTINGS }; choices = []; }
    })();
    return initialized;
  }
  async function context(sender, surface) {
    let tab;
    if (surface === 'newtab') {
      if (!validID(sender.tab?.id)) throw new Error('stale');
      tab = await browser.tabs.get(sender.tab.id);
      if (tab.url !== pageURLs.newtab || tab.windowId !== sender.tab.windowId) throw new Error('stale');
    } else if (surface === 'options' && sender.tab) {
      if (!validID(sender.tab.id)) throw new Error('stale');
      tab = await browser.tabs.get(sender.tab.id);
      if (tab.url !== pageURLs.options || tab.windowId !== sender.tab.windowId) throw new Error('stale');
    } else if (surface === 'popup') {
      [tab] = await browser.tabs.query({ active: true, currentWindow: true });
      if (!tab || !validID(tab.windowId) || typeof tab.incognito !== 'boolean') throw new Error('private');
    }
    const unknownPrivacy = tab && typeof tab.incognito !== 'boolean' && typeof sender.tab?.incognito !== 'boolean';
    return { surface, incognito: sender.incognito === true || sender.tab?.incognito === true || tab?.incognito === true || !!unknownPrivacy,
      ...(validID(tab?.id) ? { tabId: tab.id } : {}), ...(validID(tab?.windowId) ? { windowId: tab.windowId } : {}) };
  }
  function mutate(task) {
    const next = mutations.then(task); mutations = next.catch(() => {}); return next;
  }
  async function record(target, title, ctx) {
    if (ctx.incognito || !settings.rememberChoices) return;
    await mutate(async () => {
      if (!settings.rememberChoices) return;
      const updated = rememberChoice(choices, target, title, now());
      await browser.storage.local.set({ choices: updated }); choices = updated;
    }).catch(() => {});
  }
  async function createOrUpdate(url, ctx, forceNew) {
    if (ctx.surface === 'newtab' && !forceNew) {
      const tab = await browser.tabs.get(ctx.tabId);
      if (tab.url !== pageURLs.newtab || tab.windowId !== ctx.windowId || !!tab.incognito !== ctx.incognito) throw new Error('stale');
      await browser.tabs.update(ctx.tabId, { url, active: true });
    } else {
      if (ctx.incognito && !validID(ctx.windowId)) throw new Error('private');
      await browser.tabs.create({ url, active: true, ...(validID(ctx.windowId) ? { windowId: ctx.windowId } : {}) });
    }
    tabCache.invalidate();
  }
  async function activate(message, ctx) {
    const { target, forceNew = false } = message;
    if (ctx.surface === 'options') throw new Error('invalid');
    if (target.kind === 'tab') {
      const tab = await browser.tabs.get(target.tabId);
      if (!!tab.incognito !== ctx.incognito || tab.url?.startsWith(extensionRoot)) throw new Error('stale');
      if (forceNew) {
        const address = webURL(tab.url);
        if (!address) throw new Error('invalid');
        await createOrUpdate(address, ctx, true);
      } else {
        await browser.tabs.update(tab.id, { active: true });
        await browser.windows.update(tab.windowId, { focused: true });
        // Never remove an arbitrary tab: both its exact URL and original context must still match.
        if (ctx.surface === 'newtab' && ctx.tabId !== tab.id) {
          const source = await browser.tabs.get(ctx.tabId).catch(() => null);
          if (source?.url === pageURLs.newtab && source.windowId === ctx.windowId && !!source.incognito === ctx.incognito) {
            await browser.tabs.remove(ctx.tabId).catch(() => {});
          }
        }
      }
      await record({ kind: 'url', url: tab.url }, tab.title, ctx);
    } else {
      const url = target.kind === 'url' ? webURL(target.url) : destination(target.query, settings.engine);
      if (!url) return { closePopup: false };
      await createOrUpdate(url, ctx, forceNew);
      const direct = target.kind === 'url' || address(target.query);
      const remembered = target.kind === 'url' || direct ? { kind: 'url', url } : { kind: 'query', query: target.query };
      await record(remembered, remembered.kind === 'url' ? url : target.query.trim(), ctx);
    }
    return { closePopup: ctx.surface === 'popup' };
  }
  async function handle(message, sender) {
    const surface = trustedSurface(sender);
    if (!surface || !validMessage(message)) return { ok: false, error: 'This request is not allowed.' };
    try {
      await load();
      const ctx = await context(sender, surface);
      switch (message.type) {
        case 'state': return { ok: true, settings: { ...settings }, context: ctx };
        case 'query': {
          const { tabs, refreshing } = await tabCache.get({ force: message.force, incognito: ctx.incognito });
          const visible = tabs.filter(tab => validID(tab.id) && !tab.url?.startsWith(extensionRoot));
          return { ok: true, query: message.query, rows: buildRows(visible, message.query,
            ctx.incognito || !settings.rememberChoices ? [] : choices, now()), refreshing };
        }
        case 'suggest': return { ok: true, query: message.query,
          suggestions: await suggestions.get(message.query, { enabled: settings.googleSuggestions, incognito: ctx.incognito }) };
        case 'favicon': return { ok: true, image: await favicons.get(message.url, { incognito: ctx.incognito }) };
        case 'activate': return { ok: true, ...await activate(message, ctx) };
        case 'settings': {
          if (ctx.incognito) throw new Error('private');
          return await mutate(async () => {
            const updated = sanitizeSettings({ ...settings, ...message.settings });
            await browser.storage.local.set({ settings: updated }); settings = updated;
            if (!settings.googleSuggestions) suggestions.clear();
            return { ok: true, settings: { ...settings } };
          });
        }
        case 'clearChoices': {
          if (ctx.incognito) throw new Error('private');
          return await mutate(async () => { await browser.storage.local.set({ choices: [] }); choices = []; return { ok: true }; });
        }
      }
    } catch { return { ok: false, error: 'Safari could not complete this action. Refresh and try again.' }; }
  }
  function install() {
    const invalidate = () => tabCache.invalidate();
    for (const name of ['onCreated', 'onRemoved', 'onUpdated', 'onMoved', 'onAttached', 'onDetached', 'onReplaced']) {
      browser.tabs[name]?.addListener(invalidate);
    }
    browser.storage.onChanged?.addListener((changes, area) => {
      if (area !== 'local') return;
      if (changes.settings) { settings = sanitizeSettings(changes.settings.newValue); if (!settings.googleSuggestions) suggestions.clear(); }
      if (changes.choices) choices = sanitizeChoices(changes.choices.newValue, now());
    });
    browser.runtime.onMessage.addListener(handle);
  }
  return { handle, install, tabCache };
}

if (globalThis.browser?.runtime?.onMessage) createBackground({ browser: globalThis.browser }).install();
