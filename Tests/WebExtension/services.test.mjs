import test from 'node:test';
import assert from 'node:assert/strict';
import { FaviconService, MemoryCache, PersistentFaviconCache, SuggestionsService, TabCache } from '../../SafariExtension/services.mjs';

const deferred = () => { let resolve; let reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; };
const reply = (data, mime = 'application/json', extra = {}) => new Response(data, { headers: { 'content-type': mime, ...extra } });
const prediction = query => reply(JSON.stringify([query, ['weather today', ['Weather tomorrow', '', []], 'WEATHER TODAY']]));
function png(width = 32, height = 32) {
  const bytes = new Uint8Array(24); bytes.set([137, 80, 78, 71, 13, 10, 26, 10]);
  const view = new DataView(bytes.buffer); view.setUint32(16, width); view.setUint32(20, height); return bytes;
}

test('LRU expires at boundary, evicts least-recently-used, and caches null', () => {
  let time = 0; const cache = new MemoryCache({ limit: 2, ttl: 10, now: () => time });
  cache.set('a', null); cache.set('b', 2); assert.equal(cache.get('a'), null); cache.set('c', 3);
  assert.equal(cache.get('b'), undefined); time = 10; assert.equal(cache.get('a'), undefined); assert.equal(cache.get('c'), undefined);
});

test('suggestions opt-in and incognito/privacy exclusions never touch network or cache', async () => {
  let calls = 0; const service = new SuggestionsService({ fetch: async () => { calls++; return prediction('weather'); } });
  for (const options of [{}, { enabled: true, incognito: true }]) assert.deepEqual(await service.get('weather', options), []);
  for (const query of ['example.com/private', 'secret abc', 'name@example.com', 'localhost:3000', '127.0.0.1', 'x']) {
    assert.deepEqual(await service.get(query, { enabled: true }), []);
  }
  assert.equal(calls, 0); assert.equal(service.cache.entries.size, 0);
});

test('suggestions coalesce, preserve provider order, deduplicate, and use cookie-free fixed endpoint', async () => {
  const pending = deferred(); const calls = [];
  const service = new SuggestionsService({ fetch: (url, options) => { calls.push({ url, options }); return pending.promise; } });
  const first = service.get('weather', { enabled: true }); const second = service.get(' WEATHER ', { enabled: true });
  assert.equal(calls.length, 1); pending.resolve(prediction('weather'));
  assert.deepEqual(await first, ['weather today', 'Weather tomorrow']); assert.deepEqual(await second, await first);
  assert.equal(new URL(calls[0].url).hostname, 'suggestqueries.google.com');
  assert.equal(new URL(calls[0].url).searchParams.get('q'), 'weather');
  assert.equal(calls[0].options.credentials, 'omit'); assert.equal(calls[0].options.referrerPolicy, 'no-referrer');
  assert.equal(calls[0].options.redirect, 'error'); assert.equal(calls[0].options.cache, 'no-store');
  assert.equal(calls[0].options.headers.Authorization, undefined);
});

test('suggestions cache is memory-only, bounded, fresh for five minutes', async () => {
  let time = 0; let count = 0;
  const service = new SuggestionsService({ now: () => time, fetch: async url => {
    count++; const query = new URL(url).searchParams.get('q'); return reply(JSON.stringify([query, [`${query} result`]]));
  } });
  await service.get('weather', { enabled: true }); time = 299999; await service.get('weather', { enabled: true }); assert.equal(count, 1);
  time = 300000; await service.get('weather', { enabled: true }); assert.equal(count, 2);
  for (let index = 0; index < 70; index++) await service.get(`public query ${index}`, { enabled: true });
  assert.equal(service.cache.entries.size, 64);
});

test('late disabled suggestion responses do not repopulate cache or return predictions', async () => {
  const pending = deferred(); const service = new SuggestionsService({ fetch: () => pending.promise });
  const response = service.get('weather', { enabled: true }); service.clear(); pending.resolve(prediction('weather'));
  assert.deepEqual(await response, []); assert.equal(service.cache.entries.size, 0);
});

test('suggestion response MIME, echo, schema, controls, size and redirect are checked', async () => {
  const replies = [reply('<html>not JSON</html>', 'text/html'), reply('not-json'), reply(JSON.stringify(['other', ['private']])),
    reply(JSON.stringify(['weather', null])), reply(JSON.stringify(['weather', ['bad\ntext', '', 'x'.repeat(121)]])),
    reply('x'.repeat(65537)), reply('[]', 'application/json', { 'content-length': '999999' }),
    { ok: true, redirected: true }, new Response('', { status: 500 })];
  for (const response of replies) {
    const service = new SuggestionsService({ fetch: async () => response });
    assert.deepEqual(await service.get('weather', { enabled: true }), []);
  }
});

