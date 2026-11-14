#!/bin/bash
# Builds the reference encoders and preflate the corpus and the baseline use,
# all from source into $PF/tools (no sudo), and writes $PF/tools/VERSIONS.tsv.
#
#   PF=/mnt/IA_LAB/agentes/ppa/preflate bash tools/preflate/build_tools.sh
#
# Sources: the copies the preflate study already has on this machine when they
# are there (STUDY, PRECOMP), else downloads pinned to the same versions.
# Taken from the system, not built: python3's zlib, 7-Zip (7zz), optipng,
# and oxipng (cargo install); their versions go into VERSIONS.tsv too.
set -euo pipefail
PF=${PF:-/mnt/IA_LAB/agentes/ppa/preflate}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
STUDY=${STUDY:-/mnt/IA_LAB/agentes/ppa/preflate-study}
PRECOMP=${PRECOMP:-/mnt/IA_LAB/agentes/ppa/tools/precomp-0.4.7}
T=$PF/tools; S=$T/src; B=$T/bin
mkdir -p "$S" "$B" "$T/dl"
ulimit -v 6000000

fetch() {  # url file sha256
  [ -f "$T/dl/$2" ] || curl -sSL -o "$T/dl/$2" "$1"
  echo "$3  $T/dl/$2" | sha256sum -c --quiet -
}
clone() {  # dir local-copy url commit
  [ -d "$S/$1" ] && return
  if [ -d "$2" ]; then cp -r "$2" "$S/$1"; else git clone -q "$3" "$S/$1"; fi
  git -C "$S/$1" checkout -q "$4"
}

