#!/bin/bash
# Sigmond appliance USB image builder v2 — runs on B3 in ~/appliance/v2.
# Codifies the June packaging (which was inline-only):
#   1. prepare-iso: PVE 9.1 + answer.toml (power-off mode) + firstboot-v2
#   2. ext4 payload (decoder template + wizard + sigmond-rac payload)
#      APPENDED after the pristine ISO at 1MiB-aligned PVD volsize offset
#      (NEVER add a GPT partition for it — breaks UEFI auto-install; see
#      project memory 2026-06-12)
# Usage: build-usb-v2.sh [--release]   (--release strips the test ssh key)
set -eu
cd "$HOME/appliance/v2"
LOG="$PWD/usb-build.log"
exec > >(tee -a "$LOG") 2>&1
say(){ echo "[usb $(date '+%T')] $*"; }
RELEASE=0; [ "${1:-}" = "--release" ] && RELEASE=1

SRC_ISO="$HOME/appliance/iso/proxmox-ve_9.1-1.iso"
TPL=sigmond-decoder-template-v2.qcow2
[ -f "$SRC_ISO" ] || { say "FATAL: $SRC_ISO missing"; exit 1; }
[ -f "$TPL" ] || { say "FATAL: $TPL missing (build the golden VM first)"; exit 1; }
[ -f sigmond-wizard.sh ] || { say "FATAL: sigmond-wizard.sh missing"; exit 1; }
[ -f firstboot-v2.sh ] || { say "FATAL: firstboot-v2.sh missing"; exit 1; }

say "answer file"
cp ../build/answer.toml answer-v2.toml
if [ "$RELEASE" = 1 ]; then
    sed -i '/^root-ssh-keys/d' answer-v2.toml
    say "release mode: test ssh key stripped"
fi
grep -q 'reboot-mode = "power-off"' answer-v2.toml || { say "FATAL: answer.toml lost power-off mode"; exit 1; }

say "sigmond-rac payload"
if [ ! -d sigmond-rac ]; then
    git clone -q https://github.com/HamSCI/sigmond-rac sigmond-rac
fi
git -C sigmond-rac pull -q 2>/dev/null || true
tar czf sigmond-rac.tar.gz sigmond-rac

say "prepare-iso (embed answer + firstboot)"
rm -f pve-sc-v2.iso
proxmox-auto-install-assistant prepare-iso "$SRC_ISO" \
    --fetch-from iso --answer-file answer-v2.toml \
    --on-first-boot firstboot-v2.sh --output pve-sc-v2.iso
[ -f pve-sc-v2.iso ] || { say "FATAL: prepare-iso produced nothing"; exit 1; }

say "payload ext4 (template + wizard + rac)"
PAYSZ_MB=$(( $(stat -c%s "$TPL")/1048576 + $(stat -c%s sigmond-rac.tar.gz)/1048576 + 256 ))
rm -f payload-v2.ext4
dd if=/dev/zero of=payload-v2.ext4 bs=1M count="$PAYSZ_MB" status=none
/usr/sbin/mkfs.ext4 -q -L SIGTPL payload-v2.ext4
mkdir -p /tmp/sigpay.$$
sudo mount -o loop payload-v2.ext4 /tmp/sigpay.$$
sudo cp "$TPL" sigmond-wizard.sh sigmond-rac.tar.gz QUICKSTART.txt /tmp/sigpay.$$/
sudo umount /tmp/sigpay.$$; rmdir /tmp/sigpay.$$

STAMP="$(date +%Y%m%d-%H%M)"
SUFFIX=""
if [ "$RELEASE" = 1 ]; then SUFFIX="-release"; fi
IMG="sigmond-appliance-${STAMP}${SUFFIX}.img"
say "assemble USB image (pristine ISO + payload at aligned volsize offset) -> $IMG"
VB=$(od -An -tu4 -j $((16*2048+80)) -N4 pve-sc-v2.iso | tr -d ' ')
OFF=$(( VB*2048 )); OFF=$(( (OFF+1048575)/1048576*1048576 ))
say "iso volsize=$((VB*2048)) bytes → payload offset=$OFF"
rm -f $IMG
cp pve-sc-v2.iso $IMG
truncate -s "$OFF" $IMG
cat payload-v2.ext4 >> $IMG

say "compress + checksum"
rm -f "$IMG.zst"
zstd -T0 -9 -q "$IMG" -o "$IMG.zst"
sha256sum $IMG $IMG.zst | tee ${IMG%.img}.sha256
ls -la $IMG $IMG.zst
say "USB IMAGE BUILD COMPLETE"
