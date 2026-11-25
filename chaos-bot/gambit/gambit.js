// GAMBIT'S LOADER (README.md). It loads gambit.wasm and hands it what it decides on.
var fs = require('fs'), path = require('path');

var OPS = { '>=': 1, '<=': 2, '==': 3, '!=': 4, '>': 5, '<': 6 };   // rules.c OP_*
// A test as the rules file writes it ("<=3", or a number or a boolean: ==) as rules.c reads it: [op, n, near] -- near when it is a
// string gambit.js nearKey reads (no "!=", no negative). Undefined: not asked.
function testOf(t, what) {
  if (t === undefined || t === null) return [0, 0, 0];
  if (typeof t === 'number' || typeof t === 'boolean') return [OPS['=='], +t, 0];
  var m = /^(>=|<=|==|!=|>|<)\s*(-?\d+)$/.exec(String(t).trim());
  if (!m) throw new Error('gambit: ' + what + ' test ' + JSON.stringify(t) + ' is not one rules.c reads');
  return [OPS[m[1]], +m[2], m[1] !== '!=' && +m[2] >= 0 ? 1 : 0];
}
// An aim as rules.c reads it: combo, chain, send (each [op, n]) and break (-1 not asked, 0, 1). Every field meets() reads is here; an
// aim with any other is refused, so nothing in a list is dropped unseen.
var AIM_KEYS = { combo: 1, chain: 1, send: 1, break: 1 };
function aimWords(a) {
  Object.keys(a).forEach(function (k) { if (!AIM_KEYS[k]) throw new Error('gambit: an aim asks ' + k + ', which rules.c does not read'); });
  // ("fill": the chains the enemy's room asks, decide.c fillList -- rules.c OP_FILL)
  return [].concat(testOf(a.combo, 'combo'), a.chain === 'fill' ? [7, 0, 0] : testOf(a.chain, 'chain'), testOf(a.send, 'send'), [a.break === true ? 1 : a.break === false ? 0 : -1]);
}

// The exports of a gambit.wasm instance, bound: its io body and the calls that hand it what it decides on.
function bind(X) {
  function body(n) { return new Int32Array(X.memory.buffer, (X.gb_io() >>> 0), n); }
  return {
    X: X, body: body,
    // The mode's list (its aims, as the rules file has them), into rules.c.
    list: function (aims) {
      var w = [].concat.apply([], aims.map(aimWords)), b = body(w.length);
      for (var i = 0; i < w.length; i++) b[i] = w[i];
      if (X.gb_list(aims.length) !== aims.length) throw new Error('gambit: the list was refused (' + aims.length + ' aims)');
    }
  };
}
function load(file) {
  var inst = new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(file || path.join(__dirname, 'gambit.wasm'))),
                                      { env: { abort_poll: function () { return 0; }, clock_ms: function () { return Date.now(); } } });
  return bind(inst.exports);
}

// ---- THE RULES, as gambit.c reads them (gb_rules): every rule's `when` (facts by id), its list, its deadline, its floor and its raise
var FACTS = ['us.topped', 'us.stop', 'us.height', 'us.material', 'us.contact', 'us.dies', 'us.evenness', 'us.coming', 'us.heavy', 'us.nextLands',
             'us.breakWaits', 'us.queueKills', 'enemy.topped', 'enemy.height', 'enemy.stop', 'enemy.none'];   // facts.c FACT_*
