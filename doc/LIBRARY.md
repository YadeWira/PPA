# libppa: PPA as a library and a 7-Zip plugin

`libppa` is one shared object (`ppa.so`, `ppa.dll`, `ppa.dylib`) that does
two jobs, as PJA's `libpja` does (its shape, its code where the format does
not differ):

- a **C library** (`pas/lib/ppa.h`) for any program: one file in memory to
  a `.ppa` and back, and a **filter** over a stream of any bytes;
- a **codec plugin for 7-Zip and 7-Zip-zstd**, the method `PPA`, which is
  that filter.

PPA's formats are not frozen before 1.0.0 (`FORMAT.md`): a `.ppa`, a filter
stream or a 7-Zip archive written with a 0.x release may not open in a
later one, which then says so (`PPA_E_VERSION`, 7-Zip's "Unsupported
Method") where it can; what a published release wrote is read by the
later ones.

It is built from `pas/lib/`: `ppalib.pas` (the library, its exports and
PPA's codec), `ppafilter.c` (the filter), `ppa7z.c` (7-Zip's interfaces),
plus PPA's C part (`pas/build_c.sh`, which builds PJA's for a JNG's JPEG
too):

```sh
pas/lib/build.sh build/lib                                   # Linux: ppa.so
CC=x86_64-w64-mingw32-gcc FPC="fpc -Twin64 -Px86_64" pas/lib/build.sh build/w64   # ppa.dll
```

## The filter

