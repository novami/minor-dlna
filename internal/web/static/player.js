"use strict";
// Web player: video overlay and music bar. Loaded after tv.js, before app.js.
//
// Files the browser plays are opened directly. Others come converted from ?t= seconds (fragmented MP4,
// HLS in Safari, which plays media only with byte ranges); seeking there restarts the stream at the new time.

const probe = document.createElement("video");
const HEVC = !!probe.canPlayType('video/mp4; codecs="hvc1.1.6.L120.90"');
const UA = navigator.userAgent;
const TOUCH = navigator.maxTouchPoints > 1; // iPhone and iPad, also with a desktop user agent
const USE_HLS =!!probe.canPlayType("application/vnd.apple.mpegurl") && /AppleWebKit/.test(UA) && !/Chrome|Chromium|Edg|Android/.test(UA);
// Dolby Vision profile 5 keeps its colours only in HLS, where the server copies it with its DV configuration.
const DV = USE_HLS && !!probe.canPlayType('video/mp4; codecs="dvh1.05.06"');

// A media element with an absolute timeline over direct or restarted streams.
function mediaStream(el) {
  const st = { info: null, offset: 0, token: "", retried: false };
  const stopHLS = () => {
    if (st.token) fetch("/api/play/hls/stop", { method: "POST", keepalive: true, headers: { "Content-Type": "application/json", "X-MinorDLNA": "1" }, body: JSON.stringify({ token: st.token }) }).catch(() => {});
    st.token = "";
  };
  return {
    st,
    async open(info, at, retry) {
      st.info = info; st.retried = !!retry;
      at = Math.max(0, at || 0);
      if (info.direct) {
        stopHLS();
        this.onopen?.(info, at);
        st.offset = 0;
        el.src = info.src;
        if (at) el.addEventListener("loadedmetadata", () => { el.currentTime = at; }, { once: true });
      } else {
        const r = await api("/api/play/start", { id: info.id, t: at, hevc: HEVC, dv: DV, hls: USE_HLS, sdr: TOUCH && !matchMedia("(video-dynamic-range: high)").matches, stop: st.token });
        st.token = r.token || ""; st.offset = r.start;
        this.onopen?.(info, r.start);
        el.src = (TOUCH && r.master) || r.url;
      }
      await el.play().catch((e) => { if (e.name === "NotAllowedError") this.onblocked?.(); });
    },
    abs() { return st.offset + (el.currentTime || 0); },
    duration() { return st.info?.duration_ms ? st.info.duration_ms / 1000 : (isFinite(el.duration) ? el.duration : 0); },
    seek(t) {
      const d = this.duration();
      t = Math.max(0, d ? Math.min(t, d - 1) : t);
      if (st.info.direct) el.currentTime = t;
      else this.open(st.info, t);
    },
    // A converted stream may die (server restart, idle HLS session); continue once from where it stopped.
    recover() {
      if (!st.info || st.info.direct || st.retried) return false;
      this.open(st.info, this.abs(), true).catch(() => {});
      return true;
    },
    close() {
      stopHLS();
      el.pause();
      el.removeAttribute("src");
      el.load(); // aborts the download, which stops ffmpeg
      st.info = null;
    },
  };
}

const savePosition = (id, posMs, durMs, keepalive) => fetch("/api/position", {
  method: "POST", keepalive, headers: { "Content-Type": "application/json", "X-MinorDLNA": "1" },
  body: JSON.stringify({ id, position_ms: Math.round(posMs), duration_ms: Math.round(durMs || 0) }),
}).catch(() => {});

const playInfo = (id) => api(`/api/play?id=${encodeURIComponent(id)}${HEVC ? "&hevc=1" : ""}${DV ? "&dv=1" : ""}`);

// ---------- video ----------

let vp = null; // { box, video, ms, saved, dragging, subsOn }

window.webPlay = async (fromMs) => {
  const it = tv.sheet?.it;
  if (!it) return;
  tvCloseSheet();
  if (it.kind === "audio") return musicPlay([it], 0);
  musicPause();
  // Safari allows sound only for a play() inside the click; the stream URL comes later, so unlock the element now.
  videoBox();
  vp.box.classList.add("loading");
  vp.video.play().catch(() => {});
  try {
    const info = await playInfo(it.id);
    videoOpen(info, (fromMs > 0 ? Math.max(fromMs - 5000, 0) : 0) / 1000);
  } catch (e) { videoClose(); alert(e.message); }
};

