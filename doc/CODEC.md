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
| 2 | `ppapreflate` | one deflate stream's API, independent of PNG (for PDA too): stream ↔ its bytes + a recipe (the framing, and how the deflate data is made: kind 0, zlib's parameters), checked bit for bit; the codec keeps each image stream's recipe | kind 0 (zlib's parameters exact), written as stream version 2 writes it |
| 3 | `ppapixels` | filtered scanlines ↔ pixels + each line's filter, interlaced or not | done |
| 4 | `ppaarith` | binary arithmetic coder, adaptive bit counters, stretch and squash | done |
| 5 | `ppastatic`, `ppafast`, `ppamodel` | modelling the pixels (three models, chosen by image; the slow one for all with `--max`), the deflate corrections and the raw bytes | static and fast models; slow one, second version |
| 6 | `ppacodec` | the compressed stream, verified at compress time | done |
| 7 | `ppaformat`, `ppacli` | the `.ppa` file (`FORMAT.md`) and the `ppa` command (`CLI.md`) | done |

A JNG's JPEG (JDAT, and JDAA for its alpha) goes to PJA's codec: its Pascal
units and C, vendored unmodified from PJA's release tarball (`vendor/pja`,
as zpaq-std, PMPA and POA vendor it): PJA 0.6.1 until 0.1.1, PJA 0.9.8
since (12/11/2026; it reads every stream 0.6.1 wrote). The JPEG is
kept as its bytes when PJA does not take it or does not make it smaller.

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

## Layer 4: the arithmetic coder

`ppaarith` is PJA's coder (`pjaarith`): carryless, the interval in 32 bits
(the lpaq form), probabilities in 16 bits; the decoder reads zeros past the
end and cannot fail. With it, the adaptive counters (fast at first, then at
about 1/limit) and stretch/squash for logistic mixing. Everything is
integer: the tables too are made with integers (squash from repeated
multiplication by e^(-1/256) in fixed point), so they are the same
everywhere, and a ZPAQL decoder, which has only 32-bit integers, can make
the same ones.

`test_arith`: a million bits back at any probabilities, extreme and wrong
ones included, at what the probabilities say (90,231 bytes for an ideal of
90,226); squash increasing, stretch its inverse.

## Layer 5: the model (prototype)

The first model, to measure against. It codes an image's unfiltered bytes
(layer 3) bit by bit, most significant first; each bit mixes six contexts
of the byte's neighbours in its channel (W, N, the gradient W + N - NW, the
average with NE, W N NE quantized, and the gradient corrected by what the
previous channel of the same pixel left over its own), each a hashed table
of counters, with mixer weights chosen by channel and bit position. A
line's filter is coded with the previous line's as context. `CodeImage` is
the same code for encoding and decoding.

The mixer's arithmetic stays in 32 bits (weights bounded, each term shifted
before summing). Measured on 31/10/2026, the build without range checks
gives the same bytes as the checked one.

### Its ZPAQL, decided for now

zpaq-std's blocks carry a ZPAQL decoder. PJA's does everything in its
PCOMP (zero zpaq components: its own coder, model and JPEG rebuilding,
written in `zpaqlc`, its Python-subset-to-ZPAQL compiler). The other way
would be zpaq's own components (CM, ICM, ISSE, MIX, SSE, with HCOMP giving
the contexts) and a PCOMP that only rebuilds the PNG: faster in ZPAQL, but
the native coder would have to imitate libzpaq bit for bit and the model
could only be what those components express. PPA follows PJA's way for
now: the model free, in 32-bit integers, written so that `zpaqlc` can take
it. Rebuilding the deflate stream with zlib's choices (layer 2b) has to be
in the PCOMP either way, and is what will weigh most there. To be measured
with a prototype of each when the ZPAQL is written.

## Layer 6: the stream

