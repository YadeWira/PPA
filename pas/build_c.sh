#!/bin/sh
# The C part of PPA as objects for FreePascal to link: layer 5's pixel loop
# (ppamodelc.c, {$L ppamodelc.o} in ppamodel.pas; ppafastc.c, the fast one) and layer 2b's
# longest_match (ppazlibc.c, in ppazlib.pas), and PJA's (vendor/pja, built
# by its own build_c.sh), found through -Fo<dir>. As PJA's pas/build_c.sh.
#
#   pas/build_c.sh <out dir> [extra C flags]
#
# CC picks the compiler (cc by default): gcc or clang, native or a cross
# compiler (x86_64-w64-mingw32-gcc, i686-w64-mingw32-gcc, "gcc -m32").
#
# The object calls no library and needs no runtime: no stack protector, no
# loop turned into memset (gcc's -fno-tree-loop-distribute-patterns, clang's
# -fno-builtin), no position-independent code where the
# executable is not (32-bit x86). -fwrapv and -ffp-contract=off keep the
# arithmetic the same everywhere.
set -eu
OUT=${1:?usage: build_c.sh <out dir> [extra C flags]}
shift
HERE=$(cd "$(dirname "$0")" && pwd)
CC=${CC:-cc}
FLAGS="-O3 -fwrapv -ffp-contract=off -fno-stack-protector"
if $CC --version 2>/dev/null | grep -qi clang; then
  FLAGS="$FLAGS -fno-builtin"
else
  FLAGS="$FLAGS -fno-tree-loop-distribute-patterns"
fi
case "$CC $*" in
  *-m32*|*i686*|*i386*) FLAGS="$FLAGS -fno-pic" ;;
esac
mkdir -p "$OUT"
for f in ppamodelc ppafastc ppastaticc ppazlibc ppapixc ppadeflatec ppasysc; do
  # shellcheck disable=SC2086
  $CC $FLAGS "$@" -c "$HERE/$f.c" -o "$OUT/$f.o"
done
# PJA's C (vendor/pja: its version 7 model, for a JNG's JPEG), by its own script
CC=$CC sh "$HERE/../vendor/pja/pas/build_c.sh" "$OUT" "$@"
