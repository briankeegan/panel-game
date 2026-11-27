#!/usr/bin/env python3
# describe.py LOG [FROM [TO]]: every GAMBITD decision of a survivor.log (or a replay's dec lines on stdin with '-') in plain words --
# what the move does, what it continues, what a set-up builds, why a hold holds -- read from the line's own fields and nothing else.
# The rank rule a decision names (won=k<line>) is quoted from rank.c: the comment above that line -- rank.c as the build that played
# the game had it (--sha SHA: read from git), since a key is a line number and the lines move from build to build.
import os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
HEADING = re.compile(r"^  // (\d{1,2}[a-z]?'{0,2}[a-zA-Z0-9]?\.) (.*)")   # (one or two digits: '5287.' in a comment is a frame)

def rank_rules(sha=None):
    """line number of each `return (cmpKey = __LINE__` -> the comment just above it, first sentence"""
    if sha:
        text = subprocess.run(['git', '-C', HERE, 'show', sha + ':./rank.c'], capture_output=True, text=True, check=True).stdout
    else:
        text = open(os.path.join(HERE, 'rank.c'), errors='replace').read()
    lines = text.splitlines()
    rules = {}
    for i, l in enumerate(lines):
        if 'cmpKey = __LINE__' not in l:
            continue
        j = i - 1
        while j >= 0 and not lines[j].strip().startswith('//') and i - j < 6:
            j -= 1
        block = []
        while j >= 0 and lines[j].strip().startswith('//'):
            block.insert(0, lines[j].strip()[2:].strip())
            j -= 1
        # (an exception note -- "(and only ...", "(but never ..." -- is not why the key decided: the comment above it, within the same
        # rule, is)
        while block and re.match(r'\(?(but|and|or|only) ', block[0]) and j > 0 and not HEADING.match(lines[j + 1]):
            k = j
            while k >= 0 and not lines[k].strip().startswith('//') and j - k < 8:
                k -= 1
            above = []
            while k >= 0 and lines[k].strip().startswith('//'):
                above.insert(0, lines[k].strip()[2:].strip())
                k -= 1
            if not above:
                break
            block, j = above, k
        text = ' '.join(block).strip()
        text = re.sub(r'^\(|\)$', '', text)
        text = re.split(r'(?<=[a-z0-9)]) -- |: (?=[a-z])', text)[0] if text else ''
        # (the rule the line belongs to: the nearest numbered heading above it, "1'a. THE ALLOWANCE'S RESERVE")
        head = ''
        for k in range(i, -1, -1):
            m = HEADING.match(lines[k])
            if m:
                head = m.group(1) + ' ' + re.split(r' \(|:| --', m.group(2))[0].strip()
                break
        # (a key of its own between two rules -- written at the function's own indent, `  if (...) return`, under a comment of its own --
        # belongs to no heading above it)
        own = re.match(r'^  if ', lines[i]) and block and not HEADING.match('  // ' + block[0])
        if own:
            head = ''
        if head and re.match(r'(but|and|or) ', text):   # (an exception to the rule, not why it decided)
            text = head
        elif head and text and not text.startswith(head.split(' ')[0]):
            text = head + ' / ' + text
        elif head and not text:
            text = head
        rules[i + 1] = text[:200] if text else 'rank.c line %d' % (i + 1)
    return rules

def fields(l):
    f = {}
    for m in re.finditer(r' ([a-zA-Z_0-9]+)=(\S+)', l):
        f.setdefault(m.group(1), m.group(2))
    return f

def made(f):
    c, x, b = f.get('combo', '0'), f.get('chain', '0'), f.get('broke', '0')
    out = []
    if x.isdigit() and int(x) >= 2: out.append('a %s-chain' % x)
    if c.isdigit() and int(c) >= 4: out.append('a combo of %s' % c)
    if b.isdigit() and int(b) > 0: out.append('breaks %s garbage' % b)
    return ', '.join(out)

def aim(f):
    a = f.get('aim')
    if not a: return ''
    if a == 'none': return 'nothing an attack is one swap from'
    if a == 'eight': return 'a two-column combo of 8'
    m = re.match(r'([cx])(\d+):e(\d+)/(\d+)', a)
    if not m: return a
    kind = 'a combo of %s' % m.group(2) if m.group(1) == 'c' else 'a %s-chain' % m.group(2)
    return '%s (%s ready a swap away)' % (kind, m.group(4))

ACT = {
    'break_line': 'breaking garbage', 'break_search': 'breaking garbage', 'convert': 'breaking garbage', 'lineup': 'breaking garbage',
    'nearest': 'going for the nearest attack', 'extend': 'continuing the chain', 'entry': "going for the mode's attack",
    'zip': 'zipping', 'level': 'flattening', 'survive': 'buying time', 'clear': 'clearing', 'cut': 'cutting the stack down',
    'ready': 'readying a break for the garbage coming', 'toward': 'walking toward an attack', 'raise': 'raising', 'setup': 'setting up',
}

DECIDED = {'drift': 'first in the order; compared again after the decision the keys no longer put it first (state moved)', 'only': 'the only line offered', 'tie': 'the order\'s keys left it alike with the next (kept first)',
           'raise': 'the raise', 'none': 'nothing offered'}
