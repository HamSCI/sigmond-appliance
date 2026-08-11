#!/bin/bash
# Sigmond appliance USB image builder v3 — runs on B3 in ~/appliance/v3.
#
# v3 over v2:
#   - EXPLICIT VERSION per image (arg 1, e.g. v3.0) baked into: the image
#     filename, the Proxmox host fqdn, the decoder VM name, /etc/motd,
#     QUICKSTART — so test sticks are never confused (rob 2026-07-26).
#   - the SIGMOND REPO rides in the payload (host tuning scripts:
#     host-discover/host-apply/cpu-pin template used by the importer).
#   - image is SHIPPED TO wd30 IMMEDIATELY after build, before testing,
#     so rob/Michael can download+burn in parallel with the nested test.
#
# Packaging rules (hard-won, June 2026):
#   - ISO bytes stay PRISTINE; payload appended at the 1MiB-aligned
#     iso9660 volsize offset. NEVER a GPT partition for the payload.
#   - reboot-mode = "power-off" stays: remove-the-stick cue + loop guard.
#
# Usage: build-usb-v3.sh <version> [--release] [--no-ship]
#   e.g.: build-usb-v3.sh v3.0
set -eu
cd "$HOME/appliance/v3"
LOG="$PWD/usb-build.log"
exec > >(tee -a "$LOG") 2>&1
say(){ echo "[usb $(date '+%T')] $*"; }

VERSION="${1:?usage: build-usb-v3.sh <version e.g. v3.0> [--release] [--no-ship]}"
shift
RELEASE=0; SHIP=1
for a in "$@"; do
    case "$a" in
        --release) RELEASE=1 ;;
        --no-ship) SHIP=0 ;;
    esac
done
case "$VERSION" in v[0-9]*) ;; *) say "FATAL: version must look like v3.0"; exit 1;; esac
VTAG="${VERSION//./-}"

SRC_ISO="$HOME/appliance/iso/proxmox-ve_9.1-1.iso"
TPL=sigmond-decoder-template-v3.qcow2
[ -f "$SRC_ISO" ] || { say "FATAL: $SRC_ISO missing"; exit 1; }
[ -f "$TPL" ] || { say "FATAL: $TPL missing (build the golden VM first)"; exit 1; }
# The wizard is versioned in HamSCI/sigmond (scripts/proxmox/sigmond-wizard.sh)
# as of 0774d81.  Take it from the checkout rather than a local copy: it used
# to live only in this rig, unversioned, and the whole point of putting it in
# the repo was to stop the rig and the repo drifting.  Refuse to build from a
# checkout whose wizard is uncommitted, and warn if the checkout is not at
# origin/main -- the image would otherwise ship something nobody can identify.
SIGMOND_REPO="${SIGMOND_REPO:-$HOME/appliance/repos/sigmond}"
WIZ_SRC="$SIGMOND_REPO/scripts/proxmox/sigmond-wizard.sh"
[ -f "$WIZ_SRC" ] || { say "FATAL: wizard missing at $WIZ_SRC"; exit 1; }
if [ -n "$(git -C "$SIGMOND_REPO" status --porcelain -- scripts/proxmox/sigmond-wizard.sh 2>/dev/null)" ]; then
    say "FATAL: $WIZ_SRC has uncommitted changes — commit and push first"; exit 1