function videoBox() {
  if (!vp) {
    const box = document.createElement("div");
    box.className = "player";
    box.innerHTML = `<video playsinline></video>
      <div class="p-top"><b></b><button class="x" data-a="close" aria-label="Zavřít">×</button></div>
      <div class="p-bar"></div><div class="p-msg" hidden></div>`;
    document.body.appendChild(box);
    const video = box.querySelector("video");
    vp = { box, video, ms: mediaStream(video), saved: 0, dragging: false, subsOn: localGet("subs") !== "0", idle: 0 };
    video.addEventListener("timeupdate", videoTick);
    video.addEventListener("play", videoBar);
    video.addEventListener("pause", () => { videoSave(); videoBar(); });
    video.addEventListener("ended", videoEnded);
    video.addEventListener("error", () => { if (vp && vp.video.getAttribute("src") && !vp.ms.recover()) videoMsg("Video se nepodařilo přehrát."); });
    video.addEventListener("waiting", () => box.classList.add("loading"));
    video.addEventListener("playing", () => { box.classList.remove("loading"); videoMsg(""); vp.ms.st.retried = false; });
    video.addEventListener("click", () => { if (!vp.ms.st.info?.direct) videoToggle(); });
    box.addEventListener("click", videoClick);
    box.addEventListener("mousemove", videoWake);
    box.addEventListener("touchstart", videoWake, { passive: true });
    document.addEventListener("keydown", videoKey);
    window.addEventListener("pagehide", videoSaveNow);
  }
}

function videoOpen(info, at) {
  videoBox();
  vp.ms.onopen = videoSubs; // subtitles of a restarted stream are shifted to its new start
  vp.ms.onblocked = () => { vp.box.classList.remove("loading"); videoBar(); videoWake(); videoMsg("Spusťte přehrávání tlačítkem ▶."); };
  vp.box.querySelector(".p-top b").textContent = info.title;
  vp.video.controls = info.direct; // native controls seek well in direct files
  vp.box.classList.toggle("direct", info.direct);
  vp.box.classList.add("loading");
  videoMsg("");
  vp.ms.open(info, at).catch((e) => videoMsg(e.message));
  videoBar();
  videoWake();
}

function videoSubs(info, at) {
  if (!vp) return;
  vp.video.querySelectorAll("track").forEach((t) => t.remove());
  if (!info.subs) return;
  const tr = document.createElement("track");
  tr.kind = "subtitles"; tr.srclang = "cs"; tr.label = "Titulky";
  tr.src = `/api/play/${info.id.slice(1)}/subs.vtt${info.direct ? "" : `?t=${at.toFixed(1)}`}`;
  tr.default = vp.subsOn;
  vp.video.appendChild(tr);
  tr.addEventListener("load", () => { tr.track.mode = vp.subsOn ? "showing" : "hidden"; });
}

function videoBar() {
  if (!vp || vp.dragging) return;
  const info = vp.ms.st.info;
  const bar = vp.box.querySelector(".p-bar");
  if (!info) return;
  const subs = info.subs ? `<button class="link ${vp.subsOn ? "on" : ""}" data-a="subs" title="Titulky">CC</button>` : "";
  const next = info.next ? `<button class="link" data-a="next" title="${esc(info.next.title)}">Další díl ›</button>` : "";
  if (info.direct) { // native controls; keep only what they lack
    bar.innerHTML = subs || next ? `<div class="r-ctl">${subs}${next}</div>` : "";
    return;
  }
  const pos = vp.ms.abs(), dur = vp.ms.duration();
  const paused = vp.video.paused;
  bar.innerHTML = `
    <div class="r-seek"><span>${fmtTime(pos * 1000)}</span>
      <input type="range" min="0" max="${Math.round(dur)}" step="1" value="${Math.round(Math.min(pos, dur))}" ${dur ? "" : "disabled"}
        oninput="vp.dragging=true;this.previousElementSibling.textContent=fmtTime(this.value*1000)" onchange="vp.dragging=false;vp.ms.seek(+this.value)">
      <span>${dur ? fmtTime(dur * 1000) : "–"}</span></div>
    <div class="r-ctl">
      <button data-a="back" title="Zpět o 10 s">−10 s</button>
      <button class="primary play" data-a="toggle">${paused ? "▶" : "❚❚"}</button>
      <button data-a="fwd" title="Vpřed o 30 s">+30 s</button>
      ${subs}${next}
      <button class="link" data-a="full" title="Celá obrazovka">⛶</button>
    </div>`;
}

