#!/bin/bash
# flash-usb.sh — write a sigmond appliance image to a USB stick, and PROVE it.
#
# ⛔ WHY THIS EXISTS RATHER THAN THE dd LINE IN QUICKSTART.txt
#
# QUICKSTART says `sudo dd if=...img of=/dev/sdX`, and then verifies with
# `file -s /dev/sdX`.  Two problems, both of which have real teeth:
#
#   1. /dev/sdX is a placeholder a human substitutes at 1am.  Get it wrong
#      and you have overwritten the machine's own disk, silently, with no
#      confirmation step between typing and destruction.
#   2. `file -s` reads the BOOT SECTOR.  A stick that took the first megabyte
#      and then dropped off the USB bus still says "DOS/MBR boot sector".  So
#      does a stick carrying LAST MONTH'S image.  It verifies almost nothing,
#      and it verifies it about the first 0.00002% of the write.
#
# `dd` exiting 0 is not evidence either: with the page cache in the way the
# kernel can report a completed write that has not reached the device.
#
# So: find the stick by its REMOVABLE+USB attributes rather than by a letter,
# refuse anything that carries the running system, write with oflag=direct,
# and then READ THE STICK BACK and compare sha256 over exactly the image's
# byte count.  Nothing here trusts a return code.
#
# Usage:
#   ./flash-usb.sh                          # newest *-release.img here, auto-find stick
#   ./flash-usb.sh <image.img>              # that image, auto-find stick
#   ./flash-usb.sh <image.img> /dev/sdb     # explicit target (still checked)
#   DRY_RUN=1 ./flash-usb.sh ...            # do everything except write
set -uo pipefail

ts(){ date -u '+%H:%M:%SZ'; }
say(){ printf '%s  %s\n' "$(ts)" "$*"; }
die(){ printf '%s  ABORT: %s\n' "$(ts)" "$*" >&2; exit 1; }

IMG="${1:-}"
WANT_DEV="${2:-}"

# ── 1. the image ────────────────────────────────────────────────────────────
if [ -z "$IMG" ]; then
    IMG=$(ls -1t ./sigmond-appliance-*-release.img 2>/dev/null | head -1)
    [ -n "$IMG" ] || die "no image given and no ./sigmond-appliance-*-release.img here"
    say "no image named — using the newest one here:"
fi
[ -f "$IMG" ] || die "no such image: $IMG"
BYTES=$(stat -c %s "$IMG")
say "image: $IMG"
say "       $BYTES bytes ($(( BYTES / 1024 / 1024 )) MiB), modified $(stat -c %y "$IMG" | cut -d. -f1)"
# A Drive HTML interstitial, a truncated scp, a half-written build: all small.
[ "$BYTES" -gt 1000000000 ] || die "only $BYTES bytes — that is not an appliance image"

say "hashing the image (a few seconds)"
IMG_SHA=$(sha256sum "$IMG" | awk '{print $1}')
say "       sha256 ${IMG_SHA:0:16}…"

# ── 2. the target, found by attribute and never by letter ───────────────────
if [ -n "$WANT_DEV" ]; then
    [ -b "$WANT_DEV" ] || die "$WANT_DEV is not a block device"
    DISK="$WANT_DEV"
    rm=$(lsblk -dno RM "$DISK" 2>/dev/null | tr -d ' ')
    tran=$(lsblk -dno TRAN "$DISK" 2>/dev/null | tr -d ' ')
    say "target named explicitly: $DISK (transport=${tran:-?} removable=${rm:-?})"
    # ⛔ "USB" DOES NOT MEAN "STICK".  The appliance build rig boots from an
    # NVMe but carries a 465 GB USB-attached disk mounted at /srv/build --
    # every build artefact on the machine.  It is TRAN=usb, so a naive
    # usb-means-safe check waves it through, and the /-/boot check below does
    # not cover it either because the OS lives elsewhere.  A DRY_RUN on the
    # rig on 2026-09-23 said "every check passed" for exactly that disk.
    #
    # This tool writes REMOVABLE STICKS.  Anything else has to be asked for
    # in writing.
    if [ "$rm" != "1" ]; then
        say "  ⚠ $DISK is NOT removable (RM=$rm) — that is a fixed disk, not a stick"
        [ "${ALLOW_FIXED:-0}" = 1 ] \
            || die "refusing a non-removable disk; set ALLOW_FIXED=1 if you really mean it"
        say "  ALLOW_FIXED=1 — proceeding against a FIXED disk"
    fi
else
    DISK=""; N=0
    while read -r name size tran rm type; do
        [ "$type" = "disk" ] && [ "$tran" = "usb" ] && [ "$rm" = "1" ] || continue
        DISK="/dev/$name"; N=$((N+1))
        say "candidate: /dev/$name  $size  usb removable"
    done < <(lsblk -dno NAME,SIZE,TRAN,RM,TYPE)
    [ "$N" -eq 1 ] || die "expected exactly one removable USB disk, found $N — name the device explicitly: $0 $IMG /dev/sdX"
