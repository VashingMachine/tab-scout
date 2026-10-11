import test from 'node:test';
import assert from 'node:assert/strict';
import { address, buildRows, destination, eligibleSuggestionQuery, normalize, publicOrigin,
  rankTabs, rememberChoice, RETENTION_MS, sanitizeChoices, sanitizeSettings, targetIdentity, webURL } from '../../SafariExtension/core.mjs';

const now = 2000000000000;
const choice = (kind, value, extra = {}) => ({ kind, value, title: value, count: 1, lastUsed: now, ...extra });
const tab = (id, title, url) => ({ id, title, url, windowId: 1 });

test('normalization folds case, whitespace, combining accents and Polish letters', () => {
  assert.equal(normalize('  ŁÓDŹ\tTRIPS\n'), 'lodz trips');
  assert.equal(normalize('Cafe\u0301'), normalize('Café'));
  assert.equal(normalize(null), '');
});

test('empty destinations never navigate to about:blank', () => {
  for (const query of ['', ' ', '\t\n']) assert.equal(destination(query), null);
});

test('addresses preserve paths and query while bare hosts and localhost are handled', () => {
  const cases = [
    [' https://example.com/a?x=1&b=2#c ', 'https://example.com/a?x=1&b=2#c'],
    ['example.com/docs', 'https://example.com/docs'], ['localhost:3000/a', 'http://localhost:3000/a'],
    ['127.0.0.1:8080/a', 'http://127.0.0.1:8080/a'], ['https://EXAMPLE.com:443', 'https://example.com/'],
  ];
  for (const [query, expected] of cases) assert.equal(destination(query), expected);
  assert.equal(address('normal search'), null);
});

test('explicit provider choices encode search text without executing arbitrary schemes', () => {
  for (const engine of ['google', 'bing', 'duckduckgo']) {
    for (const query of ['Swift programming', 'a & b #c', 'javascript:alert(1)', 'file:///etc/passwd', 'favorites://', 'about:blank']) {
      const url = new URL(destination(query, engine));
      assert.equal(url.protocol, 'https:');
      assert.equal(url.searchParams.get('q'), query);
      assert.ok(url.hostname.includes(engine === 'duckduckgo' ? 'duckduckgo' : engine));
    }
  }
  assert.equal(new URL(destination('unknown engine', 'unexpected')).hostname, 'www.google.com');
});

test('HTTP identity normalizes authority but preserves path case and rejects credentials', () => {
  assert.equal(webURL('https://EXAMPLE.com:443/a'), 'https://example.com/a');
  assert.notEqual(targetIdentity({ kind: 'url', url: 'https://example.com/A' }), targetIdentity({ kind: 'url', url: 'https://example.com/a' }));
  assert.equal(targetIdentity({ kind: 'query', query: 'Łódź Trips' }), 'query:lodz trips');
  for (const value of ['javascript:alert(1)', 'file:///tmp/a', 'https://name:secret@example.com', 'https://example.com/\nprivate']) assert.equal(webURL(value), null);
  assert.equal(targetIdentity({ kind: 'url', url: 'about:blank' }), null);
});

test('favicon origins reject local, IP, port, non-HTTPS, credentials and internal domains', () => {
  assert.equal(publicOrigin('https://example.com/a?private=1#token'), 'https://example.com');
  for (const input of ['http://example.com', 'https://example.com:8443', 'https://localhost', 'https://a.local',
    'https://intranet', 'https://127.0.0.1', 'https://192.168.1.1', 'https://[::1]', 'https://[2606:4700::1]',
    'https://a.internal', 'https://a.test', 'https://a.onion', 'https://a..com', 'https://-a.com', 'https://x:y@example.com']) {
    assert.equal(publicOrigin(input), null, input);
  }
});

test('Google eligibility excludes obvious URLs, secrets, email, control characters and overlong input', () => {
  for (const input of ['', 'x', 'a'.repeat(121), 'weather\nforecast', 'https://example.com/private', 'example.com',
    'weather example.com/private', 'www.example.com', 'localhost:3000', '127.0.0.1', '[::1]', 'name@example.com',
    'password secret', 'api_key abc', 'Bearer abc', 'authorization: abc', 'file:///tmp', 'javascript:alert(1)',
    '~/private', '/private', 'C:\\private']) assert.equal(eligibleSuggestionQuery(input), null, input);
  assert.equal(eligibleSuggestionQuery(' weather forecast '), 'weather forecast');
  assert.equal(eligibleSuggestionQuery('Łódź weather'), 'Łódź weather');
});

