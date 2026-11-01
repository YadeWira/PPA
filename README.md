# PPA

Lossless recompression of the **PNG family** (PNG, APNG, MNG, JNG), in
FreePascal, with the hot loops in C and some x86-64 assembly; no libraries.
The successor of [packPNG](https://github.com/YadeWira/packPNG), with a
format of its own, the way [PJA](https://github.com/YadeWira/PJA) followed
packJPG.

| Component | Status |
|---|---|
| CI | [![CI][ciBadge]][ciLink] |
| Latest release | none yet (build from source) |

```sh
ppa a image.png          # -> image.ppa
ppa x image.ppa          # -> image.png, the same file byte for byte
```

**Work in progress: version 0.1.0, a first one.** Every layer of the codec
works and the command does too, but its model is a first prototype and it
is slow (one thread, the Pascal reference code). The status of each layer,
and everything measured, is in [`doc/CODEC.md`](doc/CODEC.md).

The original comes back **byte for byte**, and nothing is written under an
output's name unless it verified: compressing decompresses the result and
compares it with the input before writing, and extracting checks the size
and the BLAKE3 hash stored in the `.ppa`. A file PPA cannot take, or does
not make smaller, is stored in the `.ppa` as it is.

The command is described in [`doc/CLI.md`](doc/CLI.md), the file in
[`doc/FORMAT.md`](doc/FORMAT.md).

## Against other compressors

One file at a time, against the two byte-exact recompressors of PNG:
[packPNG](https://github.com/YadeWira/packPNG) 2.0b (its default: preflate
and WebP-lossless) and [precomp](https://github.com/schnaader/precomp-cpp)
0.4.7 (preflate and LZMA), against `ppa` 0.1.0. Measured on 01/11/2026
([how][wComp]): each set's whole output against its input, every file
extracted and compared with the original; a file a tool does not take, or
that does not come back the same, would count at its own size (every tool
took and gave back every file).

| set | files | size | packPNG 2.0b | precomp 0.4.7 | PPA 0.1.0 |
|---|---|---|---|---|---|
| the PNG family of a sample corpus (PNG, APNG, MNG, JNG, CgBI) | 70 | 32.9 MB | 76.99% | 97.81% | **51.04%** |
| photos as PNG (decoded from JPEG, 1.3 to 2.9 MP) | 20 | 40.3 MB | 73.92% | 103.62% | **58.53%** |
| generated (zlib levels, filters and strategies, colour types, 16 bits, Adam7, optipng, oxipng) | 75 | 15.7 MB | 75.59% | 95.86% | **55.39%** |

And how fast, on the 20 photos (two Xeon E5-2697A v4, 64 threads, with
other work running). "8 at once": `ppa -th 8`; the others, 8 processes of
one file each. PPA and packPNG verify what they write.

| | packPNG 2.0b | precomp 0.4.7 | PPA 0.1.0 |
|---|---|---|---|
| compress, 1 thread | 79.6 s | **17.4 s** | 292.4 s |
| decompress, 1 thread | **8.7 s** | 11.7 s | 145.5 s |
| compress, 8 at once | 12.3 s | **2.6 s** | 50.7 s |
| decompress, 8 at once | **1.3 s** | 1.8 s | 24.6 s |

PPA is the smallest on every set, 20 to 34% smaller than packPNG, and by
far the slowest: its model codes every bit of every pixel, and a stream
zlib wrote at a high level takes, to rebuild, about what zlib took to write
it. Speed is its weak point in this first version.

## Against archivers

One archive per set, 8 threads, on 01/11/2026; every file extracted and
compared, and every one came back. Times are to write the archive / to
extract it. PPA has no 7-Zip or zpaq-std plugin yet: "PPA, then 7-Zip" is
the two in a row, `ppa a -th 8` on every file and then 7-Zip on the `.ppa`
files (and the reverse to extract).

| set | PPA, then 7-Zip | 7-Zip | zpaq-std 2.0.3 |
|---|---|---|---|
| corpus (70) | **38.39%**, 227.6 / 112.3 s | 84.36%, 2.9 / 0.5 s | 85.45%, 0.3 / 0.2 s |
| photos (20) | **58.54%**, 50.8 / 24.9 s | 99.11%, 3.7 / 0.9 s | 100.06%, 0.3 / 0.3 s |
| generated (75) | **25.65%**, 33.7 / 16.5 s | 70.70%, 1.1 / 0.2 s | 71.94%, 0.2 / 0.2 s |

In one archive the same pixels compress once: the corpus has the same
images in several files (a PNG and an MNG of the same photo, an animation
and its frames), and the generated set is five images written many ways,
whose `.ppa` files are nearly the same bytes.

## Building and tests

```sh
sh pas/build_c.sh build/c                                                   # the C part
fpc -O3 -dPPA_FAST -dPJA_FAST -Fupas -Fipas -Fuvendor/pja/pas -Fivendor/pja/pas -Fobuild/c -FUbuild -obuild/ppa pas/ppacli.pas   # the command
```

```sh
pas/run_tests.sh                                  # needs fpc 3.2.2, a C compiler and python3
PNG_CORPUS=dir1:dir2 pas/run_tests.sh             # plus the round trip over those directories
```

## License

MIT, see [LICENSE](LICENSE).

[ciBadge]: https://github.com/YadeWira/PPA/actions/workflows/ci.yml/badge.svg
[ciLink]: https://github.com/YadeWira/PPA/actions/workflows/ci.yml
[wComp]: https://github.com/YadeWira/PPA/wiki/Benchmarks
