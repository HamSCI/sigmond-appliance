#!/bin/bash
# sigmond-flash-latest.sh — download the NEWEST published Sigmond appliance
# image and write it to a USB stick, then PROVE the stick matches.
#
# One script for every release.  It reads the public download folder, picks
# the highest version that has both an .img and its .sha256, downloads it (or
# reuses a copy already downloaded and verified; after a new download only it
# and the previous version are kept), checks the sha256, writes
# the stick and reads it back.  If a newer copy of this script is published,
# it replaces itself and asks you to run it again.  Nothing needs a Google login or rclone: the
# folder is "anyone with the link", and curl is enough.
#
# Runs on Linux and macOS.
#
# Usage (as a normal user with sudo; the write itself needs root):
#   bash sigmond-flash-latest.sh                  # newest image, auto-find the stick
#   bash sigmond-flash-latest.sh --list           # show what is published, write nothing
#   bash sigmond-flash-latest.sh --version v3.85  # a specific published version
#   bash sigmond-flash-latest.sh --pending        # newest build, tested or not: also
#                                                 # reads pending/, where the rig puts
#                                                 # each image before its tests end
#   bash sigmond-flash-latest.sh --device /dev/sdb     (macOS: /dev/disk5)
#   bash sigmond-flash-latest.sh --download-only  # fetch and verify, no stick
#   bash sigmond-flash-latest.sh --yes            # erase the stick without asking
#   DRY_RUN=1 bash sigmond-flash-latest.sh        # every check, no write
#
# Every question comes in the first seconds, before the download: which stick
# it found, "erase it?", and sudo's password.  After that it runs to the end
# unattended, so you can walk away.
#
# Environment:
#   SIGMOND_IMAGE_DIR     where images are kept   (default ~/sigmond-images)
#   SIGMOND_IMAGE_FOLDER  Drive folder id          (default: the HamSCI release folder)
#   FORCE=1               same as --yes: skip the "erase it? [y/N]" confirmation
#   ALLOW_FIXED=1         with --device only: accept a USB whole disk that does
#                         not report itself removable (never needed for a stick)
#   SIGMOND_FLASH_MAX_GB  size cap for the automatic pick, in GiB (default 1024)
#
# Exit status: 0 written and verified (or --list/--download-only/DRY_RUN done),
# 2 no USB stick plugged in (nothing to write to; not a failure), 1 any failure.
#   SIGMOND_NO_UPDATE=1   do not replace this script with a newer published one
#
# The stick is found by attribute (whole disk AND USB transport AND removable
# AND under the size cap), never by a letter, and a disk carrying the running
# system or an in-service mount is refused.  A named --device must pass the
# same attribute checks (all but the cap).  On macOS the same attributes come
# from `diskutil info`: an external USB hard disk reports "Removable Media:
# Fixed" and is never picked.  The rules follow flash-usb.sh and rig-flash.sh
# in the appliance repo, which write an image you already have; this script
# adds the fetch.
set -uo pipefail

# Bump on every published change: the self-update below compares this.
FLASH_VERSION=2026.11.11.3

FOLDER_ID="${SIGMOND_IMAGE_FOLDER:-1Eym7xsP_qVvbGOVmlXER73K3jx6J7dQs}"
IMG_DIR="${SIGMOND_IMAGE_DIR:-$HOME/sigmond-images}"
LIST_URL="https://drive.google.com/embeddedfolderview?id=${FOLDER_ID}"
DL_URL="https://drive.usercontent.google.com/download?export=download&confirm=t&id="

ts(){ date -u '+%H:%M:%SZ'; }
say(){ printf '%s  %s\n' "$(ts)" "$*"; }
die(){ printf '%s  ABORT: %s\n' "$(ts)" "$*" >&2; exit 1; }

