# The `ppa` command

```
ppa a [options] FILE...     compress:  image.png -> image.ppa
ppa x [options] FILE...     extract:   image.ppa -> image.png (the original's extension)
ppa list FILE...            what each .ppa holds: original size, stored size, extension, hash
ppa t FILE...               test each .ppa: extract and verify in memory, write nothing
ppa info FILE...            the structure of each file, and what PPA does with it
ppa report [FILE]           a bug report (no pixels, no metadata) and a link to open an issue
ppa bench FILE...           how fast this machine runs a, a --no-verify and x on them
ppa selftest                the samples inside the binary, on both code paths
ppa --version, ppa -V       the build, the compilers, the system and the code path
```

The command is shaped as PJA's (0.9.7): the same commands, switches,
writes and exit statuses, so that a script for one works for the other.

| switch | what it does |
|---|---|
| `-o PATH` | output name with one input; a directory if it exists or ends in `/` |
| `--output-dir=DIR` | output directory, and nothing else |
| `-f`, `--force` | replace an existing output, only with something that verified |
| `-th N`, `--threads=N` | threads; by default the processors, up to 8. They go to files first, several at once, the largest first, and a file also takes for its image streams and bands (zlib's parameters searched when compressing, the bands decoded and the deflate streams rebuilt when extracting) as many of the free ones as its share of the bytes not yet started is of N, so that the last files take what the others left. Each file's lines still come out in the order of the inputs; the `.ppa` is the same bytes whatever the threads |
| `--max` | `a`: every image with the slow model (`ppamodel`): smaller still (a tenth on photographs, more on drawings), ten to forty times slower to extract. By default an image of 8-bit samples (gray, gray and alpha, RGB, RGBA) takes the static model, or where that loses much (drawings) the fast or the slow one, as a sample of the image shows; `x` needs no switch |
| `--no-verify` | `a`: do not decompress the stream to check it before writing. A codec bug would then only show when extracting, where the hash catches it; the `.ppa` is the same byte for byte |
| `--max-output=SIZE` | `x`, `t`: refuse a declared original above SIZE (`256M` by default, `K`/`M`/`G`, `0` = no limit) |
| `--keep-corrupt` | `x`: an output that does not verify stays as `NAME.corrupt` (`ppa.corrupt` beside it if that name would be too long) |
| `--no-sync` | `a`, `x`, `report`, `bench`: do not wait for each output to reach the disk before it takes its name. A few percent faster on a real disk (none on tmpfs), but after a power cut an output may be empty or missing ([below](#interrupted-runs)) |
| `--clean-temps` | `a`, `x`: delete the temporaries an interrupted run left in the directories this run writes to: only PPA's (`.ppa-tmp-PID-N`), only regular files, only older than an hour, and never one whose process is still running ([below](#interrupted-runs)) |
| `-n`, `--dry-run` | do everything but write: an output that exists, or that two inputs share, or (`x`) a `.ppa` whose size or hash does not match, fails as it would for real |
| `-q`, `--quiet` | only errors (`--stats` lines still come out, each under its file's name: they were asked for) |
| `--stats` | `a`, `x`, `t`: after each file, where its time went (below), its threads and (`a`) its bands; then a line for the run: files, bytes in and out, time, MB/s of the originals |
| `--json` | `a`, `x`, `t`, `info`, `list`: one JSON object a line for each file, in the order of the inputs, then `{"summary": ...}`; errors still go to stderr as well |
| `--path=PATH` | the hot loops in `c` (the default) or in `pascal`, the reference each C loop is checked against; before or after the command. Both write and read the same bytes, the Pascal one slower (`selftest` proves it; `selftest --path=PATH` checks that path alone). `PPA_NOC=1` in the environment does what `--path=pascal` does |
| `-o REPORT` | `report`: the file the report goes to (never over an existing one without `-f`) |
| `--with-file` | `report`: also copy the file beside the report as `ppa-report-NAME`, to attach if you choose to (without FILE it is refused: exit 2) |
| `-r N` | `bench`: runs of each measure, the best one counts (3 by default) |
| `--` | everything after it is a file, even if it starts with a dash |

All warnings and errors go to stderr.

| exit status | when |
|---|---|
| 0 | every file went through (`t`: every `.ppa` verified; `selftest`: every check passed) |
| 1 | a file failed: it is damaged, it could not be read or written (each with its line on stderr); the command's own output could not be written (a full disk, `ppa: could not write the output: ...`); `selftest`: a check failed |
| 2 | usage error: an unknown command or option, a value out of range, an option for another command |
| 3 | a bug in PPA: an exception that is not about the file or the system (a range check, an access violation; not a read or a write the system refused, nor memory it did not give), or `a`'s own check finding that the stream does not give the file back (the file is then stored in the `.ppa` as it is, whole). The run ends with `This is a bug in PPA. Please run: ppa report FILE and open an issue at https://github.com/YadeWira/PPA/issues` |
| 130, 143, 129, 141 | ended by SIGINT (Ctrl-C), SIGTERM, SIGHUP or SIGPIPE, after deleting the temporaries it was writing ([below](#interrupted-runs)); `STATUS_CONTROL_C_EXIT` on Windows |

A file that is not of the PNG family, or that the codec does not make
smaller, is not an error: `a` stores it in the `.ppa` as it is.

## Checking and reporting

These are for helping: telling what happened, on which machine, in a form
that can be pasted into an issue, and checking a build before trusting it.

### `ppa t FILE...`

What `x` does, without writing: the format, the declared size against
`--max-output`, decoding, then the size and the BLAKE3-128. A line
`NAME: OK` for each one that verifies, `ppa: NAME: FAILED: why` on stderr for
each that does not (exit 1). Takes `-th`, `-q`, `--max-output`, `--stats`
and `--json`; `-o`, `-f`, `-n` and `--keep-corrupt` are refused (exit 2).

### `ppa info FILE...`

The structure of each file, and what PPA does with it:

```
image.png
  format: APNG
  size: 19607
  chunk_count: 11
  chunks:
    - IHDR x1, 13 B
    - acTL x1, 8 B
    - fcTL x3, 78 B
    - IDAT x1, 6432 B
    - fdAT x4, 12.6 KB
    - IEND x1, 0 B
  metadata_bytes: 0
  image: 64 x 48, 8-bit RGB, 3 frame(s)
  image_stream_count: 3
  image_streams:
    - IDAT, 6432 B in 1 chunk(s), zlib 68de (maximum, 16 KB window)
    - fdAT, 6481 B in 2 chunk(s), zlib 68de (maximum, 16 KB window)
    - fdAT, 6439 B in 2 chunk(s), zlib 68de (maximum, 16 KB window)
  trailer_bytes: 0
  problems: (none)
  ppa: stores it as it is (the codec does not make it smaller): 19607 B -> 19647 B
```

- PNG, APNG, MNG, JNG and Apple's CgBI PNG: the chunks by type (how many
  and their bytes), the image's header (IHDR, acTL's frames, MHDR, JHDR),
  each image stream (IDAT, fdAT, JDAT, JDAA: its bytes, its chunks, its
  zlib header with the level it claims and its window, or JPEG), the bytes
  after the last chunk, and the problems (CRCs that do not match, bytes
  after the end, no IEND).
- A `.ppa`: its descriptor (format version, stored or not, original size,
  extension, BLAKE3-128), its payload, its stream's version and how many
  substreams it holds.
- `ppa:` what `a` does with it, by doing it in memory (a dry run, without
  the verification): which models its images take, how many streams go as
  bytes, and the size; or that it stores it as it is, and why. For a
  `.ppa`, whether `x` extracts and verifies it.

Metadata chunks (tEXt, zTXt, iTXt, iCCP, eXIf, tIME, caBX) are counted
and sized, never shown. A file that hits a bug while being described says
so (`internal_error`, exit 3) instead of ending the run.

### `ppa report [FILE] [-o REPORT.txt] [--with-file]`

A plain-text bug report, to stdout or to `-o`'s file:

- PPA: version, stream and format versions, commit, build date, FPC's
  version, the C compiler and the vector code of the C loops, the target;
  the system, the processor's name, the code path, the SIMD of PJA's JPEG
  model (a JNG's JPEG), the processors, the threads;
- the command line, each path cut to its name (an option's value too:
  `--output-dir=NAME`; a path after `--` that starts with a dash as well);
- for FILE: its BLAKE3-128, its structure and what PPA does with it, as
  `info` gives them, with `a`'s verification: a report needs the facts.
  Above 64 MB there is no dry run (`not estimated: the file is larger than
  64 MB`), only the structure.

**What is not in it**: no pixel, no metadata contents (only how many
bytes), no folder names.

Then a link that opens a new issue on GitHub with the report in it
(`https://github.com/YadeWira/PPA/issues/new?template=bug_report.yml&title=...&body=...`):
a report too long for a link (about 6000 characters) keeps its start (PPA,
the system, the command) and its end (the image streams, the problems,
what PPA does), with a line in their place saying how many lines were cut
and to paste the whole report; the line before the link says so too.
`--with-file` copies FILE beside the report as `ppa-report-NAME` (never
over an existing file): it goes nowhere unless you attach it; GitHub takes
a `.png`, anything else (`.mng`, `.jng`, `.ppa`) zipped. Without FILE, the
system part alone, for a problem with no file.

### `ppa bench FILE... [-r N] [-th N]`

Prints the system part of the report, then for each file the best of N
runs (3 by default) of `a`, `a --no-verify` and `x`, in milliseconds and
MB/s (2^20 bytes) of the original, with where `a`'s and `x`'s time went,
and the write of the `.ppa` alone; then the totals. Everything is in
memory but that write, which goes to a folder of its own in the system's
temporary folder and is deleted: nothing is written beside the inputs. A
`.ppa` given is only extracted.

### `ppa selftest`

The binary carries eleven small samples of `tests/png` (RGB, RGBA, gray, a
palette, 16 bits, Adam7, an APNG, an MNG, a JNG with and one without
alpha), some with a model forced so that the static, fast and slow models
all run (each too costly or too slow to be chosen on so small an image),
and the size and BLAKE3-128 of the `.ppa` each one has to give
(`pas/ppaselftest.inc`, written by `tools/gen_selftest.py`; the stream is
kept even where it is no smaller than the sample, so that it is what gets
compared). On both code paths (`c` and `pascal`), with one thread and with
two, each is compressed, compared with its expected `.ppa`, and extracted
back. `--path=PATH` checks that path alone. Exit 0 only if every check
passed. CI runs it on every platform.

The streams are not frozen before 1.0.0 (`FORMAT.md`): a change to one
changes some expected `.ppa`, `tools/gen_selftest.py` writes the include
again, and `pas/run_tests.sh` fails while it is not current.

### `ppa --version`

```
ppa 0.1.1
stream_version: 1
format_version: 1
commit: 1854965
built: 2026/11/07
fpc: 3.2.2
c_compiler: gcc 14.2.0
c_simd: sse2
target: x86_64-linux
system: Linux 6.12.115 x86_64
cpu: Intel(R) Xeon(R) CPU E5-2697A v4 @ 2.60GHz
code_path: c
jpeg_model_simd: sse4.1 avx2
processors: 64
default_threads: 8
```

The commit comes from `PPA_COMMIT` at build time (`.github/test.sh` sets
it from git); a build without it says `commit:` and nothing. `c_simd` is
the vector code the C loops were built with (`sse2`, NEON's vector types
on arm64, or plain C): every one gives the Pascal reference's bits.
`jpeg_model_simd` is what PJA's model takes for the JPEG inside a JNG, by
cpuid (`PJA_NOASM=1`, `PJA_NOAVX2=1` turn it off).

### `--stats`

```
image.png -> image.ppa  2.4 MB -> 1.5 MB  62.09%
  stats: read 0.85 ms, parse 1189.86 ms, encode 329.89 ms, verify 802.89 ms, hash 6.28 ms, write 8.68 ms; total 2338.45 ms; 1 thread(s), 2 band(s)
```

The stages: `read` the input; `parse` the file taken into chunks, each
image stream decoded and unfiltered, zlib's parameters found and the model
chosen (`a`); `encode` the pixels modelled; `verify` the stream decoded
again and compared with the input; `decode` the pixels decoded (`x`, `t`);
`rebuild` each image filtered and its deflate stream written again (most
of `x`); `hash` BLAKE3; `write` the output, verified, flushed to the disk
(unless `--no-sync`) and renamed; `other` what falls between. `threads`
are the file's own (what `-th` leaves each file), `bands` the bands `a`
cut its images into (each its own stream, coded and decoded in parallel).

### `--json`

One object a line, so that `python3 -c 'import json'` or `jq` read it
line by line:

```
{"file":"palette.png","output":"palette.ppa","original_size":609,"ppa_size":483,"ratio_percent":79.31,"stored":false,"ok":true}
{"summary":{"command":"a","files":1,"failed":0,"bugs":0,"bytes_in":609,"bytes_out":483,"seconds":0.18,"threads":8}}
```

| command | fields of each file (after `"file"`) |
|---|---|
| every one | `ok` (`true`: it went through; for `info`, it was read and described); `error` (what failed, as on stderr) when it did not; `internal_error` when it met a bug |
| `a` | `output`, `original_size`, `ppa_size`, `ratio_percent`, `stored`, and `why_stored` when it was |
| `x` | `output`, `original_size`, `ppa_size` |
| `t` | `original_size`, `ppa_size` |
| `list` | `original_size`, `ppa_size`, `ratio_percent`, `stored`, `extension`, `blake3_128` |
| `info` | the tree the text shows (`format`, `size`, `chunks`, `image`, `image_streams`, `problems`...; for a `.ppa`, its descriptor), then `ppa`: `command` (`a` or `x`), `ok`, `summary` (the line of the text), and for `a`: `takes`, `stored`, `ppa_size`, `ratio_percent`, `image_streams` (how many go each way), `bands`, or `error`; for `x`: `original_size` or `error` |
| `--stats` (`a`, `x`, `t`) | `stats`: each stage's `NAME_ms`, `total_ms`, `threads`, and `bands` for `a` |

The summary: `command`, `files`, `failed`, `bugs`, `bytes_in`, `bytes_out`,
`seconds`, `threads`.

## Nothing written that did not verify

- `a` writes the `.ppa` only after the codec has decompressed its own
  stream and compared it with the input (unless `--no-verify`). A file the
  codec does not take, or does not make smaller, is stored in the `.ppa`
  as it is.
- `x` does, in order: validate the format; refuse a declared size above
  `--max-output` **before** decoding; decode with that size as the cap;
  check the size **and** the hash; and only then write.
- Writing creates the file without following links, always as a temporary
  in the same directory (`.ppa-tmp-PID-N`) that takes the output's name
  only once it is complete **and on the disk** (`fsync`; `FlushFileBuffers`
  on Windows), and on Unix the directory is flushed after the name is
  given: after a power cut the output is either whole or not there, never
  empty or partial under its name. (Windows has no call to flush a
  directory: the name is left to the file system's journal.) If only that
  last flush fails, the run fails (rc 1) with `written, but its directory
  could not be flushed to the disk`: the output is in place and whole.
  Without `-f` the name is only taken if it is still free; with `-f` the
  temporary is renamed on top: what was there is only replaced by
  something that verified. Nothing that fails deletes a file this run did
  not write. (On a file system without hard links, such as FAT, it is
  written in place when there is no `-f`.)
- Two inputs of one run with the same output, or an output that is
  another input of the run, fail instead of overwriting each other.

The file layer is PJA's (`pas/ppafs.pas` is its `pjafs.pas`).

## Interrupted runs

- **Ctrl-C, `kill`, a closed terminal, a closed pipe**: SIGINT, SIGTERM,
  SIGHUP and SIGPIPE (`ppa x ... | head`; on Windows Ctrl-C, Ctrl-Break
  and closing the console) delete the temporaries the run is still
  writing, and it ends as the signal would have ended it (exit status 130
  for SIGINT, 143 for SIGTERM, 129 for SIGHUP, 141 for SIGPIPE;
  `STATUS_CONTROL_C_EXIT` on Windows). Outputs already written stay:
  each one verified. A signal ignored by whoever started `ppa` (`nohup`, a
  background job of a script) stays ignored.
- **`kill -9`, a crash, a power cut**: nothing can run then, so a
  `.ppa-tmp-PID-N` may stay. The next run that writes in that directory
  names them on stderr (`found 2 leftover temporaries of an interrupted
  run: ...; --clean-temps deletes them`), once per directory, and deletes
  nothing unless `--clean-temps` is given. Either way only names of PPA's
  own pattern count, only regular files (a link or a directory with that
  name is left alone), only older than an hour, and never one whose
  process (the PID in its name) is still running. With `-n` they are only
  named. The PID is checked in this machine's process table: in a
  directory shared with another machine or container (NFS, a bind mount)
  the hour of age is the only guard, so do not use `--clean-temps` there
  while another machine may be writing.
- **The flush beside the work**: each flush waits on the disk (about
  16 ms a file on a SATA SSD), so `a` and `x` hand each file's write,
  flush and rename to a thread of their own and go on with the next file;
  the file's line comes out once its write is done, in the same order,
  and the run ends only when every write has. At most 8 writes wait (their
  bytes in memory). Not with `--no-sync` (nothing to wait for), `-n`, or
  `--stats` (which times the write in the file's own stages);
  `PPA_SYNC_INLINE=1` writes in the file's own thread.

## For a program that calls the codec

`ppacodec.Compress(data, stream, why, stats, verify, threads)` and
`ppacodec.Decompress(stream, maxOut, data, why, threads)` take the threads
as a parameter (1 by default: everything in the calling thread); there is
no global for them, so two callers in two threads may each give their own.
The stream is the same bytes whatever the threads.
