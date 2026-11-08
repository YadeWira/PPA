#!/usr/bin/env python3
"""pas/plugin/zpaql/model.zl checked against dump_streams' dumps.

    test_model_zl.py py  DUMPDIR [NAME ...]   the .zl run in CPython
    test_model_zl.py vm  DUMPDIR [NAME ...]   compiled (zpaqlc, opt=3), run in zpaqlvm
    test_model_zl.py size                     compile only: the PCOMP's size

DUMPDIR holds what pas/tests/dump_streams writes (NAME.stream, NAME.sub0,
NAME.json, NAME.img<s>.filt, NAME.z<s>.plain, NAME.s<s>.b<j>.meta). For each
file: substream 0 decoded must be NAME.sub0, and each image stream of the
static model must come back as its filtered lines (NAME.img<s>.filt)
followed by its pixels' tail (all of it: NAME.z<s>.plain). Image streams of
other modes are skipped (the program's LENIENT); a file whose sub0 or a
static image differs is a failure.

`py` runs the source itself with zpaqlc's semantics (every value 32 bits
unsigned, wrapping; x // 0 = x % 0 = 0; shifts by n & 31; the signed
helpers), H a list of words and M a bytearray: the source's arithmetic, not
the machine's, so it finds the decoder's mistakes fast. `vm` runs the
compiled program in zpaqlc's interpreter, H and M sized as a query would
(the smallest powers of two that hold them)."""
import ast, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
SRC = os.path.join(HERE, '..', '..', 'pas', 'plugin', 'zpaql', 'model.zl')
M32 = 0xFFFFFFFF


class ZlError(Exception):
    pass


class ZlHalt(Exception):
    pass


# ---------------------------------------------------------------- the source in CPython

class Py(ast.NodeTransformer):
    """zpaqlc's language -> Python with its 32-bit semantics"""

    def __init__(self, arrays, consts):
        self.arrays = arrays
        self.consts = consts

    def mask(self, e):
        return ast.BinOp(left=e, op=ast.BitAnd(), right=ast.Constant(M32))

    def visit_BinOp(self, n):
        self.generic_visit(n)
        op = n.op
        if isinstance(op, (ast.Add, ast.Sub, ast.Mult)):
            return self.mask(n)
        if isinstance(op, ast.LShift):
            n.right = ast.BinOp(left=n.right, op=ast.BitAnd(), right=ast.Constant(31))
            return self.mask(n)
        if isinstance(op, ast.RShift):
            n.right = ast.BinOp(left=n.right, op=ast.BitAnd(), right=ast.Constant(31))
            return n
        if isinstance(op, ast.FloorDiv):
            return ast.Call(func=ast.Name('_div', ast.Load()), args=[n.left, n.right], keywords=[])
        if isinstance(op, ast.Mod):
            return ast.Call(func=ast.Name('_mod', ast.Load()), args=[n.left, n.right], keywords=[])
        return n

    def visit_UnaryOp(self, n):
        self.generic_visit(n)
        if isinstance(n.op, ast.USub):
            return self.mask(n)
        if isinstance(n.op, ast.Invert):
            return ast.BinOp(left=n.operand, op=ast.BitXor(), right=ast.Constant(M32))
        return n

    def visit_AugAssign(self, n):
        t = n.target
        load = ast.parse(ast.unparse(t), mode='eval').body
        new = ast.Assign(targets=[t], value=ast.BinOp(left=load, op=n.op, right=n.value), lineno=n.lineno)
        return self.visit(new)

    def visit_Assign(self, n):
        self.generic_visit(n)
        t = n.targets[0]
        if isinstance(t, ast.Subscript) and isinstance(t.value, ast.Name) and t.value.id == 'M':
            n.value = ast.BinOp(left=n.value, op=ast.BitAnd(), right=ast.Constant(255))
        return n

    def visit_Subscript(self, n):
        self.generic_visit(n)
        if isinstance(n.value, ast.Name) and n.value.id in self.arrays:
            b = self.arrays[n.value.id]
            idx = n.slice
            n.value = ast.Name('H', ast.Load())
            n.slice = ast.BinOp(left=ast.Constant(b), op=ast.Add(), right=idx)
        return n

    def visit_Call(self, n):
        self.generic_visit(n)
        if isinstance(n.func, ast.Name) and n.func.id == 'base':
            return ast.Constant(self.arrays[n.args[0].id])
        return n

    def visit_Name(self, n):
        if isinstance(n.ctx, ast.Load) and n.id in self.consts:
            return ast.Constant(self.consts[n.id])
        return n


