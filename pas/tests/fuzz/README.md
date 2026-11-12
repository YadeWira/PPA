# Coverage-guided fuzzing of the decoders

The safety measurement in the README fuzzed blindly (random mutations, no
sanitizer). This directory fuzzes what reads untrusted bytes with coverage
feedback and with the memory errors made to crash:

| target | engine | what it runs | checks |
|---|---|---|---|
| `filter_c` | libFuzzer | `pas/lib/ppafilter.c` alone, with a host of its own instead of the codec: PPAF decoding of any bytes, and encode + decode back of any bytes (which must come back) | ASan, UBSan, the round trip |
| `static_c` | libFuzzer | `pas/ppastaticc.c`'s rANS decoder (mode 2) alone: any bytes, widths, channel counts, stream versions, with tables that pass `DecodeImageStatic`'s checks | ASan, UBSan |
| `lib_ppa_rel` | libFuzzer | libppa's `ppa_decompress` on a `.ppa`; the release settings (`-O3 -dPPA_FAST -dPJA_FAST`) | ASan + UBSan on every C file (`pas/ppa*c.c`, PJA's C, the filter); `cmem`, so the Pascal heap is malloc's and ASan sees a C access past a Pascal array |
| `lib_ppa_chk` | libFuzzer | the same, `-O2 -Cr -Co` (range and overflow checks everywhere) | the same, and a check error |
| `lib_filter_rel` | libFuzzer | libppa's `ppa_filter_decode` on a PPAF stream | as `lib_ppa_rel` |
| `afl_ppa_rel` | AFL++, qemu mode | `fuzz_decode ppa`: `ppaformat.Unpack`, release settings | coverage of the Pascal too; `ppaguardheap` (an over-read past any heap block faults: exit 86) |
| `afl_ppa_chk` | AFL++, qemu mode | the same, `-O2 -Cr -Co` | and a check error |
| `afl_ppa_chk_noc` | AFL++, qemu mode | the same with `PPA_NOC=1`: the Pascal pixel loops instead of the C ones | |
| `afl_filter_chk` | AFL++, qemu mode | `fuzz_decode filter`: `ppafilter.c`'s decoder with each file through `DecompressEx` | |

Every Pascal build has `ppafuzzhook` first in its uses (`-Fa`): the decoder
catches every exception and calls it damage (`ppacodec.DecompressSafe`, the
library's exports, the filter's jobs), which is right for a user and hides
the exceptions that are bugs from a fuzzer. The hook sees each raise before
any handler: anything but the plain `Exception` the decoders raise on purpose
(`ppamodel`, `ppafast`, `ppastatic`) and `EOutOfMemory` prints its class,
message and backtrace and aborts. FreePascal has no sanitizers and no
coverage instrumentation: the libFuzzer targets are guided by the C alone,
the AFL++ ones see the whole program through qemu.

## Running

```sh
pas/tests/fuzz/run.sh build                  # in $FUZZ_DIR/bin (/mnt/IA_LAB/agentes/ppa/fuzz)
pas/tests/fuzz/run.sh seeds <png dir>...     # tests/png and those dirs as .ppa (each model), PPAF streams
pas/tests/fuzz/run.sh fuzz <target> <secs>   # one campaign; up to 4 at a time on this machine
pas/tests/fuzz/run.sh repro <target> <file>  # one input, with its report
```

What it needs: clang with compiler-rt (libFuzzer, ASan, UBSan), FreePascal,
and for the `afl_*` targets AFL++ with qemu mode, built without root:

```sh
git clone --depth 1 https://github.com/AFLplusplus/AFLplusplus $FUZZ_DIR/tools/aflpp
cd $FUZZ_DIR/tools/aflpp && LLVM_CONFIG=llvm-config-19 make source-only NO_NYX=1
python3 -m venv ../venv && ../venv/bin/pip install meson ninja
cd qemu_mode && PATH=$PWD/../../venv/bin:$PATH ./build_qemu_support.sh
```

An ASan target runs with `-rss_limit_mb=2048 -malloc_limit_mb=1024`, inside
a `systemd-run --user --scope -p MemoryMax=3G` when there is one; an AFL
target under `ulimit -v 6000000`. A finding is in `out/<target>/crashes/`
(libFuzzer) or `out/<target>/afl/default/{crashes,hangs}/` (AFL++).

Speed: an image costs what its model costs. The slow model's tables are
about 130 MB, set up for every image however small (0.1 s natively, 1 s or
more in qemu), so `seeds` puts the seeds that take over 20 ms aside
(`seeds/ppa_slow`), but for the smallest two and the samples of `tests/png`.

## Disk full on ext4

`diskfull_ext4.sh <ppa> <png>`: an ext4 image (`mkfs.ext4`) mounted with
`fuse2fs` (no root: e2fsprogs built with `--enable-fuse2fs`, against
libfuse3's headers from `apt-get download libfuse3-dev`), filled to leave
0, a block, 10, 50, 90 and 99% of the output's size; `ppa a` and `ppa x`,
with and without `--no-sync`, without and with an old file under the
output's name (`-f`). Each case must end in an error with nothing under the
output's name (or the old file, whole), no temporary left, and a clean
`e2fsck -fn`.
