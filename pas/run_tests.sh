#!/bin/bash
# The codec test suite (doc/CODEC.md), layer by layer.
#
#   pas/run_tests.sh                          what is in the repo
#   PNG_CORPUS=dir1:dir2 pas/run_tests.sh     plus the round trip over those directories
#   PREFLATE_CORPUS=dir pas/run_tests.sh      ppapreflate on the preflate corpus (tools/preflate):
#                                             default /mnt/IA_LAB/agentes/ppa/preflate/corpus when there
#
# Each test demands its own minimum count: one that runs zero cells is not green.
set -euo pipefail
FPC=${FPC:-fpc}
PAS=$(cd "$(dirname "$0")" && pwd); PPA=$(dirname "$PAS"); OUT=${PAS_OUT:-$PAS/build/tests}
mkdir -p "$OUT" "$OUT/cli"

echo "== source guards"
python3 "$PAS/collisions.py" "$PAS"
# the 7-Zip plugin's module version is the command's (0.2.1 -> 0.21)
V=$(sed -n "s/^  VERSION = '\(.*\)';/\1/p" "$PAS/ppasysinfo.pas")
MV=$(echo "$V" | awk -F. '{print $2*10+$3}'); MM=$(echo "$V" | cut -d. -f1)
grep -q "(${MM}u << 16) | ${MV}u;" "$PAS/lib/ppa7z.c" || { echo "FAIL: ppa7z.c's module version is not $V"; exit 1; }

echo "== build"
# the C part (CC: the platform's C compiler)
sh "$PAS/build_c.sh" "$OUT/c"
for prog in test_png test_png_corrupt test_deflate test_deflate_corrupt test_zlib test_preflate test_pixels test_arith measure_model measure_fast measure_static test_blake3 test_codec test_format; do
  $FPC -O2 -g -gl -Fu"$PAS" -Fi"$PAS" -Fu"$PPA/vendor/pja/pas" -Fi"$PPA/vendor/pja/pas" -Fo"$OUT/c" -FU"$OUT" -FE"$OUT" "$PAS/tests/$prog.pas" > "$OUT/fpc.log" 2>&1 \
    || { cat "$OUT/fpc.log"; exit 1; }
done

echo "== layer 1: file <-> chunks and image streams"
"$OUT/test_png" "$PPA/tests/png" 14 | tail -1
# every bit of the first 512 bytes and every cut: no exception, the same bytes back
"$OUT/test_png_corrupt" "$PPA/tests/png" 512 | tail -1
IFS=: read -ra dirs <<< "${PNG_CORPUS:-}"
for d in "${dirs[@]}"; do "$OUT/test_png" "$d" 1 | tail -1; done

echo "== layer 2a: zlib stream <-> its bytes and its encoder's choices"
"$OUT/test_deflate" "$PPA/tests/png" 16 | tail -1
PPA_NOC=1 "$OUT/test_deflate" "$PPA/tests/png" 16 | tail -1
# what it decodes are the bytes zlib decodes
rm -rf "$OUT/zdump"; mkdir -p "$OUT/zdump"
"$OUT/test_deflate" "$PPA/tests/png" 1 -dump "$OUT/zdump" > "$OUT/zdump/list"
python3 "$PPA/tests/zcheck.py" "$OUT/zdump"
# every bit of the first 256 bytes of each stream and every cut: decoded or not, never different
"$OUT/test_deflate_corrupt" "$PPA/tests/png" 256 | tail -1
for d in "${dirs[@]}"; do
  "$OUT/test_deflate" "$d" 1 | tail -1
  rm -rf "$OUT/zdump"; mkdir -p "$OUT/zdump"
  "$OUT/test_deflate" "$d" 1 -dump "$OUT/zdump" > "$OUT/zdump/list"
  python3 "$PPA/tests/zcheck.py" "$OUT/zdump"
done

echo "== layer 2b: zlib's choices predicted"
"$OUT/test_zlib" "$PPA/tests/png" | tail -1
"$OUT/test_zlib" "$PPA/tests/png" | grep -q '16 told by their zlib parameters'

echo "== layer 2: one deflate stream <-> its bytes and its recipe (ppapreflate)"
# every stream kind 0 and back the same (on 1 and 4 threads), Compress's
# maxVersion, and the crafted streams and damaged recipes
"$OUT/test_preflate" "$PPA/tests/png" 16 -all0 -codec | tail -1
PPA_NOC=1 "$OUT/test_preflate" "$PPA/tests/png" 16 -all0 | tail -1
PF_CORPUS=${PREFLATE_CORPUS-/mnt/IA_LAB/agentes/ppa/preflate/corpus}
if [ -d "$PF_CORPUS/png-zlib" ]; then
  # the regression set: all 392 streams kind 0; zlib does not write the 24 others
  "$OUT/test_preflate" "$PF_CORPUS/png-zlib" 392 -all0 | tail -1
  "$OUT/test_preflate" "$PF_CORPUS/png-nonzlib" 24 -none0 | tail -1
