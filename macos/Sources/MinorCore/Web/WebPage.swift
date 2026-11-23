enum WebPage {
	static let index = #"""
	<!doctype html>
	<html lang="cs">
	<head>
	<meta charset="utf-8">
	<meta name="viewport" content="width=device-width, initial-scale=1">
	<title>MinorDLNA</title>
	<style>
	:root { color-scheme: light dark; font: 16px/1.4 -apple-system, system-ui, sans-serif; }
	body { max-width: 34rem; margin: 2rem auto; padding: 0 1rem; }
	h1 { font-size: 1.5rem; margin-bottom: .2rem; }
	.muted { opacity: .6; }
	.card { border: 1px solid color-mix(in srgb, currentColor 18%, transparent); border-radius: 12px; padding: 1rem; margin: 1rem 0; }
	li { display: flex; justify-content: space-between; padding: .3rem 0; }
	ul { list-style: none; padding: 0; margin: 0; }
	input, button { font: inherit; padding: .5rem .8rem; border-radius: 8px; }
	input { width: 100%; box-sizing: border-box; margin: .5rem 0; border: 1px solid color-mix(in srgb, currentColor 30%, transparent); }
	button { border: 0; background: #e8641e; color: #fff; cursor: pointer; }
	.error { color: #d33; }
	[hidden] { display: none !important; }
	</style>
	</head>
	<body>
	<form id="login" class="card" hidden>
	  <h1>MinorDLNA</h1>
	  <label for="pw">Heslo</label>
	  <input id="pw" type="password" autocomplete="current-password" required autofocus>
	  <button>Přihlásit</button>
	  <p id="login-error" class="error"></p>
	</form>
	<main id="app" hidden>
	  <h1 id="name"></h1>
	  <div class="muted">Verze <span id="version"></span></div>
	  <div class="card"><ul id="libs"></ul></div>
	  <p class="muted">Webové rozhraní je zatím jen základní.</p>
	  <button id="logout" hidden>Odhlásit</button>
	</main>
	<p id="error" class="error"></p>
	<script>
	const types = { movies: 'Filmy', shows: 'Seriály', videos: 'Videa', photos: 'Fotky', music: 'Hudba' };
	const post = (url, body) => fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-MinorDLNA': '1' }, body: JSON.stringify(body || {}) });
	function count(n) { return n + ' ' + (n === 1 ? 'položka' : n >= 2 && n <= 4 ? 'položky' : 'položek'); }
	function el(tag, text, cls) { const e = document.createElement(tag); e.textContent = text; if (cls) e.className = cls; return e; }

	async function load() {
	  const r = await fetch('/api/state');
	  if (r.status === 401) { document.getElementById('login').hidden = false; document.getElementById('app').hidden = true; return; }
	  if (!r.ok) { document.getElementById('error').textContent = await r.text(); return; }
	  const s = await r.json();
	  document.title = s.name;
	  document.getElementById('name').textContent = s.name;
	  document.getElementById('version').textContent = s.version;
	  const libs = document.getElementById('libs');
	  libs.replaceChildren(...(s.libraries.length ? s.libraries.map(l => {
	    const li = document.createElement('li');
	    const left = el('span', l.name + ' ');
	    left.append(el('span', types[l.type] || l.type, 'muted'));
	    li.append(left, el('span', count(l.items)));
	    return li;
	  }) : [el('li', 'Zatím žádná knihovna.', 'muted')]));
	  document.getElementById('logout').hidden = s.local;
	  document.getElementById('login').hidden = true;
	  document.getElementById('app').hidden = false;
	}

	document.getElementById('login').addEventListener('submit', async e => {
	  e.preventDefault();
	  const r = await post('/api/login', { password: document.getElementById('pw').value });
	  if (r.ok) { document.getElementById('pw').value = ''; document.getElementById('login-error').textContent = ''; return load(); }
	  const j = await r.json().catch(() => ({}));
	  document.getElementById('login-error').textContent = j.error || 'Přihlášení selhalo.';
	});
	document.getElementById('logout').addEventListener('click', async () => { await post('/api/logout'); load(); });
	load();
	</script>
	</body>
	</html>
	"""#
}
