#!/bin/sh
# The ppa command (doc/CLI.md): every sample compressed and extracted, the
# same bytes back; a file that is not of the family stored and back; an
# existing output kept without -f and replaced with it; -n writes nothing;
# list; a damaged .ppa refused with exit status 1 and nothing written; usage
# errors give 2.
#
#   sh pas/tests/cli.sh <ppa binary> <work dir>
set -eu
PPA=$1; W=$2
rm -rf "$W"; mkdir -p "$W/in" "$W/x"
cp tests/png/* README.md "$W/in/"
fail() { echo "FAIL: $*"; exit 1; }

"$PPA" a -q "$W"/in/* || fail "a"
n=0
for f in "$W"/in/*; do
  case $f in *.ppa) continue ;; esac
  b=$(basename "$f"); stem=${b%.*}
  "$PPA" x -q --output-dir="$W/x" "$W/in/$stem.ppa" || fail "x $stem.ppa"
  cmp -s "$f" "$W/x/$b" || fail "$b does not come back"
  n=$((n + 1))
done
[ "$n" -ge 15 ] || fail "only $n files"

# an existing output: kept without -f (status 1), replaced with it
if "$PPA" a -q "$W/in/rgb8.png" 2>/dev/null; then fail "replaced an existing output without -f"; fi
"$PPA" a -q -f "$W/in/rgb8.png" || fail "-f"
# -n writes nothing
rm -f "$W/in/gray8.ppa"
"$PPA" a -q -n "$W/in/gray8.png" || fail "-n"
[ ! -e "$W/in/gray8.ppa" ] || fail "-n wrote a file"
# list
"$PPA" list "$W/in/rgb8.ppa" | grep -q "BLAKE3-128" || fail "list"
# a damaged .ppa: refused, nothing written
cp "$W/in/rgba8.ppa" "$W/bad.ppa"
printf '\377' | dd of="$W/bad.ppa" bs=1 seek=60 conv=notrunc 2>/dev/null
set +e
"$PPA" x -q --output-dir="$W/x2" "$W/bad.ppa" 2>/dev/null; st=$?
set -e
[ "$st" -eq 1 ] || fail "a damaged .ppa gave status $st"
[ ! -e "$W/x2/bad.png" ] || fail "a damaged .ppa was written"
# usage
set +e
"$PPA" > /dev/null 2>&1; st=$?
"$PPA" a --bogus x > /dev/null 2>&1; st2=$?
set -e
[ "$st" -eq 2 ] && [ "$st2" -eq 2 ] || fail "usage errors give $st and $st2"
echo "cli: $n files back, -f, -n, list, a damaged file and usage: 0 failures"