fi

echo "== layer 3: filtered lines <-> each line's filter and the image's bytes"
"$OUT/test_pixels" "$PPA/tests/png" 16 | tail -1
PPA_NOC=1 "$OUT/test_pixels" "$PPA/tests/png" 16 | tail -1
# what it unfilters are the pixels ImageMagick decodes
rm -rf "$OUT/pxdump"; mkdir -p "$OUT/pxdump"
"$OUT/test_pixels" "$PPA/tests/png" 1 -dump "$OUT/pxdump" > "$OUT/pxdump/list"
python3 "$PPA/tests/pxcheck.py" "$OUT/pxdump"
for d in "${dirs[@]}"; do
  "$OUT/test_pixels" "$d" 1 | tail -1
  rm -rf "$OUT/pxdump"; mkdir -p "$OUT/pxdump"
  "$OUT/test_pixels" "$d" 1 -dump "$OUT/pxdump" > "$OUT/pxdump/list"
  python3 "$PPA/tests/pxcheck.py" "$OUT/pxdump"
done

echo "== layer 4: arithmetic coder"
"$OUT/test_arith" | tail -1

echo "== layer 5: the model (every image coded and decoded back)"
"$OUT/measure_model" "$PPA/tests/png" | tail -1 | tee "$OUT/model_c.txt"
# the Pascal pixel loop gives the same streams as the C one
PPA_NOC=1 "$OUT/measure_model" "$PPA/tests/png" | tail -1 > "$OUT/model_pas.txt"
[ "$(sed 's/, [0-9.]* s,/,/' "$OUT/model_c.txt")" = "$(sed 's/, [0-9.]* s,/,/' "$OUT/model_pas.txt")" ] \
  || { echo "FAIL: the C and Pascal pixel loops give different streams"; cat "$OUT/model_pas.txt"; exit 1; }
# the fast model (ppafast): every 8-bit image back, the same streams from C and Pascal
"$OUT/measure_fast" "$PPA/tests/png" | tail -1 | tee "$OUT/fast_c.txt"
PPA_NOC=1 "$OUT/measure_fast" "$PPA/tests/png" | tail -1 > "$OUT/fast_pas.txt"
[ "$(sed 's/, encode .*, \([0-9]* failures\)/, \1/' "$OUT/fast_c.txt")" = "$(sed 's/, encode .*, \([0-9]* failures\)/, \1/' "$OUT/fast_pas.txt")" ] \
  || { echo "FAIL: the C and Pascal fast models give different streams"; cat "$OUT/fast_pas.txt"; exit 1; }
for d in "${dirs[@]}"; do "$OUT/measure_fast" "$d" | tail -1; done
# the static model (ppastatic): the same, C and Pascal
"$OUT/measure_static" "$PPA/tests/png" | tail -1 | tee "$OUT/static_c.txt"
PPA_NOC=1 "$OUT/measure_static" "$PPA/tests/png" | tail -1 > "$OUT/static_pas.txt"
[ "$(sed 's/, encode .*, \([0-9]* failures\)/, \1/' "$OUT/static_c.txt")" = "$(sed 's/, encode .*, \([0-9]* failures\)/, \1/' "$OUT/static_pas.txt")" ] \
  || { echo "FAIL: the C and Pascal static models give different streams"; cat "$OUT/static_pas.txt"; exit 1; }
for d in "${dirs[@]}"; do "$OUT/measure_static" "$d" | tail -1; done

echo "== layer 6: the codec (every file compressed, verified, decompressed)"
"$OUT/test_codec" "$PPA/tests/png" 14 | tail -1
# bands: 4 KB ones, so that the samples have several, decoded last first
PPA_TEST_BAND_BYTES=4096 PPA_TEST_BANDS_REVERSE=1 "$OUT/test_codec" "$PPA/tests/png" 14 | tail -1
# --max: every image with the slow model
PPA_TEST_MAX=1 "$OUT/test_codec" "$PPA/tests/png" 14 | tail -1
# each deflate stream rebuilt in segments on 4 threads (ppazlib's ParallelSlow), the small samples too
PPA_TEST_PAR_BYTES=512 PPA_TEST_THREADS=4 "$OUT/test_codec" "$PPA/tests/png" 14 | tail -1
PPA_TEST_MAX=1 PPA_TEST_BAND_BYTES=4096 PPA_TEST_BANDS_REVERSE=1 "$OUT/test_codec" "$PPA/tests/png" 14 | tail -1
for d in "${dirs[@]}"; do "$OUT/test_codec" "$d" 1 | tail -1; done