_DEC = None
def decide_place(n):
    """the comment block over decide.c's line n -- the place in playOf that put the line played in the order's place"""
    global _DEC
    if _DEC is None:
        try: _DEC = open(os.path.join(HERE, 'decide.c'), errors='replace').read().splitlines()
        except OSError: _DEC = []
    i = min(n - 1, len(_DEC) - 1)
    while i > 0 and i > n - 80 and not _DEC[i].strip().startswith('//'): i -= 1
    j = i
    while j > 0 and _DEC[j - 1].strip().startswith('//'): j -= 1
    t = ' '.join(_DEC[j].strip()[2:].split()) if 0 <= j < len(_DEC) else ''
    return '(' + t[:90].lstrip('(') + ')' if t else ''

def describe(l, rules):
    f = fields(l)
    p = l.split()
    frame, mode = p[1], p[2] if p[3].startswith('play=') else p[2] + ' ' + p[3]
    play = f.get('play', '?')
    life = 'lives' if f.get('v') == 'lives' else ('every option loses the board' if f.get('v') == 'dies' else '')
    key = f.get('won', '')
    km = re.match(r'k(\d+):(\S+)', key)
    rule = ('rule: %s (over %s)' % (rules.get(int(km.group(1)), 'rank.c %s' % km.group(1)), km.group(2))) if km else ''
    # (every decision labelled: won=d<line> -- decide.c's playOf put another line in the order's first place; only, tie, raise, none)
    dm = re.match(r'd(\d+):(\S+)', key)
    if dm: rule = 'rule: decide.c %s %s (over the order\'s first, %s)' % (dm.group(1), decide_place(int(dm.group(1))), dm.group(2))
    elif key.startswith('inv:'):
        im = re.match(r'inv:k(\d+):(\S+)', key)
        rule = 'rule: played first though %s puts %s before it (the order inverted)' % (rules.get(int(im.group(1)), 'rank.c %s' % im.group(1)), im.group(2)) if im else 'rule: ' + key
    elif key in DECIDED: rule = 'rule: ' + DECIDED[key]
    elif not key: rule = 'rule: (unlabelled)'
    if play == 'hold' and f.get('held'):
        h = f['held']
        what = {'raise': 'holding: waiting for the raise to open',
                'timing': 'holding: timing -- its next swap does as well pressed later (%s wanted)' % f.get('want'),
                'nothing': 'holding: nothing else was offered'}.get(h, 'holding -- ' + rule if rule else 'holding: the hold ranked first')
    elif play == 'hold':
        if f.get('deferred') == '1':
            what = 'holding: timing -- its next swap does as well pressed later (%s wanted)' % f.get('want')
        elif f.get('want') == 'raise':
            what = 'holding: waiting for the raise to open'
        elif f.get('cands') in ('-', None) or f.get('live', '').endswith('/1'):
            what = 'holding: nothing else was offered'
        elif rule:
            what = 'holding -- ' + rule
        else:
            what = 'holding: the hold ranked first'
    elif play in ('carry', 'carry_wait'):
        fr = f.get('from', '')
        m = re.match(r'(\d+):(\S+)', fr)
        begun = ('the %s begun at frame %s' % (ACT.get(m.group(2), m.group(2)), m.group(1))) if m else 'its line'
        what = 'continuing ' + begun + (' -- waiting for its next swap' if play == 'carry_wait' else '')
        mk = made(f)
        if mk: what += ' (%s)' % mk
    elif play == 'setup':
        a = aim(f)
        what = 'setting up ' + (a if a else '(no aim logged)')
        if f.get('twinLo') or f.get('free8'): what = 'setting up a two-column combo of 8'
    else:
        what = ACT.get(play, play)
        mk = made(f)
        if mk: what += ' (%s)' % mk
        a = aim(f)
        if a and play in ('zip', 'level', 'toward', 'ready'): what += ', leaving ' + a
    under = 'under garbage' if f.get('under') == '1' else ''
    tail = ', '.join(x for x in (under, 'tops out in %s frames' % f['dies'] if 'dies' in f else '', life) if x)
    return '%s %-11s %s%s%s' % (frame, mode, what, ' [%s]' % tail if tail else '', ('  ' + rule) if rule and (play != 'hold' or rule not in what) else '')

def main():
    sha = None
    if '--sha' in sys.argv:
        k = sys.argv.index('--sha'); sha = sys.argv[k + 1]; del sys.argv[k:k + 2]
    rules = rank_rules(sha)
    src = sys.stdin if sys.argv[1] == '-' else open(sys.argv[1], errors='replace')
    lo = int(sys.argv[2]) if len(sys.argv) > 2 else -1
    hi = int(sys.argv[3]) if len(sys.argv) > 3 else 1 << 30
    seen = set()
    try:
      for l in src:
        i = l.find('GAMBITD ')
        if i < 0: continue
        l = l[i:].rstrip('\n')
        fr = int(l.split()[1])
        if fr < lo or fr > hi or fr in seen: continue
        seen.add(fr)
        print(describe(l, rules))
    except BrokenPipeError:
      pass

if __name__ == '__main__':
    main()
