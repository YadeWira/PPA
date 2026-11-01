#!/bin/bash
# Archivers, one archive per set, 8 threads: write it, extract it, compare
# every file (as PJA's arch5.sh). PPA has no 7-Zip or zpaq-std plugin yet,
# so "PPA, then 7-Zip" is the two in a row: ppa a -th 8 on every file, then
# 7-Zip on the .ppa files; extracting, the reverse. The others with their
# defaults and 8 threads (aqueous's aqr: its default level, mid).
#
#   PPA=<ppa> bash tools/bench/arch.sh [set...]   (corpus photos generated)
export LC_ALL=C
S=/mnt/IA_LAB/agentes/ppa/sets; R=${WORK:-/mnt/IA_LAB/agentes/ppa/bench/arch}
Z7=${Z7:-/usr/bin/7zz}
ZS=${ZS:-/home/forum/git/zpaq-std/zpaq-std}
AQR=${AQR:-/mnt/IA_LAB/agentes/ppa/tools/aqr-20261101/aqr}
ONLY=${ONLY:-}   # one label alone (e.g. ONLY=aqueous)
shopt -s nullglob
t() { local s; s=$(date +%s.%N); "$@" > /dev/null 2>&1; local rc=$?; printf '%.1f%s' "$(echo "$(date +%s.%N) - $s" | bc)" "$([ $rc = 0 ] || echo "(rc$rc)")"; }
sets=("$@"); [ ${#sets[@]} = 0 ] && sets=(corpus photos generated)
for n in "${sets[@]}"; do
  d=$S/$n; f=("$d"/*)
  names=(); for g in "${f[@]}"; do names+=("$(basename "$g")"); done
  in=$(cat "${f[@]}" | wc -c)
  run() {  # label write-cmd extract-cmd archive
    local label=$1 arc=$4; [ -n "$ONLY" ] && [ "$ONLY" != "$label" ] && return; rm -rf "${R:?}/x" "$R/p" "$R/q"; mkdir -p "$R/x" "$R/p" "$R/q"; rm -f "$arc"
    local a b; a=$(cd "$d" && t bash -c "$2"); b=$(cd "$R/x" && t bash -c "$3")
    local bad=0; for g in "${f[@]}"; do cmp -s "$g" "$R/x/$(basename "$g")" || bad=$((bad+1)); done
    local z; z=$(stat -c %s "$arc" 2>/dev/null || echo 0)
    printf '%s\t%s\t%d\t%d\t%.2f%%\t%s\t%s\tnotback=%d\n' "$n" "$label" "$in" "$z" "$(echo "100*$z/$in" | bc -l)" "$a" "$b" $bad
  }
  mkdir -p "$R"
  q=$(printf '%q ' "${names[@]}")
  run "PPA, then 7-Zip" "$PPA a -q -th 8 --output-dir=$R/p $q && cd $R/p && $Z7 a -bso0 -bsp0 -mmt=8 $R/a.7z *.ppa" \
      "$Z7 x -bso0 -bsp0 -mmt=8 -o$R/q $R/a.7z && $PPA x -q -th 8 --output-dir=$R/x $R/q/*.ppa" "$R/a.7z"
  run "7-Zip" "$Z7 a -bso0 -bsp0 -mmt=8 $R/b.7z $q" "$Z7 x -bso0 -bsp0 -mmt=8 $R/b.7z" "$R/b.7z"
  run "zpaq-std" "$ZS a $R/b.zpaq $q -t8" "$ZS x $R/b.zpaq -t8" "$R/b.zpaq"
  run "aqueous" "$AQR -q -T 8 -o $R/b.aqr $q" "$AQR -d -q -f -T 8 -o $R/x $R/b.aqr" "$R/b.aqr"
done