echo "== layer 7: the .ppa file and the command"
"$OUT/test_blake3" "$PAS/tests/kat.txt" | tail -1
"$OUT/test_format" "$PPA/tests/png" | tail -1
# the same damaged files through the release build (range checks off)
mkdir -p "$OUT/fu"
$FPC -O3 -dPPA_FAST -dPJA_FAST -Fu"$PAS" -Fi"$PAS" -Fu"$PPA/vendor/pja/pas" -Fi"$PPA/vendor/pja/pas" -Fo"$OUT/c" -FU"$OUT/fu" -o"$OUT/test_format_fast" "$PAS/tests/test_format.pas" > "$OUT/fpc.log" 2>&1 \
  || { cat "$OUT/fpc.log"; exit 1; }
"$OUT/test_format_fast" "$PPA/tests/png" > "$OUT/damaged.txt" 2>&1 || { cat "$OUT/damaged.txt"; exit 1; }
tail -1 "$OUT/damaged.txt"; grep -q ', 0 failures' "$OUT/damaged.txt"
$FPC -O3 -dPPA_FAST -dPJA_FAST -Fu"$PAS" -Fi"$PAS" -Fu"$PPA/vendor/pja/pas" -Fi"$PPA/vendor/pja/pas" -Fo"$OUT/c" -FU"$OUT/cli" -o"$OUT/ppa" "$PAS/ppacli.pas" > "$OUT/fpc.log" 2>&1 \
  || { cat "$OUT/fpc.log"; exit 1; }
(cd "$PPA" && sh pas/tests/cli.sh "$OUT/ppa" "$OUT/clitest")
# the samples inside the binary (ppa selftest) are this code's .ppa
python3 "$PPA/tools/gen_selftest.py" --check "$OUT/ppa"

echo "== the zpaq-std plugin (codec ppa1): its ZPAQL decoder, the query's memory, the library"
# the decoder compiled from pas/plugin/zpaql/ is the .inc's; zpaqlc's own tests
python3 "$PPA/tools/zpaql/gen_ppadec.py" --check
python3 "$PPA/tools/zpaql/test_zpaqlc.py" | tail -1
# the query (ppazpaqlargs) on images of many sizes built there and on tests/png,
# and the detection's refusals; then the decoder itself with exactly that H
# and M (the file back) and one word or byte less (error()), the smallest
# also compiled, in zpaqlvm
$FPC -O2 -g -gl -Fu"$PAS" -Fi"$PAS" -Fu"$PAS/plugin" -Fi"$PAS/plugin" -Fu"$PPA/vendor/pja/pas" -Fi"$PPA/vendor/pja/pas" \
  -Fo"$OUT/c" -FU"$OUT" -FE"$OUT" "$PAS/tests/test_zpaqlargs.pas" > "$OUT/fpc.log" 2>&1 || { cat "$OUT/fpc.log"; exit 1; }
rm -rf "$OUT/zpaqlargs"
"$OUT/test_zpaqlargs" "$OUT/zpaqlargs" "$PPA/tests/png" | tail -1
python3 "$PAS/tests/check_zpaqlargs.py" "$OUT/zpaqlargs" --vm 1 --jobs 8
# the library as zpaq-std loads it (ctypes): its codec, what it takes and
# refuses, compress, query, decompress
mkdir -p "$OUT/pu"
sh "$PAS/build_c.sh" "$OUT/pc" -fPIC
$FPC -O3 -dPPA_FAST -dPJA_FAST -Cg -Fu"$PAS" -Fi"$PAS" -Fu"$PAS/plugin" -Fi"$PAS/plugin" -Fu"$PPA/vendor/pja/pas" -Fi"$PPA/vendor/pja/pas" \
  -Fo"$OUT/pc" -FU"$OUT/pu" -o"$OUT/ppa_plugin.so" "$PAS/plugin/ppa_zpaqstd.pas" > "$OUT/fpc.log" 2>&1 || { cat "$OUT/fpc.log"; exit 1; }
python3 "$PAS/tests/probe_plugin.py" "$OUT/ppa_plugin.so" --need-refusals "$PPA/tests/png" | tail -1
for d in "${dirs[@]}"; do python3 "$PAS/tests/probe_plugin.py" "$OUT/ppa_plugin.so" "$d" | tail -1; done

echo "all green"
