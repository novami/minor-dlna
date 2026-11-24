nonisolated enum WebPage {
	static let index = #"""
	<!doctype html>
	<html lang="cs">
	<head>
	<meta charset="utf-8">
	<meta name="viewport" content="width=device-width, initial-scale=1">
	<title>MinorDLNA</title>
	<style>
	:root { color-scheme: light dark; font: 16px/1.4 -apple-system, system-ui, sans-serif; --line: color-mix(in srgb, currentColor 15%, transparent); }
	body { max-width: 46rem; margin: 0 auto; padding: 1rem 1rem 9rem; }
	h1 { font-size: 1.4rem; margin: 0; }
	.muted { opacity: .6; }
	.card { border: 1px solid var(--line); border-radius: 12px; padding: 1rem; margin: 1rem 0; }
	.bar { display: flex; gap: .5rem; align-items: center; flex-wrap: wrap; }
	.grow { flex: 1; min-width: 0; }
	input, button, select { font: inherit; padding: .45rem .7rem; border-radius: 8px; }
	input, select { border: 1px solid color-mix(in srgb, currentColor 30%, transparent); background: transparent; color: inherit; }
	input[type=search], #pw { width: 100%; box-sizing: border-box; }
	button { border: 0; background: #e8641e; color: #fff; cursor: pointer; }
	button.plain { background: color-mix(in srgb, currentColor 10%, transparent); color: inherit; }
	button:disabled { opacity: .4; cursor: default; }
	ul { list-style: none; padding: 0; margin: 0; }
	#list li { display: flex; gap: .7rem; align-items: center; padding: .45rem 0; border-bottom: 1px solid var(--line); }
	#list li.folder { cursor: pointer; }
	#list img, #list .ph { width: 44px; height: 44px; object-fit: contain; border-radius: 4px; flex: none; background: var(--line); }
	.title { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
	.sub { font-size: .8rem; opacity: .6; display: flex; gap: .5rem; align-items: center; }
	progress { width: 60px; height: 6px; }
	#crumbs { margin: .8rem 0 .3rem; font-size: .9rem; }
	#crumbs a { color: inherit; cursor: pointer; text-decoration: underline; }
	#dock { position: fixed; left: 0; right: 0; bottom: 0; background: Canvas; }
	#dock > div { padding: .7rem 1rem; border-top: 1px solid var(--line); }
	#dock > div > div { max-width: 46rem; margin: 0 auto; }
	#music img { width: 40px; height: 40px; object-fit: cover; border-radius: 4px; }
	#seek, #m-seek { width: 100%; }
	.player { position: fixed; inset: 0; z-index: 10; background: #000; color: #fff; }
	.player video { width: 100%; height: 100%; }
	.player video::-webkit-media-text-track-container { bottom: 6.5rem; }
	.p-top, .p-bar { position: absolute; left: 0; right: 0; padding: .8rem 1rem; transition: opacity .3s; }
	.p-top { top: 0; display: flex; gap: .7rem; align-items: center; background: linear-gradient(#000a, #0000); }
	.p-bar { bottom: 0; background: linear-gradient(#0000, #000b); }
	.p-bar .bar { justify-content: center; }
	.player button { background: #fff3; color: #fff; -webkit-backdrop-filter: blur(12px); backdrop-filter: blur(12px); }
	.player button.on { background: #e8641e; }
	.player button.big { width: 3.2rem; height: 3.2rem; border-radius: 50%; font-size: 1.2rem; }
	.player.direct .p-bar { bottom: 4rem; background: none; }
	.player.idle { cursor: none; }
	.player.idle .p-top, .player.idle .p-bar { opacity: 0; }
	.p-msg { position: absolute; top: 45%; left: 1rem; right: 1rem; text-align: center; }
	.player.loading::after { content: ""; position: absolute; top: calc(50% - 20px); left: calc(50% - 20px); width: 40px; height: 40px;
	  border: 3px solid #fff4; border-top-color: #fff; border-radius: 50%; animation: spin 1s linear infinite; }
	@keyframes spin { to { transform: rotate(360deg); } }
	.ticks { display: inline-flex; flex-direction: column; width: 9rem; }
	.ticks input { width: 100%; margin: 0; }
	.dots { display: flex; justify-content: space-between; padding: 0 7px; }
	.dots i { width: 3px; height: 3px; border-radius: 50%; background: currentColor; opacity: .45; }
	footer { text-align: center; font-size: .75rem; margin-top: 2rem; }
	.error { color: #d33; }
	[hidden] { display: none !important; }
	</style>
	</head>
	<body>
	<form id="login" class="card" hidden>
	  <h1>MinorDLNA</h1>
	  <label for="pw">Heslo</label>
	  <input id="pw" type="password" autocomplete="current-password" required autofocus>
	  <p><button>Přihlásit</button></p>
	  <p id="login-error" class="error"></p>
	</form>
	<main id="app" hidden>
	  <div class="bar">
	    <h1 id="name" class="grow"></h1>
	    <select id="tv" aria-label="Televize"></select>
	    <button id="tv-search" class="plain">Hledat TV</button>
	    <button id="tv-wake" class="plain" hidden>Zapnout</button>
	    <button id="logout" class="plain" hidden>Odhlásit</button>
	  </div>
	  <p><input id="q" type="search" placeholder="Hledat filmy, seriály, hudbu"></p>
	  <div id="crumbs"></div>
	  <ul id="list"></ul>
	  <footer class="muted">Verze <span id="version"></span></footer>
	</main>
	<p id="error" class="error"></p>
	<div id="dock">
	<div id="music" hidden><div>
	  <div class="bar"><img id="m-art" alt="" hidden><div class="grow"><div id="m-title" class="title"></div><div id="m-info" class="sub"></div></div>
	    <button id="m-prev" class="plain" aria-label="Předchozí">⏮</button><button id="m-play" class="plain">⏸</button><button id="m-next" class="plain" aria-label="Další">⏭</button>
	    <button id="m-close" class="plain" aria-label="Zavřít">✕</button></div>
	  <div class="bar sub"><span id="m-pos"></span><input id="m-seek" class="grow" type="range" min="0" value="0"><span id="m-dur"></span></div>
	</div></div>
	<div id="remote" hidden><div>
	  <div class="bar"><div class="grow"><div id="r-title" class="title"></div><div id="r-state" class="sub"></div></div>
	    <button id="r-play" class="plain">⏯</button><button id="r-stop" class="plain">⏹</button>
	    <button id="r-mute" class="plain" hidden>🔇</button><span id="r-volbox" class="ticks" hidden><input id="r-vol" type="range" min="0" max="100" step="10"><span class="dots"><i></i><i></i><i></i><i></i><i></i><i></i><i></i><i></i><i></i><i></i><i></i></span></span>
	  </div>
	  <div class="bar sub"><span id="r-pos"></span><input id="seek" class="grow" type="range" min="0" value="0"><span id="r-dur"></span></div>
	</div></div>
	</div>
	<script>
	const $ = id => document.getElementById(id);
	const post = (url, body) => fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-MinorDLNA': '1' }, body: JSON.stringify(body || {}) });
	function el(tag, text, cls) { const e = document.createElement(tag); if (text != null) e.textContent = text; if (cls) e.className = cls; return e; }
	function time(ms) { const s = Math.max(0, Math.floor(ms / 1000)), p = n => String(n).padStart(2, '0');
	  return s >= 3600 ? Math.floor(s / 3600) + ':' + p(Math.floor(s / 60) % 60) + ':' + p(s % 60) : Math.floor(s / 60) + ':' + p(s % 60); }
	const states = { STARTING: 'Spouštím…', WAKING: 'Zapínám televizi…', PLAYING: 'Přehrává', PAUSED_PLAYBACK: 'Pozastaveno', TRANSITIONING: 'Načítá…', STOPPED: 'Zastaveno', NO_MEDIA_PRESENT: 'Zastaveno' };
	let stack = [], listed = [], tvs = { devices: [], status: null }, dragging = false, lastItem = null;

	function showError(msg) { $('error').textContent = msg || ''; }
	async function api(url, body) {
	  const r = body === undefined ? await fetch(url) : await post(url, body);
	  if (r.status === 401) { loginForm(); throw new Error('login'); }
	  const j = await r.json().catch(() => ({}));
	  if (!r.ok) throw new Error(j.error || r.statusText);
	  return j;
	}
	function loginForm() { $('login').hidden = false; $('app').hidden = true; $('remote').hidden = true; }
	function show(entries, empty) { listed = entries; $('list').replaceChildren(...(entries.length ? entries.map(row) : [el('li', empty, 'muted')])); playButtons(); }
	function reloadList() { const top = stack[stack.length - 1]; if (top && !$('q').value.trim()) open(top.id); }

	async function load() {
	  const r = await fetch('/api/state');
	  if (r.status === 401) return loginForm();
	  if (!r.ok) return showError(await r.text());
	  const s = await r.json();
	  document.title = s.name;
	  $('name').textContent = s.name;
	  $('version').textContent = s.version;
	  $('logout').hidden = s.local;
	  $('login').hidden = true;
	  $('app').hidden = false;
	  stack = [];
	  open('0');
	  refreshTV();
	}

	function row(e) {
	  const li = el('li', null, e.kind === 'folder' ? 'folder' : '');
	  if (e.artPath) { const img = el('img'); img.loading = 'lazy'; img.src = e.artPath; img.alt = ''; li.append(img); } else li.append(el('span', null, 'ph'));
	  const mid = el('div', null, 'grow'), sub = el('div', null, 'sub');
	  mid.append(el('div', e.title, 'title'), sub);
	  if (e.durationMs) sub.append(el('span', time(e.durationMs)));
	  if (e.watched) sub.append(el('span', '✓ zhlédnuto'));
	  else if (e.positionMs > 0 && e.durationMs) { const p = el('progress'); p.max = e.durationMs; p.value = e.positionMs; sub.append(p, el('span', 'zbývá ' + time(e.durationMs - e.positionMs))); }
	  if (e.kind === 'folder' && e.childCount != null) sub.append(el('span', e.childCount + ' položek'));
	  li.append(mid);
	  if (e.kind === 'folder') li.addEventListener('click', () => open(e.id, e.title));
	  if (e.kind === 'video' || e.kind === 'audio') {
	    const resume = e.positionMs > 0 && !e.watched;
	    const b = el('button', resume ? '▶ Pokračovat' : '▶ Přehrát');
	    b.dataset.id = e.id; b.dataset.label = b.textContent;
	    b.addEventListener('click', () => localID() === e.id ? localStop() : playingID() === e.id ? cmd('stop') : play(e, false));
	    li.append(b);
	    if (resume) { const s = el('button', 'Od začátku', 'plain'); s.addEventListener('click', () => play(e, true)); li.append(s); }
	  }
	  return li;
	}

	async function open(id, title) {
	  try {
	    const p = await api('/api/browse?id=' + encodeURIComponent(id));
	    const i = stack.findIndex(s => s.id === id);
	    stack = i >= 0 ? stack.slice(0, i + 1) : [...stack, { id, title: id === '0' ? 'Knihovna' : p.title }];
	    crumbs();
	    show(p.entries, 'Prázdné.');
	    showError();
	  } catch (e) { if (e.message !== 'login') showError(e.message); }
	}
	function crumbs() {
	  $('crumbs').replaceChildren(...stack.flatMap((s, i) => {
	    if (i === stack.length - 1) return [el('b', s.title)];
	    const a = el('a', s.title); a.addEventListener('click', () => open(s.id)); return [a, document.createTextNode(' › ')];
	  }));
	}
	let searchTimer;
	$('q').addEventListener('input', () => {
	  clearTimeout(searchTimer);
	  searchTimer = setTimeout(async () => {
	    const q = $('q').value.trim();
	    if (!q) { const top = stack.pop() || { id: '0' }; return open(top.id, top.title); }
	    try {
	      const r = await api('/api/search?q=' + encodeURIComponent(q));
	      $('crumbs').replaceChildren(el('b', 'Hledání'));
	      show(r.entries, 'Nic nenalezeno.');
	    } catch (e) { if (e.message !== 'login') showError(e.message); }
	  }, 250);
	});

	function playingID() {
	  const s = tvs.status;
	  return s && s.state !== 'STOPPED' && s.state !== 'NO_MEDIA_PRESENT' ? s.itemID : null;
	}
	function playButtons() {
	  const ids = [playingID(), localID()];
	  document.querySelectorAll('#list button[data-id]').forEach(b => { b.textContent = ids.includes(b.dataset.id) ? '⏹ Zastavit' : b.dataset.label; });
	}
	// The TV to play on; null plays in this browser (picked, or no TV is online).
	function selectedTV() {
	  const saved = localStorage.getItem('tv');
	  if (saved === 'here') return null;
	  return tvs.devices.find(d => d.udn === saved) || tvs.devices.find(d => d.online) || null;
	}
	function renderTV() {
	  const sel = $('tv'), cur = selectedTV(), here = el('option', 'Toto zařízení');
	  here.value = 'here';
	  sel.replaceChildren(here, ...tvs.devices.map(d => { const o = el('option', d.name + (d.online ? '' : ' (nenalezena)')); o.value = d.udn; return o; }));
	  sel.value = cur ? cur.udn : 'here';
	  $('tv-wake').hidden = !(cur && !cur.online && cur.canWake);
	  playButtons();
	  const s = tvs.status;
	  $('remote').hidden = !s || $('app').hidden;
	  if (!s) return;
	  const live = s.state !== 'STOPPED' && s.state !== 'NO_MEDIA_PRESENT';
	  $('r-title').textContent = s.title;
	  $('r-state').textContent = s.tv + ' · ' + (s.error || states[s.state] || s.state);
	  $('r-state').classList.toggle('error', !!s.error);
	  $('r-play').hidden = $('r-stop').hidden = !live;
	  $('r-play').textContent = s.state === 'PLAYING' ? '⏸' : '▶';
	  $('r-mute').hidden = $('r-volbox').hidden = !(live && s.canVolume);
	  $('r-mute').textContent = s.muted ? '🔇' : '🔊';
	  if (document.activeElement !== $('r-vol')) $('r-vol').value = s.volume;
	  $('seek').parentElement.hidden = !(live && s.durationMs > 0);
	  $('seek').max = s.durationMs;
	  if (!dragging) { $('seek').value = s.positionMs; $('r-pos').textContent = time(s.positionMs); }
	  $('r-dur').textContent = time(s.durationMs);
	  // Playback ended or moved on: saved positions in the list changed.
	  if (lastItem && (!live || s.itemID !== lastItem)) reloadList();
	  lastItem = live ? s.itemID : null;
	}
	async function refreshTV(action, body) {
	  try { tvs = await api('/api/tv' + (action ? '/' + action : ''), action ? body || {} : undefined); renderTV(); if (action) showError(); }
	  catch (e) { if (e.message !== 'login') showError(e.message); }
	}
	async function play(e, fromStart) {
	  const tv = selectedTV();
	  if (!tv) return localPlay(e, fromStart);
	  await refreshTV('play', { udn: tv.udn, id: e.id, fromStart });
	}
	const cmd = (command, value) => refreshTV('command', { command, value });
	$('tv').addEventListener('change', () => { localStorage.setItem('tv', $('tv').value); renderTV(); });
	$('tv-search').addEventListener('click', async () => {
	  $('tv-search').disabled = true; $('tv-search').textContent = 'Hledám…';
	  await refreshTV('search');
	  $('tv-search').disabled = false; $('tv-search').textContent = 'Hledat TV';
	  if (!tvs.devices.some(d => d.online)) showError('Žádná televize se neozvala. Zapněte ji a povolte na ní sdílení obsahu (DLNA).');
	});
	$('tv-wake').addEventListener('click', () => { const tv = selectedTV(); if (tv) refreshTV('wake', { udn: tv.udn }); });
	$('r-play').addEventListener('click', () => cmd(tvs.status && tvs.status.state === 'PLAYING' ? 'pause' : 'play'));
	$('r-stop').addEventListener('click', () => cmd('stop'));
	$('r-mute').addEventListener('click', () => cmd('mute', tvs.status && tvs.status.muted ? 0 : 1));
	// Each step goes to the TV at once; one request at a time, the last value wins.
	let volBusy = false, volWant = null;
	async function sendVolume() {
	  if (volBusy || volWant === null) return;
	  volBusy = true;
	  const v = volWant; volWant = null;
	  await cmd('volume', v);
	  volBusy = false;
	  sendVolume();
	}
	$('r-vol').addEventListener('input', () => { volWant = +$('r-vol').value; sendVolume(); });
	$('seek').addEventListener('input', () => { dragging = true; $('r-pos').textContent = time(+$('seek').value); });
	$('seek').addEventListener('change', async () => { await cmd('seek', +$('seek').value); dragging = false; });
	setInterval(() => { if (!$('app').hidden && !document.hidden) refreshTV(); }, 2000);

	// ---------- playing in this browser ----------
	// Files the browser plays are opened directly. Others come converted from ?t= seconds (fragmented MP4, HLS in
	// Safari, which plays media only with byte ranges); seeking there restarts the stream at the new time.
	const probe = document.createElement('video');
	const HEVC = !!probe.canPlayType('video/mp4; codecs="hvc1.1.6.L120.90"');
	const UA = navigator.userAgent, TOUCH = navigator.maxTouchPoints > 1; // iPhone and iPad, also with a desktop user agent
	const USE_HLS = !!probe.canPlayType('application/vnd.apple.mpegurl') && /AppleWebKit/.test(UA) && !/Chrome|Chromium|Edg|Android/.test(UA);
	// Dolby Vision profile 5 keeps its colours only in HLS, where the server copies it with its DV configuration.
	const DV = USE_HLS && !!probe.canPlayType('video/mp4; codecs="dvh1.05.06"');
	const playInfo = id => api('/api/play?id=' + encodeURIComponent(id) + (HEVC ? '&hevc=1' : '') + (DV ? '&dv=1' : ''));
	const beacon = (url, body) => fetch(url, { method: 'POST', keepalive: true, headers: { 'Content-Type': 'application/json', 'X-MinorDLNA': '1' }, body: JSON.stringify(body) }).catch(() => {});
	const savePosition = (id, pos, dur) => { if (pos >= 1) beacon('/api/position', { id, positionMs: Math.round(pos * 1000), durationMs: Math.round(dur * 1000) }); };

	// A media element with an absolute timeline over direct or restarted streams.
	function mediaStream(m) {
	  const st = { info: null, offset: 0, token: '', retried: false };
	  const stopHLS = () => { if (st.token) beacon('/api/play/hls/stop', { token: st.token }); st.token = ''; };
	  return {
	    st, onopen: null, onblocked: null,
	    async open(info, at, retry) {
	      st.info = info; st.retried = !!retry; at = Math.max(0, at || 0);
	      if (info.direct) {
	        stopHLS(); st.offset = 0; this.onopen?.(info, at);
	        m.src = info.src;
	        if (at) m.addEventListener('loadedmetadata', () => { m.currentTime = at; }, { once: true });
	      } else {
	        const r = await api('/api/play/start', { id: info.id, t: at, hevc: HEVC, dv: DV, hls: USE_HLS,
	          sdr: TOUCH && !matchMedia('(video-dynamic-range: high)').matches, stop: st.token || undefined });
	        st.token = r.token || ''; st.offset = r.start; this.onopen?.(info, r.start);
	        m.src = (TOUCH && r.master) || r.url;
	      }
	      await m.play().catch(e => { if (e.name === 'NotAllowedError') this.onblocked?.(); });
	    },
	    abs() { return st.offset + (m.currentTime || 0); },
	    duration() { return st.info?.durationMs ? st.info.durationMs / 1000 : (isFinite(m.duration) ? m.duration : 0); },
	    seek(t) {
	      const d = this.duration();
	      t = Math.max(0, d ? Math.min(t, d - 1) : t);
	      if (st.info.direct) m.currentTime = t; else this.open(st.info, t).catch(e => showError(e.message));
	    },
	    // A converted stream may die (server restart, idle HLS session); continue once from where it stopped.
	    recover() {
	      if (!st.info || st.info.direct || st.retried) return false;
	      this.open(st.info, this.abs(), true).catch(() => {});
	      return true;
	    },
	    close() { stopHLS(); m.pause(); m.removeAttribute('src'); m.load(); st.info = null; }, // load() aborts the download, which stops ffmpeg
	  };
	}

	function localID() { return vp?.ms.st.info?.id || (music.queue.length ? music.queue[music.i].id : null); }
	function localStop() { if (vp) videoClose(); else musicStop(); }
	async function localPlay(e, fromStart) {
	  if (e.kind === 'audio') { const q = listed.filter(x => x.kind === 'audio'); return musicPlay(q, Math.max(q.findIndex(x => x.id === e.id), 0)); }
	  musicStop();
	  // Safari allows sound only for play() inside the click; the stream URL comes later, so unlock the element now.
	  videoBox(); vp.box.classList.add('loading'); vp.video.play().catch(() => {});
	  try {
	    const info = await playInfo(e.id);
	    videoOpen(info, fromStart || info.watched ? 0 : info.positionMs / 1000);
	  } catch (err) { videoClose(); if (err.message !== 'login') showError(err.message); }
	}

	// ---------- video ----------
	let vp = null; // { box, video, ms, saved, dragging, subsOn, idle }

	function videoBox() {
	  if (vp) return;
	  const box = el('div', null, 'player');
	  box.innerHTML = `<video playsinline></video>
	    <div class="p-top"><button data-a="close" aria-label="Zavřít">✕</button><b class="grow title"></b></div>
	    <div class="p-bar"></div><div class="p-msg" hidden></div>`;
	  document.body.append(box);
	  const video = box.querySelector('video');
	  vp = { box, video, ms: mediaStream(video), saved: 0, dragging: false, subsOn: localStorage.getItem('subs') !== '0', idle: 0 };
	  video.addEventListener('timeupdate', videoTick);
	  video.addEventListener('play', videoBar);
	  video.addEventListener('pause', () => { videoSave(); videoBar(); });
	  video.addEventListener('ended', videoEnded);
	  video.addEventListener('error', () => { if (vp?.video.getAttribute('src') && !vp.ms.recover()) videoMsg('Video se nepodařilo přehrát.'); });
	  video.addEventListener('waiting', () => box.classList.add('loading'));
	  video.addEventListener('playing', () => { box.classList.remove('loading'); videoMsg(''); vp.ms.st.retried = false; });
	  video.addEventListener('click', () => { if (!vp.ms.st.info?.direct) videoToggle(); });
	  box.addEventListener('click', videoClick);
	  box.addEventListener('mousemove', videoWake);
	  box.addEventListener('touchstart', videoWake, { passive: true });
	  document.addEventListener('keydown', videoKey);
	  window.addEventListener('pagehide', videoSave);
	  playButtons();
	}

	function videoOpen(info, at) {
	  videoBox();
	  vp.ms.onopen = videoSubs; // subtitles of a restarted stream are shifted to its new start
	  vp.ms.onblocked = () => { vp.box.classList.remove('loading'); videoBar(); videoWake(); videoMsg('Spusťte přehrávání tlačítkem ▶.'); };
	  vp.box.querySelector('.p-top b').textContent = info.title;
	  vp.video.controls = info.direct; // native controls seek well in direct files
	  vp.box.classList.toggle('direct', info.direct);
	  vp.box.classList.add('loading');
	  videoMsg('');
	  vp.ms.open(info, at).catch(e => videoMsg(e.message));
	  videoBar(); videoWake(); playButtons();
	}

	function videoSubs(info, at) {
	  if (!vp) return;
	  vp.video.querySelectorAll('track').forEach(t => t.remove());
	  if (!info.subs) return;
	  const tr = el('track');
	  tr.kind = 'subtitles'; tr.srclang = 'cs'; tr.label = 'Titulky'; tr.default = vp.subsOn;
	  tr.src = `/api/play/${info.id.slice(1)}/subs.vtt` + (info.direct ? '' : `?t=${at.toFixed(3)}`);
	  vp.video.append(tr);
	  tr.addEventListener('load', () => { tr.track.mode = vp.subsOn ? 'showing' : 'hidden'; });
	}

	function button(label, action, cls, title) { const b = el('button', label, cls); b.dataset.a = action; if (title) b.title = title; return b; }

	function videoBar() {
	  if (!vp || vp.dragging) return;
	  const info = vp.ms.st.info, bar = vp.box.querySelector('.p-bar');
	  if (!info) return;
	  const extra = [];
	  if (info.subs) extra.push(button('CC', 'subs', vp.subsOn ? 'on' : '', 'Titulky'));
	  if (info.next) extra.push(button('Další díl ›', 'next', '', info.next.title));
	  if (info.direct) { bar.replaceChildren(el('div', null, 'bar')); bar.firstChild.append(...extra); return; } // native controls; only what they lack
	  const pos = vp.ms.abs(), dur = vp.ms.duration();
	  const seek = el('input'); seek.type = 'range'; seek.min = 0; seek.max = Math.round(dur); seek.step = 1; seek.value = Math.round(Math.min(pos, dur)); seek.disabled = !dur; seek.className = 'grow';
	  const cur = el('span', time(pos * 1000));
	  seek.addEventListener('input', () => { vp.dragging = true; cur.textContent = time(seek.value * 1000); });
	  seek.addEventListener('change', () => { vp.dragging = false; vp.ms.seek(+seek.value); });
	  const line = el('div', null, 'bar sub'); line.append(cur, seek, el('span', dur ? time(dur * 1000) : '–'));
	  const ctl = el('div', null, 'bar');
	  ctl.append(button('−10 s', 'back', '', 'Zpět o 10 s'), button(vp.video.paused ? '▶' : '❚❚', 'toggle', 'big'), button('+30 s', 'fwd', '', 'Vpřed o 30 s'), ...extra, button('⛶', 'full', '', 'Celá obrazovka'));
	  bar.replaceChildren(line, ctl);
	}

	function videoTick() {
	  if (!vp) return;
	  if (!vp.ms.st.info?.direct && !vp.dragging) {
	    const line = vp.box.querySelector('.p-bar .sub'), pos = vp.ms.abs();
	    if (line) { line.firstChild.textContent = time(pos * 1000); line.querySelector('input').value = Math.round(pos); }
	  }
	  if (Date.now() - vp.saved > 10000) videoSave();
	}

	function videoSave() {
	  const info = vp?.ms.st.info;
	  if (!info) return;
	  vp.saved = Date.now();
	  savePosition(info.id, vp.ms.abs(), vp.ms.duration());
	}

	function videoEnded() {
	  const info = vp.ms.st.info, dur = vp.ms.duration();
	  savePosition(info.id, dur, dur);
	  if (info.next && info.autoNext) return videoNext();
	  if (info.next) { videoMsg('Dohráno.'); vp.box.classList.remove('idle'); return; }
	  videoClose();
	}

	async function videoNext() {
	  const info = vp?.ms.st.info;
	  if (!info?.next) return;
	  videoSave();
	  try { videoOpen(await playInfo(info.next.id), 0); } catch (e) { videoMsg(e.message); }
	}

	function videoClose() {
	  if (!vp) return;
	  videoSave();
	  vp.ms.close();
	  vp.box.remove();
	  document.removeEventListener('keydown', videoKey);
	  window.removeEventListener('pagehide', videoSave);
	  if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
	  vp = null;
	  setTimeout(reloadList, 300); // the list shows the new progress
	}

	function videoToggle() { if (vp.video.paused) vp.video.play(); else vp.video.pause(); }

	function videoFull() {
	  if (document.fullscreenElement) return document.exitFullscreen();
	  if (vp.box.requestFullscreen) vp.box.requestFullscreen().catch(() => {});
	  else if (vp.video.webkitEnterFullscreen) vp.video.webkitEnterFullscreen(); // iPhone
	}

	function videoClick(e) {
	  const a = e.target.closest('[data-a]')?.dataset.a;
	  if (!a) return;
	  const pos = vp.ms.abs();
	  ({
	    close: videoClose, toggle: videoToggle, full: videoFull, next: videoNext,
	    back: () => vp.ms.seek(pos - 10), fwd: () => vp.ms.seek(pos + 30),
	    subs: () => {
	      vp.subsOn = !vp.subsOn; localStorage.setItem('subs', vp.subsOn ? '1' : '0');
	      const t = vp.video.textTracks[0];
	      if (t) t.mode = vp.subsOn ? 'showing' : 'hidden';
	      videoBar();
	    },
	  })[a]?.();
	}

	function videoKey(e) {
	  if (!vp || (e.target.tagName === 'INPUT' && e.target.type !== 'range')) return;
	  const pos = vp.ms.abs(), direct = vp.ms.st.info?.direct;
	  if (e.key === 'Escape' && !document.fullscreenElement) videoClose();
	  else if (e.key === ' ' && !direct) { e.preventDefault(); videoToggle(); }
	  else if (e.key === 'ArrowLeft' && !direct) vp.ms.seek(pos - 10);
	  else if (e.key === 'ArrowRight' && !direct) vp.ms.seek(pos + 30);
	  else if (e.key === 'f') videoFull();
	  else return;
	  videoWake();
	}

	// The controls hide after a few seconds of playback without mouse movement.
	function videoWake() {
	  if (!vp) return;
	  vp.box.classList.remove('idle');
	  clearTimeout(vp.idle);
	  vp.idle = setTimeout(() => { if (vp && !vp.video.paused && !vp.dragging) vp.box.classList.add('idle'); }, 3000);
	}

	function videoMsg(text) {
	  const m = vp?.box.querySelector('.p-msg');
	  if (!m) return;
	  m.textContent = text; m.hidden = !text;
	  if (text) vp.box.classList.remove('loading');
	}

	// ---------- music ----------
	const music = { queue: [], i: 0, el: null, ms: null, dragging: false };

	async function musicPlay(queue, i) {
	  if (!music.el) {
	    music.el = new Audio();
	    music.ms = mediaStream(music.el);
	    music.el.addEventListener('timeupdate', musicTick);
	    music.el.addEventListener('play', musicBar);
	    music.el.addEventListener('pause', musicBar);
	    music.el.addEventListener('playing', () => { music.ms.st.retried = false; });
	    music.el.addEventListener('ended', () => musicGo(1));
	    music.el.addEventListener('error', () => { if (music.el.getAttribute('src') && !music.ms.recover()) musicGo(1); });
	  }
	  if (!music.el.getAttribute('src')) music.el.play().catch(() => {}); // unlock inside the click, see localPlay
	  music.queue = queue; music.i = i;
	  await musicLoad();
	}

	async function musicLoad() {
	  musicBar();
	  try { await music.ms.open(await playInfo(music.queue[music.i].id), 0); } catch (e) { if (e.message !== 'login') showError(e.message); }
	  musicBar();
	}

	function musicGo(d) {
	  if (d < 0 && music.ms.abs() > 3) return music.ms.seek(0);
	  const n = music.i + d;
	  if (n < 0 || n >= music.queue.length) return musicStop();
	  music.i = n;
	  musicLoad();
	}

	function musicStop() {
	  if (!music.queue.length) return;
	  music.ms.close();
	  music.queue = [];
	  musicBar();
	}

	function musicTick() {
	  if (music.dragging) return;
	  const pos = music.ms.abs(), dur = music.ms.duration();
	  $('m-seek').max = Math.round(dur); $('m-seek').disabled = !dur; $('m-seek').value = Math.round(pos);
	  $('m-pos').textContent = time(pos * 1000); $('m-dur').textContent = dur ? time(dur * 1000) : '–';
	}

	function musicBar() {
	  const it = music.queue[music.i];
	  $('music').hidden = !it;
	  playButtons();
	  if (!it) return;
	  $('m-art').hidden = !it.artPath; if (it.artPath) $('m-art').src = it.artPath;
	  $('m-title').textContent = it.title;
	  $('m-info').textContent = music.queue.length > 1 ? `${music.i + 1} / ${music.queue.length}` : '';
	  $('m-play').textContent = music.el.paused ? '▶' : '⏸';
	  $('m-next').disabled = music.i + 1 >= music.queue.length;
	  musicTick();
	}
	$('m-play').addEventListener('click', () => music.el.paused ? music.el.play() : music.el.pause());
	$('m-prev').addEventListener('click', () => musicGo(-1));
	$('m-next').addEventListener('click', () => musicGo(1));
	$('m-close').addEventListener('click', musicStop);
	$('m-seek').addEventListener('input', () => { music.dragging = true; $('m-pos').textContent = time($('m-seek').value * 1000); });
	$('m-seek').addEventListener('change', () => { music.dragging = false; music.ms.seek(+$('m-seek').value); });

	$('login').addEventListener('submit', async e => {
	  e.preventDefault();
	  const r = await post('/api/login', { password: $('pw').value });
	  if (r.ok) { $('pw').value = ''; $('login-error').textContent = ''; return load(); }
	  const j = await r.json().catch(() => ({}));
	  $('login-error').textContent = j.error || 'Přihlášení selhalo.';
	});
	$('logout').addEventListener('click', async () => { await post('/api/logout'); load(); });
	load();
	</script>
	</body>
	</html>
	"""#
}
