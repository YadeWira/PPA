# PPA format

**A `.ppa` is ONE compressed file**: a PNG, APNG, MNG or JNG file, as the
codec stream (`doc/CODEC.md`), together with the size, hash and extension of
the original. It follows PJA's `.pja` closely; dispatch is by magic, not by
extension.

| | why |
|---|---|
| **BLAKE3-128 hash of the original** | A damaged stream can decode to **another valid file** without any error. The hash gives it away. |
| **declared original size** | Allows rejecting a bomb **before decoding**. It is also the decoder's cap: the output cannot exceed it. |
| **the original's extension** | So that `image.PNG` comes back as `image.PNG`. Only the extension: the name is the `.ppa`'s own. With a check of its own, since the hash covers the content only. |

The codec verifies its own stream when compressing (it decompresses it and
compares), so what the hash protects against is damage **after** writing.
No encryption.

**Not frozen before 0.9.0** (as PJA's): until then this layout and
the codec stream may change, each change with a new version number, and
what a published release wrote is still read by every later one (a later
release's file may not open in an earlier one, which says so). From 0.9.0
on the formats are fixed. `doc/STABILITY.md` lists the versions.

## Layout

```
HEADER - 8 B
  magic        4 B   "PPA\x01"
  version      1 B   1
  flags        1 B   bit 0: stored (the payload is the original itself); the rest 0
  reserved     2 B   0

DESCRIPTOR - 29 B and the extension
  orig_size    u64 LE   the original's length
  hash         16 B     BLAKE3-128 of the original
  ext_len      1 B      0 to 15
  ext          ext_len  the original's extension, without the dot, as written:
                        letters, digits, '_' and '-' only
  ext_check    4 B LE   the first 4 bytes of BLAKE3 of ext_len and ext

PAYLOAD - the rest: the codec stream, or with the stored flag the original
```

A file the codec does not take (not of the family) or does not make
smaller is stored as it is: 37 bytes more than the original, and its
extension. Then `orig_size` has to be the payload's length exactly.

The hash is BLAKE3 truncated to 128 bits, in Pascal (`pas/ppablake3.pas`,
PJA's), checked against the official vectors (`pas/tests/kat.txt`).

## Limits

| rule | value | why |
|---|---|---|
| `orig_size` >= 1 | | an empty file is not packed |
| `orig_size` <= 2^63 - 1 | | |
| stored: `orig_size` = payload, payload >= 1 B | | a stored file cannot claim another size |
| codec stream: payload >= 5 B | the version byte and the coder's 4 | no impossible payload |
| `orig_size` <= 65,536 x payload | checked by division | rejects before decoding (a last-resort cap, as PJA's) |
| `orig_size` <= `--max-output` | 256 MB by default; 0 = none | the user's ceiling, before decoding |

Inside the codec, each image is capped before it is decoded: an image
stream of L bytes holds at most about 1,100 L bytes (deflate expands at
most 1,032 times).

**The writer applies the same rules as the reader, with the same
function**: what is written can be opened. A codec stream the reader would
refuse is not written; the file is stored instead.

## Order of operations on extract (`ppaformat.Unpack`)

1. the header: magic, version, flags, reserved bytes
2. the descriptor: sizes against the limits, the extension and its check
3. `orig_size` against the user's cap
4. decode, with `orig_size` as the cap
5. the result must be `orig_size` bytes long and have the declared hash
6. only then is it written, to a temporary name renamed into place

Tests: `test_format` (every sample round trip; every bit of the header,
descriptor and first payload bytes flipped, a sample of the rest, cuts: an
error or exactly the original, never another file; each header case) and
`pas/tests/cli.sh`.