WANT_VER="" WANT_DEV="" LIST_ONLY=0 DL_ONLY=0 PENDING=0
# argval <option> <rest of argv...> -- the option's value, or die.  A missing
# value used to leave `shift 2` failing on the last argument, so the loop
# never advanced and the script hung.
argval(){
    case "${2:-}" in ""|-*) die "$1 needs a value (try --help)" ;; esac
    printf '%s' "$2"
}
while [ $# -gt 0 ]; do
    case "$1" in
        --version)       WANT_VER=$(argval "$@") || exit 1; shift 2 ;;
        --device)        WANT_DEV=$(argval "$@") || exit 1; shift 2 ;;
        --list)          LIST_ONLY=1; shift ;;
        --download-only) DL_ONLY=1; shift ;;
        --pending)       PENDING=1; shift ;;
        -y|--yes)        FORCE=1; shift ;;
        -h|--help)       awk 'NR>1 && /^#/{print; next} NR>1{exit}' "$0"; exit 0 ;;
        *)               die "unknown argument: $1 (try --help)" ;;
    esac
done
[ -n "$WANT_VER" ] && case "$WANT_VER" in v*) ;; *) WANT_VER="v$WANT_VER" ;; esac

OS=$(uname -s)
case "$OS" in
    Linux)  DISK_TOOLS="lsblk findmnt dd"
            sha256(){ sha256sum "$@"; }
            fsize(){ stat -c %s "$1"; } ;;
    Darwin) DISK_TOOLS="diskutil plutil dd"
            sha256(){ shasum -a 256 "$@"; }
            fsize(){ stat -f %z "$1"; } ;;
    *)      die "unsupported system: $OS (Linux or macOS only)" ;;
esac

# Only one candidate is ever offered, so a plain yes is enough; the device
# name is accepted too.  Anything else, including just Enter, writes nothing.
confirm_erase(){
    printf '%s  erase %s and write the image? [y/N] ' "$(ts)" "$DISK"
    read -r ans
    case "$ans" in
        y|Y|yes|Yes|YES|"$DISK") ;;
        *) die "not confirmed — nothing written" ;;
    esac
}
# Disk tools are checked only when a stick is to be written, so --list and
# --download-only work anywhere curl does.
need(){ for t in "$@"; do command -v "$t" >/dev/null || die "missing tool: $t"; done; }
need curl awk sed sort

# After a new image has downloaded and verified, keep it and the newest older
# version (the last good one) and delete every older one with its .sha256 and
# any .part.  Only sigmond-appliance-v*-release files in IMG_DIR are touched,
# and nothing newer than the image just fetched (--version may pick an old one).
prune_old_images(){
    local keep_prev old f n=0 freed=0
    keep_prev=$(ls "$IMG_DIR" 2>/dev/null \
        | sed -nE 's/^sigmond-appliance-(v[0-9.]+)-[0-9]{8}-release\..*/\1/p' | sort -uV \
        | awk -v v="$VER" '$0!=v' | while read -r o; do
              [ "$(printf '%s\n%s\n' "$o" "$VER" | sort -V | tail -1)" = "$VER" ] && echo "$o"
          done)
    old=$(printf '%s\n' "$keep_prev" | sed '$d')     # all but the newest older one
    for o in $old; do
        for f in "$IMG_DIR"/sigmond-appliance-"$o"-*-release.*; do
            [ -f "$f" ] || continue
            freed=$(( freed + $(fsize "$f") )); rm -f "$f" && n=$((n+1))
        done
    done
    [ "$n" -gt 0 ] && say "removed $n older image file(s) ($((freed/1048576)) MiB); kept $VER and $(printf '%s\n' "$keep_prev" | tail -1)"
    return 0
}

# The write needs root.  Plain sudo, which asks for a password if it needs
# one; this script never changes the machine's sudo policy.
need_sudo(){
    say "the write needs root: sudo may ask for your password"
    sudo -v || die "sudo is needed to write the stick"
}
MAX_GB="${SIGMOND_FLASH_MAX_GB:-1024}"
case "$MAX_GB" in ''|*[!0-9]*) die "SIGMOND_FLASH_MAX_GB must be a whole number of GiB" ;; esac
MAX_BYTES=$(( MAX_GB * 1073741824 ))
no_stick(){
    say "NO USB STICK FOUND — nothing written.  $*"
    exit 2      # distinct from a failure, as in rig-flash.sh: nothing to write to
}

