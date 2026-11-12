#!/bin/bash
# Coverage-guided fuzzing of PPA's decoders (pas/tests/fuzz/README.md).
#
#   pas/tests/fuzz/run.sh build                 every target, in $FUZZ_DIR/bin
#   pas/tests/fuzz/run.sh seeds [png dir]...    the seed corpora, from tests/png and those dirs
#   pas/tests/fuzz/run.sh fuzz <target> <secs>  one campaign (in the background: run several)
#   pas/tests/fuzz/run.sh repro <target> <file> run one input through a target, with its report
#   pas/tests/fuzz/run.sh list                  the targets
#
# FUZZ_DIR: the work area (/mnt/IA_LAB/agentes/ppa/fuzz by default). AFL: the
# AFL++ checkout with qemu mode built (afl-fuzz, afl-qemu-trace), default
# $FUZZ_DIR/tools/aflpp. Memory: an ASan target runs under its own limits
# (-rss_limit_mb, -malloc_limit_mb), in a systemd scope of MEM (3G) when
# systemd-run --user works; an AFL target under ulimit -v.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); PAS=$(cd "$HERE/../.." && pwd); PPA=$(dirname "$PAS")
VEND=$PPA/vendor/pja/pas
W=${FUZZ_DIR:-/mnt/IA_LAB/agentes/ppa/fuzz}
AFL=${AFL:-$W/tools/aflpp}
MEM=${MEM:-3G}
CLANG=${CLANG:-clang}
FPC=${FPC:-fpc}
SAN="-fsanitize=address,undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer"
REL="-O3 -dPPA_FAST -dPJA_FAST"          # the release settings (pas/build.sh, pas/lib/build.sh)
CHK="-O2 -Cr -Co"                         # range and overflow checks on everywhere

# targets: name -> kind (lib: libFuzzer binary; afl: AFL++ qemu over fuzz_decode) and its corpus
LIB_TARGETS="filter_c static_c lib_ppa_rel lib_ppa_chk lib_filter_rel"
AFL_TARGETS="afl_ppa_rel afl_ppa_chk afl_ppa_chk_noc afl_filter_chk"
corpus_of() {
  case $1 in
    filter_c) echo filter_c ;; static_c) echo static_c ;;
    *filter*) echo filter ;; *) echo ppa ;;
  esac
}

build() {
  mkdir -p "$W/bin" "$W/build"
  local B=$W/build
  # 1. C alone: the filter, the static model's rANS decoder
  for t in filter_c static_c; do
    $CLANG -g -O1 -fwrapv -ffp-contract=off -fsanitize=fuzzer $SAN "$HERE/fuzz_$t.c" -o "$W/bin/$t"
  done
  # 2. libppa with the C under ASan + UBSan + libFuzzer's coverage, the Pascal with cmem and the hook
  for v in rel chk; do
    local o=$B/lib_$v; rm -rf "$o"; mkdir -p "$o/c" "$o/u"
    local cfl="-g -fPIC -fsanitize=fuzzer-no-link $SAN"
    CC=$CLANG sh "$PAS/build_c.sh" "$o/c" $cfl > "$o/cc.log" 2>&1 || { cat "$o/cc.log"; exit 1; }
    for f in ppafilter ppa7z; do
      $CLANG -O3 -fwrapv -ffp-contract=off -fno-stack-protector -fno-builtin $cfl -c "$PAS/lib/$f.c" -o "$o/c/$f.o"
    done
    local pf=$REL; [ $v = chk ] && pf=$CHK
    $FPC $pf -Cg -gl -gw -Facmem,ppafuzzhook -Fu"$HERE" -Fu"$PAS" -Fi"$PAS" -Fu"$VEND" -Fi"$VEND" \
      -Fo"$o/c" -FU"$o/u" -o"$o/ppa.so" "$PAS/lib/ppalib.pas" > "$o/fpc.log" 2>&1 || { cat "$o/fpc.log"; exit 1; }
    for m in ppa filter; do
      [ $v = chk ] && [ $m = filter ] && continue
      local d=; [ $m = filter ] && d=-DFUZZ_FILTER
      $CLANG -g -O1 -fsanitize=fuzzer $SAN $d "$HERE/fuzz_lib.c" "$o/ppa.so" -Wl,-rpath,"$o" -o "$W/bin/lib_${m}_$v"
    done
  done
  # 3. fuzz_decode for AFL++'s qemu mode: plain C (gcc), ppaguardheap and the hook first
  for v in rel chk; do
    local o=$B/afl_$v; rm -rf "$o"; mkdir -p "$o/c" "$o/u"
    sh "$PAS/build_c.sh" "$o/c" -g > "$o/cc.log" 2>&1 || { cat "$o/cc.log"; exit 1; }
    cc -O3 -g -fwrapv -ffp-contract=off -fno-stack-protector -fno-tree-loop-distribute-patterns -c "$PAS/lib/ppafilter.c" -o "$o/c/ppafilter.o"
    local pf=$REL; [ $v = chk ] && pf=$CHK
    $FPC $pf -gl -gw -Fappaguardheap,cthreads,ppafuzzhook -Fu"$HERE" -Fu"$PAS/tests" -Fu"$PAS" -Fi"$PAS" -Fu"$VEND" -Fi"$VEND" \
      -Fo"$o/c" -FU"$o/u" -o"$W/bin/fuzz_decode_$v" "$HERE/fuzz_decode.pas" > "$o/fpc.log" 2>&1 || { cat "$o/fpc.log"; exit 1; }
  done
  ls -la "$W/bin"
}