test('settings use explicit validated engines and opt-in Google defaults', () => {
  assert.deepEqual(sanitizeSettings(null), { engine: 'google', googleSuggestions: false, rememberChoices: true });
  assert.deepEqual(sanitizeSettings({ engine: 'bing', googleSuggestions: true, rememberChoices: false }),
    { engine: 'bing', googleSuggestions: true, rememberChoices: false });
  assert.equal(sanitizeSettings({ engine: '__proto__', googleSuggestions: 'true' }).engine, 'google');
});

test('choices deduplicate canonical URLs and normalized phrases without inflating counts', () => {
  const records = sanitizeChoices([choice('query', 'Łódź trips', { count: 2, lastUsed: now - 1 }),
    choice('query', 'LODZ TRIPS', { count: 3 }), choice('url', 'https://EXAMPLE.com:443/', { count: 4 }),
    choice('url', 'https://example.com', { count: 2, lastUsed: now - 1 })], now);
  assert.equal(records.length, 2);
  assert.equal(records.find(item => item.kind === 'query').count, 3);
  assert.equal(records.find(item => item.kind === 'url').count, 4);
});

test('choice retention and malformed records remain bounded and recoverable', () => {
  const invalid = [null, {}, choice('url', 'file:///tmp/a'), choice('query', 'x'.repeat(121)),
    choice('query', 'control\ntext'), choice('query', 'future', { lastUsed: now + 1 }),
    choice('query', 'expired', { lastUsed: now - RETENTION_MS - 1 })];
  assert.deepEqual(sanitizeChoices(invalid, now), []);
  assert.equal(sanitizeChoices([choice('query', 'boundary', { lastUsed: now - RETENTION_MS })], now).length, 1);
  const records = [...Array.from({ length: 1200 }, (_, i) => choice('url', `https://example.com/${i}`, { lastUsed: now - i })),
    ...Array.from({ length: 600 }, (_, i) => choice('query', `query ${i}`, { lastUsed: now - i }))];
  const bounded = sanitizeChoices(records, now);
  assert.equal(bounded.filter(item => item.kind === 'url').length, 1000);
  assert.equal(bounded.filter(item => item.kind === 'query').length, 500);
  assert.equal(sanitizeChoices([choice('query', 'count', { count: Infinity, title: 'x'.repeat(900) })], now)[0].title.length, 512);
});

test('accepted choices increment only their existing identity and ignore empty actions', () => {
  const records = [choice('query', 'Łódź trips', { count: 2, lastUsed: now - 1 })];
  const updated = rememberChoice(records, { kind: 'query', query: ' LODZ TRIPS ' }, '', now);
  assert.equal(updated.length, 1); assert.equal(updated[0].count, 3); assert.equal(updated[0].lastUsed, now);
  assert.deepEqual(rememberChoice(updated, { kind: 'query', query: '' }, '', now), updated);
});

test('tab ranking requires all tokens and prioritizes textual relevance before usage', () => {
  const exact = tab(1, 'Other', 'https://work.com/');
  const popular = tab(2, 'Notes about work', 'https://example.com/');
  const partial = tab(3, 'Work docs', 'https://example.net/');
  const records = [choice('url', popular.url, { count: 100000 })];
  assert.deepEqual(rankTabs([popular, exact, partial], 'work', records, now), [exact, partial, popular]);
  assert.deepEqual(rankTabs([popular, exact, partial], 'work docs', records, now), [partial]);
  assert.deepEqual(rankTabs([popular, exact], 'missing', records, now), []);
});

test('equal text matches use recency/frequency then stable source order', () => {
  const old = tab(1, 'Work notes', 'https://old.example.com'); const fresh = tab(2, 'Work notes', 'https://fresh.example.com');
  assert.deepEqual(rankTabs([old, fresh], 'work', [choice('url', old.url, { lastUsed: now - 30 * 86400000 }),
    choice('url', fresh.url)], now), [fresh, old]);
  assert.deepEqual(rankTabs([old, fresh], 'work', [], now), [old, fresh]);
});

