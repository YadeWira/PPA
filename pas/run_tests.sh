#!/bin/bash
# The codec test suite (doc/CODEC.md), layer by layer.
#
#   pas/run_tests.sh                          what is in the repo
#   PNG_CORPUS=dir1:dir2 pas/run_tests.sh     plus the round trip over those directories
#
# Each test demands its own minimum count: one that runs zero cells is not green.
set -euo pipefail
FPC=${FPC:-fpc}
PAS=$(cd "$(dirname "$0")" && pwd); PPA=$(dirname "$PAS"); OUT=${PAS_OUT:-$PAS/build/tests}
mkdir -p "$OUT" "$OUT/cli"

echo "== source guards"
python3 "$PAS/collisions.py" "$PAS"

echo "== build"
# the C part (CC: the platform's C compiler)
sh "$PAS/build_c.sh" "$OUT/c"
for prog in test_png test_png_corrupt test_deflate test_deflate_corrupt test_zlib test_pixels test_arith measure_model test_blake3 test_codec test_format; do
  $FPC -O2 -g -gl -Fu"$PAS" -Fi"$PAS" -Fo"$OUT/c" -FU"$OUT" -FE"$OUT" "$PAS/tests/$prog.pas" > "$OUT/fpc.log" 2>&1 \
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

echo "== layer 3: filtered lines <-> each line's filter and the image's bytes"
"$OUT/test_pixels" "$PPA/tests/png" 16 | tail -1
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

echo "== layer 6: the codec (every file compressed, verified, decompressed)"
"$OUT/test_codec" "$PPA/tests/png" 14 | tail -1
# bands: 4 KB ones, so that the samples have several, decoded last first
PPA_TEST_BAND_BYTES=4096 PPA_TEST_BANDS_REVERSE=1 "$OUT/test_codec" "$PPA/tests/png" 14 | tail -1
for d in "${dirs[@]}"; do "$OUT/test_codec" "$d" 1 | tail -1; done

echo "== layer 7: the .ppa file and the command"
"$OUT/test_blake3" "$PAS/tests/kat.txt" | tail -1
"$OUT/test_format" "$PPA/tests/png" | tail -1
$FPC -O3 -dPPA_FAST -Fu"$PAS" -Fi"$PAS" -Fo"$OUT/c" -FU"$OUT/cli" -o"$OUT/ppa" "$PAS/ppacli.pas" > "$OUT/fpc.log" 2>&1 \
  || { cat "$OUT/fpc.log"; exit 1; }
(cd "$PPA" && sh pas/tests/cli.sh "$OUT/ppa" "$OUT/clitest")

echo "all green"
