import { address, normalize, targetIdentity, eligibleSuggestionQuery } from "./core.mjs";

const sectionTitles = { tabs: "Open Tabs", recent: "Recent Searches", history: "History", suggestions: "Google Suggestions" };
const providerTitles = { google: "Google", bing: "Bing", duckduckgo: "DuckDuckGo" };

export function mergeSuggestionRows(rows, suggestions, query) {
  if (!normalize(query)) return [...rows];
  const seen = new Set([normalize(query)]);
  for (const row of rows) {
    if (row.target?.kind === "query") seen.add(normalize(row.target.query));
  }
  const remote = [];
  for (const candidate of suggestions) {
    if (typeof candidate !== "string") continue;
    const title = candidate.trim();
    const key = normalize(title);
    if (!key || seen.has(key)) continue;
    seen.add(key);
    remote.push({ id: `suggestion:${key}`, kind: "suggestion", section: "suggestions", title,
      subtitle: "Google", target: { kind: "query", query: title } });
    if (remote.length === 8) break;
  }
  return [...rows, ...remote];
}

export function retainedSelectedRow(previous, rows) {
  if (!previous) return null;
  if (rows.some(row => row.id === previous.id)) return previous.id;
  const identity = targetIdentity(previous.target);
  const candidates = rows.filter(row => {
    if (identity && targetIdentity(row.target) === identity) return true;
    if (previous.target?.kind === "url" && row.target?.kind === "tab" && row.url) {
      return identity !== null && identity === targetIdentity({ kind: "url", url: row.url });
    }
    if (previous.target?.kind === "tab" && previous.url && row.target?.kind === "url") {
      const urlIdentity = targetIdentity({ kind: "url", url: previous.url });
      return urlIdentity !== null && urlIdentity === targetIdentity(row.target);
    }
    return false;
  });
  return candidates.length === 1 ? candidates[0].id : null;
}

export function nextSelection(rows, selectedID, step) {
  if (!rows.length || ![1, -1].includes(step)) return null;
  const current = rows.findIndex(row => row.id === selectedID);
  if (current === -1) return rows[0].id;
  return rows[Math.max(0, Math.min(rows.length - 1, current + step))].id;
}

export function formatLastUsed(timestamp, now = Date.now(), locale = globalThis.navigator?.language) {
  if (!Number.isFinite(timestamp) || timestamp <= 0 || timestamp > now) return null;
  const seconds = Math.floor((now - timestamp) / 1000);
  if (!seconds) return "Just now";
  const [value, unit] = seconds < 60 ? [seconds, "second"]
    : seconds < 3600 ? [Math.floor(seconds / 60), "minute"]
    : seconds < 86400 ? [Math.floor(seconds / 3600), "hour"]
    : seconds < 2592000 ? [Math.floor(seconds / 86400), "day"]
    : seconds < 31536000 ? [Math.floor(seconds / 2592000), "month"]
    : [Math.floor(seconds / 31536000), "year"];
  return new Intl.RelativeTimeFormat(locale, { numeric: "always" }).format(-value, unit);
}

export function formatRowDetail(row, engine = "google", now = Date.now(), locale = globalThis.navigator?.language) {
  const subtitle = row.subtitle || "";
  if (row.kind === "tab") {
    const window = Number.isSafeInteger(row.windowNumber) && row.windowNumber > 0 ? ` | Window ${row.windowNumber}` : "";
    return (subtitle || "Start Page") + window;
  }
  const age = ["history", "recent"].includes(row.kind) ? formatLastUsed(row.lastUsed, now, locale) : null;
  if (row.kind === "recent") return age || subtitle;
  if (row.kind === "history") return subtitle + (age ? ` | ${age}` : "");
  if (row.kind === "action") {
    if (row.target?.kind === "newtab") return "Safari default page";
    const query = typeof row.target?.query === "string" ? row.target.query.trim() : "";
    if (!query) return "Tab Scout search page";
    if (address(query)) return "New Safari tab";
    const provider = Object.hasOwn(providerTitles, engine) ? providerTitles[engine] : "Google";
    return `${provider} search`;
  }
  return subtitle;
}