`ppacodec.Compress` takes a whole file. The stream is one version byte
(`STREAM_VERSION`: 2 since 0.1.1, the static model's 320 contexts; 1, PPA 0.1.0's, still read; a file is written with the oldest version that holds it, never newer than `Compress`'s `maxVersion`, which ppa1 sets to 2), the count and lengths of its substreams (varints),
and the substreams, each its own arithmetic stream. Substream 0 holds:

- the file's structure, written as bytes (numbers as varints) and coded with
  a byte model (orders 0 to 3, mixed): the kind of file; each chunk's type,
  length and CRC when wrong, and either the image stream it belongs to (and
  an fdAT's sequence number) or its data; the bytes after the end; and for
  each image stream how it is kept (as bytes, as an image with the static,
  the fast or the slow model, as PJA's stream);
- then the image streams kept as **bytes**, in order (the byte model, one
  that goes on learning from stream to stream).

And each image stream kept as an **image** follows, band by band, a
substream each: for the images of 8-bit samples that are not a palette,
`EncodeImageStatic` (its own bytes, below), `CodeImageFast` or
`CodeImageBand`, as the choice below says; `CodeImageBand` for the others,
and for every image with `--max`. A non-interlaced image goes in horizontal
bands of at least 2 MB unfiltered (`BAND_BYTES`), at most 16; an
interlaced one in one. Each band has its own model and reads nothing
before its own first line (its first line has none above, its match model
looks no further back): bands are coded and decoded in parallel, on the
codec's threads. The count depends only on the image, so the file is the
same on every machine and with any number of threads. Measured on
01/11/2026, a band costs size: the 7.2 MB photo in 2, 4, 8, 16 bands
+0.3%, +0.7%, +1.2%, +2.1%; a 1.9 MB RGBA frame in 2 and 4 bands +1.6% and
+3.3%. 2 MB bands put the photo in 3 (about +0.5%).

For the tests, `PPA_TEST_BAND_BYTES` makes the bands smaller (the suite's
samples get several each; a stream made so decodes only with the same
value) and `PPA_TEST_BANDS_REVERSE=1` decodes them last first, on one
thread: a band that read another's bytes would fail (PJA's
`PJA_BANDS_REVERSE`).

An image stream is kept as an image when its deflate stream decodes, its
image fits its header, zlib's parameters are found and give its very bits
back (checked, not assumed). It keeps then: the four parameters, the zlib
header, whether the Adler-32 is right, the pad bits, what follows the
deflate data, and what follows the image in it. A JNG's JPEG (JDAT, JDAA) is
kept as **PJA's stream** (`pjacodec.Compress`, which verifies it, with
version 7's model) when PJA takes it and makes it smaller, in a substream
of its own after the bands; `Decompress` gives it back with
`pjacodec.Decompress`, the JPEG's length (from its chunks) as the cap, and
it must have exactly that length. Anything else is kept as its bytes: the
13 streams of the corpus no zlib parameters give, a JPEG PJA does not take.
PJA keeps its models in threadvars, which FreePascal does not free when a
thread ends: `ppathreads` runs `pjamodel.ReleaseThreadModels` at the end of
each of its threads.

`Compress` decompresses its own stream and compares; a file that does not
come back is not taken (and that would be a PPA bug). `Decompress` never
raises: a damaged or hostile stream gives False and a reason. Every count
and length in the structure is checked against what it can be; the chunks
of each image stream must add up to the stream's length before the file
is put together; and each image is capped before it is decoded: an image
stream of L bytes holds at most 1,100 L.

A model's millions of counters start at 1/2 without a loop: their
probability is kept as p xor $8000, so the zeros a new array comes with
are 1/2 (31/10/2026: the same bytes, the codec test 1.7 times faster).

Tests: `test_codec` (every file compressed, verified, decompressed and
compared).

## Layer 7: the file and the command

`ppaformat` is PJA's `.pja` for PNG: header, original size, BLAKE3-128 of
the original, its extension with a check of its own, and the payload (the
codec stream, or the original itself when the codec does not take it or
does not make it smaller). The writer and the reader apply the same limits
with the same function. `FORMAT.md` has the layout and the limits; `CLI.md`
the command.

Tests: `test_blake3` (PJA's vectors), `test_format` (every sample round
trip; every bit of the header and descriptor flipped, a sample of the
payload, cuts: refused or the very original, never another file; each
header case) and `pas/tests/cli.sh` (the command: every sample back, `-f`,
`-n`, `list`, a damaged file refused with nothing written, usage errors).

## Layer 5, second version (01/11/2026)

Tuned on a set of 11 images of the corpus (`/mnt/IA_LAB/agentes/ppa/tune`:
a 640x480 crop of the photo, RGBA frames, a synthetic diagram, a 16-bit
RGBA image, palettes, 1-bit, a CgBI), coding only (`measure_model -e`),
one change at a time, each kept only if the set got smaller. packPNG 2.0
(WebP-lossless) on the same set as the yardstick: the first model already
beat it on most images, and lost on the photo (4% bigger) and on the
synthetic diagram (51% bigger).

| change | set | photo | diagram |
|---|---|---|---|
| the first model | 1,218,054 | 388,482 | 28,537 |
| an APM after the mixer (channel, bits so far, 33 points) | 1,214,341 | | |
| a match model (the last time the 6 bytes before were seen) | 1,194,529 | 384,130 | 26,073 |
| whole pixels as contexts (W's, N's, with this pixel's bytes so far) | 1,186,510 | 381,819 | 22,212 |
| a second weight set, by the area's activity, averaged | 1,176,533 | 378,947 | 22,199 |
| 16-bit samples predicted as 16-bit values | 1,174,662 | | |
| **colour: W and N corrected by the previous channel's change** | **1,083,073** | **301,184** | **16,470** |
| blue also from red's residual | 1,077,067 | 295,738 | 16,366 |
| the two contexts the ablation showed redundant, out (8 contexts) | 1,078,750 | 296,265 | 16,499 |

packPNG on the same: photo 372,715, diagram 18,844. Tried and not kept: the
average corrected by colour (no gain), the APM keyed by the best prediction
(-0.07%, a 2 MB table more).

The ablation (each context's input zeroed, the set coded again) is what
showed where the size is: before the colour contexts, the gradient
corrected by the previous channel's residual was worth 155 KB and every
other context 2 to 12 KB. A pixel's channels predict each other far
better than its neighbours predict it; the contexts that use that, W + the
previous channel's change from its W and N + its change from its N, are now
the two that matter most (33 KB and 15 KB).

The model now: 8 contexts (W; N; N + dN; the average with NE; W + dW; the
gradient corrected by the residuals of the channels before; the linear
extrapolations 2N - NN and 2W - WW, or for 16-bit samples the 16-bit
predictions; the whole pixel above with this pixel's bytes so far), a match
model, a bias; two weight sets (channel and bit; activity and bit)
averaged; an APM; the counters by nibble in tables of 2^22. The C loop and
the Pascal reference give the same streams.

## Layer 5, the fast model (01/11/2026)

`ppafast`, for the images of 8-bit samples that are not a palette (gray,
gray and alpha, RGB, RGBA): the photographs and most of what is drawn. The
slow model (`ppamodel`, above) codes each byte bit by bit, eight decisions
each from eight contexts and two mixers: about 1 µs a byte. This one
predicts each sample and codes the residual with few decisions, about ten
times as quick, within a few percent of its size.

- **The prediction**: eight predictors, blended by how wrong each was
  around the sample (W twice, N twice, NW, NE, WW, NN), each weighed by
  1/(e+2)^2 (a table, 16 bits). A sample's own channel for gray and alpha
  (W, N, NE, W + N - NW, MED, (W + NE) / 2, 2W - WW, 2N - NN); a colour
  channel predicts its difference to the channel before with the same
  eight, which is where photographs decoded from JPEG (Y, Cb, Cr) give
  most. No bias correction (CALIC's made the residual worse here).
- **The residual**, folded to -128..127: zero or not (two counters mixed,
  then an APM), a second guess where values repeat (a match running, or a
  flat area: the value this exact neighbourhood had last, or W, N, NE, when
  farther than 4 from the prediction; four counters mixed), the sign (one
  counter), the magnitude's class in unary (the first two from two
  counters mixed) and its bits (one counter each). The contexts: the signs
  of the residuals around and of the channels before, an energy (the
  residuals around, the channels before, how far apart the predictors
  are), the exact value of the channel before with the prediction's
  difference to it (hashed), and the match model's state.
- **A match model** (the last 6 bytes hashed): what drawings repeat.
- The loop in C (`ppafastc.c`, SSE2 for the blend where the compiler has it,
  the same results without), its Pascal reference line for line, the suite
  demands the same streams from both, and CI on six platforms. A 32-bit
  x86 build takes the plain C path: the same streams.

Measured on 01/11/2026, against the slow model on the same images: the 5
photos used to tune it, 102.4% of its size; 7 generated ones (drawings,
icons, RGBA, gray), 106%; the 20 photos of the benchmark, through the
whole codec, 100.4% (some photos smaller than with the slow model). But
drawings can lose far more: in the corpus, 117 of its 152 images of 8-bit
samples are over 15% larger, Atari bitmaps 60-85%, rendered RGBA
animation frames 20-36%, tiny frames (22x22) twice as large.

**The choice** (`SlowMuchSmaller`, compressing only: the stream keeps it):
both models code a sample of the image, the lines in its middle (256 KB
of them) or all of it when smaller, and the slow model takes the image
when it is at least 10% smaller there. Photographs stay with the fast one;
the corpus goes from 57.37% (every image fast) to 55.02% (the slow model
everywhere: 51.03%). The sample costs about 0.3 s a photo when
compressing. `--max` takes the slow model for every image.

**Decompressing the 20 photos, one thread** (116 MB of pixels): 116 s to
27.5 s. The model was 90% of it; then zlib's choices rebuilt, the filters,
the deflate bits, the Adler-32:

- **zlib's choices** (layer 2b): deflate's loop in C and its hash chains
  skipped (above); the tables of positions sized by the input (two
  entries a byte, 2^12 to 2^19). 0.78 s to 0.47 s on the 1920x1080 photo.
- **The filters, the CRC-32, the Adler-32, the deflate bit writer**: their
  bounds checked once, not at each byte (the filters a loop per filter
  type, the CRC four bytes at a time, the bit writer 32 bits at a time).

## Layer 5, the static model (01/11/2026)

The fast model still left PPA three times as slow as packPNG to
decompress the 20 photos (26.4 s against 8.6 s): packPNG's own model
(WebP lossless) costs next to nothing. `ppastatic` codes what the fast
model codes at the cost of a table lookup a sample:

- **The prediction**: LOCO-I's MED, and for a colour channel the channel
  before plus MED of the differences to it. Blending eight predictors, as
  the fast model does, gave only 1.3% more here: the counters' adaptation
  is what used it.
- **The residual**, folded and zigzagged to a symbol 0..255, in one of 320
  contexts (64 until 07/11/2026, below): an energy bin (the residuals
  around, the channel before's, the gradient) by channel, by the channel
  before's residual in five levels. Each context's frequencies (12 bits) are counted
  over the band and sent before it; the symbols are coded by **rANS** (one
  32-bit state, a byte at a time). Huffman codes were tried first: twice
  the entropy on smooth photos, where the zero residual is more likely than
  one half and Huffman cannot spend less than a bit.
- **A band's substream**: the length of an arithmetic stream (the byte
  model) holding the frequencies and the lines' filters, that stream, then
  the rANS bytes. The decoder checks every table (each used context sums
  to 4096) and never reads outside the substream.
- The line loop in C (`ppastaticc.c`), its Pascal reference line for line,
  the same streams from both.

Measured on 01/11/2026, the 5 photos used to tune it: 110.4% of the slow
model's size (the fast one: 102.4%); 7 generated images: drawings twice
as large, photos 116-121%; the corpus's 152 images of 8-bit samples
78.35% of their zlib streams (the slow model: 48.8%). Decoding a 1920x1080
photo: about 0.12 s (the fast model: 0.85 s).

**The choice** (`ChooseModel`, compressing only): the three models code a
sample of the image (the lines in its middle, 256 KB, or all of it); the
static model takes it unless it is more than 25% (15% since 07/11/2026) larger than the fast
one, or the image is smaller than 256 KB (its tables would weigh, and its
time does not matter); otherwise the slow model if it is 10% smaller than
the fast one, else the fast one. Photographs take the static model,
drawings the others. The corpus: 56.78% (the fast model and the slow one
alone: 55.02%; the slow one everywhere: 51.03%).

| the 20 photos, one thread | packPNG 2.0b | fast model | static model |
|---|---|---|---|
| `ppa x` | 8.7 s | 26.4 s | 14.7 s |
| `ppa a` | 82.0 s | 67.0 s | 41.9 s |
| size | 73.92% | 58.84% | 62.29% |

What is left of `ppa x` is mostly zlib's choices rebuilt: about 0.45 s of
the photo's 0.74 s.

## Ratio and speed, second pass (07/11/2026)

Measured first (`ppa a/x --stats`, callgrind, and a bench of zlib's
choices alone): on the 20 photos, `x` was 4.8 s of pixels decoded and 8.8 s
of deflate streams rebuilt; `a`, the zlib parameter search and the
verification, which rebuilt every stream again. zlib 1.3.1 itself takes
9.1 s to write those 20 streams (level 7, filtered, memLevel 9); PPA's
choices took 7.6 s, the skip links half of it.

- **The static model's contexts**: the residual of the channel before, in
  five levels (below -2, -2 or -1, 0, 1 or 2, above 2), joins the energy
  bin: 320 contexts. Their symbol tables a sixteenth as large (the slot of
  every 16th, then up while the next range starts at or before it), so
  that they stay in the cache. A prototype on the 20 photos tried more: a
  texture bit (-0.4%), CALIC's bias correction (-0.25%), finer energy bins
  (nothing), the fast model's eight predictors blended (-1.8% more, three
  times the time); adaptive frequencies with the same contexts are larger
  than the static ones.
- **zlib's choices**: the same 3 bytes on zlib's own chain (no table of
  their own: it cost more to keep than it saved), the walk resumed from the
  link not known instead of from the start, and links of the same 16 bytes
  for levels 8 and 9, whose chains are long (an animation's frames spent
  most of their time on the 8 bytes' chain with matches of 16 to 31).
  Every stream of the three sets back bit for bit.
- **The search for zlib's parameters**: the memLevel the first block's
  length names (2^(memLevel + 6) - 1 symbols) tried first.
- **The verification**: each image's deflate stream is not written again;
  what the decoder refilters is compared with the inflated bytes, whose
  stream the parameters were checked to give when planned.
- **BLAKE3**: PJA's C (four chunks at a time in SSE2) for `ppablake3` too.
- **The deflate streams rebuilt on several threads** (levels 4 to 9,
  default or filtered strategy), the same tokens and blocks: each segment
  is parsed on its own from its start, the window before it inserted first
  (deflate_slow inserts every position); after a match the parse is as it
  starts, so where a segment and the next both end a match at the same
  position, the tokens are taken from one up to there and from the other
  after; the blocks then in order, as deflate_slow ends them. A segment
  that does not meet the next (none was seen) falls back to one thread.
  `PPA_TEST_PAR_BYTES` cuts the samples into segments for the tests.

Measured one after the other, the release 0.1.0 and this (the machine
somewhat busier than for the tables above):

| the 20 photos | 0.1.0 | after |
|---|---|---|
| size | 62.29% | **61.20%** |
| `ppa a`, one thread | 41.2 s | **29.4 s** |
| `ppa x`, one thread | 14.2 s | **13.7 s** |
| `ppa a` / `ppa x`, -th 8 | 6.7 s / 2.4 s | 5.6 s / 2.5 s |
| one photo's `ppa x` (1920x1080), -th 1 / -th 8 | 0.86 s | 0.86 s / **0.32 s** |
| the corpus, size | 56.79% | **56.38%** |
| the generated set, size | 61.91% | **61.53%** |

**How much larger the static model may be** than the fast one on the
sample, and still be taken (`STATIC_LOSS`, a choice of speed against size;
Wira's, 07/11/2026: 15%). One thread, the same build:

| `STATIC_LOSS` | photos | `x` | corpus | `x` | generated | `x` |
|---|---|---|---|---|---|---|
| 25% | 61.20% | 13.6 s | 56.38% | 63.4 s | 61.53% | 37.7 s |
| **15%** | **60.51%** | **15.4 s** | **56.30%** | 64.7 s | **58.86%** | 39.5 s |
| 10% | 59.67% | 18.3 s | 55.44% | 68.5 s | 58.86% | 39.7 s |

The slow model's own margin (`SLOW_GAIN`, 10%): 5% gives the corpus
55.49% for 19% more time to extract, 2% 53.93% for 61% more.

## Speed, third pass (13/11/2026)

The goal (aim todo 18): extracting the 20 photos on one thread as fast as
packPNG, without one byte of a `.ppa` changing. Measured first
(`perf record` on `ppa x -th 1`, the 20 photos, 16.2 s): the fast model's
loop 34% (9 of the photos take it), zlib's choices rebuilt 49%
(`longest_match` 30%, the insertion of each position 10%, the loop 9%),
the static model 7%, the rest (the byte model, the filters, the checksums,
the deflate bits) 13%. A bench of zlib's choices alone on the 20 streams
(all level 7, filtered, memLevel 9): 7.6 s.

Every change below gives the same `.ppa` bytes, and every stream reads
back the same: after each step, the four sets' 179 files (`tests/png`,
the photos, the corpus, the generated set) compressed into the
baseline's bytes and the baseline's `.ppa` extracted back to the
originals; at the end, all four ways (one thread and eight, the C path
and `PPA_NOC=1`): 716 `.ppa` the same bytes, 4 x 179 files back.

- **A filtered stream's search starts at 5 bytes.** deflate_slow with the
  filtered strategy drops every match of 5 bytes or fewer, so only one of 6
  or more can count: the C search starts as if it had one of 5. Where the
  longest is 6 or more it is the same match (a candidate improves on the
  best only with more bytes, wherever the best started); where it is not,
  the caller drops what it gets, as it dropped zlib's. And the first skip
  level then needs 6 bytes the same, not 4: its links (t4, d4) are of the
  same 6 bytes for that strategy. zlib's choices: 7.6 s -> 5.9 s.
- **A window position's chain state in 8 bytes.** zlib's prev, the two
  skip links and the order in the hash chain as 16-bit distances and
  counts in one record (the window is at most 32 KB; the differences of
  orders are exact modulo 2^16, two positions the walk compares being less
  than the window apart): 896 KB to 256 KB, one cache line a step instead of
  two. 5.9 s -> 5.4 s.
- **The skip tables in sets of two.** A link was not known wherever the
  table's slot held another key, and each one not known made the search
  walk zlib's whole chain to the key. Two positions a set, at most one of
  each key: not known only where both are in the window with other keys.
  5.4 s -> 4.9 s.
- **The loop in a copy for each of its constants** (deflate_fast or slow,
  the first key's length, the 16 bytes' links kept or not), so that the
  insertion and the search inline into it without their tests and
  switches. 4.9 s -> 4.3 s.
- **The fast model's later counters fetched early**: once a sample's
  contexts are known, the slots its second guess, its first two class
  decisions (both signs) and the last-value table may read are prefetched
  while the zero decision is coded. 1.5-3% of a fast photo.
- **The byte model in C** (`ppam_bytes`, its Pascal reference kept;
  `test_arith` codes four kinds of data both ways in pieces of many
  sizes): the structure, the streams kept as bytes and the static model's
  tables. About 3% of a static photo.
- **The slow model's tables kept from band to band.** Each band asked for
  128 MB, which the system zeroed again page by page as it was touched; a
  pool now keeps the blocks while the codec (each call) or the command
  (its whole run) holds it, and a band zeros the one it takes. The corpus:
  6.7 s -> 1.2 s of system time.

Tried and left out (each measured, none faster, or slower):

- the 16 bytes' links for every level from 4 (not only 8 and 9): fewer
  steps along the 8 bytes' chain, but keeping them costs more (+12-30%);
  also kept only for the positions with 8 bytes seen before (a link it
  finds is still the newest, one it does not is not known): +13%;
- the 8 bytes' links only for the positions with 6 seen before: the same;
- no 8 bytes' links at all for a filtered stream: the same on photos;
- the walk where a link is not known along the level below instead of
  zlib's chain: the same (two-way sets left few of them);
- the chain state in three arrays of 4 bytes, one per chain walked (128
  KB each): the same;
- smaller skip tables (2^17, 2^18 slots): 20% and 5% slower; the tables'
  prefetch 8 or 16 positions ahead instead of 4, and head's and cnt's
  slots prefetched: the same;
- the match model's slot prefetched for the prediction's value: slower.

What is left. zlib's choices on the 20 photos: 4.3 s in the bench, about
half of it the search, most of whose steps (counted: 179 million of 230
million) are along the 8 bytes' links (a search that finds 7 bytes or more
then steps, a cache miss each, through every position with the same 8
bytes on zlib's chain), the rest the insertion of every position. The fast
model is now the largest part: about 740 instructions and 4 cache misses
a sample, a serial chain of decisions, already tuned (first pass); a
quicker one would mean another model, and other bytes.

Measured on 13/11/2026, the build before this pass and after it one after
the other, the best of three (two for the corpus and the generated set);
packPNG 2.0l on `.ppg` made from the same photos:

| | before | after | packPNG 2.0l |
|---|---|---|---|
| the 20 photos, `ppa x`, one thread | 15.5 s | **11.5 s** | 7.5 s |
| the 20 photos, `ppa x -th 8` | 2.7 s | **2.1 s** | 1.3 s |
| the 20 photos, `ppa a`, one thread | 34.2 s | **29.4 s** | |
| the 20 photos, `ppa a -th 8` | 6.3 s | **5.2 s** | |
| the corpus, `ppa x`, one thread / 8 | 66.8 s / 17.9 s | **55.7 s / 15.9 s** | |
| the generated set, `ppa x`, one thread / 8 | 40.4 s / 6.5 s | **38.3 s / 6.2 s** | |
| the `.ppa` files | | the same bytes | |

So one thread extracts the photos 1.5 times as slowly as packPNG, no
longer 2.1 times: not yet as fast. The corpus and the generated set are
mostly the slow model, untouched here.

## Speed, first pass (31/10/2026)

Measured first, phase by phase (`measure_phases`), on the corpus's
1920x1280 photo (4.8 MB of zlib stream, 7.4 MB unfiltered). Before: the
model took 8.7 s to code it and 9.0 s to decode it, zlib's predictor 2.2 s
a run, and compressing ran it three times (the search, the check, the
verification).

- **The predictor without range checks** in the release build (`PPA_FAST`,
  as the model): it only indexes its own arrays with its own values. 2.2 s
  to 1.1 s a run. And the search's own choices (it compared every block)
  are the check: one run less.
- **The model's counters in buckets of 16**, the 15 nodes of a nibble's
  binary tree in one 64-byte cache line: two table lookups a byte and a
  context instead of eight. Tables of 2^22 counters (with 2^20 the buckets
  cost 2.4% of size; with 2^22 the model is 2.9% smaller than before). A
  check in each bucket's spare counter, emptying a bucket another context
  has, was tried and was worse (+7%).
- **The pixel loop in C** (`pas/ppamodelc.c`, as PJA's `pjav7c.c`): Pascal
  owns every table and buffer, C codes one line with the coder inline;
  `PPA_NOC=1` runs the Pascal reference, and the suite demands the same
  streams from both (and CI on all six platforms). 6.4 s to 4.2 s.

With tables small enough for the cache the C loop takes 3.1 s: about
2 MB/s is this model's own cost (lpaq's order), not memory's. Further speed
has to come from less work a bit, as PJA's version 7, and from threads.

**zlib's own cost.** On an 800x600 RGBA frame (1.9 MB unfiltered), the
predictor takes 24 ms at level 1 and 2.2 s at level 9; zlib itself takes
21 ms and 1.5 s (Python's zlib, the same parameters). Rebuilding a stream
zlib wrote at level 9 costs about what writing it cost zlib: the hash
chains walked, up to 4,096 candidates a position in flat areas. `longest_match`
went to C too (`pas/ppazlibc.c`, the same choices as the Pascal, 8 bytes
compared at a time): 3.1 s to 2.1 s. What is left is walking the chains.

**Bands** (01/11/2026, layer 6): the photo, one stream in 3 bands: `ppa a`
21.7 s with one thread, 12.1 s with 8; `ppa x` 11.3 s, 5.7 s. What is left
in series is the one stream's inflate, zlib parameter search and rebuild.

**Threads.** The command gives its threads to files first and what is left
to each file's image streams (`ppathreads.ParallelFor`): their zlib
parameters when compressing, their deflate streams rebuilt when
extracting (the pixels are decoded first, in order: one arithmetic
stream). The bytes do not depend on the threads. On the corpus's 16-frame
APNG (4.6 MB, level 9): `ppa a` 148 s with one thread, 39.5 s with 8;
`ppa x` 71 s, 20 s.

| the photo | before | after |
|---|---|---|
| `ppa a` (verifying) | 25.4 s | 13.0 s |
| `ppa a --no-verify` | | 6.3 s |
| `ppa x` | 10.6 s | 5.8 s |
| size | 72.13% | 70.05% |

**The model's loop, again** (01/11/2026). Measured with valgrind
(callgrind for the instructions, cachegrind for the branches) and the
clock: ~860 instructions a bit, 2.6 mispredicted branches a bit, a third of
them one line. Three changes, all giving the same streams bit for bit:

- **The counters without a branch**: `n += n < limit`, and the update's
  product in 32 bits unsigned (|target - p| < 2^16, recip[n] < 2^16: the
  floor of |product| / 2^16 with the sign put back is the truncation the
  64-bit product had). The model's loop 17% quicker.
- **The tables in one block aligned to 2 MiB**: a bucket is one cache
  line, and the system can back the tables with large pages (before, about
  half of them were). 15% on the photo.
- **The mixer on vectors** (GCC's and clang's vector types: SSE2, NEON, or
  plain code), its rows padded to 12 weights (`NINP`). Each lane does what
  the Pascal does to one input. 17% fewer instructions, a few percent of
  time.

Tried and left out: the arithmetic decoder without a branch, fetching the
second nibble's buckets ahead (1, 2 or 3 bits ahead), unrolling the bit
loop, -O2: none above the noise.

| the 20 photos, `-th 1` | before | after |
|---|---|---|
| `ppa a` | 300.4 s | 240.8 s |
| `ppa x` | 155.1 s | 116.0 s |
| size | 23,569,576 | the same bytes |

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
| 31/10/2026 | layer 2b again, after the fixed-block fix | 211/224 told by their zlib parameters, 0 failures |
| 31/10/2026 | layer 5's prototype, the corpus's 224 images (195 MB unfiltered, 32.8 MB of zlib streams) | 19.3 MB = 59.0% of the zlib streams, every image decoded back; the 1920x1280 photo 72.2%, the 800x600 RGBA frames ~50%; 316 s for coding and decoding, one thread, without range checks |
| 31/10/2026 | layer 5's prototype, `tests/png/` (16 small images, ~3,000 pixels each) | 102.7% of the zlib streams: too small for the model to learn |
| 31/10/2026 | layer 7, damaged `.ppa` files of `tests/png/` (20,062 variants, header to payload) | every one refused, none another file, no exception |
| 31/10/2026 | the command on `tests/png/`, x86-64 and a 32-bit build | the same `.ppa` bytes on both |
| 31/10/2026 | the six CI platforms (`.github/test.sh`) | the same `.ppa` bytes on all six |
| 01/11/2026 | layer 5, second version, the corpus's 224 images | **16.7 MB = 50.89% of the zlib streams** (the first: 59.0%), every one decoded back; 383 s coding and decoding, one thread |
| 01/11/2026 | JNG through PJA 0.6.0 (v7), the corpus's 13 JNG files (85,403 bytes) | 63.48% (as bytes: 88.54%), every one back |
| 01/11/2026 | the fast model (`ppafast`) for 8-bit images, zlib's chains skipped, the filters and checksums unchecked inside; the 20 photos, one thread | every one back byte for byte; `ppa x` 116.0 s -> 27.5 s, `ppa a` 240.8 s -> 61.9 s; 23,669,672 bytes (the slow model: 23,569,576) |
| 01/11/2026 | the model's loop without its two costly branches, its tables aligned, its mixer on vectors; the 20 photos, one thread | the same `.ppa` bytes; `ppa x` 155.1 s -> 116.0 s, `ppa a` 300.4 s -> 240.8 s |
| 13/11/2026 | speed, third pass: the four sets (179 files), one thread and eight, C and `PPA_NOC=1` | the same 716 `.ppa` bytes as before it, every file back; the 20 photos' `ppa x -th 1` 15.5 s -> 11.5 s (packPNG 2.0l: 7.5 s) |
| 01/11/2026 | the command, 8 threads, bands, the whole corpus (77 files) | every one back byte for byte; the 70 of the family 32.9 MB -> **16.8 MB = 51.11%** (was 58.81%), the 7 others stored; `ppa a` 220 s, `ppa x` 111 s |
| 31/10/2026 | layer 6, the corpus's 70 files of the family (32.9 MB) | **19.4 MB = 58.81%**, every one back; 211 image streams as images, 30 as bytes (13 not zlib's, 17 JNG JPEGs); 2,387 s for compressing, verifying and decompressing, one thread: the zlib parameter search and the model are the slow parts |
