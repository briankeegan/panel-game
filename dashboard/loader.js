// Stand-in for the artifact "dash" object: loads data files from ./data and runs the page's onData callbacks when they arrive.
(function () {
  const P = { ver: '', opp: '', minn: 10 }, fns = [], cache = {};
  const URLS = (id) => (id === 'games' || id === 'versions') ? 'data/' + id + '.json' : 'data/' + id + '.json.gz';
  async function load(id) {
    try {
      const url = URLS(id), r = await fetch(url); if (!r.ok) throw new Error(url + ' ' + r.status);
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
  };
})();
