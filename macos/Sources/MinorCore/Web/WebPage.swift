enum WebPage {
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
	#remote { position: fixed; left: 0; right: 0; bottom: 0; padding: .7rem 1rem; background: Canvas; border-top: 1px solid var(--line); }
	#remote > div { max-width: 46rem; margin: 0 auto; }
	#seek { width: 100%; }
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
	  <p class="muted">Verze <span id="version"></span></p>
	</main>
	<p id="error" class="error"></p>
	<div id="remote" hidden><div>
	  <div class="bar"><div class="grow"><div id="r-title" class="title"></div><div id="r-state" class="sub"></div></div>
	    <button id="r-play" class="plain">⏯</button><button id="r-stop" class="plain">⏹</button>
	    <button id="r-mute" class="plain" hidden>🔇</button><input id="r-vol" type="range" min="0" max="100" hidden style="width:6rem">
	  </div>
	  <div class="bar sub"><span id="r-pos"></span><input id="seek" class="grow" type="range" min="0" value="0"><span id="r-dur"></span></div>
	</div></div>
	<script>
	const $ = id => document.getElementById(id);
	const post = (url, body) => fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-MinorDLNA': '1' }, body: JSON.stringify(body || {}) });
	function el(tag, text, cls) { const e = document.createElement(tag); if (text != null) e.textContent = text; if (cls) e.className = cls; return e; }
	function time(ms) { const s = Math.max(0, Math.floor(ms / 1000)), p = n => String(n).padStart(2, '0');
	  return s >= 3600 ? Math.floor(s / 3600) + ':' + p(Math.floor(s / 60) % 60) + ':' + p(s % 60) : Math.floor(s / 60) + ':' + p(s % 60); }
	const states = { STARTING: 'Spouštím…', WAKING: 'Zapínám televizi…', PLAYING: 'Přehrává', PAUSED_PLAYBACK: 'Pozastaveno', TRANSITIONING: 'Načítá…', STOPPED: 'Zastaveno', NO_MEDIA_PRESENT: 'Zastaveno' };
	let stack = [], tvs = { devices: [], status: null }, dragging = false, lastItem = null;

	function showError(msg) { $('error').textContent = msg || ''; }
	async function api(url, body) {
	  const r = body === undefined ? await fetch(url) : await post(url, body);
	  if (r.status === 401) { loginForm(); throw new Error('login'); }
	  const j = await r.json().catch(() => ({}));
	  if (!r.ok) throw new Error(j.error || r.statusText);
	  return j;
	}
	function loginForm() { $('login').hidden = false; $('app').hidden = true; $('remote').hidden = true; }

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
	    b.addEventListener('click', () => play(e, false));
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
	    $('list').replaceChildren(...(p.entries.length ? p.entries.map(row) : [el('li', 'Prázdné.', 'muted')]));
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
	      $('list').replaceChildren(...(r.entries.length ? r.entries.map(row) : [el('li', 'Nic nenalezeno.', 'muted')]));
	    } catch (e) { if (e.message !== 'login') showError(e.message); }
	  }, 250);
	});

	function selectedTV() {
	  const saved = localStorage.getItem('tv');
	  return tvs.devices.find(d => d.udn === saved) || tvs.devices.find(d => d.online);
	}
	function renderTV() {
	  const sel = $('tv'), cur = selectedTV();
	  sel.replaceChildren(...(tvs.devices.length ? tvs.devices.map(d => { const o = el('option', d.name + (d.online ? '' : ' (nenalezena)')); o.value = d.udn; return o; })
	    : [el('option', 'Žádná televize')]));
	  sel.disabled = !tvs.devices.length;
	  if (cur) sel.value = cur.udn;
	  $('tv-wake').hidden = !(cur && !cur.online && cur.canWake);
	  const s = tvs.status;
	  $('remote').hidden = !s || $('app').hidden;
	  if (!s) return;
	  const live = s.state !== 'STOPPED' && s.state !== 'NO_MEDIA_PRESENT';
	  $('r-title').textContent = s.title;
	  $('r-state').textContent = s.tv + ' · ' + (s.error || states[s.state] || s.state);
	  $('r-state').classList.toggle('error', !!s.error);
	  $('r-play').hidden = $('r-stop').hidden = !live;
	  $('r-play').textContent = s.state === 'PLAYING' ? '⏸' : '▶';
	  $('r-mute').hidden = $('r-vol').hidden = !(live && s.canVolume);
	  $('r-mute').textContent = s.muted ? '🔇' : '🔊';
	  if (document.activeElement !== $('r-vol')) $('r-vol').value = s.volume;
	  $('seek').parentElement.hidden = !(live && s.durationMs > 0);
	  $('seek').max = s.durationMs;
	  if (!dragging) { $('seek').value = s.positionMs; $('r-pos').textContent = time(s.positionMs); }
	  $('r-dur').textContent = time(s.durationMs);
	  // Playback ended or moved on: saved positions in the list changed.
	  if (lastItem && (!live || s.itemID !== lastItem)) { const top = stack[stack.length - 1]; if (top && !$('q').value.trim()) open(top.id); }
	  lastItem = live ? s.itemID : null;
	}
	async function refreshTV(action, body) {
	  try { tvs = await api('/api/tv' + (action ? '/' + action : ''), action ? body || {} : undefined); renderTV(); if (action) showError(); }
	  catch (e) { if (e.message !== 'login') showError(e.message); }
	}
	async function play(e, fromStart) {
	  const tv = selectedTV();
	  if (!tv) return showError('Vyberte televizi, případně ji nechte vyhledat.');
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
	$('r-vol').addEventListener('change', () => cmd('volume', +$('r-vol').value));
	$('seek').addEventListener('input', () => { dragging = true; $('r-pos').textContent = time(+$('seek').value); });
	$('seek').addEventListener('change', async () => { await cmd('seek', +$('seek').value); dragging = false; });
	setInterval(() => { if (!$('app').hidden && !document.hidden) refreshTV(); }, 2000);

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
