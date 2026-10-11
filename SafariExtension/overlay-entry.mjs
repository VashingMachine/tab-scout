import css from "./overlay.css";

const api = globalThis.browser || globalThis.chrome;
const validToken = value => typeof value === "string" && /^[a-f0-9]{64}$/.test(value);
const exact = (value, keys) => value && typeof value === "object" && !Array.isArray(value)
  && Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key));

// This singleton lives in the extension's isolated world, never the website's JS world.
if (api?.runtime?.id && !globalThis.__tabScoutOverlayInstalled && window === window.top) {
  globalThis.__tabScoutOverlayInstalled = true;
  let current = null;
  let pendingToken = null;
  let generation = 0;
  const frameURL = api.runtime.getURL("overlay-frame.html");
  const url = new URL(frameURL);
  const extensionOrigin = `${url.protocol}//${url.host}`;

  function close(notify = true, restore = true) {
    generation += 1;
    pendingToken = null;
    const mount = current;
    current = null;
    if (!mount) return;
    mount.life.abort();
    mount.observer.disconnect();
    mount.finish(false);
    if (mount.host.matches(":popover-open")) mount.host.hidePopover();
    mount.host.remove();
    if (notify) void api.runtime.sendMessage({ type: "overlayClose", overlayToken: mount.token }).catch(() => {});
    if (restore && !document.hidden && mount.previous?.isConnected
      && (!document.activeElement || document.activeElement === document.body || document.activeElement === mount.host)) {
      mount.previous.focus?.({ preventScroll: true });
    }
  }

  async function open(token) {
    const ticket = ++generation;
    pendingToken = token;
    let state;
    try { state = await api.runtime.sendMessage({ type: "state", overlayToken: token }); }
    catch { return { ok: false }; }
    if (ticket !== generation || pendingToken !== token || !state?.ok || document.hidden
      || !["http:", "https:"].includes(location.protocol) || document.contentType !== "text/html") return { ok: false };
    close(false, false);
    const previous = document.activeElement;
    const host = document.createElement("div");
    host.dataset.tabScoutOverlay = "";
    host.popover = "manual";
    const shadow = host.attachShadow({ mode: "closed" });
    try {
      const sheet = new CSSStyleSheet();
      sheet.replaceSync(css);
      shadow.adoptedStyleSheets = [sheet];
    } catch { return { ok: false }; }
    const frame = document.createElement("iframe");
    frame.title = "Tab Scout";
    frame.src = frameURL;
    const life = new AbortController();
    let finish;
    const ready = new Promise(resolve => { finish = resolve; });
    const observer = new MutationObserver(() => { if (!host.isConnected) close(true, false); });
    current = { host, frame, token, previous, life, observer, finish };
    frame.addEventListener("load", () => {
      if (current?.token === token) frame.contentWindow.postMessage({ type: "overlayAuthorize", token }, extensionOrigin);
    }, { signal: life.signal });
    host.addEventListener("click", event => { if (event.target === host) close(); }, { signal: life.signal });
    document.addEventListener("visibilitychange", () => { if (document.hidden) close(true, false); }, { signal: life.signal });
    window.addEventListener("pagehide", () => close(true, false), { signal: life.signal });
    shadow.append(frame);
    document.documentElement.append(host);
    observer.observe(document.documentElement, { childList: true });
    try { host.showPopover(); } catch { close(false); return { ok: false }; }
    frame.focus({ preventScroll: true });
    const timer = window.setTimeout(() => { if (current?.token === token) close(false); }, 1500);
    const opened = await ready;
    window.clearTimeout(timer);
    if (opened && current?.token === token) {
      // Keep the foreground session alive across Safari's idle-worker shutdowns.
      const heartbeat = window.setInterval(async () => {
        try {
          const response = await api.runtime.sendMessage({ type: "state", overlayToken: token });
          if (!response?.ok && current?.token === token) close(false);
        } catch { if (current?.token === token) close(false); }
      }, 20000);
      life.signal.addEventListener("abort", () => window.clearInterval(heartbeat), { once: true });
    }
    return { ok: opened && current?.token === token };
  }

  api.runtime.onMessage.addListener((message, sender) => {
    if (sender?.id !== api.runtime.id || !exact(message, ["type", "token"]) || !validToken(message.token)) return;
    if (message.type === "overlayOpen") return open(message.token);
    if (message.type === "overlayReady" && current?.token === message.token) {
      current.frame.focus({ preventScroll: true });
      try { current.frame.contentWindow.focus(); } catch {}
      current.finish(true);
      return Promise.resolve({ ok: true });
    }
    if (message.type === "overlayDismiss" && (current?.token === message.token || pendingToken === message.token)) {
      if (current?.token === message.token) close(false);
      else { generation += 1; pendingToken = null; }
      return Promise.resolve({ ok: true });
    }
  });
}
