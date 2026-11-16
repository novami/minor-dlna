"use strict";

const TYPES = [
  ["movies", "Filmy"], ["shows", "Seriály"], ["videos", "Videa"], ["photos", "Fotky"], ["music", "Hudba"],
];
const $app = document.getElementById("app");
let state = null;   // server state
let draft = null;   // edited settings
let step = 0;       // wizard step

const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
// Shortens only the current user's home to "~"; other users' folders keep their full path.
const short = (p) => {
  p = p || "";
  const home = state && state.home;
  if (home && (p === home || p.startsWith(home + "/"))) return "~" + p.slice(home.length);
  return p;
};

async function api(path, body) {
  const opts = body === undefined ? {} : {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-MinorDLNA": "1" },
    body: JSON.stringify(body),
  };
  const res = await fetch(path, opts);
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || "Požadavek selhal.");
  return data;
}

async function load() {
  state = await api("/api/state");
  draft = {
    name: state.setup_needed && state.name === "MinorDLNA" ? `MinorDLNA (${state.computer_name})` : state.name,
    libraries: state.libraries.map((l) => ({ name: l.name, type: l.type, paths: [...l.paths] })),
    dts: state.setup_needed ? null : state.dts,
    hwaccel: state.hwaccel,
    autostart: state.setup_needed ? true : state.autostart,
  };
  render();
}

function header() {
  document.getElementById("subtitle").textContent = state.setup_needed ? "První nastavení" : `TV najde server jako „${state.name}“`;
  const pill = document.getElementById("status");
  pill.hidden = state.setup_needed;
  pill.className = "pill " + (state.scanning ? "" : "ok");
  pill.textContent = state.scanning ? "Prohledávám…" : "Běží";
}

function render() {
  header();
  $app.innerHTML = state.setup_needed ? wizard() : dashboard();
}

// ---------- shared editors ----------

function guessType(path) {
  const p = path.toLowerCase();
  if (/pictures|obrázky|fotky|photos/.test(p)) return "photos";
  if (/music|hudba/.test(p)) return "music";
  if (/seri[aá]l|series|tv shows/.test(p)) return "shows";
  if (/movies|filmy|films/.test(p)) return "movies";
  return "videos";
}

function libsEditor() {
  const used = new Set(draft.libraries.flatMap((l) => l.paths));
  const chips = (state.suggestions || []).filter((s) => !used.has(s.paths[0]));
  return `
    ${chips.length ? `<div class="chips">${chips.map((s, i) =>
      `<button class="chip" onclick="addSuggestion(${i})">+ ${esc(s.name)} <span class="addr">${esc(short(s.paths[0]))}</span></button>`).join("")}</div>` : ""}
    ${draft.libraries.map((l, i) => `
      <div class="lib">
        <div class="row">
          <input type="text" value="${esc(l.name)}" placeholder="Název knihovny" oninput="draft.libraries[${i}].name=this.value">
          <select onchange="draft.libraries[${i}].type=this.value">
            ${TYPES.map(([v, t]) => `<option value="${v}" ${v === l.type ? "selected" : ""}>${t}</option>`).join("")}
          </select>
          <button class="x" title="Odebrat knihovnu" onclick="removeLib(${i})">×</button>
        </div>
        ${l.paths.map((p, j) => `
          <div class="path"><code title="${esc(p)}">${esc(short(p))}</code>
            ${l.paths.length > 1 ? `<button class="x" title="Odebrat složku" onclick="removePath(${i},${j})">×</button>` : ""}
          </div>`).join("")}
        <button class="link" onclick="addPath(${i})">+ Další složka do této knihovny</button>
      </div>`).join("")}
    <button onclick="addLibrary()">+ Přidat složku</button>
    <span class="addr" style="margin-left:8px">Otevře se okno pro výběr složky na tomto Macu.</span>`;
}

function dtsChoice() {
  const opt = (v, title, sub) => `
    <label><input type="radio" name="dts" ${draft.dts === v ? "checked" : ""} onchange="draft.dts=${v}">${title}<small>${sub}</small></label>`;
  return `<div class="choice">
    ${opt(false, "Nevím / Ne", "Zvuk DTS se převede, přehraje se vždy.")}
    ${opt(true, "Ano", "Moje TV DTS přehraje sama.")}
  </div>`;
}