test('streamed oversized suggestions cancel reader and bounded timeout handles ignored abort', async () => {
  let cancelled = false;
  const response = new Response(new ReadableStream({ pull(controller) { controller.enqueue(new Uint8Array(70000)); },
    cancel() { cancelled = true; } }), { headers: { 'content-type': 'application/json' } });
  const service = new SuggestionsService({ fetch: async () => response });
  assert.deepEqual(await service.get('weather', { enabled: true }), []); assert.ok(cancelled);
  const timeout = new SuggestionsService({ fetch: () => new Promise(() => {}), timeout: 5 });
  assert.deepEqual(await timeout.get('weather', { enabled: true }), []);
});

test('favicon uses only HTTPS origin root favicon, never page paths or third-party aggregators', async () => {
  const calls = []; const service = new FaviconService({ fetch: async (url, options) => {
    calls.push({ url, options }); return reply(png(), 'image/png');
  } });
  assert.match(await service.get('https://example.com/private?token=secret#section'), /^data:image\/png;base64,/);
  assert.equal(calls[0].url, 'https://example.com/favicon.ico');
  assert.equal(calls[0].options.credentials, 'omit'); assert.equal(calls[0].options.redirect, 'error');
  await service.get('https://example.com/other'); assert.equal(calls.length, 1);
});

test('favicon rejects incognito and unsafe address forms before cache or network', async () => {
  let calls = 0; const service = new FaviconService({ fetch: async () => { calls++; return reply(png(), 'image/png'); } });
  assert.equal(await service.get('https://example.com', { incognito: true }), null);
  for (const url of ['http://example.com', 'https://127.0.0.1', 'https://[::1]', 'https://localhost',
    'https://a.local', 'https://a.internal', 'https://user:password@example.com']) assert.equal(await service.get(url), null);
  assert.equal(calls, 0); assert.equal(service.cache.entries.size, 0);
});

test('favicon validates raster signature, dimensions, MIME, maximum response size and redirects', async () => {
  for (const response of [reply('<svg onload="alert(1)"></svg>', 'image/svg+xml'), reply('<html/>', 'image/png'),
    reply(png(5000), 'image/png'), reply(png(0), 'image/png'), reply(new Uint8Array(262145), 'image/png'),
    { ok: true, redirected: true }]) {
    assert.equal(await new FaviconService({ fetch: async () => response }).get('https://example.com'), null);
  }
  const ico = new Uint8Array(22); ico.set([0, 0, 1, 0, 1, 0]);
  assert.match(await new FaviconService({ fetch: async () => reply(ico, 'image/x-icon') }).get('https://example.com'), /^data:image\/x-icon;base64,/);
});

test('favicon success/negative expiry, coalescing and LRU bounds stay deterministic', async () => {
  let time = 0; let count = 0; const pending = deferred();
  const service = new FaviconService({ now: () => time, fetch: async () => { count++; return pending.promise; } });
  const first = service.get('https://example.com/a'); const second = service.get('https://example.com/b');
  assert.equal(count, 1); pending.resolve(reply(png(), 'image/png')); assert.equal(await first, await second);
  await service.get('https://example.com/c'); assert.equal(count, 1);
  time = 7 * 86400000; service.fetch = async () => { count++; return reply('missing', 'text/html'); };
  assert.equal(await service.get('https://example.com'), null); await service.get('https://example.com'); assert.equal(count, 2);
  time += 3600000; await service.get('https://example.com'); assert.equal(count, 3);
  for (let i = 0; i < 140; i++) await service.get(`https://s${i}.example.com`);
  assert.equal(service.cache.entries.size, 128);
});

test('favicon requests cap concurrency at four and late cleared result cannot repopulate cache', async () => {
  let active = 0; let maximum = 0; const resolvers = [];
  const service = new FaviconService({ fetch: async () => {
    active++; maximum = Math.max(maximum, active); const pending = deferred(); resolvers.push(() => { active--; pending.resolve(reply(png(), 'image/png')); });
    return pending.promise;
  } });
  const tasks = Array.from({ length: 9 }, (_, i) => service.get(`https://s${i}.example.com`));
  assert.equal(resolvers.length, 4);
  while (resolvers.length) { resolvers.shift()(); await new Promise(resolve => setImmediate(resolve)); }
  await Promise.all(tasks); assert.equal(maximum, 4);
  const pending = deferred(); const late = new FaviconService({ fetch: () => pending.promise });
  const task = late.get('https://example.com'); late.clear(); pending.resolve(reply(png(), 'image/png'));
  assert.equal(await task, null); assert.equal(late.cache.entries.size, 0);
});

