import { normalize, targetIdentity, eligibleSuggestionQuery } from "./core.mjs";

const sectionTitles = { tabs: "Open Tabs", recent: "Recent Searches", history: "History", suggestions: "Google Suggestions" };

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

async function startSearch(api) {
  const input = document.querySelector("#query");
  const results = document.querySelector("#results");
  const status = document.querySelector("#status");
  const summary = document.querySelector("#summary");
  const providerStatus = document.querySelector("#provider-status");
  const refresh = document.querySelector("#refresh");
  const settingsButton = document.querySelector("#settings");
  const clear = document.querySelector("#clear-search");
  const popup = document.body.dataset.surface === "popup";
  let settings = { engine: "google", googleSuggestions: false, rememberChoices: true };
  let incognito = true;
  let baseRows = [];
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

  async function send(message) {
    const response = await api.runtime.sendMessage(message);
    if (!response?.ok) throw new Error(response?.error || "Tab Scout is unavailable.");
    return response;
  }

  function showStatus(text, error = false) {
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
    return row.kind === "recent" || row.kind === "history" ? "clock" : row.kind === "tab" ? "panels-top-left" : row.title === "New tab" ? "plus" : "search";
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
      button.title = [row.title, row.subtitle].filter(Boolean).join("\n");
      const image = document.createElement("img");
      image.className = "result-image is-symbol";
      const fallbackSource = `icons/${fallbackIcon(row)}.svg`;
      image.src = fallbackSource;
      image.onerror = () => {
        image.onerror = null;
        image.src = fallbackSource;
        image.classList.add("is-symbol");
      };
      image.alt = "";
      image.width = 24;
      image.height = 24;
      if (row.url && ["tab", "history"].includes(row.kind)) {
        favicon(row.url).then(data => {
          if (!data || !image.isConnected || button.dataset.rowId !== row.id) return;
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
      const age = ["history", "recent"].includes(row.kind) ? formatLastUsed(row.lastUsed) : null;
      detail.textContent = row.kind === "recent" && age ? age : row.subtitle || "";
      const detailLine = document.createElement("span");
      detailLine.className = "result-detail";
      detailLine.append(detail);
      if (row.kind === "history" && age) {
        const date = document.createElement("span");
        date.className = "result-date";
        date.textContent = age;
        detailLine.append(date);
      }
      text.append(title, detailLine);
      const action = document.createElement("img");
      action.className = "result-action";
      action.src = `icons/${row.target?.kind === "tab" ? "panels-top-left" : "arrow-up-right"}.svg`;
      action.alt = "";
      button.append(image, text, action);
      fragment.append(button);
    });
    results.replaceChildren(fragment);
    applySelection();
    const count = baseRows.filter(row => row.kind === "tab").length;
    summary.textContent = `${count} ${count === 1 ? "tab" : "tabs"}`;
    clear.hidden = !input.value;
  }

  async function activate(forceNew = false) {
    if (acting) return;
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
      showStatus("");
    } catch (error) {
      showStatus(error.message, true);
    } finally {
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
      if (ticket !== generation || request !== queryRequest || acting || response.query !== query) return;
      baseRows = Array.isArray(response.rows) ? response.rows.filter(row => typeof row.id === "string" && typeof row.title === "string" && row.target) : [];
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
    document.querySelector("#private-badge").hidden = !incognito;
  }

  input.addEventListener("input", queryChanged);
  input.addEventListener("keydown", event => {
    if (event.isComposing) return;
    if (["ArrowDown", "ArrowUp"].includes(event.key) && !event.metaKey && !event.ctrlKey && !event.altKey && !event.shiftKey) {
      event.preventDefault();
      selectedID = nextSelection(rows, selectedID, event.key === "ArrowDown" ? 1 : -1);
      applySelection(true);
    } else if (event.key === "Enter") {
      event.preventDefault();
      activate(event.metaKey || event.ctrlKey);
    } else if (event.key === "Escape" && popup) {
      event.preventDefault();
      if (!acting) window.close();
    }
  });
  document.querySelector("#search-form").addEventListener("submit", event => { event.preventDefault(); activate(); });
  results.addEventListener("mousedown", event => {
    if (event.target.closest(".result")) event.preventDefault();
  });
  results.addEventListener("click", event => {
    const button = event.target.closest("button[data-row-id]");
    if (!button || !rows.some(row => row.id === button.dataset.rowId)) return;
    selectedID = button.dataset.rowId;
    applySelection();
    activate();
  });
  clear.addEventListener("click", () => { input.value = ""; queryChanged(); input.focus(); });
  refresh.addEventListener("click", () => { favicons.clear(); runQuery(generation, true, true); input.focus(); });
  settingsButton.addEventListener("click", async () => {
    try {
      await api.runtime.openOptionsPage();
      if (popup) window.close();
    } catch { showStatus("Settings could not be opened.", true); }
  });
  api.runtime.onMessage?.addListener(message => {
    if (message?.type === "tabsChanged" && !acting) runQuery(generation, false, true);
  });
  document.addEventListener("visibilitychange", async () => {
    if (document.hidden || acting) return;
    try { await loadState(); suggestions = []; runQuery(generation, false, true); requestSuggestions(generation); }
    catch (error) { showStatus(error.message, true); }
  });
  try {
    await loadState();
    queryChanged();
    input.focus();
  } catch (error) { loading = false; showStatus(error.message, true); }
}

const api = globalThis.browser || globalThis.chrome;
if (typeof document !== "undefined") {
  if (api?.runtime?.sendMessage) startSearch(api);
  else {
    const status = document.querySelector("#status");
    if (status) { status.textContent = "Tab Scout is not connected to Safari."; status.classList.add("is-error"); }
  }
}
