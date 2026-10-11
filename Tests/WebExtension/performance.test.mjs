import test from 'node:test';
import assert from 'node:assert/strict';
import { performance } from 'node:perf_hooks';
import { buildRows } from '../../SafariExtension/core.mjs';
import { TabCache } from '../../SafariExtension/services.mjs';

test('1,000 fixture tabs remain searchable and 100 warm opens avoid further inventory reads', async context => {
  const tabs = Array.from({ length: 1000 }, (_, i) => ({ id: i, windowId: 1, title: `Fixture project ${i}`, url: `https://site${i}.example.com/project` }));
  let reads = 0; const cache = new TabCache({ tabs: { query: async () => { reads++; return tabs; } } }, { now: () => 1 });
  const snapshot = await cache.get(); const samples = [];
  for (let i = 0; i < 100; i++) {
    assert.equal((await cache.get()).tabs.length, 1000);
    const start = performance.now(); const rows = buildRows(snapshot.tabs, `project ${i}`, [], 1); samples.push(performance.now() - start);
    assert.ok(rows.some(row => row.target.kind === 'tab' && row.target.tabId === i));
    assert.equal(rows.at(-1).target.query, `project ${i}`);
  }
  assert.equal(reads, 1); samples.sort((a, b) => a - b);
  context.diagnostic(`1,000 tabs: median ${samples[50].toFixed(2)} ms/query, p95 ${samples[95].toFixed(2)} ms; 100 warm opens, 0 additional inventory reads`);
});
