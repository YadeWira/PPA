#!/usr/bin/env python3
"""ppa1's ZPAQL decoder run with exactly the memory the plugin's query
computes (pas/plugin/ppazpaqlargs.Ppa1Needs), on what test_zpaqlargs wrote:
NAME.seg (the segment zpaq-std hands the decoder), NAME.orig (the file),
NAME.needs ("hWords mBytes ph pm images byteStreams").

    check_zpaqlargs.py <dir> [--max-orig N] [--jobs J] [--vm K]

For each segment (of an original of at most --max-orig bytes, default 256 KB):
  - the decoder's sources (tools/zpaql/gen_ppadec.py's, in CPython with
    zpaqlc's 32-bit semantics: test_model_zl's loader), M exactly mBytes:
    the file back; M one byte less: error();
  - H: the decoder's heap at its peak (hpmax, in the loader's layout, whose
    arrays start at 0 and have no variables' region) is exactly hWords less
    PPA1_ZPAQL_STATIC_WORDS (zpaqlc's arrays, tables and variables, the
    compiled program's heap start): the query neither under- nor
    over-counts it;
  - --vm K: the K smallest also through the compiled program (the .inc's
    config, zpaqlvm), with $3 and $4 as the query gives them: the file
    back; with $4 one less: error() (M is then smaller than mBytes).
Exit code 1 on any failure."""
import ast, os, sys
from concurrent.futures import ProcessPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(REPO, 'tools', 'zpaql'))
import gen_ppadec
import test_model_zl


def heap_base(src):
    """where the loader puts the heap: after the arrays and tables, in order"""
    tree = ast.parse(src)
    consts, pending, pos = {}, [], 0
    order = []
    for node in tree.body:
        if isinstance(node, ast.Assign):
            name, v = node.targets[0].id, node.value
            if isinstance(v, ast.Call) and v.func.id in ('array', 'table'):
                order.append(v)
            elif isinstance(v, ast.Call) and v.func.id == 'heap':
                pass
            elif name.isupper():
                pending.append((name, v))
    while pending:
        left = []
        for name, v in pending:
            try:
                consts[name] = eval(compile(ast.Expression(v), '<c>', 'eval'), {}, dict(consts))
            except NameError:
                left.append((name, v))
        if len(left) == len(pending):
            raise SystemExit('constants: ' + ', '.join(n for n, _ in left))
        pending = left
    for v in order:
        if v.func.id == 'array':
            pos += eval(compile(ast.Expression(v.args[0]), '<c>', 'eval'), {}, dict(consts))
        else:
            pos += len(v.args[0].elts)
    return pos


SRC = gen_ppadec.source()
BASE = heap_base(SRC)
INC = open(gen_ppadec.INC).read()
STATIC = int(INC.split('PPA1_ZPAQL_STATIC_WORDS = ')[1].split(';')[0])


def lg(n):
    k = 0
    while (1 << k) < n:
        k += 1
    return k


def load(d, name):
    seg = open(os.path.join(d, name + '.seg'), 'rb').read()
    orig = open(os.path.join(d, name + '.orig'), 'rb').read()
    hw, mb, ph, pm = map(int, open(os.path.join(d, name + '.needs')).read().split()[:4])
    return seg, orig, hw, mb, ph, pm


def run_py(seg, hwords, mbytes):
    try:
        out, ns = test_model_zl.run_py(SRC, seg, hwords, mbytes)
        return bytes(out), ns, None
    except test_model_zl.ZlError as e:
        return None, None, 'error()'
    except Exception as e:
        return None, None, '%s %s' % (type(e).__name__, e)


def check_py(args):
    d, name = args
    seg, orig, hw, mb, ph, pm = load(d, name)
    bad = []
    if (lg(hw), lg(mb)) != (ph, pm):
        bad.append('$3, $4 are not the logs')
    # M exactly, H generous: the file, and the heap's peak
    out, ns, err = run_py(seg, BASE + (hw - STATIC) + 4096, mb)
    if out != orig:
        bad.append('M exactly: %s' % (err or 'other bytes (%d of %d)' % (len(out), len(orig))))
    elif ns['hpmax'] - BASE != hw - STATIC:
        bad.append('the heap\'s peak is %d words, the query counts %d' % (ns['hpmax'] - BASE, hw - STATIC))
    # one byte of M less, one word of H less: error()
    out, ns, err = run_py(seg, BASE + (hw - STATIC) + 4096, mb - 1)
    if err != 'error()':
        bad.append('M one byte less: %s' % (err or 'gave %d bytes' % len(out)))
    out, ns, err = run_py(seg, BASE + (hw - STATIC) - 1, mb)
    if err != 'error()':
        bad.append('H one word less: %s' % (err or 'gave %d bytes' % len(out)))
    return name, len(orig), bad


def check_vm(args):
    import zpaqlvm
    d, name = args
    seg, orig, hw, mb, ph, pm = load(d, name)
    cfg = gen_ppadec.config_of_inc(INC)
    a = [lg(len(seg)), lg(len(orig)), ph, pm]
    bad = []
    try:
        out, steps, _ = zpaqlvm.run_config(cfg, seg, a)
        if out != orig:
            bad.append('vm with the query\'s $3, $4: other bytes')
    except Exception as e:
        bad.append('vm with the query\'s $3, $4: %s' % e)
    try:
        out, steps, _ = zpaqlvm.run_config(cfg, seg, a[:3] + [pm - 1])
        bad.append('vm with $4 one less: gave %d bytes' % len(out))
    except Exception:
        pass
    return name, len(orig), bad


def main():
    args = sys.argv[1:]
    opts = {'--max-orig': 256 * 1024, '--jobs': 8, '--vm': 0}
    for k in list(opts):
        if k in args:
            i = args.index(k)
            opts[k] = int(args[i + 1])
            del args[i:i + 2]
    d = args[0]
    names = sorted(f[:-6] for f in os.listdir(d) if f.endswith('.needs'))
    names = [n for n in names if os.path.getsize(os.path.join(d, n + '.orig')) <= opts['--max-orig']]
    names.sort(key=lambda n: os.path.getsize(os.path.join(d, n + '.orig')))
    fails = 0
    jobs = [(d, n) for n in names]
    vmjobs = jobs[:opts['--vm']]
    with ProcessPoolExecutor(opts['--jobs']) as ex:
        for name, size, bad in list(ex.map(check_py, jobs)) + list(ex.map(check_vm, vmjobs)):
            for b in bad:
                print('FAIL %s: %s' % (name, b))
            fails += bool(bad)
    print('check_zpaqlargs: %d segments with exactly their query\'s memory (the file back; one byte of M, one word of H '
          'less: error()), %d also in zpaqlvm; %d failed' % (len(jobs), len(vmjobs), fails))
    sys.exit(1 if fails or not jobs else 0)


if __name__ == '__main__':
    main()
