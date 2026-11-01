#!/bin/sh
# The check every platform runs (CI): the layer tests built and run on the
# repository's samples (layer 1: every file back byte for byte; layer 2a:
# every zlib stream back bit for bit; layer 2b: zlib's parameters found and
# the predicted choices giving the same bits; layer 3: every image
# unfiltered and filtered again), and the SHA-256 of what they
# found (the parameters of each stream, the CRC-32 of the bytes each holds)
# written to hash.txt: the same on every platform, which the last CI job
# checks.
#
#   FPC=<compiler> PPA_OUT=<dir> sh .github/test.sh
set -eu
FPC=${FPC:-fpc}
OUT=${PPA_OUT:-build/ci}
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) EXE=.exe ;; *) EXE= ;; esac
if command -v sha256sum > /dev/null; then SHA="sha256sum"; else SHA="shasum -a 256"; fi
rm -rf "$OUT"; mkdir -p "$OUT/u" "$OUT/z"

echo "== build"
for prog in test_png test_deflate test_zlib test_pixels test_arith measure_model; do
  # shellcheck disable=SC2086
  $FPC -O2 -Fupas -Fipas -FU"$OUT/u" -o"$OUT/$prog$EXE" pas/tests/$prog.pas > "$OUT/fpc.log" 2>&1 \
    || { cat "$OUT/fpc.log"; exit 1; }
done

echo "== layer 1"
"$OUT/test_png$EXE" tests/png 14 | tail -1
echo "== layer 2a"
"$OUT/test_deflate$EXE" tests/png 16 | tail -1
"$OUT/test_deflate$EXE" tests/png 1 -dump "$OUT/z" > "$OUT/streams.txt"
echo "== layer 2b"
"$OUT/test_zlib$EXE" tests/png -v > "$OUT/zlib.txt"
tail -1 "$OUT/zlib.txt"
grep -q ', 0 failures' "$OUT/zlib.txt"
echo "== layer 3"
"$OUT/test_pixels$EXE" tests/png 16 | tail -1
echo "== layers 4 and 5"
"$OUT/test_arith$EXE" | tail -1
"$OUT/measure_model$EXE" tests/png | sed 's/, [0-9.]* s,/,/' > "$OUT/model.txt"
cat "$OUT/model.txt"

cat "$OUT/streams.txt" "$OUT/zlib.txt" "$OUT/model.txt" | tr -d '\r' | $SHA | cut -d' ' -f1 > hash.txt
echo "hash: $(cat hash.txt)"
