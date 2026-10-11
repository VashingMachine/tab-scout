const assert = require('node:assert/strict');
const { readFileSync, mkdirSync } = require('node:fs');
const { resolve, extname } = require('node:path');
const http = require('node:http');
const { chromium } = require(process.env.TAB_SCOUT_PLAYWRIGHT_MODULE || 'playwright');

const root = resolve(__dirname, '../SafariExtension');
const output = resolve(process.env.TAB_SCOUT_UI_OUTPUT_DIR || '.build/safari-ui');
const icon = readFileSync(resolve(root, 'icons/app-16.png')).toString('base64');
const mime = { '.html': 'text/html', '.mjs': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.png': 'image/png' };

function fixture({ icon, privateMode, suggestionsEnabled }) {
  const listeners = [];
  const events = () => ({ addListener() {} });
  const ownedPage = location.pathname === '/options.html' ? 'options.html' : 'newtab.html';
  const owned = { id: 900, windowId: 4, url: `${location.origin}/${ownedPage}`, title: 'Tab Scout', active: true, incognito: privateMode };
  const tabs = [owned,
    { id: 1, windowId: 4, url: 'https://example.com/guide', title: 'Example Guide', incognito: privateMode },
    { id: 2, windowId: 7, url: 'https://example.org/cafe', title: 'Caf\u00e9 Research', incognito: privateMode },
    { id: 3, windowId: 4, url: 'https://example.net/long', title: 'A very long fixture tab title '.repeat(12), incognito: privateMode },
  ];
  const store = { settings: { engine: 'google', googleSuggestions: suggestionsEnabled, rememberChoices: true }, choices: [] };
  let resolveReady;
  const ready = new Promise(resolve => { resolveReady = resolve; });
  window.testFixture = { tabs, store, updates: [], creates: [], removed: [], focused: [], requests: [], closed: false };
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
      onMessage: { addListener: listener => { listeners.push(listener); if (listener.length >= 2) resolveReady(); } },
      async sendMessage(message) {
        await ready;
        // search.mjs has a notification listener; only the background listener returns a reply.
        const sender = { id: 'fixture', url: location.href, tab: owned, incognito: privateMode };
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
      async query(filter = {}) { return tabs.filter(tab => !filter.active || tab.active).map(tab => ({ ...tab })); },
      async get(id) { const tab = tabs.find(tab => tab.id === id); if (!tab) throw Error('closed'); return { ...tab }; },
      async update(id, value) {
        const tab = tabs.find(tab => tab.id === id); if (!tab) throw Error('closed');
        window.testFixture.updates.push({ id, value }); Object.assign(tab, value); return { ...tab };
      },
      async create(value) { window.testFixture.creates.push(value); return { id: 999, ...value }; },
      async remove(id) { window.testFixture.removed.push(id); tabs.splice(tabs.findIndex(tab => tab.id === id), 1); },
      onCreated: events(), onRemoved: events(), onUpdated: events(),
    },
    windows: { async update(id, value) { window.testFixture.focused.push({ id, value }); } },
  };
}

