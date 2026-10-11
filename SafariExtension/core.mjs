export const ENGINES = Object.freeze({
  google: 'https://www.google.com/search',
  bing: 'https://www.bing.com/search',
  duckduckgo: 'https://duckduckgo.com/',
});
export const DEFAULT_SETTINGS = Object.freeze({ engine: 'google', googleSuggestions: false, rememberChoices: true });
export const RETENTION_MS = 183 * 86400000;

// Shared normalization keeps local ranking and UI selection identity consistent.
export function normalize(text) {
  return String(text ?? '').normalize('NFKD').replace(/\p{M}/gu, '').replace(/[łŁ]/g, 'l')
    .toLowerCase().replace(/\s+/g, ' ').trim();
}

export function webURL(text) {
  if (typeof text !== 'string' || text.length > 4096 || /[\u0000-\u001f\u007f]/.test(text)) return null;
  try {
    const url = new URL(text);
    if (!['http:', 'https:'].includes(url.protocol) || !url.hostname || url.username || url.password) return null;
    return url.href;
  } catch { return null; }
}

export function targetIdentity(target) {
  if (target?.kind === 'tab' && Number.isSafeInteger(target.tabId)) return `tab:${target.tabId}`;
  if (target?.kind === 'query') return `query:${normalize(target.query)}`;
  if (target?.kind === 'url') return webURL(target.url) ? `url:${webURL(target.url)}` : null;
  return null;
}