echo "== preflate 0.3.4 (precomp 0.4.7 contrib/preflate)"
if [ ! -x "$B/preflate" ]; then
  rm -rf "$S/preflate"; cp -r "$PRECOMP/contrib/preflate" "$S/preflate"
  # its Makefile wants precomp's bundled zlib and packARI; main.cpp needs neither.
  # _fseeki64 is MSVC's: the glibc names do the same.
  (cd "$S/preflate" && g++ -std=c++11 -O2 -w -include cstdio -D_fseeki64=fseeko64 -D_ftelli64=ftello64 \
     -o "$B/preflate" main.cpp preflate_*.cpp support/*.cpp -lpthread)
fi

echo "== zfl (zlib with flushes and deflateParams), ppastreams, ppa"
gcc -O2 -o "$B/zfl" "$REPO/tools/preflate/zfl.c" -lz
# and with old zlibs, whose flushes differ (M2's zflow subset): 1.2.5 and 1.2.3
for v in 1.2.5:6064e52e513facb0fbb7998c6413406cf253cfb986063d68f4771c2bf7a3f958 \
         1.2.3:1795c7d067a43174113fdf03447532f373e1c6c57c08d61d9e4e9be5e244b05e; do
  zv=${v%%:*}
  if [ ! -x "$B/zfl-$zv" ]; then
    fetch https://zlib.net/fossils/zlib-$zv.tar.gz zlib-$zv.tar.gz "${v#*:}"
    rm -rf "$S/zlib-$zv"; tar xzf "$T/dl/zlib-$zv.tar.gz" -C "$S"
    (cd "$S/zlib-$zv" && gcc -O2 -w -c adler32.c compress.c crc32.c deflate.c trees.c zutil.c inffast.c inflate.c inftrees.c \
       && ar rcs libzold.a ./*.o)
    gcc -O2 -I"$S/zlib-$zv" -o "$B/zfl-$zv" "$REPO/tools/preflate/zfl.c" "$S/zlib-$zv/libzold.a"
  fi
done
mkdir -p "$T/fpc/c" "$T/fpc/u"
sh "$REPO/pas/build_c.sh" "$T/fpc/c" > /dev/null
for prog in "$REPO/pas/ppacli.pas:ppa" "$REPO/tools/preflate/ppastreams.pas:ppastreams"; do
  fpc -O3 -dPPA_FAST -dPJA_FAST -Fu"$REPO/pas" -Fi"$REPO/pas" -Fu"$REPO/vendor/pja/pas" -Fi"$REPO/vendor/pja/pas" \
    -Fo"$T/fpc/c" -FU"$T/fpc/u" -o"$B/${prog#*:}" "${prog%:*}" > "$T/fpc/fpc.log" 2>&1 || { cat "$T/fpc/fpc.log"; exit 1; }
done

echo "== advancecomp 2.6 (advpng, advdef)"
if [ ! -x "$B/advpng" ]; then
  fetch https://github.com/amadvance/advancecomp/releases/download/v2.6/advancecomp-2.6.tar.gz advancecomp-2.6.tar.gz \
    b07d77735540409771cbe1b6df165b5151c11bb9c3d8f01290be0ec88ec3498f
  tar xzf "$T/dl/advancecomp-2.6.tar.gz" -C "$S"
  (cd "$S/advancecomp-2.6" && ./configure --prefix="$T/inst" > /dev/null && make -j4 > /dev/null && make install > /dev/null)
  cp "$T/inst/bin/advpng" "$T/inst/bin/advdef" "$B/"
fi

echo "== pngcrush 1.8.13 (its own libpng 1.6.32 and zlib 1.2.11)"
if [ ! -x "$B/pngcrush" ]; then
  fetch https://downloads.sourceforge.net/project/pmt/pngcrush/1.8.13/pngcrush-1.8.13.tar.xz pngcrush-1.8.13.tar.xz \
    8fc18bcbcc65146769241e20f9e21e443b0f4538d581250dce89b1e969a30705
  tar xJf "$T/dl/pngcrush-1.8.13.tar.xz" -C "$S"
  (cd "$S/pngcrush-1.8.13" && make -j4 > /dev/null) && cp "$S/pngcrush-1.8.13/pngcrush" "$B/"
fi

echo "== zopfli df1517d (zopfli, zopflipng, zop: raw deflate)"
clone zopfli "$STUDY/algorithm/dl/zopfli" https://github.com/google/zopfli.git df1517d
if [ ! -x "$B/zopflipng" ]; then
  (cd "$S/zopfli" && make -j4 zopfli zopflipng > /dev/null) && cp "$S/zopfli/zopfli" "$S/zopfli/zopflipng" "$B/"
fi
gcc -O2 -I"$S/zopfli/src" "$REPO/tools/preflate/enc/zop.c" $(ls "$S"/zopfli/src/zopfli/*.c | grep -v zopfli_bin) -lm -o "$B/zop"

echo "== libdeflate 7e66210 (1.26-dev; ldf: raw deflate at levels 0-12)"
clone libdeflate "$STUDY/algorithm/dl/libdeflate" https://github.com/ebiggers/libdeflate.git 7e66210
gcc -O2 -I"$S/libdeflate" "$REPO/tools/preflate/enc/ldf.c" "$S"/libdeflate/lib/*.c "$S"/libdeflate/lib/x86/*.c -o "$B/ldf"

echo "== miniz 1.14 and 3.0.2 (mz114, mz3: tdefl_compress_mem_to_heap, raw)"
for v in miniz114 miniz; do
  [ -d "$S/$v" ] || cp -r "$STUDY/encoder-census/dl/src/$v" "$S/$v"
done
gcc -O2 -w -I"$S/miniz114" -DMZ114 "$REPO/tools/preflate/enc/mz.c" -o "$B/mz114"
gcc -O2 -w -I"$S/miniz" "$REPO/tools/preflate/enc/mz.c" "$S/miniz/miniz.c" -o "$B/mz3"

echo "== zlib-ng 2.3.3 (python zlib_ng 1.1.0)"
[ -d "$T/pylib/zlib_ng" ] || { mkdir -p "$T/pylib"; cp -r "$STUDY"/pda-census/pylib/zlib_ng* "$T/pylib/"; }

echo "== versions"
{
  printf 'tool\tversion\tsource\n'
  printf 'preflate\t%s\t%s\n' "$("$B/preflate" 2>&1 | head -1)" "$PRECOMP/contrib/preflate"
  printf 'zfl\tzlib %s\tsystem libz\n' "$(python3 -c 'import zlib;print(zlib.ZLIB_RUNTIME_VERSION)')"
  printf 'zfl-1.2.5\tzlib 1.2.5\tzlib-1.2.5.tar.gz (zlib.net/fossils)\n'
  printf 'zfl-1.2.3\tzlib 1.2.3\tzlib-1.2.3.tar.gz (zlib.net/fossils)\n'
  printf 'ppa\t%s\t%s\n' "$("$B/ppa" --version | head -1)" "$(git -C "$REPO" rev-parse --short HEAD)"
  printf 'advpng\t%s\tadvancecomp-2.6.tar.gz\n' "$("$B/advpng" --version | head -1)"
  printf 'pngcrush\t%s\tpngcrush-1.8.13.tar.xz\n' "$("$B/pngcrush" -version 2>&1 | grep -m1 pngcrush | sed 's/^ *//')"
  printf 'zopfli/zopflipng/zop\tgit %s\tgoogle/zopfli\n' "$(git -C "$S/zopfli" rev-parse --short HEAD)"
  printf 'ldf\tlibdeflate %s git %s\tebiggers/libdeflate\n' "$(sed -n 's/.*LIBDEFLATE_VERSION_STRING\t*"\(.*\)"/\1/p' "$S/libdeflate/libdeflate.h")" "$(git -C "$S/libdeflate" rev-parse --short HEAD)"
  printf 'mz114\tminiz 1.14\tminiz.c v1.14\n'
  printf 'mz3\tminiz 3.0.2 (MZ_VERSION %s)\trichgel999/miniz\n' "$(sed -n 's/#define MZ_VERSION "\(.*\)"/\1/p' "$S/miniz/miniz.h")"
  printf 'zlib-ng\t%s\tpython zlib_ng 1.1.0\n' "$(PYTHONPATH=$T/pylib python3 -c 'from zlib_ng import zlib_ng as z;print(z.ZLIBNG_VERSION)')"
  printf 'python-zlib\t%s\tsystem\n' "$(python3 -c 'import zlib;print(zlib.ZLIB_RUNTIME_VERSION)')"
  printf '7zz\t%s\tsystem\n' "$(7zz | sed -n 2p | cut -c1-40)"
  printf 'optipng\t%s\tsystem\n' "$(optipng --version | head -1)"
  printf 'oxipng\t%s\tcargo install\n' "$(oxipng --version)"
} > "$T/VERSIONS.tsv"
cat "$T/VERSIONS.tsv"