async function main() {
  mkdirSync(output, { recursive: true });
  const server = http.createServer((request, response) => {
    try {
      const path = resolve(root, `.${new URL(request.url, 'http://localhost').pathname}`);
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
    async function pageFor(surface, viewport, privateMode = false, suggestionsEnabled = false) {
      const context = await browser.newContext({ viewport });
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
    async function checkNewTabPlacement(page, name, viewport) {
      const layout = await page.evaluate(() => {
        const bounds = node => {
          const rect = node.getBoundingClientRect();
          return { left: rect.left, right: rect.right, top: rect.top, bottom: rect.bottom,
            centerX: rect.left + rect.width / 2, centerY: rect.top + rect.height / 2 };
        };
        return { scout: bounds(document.querySelector('.scout')), height: document.documentElement.scrollHeight,
          controls: [...document.querySelectorAll('.toolbar button, #query, #clear-search, .result-footer')]
            .filter(node => !node.hidden).map(bounds) };
      });
      assert.ok(Math.abs(layout.scout.centerX - viewport.width / 2) <= 0.5, `${name} centers horizontally in the viewport`); checks++;
      assert.ok(Math.abs(layout.scout.centerY - viewport.height / 2) <= 0.5, `${name} centers vertically in the viewport`); checks++;
      assert.ok(layout.scout.left >= 0 && layout.scout.right <= viewport.width && layout.scout.top >= 0 && layout.scout.bottom <= viewport.height,
        `${name} search surface fits the viewport`); checks++;
      assert.ok(layout.controls.every(rect => rect.left >= 0 && rect.right <= viewport.width && rect.top >= 0 && rect.bottom <= viewport.height),
        `${name} toolbar, search, and footer remain visible`); checks++;
      assert.ok(layout.height <= viewport.height, `${name} has no document-level vertical overflow`); checks++;
    }
    for (const [name, surface, viewport] of [
      ['desktop', 'newtab', { width: 1280, height: 900 }],
      ['narrow', 'newtab', { width: 320, height: 700 }],
      ['popup', 'popup', { width: 520, height: 550 }],
      ['settings', 'options', { width: 320, height: 700 }],
    ]) {
      const { page, context, errors } = await pageFor(surface, viewport);
      const layout = await page.evaluate(() => ({ width: document.documentElement.scrollWidth, viewport: innerWidth,
        controls: [...document.querySelectorAll('button, input, select')].filter(node => !node.hidden).map(node => {
          const rect = node.getBoundingClientRect(); return { width: rect.width, left: rect.left, right: rect.right };
        }) }));
      assert.ok(layout.width <= layout.viewport, `${name} has no horizontal overflow`); checks++;
      assert.ok(layout.controls.every(rect => rect.width > 0 && rect.left >= 0 && rect.right <= viewport.width + 1), `${name} controls fit`); checks++;
      if (surface === 'newtab') await checkNewTabPlacement(page, name, viewport);
      if (surface === 'popup') {
        const bounds = await page.locator('.scout').boundingBox();
        assert.deepEqual(bounds, { x: 0, y: 0, width: 520, height: 500 }, 'popup remains anchored to its own surface'); checks++;
      }
      if (surface === 'options') {
        const bounds = await page.locator('.settings-page').boundingBox();
        assert.equal(bounds.y, 24, 'narrow settings retain their existing top margin'); checks++;
      }
      if (surface !== 'options') {
        assert.equal(await page.locator('#query').evaluate(node => document.activeElement === node), true); checks++;
        assert.ok(await page.locator('.result-image').first().evaluate(node => node.complete && node.naturalWidth > 0)); checks++;
      }
      await page.screenshot({ path: resolve(output, `${name}.png`), fullPage: true });
      assert.deepEqual(errors, []); checks++;
      await context.close();
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
      await checkNewTabPlacement(resizing.page, name, viewport);
      assert.equal(await resizing.page.locator('#query').inputValue(), 'cafe', `${name} preserves the query`); checks++;
      assert.deepEqual(await resizing.page.locator('.result-title').allTextContents(), resultTitles, `${name} preserves results`); checks++;
      assert.equal(await resizing.page.locator('.is-selected .result-title').textContent(), selectedTitle, `${name} preserves selection`); checks++;
      await resizing.page.screenshot({ path: resolve(output, `${name}.png`), fullPage: true });
    }
    assert.deepEqual(await resizing.page.evaluate(() => ({ updates: testFixture.updates, creates: testFixture.creates, removed: testFixture.removed })),
      { updates: [], creates: [], removed: [] }, 'resizing does not act on Safari tabs'); checks++;
    assert.deepEqual(resizing.errors, []); checks++;
    await resizing.context.close();
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

    const popup = await pageFor('popup', { width: 520, height: 550 });
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
