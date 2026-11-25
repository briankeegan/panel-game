#!/usr/bin/env node
// THE PROFILE AS NUMBERS, for a native host (lua/GambitNative.lua): its hands and pacing, Gambit's numbers and the rules, encoded by
// the loader (gambit.js rulesWords) -- the one encoder there is. The profile is GC_SURVIVOR_PROFILE's.
//
//   GC_SURVIVOR_PROFILE=<profile> node words.js > gambit.words
var path = require('path'), G = require('./gambit.js'), SH = require('../eval/survivor_shared.js');
var p = SH.profile(), gp = p.gambit || {}, rules = G.rulesFor(p, path.join(__dirname, '..', 'eval'));
if (!rules) { console.error('words.js: the profile has no gambit'); process.exit(2); }
var names = [], R = G.rulesWords(rules.get(null), names), pace = p.pace && p.pace.slack ? p.pace : null;
var out = [];
out.push(['setup', p.reaction, p.swapGap, p.cursorMoveFrames, p.ahead || 90, pace ? pace.gap : -1, pace ? pace.jitter || 0 : 0, p.planHealth || 0].join(' '));
out.push(['profile', gp.mode ? names.indexOf(gp.mode) : -1, gp.ms || 0, gp.extendMs || 0, gp.width || 0, gp.depth || 0, gp.pool || 0, gp.extendDepth || 0,
          gp.extend === false ? 1 : 0].join(' '));
// (switching: the stretch between switches, in frames -- answer.c gb_switch)
if (gp.switch) out.push(['switch', gp.switch.min, gp.switch.max].join(' '));
// (the break search's share of the searches' time, in percent: under garbage, otherwise -- answer.c gb_share)
if (gp.share) out.push(['share', gp.share.under || 0, gp.share.otherwise || 0].join(' '));
names.forEach(function (n, i) { out.push('name ' + i + ' ' + n); });
out.push(['rules', R.n, R.words.length].concat(R.words).join(' '));
console.log(out.join('\n'));
