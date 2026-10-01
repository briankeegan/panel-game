#!/usr/bin/env node
// BITBOT ON THE SERVER: GameCreator's BitBot, hooked up to bot/SurvivalLink.lua.
//
//   node bot/bitbot_link.js --dir <GameCreator>/games/the-game/ai/eval [--port 47777] [--host 127.0.0.1]
//
// BitBot is NOT changed or re-driven here. It plays exactly as it does in
// GameCreator's duels: one BitBot per match, its own update() every frame,
// so its walk, reaction cooldown, raise latch and reveal/stop-time wake-ups
// are all its own. This file only stands in for the engine it talks to:
//
//   each frame   the client (SurvivalLink.lua, brain "survival") sends the
//                server's board; it is rebuilt on pa-engine.js (the server's
//                rules) and shown to BitBot as the panel-engine.js Stack it
//                reads (pa-engine toPanelEngine), then BitBot.update() runs
//   its keys     what it passes to stack.setInput -- cursor and raise -- is
//                the frame's input
//   its swaps    BitBot swaps by calling stack.tryQueueSwap() when its cursor
//                arrives (panel-cpu.js driveWalk); that is pressed as the
//                swap key this frame, and the answer it gets is the server's
//                rules' own (pa-engine canSwapPanels at the cursor)
//
// The reply is { clock, input } with input in the client's key bits:
// Right 1, Left 2, Down 4, Up 8, Swap 16, Raise 32.
var net = require('net'), path = require('path');

var args = process.argv.slice(2), opt = { port: 47777, host: '127.0.0.1', dir: process.env.GC_EVAL_DIR };
for (var i = 0; i < args.length; i += 2) { var key = args[i].replace(/^--/, ''); opt[key] = key === 'port' ? Number(args[i + 1]) : args[i + 1]; }
if (!opt.dir) throw new Error('bitbot_link.js: --dir <GameCreator>/games/the-game/ai/eval');
var DIR = path.resolve(opt.dir);
require(path.join(DIR, '..', '..', 'panel-engine.js'));
require(path.join(DIR, '..', '..', 'panel-cpu.js'));
var BitBot = require(path.join(DIR, 'bitbot.js')), PA = require(path.join(DIR, 'pa-engine.js')), PE = globalThis.PanelEngine;

var BITS = { right: 1, left: 2, down: 4, up: 8, swap: 16, raise: 32 };

// WHAT BITBOT MAY ASK OF ITS STACK. Reads work on the view as they would on
// GameCreator's engine; setInput and tryQueueSwap are the two ways it acts,
// and both are relayed. BitBot is still being written: if a version of it
// calls anything else on the stack (a new way to act, say), that call would
// land on the throwaway view and never reach the server -- so it is caught
// and named in the log ("not relayed"), and the deploy's pre-flight fails on
// it rather than putting a bot that silently does nothing in the lobby.
var RELAYED = { setInput: true, tryQueueSwap: true };
var READS = { panelAt: true, canSwap: true, isToppedOut: true, hasActivePanels: true, hasFallingGarbage: true, fillRatio: true };
var notRelayed = {};
function guard(view) {
  var depth = 0, proto = Object.getPrototypeOf(view);
  Object.getOwnPropertyNames(proto).forEach(function (name) {
    if (name === 'constructor' || RELAYED[name] || typeof proto[name] !== 'function') return;
    var fn = proto[name];
    view[name] = function () {
      // only BitBot's own calls: the engine calling itself is not BitBot acting
      if (depth === 0 && !READS[name] && !notRelayed[name]) {
        notRelayed[name] = true;
        console.log('not relayed: BitBot called stack.' + name + '(), which bitbot_link.js does not pass to the server');
      }
      depth++;
      try { return fn.apply(this, arguments); } finally { depth--; }
    };
  });
}

function Match(level) {
  this.level = level;
  this.bot = null;
  this.stats = { frames: 0, swaps: 0, swapsRefused: 0, raiseFrames: 0, maxMs: 0 };
}
// One frame: BitBot plays it on the server's board; the keys it pressed come back.
Match.prototype.frame = function (state) {
  var t0 = Date.now();
  var truth = PA.fromLua(state, this.level, new PA.Unseen());
  var view = PA.toPanelEngine(truth, PE);
  var input = {}, swap = false, stats = this.stats;
  guard(view);
  view.setInput = function (inp) { input = inp || {}; };
  view.tryQueueSwap = function (row, col) {
    var p1 = truth.panels[row] && truth.panels[row][col], p2 = truth.panels[row] && truth.panels[row][col + 1];
    var ok = !!(p1 && p2 && truth.canSwapPanels(p1, p2)[0]) && row === view.curRow && col === view.curCol;
    if (ok) { swap = true; stats.swaps++; } else stats.swapsRefused++;
    return ok;
  };
  if (!this.bot) this.bot = new BitBot(view, {});
  this.bot.stack = view;
  this.bot.update();
  var bits = 0;
  ['right', 'left', 'down', 'up', 'raise'].forEach(function (k) { if (input[k]) bits += BITS[k]; });
  if (swap || input.swap) bits |= BITS.swap;
  if (input.raise) stats.raiseFrames++;
  stats.frames++;
  stats.maxMs = Math.max(stats.maxMs, Date.now() - t0);
  return { clock: truth.clock, input: bits };
};
Match.prototype.summary = function () {
  // BitBot's own counters when it has them -- a later version may not
  var b = this.bot, c = b && b.counts || {}, out = { stats: this.stats, notRelayed: Object.keys(notRelayed) };
  if (b) { out.spend = b.spend; out.decisions = b.decisions; out.counts = { swaps: c.swaps, raises: c.raises, holds: c.holds }; }
  return JSON.stringify(out);
};

var server = net.createServer(function (sock) {
  var buf = '', match = null;
  sock.setNoDelay(true);
  sock.on('error', function (e) { console.log('link: ' + e.message); });
  sock.on('close', function () { if (match) console.log('match over: ' + match.summary()); match = null; });
  sock.on('data', function (chunk) {
    buf += chunk;
    var nl;
    while ((nl = buf.indexOf('\n')) >= 0) {
      var line = buf.slice(0, nl); buf = buf.slice(nl + 1);
      if (!line) continue;
      var m = JSON.parse(line), reply;
      if (m.t === 'match') {
        if (match) console.log('match over: ' + match.summary());
        match = new Match({ levelData: m.levelData, behaviours: m.behaviours, stackOverConditions: m.stackOverConditions });
        console.log('match start');
        reply = { ok: true };
      } else if (m.t === 'f') {
        try { reply = match ? match.frame(m.state) : { input: 0 }; }
        catch (e) { console.log('frame failed: ' + (e && e.stack || e)); reply = { input: 0 }; }
      } else if (m.t === 'bye') {
        if (match) console.log('match over: ' + match.summary());
        match = null; reply = { ok: true };
      }
      sock.write(JSON.stringify(reply) + '\n');
    }
  });
});
server.listen(opt.port, opt.host, function () { console.log('BitBot listening on ' + opt.host + ':' + opt.port + ' (bitbot.js from ' + DIR + ')'); });