test('empty row stays first while all tabs and recent searches remain accessible', () => {
  const tabs = [tab(1, 'One', 'https://one.example.com'), tab(2, 'Two', 'https://two.example.com')];
  const rows = buildRows(tabs, ' \n ', [choice('query', 'recent query')], now);
  assert.equal(rows[0].kind, 'action'); assert.equal(rows[0].target.query, '');
  assert.equal(rows.filter(row => row.kind === 'tab').length, 2);
  assert.equal(rows.at(-1).kind, 'recent');
});

test('tab window ordinals follow the full inventory before query filtering and ranking', () => {
  const tabs = [
    { ...tab(1, 'Other topic', 'https://one.example.com/'), windowId: 80 },
    { ...tab(2, 'Work notes', 'https://two.example.com/'), windowId: 3 },
    { ...tab(3, 'Work notes', 'https://three.example.com/'), windowId: 80 },
    { ...tab(4, 'Work notes', 'https://four.example.com/'), windowId: 999 },
  ];
  const records = [choice('url', tabs[3].url, { count: 100 })];
  const rows = buildRows(tabs, 'work', records, now).filter(row => row.kind === 'tab');
  assert.deepEqual(rows.map(row => [row.target.tabId, row.windowNumber]), [[4, 3], [2, 2], [3, 1]]);
  const filtered = buildRows(tabs, 'four.example.com', [], now).filter(row => row.kind === 'tab');
  assert.deepEqual(filtered.map(row => [row.target.tabId, row.windowNumber]), [[4, 3]]);
  const all = buildRows(tabs, '', [], now).filter(row => row.kind === 'tab');
  assert.deepEqual(all.map(row => [row.target.tabId, row.windowNumber]), [[1, 1], [2, 2], [3, 1], [4, 3]]);
  assert.deepEqual(tabs.map(tab => tab.windowId), [80, 3, 80, 999]);
});

test('invalid or missing window IDs do not invent tab window ordinals or change targets', () => {
  const ids = [undefined, null, -1, 1.5, Infinity, NaN, '1', Number.MAX_SAFE_INTEGER + 1, 0, 12, 0];
  const tabs = ids.map((windowId, index) => ({ ...tab(index + 1, `Window ${index}`, `https://example.com/${index}`), windowId }));
  const original = structuredClone(tabs);
  const rows = buildRows(tabs, '', [], now).filter(row => row.kind === 'tab');
  for (let index = 0; index < 8; index++) assert.equal(Object.hasOwn(rows[index], 'windowNumber'), false);
  assert.deepEqual(rows.slice(8).map(row => row.windowNumber), [1, 2, 1]);
  rows.forEach((row, index) => {
    assert.deepEqual(row.target, { kind: 'tab', tabId: tabs[index].id });
    assert.equal(row.url, tabs[index].url); assert.equal(row.subtitle, tabs[index].url);
  });
  assert.deepEqual(tabs, original);
});

test('history recovers currently open URL under changed title instead of duplicate creation', () => {
  const current = { ...tab(1, 'Unrelated new title', 'https://example.com/'), windowId: 9 };
  const earlier = { ...tab(2, 'Unrelated other topic', 'https://other.example.com/'), windowId: 2 };
  const rows = buildRows([earlier, current], 'swift', [choice('url', 'https://example.com', { title: 'Swift docs' })], now);
  assert.equal(rows[0].kind, 'tab'); assert.equal(rows[0].target.tabId, 1);
  assert.equal(rows[0].windowNumber, 2);
  assert.equal(rows.filter(row => row.kind === 'history').length, 0);
  assert.equal(rows.at(-1).kind, 'action');
});

test('local recent and history result bounds leave raw typed action accessible', () => {
  const records = [...Array.from({ length: 20 }, (_, i) => choice('query', `work ${i}`)),
    ...Array.from({ length: 20 }, (_, i) => choice('url', `https://example.com/${i}`, { title: `Work ${i}` }))];
  const rows = buildRows([], 'work', records, now);
  assert.equal(rows.filter(row => row.kind === 'recent').length, 5);
  assert.equal(rows.filter(row => row.kind === 'history').length, 8);
  assert.equal(rows.at(-1).target.query, 'work');
});
