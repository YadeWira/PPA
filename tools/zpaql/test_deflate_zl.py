#!/usr/bin/env python3
"""pas/plugin/zpaql/deflate.zl against PPA's own deflate streams.

    test_deflate_zl.py py   DUMPDIR... [-j 8] [--max-plain N]   the .zl run as Python
    test_deflate_zl.py vm   DUMPDIR... [-j 8] [--max-plain N]   compiled (opt=3), in zpaqlvm
    test_deflate_zl.py size                                     the test program's PCOMP size
    test_deflate_zl.py params WORK --ref ZREF [DUMPDIR...] [-j 8] [--vm] [--max-plain N]

DUMPDIR holds pas/tests/dump_streams' output: for each zlib stream s of a
file NAME, NAME.z<s>.plain (the bytes deflated), NAME.z<s>.deflate (what
PPA writes: header, blocks, end padding, Adler-32, tail) and in NAME.json
the stream's zlib parameters. Each stream is given to the test program
(deflate.zl plus the main below) as one segment:

    level strategy memLevel wbits flags CMF FLG endPad   (8 bytes)
    n (u32, little-endian)  tailLen (u32)  plain (n bytes)  tail

and what it writes must be the .deflate, byte for byte.

"params" covers what the files do not (levels 2, 3, 5, Z_FIXED, memLevel 1-7,
wbits 8-14, bare streams, stored and fixed blocks): small inputs, made up
and cut from the dumps' .plain files, under many parameters, each against
ZREF, a program that writes PPA's own stream for a file and parameters
(ppazlib.ZlibChoices + ppadeflate.Encode, the header ZlibHeader's):

    ZREF <plain> <level> <strategy> <memLevel> <wbits> <flags> <endPad> <out>

run with PPA_NOC=1 (the Pascal reference). WORK gets the inputs and the
reference streams; --vm runs the compiled program instead of CPython.

"py" runs the source in CPython with zpaqlc's semantics: every value 32
bits unsigned (+ - * << wrap, x // 0 = x % 0 = 0, shifts by n & 31, -x and
~x modulo 2^32), H a ring of 32-bit words and M one of bytes, the arrays
and tables at their places in H, slt/sle/sgt/sge/sar signed. The source is
rewritten (ast) so, then exec'd. "vm" compiles it with zpaqlc at opt=3 and
runs it in zpaqlvm with H and M just large enough (the interpreter is slow:
use it on the small streams)."""
import ast, json, math, os, sys, time
from multiprocessing import Pool

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
ROOT = os.path.dirname(os.path.dirname(HERE))
ZL = os.path.join(ROOT, 'pas', 'plugin', 'zpaql', 'deflate.zl')
M32 = 0xFFFFFFFF

TEST_MAIN = '''
ZSCRATCH = heap()

def main():
    global zmem
    zmem = base(ZSCRATCH)
    n = M[8] | (M[9] << 8) | (M[10] << 16) | (M[11] << 24)
    tl = M[12] | (M[13] << 8) | (M[14] << 16) | (M[15] << 24)
    zdeflate(16, n, M[0], M[1], M[2], M[3], M[4], M[5], M[6], M[7])
    a = 16 + n
    for i in range(tl):
        out(M[a + i])
'''


def source():
    return open(ZL).read() + TEST_MAIN


# ---------------------------------------------------------------- CPython

def _div(a, b):
    return a // b if b else 0


def _mod(a, b):
    return a % b if b else 0


def _s(v):
    return v - (1 << 32) if v & 0x80000000 else v


def slt(a, b): return _s(a) < _s(b)
def sle(a, b): return _s(a) <= _s(b)
def sgt(a, b): return _s(a) > _s(b)
def sge(a, b): return _s(a) >= _s(b)
def sar(a, n): return (_s(a) >> (n & 31)) & M32


class ZlError(Exception):
    pass


