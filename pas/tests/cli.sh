#!/bin/sh
# The ppa command (doc/CLI.md): every sample compressed and extracted, the
# same bytes back; a file that is not of the family stored and back; an
# existing output kept without -f and replaced with it; -n writes nothing;
# list; a damaged .ppa refused with exit status 1 and nothing written; usage
# errors give 2. Then what PJA 0.9.5 to 0.9.7 brought: t, info, report,
# selftest, --json, --stats, the bug status (3), --keep-corrupt, and the
# leftovers of an interrupted run (--clean-temps).
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
"$PPA" list "$W/in/rgb8.ppa" | grep -q "blake3-128" || fail "list"
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

# what the published releases wrote still comes back (tests/ppa1: PPA 0.1.0,
# stream version 1, each model)
mkdir -p "$W/v1"
"$PPA" x -q --output-dir="$W/v1" tests/ppa1/*.ppa || fail "x of 0.1.0's .ppa files"
for f in tests/ppa1/*.ppa; do
  b=$(basename "$f" .ppa)
  o=$(ls "$W/v1/$b".* 2>/dev/null | head -1)
  [ -n "$o" ] && cmp -s "$o" "tests/png/$(basename "$o")" || fail "0.1.0's $b.ppa does not come back"
done

# t: extract and verify, write nothing; a damaged one FAILED, status 1
"$PPA" t "$W/in/rgb8.ppa" "$W/in/palette.ppa" | grep -c ': OK' | grep -q '^2$' || fail "t"
before=$(ls "$W/in" | wc -l)
set +e
"$PPA" t "$W/in/rgb8.ppa" "$W/bad.ppa" > /dev/null 2> "$W/t.err"; st=$?
set -e
[ "$st" -eq 1 ] || fail "t on a damaged .ppa gave status $st"
grep -q 'FAILED' "$W/t.err" || fail "t did not say FAILED"
[ "$(ls "$W/in" | wc -l)" -eq "$before" ] || fail "t wrote something"

# info: the structure and what ppa does; the metadata only by its size
"$PPA" info "$W/in/apng3.png" | grep -q 'format: APNG' || fail "info APNG"
"$PPA" info "$W/in/bad_crc_trailer.png" | grep -q 'CRC that does not match' || fail "info problems"
"$PPA" info "$W/in/alpha.jng" | grep -q 'JPEG (PJA)' || fail "info JNG"
"$PPA" info "$W/in/palette.ppa" | grep -q 'extracts it' || fail "info .ppa"
"$PPA" info "$W/bad.ppa" | grep -q 'does not extract it' || fail "info damaged .ppa"
if "$PPA" info "$W/in/gray1.png" | grep -q 'Comment\|Created'; then fail "info printed metadata text"; fi

# --json: one object a file, in order, then the summary
"$PPA" list --json "$W/in/rgb8.ppa" "$W/in/palette.ppa" > "$W/j.txt"
[ "$(wc -l < "$W/j.txt")" -eq 3 ] || fail "--json lines"
head -1 "$W/j.txt" | grep -q '"file":"[^"]*rgb8.ppa"' || fail "--json order"
tail -1 "$W/j.txt" | grep -q '^{"summary":{"command":"list","files":2,"failed":0' || fail "--json summary"
# --stats: where the time went
"$PPA" t --stats "$W/in/palette.ppa" | grep -q 'stats: .*decode' || fail "--stats"

# report: no folders in it, the link; --with-file copies beside it
mkdir -p "$W/rep"
"$PPA" report "$W/in/rgb8.png" > "$W/rep.txt" || fail "report"
grep -q '^ppa report rgb8.png$' "$W/rep.txt" || fail "report shows a folder"
grep -q 'issues/new?template=bug_report.yml' "$W/rep.txt" || fail "report link"
"$PPA" report -o "$W/rep/r.txt" --with-file "$W/in/rgb8.png" > /dev/null || fail "report -o --with-file"
cmp -s "$W/rep/ppa-report-rgb8.png" "$W/in/rgb8.png" || fail "report --with-file copy"

# a bug: status 3 and what to do
set +e
PPA_TEST_CRASH=range "$PPA" t "$W/in/rgb8.ppa" 2> "$W/bug.err"; st=$?
set -e
[ "$st" -eq 3 ] || fail "a bug gave status $st"
grep -q 'This is a bug in PPA' "$W/bug.err" || fail "the bug note"

# --keep-corrupt: a .ppa whose hash does not match, kept as NAME.corrupt
# (the hash's first byte changed: the stream decodes, the hash says no)
cp "$W/in/palette.ppa" "$W/hash.ppa"
printf '\001' | dd of="$W/hash.ppa" bs=1 seek=16 conv=notrunc 2>/dev/null
mkdir -p "$W/kc"
set +e
"$PPA" x -q --output-dir="$W/kc" "$W/hash.ppa" 2>/dev/null; st=$?
"$PPA" x -q --keep-corrupt --output-dir="$W/kc" "$W/hash.ppa" 2>/dev/null; st2=$?
set -e
[ "$st" -eq 1 ] && [ "$st2" -eq 1 ] || fail "a hash mismatch gave $st and $st2"
[ ! -e "$W/kc/hash.png" ] || fail "a hash mismatch was written under its name"
[ -e "$W/kc/hash.png.corrupt" ] || fail "--keep-corrupt kept nothing"

# the leftovers of an interrupted run: named, deleted with --clean-temps
mkdir -p "$W/left"
cp "$W/in/gray8.png" "$W/left/"
: > "$W/left/.ppa-tmp-99999999-0"
touch -t 202001010000 "$W/left/.ppa-tmp-99999999-0"
"$PPA" a -q "$W/left/gray8.png" 2> "$W/left.err" || fail "a with a leftover"
grep -q 'found 1 leftover temporary' "$W/left.err" || fail "the leftover not named"
"$PPA" a -q -f --clean-temps "$W/left/gray8.png" 2> "$W/left2.err" || fail "--clean-temps"
grep -q 'deleted 1 leftover temporary' "$W/left2.err" || fail "--clean-temps did not delete it"
[ ! -e "$W/left/.ppa-tmp-99999999-0" ] || fail "the leftover is still there"

# selftest: every check on both paths
"$PPA" selftest -q | grep -q 'checks passed on 2 path' || fail "selftest"
"$PPA" --version | grep -q 'code_path: c' || fail "--version"

# usage: options for other commands
set +e
"$PPA" t -o x "$W/in/rgb8.ppa" > /dev/null 2>&1; u1=$?
"$PPA" list --no-sync "$W/in/rgb8.ppa" > /dev/null 2>&1; u2=$?
"$PPA" --path=simd selftest > /dev/null 2>&1; u3=$?
"$PPA" x --max "$W/in/rgb8.ppa" > /dev/null 2>&1; u4=$?
set -e
[ "$u1" -eq 2 ] && [ "$u2" -eq 2 ] && [ "$u3" -eq 2 ] && [ "$u4" -eq 2 ] || fail "usage errors give $u1 $u2 $u3 $u4"
echo "cli: $n files back, 0.1.0's files, -f, -n, list, a damaged file, usage, t, info, --json, --stats, report, a bug, --keep-corrupt, leftovers and selftest: 0 failures"