function autostartSwitch() {
  return `<div class="switch">
    <div><b>Spouštět po přihlášení</b><small>Server poběží na pozadí, TV ho najde i bez otevírání aplikace.</small></div>
    <label class="toggle"><input type="checkbox" ${draft.autostart ? "checked" : ""} onchange="draft.autostart=this.checked"><span></span></label>
  </div>`;
}

async function pick() {
  try {
    const r = await api("/api/pick-folder", {});
    return r.path || null;
  } catch (e) { showError(e.message); return null; }
}

window.addLibrary = async () => {
  const p = await pick();
  if (!p) return;
  const base = p.split("/").pop() || p;
  draft.libraries.push({ name: uniqueName(base), type: guessType(p), paths: [p] });
  render();
};
window.addSuggestion = (i) => {
  const s = state.suggestions.filter((s) => !draft.libraries.some((l) => l.paths.includes(s.paths[0])))[i];
  draft.libraries.push({ name: uniqueName(s.name), type: s.type, paths: [...s.paths] });
  render();
};
window.addPath = async (i) => {
  const p = await pick();
  if (p && !draft.libraries[i].paths.includes(p)) { draft.libraries[i].paths.push(p); render(); }
};
window.removePath = (i, j) => { draft.libraries[i].paths.splice(j, 1); render(); };
window.removeLib = (i) => { draft.libraries.splice(i, 1); render(); };

function uniqueName(name) {
  let n = name, k = 2;
  while (draft.libraries.some((l) => l.name === n)) n = `${name} ${k++}`;
  return n;
}

function showError(msg) {
  const el = document.getElementById("error");
  if (el) el.textContent = msg; else alert(msg);
}

async function save(btn) {
  showError("");
  if (draft.dts === null) draft.dts = false;
  btn.disabled = true;
  try {
    await api("/api/config", { ...draft });
    await waitForRestart();
  } catch (e) {
    showError(e.message);
    btn.disabled = false;
  }
}

async function waitForRestart() {
  const overlay = document.getElementById("overlay");
  overlay.hidden = false;
  await new Promise((r) => setTimeout(r, 1200));
  for (let i = 0; i < 40; i++) {
    try {
      const res = await fetch("/api/ping", { cache: "no-store" });
      if (res.ok) break;
    } catch (_) { /* restarting */ }
    await new Promise((r) => setTimeout(r, 500));
  }
  overlay.hidden = true;
  step = 0;
  await load();
}

// ---------- wizard ----------

function wizard() {
  const bar = `<div class="steps">${[0, 1, 2].map((i) => `<span class="${i <= step ? "done" : ""}"></span>`).join("")}</div>`;
  if (step === 0) return `<section class="card">${bar}
      <div class="hero">Vítejte v MinorDLNA</div>
      <p class="hint">Za minutu budete mít filmy, fotky a hudbu z tohoto Macu v televizi. Nic se nikam nenahrává, vše zůstává ve vaší síti.</p>
      <label class="field">Jak se má server jmenovat v televizi</label>
      <input type="text" value="${esc(draft.name)}" oninput="draft.name=this.value">
      <div class="actions"><button class="primary" onclick="go(1)">Pokračovat</button></div>
    </section>`;
  if (step === 1) return `<section class="card">${bar}
      <h2>Co chcete sdílet?</h2>
      <p class="hint">Přidejte složky s médii a zvolte jejich typ – podle něj televize nabídne třeba seriály po sériích nebo fotky podle data.</p>
      ${libsEditor()}
      <div class="error" id="error"></div>
      <div class="actions"><button class="left link" onclick="go(0)">Zpět</button>
        <button class="primary" onclick="go(2)" ${draft.libraries.length ? "" : "disabled"}>Pokračovat</button></div>
    </section>`;
  return `<section class="card">${bar}
      <h2>Poslední drobnosti</h2>
      <p class="hint">Umí vaše televize přehrát zvuk DTS? U LG záleží na modelu a roce.</p>
      ${dtsChoice()}
      <div style="height:12px"></div>
      ${autostartSwitch()}
      ${state.ffmpeg ? "" : ffmpegNotice()}
      <div class="error" id="error"></div>
      <div class="actions"><button class="left link" onclick="go(1)">Zpět</button>
        <button class="primary" onclick="save(this)">Dokončit a spustit</button></div>
    </section>`;
}

