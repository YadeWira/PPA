# PPA

**packPNG Algorithm**: lossless recompression of the **PNG family** (PNG, APNG, MNG, JNG), in
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

**Work in progress: version 0.1.0, no release yet.** Every layer of the
codec works and the command does too, with three models for the pixels
chosen image by image (a static one for photographs, quick to extract; an
adaptive one; the slowest and smallest, which `--max` takes for every
image). The status of each layer, and everything measured, is in
[`doc/CODEC.md`](doc/CODEC.md).

**The formats are not frozen before 1.0.0**: until then the stream and the
`.ppa` may change without a promise of compatibility, and a file made with
a 0.x version may not open in a later one. From 1.0.0 on, what is
published is read forever.

The original comes back **byte for byte**, and nothing is written under an
output's name unless it verified: compressing decompresses the result and
compares it with the input before writing, and extracting checks the size
and the BLAKE3 hash stored in the `.ppa`. A file PPA cannot take, or does
not make smaller, is stored in the `.ppa` as it is.

The command is described in [`doc/CLI.md`](doc/CLI.md), the file in
[`doc/FORMAT.md`](doc/FORMAT.md).

PPA belongs to a family of recompressors that share that rule: the original
comes back byte for byte, and nothing is written unless it verified.

| Sibling | Formats | Successor of |
|---|---|---|
| [PMPA](https://github.com/YadeWira/PMPA) | MPEG audio (MP1, MP2, MP3) | [packMP3](https://github.com/YadeWira/packMP3), [packMP2](https://github.com/YadeWira/packMP2) |
| [PRA](https://github.com/YadeWira/PRA) | raster images (PNM, BMP, TIFF, PSD, HDR, ...) | [packPNM](https://github.com/packjpg/packPNM) |
| **PPA** | the PNG family (PNG, APNG, MNG, JNG) | [packPNG](https://github.com/YadeWira/packPNG) |
| [PAIA](https://github.com/YadeWira/PAIA) | animated images (GIF, WebP, FLI/FLC, ANI, ...) | (new) |
| [PJA](https://github.com/YadeWira/PJA) | JPEG and JPEG-LS | [packJPG](https://github.com/YadeWira/packJPG) |

## Against other compressors

One file at a time, against the two byte-exact recompressors of PNG:
[packPNG](https://github.com/YadeWira/packPNG) 2.0b (its default: preflate
and WebP-lossless) and [precomp](https://github.com/schnaader/precomp-cpp)
0.4.7 (preflate and LZMA), against `ppa` 0.1.0 (commit bb5add8). Measured on 01/11/2026
([how][wComp]): each set's whole output against its input, every file
extracted and compared with the original; a file a tool does not take, or
that does not come back the same, would count at its own size (every tool
took and gave back every file).

| set | files | size | packPNG 2.0b | precomp 0.4.7 | PPA 0.1.0 |
|---|---|---|---|---|---|
| the PNG family of a sample corpus (PNG, APNG, MNG, JNG, CgBI) | 70 | 32.9 MB | 76.99% | 97.81% | **56.79%** |
| photos as PNG (decoded from JPEG, 1.3 to 2.9 MP) | 20 | 40.3 MB | 73.92% | 103.62% | **62.29%** |
| generated (zlib levels, filters and strategies, colour types, 16 bits, Adam7, optipng, oxipng) | 75 | 15.7 MB | 75.59% | 95.86% | **61.91%** |

And how fast, on the 20 photos (two Xeon E5-2697A v4, 64 threads, with
other work running). "8 at once": `ppa -th 8`; the others, 8 processes of
one file each. PPA and packPNG verify what they write.

| | packPNG 2.0b | precomp 0.4.7 | PPA 0.1.0 |
|---|---|---|---|
| compress, 1 thread | 77.0 s | **17.3 s** | 43.7 s |
| decompress, 1 thread | **8.3 s** | 11.7 s | 14.3 s |
| compress, 8 at once | 12.3 s | **2.6 s** | 6.7 s |
| decompress, 8 at once | **1.3 s** | 2.0 s | 2.4 s |

PPA is the smallest on every set, 16 to 26% smaller than packPNG, and
compresses faster than it, but is still slower to decompress (1.7 times
with one thread): rebuilding zlib's own choices for the deflate stream
costs about as much as packPNG's whole decompression. A photograph takes
PPA's static model (a table lookup a sample); a drawing, where that model
loses much, its adaptive ones. `ppa a --max` takes the slowest and
smallest model for every image (51.04%, 58.53% and 55.39% of the three
sets, measured with commit 35e55e5) and extracts about ten times slower.

## Against archivers

One archive per set, 8 threads, on 01/11/2026; every file extracted and
compared, and every one came back. Times are to write the archive / to
extract it. PPA has no 7-Zip or zpaq-std plugin yet: "PPA, then 7-Zip" is
the two in a row, `ppa a -th 8` on every file and then 7-Zip on the `.ppa`
files (and the reverse to extract). [aqueous](https://github.com/lifthrasiir/aqueous)'s
`aqr` (its release of 01/11/2026, its default level `mid`) recompresses
PNG itself.

| set | PPA, then 7-Zip | 7-Zip | zpaq-std 2.0.3 | aqueous 0.0.20261101 |
|---|---|---|---|---|
| corpus (70) | **42.43%**, 84.7 / 34.3 s | 84.36%, 2.9 / 0.5 s | 85.45%, 0.3 / 0.2 s | 94.17%, 2.3 / 0.3 s |
| photos (20) | **62.30%**, 8.9 / 2.5 s | 99.11%, 3.8 / 1.0 s | 100.06%, 0.3 / 0.3 s | 81.42%, 1.3 / 0.4 s |
| generated (75) | **27.97%**, 18.3 / 7.1 s | 70.70%, 1.2 / 0.2 s | 71.94%, 0.2 / 0.2 s | 52.27%, 1.0 / 0.2 s |

In one archive the same pixels compress once: the corpus has the same
images in several files (a PNG and an MNG of the same photo, an animation
and its frames), and the generated set is five images written many ways,
whose `.ppa` files are nearly the same bytes.

## Something went wrong?

```sh
ppa report image.png     # a bug report (no pixels, no metadata, no folders) and a link that opens the issue
ppa selftest             # the samples inside the binary, compressed and extracted on both code paths
ppa info image.png       # the file's chunks and image streams, and what PPA does with it
ppa t image.ppa          # extract and verify, write nothing
```

A bug in PPA ends the run with exit status 3 and says to run `ppa report`.
Outputs reach the disk before they take their names, and Ctrl-C or a kill
leaves no half-written file behind ([`doc/CLI.md`](doc/CLI.md)).

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
