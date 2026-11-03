#!/bin/bash
# sigmond-flash-latest.sh — download the NEWEST published Sigmond appliance
# image and write it to a USB stick, then PROVE the stick matches.
#
# One script for every release.  It reads the public download folder, picks
# the highest version that has both an .img and its .sha256, downloads it (or
# reuses a copy already downloaded and verified), checks the sha256, writes
# the stick and reads it back.  Nothing needs a Google login or rclone: the
# folder is "anyone with the link", and curl is enough.
#
# Runs on Linux and macOS.
#
# Usage (as a normal user with sudo; the write itself needs root):
#   bash sigmond-flash-latest.sh                  # newest image, auto-find the stick
#   bash sigmond-flash-latest.sh --list           # show what is published, write nothing
#   bash sigmond-flash-latest.sh --version v3.85  # a specific published version
#   bash sigmond-flash-latest.sh --device /dev/sdb     (macOS: /dev/disk5)
#   bash sigmond-flash-latest.sh --download-only  # fetch and verify, no stick
#   DRY_RUN=1 bash sigmond-flash-latest.sh        # every check, no write
#
# Environment:
#   SIGMOND_IMAGE_DIR     where images are kept   (default ~/sigmond-images)
#   SIGMOND_IMAGE_FOLDER  Drive folder id          (default: the HamSCI release folder)
#   FORCE=1               skip the "erase it? [y/N]" confirmation
#   ALLOW_FIXED=1         allow a non-removable target (never needed for a stick)
#
# The stick is found by attribute (USB transport AND removable), never by a
# letter, and a disk carrying the running system or an in-service mount is
# refused.  On macOS the same attributes come from `diskutil info`: an
# external USB hard disk reports "Removable Media: Fixed" and is never picked.  These are the rules of flash-usb.sh in the appliance repo, which
# writes an image you already have; this script adds the fetch.
set -uo pipefail

FOLDER_ID="${SIGMOND_IMAGE_FOLDER:-1Eym7xsP_qVvbGOVmlXER73K3jx6J7dQs}"
IMG_DIR="${SIGMOND_IMAGE_DIR:-$HOME/sigmond-images}"
LIST_URL="https://drive.google.com/embeddedfolderview?id=${FOLDER_ID}"
DL_URL="https://drive.usercontent.google.com/download?export=download&confirm=t&id="

ts(){ date -u '+%H:%M:%SZ'; }
say(){ printf '%s  %s\n' "$(ts)" "$*"; }
die(){ printf '%s  ABORT: %s\n' "$(ts)" "$*" >&2; exit 1; }

WANT_VER="" WANT_DEV="" LIST_ONLY=0 DL_ONLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --version)       WANT_VER="${2:-}"; shift 2 ;;
        --device)        WANT_DEV="${2:-}"; shift 2 ;;
        --list)          LIST_ONLY=1; shift ;;
        --download-only) DL_ONLY=1; shift ;;
        -h|--help)       sed -n '2,30p' "$0"; exit 0 ;;
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

# The write needs root.  When sudo would ask for a password, offer once to let
# this account use sudo without one (a drop-in under /etc/sudoers.d, checked
# with visudo before it is installed).  The default is no: sudo then just asks.
offer_nopasswd_sudo(){
    sudo -n true 2>/dev/null && return 0
    [ -t 0 ] && [ "${FORCE:-0}" != 1 ] || return 0
    local u f tmp grp ans
    u=$(id -un); f="/etc/sudoers.d/90-nopasswd-${u//[^A-Za-z0-9_-]/_}"
    say "sudo will ask for your password for the write (and again for the read-back"
    say "  if it takes longer than sudo remembers it)."
    printf '%s  let %s use sudo without a password from now on? This writes %s [y/N] ' "$(ts)" "$u" "$f"
    read -r ans
    case "$ans" in y|Y|yes|Yes|YES) ;; *) say "ok — sudo will ask"; return 0 ;; esac
    tmp=$(mktemp) || die "cannot make a temp file"
    printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$u" > "$tmp"
    [ "$OS" = Darwin ] && grp=wheel || grp=root
    if sudo visudo -cqf "$tmp" && sudo install -m 0440 -o root -g "$grp" "$tmp" "$f" && sudo -n true 2>/dev/null; then
        say "done: $u now uses sudo without a password (undo: sudo rm $f)"
    else
        say "could not set that up; sudo will ask for your password"
    fi
    rm -f "$tmp"
}

