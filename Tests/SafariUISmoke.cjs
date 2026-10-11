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
  window.testFixture = { tabs, store, updates: [], creates: [], removed: [], focused: [], requests: [], queries: [], closed: false };
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
      async query(filter = {}) {
        window.testFixture.queries.push(filter);
        return tabs.filter(tab => !filter.active || tab.active).map(tab => ({ ...tab }));
      },
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
