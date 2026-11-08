#!/usr/bin/env python3
"""PPA's zpaq-std decoder (pas/plugin/ppa1zpaql.inc) run on segments: each
must give back its file byte for byte.

    test_ppadec.py vm    DUMPDIR [NAME ...] [--orig DIR] [--max-plain N]
    test_ppadec.py py    DUMPDIR [NAME ...] [--orig DIR] [--max-plain N]
    test_ppadec.py block DUMPDIR NAME1 NAME2 ... [--orig DIR] [--zr RUNNER]
    test_ppadec.py jit   DUMPDIR [NAME ...] --zr RUNNER [--orig DIR] [--max-plain N]
    test_ppadec.py args  DUMPDIR [NAME ...]

DUMPDIR holds pas/tests/dump_streams' output (NAME.stream, NAME.json and,
for each static image stream s, its bands' first parts NAME.s<s>.b<j>.meta).
A segment is what zpaq-std makes of a file: the original size (u32,
little-endian) then the stream. Without NAMEs, every file of DUMPDIR the
codec takes (each image stream of the static model, the others kept as
bytes, no JPEG of a JNG), smallest first; --max-plain N keeps those whose
image streams' plain bytes add up to less than N. The originals are in
--orig DIR (default: tests/png for a DUMPDIR named png, else
/mnt/IA_LAB/agentes/ppa/sets/<DUMPDIR's name>).

Each segment runs with the arguments zpaq-std would give it:
$1 = ceil log2 of the segment, $2 = ceil log2 of the original, and $3, $4
from what the stream needs (ppadec.zl's header: the query's sums, rounded up
to powers of two; `args` prints them). --dh K / --dm K run with H or M
2^K times that (K < 0: too small, which must be error(), never other
bytes).

  vm     the compiled program (from the .inc) in zpaqlvm, one instruction
         at a time (slow: about 2 M instructions a second);
  py     the sources (model.zl, deflate.zl, ppadec.zl, as gen_ppadec.py
         joins them) run in CPython with zpaqlc's 32-bit semantics
         (test_model_zl's loader): the source's logic, much faster;
  block  NAME1, NAME2, ... as segments of ONE block, in zpaqlvm (or
         RUNNER's libzpaq with --zr): each must start as the first did
         (reset);
  jit    the .inc's config through RUNNER, a libzpaq program run as
         RUNNER <cfg> <$3|$4<<8> <out> <segment>... (libzpaq's JIT; not
         part of the repository)."""
import json, math, os, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import gen_ppadec

SETS = '/mnt/IA_LAB/agentes/ppa/sets'


def lg(n):
    k = 0
    while (1 << k) < n:
        k += 1
    return k


def zwords(ml, wb):
    return (3 << (ml + 6)) + (1 << max(wb, 9))


def taken(j):
    """the codec takes it: each stream static or kept as bytes, one image at least"""
    ss = j['streams']
    return bool(j.get('taken')) and all(s['mode'] in (0, 4) for s in ss) and any(s['mode'] == 4 for s in ss)


def plain_total(j):
    return sum(s['zlib']['plain_len'] for s in j['streams'] if s['mode'] == 4)


def needs(ddir, name, j, seglen, static_words):
    """H words and M bytes, as the plugin's query would sum them"""
    h = static_words + 2 * j['n_subs'] + 8 * len(j['chunks']) + 24 * len(j['streams'])
    hx = 0
    m = seglen + os.path.getsize(os.path.join(ddir, name + '.sub0'))
    mx = 0
    for s in j['streams']:
        if s['mode'] != 4:
            continue
        im, z = s['image'], s['zlib']
        hx = max(hx, 5 * (im['width'] + 4) * im['bpp'], zwords(z['mem_level'], z['window_bits']))
        m += s['length']
        first = 0
        for b in range(len(im['bands'])):
            first = max(first, os.path.getsize(os.path.join(ddir, '%s.s%d.b%d.meta' % (name, s['index'], b))))
        mx = max(mx, z['plain_len'] + first)
    return h + hx, m + mx


def orig_dir(ddir, opt):
    if opt:
        return opt
    b = os.path.basename(os.path.normpath(ddir))
    if b == 'png':
        return os.path.join(REPO, 'tests', 'png')
    return os.path.join(SETS, b)


class Case:
    def __init__(self, ddir, name, odir, static_words):
        self.name = name
        self.j = json.load(open(os.path.join(ddir, name + '.json')))
        stream = open(os.path.join(ddir, name + '.stream'), 'rb').read()
        self.seg = self.j['size'].to_bytes(4, 'little') + stream
        self.want = open(os.path.join(odir, self.j['file']), 'rb').read()
        self.hw, self.mb = needs(ddir, name, self.j, len(self.seg), static_words)
        self.ph, self.pm = lg(self.hw), lg(self.mb)
        self.args = [lg(len(self.seg)), lg(len(self.want)), self.ph, self.pm]


def config():
    return gen_ppadec.config_of_inc(open(gen_ppadec.INC).read())


def static_words():
    t = open(gen_ppadec.INC).read()
    return int(t.split('PPA1_ZPAQL_STATIC_WORDS = ')[1].split(';')[0])


def describe(got, want):
    if got == want:
        return 'the original'
    if len(got) != len(want):
        n = min(len(got), len(want))
    else:
        n = len(got)
    d = next((i for i in range(n) if got[i] != want[i]), n)
    return 'DIFFERS (%d bytes of %d, first difference at %d)' % (len(got), len(want), d)