export function address(input) {
  const query = String(input ?? '').trim();
  if (!query) return null;
  const direct = webURL(query);
  if (direct) return direct;
  if (!/\s/.test(query) && !/^[a-z][a-z\d+.-]*:\/\//i.test(query)) {
    const local = /^(?:localhost|(?:\d{1,3}\.){3}\d{1,3})(?::\d+)?(?:[/?#]|$)/i.test(query);
    const host = /^[a-z\d](?:[a-z\d.-]*\.[a-z]{2,})(?::\d+)?(?:[/?#]|$)/i.test(query);
    if (local || host) {
      const url = webURL(`${local ? 'http' : 'https'}://${query}`);
      if (url) return url;
    }
  }
  return null;
}

export function destination(input, engine = 'google') {
  const query = String(input ?? '').trim();
  if (!query) return null;
  const direct = address(query);
  if (direct) return direct;
  const url = new URL(ENGINES[engine] ?? ENGINES.google);
  url.searchParams.set('q', query);
  return url.href;
}

export function publicOrigin(text) {
  const address = webURL(text);
  if (!address) return null;
  const url = new URL(address);
  const host = url.hostname.toLowerCase();
  if (url.protocol !== 'https:' || url.port || !host.includes('.') || /[^a-z\d.-]/.test(host)
      || !/\.[a-z]{2,}$/.test(host) || host.split('.').some(part => !part || part.startsWith('-') || part.endsWith('-'))
      || /(?:^|\.)(?:localhost|local|internal|lan|home|test|invalid|onion)$/.test(host)) return null;
  return url.origin;
}

export function eligibleSuggestionQuery(text) {
  if (typeof text !== 'string' || /[\u0000-\u001f\u007f]/.test(text)) return null;
  const query = text.trim();
  if (query.length < 2 || query.length > 120 || /[@\\]/.test(query)
      || /(?:https?:|www\.|localhost|(?:\d{1,3}\.){3}\d{1,3}|\[[a-f\d:]+\])/i.test(query)
      || /^(?:[a-z][a-z\d+.-]*:|\/|~\/|(?:password|passwd|secret|token|api[-_ ]?key|authorization|bearer)\b)/i.test(query)
      || /\b[a-z\d-]+\.[a-z]{2,}(?:[/:?#]|\b)/i.test(query)) return null;
  return query;
}

export function sanitizeSettings(value) {
  return {
    engine: Object.hasOwn(ENGINES, value?.engine) ? value.engine : DEFAULT_SETTINGS.engine,
    googleSuggestions: typeof value?.googleSuggestions === 'boolean' ? value.googleSuggestions : false,
    rememberChoices: typeof value?.rememberChoices === 'boolean' ? value.rememberChoices : true,
  };
}

export function sanitizeChoices(records, now = Date.now()) {
  const merged = new Map();
  for (const item of Array.isArray(records) ? records.slice(0, 10000) : []) {
    if (!item || !['query', 'url'].includes(item.kind) || typeof item.value !== 'string'
        || !Number.isFinite(item.lastUsed) || item.lastUsed > now || item.lastUsed < now - RETENTION_MS) continue;
    const value = item.kind === 'url' ? webURL(item.value) : item.value.trim();
    if (!value || (item.kind === 'query' && (value.length > 120 || /[\u0000-\u001f\u007f]/.test(value)))) continue;
    const key = item.kind === 'url' ? `url:${value}` : `query:${normalize(value)}`;
    const choice = { kind: item.kind, value, title: typeof item.title === 'string' ? item.title.slice(0, 512) : value,
      count: Math.min(100000, Math.max(1, Math.floor(Number(item.count) || 1))), lastUsed: item.lastUsed };
    const previous = merged.get(key);
    if (!previous || choice.lastUsed > previous.lastUsed) merged.set(key, choice);
    if (previous) merged.get(key).count = Math.max(previous.count, choice.count);
  }
  const ordered = [...merged.values()].sort((a, b) => b.lastUsed - a.lastUsed);
  let urls = 0; let queries = 0;
  return ordered.filter(item => item.kind === 'url' ? ++urls <= 1000 : ++queries <= 500);
}

export function rememberChoice(records, target, title, now = Date.now()) {
  const kind = target.kind === 'url' ? 'url' : target.kind === 'query' ? 'query' : null;
  const value = kind === 'url' ? webURL(target.url) : kind === 'query' ? String(target.query ?? '').trim() : null;
  if (!value || (kind === 'query' && (value.length > 120 || /[\u0000-\u001f\u007f]/.test(value)))) return sanitizeChoices(records, now);
  const id = targetIdentity(kind === 'url' ? { kind, url: value } : { kind, query: value });
  const choices = sanitizeChoices(records, now);
  const previous = choices.find(item => targetIdentity(item.kind === 'url'
    ? { kind: 'url', url: item.value } : { kind: 'query', query: item.value }) === id);
  return sanitizeChoices([...choices.filter(item => item !== previous), {
    kind, value, title: title || value, count: (previous?.count ?? 0) + 1, lastUsed: now,
  }], now);
}

export function frecency(choice, now) {
  return choice ? 40 * Math.exp(-Math.max(0, now - choice.lastUsed) / (30 * 86400000))
    + Math.min(20, 4 * Math.log2(choice.count + 1)) : 0;
}

function matchScore(title, address, query) {
  const text = normalize(title); const url = normalize(address); const needle = normalize(query);
  if (!needle) return 0;
  if (!needle.split(' ').every(token => `${text} ${url}`.includes(token))) return null;
  let host = '';
  try { host = normalize(new URL(address).hostname.replace(/^www\./, '')); } catch { }
  if (host === needle) return 100;
  if (text === needle) return 95;
  if (host.startsWith(needle)) return 90;
  if (text.startsWith(needle)) return 85;
  if (text.includes(needle)) return 80;
  if (url.includes(needle)) return 60;
  return 40;
}

export function rankTabs(tabs, query, choices = [], now = Date.now()) {
  const usage = new Map(choices.filter(item => item.kind === 'url').map(item => [webURL(item.value), item]));
  return tabs.map((tab, index) => ({ tab, index, score: matchScore(tab.title, tab.url, query),
    usage: frecency(usage.get(webURL(tab.url)), now) })).filter(item => item.score !== null)
    .sort((a, b) => b.score - a.score || b.usage - a.usage || a.index - b.index).map(item => item.tab);
}

export function buildRows(tabs, query, choices = [], now = Date.now()) {
  const clean = String(query ?? '').trim(); const needle = normalize(clean); const rows = [];
  const windowNumbers = new Map();
  for (const tab of tabs) {
    if (Number.isSafeInteger(tab.windowId) && tab.windowId >= 0 && !windowNumbers.has(tab.windowId)) {
      windowNumbers.set(tab.windowId, windowNumbers.size + 1);
    }
  }
  const action = { id: `action:${needle}`, kind: 'action', section: 'action', title: clean ? `${address(clean) ? 'Open' : 'Search for'} ${clean}` : 'New tab',
    subtitle: '', target: { kind: 'query', query: clean } };
  if (!clean) rows.push(action);
  const rankedTabs = rankTabs(tabs, clean, choices, now);
  const displayedTabIDs = new Set();
  const appendTab = tab => {
    if (displayedTabIDs.has(tab.id)) return;
    displayedTabIDs.add(tab.id);
    rows.push({ id: `tab:${tab.id}`, kind: 'tab', section: 'tabs', title: tab.title || tab.url || 'Untitled',
      subtitle: tab.url || '', url: tab.url || '',
      ...(windowNumbers.has(tab.windowId) ? { windowNumber: windowNumbers.get(tab.windowId) } : {}),
      target: { kind: 'tab', tabId: tab.id } });
  };
  rankedTabs.forEach(appendTab);
  const rankChoices = items => items.map((choice, index) => ({ choice, index, score: matchScore(choice.title, choice.value, clean) }))
    .filter(item => item.score !== null).sort((a, b) => b.score - a.score
      || frecency(b.choice, now) - frecency(a.choice, now) || a.index - b.index).map(item => item.choice);
  const recent = choices.filter(item => item.kind === 'query');
  const recentRows = !clean ? [...recent].sort((a, b) => b.lastUsed - a.lastUsed) : rankChoices(recent);
  for (const item of recentRows.slice(0, 5)) rows.push({ id: `query:${normalize(item.value)}`, kind: 'recent', section: 'recent',
    title: item.value, subtitle: 'Recent search', lastUsed: item.lastUsed, target: { kind: 'query', query: item.value } });
  if (clean) {
    const destinations = new Set();
    const open = new Map(tabs.map(tab => [webURL(tab.url), tab]));
    for (const item of rankChoices(choices.filter(item => item.kind === 'url'))) {
      const address = webURL(item.value);
      if (!address || destinations.has(address)) continue;
      destinations.add(address);
      if (open.has(address)) { appendTab(open.get(address)); continue; }
      if (rows.filter(row => row.kind === 'history').length >= 8) continue;
      rows.push({ id: `url:${address}`, kind: 'history', section: 'history', title: item.title || address,
        subtitle: address, url: address, lastUsed: item.lastUsed, target: { kind: 'url', url: address } });
    }
  }
  // History can recover an open tab with a changed title; keep all tab actions together.
  const tabRows = rows.filter(row => row.kind === 'tab');
  const localRows = rows.filter(row => row.kind !== 'tab' && row.kind !== 'action');
  return clean ? [...tabRows, ...localRows, action] : [action, ...tabRows, ...localRows];
}