var KEEPS = ['height', 'material', 'evenness'];   // facts.c KEEP_*
function keepWords(keep) {
  if (!keep) return [0].concat(testOf(), testOf(), testOf());
  var w = [1];
  KEEPS.forEach(function (k) { w = w.concat(testOf(keep[k] !== undefined ? keep[k] : keep['us.' + k], 'keep ' + k)); });
  Object.keys(keep).forEach(function (k) { if (KEEPS.indexOf(k.replace(/^us\./, '')) < 0) throw new Error('gambit: a floor asks ' + k + ', which facts.c does not keep'); });
  return w;
}
// the words of a table set ({ defend, attack, opener, keep, raise, underGarbage }), its rules' names numbered in `names` (the opener:
// the rule a fight plays from its start until either board tops out -- decide.c read)
function rulesWords(tables, names) {
  var w = [], n = 0;
  [['defend', 0], ['attack', 1], ['opener', 2]].forEach(function (tb) {
    (tables[tb[0]] || []).forEach(function (r) {
      if (names.indexOf(r.name) < 0) names.push(r.name);
      var when = Object.keys(r.when || {}), list = aimsOf(r), end = 0, aims = [];
      for (var i = 0; i < list.length; i++) { if (typeof list[i] === 'string') { end = list[i] === 'hold' ? 2 : 1; break; } aims.push(list[i]); }
      w.push(tb[1], names.indexOf(r.name), when.length);
      when.forEach(function (k) { w.push(FACTS.indexOf(k)); w = w.concat(testOf(r.when[k], 'when ' + k)); });
      w.push(aims.length); aims.forEach(function (a) { w = w.concat(aimWords(a)); });
      w.push(end, typeof r.by === 'string' ? FACTS.indexOf(r.by) : -1, typeof r.by === 'number' ? r.by : -1);
      w = w.concat(keepWords(r.keep), [(r.raise && r.raise.to) || 0]);
      n++;
    });
  });
  w = w.concat(keepWords(tables.keep), [(tables.raise && tables.raise.to) || 0, tables.underGarbage === 'ignore' ? 1 : 0]);
  return { n: n, words: w };
}

// ---- THE RULES FILE, read again whenever it changes (its mtime): it may be rewritten between matches or while one runs, and the next
// decision plays by it. An opponent with tables of its own is played by those. A file that fails to read or parse leaves the last good
// tables in force; the rules it drops (a `when` on the wrong side's board, no aim) are listed in `errors`.
var SIDE = { defend: 'us.', attack: 'enemy.', opener: 'us.' };
function aimsOf(rule) { if (Array.isArray(rule.aims)) return rule.aims; var l = []; if (rule.aim) l.push(rule.aim); if (rule.else) l.push(rule.else); return l; }
// a table's rules, each `when` led by its own side's board: a rule that tests only the other side is dropped, and the reason kept
function checked(tables) {
  var out = { defend: [], attack: [], opener: [] }, errors = [];
  ['defend', 'attack', 'opener'].forEach(function (t) {
    ((tables && tables[t]) || []).forEach(function (r, i) {
      var keys = Object.keys(r.when || {}), own = keys.filter(function (k) { return k.indexOf(SIDE[t]) === 0; });
      if (keys.length && !own.length) errors.push(t + ' rule ' + i + ' (' + (r.name || '') + ') tests only ' + keys.join(', ') + ': a ' + t + ' rule tests ' + SIDE[t] + '* first');
      else if (!aimsOf(r).length || !aimsOf(r).every(function (a) { return (a && typeof a === 'object') || a === 'default' || a === 'hold'; })) errors.push(t + ' rule ' + i + ' (' + (r.name || '') + ') has no aims, or one that is not an aim, "default" or "hold"');
      else out[t].push(r);
    });
  });
  return { tables: out, errors: errors };
}
// every table checked, each with the file's settings -- the floor (keep), the raise, what is done under garbage -- an opponent's over the file's
function parse(j) {
  var c = checked(j), own = {}, errors = c.errors.slice();
  var settings = function (o) { return { keep: (o && o.keep) || j.keep || null, raise: (o && o.raise) || j.raise || null, underGarbage: (o && o.underGarbage) || j.underGarbage || 'break' }; };
  Object.assign(c.tables, settings(null));
  Object.keys(j.opponents || {}).forEach(function (name) {
    var co = checked(j.opponents[name]);
    own[name] = Object.assign(co.tables, settings(j.opponents[name]));
    co.errors.forEach(function (e) { errors.push(name + ': ' + e); });
  });
  return { all: c.tables, own: own, errors: errors };
}
function Rules(file) { this.file = file; this.mtime = -1; this.all = { defend: [], attack: [] }; this.own = {}; this.error = null; this.errors = []; }
Rules.prototype.get = function (opponent) {
  try {
    var st = fs.statSync(this.file);
    if (st.mtimeMs !== this.mtime) {
      var P = parse(JSON.parse(fs.readFileSync(this.file, 'utf8')));
      this.all = P.all; this.own = P.own; this.errors = P.errors; this.mtime = st.mtimeMs; this.error = null;
      console.error('GAMBIT rules ' + this.file + ': ' + this.all.defend.length + ' defend, ' + this.all.attack.length + ' attack, ' + this.all.opener.length + ' opener, ' + Object.keys(P.own).length + ' opponents' + (P.errors.length ? '; dropped: ' + P.errors.join(' | ') : ''));
    }
  } catch (e) { this.error = String(e && e.message || e); }
  return (opponent && this.own[opponent]) || this.all;
};
// The rules of a profile with `gambit` (null without): its own object, the file GC_GAMBIT_RULES names, or the file the profile names
function rulesFor(profile, dir) {
  var g = profile && profile.gambit;
  if (!g) return null;
  if (g.rules && typeof g.rules === 'object') { var P = parse(g.rules); return { get: function (opponent) { return (opponent && P.own[opponent]) || P.all; } }; }
  if (process.env.GC_GAMBIT_RULES) return new Rules(process.env.GC_GAMBIT_RULES);
  return new Rules(path.isAbsolute(g.rules) ? g.rules : path.join(dir, g.rules));
}