function videoTick() {
  if (!vp) return;
  if (!vp.ms.st.info?.direct) {
    const pos = vp.ms.abs();
    const r = vp.box.querySelector(".r-seek");
    if (r && !vp.dragging) { r.firstElementChild.textContent = fmtTime(pos * 1000); r.querySelector("input").value = Math.round(pos); }
  }
  if (Date.now() - vp.saved > 10000) videoSave();
}

function videoSave(keepalive) {
  const info = vp?.ms.st.info;
  const pos = vp ? vp.ms.abs() : 0;
  if (!info || pos < 1) return;
  vp.saved = Date.now();
  savePosition(info.id, pos * 1000, vp.ms.duration() * 1000, keepalive);
}
function videoSaveNow() { videoSave(true); }

async function videoEnded() {
  const info = vp.ms.st.info;
  savePosition(info.id, vp.ms.duration() * 1000, vp.ms.duration() * 1000);
  if (info.next) return videoNext();
  videoClose();
}

async function videoNext() {
  const info = vp.ms.st.info;
  if (!info?.next) return;
  videoSave();
  try { videoOpen(await playInfo(info.next.id), 0); } catch (e) { videoMsg(e.message); }
}

function videoClose() {
  if (!vp) return;
  videoSave(true);
  vp.ms.close();
  vp.box.remove();
  document.removeEventListener("keydown", videoKey);
  window.removeEventListener("pagehide", videoSaveNow);
  if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
  vp = null;
  // The library shows the new progress.
  if (typeof tab !== "undefined" && tab === "library" && browse.trail.length) openFolder(browse.trail[browse.trail.length - 1].id);
}

function videoToggle() { if (vp.video.paused) vp.video.play(); else vp.video.pause(); }

function videoFull() {
  if (document.fullscreenElement) return document.exitFullscreen();
  if (vp.box.requestFullscreen) vp.box.requestFullscreen().catch(() => {});
  else if (vp.video.webkitEnterFullscreen) vp.video.webkitEnterFullscreen(); // iPhone
}

function videoClick(e) {
  const a = e.target.closest("[data-a]")?.dataset.a;
  if (!a) return;
  const pos = vp.ms.abs();
  ({
    close: videoClose, toggle: videoToggle, full: videoFull, next: videoNext,
    back: () => vp.ms.seek(pos - 10), fwd: () => vp.ms.seek(pos + 30),
    subs: () => {
      vp.subsOn = !vp.subsOn; localSet("subs", vp.subsOn ? "1" : "0");
      const t = vp.video.textTracks[0];
      if (t) t.mode = vp.subsOn ? "showing" : "hidden";
      videoBar();
    },
  })[a]?.();
}

function videoKey(e) {
  if (!vp || e.target.tagName === "INPUT" && e.target.type !== "range") return;
  const pos = vp.ms.abs();
  const direct = vp.ms.st.info?.direct;
  if (e.key === "Escape" && !document.fullscreenElement) videoClose();
  else if (e.key === " " && !direct) { e.preventDefault(); videoToggle(); }
  else if (e.key === "ArrowLeft" && !direct) vp.ms.seek(pos - 10);
  else if (e.key === "ArrowRight" && !direct) vp.ms.seek(pos + 30);
  else if (e.key === "f") videoFull();
  else return;
  videoWake();
}

// Controls hide after a few seconds of playback without mouse movement.
function videoWake() {
  if (!vp) return;
  vp.box.classList.remove("idle");
  clearTimeout(vp.idle);
  vp.idle = setTimeout(() => { if (vp && !vp.video.paused && !vp.dragging) vp.box.classList.add("idle"); }, 3000);
}

function videoMsg(text) {
  const m = vp?.box.querySelector(".p-msg");
  if (!m) return;
  m.textContent = text;
  m.hidden = !text;
  if (text) vp.box.classList.remove("loading");
}

