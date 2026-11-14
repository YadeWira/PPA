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

- **Codec stream version 2** (what PPA writes today) holds **kind 0 only**,
  in its own layout (`RecipeBytesV2`, CODEC.md "Layer 6"). The codec asks
  `FindRecipe` for kind 0 alone (`maxKind = RECIPE_ZLIB`), so an image whose
  stream needs a flow is kept as its bytes, as before. Every `.ppa` PPA
  writes is the same as before kind 1 existed.
- **`RecipeBytes`** below is a provisional format for any kind. No stream
  format holds it yet; codec stream version 3 (milestone M4) will. Until
  then it may change, but only by the versioning rule.

## Kinds

| kind | name | what makes the deflate data | since |
|---|---|---|---|
| 0 | `RECIPE_ZLIB` | zlib's parameters: level, strategy, memLevel, windowBits | 0.1.0 (codec v2) |
| 1 | `RECIPE_ZLIB_FLOW` | kind 0's parameters at the start, and a **flow**: the flushes and parameter changes zlib made along the stream, and which zlib made them | M2 (not written by PPA yet) |
| 2 | | reserved: a known non-zlib encoder (design §(a) 7) | |
| 3 | `RECIPE_CORR` | a zlib-like predictor (`ppacorr`) and the **corrections** that make what it predicts the stream: any stream `ppadeflate` reads | M3a, M3b (not written by PPA yet) |
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

### Kind 3: a predictor and its corrections

`pas/ppacorr.pas` (and its hot loops in `pas/ppacorrc.c`). `FindRecipe`
tries it after kinds 0 and 1, so it never replaces them (a zlib stream is
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

### RecipeBytes (format 2, provisional)

All integers are bytes or varints (7 bits a byte, low first, the high bit
set on all but the last).

```
byte    format              RECIPE_FORMAT = 2
byte    kind                0, 1 or 3
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
- Golden vectors (recipes and the streams they give) are committed per
  version and checked by the suite, C and Pascal, 32 and 64 bits, before
  M4 freezes format 1.

Before M4 nothing is published, and the format may still change; when it
does, its byte goes up. M3b did so: format 2 (kind 3's `tree` byte; the
predictor and its models are `PRED_VERSION` 2, and kind 1's variant may
carry `ZV_NO_TOO_FAR`). A format 1 recipe is refused.

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
is the stream.

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

## Credits

The idea of rebuilding a deflate stream from its bytes and a small
description of how its encoder worked, and of keeping flushes as data, is
preflate's (Dirk Steinke, Apache-2.0), studied in
`/mnt/IA_LAB/agentes/ppa/preflate-study/`. No code of preflate is here: the
flushes are zlib's own (`deflate.c`, `trees.c` of zlib 1.3.1, 1.2.5 and
1.2.3), ported into `ppazlib` as NOTICE says.
