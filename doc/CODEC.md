# The PPA codec

Its own format, written from scratch in FreePascal, for the whole PNG
family: PNG, APNG, MNG and JNG. It is **not** compatible with packPNG's
`.ppg`: packPNG is kept only as a yardstick for compression ratio. No
encryption.

## The one guarantee

File → compressed → file gives **the same file, byte for byte**. The
compressor checks this before handing anything out: it rebuilds in memory and
compares. A file that does not come back identical is not compressed: it is
stored as it is, with its reason.

Since there is no reference format to compare against, that round trip, run
over a large corpus, is the oracle for the whole project.

## Layers, bottom up

| layer | unit | what it does | status |
|---|---|---|---|
| 1 | `ppapng` | file ↔ chunks + one data stream per image (IDAT, fdAT, JDAT, JDAA) + what is needed to cut them into the same chunks | done |
| 2a | `ppadeflate` | zlib stream ↔ the bytes it holds + every choice its encoder made (blocks, codes, tokens, pad bits): the same bits back | done |
| 2b | `ppazlib` | those choices predicted from the bytes the way zlib makes them, only the differences kept (our own preflate) | in progress: zlib's choices exact |
| 3 | `ppapixels` | filtered scanlines ↔ pixels + each line's filter, interlaced or not | done |
| 4 | `ppaarith` | binary arithmetic coder and adaptive bit counters | |
| 5 | `ppamodel` | context modelling of the pixels, the deflate corrections and the raw bytes | |
| 6 | `ppacodec` | the compressed stream, verified at compress time | |
| 7 | `ppaformat`, `ppacli` | the `.ppa` file and the `ppa` command | |

A JNG's JPEG (JDAT, and JDAA for its alpha) goes to PJA's codec, its Pascal
units vendored from a release tag, the JPEG kept as it is when PJA does not
take it or does not make it smaller.

Each layer has its test in `pas/tests/`, and nothing moves up to the next
layer with a red test. `pas/run_tests.sh` runs them all.

## Layer 1: chunks and image streams

`ppapng.Decompose` reads the signature (`\x89PNG`, `\x8AMNG`, `\x8BJNG`) and
then chunks while they are chunks: a length up to 2^31 - 1 that fits in the
file, and a type of four letters. The data of the image chunks is gathered
into one stream per image, the way a decoder reads it: all the IDAT between
an image's header (IHDR or JHDR) and its IEND, even if other chunks come in
between; the fdAT of each APNG frame (after its fcTL), without their
sequence numbers; the JDAT and the JDAA of each JNG image. An MNG holds as
many images as it embeds.

What is recorded to cut each stream into the same chunks: each chunk's
length, each fdAT's sequence number, and the CRC when it is not the right one
(a right CRC is computed again). Everything else is kept verbatim, including
the bytes after the last chunk: after IEND (MEND in an MNG), or from where
the bytes stop being a chunk, so a file cut short keeps what it has and
anything after the signature decomposes.

Tests: `test_png` (every file back byte for byte, the streams holding exactly
what their chunks carry) and `test_png_corrupt` (every bit of the first 512
bytes flipped, and the file cut at every length up to 512 and at 256 more
points: always back byte for byte, never an exception).

## Layer 2a: a zlib stream and its encoder's choices

`ppadeflate.Decode` inflates a zlib stream, or a bare deflate stream as an
iPhone's CgBI PNG has, and records everything RFC 1950 and 1951 leave to the
encoder: each block's end, finality and type; a dynamic block's HLIT, HDIST,
HCLEN, code-length code and the run-length symbols (16, 17, 18) that write
its code lengths; every literal and match, including a match of 258 written
as 284 with its extra bits all set instead of 285; the bits skipped before a
stored block's LEN and after the last block; the zlib header, whether the
Adler-32 is right, and what follows it. `Encode` writes them back, the same
bits. Codes are canonical, so code lengths are enough to give the codes.

Nothing is predicted yet: this layer alone makes nothing smaller. It is the
ground layer 2b stands on: a stream is predicted from its bytes, and what the
prediction misses is told as a difference against these choices.

This is the reference version: Huffman codes are read a bit at a time, as
zlib's `puff.c` does. Measured on 31/10/2026: decode and encode, 4.3 MB of
stream (26 MB of the bytes they hold) per second, one thread.