An archiver that puts many files into one stream (7-Zip's solid blocks)
cannot hand PPA one file at a time. The filter takes the stream as it is,
finds the PNG, MNG and JNG files inside it, recompresses each one with
PPA's codec (verified: it must come back byte for byte), and passes
**every other byte through untouched**, so that the archiver's own
compressor (LZMA2, zstd) still sees them and finds what repeats across
files:

```
solid block ──► PPA filter ──► [ raw bytes | PNG as PPA | raw bytes | ... ] ──► LZMA2 ──► archive
```

### How it finds a file

By its signature (`89 PNG`, `8A MNG` or `8B JNG`, then `0D 0A 1A 0A`), then
by walking its chunks (a length, a type of four letters, the data, a CRC)
to its end chunk: `IEND` for PNG and JNG, `MEND` for MNG (whose embedded
PNGs' `IEND`s are inside). The first chunk must be the file's header
(`IHDR`, or Apple's `CgBI` before it; `MHDR`; `JHDR`). A file whose chunks do
not add up, that PPA does not take, that does not come back, or that does
not get smaller stays among the raw bytes, and so do the bytes after its
end chunk and anything past 256 MiB.

### The stream

```
"PPAF" 01                 magic and version
records, each a tag byte:
  00 n bytes              n raw bytes (n a LEB128 number, 1 to 256 KiB)
  01 size n stream        a file of `size` bytes as PPA's codec stream of n bytes
                          (ppacodec.Compress; 0 < n < size <= 256 MiB)
  FF                      the end
```

Tags 02 to FE are left for records of later releases: a decoder that meets
one stops with `PPA_E_VERSION`, as it does at a filter version past its
own or a file record whose codec stream is of a later version. Raw bytes go
out in records of 256 KiB counted from the end of the last file written,
so the stream is the same however the input was read, and whatever the
threads.

### Threads

Files go to a pool of threads as the filter finds them, up to eight per
thread (or 64 MiB) ahead of the oldest, which is written as soon as it is
done; so reading, compressing and writing overlap, and extracting works the
same way. A file alone gets the threads for its images. None of this
changes the stream.

## The C interface

`pas/lib/ppa.h`. Every function can be called from several threads at once,
and no exception leaves the library: errors are return codes.

| function | does |
|---|---|
| `ppa_version()` | `"ppa 0.1.1"` |
| `ppa_compress(in, size, &out, &out_size, threads)` | a file of the PNG family → a `.ppa` (the command's format: size and BLAKE3 hash inside; no extension kept); `PPA_E_NOT_TAKEN` for a file PPA does not take or does not make smaller |
| `ppa_decompress(in, size, &out, &out_size, max_size, threads)` | a `.ppa` → the original, checked against its size and hash; `PPA_E_VERSION` for one a newer PPA wrote |
| `ppa_filter_encode(read, ctx, write, ctx, threads)` | the filter: every byte read → its stream, written |
| `ppa_filter_decode(read, ctx, write, ctx, threads)` | its stream → the bytes |
| `ppa_free(p)` | frees what the library returned (never `free()`) |

Return codes: `PPA_OK` (0), `PPA_E_NOT_TAKEN` (1), `PPA_E_DATA` (2:
damaged, or not PPA's), `PPA_E_MEMORY` (3: out of memory or over a size
limit), `PPA_E_READ` (4) and `PPA_E_WRITE` (5: the filter's callbacks),
`PPA_E_ARG` (6), and `PPA_E_VERSION` (7): the input was written by a newer
PPA, a `.ppa` format version, a codec stream version (or a JNG's JPEG
stream of a newer PJA), a filter version or record this release does not
know. Those bytes can also be damaged, and nothing tells the two apart
there (a `.ppa`'s hash covers the original, checked after its stream is
decoded): damage that makes a codec stream's first byte 3 to 255 gives
`PPA_E_VERSION` as well; damage anywhere else gives `PPA_E_DATA`. More codes
may come; a caller treats one it does not know as an error.

`threads` is 1 to 64 (outside that, the nearest). `max_size` caps the
original's size (0: the library's own cap, 2^31); it does not cap the
memory a decode takes on the way: each image's pixels (up to 1 GiB, and
2 GiB for all of a file's together) and the slow model's tables (about
140 MB a band). A 32-bit host has less room than that.

The settings the `ppa` command's tests read from the environment
(`PPA_TEST_*`, `PPA_NOC`) are put back to their defaults when the library
loads: a host's environment does not change its streams (CI runs the test
with them set). PJA's own (`PJA_NOASM`, `PJA_NOAVX2`, `PJA_BANDS_REVERSE`)
still apply to a JNG's JPEG; they change the speed only.

`pas/lib/test_lib.c` is the test, and an example: each file through
`ppa_compress`/`ppa_decompress` (the same bytes on one thread and two),
four threads compressing at once and forty short-lived ones (the same
bytes), all the files in one stream with bytes and false signatures
between them through the filter, read 1 byte to 1 MiB at a time (the same
stream every time, and on one thread), damaged and cut filter streams, and
what a newer PPA would write (a `.ppa` of format version 2, codec streams
of versions 3 to 255, `PPAF` 02, records 02 to FE, a file record of a later
codec stream): `PPA_E_VERSION` every time.

## The 7-Zip plugin

Put the library in the `Codecs` folder next to 7-Zip: `7z.exe` on Windows
(7-Zip or 7-Zip-zstd), `7z` and `7z.so` on Linux. The library's build must
be 7-Zip's: the x64 `ppa.dll` for 64-bit 7-Zip, the x86 one for 32-bit
7-Zip. `7z i` lists the method:

```
 1  ED     37F11 PPA
```

```sh
7z a -m0=PPA -m1=LZMA2 images.7z images/        # 7-Zip
7z a -m0=PPA -m1=zstd  images.7z images/        # 7-Zip-zstd
7z x images.7z
```

A stream a newer PPA wrote (`PPA_E_VERSION`) comes out of the plugin as
`E_NOTIMPL`, which 7-Zip reports as "Unsupported Method" for the block's
files, and damaged data as "Data Error".

`-mmt` sets the filter's threads when compressing; extracting, 7-Zip
gives its thread count only to the first coder of the chain that takes one
(LZMA2), so PPA uses the processors (up to 8; 2 in a 32-bit 7-Zip, whose
memory the slow model's tables would fill). **The archive needs the
plugin to be extracted**, in every 7-Zip that opens it. It works with
7-Zip on Windows and with 7-Zip 23 or later on Linux and macOS; p7zip (the
old port, `7z` 16.02) builds its interfaces differently and does not load
it.

Measured on 07/11/2026 with 7-Zip 25.01 on Linux (`-m0=PPA -m1=LZMA2
-mmt=8`, one archive per set, every file extracted and compared): the
archive against the input, and the times to write it and to extract it.

| set | files | 7-Zip + PPA | 7-Zip alone | `ppa` alone |
|---|---|---|---|---|
| photos | 20 | **60.51%**, 6.7 / 3.2 s | 99.11% | 60.51% |
| corpus of the PNG family | 70 | **42.06%**, 72.1 / 33.2 s | 84.36% | 56.30% |
| generated | 75 | **27.47%**, 17.2 / 7.1 s | 70.70% | 58.86% |

Where files repeat an image (the corpus holds the same pictures in several
files, the generated set five images written many ways), 7-Zip after PPA
finds the repeats PPA alone cannot.

The method ID, `03 7F 11`, is in the slot 7-Zip's `DOC/Methods.txt` keeps
for an experimental method, beside PJA's `03 7F 01` and `03 7F 02`, so
that both plugins can sit in the same `Codecs` folder; PPA will move to an
ID of its own with 1.0.0 (the family asks 7-Zip for one) and stay able to
read this one.

On Windows the library takes its memory from the process heap
(`pas/ppaheap.pas`, PJA's `pjaheap.pas`), not FreePascal's own:
FreePascal 3.2.2's heap, in a DLL, deletes its lock when the thread that
loaded the DLL ends, and 7-Zip's file manager loads its codecs from such a
short-lived thread (PJA found it, crashing in 7zFM). With the memory gone
it returns nil, never a runtime error, so a host gets `PPA_E_MEMORY`.

PJA's codec (a JNG's JPEG) keeps its models (about 18 MB) in threadvars,
which FreePascal does not free when a thread of the host ends: every call
gives them back before returning, and so do the filter's threads.

How it is made: 7-Zip's interfaces are C++ classes with only virtual
methods, which is a table of function pointers at the start of the object,
so `ppa7z.c` builds them in plain C (`__stdcall` on 32-bit Windows). The
library exports `GetNumberOfMethods`, `GetMethodProperty`,
`CreateDecoder`, `CreateEncoder`, `CreateObject` and `GetModuleProp`
(which tells 7-Zip on Linux, since version 23, that `IUnknown` has no
virtual destructor, and gives the module's version, PPA's: 0.11 for 0.1.1).
Strings handed to 7-Zip are BSTRs of `wchar_t`: OLE's on Windows, 7-Zip's
own layout from `malloc` elsewhere. CI builds the library on all six
platforms, runs `test_lib`, and on Linux and Windows x64 writes an archive
of every sample through a real 7-Zip and extracts it.