def load_py(src, hwords, mbytes, segment):
    """the program in CPython: a namespace whose main() runs it on segment"""
    tree = ast.parse(src)
    consts, arrays, tables, glob = {}, {}, {}, {}
    order = []
    pending = []
    heapname = None
    for node in tree.body:
        if isinstance(node, ast.Assign):
            name = node.targets[0].id
            v = node.value
            if isinstance(v, ast.Call) and v.func.id in ('array', 'table', 'heap'):
                if v.func.id == 'heap':
                    heapname = name
                else:
                    order.append((name, v))
            elif name.isupper():
                pending.append((name, v))
            else:
                glob[name] = v
    while pending:
        left = []
        for name, v in pending:
            try:
                consts[name] = eval(compile(ast.Expression(v), '<c>', 'eval'), {}, dict(consts)) & M32
            except NameError:
                left.append((name, v))
        if len(left) == len(pending):
            raise SyntaxError('constants: ' + ', '.join(n for n, _ in left))
        pending = left
    pos = 0
    for name, v in order:
        arrays[name] = pos
        if v.func.id == 'array':
            pos += eval(compile(ast.Expression(v.args[0]), '<c>', 'eval'), {}, dict(consts))
        else:
            vals = [eval(compile(ast.Expression(e), '<c>', 'eval'), {}, dict(consts)) & M32 for e in v.args[0].elts]
            tables[name] = vals
            pos += len(vals)
    if heapname:
        arrays[heapname] = pos
    H = [0] * hwords
    for name, vals in tables.items():
        H[arrays[name]:arrays[name] + len(vals)] = vals
    M = bytearray(mbytes)
    M[:len(segment)] = segment
    funcs = [n for n in tree.body if isinstance(n, ast.FunctionDef)]
    mod = ast.Module(body=funcs, type_ignores=[])
    mod = Py(arrays, consts).visit(mod)
    ast.fix_missing_locations(mod)
    out = bytearray()

    def error():
        raise ZlError('error()')

    def reset(n):
        raise ZlHalt()

    S = 0x80000000
    ns = {
        'H': H, 'M': M, 'out': lambda v: out.append(v & 255), 'error': error, 'reset': reset,
        'inlen': lambda: len(segment),
        '_div': lambda a, b: a // b if b else 0, '_mod': lambda a, b: a % b if b else 0,
        'slt': lambda a, b: (a ^ S) < (b ^ S), 'sle': lambda a, b: (a ^ S) <= (b ^ S),
        'sgt': lambda a, b: (a ^ S) > (b ^ S), 'sge': lambda a, b: (a ^ S) >= (b ^ S),
        'sar': lambda a, n: ((a - (1 << 32) if a & S else a) >> (n & 31)) & M32,
    }
    for name, v in glob.items():
        ns[name] = eval(compile(ast.Expression(v), '<c>', 'eval'), {}, dict(consts)) & M32
    exec(compile(mod, 'model.zl', 'exec'), ns)

    # H and M sized by the harness: no wrap to find
    def probeh():
        ns['hsize'] = hwords

    def probem():
        ns['msize'] = mbytes
    ns['probeh'] = probeh
    ns['probem'] = probem
    return ns, out


def run_py(src, segment, hwords, mbytes):
    ns, out = load_py(src, hwords, mbytes, segment)
    try:
        ns['main']()
    except ZlHalt:
        pass
    return bytes(out), ns


# ---------------------------------------------------------------- dumps

def expected(ddir, name):
    """the segment (u32 original size, the stream) and what the test main
    must write: sub0, then each static image's plain bytes"""
    j = json.load(open(os.path.join(ddir, name + '.json')))
    stream = open(os.path.join(ddir, name + '.stream'), 'rb').read()
    seg = j['size'].to_bytes(4, 'little') + stream
    parts = [('sub0', open(os.path.join(ddir, name + '.sub0'), 'rb').read())]
    for s in j['streams']:
        if s.get('mode_name') == 'static' or s.get('mode') == 4:
            k = s['index']
            filt = open(os.path.join(ddir, '%s.img%d.filt' % (name, k)), 'rb').read()
            plain = open(os.path.join(ddir, '%s.z%d.plain' % (name, k)), 'rb').read()
            if plain[:len(filt)] != filt:
                raise RuntimeError('%s: .plain does not start with .filt' % name)
            parts.append(('img%d' % k, plain, len(filt)))
    return j, seg, parts


