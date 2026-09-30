#!/bin/bash
# rig-flash.sh — write a freshly built image straight to a USB stick in the rig.
#
# ⛔ WHY THIS EXISTS.  The image is BUILT on the rig, and until now the only way
# to get it onto a stick was to upload 5.3 GB to Drive and download it again --
# even for someone sitting at the same machine.  rob, 2026-09-30: "could we
# write it directly to a USB drive attached to the rig ... so that Michael
# could have a flash drive even before the rest of us."
#
# ⚠ SELECTION IS BY ATTRIBUTE, NEVER BY NAME.  The rig's /dev/sda is an
# INTERNAL 500 GB WD spinning disk (removable=0) and its system lives on
# nvme0n1.  A hardcoded device, or a "first disk that isn't nvme" rule, would
# destroy that drive.  This takes only a disk that is USB-attached AND flagged
# removable AND under the size cap, and refuses unless there is exactly one.
#
#   usage: ./rig-flash.sh [/path/to/image.img]     (default: newest in $BUILD)
set -u
BUILD="${SIGMOND_BUILD_DIR:-/srv/build/v3}"
# Upper bound on what counts as "a card someone plugged in to receive an
# image".  rob, 2026-09-30, on the rig's own stick -- a microSD in a USB
# adapter, 238 GiB: "look for anything under a terabyte ... removable USB disc,
# that would be a qualification for writing to it."  Cards keep growing; 256
# was already too tight for the one actually in use.
#
# ⚠ This is the LOOSEST of the three guards and the only one that is a
# judgement call.  removable=1 and USB-attached are facts about the device; a
# size cap is a guess about intent, and at 1 TB a USB-attached backup HDD can
# qualify.  It is the "exactly one candidate" rule that carries the weight
# here: two attached disks and this refuses rather than picks.
MAXSZ_GB="${RIG_FLASH_MAX_GB:-1024}"
ts(){ printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
die(){ ts "FATAL: $*"; exit 1; }

IMG="${1:-}"
if [ -z "$IMG" ]; then
    IMG=$(ls -1t "$BUILD"/sigmond-appliance-v*-release.img 2>/dev/null | head -1)
fi
[ -n "$IMG" ] && [ -f "$IMG" ] || die "no image found (looked in $BUILD)"
SHA_FILE="${IMG%.img}.sha256"
ts "image: $IMG ($(stat -c %s "$IMG") bytes)"

# The published checksum, when there is one: a truncated build must never reach
# a stick, and the .sha256 is what every other consumer trusts.
if [ -f "$SHA_FILE" ]; then
    ts "verifying against $(basename "$SHA_FILE")"
    want=$(awk '{print $1}' < "$SHA_FILE")
    got=$(sha256sum "$IMG" | awk '{print $1}')
    [ "$want" = "$got" ] || die "image does not match its own .sha256
    published:  $want
    on disk:    $got"
    ts "  sha256 OK ${want:0:16}…"
else
    ts "  no .sha256 beside the image — writing unverified"
    want=$(sha256sum "$IMG" | awk '{print $1}')
fi

# ── pick the stick ─────────────────────────────────────────────────────────
CAND=""
for d in /sys/block/*; do
    [ -e "$d/removable" ] || continue
    n=$(basename "$d")
    case "$n" in loop*|nbd*|ram*|dm-*|sr*|zram*) continue ;; esac
    [ "$(cat "$d/removable" 2>/dev/null)" = 1 ] || continue
    case "$(readlink -f "$d/device" 2>/dev/null)" in *usb*) ;; *) continue ;; esac
    sz=$(cat "$d/size" 2>/dev/null); [ "${sz:-0}" -gt 0 ] || continue
    [ "$sz" -lt $(( MAXSZ_GB * 2097152 )) ] || continue
    CAND="${CAND}${CAND:+ }$n"
done
set -- $CAND
if [ "$#" -eq 0 ]; then
    ts "NO USB STICK IN THE RIG — nothing written."
    ts "  Plug one into $(hostname) and re-run: $0"
    exit 2                      # distinct from a failure: nothing was wrong
fi
[ "$#" -eq 1 ] || die "expected exactly one removable USB disk, found: $CAND
  refusing to guess which one you meant"
DEV=/dev/$1
ts "target $DEV ($(( $(cat /sys/block/$1/size) / 2097152 )) GiB, USB, removable)"
ts "  model: $(cat /sys/block/$1/device/model 2>/dev/null | tr -s ' ')"
ts "contents of $DEV are about to be DESTROYED"

umount "$DEV"?* 2>/dev/null
ts "writing $(stat -c %s "$IMG") bytes"
dd if="$IMG" of="$DEV" bs=4M conv=fsync status=none || die "dd failed"
sync
ts "  written"

# ⛔ Read back, always.  A stick that reports a clean write and returns
# different bytes is the failure this catches, and it is not rare.
ts "reading back and comparing (the real test)"
back=$(dd if="$DEV" bs=4M count=$(( ( $(stat -c %s "$IMG") + 4194303 ) / 4194304 )) status=none \
       | head -c "$(stat -c %s "$IMG")" | sha256sum | awk '{print $1}')
[ "$back" = "$want" ] || die "READ-BACK MISMATCH
    image: $want
    stick: $back"
ts "VERIFIED — $DEV matches $(basename "$IMG") byte for byte"
ts "DONE. Safe to unplug."
