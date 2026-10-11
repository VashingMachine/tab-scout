const validID = value => Number.isSafeInteger(value) && value >= 0;
export const validOverlayToken = value => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
const website = value => {
  try { return ['http:', 'https:'].includes(new URL(value).protocol); } catch { return false; }
};
const token = () => [...globalThis.crypto.getRandomValues(new Uint8Array(32))]
  .map(value => value.toString(16).padStart(2, '0')).join('');

export function createOverlayController({ browser, now = Date.now, createToken = token,
  ttlMs = 300000, timeoutMs = 2000, maxSessions = 16, setTimer = setTimeout, clearTimer = clearTimeout }) {
  const sessions = new Map();
  const frameURL = browser.runtime.getURL('overlay-frame.html');
  const live = session => sessions.get(session.tabId) === session && session.expires > now();
  const sameTab = (session, tab) => tab?.id === session.tabId && tab.windowId === session.windowId
    && tab.url === session.url && tab.incognito === session.incognito;

  function sendDismiss(session) {
    if (!session.token) return Promise.resolve();
    const { tabId, token } = session;
    return Promise.resolve().then(() => browser.tabs.sendMessage(tabId,
      { type: 'overlayDismiss', token }, { frameId: 0 })).catch(() => {});
  }
  function revoke(session, notify = true) {
    if (sessions.get(session.tabId) !== session) return;
    sessions.delete(session.tabId);
    clearTimer(session.timer);
    if (notify) void sendDismiss(session);
  }
  function renew(session) {
    clearTimer(session.timer);
    session.expires = now() + ttlMs;
    session.timer = setTimer(() => revoke(session), ttlMs);
    session.timer?.unref?.();
  }
  async function current(session, active = false) {
    if (!live(session)) { revoke(session); return false; }
    const tab = await browser.tabs.get(session.tabId).catch(() => null);
    if (!live(session) || !sameTab(session, tab) || (active && tab.active !== true)) {
      revoke(session); return false;
    }
    return true;
  }
  function bounded(operation, session) {
    let timer;
    const timeout = new Promise((_, reject) => {
      timer = setTimer(() => { revoke(session); reject(new Error('timeout')); }, timeoutMs);
      timer?.unref?.();
    });
    return Promise.race([operation, timeout]).finally(() => clearTimer(timer));
  }
  async function fallback(session) {
    if (!browser.action?.openPopup || !await current(session, true)) return false;
    try {
      await browser.action.openPopup({ windowId: session.windowId });
      return await current(session, true);
    } catch { return false; }
  }
  async function toggle(requestedTab) {
    let tab;
    try {
      if (validID(requestedTab?.id)) tab = await browser.tabs.get(requestedTab.id);
      else [tab] = await browser.tabs.query({ active: true, currentWindow: true });
    } catch { return { ok: false }; }
    if (!validID(tab?.id) || !validID(tab.windowId) || typeof tab.incognito !== 'boolean' || tab.active !== true) return { ok: false };
    const previous = sessions.get(tab.id);
    if (previous && live(previous) && sameTab(previous, tab)) {
      revoke(previous);
      return { ok: true, closed: true };
    }
    if (previous) revoke(previous);
    while (sessions.size >= maxSessions) revoke(sessions.values().next().value);
    const session = { tabId: tab.id, windowId: tab.windowId, url: tab.url, incognito: tab.incognito,
      token: null, documentId: null, childFrame: null, topAuthorized: false, phase: 'opening' };
    sessions.set(tab.id, session);
    renew(session);
    if (!website(tab.url) || !browser.scripting?.executeScript) {
      const opened = await bounded(fallback(session), session).catch(() => false);
      revoke(session, false);
      return { ok: opened, fallback: true };
    }
    try { session.token = createToken(); } catch { revoke(session, false); return { ok: false }; }
    if (!validOverlayToken(session.token)) { revoke(session, false); return { ok: false }; }
    const opening = (async () => {
      const frames = await browser.scripting.executeScript({ target: { tabId: tab.id, frameIds: [0] }, files: ['overlay.js'] });
      const frame = frames?.find(result => result.frameId === 0);
      if (typeof frame?.documentId === 'string') session.documentId = frame.documentId;
      if (!await current(session, true)) return false;
      const response = await browser.tabs.sendMessage(tab.id, { type: 'overlayOpen', token: session.token }, { frameId: 0 });
      if (!await current(session, true)) { void sendDismiss(session); return false; }
      if (response?.ok !== true) throw new Error('overlay');
      session.phase = 'open';
      return true;
    })();
    try {
      const opened = await bounded(opening, session);
      if (!opened) revoke(session);
      return { ok: opened };
    } catch {
      // Injection failure can fall back; a navigation or timeout must not open delayed UI.
      if (!await current(session, true)) return { ok: false };
      void sendDismiss(session);
      session.token = null;
      session.phase = 'fallback';
      const opened = await bounded(fallback(session), session).catch(() => false);
      revoke(session, false);
      return { ok: opened, fallback: true };
    }
  }
  async function validate(sender, overlayToken) {
    if (sender?.id !== browser.runtime.id || !validID(sender.frameId) || !validID(sender.tab?.id) || !validOverlayToken(overlayToken)) return null;
    const session = sessions.get(sender.tab.id);
    if (!session || session.token !== overlayToken || sender.tab.windowId !== session.windowId
      || sender.tab.incognito !== session.incognito || (sender.incognito !== undefined && sender.incognito !== session.incognito)) return null;
    const child = sender.frameId > 0;
    if (child) {
      if (sender.url !== frameURL || !session.topAuthorized) return null;
      const matchesFrame = () => !session.childFrame || (session.childFrame.id === sender.frameId
        && (!session.childFrame.documentId || session.childFrame.documentId === sender.documentId));
      if (!matchesFrame() || !await current(session, !session.childFrame) || !matchesFrame()) return null;
      if (!session.childFrame) session.childFrame = { id: sender.frameId, documentId: null };
      if (!session.childFrame.documentId && typeof sender.documentId === 'string') session.childFrame.documentId = sender.documentId;
    } else {
      const matchesDocument = () => !session.documentId || sender.documentId === session.documentId;
      if (!website(sender.url) || sender.url !== session.url || !matchesDocument() || !await current(session) || !matchesDocument()) return null;
      if (!session.documentId && typeof sender.documentId === 'string') session.documentId = sender.documentId;
      session.topAuthorized = true;
    }
    renew(session);
    return { surface: 'overlay', tabId: session.tabId, windowId: session.windowId,
      incognito: session.incognito, overlayToken, ...(child ? { frameId: sender.frameId } : {}) };
  }
  async function verify(context) {
    const session = sessions.get(context.tabId);
    return !!session && session.token === context.overlayToken && session.windowId === context.windowId
      && session.incognito === context.incognito && (context.frameId === undefined || session.childFrame?.id === context.frameId)
      && await current(session);
  }
  async function ready(context) {
    const session = sessions.get(context.tabId);
    if (!session || !validID(context.frameId) || context.frameId === 0 || session.childFrame?.id !== context.frameId
      || !await verify(context) || !await current(session, true)) return false;
    const response = await browser.tabs.sendMessage(session.tabId,
      { type: 'overlayReady', token: session.token }, { frameId: 0 }).catch(() => null);
    return response?.ok === true && await current(session, true);
  }
  async function dismiss(tabId, overlayToken) {
    const session = sessions.get(tabId);
    if (!session || session.token !== overlayToken) return;
    revoke(session, false);
    void sendDismiss(session);
  }
  function install() {
    browser.commands?.onCommand?.addListener((command, tab) => {
      if (command === 'toggle-search') void toggle(tab).catch(() => {});
    });
    const invalidate = tabId => {
      if (!validID(tabId)) return;
      const session = sessions.get(tabId); if (session) revoke(session);
    };
    for (const name of ['onRemoved', 'onMoved', 'onAttached', 'onDetached']) browser.tabs[name]?.addListener(invalidate);
    browser.tabs.onReplaced?.addListener((added, removed) => { invalidate(added); invalidate(removed); });
    browser.tabs.onUpdated?.addListener((tabId, changes) => {
      if (changes && ['url', 'status', 'incognito', 'windowId'].some(key => Object.hasOwn(changes, key))) invalidate(tabId);
    });
    browser.tabs.onActivated?.addListener(info => {
      for (const session of sessions.values()) if (session.windowId === info.windowId && session.tabId !== info.tabId) revoke(session);
    });
  }
  return { toggle, validate, verify, ready, dismiss, install };
}
