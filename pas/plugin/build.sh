#!/bin/bash
# PPA as a zpaq-std plugin (ppa_zpaqstd.pas): the .so for Linux, the .dll
# for 64-bit Windows (cross: fpc -Twin64 -Px86_64, x86_64-w64-mingw32-gcc)
# and, with FPCW32 (an i386-win32 FreePascal, the whole command: a script
# that runs ppc386 -Twin32 with its units) and i686-w64-mingw32-gcc, the
# 32-bit .dll. As PJA's pas/plugin/build.sh. The C part (pas/build_c.sh,
# with PJA's from vendor/pja for a JNG's JPEG, which ppacodec links) is
# built here for each target.
#
#   pas/plugin/build.sh <out dir>   -> <out dir>/ppa.so, ppa.dll, ppa32.dll
#
# zpaq-std looks for codecs/ppa.so (or codecs\ppa.dll) next to its binary.
# FPCW32 defaults to /mnt/IA_LAB/agentes/ppa/fpc-i386/fpcw32 when it exists;
# FPCW32= (empty) skips the 32-bit .dll.
set -euo pipefail
FPC=${FPC:-fpc}
PAS=$(cd "$(dirname "$0")/.." && pwd); OUT=${1:?usage: build.sh <out dir>}
VEND=$(cd "$PAS/../vendor/pja/pas" && pwd)
W32DEF=/mnt/IA_LAB/agentes/ppa/fpc-i386/fpcw32
[ -x "$W32DEF" ] || W32DEF=
FPCW32=${FPCW32-$W32DEF}
mkdir -p "$OUT"; OUT=$(realpath "$OUT"); B=$OUT/build
rm -rf "$B"; mkdir -p "$B/lin" "$B/win" "$B/w32"
SRC=$PAS/plugin/ppa_zpaqstd.pas
UNITS=(-Fu"$PAS" -Fi"$PAS" -Fu"$PAS/plugin" -Fi"$PAS/plugin" -Fu"$VEND" -Fi"$VEND")
# the commit the plugin's info card names (codecinfoex in zpaq-std)
export PPA_COMMIT=${PPA_COMMIT:-$(git -C "$PAS" describe --always --dirty --abbrev=7 2>/dev/null || true)}
run() { "$@" > "$B/fpc.log" 2>&1 || { cat "$B/fpc.log"; exit 1; }; }
# -Cg: position-independent code, needed by a shared library (and -fPIC for its C)
run sh "$PAS/build_c.sh" "$B/lin/c" -fPIC
run $FPC -O3 -dPPA_FAST -dPJA_FAST -Cg "${UNITS[@]}" -Fo"$B/lin/c" -FU"$B/lin" -o"$B/lin/ppa.so" "$SRC"
cp "$B/lin/ppa.so" "$OUT/ppa.so"
CC=x86_64-w64-mingw32-gcc run sh "$PAS/build_c.sh" "$B/win/c"
run $FPC -Twin64 -Px86_64 -O3 -dPPA_FAST -dPJA_FAST "${UNITS[@]}" -Fo"$B/win/c" -FU"$B/win" -o"$OUT/ppa.dll" "$SRC"
if [ -n "$FPCW32" ]; then
  CC=i686-w64-mingw32-gcc run sh "$PAS/build_c.sh" "$B/w32/c"
  run "$FPCW32" -O3 -dPPA_FAST -dPJA_FAST "${UNITS[@]}" -Fo"$B/w32/c" -FU"$B/w32" -o"$OUT/ppa32.dll" "$SRC"
fi
ls -l "$OUT"/ppa*.so "$OUT"/ppa*.dll
