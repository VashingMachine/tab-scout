const assert = require('node:assert/strict');
const { readFileSync, mkdirSync } = require('node:fs');
const { resolve, extname } = require('node:path');
const http = require('node:http');
const { chromium } = require(process.env.TAB_SCOUT_PLAYWRIGHT_MODULE || 'playwright');

const root = resolve(__dirname, '../SafariExtension');
const output = resolve(process.env.TAB_SCOUT_UI_OUTPUT_DIR || '.build/safari-ui');
const icon = readFileSync(resolve(root, 'icons/app-16.png')).toString('base64');
const mime = { '.html': 'text/html', '.mjs': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.png': 'image/png' };

function fixture({ icon, privateMode, suggestionsEnabled, overlayMode = false, queryDelayMs = 0, focusErrorMode = 'none' }) {
  if (overlayMode && location.pathname === '/overlay-frame.html') {
    const parentAPI = parent.browser;
    window.testFrameKeys = [];
    document.addEventListener('keydown', event => window.testFrameKeys.push({ key: event.key, trusted: event.isTrusted,
      target: event.target.tagName, active: document.activeElement.tagName }), { capture: true });
    document.addEventListener('keydown', event => {
      if (window.testSuppressPaste && (event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'v') {
        window.testPasteKey = { defaultPrevented: event.defaultPrevented, active: document.activeElement.id };
        event.preventDefault();
      }
    });
    if (focusErrorMode === 'child') {
      window.focus = () => {
        parent.testFixture.focusErrors.push('child-self');
        throw new DOMException('Blocked frame focus in Safari fixture', 'SecurityError');
      };
    }
    window.browser = { ...parentAPI, runtime: { ...parentAPI.runtime,
      sendMessage(message) {
        return parentAPI.runtime.sendMessage(message, { id: 'fixture', url: location.href,
          tab: parent.testFixture.tabs[0], incognito: privateMode, frameId: 1, documentId: 'fixture-child-document' });
      },
    } };
    return;
  }
  const listeners = [];
  const contentListeners = [];
  const events = () => {
    const callbacks = [];
    return { addListener(callback) { callbacks.push(callback); },
      async emit(...args) { for (const callback of callbacks) await callback(...args); } };
  };
  const ownedPage = location.pathname === '/options.html' ? 'options.html' : 'newtab.html';
  const owned = { id: 900, windowId: 4, url: overlayMode ? location.href : `${location.origin}/${ownedPage}`,
    title: 'Tab Scout', active: true, incognito: privateMode };
  const tabs = [owned,
    { id: 1, windowId: 4, url: 'https://example.com/guide', title: 'Example Guide', incognito: privateMode },
    { id: 2, windowId: 7, url: 'https://example.org/cafe', title: 'Caf\u00e9 Research', incognito: privateMode },
    { id: 3, windowId: 4, url: 'https://example.net/long', title: 'A very long fixture tab title '.repeat(12), incognito: privateMode },
  ];
  const store = { settings: { engine: 'google', googleSuggestions: suggestionsEnabled, rememberChoices: true }, choices: [] };
  let resolveReady;
  const ready = new Promise(resolve => { resolveReady = resolve; });
  window.testFixture = { tabs, store, updates: [], creates: [], removed: [], focused: [], requests: [], queries: [],
    messages: [], injected: [], shadowRoots: [], violations: [], overlayReplies: [], websiteKeys: [], popupOpens: [], focusErrors: [], closed: false };
  if (overlayMode) {
    if (focusErrorMode === 'parent') {
      const contentWindow = Object.getOwnPropertyDescriptor(HTMLIFrameElement.prototype, 'contentWindow');
      const proxies = new WeakMap();
      Object.defineProperty(HTMLIFrameElement.prototype, 'contentWindow', { ...contentWindow, get() {
        const window = contentWindow.get.call(this);
        if (!window) return window;
        if (!proxies.has(window)) proxies.set(window, new Proxy(window, { get(target, property) {
          if (property === 'focus') return () => {
            testFixture.focusErrors.push('parent-to-frame');
            throw new DOMException('Blocked cross-origin focus in Safari fixture', 'SecurityError');
          };
          const value = Reflect.get(target, property, target);
          return typeof value === 'function' ? value.bind(target) : value;
        } }));
        return proxies.get(window);
      } });
    }
    const attachShadow = Element.prototype.attachShadow;
    Element.prototype.attachShadow = function(options) {
      const root = attachShadow.call(this, options);
      window.testFixture.shadowRoots.push({ host: this, root, mode: options.mode });
      return root;
    };
    window.testFixture.overlayRoot = () => [...window.testFixture.shadowRoots].reverse().find(item => item.host.isConnected)?.root;
    window.testFixture.deliverOverlay = async (message, sender = { id: 'fixture' }) => {
      for (const listener of contentListeners) {
        const result = await listener(message, sender);
        if (result !== undefined) return result;
      }
    };
    addEventListener('securitypolicyviolation', event => window.testFixture.violations.push(event.violatedDirective));
    document.addEventListener('keydown', event => window.testFixture.websiteKeys.push(event.key));
  }
  window.close = () => { window.testFixture.closed = true; };
  window.fetch = async url => {
    window.testFixture.requests.push(String(url));
    if (String(url).startsWith('https://suggestqueries.google.com/')) {
      const q = new URL(url).searchParams.get('q');
      return new Response(JSON.stringify([q, [`${q} nearby`, `${q} reviews`]]), { headers: { 'content-type': 'application/json' } });
    }
    const bytes = Uint8Array.from(atob(icon), character => character.charCodeAt(0));
    return new Response(bytes, { headers: { 'content-type': 'image/png' } });
  };
  window.browser = {
    runtime: {
      id: 'fixture', getURL: path => `${location.origin}/${path}`,
      onMessage: { addListener: listener => {
        (window.testFixture.injectingOverlay ? contentListeners : listeners).push(listener);
        if (listener.length >= 2 && !window.testFixture.injectingOverlay) resolveReady();
      } },
      async sendMessage(message, fixtureSender) {
        await ready;
        window.testFixture.messages.push(message);
        if (window.testFixture.rejectOverlayState && message.type === 'state' && message.overlayToken) {
          return { ok: false, error: 'Simulated worker restart' };
        }
        // search.mjs has a notification listener; only the background listener returns a reply.
        const sender = fixtureSender || { id: 'fixture', url: location.href, tab: owned, incognito: privateMode,
          ...(overlayMode ? { frameId: 0, documentId: 'fixture-document' } : {}) };
        for (const listener of listeners) {
          const response = await listener(message, sender);
          if (response !== undefined) return response;
        }
      },
      async openOptionsPage() { window.testFixture.openedSettings = true; },
    },
    storage: {
      local: { async get() { return structuredClone(store); }, async set(value) { Object.assign(store, structuredClone(value)); } },
      onChanged: events(),
    },
    tabs: {
      async query(filter = {}) {
        window.testFixture.queries.push(filter);
        if (queryDelayMs) await new Promise(resolve => setTimeout(resolve, queryDelayMs));
        return tabs.filter(tab => !filter.active || tab.active).map(tab => ({ ...tab }));
      },
      async sendMessage(id, message, options) {
        if (!overlayMode || id !== owned.id || options?.frameId !== 0) throw Error('unexpected overlay delivery');
        window.testFixture.lastDelivery = message;
        const result = await window.testFixture.deliverOverlay(message);
        window.testFixture.overlayReplies.push({ message, result });
        return result;
      },
      async get(id) { const tab = tabs.find(tab => tab.id === id); if (!tab) throw Error('closed'); return { ...tab }; },
      async update(id, value) {
        const tab = tabs.find(tab => tab.id === id); if (!tab) throw Error('closed');
        window.testFixture.updates.push({ id, value }); Object.assign(tab, value); return { ...tab };
      },
      async create(value) { window.testFixture.creates.push(value); return { id: 999, ...value }; },
      async remove(id) { window.testFixture.removed.push(id); tabs.splice(tabs.findIndex(tab => tab.id === id), 1); },
      onCreated: events(), onRemoved: events(), onUpdated: events(), onActivated: events(),
    },
    commands: { onCommand: events() },
    action: { onClicked: events(),
      async openPopup(value) {
        window.testFixture.popupOpens.push(value);
        window.testFixture.openedPopup = value;
        // A static manifest popup can present asynchronously without configuration races.
        setTimeout(() => { window.testFixture.popupPresented = true; }, 25);
      },
    },
    scripting: { async executeScript(request) {
      if (!overlayMode || request.target?.tabId !== owned.id || request.target?.frameIds?.join() !== '0'
        || request.files?.join() !== 'overlay.js') throw Error('unexpected script injection');
      window.testFixture.injected.push(request);
      window.testFixture.injectingOverlay = true;
      try {
        await new Promise((resolve, reject) => {
          const script = document.createElement('script');
          script.src = `${location.origin}/overlay.js`;
          script.onload = resolve; script.onerror = reject;
          document.head.append(script);
        });
      } finally { window.testFixture.injectingOverlay = false; }
      return [{ frameId: 0, documentId: 'fixture-document' }];
    } },
    windows: { async update(id, value) { window.testFixture.focused.push({ id, value }); } },
  };
}

async function main() {
  mkdirSync(output, { recursive: true });
  const server = http.createServer((request, response) => {
    try {
      const pathname = new URL(request.url, 'http://localhost').pathname;
      if (pathname === '/overlay-fixture.html') {
        response.writeHead(200, { 'content-type': 'text/html', 'content-security-policy':
          `default-src 'none'; script-src 'self'; style-src 'none'; img-src 'self' data:; connect-src 'none'; frame-src ${request.url.includes('blocked-frame') ? "'none'" : "'self'"}` });
        response.end('<!doctype html><html><head><title>Existing Website Fixture</title></head><body>'
          + '<article id="website"><h1>Existing Website</h1><input id="website-input" value="Keep this text">'
          + '<button id="website-action" type="button">Website action</button><p>Unchanged browsing content.</p></article></body></html>');
        return;
      }
      const path = resolve(root, `.${pathname}`);
      if (!path.startsWith(`${root}/`)) throw Error('path');
      response.writeHead(200, { 'content-type': mime[extname(path)] || 'application/octet-stream' });
      response.end(readFileSync(path));
    } catch { response.writeHead(404); response.end(); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const origin = `http://127.0.0.1:${server.address().port}`;
  let browser;
  let checks = 0;
  try {
    browser = await chromium.launch({ headless: true });
    async function pageFor(surface, viewport, privateMode = false, suggestionsEnabled = false, colorScheme = 'light') {
      const context = await browser.newContext({ viewport, colorScheme });
      const page = await context.newPage();
      await page.addInitScript(fixture, { icon, privateMode, suggestionsEnabled });
      const errors = [];
      page.on('pageerror', error => errors.push(error.message));
      await page.goto(`${origin}/${surface}.html`);
      await page.evaluate(() => import('./background.mjs'));
      if (surface === 'options') await page.locator('#engine:enabled').waitFor();
      else {
        await page.locator('.result').first().waitFor();
        await page.waitForFunction(() => [...document.querySelectorAll('.result-image')].every(node => node.complete && node.naturalWidth > 0));
      }
      return { page, context, errors };
    }
    async function overlayPageFor(viewport, colorScheme = 'light', blocked = false, useClock = false, focusErrorMode = 'none') {
      const context = await browser.newContext({ viewport, colorScheme });
      const page = await context.newPage();
      if (useClock) await page.clock.install();
      await page.addInitScript(fixture, { icon, privateMode: false, suggestionsEnabled: false,
        overlayMode: true, queryDelayMs: blocked ? 0 : 200, focusErrorMode });
      const errors = [];
      page.on('pageerror', error => errors.push(error.message));
      await page.goto(`${origin}/overlay-fixture.html${blocked ? '?blocked-frame' : ''}`);
      await page.evaluate(() => import('./background.mjs'));
      await page.locator('#website-input').focus();
      return { page, context, errors };
    }
    async function websiteSnapshot(page) {
      return page.evaluate(() => {
        const content = document.querySelector('#website').cloneNode(true);
        // Screenshot caret hiding can leave an empty, visually inert style attribute.
        for (const node of content.querySelectorAll('[style]')) if (!node.getAttribute('style').trim()) node.removeAttribute('style');
        return { url: location.href, title: document.title, content: content.outerHTML,
          value: document.querySelector('#website-input').value,
          bodyStyle: document.body.getAttribute('style'), htmlStyle: document.documentElement.getAttribute('style') };
      });
    }
    async function waitForOverlay(page) {
      await page.waitForFunction(() => !!window.testFixture.overlayRoot()?.querySelector('iframe'));
      const frame = page.frames().find(frame => frame.url().endsWith('/overlay-frame.html'))
        || await page.waitForEvent('framenavigated', {
          predicate: frame => frame.url().endsWith('/overlay-frame.html'), timeout: 3000,
        });
      assert.ok(frame, 'overlay loads its packaged extension frame'); checks++;
      await frame.locator('#query').waitFor();
      await frame.waitForFunction(() => document.activeElement?.id === 'query');
      return frame;
    }
    function near(actual, expected, message, tolerance = 1) {
      assert.ok(Math.abs(actual - expected) <= tolerance, `${message}: expected ${expected}, received ${actual}`); checks++;
    }
    async function checkPopupPreferredSize(page, name) {
      const body = await page.locator('body').boundingBox();
      near(body.width, 660, `${name} keeps the native preferred popup width independent of the viewport`);
      near(body.height, 440, `${name} keeps the native preferred popup height independent of the viewport`);
      assert.equal(await page.locator('body').evaluate(node => getComputedStyle(node).overflow), 'hidden',
        `${name} clips the preferred outer document while its inner palette responds`); checks++;
    }
    async function checkRowContrast(page, name, selector, state) {
      const colors = await page.evaluate(selector => {
        const row = document.querySelector(selector);
        const canvas = document.createElement('canvas');
        canvas.width = canvas.height = 1;
        const context = canvas.getContext('2d', { willReadFrequently: true });
        const color = (node, property) => {
          context.clearRect(0, 0, 1, 1);
          context.fillStyle = getComputedStyle(node)[property];
          context.fillRect(0, 0, 1, 1);
          return [...context.getImageData(0, 0, 1, 1).data].map(value => value / 255);
        };
        return { backgrounds: [document.documentElement, document.body, document.querySelector('.scout'),
          row].map(node => color(node, 'backgroundColor')),
          title: color(row.querySelector('.result-title'), 'color'),
          detail: color(row.querySelector('.result-detail'), 'color') };
      }, selector);
      // Contrast uses the rendered background, including both translucent panel layers in popups.
      const over = (foreground, background) => foreground.slice(0, 3).map((channel, index) =>
        channel * foreground[3] + background[index] * (1 - foreground[3]));
      const background = colors.backgrounds.reduce((result, layer) => over(layer, result), [1, 1, 1]);
      const luminance = rgb => rgb.map(channel => channel <= 0.04045 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4)
        .reduce((sum, channel, index) => sum + channel * [0.2126, 0.7152, 0.0722][index], 0);
      for (const [label, color] of [['title', colors.title], ['detail', colors.detail]]) {
        const light = luminance(over(color, background));
        const dark = luminance(background);
        const contrast = (Math.max(light, dark) + 0.05) / (Math.min(light, dark) + 0.05);
        assert.ok(contrast >= 4.5, `${name} ${state} ${label} contrast is ${contrast.toFixed(2)}:1, at least 4.5:1 required`); checks++;
      }
    }
    async function checkNativePalette(page, name, surface, viewport, checkFixtureRows = true) {
      const layout = await page.evaluate(() => {
        const bounds = node => {
          const rect = node.getBoundingClientRect();
          return { left: rect.left, right: rect.right, top: rect.top, bottom: rect.bottom,
            width: rect.width, height: rect.height, centerX: rect.left + rect.width / 2, centerY: rect.top + rect.height / 2 };
        };
        const style = selector => getComputedStyle(document.querySelector(selector));
        const results = [...document.querySelectorAll('.result')];
        return {
          scout: bounds(document.querySelector('.scout')), search: bounds(document.querySelector('.search-field')),
          form: bounds(document.querySelector('.search-form')), region: bounds(document.querySelector('.result-region')),
          results: bounds(document.querySelector('.results')),
          footer: bounds(document.querySelector('.result-footer')), refresh: bounds(document.querySelector('#refresh')),
          settings: bounds(document.querySelector('#settings')), width: document.documentElement.scrollWidth,
          height: document.documentElement.scrollHeight,
          border: style('.scout').borderTopWidth, shadow: style('.scout').boxShadow,
          inputFont: style('#query').fontSize, titleFont: style('.result-title').fontSize,
          detailFont: style('.result-detail').fontSize, rows: results.map(bounds),
          titleInsets: results.map(node => node.querySelector('.result-title').getBoundingClientRect().top
            - node.getBoundingClientRect().top),
          adjacentGaps: results.flatMap((node, index) => node.previousElementSibling === results[index - 1]
            ? [node.getBoundingClientRect().top - results[index - 1].getBoundingClientRect().bottom] : []),
          images: [...document.querySelectorAll('.result-image')].map(bounds),
          labels: [...document.querySelectorAll('.section-label')].map(bounds),
          controls: [...document.querySelectorAll('#query, #clear-search, #refresh, #settings, .result-footer')]
            .filter(node => !node.hidden).map(bounds),
          assets: [...document.querySelectorAll('img')].filter(node => !node.hidden).map(node => ({
            src: node.currentSrc, complete: node.complete, width: node.naturalWidth,
          })),
        };
      });
      const horizontalMargin = viewport.width <= 420 ? 12 : 20;
      if (surface === 'newtab') {
        near(layout.scout.centerX, viewport.width / 2, `${name} centers horizontally`, 0.5);
        near(layout.scout.centerY, viewport.height / 2, `${name} centers vertically`, 0.5);
        near(layout.scout.width, Math.min(660, viewport.width - horizontalMargin * 2), `${name} native panel width`);
        near(layout.scout.height, Math.min(440, viewport.height - 40), `${name} native panel height`);
        assert.ok((parseFloat(layout.border) > 0 || layout.shadow.includes('inset')) && layout.shadow !== 'none',
          `${name} frames the native-style palette`); checks++;
        assert.ok(layout.width <= viewport.width, `${name} has no document-level horizontal overflow`); checks++;
        assert.ok(layout.height <= viewport.height, `${name} has no document-level vertical overflow`); checks++;
      } else {
        near(layout.scout.left, 0, `${name} popup stays horizontally anchored`);
        near(layout.scout.top, 0, `${name} popup stays vertically anchored`);
        near(layout.scout.width, Math.min(660, viewport.width), `${name} popup native width`);
        near(layout.scout.height, Math.min(440, viewport.height), `${name} popup native height`);
        await checkPopupPreferredSize(page, name);
      }
      assert.ok(layout.scout.left >= 0 && layout.scout.right <= viewport.width && layout.scout.top >= 0 && layout.scout.bottom <= viewport.height,
        `${name} search surface fits the viewport`); checks++;
      assert.ok(layout.controls.every(rect => rect.left >= layout.scout.left && rect.right <= layout.scout.right
        && rect.top >= layout.scout.top && rect.bottom <= layout.scout.bottom), `${name} search and footer controls stay inside the palette`); checks++;
      assert.equal(await page.locator('.toolbar, h1').count(), 0, `${name} does not add a brand header above the search`); checks++;
      near(layout.search.left - layout.scout.left, 20, `${name} native search left inset`, 2);
      near(layout.scout.right - layout.search.right, 20, `${name} native search right inset`, 2);
      near(layout.search.top - layout.scout.top, 20, `${name} native search top inset`, 2);
      near(layout.search.height, 38, `${name} native search height`);
      near(layout.form.bottom - layout.scout.top, 74, `${name} separator below the search`, 2);
      near(layout.results.top - layout.form.bottom, 8, `${name} space below the separator`, 1);
      near(layout.footer.height, 43, `${name} native footer height`);
      near(layout.footer.bottom, layout.scout.bottom, `${name} footer stays at palette bottom`, 2);
      near(layout.refresh.width, 28, `${name} native refresh width`);
      near(layout.refresh.height, 28, `${name} native refresh height`);
      near(layout.settings.width, 28, `${name} native settings width`);
      near(layout.settings.height, 28, `${name} native settings height`);
      near(layout.scout.right - layout.settings.right, 16, `${name} settings right inset`, 2);
      near(layout.scout.bottom - layout.settings.bottom, 9, `${name} settings bottom inset`, 2);
      near(layout.settings.left - layout.refresh.right, 5, `${name} footer button gap`);
      assert.equal(layout.inputFont, '21px', `${name} matches the native input font`); checks++;
      assert.equal(layout.titleFont, '14px', `${name} matches the native title font`); checks++;
      assert.equal(layout.detailFont, '12px', `${name} matches the native detail font`); checks++;
      assert.ok(layout.rows.every(row => row.height === 58), `${name} keeps result rows at 58px`); checks++;
      assert.ok(layout.titleInsets.every(inset => Math.abs(inset - 9) <= 0.5), `${name} keeps native result titles 9px below the row top`); checks++;
      if (checkFixtureRows) {
        assert.ok(layout.adjacentGaps.length > 0 && layout.adjacentGaps.every(gap => gap === 2), `${name} keeps 2px result gaps`); checks++;
      }
      assert.ok(layout.images.every(image => image.width === 23 && image.height === 23), `${name} keeps favicons and fallback symbols at 23px`); checks++;
      assert.ok(layout.labels.every(label => label.height === 25), `${name} keeps native section rows at 25px`); checks++;
      assert.equal(await page.locator('.result-action').count(), 0, `${name} has no extra trailing row actions`); checks++;
      assert.ok(layout.assets.every(asset => asset.complete && asset.width > 0), `${name} renders all row and control assets`); checks++;
      assert.ok(layout.assets.every(asset => asset.src.startsWith(`${origin}/icons/`) || asset.src.startsWith('data:image/')),
        `${name} icons use packaged assets or validated cached rasters`); checks++;
      if (checkFixtureRows) {
        const clipping = await page.locator('.result-title', { hasText: 'A very long fixture tab title' }).evaluate(node => {
          const rect = node.getBoundingClientRect();
          const parent = node.closest('.result').getBoundingClientRect();
          const css = getComputedStyle(node);
          return { clips: node.scrollWidth > node.clientWidth, fits: rect.left >= parent.left && rect.right <= parent.right,
            overflow: css.overflow, whiteSpace: css.whiteSpace, ellipsis: css.textOverflow };
        });
        assert.deepEqual(clipping, { clips: true, fits: true, overflow: 'hidden', whiteSpace: 'nowrap', ellipsis: 'ellipsis' },
          `${name} truncates long tab titles within their rows`); checks++;
      }
      assert.equal(await page.locator('#query').evaluate(node => document.activeElement === node), true, `${name} focuses the search input`); checks++;
      await checkRowContrast(page, name, '.result.is-selected', 'selected');
      await page.locator('.result:not(.is-selected)').first().hover();
      await checkRowContrast(page, name, '.result:hover:not(.is-selected)', 'hovered');
      await page.mouse.move(0, 0);
    }
    for (const [name, viewport, colorScheme] of [
      ['overlay-desktop-light', { width: 1280, height: 900 }, 'light'],
      ['overlay-desktop-dark', { width: 1280, height: 900 }, 'dark'],
      ['overlay-mobile-light', { width: 320, height: 700 }, 'light'],
      ['overlay-short-dark', { width: 960, height: 320 }, 'dark'],
    ]) {
      const overlay = await overlayPageFor(viewport, colorScheme);
      const { page } = overlay;
      const original = await websiteSnapshot(page);
      await page.evaluate(async () => {
        const style = document.createElement('style');
        style.textContent = '#website { display: none }';
        document.head.append(style);
        await new Promise(resolve => setTimeout(resolve, 20));
        style.remove();
        await browser.scripting.executeScript({ target: { tabId: 900, frameIds: [0] }, files: ['overlay.js'] });
      });
      assert.ok(await page.evaluate(() => testFixture.violations.some(value => value.startsWith('style-src'))),
        `${name} fixture really blocks page style elements`); checks++;
      const violationsBeforeOverlay = await page.evaluate(() => testFixture.violations.length);
      await page.evaluate(async () => {
        await testFixture.deliverOverlay({ type: 'overlayOpen', token: 'a'.repeat(64) }, { id: 'foreign-extension' });
        await testFixture.deliverOverlay({ type: 'overlayOpen', token: 'not-a-token' });
        await testFixture.deliverOverlay({ type: 'overlayOpen', token: 'b'.repeat(64) });
      });
      assert.equal(await page.locator('[data-tab-scout-overlay]').count(), 0, `${name} rejects forged senders and invalid or unissued tokens`); checks++;
      await page.evaluate(() => browser.commands.onCommand.emit('toggle-search'));
      const frame = await waitForOverlay(page);
      await page.keyboard.type('cafe');
      await frame.locator('.result-title', { hasText: 'Caf\u00e9 Research' }).waitFor();
      assert.equal(await frame.locator('#query').inputValue(), 'cafe', `${name} accepts immediate typing while initial results load`); checks++;
      assert.deepEqual(await page.evaluate(() => testFixture.websiteKeys), [], `${name} typed query events never reach the website document`); checks++;
      const layout = await page.evaluate(() => {
        const root = testFixture.overlayRoot();
        const frame = root.querySelector('iframe');
        const rect = frame.getBoundingClientRect();
        return { left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom,
          width: rect.width, height: rect.height, closed: root.host.shadowRoot === null,
          mode: testFixture.shadowRoots.at(-1).mode, sheets: root.adoptedStyleSheets.length,
          styleElements: root.querySelectorAll('style, link[rel="stylesheet"]').length,
          pageInput: document.querySelector('#query'), markup: root.host.outerHTML,
          frameURL: frame.src, token: testFixture.lastDelivery.token };
      });
      near(layout.width, Math.min(660, viewport.width - (viewport.width <= 420 ? 24 : 40)), `${name} native overlay width`);
      near(layout.height, Math.min(440, viewport.height - 40), `${name} native overlay height`);
      near(layout.left + layout.width / 2, viewport.width / 2, `${name} centers in the current browsing viewport`);
      near(layout.top + layout.height / 2, viewport.height / 2, `${name} centers vertically in the current browsing viewport`);
      assert.ok(layout.left >= 0 && layout.top >= 0 && layout.right <= viewport.width && layout.bottom <= viewport.height,
        `${name} fits the browsing viewport`); checks++;
      assert.equal(layout.closed, true, `${name} shadow root is inaccessible to normal page DOM`); checks++;
      assert.equal(layout.mode, 'closed', `${name} uses a closed shadow root`); checks++;
      assert.ok(layout.sheets > 0 && layout.styleElements === 0, `${name} uses adopted CSSStyleSheet styling despite page style CSP`); checks++;
      assert.equal(layout.pageInput, null, `${name} search input is absent from the website document`); checks++;
      assert.ok(!layout.markup.includes(layout.token) && !layout.frameURL.includes(layout.token), `${name} keeps authorization tokens out of DOM and frame URL`); checks++;
      const inner = await frame.evaluate(() => {
        const panel = document.querySelector('.scout').getBoundingClientRect();
        return { width: panel.width, height: panel.height, queryFont: getComputedStyle(document.querySelector('#query')).fontSize,
          footerHeight: document.querySelector('.result-footer').getBoundingClientRect().height,
          header: document.querySelectorAll('.toolbar, h1').length,
          controls: [...document.querySelectorAll('#query, #refresh, #settings')].map(node => {
            const rect = node.getBoundingClientRect();
            return rect.left >= 0 && rect.top >= 0 && rect.right <= innerWidth && rect.bottom <= innerHeight;
          }) };
      });
      near(inner.width, layout.width, `${name} frame fills native panel width`);
      near(inner.height, layout.height, `${name} frame fills native panel height`);
      assert.equal(inner.queryFont, '21px', `${name} retains native query typography`); checks++;
      assert.equal(inner.footerHeight, 43, `${name} retains native footer height`); checks++;
      assert.equal(inner.header, 0, `${name} adds no brand header`); checks++;
      assert.ok(inner.controls.every(Boolean), `${name} keeps controls inside the native frame`); checks++;
      await checkRowContrast(frame, name, '.result.is-selected', 'selected');
      await frame.locator('.result:not(.is-selected)').first().hover();
      await checkRowContrast(frame, name, '.result:hover:not(.is-selected)', 'hovered');
      await page.mouse.move(0, 0);
      assert.equal(await page.evaluate(() => testFixture.violations.length), violationsBeforeOverlay,
        `${name} mounting adds no CSP violations`); checks++;
      assert.deepEqual(await websiteSnapshot(page), original, `${name} leaves the website content and location unchanged`); checks++;
      const firstToken = layout.token;
      await page.evaluate(async token => {
        await testFixture.deliverOverlay({ type: 'overlayOpen', token }, { id: 'foreign-extension' });
        await testFixture.deliverOverlay({ type: 'overlayOpen', token: 'd'.repeat(64) });
      }, firstToken);
      assert.equal(await page.locator('[data-tab-scout-overlay]').count(), 1, `${name} stale or forged opens preserve the current authorized overlay`); checks++;
      assert.equal(await frame.locator('#query').inputValue(), 'cafe', `${name} rejected opens preserve the existing typed query`); checks++;
      await page.evaluate(token => testFixture.deliverOverlay({ type: 'overlayDismiss', token }, { id: 'foreign-extension' }), firstToken);
      await page.evaluate(() => testFixture.deliverOverlay({ type: 'overlayDismiss', token: 'c'.repeat(64) }));
      assert.equal(await page.locator('[data-tab-scout-overlay]').count(), 1, `${name} ignores forged and stale dismissals`); checks++;
      await page.screenshot({ path: resolve(output, `${name}.png`) });
      const focusOrder = [];
      for (let step = 0; step < 4; step++) {
        await page.keyboard.press('Tab');
        focusOrder.push(await frame.evaluate(() => document.activeElement?.id));
      }
      assert.deepEqual(focusOrder, ['clear-search', 'refresh', 'settings', 'query'], `${name} Tab cycles only through native search controls`); checks++;
      await page.keyboard.press('Shift+Tab');
      assert.equal(await frame.evaluate(() => document.activeElement?.id), 'settings', `${name} Shift+Tab wraps backwards inside the frame`); checks++;
      assert.deepEqual(await page.evaluate(() => testFixture.websiteKeys), [], `${name} keyboard navigation remains private from the website`); checks++;
      await page.keyboard.press('Escape');
      await page.locator('[data-tab-scout-overlay]').waitFor({ state: 'detached' });
      assert.equal(await page.evaluate(() => document.activeElement?.id), 'website-input', `${name} Escape from a footer control restores original website focus`); checks++;
      await page.evaluate(token => testFixture.deliverOverlay({ type: 'overlayOpen', token }), firstToken);
      assert.equal(await page.locator('[data-tab-scout-overlay]').count(), 0, `${name} a revoked token cannot reopen the overlay`); checks++;
      await page.evaluate(() => browser.commands.onCommand.emit('toggle-search'));
      const reopened = await waitForOverlay(page);
      assert.equal(await reopened.locator('#query').inputValue(), '', `${name} reopening starts with a fresh query`); checks++;
      assert.notEqual(await page.evaluate(() => testFixture.lastDelivery.token), firstToken, `${name} reopening uses a fresh token`); checks++;
      await page.keyboard.press('Tab');
      assert.equal(await reopened.evaluate(() => document.activeElement?.id), 'refresh', `${name} the empty-query tab order skips the hidden clear control`); checks++;
      await page.evaluate(() => browser.commands.onCommand.emit('toggle-search'));
      await page.locator('[data-tab-scout-overlay]').waitFor({ state: 'detached' });
      assert.equal(await page.evaluate(() => document.activeElement?.id), 'website-input', `${name} toggling the shortcut dismisses and restores original focus`); checks++;
      assert.deepEqual(await page.evaluate(() => ({ updates: testFixture.updates, creates: testFixture.creates, removed: testFixture.removed })),
        { updates: [], creates: [], removed: [] }, `${name} opening, dismissing and reopening never create or modify tabs`); checks++;
      assert.deepEqual(await websiteSnapshot(page), original, `${name} dismissal and reopening preserve website state`); checks++;
      assert.deepEqual(overlay.errors, [], `${name} has no script errors`); checks++;
      await overlay.context.close();
    }
    for (const focusErrorMode of ['parent', 'child']) {
      const focusOverlay = await overlayPageFor({ width: 1280, height: 900 }, 'light', false, false, focusErrorMode);
      const { page } = focusOverlay;
      const original = await websiteSnapshot(page);
      await page.evaluate(() => browser.commands.onCommand.emit('toggle-search'));
      await page.waitForFunction(() => testFixture.overlayReplies.some(reply => reply.message.type === 'overlayOpen'));
      assert.equal(await page.evaluate(() => testFixture.overlayReplies.find(reply => reply.message.type === 'overlayOpen').result?.ok), true,
        `${focusErrorMode} blocked window focus does not reject authenticated overlay readiness`); checks++;
      assert.ok(await page.evaluate(mode => testFixture.focusErrors.includes(mode === 'parent' ? 'parent-to-frame' : 'child-self'), focusErrorMode),
        `${focusErrorMode} fixture exercises a real blocked focus call`); checks++;
      assert.equal(await page.locator('[data-tab-scout-overlay]').count(), 1,
        `${focusErrorMode} blocked window focus retains the ready overlay host`); checks++;
      assert.deepEqual(await page.evaluate(() => testFixture.popupOpens), [],
        `${focusErrorMode} blocked window focus does not open a popup fallback`); checks++;
      const frame = await waitForOverlay(page);
      await page.keyboard.type('cafe');
      await frame.locator('.result-title', { hasText: 'Caf\u00e9 Research' }).waitFor();
      assert.equal(await frame.locator('#query').inputValue(), 'cafe',
        `${focusErrorMode} blocked window focus still accepts immediate typing without a click`); checks++;
      assert.equal(await frame.evaluate(() => document.activeElement?.id), 'query',
        `${focusErrorMode} blocked window focus leaves the search field focused`); checks++;
      assert.deepEqual(await page.evaluate(() => testFixture.websiteKeys), [],
        `${focusErrorMode} blocked window focus keeps typing private from the website`); checks++;
      assert.deepEqual(await websiteSnapshot(page), original,
        `${focusErrorMode} blocked window focus leaves the website unchanged`); checks++;
      await page.keyboard.press('Escape');
      await page.locator('[data-tab-scout-overlay]').waitFor({ state: 'detached' });
      assert.deepEqual(await page.evaluate(() => ({ updates: testFixture.updates, creates: testFixture.creates, removed: testFixture.removed })),
        { updates: [], creates: [], removed: [] }, `${focusErrorMode} blocked window focus never changes tabs`); checks++;
      assert.deepEqual(focusOverlay.errors, [], `${focusErrorMode} blocked window focus has no uncaught script errors`); checks++;
      await focusOverlay.context.close();
    }
    const blockedOverlay = await overlayPageFor({ width: 1280, height: 900 }, 'light', true);
    const blockedOriginal = await websiteSnapshot(blockedOverlay.page);
    await blockedOverlay.page.evaluate(() => browser.commands.onCommand.emit('toggle-search'));
    await blockedOverlay.page.waitForFunction(() => testFixture.overlayReplies.some(reply => reply.message.type === 'overlayOpen' && reply.result?.ok === false));
    await blockedOverlay.page.waitForFunction(() => testFixture.popupPresented);
    assert.equal(await blockedOverlay.page.locator('[data-tab-scout-overlay]').count(), 0, 'frame-blocking CSP closes the failed overlay instead of bypassing page policy'); checks++;
    assert.deepEqual(await blockedOverlay.page.evaluate(() => testFixture.openedPopup), { windowId: 4 }, 'frame-blocking CSP falls back to the Safari toolbar popup in the source window'); checks++;
    assert.deepEqual(await blockedOverlay.page.evaluate(() => testFixture.popupOpens), [{ windowId: 4 }],
      'CSP fallback opens the static toolbar popup exactly once without configuration mutation'); checks++;
    assert.equal(JSON.parse(readFileSync(resolve(root, 'manifest.json'), 'utf8')).action.default_popup, 'popup.html',
      'the toolbar popup is statically registered in the manifest'); checks++;
    assert.deepEqual(await websiteSnapshot(blockedOverlay.page), blockedOriginal, 'blocked overlay leaves the website unchanged'); checks++;
    assert.equal(await blockedOverlay.page.evaluate(() => testFixture.creates.length), 0, 'blocked overlay never creates a fallback tab'); checks++;
    assert.deepEqual(blockedOverlay.errors, [], 'blocked overlay has no script errors'); checks++;
    await blockedOverlay.context.close();
    const activatingOverlay = await overlayPageFor({ width: 1280, height: 900 });
    const activatingOriginal = await websiteSnapshot(activatingOverlay.page);
    await activatingOverlay.page.evaluate(() => browser.commands.onCommand.emit('toggle-search'));
    const activatingFrame = await waitForOverlay(activatingOverlay.page);
    await activatingOverlay.page.keyboard.type('cafe');
    await activatingFrame.locator('.result-title', { hasText: 'Caf\u00e9 Research' }).waitFor();
    await activatingOverlay.page.keyboard.press('Enter');
    await activatingOverlay.page.locator('[data-tab-scout-overlay]').waitFor({ state: 'detached' });
    assert.equal(await activatingOverlay.page.evaluate(() => testFixture.updates[0].id), 2, 'overlay Enter switches to the matched existing tab'); checks++;
    assert.equal(await activatingOverlay.page.evaluate(() => testFixture.focused[0].id), 7, 'overlay Enter focuses the matched Safari window'); checks++;
    assert.deepEqual(await activatingOverlay.page.evaluate(() => testFixture.removed), [], 'switching from an overlay never removes its source website tab'); checks++;
    assert.deepEqual(await activatingOverlay.page.evaluate(() => testFixture.creates), [], 'switching to an existing tab never creates a duplicate'); checks++;
    assert.equal(await activatingOverlay.page.evaluate(() => testFixture.store.choices.length), 1, 'overlay accepted choices retain local ranking history'); checks++;
    assert.deepEqual(await websiteSnapshot(activatingOverlay.page), activatingOriginal, 'overlay activation leaves the source website unchanged'); checks++;
    assert.deepEqual(await activatingOverlay.page.evaluate(() => testFixture.websiteKeys), [], 'overlay activation keys never reach the website'); checks++;
    assert.deepEqual(activatingOverlay.errors, [], 'overlay activation has no script errors'); checks++;
    await activatingOverlay.context.close();
    const firstKeyOverlay = await overlayPageFor({ width: 1280, height: 900 });
    const firstKeyOriginal = await websiteSnapshot(firstKeyOverlay.page);
    await firstKeyOverlay.page.evaluate(() => browser.commands.onCommand.emit('toggle-search'));
    const firstKeyFrame = await waitForOverlay(firstKeyOverlay.page);
    const focusFrameBody = () => firstKeyFrame.evaluate(() => {
      document.querySelector('#query').blur();
      document.body.tabIndex = -1;
      document.body.focus();
      return document.activeElement === document.body;
    });
    assert.equal(await focusFrameBody(), true, 'first-key fixture reproduces an active frame with its body, not input, focused'); checks++;
    await firstKeyFrame.evaluate(() => document.body.dispatchEvent(new KeyboardEvent('keydown', { key: 'x', bubbles: true })));
    assert.equal(await firstKeyFrame.locator('#query').inputValue(), '', 'untrusted synthetic printable events cannot trigger first-key insertion'); checks++;
    assert.equal(await firstKeyFrame.evaluate(() => document.activeElement === document.body), true,
      'untrusted synthetic printable events cannot supply the focus gesture'); checks++;
    await firstKeyFrame.evaluate(() => { document.querySelector('#query').readOnly = true; });
    await firstKeyOverlay.page.keyboard.press('r');
    assert.equal(await firstKeyFrame.locator('#query').inputValue(), '', 'readonly search ignores printable frame-body bootstrap keys'); checks++;
    assert.equal(await firstKeyFrame.evaluate(() => document.activeElement === document.body), true,
      'readonly search does not move body focus while activating'); checks++;
    await firstKeyFrame.evaluate(() => {
      document.querySelector('#query').readOnly = false;
      // Stop the browser's default paste after recording the production handler's decision.
      window.testSuppressPaste = true;
    });
    await firstKeyOverlay.page.keyboard.press('Meta+v');
    assert.deepEqual(await firstKeyFrame.evaluate(() => testPasteKey), { defaultPrevented: false, active: 'query' },
      'Cmd+V from the frame body focuses search without cancelling the browser paste action'); checks++;
    assert.equal(await firstKeyFrame.locator('#query').inputValue(), '', 'Cmd+V focus bootstrap never inserts a literal v'); checks++;
    await firstKeyFrame.evaluate(() => { window.testSuppressPaste = false; });
    assert.equal(await focusFrameBody(), true, 'printable bootstrap still starts with the frame body focused after paste recovery'); checks++;
    await firstKeyOverlay.page.keyboard.press('c');
    assert.deepEqual(await firstKeyFrame.evaluate(() => testFrameKeys.find(event => event.key === 'c')),
      { key: 'c', trusted: true, target: 'BODY', active: 'BODY' }, 'first-key regression reaches the real frame-body trusted-key path'); checks++;
    assert.equal(await firstKeyFrame.locator('#query').inputValue(), 'c', 'first trusted printable key is retained exactly once when frame-body focus moves to the input'); checks++;
    assert.equal(await firstKeyFrame.evaluate(() => document.activeElement?.id), 'query', 'first printable key focuses the query inside the frame'); checks++;
    await firstKeyOverlay.page.keyboard.type('afe');
    await firstKeyFrame.locator('.result-title', { hasText: 'Caf\u00e9 Research' }).waitFor();
    assert.equal(await firstKeyFrame.locator('#query').inputValue(), 'cafe', 'typing continues normally after first-key focus recovery'); checks++;
    const firstKeySelection = await firstKeyFrame.locator('.is-selected').getAttribute('data-row-id');
    assert.equal(await focusFrameBody(), true, 'ArrowDown regression starts with the frame body focused'); checks++;
    await firstKeyOverlay.page.keyboard.press('ArrowDown');
    assert.notEqual(await firstKeyFrame.locator('.is-selected').getAttribute('data-row-id'), firstKeySelection,
      'ArrowDown from the frame body advances the real search selection'); checks++;
    assert.equal(await firstKeyFrame.evaluate(() => document.activeElement?.id), 'query', 'ArrowDown from the frame body focuses the query'); checks++;
    assert.equal(await focusFrameBody(), true, 'ArrowUp regression starts with the frame body focused'); checks++;
    await firstKeyOverlay.page.keyboard.press('ArrowUp');
    assert.equal(await firstKeyFrame.locator('.is-selected').getAttribute('data-row-id'), firstKeySelection,
      'ArrowUp from the frame body restores the original selected result'); checks++;
    assert.deepEqual(await firstKeyOverlay.page.evaluate(() => ({ updates: testFixture.updates, creates: testFixture.creates, removed: testFixture.removed })),
      { updates: [], creates: [], removed: [] }, 'first printable key and arrow recovery never act on Safari tabs'); checks++;
    assert.equal(await focusFrameBody(), true, 'Enter regression starts with the frame body focused'); checks++;
    await firstKeyOverlay.page.keyboard.press('Enter');
    await firstKeyOverlay.page.locator('[data-tab-scout-overlay]').waitFor({ state: 'detached' });
    assert.equal(await firstKeyOverlay.page.evaluate(() => testFixture.updates[0].id), 2, 'Enter from the frame body activates the selected existing tab'); checks++;
    assert.deepEqual(await firstKeyOverlay.page.evaluate(() => testFixture.creates), [], 'Enter focus recovery creates no duplicate tab'); checks++;
    assert.deepEqual(await firstKeyOverlay.page.evaluate(() => testFixture.websiteKeys), [], 'first-key, arrow and Enter recovery keep all key events private from the parent website'); checks++;
    assert.deepEqual(await websiteSnapshot(firstKeyOverlay.page), firstKeyOriginal, 'first-key focus recovery leaves the underlying website unchanged'); checks++;
    assert.deepEqual(firstKeyOverlay.errors, [], 'first-key focus recovery has no script errors'); checks++;
    await firstKeyOverlay.context.close();
    const heartbeatOverlay = await overlayPageFor({ width: 1280, height: 900 }, 'light', false, true);
    const heartbeatOriginal = await websiteSnapshot(heartbeatOverlay.page);
    await heartbeatOverlay.page.evaluate(() => browser.commands.onCommand.emit('toggle-search'));
    await waitForOverlay(heartbeatOverlay.page);
    await heartbeatOverlay.page.waitForFunction(() => testFixture.overlayReplies.some(reply => reply.message.type === 'overlayOpen' && reply.result?.ok));
    const initialStateCalls = await heartbeatOverlay.page.evaluate(() => testFixture.messages.filter(message => message.type === 'state').length);
    await heartbeatOverlay.page.clock.fastForward(20001);
    assert.equal(await heartbeatOverlay.page.evaluate(() => testFixture.messages.filter(message => message.type === 'state').length),
      initialStateCalls + 1, 'an open foreground overlay validates its token every 20 seconds'); checks++;
    assert.equal(await heartbeatOverlay.page.locator('[data-tab-scout-overlay]').count(), 1,
      'a successful heartbeat keeps the foreground overlay mounted'); checks++;
    await heartbeatOverlay.page.evaluate(() => { testFixture.rejectOverlayState = true; });
    await heartbeatOverlay.page.clock.fastForward(20001);
    await heartbeatOverlay.page.locator('[data-tab-scout-overlay]').waitFor({ state: 'detached' });
    assert.deepEqual(await websiteSnapshot(heartbeatOverlay.page), heartbeatOriginal,
      'a failed heartbeat after worker restart closes the overlay without changing the source website'); checks++;
    assert.equal(await heartbeatOverlay.page.evaluate(() => document.activeElement?.id), 'website-input',
      'a failed heartbeat restores website focus'); checks++;
    assert.deepEqual(await heartbeatOverlay.page.evaluate(() => ({ opened: testFixture.openedPopup ?? null,
      calls: testFixture.popupOpens })), { opened: null, calls: [] },
      'a failed foreground heartbeat never enters a popup fallback loop'); checks++;
    assert.deepEqual(await heartbeatOverlay.page.evaluate(() => testFixture.creates), [],
      'a failed foreground heartbeat never opens a fallback tab'); checks++;
    const failedStateCalls = await heartbeatOverlay.page.evaluate(() => testFixture.messages.filter(message => message.type === 'state').length);
    await heartbeatOverlay.page.clock.fastForward(60001);
    assert.equal(await heartbeatOverlay.page.evaluate(() => testFixture.messages.filter(message => message.type === 'state').length),
      failedStateCalls, 'failed-heartbeat dismissal aborts subsequent interval checks'); checks++;
    assert.deepEqual(heartbeatOverlay.errors, [], 'foreground heartbeat recovery has no script errors'); checks++;
    await heartbeatOverlay.context.close();
    const dismissedHeartbeat = await overlayPageFor({ width: 1280, height: 900 }, 'light', false, true);
    await dismissedHeartbeat.page.evaluate(() => browser.commands.onCommand.emit('toggle-search'));
    await waitForOverlay(dismissedHeartbeat.page);
    await dismissedHeartbeat.page.waitForFunction(() => testFixture.overlayReplies.some(reply => reply.message.type === 'overlayOpen' && reply.result?.ok));
    await dismissedHeartbeat.page.keyboard.press('Escape');
    await dismissedHeartbeat.page.locator('[data-tab-scout-overlay]').waitFor({ state: 'detached' });
    const dismissedStateCalls = await dismissedHeartbeat.page.evaluate(() => testFixture.messages.filter(message => message.type === 'state').length);
    await dismissedHeartbeat.page.clock.fastForward(60001);
    assert.equal(await dismissedHeartbeat.page.evaluate(() => testFixture.messages.filter(message => message.type === 'state').length),
      dismissedStateCalls, 'closing before the first heartbeat clears its timer without further state requests'); checks++;
    assert.deepEqual(await dismissedHeartbeat.page.evaluate(() => ({ opened: testFixture.openedPopup ?? null,
      calls: testFixture.popupOpens })), { opened: null, calls: [] },
      'early dismissal never reopens a toolbar popup'); checks++;
    assert.deepEqual(dismissedHeartbeat.errors, [], 'early heartbeat dismissal has no script errors'); checks++;
    await dismissedHeartbeat.context.close();
    for (const colorScheme of ['light', 'dark']) {
      for (const [surfaceName, surface, viewport] of [
        ['desktop', 'newtab', { width: 1280, height: 900 }],
        ['narrow', 'newtab', { width: 320, height: 700 }],
        ['short', 'newtab', { width: 960, height: 320 }],
        ['narrow-short', 'newtab', { width: 320, height: 320 }],
        ['popup', 'popup', { width: 660, height: 440 }],
        ['popup-narrow', 'popup', { width: 320, height: 440 }],
        ['popup-short', 'popup', { width: 320, height: 320 }],
      ]) {
        const name = `${surfaceName}-${colorScheme}`;
        const { page, context, errors } = await pageFor(surface, viewport, false, false, colorScheme);
        await checkNativePalette(page, name, surface, viewport);
        await page.screenshot({ path: resolve(output, `${name}.png`), fullPage: surface !== 'popup' });
        assert.deepEqual(errors, [], `${name} has no runtime errors`); checks++;
        await context.close();
      }
    }
    const bootstrap = await pageFor('popup', { width: 100, height: 60 });
    for (const [name, viewport] of [
      ['popup-tiny-bootstrap', { width: 100, height: 60 }],
      ['popup-expanded-bootstrap', { width: 660, height: 440 }],
      ['popup-short-bootstrap', { width: 320, height: 320 }],
      ['popup-wide-bootstrap', { width: 800, height: 600 }],
    ]) {
      await bootstrap.page.setViewportSize(viewport);
      await checkPopupPreferredSize(bootstrap.page, name);
      const panel = await bootstrap.page.locator('.scout').boundingBox();
      near(panel.width, Math.min(660, viewport.width), `${name} bounds inner palette width without shrinking the preferred document`);
      near(panel.height, Math.min(440, viewport.height), `${name} bounds inner palette height without shrinking the preferred document`);
    }
    assert.deepEqual(bootstrap.errors, [], 'popup preferred-size bootstrapping has no runtime errors'); checks++;
    await bootstrap.context.close();
    for (const [name, viewport, colorScheme] of [
      ['settings-narrow-light', { width: 320, height: 700 }, 'light'],
      ['settings-narrow-dark', { width: 320, height: 700 }, 'dark'],
      ['settings-desktop-light', { width: 700, height: 700 }, 'light'],
    ]) {
      const settings = await pageFor('options', viewport, false, false, colorScheme);
      const layout = await settings.page.evaluate(() => ({ width: document.documentElement.scrollWidth,
        controls: [...document.querySelectorAll('button, input, select')].filter(node => !node.hidden).map(node => {
          const rect = node.getBoundingClientRect(); return { width: rect.width, left: rect.left, right: rect.right };
        }) }));
      assert.ok(layout.width <= viewport.width, `${name} settings do not overflow horizontally`); checks++;
      assert.ok(layout.controls.every(rect => rect.width > 0 && rect.left >= 0 && rect.right <= viewport.width + 1),
        `${name} settings controls fit`); checks++;
      assert.equal((await settings.page.locator('.settings-page').boundingBox()).y, viewport.width <= 420 ? 24 : 40,
        `${name} settings keep their original top margin`); checks++;
      assert.equal(await settings.page.locator('.toolbar h1').isVisible(), true, `${name} settings retain the settings header`); checks++;
      await settings.page.screenshot({ path: resolve(output, `${name}.png`), fullPage: true });
      assert.deepEqual(settings.errors, [], `${name} settings have no runtime errors`); checks++;
      await settings.context.close();
    }
    const resizing = await pageFor('newtab', { width: 1280, height: 900 });
    await resizing.page.locator('#query').fill('cafe');
    await resizing.page.locator('.result-title', { hasText: 'Caf\u00e9 Research' }).waitFor();
    const resultTitles = await resizing.page.locator('.result-title').allTextContents();
    const selectedTitle = await resizing.page.locator('.is-selected .result-title').textContent();
    for (const [name, viewport] of [
      ['resized-narrow', { width: 320, height: 700 }],
      ['resized-wide-tall', { width: 1920, height: 1440 }],
      ['resized-short', { width: 960, height: 320 }],
      ['resized-desktop', { width: 1280, height: 900 }],
    ]) {
      await resizing.page.setViewportSize(viewport);
      await checkNativePalette(resizing.page, name, 'newtab', viewport, false);
      assert.equal(await resizing.page.locator('#query').inputValue(), 'cafe', `${name} preserves the query`); checks++;
      assert.deepEqual(await resizing.page.locator('.result-title').allTextContents(), resultTitles, `${name} preserves results`); checks++;
      assert.equal(await resizing.page.locator('.is-selected .result-title').textContent(), selectedTitle, `${name} preserves selection`); checks++;
      await resizing.page.screenshot({ path: resolve(output, `${name}.png`), fullPage: true });
    }
    assert.deepEqual(await resizing.page.evaluate(() => ({ updates: testFixture.updates, creates: testFixture.creates, removed: testFixture.removed })),
      { updates: [], creates: [], removed: [] }, 'resizing does not act on Safari tabs'); checks++;
    assert.deepEqual(resizing.errors, []); checks++;
    await resizing.context.close();
    const controls = await pageFor('newtab', { width: 1280, height: 900 });
    const originalSelection = await controls.page.locator('.is-selected').getAttribute('data-row-id');
    await controls.page.locator('#query').press('ArrowDown');
    assert.notEqual(await controls.page.locator('.is-selected').getAttribute('data-row-id'), originalSelection,
      'ArrowDown advances selection'); checks++;
    await controls.page.locator('#query').press('ArrowUp');
    assert.equal(await controls.page.locator('.is-selected').getAttribute('data-row-id'), originalSelection,
      'ArrowUp restores selection'); checks++;
    assert.equal(await controls.page.locator('#query').evaluate(node => document.activeElement === node), true,
      'keyboard selection keeps the search focused'); checks++;
    assert.equal(await controls.page.locator('#query').getAttribute('aria-activedescendant'),
      await controls.page.locator('.is-selected').getAttribute('id'), 'input identifies the selected accessible result'); checks++;
    await controls.page.locator('#query').fill('cafe');
    await controls.page.locator('.result-title', { hasText: 'Caf\u00e9 Research' }).waitFor();
    await controls.page.locator('#clear-search').click();
    await controls.page.locator('.result-title', { hasText: 'Example Guide' }).waitFor();
    assert.equal(await controls.page.locator('#query').inputValue(), '', 'clear control resets the query'); checks++;
    assert.equal(await controls.page.locator('#clear-search').isHidden(), true, 'clear control hides after clearing'); checks++;
    assert.equal(await controls.page.locator('#query').evaluate(node => document.activeElement === node), true,
      'clear control returns focus to search'); checks++;
    const queriesBeforeRefresh = await controls.page.evaluate(() => testFixture.queries.length);
    const titlesBeforeRefresh = await controls.page.locator('.result-title').allTextContents();
    const selectedBeforeRefresh = await controls.page.locator('.is-selected').getAttribute('data-row-id');
    await controls.page.locator('#refresh:enabled').click();
    await controls.page.waitForFunction(count => testFixture.queries.length > count, queriesBeforeRefresh);
    await controls.page.locator('#refresh:enabled').waitFor();
    assert.deepEqual(await controls.page.locator('.result-title').allTextContents(), titlesBeforeRefresh,
      'footer refresh preserves result rows'); checks++;
    assert.equal(await controls.page.locator('.is-selected').getAttribute('data-row-id'), selectedBeforeRefresh,
      'footer refresh preserves selection'); checks++;
    assert.equal(await controls.page.locator('#query').evaluate(node => document.activeElement === node), true,
      'footer refresh returns focus to search'); checks++;
    await controls.page.locator('#settings').click();
    assert.equal(await controls.page.evaluate(() => testFixture.openedSettings), true, 'footer settings opens extension settings'); checks++;
    assert.deepEqual(await controls.page.evaluate(() => ({ updates: testFixture.updates, creates: testFixture.creates, removed: testFixture.removed })),
      { updates: [], creates: [], removed: [] }, 'selection and footer controls never act on tabs'); checks++;
    assert.deepEqual(controls.errors, [], 'footer controls have no runtime errors'); checks++;
    await controls.context.close();
    const { page, context, errors } = await pageFor('newtab', { width: 1000, height: 800 });
    await page.locator('#query').fill('cafe');
    await page.locator('.result-title', { hasText: 'Caf\u00e9 Research' }).waitFor();
    await page.locator('#query').press('Enter');
    await page.waitForFunction(() => testFixture.removed.length === 1);
    assert.deepEqual(await page.evaluate(() => testFixture.removed), [900]); checks++;
    assert.equal(await page.evaluate(() => testFixture.focused[0].id), 7); checks++;
    assert.equal(await page.evaluate(() => testFixture.store.choices.length), 1); checks++;
    await context.close();

    const direct = await pageFor('newtab', { width: 1000, height: 800 });
    await direct.page.locator('#query').fill('https://example.edu/new');
    await direct.page.locator('.result-title', { hasText: 'Open https://example.edu/new' }).waitFor();
    await direct.page.locator('#query').press('Enter');
    await direct.page.waitForFunction(() => testFixture.updates.length > 0);
    assert.equal(await direct.page.evaluate(() => testFixture.updates[0].id), 900); checks++;
    assert.equal(await direct.page.evaluate(() => testFixture.creates.length), 0); checks++;
    await direct.context.close();

    const popup = await pageFor('popup', { width: 660, height: 440 });
    await popup.page.locator('#query').fill('cafe');
    await popup.page.locator('.result-title', { hasText: 'Caf\u00e9 Research' }).waitFor();
    await popup.page.locator('#query').press('Enter');
    await popup.page.waitForFunction(() => testFixture.closed);
    assert.equal(await popup.page.evaluate(() => testFixture.removed.length), 0); checks++;
    await popup.context.close();

    const options = await pageFor('options', { width: 700, height: 700 });
    assert.equal((await options.page.locator('.settings-page').boundingBox()).y, 40, 'desktop settings retain their existing top margin'); checks++;
    await options.page.locator('#engine').selectOption('duckduckgo');
    await options.page.waitForFunction(() => testFixture.store.settings.engine === 'duckduckgo'); checks++;
    await options.context.close();

    const predictions = await pageFor('newtab', { width: 1000, height: 800 }, false, true);
    await predictions.page.locator('#query').fill('weather');
    await predictions.page.locator('.result-title', { hasText: 'weather nearby' }).waitFor();
    assert.equal(await predictions.page.locator('.is-selected .result-title').textContent(), 'Search for weather'); checks++;
    await predictions.page.locator('#query').press('Enter');
    await predictions.page.waitForFunction(() => testFixture.updates.length > 0);
    assert.equal(await predictions.page.evaluate(() => new URL(testFixture.updates[0].value.url).searchParams.get('q')), 'weather'); checks++;
    await predictions.context.close();

    const privatePage = await pageFor('newtab', { width: 1000, height: 800 }, true, true);
    assert.equal(await privatePage.page.locator('#private-badge').isVisible(), true); checks++;
    await privatePage.page.locator('#query').fill('weather');
    await privatePage.page.locator('.result-title', { hasText: 'Search for weather' }).waitFor();
    await privatePage.page.waitForTimeout(250);
    assert.equal(await privatePage.page.evaluate(() => testFixture.requests.length), 0); checks++;
    await privatePage.page.locator('#query').press('Meta+Enter');
    await privatePage.page.waitForFunction(() => testFixture.creates.length === 1);
    assert.equal(await privatePage.page.evaluate(() => testFixture.creates[0].windowId), 4); checks++;
    assert.equal(await privatePage.page.evaluate(() => testFixture.store.choices.length), 0); checks++;
    await privatePage.context.close();
    assert.deepEqual(errors, []); checks++;
    process.stdout.write(`Safari UI smoke: ${checks} checks passed; screenshots in ${output}\n`);
  } finally {
    if (browser) await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
}
main().catch(error => { console.error(error); process.exitCode = 1; });
