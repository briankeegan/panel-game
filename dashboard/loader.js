// Stand-in for the artifact "dash" object: loads data files and runs the page's onData callbacks when they arrive.
// THE DATA IS NOT PART OF THE PAGE: it lives at its own address (the data project, <project>-data.pages.dev), named in data-base.txt beside
// the page (a URL, else ignored: Pages answers a missing file with the page), so new games reach the page without the page being published again. No data-base.txt (a local copy): ./data.
// THE SET (#set=<name> in the link): which bot's games. Ranmaru's are the data's top level, as they always were; another bot's sit
// in their own folder beside them (data/chaos/ for the chaos bot), so the two never mix. A set is chosen by a fresh load.
(function () {
  const P = { ver: '', opp: '', minn: 10 }, fns = [], cache = {};
  const SET = ((/(?:^#|&)set=([a-z0-9-]+)/.exec(location.hash) || [])[1] || 'ranmaru');
  document.documentElement.classList.add('set-' + SET);   // (each set's colours: page.html, html.set-<name>; set before anything draws)
  const base = fetch('data-base.txt', { cache: 'no-store' }).then((r) => (r.ok ? r.text() : '')).then((t) => (/^https:\/\/[^\s<]+$/.test(t.trim()) ? t.trim().replace(/\/?$/, '/') : 'data/')).catch(() => 'data/')
    .then((b) => (SET === 'ranmaru' ? b : b + SET + '/'));
  const name = (id) => (id === 'games' || id === 'versions') ? id + '.json' : id + '.json.gz';
  async function load(id) {
    try {
      // (no-store: a game finished a minute ago is on the page at the next load, not after a cache expires)
      const url = (await base) + name(id), r = await fetch(url, { cache: 'no-store' });
      // a set with no games yet has no folder at all: its lists are empty, not an error (Ranmaru's data/ always exists)
      if (r.status === 404 && SET !== 'ranmaru' && (id === 'games' || id === 'versions')) { cache[id] = { status: 'ok', data: [] }; fns.forEach((f) => f()); return; }
      if (!r.ok) throw new Error(url + ' ' + r.status);
      let text;
      if (url.endsWith('.gz') && r.headers.get('content-encoding') !== 'gzip' && window.DecompressionStream) text = await new Response(r.body.pipeThrough(new DecompressionStream('gzip'))).text();
      else text = await r.text();
      cache[id] = { status: 'ok', data: JSON.parse(text) };
    } catch (e) { console.error(e); cache[id] = { status: 'error', data: [] }; }
    fns.forEach((f) => f());
  }
  window.dash = {
    colors: ['#2f6fe0', '#e08a2f', '#3fbf5a', '#b367e0', '#d9433f', '#3fc8d8', '#f0c33c', '#9aa4b8'],
    params: () => Object.assign({}, P),
    setParams: (o) => { Object.assign(P, o); fns.forEach((f) => f()); },
    resetParams: () => { Object.assign(P, { ver: '', opp: '', minn: 10 }); fns.forEach((f) => f()); },
    data: (id) => { if (!cache[id]) { cache[id] = { status: 'loading', data: [] }; load(id); } return cache[id]; },
    onData: (f) => { fns.push(f); f(); }, setLink() {}, refresh() {},
    dataBase: () => base,
    set: SET,
  };
  base.then((b) => { window.__dataBase = b; });   // (for the page's own links to a replay file)
})();