class Rewrite(ast.NodeTransformer):
    """32-bit arithmetic, and H, M and the arrays as rings, written out"""

    def __init__(self, bases, hmask, mmask):
        self.bases, self.hmask, self.mmask = bases, hmask, mmask

    @staticmethod
    def k(v):
        return ast.Constant(v)

    def mask(self, e, m=M32):
        return ast.BinOp(left=e, op=ast.BitAnd(), right=self.k(m))

    def visit_BinOp(self, n):
        self.generic_visit(n)
        if isinstance(n.op, (ast.Add, ast.Sub, ast.Mult)):
            return self.mask(n)
        if isinstance(n.op, (ast.LShift, ast.RShift)):
            r = n.right
            if not (isinstance(r, ast.Constant) and r.value < 32):
                r = self.mask(r, 31)
            n2 = ast.BinOp(left=n.left, op=n.op, right=r)
            return self.mask(n2) if isinstance(n.op, ast.LShift) else n2
        if isinstance(n.op, (ast.FloorDiv, ast.Mod)):
            f = '_div' if isinstance(n.op, ast.FloorDiv) else '_mod'
            return ast.Call(func=ast.Name(f, ast.Load()), args=[n.left, n.right], keywords=[])
        return n                       # & | ^ of 32-bit values

    def visit_UnaryOp(self, n):
        self.generic_visit(n)
        if isinstance(n.op, (ast.USub, ast.Invert)):
            return self.mask(n)
        return n

    def visit_AugAssign(self, n):
        t = n.target
        load = ast.parse(ast.unparse(t), mode='eval').body
        return self.visit(ast.copy_location(ast.Assign(targets=[t], value=ast.BinOp(left=load, op=n.op,
                                                                                   right=n.value)), n))

    def index(self, n):
        """(ring, index expression) for H[i], M[i], arr[i]; None otherwise"""
        if not isinstance(n.value, ast.Name):
            return None
        nm = n.value.id
        i = self.visit(n.slice)
        if nm == 'H':
            return '_H', self.mask(i, self.hmask)
        if nm == 'M':
            return '_M', self.mask(i, self.mmask)
        if nm in self.bases:
            return '_H', self.mask(ast.BinOp(left=self.k(self.bases[nm]), op=ast.Add(), right=i), self.hmask)
        return None

    def visit_Subscript(self, n):
        r = self.index(n)
        if r is None:
            raise ZlError('subscript of ' + ast.unparse(n))
        return ast.Subscript(value=ast.Name(r[0], ast.Load()), slice=r[1], ctx=n.ctx)

    def visit_Assign(self, n):
        v = self.visit(n.value)
        t = n.targets[0]
        if isinstance(t, ast.Subscript):
            r = self.index(t)
            v = self.mask(v, 255 if r[0] == '_M' else M32)
            t = ast.Subscript(value=ast.Name(r[0], ast.Load()), slice=r[1], ctx=ast.Store())
        return ast.copy_location(ast.Assign(targets=[t], value=v), n)

    def visit_Call(self, n):
        self.generic_visit(n)
        if isinstance(n.func, ast.Name) and n.func.id == 'base':
            return self.k(self.bases[n.args[0].id])
        return n


def ev(e, consts):
    return eval(compile(ast.Expression(e), '<const>', 'eval'), {'__builtins__': {}}, dict(consts))


def layout(tree):
    """the arrays' places in H (the heap last) and the tables' contents"""
    bases, tables, at, heap = {}, {}, 256, None
    consts = {}
    for node in tree.body:
        if isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name) and \
                node.targets[0].id.isupper() and not isinstance(node.value, ast.Call):
            consts[node.targets[0].id] = ev(node.value, consts)
    for node in tree.body:
        if isinstance(node, ast.Assign) and isinstance(node.value, ast.Call) and \
                isinstance(node.value.func, ast.Name) and node.value.func.id in ('array', 'table', 'heap'):
            nm, kind = node.targets[0].id, node.value.func.id
            if kind == 'heap':
                heap = nm
                continue
            if kind == 'table':
                vals = [ev(e, consts) for e in node.value.args[0].elts]
                tables[nm] = vals
                size = len(vals)
            else:
                size = ev(node.value.args[0], consts)
            bases[nm] = at
            at += size
    if heap:
        bases[heap] = at
    return bases, tables, at


def py_program(src, hbits, mbits):
    tree = ast.parse(src)
    bases, tables, fixed = layout(tree)
    body = []
    for node in tree.body:
        if isinstance(node, ast.Assign) and isinstance(node.value, ast.Call) and \
                isinstance(node.value.func, ast.Name) and node.value.func.id in ('array', 'table', 'heap'):
            continue
        body.append(node)
    tree.body = body
    tree = Rewrite(bases, (1 << hbits) - 1, (1 << mbits) - 1).visit(tree)
    for node in ast.walk(tree):
        for f in ('lineno', 'end_lineno', 'col_offset', 'end_col_offset'):
            if not isinstance(node, ast.stmt) and f in node.__dict__:
                delattr(node, f)
    ast.fix_missing_locations(tree)
    return compile(tree, ZL, 'exec'), bases, tables, fixed


def run_py(code_info, hbits, mbits, segment):
    code, bases, tables, fixed = code_info
    H = [0] * (1 << hbits)
    M = bytearray(1 << mbits)
    M[:len(segment)] = segment
    for nm, vals in tables.items():
        H[bases[nm]:bases[nm] + len(vals)] = vals
    outb = bytearray()

    def error():
        raise ZlError('error()')
    ns = dict(_H=H, _M=M, _div=_div, _mod=_mod, slt=slt, sle=sle, sgt=sgt, sge=sge, sar=sar,
              out=lambda c: outb.append(c & 255), error=error, inlen=lambda: len(segment))
    exec(code, ns)
    ns['main']()
    return bytes(outb)


