import test from 'node:test';
import assert from 'node:assert/strict';
import { formatLastUsed, formatResultSummary, formatRowDetail, mergeSuggestionRows, nextSelection, retainedSelectedRow } from '../../SafariExtension/search.mjs';

const action = query => ({ id: `action:${query}`, kind: 'action', section: 'action', target: { kind: 'query', query } });
const recent = (query, id = `query:${query}`) => ({ id, kind: 'recent', section: 'recent', target: { kind: 'query', query } });
const history = (url, id = `url:${url}`) => ({ id, kind: 'history', section: 'history', target: { kind: 'url', url } });
const tab = (id, url = 'https://example.com') => ({ id: `tab:${id}`, kind: 'tab', section: 'tabs', url, target: { kind: 'tab', tabId: id } });

test('Google predictions preserve provider order and deduplicate typed/recent phrases', () => {
  const rows = [recent('Łódź trips'), action('lodz')];
  const merged = mergeSuggestionRows(rows, ['LODZ TRIPS', 'lodz', 'lodz hotels', 'LODZ HOTELS', ' lodz weather ', null], 'lodz');
  assert.deepEqual(merged.slice(0, 2), rows); assert.deepEqual(merged.slice(2).map(row => row.title), ['lodz hotels', 'lodz weather']);
  assert.equal(merged.at(-1).subtitle, 'Google');
});

test('empty query has no remote rows and remote result list is bounded', () => {
  assert.deepEqual(mergeSuggestionRows([action('')], ['weather'], ' \n '), [action('')]);
  assert.equal(mergeSuggestionRows([action('work')], Array.from({ length: 30 }, (_, i) => `work ${i}`), 'work').length, 9);
});

test('selected typed action remains selected when predictions arrive or force-refreshed rows change', () => {
  const previous = action('work'); const rows = mergeSuggestionRows([tab(1), previous], ['work tools'], 'work');
  assert.equal(retainedSelectedRow(previous, rows), previous.id);
  assert.equal(retainedSelectedRow(tab(1), [tab(2), tab(1), previous]), 'tab:1');
  assert.equal(retainedSelectedRow(previous, [action('different')]), null);
});

test('selection retains logical recent/suggestion query through promotion and count/date updates', () => {
  const suggestion = { id: 'suggestion:lodz trips', target: { kind: 'query', query: 'Łódź trips' } };
  const promoted = recent('LODZ TRIPS', 'query:lodz trips');
  assert.equal(retainedSelectedRow(suggestion, [action('lodz'), promoted]), promoted.id);
  assert.equal(retainedSelectedRow(promoted, [suggestion]), suggestion.id);
  assert.equal(retainedSelectedRow(suggestion, [recent('LODZ TRIPS', 'other-a'), recent('lodz trips', 'other-b')]), null);
});

test('history/tab selection promotes by canonical URL but never guesses duplicate or invalid URLs', () => {
  const previous = history('https://EXAMPLE.com:443/');
  assert.equal(retainedSelectedRow(previous, [tab(1, 'https://example.com')]), 'tab:1');
  assert.equal(retainedSelectedRow(tab(1, 'https://example.com'), [previous]), previous.id);
  assert.equal(retainedSelectedRow(previous, [tab(1), tab(2)]), null);
  assert.equal(retainedSelectedRow(history('about:blank'), [tab(1, 'file:///tmp')]), null);
  assert.equal(retainedSelectedRow(tab(1, 'about:blank'), [history('file:///tmp')]), null);
});

test('arrow navigation clamps selectable row model, handles empty list and invalid current IDs', () => {
  const rows = [tab(1), recent('work'), action('work')];
  assert.equal(nextSelection(rows, 'tab:1', 1), 'query:work');
  assert.equal(nextSelection(rows, 'query:work', 1), 'action:work');
  assert.equal(nextSelection(rows, 'action:work', 1), 'action:work');
  assert.equal(nextSelection(rows, 'tab:1', -1), 'tab:1');
  assert.equal(nextSelection(rows, 'action:work', -1), 'query:work');
  assert.equal(nextSelection(rows, 'invalid', 1), 'tab:1');
  assert.equal(nextSelection([], null, 1), null); assert.equal(nextSelection(rows, 'tab:1', 10), null);
});