# ── 1. what is published ────────────────────────────────────────────────────
# The embedded folder view is plain HTML, one <div class="flip-entry"
# id="entry-<FILEID>"> per file with its name in flip-entry-title.  Only the
# folder's top level is read: pending/ (untested builds) is a subfolder and
# never offered.
say "reading the published image list"
LISTING=$(curl -fsL --max-time 60 "$LIST_URL") || die "cannot read the download folder ($LIST_URL)"
ENTRIES=$(printf '%s' "$LISTING" | sed 's/<div class="flip-entry" id="entry-/\n@@/g' \
    | sed -nE 's/^@@([A-Za-z0-9_-]+)".*flip-entry-title">([^<]+)<.*/\1 \2/p')
[ -n "$ENTRIES" ] || die "the download folder listing had no files (did Google change the page?)"

id_of(){ printf '%s\n' "$ENTRIES" | awk -v n="$1" '$2==n{print $1; exit}'; }

# Versions with BOTH an image and its checksum, newest last.
VERSIONS=$(printf '%s\n' "$ENTRIES" | awk '{print $2}' \
    | sed -nE 's/^sigmond-appliance-(v[0-9.]+)-([0-9]{8})-release\.img$/\1 \2/p' \
    | while read -r v d; do
          [ -n "$(id_of "sigmond-appliance-$v-$d-release.sha256")" ] && echo "$v $d"
      done | sort -V)
[ -n "$VERSIONS" ] || die "no published image with a checksum found"

if [ "$LIST_ONLY" = 1 ]; then
    say "published images (newest last):"
    printf '%s\n' "$VERSIONS" | sed 's/^/          /'
    exit 0
fi

if [ -n "$WANT_VER" ]; then
    PICK=$(printf '%s\n' "$VERSIONS" | awk -v v="$WANT_VER" '$1==v' | tail -1)
    [ -n "$PICK" ] || die "$WANT_VER is not published; published: $(printf '%s\n' "$VERSIONS" | awk '{print $1}' | tr '\n' ' ')"
else
    PICK=$(printf '%s\n' "$VERSIONS" | tail -1)
