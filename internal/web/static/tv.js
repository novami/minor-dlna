"use strict";
// Play to TV: the TV list, the item sheet and the remote control bar. Loaded before app.js.

const tv = { devices: [], session: null, searching: false, sheet: null, dragging: false, dismissed: "", tick: 0 };
const TV_STATES = {
  STARTING: "Spouštím…", WAKING: "Zapínám televizi…", TRANSITIONING: "Načítám…",
  PLAYING: "Přehrává", PAUSED_PLAYBACK: "Pozastaveno", STOPPED: "Zastaveno", NO_MEDIA_PRESENT: "Načítám…",
};

function fmtTime(ms) {
  const s = Math.max(0, Math.floor((ms || 0) / 1000));
  const h = Math.floor(s / 3600), m = Math.floor(s / 60) % 60, sec = String(s % 60).padStart(2, "0");
  return h ? `${h}:${String(m).padStart(2, "0")}:${sec}` : `${m}:${sec}`;
}

function tvChosen() {
  let udn = null;
  try { udn = localStorage.getItem("tv"); } catch (_) { /* private mode */ }
  return tv.devices.find((d) => d.udn === udn) || tv.devices.find((d) => d.online) || tv.devices[0];
}
window.tvChoose = (udn) => { try { localStorage.setItem("tv", udn); } catch (_) { /* private mode */ } tvRenderSheet(); };

async function tvLoad() {
  try { tvApply(await api("/api/tv")); } catch (_) { /* restarting or logged out */ }
}

function tvApply(d) {
  const was = tv.session && tv.session.state !== "STOPPED";
  tv.devices = d.devices || [];
  tv.session = d.session;
  const now = tv.session && tv.session.state !== "STOPPED";
  // Playback ended: the library shows the new progress.
  if (was && !now && typeof tab !== "undefined" && tab === "library" && browse.trail.length) openFolder(browse.trail[browse.trail.length - 1].id);
  tvRenderBar();
  tvRenderSheet();
  const card = document.getElementById("tvcard");
  if (card) card.innerHTML = tvCard();
}

window.tvSearch = async () => {
  tv.searching = true; tvRenderSheet();
  const card = document.getElementById("tvcard");
  if (card) card.innerHTML = tvCard();
  try { tvApply(await api("/api/tv/search", {})); } catch (e) { alert(e.message); }
  tv.searching = false; tvApply({ devices: tv.devices, session: tv.session });
};

window.tvWake = async (i) => {
  try { await api("/api/tv/wake", { udn: tv.devices[i].udn }); } catch (e) { return alert(e.message); }
  alert("Televize se zapíná. Za chvíli ji vyhledám znovu.");
  setTimeout(tvSearch, 15000);
};

// ---------- overview card ----------

function tvCard() {
  const rows = tv.devices.map((d, i) => `
    <div class="usage-row tv-row">
      <span><b>${esc(d.name)}</b><small>${esc(d.ip)}${d.mac ? "" : " · MAC neznámá"}</small></span>
      <span>${d.online ? `<small class="on">zapnutá</small>` : d.mac
        ? `<button class="link" onclick="tvWake(${i})">Zapnout</button>` : `<small>nedostupná</small>`}</span>
    </div>`).join("");
  return `<h2>Televize</h2>
    <p class="hint">Filmy a hudbu z knihovny pustíte na televizi tlačítkem <b>Přehrát na TV</b>. Televize musí mít zapnuté sdílení obsahu (DLNA); pro zapínání přes síť povolte <b>Zapnout přes Wi-Fi/LAN</b>.</p>
    ${tv.devices.length ? `<div class="usage">${rows}</div>` : `<p class="hint">${tv.searching ? "Hledám…" : "Zatím žádná televize."}</p>`}
    <div class="actions"><button onclick="tvSearch()" ${tv.searching ? "disabled" : ""}>${tv.searching ? "Hledám…" : "Hledat televize"}</button></div>`;
}

// ---------- item sheet ----------

window.tvSheet = (it) => {
  tv.sheet = { it, error: "", busy: false };
  const bg = document.createElement("div");
  bg.className = "sheet-bg";
  bg.id = "sheet";
  bg.addEventListener("click", (e) => { if (e.target === bg) tvCloseSheet(); });
  document.body.appendChild(bg);
  document.addEventListener("keydown", tvSheetKey);
  tvRenderSheet();
  if (!tv.devices.some((d) => d.online)) tvSearch();
};

function tvSheetKey(e) { if (e.key === "Escape") tvCloseSheet(); }
window.tvCloseSheet = () => {
  document.getElementById("sheet")?.remove();
  document.removeEventListener("keydown", tvSheetKey);
  tv.sheet = null;
};