# ---------------------------------------------------------------- cases

def cases(dirs, max_plain):
    out = []
    for d in dirs:
        for fn in sorted(os.listdir(d)):
            if not fn.endswith('.json'):
                continue
            name = fn[:-5]
            js = json.load(open(os.path.join(d, fn)))
            for s in js.get('streams', []):
                z = s.get('zlib')
                if not z:
                    continue
                p = os.path.join(d, '%s.z%d.plain' % (name, s['index']))
                q = os.path.join(d, '%s.z%d.deflate' % (name, s['index']))
                if not (os.path.exists(p) and os.path.exists(q)):
                    continue
                if max_plain and os.path.getsize(p) > max_plain:
                    continue
                out.append((os.path.basename(os.path.normpath(d)), name, s['index'], p, q, z))
    return out


def segment(p, q, z):
    plain = open(p, 'rb').read()
    want = open(q, 'rb').read()
    tl = z['tail_len']
    tail = want[len(want) - tl:] if tl else b''
    flags = (1 if z['raw'] else 0) | (2 if z['adler_ok'] else 0)
    hd = bytes([z['level'], z['strategy'], z['mem_level'], z['window_bits'], flags,
                z['header'][0], z['header'][1], z['end_pad']])
    seg = hd + len(plain).to_bytes(4, 'little') + tl.to_bytes(4, 'little') + plain + tail
    return seg, want


def h_bits(z):
    """H for the test program: its fixed arrays plus zwords()"""
    _, _, fixed = layout(ast.parse(source()))
    wb = max(z['window_bits'], 9)
    # zpaqlc puts the arrays after its 8192 words of variables (layout's start at 256)
    need = fixed - 256 + 8192 + (3 << (z['mem_level'] + 6)) + (1 << wb)
    return max(10, math.ceil(math.log2(need)))


def m_bits(n):
    return max(10, math.ceil(math.log2(n)))


_PY = {}


def job_py(c):
    setname, name, si, p, q, z = c
    seg, want = segment(p, q, z)
    hb, mb = h_bits(z), m_bits(len(seg))
    key = (hb, mb)
    if key not in _PY:
        _PY[key] = py_program(source(), hb, mb)
    t = time.time()
    try:
        got = run_py(_PY[key], hb, mb, seg)
    except Exception as e:
        return (setname, name, si, os.path.getsize(p), False, 'exception %r' % e, time.time() - t)
    return (setname, name, si, os.path.getsize(p), got == want, why(got, want), time.time() - t)


def why(got, want):
    if got == want:
        return ''
    i = 0
    while i < min(len(got), len(want)) and got[i] == want[i]:
        i += 1
    return 'got %d bytes, want %d, first difference at %d' % (len(got), len(want), i)


_VM = {}


def job_vm(c):
    import zpaqlc, zpaqlvm
    setname, name, si, p, q, z = c
    seg, want = segment(p, q, z)
    hb, mb = h_bits(z), m_bits(len(seg))
    if 'cfg' not in _VM:
        _VM['cfg'] = zpaqlc.compile_source(source(), 'ppadeflate', '$1', '$2', opt=3)[0]
    t = time.time()
    try:
        got, steps, size = zpaqlvm.run_config(_VM['cfg'], seg, [hb, mb])
    except Exception as e:
        return (setname, name, si, os.path.getsize(p), False, 'exception %r' % e, time.time() - t)
    return (setname, name, si, os.path.getsize(p), got == want, why(got, want) or '%d instructions' % steps,
            time.time() - t)


# ---------------------------------------------------------------- params