fi
git -C "$SIGMOND_REPO" fetch origin >/dev/null 2>&1 || true
_wiz_head=$(git -C "$SIGMOND_REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)
if [ "$(git -C "$SIGMOND_REPO" rev-parse HEAD 2>/dev/null)" \
   != "$(git -C "$SIGMOND_REPO" rev-parse origin/main 2>/dev/null)" ]; then
    say "WARN: sigmond checkout at $_wiz_head is not origin/main — wizard may be stale"
fi
cp "$WIZ_SRC" sigmond-wizard.sh
say "wizard sourced from sigmond $_wiz_head ($(wc -l < sigmond-wizard.sh) lines)"
[ -f sigmond-wizard.sh ] || { say "FATAL: sigmond-wizard.sh missing"; exit 1; }
[ -f firstboot-v3.sh ] || { say "FATAL: firstboot-v3.sh missing"; exit 1; }

say "=== building sigmond-appliance $VERSION (tag $VTAG, release=$RELEASE) ==="

say "answer file (fqdn carries the version)"
sed -e "s|^fqdn = .*|fqdn = \"sigmond-appliance-${VTAG}.local\"|" \
    ../build/answer.toml > answer-v3.toml
grep -q "sigmond-appliance-${VTAG}" answer-v3.toml || { say "FATAL: fqdn substitution failed"; exit 1; }
if [ "$RELEASE" = 1 ]; then
    sed -i '/^root-ssh-keys/d' answer-v3.toml
    say "release mode: test ssh key stripped"
fi
grep -q 'reboot-mode = "power-off"' answer-v3.toml || { say "FATAL: answer.toml lost power-off mode"; exit 1; }

say "firstboot + quickstart + wizard (version substitution)"
sed -e "s|@@VERSION@@|${VERSION}|g" firstboot-v3.sh > firstboot-rendered.sh
sed -e "s|@@VERSION@@|${VERSION}|g" -e "s|@@VTAG@@|${VTAG}|g" QUICKSTART.txt > QUICKSTART-rendered.txt
# decoder VM is VMID 100 in v3 (fleet convention); wizard default was 120
sed -e 's|SIGMOND_VMID:-120|SIGMOND_VMID:-100|g' \
    -e 's|"SIGMOND_VMID", "120"|"SIGMOND_VMID", "100"|g' sigmond-wizard.sh > sigmond-wizard-rendered.sh
if grep -q '120' sigmond-wizard-rendered.sh; then
    grep -n '120' sigmond-wizard-rendered.sh | grep -qiv 'timeout\|sleep\|port\|freq\|OnUnitActiveSec' && say "WARN: wizard still mentions 120 somewhere — check"
fi

say "sigmond repo payload (host tuning scripts ride on the stick)"
if [ ! -d ../sigmond-ref/.git ]; then
    git clone -q --depth 1 git@github.com:HamSCI/sigmond ../sigmond-ref
fi
git -C ../sigmond-ref pull -q 2>/dev/null || true
SIGREV=$(git -C ../sigmond-ref rev-parse --short HEAD)
tar czf sigmond.tar.gz -C .. --transform 's|^sigmond-ref|sigmond|' sigmond-ref
say "sigmond payload @ $SIGREV"

say "sigmond-rac payload"
if [ ! -d sigmond-rac ]; then
    git clone -q https://github.com/HamSCI/sigmond-rac sigmond-rac
fi
git -C sigmond-rac pull -q 2>/dev/null || true
tar czf sigmond-rac.tar.gz sigmond-rac

say "prepare-iso (embed answer + firstboot)"
# a stale .tmp from an interrupted run makes xorriso append to a full image
# ("Image size ... exceeds free space on media 0s" — killed the first v3.4
# build 2026-07-27); the assistant writes it next to the SOURCE iso
rm -f pve-sc-v3.iso "$(dirname "$SRC_ISO")"/pve-sc-v3.iso.tmp
proxmox-auto-install-assistant prepare-iso "$SRC_ISO" \
    --fetch-from iso --answer-file answer-v3.toml \
    --on-first-boot firstboot-rendered.sh --output pve-sc-v3.iso
[ -f pve-sc-v3.iso ] || { say "FATAL: prepare-iso produced nothing"; exit 1; }

say "ESP FAT12→FAT16 in-place conversion (AMI firmwares silently refuse FAT12"
say "ESPs on USB media — B4 AZW SER offered no boot option, 2026-07-26)"
ESP_START=$(sgdisk -i 2 pve-sc-v3.iso 2>/dev/null | awk '/First sector/{print $3}')
ESP_END=$(sgdisk -i 2 pve-sc-v3.iso 2>/dev/null | awk '/Last sector/{print $3}')
[ -n "$ESP_START" ] && [ -n "$ESP_END" ] || { say "FATAL: cannot locate ESP in prepared iso"; exit 1; }
ESP_SECS=$(( ESP_END - ESP_START + 1 ))
rm -rf /tmp/espfix.$$; mkdir -p /tmp/espfix.$$/old /tmp/espfix.$$/new
dd if=pve-sc-v3.iso of=/tmp/espfix.$$/esp-old.bin bs=512 skip="$ESP_START" count="$ESP_SECS" status=none
mount -o ro,loop /tmp/espfix.$$/esp-old.bin /tmp/espfix.$$/old
dd if=/dev/zero of=/tmp/espfix.$$/esp-new.bin bs=512 count="$ESP_SECS" status=none
/usr/sbin/mkfs.vfat -F 16 -s 1 /tmp/espfix.$$/esp-new.bin >/dev/null
mount -o loop /tmp/espfix.$$/esp-new.bin /tmp/espfix.$$/new
cp -r /tmp/espfix.$$/old/. /tmp/espfix.$$/new/
umount /tmp/espfix.$$/old /tmp/espfix.$$/new
file /tmp/espfix.$$/esp-new.bin | grep -q "FAT (16 bit)" || { say "FATAL: ESP rebuild is not FAT16"; exit 1; }
dd if=/tmp/espfix.$$/esp-new.bin of=pve-sc-v3.iso bs=512 seek="$ESP_START" conv=notrunc status=none
rm -rf /tmp/espfix.$$
say "ESP rewritten as FAT16 at sectors ${ESP_START}-${ESP_END} (contents identical)"

say "MBR active flag on partition entry 1 (legacy AMI BIOSes refuse disks"
say "with no 0x80 active partition — Kamrui mini PC, 2026-07-27; UEFI ignores it)"
printf '\x80' | dd of=pve-sc-v3.iso bs=1 seek=446 conv=notrunc status=none

say "payload ext4 (template + wizard + sigmond + rac + quickstart)"
PAYSZ_MB=$(( $(stat -c%s "$TPL")/1048576 + $(stat -c%s sigmond.tar.gz)/1048576 + $(stat -c%s sigmond-rac.tar.gz)/1048576 + 320 ))
rm -f payload-v3.ext4
dd if=/dev/zero of=payload-v3.ext4 bs=1M count="$PAYSZ_MB" status=none
/usr/sbin/mkfs.ext4 -q -L SIGTPL payload-v3.ext4
mkdir -p /tmp/sigpay.$$
mount -o loop payload-v3.ext4 /tmp/sigpay.$$
cp "$TPL" sigmond.tar.gz sigmond-rac.tar.gz /tmp/sigpay.$$/
cp sigmond-wizard-rendered.sh /tmp/sigpay.$$/sigmond-wizard.sh
cp QUICKSTART-rendered.txt /tmp/sigpay.$$/QUICKSTART.txt
# FFT wisdom seed (from the live B4 appliance VM, fftw 3.3.10): smd apply
# gates radiod START on /etc/fftw/wisdomf existing, and the in-VM planner
# grinds for over an hour on first boot — the wizard pushes this seed so
# radiod starts immediately (fftw ignores entries that don't match the CPU)
WSEED=""
[ -f wisdomf-seed ] && WSEED=wisdomf-seed
[ -z "$WSEED" ] && [ -f wisdomf-ryzen5825u ] && WSEED=wisdomf-ryzen5825u
[ -n "$WSEED" ] && cp "$WSEED" /tmp/sigpay.$$/wisdomf-seed \
  || say "WARN: no wisdom seed in rig — first radiod start may wait on the planner"
# site-timing auto-wiring helper (chrony refclocks, LAN NTP/GNSS discovery,
# metrology channels, full timestd profile) — pushed into the VM by the wizard
[ -f sigmond-site-timing ] && cp sigmond-site-timing /tmp/sigpay.$$/ \
  || say "WARN: sigmond-site-timing missing from rig — timing chain manual"
# operator shell helpers (tm/ll/lrt) for host + VM /etc/profile.d
[ -f sigmond-operator.sh ] && cp sigmond-operator.sh /tmp/sigpay.$$/
# location authority (GPSDO definitive over operator entry)
[ -f sigmond-location-check ] && cp sigmond-location-check /tmp/sigpay.$$/
echo "$VERSION sigmond@$SIGREV built $(date -Iseconds)" > /tmp/sigpay.$$/VERSION
umount /tmp/sigpay.$$; rmdir /tmp/sigpay.$$

STAMP="$(date +%Y%m%d)"
SUFFIX=""; [ "$RELEASE" = 1 ] && SUFFIX="-release"
IMG="sigmond-appliance-${VERSION}-${STAMP}${SUFFIX}.img"
say "assemble USB image (pristine ISO + payload at aligned volsize offset) -> $IMG"
VB=$(od -An -tu4 -j $((16*2048+80)) -N4 pve-sc-v3.iso | tr -d ' ')
OFF=$(( VB*2048 )); OFF=$(( (OFF+1048575)/1048576*1048576 ))
say "iso volsize=$((VB*2048)) bytes -> payload offset=$OFF"
rm -f "$IMG"
cp pve-sc-v3.iso "$IMG"
truncate -s "$OFF" "$IMG"
cat payload-v3.ext4 >> "$IMG"

# Publish the RAW .img — no compression (rob 2026-08-09).
# Measured over v3.21/22/23: xz lands at 90.7% every time, saving ~464 MB on
# a ~5 GB image for 2 min 36 s of build time plus the operator's decompress.
# The payload is already-compressed data (squashfs Proxmox ISO + a compacted
# qcow2 template), so xz grinds on incompressible bytes for 9%.
#
# The decisive argument is safety, not speed: compression is the direct cause
# of the worst failure this fleet has had -- Raspberry Pi Imager writing the
# COMPRESSED bytes verbatim to the stick, which looks written and silently
# will not boot (hit with .zst 2026-07-26, then again with .img.xz 2026-07-27).
# Shipping raw deletes that class outright: there is no decompress step to get
# wrong and no GUI writer to mishandle.  wd30 can still compress on demand for
# a slow-link site without the build or the burn path depending on it.
say "checksum (publishing the RAW .img — no compression; see the note above)"
rm -f "$IMG.xz"
sha256sum "$IMG" | tee "${IMG%.img}.sha256"
ls -la "$IMG"

if [ "$SHIP" = 1 ]; then
    say "SHIPPING to wd30 NOW (untested — test verdict follows separately)"
    scp -q "$IMG" "${IMG%.img}.sha256" wd30:~/ \
        && say "shipped: wd30:~/$IMG + .sha256" \
        || say "WARNING: ship to wd30 FAILED — ship manually"
fi
say "USB IMAGE BUILD COMPLETE: $VERSION ($IMG)"
