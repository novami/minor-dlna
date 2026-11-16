"use strict";

const TYPES = [
  ["movies", "Filmy"], ["shows", "Seriály"], ["videos", "Videa"], ["photos", "Fotky"], ["music", "Hudba"],
];
const $app = document.getElementById("app");
let state = null;      // server state
let draft = null;      // edited settings
let step = 0;          // wizard step
const TABS = ["home", "library", "settings"];
// The menu bar links to a tab with #library etc.
let tab = TABS.includes(location.hash.slice(1)) ? location.hash.slice(1) : (sessionStorageGet("tab") || "home");
let upd = null;        // update state
let browse = { trail: [{ id: "0", title: "Knihovny" }], data: null };

function sessionStorageGet(k) { try { return sessionStorage.getItem(k); } catch (_) { return null; } }
function sessionStorageSet(k, v) { try { sessionStorage.setItem(k, v); } catch (_) { /* private mode */ } }

const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
// Shortens only the current user's home to "~"; other users' folders keep their full path.
const short = (p) => {
  p = p || "";
  const home = state && state.home;
  if (home && (p === home || p.startsWith(home + "/"))) return "~" + p.slice(home.length);
  return p;
};
const typeName = (t) => TYPES.find(([v]) => v === t)?.[1] || t;

class LoginRequired extends Error {}

async function api(path, body) {
  const opts = body === undefined ? {} : {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-MinorDLNA": "1" },
    body: JSON.stringify(body),
  };
  const res = await fetch(path, opts);
  const data = await res.json().catch(() => ({}));
  if (res.status === 401) throw new LoginRequired();
  if (!res.ok) throw new Error(data.error || "Požadavek selhal.");
  return data;
}

async function load() {
  try {
    state = await api("/api/state");
  } catch (e) {
    if (e instanceof LoginRequired) return renderLogin();
    throw e;
  }
  draft = {
    name: state.setup_needed && state.name === "MinorDLNA" ? `MinorDLNA (${state.computer_name})` : state.name,
    libraries: state.libraries.map((l) => ({ name: l.name, type: l.type, paths: [...l.paths] })),
    dts: state.setup_needed ? null : state.dts,
    hwaccel: state.hwaccel,
    autostart: state.setup_needed ? true : state.autostart,
    auto_update: state.auto_update,
    menubar: state.menubar,
    metadata: state.metadata,
    tmdb_token: null, // null = keep the saved token
    remote: state.remote,
    password: "",
  };
  render();
  if (!state.setup_needed) { loadUpdate(); loadStorage(); loadMeta(); tvLoad(); loadClients(); }
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
  if (state.setup_needed) { $app.innerHTML = wizard(); return; }
  const tabs = [["home", "Přehled"], ["library", "Knihovna"], ["settings", "Nastavení"]];
  $app.innerHTML = `<nav class="tabs">${tabs.map(([k, t]) =>
    `<button class="${k === tab ? "active" : ""}" onclick="setTab('${k}')">${t}</button>`).join("")}</nav>
    <div id="tab">${tab === "home" ? home() : tab === "library" ? libraryView() : settings()}</div>`;
  if (tab === "library" && !browse.data) openFolder(browse.trail[browse.trail.length - 1].id);
}

window.setTab = (t) => { tab = t; sessionStorageSet("tab", t); history.replaceState(null, "", "#" + t); render(); };
window.addEventListener("hashchange", () => {
  const t = location.hash.slice(1);
  if (TABS.includes(t) && t !== tab && state && !state.setup_needed) { tab = t; render(); }
});

// ---------- login (other devices) ----------

function renderLogin() {
  document.getElementById("subtitle").textContent = "Přihlášení";
  document.getElementById("status").hidden = true;
  $app.innerHTML = `<section class="card narrow">
    <h2>Správa serveru</h2>
    <p class="hint">Zadejte heslo nastavené na Macu se serverem.</p>
    <form onsubmit="login(event)">
      <input type="password" id="pw" placeholder="Heslo" autocomplete="current-password" autofocus>
      <div class="error" id="error"></div>
      <div class="actions"><button class="primary" type="submit">Přihlásit</button></div>
    </form></section>`;
}

