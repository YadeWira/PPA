# PJA 0.6.0: the zpaq-std plugin, vendored

PJA (https://github.com/YadeWira/PJA), tag `v0.6.0`, commit `8569253`:
only the sources the zpaq-std plugin is built from. MIT (`LICENSE`);
`NOTICE` has the third-party notes. The same sources as the prototype of
commit `9c3e61a` (zpaq-std's exp/v7) but for the version number.

## What is new

Four codecs, indices 10 to 13 of `zpaqstd_codecs_v1`; 0 to 9 are 0.5.3's,
unchanged (streams, ZPAQL, what each takes):

| index | codec | takes | stream | ZPAQL |
|---|---|---|---|---|
| 10 | `pja7` | what `pja` takes | version 7 | `PJA7_ZPAQL`, 35,104 bytes, `comp 0 0 $3 $1+1 0` |
| 11 | `pjax7` | what `pjax` takes | `pjax`'s version 6, its parts version 7 | `PJAX7_ZPAQL`, 35,211 bytes |
| 12 | `pja7z` | what `pja` takes | as `pja7`, through the block's LZ77 (as `pjaz`) | `PJA7Z_ZPAQL`, 35,829 bytes, `comp 0 0 $3 $1 0` |
| 13 | `pjax7z` | what `pjax` takes | as `pjax7`, through the LZ77 (as `pjaxz`) | `PJAX7Z_ZPAQL`, 35,987 bytes |

- The ZPAQL decoders are in `pas/plugin/v7zpaql.inc` (handed out as
  `ZS_DATA_ZPAQL_ARGS`), `$3` from each codec's `query(ZS_QUERY_ZPAQL_ARGS)`
  (`ZpaqlArgs7`, `ZpaqlPjaxArgs(..., True)`), several segments a block.
  A z codec's compress, decompress, query and detect are its codec's.
- Detection: `pja7` and `pjax7` take what `pja` and `pjax` take, with the
  memory of version 7's decoder under the same cap (2^26 words): its
  models are 210,731 words each, two a band (version 5's: about 77,500).
- The plugin now links C: the version 7 model (`pjav7c.c`,
  `pjav7c_loop.h`) and its helpers (`pjasysc.c`), through `pjav7.pas`.
  They call no library and need no C runtime: the Windows DLL imports only
  kernel32, oleaut32 and user32, as before. x86 and x64 write the same
  bytes (checked: pja7 on 20 photos, pjax7 on an MPO; PJA's CI compares
  every platform's streams).

## Building

FreePascal 3.2.2 and a C compiler (gcc or clang) for the same target. The C
first (`pas/build_c.sh <dir> [flags]`: `-O3 -fwrapv -ffp-contract=off
-fno-stack-protector`, and `-fno-tree-loop-distribute-patterns` with gcc),
then fpc with `-Fo<dir>` so `pjav7.pas`'s `{$L pjav7c.o}` and
`{$L pjasysc.o}` find the objects. From this directory:

```sh
export PJA_COMMIT=8569253
```

Linux x86_64 (position-independent C, `-fPIC`, and `-Cg`):

```sh
sh pas/build_c.sh build/lin/c -fPIC
fpc -O3 -dPJA_FAST -Cg -Fupas -Fipas -Fupas/plugin -Fipas/plugin -Fobuild/lin/c \
    -FUbuild/lin -obuild/lin/pja.so pas/plugin/pja_zpaqstd.pas
```

Linux x86 (32-bit): `CC="gcc -m32" sh pas/build_c.sh build/l32/c -fPIC`, then
the i386 fpc with `-Fobuild/l32/c`, as above.

Linux arm64: `CC=aarch64-linux-gnu-gcc sh pas/build_c.sh build/a64/c -fPIC`
(or the native gcc), then fpc for aarch64 with `-Fobuild/a64/c -Cg`.

Windows x64 (no `-fPIC`):

```sh
CC=x86_64-w64-mingw32-gcc sh pas/build_c.sh build/win64/c
fpc -Twin64 -Px86_64 -O3 -dPJA_FAST -Fupas -Fipas -Fupas/plugin -Fipas/plugin -Fobuild/win64/c \
    -FUbuild/win64 -obuild/win64/pja.dll pas/plugin/pja_zpaqstd.pas
```

Windows x86: `CC=i686-w64-mingw32-gcc sh pas/build_c.sh build/win32/c`
(build_c.sh adds `-fno-pic` for 32-bit x86), then `ppc386 -n -Twin32 ...
-Fobuild/win32/c`, as 0.5.3's with `-Fo` added.

macOS arm64: `sh pas/build_c.sh build/mac/c -fPIC` with clang, then fpc with
`-Fobuild/mac/c -Cg`.

`-dPJA_FAST` as before. On x86 the C has SSE4.1 and AVX2 copies of its
loop, taken by cpuid at run time; every copy writes the same bits.

## Checked

zpaq-std, through its whole path (`-sa -t8`, branch exp/v7, against its
2.0.3): photos -3.1%, corpus -2.4%, MPO -1.0%, arithmetic-coded -3.1%,
generated -2.6%; writing 1.3 to 1.6 times as fast, extracting natively
1.2 to 1.6 times, zpaq 7.15 with the ZPAQL 1.5 to 1.6 times. Every file
back, natively and with zpaq 7.15, with the smallest valid window forced
in each group too; its CI (run 41227860640) on its six platforms, the
same archive on every one.

PJA: every file back, natively and through the ZPAQL with libzpaq (zpaq
7.15's engine), at the `$3` the query gives:

| set | v5 codec | v7 codec | compress (one thread) | decompress |
|---|---|---|---|---|
| 151 photos (pja / pja7) | 75.03% | **72.68%** | 52.7 -> 33.5 s | 53.5 -> 35.9 s |
| corpus, the 65 pja takes | 73.85% | **72.22%** | 25.6 -> 19.6 s | 20.4 -> 15.2 s |
| 244 arithmetic-coded | 76.35% | **74.44%** | 6.2 -> 5.0 s | 5.9 -> 4.8 s |
| 640 generated | 75.47% | **73.58%** | 12.5 -> 9.4 s | 12.9 -> 10.1 s |
| MPO, the 4 pjax takes (pjax / pjax7) | 73.93% | **73.18%** | 23.5 -> 16.8 s | 22.1 -> 16.0 s |

The ZPAQL: libzpaq extracts 30 photos in 46.4 s with pja7's, 108.6 s with
pja's. In one block through a test LZ77 (the z, $1 = 24): arithmetic
17.70% (pjaz) -> 17.18% (pja7z), generated 16.77% -> 16.34%; MPO + corpus
through pjax7z 70.47%; a 4 KB window too; 150 damaged segments a codec,
no hang. PJA's suite decodes pja7 and pjax7 segments, and their z, in its
ZPAQL interpreter.

## Frozen

`pja7`, `pjax7`, `pja7z` and `pjax7z`: their streams, their ZPAQL
(`pas/plugin/v7zpaql.inc`) and what each takes do not change under these
names, as codecs 0 to 9's.
