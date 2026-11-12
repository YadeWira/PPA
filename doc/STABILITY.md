# What does not change

PPA's formats are **not frozen before 0.9.0** (Wira's decision of
07/11/2026, as PJA's). Until then a release may change what it writes.
What it may not do is stop reading what a published release wrote: every
`.ppa`, filter stream and 7-Zip archive a published PPA wrote is read by
every later release. A format change therefore comes with a new version
number in the format, and the reader keeps the old one.

From 0.9.0 every format below is fixed, as PJA's are from its 0.9.0.
1.0.0 is the release that brings a 7-Zip method ID of PPA's own, once
7-Zip gives one.

What may always change: speed, the encoder's choices (which model an image
takes, the bands, zlib's parameters it finds first), and the files PPA
takes (more, never fewer). For the same file a later release may write
other bytes, in a format every later release reads. A release that meets a
version it does not know refuses it cleanly, before decoding: "made by a
newer PPA" (`feFutureVersion`, `feFutureStream`; `PPA_E_VERSION` in the
library; "Unsupported Method" in 7-Zip), never reads it as something else.

## The `.ppa` file

`doc/FORMAT.md`. Magic `PPA\x01`, format version 1 (written since 0.1.0);
the stored flag; the descriptor with the original's size, BLAKE3-128 and
extension. A version past 1 is a newer PPA's.

## The codec stream

`doc/CODEC.md`, "Layer 6". Its first byte is its version:

| version | written by | read by | what changed |
|---|---|---|---|
| 1 | 0.1.0 | every release | the first: the structure, zlib's parameters, the three pixel models (slow, fast, static with 64 contexts), a JNG's JPEG through PJA's stream 7 |
| 2 | 0.1.1 | 0.1.1 and later | the static model's 320 contexts (the channel before's residual in five levels) |

`tests/ppa1/` holds `.ppa` files 0.1.0 wrote, one for each model, an APNG
and a JNG; `pas/tests/cli.sh` extracts them with every build, on the six
platforms: a published version stays readable. 0 is never written; a
version past the reader's own is refused as a newer PPA's. A JNG's JPEG
carries PJA's codec stream, whose versions PJA keeps (its
`doc/STABILITY.md`); one PPA's vendored PJA does not know is refused the
same way.

## The library and 7-Zip

`doc/LIBRARY.md`. The filter's stream, `PPAF` version 1: records 00 raw,
01 file (its size and its bare codec stream), FF end. Record tags 02 to FE
are left for later records: a decoder that meets one stops with
`PPA_E_VERSION`, as it does at a `PPAF` version past its own or at a file
record whose codec stream is of a later version.

The C interface in `pas/lib/ppa.h` keeps its functions and their meaning;
new functions may come, and new error codes: a caller treats a code it
does not know as an error.

7-Zip method: `PPA`, one stream, today under 7-Zip's experimental ID
`03 7F 11` (beside PJA's `03 7F 01` and `03 7F 02`). 1.0.0 brings an ID of
PPA's own; archives written with the experimental one keep opening in
every release after.

## The zpaq-std codecs

| codec | published | takes | stream | ZPAQL |
|---|---|---|---|---|
| `ppa1` | 0.2.0 | PNG, APNG, MNG whose every image is 8-bit gray, gray+alpha, RGB or RGBA (no JNG), up to 7 MiB of image a file | codec stream version 2, every image with the static model, the rest as bytes | `pas/plugin/ppa1zpaql.inc`, 19,264 bytes, `comp 0 0 $3 $4 0` |

`pas/plugin/VENDOR.md` has the rest (queries, `+rcmd`); every release
carries the sources as `ppa-<tag>-zpaqstd.tar.gz`. What `ppa1` takes and
writes may still change in the encoder (which images go as bytes, for
one), never in what its decoder reads.

PPA's codecs for zpaq-std carry versioned names: each name keeps its
index, its stream, what it takes and its ZPAQL decoder byte for byte from
the release that publishes it, whatever PPA's own formats do later (any
zpaq extracts a block through the decoder it carries). A new stream, or a
smaller or faster decoder for the same one, is a new codec. Names never end
in `z`, `o` or `8`, which zpaq-std's detection reads as other families'.