# ── 1. what is published ────────────────────────────────────────────────────
# The embedded folder view is plain HTML, one <div class="flip-entry"
# id="entry-<FILEID>"> per file with its name in flip-entry-title.  Only the
# folder's top level is read, unless --pending also asks for pending/ (untested
# builds, a subfolder); see below.
say "reading the published image list"
LISTING=$(curl -fsL --max-time 60 "$LIST_URL") || die "cannot read the download folder ($LIST_URL)"
ENTRIES=$(printf '%s' "$LISTING" | sed 's/<div class="flip-entry" id="entry-/\n@@/g' \
    | sed -nE 's/^@@([A-Za-z0-9_-]+)".*flip-entry-title">([^<]+)<.*/\1 \2/p')
[ -n "$ENTRIES" ] || die "the download folder listing had no files (did Google change the page?)"

id_of(){ printf '%s\n' "$ENTRIES" | awk -v n="$1" '$2==n{print $1; exit}'; }

# ── self-update ─────────────────────────────────────────────────────────────
# The published copy of this script sits in the same folder.  If its
# FLASH_VERSION is newer than this one's, replace this file with it and ask for a rerun, so a
# fix reaches everyone who kept an old copy.  The new copy must look like this
# script and parse before it replaces anything.  SIGMOND_NO_UPDATE=1 skips this.
self_update(){
    [ "${SIGMOND_NO_UPDATE:-0}" = 1 ] && return 0
    local sid self new
    sid=$(id_of sigmond-flash-latest.sh); [ -n "$sid" ] || return 0
    self=$0; [ -f "$self" ] || return 0
    new=$(mktemp) || return 0
    if ! curl -fsL --max-time 60 -o "$new" "${DL_URL}${sid}" \
       || ! head -1 "$new" | grep -q '^#!/bin/bash' \
       || ! grep -q 'sigmond-flash-latest' "$new" || ! bash -n "$new" 2>/dev/null; then
        say "could not check for a newer version of this script; carrying on with this one"
        rm -f "$new"; return 0
    fi
    local pub
    pub=$(sed -n 's/^FLASH_VERSION=\([0-9.]*\).*/\1/p' "$new" | head -1)
    if [ -z "$pub" ] || [ "$pub" = "$FLASH_VERSION" ] \
       || [ "$(printf '%s\n%s\n' "$pub" "$FLASH_VERSION" | sort -V | tail -1)" != "$pub" ]; then
        rm -f "$new"; return 0      # published copy is not newer than this one
    fi
    if [ -w "$self" ] && cat "$new" > "$self"; then
        rm -f "$new"
        say "a newer version of this script ($pub; you had $FLASH_VERSION) was published; $self is now updated."
        say "Please run it again (same command)."
        exit 0
    fi
    mv "$new" "$IMG_DIR/sigmond-flash-latest.sh.new" 2>/dev/null \
        && say "a newer version of this script is at $IMG_DIR/sigmond-flash-latest.sh.new (cannot write $self); carrying on with this one"
    return 0
}
mkdir -p "$IMG_DIR" 2>/dev/null
self_update

# ── --pending: also the rig's untested builds ──────────────────────────────
# build-usb-v3.sh ships each image into pending/ as soon as it is built, while
# the nested and update tests still run; bless-release.sh later publishes it at
# the top level.  A developer who wants to test in parallel with the rig asks
# for --pending: the newest of pending/ AND the published images is picked, so
# it is never older than the newest blessed release.  Published entries come
# first, so a name in both folders is fetched from the blessed copy.  Read
# after self_update, so only the published copy of this script can replace it.
PENDING_NAMES=""
PUB_NAMES=$(printf '%s\n' "$ENTRIES" | awk '{print $2}')
if [ "$PENDING" = 1 ]; then
    PID=$(id_of pending)
    [ -n "$PID" ] || die "--pending: the download folder has no pending/ subfolder"
    say "reading pending/ (untested builds)"
    PLISTING=$(curl -fsL --max-time 60 "https://drive.google.com/embeddedfolderview?id=${PID}") \
        || die "cannot read the pending folder"
    PENTRIES=$(printf '%s' "$PLISTING" | sed 's/<div class="flip-entry" id="entry-/\n@@/g' \
        | sed -nE 's/^@@([A-Za-z0-9_-]+)".*flip-entry-title">([^<]+)<.*/\1 \2/p')
    PENDING_NAMES=$(printf '%s\n' "$PENTRIES" | awk '{print $2}')
    [ -n "$PENTRIES" ] && ENTRIES=$(printf '%s\n%s\n' "$ENTRIES" "$PENTRIES")
