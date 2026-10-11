import { startSearch } from "./search.mjs";

const api = globalThis.browser || globalThis.chrome;
const validToken = value => typeof value === "string" && /^[a-f0-9]{64}$/.test(value);
let authorized = false;
let closed = false;
const life = new AbortController();

window.addEventListener("message", async event => {
  const message = event.data;
  if (authorized || closed || !event.isTrusted || event.source !== window.parent || window === window.parent
    || !message || Object.keys(message).length !== 2 || message.type !== "overlayAuthorize" || !validToken(message.token)) return;
  authorized = true;
  const token = message.token;
  const send = message => api.runtime.sendMessage({ ...message, overlayToken: token });
  try {
    const state = await send({ type: "state" });
    if (!state?.ok || closed) throw new Error("Unauthorized overlay.");
    const response = await fetch(api.runtime.getURL("popup.html"));
    if (!response.ok || closed) throw new Error("Search UI unavailable.");
    const template = new DOMParser().parseFromString(await response.text(), "text/html");
    if (closed) return;
    document.body.replaceChildren(...[...template.body.children].map(node => document.importNode(node, true)));
    const close = () => {
      if (closed) return;
      closed = true;
      life.abort();
      void send({ type: "overlayClose" }).catch(() => {});
    };
    const scopedAPI = { runtime: { sendMessage: send, openOptionsPage: () => api.runtime.openOptionsPage() } };
    document.addEventListener("keydown", event => {
      if (event.isComposing) return;
      const input = document.querySelector("#query");
      const fieldNeedsFocus = [document.body, document.documentElement].includes(document.activeElement);
      // Safari can focus a new cross-origin frame before it permits focusing its field.
      // The first real keystroke supplies the gesture; retain that character as focus moves.
      if (event.isTrusted && fieldNeedsFocus && !input.readOnly
        && !event.metaKey && !event.ctrlKey && event.key !== "Tab" && event.key !== "Escape") {
        input.focus({ preventScroll: true });
        if (document.activeElement !== input) return;
        if (Array.from(event.key).length === 1) {
          event.preventDefault();
          input.setRangeText(event.key, input.selectionStart, input.selectionEnd, "end");
          input.dispatchEvent(new Event("input", { bubbles: true }));
        } else if (["Enter", "ArrowDown", "ArrowUp"].includes(event.key)) {
          event.preventDefault();
          input.dispatchEvent(new KeyboardEvent("keydown", { key: event.key, altKey: event.altKey,
            shiftKey: event.shiftKey, bubbles: true }));
        }
      } else if (event.isTrusted && fieldNeedsFocus && (event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "v") {
        input.focus({ preventScroll: true });
      }
      if (event.key === "Escape") {
        event.preventDefault();
        event.stopPropagation();
        if (!input.readOnly) close();
      } else if (event.key === "Tab" && !event.metaKey && !event.ctrlKey && !event.altKey) {
        const controls = [...document.querySelectorAll("#query, #clear-search, #refresh, #settings")]
          .filter(node => !node.hidden && !node.disabled);
        if (!controls.length) return;
        event.preventDefault();
        const index = controls.indexOf(document.activeElement);
        controls[(index + (event.shiftKey ? -1 : 1) + controls.length) % controls.length].focus();
      }
    }, { capture: true, signal: life.signal });
    // Only this extension-origin frame sees input events and result data.
    void startSearch(scopedAPI, { surface: "overlay", onClose: close, signal: life.signal, initialState: state });
    try { window.focus(); } catch {}
    document.querySelector("#query").focus({ preventScroll: true });
    const ready = await send({ type: "overlayReady" });
    if (!ready?.ok || closed) throw new Error("Overlay closed.");
    document.querySelector("#query").focus({ preventScroll: true });
  } catch {
    closed = true;
    life.abort();
    document.body.replaceChildren();
  }
}, { signal: life.signal });
window.addEventListener("pagehide", () => { closed = true; life.abort(); }, { once: true });
