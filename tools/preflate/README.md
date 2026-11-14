# tools/preflate: corpus and harness for PPA's own preflate

PPA 0.3.0 starts "deflate recipes": rebuilding, byte for byte, deflate streams
that zlib's parameters do not reproduce (design and review:
`/mnt/IA_LAB/agentes/ppa/preflate-study/design.md`, `review.md`). This folder
is milestone M0: the test corpus, a harness that measures what PPA does with
each stream today, and preflate 0.3.4's reconstruction cost as the figure to
beat. **Nothing here changes PPA or its output.** The numbers are in
[BASELINE.md](BASELINE.md).

preflate (Dirk Steinke, Apache-2.0) is used only as an external reference
binary, built from precomp 0.4.7's `contrib/preflate`. No code of it is in
this repository. PPA's own implementation takes ideas from it, never its code,
and credits it in `NOTICE` when it does.

## Where things live

Everything big stays outside the repository, under
`PF=/mnt/IA_LAB/agentes/ppa/preflate`:

| path | what |
|---|---|
| `$PF/tools/` | the reference encoders and preflate, built from source by `build_tools.sh`; `VERSIONS.tsv` lists each |
| `$PF/corpus/<subset>/` | the corpus, made by `mkcorpus.py`, each subset with a `MANIFEST.tsv` |
| `$PF/m0/bench/` | frozen read-only: the baseline's TSVs (`*.files.tsv`, `*.streams.tsv`, `gate.tsv`) and `summary.md` |
| `$PF/m0/work/` | scratch the harness rebuilds on each run (the `.ppa` it wrote, the gate's outputs) |

Each `MANIFEST.tsv` has: file, kind, origin, encoder, version, settings,
bytes, sha256, note. Every file is a copy. Nothing is written to
`/mnt/OSR_D3`, to the study folders or to `sets/`.

## The corpus

| subset | what | files |
|---|---|---|
| `png-zlib` | the census's PNG-family files whose every stream zlib reproduces: 63 from the shared corpus (MNG, JNG and CgBI included) and 70 from `sets/generated`. **Regression set**: v2 output must not change. | 133 |
| `png-nonzlib` | the 24 whose stream zlib does not reproduce: 12 miniz 1.x L9, 6 spider `.spi` (unidentified), `ipad.png` (CgBI, zlib L9 + `Z_FULL_FLUSH`), 5 `*_oxipng.png` (libdeflate 1.23 L11) | 24 |
| `png-synth` | 34 sources (`png-synth/sources/`, own manifest) re-encoded by oxipng (`-o 0/2/4/max`, `-z`), zopflipng, pngcrush (`-m 1/4/7/113/124`), advpng (`-z -1..-4`), optipng; zlib with flushes and `deflateParams` changes (`zfl`, 9 scripts); and on 14 sources (the first 10 and the 4 synthetic ones) raw rewraps of the same filtered bytes by libdeflate 1/6/9/12, miniz 1.14 L9 and 3.x L1/6/10, zlib-ng 2.3.3 L1/6/9, zopfli and 7-Zip gzip mx9. An output whose IDAT stream is the same bytes as the source's or another output's is dropped. | see manifest |
| `raw` | bare deflate of the report0 samples (text, exe, bmp): the study's 11 encoders (cell by cell comparable with report0 §2), libdeflate 0-12, miniz, zlib-ng, zfl flush streams; ecoli.gbk under 7z mx9 and zlib 9 (plain not copied) | 101 |
| `pda` | 742 FlateDecode and ZIP streams from the PDA census samples, stratified by creator: up to 6 misses, 3 with flushes and 3 matches per creator, then small streams. `.z` keep the zlib framing, `.raw` are bare | 742 |
| `zflow` | (M2) zlib 1.3.1, 1.2.5 and 1.2.3 (`zfl`, `zfl-1.2.5`, `zfl-1.2.3`) with 15 flush and `deflateParams` scripts each on the first 120000 bytes of the `raw` samples (text, exe, bmp): partial flushes every 20 bytes (old zlibs' second empty block), every 97 and 4096, syncs, full flushes, a mix, `Z_BLOCK`s, parameter changes with and without a flush, RLE and Huffman-only with flushes (1.2.3 has no `Z_BLOCK`) | 129 |
| `hostile` | crafted: 64 MiB zero runs (zlib 1, 9, libdeflate 12), 16 MiB `ab`, distance 32768, 258 as 284, 1-byte stored blocks with non-zero pads, stored only, empty blocks, FDICT, bad Adler, bytes after, truncated, bit flip, block type 3, window 9 | 18 |

Not yet in it (design §(e) asks for them; add when a milestone needs them):
the ≥ 256 MB image and the 1 GB zero run (memory on this shared machine),
zlib 1-9 × every strategy on `png-synth` (`sets/generated` has most of
them), and the PDA census's 61 non-inflatable and 95 encrypted streams
(`hostile` has the same failure kinds).

## The tools

```sh
PF=/mnt/IA_LAB/agentes/ppa/preflate
bash tools/preflate/build_tools.sh              # $PF/tools: preflate, zfl, ppastreams, ppa, encoders
python3 tools/preflate/mkcorpus.py all -j 4     # $PF/corpus (png, synth, raw, pda, hostile, zflow)
OUT=$PF/m1/bench   # $PF/m0/bench is the frozen M0 baseline
python3 tools/preflate/baseline.py streams png-zlib png-nonzlib png-synth raw pda hostile -j 4 --out $OUT
python3 tools/preflate/baseline.py gate --out $OUT        # v2 .ppa hashes: tests/png, sets corpus/generated/photos
python3 tools/preflate/baseline.py summary --out $OUT   # --md FILE: tables below its marker
```

Every child process runs under `ulimit -v 6000000`, with at most 4 at a time.

- **`build_tools.sh`** builds from source: preflate 0.3.4 (precomp 0.4.7
  `contrib/preflate`, `main.cpp` + the library, glibc names for `_fseeki64`),
  advancecomp 2.6, pngcrush 1.8.13, zopfli/zopflipng (git df1517d),
  libdeflate (git 7e66210, 1.26), miniz 1.14 and 3.0.2, and `zfl` (with the
  system's zlib 1.3.1, and with zlib 1.2.5 and 1.2.3 from zlib.net/fossils,
  pinned by sha256: `zfl-1.2.5`, `zfl-1.2.3`); it takes
  zlib-ng 2.3.3 from the PDA census's Python package, and 7-Zip 25.01,
  optipng 0.7.8, oxipng 10.1.1 and python's zlib 1.3.1 from the system.
  Downloads are pinned by sha256.
- **`zfl.c`**: zlib's deflate driven by a script, `POS:sync|full|partial|block`
  and `POS:params=L,S` (`deflateParams` mid-stream), for the flush and
  parameter-change streams M2 must rebuild.
- **`enc/`**: three small drivers, raw deflate of a file: `ldf` (libdeflate),
  `mz` (miniz; `-DMZ114` for 1.14), `zop` (zopfli).
- **`ppastreams.pas`**: each deflate stream of PNG-family files as PPA sees
  it: `ppapng.Decompose`, `ppadeflate.Decode`, `ppazlib.FindZlibParams` and
  `Encode` compared with the stream, as `ppacodec.PlanImage` does. `-dump DIR`
  writes the streams; `-stream` takes stream files (`.raw` bare, else zlib).
- **`mkcorpus.py`** builds the subsets and their manifests. `png` re-checks
  each corpus file's sha256 against its `/mnt/OSR_D3` origin.
- **`baseline.py`**:
  - `streams`: per file, the real `ppa a` (size, `.ppa` sha256) and
    `ppa info` (image streams kept as bytes); per stream, `ppastreams` (does
    PPA's zlib search reproduce it, with which parameters) and preflate
    `-s`/`-x` on its bare deflate (diff bytes, times, peak RSS), the round
    trip compared byte for byte;
  - `gate`: `ppa a` over whole sets three ways (C 8 threads, C 1 thread,
    Pascal `PPA_NOC=1` 8 threads), `.ppa` sha256 per file and whether the
    three agree. This is M1's "hashes unchanged" check: run it again after a
    change and compare `gate.tsv` (`cut -f1,2,5 gate.tsv`);
  - `summary`: the tables of `BASELINE.md`.

## For the next milestones

- The hash gate (M1 and every milestone until codec v3): with the ppa to
  check (`PPA_BIN=...`, default `$PF/tools/bin/ppa`),
  `baseline.py gate tests-png sets-corpus sets-generated sets-photos png-zlib png-nonzlib png-synth --out DIR`,
  then `baseline.py gatecheck --out DIR`: every file `gate-v2.tsv` names
  must have the same `.ppa` sha256 in all three runs. `gate-v2.tsv` is the
  committed reference (set, file, bytes, `.ppa` size and sha256, C 8
  threads), written by M0's ppa (`c45ea74`); M1 added the three corpus
  sets to it, from that same build. About 50 minutes on this machine
  (png-synth is most of it).
- M1 moved the stream layer into `pas/ppapreflate.pas`
  (`Parse`/`FindRecipe`/`Analyze`, `Rebuild`, `RecipeBytesV2`/`ReadRecipeV2`,
  kind 0 only) and gave `ppacodec.Compress` a `maxVersion` (ppa1 passes 2).
  `pas/tests/test_preflate` runs every stream of a folder through it;
  `run_tests.sh` runs it on `tests/png` and, when `$PF/corpus` is there
  (`PREFLATE_CORPUS`), on `png-zlib` (all 392 kind 0) and `png-nonzlib`
  (none).
- M2: `png-synth` files named `*.zfl-*` and `raw/*.zfl-*` are zlib with
  flushes or `deflateParams`; `ipad.png` in `png-nonzlib`; the PDA streams
  whose manifest settings carry `flushes:`. The `ppa_zlib` column of the
  streams TSV says what PPA's search finds today.
- M2 (13/11/2026) added recipe kind 1, zlib's flushes and parameter
  changes (`doc/PREFLATE.md`), found by `ppapreflate.FindZlibFlow` and
  rebuilt by `ppazlib.ZlibChoicesFlow`; PPA still writes only kind 0
  (codec v2), so the gate above did not move. `pas/tests/test_preflate`
  measures it: `-all01`, `-min1 N`, `-minok N`, `-only TEXT`, and the
  `recipes` digest that the C and the Pascal code must give alike. The
  `zflow` subset is new (above).
- M3: the preflate columns per group are the "total diff ≤ preflate's per
  encoder group" gate.
- M3a (13/11/2026) added recipe kind 3 (`pas/ppacorr.pas`): every stream
  that inflates has a recipe. `test_preflate DIR 1 -all013 -tsv FILE`
  writes a line per stream; `compare_recipes.py SUBSET FILE...` makes the
  per-group table against M0's preflate figures (doc/PREFLATE.md, "Status
  (M3a)"). Scratch and results: `$PF/m3/`.
- M3b (14/11/2026) made kind-3 recipes small (context mixing, the longest
  match as the length's guess, the rank walk's skips over runs, the tree
  builders of libdeflate, miniz and zopfli, the parameters by coded size)
  and found pngcrush's (and spider's) zlib: built with `TOO_FAR` 32767, now
  kind 1 (`ZV_NO_TOO_FAR`). Same harness (`-all013 -diffc -tsv`,
  `compare_recipes.py`); doc/PREFLATE.md, "Status (M3b)". Scratch and
  results: `$PF/m3/m3b/`.