window.go = (s) => { step = s; render(); };

function ffmpegNotice() {
  return `<div class="notice">Pro převod formátů, které televize neumí, a pro náhledy videí nainstalujte ffmpeg:
    <code>brew install ffmpeg</code> a server restartujte.</div>`;
}

// ---------- dashboard ----------

function statLabel(l) {
  const type = TYPES.find(([v]) => v === l.type)?.[1] || l.type;
  return l.name === type ? esc(l.name) : `${esc(l.name)} · ${type}`;
}

function dashboard() {
  const libs = state.libraries.map((l) => `
    <div class="stat"><b>${l.count.toLocaleString("cs-CZ")}</b><span>${statLabel(l)}</span></div>`).join("");
  return `
    <section class="card">
      <h2>Knihovny</h2>
      <p class="hint">Změny ve složkách se projeví do minuty. Na televizi otevřete <b>Média</b> nebo <b>Připojená zařízení</b>.</p>
      <div class="stats">${libs}</div>
      ${state.ffmpeg ? "" : ffmpegNotice()}
      <div class="actions"><button onclick="rescan(this)">Prohledat znovu</button></div>
    </section>
    <section class="card">
      <h2>Nastavení</h2>
      <label class="field">Název serveru v televizi</label>
      <input type="text" value="${esc(draft.name)}" oninput="draft.name=this.value">
      <label class="field">Knihovny</label>
      ${libsEditor()}
      <label class="field">Zvuk DTS</label>
      ${dtsChoice()}
      <label class="field">Převod videa</label>
      <select onchange="draft.hwaccel=this.value">
        <option value="videotoolbox" ${draft.hwaccel === "videotoolbox" ? "selected" : ""}>Hardwarový (doporučeno, šetří procesor)</option>
        <option value="none" ${draft.hwaccel === "none" ? "selected" : ""}>Softwarový (vyšší kvalita, pomalejší)</option>
      </select>
      <div style="height:8px"></div>
      ${autostartSwitch()}
      <div class="error" id="error"></div>
      <div class="actions"><button class="primary" onclick="save(this)">Uložit</button></div>
    </section>
    <div class="foot">
      <span>Verze ${esc(state.version)} · ${state.addresses.map((a) => `<span class="addr">${esc(a)}</span>`).join(" ")}</span>
      <button class="danger" onclick="quitServer()">Ukončit server</button>
    </div>`;
}

window.save = save;
window.rescan = async (btn) => {
  btn.disabled = true;
  await api("/api/rescan", {}).catch((e) => showError(e.message));
  setTimeout(load, 800);
};
window.quitServer = async () => {
  if (!confirm("Ukončit server? Televize přestane vidět vaše média, dokud aplikaci znovu nespustíte.")) return;
  await api("/api/quit", {}).catch(() => {});
  $app.innerHTML = `<section class="card"><h2>Server je ukončen</h2><p class="hint">Znovu ho spustíte z Finderu nebo Spotlightu (MinorDLNA).</p></section>`;
  document.getElementById("status").hidden = true;
};

// Refresh counts while scanning, without touching unsaved edits.
setInterval(async () => {
  if (!state || state.setup_needed || document.getElementById("overlay").hidden === false) return;
  try {
    const s = await api("/api/state");
    const changed = s.scanning !== state.scanning || JSON.stringify(s.libraries.map((l) => l.count)) !== JSON.stringify(state.libraries.map((l) => l.count));
    state = s;
    if (changed) {
      header();
      const stats = document.querySelector(".stats");
      if (stats) stats.innerHTML = s.libraries.map((l) => `
        <div class="stat"><b>${l.count.toLocaleString("cs-CZ")}</b><span>${statLabel(l)}</span></div>`).join("");
    }
  } catch (_) { /* server restarting */ }
}, 3000);

load().catch((e) => { $app.innerHTML = `<section class="card"><h2>Chyba</h2><p class="hint">${esc(e.message)}</p></section>`; });
