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
# the C objects call no library: on Linux, nm must find no undefined symbol
# (a 64-bit builtin once pulled libgcc's __ctzdi2 into the 32-bit build)
if [ "$(uname -s)" = Linux ] && command -v nm > /dev/null; then
  if nm "$OUT"/c/*.o | grep ' U '; then echo "FAIL: the C objects need a library"; exit 1; fi
fi
for prog in test_png test_deflate test_zlib test_pixels test_arith measure_model measure_fast measure_static test_codec; do
  # shellcheck disable=SC2086
  $FPC -O2 -Fupas -Fipas -Fuvendor/pja/pas -Fivendor/pja/pas -Fo"$OUT/c" -FU"$OUT/u" -o"$OUT/$prog$EXE" pas/tests/$prog.pas > "$OUT/fpc.log" 2>&1 \
    || { cat "$OUT/fpc.log"; exit 1; }
done

# the commit, for ppa --version and ppa report ({$I %PPA_COMMIT%})
PPA_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || true); export PPA_COMMIT
# shellcheck disable=SC2086
$FPC -O3 -dPPA_FAST -dPJA_FAST -Fupas -Fipas -Fuvendor/pja/pas -Fivendor/pja/pas -Fo"$OUT/c" -FU"$OUT/cu" -o"$OUT/ppa$EXE" pas/ppacli.pas > "$OUT/fpc.log" 2>&1 \
  || { cat "$OUT/fpc.log"; exit 1; }
"$OUT/ppa$EXE" --version
# the damaged .ppa variants through the release build (-dPPA_FAST: range
# checks off in the hot units): every one refused, none read or written out
# of bounds (a decoded line filter above 4 once indexed past its table there)
mkdir -p "$OUT/fu"
# shellcheck disable=SC2086
$FPC -O3 -dPPA_FAST -dPJA_FAST -Fupas -Fipas -Fuvendor/pja/pas -Fivendor/pja/pas -Fo"$OUT/c" -FU"$OUT/fu" -o"$OUT/test_format_fast$EXE" pas/tests/test_format.pas > "$OUT/fpc.log" 2>&1 \
  || { cat "$OUT/fpc.log"; exit 1; }

echo "== the command"
sh pas/tests/cli.sh "$OUT/ppa$EXE" "$OUT/cli"
# the samples' .ppa only: README.md, which cli.sh stores too, is text, and
# git gives it CRLF line ends on Windows. Only the hash and the name: the
# tools print other separators on Windows ("hash *name")
( cd "$OUT/cli/in" && for f in *.ppa; do [ "$f" = README.ppa ] || echo "$($SHA "$f" | cut -c1-64) $f"; done ) | tr -d '\r' | sort > "$OUT/ppa.txt"

echo "== libppa"
sh pas/lib/build.sh "$OUT/lib" > "$OUT/lib.log" 2>&1 || { cat "$OUT/lib.log"; echo "FAIL: libppa did not build"; exit 1; }
LIBF=$(tail -1 "$OUT/lib.log")
# its C objects call no library either (the DLL has no C runtime)
# (the objects' own symbols aside: ppa7z.o calls ppafilter.o)
# (the 32-bit PIC objects name the GOT, which the linker makes: not a library)
if [ "$(uname -s)" = Linux ] && command -v nm > /dev/null; then
  nm "$OUT"/lib/c/*.o | awk '$2 ~ /^[TDBR]$/ {print $3}' | sort -u > "$OUT/lib/defined.txt"
  nm -u "$OUT"/lib/c/*.o | awk 'NF {print $NF}' | grep -v ':$' | grep -vx '_GLOBAL_OFFSET_TABLE_' | sort -u | comm -23 - "$OUT/lib/defined.txt" > "$OUT/lib/undefined.txt"
  if [ -s "$OUT/lib/undefined.txt" ]; then cat "$OUT/lib/undefined.txt"; echo "FAIL: libppa's C objects need a library"; exit 1; fi
fi
# the test finds the library by its rpath alone (no DYLD_LIBRARY_PATH: on
# macOS the install name a program records is @rpath/ppa.dylib, not the
# path the library was built at)
RP=; case "$(uname -s)" in Linux) RP="-pthread -Wl,-rpath,$(dirname "$LIBF")" ;; Darwin) RP="-Wl,-rpath,$(dirname "$LIBF")" ;; esac
if [ "$(uname -s)" = Darwin ]; then
  ID=$(otool -D "$LIBF" | tail -1)
  [ "$ID" = "@rpath/ppa.dylib" ] || { echo "FAIL: libppa's install name is $ID"; exit 1; }
fi
# shellcheck disable=SC2086
${CC:-cc} -O2 -Ipas/lib pas/lib/test_lib.c -o "$OUT/lib/test_lib$EXE" "$LIBF" $RP
# the command's test settings set here: the library must not take them
# from the host's environment (its streams would change)
PPA_TEST_BAND_BYTES=4096 PPA_TEST_MODEL=slow PPA_NOC=1 "$OUT/lib/test_lib$EXE" tests/png/* README.md > "$OUT/lib/test.txt" \
  || { cat "$OUT/lib/test.txt"; echo "FAIL: libppa's test"; exit 1; }
tail -3 "$OUT/lib/test.txt"
# 7-Zip 23 or later (not p7zip, whose IUnknown differs): a copy with the
# plugin in its Codecs folder (the same word size as the library), an
# archive written and extracted. Linux: 7-Zip's package; Windows: the
# 7-Zip installed (64-bit on the runners), and for a 32-bit library the
# 32-bit 7-Zip in SEVEN32 (CI's windows-x86 job unpacks one there: the
# Windows XP heap fault of 0.1.1 showed only in a 32-bit 7-Zip)
case "$LIBF" in
  *.dll) SEVEN="/c/Program Files/7-Zip"; SLIB=7z.dll
    [ -f "$SEVEN/$SLIB" ] || { S=$(command -v 7z 2> /dev/null) && SEVEN=$(dirname "$S"); } || SEVEN= ;;
  *.so) SEVEN=/usr/lib/7zip; SLIB=7z.so ;;
  *) SEVEN=; SLIB= ;;
esac
case "${CC:-} $FPC" in *-m32*|*i386*) SEVEN=${SEVEN32:-} ;; esac
if [ -z "$SEVEN" ] || [ ! -f "$SEVEN/$SLIB" ] || [ ! -f "$SEVEN/7z$EXE" ]; then
  echo "7-Zip: none of the library's word size here, not tried"
else
  Z="$OUT/7z"; rm -rf "$Z"; mkdir -p "$Z/Codecs" "$OUT/7in" "$OUT/7x"
  cp "$SEVEN/7z$EXE" "$SEVEN/$SLIB" "$Z/"
  cp "$LIBF" "$Z/Codecs/"
  cp tests/png/* README.md "$OUT/7in/"
  "$Z/7z$EXE" i | grep -q '37F11 PPA' || { echo "FAIL: 7-Zip does not list PPA (37F11)"; exit 1; }
  (cd "$OUT/7in" && "../7z/7z$EXE" a -bso0 -bsp0 -m0=PPA -m1=LZMA2 ../a.7z .)
  "$Z/7z$EXE" x -bso0 -bsp0 -o"$OUT/7x" "$OUT/a.7z"
  for f in "$OUT"/7in/*; do
    cmp -s "$f" "$OUT/7x/$(basename "$f")" || { echo "FAIL: 7-Zip: $(basename "$f") does not come back"; exit 1; }
  done
  echo "7-Zip with the PPA plugin: every sample back, $(wc -c < "$OUT/a.7z" | tr -d ' ') bytes"
fi

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
echo "== layer 7, damaged .ppa files through the release build"
"$OUT/test_format_fast$EXE" tests/png > "$OUT/damaged.txt" 2>&1 || { cat "$OUT/damaged.txt"; echo "FAIL: the release build on damaged files"; exit 1; }
tail -1 "$OUT/damaged.txt"
grep -q ', 0 failures' "$OUT/damaged.txt" || { cat "$OUT/damaged.txt"; exit 1; }
echo "== layer 6, bands (4 KB ones, decoded last first)"
PPA_TEST_BAND_BYTES=4096 PPA_TEST_BANDS_REVERSE=1 "$OUT/test_codec$EXE" tests/png 14 | sed 's/; [0-9.]* s;/;/' | tee "$OUT/bands.txt"
echo "== layer 2b, the deflate streams rebuilt in segments on 4 threads"
PPA_TEST_PAR_BYTES=512 PPA_TEST_THREADS=4 "$OUT/test_codec$EXE" tests/png 14 | tail -1
echo "== layers 4 and 5"
"$OUT/test_arith$EXE" | tail -1
"$OUT/measure_model$EXE" tests/png | sed 's/, [0-9.]* s,/,/' > "$OUT/model.txt"
cat "$OUT/model.txt"
PPA_NOC=1 "$OUT/measure_model$EXE" tests/png | sed 's/, [0-9.]* s,/,/' > "$OUT/model_pas.txt"
cmp -s "$OUT/model.txt" "$OUT/model_pas.txt" || { echo "FAIL: the C and Pascal pixel loops differ"; cat "$OUT/model_pas.txt"; exit 1; }
"$OUT/measure_fast$EXE" tests/png | sed 's/, encode .*, \([0-9]* failures\)/, \1/' > "$OUT/fast.txt"
cat "$OUT/fast.txt"
PPA_NOC=1 "$OUT/measure_fast$EXE" tests/png | sed 's/, encode .*, \([0-9]* failures\)/, \1/' > "$OUT/fast_pas.txt"
cmp -s "$OUT/fast.txt" "$OUT/fast_pas.txt" || { echo "FAIL: the C and Pascal fast models differ"; cat "$OUT/fast_pas.txt"; exit 1; }
"$OUT/measure_static$EXE" tests/png | sed 's/, encode .*, \([0-9]* failures\)/, \1/' > "$OUT/static.txt"
cat "$OUT/static.txt"
PPA_NOC=1 "$OUT/measure_static$EXE" tests/png | sed 's/, encode .*, \([0-9]* failures\)/, \1/' > "$OUT/static_pas.txt"
cmp -s "$OUT/static.txt" "$OUT/static_pas.txt" || { echo "FAIL: the C and Pascal static models differ"; cat "$OUT/static_pas.txt"; exit 1; }

# each part's own hash too, to find which one differs when the job that
# compares the platforms fails
for part in streams zlib model fast static ppa; do echo "$part: $(tr -d '\r' < "$OUT/$part.txt" | $SHA | cut -c1-16)"; done
cat "$OUT/ppa.txt"
cat "$OUT/streams.txt" "$OUT/zlib.txt" "$OUT/model.txt" "$OUT/fast.txt" "$OUT/static.txt" "$OUT/ppa.txt" "$OUT/bands.txt" | tr -d '\r' | $SHA | cut -d' ' -f1 > hash.txt
echo "hash: $(cat hash.txt)"