function localGet(k) { try { return localStorage.getItem(k); } catch (_) { return null; } }
function localSet(k, v) { try { localStorage.setItem(k, v); } catch (_) { /* private mode */ } }

// ---------- music ----------

const music = { queue: [], i: 0, el: null, ms: null, dragging: false };

window.musicPlay = async (queue, i) => {
  if (!music.el) {
    music.el = new Audio();
    music.ms = mediaStream(music.el);
    music.el.addEventListener("timeupdate", musicTick);
    music.el.addEventListener("play", musicBar);
    music.el.addEventListener("playing", () => { music.ms.st.retried = false; });
    music.el.addEventListener("pause", musicBar);
    music.el.addEventListener("ended", () => musicGo(1));
    music.el.addEventListener("error", () => { if (music.el.getAttribute("src") && !music.ms.recover()) musicGo(1); });
  }
  music.queue = queue; music.i = i;
  if (!music.el.getAttribute("src")) music.el.play().catch(() => {}); // unlock inside the click, see webPlay
  await musicLoad();
};

async function musicLoad() {
  const it = music.queue[music.i];
  musicBar();
  try { await music.ms.open(await playInfo(it.id), 0); } catch (e) { alert(e.message); }
  musicBar();
}

function musicGo(d) {
  if (d < 0 && music.ms.abs() > 3) return music.ms.seek(0);
  const n = music.i + d;
  if (n < 0 || n >= music.queue.length) { musicStop(); return; }
  music.i = n;
  musicLoad();
}

function musicPause() { music.el?.pause(); }

window.musicStop = () => {
  music.ms?.close();
  music.queue = [];
  musicBar();
};

window.musicCmd = (a) => {
  if (a === "toggle") music.el.paused ? music.el.play() : music.el.pause();
  else if (a === "prev") musicGo(-1);
  else if (a === "next") musicGo(1);
  else if (a === "tv") { const it = music.queue[music.i]; music.el.pause(); tvSheet(it); }
};

function musicTick() {
  const r = document.querySelector("#music .r-seek");
  if (!r || music.dragging) return;
  const pos = music.ms.abs(), dur = music.ms.duration();
  r.firstElementChild.textContent = fmtTime(pos * 1000);
  const input = r.querySelector("input");
  if (dur && +input.max !== Math.round(dur)) { input.max = Math.round(dur); input.disabled = false; r.lastElementChild.textContent = fmtTime(dur * 1000); }
  input.value = Math.round(pos);
}

function musicBar() {
  const it = music.queue[music.i];
  let bar = document.getElementById("music");
  document.body.classList.toggle("has-music", !!it);
  if (!it) { bar?.remove(); return; }
  if (!bar) {
    bar = document.createElement("div");
    bar.id = "music";
    bar.className = "remote music";
    document.body.appendChild(bar);
  }
  if (music.dragging) return;
  const dur = music.ms.duration(), pos = music.ms.abs();
  bar.innerHTML = `
    <div class="r-top">${it.art ? `<img src="${esc(it.art)}" alt="">` : ""}
      <span><b>${esc(it.title)}</b><small>${esc(it.info || "")}${music.queue.length > 1 ? ` · ${music.i + 1}/${music.queue.length}` : ""}</small></span>
      <button class="link" onclick="musicCmd('tv')" title="Přehrát na TV">TV</button>
      <button class="x" onclick="musicStop()" aria-label="Zavřít">×</button></div>
    <div class="r-seek"><span>${fmtTime(pos * 1000)}</span>
      <input type="range" min="0" max="${Math.round(dur)}" step="1" value="${Math.round(pos)}" ${dur ? "" : "disabled"}
        oninput="music.dragging=true;this.previousElementSibling.textContent=fmtTime(this.value*1000)" onchange="music.dragging=false;music.ms.seek(+this.value)">
      <span>${dur ? fmtTime(dur * 1000) : "–"}</span></div>
    <div class="r-ctl">
      <button onclick="musicCmd('prev')" title="Předchozí">⏮</button>
      <button class="primary play" onclick="musicCmd('toggle')">${music.el.paused ? "▶" : "❚❚"}</button>
      <button onclick="musicCmd('next')" ${music.i + 1 < music.queue.length ? "" : "disabled"} title="Další">⏭</button>
    </div>`;
}
