# PPA

**packPNG Algorithm**: lossless recompression of the **PNG family** (PNG,
APNG, MNG, JNG), in FreePascal, with the hot loops in C; no libraries. The
successor of [packPNG](https://github.com/YadeWira/packPNG): a new codec
and format of its own (it does not read `.ppg` files), smaller and verified
before anything is written.

| Component | Status |
|---|---|
| CI | [![CI][ciBadge]][ciLink] |
| Latest release | [![Release][relBadge]][relLink] |

```sh
ppa a image.png          # -> image.ppa, about 40% smaller
ppa x image.ppa          # -> image.png, the same file byte for byte
```

The original comes back **byte for byte**, and nothing is written under an
output's name unless it verified: compressing decompresses the result and
compares it with the input before writing, and extracting checks the size
and the BLAKE3 hash stored in the `.ppa`.

The formats freeze at 0.9.0; until then a release may write a newer
format, but every `.ppa` and 7-Zip archive a published release wrote opens
in every later one ([doc/STABILITY.md](doc/STABILITY.md)).

PPA belongs to a family of recompressors that share that rule: the original
comes back byte for byte, and nothing is written unless it verified.

| Sibling | Formats | Successor of |
|---|---|---|
| [PMPA](https://github.com/YadeWira/PMPA) | MPEG audio (MP1, MP2, MP3) | [packMP3](https://github.com/YadeWira/packMP3), [packMP2](https://github.com/YadeWira/packMP2) |
| [PRA](https://github.com/YadeWira/PRA) | raster images (PNM, BMP, TIFF, PSD, HDR, ...) | [packPNM](https://github.com/packjpg/packPNM) |
| **PPA** | the PNG family (PNG, APNG, MNG, JNG) | [packPNG](https://github.com/YadeWira/packPNG) |
| [PAIA](https://github.com/YadeWira/PAIA) | animated images (GIF, WebP, FLI/FLC, ANI, ...) | (new) |
| [PJA](https://github.com/YadeWira/PJA) | JPEG, JPEG-LS and JPEG 2000 | [packJPG](https://github.com/YadeWira/packJPG) |

## What it handles

- **PNG**: every colour type and bit depth (1 to 16 bits, palette, alpha),
  Adam7, any line filters; each zlib stream rebuilt from zlib's own
  parameters (every level, strategy, window and memLevel), and its pixels
  coded by one of three models chosen image by image.
- **APNG**: every frame's stream, the same way.
- **MNG**: the PNG and JNG images it embeds.
- **JNG**: its JPEG through [PJA](https://github.com/YadeWira/PJA)'s codec.
- Odd files: Apple's **CgBI** PNG, wrong CRCs, a file cut short, bytes
  after the end; taken and given back as they are, what can be
  recompressed recompressed.

A deflate stream that zlib did not write (zopfli, libdeflate, advpng)
goes through as bytes for now, and so does anything else; `ppa info` says
what PPA does with a file ([details](doc/CODEC.md)).

## Install

Download the command for your platform from the [latest release][relLink]:
Linux (x86-64, x86, arm64; glibc 2.34 or later: Debian 12, Ubuntu 22.04,
RHEL 9 and newer), macOS (Apple silicon) or Windows (x64, and x86 from XP
on). Each build is tested by CI on its own platform, and a `.ppa` made on
one opens on any other.

```sh
ppa a *.png --output-dir=packed   # compress many
ppa x packed/*.ppa -o restored/   # and back
ppa list packed/*.ppa             # sizes and hashes
```

The command's manual is [doc/CLI.md](doc/CLI.md).

## Against other compressors

One file at a time, against the other recompressors that give a PNG back
byte for byte: [packPNG](https://github.com/YadeWira/packPNG) 2.0b (its
default: preflate and WebP-lossless) and
[precomp](https://github.com/schnaader/precomp-cpp) 0.4.7 (preflate and
LZMA). Each set's whole output against its input, every file extracted and
compared; a file a tool does not take would count at its own size (every
tool took every file).

| set | files | size | packPNG 2.0b | precomp 0.4.7 | PPA 0.1.1 |
|---|---|---|---|---|---|
| the PNG family of a sample corpus (PNG, APNG, MNG, JNG, CgBI) | 70 | 32.9 MB | 76.99% | 97.81% | **56.30%** |
| photos as PNG (1.3 to 2.9 MP) | 20 | 40.3 MB | 73.92% | 103.62% | **60.51%** |
| generated (zlib levels, filters and strategies, colour types, 16 bits, Adam7, optipng, oxipng) | 75 | 15.7 MB | 75.59% | 95.86% | **58.86%** |

Speed on the 20 photos (two Xeon E5-2697A v4; "8 at once": `ppa -th 8`,
the others 8 processes):

| | packPNG 2.0b | precomp 0.4.7 | PPA 0.1.1 |
|---|---|---|---|
| compress, 1 thread | 77.0 s | **17.3 s** | 32.6 s |
| decompress, 1 thread | **8.3 s** | 11.7 s | 15.1 s |
| compress, 8 at once | 12.3 s | **2.6 s** | 6.1 s |
| decompress, 8 at once | **1.3 s** | 2.0 s | 2.6 s |

PPA is the smallest on every set, 18 to 27% smaller than packPNG, and
compresses faster than it; it is slower to decompress (1.8 times on one
thread), as rebuilding zlib's choices costs about as much as packPNG's
whole decompression. One photo extracts in 0.31 s on 8 threads.
`ppa a --max` takes the slowest model for every image: 51.04%, 58.53% and
55.39% of the three sets (measured with a build before 0.1.1), about ten
times slower to extract.

## Safe by design

PPA's first rule is that the original comes back byte for byte, or nothing
is written. Measured against the other PNG recompressors on the same 20
files (15 to 266 KB, PNG, MNG, JNG and CgBI) with PJA's method, on
07/11/2026:

| | PPA 0.1.1 | packPNG 2.0l | precomp 0.4.7 |
|---|---|---|---|
| 4,000 single-bit flips in the compressed file: a wrong PNG given back without an error | **0** | 406 | 269 |
| stores a hash of the original | **yes** (BLAKE3) | no | no |
| checks its output before writing it, by default | **yes** | no (`-ver`) | no |
| fuzzed inputs taken that do not come back | **0** of 1,000 | 7 of 899 | 0 of 1,000 |
| disk full: a truncated file under the output's name | **no** (an old file is kept) | no (an old file is kept) | no, but an old file is lost |
| writes through a symbolic link at the output's name | **no** | no | yes |
| killed while writing: a partial file under the output's name | **no** | no | yes |
| written promise that its files keep opening | **yes** ([STABILITY](doc/STABILITY.md)) | within 2.0x | no |

Most of the others' wrong files are in files they keep as they are, where
nothing but a hash could see a flip (6 of 3,600 flips elsewhere for
packPNG, 69 of 3,800 for precomp); packPNG also aborted on 527 of the
flips. PPA's hash did that work in 204 of its 4,000. It is design, not
luck: a stored hash and size, a decode-and-compare before writing, a
temporary that takes the output's name only when it is complete and on the
disk (and is deleted on Ctrl-C), and a clean refusal of anything it does
not understand. What it does not do: repair a damaged `.ppa` (keep
backups, or use an archiver with recovery records) or authenticate it (the
hash catches accidents, not tampering).

## Against archivers

One archive per set, 8 threads; every file extracted and compared. Size,
then the time to write / extract. 7-Zip + PPA: 7-Zip 25.01 with PPA
0.1.1's plugin, `-m0=PPA -m1=LZMA2` (07/11/2026);
[Aqueous](https://github.com/lifthrasiir/aqueous) 0.0.20261101 at its
default level; 7-Zip and zpaq-std 2.0.3 without PPA for reference
(01/11/2026).

| set | 7-Zip + PPA | Aqueous | 7-Zip | zpaq-std |
|---|---|---|---|---|
| corpus (70) | **42.06%**, 72.1 / 33.2 s | 94.17%, 2.3 / 0.3 s | 84.36%, 2.9 / 0.5 s | 85.45%, 0.3 / 0.2 s |
| photos (20) | **60.51%**, 6.7 / 3.2 s | 81.42%, 1.3 / 0.4 s | 99.11%, 3.8 / 1.0 s | 100.06%, 0.3 / 0.3 s |
| generated (75) | **27.47%**, 17.2 / 7.1 s | 52.27%, 1.0 / 0.2 s | 70.70%, 1.2 / 0.2 s | 71.94%, 0.2 / 0.2 s |

7-Zip + PPA is the smallest on every set, by far where files repeat an
image (the corpus holds the same pictures in several files, the generated
set five images written many ways): in one solid block LZMA2 finds the
repeats PPA alone cannot. Aqueous is much faster and takes PNG too, but
leaves 1.3 to 2.2 times as much.

## In 7-Zip and zpaq-std

**7-Zip** and [7-Zip-zstd](https://github.com/mcmilk/7-Zip-zstd): put
`libppa`'s `ppa.dll` (or `ppa.so`; in each release, x64 for 64-bit 7-Zip,
x86 for 32-bit) in the `Codecs` folder next to 7-Zip, and

```sh
7z a -m0=PPA -m1=LZMA2 images.7z images/      # 7-Zip-zstd: -m1=zstd
```

(in 7-Zip's window: **Parameters** `0=PPA 1=LZMA2`). PPA goes first in the
chain as a filter: it recompresses the PNG, MNG and JNG files of the solid
block and passes every other byte on. Extracting needs the plugin too
(7-Zip 23 or later on Linux and macOS; [details](doc/LIBRARY.md)). The
same library is a C API (`ppa.h`) for any program.

**zpaq-std**: PPA's codecs with ZPAQL decoders, so that any zpaq extracts
the blocks, are being written.

## Reporting a bug

```sh
ppa report image.png -o report.txt   # what happened, on which machine
```

It writes a plain-text report (PPA's build, the system, the command line,
and the file's size, hash and structure, but no pixels, no metadata
contents and no folder names) and prints a link that opens a [new
issue][issues] with it filled in. `--with-file` puts a copy of the file
beside it, to attach if you choose to
([doc/CLI.md](doc/CLI.md#checking-and-reporting)). A bug ends a run with
exit status 3; `ppa selftest` checks a build on the samples inside it.

## More

The codec's notes and every measurement are in
[doc/CODEC.md](doc/CODEC.md), the file format in
[doc/FORMAT.md](doc/FORMAT.md), what does not change in
[doc/STABILITY.md](doc/STABILITY.md), the library and 7-Zip plugin in
[doc/LIBRARY.md](doc/LIBRARY.md), the test files in
[tests/README.md](tests/README.md). A wiki, as PJA's, is being written.

## Building

FreePascal 3.2.2, a C compiler (gcc or clang) and, for the tests, python3:

```sh
sh pas/build_c.sh build/c                          # the C part
fpc -O3 -dPPA_FAST -dPJA_FAST -Fupas -Fipas -Fuvendor/pja/pas -Fivendor/pja/pas \
    -Fobuild/c -FUbuild -obuild/ppa pas/ppacli.pas  # the command
pas/lib/build.sh build/lib                         # libppa
pas/run_tests.sh                                   # every test
```

## License

MIT, see `LICENSE`. A JNG's JPEG goes through PJA's codec, and zlib's
choices are ported from zlib; see `NOTICE` for those and other credits.

[ciBadge]: https://github.com/YadeWira/PPA/actions/workflows/ci.yml/badge.svg "Continuous Integration"
[ciLink]: https://github.com/YadeWira/PPA/actions/workflows/ci.yml
[relBadge]: https://img.shields.io/github/v/release/YadeWira/PPA "Latest release"
[relLink]: https://github.com/YadeWira/PPA/releases/latest
[issues]: https://github.com/YadeWira/PPA/issues