fi

# ── 3. never the running system, however it was named ───────────────────────
SYS=""
for m in / /boot /boot/efi; do
    src=$(findmnt -no SOURCE "$m" 2>/dev/null) || continue
    pk=$(lsblk -no PKNAME "$src" 2>/dev/null | head -1)
    [ -n "$pk" ] && SYS="$SYS /dev/$pk"
done
for s in $SYS; do
    [ "$s" = "$DISK" ] && die "$DISK CARRIES THE RUNNING SYSTEM — refusing"
done
say "system disk(s):${SYS:- none found} — target $DISK is not among them"

# Beyond the OS: refuse a disk carrying MOUNTED DATA.  A stick that was just
# plugged in automounts under /media, /mnt or /run/media and is fine — those
# get unmounted below.  A mount anywhere ELSE (/srv/build, /var/lib/vz, a
# data array) means this disk is in service, and writing it destroys whatever
# lives there with no way back.
BUSY=""
while read -r part mp; do
    [ -n "$mp" ] || continue
    case "$mp" in
        /media/*|/mnt/*|/run/media/*) continue ;;
    esac
    BUSY="$BUSY $part=$mp"
done < <(lsblk -nro NAME,MOUNTPOINT "$DISK" 2>/dev/null | tail -n +2)
if [ -n "$BUSY" ]; then
    say "  ⚠ $DISK has partitions MOUNTED IN SERVICE:$BUSY"
    [ "${ALLOW_MOUNTED:-0}" = 1 ] \
        || die "refusing a disk with in-service mounts; set ALLOW_MOUNTED=1 if you really mean it"
    say "  ALLOW_MOUNTED=1 — proceeding against a mounted disk"
fi

DBYTES=$(sudo blockdev --getsize64 "$DISK") || die "cannot read the size of $DISK (need sudo)"
[ -n "$DBYTES" ] || die "cannot read the size of $DISK"
say "target $DISK holds $DBYTES bytes"
[ "$BYTES" -le "$DBYTES" ] || die "image ($BYTES) does not fit on $DISK ($DBYTES)"

say "contents about to be DESTROYED on $DISK:"
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$DISK" 2>/dev/null | sed 's/^/        /'

if [ "${DRY_RUN:-0}" = 1 ]; then
    say "DRY_RUN=1 — every check passed; nothing written"
    exit 0
fi

# Interactive confirmation when there is a human; scripted callers set FORCE=1.
if [ -t 0 ] && [ "${FORCE:-0}" != 1 ]; then
    printf '%s  type the device to confirm (%s): ' "$(ts)" "$DISK"
    read -r ans
    [ "$ans" = "$DISK" ] || die "got '$ans', expected '$DISK' — nothing written"
fi

# ── 4. write ────────────────────────────────────────────────────────────────
for p in $(lsblk -nro NAME "$DISK" | tail -n +2); do
    sudo umount "/dev/$p" 2>/dev/null && say "unmounted /dev/$p"
done
say "writing $(( BYTES / 1024 / 1024 )) MiB — USB 3 ~2 min, USB 2 ~10 min"
START=$(date +%s)
sudo dd if="$IMG" of="$DISK" bs=4M oflag=direct conv=fsync status=progress || die "dd failed"
sudo sync
EL=$(( $(date +%s) - START )); [ "$EL" -lt 1 ] && EL=1
say "wrote in ${EL}s ($(( BYTES / 1024 / 1024 / EL )) MiB/s)"

# ── 5. read it back — the only step that actually proves anything ───────────
# Read exactly the image's byte count, in chunks.  NEVER `dd | head`: head
# closes the pipe and dd dies of SIGPIPE *after a perfectly good write*,
# reporting failure on success.
say "reading the stick back and comparing (this is the real test)"
sudo blockdev --flushbufs "$DISK" 2>/dev/null
BACK=$(sudo python3 - "$DISK" "$BYTES" <<'PY'
import hashlib, sys
dev, want = sys.argv[1], int(sys.argv[2])
h, left, CH = hashlib.sha256(), want, 4 << 20
with open(dev, 'rb', buffering=0) as f:
    while left:
        b = f.read(min(CH, left))
        if not b:
            print("SHORT READ", file=sys.stderr); sys.exit(1)
        h.update(b); left -= len(b)
print(h.hexdigest())
PY
)
[ -n "$BACK" ] || die "read-back produced nothing"
if [ "$BACK" = "$IMG_SHA" ]; then
    say "VERIFIED — $DISK matches $(basename "$IMG") byte for byte"
    say "DONE. Connect the RX888 (and GPSDO) BEFORE booting the target from this stick."
else
    die "READ-BACK MISMATCH: stick=${BACK:0:16}… image=${IMG_SHA:0:16}… — DO NOT USE THIS STICK"
fi
