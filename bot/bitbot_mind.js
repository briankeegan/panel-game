// BITBOT'S MIND, for GameCreator's survivor.js frame loop.
//
// The live BitBot is three pieces, two of them not here:
//   bot/SurvivalLink.lua   (this repo)  the client: sends the server's board
//                                       each frame, presses what comes back
//   survivor.js            (GameCreator) the frame loop: rebuilds the board on
//                                       pa-engine.js (the server's rules), asks
//                                       a worker for decisions ahead of time,
//                                       turns each into keys (search.h's walk)
//   this file                           the worker: BitBot deciding
//
// survivor.js starts its worker from survivor_mind.js beside it; the workflow
// copies this file over that one in a fresh GameCreator checkout. So BitBot
// itself (games/the-game/ai/eval/bitbot.js) is whatever GameCreator holds at
// run time -- unchanged, and current, while it is still being worked on.
//
// The protocol is survivor_mind.js's: a message is a board predicted for a
// frame still to come; the answer is the decision for that frame, as
// { id, epoch, at, kind: 'swap' | 'raise' | 'hold', move, ms }.
//
// BitBot reads a board the way panel-engine.js holds one; pa-engine.js's
// toPanelEngine makes that view of the server's board (shock panels as the
// colour 8 they match as). Keys are not BitBot's business here: survivor.js
// presses them, so BitBot's update() -- its own walk and raise latch -- does
// not run; decide() does.
var wt = require('worker_threads'), path = require('path');
var DIR = __dirname;
require(path.join(DIR, '..', '..', 'panel-engine.js'));
require(path.join(DIR, '..', '..', 'panel-cpu.js'));
var BitBot = require(path.join(DIR, 'bitbot.js')), PA = require(path.join(DIR, 'pa-engine.js')), PE = globalThis.PanelEngine;
var cfg = wt.workerData;
var OPTS = { reaction: cfg.profile.reaction };
var bot = null, snap = null;

// BitBot keeps state between decisions (the boards it has seen, its recent
// swaps, a plan in progress). A decision the frame loop never played is
// taken back before the next, as survivor_mind.js does, one level deep so
// arrays it grows in place are restored too.
function save(b) {
  var s = {};
  for (var k in b) if (Object.prototype.hasOwnProperty.call(b, k)) s[k] = Array.isArray(b[k]) ? b[k].slice() : b[k];
  return s;
}
function restore(b, s) {
  for (var k in b) if (Object.prototype.hasOwnProperty.call(b, k) && !Object.prototype.hasOwnProperty.call(s, k)) delete b[k];
  for (k in s) b[k] = Array.isArray(s[k]) ? s[k].slice() : s[k];
}

wt.parentPort.on('message', function (m) {
  if (m.type === 'reset') { bot = null; snap = null; return; }
  var t0 = Date.now(), out;
  try {
    var view = PA.toPanelEngine(PA.revive(m.board), PE);
    if (!bot) bot = new BitBot(view, OPTS);
    if (snap && !m.acted) restore(bot, snap);
    snap = save(bot);
    bot.stack = view;
    // the raise button as the frame loop holds it
    bot.raiseFrames = m.hold.left; bot._raiseStarted = m.hold.started;
    var d = bot.decide();
    var kind = d && (d.kind === 'swap' || d.kind === 'raise') ? d.kind : 'hold';
    out = { id: m.id, epoch: m.epoch, at: m.at, kind: kind,
            move: kind === 'swap' && d.move ? [d.move[0], d.move[1]] : null, ms: Date.now() - t0, line: null, lineAt: null };
    if (kind === 'swap' && !out.move) out.kind = 'hold';
  } catch (e) {
    out = { id: m.id, epoch: m.epoch, at: m.at, error: String(e && e.stack || e), ms: Date.now() - t0 };
  }
  wt.parentPort.postMessage(out);
});
wt.parentPort.postMessage({ ready: true });
