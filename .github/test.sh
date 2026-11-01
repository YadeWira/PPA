#!/bin/sh
# The check every platform runs (CI): the ppa command built as released and
# taken through pas/tests/cli.sh (every sample compressed and extracted, the
# same bytes back), the SHA-256 of every .ppa it made (the format makes the
# same bytes on every platform); and the layer tests built and run on the
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
rm -rf "$OUT"; mkdir -p "$OUT/u" "$OUT/z" "$OUT/cu"

echo "== build"
# the C part (CC: the platform's C compiler). A compiler given by its full
# path (MSYS2's MinGW-w64 gcc on Windows) needs its own folder on PATH for
# its DLLs and its cc1/as.
case ${CC:-} in /*) PATH=$(dirname "$CC"):$PATH; export PATH ;; esac
sh pas/build_c.sh "$OUT/c" || { echo "the C part did not build (CC=${CC:-cc})"; exit 1; }
for prog in test_png test_deflate test_zlib test_pixels test_arith measure_model; do
  # shellcheck disable=SC2086
  $FPC -O2 -Fupas -Fipas -Fo"$OUT/c" -FU"$OUT/u" -o"$OUT/$prog$EXE" pas/tests/$prog.pas > "$OUT/fpc.log" 2>&1 \
    || { cat "$OUT/fpc.log"; exit 1; }
done

# shellcheck disable=SC2086
$FPC -O3 -dPPA_FAST -Fupas -Fipas -Fo"$OUT/c" -FU"$OUT/cu" -o"$OUT/ppa$EXE" pas/ppacli.pas > "$OUT/fpc.log" 2>&1 \
  || { cat "$OUT/fpc.log"; exit 1; }
"$OUT/ppa$EXE" --version

echo "== the command"
sh pas/tests/cli.sh "$OUT/ppa$EXE" "$OUT/cli"
# the samples' .ppa only: README.md, which cli.sh stores too, is text, and
# git gives it CRLF line ends on Windows. Only the hash and the name: the
# tools print other separators on Windows ("hash *name")
( cd "$OUT/cli/in" && for f in *.ppa; do [ "$f" = README.ppa ] || echo "$($SHA "$f" | cut -c1-64) $f"; done ) | tr -d '\r' | sort > "$OUT/ppa.txt"

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
PPA_NOC=1 "$OUT/measure_model$EXE" tests/png | sed 's/, [0-9.]* s,/,/' > "$OUT/model_pas.txt"
cmp -s "$OUT/model.txt" "$OUT/model_pas.txt" || { echo "FAIL: the C and Pascal pixel loops differ"; cat "$OUT/model_pas.txt"; exit 1; }

# each part's own hash too, to find which one differs when the job that
# compares the platforms fails
for part in streams zlib model ppa; do echo "$part: $(tr -d '\r' < "$OUT/$part.txt" | $SHA | cut -c1-16)"; done
cat "$OUT/ppa.txt"
cat "$OUT/streams.txt" "$OUT/zlib.txt" "$OUT/model.txt" "$OUT/ppa.txt" | tr -d '\r' | $SHA | cut -d' ' -f1 > hash.txt
echo "hash: $(cat hash.txt)"
