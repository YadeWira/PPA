#!/bin/bash
# The tarball zpaq-std vendors: the sources PPA's zpaq-std plugin (codec
# ppa1) is built from, at a commit, with VENDOR.md (pas/plugin/VENDOR.md,
# the commit and the tag filled in) and SHA256SUMS of every file.
#
#   tools/zpaqstd_tarball.sh <out dir> [commit-ish]   -> <out dir>/ppa-<tag or commit>-zpaqstd.tar.gz (+ .sha256)
set -euo pipefail
OUT=${1:?usage: zpaqstd_tarball.sh <out dir> [commit-ish]}
REV=${2:-HEAD}
cd "$(dirname "$0")/.."
C=$(git rev-parse --short=7 "$REV^{commit}")
TAG=$(git describe --tags --exact-match "$C" 2>/dev/null || true)
NAME=ppa-${TAG:-$C}-zpaqstd
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/$NAME" "$OUT"
# the plugin's sources: PPA's units and C, the plugin, PJA's vendored codec
git archive "$C" LICENSE NOTICE pas/build_c.sh pas/plugin vendor/pja \
  $(git ls-tree --name-only "$C" pas/ | grep -E '\.(pas|c|h|inc)$') | tar -x -C "$W/$NAME"
PCOMP=$(git show "$C:pas/plugin/ppa1zpaql.inc" | grep -o '[0-9,]* bytes of PCOMP' | head -1 | cut -d' ' -f1 || true)
sed -e "s/@COMMIT@/$C/" -e "s/@TAG@/${TAG:+ (tag \`$TAG\`)}/" -e "s/@PCOMP@/${PCOMP:-?}/" \
  "$W/$NAME/pas/plugin/VENDOR.md" > "$W/$NAME/VENDOR.md"
rm "$W/$NAME/pas/plugin/VENDOR.md"
(cd "$W/$NAME" && find . -type f ! -name SHA256SUMS | sort | sed 's|^\./||' | xargs sha256sum > SHA256SUMS)
tar --owner=0 --group=0 --sort=name -czf "$OUT/$NAME.tar.gz" -C "$W" "$NAME"
(cd "$OUT" && sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256" && cat "$NAME.tar.gz.sha256")