Tests: `test_deflate` (every stream back bit for bit; with `-dump`,
`tests/zcheck.py` checks the bytes against Python's zlib) and
`test_deflate_corrupt` (every bit of the first bytes of each stream flipped,
and cuts: decoded or not, never different, never an exception; and the cap
on the bytes a stream may hold).

## Layer 2b: predicting the choices

### zlib's own choices (`ppazlib`)

Most PNGs are written by libpng, that is by zlib. `ppazlib` is a port of
zlib 1.3.2's deflate.c and trees.c, cut down to what decides the bits: the
hash chains and `longest_match`, `deflate_fast` (levels 1-3), `deflate_slow`
(4-9), `deflate_rle`, `deflate_huff`, the symbol buffer that ends a block
(`lit_bufsize - 1` symbols), and `_tr_flush_block`'s choice between stored,
fixed and dynamic, with `build_tree`, `gen_bitlen` and the run-length coding
of the code lengths. Given the bytes and (level, strategy, memLevel,
windowBits), it gives the blocks and tokens zlib gives, as a `TZStream` that
layer 2a's `Encode` writes. A stream zlib wrote is then told by those four
numbers.

It takes the whole input at once. zlib gives the same bits when fed in
pieces, as libpng feeds it a row at a time, since it decides only with
`MIN_LOOKAHEAD` bytes ahead or at the end. Positions are absolute: what
zlib's sliding window forgets is always further back than `MAX_DIST`. The
slide does decide whether a block may still be stored (its start must be in
the window), which is followed. Level 0 is not there yet.

`test_zlib` looks for the parameters: levels from the header's FLEVEL, the
window from its CINFO up to 15 (libpng may write a smaller CINFO than it
used), every strategy and memLevel; a candidate is dropped at its first
token that differs. A stream found is then encoded from the predicted
choices and must give the same bits.

### What not predicting costs

`measure_parse` (31/10/2026) estimates what storing the choices costs when
the bytes are known, with a predictor simple enough for a ZPAQL decoder:
per token literal or match, the match's length, and its distance as a rank
among the earlier positions starting with the same 3 bytes (most recent
first) that match at least as long. Order-0 entropy, on the corpus's 224
streams (32.8 MB):

| part | bytes |
|---|---|
| literal or match | 2,924,729 |
| match lengths | 5,417,378 |
| distance ranks (97.7% rank 0) | 187,682 |
| dynamic headers, as written | 175,158 |
| total | 8,705,012 = 26.6% of the streams |

The distance is almost free given the bytes (zlib takes the most recent of
the longest); what costs is where the matches are and how long, which is
exactly what zlib's lazy matching decides. Storing the parse is not the way:
the choices have to be predicted, and only where the prediction fails told.

## Layer 3: each line's filter

`ppapixels.Unfilter` takes the bytes an image stream holds, finds the image
from its header (`StreamImage`: an IDAT's IHDR, a JNG alpha's JHDR, an fdAT
frame's fcTL), and splits them into each line's filter byte and the image's
own bytes, unfiltered. Each Adam7 pass is its own sub-image, and a pass
with no columns or rows has no lines. The bytes stay as the image has them:
the bits that pad the last byte of a 1, 2 or 4-bit line are kept. With the
filters recorded, `Refilter` gives back the same bytes. An image whose
filter byte is above 4, or whose stream holds fewer bytes than it needs, is
not taken; bytes after the image are kept.

Tests: `test_pixels` (every image back; with `-dump`, `tests/pxcheck.py`
checks the unfiltered bytes of the non-interlaced 8-bit gray, RGB and RGBA
images against ImageMagick's decoding).

## Measurements

| date | what | result |
|---|---|---|
| 31/10/2026 | layer 1, `tests/png/` (14 synthetic files) | 14/14 back byte for byte |
| 31/10/2026 | layer 1, damaged variants of `tests/png/` | 64,568 variants, 0 failures, 9.6 s |
| 31/10/2026 | layer 1, the PNG family in the shared sample corpus (77 files: 47 PNG/APNG, 13 MNG, 13 JNG, 7 that are not of the family) | 70/70 back byte for byte, 7 NotPng |
| 31/10/2026 | layer 2a, the zlib streams of that corpus (224: 1,272 dynamic blocks, 3 stored, 1 fixed; 12 bare deflate from CgBI) | 224/224 back bit for bit, the same bytes as zlib; 7.7 s |
| 31/10/2026 | layer 2a, damaged streams of `tests/png/` (every bit of the first 512 bytes, cuts) | 68,264 variants, 51,275 decode, 0 failures |
| 31/10/2026 | layer 2b, `tests/png/`'s 16 streams (ImageMagick, i.e. libpng and zlib) | 16/16 told by their zlib parameters (level 7 filtered or default, level 8), the same bits from the predicted choices |
| 31/10/2026 | `measure_parse` on the corpus's streams | the parse alone, order 0: 26.6% of the streams |
| 31/10/2026 | layer 2b, the corpus's 224 streams | 211 told by their zlib parameters (level 9 filtered the most, 78; level 7 default 62); 13 not zlib's: one dynamic block for the whole image (advpng-like optimizers) and one CgBI |
| 31/10/2026 | layer 3, the corpus's 224 images (23 interlaced) | 224 taken and back; the 22 non-interlaced 8-bit gray/RGB/RGBA PNG ones the same pixels as ImageMagick |