def need(j, seg, parts):
    """H words and M bytes the run needs (generous): the program's arrays
    and heap; the segment, sub0, the largest image and its band scratch"""
    widest = 1
    for s in j['streams']:
        im = s.get('image')
        if im:
            widest = max(widest, im['width'] * max(1, im['bpp']))
    hw = 1335600 + 64 + 8 * len(j['chunks']) + 24 * len(j['streams']) + 2 * j['n_subs'] + 5 * (widest + 16)
    big = 0
    for p in parts[1:]:
        big = max(big, len(p[1]))
    mb = len(seg) + len(parts[0][1]) + big + 320 * 256 * 9 + 640 + 1 + big // 2
    return hw, mb


def pow2(n):
    k = 0
    while (1 << k) < n:
        k += 1
    return k


def compare(name, out, parts):
    """which parts came back"""
    res = []
    pos = 0
    for p in parts:
        exp = p[1]
        got = out[pos:pos + len(exp)]
        ok = got == exp
        detail = ''
        if not ok:
            if len(got) < len(exp):
                detail = 'short: %d of %d' % (len(got), len(exp))
            else:
                d = next(i for i in range(len(exp)) if got[i] != exp[i])
                detail = 'first difference at %d of %d' % (d, len(exp))
        res.append((p[0], ok, len(exp), detail))
        pos += len(exp)
    if pos != len(out):
        res.append(('length', False, len(out), 'wrote %d, expected %d' % (len(out), pos)))
    return res


def lenient(src):
    return src.replace('\nLENIENT = 0', '\nLENIENT = 1', 1)


def main():
    import time
    args = sys.argv[1:]
    mode = args[0]
    src = lenient(open(SRC).read())
    if mode == 'size':
        import zpaqlc
        cfg, size, c = zpaqlc.compile_source(open(SRC).read(), 'ppa', '$3', '$4', opt=3)
        print('PCOMP %d bytes, %d H words of arrays and variables' % (size, c.hwords))
        return
    ddir = args[1]
    names = args[2:]
    if not names:
        names = sorted(f[:-5] for f in os.listdir(ddir) if f.endswith('.json'))
    cfg = None
    if mode == 'vm':
        import zpaqlc, zpaqlvm
        cfg, size, c = zpaqlc.compile_source(src, 'ppa', '$3', '$4', opt=3)
        print('# PCOMP (LENIENT=1 test build) %d bytes' % size)
    nfail = 0
    for name in names:
        try:
            j, seg, parts = expected(ddir, name)
        except FileNotFoundError as e:
            print('%s SKIP %s' % (name, e))
            continue
        hw, mb = need(j, seg, parts)
        t = time.time()
        err = ''
        if mode == 'py':
            try:
                out, ns = run_py(src, seg, hw, mb)
            except ZlError as e:
                out, err = b'', 'error() %s' % e
        else:
            ph, pm = pow2(hw), pow2(mb)
            try:
                out, steps, _ = zpaqlvm.run_config(cfg, seg, [pow2(len(seg)), pow2(j['size']), ph, pm])
            except RuntimeError as e:
                out, err = b'', str(e)
        res = compare(name, out, parts)
        ok = all(r[1] for r in res) and not err
        nfail += not ok
        nimg = len(parts) - 1
        extra = ''
        if mode == 'vm':
            extra = ' H 2^%d M 2^%d' % (pow2(hw), pow2(mb))
        print('%s %s sub0 %s, %d static image(s) %s %.1fs%s%s' % (
            'OK  ' if ok else 'FAIL', name, 'ok' if res[0][1] else 'BAD',
            nimg, '/'.join('ok' if r[1] else 'BAD' for r in res[1:nimg + 1]) or '-',
            time.time() - t, extra, (' ' + err) if err else ''))
        if not ok:
            for r in res:
                if not r[1]:
                    print('     %s: %s' % (r[0], r[3]))
        sys.stdout.flush()
    print('# %d files, %d failed' % (len(names), nfail))
    sys.exit(1 if nfail else 0)


if __name__ == '__main__':
    main()
