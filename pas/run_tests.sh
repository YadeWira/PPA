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
mkdir -p "$OUT"

echo "== source guards"
python3 "$PAS/collisions.py" "$PAS"

echo "== build"
for prog in test_png test_png_corrupt test_deflate test_deflate_corrupt test_zlib; do
  $FPC -O2 -g -gl -Fu"$PAS" -Fi"$PAS" -FU"$OUT" -FE"$OUT" "$PAS/tests/$prog.pas" > "$OUT/fpc.log" 2>&1 \
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

echo "all green"