export function formatResultSummary(rows, query, inventory = null) {
  if (normalize(query)) {
    const local = rows.filter(row => ["tab", "history", "recent"].includes(row.kind)).length;
    const suggestions = rows.filter(row => row.kind === "suggestion").length;
    return `${local} local ${local === 1 ? "result" : "results"}`
      + (suggestions ? ` | ${suggestions} Google suggestions` : "");
  }
  const tabs = rows.filter(row => row.kind === "tab");
  const validCount = value => Number.isSafeInteger(value) && value >= 0;
  const count = validCount(inventory?.tabCount) ? inventory.tabCount : tabs.length;
  const windows = validCount(inventory?.windowCount) ? inventory.windowCount
    : new Set(tabs.map(row => row.windowNumber).filter(value => Number.isSafeInteger(value) && value > 0)).size;
  return `${count} ${count === 1 ? "tab" : "tabs"} in ${windows} ${windows === 1 ? "window" : "windows"}`;
}

export async function startSearch(api, { root = document, surface = document.body?.dataset.surface,
  onClose = () => window.close(), signal, initialState } = {}) {
  const input = root.querySelector("#query");
  const results = root.querySelector("#results");
  const status = root.querySelector("#status");
  const summary = root.querySelector("#summary");
  const providerStatus = root.querySelector("#provider-status");
  const refresh = root.querySelector("#refresh");
  const settingsButton = root.querySelector("#settings");
  const clear = root.querySelector("#clear-search");
  const popup = surface === "popup";
  const overlay = surface === "overlay";
  const lifetime = new AbortController();
  const listen = (target, event, handler) => target.addEventListener(event, handler, { signal: lifetime.signal });
  let disposed = false;
  let settings = { engine: "google", googleSuggestions: false, rememberChoices: true };
  let incognito = true;
  let baseRows = [];
  let inventory = null;
  let rows = [];
  let suggestions = [];
  let selectedID = null;
  let generation = 0;
  let queryRequest = 0;
  let suggestTimer;
  let loading = true;
  let acting = false;
  let pendingActivation = null;
  const favicons = new Map();

  function dispose() {
    if (disposed) return;
    disposed = true;
    generation += 1;
    window.clearTimeout(suggestTimer);
    lifetime.abort();
    api.runtime.onMessage?.removeListener?.(tabsChanged);
    signal?.removeEventListener("abort", dispose);
    favicons.clear();
  }
  signal?.addEventListener("abort", dispose, { once: true });
  if (signal?.aborted) { dispose(); return dispose; }

  async function send(message) {
    const response = await api.runtime.sendMessage(message);
    if (disposed) throw new Error("Search closed.");
    if (!response?.ok) throw new Error(response?.error || "Tab Scout is unavailable.");
    return response;
  }

  function showStatus(text, error = false) {
    if (disposed) return;
    status.textContent = text;
    status.classList.toggle("is-error", error);
    status.hidden = !text;
  }

  function selectedRow() { return rows.find(row => row.id === selectedID); }

  function applySelection(scroll = false) {
    let active;
    for (const button of results.querySelectorAll(".result")) {
      const selected = button.dataset.rowId === selectedID;
      button.classList.toggle("is-selected", selected);
      button.setAttribute("aria-selected", String(selected));
      if (selected) active = button;
    }
    if (active) {
      input.setAttribute("aria-activedescendant", active.id);
      if (scroll) active.scrollIntoView({ block: "nearest" });
    } else input.removeAttribute("aria-activedescendant");
  }

  function fallbackIcon(row) {
    return row.kind === "recent" || row.kind === "history" ? "clock" : row.kind === "tab" ? "globe"
      : row.title === "New tab" || (row.kind === "action" && address(row.target?.query)) ? "square-plus" : "search";
  }

  async function favicon(url) {
    if (incognito) return null;
    if (!favicons.has(url)) {
      if (favicons.size >= 128) favicons.delete(favicons.keys().next().value);
      favicons.set(url, send({ type: "favicon", url }).then(response => {
        const image = response.image;
        return typeof image === "string" && /^data:image\/(?:png|jpeg|gif|webp|x-icon|vnd\.microsoft\.icon);base64,/i.test(image) ? image : null;
      }).catch(() => null));
    }
    return favicons.get(url);
  }

  function render(preserve = true) {
    const previous = preserve ? selectedRow() : null;
    rows = mergeSuggestionRows(baseRows, suggestions, input.value);
    selectedID = retainedSelectedRow(previous, rows) || rows[0]?.id || null;
    const fragment = document.createDocumentFragment();
    let section;
    rows.forEach((row, index) => {
      if (row.section !== section) {
        section = row.section;
        if (sectionTitles[section]) {
          const heading = document.createElement("div");
          heading.className = "section-label";
          heading.textContent = sectionTitles[section];
          heading.setAttribute("role", "presentation");
          fragment.append(heading);
        }
      }
      const button = document.createElement("button");
      button.type = "button";
      button.className = "result";
      button.id = `result-${index}`;
      button.dataset.rowId = row.id;
      button.setAttribute("role", "option");
      button.tabIndex = -1;
      button.title = [row.title, formatRowDetail(row, settings.engine)].filter(Boolean).join("\n");
      const icon = fallbackIcon(row);
      const image = document.createElement("img");
      image.className = "result-image is-symbol";
      image.dataset.icon = icon;
      image.dataset.kind = row.kind;
      const fallbackSource = `icons/${image.dataset.icon}.svg`;
      image.src = fallbackSource;
      image.onerror = () => {
        image.onerror = null;
        image.src = fallbackSource;
        image.classList.add("is-symbol");
      };
      image.alt = "";
      image.width = 23;
      image.height = 23;
      if (row.url && ["tab", "history"].includes(row.kind)) {
        favicon(row.url).then(data => {
          if (!data || disposed || !image.isConnected || button.dataset.rowId !== row.id) return;
          image.src = data;
          image.classList.remove("is-symbol");
        });
      }
      const text = document.createElement("span");
      text.className = "result-text";
      const title = document.createElement("span");
      title.className = "result-title";
      title.textContent = row.title;
      const detail = document.createElement("span");
      detail.className = "result-subtitle";
      detail.textContent = formatRowDetail(row, settings.engine);
      const detailLine = document.createElement("span");
      detailLine.className = "result-detail";
      detailLine.append(detail);
      text.append(title, detailLine);
      button.append(image, text);
      fragment.append(button);
    });
    results.replaceChildren(fragment);
    applySelection();
    summary.textContent = formatResultSummary(rows, input.value, inventory);
    clear.hidden = !input.value;
  }

  async function activate(forceNew = false) {
    if (acting || disposed) return;
    if (loading) { pendingActivation = { generation, forceNew }; return; }
    const target = forceNew ? { kind: "query", query: input.value.trim() } : selectedRow()?.target;
    if (!target) return;
    acting = true;
    input.readOnly = true;
    refresh.disabled = true;
    settingsButton.disabled = true;
    clear.disabled = true;
    showStatus("Opening...");
    try {
      const response = await send({ type: "activate", target, forceNew });
      if (popup && response.closePopup) window.close();
      if (overlay && response.closeOverlay) onClose();
      showStatus("");
    } catch (error) {
      showStatus(error.message, true);
    } finally {
      if (disposed) return;
      acting = false;
      input.readOnly = false;
      refresh.disabled = false;
      settingsButton.disabled = false;
      clear.disabled = false;
      input.focus();
    }
  }

  async function runQuery(ticket, force = false, preserve = true) {
    const request = ++queryRequest;
    const query = input.value;
    refresh.disabled = true;
    try {
      const response = await send({ type: "query", query, ...(force ? { force: true } : {}) });
      if (disposed || ticket !== generation || request !== queryRequest || acting || response.query !== query) return;
      baseRows = Array.isArray(response.rows) ? response.rows.filter(row => typeof row.id === "string" && typeof row.title === "string" && row.target) : [];
      inventory = response.inventory;
      loading = false;
      render(preserve);
      showStatus(baseRows.length ? "" : "No results");
      if (pendingActivation?.generation === ticket) {
        const pending = pendingActivation;
        pendingActivation = null;
        activate(pending.forceNew);
      } else if (response.refreshing && !force) {
        providerStatus.textContent = "Refreshing tabs...";
        runQuery(ticket, true, true);
      } else if (providerStatus.textContent === "Refreshing tabs...") providerStatus.textContent = "";
    } catch (error) {
      if (ticket !== generation || request !== queryRequest || acting) return;
      loading = false;
      pendingActivation = null;
      showStatus(error.message, true);
    } finally {
      if (ticket === generation && request === queryRequest && !acting) refresh.disabled = false;
    }
  }

  function requestSuggestions(ticket) {
    window.clearTimeout(suggestTimer);
    providerStatus.textContent = "";
    if (!settings.googleSuggestions || incognito) return;
    const query = eligibleSuggestionQuery(input.value);
    if (!query) return;
    suggestTimer = window.setTimeout(async () => {
      if (ticket !== generation || acting) return;
      providerStatus.textContent = "Google...";
      try {
        const response = await send({ type: "suggest", query });
        if (ticket !== generation || acting || !settings.googleSuggestions || incognito || response.query !== query) return;
        suggestions = Array.isArray(response.suggestions) ? response.suggestions : [];
        if (!loading) render(true);
        providerStatus.textContent = "";
      } catch {
        if (ticket === generation && !acting) providerStatus.textContent = "Suggestions unavailable";
      }
    }, 180);
  }

  function queryChanged() {
    if (acting) return;
    generation += 1;
    pendingActivation = null;
    suggestions = [];
    baseRows = [];
    rows = [];
    selectedID = null;
    loading = true;
    render(false);
    showStatus("Searching...");
    runQuery(generation, false, false);
    requestSuggestions(generation);
  }

  async function loadState() {
    const response = await send({ type: "state" });
    settings = response.settings;
    incognito = response.context?.incognito !== false;
    root.querySelector("#private-badge").hidden = !incognito;
  }

  listen(input, "input", queryChanged);
  listen(input, "keydown", event => {
    if (event.isComposing) return;
    if (["ArrowDown", "ArrowUp"].includes(event.key) && !event.metaKey && !event.ctrlKey && !event.altKey && !event.shiftKey) {
      event.preventDefault();
      selectedID = nextSelection(rows, selectedID, event.key === "ArrowDown" ? 1 : -1);
      applySelection(true);
    } else if (event.key === "Enter") {
      event.preventDefault();
      activate(event.metaKey || event.ctrlKey);
    } else if (event.key === "Escape" && (popup || overlay)) {
      event.preventDefault();
      if (!acting) onClose();
    }
  });
  listen(root.querySelector("#search-form"), "submit", event => { event.preventDefault(); activate(); });
  listen(results, "mousedown", event => {
    if (event.target.closest(".result")) event.preventDefault();
  });
  listen(results, "click", event => {
    const button = event.target.closest("button[data-row-id]");
    if (!button || !rows.some(row => row.id === button.dataset.rowId)) return;
    selectedID = button.dataset.rowId;
    applySelection();
    activate();
  });
  listen(clear, "click", () => { input.value = ""; queryChanged(); input.focus(); });
  listen(refresh, "click", () => { favicons.clear(); runQuery(generation, true, true); input.focus(); });
  listen(settingsButton, "click", async () => {
    try {
      await api.runtime.openOptionsPage();
      if (popup) window.close();
      if (overlay) onClose();
    } catch { showStatus("Settings could not be opened.", true); }
  });
  function tabsChanged(message) {
    if (message?.type === "tabsChanged" && !acting) runQuery(generation, false, true);
  }
  api.runtime.onMessage?.addListener(tabsChanged);
  listen(document, "visibilitychange", async () => {
    if (document.hidden || acting) return;
    try { await loadState(); suggestions = []; runQuery(generation, false, true); requestSuggestions(generation); }
    catch (error) { showStatus(error.message, true); }
  });
  listen(window, "pagehide", dispose);
  input.focus({ preventScroll: true });
  try {
    if (initialState) {
      settings = initialState.settings;
      incognito = initialState.context?.incognito !== false;
      root.querySelector("#private-badge").hidden = !incognito;
    } else await loadState();
    if (disposed) return dispose;
    queryChanged();
    input.focus();
  } catch (error) { loading = false; showStatus(error.message, true); }
  return dispose;
}

const api = globalThis.browser || globalThis.chrome;
if (typeof document !== "undefined" && ["popup", "newtab"].includes(document.body?.dataset.surface)
  && ["popup.html", "newtab.html"].some(file => api?.runtime?.getURL?.(file) === location.href.split("#")[0])) {
  if (api?.runtime?.sendMessage) startSearch(api);
  else {
    const status = document.querySelector("#status");
    if (status) { status.textContent = "Tab Scout is not connected to Safari."; status.classList.add("is-error"); }
  }
}