// ---- GAMBIT: one bot's C Gambit, on a gambit.wasm of its own (native.js's machinery on it: the board written in, the root made)
var KIND = ['hold', 'swap', 'raise'];
function Gambit(o) {
  var NAT = require(path.join(__dirname, '..', 'eval', 'native.js')), N = NAT.make();
  N.init(fs.readFileSync(path.join(__dirname, 'gambit.wasm')));
  this.N = N; this.X = N.exports(); this.G = bind(this.X);
  this.S = new N.Search({ reaction: o.reaction, swapGap: o.swapGap, cursorMoveFrames: o.cursorMoveFrames, threads: 1 });
  this.rules = o.rules; this.names = []; this.tables = null;
  var gp = o.gambit || {};
  this.mode = gp.mode || null;
  this.sw = gp.switch || null;
  this.share = gp.share || null;
  this.gp = [gp.ms || 0, gp.extendMs || 0, gp.width || 0, gp.depth || 0, gp.pool || 0, gp.extendDepth || 0, gp.extend === false ? 1 : 0, o.reaction, o.swapGap, o.cursorMoveFrames];
  this.lastAt = null;
}
// The tables for this opponent, into gambit.wasm when they change (the rules file is read again whenever it changes: rules.get)
Gambit.prototype.useTables = function (opp) {
  var t = this.rules.get(opp && opp.name);
  if (t === this.tables) return;
  var R = rulesWords(t, this.names), b = this.G.body(R.words.length);
  for (var i = 0; i < R.words.length; i++) b[i] = R.words[i];
  if (this.X.gb_rules(R.n) !== R.n) throw new Error('gambit: the rules were refused');
  this.tables = t;
  var mode = this.mode ? this.names.indexOf(this.mode) : -1;
  this.X.gb_profile.apply(null, [mode].concat(this.gp));
  this.X.gb_switch(this.sw ? this.sw.min : 0, this.sw ? this.sw.max : 0); this.X.gb_switch_game(Date.now() >>> 0);
  this.X.gb_share(this.share ? this.share.under || 0 : 0, this.share ? this.share.otherwise || 0 : 0);
};
// THE TURN: q { m (the question), board, arrivals, due, t0, margin, canRaise, mem } -- the answer as the frame loop reads it
Gambit.prototype.answer = function (q) {
  var m = q.m, X = this.X;
  this.useTables(m.opp);
  if (this.lastAt !== null && m.at < this.lastAt) { X.gb_new_game(); X.gb_switch_game(Date.now() >>> 0); }   // (a clock behind the last: a new game, nothing carried on)
  this.lastAt = m.at;
  this.S.reset();
  var root = this.S.root(q.board.copy(), m.hold, q.arrivals || [], false), opp = m.opp || null;
  var n = X.gb_answer(this.S.ctx, root._i, m.id | 0, m.at | 0, m.topped ? 1 : 0, opp ? 1 : 0, opp && opp.out ? 1 : 0, opp && opp.top != null ? 1 : 0, opp && opp.top != null ? opp.top : 0,
                      opp && opp.stop != null ? 1 : 0, opp && opp.stop != null ? opp.stop : 0, m.allowance != null ? 1 : 0, m.allowance != null ? m.allowance : 0,
                      m.lineFrom != null ? m.lineFrom : -1, m.linePressed || 0, q.canRaise() ? 1 : 0, q.due || 0, q.t0 || Date.now(), q.margin || 0);
  if (n < 0) throw new Error('gambit: the question was refused');
  var w = this.G.body(n), k = 0, r = function () { return w[k++]; };
  var kind = r(), mr = r(), mc = r(), raiseNow = r(), raiseAfter = r(), verdict = r(), holdLives = r(), brk = r(), urgent = r();
  var offered = r(), lineup = r(), touch = r(), took = r(), clears = r(), dump = r();
  var play = r(), combo = r(), chain = r(), chainAll = r(), broke = r(), done = r(), fire = r(), idleMs = r(), brMs = r();
  var hand = [], nh = r(); for (var i = 0; i < nh; i++) { var h = r(); hand.push([h >> 3, h & 7]); }
  var seq = [], ns = r(); for (i = 0; i < ns; i++) { var s = r(); seq.push([s >> 3, s & 7]); }
  var rule = r(), nlive = r(), ncands = r(), ruleName = rule >= 0 ? this.names[rule] : null;
  // (a JavaScript host presses a line handed on as soon as it can, so only a line the judge pressed so is handed to it: not a settled one,
  // nor one handed on behind a hold)
  var handSettled = r(); for (i = 0; i < nh; i++) r();
  if (handSettled || kind !== 1) hand = [];
  var log = Buffer.from(new Uint8Array(X.memory.buffer, X.gb_log() >>> 0, X.gb_log_len())).toString('latin1');
  console.error(log.replace(/^(GAMBITD \d+) @\d+/, '$1 ' + (ruleName || '')) + ' wallMs=' + (Date.now() - (q.t0 || Date.now())));
  if (dump) console.error('GAMBITB ' + m.at + ' ' + require('zlib').gzipSync(require('v8').serialize(q.board)).toString('base64') + ' ' + JSON.stringify((q.arrivals || []).map(function (a) { return [a.at, a.width, a.height]; })));
  if (kind < 0) return null;
  var name = Buffer.from(new Uint8Array(X.memory.buffer, X.gb_play_name(play) >>> 0, 32)).toString('latin1').replace(/\0.*$/, '');
  var found = kind === 1 && ns > 0, move = kind === 1 ? [mr, mc] : null;
  var info = { name: ruleName, live: nlive + '/' + ncands, lives: verdict === 1 ? true : verdict === 2 ? false : null, play: name, found: found, verdict: ['none', 'lives', 'dies', 'raise'][verdict], combo: combo, chain: chain, chainAll: chainAll, broke: broke,
               done: done >= 0 ? done : null, fire: fire >= 0 ? fire : null, seq: found ? seq : null };
  return { id: m.id, epoch: m.epoch, at: m.at, src: 'gambit', kind: KIND[kind], move: move, raiseFrames: raiseNow, raiseAfter: raiseAfter,
           ms: Date.now() - (q.t0 || Date.now()), idleMs: idleMs,
           claim: found ? { play: name, chain: chain, chainAll: chainAll, combo: combo, broke: broke, done: done >= 0 ? done : (fire >= 0 ? fire : 0), seq: seq } : null,
           queued: m.posted ? (q.t0 || 0) - m.posted : 0, brMs: brMs, line: hand.length ? hand : null, lineAt: null, lineFree: hand.length > 0,
           pace: { hold: !!holdLives, brk: !!brk, urgent: !!urgent }, mem: q.mem ? q.mem() : null,
           breaks: brk ? { offered: offered, lineup: !!lineup, touch: !!touch, took: !!took } : null,
           diag: { walk: null, clears: clears, gambit: info } };
};
Gambit.prototype.newGame = function () { this.X.gb_new_game(); this.lastAt = null; };
// THE BREAK SEARCH ALONE (the reach report: was a break there to find?): the board and the mode's list, searched for up to `ms` -- the
// break's line (swaps as [row, col]) or null
Gambit.prototype.breakOn = function (board, arrivals, aims, ms, listOn) {
  this.S.reset();
  var r = this.S.root(board.copy(), { left: 0, started: false }, arrivals || [], false), X = this.X;
  this.G.list(aims); X.gb_list_on(listOn === 0 ? 0 : 1);
  X.gb_decision_start(this.S.ctx, r._i, 0, -1, 0, 1, 0);
  return this.breakPath(ms);
};
// The same from a board as a native host logs it (GAMBITB C<size>:<base64>) and its arrivals ([at, width, height], frames from it).
// listOn 0: no line held to the list (a list ended by "default", as every list is under garbage); press { allow }: the input window's
// allowance the search is held to, as the decision was asked under it (none: no window)
Gambit.prototype.breakOnBytes = function (b64, arrivals, aims, ms, listOn, press) {
  var bytes = Buffer.from(b64, 'base64'), X = this.X, io = new Uint8Array(X.memory.buffer, X.gb_io() >>> 0, bytes.length);
  io.set(bytes);
  var w = this.G.body(Math.ceil(bytes.length / 4) + 3 * arrivals.length), k = Math.ceil(bytes.length / 4);
  arrivals.forEach(function (a) { w[k++] = a[0]; w[k++] = a[1]; w[k++] = a[2]; });
  if (X.gb_question_bytes(bytes.length, arrivals.length) < 0) throw new Error('gambit: the board bytes were refused');
  this.G.list(aims); X.gb_list_on(listOn === 0 ? 0 : 1);
  X.gb_press_allowance(press && press.allow >= 0 ? press.allow : -1);
  X.gb_decision_on(-1, 0, 1, 0);
  return this.breakPath(ms);
};
Gambit.prototype.breakPath = function (ms) {
  var X = this.X;
  var t0 = Date.now();
  X.gb_clock_start(t0 + ms);
  var w = this.G.body(X.gb_break(0, 0)), depth = w[0], k = 7, nm = w[k++], took = Date.now() - t0;
  if (!depth) return null;
  var first = nm ? [w[k] >> 3, w[k] & 7] : null; k += 3 * nm;
  var pl = w[k++], path = [];
  for (var i = 0; i < pl; i++) path.push([w[k + i] >> 3, w[k + i] & 7]);
  // (how it was found -- the first swap, the break built, the touch beam, its wider beam, a slab's line-up -- and the ms it took)
  var line = pl ? path : [first];
  line.how = w[5] ? 'lineup' : w[4] ? 'wide' : w[2] ? 'touch' : pl ? 'built' : 'first'; line.ms = took;
  return line;
};

module.exports = { load: load, bind: bind, aimWords: aimWords, testOf: testOf, rulesWords: rulesWords, aimsOf: aimsOf, checked: checked, parse: parse, Rules: Rules, rulesFor: rulesFor, FACTS: FACTS, Gambit: Gambit };
