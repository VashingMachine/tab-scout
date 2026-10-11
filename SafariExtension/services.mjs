import { eligibleSuggestionQuery, normalize, publicOrigin } from './core.mjs';

export class MemoryCache {
  constructor({ limit, ttl, now = Date.now, maxBytes = Infinity, sizeOf = () => 0 }) {
    this.limit = limit; this.ttl = ttl; this.now = now; this.maxBytes = maxBytes; this.sizeOf = sizeOf;
    this.entries = new Map(); this.bytes = 0;
  }
  delete(key) {
    const entry = this.entries.get(key);
    if (entry) this.bytes -= entry.bytes;
    this.entries.delete(key);
  }
  get(key) {
    const entry = this.entries.get(key);
    if (!entry) return undefined;
    if (entry.expires <= this.now()) { this.delete(key); return undefined; }
    this.entries.delete(key); this.entries.set(key, entry);
    return entry.value;
  }
  set(key, value, ttl = this.ttl) {
    this.delete(key); const bytes = this.sizeOf(value);
    if (bytes > this.maxBytes) return;
    this.entries.set(key, { value, expires: this.now() + ttl, bytes }); this.bytes += bytes;
    while (this.entries.size > this.limit || this.bytes > this.maxBytes) this.delete(this.entries.keys().next().value);
  }
  clear() { this.entries.clear(); this.bytes = 0; }
}

async function boundedFetch(fetchFn, url, { timeout, maxBytes, accepts }) {
  const controller = new AbortController(); let timer;
  const request = async () => {
    const response = await fetchFn(url, { credentials: 'omit', referrerPolicy: 'no-referrer', redirect: 'error',
      cache: 'no-store', signal: controller.signal, headers: { Accept: accepts } });
    if (!response.ok || response.redirected) throw new Error('Network unavailable');
    const declared = Number(response.headers.get('content-length'));
    if (declared > maxBytes) throw new Error('Response too large');
    const mime = (response.headers.get('content-type') || '').split(';')[0].trim().toLowerCase();
    if (!response.body?.getReader) throw new Error('Response unavailable');
    const reader = response.body.getReader(); const chunks = []; let length = 0;
    try {
      while (true) {
        const { value, done } = await reader.read();
        if (done) break;
        length += value.byteLength;
        if (length > maxBytes) { await reader.cancel(); throw new Error('Response too large'); }
        chunks.push(value);
      }
    } finally { reader.releaseLock(); }
    const bytes = new Uint8Array(length); let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
    return { bytes, mime };
  };
  try {
    return await Promise.race([request(), new Promise((_, reject) => {
      timer = setTimeout(() => { controller.abort(); reject(new Error('Request timed out')); }, timeout);
    })]);
  } finally { clearTimeout(timer); controller.abort(); }
}

export class SuggestionsService {
  constructor({ fetch = globalThis.fetch, now = Date.now, timeout = 3000 } = {}) {
    this.fetch = fetch; this.timeout = timeout; this.cache = new MemoryCache({ limit: 64, ttl: 300000, now });
    this.inFlight = new Map(); this.generation = 0;
  }
  clear() { this.generation++; this.cache.clear(); this.inFlight.clear(); }
  async get(text, { enabled = false, incognito = false } = {}) {
    const query = eligibleSuggestionQuery(text);
    if (!enabled || incognito || !query) return [];
    const key = normalize(query); const cached = this.cache.get(key);
    if (cached) return [...cached];
    if (this.inFlight.has(key)) return this.inFlight.get(key);
    const generation = this.generation;
    const task = (async () => {
      try {
        const url = new URL('https://suggestqueries.google.com/complete/search');
        url.searchParams.set('client', 'safari'); url.searchParams.set('q', query);
        const response = await boundedFetch(this.fetch, url.href, { timeout: this.timeout, maxBytes: 65536,
          accepts: 'application/json, application/javascript' });
        if (!['application/json', 'application/javascript', 'text/javascript', 'application/x-javascript'].includes(response.mime)) return [];
        const result = JSON.parse(new TextDecoder().decode(response.bytes));
        if (!Array.isArray(result) || typeof result[0] !== 'string' || normalize(result[0]) !== key || !Array.isArray(result[1])) return [];
        const unique = new Set(); const suggestions = [];
        for (const item of result[1].slice(0, 100)) {
          const value = typeof item === 'string' ? item : Array.isArray(item) ? item[0] : null;
          if (typeof value !== 'string' || !value.trim() || value.length > 120 || /[\u0000-\u001f\u007f]/.test(value)) continue;
          const identity = normalize(value);
          if (!unique.has(identity)) { unique.add(identity); suggestions.push(value.trim()); }
          if (suggestions.length === 8) break;
        }
        if (generation !== this.generation) return [];
        this.cache.set(key, suggestions); return suggestions;
      } catch { return []; }
    })();
    this.inFlight.set(key, task);
    try { return await task; } finally { if (this.inFlight.get(key) === task) this.inFlight.delete(key); }
  }
}