test('clock timestamps use real elapsed time and reject invalid/future values', () => {
  const now = 2000000000000;
  assert.equal(formatLastUsed(now, now, 'en'), 'Just now');
  assert.equal(formatLastUsed(now - 5000, now, 'en'), '5 seconds ago');
  assert.equal(formatLastUsed(now - 120000, now, 'en'), '2 minutes ago');
  assert.equal(formatLastUsed(now - 7200000, now, 'en'), '2 hours ago');
  assert.equal(formatLastUsed(now - 3 * 86400000, now, 'en'), '3 days ago');
  assert.equal(formatLastUsed(now - 60 * 86400000, now, 'en'), '2 months ago');
  assert.equal(formatLastUsed(now - 2 * 31536000000, now, 'en'), '2 years ago');
  for (const value of [null, undefined, NaN, Infinity, 0, -1, now + 1]) assert.equal(formatLastUsed(value, now, 'en'), null);
});

test('native-style tab detail adds stable window labels without rewriting the address', () => {
  const url = 'https://EXAMPLE.com/Case?token=kept#Section';
  const row = { ...tab(1, url), subtitle: url, windowNumber: 2 };
  assert.equal(formatRowDetail(row), `${url} | Window 2`);
  assert.equal(row.url, url);
  assert.equal(row.target.tabId, 1);
  for (const windowNumber of [null, undefined, 0, -1, 1.5, Infinity, '2']) {
    assert.equal(formatRowDetail({ ...row, windowNumber }), url);
  }
  assert.equal(formatRowDetail({ kind: 'tab', subtitle: '', windowNumber: 1 }), 'Start Page | Window 1');
});

test('history and recent details use the app-style inline age', () => {
  const now = 2000000000000;
  const row = { kind: 'history', subtitle: 'https://example.com/Case', lastUsed: now - 120000 };
  assert.equal(formatRowDetail(row, 'google', now, 'en'), 'https://example.com/Case | 2 minutes ago');
  assert.equal(formatRowDetail({ ...row, kind: 'recent' }, 'google', now, 'en'), '2 minutes ago');
  assert.equal(formatRowDetail({ ...row, lastUsed: 0 }, 'google', now, 'en'), row.subtitle);
  assert.equal(formatRowDetail({ kind: 'suggestion', subtitle: 'Google' }), 'Google');
});

test('action details name the real extension provider rather than claiming Safari default access', () => {
  const row = action('weather');
  for (const [engine, title] of [['google', 'Google'], ['bing', 'Bing'], ['duckduckgo', 'DuckDuckGo']]) {
    assert.equal(formatRowDetail(row, engine), `${title} search`);
  }
  for (const engine of ['invalid', '__proto__', 'constructor', 'toString']) {
    assert.equal(formatRowDetail(row, engine), 'Google search');
  }
  assert.equal(formatRowDetail(action('example.com/path')), 'New Safari tab');
  assert.equal(formatRowDetail(action(' \n ')), 'Tab Scout search page');
});

test('native-style summary counts inventory and local results independently of predictions', () => {
  const rows = [{ ...tab(1), windowNumber: 1 }, { ...tab(2), windowNumber: 1 },
    { ...tab(3), windowNumber: 2 }, recent('work'), history('https://example.org'), action('work'),
    { kind: 'suggestion' }, { kind: 'suggestion' }];
  assert.equal(formatResultSummary(rows, '', { tabCount: 10, windowCount: 3 }), '10 tabs in 3 windows');
  assert.equal(formatResultSummary([tab(1)], '', { tabCount: 1, windowCount: 1 }), '1 tab in 1 window');
  assert.equal(formatResultSummary(rows, 'work', { tabCount: 10, windowCount: 3 }), '5 local results | 2 Google suggestions');
  assert.equal(formatResultSummary([tab(1), action('work')], 'work'), '1 local result');
  assert.equal(formatResultSummary([action('missing')], 'missing'), '0 local results');
  assert.equal(formatResultSummary(rows, ' \n '), '3 tabs in 2 windows');
  assert.equal(formatResultSummary(rows, '', { tabCount: Infinity, windowCount: -1 }), '3 tabs in 2 windows');
  assert.equal(formatResultSummary([], ''), '0 tabs in 0 windows');
});