fi
VER=${PICK% *}; DATE=${PICK#* }
STEM="sigmond-appliance-$VER-$DATE-release"
IMG_NAME="$STEM.img"
say "selected: $IMG_NAME  (version $VER, built $DATE)"

# ── 2. the checksum, then the image (reused if already here and good) ──────
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
fi
BYTES=$(fsize "$IMG")

if [ "$DL_ONLY" = 1 ]; then
    say "DONE (download only): $IMG is $VER, sha256 ${WANT_SHA:0:16}…"
    exit 0
fi

# ── 3-5 on macOS: the same rules, from diskutil ─────────────────────────────
# dinfo <disk> <key> — one field of `diskutil info -plist`.
dinfo(){ diskutil info -plist "$1" 2>/dev/null | plutil -extract "$2" raw -o - - 2>/dev/null; }

flash_macos(){
    need $DISK_TOOLS
    if [ -n "$WANT_DEV" ]; then
        DISK="/dev/${WANT_DEV#/dev/}"; DISK="${DISK/rdisk/disk}"
        [ "$(dinfo "$DISK" WholeDisk)" = true ] || die "$DISK is not a whole disk (name the disk, e.g. /dev/disk5, not a partition)"
        if [ "$(dinfo "$DISK" RemovableMedia)" != true ]; then
            [ "${ALLOW_FIXED:-0}" = 1 ] || die "$DISK is not removable (a fixed disk, not a stick); refusing"
            say "ALLOW_FIXED=1 — proceeding against a FIXED disk"
        fi
    else
        DISK=""; N=0
        for d in $(diskutil list external physical | sed -nE 's#^(/dev/disk[0-9]+) .*#\1#p'); do
            [ "$(dinfo "$d" BusProtocol)" = USB ] && [ "$(dinfo "$d" RemovableMedia)" = true ] \
                && [ "$(dinfo "$d" Internal)" = false ] || continue
            DISK="$d"; N=$((N+1))
            say "found USB stick: $d  $(( $(dinfo "$d" TotalSize) / 1000000000 )) GB  $(dinfo "$d" MediaName)"
        done
        # loginwindow ejects removable disks attached while the screen is
        # locked (seen 2026-11-03): the stick is on the bus with no disk.
        [ "$N" -eq 0 ] && say "no stick found. If one IS plugged in: macOS ejects a stick attached while the screen is locked — unplug it and plug it in again with the Mac unlocked."
        [ "$N" -eq 1 ] || die "expected exactly one USB stick plugged in, found $N — plug in one, or name it: --device /dev/diskN (see: diskutil list external)"
    fi
    [ "$(dinfo "$DISK" Internal)" = true ] && [ "${ALLOW_FIXED:-0}" != 1 ] && die "$DISK is an internal disk; refusing"

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
    [ "$BYTES" -le "$DBYTES" ] || die "the image ($((BYTES/1048576)) MiB) does not fit on $DISK ($((DBYTES/1048576)) MiB)"
    MODEL=$(dinfo "$DISK" MediaName)

    say "about to ERASE $DISK (${MODEL:-unknown model}, $((DBYTES/1000000000)) GB):"
    diskutil list "$DISK" 2>/dev/null | sed 's/^/          /'
    if [ "${DRY_RUN:-0}" = 1 ]; then
        say "DRY_RUN=1 — every check passed; nothing written"
        exit 0
    fi
    # No terminal (e.g. `curl ... | bash`) means no one to confirm: refuse rather
    # than erase a disk unasked.  Download the script and run it instead.
    if [ "${FORCE:-0}" != 1 ]; then
        [ -t 0 ] || die "no terminal to confirm on — run the downloaded script directly (bash sigmond-flash-latest.sh), or set FORCE=1"
        confirm_erase
    fi
    offer_nopasswd_sudo

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

if [ "$OS" = Darwin ]; then
    flash_macos
else
    need $DISK_TOOLS
    # ── 3. the stick, found by attribute and never by letter ───────────────────
    if [ -n "$WANT_DEV" ]; then
        [ -b "$WANT_DEV" ] || die "$WANT_DEV is not a block device"
        DISK="$WANT_DEV"
        rm_=$(lsblk -dno RM "$DISK" | tr -d ' ')
        if [ "$rm_" != "1" ]; then
            [ "${ALLOW_FIXED:-0}" = 1 ] || die "$DISK is not removable (a fixed disk, not a stick); refusing"
            say "ALLOW_FIXED=1 — proceeding against a FIXED disk"
        fi
    else
        DISK=""; N=0
        while read -r name size tran rm_ type; do
            [ "$type" = disk ] && [ "$tran" = usb ] && [ "$rm_" = 1 ] || continue
            DISK="/dev/$name"; N=$((N+1))
            say "found USB stick: /dev/$name  $size"
        done < <(lsblk -dno NAME,SIZE,TRAN,RM,TYPE)
        [ "$N" -eq 1 ] || die "expected exactly one USB stick plugged in, found $N — plug in one, or name it: --device /dev/sdX"
    fi

    for m in / /boot /boot/efi; do
        src=$(findmnt -no SOURCE "$m" 2>/dev/null) || continue
        pk=$(lsblk -no PKNAME "$src" 2>/dev/null | head -1)
        [ -n "$pk" ] && [ "/dev/$pk" = "$DISK" ] && die "$DISK CARRIES THE RUNNING SYSTEM — refusing"
    done
    BUSY=""
    while read -r part mp; do
        [ -n "$mp" ] || continue
        case "$mp" in /media/*|/mnt/*|/run/media/*) continue ;; esac
        BUSY="$BUSY $part=$mp"
    done < <(lsblk -nro NAME,MOUNTPOINT "$DISK" 2>/dev/null | tail -n +2)
    [ -z "$BUSY" ] || die "$DISK has partitions mounted in service:$BUSY — refusing"

    offer_nopasswd_sudo
    DBYTES=$(sudo blockdev --getsize64 "$DISK") || die "cannot read the size of $DISK (needs sudo)"
    [ "$BYTES" -le "$DBYTES" ] || die "the image ($((BYTES/1048576)) MiB) does not fit on $DISK ($((DBYTES/1048576)) MiB)"
    MODEL=$(lsblk -dno VENDOR,MODEL "$DISK" 2>/dev/null | tr -s ' ' | sed 's/^ //;s/ $//')

    say "about to ERASE $DISK (${MODEL:-unknown model}, $((DBYTES/1000000000)) GB):"
    lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$DISK" 2>/dev/null | sed 's/^/          /'
    if [ "${DRY_RUN:-0}" = 1 ]; then
        say "DRY_RUN=1 — every check passed; nothing written"
        exit 0
    fi
    # No terminal (e.g. `curl ... | bash`) means no one to confirm: refuse rather
    # than erase a disk unasked.  Download the script and run it instead.
    if [ "${FORCE:-0}" != 1 ]; then
        [ -t 0 ] || die "no terminal to confirm on — run the downloaded script directly (bash sigmond-flash-latest.sh), or set FORCE=1"
        confirm_erase
    fi

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
fi
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