fi
# is_pending <file name> — in pending/ and not (yet) published.
is_pending(){
    printf '%s\n' "$PENDING_NAMES" | grep -qxF "$1" && ! printf '%s\n' "$PUB_NAMES" | grep -qxF "$1"
}

# Versions with BOTH an image and its checksum, newest last.
VERSIONS=$(printf '%s\n' "$ENTRIES" | awk '{print $2}' \
    | sed -nE 's/^sigmond-appliance-(v[0-9.]+)-([0-9]{8})-release\.img$/\1 \2/p' \
    | while read -r v d; do
          [ -n "$(id_of "sigmond-appliance-$v-$d-release.sha256")" ] && echo "$v $d"
      done | sort -V)
[ -n "$VERSIONS" ] || die "no published image with a checksum found"

if [ "$LIST_ONLY" = 1 ]; then
    if [ "$PENDING" = 1 ]; then say "published and pending images (newest last):"
    else say "published images (newest last):"; fi
    printf '%s\n' "$VERSIONS" | while read -r v d; do
        if is_pending "sigmond-appliance-$v-$d-release.img"; then
            echo "          $v $d  PENDING (untested)"
        else
            echo "          $v $d"
        fi
    done
    exit 0
fi

if [ -n "$WANT_VER" ]; then
    PICK=$(printf '%s\n' "$VERSIONS" | awk -v v="$WANT_VER" '$1==v' | tail -1)
    [ -n "$PICK" ] || die "$WANT_VER is not published$([ "$PENDING" = 1 ] && echo " or pending"); found: $(printf '%s\n' "$VERSIONS" | awk '{print $1}' | tr '\n' ' ')$([ "$PENDING" = 1 ] || echo "(add --pending for untested builds)")"
else
    PICK=$(printf '%s\n' "$VERSIONS" | tail -1)