window.login = async (ev) => {
  ev.preventDefault();
  try {
    await api("/api/login", { password: document.getElementById("pw").value });
    await load();
  } catch (e) { showError(e.message); }
};

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
  const chips = state.is_local ? (state.suggestions || []).filter((s) => !used.has(s.paths[0])) : [];
  return `
    ${chips.length ? `<div class="chips">${chips.map((s) =>
      `<button class="chip" onclick="addSuggestion('${esc(s.paths[0])}')">+ ${esc(s.name)} <span class="addr">${esc(short(s.paths[0]))}</span></button>`).join("")}</div>` : ""}
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
    <span class="addr" style="margin-left:8px">${state.is_local ? "Otevře se okno pro výběr složky na tomto Macu." : "Zadáte cestu ke složce na Macu se serverem."}</span>`;
}

function dtsChoice() {
  const opt = (v, title, sub) => `
    <label><input type="radio" name="dts" ${draft.dts === v ? "checked" : ""} onchange="draft.dts=${v}">${title}<small>${sub}</small></label>`;
  return `<div class="choice">
    ${opt(false, "Nevím / Ne", "Zvuk DTS se převede, přehraje se vždy.")}
    ${opt(true, "Ano", "Moje TV DTS přehraje sama.")}
  </div>`;
}

function toggle(key, title, sub) {
  return `<div class="switch">
    <div><b>${title}</b><small>${sub}</small></div>
    <label class="toggle"><input type="checkbox" ${draft[key] ? "checked" : ""} onchange="draft['${key}']=this.checked;${key === "remote" ? "render()" : ""}"><span></span></label>
  </div>`;
}

async function pick() {
  if (!state.is_local) {
    const p = prompt("Cesta ke složce na Macu se serverem (např. /Users/jmeno/Movies):");
    return p ? p.trim() : null;
  }
  try {
    const r = await api("/api/pick-folder", {});
    return r.path || null;
  } catch (e) { showError(e.message); return null; }
}

window.addLibrary = async () => {
  const p = await pick();
  if (!p) return;
  const base = (p.split("/").filter(Boolean).pop() || p).normalize("NFC");
  draft.libraries.push({ name: uniqueName(base), type: guessType(p), paths: [p] });
  render();
};
window.addSuggestion = (path) => {
  const s = state.suggestions.find((s) => s.paths[0] === path);
  if (!s) return;
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
  if (el) el.textContent = msg; else if (msg) alert(msg);
}

async function save(btn) {
  showError("");
  if (draft.dts === null) draft.dts = false;
  btn.disabled = true;
  try {
    await api("/api/config", { ...draft });
    await waitForRestart("Restartuji server…");
  } catch (e) {
    showError(e.message);
    btn.disabled = false;
  }
}
window.save = save;

async function waitForRestart(text, wantVersion) {
  const overlay = document.getElementById("overlay");
  document.getElementById("overlay-text").textContent = text;
  overlay.hidden = false;
  await new Promise((r) => setTimeout(r, 1500));
  for (let i = 0; i < 120; i++) {
    try {
      const s = await api("/api/state");
      if (!wantVersion || s.version === wantVersion) break;
    } catch (e) { if (e instanceof LoginRequired) break; }
    await new Promise((r) => setTimeout(r, 1000));
  }
  overlay.hidden = true;
  step = 0;
  browse.data = null;
  await load();
}

