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
| 2 | `ppainflate` | zlib stream ↔ the bytes it holds + what is needed to rebuild the exact deflate bits (our own preflate) | next |
| 3 | `ppapixels` | filtered scanlines ↔ pixels + each line's filter, interlaced or not | |
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

## Measurements

| date | what | result |
|---|---|---|
| 31/10/2026 | layer 1, `tests/png/` (14 synthetic files) | 14/14 back byte for byte |
| 31/10/2026 | layer 1, damaged variants of `tests/png/` | 64,568 variants, 0 failures, 9.6 s |
| 31/10/2026 | layer 1, the PNG family in the shared sample corpus (77 files: 47 PNG/APNG, 13 MNG, 13 JNG, 7 that are not of the family) | 70/70 back byte for byte, 7 NotPng |
