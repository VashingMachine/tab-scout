import test from 'node:test';
import assert from 'node:assert/strict';
import { formatLastUsed, mergeSuggestionRows, nextSelection, retainedSelectedRow } from '../../SafariExtension/search.mjs';

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
