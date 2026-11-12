#!/bin/bash
# Disk full on ext4, without root: an ext4 image (mkfs.ext4) mounted with
# fuse2fs (e2fsprogs, built with --enable-fuse2fs: FUSE2FS), filled so that
# only part of the output fits, then ppa a / ppa x write their output there.
# What must hold: an error and a non-zero exit, nothing under the output's
# name (or the old file there, whole, with -f), no temporary left behind,
# and the file system clean afterwards (e2fsck -fn).
#
#   pas/tests/fuzz/diskfull_ext4.sh <ppa command> <a PNG> [work dir]
#
# Each case on a fresh image of IMG_MB (16) MB: with and without --no-sync,
# without and with an old file under the output's name (-f), and the free
# space at 0, a block, 10%, 50%, 90% and 99% of the output's size.
set -uo pipefail
PPA=${1:?ppa command}; PNG=${2:?a PNG}; W=${3:-/mnt/IA_LAB/agentes/ppa/fuzz/diskfull}
FUSE2FS=${FUSE2FS:-/mnt/IA_LAB/agentes/ppa/fuzz/tools/e2fs/misc/fuse2fs}
MKFS=${MKFS:-/sbin/mkfs.ext4}; FSCK=${FSCK:-/sbin/e2fsck}
IMG_MB=${IMG_MB:-16}
PPA=$(readlink -f "$PPA"); PNG=$(readlink -f "$PNG")
mkdir -p "$W/mnt" "$W/ref"
IMG=$W/ext4.img; M=$W/mnt
fusermount -u "$M" 2>/dev/null || true

# the outputs, made elsewhere
cp "$PNG" "$W/ref/in.png"
( cd "$W/ref" && rm -f in.ppa && "$PPA" a -q in.png ) || { echo "ppa a failed on $PNG"; exit 1; }
SA=$(stat -c %s "$W/ref/in.ppa"); SX=$(stat -c %s "$W/ref/in.png")
echo "input $(basename "$PNG"): $SX bytes, .ppa $SA bytes"

mount_fresh() {
  rm -f "$IMG"; truncate -s ${IMG_MB}M "$IMG"
  "$MKFS" -q -F -E root_owner="$(id -u):$(id -g)" "$IMG" || exit 1
  "$FUSE2FS" "$IMG" "$M" -o rw || exit 1
}
# fill until `free` bytes are left (what statfs says is available)
fill_to() {
  local free=$1 avail
  avail=$(( $(stat -f -c '%a * %S' "$M") ))
  [ "$avail" -gt "$free" ] && head -c $(( avail - free )) /dev/zero > "$M/filler" 2>/dev/null
  sync "$M/filler" 2>/dev/null || true
}

fails=0; n=0
for op in a x; do
  if [ $op = a ]; then size=$SA; src=$W/ref/in.png; out=o.ppa; ref=$W/ref/in.ppa
  else size=$SX; src=$W/ref/in.ppa; out=o.png; ref=$W/ref/in.png; fi
  for sync in sync no-sync; do
    for old in no yes; do
      for frac in 0 block 10 50 90 99; do
        mount_fresh
        [ $old = yes ] && printf OLDCONTENT > "$M/$out"
        case $frac in 0) free=0 ;; block) free=4096 ;; *) free=$(( size * frac / 100 )) ;; esac
        fill_to $free
        args=(-q -th 1); [ $sync = no-sync ] && args+=(--no-sync); [ $old = yes ] && args+=(-f)
        msg=$("$PPA" $op "${args[@]}" -o "$M/$out" "$src" 2>&1); rc=$?
        left=$(cd "$M" && find . -maxdepth 1 -type f ! -name filler | sed 's|^\./||' | sort | tr '\n' ' ')
        if [ -e "$M/$out" ]; then
          if cmp -s "$M/$out" "$ref"; then v=complete
          elif [ "$(cat "$M/$out")" = OLDCONTENT ]; then v=old-kept
          else v="TRUNCATED($(stat -c %s "$M/$out"))"; fi
        else v=absent; fi
        fusermount -u "$M"
        fs=clean; "$FSCK" -fn "$IMG" > "$W/fsck.log" 2>&1 || fs=DIRTY
        bad=
        # complete with rc 0 is right when it fitted; anything else must be an error with nothing half-written
        if [ $rc = 0 ]; then [ $v = complete ] || bad=1
        else
          case $v in absent) [ $old = no ] || bad=1 ;; old-kept) [ $old = yes ] || bad=1 ;; *) bad=1 ;; esac
        fi
        echo "$left" | grep -q 'ppa-tmp' && bad=1
        [ $fs = clean ] || bad=1
        n=$((n + 1))
        [ -n "$bad" ] && fails=$((fails + 1))
        printf '%-4s %s %-7s old=%-3s free=%-5s rc=%s %-10s files=[%s] fs=%s %s| %s\n' \
          "${bad:+BAD}" $op $sync $old $frac $rc "$v" "$left" $fs "" "$(echo "$msg" | tail -1 | cut -c1-150)"
      done
    done
  done
done
echo "$n cases, $fails bad"
[ $fails = 0 ]
