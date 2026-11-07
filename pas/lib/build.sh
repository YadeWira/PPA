#!/bin/sh
# libppa: PPA as a shared library (ppa.h) and 7-Zip codec plugin, from
# ppalib.pas, the C part (pas/build_c.sh, with PJA's for a JNG's JPEG), the
# filter (ppafilter.c) and the 7-Zip side (ppa7z.c), all position-
# independent. From PJA's pas/lib/build.sh.
#
#   pas/lib/build.sh <out dir>     -> <out dir>/ppa.so (ppa.dll, ppa.dylib)
#
# FPC picks the FreePascal compiler and its target options (fpc by default:
# "fpc -Twin64 -Px86_64" cross-compiles), CC the C compiler for the same
# target (pas/build_c.sh).
set -eu
OUT=${1:?usage: build.sh <out dir>}
# a folder's absolute path; on Windows (MSYS, Git Bash) in Windows' form,
# since FreePascal gets it glued to an option (-Fu...), which MSYS does not
# translate
apath() {
  p=$(cd "$1" && pwd)
  case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) p=$(echo "$p" | sed -E 's|^/([A-Za-z])/|\1:/|') ;; esac
  echo "$p"
}
HERE=$(apath "$(dirname "$0")"); PAS=$(dirname "$HERE"); VEND=$(apath "$PAS/../vendor/pja/pas")
FPC=${FPC:-fpc}
CC=${CC:-cc}
mkdir -p "$OUT/c" "$OUT/u"
OUT=$(apath "$OUT")
# Windows: a native build (MSYS, Git Bash: by uname, as .github/test.sh)
# or a cross one
WIN=; case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) WIN=1 ;; esac
case "$CC $FPC" in *mingw*|*-Twin*) WIN=1 ;; esac
if [ -n "$WIN" ]; then PIC=; EXT=dll; else PIC=-fPIC; EXT=so; fi
# macOS: the install name is @rpath/ppa.dylib, not the path it was built
# at, so that a program linked against it finds it by its own rpath
LDN=
if [ -z "$WIN" ] && [ "$(uname -s)" = Darwin ]; then EXT=dylib; LDN="-k-install_name -k@rpath/ppa.dylib"; fi
# shellcheck disable=SC2086
CC="$CC" "$PAS/build_c.sh" "$OUT/c" $PIC
FLAGS="-O3 -fwrapv -ffp-contract=off -fno-stack-protector"
# no memset or memcpy calls, as build_c.sh: the DLL has no C runtime
if $CC --version 2>/dev/null | grep -qi clang; then
  FLAGS="$FLAGS -fno-builtin"
else
  FLAGS="$FLAGS -fno-tree-loop-distribute-patterns"
fi
# 32-bit x86: any 686, as build_c.sh
case "$CC $($CC -dumpmachine 2>/dev/null)" in
  *-m32*|*i686*|*i386*|*i586*) FLAGS="$FLAGS -march=i686" ;;
esac
# shellcheck disable=SC2086
for f in ppafilter ppa7z; do
  $CC $FLAGS $PIC -c "$HERE/$f.c" -o "$OUT/c/$f.o"
done
CG=; [ -n "$PIC" ] && CG=-Cg
echo "units from $PAS, objects in $OUT/c"
# MSYS would take "-Fud:/..." for a list of paths (the colon) and rewrite
# it: no conversion for FreePascal's arguments
# shellcheck disable=SC2086
MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' $FPC -O3 -dPPA_FAST -dPJA_FAST $CG $LDN -Fu"$PAS" -Fi"$PAS" -Fu"$VEND" -Fi"$VEND" -Fo"$OUT/c" -FU"$OUT/u" -o"$OUT/ppa.$EXT" "$HERE/ppalib.pas" \
  > "$OUT/fpc.log" 2>&1 || { cat "$OUT/fpc.log"; exit 1; }
echo "$OUT/ppa.$EXT"
