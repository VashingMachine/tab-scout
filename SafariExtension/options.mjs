async function startOptions(api) {
  const form = document.querySelector("#settings-form");
  const engine = document.querySelector("#engine");
  const google = document.querySelector("#google-suggestions");
  const remember = document.querySelector("#remember-choices");
  const clear = document.querySelector("#clear-choices");
  const status = document.querySelector("#settings-status");
  let settings;
  let saving = false;

  function showStatus(text, error = false) {
    status.textContent = text;
    status.classList.toggle("is-error", error);
  }

  function setDisabled(disabled) {
    for (const control of form.querySelectorAll("input, select, button")) control.disabled = disabled;
  }

  function render() {
    engine.value = settings.engine;
    google.checked = settings.googleSuggestions;
    remember.checked = settings.rememberChoices;
  }

  async function send(message) {
    const response = await api.runtime.sendMessage(message);
    if (!response?.ok) throw new Error(response?.error || "Settings are unavailable.");
    return response;
  }

  form.addEventListener("submit", event => event.preventDefault());
  form.addEventListener("change", async event => {
    if (!settings || saving) return;
    if (event.target === google && google.checked && !window.confirm("Send eligible typed searches to Google for suggestions? Cookies, local history, and private browsing searches are not sent.")) {
      google.checked = false;
      return;
    }
    const next = { engine: engine.value, googleSuggestions: google.checked, rememberChoices: remember.checked };
    saving = true;
    setDisabled(true);
    showStatus("Saving...");
    try {
      const response = await send({ type: "settings", settings: next });
      settings = response.settings;
      render();
      showStatus("Saved");
    } catch (error) {
      render();
      showStatus(error.message, true);
    } finally { saving = false; setDisabled(false); }
  });
  clear.addEventListener("click", async () => {
    if (saving || !window.confirm("Clear searches and tab choices saved by Tab Scout? Browser history is not changed.")) return;
    saving = true;
    setDisabled(true);
    try { await send({ type: "clearChoices" }); showStatus("Tab Scout history cleared"); }
    catch (error) { showStatus(error.message, true); }
    finally { saving = false; setDisabled(false); }
  });
  setDisabled(true);
  try {
    const response = await send({ type: "state" });
    settings = response.settings;
    render();
    showStatus("");
    setDisabled(false);
  } catch (error) { showStatus(error.message, true); }
}

const api = globalThis.browser || globalThis.chrome;
if (typeof document !== "undefined") {
  if (api?.runtime?.sendMessage) startOptions(api);
  else {
    document.querySelector("#settings-status").textContent = "Tab Scout is not connected to Safari.";
    for (const control of document.querySelectorAll("input, select, button")) control.disabled = true;
  }
}