function tvRenderSheet() {
  const el = document.getElementById("sheet");
  if (!el || !tv.sheet) return;
  const { it, error, busy } = tv.sheet;
  const dev = tvChosen();
  const resume = it.position_ms >= 30000 && !it.watched;
  const progress = it.watched ? `<p class="seen-line">✓ Zhlédnuto</p>`
    : it.position_ms > 0 ? `<p class="seen-line">Rozkoukáno v ${fmtTime(it.position_ms)}${it.duration_ms ? ` z ${fmtTime(it.duration_ms)}` : ""}</p>` : "";
  const devState = (d) => d.online ? "" : d.mac ? " (vypnutá – zkusím ji zapnout)" : " (nedostupná)";
  const picker = !tv.devices.length
    ? `<p class="hint">${tv.searching ? "Hledám televize…" : "Žádná televize nenalezena. Zapněte ji a povolte na ní sdílení obsahu (DLNA)."}</p>`
    : tv.devices.length === 1 ? `<p class="hint">Televize: <b>${esc(dev.name)}</b>${devState(dev)}</p>`
    : `<label class="field">Televize</label><select onchange="tvChoose(this.value)">${tv.devices.map((d) =>
      `<option value="${esc(d.udn)}" ${d.udn === dev.udn ? "selected" : ""}>${esc(d.name)}${devState(d)}</option>`).join("")}</select>`;
  const can = dev && !busy;
  el.innerHTML = `<div class="sheet">
    <button class="x close" onclick="tvCloseSheet()" aria-label="Zavřít">×</button>
    <div class="sheet-head">
      ${it.art ? `<img class="${it.poster ? "poster" : ""}" src="${esc(it.art)}" alt="">` : ""}
      <div><h2>${esc(it.title)}</h2>${it.info ? `<small>${esc(it.info)}</small>` : ""}${progress}</div>
    </div>
    ${it.desc ? `<p class="desc">${esc(it.desc)}</p>` : ""}
    ${picker}
    <div class="actions">
      <button class="link left" onclick="tvSearch()" ${tv.searching ? "disabled" : ""}>${tv.searching ? "Hledám…" : "Hledat znovu"}</button>
      ${resume ? `<button onclick="tvPlay(0)" ${can ? "" : "disabled"}>Od začátku</button>
        <button class="primary" onclick="tvPlay(${it.position_ms})" ${can ? "" : "disabled"}>Pokračovat od ${fmtTime(Math.max(it.position_ms - 5000, 0))}</button>`
      : `<button class="primary" onclick="tvPlay(0)" ${can ? "" : "disabled"}>Přehrát na TV</button>`}
    </div>
    <div class="error">${esc(error)}</div>
  </div>`;
}

window.tvPlay = async (fromMs) => {
  const dev = tvChosen();
  if (!dev || !tv.sheet) return;
  tv.sheet.busy = true; tv.sheet.error = ""; tvRenderSheet();
  try {
    tvApply(await api("/api/tv/play", { udn: dev.udn, id: tv.sheet.it.id, from_ms: fromMs }));
    tvCloseSheet();
  } catch (e) {
    tv.sheet.busy = false; tv.sheet.error = e.message; tvRenderSheet();
  }
};

// ---------- remote control ----------

function tvRenderBar() {
  const s = tv.session;
  const key = s ? s.id + "|" + (s.error || "") : "";
  const show = s && (s.state !== "STOPPED" || (s.error && tv.dismissed !== key));
  let bar = document.getElementById("remote");
  document.body.classList.toggle("has-remote", !!show);
  if (!show) { bar?.remove(); return; }
  if (!bar) {
    bar = document.createElement("div");
    bar.id = "remote";
    bar.className = "remote";
    document.body.appendChild(bar);
  }
  if (s.state === "STOPPED") {
    bar.innerHTML = `<div class="r-top"><span><b>${esc(s.title)}</b><small class="warn">${esc(s.error)}</small></span>
      <button class="x" onclick="tvDismiss()" aria-label="Zavřít">×</button></div>`;
    return;
  }
  if (tv.dragging) return;
  const ready = s.state === "PLAYING" || s.state === "PAUSED_PLAYBACK";
  const dur = s.duration_ms || 0;
  bar.innerHTML = `
    <div class="r-top"><span><b>${esc(s.title)}</b><small>${esc(s.tv)} · ${TV_STATES[s.state] || esc(s.state)}</small></span>
      <button class="x" onclick="tvCmd('stop')" title="Zastavit" aria-label="Zastavit">■</button></div>
    <div class="r-seek"><span>${fmtTime(s.position_ms)}</span>
      <input type="range" min="0" max="${dur}" step="1000" value="${Math.min(s.position_ms, dur)}" ${ready && dur ? "" : "disabled"}
        oninput="tv.dragging=true;this.previousElementSibling.textContent=fmtTime(+this.value)" onchange="tvSeek(+this.value)">
      <span>${dur ? fmtTime(dur) : "–"}</span></div>
    <div class="r-ctl">
      <button onclick="tvCmd('seek', ${Math.max(s.position_ms - 10000, 0)})" ${ready ? "" : "disabled"} title="Zpět o 10 s">−10 s</button>
      <button class="primary play" onclick="tvCmd('${s.state === "PLAYING" ? "pause" : "play"}')" ${ready ? "" : "disabled"}>${s.state === "PLAYING" ? "❚❚" : "▶"}</button>
      <button onclick="tvCmd('seek', ${dur ? Math.min(s.position_ms + 30000, dur - 1000) : s.position_ms + 30000})" ${ready ? "" : "disabled"} title="Vpřed o 30 s">+30 s</button>
      ${s.can_volume ? `<span class="vol">
        <button class="link" onclick="tvCmd('mute', ${s.muted ? 0 : 1})" title="Ztlumit">${s.muted ? "🔇" : "🔊"}</button>
        <input type="range" min="0" max="100" value="${s.volume}" onchange="tvCmd('volume', +this.value)"></span>` : ""}
    </div>`;
}

window.tvDismiss = () => { const s = tv.session; if (s) tv.dismissed = s.id + "|" + (s.error || ""); tvRenderBar(); };
window.tvSeek = (ms) => { tv.dragging = false; tvCmd("seek", ms); };
window.tvCmd = async (action, value) => {
  try { tvApply(await api("/api/tv/command", { action, value: Math.round(value || 0) })); } catch (e) { alert(e.message); }
};

// Poll often while something plays, otherwise only refresh the TV list now and then.
setInterval(() => {
  if (document.hidden || typeof state === "undefined" || !state || state.setup_needed) return;
  tv.tick++;
  const active = tv.session && tv.session.state !== "STOPPED";
  if (active || tv.sheet || tv.tick % 8 === 0) tvLoad();
}, 2000);