export function rasterMime(bytes, mime) {
  const starts = prefix => prefix.every((value, index) => bytes[index] === value);
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (mime === 'image/png' && bytes.length >= 24 && starts([137, 80, 78, 71, 13, 10, 26, 10])) {
    const width = view.getUint32(16); const height = view.getUint32(20);
    return width > 0 && width <= 4096 && height > 0 && height <= 4096 ? 'image/png' : null;
  }
  if (['image/x-icon', 'image/vnd.microsoft.icon'].includes(mime) && bytes.length >= 22 && starts([0, 0, 1, 0])) {
    const count = view.getUint16(4, true);
    return count > 0 && count <= 32 && bytes.length >= 6 + count * 16 ? 'image/x-icon' : null;
  }
  if (mime === 'image/gif' && bytes.length >= 10 && new TextDecoder().decode(bytes.slice(0, 6)).match(/^GIF8[79]a$/)) {
    const width = view.getUint16(6, true); const height = view.getUint16(8, true);
    return width > 0 && width <= 4096 && height > 0 && height <= 4096 ? 'image/gif' : null;
  }
  if (mime === 'image/jpeg' && bytes.length > 10 && starts([255, 216, 255])) {
    for (let index = 2; index + 9 < bytes.length;) {
      if (bytes[index] !== 255) return null;
      const marker = bytes[index + 1]; const length = view.getUint16(index + 2);
      if (length < 2) return null;
      if ([192, 193, 194].includes(marker)) {
        const height = view.getUint16(index + 5); const width = view.getUint16(index + 7);
        return width > 0 && width <= 4096 && height > 0 && height <= 4096 ? 'image/jpeg' : null;
      }
      index += 2 + length;
    }
  }
  return null;
}

export class PersistentFaviconCache {
  constructor({ storage, now = Date.now, crypto = globalThis.crypto } = {}) {
    this.storage = storage; this.now = now; this.crypto = crypto;
    this.records = new Map(); this.loaded = null; this.writeTask = null; this.dirty = false;
  }
  async hash(origin) {
    if (!this.crypto?.subtle) return null;
    const hash = await this.crypto.subtle.digest('SHA-256', new TextEncoder().encode(origin));
    return [...new Uint8Array(hash)].map(byte => byte.toString(16).padStart(2, '0')).join('');
  }
  trim() {
    const ordered = [...this.records.values()].filter(record => record.expires > this.now()
      && record.expires <= this.now() + 7 * 86400000).sort((a, b) => b.lastUsed - a.lastUsed);
    this.records.clear(); let bytes = 0;
    for (const record of ordered) {
      const size = (record.image?.length ?? 0) * 2;
      if (this.records.size >= 128 || bytes + size > 4 * 1024 * 1024) continue;
      bytes += size; this.records.set(record.id, record);
    }
  }
  async load() {
    if (!this.loaded) this.loaded = (async () => {
      try {
        const stored = (await this.storage.get('faviconCacheV1')).faviconCacheV1;
        if (stored?.version !== 1 || !Array.isArray(stored.entries)) return;
        for (const record of stored.entries.slice(0, 128)) {
          if (!record || !/^[a-f\d]{64}$/.test(record.id) || !Number.isFinite(record.expires)
              || !Number.isFinite(record.lastUsed) || record.lastUsed > this.now()) continue;
          if (record.image !== null) {
            if (typeof record.image !== 'string' || record.image.length > 350000) continue;
            const match = /^data:(image\/(?:png|jpeg|gif|x-icon));base64,([A-Za-z\d+/]+={0,2})$/.exec(record.image);
            if (!match) continue;
            try {
              const bytes = Uint8Array.from(atob(match[2]), character => character.charCodeAt(0));
              if (!rasterMime(bytes, match[1])) continue;
            } catch { continue; }
          }
          this.records.set(record.id, { id: record.id, image: record.image, expires: record.expires, lastUsed: record.lastUsed });
        }
        this.trim();
      } catch { this.records.clear(); }
    })();
    return this.loaded;
  }
  async get(origin) {
    try {
      const id = await this.hash(origin); if (!id) return undefined;
      await this.load(); this.trim(); const record = this.records.get(id);
      if (!record) return undefined;
      record.lastUsed = this.now(); return { image: record.image, expires: record.expires };
    } catch { return undefined; }
  }
  async set(origin, image, ttl) {
    try {
      const id = await this.hash(origin); if (!id) return;
      await this.load();
      this.records.set(id, { id, image, expires: this.now() + ttl, lastUsed: this.now() }); this.trim(); this.dirty = true;
      if (!this.writeTask) {
        // One serial writer folds simultaneous completed icon requests into bounded snapshots.
        this.writeTask = Promise.resolve().then(async () => {
          while (this.dirty) {
            this.dirty = false;
            await this.storage.set({ faviconCacheV1: { version: 1, entries: [...this.records.values()] } });
          }
        }).catch(() => { this.dirty = false; }).finally(() => { this.writeTask = null; });
      }
      await this.writeTask;
    } catch { }
  }
}

