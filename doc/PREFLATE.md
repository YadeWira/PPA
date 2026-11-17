# Deflate recipes (PPA's own preflate)

A **recipe** is what PPA needs, besides the bytes a deflate stream holds, to
write that stream again bit for bit. `pas/ppapreflate.pas` finds it
(`Analyze`, `FindRecipe`) and uses it (`Rebuild`); `pas/ppazlib.pas` is the
zlib emulation both stand on. Nothing here knows of PNG: PDA (documents)
will use the same unit for the deflate streams of PDFs and ZIPs.

The plan (design and review: `/mnt/IA_LAB/agentes/ppa/preflate-study/`)
grows recipes kind by kind. This file has the kinds that exist, their
fields, how they are written, and the rule that freezes them. The corpus
and the baselines are in `tools/preflate/` (README.md, BASELINE.md).

## Where recipes are written

- **Codec stream version 2** holds **kind 0 only**, in its own layout
  (`RecipeBytesV2`, CODEC.md "Layer 6"). ppa1 (the zpaq-std plugin) writes
  it alone: it asks `FindRecipe` for kind 0 (`maxKind = RECIPE_ZLIB`), and
  an image whose stream needs another kind is kept as its bytes.
- **Codec stream version 3** (M4, PPA 0.3.0) holds any kind in
  **`RecipeBytes`**' format, below. Kind 0 is looked for first, so a file
  whose images are all zlib's alone is still written as version 2, the
  same `.ppa` as before (M4's hash gate). Format 2, published with
  0.3.0 (kinds 0 to 3), is frozen by the versioning rule.
- **Codec stream version 4** (M6, PPA 0.4.0) is version 3 and one more
  value: kind 2's encoder 2, libdeflate. The same format 2; a file is
  written in version 4 only when an image's recipe is libdeflate's, so
  PPA 0.3.0 refuses it as a newer PPA's (its version byte) and reads every
  other file 0.4.0 writes. A version 3 stream holding encoder 2 is damage
  (never written so) and is refused.
- **Codec stream version 5** (M9) is version 4 and kind 2's encoder 3,
  zopfli: written only when an image's recipe is zopfli's (at the default
  level, images of up to 64 KiB of bytes; at `-3`, any), so 0.4.0 refuses
  such a file as a newer PPA's and reads every other. A version 4 stream
  holding encoder 3 is damage.
- **Codec stream version 6** is version 5 and zopfli's variant 1, the Rust
  port (oxipng's `--zopfli`): written only for such an image, so 0.5.0
  refuses it as a newer PPA's. A version 5 stream holding variant 1 is
  damage.
- **libppa's `ppa_deflate_*`** (M8, PPA 0.7.0): one stream at a time,
  for PDA. A recipe there is a byte, the codec stream version that holds
  its encoder (`RecipeVersion`, 3 at least), and `RecipeBytes` with no
  tail: the bytes after the stream are the caller's (`consumed`).

## Kinds

| kind | name | what makes the deflate data | since |
|---|---|---|---|
| 0 | `RECIPE_ZLIB` | zlib's parameters: level, strategy, memLevel, windowBits | 0.1.0 (codec v2) |
| 1 | `RECIPE_ZLIB_FLOW` | kind 0's parameters at the start, and a **flow**: the flushes and parameter changes zlib made along the stream, and which zlib made them | M2 (codec v3, M4) |
| 2 | `RECIPE_ENCODER` | another encoder, exactly: which (`ENC_MINIZ`, miniz's tdefl; `ENC_LIBDEFLATE`, libdeflate) and its parameters (miniz: its flags and build; libdeflate: its variant and level; zopfli: its variant and options) | M5 (codec v3), M6 (libdeflate, codec v4), M9 (zopfli, codec v5) |
| 3 | `RECIPE_CORR` | a zlib-like predictor (`ppacorr`) and the **corrections** that make what it predicts the stream: any stream `ppadeflate` reads | M3a, M3b (codec v3, M4) |
| 4 | | reserved: cost-guided predictor plus corrections | |

Every kind also carries the **framing**, as layer 2a records it: bare
deflate or zlib (its two header bytes as written, never recomputed),
whether the 4 bytes after the data are its Adler-32, the bits after the
last block (`endPad`), and whatever follows (`tail`; a wrong Adler-32 is
there).

### Kind 1: a flow

In memory (`ppazlib.TZlibFlow`):

| field | values | meaning |
|---|---|---|
| `variant` | 0 `ZV_NEW` | zlib 1.2.5.3 to 1.3.x |
| | 1 `ZV_125` | zlib 1.2.3.4 to 1.2.5.2 |
| | 2 `ZV_123` | zlib up to 1.2.3.3 |
| | + 4 `ZV_NO_TOO_FAR` | (M3b) that zlib built with `TOO_FAR` = 32767: `deflate_slow` keeps a match of 3 bytes however far (pngcrush builds its zlib so; so did whatever wrote the corpus's spider images) |
| `events[]` | in order of `pos`, then as made | each: `pos`, `kind`, and for `ZE_PARAMS` the new `level` and `strategy` |

An event at `pos` is what deflate was asked for once it had been given the
bytes before `pos`:

| event | zlib call | what the rebuild does |
|---|---|---|
| `ZE_SYNC` (1) | `deflate(Z_SYNC_FLUSH)` | drain to `pos` (the lookahead ends there), end the block if it holds symbols, an empty stored block |
| `ZE_FULL` (2) | `deflate(Z_FULL_FLUSH)` | the same, then forget the past: no match may reach back over `pos` |
| `ZE_PARTIAL` (3) | `deflate(Z_PARTIAL_FLUSH)` | drain, end the block, an empty fixed block (`_tr_align`) |
| `ZE_BLOCK` (4) | `deflate(Z_BLOCK)` | drain, end the block, no marker |
| `ZE_PARAMS` (5) | `deflateParams(level, strategy)` | the new parameters from the first top of deflate's loop at or after `pos`; when the loop changes (fast, slow, rle, huffman), only right after a flush at `pos` |

"Drain" is zlib's own: deflate takes every byte before `pos` with the
lookahead ending there (so `nice_match`, `max_insert` and the end of a match
are cut at `pos`), and `deflate_slow` emits the literal it was holding.
After a flush the details that differ by version:

| | `ZV_NEW` | `ZV_125` | `ZV_123` |
|---|---|---|---|
| a flush with no symbols pending | no block | an empty block (`FLUSH_BLOCK` always) | the same |
| the two positions before the flush | inserted into the hash when the next input comes (`s->insert`, by `fill_window`) | never | never |
| `Z_PARTIAL_FLUSH` | one empty fixed block | a second one when `1 + last_eob_len + 10 - bi_valid < 9` (the bits written so far and the previous block's end-of-block code length) | the same |
| `Z_FULL_FLUSH` | the hash cleared, positions start again at `pos` (strstart 0) | the same | the hash cleared, positions go on |

In every version `fill_window` starts the hash again from the input after a
flush, and `deflateParams` flushes on its own (with `Z_BLOCK` from 1.2.3.4
on when the loop or the strategy changes, with `Z_PARTIAL_FLUSH` before
1.2.3.4 when the loop changes): in a flow that flush is its own event, at
the same position, before the `ZE_PARAMS`. A `ZE_PARAMS` with no flush
before it (zlib changes the level, or an old zlib the strategy, of the same
loop) takes effect at the first top of the loop at or after `pos`; zlib's
is the first past its input less `MIN_LOOKAHEAD`.

**Finding the variant flag.** zlib's `deflate_slow` drops a match of 3
bytes more than `TOO_FAR` (4096) back. pngcrush 1.8.13 compiles its zlib
1.2.11 with `-DTOO_FAR=32767` (its Makefile), so its `-m 1` and `-m 7`
streams part from zlib's at the first such match: that was M2's open
question. When a candidate of the slow loop parts from the stream at a
match of 3 further than 4096, the search tries it again with the flag
(and mending may toggle it too). Kind 0 cannot say this (codec stream
version 2's layout has no field for it), so those streams are kind 1.

Not emulated: level 0 (`deflate_stored`), the Huffman-only and RLE
strategies of zlib before 1.2.5 (they ran inside `deflate_fast` and
`deflate_slow`), and the stored-block choice of `Z_FIXED` before 1.2.12.
Input given a byte or two at a time right after a flush would insert fewer
positions at first (zlib's `lookahead + insert < MIN_MATCH`): the emulation
takes each stretch's input at once.

### Kind 2: a known encoder (miniz)

`pas/ppaminiz.pas` (the Pascal reference) and `pas/ppaminizc.c` (its parse
in C, the same tokens and blocks): miniz's deflate, `tdefl`, as miniz
1.14 and 3.0.2 make it, ported step for step where a step decides a choice
(NOTICE has miniz's license). It gives miniz's choices as `ppadeflate`'s
blocks and tokens, and `Encode` writes them: the same bits.

| field | values | meaning |
|---|---|---|
| `encoder` | 1 `ENC_MINIZ` | miniz's tdefl, 1.x to 3.x |
| `mz.flags` | the probes (low 12 bits) and `MZ_GREEDY` ($4000), `MZ_RLE` ($10000), `MZ_FILTER` ($20000), `MZ_STATIC` ($40000), `MZ_RAW` ($80000) | tdefl's own flags (`TDEFL_*`), as `tdefl_init` takes them; no other bit |
| `mz.variant` | 0, 1 `MZV_FAST` | the build: level 1's own loop (`tdefl_compress_fast`) or not |

What decides miniz's choices, all of it in the port:

- **The parse** (`tdefl_compress_normal`): a 32 KB ring with 257 bytes
  mirrored after it, hash heads and links of 16-bit positions (a link of
  0 ends a chain, so a match never starts at position 0 or at a multiple
  of 64K), probes counted 3 at a time (`1 + (probes + 2) / 3` of them, a
  quarter of that once the match is 32 bytes long), lazy (one position)
  or greedy, and matches dropped: 3 bytes from 8 KB or further, one whose
  distance equals the ring position (a quirk of the code), up to 5 bytes
  with `MZ_FILTER`. `MZ_RLE` matches only the byte before; `MZ_RAW` none.
- **Level 1's loop** (`tdefl_compress_fast`), in builds with unaligned
  loads (`MINIZ_USE_UNALIGNED_LOADS_AND_STORES`): miniz 1.x has it on x86
  and x86-64, miniz 3.x builds without it by default and runs level 1
  through the normal loop. One probe of a 4096-entry hash of 3 bytes, the
  input taken in 4 KB pieces (no match crosses one's end: its last bytes
  are literals). The two builds differ only there; at every other level
  1.14 and 3.0.2 give the same stream (checked on the corpus).
- **The blocks**: one ends when the LZ code buffer (64 KB: a byte a
  literal, 3 a match, a flag byte every 8) is full, or (not in level 1's
  loop) once it covers 31 KB and its codes take 115/128 of its bytes or
  more, or always then with `MZ_RAW`. A block of fewer than 48 bytes, or
  with `MZ_STATIC`, has the static codes; the others miniz's own
  (`ppacorr.LensMiniz`, `SeqMiniz`). It is stored instead when that is no
  bigger (its coded bytes + 1 >= its bytes) and all its bytes are still
  in the window, or always with `MZ_RAW` then; and written with the
  static codes when the coded block would overflow miniz's output buffer
  (85,180 bytes; the zlib header counts in the first block).
- **One call** with all the bytes and `TDEFL_FINISH`: what
  `tdefl_compress_mem_to_heap`, miniz's PNG writer and `mz_compress` do.
  The last block may be empty (the code buffer filled with the last
  byte). No flushes: a stream with a flush's marker is not tried.

`FindRecipe` tries kind 2 after kind 0 and before kind 1: its search is
quick (each candidate stops at its first token, block end or block type
unlike the stream's), kind 1's long where it fails, and no stream is both.
Miniz first, then libdeflate (below).
The candidates (`FindMinizParams`): every level's probes (1, 6, 32, 16, 32,
128, 256, 512, 768, 1500), greedy as the level makes it and the other way
(the PNG writer makes no level greedy), level 1 in both builds; the same
with `MZ_FILTER` where no match is 5 bytes or shorter, with `MZ_STATIC`
where no block is dynamic; `MZ_RLE` where every match is at distance 1;
Huffman only and `MZ_RAW` where there is none (`MZ_RAW` first where every
block is stored). A stream with a match of 3 bytes from 8 KB or further,
or 258 written as 284, is not miniz's. The first whose choices are the
stream's is the recipe, verified as every kind is.

### Kind 2's libdeflate (M6)

`pas/ppalibdeflate.pas` and `pas/ppaldfc.c`: not a port but libdeflate's
own compressor (`vendor/libdeflate`: libdeflate 1.26's
`lib/deflate_compress.c` and the headers it includes, copied unmodified
from its release tarball; NOTICE has its license), built with no C
runtime (its freestanding build; `memcpy`, `memmove` and `memset` defined
in `ppaldfc.c`, hidden, for the copies the compiler still calls them for)
and its memory from FreePascal's heap. `Rebuild` calls
`libdeflate_deflate_compress` at the recipe's level with all the bytes,
reads its stream back into blocks and tokens (`ppadeflate.Decode`) and
writes them with the recipe's framing (`Encode`): the same bits. It is C
only: libdeflate itself is the reference (`PPA_NOC` and `--path=pascal`
do not change it).

| field | values | meaning |
|---|---|---|
| `encoder` | 2 `ENC_LIBDEFLATE` | libdeflate's compressor |
| `ldf.variant` | 0 `LDFV_119` | libdeflate 1.19 to 1.26: the same bytes at every level (checked: 1.19, 1.23 and 1.26 on the corpus's streams and made ones, every level, x86-64 and x86); 1.18 and before sometimes differ (a few streams of 65), which would be another variant |
| `ldf.level` | 1 to 12 | `libdeflate_alloc_compressor`'s level: 1 its own loop, 2-4 greedy, 5-7 lazy, 8-9 lazy2, 10-12 near-optimal parsing |

oxipng writes its PNGs with libdeflate (libdeflater): its `-o1` is level
10, `-o2` level 11, `-o3` and over level 12 (oxipng 10.1.1, checked);
libdeflate's own default is 6. One call with all the bytes, as oxipng and
libdeflate's zlib and gzip wrappers make it.

**The search** (`FindLdfParams`): only where the first two dynamic blocks
have libdeflate's code lengths for their own symbol counts and its
code-length code (`ppacorr.LibdeflateTrees`, kind 3's tree builder 1:
miniz's lengths are the same, so miniz is tried first), or where there is
no dynamic block and at most 64 KB of bytes. Then the levels 12, 11, 10
(oxipng's), 6, 9, 8, 7, 5, 4, 3, 2, 1, each compressed whole and compared
with the stream's deflate bytes but the last (whose pad bits the framing
keeps); the first that matches is rebuilt and compared bit for bit, as
every kind is. Levels that write the same bytes (8 and 9 often, 10 and 12
on small inputs) count as found.

**Rebuilding** costs libdeflate's time at that level: level 12 about 3.4
MB/s of bytes on one thread (a 787 KB photo in 0.23 s), level 6 about 40
MB/s; kind 3's rebuild of the same streams was about 0.4 MB/s.

### Kind 2's zopfli (M9)

`pas/ppazopfli.pas` and `pas/ppazopc.c`: zopfli's own deflate
(`vendor/zopfli`: zopfli 1.0.3's `src/zopfli`, without its containers and
command, copied unmodified from its release tarball; NOTICE has its
license; its master branch has the same deflate), built with no C runtime
and so that every platform gives the same bits:

- zopfli's costs are doubles. IEEE `+`, `-`, `*` and `/` give the same
  results everywhere with `-ffp-contract=off` and SSE2 doubles (32-bit x86
  builds this object with `-msse2 -mfpmath=sse`, never x87's; a processor
  without SSE2 fails the calls cleanly: such a file does not extract
  there). Its one libm call, `log()` of symbol counts, is
  `ppa_zop_log`: double-double arithmetic, correctly rounded. glibc's log
  is not correctly rounded for 487 of the integers up to 20,000,000 (32-bit
  glibc's x87 log for more): a stream whose zopfli met one of those where
  a tie turns on it would not be given back, and is simply not this
  recipe (none met in the corpus).
- Memory: `malloc`, `realloc`, `calloc` and `free` are the caller's
  (FreePascal's heap), each block on a list kept for the call; where zopfli
  would `exit()` (an allocation failed) the call jumps back
  (`__builtin_setjmp`) and frees the list: a host never exits. Its
  `qsort` (at most 288 leaves of distinct weights) is an insertion sort;
  `memcpy` and its kin are `ppamemc.c`'s; Windows' stack probe
  (`___chkstk_ms`) is PPA's own.

| field | values | meaning |
|---|---|---|
| `encoder` | 3 `ENC_ZOPFLI` | zopfli's deflate (`ZopfliDeflate`, btype 2, final) |
| `zop.variant` | 0 `ZOPV_103`, 1 `ZOPV_RS08` | zopfli 1.0.3 with a correctly rounded log; the Rust port (the zopfli crate 0.8, oxipng's `--zopfli`) with a correctly rounded log2 (codec stream version 6) |
| `zop.iterations` | 1 to 1000 | `numiterations` |
| `zop.flags` | bit 0 block splitting, bit 1 splitting last | `blocksplitting`, `blocksplittinglast` |
| `zop.bsMax` | 0 to 1000 | `blocksplittingmax` (zopfli's default 15) |

zopflipng writes with it: 15 iterations for images under 200,000 bytes,
5 over (60 and 20 with `-m`), splitting first, at most 15 blocks;
advpng `-z4` with 5 iterations; zopfli's command 15.

**Variant 1, the Rust port.** oxipng 10's `--zopfli` links the zopfli
crate 0.8.3 (its `Cargo.lock`), a port of zopfli to Rust: the same block
splitting, trees and LZ77, but an optimal pass that parts from 1.0.3's in
three places, which `ppazopc.c` writes again from zopfli's own (variant 1
of `ZopfliLZ77Optimal` and `ZopfliLZ77OptimalFixed`, chosen by the call's
variant; zopfli's files stay as they are):

- the costs are randomised once the cost stops falling one iteration
  earlier (its counter counts the run just made: `i + 1 > 5`, not
  `i > 5`);
- the shortcut over long repetitions adds the cost in single precision
  (the cost rounded to a float first, where 1.0.3 adds in double and
  rounds the sum);
- the entropy of a symbol is `log2` itself (1.0.3: `log` times a constant
  of 13 digits), and not clamped at zero: a correctly rounded log2 here.

The two give the same stream on most inputs (8 of the 9 oxipng `--zopfli`
images of up to 64 KiB of png-synth are variant 0's too); where they part
(long runs, 7 iterations or more), only variant 1 gives oxipng's. The
search tries each candidate in variant 0, then 1.

**The search** (`FindZopParams`). zopfli splits a master block (1,000,000
bytes) before it iterates, optimises each piece on its own and writes the
pieces' tokens in order (the blocks may be grouped again after, if that
is smaller): so a candidate number of iterations is tried on the first
piece alone, against the stream's first tokens, and only the one that
gives them is run whole and compared. First on the stream's first block
(zopfli's first piece when it kept its split: cheap), with every
candidate (15, 60, 5, 20, 1, 10, 30, 50, 100; 5 and 20 first over
200,000 bytes) when one of the first four dynamic blocks has the code
lengths zopfli itself gives its tokens (`ppa_zop_lengths`: its
`GetDynamicLengths`, ties as it breaks them), else zopflipng's two; then,
with those trees, on the first piece of zopfli's own split
(`ppa_zop_split`). Tried after kind 1 (its cost is zopfli runs), for
streams of at most `zopMax` bytes: the codec's level decides it (`-1`
never, `-2` up to 64 KiB, `-3` any). A stream that is not zopfli's costs
about 0.4 s for 60 KB at the default level; one that is, its search and a
zopfli run (s23's 60 KB: 2 s).

**Rebuilding** costs a zopfli run: about 0.2 MB/s of bytes at
zopflipng's settings (60 KB in 1.0 to 1.4 s; 1.9 MB in 47 s), which is
why the default level keeps it to small images.

### Kind 3: a predictor and its corrections

`pas/ppacorr.pas` (and its hot loops in `pas/ppacorrc.c`). `FindRecipe`
tries it after kinds 0, 2 and 1, so it never replaces them (a zlib stream is
never larger as kind 3 than as kind 0 or 1: it is not kind 3); it takes
every stream `ppadeflate.Decode` reads, and `Analyze` verifies its rebuild
like the others'.

**The predictor** (`TPredParams`, frozen by `PRED_VERSION` = 2). Three
chains over every position: zlib's hash over 3 bytes (`hbits` 8..16 bits,
the predictor's own search), and two of the corrections' own, a 16-bit
multiplicative hash of 3 bytes (`Hash3x`) and one of 4 bytes (`Hash4`),
each defined on the bytes' values, the first lowest, the same on every
machine. With `flags` bit 4 (`PF_LONGEST`) clear, the search is zlib's
`longest_match` on its chain (`chain` 1..4096 candidates, `nice`, `good`:
the chain / 4 when the match to beat is that long; candidates up to
`maxDist` back, position 0 never one). With `PF_LONGEST`, the search is
the **longest match** (below), the guess for an optimal parser. With
`lazy` > 0, deflate_slow's lazy match one position ahead (up to `lazy`)
and its filters (`flags` 1: a match of 5 or fewer dropped, `Z_FILTERED`;
2: a match of 3 further than 4096 dropped, `TOO_FAR`); with `lazy` = 0,
deflate_fast's greedy match. `symEnd` (0: none) is the symbol count that
ends a block. `tree` (0..4) names the code lengths' builder (below). The
predictor runs on the stream's own parse (a *forced parse*): each token
is predicted from the bytes and the position alone, then the real one is
taken and the next is predicted where it ends; a lazy match looked up for
the next position is used there only if the real token was the literal
the predictor expected.

**The longest match** at q (`LongestPas`, `pc_longest`): the nearest
position whose 3 bytes are q's, on the `Hash3x` chain (256 positions at
most); if q has 4 bytes left, longer matches on the `Hash4` chain (below
that one when it matched 4 or more), up to 4096 positions (256 for a
context, below); up to 32768 back, position 0 included; at most 258 and
the bytes left. Its distance is the nearest of that length. **Runs of one
byte are skipped** where they cannot hold a better candidate (each skip
one hop): when q starts with rq bytes of one byte (4 <= rq < 258), a
position of a run of that byte with rc <> rq of them left matches min(rc,
rq) bytes, so the walk goes to that run's position with rq left (rc < rq)
or below the run (rc > rq), noting what the run gave.

**The rank walk** (`RankPas`, `pc_rank`): the candidates at least len
long, newest first, on the `Hash3x` chain, up to 32768 back, position 0
included, 4096 positions at most, with the same skips (3 <= rq < len): the
skipped positions match fewer than len bytes, so a rank is the same with
or without them. Without the skips, an image's runs used up the 4096
positions and most distances of zopfli and oxipng were escaped; with them,
nearly every distance in the corpus has rank 0.

**The corrections**, in the order the driver (`Drive`, one routine for
both directions) codes them, each a binary decision or a small number
against a guess. Every bit is coded with ppaarith's arithmetic coder by
an adaptive model (P(1) in 22 bits, rate 1/(n+1.5) down to 1/128.5,
starting at 1/2); a token's main decisions **mix** several such models,
each by its own context: their stretched probabilities summed with
weights of their own (16.16, starting at 30000/65536, and a bias) and
squashed back, the weights moved by stretch x error >> 14 after each bit.
All integer, the same on every machine.

| field (`TDeflateBlock`, tokens) | guess | coded |
|---|---|---|
| stored or not | | a bit (context: the previous block's type) |
| stored `storedLen` | what is left, at most 65535 | a bit, or 16 bits (at most what is left) |
| stored `pad` | 0 | a bit, or 7 bits (must fit the pad's bits where it is written) |
| where a block ends | `symEnd`; the previous block's count | a bit before each token (contexts: first token, at `symEnd`, at the previous count, else; and the count's bit length); none once the bytes are used up |
| a token | the predictor's | a bit, **mixed** from: the predicted length's bucket and whether the last token missed; the last 4 tokens' hits; the longest match's bucket, the lazy one's (or the longest match one position on, 256 positions, when no lazy one was looked for) and whether a match was predicted; the last token's length; the byte; the longest match's cost against its bytes as literals in the previous block's code lengths |
| a missed token, literal or match | (when a match was predicted) | a bit, mixed from the same kind of contexts |
| a missed match's length | the longest match there (or the predicted length if longer) | a bit "the longest", mixed (case: predicted the longest, shorter, a literal, nothing; the bucket; hits; lazy; the cost); else "the predicted" (when shorter); else shorter or longer (mixed); shorter: the length symbol, steps down from the reference's (unary), then its top length (a bit: optimal parsers take the length with the fewest extra bits) or how far below (adaptive bits); longer or no reference: an exponent (unary) and its low bits, adaptive |
| a match's distance | rank 0 | its rank among the candidates at least that long (the rank walk) as a bucket (unary, by length) and its low bits (adaptive); or the escape and the distance as an exponent and low bits (the decoder checks the match against the bytes) |
| 258 written as symbol 284 (`LEN_258_AS_284`) | not | a bit after every match of 258 |
| fixed or dynamic | zlib's choice (fixed when no bigger) | a bit |
| `litLen`, `distLen` | the builder's lengths over the block's own symbol counts | a bit for all; else each symbol: as guessed, or 4 bits (context: the guess, whether the symbol is used) |
| `hlit`, `hdist` | the least the lengths need | a bit, or 5 bits (at least that, at most 286 / 30) |
| `clenSeq` (16, 17, 18) | zlib's `send_tree` on each tree; on both at once; libdeflate's; miniz's; zopfli's (the smallest of its 8) | which (a bit each, context: the previous block's; a guess the same as an earlier one is skipped), or each step: literal or which run, and its count (the longest it can be, or its extra bits); every choice checked against the lengths |
| `clen[19]` | the builder's code-length code over the symbols used | a bit for all; else each: as guessed, or 3 bits |
| `hclen` | the least `clen` needs (at least 4) | a bit, or 4 bits (at least that) |
| `final` | | a bit, only where the bytes are used up |

**The code lengths' builders** (`tree`), each over the block's symbol
counts (end of block counted once), and its code-length code by the same:

| `tree` | builder | exact on |
|---:|---|---|
| 0 | zlib's `build_tree` (`ppazlib.ZlibTrees`, `ZlibBlTree`) | zlib, zlib-ng, GNU gzip |
| 1 | libdeflate's: symbols by count then value, two-queue Huffman, a too deep node takes the deepest length still free (14 bits for literals and lengths, 15 for distances, 7 for the code-length code), the lengths in sorted order; fewer than 2 used: symbol 0 and the other get 1 | libdeflate, oxipng (libdeflate), miniz (the same lengths) |
| 2 | miniz's: Moffat and Katajainen's in-place lengths (16-bit sums), `tdefl_huffman_enforce_max_code_size`; one used: it gets 1 | miniz 1.x and 3.x |
| 3 | optimal lengths of at most 15 (7) bits by package-merge (of equal weights, a package first), given in sorted order; two distance codes at least (zopfli's patch) | |
| 4 | zopfli's: 3, and the same over the counts evened out for runs (`OptimizeHuffmanForRle`), the one whose tree and symbols take fewer bits (its 8 run-length codings, the smallest) | zopfli, zopflipng, oxipng `-Z` |

7-Zip's trees are none of these (about one length in ten differs from
libdeflate's, the nearest; open).

Caps, checked as values are decoded: a length or a stored block no longer
than the bytes left, a distance back into the bytes and within 32768, at
most 2 x plain + 4096 blocks, rank walks of 4096 positions, the longest
match's walks of 256 and 4096, run lengths of 259 at most, exponents of 9
(lengths) and 15 (distances: 32768 included), header fields as above, the pad bits and
`endPad` within the bits they have, and a dynamic block's code lengths,
whatever corrections give them: codes `ppadeflate` reads (none over-subscribed:
the code-length code, the literal/length and the distance trees), a code for
every symbol the block writes (its literals, lengths, distances, its end, and
the code-length symbols of its header); else the recipe is refused. The rebuild writes each block as it
comes (`ppadeflate.TDeflWriter`), holding one block's tokens.

**The parameters** are chosen by coded size, never from the header
(FLEVEL). First what the stream shows of its encoder, on its first 64K
tokens (`Estimate`): the hops each match's distance is down zlib's chain
(hash of 15 bits), the 99th percentile + 1 as a chain; whether literals
stand where a match of 4 or more was there with a longer one next (a lazy
encoder) and how long those were (lazy must be longer). The tree builder
is the one whose lengths (and code-length codes) differ the least from the
stream's on its first 256 dynamic blocks (`ChooseTree`, zlib's of as
few). Then the candidates: every zlib level's (deflate_fast for 1-3, the
filtered strategy for 4-9); the chain the stream shows, lazy or greedy as
it shows; two of no limits (chain 4096, nice and lazy 258, window 32768,
lazy and greedy); the longest match, greedy and lazy. All are measured on
the first 8192 tokens (or 128 KB of bytes), then the best one's variants
(`TOO_FAR`; for zlib's search, the hash bits 12..16, the window, nice; lazy
16 and 258); the 3 cheapest of all on the first 64K tokens (or 1 MB) when
the stream is longer. `symEnd` is the commonest token count of the blocks
before the last (if two have it).

### RecipeBytes (format 2)

All integers are bytes or varints (7 bits a byte, low first, the high bit
set on all but the last).

```
byte    format              RECIPE_FORMAT = 2
byte    kind                0 to 3
kind 2: everything below it instead:
  byte    encoder           1 (miniz), 2 (libdeflate: codec stream version 4),
                            3 (zopfli: codec stream version 5)
  encoder 1:
    byte    variant         0..1
    varint  flags           the bits of MZ_FLAGS only
  encoder 2:
    byte    variant         0
    varint  level           1..12
  encoder 3:
    byte    variant         0
    varint  iterations      1..1000
    byte    flags           0..3
    varint  bsMax           0..1000
  framing (below)
kind 3: everything below it instead:
  byte    version           PRED_VERSION = 2
  varint  chain             1..4096
  varint  nice              3..258
  varint  lazy              0, 3..258
  varint  good              3..258
  byte    hbits             8..16
  varint  maxDist           1..32768
  byte    flags             0..7
  varint  symEnd            0..2^20
  byte    tree              0..4
  framing (below)
  varint  corrections' length   at most the bytes left
  bytes   corrections
kinds 0 and 1:
byte    level               1..9
byte    strategy            0..4
byte    memLevel            1..9
byte    windowBits          8..15
kind 1:
  byte    variant           0..2, or 4..6 (+ ZV_NO_TOO_FAR)
  varint  events            at most 2 x plain + 2, and (bytes left) / 2;
                            at most 4 at one position
  per event:
    varint  pos - previous pos   (the first from 0); the sum at most plain
    byte    kind            1..5
    ZE_PARAMS: byte  level | strategy << 4
framing (as codec stream version 2's):
  byte    flags             1 bare deflate, 2 Adler-32 right; no other bit
  byte    header[0], header[1]
  byte    endPad
  varint  tail length       at most the caller's cap and the bytes left
  bytes   tail
```

`ReadRecipe(b, pos, plainLen, maxTail)` reads it with the plain length it is
for. Every value is checked as it is read, before anything is allocated for
it: the event count against `2 x plainLen + 2` and against the bytes left,
each position against `plainLen`. The flow as a whole must then pass
`ZlibFlowValid` (positions in order, at most 4 events at one position;
parameters in range; a change of loop only right after a flush). Four is
not all zlib can make at one position: a flush weaker than or the same as
the one before it there does nothing, but `Z_BLOCK` is the weakest, so
`deflateParams`' own `Z_BLOCK`, the change, then a partial, a sync and a
full flush are five. From 1.2.5.3 on the `Z_BLOCK` before another flush
adds no block (nothing is pending) and the flow without it gives the same
stream; before 1.2.5.3 it adds an empty block, and such a stream has no
recipe (none seen in the corpus). Several parameter changes with no byte
between them act as the last one. `Rebuild` checks the same again and refuses what
does not pass; it never raises on a recipe.

### The versioning rule

**Each recipe version freezes its predictor.** A recipe decodes only with
the emulation that made it: zlib's tables, the order things happen at a
flush, the old versions' second block. So:

- The pair (format byte, kind) names one exact decoder. Once a version of
  it is published in a stream PPA writes (from codec stream version 3 on),
  that decoder never changes the bits it gives for any recipe it accepts.
- A change that would give other bits (a better emulation of some zlib, a
  new event, a tuned predictor for kinds 3 and 4) is a new kind, a new
  variant number or a new format byte. The old code path is kept, and
  every stream already written still reads.
- New variants and new event kinds only add values a reader refuses today
  (`ReadRecipe` refuses a variant whose version is above `ZV_LAST` or with
  a flag other than `ZV_NO_TOO_FAR`, and an event kind above 5), so an old
  PPA stops cleanly on a newer recipe.
- **Golden vectors**: `tests/recipes/` holds deflate streams by many
  encoders (`tools/preflate/mkgolden.py`: zlib 1.3.1, 1.2.5 and 1.2.3 with
  flushes, pngcrush, libdeflate, miniz 1.14 and 3, zopfli; framing with a
  wrong Adler-32, bytes after the stream, pad bits), each beside the recipe
  PPA made of it (`NAME.recipe`), and recipes no encoder made (a kind-3
  recipe with one predictor field changed: each tree builder, `symEnd`,
  the filters, the search) beside the stream they give: 45 in all, 5 kind 0,
  9 kind 1 (each zlib variant, `ZV_NO_TOO_FAR`), 31 kind 3 (each tree
  builder); and (M5, `mkgolden.py --kind2`, beside them) 14 kind 2, miniz
  1.14 and 3.0.2 (both builds of level 1, levels 6, 9 and 10, the PNG
  writer's, filtered, RLE, Huffman only, static, raw, and 88 KB of photo,
  noise and text in several blocks, some stored); and (M6, `mkgolden.py
  --libdeflate`) 14 kind 2's libdeflate (libdeflate 1.23, as oxipng has
  it: each parser, levels 1, 2, 4, 5, 6, 8, 9, 10, 11, 12, raw and in a
  zlib frame, one with a wrong Adler-32 and bytes after it, one with pad
  bits set); and (M9, `mkgolden.py --zopfli`) 8 kind 2's zopfli (the
  study's zopfli 1.0.3 with glibc's log: 1, 5, 10, 15 and 20 iterations,
  raw and in a zlib frame, a wrong Adler-32 and bytes after it, pad bits):
  81.
  `test_preflate tests/recipes 81 -golden` requires each recipe,
  read back, to give its stream bit for bit (on 1 thread and in segments on
  4) and to be written the same again; `.github/test.sh` runs it on the six
  platforms, 32 and 64 bits, with the C and the Pascal code. A vector is
  never made again: a new format adds its own beside them.

Format 1 was never published (M3b moved to format 2: kind 3's `tree`
byte; the predictor and its models are `PRED_VERSION` 2, and kind 1's
variant may carry `ZV_NO_TOO_FAR`); a format 1 recipe is refused. Format 2
is the one codec stream version 3 holds.

## Finding a flow (`FindZlibFlow`)

Kind 0 is looked for first, exactly as codec stream version 2 always has,
except where the blocks show a flush (zlib alone never ends a block empty).
Then:

1. **The flushes are read off the blocks.** A non-final empty stored block is
   a sync or full flush (zlib never stores nothing on its own); a non-final
   empty fixed block a partial flush; a block that ends with fewer symbols
   than memLevel's buffer holds, with no marker after it, a `Z_BLOCK` (or
   `deflateParams`' flush). A marker some later match reaches back over is
   a sync; one none reaches over is taken as a full flush when many bytes
   with matches follow it. Two empty fixed blocks in a row, or one before
   an empty stored block, are a zlib before 1.2.5.3; there the bits each
   block ends at (computed from the stream) say which empty block was
   `_tr_align`'s second.
2. **Every parameter set is tried** with the flow its memLevel gives: the
   header's window first (bare: 15), then 15 to 9, only one of those whose
   window holds the whole input (they choose the same); memLevel by the
   blocks' symbol counts first; the levels the header's FLEVEL names first,
   then the others (kind 1 does not trust FLEVEL or CINFO); every strategy.
   Each is run on the stream's first blocks (64K tokens or 1 MB) and, if
   they all come out the same, on the whole.
3. **The three that came furthest are mended** where they part from the
   stream, one change at a time, kept when it takes them at least 256 bytes
   further: a `Z_BLOCK` where a stored block ended; the other of sync and
   full; the other zlib versions; new parameters right after the last flush
   before where they part (each version); new parameters of the same loop
   with no flush, at the top of the loop where they part (deflate_slow's
   chains are the same at any level, so that place is as good as zlib's).
   The mending stops after 3000 runs or 48 times the stream's bytes
   compared.

What `Analyze` returns is always verified: the recipe's rebuild, written,
is the stream (kinds 1 and 3: `Rebuild` of the recipe itself, as a reader
has it; kind 0: zlib's choices with its parameters, what `Rebuild` makes,
as codec stream version 2 has always checked them).

## Status (M2, 13/11/2026)

Measured with `pas/tests/test_preflate` (C, and `PPA_NOC=1` for the
Pascal reference: the same recipes, compared by a digest of their bytes).
See tools/preflate/README.md for the sets.

| set | streams | kind 0 | kind 1 | no recipe | C time | same recipes from Pascal |
|---|---:|---:|---:|---:|---:|---|
| `tests/png` | 16 | 16 | 0 | 0 | | yes |
| crafted flows (each zlib version, 6 flows on 2 samples) | 36 | 0 | 36 | 0 | | yes |
| `png-zlib` (the v2 regression set) | 392 | 392 | 0 | 0 | 89 s | |
| `png-nonzlib` | 24 | 0 | 1 (`ipad.png`) | 23 | 19 s | yes |
| `png-synth` `*.zfl-*` (zlib 1.3.1 with flushes and `deflateParams`) | 288 | 0 | **288** (68,680,796 B) | 0 | 3 min 54 s | yes, on the 216 of its 24 smaller sources (C 1 min 41 s, Pascal 6 min 24 s) |
| `zflow` (zlib 1.3.1, 1.2.5, 1.2.3) | 129 | 0 | 126 | 3 | 48 s | yes |
| `raw` `*.zfl-*` | 6 | 0 | 6 | 0 | 2 s | |
| `pda` | 742 | 335 | 260 | 147 | 51 s | yes |

- **`ipad.png`** (Apple CgBI, bare deflate): zlib level 9, filtered,
  memLevel 8, window 15, one `Z_FULL_FLUSH` at plain 10404, zlib 1.2.5.3 or
  later.
- **`zflow`**: the three without a recipe are zlib 1.2.3's RLE (it ran
  inside `deflate_fast`). `deflateParams` of the same loop (6 to 9) and
  1.2.3's strategy change without a flush are found (the last mending
  step).
- **PDA**: with a recipe, 595 streams, 17,354,078 B of the sample's
  18,955,136 (91.6%); before M2 (kind 0 alone) 335 streams, 12,741,752 B
  (67.2%). The PDA census's zlib with flush replay (census3) rebuilt 568
  of these 742 streams, 17,185,143 B (90.7%): all 568 have a recipe now, and
  27 more (pdfTeX's empty streams, zlib before 1.2.5.3; Acrobat Distiller
  5 and 10, Adobe PDF Library 9.9, Aspose, iText, htmldoc, two MS Word
  2007 parts, ...: headers that name another level or window, older
  zlibs, parameter changes). Of the 260 kind 1: 246 zlib 1.2.5.3 on, 11
  1.2.3.4 to 1.2.5.2, 3 older; events: 164 streams with partial flushes,
  83 with syncs, 19 full flushes, 8 `Z_BLOCK`, 4 with parameter changes.
  The 147 left are the census's non-zlib streams (MS Office 2013 and
  later, cairo/Firefox, Skia, Inkscape, PDFTron, ...): kinds 2 to 4.
- Rebuild speed (the emulation, against the stream), 6.9 MB of plain
  (`s00`): C 0.2 to 0.9 s (8 to 36 MB/s), Pascal 0.6 to 13 s. Kind 1 is
  rebuilt on one thread (kind 0 keeps its parallel rebuild).
- Not found: pngcrush 1.8.13's `-m 1` and `-m 7` streams that kind 0 misses
  (23 of 32 for `-m 1`) are not kind 1 either; they part from zlib 1.3.1
  in their first block (BASELINE.md), with no flush.

## Status (M3a, 13/11/2026): kind 3, every stream

Measured with `pas/tests/test_preflate -all013 -tsv` (C; the Pascal code
gives the same recipes: `-diffc` in process, and `PPA_NOC=1` runs compared
by their digest), against preflate 0.3.4's diff (M0, `tools/preflate/BASELINE.md`).
Recipe bytes are whole `RecipeBytes` (kind 3: about 20 bytes of
parameters, framing and length besides the corrections).

| set | streams | kind 0 / 1 / 3 | no recipe | recipes, % of deflate | preflate | kind-3 streams only: ours / preflate |
|---|---:|---:|---:|---:|---:|---:|
| `png-nonzlib` | 24 | 0 / 1 / 23 | 0 | 13.86% | 11.23% | 13.99% / 11.32% |
| `png-synth` (all 878 PNGs) | 878 | 136 / 290 / 452 | 0 | 4.02% | 9.43% | 7.35% / 10.02% |
| `raw` | 101 | 10 / 7 / 84 | 0 | 2.03% | 3.22% | 2.54% / 4.03% |
| `pda` | 742 | 335 / 260 / 147 | 0 | 0.23% | 0.50% | 2.23% / 3.40% |
| `hostile` (15 inflate, 3 do not) | 18 | 7 / 1 / 7 | 0 (3 not deflate) | 0.06% | 0.10% | |

- Better than preflate: zlib-like encoders (pngcrush `-m1`/`-m7`, the
  M2 misses: 1.2% and 0.5%; zlib-ng 1 and 6; miniz 3 at 1 and 6: 7% against
  28%), libdeflate 1 and 6 (9 about even), advpng, spider (0.28% against 1.93%), PDA's
  non-zlib streams, every `raw` group but GNU gzip 9 (+90 B).
- Worse: optimal and near-optimal parsers, where a lazy zlib-like guess is
  wrong most often: oxipng/libdeflate 10-12 (11-17% against 10-13%),
  zopfli and zopflipng (11.6% against 8.3%), 7-Zip mx9 PNGs (10.3% against
  9.1%), zlib-ng 9 (5.7% against 2.9%), miniz 1.x L9 in the corpus (10.7%
  against 9.7%). The models are deliberately simple here (M3b): no
  context mixing, zlib's tree builder only, the length of a missed match
  not tied to the longest one there.
- Speed, release build (`PPA_FAST`), one thread, kind 3 alone (parameter
  search, corrections, rebuild): rebuild 2.3 MB/s on a 6.9 MB oxipng image
  (the predictor's chain of 4096), 20 MB/s on libdeflate 6, 47 MB/s on
  pngcrush `-m1`, 11-12 MB/s on `raw` text and exe; the Pascal reference
  1-1.8 times slower. The search over parameters costs about a sixth of
  an encoding pass. `Analyze` first tries kinds 0 and 1 (most of its time
  on non-zlib streams).
- Memory: the rebuild holds the bytes, the stream being written and one
  block's tokens; peak RSS of a whole `png-synth` slice run under 110 MB.

## Status (M3b, 14/11/2026): kind 3 made small

Measured as M3a (`test_preflate -all013 -diffc -tsv`, release build;
`-diffc` makes each kind-3 recipe again with the other code, C or Pascal,
and requires the same recipe and rebuild: all the same), against preflate
0.3.4's diff (M0). Recipe bytes are whole `RecipeBytes` (kind 3: about 20
bytes besides the corrections). Every stream with a recipe rebuilds; peak
RSS of a whole `png-synth` slice under 103 MB.

| set | streams | kind 0 / 1 / 3 | recipes, % of deflate | M3a | preflate | kind-3 streams only: ours / preflate |
|---|---:|---:|---:|---:|---:|---:|
| `png-nonzlib` | 24 | 0 / 7 / 17 | 6.89% | 13.86% | 11.23% | 7.96% / 12.68% |
| `png-synth` (all 878) | 878 | 136 / 336 / 406 | 2.17% | 4.02% | 9.43% | 4.66% / 11.17% |
| `raw` | 101 | 10 / 7 / 84 | 1.50% | 2.03% | 3.22% | 1.88% / 4.03% |
| `pda` | 742 | 335 / 260 / 147 | 0.20% | 0.23% | 0.50% | 1.88% / 3.40% |
| `hostile` (15 inflate, 3 do not) | 18 | 7 / 1 / 7 | 0.06% | 0.06% | 0.10% | |

**Every encoder group is at or below preflate's diff**, in every set:
`png-synth` (e.g. oxipng 4.6-5.6% against 8.2-11.9%, zopflipng 5.4% /
8.3%, zopfli-15 9.1% / 12.2%, 7-Zip mx9 4.7% / 9.1%, libdeflate 12 5.6% /
9.8%, zlib-ng 9 0.46% / 2.46%, zlib-ng 1 14.6% / 33.4%, miniz 0.8-1.7%),
`raw` (7-Zip mx9 5.2% / 10.8%, zopfli 2.45% / 3.9%, every libdeflate level,
GNU gzip 9 390 B / 393 B), `png-nonzlib` (oxipng 8.2% / 13.2%, miniz 6.4% /
9.7%, spider 78 B / 2,616 B), `pda` (zlib 0.04% / 0.23%, not zlib 1.73% /
3.17%). In `hostile` the total is below (440 B / 678 B); its 1 to 30 byte
streams cost a recipe's fixed ~20 bytes each. Per group: `compare_recipes.py`
on the TSVs in `/mnt/IA_LAB/agentes/ppa/preflate/m3/m3b/res/`.

- **zlib streams** are never kind 3 (kind 3 is tried only when kinds 0 and 1
  fail), so never larger than kinds 0 and 1.
- **pngcrush `-m1` / `-m7`** (M2's open question): zlib 1.2.11 built with
  `TOO_FAR` = 32767; all 32 and 31 now kind 0 or 1 (23 each kind 1 with
  `ZV_NO_TOO_FAR`), 398 B and 387 B in all. The 6 spider images of
  `png-nonzlib` are the same (kind 1, 13 bytes each).
- **MS Office 2013+** in `pda` (creators version 15, 16, 2013 on, 365): 108
  streams, all rebuild (19 kind 0, 35 kind 1, 54 kind 3), 7,520 B of
  recipes against preflate's 10,262 B.
- What it took, on a dev set of 39 streams (corrections only; preflate
  325,772 B): M3a 405,652 B; the rank walk's skips over runs and context
  mixing 280,419 B (most escapes had been the 4096-position cap in runs);
  the longest match as the length's reference, a shorter length by its
  symbol, the cost and one-on contexts, parameters by coded size with the
  longest-match predictor 189,223 B; the tree builders 180,673 B (code
  lengths' corrections from 9.1 KB to 1.2 KB: exact on libdeflate, oxipng,
  miniz and zopfli streams); then the mixer's rate and the counters' limit
  tuned (-3.7% on a subset).
- Speed, release build, one thread, kind 3 alone (parameter search /
  corrections / rebuild), C and Pascal: oxipng `s00` (6.9 MB of plain) 1.3 /
  3.4 / 3.3 s and 1.9 / 4.2 / 4.2 s (rebuild 2.1 MB/s in C); libdeflate 6
  `s00` 0.77 / 0.84 / 0.79 s (8.7 MB/s) and 1.1 / 1.1 / 1.0 s; zopflipng
  `s00` 1.3 / 2.5 / 2.5 s and 1.9 / 3.2 / 3.2 s; `raw` text by libdeflate 12
  (0.78 MB) 0.25 / 0.11 / 0.10 s. The whole of `png-synth` runs at 1.5 MB/s
  of analysis (kinds 0, 1, 3, both codes) and 9.5 MB/s of rebuild.
- Open: 7-Zip's trees (about one length in ten differs from the nearest
  builder); the parameter search's cost on small images with long runs
  (zlib's longest_match emulation walks its chain through them: 2 s on a
  256 KB miniz image) and no `maxWork` yet; the slow walks are bounded but
  not cheap; golden vectors per format before M4.

## Status (M4, 14/11/2026): codec stream version 3

PPA writes recipes of kinds 1 and 3 (CODEC.md "Layer 6"). The hash gate
(`tools/preflate/baseline.py gate` and `gatecheck`, the ppa command three
ways: C on 8 threads and on 1, Pascal on 8) over the 1,214 files of
`gate-v2.tsv`: every `.ppa` in stream version 2 is the reference's byte for
byte; those in version 3 are the same in the three runs and extract:

| set | files | version 2, identical | version 3 | their `.ppa`, before / now |
|---|---:|---:|---:|---:|
| `tests-png` | 14 | 14 | 0 | |
| `sets-corpus` | 70 | 62 | 8 | 65,224 / 42,575 B |
| `sets-generated` | 75 | 70 | 5 | 807,865 / 597,928 B |
| `sets-photos` | 20 | 20 | 0 | |
| `png-zlib` | 133 | 133 | 0 | |
| `png-nonzlib` | 24 | 5 | 19 | 1,014,065 / 735,268 B |
| `png-synth` | 878 | 189 | 689 | 180,444,794 / 108,349,683 B |

The sets' totals: corpus 18,549,124 -> 18,526,475 B (design's gate:
under 19,380,789), generated 9,216,406 -> 9,006,469 B (-2.3%). The files
left in version 2 of `png-nonzlib` and `png-synth` are those whose images
went as bytes (noise, small palettes: bands and recipe not smaller than
the deflate stream). PPA 0.2.1 refuses a version 3 `.ppa` cleanly ("made
by a newer PPA"). Fuzzing (`pas/tests/fuzz`) with 28 version-3 seeds, 30
minutes each of `lib_ppa_chk` (libFuzzer, 167,490 runs) and `afl_ppa_chk`
(AFL++, 49,159): nothing.

- No step budget (`maxWork`): the work at each position is bounded by the
  predictor's caps (search, rank and longest-match walks), whatever the
  recipe; and C and Pascal search differently (the C's own links), so a
  count of steps would not be the same in both. Measured on adversarial
  bytes (noise of 2 and 4 values, near-periodic data, runs of every
  length), 2 MB each by libdeflate 6 and 12: the slowest rebuild, 2-value
  noise by libdeflate 12, 0.37 MB/s (5.7 s), its analysis 23 s.
- Analysis speed (15/11/2026). Measured with callgrind (perf is not
  allowed on the machine): on a doodle, kind 3's parameter search was 65%
  of `ppa a`, a third of it the predictor's longest-match walk
  (`pc_longest`); on the oxipng photo, whose predictor is the longest
  match (`PF_LONGEST`), that walk was 68% of everything; on
  `arrowdwn.png` the kind-1 mending was 70%, spent in full on each of its
  three candidates and found nothing. Three changes, none of which changes
  a recipe or a `.ppa` byte (the whole suite's counts the same, the hash
  gate's files M4's):
  - **The longest matches kept** (`TLongMemo`): `Longest` is the plain's and
    the position's alone (its chains are of every position before), and
    while encoding every candidate is at the same positions, the stream's
    tokens. The search's candidates share one, and the recipe's encoding
    and FindRecipe's own rebuild share another (up to `CORR_MEMO_MAX`, 4 Mi
    positions, 8 bytes each). The codec's verification rebuilds without
    it, as a reader does. Inside `Drive`, the last few asked are kept too
    (p + 1's is the next literal's p, a missed match's reference is the
    prediction's): that one also speeds up every rebuild, extraction
    included.
  - **The candidates on threads**: the parameter search's measures run on
    the threads `Compress` leaves to the image (all of them for a file of
    one image), the cheapest chosen in the same order.
  - **The mending's budget**: the candidate that came furthest keeps 16
    times the stream (plus 8 MB) of work, the other two 4 times (plus 2
    MB), down from 48 times plus 32 MB each. On the corpora (png-synth,
    zflow, pda) the mended streams were nearly all the first candidate's
    (131 to 4), none past 16 times a large stream (46 MB at most) or 2.5 MB
    on a small one.

  Tried and left out: every position's longest match found first on the
  threads, in pieces of 64 Ki positions (each with chains built from a
  window before it, the same matches): about 8 times the work of the
  positions the predictor asks (inside long matches the walks are long),
  so slower on 8 threads than one pass.

  Release build: the doodle (`BIRD1`, 18 KB) 3.0 -> 2.0 s on one thread,
  1.3 s on eight; the oxipng photo (426 KB) 8.8 -> 5.3 s (its extraction
  2.1 -> 1.6 s); `arrowdwn.png` 8.3 -> 4.9 s (the rest is the slow model);
  run_tests' `png-nonzlib` 223 -> 114 s, `zflow` 99 -> 42 s; the hash
  gate's `png-nonzlib` 21.9 -> 11.5 s on eight threads, 62 -> 40 s on one,
  `png-synth` 2405 -> 2067 s on one. All 1214 `.ppa` of the gate's seven
  sets are M4's, byte for byte, in its three runs. Rebuild of
  kind 3 still runs on one thread (no checkpoints yet).

## Status (M5, 15/11/2026): kind 2, miniz exact

`pas/ppaminiz.pas` and `pas/ppaminizc.c` ("Kind 2" above). Checked
against miniz itself (`pas/tests/test_miniz`, tools/preflate/README.md):
64 files of the shared corpus and 4 made ones (zeros, noise, one byte,
empty), each by miniz 1.14, 3.0.2 and 3.0.2 with unaligned loads, with 28
sets of flags (level 0, levels 1 to 10 greedy and lazy, filtered at 6 and
10, static at 1 and 6, RLE, Huffman only, raw with probes): 5,376 streams,
every one written back bit for bit by the C and by the Pascal code, and
every one's flags found by `FindMinizParams` (flags that give the same
stream count as found).

The corpora (`test_preflate`, C and Pascal, `-diffc`): `png-nonzlib`'s 12
miniz 1.x images (level 9, lazy: flags $300) are kind 2, down from kind 3
(their recipes 132 bytes in all, 11 each, from 8,521 as kind 3); `png-synth`'s 55 miniz
outputs (1.14 at 9, 3.x at 1, 6 and 10) and `raw`'s 12 kind 2; one of
`pda`'s 742 streams (498 bytes) is miniz's level 6; `tests/png3` has one.
No kind-0 or kind-1 recipe changed.

The hash gate (C on 8 threads and on 1, Pascal on 8), the seven sets'
1,214 files: every `.ppa` the same in the three runs and extracted; 1,144
are M4's byte for byte, and the 70 that changed are those with a miniz
image, each smaller: `sets-corpus` (the same 9 as `png-nonzlib`) 63,487 ->
59,027 B, `png-synth` 52 files 7,810,695 -> 7,605,782 B (the other 3
miniz outputs go as bytes either way). Totals: corpus 18,526,475 ->
18,522,015 B, `png-nonzlib` 808,447 -> 803,987 B, `png-synth`
129,717,160 -> 129,512,247 B. `doodleAtari`'s images are found in 0.15 s
(BIRD1 `ppa a` on one thread 3.2 -> 0.8 s).

Fuzzing (`pas/tests/fuzz`) with two version-3 seeds holding kind-2 recipes
added: 30 minutes each of `lib_ppa_chk` (libFuzzer, 104,314 runs) and
`afl_ppa_chk` (AFL++, 27,753): nothing.

- The search: each candidate stops at the first token, block end or block
  type unlike the stream's, so a stream that is not miniz's costs 0 to 18
  ms (png-synth's, up to 7 MB of bytes); one with a match of 3 bytes from
  8 KB or further costs nothing (no candidate).
- Not ported (each would be a new variant): miniz built with
  `TDEFL_LESS_MEMORY` (a 24 KB code buffer, a 12-bit hash), flushes
  (`mz_deflate` with `MZ_SYNC_FLUSH` or `MZ_FULL_FLUSH`), and
  miniz_oxide (Rust's port, which has parted from miniz's choices).

## Status (M6, 16/11/2026): kind 2, libdeflate exact

`pas/ppalibdeflate.pas` and `pas/ppaldfc.c` over `vendor/libdeflate`
("Kind 2's libdeflate" above), in codec stream version 4.

- **libdeflate itself**: `ppaldfc.c` built as PPA builds its C gives what
  libdeflate 1.23 (Debian's) writes, byte for byte, on 216 cases (18
  streams' bytes, levels 1 to 12) on x86-64 and on x86; 1.19, 1.23 and 1.26
  agree on 130 of 130; 1.15 and 1.18 differ on 7 and 2 of 65. With no C
  runtime it leaves no symbol undefined for x86-64, x86, arm64 (gcc),
  Windows x64 and x86 (mingw) or clang (64 and 32 bits).
- **oxipng 10.1.1**: its IDAT is libdeflate's level 10 for `-o1`, 11 for
  `-o2`, 12 for `-o4`, `-o6` and `max` (3 photos, 5 presets each).
- **The corpora** (`test_preflate`): `png-nonzlib`'s 5 oxipng images are
  kind 2 now (were kind 3; 0 kind 3 left there); `hostile`'s
  `zeros64m.ldf12` too; `tests/png3` has `rgb8-oxipng-o2.png` (oxipng
  `-o2 --force`, written in version 4) and its two libdeflate images (6 and
  12) are kind 2. Crafted: libdeflate's 12 levels of 40 KB of words, a
  table, noise and zeros each come back as kind 2 (8 and 9 write the same
  bytes), never with kind 2's encoders up to miniz (version 3); a kind-2
  libdeflate recipe cut anywhere is refused, every value of every byte is
  refused or rebuilt, and an unknown variant, level 0 or 13 do not rebuild.
- **The hash gate** against the published 0.3.0, the benchmark's three
  sets: corpus 70 and photos 20 `.ppa` the same byte for byte; generated
  70 of 75 the same and its 5 oxipng files smaller: photo 316,583 ->
  285,331 B, rgba 137,037 -> 109,996, art 55,285 -> 50,530, graphic
  21,073 -> 19,690, icon 67,950 -> 66,107; the set 9,006,469 -> 8,940,195
  B (57.52% -> 57.10%). Every file extracted and compared.
- **Speed**: 15 oxipng photos (`-o1` to `max`), 8 at once: compressing
  10.3 s (0.3.0, kind 3) -> 6.8 s.
- **The corpora's PNG streams by libdeflate and oxipng** (`png-synth`):
  libdeflate 1.23's (levels 1, 6, 9, 12) 49 of 51 kind 2, oxipng's 116 of
  153 (of the rest, 34 are `-o2-zopfli`, zopfli's: kind 3; one zlib's,
  kind 0); the 2 and 2 left are s33's noise, stored blocks only over 64
  KB, where libdeflate is not tried. `raw`: libdeflate's 48 kind 2 (was
  kind 3); `pda`: 2.
- **CI** (04c15e8): the six platforms, 32 and 64 bits, give the same
  hashes (`determinism`); the zpaq-std tarball builds alone (`ppa.so`,
  `ppa.dll`, `ppa32.dll`; the DLLs still import only kernel32, oleaut32
  and user32).
- **Fuzzing** (`pas/tests/fuzz`), seeds with version 4 streams
  (`tests/png3`): 30 minutes each of `lib_ppa_chk` (libFuzzer, 145,600
  runs) and `afl_ppa_chk` (AFL++, 43,418): nothing.

## Status (M9, 16/11/2026): kind 2, zopfli exact

`pas/ppazopfli.pas` and `pas/ppazopc.c` over `vendor/zopfli` ("Kind 2's
zopfli" above), in codec stream version 5.

- **zopfli itself**: zopflipng's IDAT is zopfli 1.0.3's deflate with 15
  iterations under 200,000 bytes and 5 over (its `num_iterations_large`);
  advpng `-z4`'s with 5. PPA's build (correctly rounded log, SSE2) gives
  47 of png-synth's 53 zopflipng and advpng `-z4` streams back at the
  iterations tried there, the same bits on x86-64 and on x86 (the other 6
  are advpng over 2 MB, tried at 1 iteration only); with no C runtime it
  leaves no symbol undefined for x86-64, x86, arm64, mingw x64 and x86,
  clang 64 and 32. Its log is the correctly rounded one where glibc's is
  not (checked to 20,000,000 against Python's decimal).
- **Not the same**: oxipng's `--zopfli` (a Rust port: the same blocks, a
  token differs here and there, a tie in its costs) and advpng `-z3`
  (7-Zip's deflate): kind 3 as before; another variant if ever.
- **The search**: s23's 60 KB found in 1.9 s (15 iterations), s05's 283
  KB in 2.9 s (5); a 60 KB stream that is not zopfli's costs 0.4 s;
  `rgba8-zopfli` (one block) 0.09 s.
- **The corpora** (`test_preflate`): png-synth's zopflipng files of up to
  64 KiB, 8 kind 2 (up to 256 KiB: 12; advpng `-z4`: 3 and 7); `tests/png3`'s
  `rgba8-zopfli.png` is written in version 5 (kind 2 at 15 iterations).
  Crafted: zopfli's 15, 5 and 1 iterations come back as kind 2, never with
  the encoders up to libdeflate (version 4) nor with zopfli's search off;
  without block splitting, kind 3 (not searched); a zopfli recipe cut
  anywhere is refused, every value of every byte refused or rebuilt.
- **The hash gate** against the published 0.4.0, the benchmark's three
  sets at the default level: every `.ppa` the same, byte for byte (they
  hold no zopfli image); compressing 4 to 5% longer (zopfli's search on
  the streams that go to kind 3).
- **CI** (a536fa5): the six platforms, 32 and 64 bits, give the same
  hashes (`determinism`: `tests/png3`'s version 5 stream, zopfli's doubles
  and log, the same bits on x86-64, x86, arm64, macOS and Windows). Apple's
  clang has no `__builtin_setjmp` on arm64: macOS takes the system's
  `_setjmp`. The zpaq-std tarball builds alone; the DLLs import only
  kernel32, oleaut32 and user32.
- **Fuzzing**, seeds with version 5 streams: 30 minutes each of
  `lib_ppa_chk` (libFuzzer, 84,938 runs) and `afl_ppa_chk` (AFL++, 40,900):
  nothing.

## Status (17/11/2026): zopfli's variant 1, the Rust port

- **oxipng's `--zopfli`** (oxipng 10.1.1, the zopfli crate 0.8.3, checksum
  as its `Cargo.lock`): the study's harness `zoprs`
  (`tools/preflate/enc/zoprs`, the crate called as oxipng calls it) gives
  its IDAT byte for byte. Variant 1 gives all 34 of png-synth's
  `oxipng -o 2 -z` streams back (25 at 15 iterations, 9 at `--zi 1`, up to
  6.9 MB in 7 master blocks); zopfli 1.0.3 gives 11 of the 14 up to 300
  KB, and not s02 at one iteration.
- **The corpora**: png-synth's 9 oxipng `--zopfli` images of up to 64 KiB
  are kind 2 at the default level (s23 the one in variant 1: its `.ppa`
  20,888 -> 18,651 B); `tests/png3/gray8-oxipng-zopfli.png` (oxipng `-o2
  -z --force --nx` of a gray image of long runs and noise rows) is written
  in version 6. 4 golden vectors of variant 1 (`mkgolden.py
  --zopfli-rs`: runs of one byte, text and noise, where 1.0.3 parts from
  the port at 10, 15 and 20 iterations): 85 in all.

## Status (M8, 17/11/2026): libppa's `ppa_deflate_*`, for PDA

- **The API** (`pas/lib/ppa.h`, `LIBRARY.md`; `pas/ppadeflctx.pas`): a
  context per thread (the size cap, zlib's tables kept from one stream to
  the next, the last stream's recipe tried first: PDA's batch),
  `ppa_deflate_analyze` (a stream, raw, zlib or either, and a level ->
  its bytes, a recipe and where the stream ended) and
  `ppa_deflate_rebuild`. The recipe: `RecipeVersion` (3 at least) and
  `RecipeBytes`, no tail.
- **PDA's set** (`preflate/corpus/pda`: 467 zlib streams of PDFs, 275 raw
  of ZIPs, 18,955,136 B holding 141,235,742 B): `test_lib --deflate`
  rebuilds all 742 through the C interface, with one context and with a
  fresh one each; 38,714 B of recipes; 4 threads with a context each give
  the same recipes; bytes after a stream left out (`consumed`); recipe
  versions 7 to 255 `PPA_E_VERSION`; damaged recipes and cut streams an
  error or other bytes, never a crash. The 85 golden vectors too, at the
  default level (zopfli's searched: 48 minutes; CI runs them at level 1
  and two of zopfli's at the default).
- **The time a stream costs**: a 39-byte stream (847 B, zlib level 6,
  the hint right) 62 µs to analyze (the parse and one encode to check)
  and 45 µs to rebuild, from about 130 µs each: zlib's tables kept in the
  context (no allocation a stream), the positions' arrays as long as the
  input when it is shorter than the window, and `BuildEnc`'s bit reversal
  by table (the same bits: the suite's hashes). The rest is the encode
  itself (ppazlibc's skip tables, about 150 instructions a byte on short
  inputs), clearing zlib's hash table (128 KB at memLevel 8) and the
  parse. The design's 50 µs is not reached for analysis; a stream whose
  recipe the hint does not give costs the search (PDA's set, its streams
  of 256 to 1023 B: a median of 348 µs to analyze, 106 µs to rebuild).

## Studied, not done yet (M7, 16/11/2026): zlib-ng

zlib-ng 2.0.7, 2.1.8, 2.2.5 and 2.3.3 built with and without SIMD
(`WITH_OPTIM`), each level and strategy on 14 streams' bytes (scripts in
`/mnt/IA_LAB/agentes/ppa/m7/`):

- 2.2.x and 2.3.x write the same with and without SIMD, and the same as
  2.1.8 without it: one variant would cover them on any CPU. 2.0.x and
  2.1.x with SIMD differ at levels 1 to 5 (the CPU's).
- It differs from zlib at every level but on some level 9 streams; its
  Huffman-only, RLE and fixed strategies write zlib's (kind 0).
- Unlike zlib, levels 1 (`deflate_quick`), 5 and 6 (`deflate_medium`)
  depend on how the input is given (fed a row at a time, as libpng does,
  31 of 117 streams differ from one call) and, more rarely, on the output
  buffer (libpng's 8 KB; Python's growing blocks): a recipe would have to
  name the program's feeding as well. Levels 2 to 4 and 7 to 9 do not.
- The corpus's 1,820 PNGs: zlib-ng in 2 real files (Debian's apache2-doc,
  level 6 a row at a time; 553 B of kind-3 corrections each), and the
  study's own samples (`zlibng-1`, `-6`, `-9`: about 335 KB of the 731 KB
  of kind-3 corrections the corpus's PNGs cost, nearly all level 1).

Wira's decision: zopfli (M9) before zlib-ng (done above).

## Credits

The idea of rebuilding a deflate stream from its bytes and a small
description of how its encoder worked, and of keeping flushes as data, is
preflate's (Dirk Steinke, Apache-2.0), studied in
`/mnt/IA_LAB/agentes/ppa/preflate-study/`. No code of preflate is here: the
flushes are zlib's own (`deflate.c`, `trees.c` of zlib 1.3.1, 1.2.5 and
1.2.3), ported into `ppazlib` as NOTICE says.

Kind 2's miniz is miniz's own tdefl (1.14 and 3.0.2; Rich Geldreich and
contributors, MIT / public domain), ported into `ppaminiz` as NOTICE says.
Kind 2's libdeflate is libdeflate's own compressor (1.26; Eric Biggers,
MIT), unmodified in `vendor/libdeflate`, as NOTICE says. Kind 2's zopfli
is zopfli's own deflate (1.0.3; Google, Apache-2.0), unmodified in
`vendor/zopfli`, as NOTICE says.