test('tab cache coalesces cold reads, serves fresh and stale snapshots, and bounds retention', async () => {
  let time = 0; let calls = 0; let pending = deferred();
  const browser = { tabs: { query: () => { calls++; return pending.promise; } } };
  const cache = new TabCache(browser, { now: () => time });
  const first = cache.get(); const second = cache.get(); assert.equal(calls, 1);
  pending.resolve([{ id: 1 }, { id: 2, incognito: true }]); assert.deepEqual((await first).tabs, [{ id: 1 }]); await second;
  time = 4999; assert.equal((await cache.get()).refreshing, false); assert.equal(calls, 1);
  time = 5000; pending = deferred(); const stale = await cache.get(); assert.equal(stale.refreshing, true); assert.equal(calls, 2);
  const forced = cache.get({ force: true }); assert.equal(calls, 2); pending.resolve([{ id: 3 }]); assert.deepEqual((await forced).tabs, [{ id: 3 }]);
  time = 125000; pending = deferred(); const expired = cache.get(); assert.equal(calls, 3); pending.resolve([]); assert.deepEqual((await expired).tabs, []);
});

test('tab events mark snapshot dirty without delaying stale rows; superseded reads retry', async () => {
  let calls = 0; const pending = [];
  const cache = new TabCache({ tabs: { query: () => { calls++; const item = deferred(); pending.push(item); return item.promise; } } }, { now: () => 1 });
  const cold = cache.get(); cache.invalidate(); pending.shift().resolve([{ id: 1 }]);
  await new Promise(resolve => setImmediate(resolve)); assert.equal(calls, 2);
  pending.shift().resolve([{ id: 2 }]); assert.deepEqual((await cold).tabs, [{ id: 2 }]);
  cache.invalidate(); const stale = await cache.get(); assert.equal(stale.refreshing, true); assert.deepEqual(stale.tabs, [{ id: 2 }]);
  pending.shift().resolve([{ id: 3 }]); await cache.inFlight;
});

test('private tab reads are fresh, isolated, and never added to regular snapshot', async () => {
  let calls = 0; const cache = new TabCache({ tabs: { query: async () => { calls++; return [{ id: 1 }, { id: 2, incognito: true }]; } } });
  assert.deepEqual((await cache.get({ incognito: true })).tabs, [{ id: 2, incognito: true }]);
  assert.deepEqual((await cache.get({ incognito: true })).tabs, [{ id: 2, incognito: true }]);
  assert.equal(calls, 2); assert.equal(cache.snapshot, null);
  assert.deepEqual((await cache.get()).tabs, [{ id: 1 }]);
});

test('tab refresh failures preserve only bounded prior data and propagate force failure', async () => {
  let time = 0; const browser = { tabs: { query: async () => [{ id: 1 }] } }; const cache = new TabCache(browser, { now: () => time });
  await cache.get(); time = 6000; browser.tabs.query = async () => { throw new Error('denied'); };
  assert.equal((await cache.get()).refreshing, true);
  await assert.rejects(cache.get({ force: true }));
  time = 120000; await assert.rejects(cache.get());
});

test('cache byte budget evicts LRU entries and remains accurate after expiry and clear', () => {
  let time = 0; const cache = new MemoryCache({ limit: 128, ttl: 10, maxBytes: 8, sizeOf: value => value.length * 2, now: () => time });
  cache.set('a', 'aa'); cache.set('b', 'bb'); cache.get('a'); cache.set('c', 'cc');
  assert.equal(cache.get('b'), undefined); assert.equal(cache.bytes, 8);
  cache.set('oversize', 'too big'); assert.equal(cache.get('oversize'), undefined); assert.equal(cache.bytes, 8);
  time = 10; cache.get('a'); assert.equal(cache.bytes, 4); cache.clear(); assert.equal(cache.bytes, 0);
});

function persistentStorage(initial = {}) {
  const state = structuredClone(initial); const calls = []; let active = 0; let maximum = 0;
  const storage = {
    async get(key) { calls.push(['get', key]); return structuredClone(state); },
    async set(patch) {
      active++; maximum = Math.max(maximum, active); calls.push(['set', structuredClone(patch)]);
      await new Promise(resolve => setImmediate(resolve)); Object.assign(state, structuredClone(patch)); active--;
    },
  };
  return { state, calls, storage, get maximum() { return maximum; } };
}

test('persistent favicon cache survives worker restart without raw origin/path/query storage', async () => {
  const fixture = persistentStorage(); let calls = 0; const now = () => 100000;
  const first = new FaviconService({ now, persistence: new PersistentFaviconCache({ storage: fixture.storage, now }),
    fetch: async () => { calls++; return reply(png(), 'image/png'); } });
  const image = await first.get('https://example.com/private?secret=abc'); assert.ok(image);
  const serialized = JSON.stringify(fixture.state);
  for (const forbidden of ['example.com', 'private', 'secret', 'abc']) assert.equal(serialized.includes(forbidden), false);
  const record = fixture.state.faviconCacheV1.entries[0]; assert.match(record.id, /^[a-f\d]{64}$/);
  const restarted = new FaviconService({ now, persistence: new PersistentFaviconCache({ storage: fixture.storage, now }),
    fetch: async () => { calls++; throw new Error('must use persisted'); } });
  assert.equal(await restarted.get('https://example.com/other'), image); assert.equal(calls, 1);
});

