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
for prog in test_png test_png_corrupt; do
  $FPC -O2 -g -gl -Fu"$PAS" -Fi"$PAS" -FU"$OUT" -FE"$OUT" "$PAS/tests/$prog.pas" > "$OUT/fpc.log" 2>&1 \
    || { cat "$OUT/fpc.log"; exit 1; }
done

echo "== layer 1: file <-> chunks and image streams"
"$OUT/test_png" "$PPA/tests/png" 14 | tail -1
# every bit of the first 512 bytes and every cut: no exception, the same bytes back
"$OUT/test_png_corrupt" "$PPA/tests/png" 512 | tail -1
IFS=: read -ra dirs <<< "${PNG_CORPUS:-}"
for d in "${dirs[@]}"; do "$OUT/test_png" "$d" 1 | tail -1; done

echo "all green"