# the seeds: each tests/png file (and each PNG-family file of the dirs given,
# up to 64 KB, 40 of them) as a .ppa with each model, its bare stream, and a
# PPAF stream of it among raw bytes; the command must be built (pas/build.sh: PPA_BIN)
seeds() {
  local ppa=${PPA_BIN:-$W/bin/ppa}
  if [ ! -x "$ppa" ]; then
    local o=$W/build/cli; mkdir -p "$o/c" "$o/u"
    sh "$PAS/build_c.sh" "$o/c" > /dev/null
    $FPC $REL -Fu"$PAS" -Fi"$PAS" -Fu"$VEND" -Fi"$VEND" -Fo"$o/c" -FU"$o/u" -o"$ppa" "$PAS/ppacli.pas" > "$o/fpc.log" 2>&1 \
      || { cat "$o/fpc.log"; exit 1; }
  fi
  local S=$W/seeds; rm -rf "$S"; mkdir -p "$S/src" "$S/ppa" "$S/filter" "$S/filter_c" "$S/static_c"
  find "$PPA/tests/png" -maxdepth 1 -type f -exec cp {} "$S/src/" \;
  cp "$PPA"/tests/ppa1/*.ppa "$S/ppa/"
  for d in "$@"; do
    find "$d" -type f -size -64k \( -iname '*.png' -o -iname '*.mng' -o -iname '*.jng' -o -iname '*.apng' \) | head -40 |
      while read -r f; do cp "$f" "$S/src/$(basename "$(dirname "$f")")_$(basename "$f")"; done
  done
  local f b m
  for f in "$S"/src/*; do
    b=$(basename "$f")
    for m in default static fast slow; do
      local t=$S/w; rm -rf "$t"; mkdir -p "$t"; cp "$f" "$t/$b"
      if [ $m = default ]; then (cd "$t" && "$ppa" a -q "$b" > /dev/null 2>&1) || true
      else (cd "$t" && PPA_TEST_MODEL=$m "$ppa" a -q "$b" > /dev/null 2>&1) || true; fi
      [ -s "$t/${b%.*}.ppa" ] && cp "$t/${b%.*}.ppa" "$S/ppa/$b.$m.ppa"
    done
    # the filter's input for the C target: odd first byte = encode and decode back
    { printf '\001'; head -c 100 /dev/urandom; cat "$f"; head -c 50 /dev/urandom; } > "$S/filter_c/$b.enc"
  done
  rm -rf "$S/w"
  # the slow ones aside (over 20 ms natively: the slow model's tables, a large image), but the two smallest:
  # a fuzzer spends its time on executions, and these take 10 to 100 times as long in qemu
  if [ -x "$W/bin/fuzz_decode_rel" ]; then
    mkdir -p "$S/ppa_slow"
    for f in "$S"/ppa/*; do
      local t0 t1; t0=$(date +%s%N); PPA_GUARD_OFF=1 "$W/bin/fuzz_decode_rel" ppa "$f" > /dev/null 2>&1; t1=$(date +%s%N)
      echo "$(( (t1 - t0) / 1000000 )) $(stat -c %s "$f") $(basename "$f")"
    done | sort -n > "$S/times.txt"
    awk '$1 > 20' "$S/times.txt" | sort -k2 -n | tail -n +3 | while read -r _ _ b; do
      mv "$S/ppa/$b" "$S/ppa_slow/"
    done
  fi
  # PPAF streams of the .ppa payloads (mkppaf.py)
  python3 "$HERE/mkppaf.py" "$S/ppa" "$S/filter"
  # the C filter decoder: the PPAF streams, even first byte
  for f in "$S"/filter/*; do { printf '\000'; cat "$f"; } > "$S/filter_c/$(basename "$f").dec"; done
  # the static decoder: a few random ones with a valid state
  python3 - "$S/static_c" <<'EOF'
import os, sys, random
r = random.Random(1)
for i in range(32):
    hdr = bytes([r.randrange(256), r.randrange(256), r.randrange(16), r.randrange(256)])
    st = (r.randrange(1 << 23, 1 << 31)).to_bytes(4, 'big')
    open(os.path.join(sys.argv[1], 's%02d' % i), 'wb').write(hdr + st + os.urandom(r.randrange(16, 4096)))
EOF
  for c in ppa filter filter_c static_c; do echo "$c: $(find "$S/$c" -type f | wc -l) seeds"; done
}

fuzz() {
  local t=${1:?target} secs=${2:?seconds}
  local c; c=$(corpus_of "$t")
  local out=$W/out/$t; mkdir -p "$out"
  case " $LIB_TARGETS " in
  *" $t "*)
    mkdir -p "$out/corpus" "$out/crashes"
    local run=("$W/bin/$t" -max_total_time="$secs" -rss_limit_mb=2048 -malloc_limit_mb=1024 -timeout=20
               -max_len=262144 -artifact_prefix="$out/crashes/" -print_final_stats=1 "$out/corpus" "$W/seeds/$c")
    export ASAN_OPTIONS=${ASAN_OPTIONS:-abort_on_error=1:detect_leaks=0:symbolize=1:allocator_may_return_null=1}
    export UBSAN_OPTIONS=${UBSAN_OPTIONS:-print_stacktrace=1:halt_on_error=1}
    if systemd-run --user --scope -q -p MemoryMax=$MEM true 2>/dev/null; then
      systemd-run --user --scope -q -p MemoryMax=$MEM "${run[@]}" > "$out/log" 2>&1 || true
    else "${run[@]}" > "$out/log" 2>&1 || true; fi ;;
  *" $t "*|*)
    case " $AFL_TARGETS " in *" $t "*) ;; *) echo "no target $t"; exit 1 ;; esac
    local v=rel mode=ppa; case $t in *chk*) v=chk ;; esac; case $t in *filter*) mode=filter ;; esac
    local noc=0; case $t in *noc) noc=1 ;; esac
    ulimit -v 6000000
    export AFL_CRASH_EXITCODE=86 AFL_NO_UI=1 AFL_SKIP_CPUFREQ=1 AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1 \
      AFL_PATH="$AFL" PPA_NOC=$noc AFL_QEMU_INST_RANGES=${AFL_QEMU_INST_RANGES:-}
    rm -rf "$out/afl"
    "$AFL/afl-fuzz" -Q -i "$W/seeds/$c" -o "$out/afl" -V "$secs" -t 5000 -m none -- \
      "$W/bin/fuzz_decode_$v" "$mode" @@ > "$out/log" 2>&1 || true ;;
  esac
  echo "$t done: $out"
}

repro() {
  local t=${1:?target} f=${2:?file}
  export ASAN_OPTIONS=${ASAN_OPTIONS:-detect_leaks=0:symbolize=1:allocator_may_return_null=1} UBSAN_OPTIONS=print_stacktrace=1
  case " $LIB_TARGETS " in
  *" $t "*) "$W/bin/$t" -rss_limit_mb=2048 -malloc_limit_mb=1024 "$f" ;;
  *) local v=rel mode=ppa; case $t in *chk*) v=chk ;; esac; case $t in *filter*) mode=filter ;; esac
     case $t in *noc) export PPA_NOC=1 ;; esac
     ( ulimit -v 6000000; "$W/bin/fuzz_decode_$v" "$mode" "$f" ) ;;
  esac
}

cmd=${1:-}; shift || true
case $cmd in
  build) build ;;
  seeds) seeds "$@" ;;
  fuzz) fuzz "$@" ;;
  repro) repro "$@" ;;
  list) echo "libFuzzer: $LIB_TARGETS"; echo "AFL++ qemu: $AFL_TARGETS" ;;
  *) sed -n '2,13p' "$0"; exit 1 ;;
esac