export class FaviconService {
  constructor({ fetch = globalThis.fetch, now = Date.now, timeout = 3000, persistence = null } = {}) {
    this.fetch = fetch; this.timeout = timeout; this.now = now; this.persistence = persistence;
    this.cache = new MemoryCache({ limit: 128, ttl: 7 * 86400000, now,
      maxBytes: 4 * 1024 * 1024, sizeOf: value => (value?.length ?? 0) * 2 }); this.inFlight = new Map();
    this.active = 0; this.waiters = []; this.generation = 0;
  }
  clear() { this.generation++; this.cache.clear(); this.inFlight.clear(); }
  async get(text, { incognito = false } = {}) {
    const origin = publicOrigin(text);
    if (incognito || !origin) return null;
    const cached = this.cache.get(origin);
    if (cached !== undefined) return cached;
    if (this.inFlight.has(origin)) return this.inFlight.get(origin);
    // A hostile page cannot queue an unbounded number of origin requests.
    if (this.inFlight.size >= 128) return null;
    const generation = this.generation;
    const task = (async () => {
      if (this.persistence) {
        const stored = await this.persistence.get(origin);
        if (generation !== this.generation) return null;
        if (stored) { this.cache.set(origin, stored.image, stored.expires - this.now()); return stored.image; }
      }
      if (this.active >= 4) await new Promise(resolve => this.waiters.push(resolve));
      else this.active++;
      let image = null;
      try {
        if (generation !== this.generation) return null;
        const { bytes, mime } = await boundedFetch(this.fetch, `${origin}/favicon.ico`, {
          timeout: this.timeout, maxBytes: 262144, accepts: 'image/png, image/x-icon, image/jpeg, image/gif' });
        const format = rasterMime(bytes, mime);
        if (format) {
          let binary = '';
          for (let offset = 0; offset < bytes.length; offset += 8192) binary += String.fromCharCode(...bytes.subarray(offset, offset + 8192));
          image = `data:${format};base64,${btoa(binary)}`;
        }
      } catch { image = null; }
      finally { const next = this.waiters.shift(); if (next) next(); else this.active--; }
      if (generation === this.generation) {
        const ttl = image ? 7 * 86400000 : 3600000;
        this.cache.set(origin, image, ttl);
        await this.persistence?.set(origin, image, ttl);
      }
      return generation === this.generation ? image : null;
    })();
    this.inFlight.set(origin, task);
    try { return await task; } finally { if (this.inFlight.get(origin) === task) this.inFlight.delete(origin); }
  }
}

export class TabCache {
  constructor(browser, { now = Date.now, freshFor = 5000, retainFor = 120000 } = {}) {
    this.browser = browser; this.now = now; this.freshFor = freshFor; this.retainFor = retainFor;
    this.snapshot = null; this.loadedAt = 0; this.generation = 0; this.inFlight = null; this.dirty = false;
  }
  invalidate() { this.generation++; this.dirty = true; }
  async refresh() {
    if (this.inFlight) return this.inFlight;
    const task = (async () => {
      for (let attempt = 0; attempt < 2; attempt++) {
        const generation = this.generation;
        const tabs = await this.browser.tabs.query({});
        if (generation !== this.generation) continue;
        this.snapshot = tabs.filter(tab => tab.incognito !== true); this.loadedAt = this.now(); this.dirty = false;
        return this.snapshot;
      }
      throw new Error('Tabs changed while refreshing');
    })();
    this.inFlight = task;
    try { return await task; } finally { if (this.inFlight === task) this.inFlight = null; }
  }
  async get({ force = false, incognito = false } = {}) {
    if (incognito) return { tabs: (await this.browser.tabs.query({})).filter(tab => tab.incognito === true), refreshing: false };
    const age = this.now() - this.loadedAt;
    if (!force && !this.dirty && this.snapshot && age < this.freshFor) return { tabs: this.snapshot, refreshing: false };
    if (!force && this.snapshot && age < this.retainFor) {
      this.refresh().catch(() => {}); return { tabs: this.snapshot, refreshing: true };
    }
    return { tabs: await this.refresh(), refreshing: false };
  }
}