fi
VER=${PICK% *}; DATE=${PICK#* }
STEM="sigmond-appliance-$VER-$DATE-release"
IMG_NAME="$STEM.img"
say "selected: $IMG_NAME  (version $VER, built $DATE)"
is_pending "$IMG_NAME" \
    && say "  ⚠ PENDING: an untested build from pending/ — not blessed; the rig may still be testing it"

# ── 2. the stick and every question, BEFORE the download ───────────────────
# ⛔ ASK NOTHING AFTER THE DOWNLOAD.  The download can take an hour, and this
# script used to find the stick and ask "erase it? [y/N]" only after it, so an
# operator who started it and walked away came back to a prompt and an
# unwritten stick (rob, 2026-11-11).  So the stick is found, checked, shown and
# confirmed now (--yes skips the question), sudo is settled now, and sudo's
# timestamp is kept fresh through the download.  After this nothing waits for
# a person.

# dinfo <disk> <key> — one field of `diskutil info -plist`.
dinfo(){ diskutil info -plist "$1" 2>/dev/null | plutil -extract "$2" raw -o - - 2>/dev/null; }

# pick_stick_macos / pick_stick_linux: find the stick by attribute, never by
# letter; refuse anything that is not a whole removable USB disk under the cap
# or that carries the running system; show it.  Set DISK, DBYTES, MODEL.
pick_stick_macos(){
    need $DISK_TOOLS
    if [ -n "$WANT_DEV" ]; then
        DISK="/dev/${WANT_DEV#/dev/}"; DISK="${DISK/rdisk/disk}"
        diskutil info "$DISK" >/dev/null 2>&1 || die "$DISK is not a disk (see: diskutil list external)"
        [ "$(dinfo "$DISK" WholeDisk)" = true ] || die "$DISK is not a whole disk (name the disk, e.g. /dev/disk5, not a partition)"
        [ "$(dinfo "$DISK" VirtualOrPhysical)" = Virtual ] && die "$DISK is a virtual disk (an APFS container or disk image), not a stick; refusing"
        [ "$(dinfo "$DISK" Internal)" = false ] || die "$DISK is not an external disk; refusing"
        [ "$(dinfo "$DISK" BusProtocol)" = USB ] || die "$DISK is not on USB (bus: $(dinfo "$DISK" BusProtocol)); refusing"
        if [ "$(dinfo "$DISK" RemovableMedia)" != true ]; then
            [ "${ALLOW_FIXED:-0}" = 1 ] || die "$DISK is not removable (a fixed disk, not a stick); refusing"
            say "ALLOW_FIXED=1 — proceeding against a FIXED disk"
        fi
    else
        DISK=""; N=0
        for d in $(diskutil list external physical | sed -nE 's#^(/dev/disk[0-9]+) .*#\1#p'); do
            [ "$(dinfo "$d" WholeDisk)" = true ] && [ "$(dinfo "$d" BusProtocol)" = USB ] \
                && [ "$(dinfo "$d" RemovableMedia)" = true ] && [ "$(dinfo "$d" Internal)" = false ] || continue
            sz=$(dinfo "$d" TotalSize)
            [ "${sz:-0}" -gt 0 ] && [ "$sz" -lt "$MAX_BYTES" ] \
                || { say "skipping $d: $(( ${sz:-0} / 1000000000 )) GB is over the ${MAX_GB} GiB cap for a stick"; continue; }
            DISK="$d"; N=$((N+1))
            say "found USB stick: $d  $(( $(dinfo "$d" TotalSize) / 1000000000 )) GB  $(dinfo "$d" MediaName)"
        done
        # loginwindow ejects removable disks attached while the screen is
        # locked (seen 2026-11-03): the stick is on the bus with no disk.
        [ "$N" -eq 0 ] && no_stick "If one IS plugged in: macOS ejects a stick attached while the screen is locked — unplug it and plug it in again with the Mac unlocked."
        [ "$N" -eq 1 ] || die "expected exactly one USB stick plugged in, found $N — plug in one, or name it: --device /dev/diskN (see: diskutil list external)"
    fi
    [ "$(dinfo "$DISK" Internal)" = true ] && die "$DISK is an internal disk; refusing"

    # Never the disk macOS runs from: its APFS container's physical store.
    BOOT=$(dinfo / ParentWholeDisk)
    for i in 0 1 2 3; do
        st=$(diskutil info -plist / | plutil -extract "APFSPhysicalStores.$i.APFSPhysicalStore" raw -o - - 2>/dev/null) || break
        BOOT="$BOOT $(dinfo "$st" ParentWholeDisk)"
    done
    for b in $BOOT; do
        [ "/dev/$b" = "$DISK" ] && die "$DISK CARRIES THE RUNNING SYSTEM — refusing"
    done

    DBYTES=$(dinfo "$DISK" TotalSize)
    [ -n "$DBYTES" ] || die "cannot read the size of $DISK"
    MODEL=$(dinfo "$DISK" MediaName)

    say "the stick: $DISK (${MODEL:-unknown model}, $((DBYTES/1000000000)) GB):"
    diskutil list "$DISK" 2>/dev/null | sed 's/^/          /'
}

lsq(){ lsblk -dnbo "$2" "$1" 2>/dev/null | head -1 | tr -d ' '; }
# stick_refusal <dev> — why <dev> may not be written, or nothing if it may.
# A whole disk, on USB, flagged removable; ALLOW_FIXED=1 lifts only the
# removable flag, and only for a named --device.
stick_refusal(){
    local t
    t=$(lsq "$1" TYPE)
    [ -n "$t" ] || { echo "$1 is not a block device"; return; }
    [ "$t" = disk ] || { echo "$1 is a $t, not a whole disk (name the disk, e.g. /dev/sdb, not /dev/sdb1)"; return; }
    t=$(lsq "$1" TRAN)
    [ "$t" = usb ] || { echo "$1 is not on USB (transport: ${t:-none}); refusing"; return; }
    if [ "$(lsq "$1" RM)" != 1 ]; then
        [ "${2:-}" = named ] && [ "${ALLOW_FIXED:-0}" = 1 ] && return
        echo "$1 is not removable (a fixed disk, not a stick); refusing"
    fi
}
pick_stick_linux(){
    need $DISK_TOOLS
    if [ -n "$WANT_DEV" ]; then
        # The canonical name (a /dev/disk/by-id link becomes /dev/sdX), so the
        # running-system comparison below sees the same string lsblk prints.
        DISK=$(lsblk -dnpo NAME "$WANT_DEV" 2>/dev/null | head -1 | tr -d ' ')
        [ -n "$DISK" ] || die "$WANT_DEV is not a block device"
        why=$(stick_refusal "$DISK" named)
        [ -z "$why" ] || die "$why"
        [ "$(lsq "$DISK" RM)" = 1 ] || say "ALLOW_FIXED=1 — proceeding against a USB disk that is not flagged removable"
    else
        DISK=""; N=0
        for d in $(lsblk -dnpo NAME 2>/dev/null); do
            [ -z "$(stick_refusal "$d")" ] || continue
            sz=$(lsq "$d" SIZE)
            [ "${sz:-0}" -gt 0 ] && [ "$sz" -lt "$MAX_BYTES" ] \
                || { say "skipping $d: $(( ${sz:-0} / 1000000000 )) GB is over the ${MAX_GB} GiB cap for a stick"; continue; }
            DISK="$d"; N=$((N+1))
            say "found USB stick: $d  $((sz/1000000000)) GB"
        done
        [ "$N" -eq 0 ] && no_stick "Plug one in and run this again."
        [ "$N" -eq 1 ] || die "expected exactly one USB stick plugged in, found $N — plug in one, or name it: --device /dev/sdX"
    fi

    # Never the disk the system runs from.  Walk each system mount up to its
    # whole disk(s) with lsblk -s, so a root on LVM, LUKS or md is caught too
    # (its own PKNAME is a dm or md device, not the disk).
    for m in / /boot /boot/efi /usr /var /home; do
        src=$(findmnt -nvo SOURCE "$m" 2>/dev/null) || continue
        [ -n "$src" ] || continue
        for top in $(lsblk -nsrpo NAME,TYPE "$src" 2>/dev/null | awk '$2=="disk"{print $1}'); do
            [ "$top" = "$DISK" ] && die "$DISK CARRIES THE RUNNING SYSTEM ($m) — refusing"
        done
    done
    BUSY=""
    while read -r part mp; do
        [ -n "$mp" ] || continue
        case "$mp" in /media/*|/mnt/*|/run/media/*) continue ;; esac
        BUSY="$BUSY $part=$mp"
    done < <(lsblk -nro NAME,MOUNTPOINT "$DISK" 2>/dev/null | tail -n +2)
    [ -z "$BUSY" ] || die "$DISK has partitions mounted in service:$BUSY — refusing"

    DBYTES=$(lsq "$DISK" SIZE)
    [ "${DBYTES:-0}" -gt 0 ] || die "cannot read the size of $DISK"
    MODEL=$(lsblk -dno VENDOR,MODEL "$DISK" 2>/dev/null | tr -s ' ' | sed 's/^ //;s/ $//')

    say "the stick: $DISK (${MODEL:-unknown model}, $((DBYTES/1000000000)) GB):"
    lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$DISK" 2>/dev/null | sed 's/^/          /'
}

# The image's size before the download, when it is already here or the server
# says: a stick too small is refused now, not after an hour.
early_size(){
    local f="$IMG_DIR/$IMG_NAME"
    if [ -f "$f" ]; then fsize "$f"; return; fi
    curl -fsIL --max-time 60 "${DL_URL}$(id_of "$IMG_NAME")" 2>/dev/null | tr -d '\r' \
        | awk 'tolower($1)=="content-length:"{n=$2} END{print n+0}'
}

if [ "$DL_ONLY" != 1 ]; then
    if [ "$OS" = Darwin ]; then pick_stick_macos; else pick_stick_linux; fi
    ESIZE=$(early_size)
    [ "${ESIZE:-0}" -gt 0 ] && [ "$ESIZE" -gt "$DBYTES" ] \
        && die "the image ($((ESIZE/1048576)) MiB) does not fit on $DISK ($((DBYTES/1048576)) MiB)"
    if [ "${DRY_RUN:-0}" = 1 ]; then
        say "DRY_RUN=1 — this stick will not be written; checking the image next"
    elif [ "${FORCE:-0}" = 1 ]; then
        say "--yes: $DISK will be erased and written after the download, without asking"
    else
        # No terminal (e.g. `curl ... | bash`) means no one to confirm: refuse rather
        # than erase a disk unasked.  Download the script and run it instead.
        [ -t 0 ] || die "no terminal to confirm on — run the downloaded script directly (bash sigmond-flash-latest.sh), or add --yes"
        confirm_erase
    fi
    if [ "${DRY_RUN:-0}" != 1 ]; then
        need_sudo
        # Keep sudo's timestamp fresh through the download, so the write after
        # it never stops to ask for the password again.
        ( while kill -0 $$ 2>/dev/null; do sudo -n -v 2>/dev/null; sleep 50; done ) &
        SUDO_KEEPER=$!
        trap 'kill "$SUDO_KEEPER" 2>/dev/null' EXIT
        say "all questions answered — the rest runs unattended"
    fi
fi

# ── 2b. the checksum, then the image (reused if already here and good) ─────
mkdir -p "$IMG_DIR" || die "cannot create $IMG_DIR"
IMG="$IMG_DIR/$IMG_NAME"
WANT_SHA=$(curl -fsL --max-time 60 "${DL_URL}$(id_of "$STEM.sha256")" | awk 'NR==1{print $1}')
printf '%s' "$WANT_SHA" | grep -qE '^[0-9a-f]{64}$' || die "could not read the published sha256 for $IMG_NAME"
say "published sha256 ${WANT_SHA:0:16}…"

if [ -f "$IMG" ]; then
    say "found $IMG already — checking it"
    if [ "$(sha256 "$IMG" | awk '{print $1}')" = "$WANT_SHA" ]; then
        say "  it matches the published checksum; not downloading again"
    else
        say "  it does NOT match; downloading again"
        rm -f "$IMG"
    fi
fi
if [ ! -f "$IMG" ]; then
    IMG_ID=$(id_of "$IMG_NAME")
    SIZE=$(curl -fsIL --max-time 60 "${DL_URL}${IMG_ID}" | tr -d '\r' \
        | awk 'tolower($1)=="content-length:"{n=$2} END{print n+0}')
    FREE=$(( $(df -Pk "$IMG_DIR" | awk 'NR==2{print $4}') * 1024 ))
    [ "${SIZE:-0}" -gt 0 ] && [ "$FREE" -lt "$SIZE" ] \
        && die "$IMG_DIR has $((FREE/1048576)) MiB free; the image needs $((SIZE/1048576)) MiB (set SIGMOND_IMAGE_DIR elsewhere)"
    say "downloading $((SIZE/1048576)) MiB to $IMG_DIR (resumes if interrupted; rerun to continue)"
    curl -fL --retry 5 --retry-delay 5 -C - -o "$IMG.part" "${DL_URL}${IMG_ID}" \
        || die "download failed — rerun this script to resume"
    BYTES=$(fsize "$IMG.part")
    # A Drive error page or quota interstitial is a few KB of HTML.
    [ "$BYTES" -gt 1000000000 ] || { head -c 300 "$IMG.part" >&2; echo >&2; rm -f "$IMG.part"; die "download is only $BYTES bytes — Google returned a page, not the image; try again later"; }
    say "verifying the download"
    GOT=$(sha256 "$IMG.part" | awk '{print $1}')
    if [ "$GOT" != "$WANT_SHA" ]; then
        rm -f "$IMG.part"
        die "download checksum ${GOT:0:16}… does not match the published ${WANT_SHA:0:16}… — deleted; rerun to fetch again"
    fi
    mv "$IMG.part" "$IMG"
    say "download verified: $IMG"
    prune_old_images
fi
BYTES=$(fsize "$IMG")

if [ "$DL_ONLY" = 1 ]; then
    say "DONE (download only): $IMG is $VER, sha256 ${WANT_SHA:0:16}…"
    exit 0
fi

# ── 3. write and read back — nothing here waits for a person ───────────────
[ "$BYTES" -le "$DBYTES" ] || die "the image ($((BYTES/1048576)) MiB) does not fit on $DISK ($((DBYTES/1048576)) MiB)"
if [ "${DRY_RUN:-0}" = 1 ]; then
    say "DRY_RUN=1 — every check passed; nothing written"
    exit 0
fi
# The stick was chosen before the download; make sure it is still that one
# (an hour is long enough to unplug it or swap it).
if [ "$OS" = Darwin ]; then
    [ "$(dinfo "$DISK" TotalSize)" = "$DBYTES" ] && [ "$(dinfo "$DISK" MediaName)" = "$MODEL" ]
else
    [ "$(lsq "$DISK" SIZE)" = "$DBYTES" ]
fi || die "$DISK is no longer the stick confirmed before the download (unplugged or swapped?) — nothing written; rerun"

write_macos(){
    diskutil unmountDisk "$DISK" >/dev/null || die "cannot unmount $DISK (close any Finder windows on it)"
    # The raw node (/dev/rdiskN) skips the buffer cache: several times faster.
    RAW="${DISK/disk/rdisk}"
    say "writing $((BYTES/1048576)) MiB to $RAW — a few minutes"
    START=$(date +%s)
    sudo dd if="$IMG" of="$RAW" bs=4194304 status=progress || die "write failed"
    sync
    EL=$(( $(date +%s) - START )); [ "$EL" -lt 1 ] && EL=1
    say "wrote in ${EL}s"

    # Read back through the raw node in whole 1 MiB blocks (raw reads must be
    # block-aligned), trimmed to the image's exact byte count.
    say "reading the stick back and comparing"
    diskutil unmountDisk "$DISK" >/dev/null 2>&1
    BLKS=$(( (BYTES + 1048575) / 1048576 ))
    BACK=$(sudo dd if="$RAW" bs=1048576 count="$BLKS" 2>/dev/null | head -c "$BYTES" | sha256 | awk '{print $1}')
}

write_linux(){
    # ── 4. write ────────────────────────────────────────────────────────────────
    for p in $(lsblk -nro NAME "$DISK" | tail -n +2); do
        sudo umount "/dev/$p" 2>/dev/null && say "unmounted /dev/$p"
    done
    say "writing $((BYTES/1048576)) MiB — about 2 min on USB 3, 10 min on USB 2"
    START=$(date +%s)
    sudo dd if="$IMG" of="$DISK" bs=4M oflag=direct conv=fsync status=progress || die "write failed"
    sudo sync
    EL=$(( $(date +%s) - START )); [ "$EL" -lt 1 ] && EL=1
    say "wrote in ${EL}s"

    # ── 5. read it back — the only step that proves anything ──────────────────
    # Exactly the image's byte count; `head -c` reading a device is safe here
    # (it is `dd | head` that dies of SIGPIPE after a good write).
    say "reading the stick back and comparing"
    sudo blockdev --flushbufs "$DISK" 2>/dev/null
    BACK=$(sudo head -c "$BYTES" "$DISK" | sha256sum | awk '{print $1}')
}

if [ "$OS" = Darwin ]; then write_macos; else write_linux; fi
if [ "$BACK" = "$WANT_SHA" ]; then
    echo
    say "VERIFIED — $DISK matches the published image byte for byte"
    say "INSTALLED ON THE STICK: $IMG_NAME"
    say "   version $VER, built $DATE, sha256 $WANT_SHA"
    II=$(id_of "$STEM.INSTALL.html")
    [ -n "$II" ] && say "   install guide: https://drive.google.com/file/d/$II/view"
    [ "$OS" = Darwin ] && diskutil eject "$DISK" >/dev/null 2>&1 && say "ejected $DISK"
    say "Remove the stick. Connect the RX888 (and GPSDO) BEFORE booting the target machine from it."
else
    die "READ-BACK MISMATCH: stick ${BACK:0:16}… vs image ${WANT_SHA:0:16}… — DO NOT USE THIS STICK; rerun"
fi
