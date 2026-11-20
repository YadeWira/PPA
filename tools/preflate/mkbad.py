# tools/preflate/mkbad.py DIR: deflate streams no inflate takes, each for its
# own reason (tests/recipes/bad/: ppa_deflate_analyze refuses each, PPA_E_DATA
# and where it showed). zlib's verdict is printed beside each.
import zlib, sys, os
out = sys.argv[1]
class BW:
    def __init__(s): s.b = bytearray(); s.acc = 0; s.n = 0
    def bits(s, v, n):            # LSB first
        for i in range(n): s.bit((v >> i) & 1)
    def huff(s, code, n):         # MSB first
        for i in range(n - 1, -1, -1): s.bit((code >> i) & 1)
    def bit(s, x):
        s.acc |= x << s.n; s.n += 1
        if s.n == 8: s.b.append(s.acc); s.acc = 0; s.n = 0
    def done(s):
        if s.n: s.b.append(s.acc)
        return bytes(s.b)
def fixlit(w, v):
    if v < 144: w.huff(0x30 + v, 8)
    elif v < 256: w.huff(0x190 + v - 144, 9)
    elif v < 280: w.huff(v - 256, 7)
    else: w.huff(0xC0 + v - 280, 8)
S = {}
w = BW(); w.bits(1, 1); w.bits(3, 2); S['btype3.raw'] = w.done() + b'\0' * 4
S['stored-nlen.raw'] = bytes([1, 5, 0, 0, 0]) + b'hello'
S['stored-cut.raw'] = bytes([1, 5, 0, 0xFA, 0xFF]) + b'hel'
w = BW(); w.bits(1, 1); w.bits(1, 2); fixlit(w, 97); fixlit(w, 257); w.huff(1, 5); fixlit(w, 256)
S['dist-before-start.raw'] = w.done()          # length 3, distance 2, after one byte
w = BW(); w.bits(1, 1); w.bits(1, 2); fixlit(w, 97); fixlit(w, 286); fixlit(w, 256); S['lit286.raw'] = w.done()
w = BW(); w.bits(1, 1); w.bits(1, 2); fixlit(w, 97); fixlit(w, 287); fixlit(w, 256); S['lit287.raw'] = w.done()
w = BW(); w.bits(1, 1); w.bits(1, 2); fixlit(w, 97); fixlit(w, 97); fixlit(w, 257); w.huff(30, 5); fixlit(w, 256)
S['dist30.raw'] = w.done()
w = BW(); w.bits(1, 1); w.bits(1, 2); fixlit(w, 97); S['no-end.raw'] = w.done()
def dyn(w, clen_lens, body):
    w.bits(1, 1); w.bits(2, 2)
    w.bits(0, 5); w.bits(0, 5)                   # HLIT 257, HDIST 1
    order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
    w.bits(len(clen_lens) - 4, 4)
    for x in clen_lens: w.bits(x, 3)
    body(w)
# code-length code oversubscribed: three codes of length 1
w = BW(); dyn(w, [1, 1, 1, 0], lambda w: None); S['clen-over.raw'] = w.done() + b'\0' * 8
# code-length code empty (all zero)
w = BW(); dyn(w, [0, 0, 0, 0], lambda w: None); S['clen-empty.raw'] = w.done() + b'\0' * 8
# a repeat (16) first: no length before it. clen code: 16 len 1 and 0 len 1 (order: 16,17,18,0)
# (16 and 0 of length 1: 0 is code 0, 16 code 1)
w = BW(); dyn(w, [1, 0, 0, 1], lambda w: (w.huff(1, 1), w.bits(0, 2))); S['repeat-first.raw'] = w.done() + b'\0' * 8
# lengths: 18 (138 zeros) twice -> past 258 codes (257 + 1)
def over(w):
    for _ in range(2): w.huff(1, 1); w.bits(127, 7)
w = BW(); dyn(w, [0, 0, 1, 1], over); S['repeat-past-end.raw'] = w.done() + b'\0' * 8
# the lengths' code: 0 and 18 (code 0 and 1); 1 of 0, then 138 + 118 zeros: 257 codes all 0, no end of block
def noeob(w):
    w.huff(0, 1)
    w.huff(1, 1); w.bits(127, 7)
    w.huff(1, 1); w.bits(107, 7)
    w.huff(0, 1)                               # the distance's: 0
w = BW(); dyn(w, [0, 0, 1, 1], noeob); S['no-eob-code.raw'] = w.done() + b'\0' * 8
S['truncated.zlib'] = zlib.compress(b'hello hello hello hello world' * 4)[:-9]
S['zlib-fcheck.zlib'] = bytes([0x78, 0x9d]) + zlib.compress(b'abc')[2:]
S['zlib-cm.zlib'] = bytes([0x79, 0x5c]) + zlib.compress(b'abc')[2:]
S['empty.raw'] = b''
for k, v in S.items():
    open(os.path.join(out, k), 'wb').write(v)
    try:
        d = zlib.decompressobj(15 if k.endswith('.zlib') else -15); d.decompress(v); d.flush()
        z = 'zlib: ok' + (' (no end)' if not d.eof else '')
    except zlib.error as e: z = 'zlib: ' + str(e)
    print('%-22s %3d B  %s' % (k, len(v), z))
