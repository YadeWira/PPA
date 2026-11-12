# PPA: the zpaq-std plugin, codec `ppa1`

PPA (https://github.com/YadeWira/PPA), commit `@COMMIT@`@TAG@. Only the
sources the plugin is built from, made by `tools/zpaqstd_tarball.sh`. MIT
(`LICENSE`); `NOTICE` has the third-party notes (PJA's codec for a JNG's
JPEG, linked but not used by `ppa1`; zlib's choices ported; PJA's ZPAQL
compiler, pinned).

## The codec

One codec, index 0 of `zpaqstd_codecs_v1`, ABI 1:

| index | codec | takes | stream | ZPAQL |
|---|---|---|---|---|
| 0 | `ppa1` | PNG, APNG, MNG (no JNG, no MNG holding one) whose every image is 8-bit gray, gray+alpha, RGB or RGBA (Adam7 too), up to 7 MiB of filtered image a file | PPA's codec stream version 2, every image with the static model; streams PPA cannot rebuild kept as bytes | `PPA1_ZPAQL` (`pas/plugin/ppa1zpaql.inc`), @PCOMP@ bytes, `comp 0 0 $3 $4 0` |

- `query(ZS_QUERY_ZPAQL_ARGS)` gives `$3 | $4 << 8` (log2 of H in words and of
  M in bytes) exactly as the decoder needs them for that stream; one word of
  H or one byte of M less and the decoder stops with `error()`.
  `query(ZS_QUERY_SEGMENTS)` = 1 (several files a block),
  `query(ZS_QUERY_WEIGHT)` = a file's filtered image bytes plus 8 KiB an
  image (from the headers: the same on every platform, whatever the
  threads), `query(ZS_QUERY_GROUP_WEIGHT)` = 7 MiB: a group of ppa1's
  files kept to that weight decodes, without the plugin, in about the time
  of its largest file.
- Detection by the bytes only, and only what the ZPAQL decodes. The ZPAQL
  is handed out as `ZS_DATA_ZPAQL_ARGS` only.
- `ppa1` is frozen once published: its stream, what it takes and its ZPAQL
  byte for byte. A change to any is a new codec name; `ppa1` stays in the
  plugin to read.
- The ZPAQL is compiled from `pas/plugin/zpaql/*.zl` by PJA's zpaqlc
  (pinned copy in PPA's `tools/zpaql`, PJA commit `114c395`, opt=3); the
  `.inc` is committed and PPA's tests check it is current.
- The plugin links PPA's C part (`pas/build_c.sh`, with PJA's from
  `vendor/pja`). No library and no C runtime: the Windows DLL imports only
  kernel32, oleaut32 and user32. On Windows it takes its memory from the
  process heap (`pas/ppaheap.pas`, PJA's `pjaheap`, with 16 bytes to spare
  after each block).

## Building

FreePascal 3.2.2 and a C compiler for the same target. From this directory:

```sh
bash pas/plugin/build.sh out      # out/ppa.so; out/ppa.dll (x86_64-w64-mingw32-gcc,
                                  # fpc -Twin64); out/ppa32.dll with FPCW32 (an
                                  # i386-win32 fpc) and i686-w64-mingw32-gcc
```

zpaq-std loads `codecs/ppa.so` (`codecs\ppa.dll`) next to its binary.

## Checked (PPA's commit above)

- PPA's `pas/run_tests.sh`: the decoder current (`gen_ppadec.py --check`),
  zpaqlc's own tests, 1041 checks of the detection and the query, 148
  segments decoded with exactly the queried memory (and one less: error()),
  the library through ctypes as zpaq-std loads it.
- zpaq-std 2.7.2 with the plugin (`-sae:ppa:ppa1+1` and `-sat`), zpaq-std
  without it and zpaq 7.15 (64 and 32 bits): every file of PPA's three
  test sets and two mixed folders back byte for byte. Measured on
  11/11/2026 (4 threads), the archive against the input:

| set | -m1 | -sa -m1 | -m5 | -sa -m5 |
|---|---|---|---|---|
| 20 photos as PNG, 40.3 MB | 100.06% | 65.62% | 96.31% | 65.35% |
| 75 generated PNG, 15.7 MB | 72.64% | 59.42% | 69.53% | 59.14% |
| 70 files of the PNG family, 32.9 MB | 85.82% | 85.44% | 83.26% | 83.30% |
| 693 mixed files (95 PNG), 90.5 MB | 72.42% | 54.78% | 66.76% | 51.05% |
| 872 mixed files (46 PNG), 80.1 MB | 62.99% | 62.97% | 55.40% | 55.53% |

  Where the 7 MiB cap leaves the large PNGs out, ppa1 takes only small
  files, whose 19 KB decoder does not pay: +0.04 and +0.13 points.

## SHA-256 of the files

`SHA256SUMS` beside this file.