def param_inputs(work, dirs):
    import random
    rnd = random.Random(1)
    ins = {'empty': b'', 'one': b'a', 'two': b'ab', 'three': b'abc', 'four': b'abca',
           'rand3k': bytes(rnd.randrange(256) for _ in range(3000)),
           'rand40k': bytes(rnd.randrange(256) for _ in range(40000)),
           'zeros70k': bytes(70000),
           'text30k': b''.join(b'line %d of the same few words, again and again\n' % (i % 97) for i in range(700))[:30000]}
    blk = bytes(rnd.randrange(256) for _ in range(700))
    far = bytearray()
    for i in range(24):          # repeats 5000, then 9000 bytes apart: TOO_FAR, small windows
        far += blk + bytes(rnd.randrange(256) for _ in range(4300 + 4000 * (i & 1)))
    ins['far'] = bytes(far)
    small = bytearray()
    for i in range(4000):
        small.append(rnd.choice(b'aaaabbc') if i % 50 < 40 else rnd.randrange(256))
    ins['mixed4k'] = bytes(small)
    k = 0
    for d in dirs:
        ps = sorted(f for f in os.listdir(d) if f.endswith('.plain'))
        for f in ps[::max(1, len(ps) // 3)][:3]:
            data = open(os.path.join(d, f), 'rb').read()
            ins['cut%d' % k] = data[:50000]
            ins['cutmid%d' % k] = data[len(data) // 2:len(data) // 2 + 3500]
            k += 1
    os.makedirs(os.path.join(work, 'in'), exist_ok=True)
    os.makedirs(os.path.join(work, 'ref'), exist_ok=True)
    paths = {}
    for nm, data in ins.items():
        paths[nm] = os.path.join(work, 'in', nm + '.bin')
        open(paths[nm], 'wb').write(data)
    return paths


def param_cases(paths, vm):
    import random
    rnd = random.Random(2)
    out = []
    for nm, p in sorted(paths.items()):
        n = os.path.getsize(p)
        if vm and n > 4000:
            continue
        combos = [(lv, st, 8, 15) for lv in range(1, 10) for st in range(5)]
        if nm in ('text30k', 'far', 'cut0', 'mixed4k', 'rand3k') or (vm and nm.startswith('cutmid')):
            combos += [(lv, 0, ml, wb) for lv in (1, 3, 6, 9) for ml in range(1, 10) for wb in range(8, 16)]
        combos += [(rnd.randrange(1, 10), rnd.randrange(5), rnd.randrange(1, 10), rnd.randrange(8, 16))
                   for _ in range(20)]
        for c in combos:
            out.append((nm, p, c, rnd.randrange(4)))
    return out


def job_param(a):
    import subprocess
    nm, p, (lv, st, ml, wb), flags, work, ref, vm = a
    cid = '%s.l%d.s%d.m%d.w%d.f%d' % (nm, lv, st, ml, wb, flags)
    q = os.path.join(work, 'ref', cid + '.deflate')
    subprocess.run([ref, p, str(lv), str(st), str(ml), str(wb), str(flags), '0', q], check=True,
                   env=dict(os.environ, PPA_NOC='1'))
    want = open(q, 'rb').read()
    raw = bool(flags & 1)
    z = dict(level=lv, strategy=st, mem_level=ml, window_bits=wb, raw=raw, adler_ok=bool(flags & 2),
             header=[0, 0] if raw else [want[0], want[1]], end_pad=0, tail_len=0)
    return (job_vm if vm else job_py)(('params', cid, 0, p, q, z))


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 2
    mode = args.pop(0)
    jobs, max_plain = 1, 0
    dirs = []
    ref, vm, work = None, False, None
    if mode == 'params':
        work = args.pop(0)
    while args:
        a = args.pop(0)
        if a == '--ref':
            ref = os.path.abspath(args.pop(0))
        elif a == '--vm':
            vm = True
        elif a == '-j':
            jobs = min(8, int(args.pop(0)))
        elif a == '--max-plain':
            max_plain = int(args.pop(0))
        else:
            dirs.append(a)
    if mode == 'size':
        import zpaqlc
        cfg, size, c = zpaqlc.compile_source(source(), 'ppadeflate', '$1', '$2', opt=3)
        print('deflate.zl + test main: %d bytes of PCOMP (opt=3), %d R registers, %d H words of variables and arrays'
              % (size, min(c.alloc.r, 256), c.hwords))
        return 0
    if mode == 'params':
        cs = [c + (work, ref, vm) for c in param_cases(param_inputs(work, dirs), vm)]
        fn = job_param
    else:
        cs = cases(dirs, max_plain)
        # the largest first: the pool's tail is then short
        cs.sort(key=lambda c: -os.path.getsize(c[3]))
        fn = job_py if mode == 'py' else job_vm
    tot, per = {}, {}
    t0 = time.time()
    with Pool(jobs) as pool:
        for r in pool.imap_unordered(fn, cs):
            setname, name, si, n, ok, msg, dt = r
            per.setdefault(setname, [0, 0])
            per[setname][0 if ok else 1] += 1
            print('%s %s %s z%d plain=%d %.1fs %s' % ('PASS' if ok else 'FAIL', setname, name, si, n, dt, msg),
                  flush=True)
    for s, (ok, bad) in sorted(per.items()):
        print('SET %s: %d pass, %d fail' % (s, ok, bad))
    print('TOTAL %d pass, %d fail, %.0fs' % (sum(v[0] for v in per.values()), sum(v[1] for v in per.values()),
                                             time.time() - t0))
    return 0 if all(v[1] == 0 for v in per.values()) else 1


if __name__ == '__main__':
    sys.exit(main())
