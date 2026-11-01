#!/usr/bin/env python3
"""Compressors, one file at a time: PPA against packPNG 2.0b and precomp
0.4.7, the byte-exact recompressors of PNG. Each set's whole output against
its input; every file is extracted and compared, and a file a tool refuses,
or that does not come back byte for byte, counts at its own size (as PJA's
vs3.py). Times are wall clock with THREADS at once: ppa -th THREADS over all
the files; the others THREADS processes, one file each.

    python3 tools/bench/vs.py THREADS SET... (corpus photos generated)

PPA (the ppa command) from $PPA, packPNG from $PACKPNG, precomp from
$PRECOMP; the sets in /mnt/IA_LAB/agentes/ppa/sets, the work in $WORK."""
import os, sys, glob, subprocess, time, shutil, filecmp
from concurrent.futures import ThreadPoolExecutor

PPA = os.environ['PPA']
PACKPNG = os.environ.get('PACKPNG', '/home/forum/git/packPNG/source/packPNG-linux-x86_64-static-v2.0b')
PRECOMP = os.environ.get('PRECOMP', '/mnt/IA_LAB/agentes/ppa/tools/precomp-0.4.7/build/precomp')
SETS = '/mnt/IA_LAB/agentes/ppa/sets'
W = os.environ.get('WORK', '/mnt/IA_LAB/agentes/ppa/bench/run')
TH = int(sys.argv[1])
names = sys.argv[2:] or ['corpus', 'photos', 'generated']


def quiet(cmd, cwd=None):
    return subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=cwd).returncode


def each(fn, items):
    t = time.time()
    with ThreadPoolExecutor(TH) as ex:
        list(ex.map(fn, items))
    return time.time() - t


def tally(files, packed, back):
    """total size: the packed file when it came back byte for byte, else the original"""
    size = taken = 0
    for f in files:
        p, x = packed(f), back(f)
        if p and os.path.exists(p) and x and os.path.exists(x) and filecmp.cmp(f, x, shallow=False):
            size += os.path.getsize(p); taken += 1
        else:
            size += os.path.getsize(f)
    return size, taken


for name in names:
    files = sorted(f for f in glob.glob(f'{SETS}/{name}/*') if os.path.isfile(f))
    orig = sum(os.path.getsize(f) for f in files)
    d = os.path.join(W, name)
    shutil.rmtree(d, ignore_errors=True)
    for sub in ('ppa', 'ppax', 'ppg', 'ppgx', 'pcf', 'pcfx'):
        os.makedirs(os.path.join(d, sub))
    stem = lambda f: os.path.splitext(os.path.basename(f))[0]
    rows = []

    # PPA: one call, -th THREADS
    t0 = time.time()
    quiet([PPA, 'a', '-q', '-th', str(TH), '--output-dir=' + d + '/ppa'] + files)
    tc = time.time() - t0
    t0 = time.time()
    quiet([PPA, 'x', '-q', '-th', str(TH), '--output-dir=' + d + '/ppax'] + sorted(glob.glob(d + '/ppa/*.ppa')))
    td = time.time() - t0
    size, taken = tally(files, lambda f: d + '/ppa/' + stem(f) + '.ppa', lambda f: d + '/ppax/' + os.path.basename(f))
    rows.append(('PPA', size, taken, tc, td))

    # packPNG 2.0b: its default (preflate + WebP-lossless), verifying
    tc = each(lambda f: quiet([PACKPNG, 'a', '-np', '-o', '-ver', '-th1', '-od' + d + '/ppg', f]), files)
    td = each(lambda f: quiet([PACKPNG, 'x', '-np', '-o', '-th1', '-od' + d + '/ppgx', d + '/ppg/' + stem(f) + '.ppg'])
              if os.path.exists(d + '/ppg/' + stem(f) + '.ppg') else 1, files)
    size, taken = tally(files, lambda f: d + '/ppg/' + stem(f) + '.ppg', lambda f: d + '/ppgx/' + os.path.basename(f))
    rows.append(('packPNG 2.0b', size, taken, tc, td))

    # precomp 0.4.7: its default (preflate + LZMA)
    tc = each(lambda f: quiet([PRECOMP, '-o' + d + '/pcf/' + os.path.basename(f) + '.pcf', f]), files)
    td = each(lambda f: quiet([PRECOMP, '-r', '-o' + d + '/pcfx/' + os.path.basename(f), d + '/pcf/' + os.path.basename(f) + '.pcf'])
              if os.path.exists(d + '/pcf/' + os.path.basename(f) + '.pcf') else 1, files)
    size, taken = tally(files, lambda f: d + '/pcf/' + os.path.basename(f) + '.pcf', lambda f: d + '/pcfx/' + os.path.basename(f))
    rows.append(('precomp 0.4.7', size, taken, tc, td))

    print(f'## {name}: {len(files)} files, {orig} bytes, {TH} at once')
    for tool, size, taken, tc, td in rows:
        print(f'  {tool:14} {size:>11} {100 * size / orig:6.2f}%  takes {taken}/{len(files)}  compress {tc:7.1f} s  decompress {td:7.1f} s')
    sys.stdout.flush()