test('persistent negative favicon cache expires at one hour and positive at seven days', async () => {
  const fixture = persistentStorage(); let time = 0; let calls = 0;
  const make = () => new FaviconService({ now: () => time, persistence: new PersistentFaviconCache({ storage: fixture.storage, now: () => time }),
    fetch: async () => { calls++; return reply('missing', 'text/html'); } });
  assert.equal(await make().get('https://example.com'), null); time = 3599999;
  assert.equal(await make().get('https://example.com'), null); assert.equal(calls, 1);
  time = 3600000; assert.equal(await make().get('https://example.com'), null); assert.equal(calls, 2);
  const positive = persistentStorage(); time = 0;
  await new FaviconService({ now: () => time, persistence: new PersistentFaviconCache({ storage: positive.storage, now: () => time }),
    fetch: async () => reply(png(), 'image/png') }).get('https://example.com');
  time = 7 * 86400000;
  const cache = new PersistentFaviconCache({ storage: positive.storage, now: () => time });
  assert.equal(await cache.get('https://example.com'), undefined);
});

test('corrupt persisted favicon MIME/base64/dimensions/expiry recover with network fallback', async () => {
  const hash = await new PersistentFaviconCache().hash('https://example.com');
  for (const patch of [{ image: 'data:image/svg+xml;base64,PHN2Zy8+' }, { image: 'data:image/png;base64,broken===' },
    { image: `data:image/png;base64,${btoa(String.fromCharCode(...png(9000)))}` }, { expires: 999999999999 },
    { lastUsed: 999999999999 }, { id: 'not-a-hash' }]) {
    const fixture = persistentStorage({ faviconCacheV1: { version: 1, entries: [{ id: hash, image: null, expires: 1000, lastUsed: 1, ...patch }] } });
    let calls = 0;
    const service = new FaviconService({ now: () => 10, persistence: new PersistentFaviconCache({ storage: fixture.storage, now: () => 10 }),
      fetch: async () => { calls++; return reply(png(), 'image/png'); } });
    assert.ok(await service.get('https://example.com')); assert.equal(calls, 1);
  }
});

test('persistent cache is bounded by entries/bytes, serializes writes and survives storage failure', async () => {
  const fixture = persistentStorage(); let time = 1; const cache = new PersistentFaviconCache({ storage: fixture.storage, now: () => time++ });
  const largePNG = new Uint8Array(20000); largePNG.set(png()); const image = `data:image/png;base64,${btoa(String.fromCharCode(...largePNG))}`;
  await Promise.all(Array.from({ length: 160 }, (_, i) => cache.set(`https://s${i}.example.com`, image, 100000)));
  assert.equal(fixture.maximum, 1); assert.ok(fixture.state.faviconCacheV1.entries.length < 128);
  assert.ok(fixture.state.faviconCacheV1.entries.reduce((total, entry) => total + entry.image.length * 2, 0) <= 4 * 1024 * 1024);
  const broken = new PersistentFaviconCache({ storage: { async get() { throw new Error('denied'); }, async set() { throw new Error('quota'); } } });
  const service = new FaviconService({ persistence: broken, fetch: async () => reply(png(), 'image/png') });
  assert.ok(await service.get('https://example.com'));
});

test('private favicon requests do not read or write persistent cache, even for an existing icon', async () => {
  const fixture = persistentStorage(); const service = new FaviconService({
    persistence: new PersistentFaviconCache({ storage: fixture.storage }), fetch: async () => reply(png(), 'image/png') });
  await service.get('https://example.com'); const before = fixture.calls.length;
  assert.equal(await service.get('https://example.com', { incognito: true }), null);
  assert.equal(fixture.calls.length, before);
});

test('late cleared favicon generation cannot write persistent results or populate memory', async () => {
  const fixture = persistentStorage(); const pending = deferred(); const service = new FaviconService({
    persistence: new PersistentFaviconCache({ storage: fixture.storage }), fetch: () => pending.promise });
  const first = service.get('https://example.com'); await new Promise(resolve => setImmediate(resolve)); service.clear();
  pending.resolve(reply(png(), 'image/png')); assert.equal(await first, null);
  assert.equal(fixture.calls.some(call => call[0] === 'set'), false); assert.equal(service.cache.entries.size, 0);
  service.fetch = async () => reply(png(), 'image/png'); assert.ok(await service.get('https://example.com'));
});
