#!/usr/bin/env python3
"""Writes pas/ppaselftest.inc: the samples `ppa selftest` carries inside the
binary, and the .ppa each one has to give (doc/CLI.md, selftest). From PJA's
tools/gen_selftest.py.

Small files of tests/png (each colour type the models take, a palette, 16
bits, Adam7, an APNG, an MNG, two JNG), some of them with a model forced
(PPA_TEST_MODEL: ppacodec.TestModel) so that the three models, each too
slow or too costly to be chosen on a file this small, run too. The .ppa of
each is the given ppa command's, with one thread, and with the stream kept
where it is no smaller than the sample (PPA_TEST_KEEP_STREAM: the stream is
what is compared, not a stored copy); the include holds its size and
BLAKE3-128 (its bytes would only double the binary's samples).

The .ppa of a sample changes when a stream or the format changes (they
are not frozen before 0.9.0): then this is run again, and CI's --check
says when it was forgotten.

    tools/gen_selftest.py <ppa binary>            write the include
    tools/gen_selftest.py --check <ppa binary>    exit 1 if it is not current
"""
import os, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'pas', 'ppaselftest.inc')
# (sample, the model forced: '' for the one ppa picks)
SAMPLES = [('rgb8.png', ''), ('rgb8.png', 'static'), ('rgba8.png', 'fast'), ('gray8.png', 'static'),
           ('palette.png', ''), ('rgb16.png', ''), ('interlaced.png', 'fast'), ('apng3.png', ''),
           ('anim.mng', ''), ('color.jng', ''), ('alpha.jng', '')]
MODEL = {'': -1, 'slow': 1, 'fast': 3, 'static': 4}


def pas_bytes(name, b):
    out = [f'  {name}: array[0..{len(b) - 1}] of Byte = (']
    for i in range(0, len(b), 20):
        out.append('    ' + ', '.join(f'${x:02X}' for x in b[i:i + 20]) + (',' if i + 20 < len(b) else ''))
    out.append('  );')
    return out


def blake3_128(ppa, path):
    """the file's BLAKE3-128, as `ppa report` gives it (its first
    blake3_128 line is the file's own; Python has no BLAKE3)"""
    out = subprocess.run([ppa, 'report', path], check=True, capture_output=True, text=True).stdout
    for line in out.splitlines():
        if line.startswith('blake3_128: '):
            return line.split()[1]
    sys.exit('ppa report gave no blake3_128 line')


def generate(ppa):
    lines = ['{ Written by tools/gen_selftest.py: do not edit. The samples of `ppa selftest`',
             '  (tests/README.md says how each was made), the model forced on each, and',
             '  the size and BLAKE3-128 of the .ppa each has to give. }', 'const']
    names, exts, models, sizes, hashes = [], [], [], [], []
    with tempfile.TemporaryDirectory() as tmp:
        for k, (rel, model) in enumerate(SAMPLES):
            src = os.path.join(ROOT, 'tests', 'png', rel)
            data = open(src, 'rb').read()
            out = os.path.join(tmp, f's{k}.ppa')
            env = dict(os.environ)
            env.pop('PPA_TEST_MODEL', None)
            # the stream, even where it is no smaller than the sample
            env['PPA_TEST_KEEP_STREAM'] = '1'
            if model:
                env['PPA_TEST_MODEL'] = model
            subprocess.run([ppa, 'a', '-q', '-f', '-th', '1', src, '-o', out], check=True, env=env)
            lines += pas_bytes(f'SELFTEST_IN_{k}', data)
            names.append(rel + (f' ({model} model)' if model else ''))
            exts.append(os.path.splitext(rel)[1][1:])
            models.append(MODEL[model])
            sizes.append(os.path.getsize(out))
            hashes.append(blake3_128(ppa, out))
    n = len(SAMPLES)
    lines.append(f'  SELFTEST_COUNT = {n};')
    lines.append(f'  SELFTEST_NAMES: array[0..SELFTEST_COUNT - 1] of string = (' + ', '.join(f"'{x}'" for x in names) + ');')
    lines.append(f'  SELFTEST_EXTS: array[0..SELFTEST_COUNT - 1] of string = (' + ', '.join(f"'{x}'" for x in exts) + ');')
    lines.append('  { ppacodec.TestModel for each: -1 the model ppa picks }')
    lines.append(f'  SELFTEST_MODELS: array[0..SELFTEST_COUNT - 1] of Integer = (' + ', '.join(map(str, models)) + ');')
    lines.append(f'  SELFTEST_PPA_SIZES: array[0..SELFTEST_COUNT - 1] of Integer = (' + ', '.join(map(str, sizes)) + ');')
    lines.append(f'  SELFTEST_PPA_HASHES: array[0..SELFTEST_COUNT - 1] of string = (')
    lines.append('    ' + ',\n    '.join(f"'{h}'" for h in hashes) + ');')
    lines.append('')
    lines.append('procedure SelftestSample(k: Integer; out data: TBytes);')
    lines.append('begin')
    lines.append('  data := nil;')
    lines.append('  case k of')
    for k in range(n):
        lines.append(f'    {k}: begin SetLength(data, Length(SELFTEST_IN_{k})); Move(SELFTEST_IN_{k}[0], data[0], Length(data)); end;')
    lines.append('  end;')
    lines.append('end;')
    return '\n'.join(lines) + '\n'


def main():
    args = sys.argv[1:]
    check = args[:1] == ['--check']
    if check:
        args = args[1:]
    if len(args) != 1:
        sys.exit(__doc__)
    text = generate(os.path.abspath(args[0]))
    if check:
        cur = open(OUT).read() if os.path.exists(OUT) else ''
        if cur != text:
            print('pas/ppaselftest.inc is not current: run tools/gen_selftest.py <ppa>')
            sys.exit(1)
        print('pas/ppaselftest.inc is current')
        return
    open(OUT, 'w').write(text)
    print('wrote', OUT)


if __name__ == '__main__':
    main()
