#!/bin/bash
# The layer tests and the command with ppaguardheap (pas/tests/ppaguardheap.pas):
# every heap block ends right before a PROT_NONE page, so that any read past
# the end of an array faults where it happens (Linux only; tests only).
#
#   pas/tests/guard.sh build <out dir> [64|32] [O2|O3]   build them
#   pas/tests/guard.sh run   <out dir> <png dir>...      run them over those
#
# GUARD_NO_DAMAGE=1 leaves out the damaged-file tests (test_format and the
# *_corrupt ones): hours under this heap on a set of megabytes.
#
# 32: FPC_I386 (the i386 compiler) and CC="gcc -m32": i386 is where FreePascal
# widens loads the most. O3: the release settings (-O3 -dPPA_FAST -dPJA_FAST),
# O2: the suite's (range checks on). A fault prints its pc and exits 86:
# addr2line -e <program> <pc>.
set -euo pipefail
PAS=$(cd "$(dirname "$0")/.." && pwd); PPA=$(dirname "$PAS")
cmd=${1:?usage: guard.sh build|run <out dir> ...}; OUT=${2:?out dir}; shift 2

if [ "$cmd" = build ]; then
  bits=${1:-64}; opt=${2:-O3}
  if [ "$bits" = 32 ]; then FPC=${FPC_I386:-/mnt/IA_LAB/agentes/ppa/fpc-i386/fpc}; export CC="gcc -m32"
  else FPC=${FPC:-fpc}; export CC=${CC:-cc}; fi
  if [ "$opt" = O3 ]; then FLAGS="-O3 -dPPA_FAST -dPJA_FAST"; else FLAGS="-O2"; fi
  mkdir -p "$OUT/u"
  sh "$PAS/build_c.sh" "$OUT/c" -g > "$OUT/cc.log" 2>&1 || { cat "$OUT/cc.log"; exit 1; }
  for src in tests/test_png tests/test_png_corrupt tests/test_deflate tests/test_deflate_corrupt \
             tests/test_zlib tests/test_pixels tests/measure_model tests/measure_fast tests/measure_static \
             tests/test_codec tests/test_format ppacli; do
    # shellcheck disable=SC2086
    $FPC $FLAGS -B -gl -gw -Fappaguardheap -Fu"$PAS/tests" -Fu"$PAS" -Fi"$PAS" -Fu"$PPA/vendor/pja/pas" -Fi"$PPA/vendor/pja/pas" \
      -Fo"$OUT/c" -FU"$OUT/u" -FE"$OUT" "$PAS/$src.pas" > "$OUT/fpc.log" 2>&1 || { cat "$OUT/fpc.log"; exit 1; }
  done
  mv "$OUT/ppacli" "$OUT/ppa"
  echo "built $OUT ($bits-bit, $FLAGS)"
  exit 0
fi

# run: every layer over each directory, C and Pascal paths, every model; the
# command compresses, tests and extracts a copy of each directory
fails=0
check() {  # name, command...: a fault (86) or a crash is a finding
  local name=$1; shift
  local log="$OUT/log/$name.log"
  set +e; "$@" > "$log" 2>&1; local rc=$?; set -e
  if grep -q 'ppaguardheap: SIGSEGV' "$log" || [ $rc -ge 128 ] || [ $rc = 86 ]; then
    echo "FAULT $name (exit $rc): $(grep 'ppaguardheap' "$log" | head -1)"; fails=$((fails + 1))
  else
    echo "ok    $name (exit $rc): $(tail -1 "$log")"
  fi
}
mkdir -p "$OUT/log"
n=0
for d in "$@"; do
  n=$((n + 1))
  for noc in 0 1; do
    export PPA_NOC=$noc
    check "png.$n.$noc" "$OUT/test_png" "$d" 1
    check "deflate.$n.$noc" "$OUT/test_deflate" "$d" 1
    check "zlib.$n.$noc" "$OUT/test_zlib" "$d"
    check "pixels.$n.$noc" "$OUT/test_pixels" "$d" 1
    check "model.$n.$noc" "$OUT/measure_model" "$d"
    check "fast.$n.$noc" "$OUT/measure_fast" "$d"
    check "static.$n.$noc" "$OUT/measure_static" "$d"
    for m in slow fast static; do
      PPA_TEST_MODEL=$m check "codec.$m.$n.$noc" "$OUT/test_codec" "$d" 1
    done
    PPA_TEST_PAR_BYTES=512 PPA_TEST_THREADS=4 check "codec.par.$n.$noc" "$OUT/test_codec" "$d" 1
    PPA_TEST_BAND_BYTES=4096 PPA_TEST_BANDS_REVERSE=1 check "codec.bands.$n.$noc" "$OUT/test_codec" "$d" 1
    [ "${GUARD_NO_DAMAGE:-}" = 1 ] || check "format.$n.$noc" "$OUT/test_format" "$d"
    # the command: a, t, x over a copy
    w="$OUT/cli.$n.$noc"; rm -rf "$w"; mkdir -p "$w"
    find "$d" -maxdepth 1 -type f \( -iname '*.png' -o -iname '*.mng' -o -iname '*.jng' -o -iname '*.apng' \) -exec cp {} "$w/" \;
    for tag in default max static; do
      mode=""; [ $tag = max ] && mode=--max
      if [ $tag = static ]; then export PPA_TEST_MODEL=static; else unset PPA_TEST_MODEL; fi
      rm -f "$w"/*.ppa
      check "cli.a.$tag.$n.$noc" sh -c "cd '$w' && find . -maxdepth 1 -type f ! -name '*.ppa' -print0 | xargs -0 '$OUT/ppa' a -q $mode"
      check "cli.t.$tag.$n.$noc" sh -c "cd '$w' && find . -maxdepth 1 -name '*.ppa' -print0 | xargs -0 -r '$OUT/ppa' t -q"
      rm -rf "$w/x"; mkdir -p "$w/x"
      check "cli.x.$tag.$n.$noc" sh -c "cd '$w' && find . -maxdepth 1 -name '*.ppa' -print0 | xargs -0 -r '$OUT/ppa' x -q --output-dir=x"
      for f in "$w"/x/*; do
        [ -e "$f" ] || continue
        cmp -s "$f" "$w/$(basename "$f")" || { echo "DIFF  cli.x.$tag.$n.$noc: $(basename "$f") not the original"; fails=$((fails + 1)); }
      done
    done
    unset PPA_TEST_MODEL
    check "cli.info.$n.$noc" sh -c "cd '$w' && find . -maxdepth 1 -type f -print0 | xargs -0 '$OUT/ppa' info"
  done
done
unset PPA_NOC
check selftest "$OUT/ppa" selftest
[ "${GUARD_NO_DAMAGE:-}" = 1 ] || for d in "$@"; do
  check "png_corrupt.$(basename "$d")" "$OUT/test_png_corrupt" "$d" 64
  check "deflate_corrupt.$(basename "$d")" "$OUT/test_deflate_corrupt" "$d" 64
done
echo "$fails faults"
[ $fails = 0 ]
