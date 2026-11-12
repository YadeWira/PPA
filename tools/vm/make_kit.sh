#!/bin/bash
# The folder test.bat runs in, for one Windows build: ppa.exe, ppa.dll and
# test_lib.exe (from a build: CI's bin-windows-x64/x86 artifact, or
# .github/test.sh's build/ci), a portable 7-Zip of the same word size
# (unpacked from 7-Zip's installer, downloaded once), the repository's
# samples (s\ and, for test_lib, lib\) and any more samples given.
#
#   tools/vm/make_kit.sh <build dir> <x64|x86> <out dir> [more samples dir]
#   then: copy <out dir> to the VM (scp -r, or vm put winxp) and run test.bat
set -euo pipefail
B=${1:?usage: make_kit.sh <build dir> <x64|x86> <out dir> [samples]}; A=${2:?}; O=${3:?}; X=${4:-}
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(dirname "$(dirname "$HERE")")
SEVENV=2501
case $A in x64) INST=7z$SEVENV-x64.exe ;; x86) INST=7z$SEVENV.exe ;; *) echo "x64 or x86" >&2; exit 2 ;; esac
CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/ppa-vm; mkdir -p "$CACHE"
[ -s "$CACHE/$INST" ] || curl -sSL --fail -o "$CACHE/$INST" "https://www.7-zip.org/a/$INST"
rm -rf "$O"; mkdir -p "$O/s" "$O/lib" "$O/7z"
find_one() { find "$B" -name "$1" -type f | head -1; }
for f in ppa.exe ppa.dll test_lib.exe; do
  p=$(find_one $f); [ -n "$p" ] || { echo "no $f under $B" >&2; exit 1; }
  cp "$p" "$O/"
done
7z x -y -bso0 -o"$O/7z" "$CACHE/$INST"
cp "$REPO"/tests/png/* "$O/s/"; cp "$REPO"/tests/png/* "$O/lib/"
[ -z "$X" ] || find "$X" -maxdepth 1 -type f -exec cp {} "$O/s/" \;
cp "$REPO/README.md" "$HERE/test.bat" "$O/"
echo "$O: $(ls "$O/s" | wc -l) samples, 7-Zip $SEVENV $A"