def run_vm(cfg, c):
    import zpaqlvm
    out, steps, _ = zpaqlvm.run_config(cfg, c.seg, c.args)
    return out, steps


def run_py(c):
    import test_model_zl
    src = gen_ppadec.source()
    # H and M as the query sizes them (the loader sets hsize and msize)
    out, ns = test_model_zl.run_py(src, c.seg, 1 << c.ph, 1 << c.pm)
    return out, None


def run_jit(cfg, c, zr, segs=None):
    with tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR')) as td:
        cp = os.path.join(td, 'ppa1.cfg')
        open(cp, 'w').write(cfg)
        paths = []
        for i, s in enumerate(segs or [c.seg]):
            p = os.path.join(td, 'seg%d' % i)
            open(p, 'wb').write(s)
            paths.append(p)
        op = os.path.join(td, 'out')
        r = subprocess.run([zr, cp, str(c.ph | c.pm << 8), op] + paths, capture_output=True, text=True)
        if r.returncode:
            raise RuntimeError('runner: ' + (r.stderr.strip() or 'exit %d' % r.returncode))
        return open(op, 'rb').read(), None


def main():
    args = sys.argv[1:]
    opts = {}
    for k in ('--orig', '--max-plain', '--zr', '--dh', '--dm'):
        if k in args:
            i = args.index(k)
            opts[k] = args[i + 1]
            del args[i:i + 2]
    mode, ddir, names = args[0], args[1], args[2:]
    odir = orig_dir(ddir, opts.get('--orig'))
    sw = static_words()
    # --dh/--dm: H or M that many powers of two off the query's (a smaller
    # one must stop with error(), never give wrong bytes)
    dh, dm = int(opts.get('--dh', '0')), int(opts.get('--dm', '0'))
    cfg = config()
    if not names:
        cand = []
        for f in os.listdir(ddir):
            if f.endswith('.json'):
                j = json.load(open(os.path.join(ddir, f)))
                if taken(j):
                    cand.append((plain_total(j), f[:-5]))
        mx = int(opts.get('--max-plain', '0'))
        names = [n for p, n in sorted(cand) if not mx or p < mx]
    pcomp = int(open(gen_ppadec.INC).read().split('PPA1_ZPAQL_PCOMP_BYTES = ')[1].split(';')[0])
    print('# %s: %s, %d bytes of PCOMP, %d files' % (mode, os.path.relpath(gen_ppadec.INC, REPO), pcomp, len(names)))
    sys.stdout.flush()
    if mode == 'block':
        import zpaqlvm
        cs = [Case(ddir, n, odir, sw) for n in names]
        segs = [c.seg for c in cs]
        a = [lg(max(map(len, segs))), lg(max(len(c.want) for c in cs)), max(c.ph for c in cs), max(c.pm for c in cs)]
        t = time.time()
        try:
            if '--zr' in opts:
                # the runner's output is the segments' outputs one after another
                cs[0].ph, cs[0].pm = a[2], a[3]
                out, _ = run_jit(cfg, cs[0], opts['--zr'], segs)
                outs, steps, k = [], 0, 0
                for c in cs:
                    outs.append(out[k:k + len(c.want)])
                    k += len(c.want)
                if k != len(out):
                    outs.append(out[k:])
            else:
                outs, steps, _ = zpaqlvm.run_segments(cfg, segs, a)
            ok = outs == [c.want for c in cs]
            what = ', '.join(describe(o, c.want) for o, c in zip(outs, cs))
        except RuntimeError as e:
            ok, what, steps = False, str(e), 0
        print('%s one block: %s: %s (H 2^%d M 2^%d, %d instructions, %.1f s)' % (
            'OK  ' if ok else 'FAIL', ' + '.join(names), what, a[2], a[3], steps, time.time() - t))
        sys.exit(0 if ok else 1)
    fails = 0
    for n in names:
        t = time.time()
        steps = None
        try:
            c = Case(ddir, n, odir, sw)
            c.ph += dh
            c.pm += dm
            c.args = c.args[:2] + [c.ph, c.pm]
        except (OSError, KeyError) as e:
            print('SKIP %s: %s' % (n, e))
            continue
        if mode == 'args':
            print('%s seg %d orig %d H %d words (2^%d) M %d bytes (2^%d) args %s' % (
                n, len(c.seg), len(c.want), c.hw, c.ph, c.mb, c.pm, c.args))
            continue
        try:
            if mode == 'vm':
                out, steps = run_vm(cfg, c)
            elif mode == 'py':
                out, steps = run_py(c)
            elif mode == 'jit':
                out, steps = run_jit(cfg, c, opts['--zr'])
            else:
                raise SystemExit('mode: vm, py, block, jit or args')
            what = describe(out, c.want)
            ok = out == c.want
        except Exception as e:
            ok, what = False, 'error: %s %s' % (type(e).__name__, e)
        fails += not ok
        print('%s %s %s (%d bytes, %d plain, H 2^%d M 2^%d%s, %.1f s)' % (
            'OK  ' if ok else 'FAIL', n, what, len(c.want), plain_total(c.j), c.ph, c.pm,
            ', %d instructions' % steps if steps else '', time.time() - t))
        sys.stdout.flush()
    if mode != 'args':
        print('# %d files, %d failed' % (len(names), fails))
    sys.exit(1 if fails else 0)


if __name__ == '__main__':
    main()