function ffmpegNotice() {
  return `<div class="notice">Pro převod formátů, které televize neumí, a pro náhledy videí nainstalujte ffmpeg:
    <code>brew install ffmpeg</code> a server restartujte.</div>`;
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
      <p class="hint">Umí vaše televize přehrát zvuk DTS? Záleží na značce, modelu a roce.</p>
      ${dtsChoice()}
      <div style="height:12px"></div>
      ${toggle("autostart", "Spouštět po přihlášení", "Server poběží na pozadí, TV ho najde i bez otevírání aplikace.")}
      ${toggle("auto_update", "Automatické aktualizace", "Nové verze se nainstalují samy, nikdy během přehrávání.")}
      ${state.ffmpeg ? "" : ffmpegNotice()}
      <div class="error" id="error"></div>
      <div class="actions"><button class="left link" onclick="go(1)">Zpět</button>
        <button class="primary" onclick="save(this)">Dokončit a spustit</button></div>
    </section>`;
}

window.go = (s) => { step = s; render(); };

// ---------- home ----------

function stats() {
  return state.libraries.map((l) => `
    <div class="stat"><b>${l.count.toLocaleString("cs-CZ")}</b><span>${l.name.normalize("NFC") === typeName(l.type) ? esc(l.name) : `${esc(l.name)} · ${typeName(l.type)}`}</span></div>`).join("");
}

function home() {
  return `
    <section class="card">
      <h2>Knihovny</h2>
      <p class="hint">Změny ve složkách se projeví do minuty. Na televizi otevřete <b>Média</b> nebo <b>Připojená zařízení</b>.</p>
      <div id="scan">${scanInfo()}</div>
      <div class="stats">${stats()}</div>
      ${state.ffmpeg ? "" : ffmpegNotice()}
      <div class="actions"><button onclick="rescan(this)">Prohledat znovu</button></div>
    </section>
    <section class="card" id="tvcard">${tvCard()}</section>
    <section class="card" id="updates">${updatesCard()}</section>
    <section class="card" id="storage">${storageCard()}</section>
    <div class="foot">
      <span>Verze ${esc(state.version)} · ${state.addresses.map((a) => `<span class="addr">${esc(a)}</span>`).join(" ")}</span>
      <span>${state.is_local ? "" : `<button class="link" onclick="logout()">Odhlásit</button>`}
      <button class="danger" onclick="quitServer()">Ukončit server</button></span>
    </div>`;
}

function updatesCard() {
  const u = upd;
  if (!u) return `<h2>Aktualizace</h2><p class="hint">Načítám…</p>`;
  const when = u.last_check && !u.last_check.startsWith("0001") ? new Date(u.last_check).toLocaleString("cs-CZ") : "zatím ne";
  let body;
  if (u.status === "installing") body = `<p class="hint">Instaluji novou verzi…</p>`;
  else if (u.latest) body = `
      <p class="hint">K dispozici je verze <b>${esc(u.latest.version)}</b>.</p>
      ${u.latest.notes ? `<pre class="notes">${esc(u.latest.notes)}</pre>` : ""}
      <div class="actions">${u.installable
        ? `<button class="primary" onclick="installUpdate('${esc(u.latest.version)}')">Nainstalovat a restartovat</button>`
        : `<a class="button" href="${esc(u.latest.url)}" target="_blank" rel="noopener">Stáhnout z GitHubu</a>`}</div>`;
  else body = `<p class="hint">${u.installable ? "Máte nejnovější verzi." : "Vývojová verze – automatické aktualizace jsou vypnuté."} Poslední kontrola: ${esc(when)}.</p>`;
  return `<h2>Aktualizace</h2>${body}
    ${u.error ? `<div class="error">${esc(u.error)}</div>` : ""}
    ${u.latest || u.status === "installing" ? "" : `<div class="actions"><button onclick="checkUpdate(this)">Zkontrolovat aktualizace</button></div>`}`;
}

async function loadUpdate() {
  try { upd = await api("/api/update"); } catch (_) { return; }
  const el = document.getElementById("updates");
  if (el) el.innerHTML = updatesCard();
}

window.checkUpdate = async (btn) => {
  btn.disabled = true;
  btn.textContent = "Kontroluji…";
  try { upd = await api("/api/update/check", {}); } catch (e) { showError(e.message); }
  const el = document.getElementById("updates");
  if (el) el.innerHTML = updatesCard();
};

window.installUpdate = async (version) => {
  if (!confirm(`Nainstalovat verzi ${version}? Server se na chvíli restartuje.`)) return;
  await api("/api/update/install", {}).catch((e) => alert(e.message));
  await waitForRestart(`Instaluji verzi ${version}…`, version);
};

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
window.logout = async () => { await api("/api/logout", {}).catch(() => {}); renderLogin(); };

function scanInfo() {
  if (!state.scanning) return "";
  const p = state.progress || {};
  let text = "Indexuji knihovny…";
  if (p.library) text = `Prohledávám knihovnu „${esc(p.library)}“${p.files ? ` – nalezeno ${p.files.toLocaleString("cs-CZ")} souborů` : ""}…`;
  else if (p.probing) text = `Zjišťuji délku a formát u ${p.probing.toLocaleString("cs-CZ")} souborů…`;
  return `<div class="progress"><div class="bar"></div><span>${text}</span></div>`;
}

// ---------- storage ----------

let storage = null;

function fmtBytes(n) {
  const u = ["B", "kB", "MB", "GB", "TB"];
  let i = 0;
  while (n >= 1000 && i < u.length - 1) { n /= 1000; i++; }
  return `${n.toLocaleString("cs-CZ", { maximumFractionDigits: n < 10 && i ? 1 : 0 })} ${u[i]}`;
}

function storageCard() {
  if (!storage) return `<h2>Místo na disku</h2><p class="hint">Načítám…</p>`;
  return `<h2>Místo na disku</h2>
    <p class="hint">Aplikace zabírá celkem <b>${fmtBytes(storage.total)}</b>. Vaše média se nepočítají ani nemažou.</p>
    <div class="usage">${storage.parts.filter((p) => p.bytes > 0 || !p.cleanable).map((p) => `
      <div class="usage-row"><span>${esc(p.title)}${p.cleanable ? ` <small>lze pročistit</small>` : ""}</span><b>${fmtBytes(p.bytes)}</b></div>`).join("")}
    </div>
    <div class="actions"><span class="addr left">Náhledy se po pročištění vytvoří znovu při procházení.</span>
      <button onclick="cleanStorage(this)" ${storage.cleanable > 0 ? "" : "disabled"}>Pročistit ${storage.cleanable > 0 ? fmtBytes(storage.cleanable) : ""}</button></div>`;
}

async function loadStorage() {
  try { storage = await api("/api/storage"); } catch (_) { return; }
  const el = document.getElementById("storage");
  if (el) el.innerHTML = storageCard();
}

window.cleanStorage = async (btn) => {
  if (!confirm(`Smazat náhledy, zálohu indexu, staré protokoly a předchozí verzi aplikace (${fmtBytes(storage.cleanable)})? Index knihoven a nastavení zůstanou.`)) return;
  btn.disabled = true;
  try { storage = await api("/api/storage/clean", {}); } catch (e) { alert(e.message); }
  document.getElementById("storage").innerHTML = storageCard();
};

// ---------- library ----------

function libraryView() {
  const d = browse.data;
  const crumbs = browse.trail.map((c, i) => i === browse.trail.length - 1
    ? `<span>${esc(c.title)}</span>`
    : `<button class="link" onclick="crumb(${i})">${esc(c.title)}</button>`).join(`<span class="sep">›</span>`);
  if (!d) return `<div class="crumbs">${crumbs}</div><p class="hint">Načítám…</p>`;
  if (!d.items.length) return `<div class="crumbs">${crumbs}</div><section class="card"><p class="hint">Tady zatím nic není.</p></section>`;
  return `<div class="crumbs">${crumbs}</div>
    <div class="grid ${d.items.every((i) => i.kind === "photo") ? "photos" : d.items.some((i) => i.poster) ? "posters" : ""}">${d.items.map(card).join("")}</div>
    ${d.items.length < d.total ? `<div class="actions"><button onclick="more(this)">Načíst další (${d.total - d.items.length})</button></div>` : ""}`;
}

function card(it, i) {
  const icon = it.dir ? "📁" : it.kind === "audio" ? "♪" : it.kind === "photo" ? "🖼" : "▶";
  const art = it.art ? `<img loading="lazy" src="${esc(it.art)}" alt="" onerror="this.replaceWith(Object.assign(document.createElement('div'),{className:'ph',textContent:'${icon}'}))">` : `<div class="ph">${icon}</div>`;
  const sub = it.dir ? (it.count >= 0 ? `${it.count} položek` : "") : (it.info || "");
  const seen = it.watched ? `<span class="seen">✓</span>` : "";
  const bar = it.position_ms > 0 && it.duration_ms ? `<div class="pbar"><i style="width:${Math.min(100, it.position_ms / it.duration_ms * 100).toFixed(1)}%"></i></div>` : "";
  return `<button class="tile" onclick="openItem(${i})" title="${esc(it.title)}">
    <div class="art">${art}${seen}${bar}</div>
    <div class="meta"><b>${esc(it.title)}</b>${sub ? `<small>${esc(sub)}</small>` : ""}</div>
  </button>`;
}

async function openFolder(id) {
  try {
    browse.data = await api("/api/browse?id=" + encodeURIComponent(id));
  } catch (e) {
    if (e instanceof LoginRequired) return renderLogin();
    browse.data = { items: [], total: 0 };
  }
  if (tab === "library") document.getElementById("tab").innerHTML = libraryView();
}

window.openItem = (i) => {
  const it = browse.data.items[i];
  if (it.dir) {
    browse.trail.push({ id: it.id, title: it.title });
    browse.data = null;
    document.getElementById("tab").innerHTML = libraryView();
    openFolder(it.id);
  } else if (it.kind === "photo" && it.large) {
    lightbox(i);
  } else if (it.kind === "audio") {
    const tracks = browse.data.items.filter((t) => t.kind === "audio");
    musicPlay(tracks, tracks.indexOf(it));
  } else if (it.kind === "video") {
    tvSheet(it);
  }
};

window.crumb = (i) => {
  browse.trail = browse.trail.slice(0, i + 1);
  browse.data = null;
  document.getElementById("tab").innerHTML = libraryView();
  openFolder(browse.trail[i].id);
};

window.more = async (btn) => {
  btn.disabled = true;
  const id = browse.trail[browse.trail.length - 1].id;
  const next = await api(`/api/browse?id=${encodeURIComponent(id)}&start=${browse.data.items.length}`);
  browse.data.items.push(...next.items);
  document.getElementById("tab").innerHTML = libraryView();
};

function lightbox(i) {
  const photos = browse.data.items.map((it, idx) => ({ it, idx })).filter((p) => p.it.kind === "photo");
  let pos = photos.findIndex((p) => p.idx === i);
  const box = document.createElement("div");
  box.className = "lightbox";
  const show = () => {
    const it = photos[pos].it;
    box.innerHTML = `<img src="${esc(it.large)}" alt=""><div class="cap">${esc(it.title)}</div>
      <button class="nav prev">‹</button><button class="nav next">›</button><button class="close">×</button>`;
  };
  const close = () => { box.remove(); document.removeEventListener("keydown", key); };
  const move = (d) => { pos = (pos + d + photos.length) % photos.length; show(); };
  const key = (e) => { if (e.key === "Escape") close(); if (e.key === "ArrowRight") move(1); if (e.key === "ArrowLeft") move(-1); };
  box.addEventListener("click", (e) => {
    if (e.target.classList.contains("prev")) move(-1);
    else if (e.target.classList.contains("next")) move(1);
    else if (e.target.tagName !== "IMG") close();
  });
  document.addEventListener("keydown", key);
  show();
  document.body.appendChild(box);
}

// ---------- settings ----------

function settings() {
  const remoteHint = state.addresses.length ? `Správa pak půjde otevřít z telefonu nebo jiného počítače: ${state.addresses.map((a) => `<span class="addr">${esc(a)}</span>`).join(", ")}` : "";
  return `
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
      ${toggle("autostart", "Spouštět po přihlášení", "Server poběží na pozadí, TV ho najde i bez otevírání aplikace.")}
      ${toggle("auto_update", "Automatické aktualizace", "Nové verze se nainstalují samy, nikdy během přehrávání.")}
      ${state.in_app ? toggle("menubar", "Ikona v řádku nabídek", "Ukazuje, že server běží, a nabízí rychlé volby: správa, knihovna, prohledání, aktualizace, ukončení.") : ""}
      ${toggle("metadata", "Názvy, popisy a plakáty filmů", "Hledá filmy a seriály na Wikidatech a Wikipedii (posílá tam jejich názvy). Bez klíče a zdarma.")}
      ${draft.metadata ? tmdbField() : ""}
      ${toggle("remote", "Přístup z jiných zařízení", "Správa chráněná heslem. " + remoteHint)}
      ${draft.remote ? `<label class="field">${state.remote ? "Nové heslo (prázdné = ponechat)" : "Heslo (aspoň 8 znaků)"}</label>
        <input type="password" autocomplete="new-password" value="${esc(draft.password)}" oninput="draft.password=this.value">` : ""}
      <div class="error" id="error"></div>
      <div class="actions"><button class="primary" onclick="save(this)">Uložit</button></div>
    </section>
    <section class="card" id="clients">${clientsCard()}</section>
    ${state.metadata ? `<section class="card" id="meta">${metaCard()}</section>` : ""}`;
}

// ---------- TVs and players ----------

let clients = null; // { clients, options }

function clientsCard() {
  const head = `<h2>Televize a přehrávače</h2>
    <p class="hint">Server pozná značku televize sám a posílá jí jen formáty, které umí – ostatní převede. Když se video na některém zařízení nepřehraje, vyberte mu profil ručně.</p>`;
  if (!clients) return head + `<p class="hint">Načítám…</p>`;
  if (!clients.clients.length) return head + `<p class="hint">Zatím se žádné zařízení nepřipojilo. Otevřete server na televizi a obnovte.</p>
    <div class="actions"><button onclick="loadClients()">Obnovit</button></div>`;
  const label = (id) => clients.options.find((o) => o.id === id)?.label || id;
  return head + `<div class="meta-list">${clients.clients.map((c) => `
      <div class="meta-row">
        <div class="ph">📺</div>
        <div class="meta-text"><b>${esc(c.name || c.ip)}</b><small title="${esc(c.ident)}">${c.name ? esc(c.ip) + " · " : ""}${esc(c.ident || "dosud nepřipojeno")}</small></div>
        <select onchange="setClientProfile('${esc(c.ip)}', this.value)">
          <option value="" ${c.profile ? "" : "selected"}>Automaticky: ${esc(label(c.detected))}</option>
          ${clients.options.map((o) => `<option value="${esc(o.id)}" ${c.profile === o.id ? "selected" : ""}>${esc(o.label)}</option>`).join("")}
        </select>
      </div>`).join("")}</div>
    <div class="error" id="clients-error"></div>
    <div class="actions"><button onclick="loadClients()">Obnovit</button></div>`;
}

function clientsRender() {
  const el = document.getElementById("clients");
  if (el) el.innerHTML = clientsCard();
}

async function loadClients() {
  try { clients = await api("/api/clients"); } catch (_) { return; }
  clientsRender();
}
window.loadClients = loadClients;

window.setClientProfile = async (ip, profile) => {
  try {
    await api("/api/clients/profile", { ip, profile });
    await loadClients();
  } catch (e) {
    const el = document.getElementById("clients-error");
    if (el) el.textContent = e.message;
  }
};

function tmdbField() {
  if (draft.tmdb_token === "" && state.tmdb) {
    return `<p class="hint">TMDb token se po uložení odebere. <button class="link" onclick="draft.tmdb_token=null;render()">Ponechat</button></p>`;
  }
  return `<label class="field">TMDb token (nepovinné – víc plakátů a delší české popisy)</label>
    <input type="password" autocomplete="off" placeholder="${state.tmdb ? "Token je uložen, prázdné = ponechat" : "API Read Access Token z themoviedb.org"}"
      value="${esc(draft.tmdb_token || "")}" oninput="draft.tmdb_token=this.value||null">
    ${state.tmdb ? `<button class="link" onclick="draft.tmdb_token='';render()">Odebrat token</button>` : ""}`;
}

// ---------- movie metadata ----------

let meta = null;       // { items, tmdb }
let metaEdit = null;   // { id, q, results, busy }

function metaStatus(e) {
  if (e.status === 3) return `<small>bez metadat</small>`;
  if (e.status === 0) return e.checked ? `<small class="warn">nenalezeno</small>` : `<small>hledám…</small>`;
  return `${esc(e.title)}${e.year ? ` (${e.year})` : ""}${e.status === 2 ? ` <small>ručně</small>` : ""}`;
}

function metaCard() {
  const head = `<h2>Metadata filmů a seriálů</h2>
    <p class="hint">Údaje z <a href="https://www.wikidata.org" target="_blank" rel="noopener">Wikidat</a> (CC0) a <a href="https://cs.wikipedia.org" target="_blank" rel="noopener">Wikipedie</a> (CC BY-SA)${meta?.tmdb ? `, plakáty a popisy z <a href="https://www.themoviedb.org" target="_blank" rel="noopener">TMDb</a>. Tento produkt používá TMDb API, ale není TMDb podporován ani certifikován` : ""}.</p>`;
  if (!meta) return head + `<p class="hint">Načítám…</p>`;
  if (!meta.items.length) return head + `<p class="hint">Zatím tu nejsou žádné filmy ani seriály.</p>`;
  const missing = meta.items.filter((e) => e.status === 0 && e.checked).length;
  return head + (missing ? `<p class="hint">${missing} ${missing === 1 ? "titul se nepodařilo" : "titulů se nepodařilo"} najít automaticky – vyberte ho ručně.</p>` : "") +
    `<div class="meta-list">${meta.items.map((e) => `
      <div class="meta-row">
        ${e.poster ? `<img src="${esc(e.poster)}" alt="">` : `<div class="ph">${e.kind === "shows" ? "📺" : "🎬"}</div>`}
        <div class="meta-text"><b>${metaStatus(e)}</b><small>${esc(e.file_title)}${e.file_year ? ` (${e.file_year})` : ""}</small></div>
        <button class="link" onclick="metaOpen(${e.id})">Změnit</button>
      </div>
      ${metaEdit && metaEdit.id === e.id ? metaEditor(e) : ""}`).join("")}
    </div>`;
}

function metaEditor(e) {
  const r = metaEdit.results;
  return `<div class="meta-edit">
    <form class="meta-search" onsubmit="metaSearch(event)">
      <input type="text" id="meta-q" value="${esc(metaEdit.q)}" placeholder="Název filmu nebo seriálu">
      <button ${metaEdit.busy ? "disabled" : ""}>Hledat</button>
    </form>
    ${r === null ? "" : r.length ? r.map((c) => `
      <button class="meta-cand" onclick="metaSet(${e.id}, '${esc(c.id)}')" ${metaEdit.busy ? "disabled" : ""}>
        <b>${esc(c.title)}${c.year ? ` (${c.year})` : ""}</b><small>${esc(c.description || "")}</small></button>`).join("")
      : `<p class="hint">Nic nenalezeno, zkuste jiný název (třeba originální).</p>`}
    <div class="actions">
      ${e.status !== 0 ? `<button class="link left" onclick="metaRematch(${e.id})">Vyhledat znovu automaticky</button>` : ""}
      <button class="link" onclick="metaSet(${e.id}, '')">Bez metadat</button>
      <button onclick="metaEdit=null;metaRender()">Zavřít</button>
    </div>
  </div>`;
}

function metaRender() {
  const el = document.getElementById("meta");
  if (el) el.innerHTML = metaCard();
}

async function loadMeta() {
  if (!state.metadata) return;
  try { meta = await api("/api/meta"); } catch (_) { return; }
  metaRender();
}

window.metaOpen = (id) => {
  const e = meta.items.find((x) => x.id === id);
  metaEdit = { id, q: e.file_title, results: null, busy: false };
  metaRender();
  document.getElementById("meta-q")?.focus();
};

window.metaSearch = async (ev) => {
  ev.preventDefault();
  metaEdit.q = document.getElementById("meta-q").value.trim();
  if (!metaEdit.q) return;
  metaEdit.busy = true; metaRender();
  try {
    metaEdit.results = await api("/api/meta/search?id=" + metaEdit.id + "&q=" + encodeURIComponent(metaEdit.q));
  } catch (e) { alert(e.message); }
  metaEdit.busy = false; metaRender();
};

window.metaSet = async (id, wikidata) => {
  metaEdit.busy = true; metaRender();
  try {
    await api("/api/meta/set", { id, wikidata });
    metaEdit = null;
  } catch (e) { alert(e.message); metaEdit.busy = false; }
  loadMeta();
};

window.metaRematch = async (id) => {
  try { await api("/api/meta/set", { id, rematch: true }); } catch (e) { return alert(e.message); }
  metaEdit = null;
  loadMeta();
  setTimeout(loadMeta, 5000);
};

// Refresh counts while scanning, without touching unsaved edits.
setInterval(async () => {
  if (!state || state.setup_needed || tab !== "home" || document.getElementById("overlay").hidden === false) return;
  try {
    const s = await api("/api/state");
    const changed = s.scanning !== state.scanning || JSON.stringify(s.libraries.map((l) => l.count)) !== JSON.stringify(state.libraries.map((l) => l.count));
    state = s;
    if (changed) {
      header();
      const el = document.querySelector(".stats");
      if (el) el.innerHTML = stats();
    }
    const scan = document.getElementById("scan");
    if (scan) scan.innerHTML = scanInfo();
    if (changed && !s.scanning) loadStorage();
  } catch (_) { /* restarting or logged out */ }
}, 3000);

load().catch((e) => { $app.innerHTML = `<section class="card"><h2>Chyba</h2><p class="hint">${esc(e.message)}</p></section>`; });
