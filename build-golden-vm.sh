#!/bin/bash
# v3 golden decoder VM build driver — runs ON B3, logs to ~/appliance/v3/build.log
# Same pipeline as v2 (provision.sh clones CURRENT HamSCI main at build time),
# ssh port 5557 to avoid any stale v2 rig.
set -u
cd "$HOME/appliance/v3"
LOG="$PWD/build.log"
exec > "$LOG" 2>&1
say(){ echo "[driver $(date '+%T')] $*"; }
KEY="$HOME/appliance/build/applkey"
SSH="ssh -i $KEY -p 5557 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 build@127.0.0.1"
SCP="scp -i $KEY -P 5557 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

say "creating fresh build disk from debian-13 base"
sudo pkill -f "name goldenv3" 2>/dev/null; sleep 2
cp ../vmbuild/debian-13-genericcloud-amd64.qcow2 golden-v3.qcow2
qemu-img resize golden-v3.qcow2 20G

say "booting build VM (headless, ssh :5557)"
sudo qemu-system-x86_64 -name goldenv3 -enable-kvm -m 8192 -smp 4 -cpu host \
  -drive file=golden-v3.qcow2,if=virtio -drive file=../vmbuild/seed.iso,media=cdrom \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:5557-:22 -device virtio-net,netdev=n0 \
  -display none -daemonize

say "waiting for ssh"
for i in $(seq 1 60); do $SSH true 2>/dev/null && break; sleep 5; done
$SSH true || { say "FATAL: VM ssh never came up"; exit 1; }
say "VM up: $($SSH hostname 2>/dev/null)"

$SCP provision.sh provision-components.sh rob.pub build@127.0.0.1:
$SCP wisdomf-ryzen5825u build@127.0.0.1:wisdomf
say "stage 1: bootstrap (clone HamSCI/sigmond + install.sh)"
$SSH "chmod +x provision*.sh && setsid ./provision.sh </dev/null >/dev/null 2>&1 &"
for i in $(seq 1 120); do $SSH "grep -q 'BOOTSTRAP DONE' provision.log" 2>/dev/null && break; sleep 15; done
$SSH "grep -q 'BOOTSTRAP DONE' provision.log" || { say "FATAL: stage1 timeout"; $SSH "tail -20 provision.log"; exit 1; }
say "stage 1 done: $($SSH "grep '###' provision.log | tail -3")"

say "stage 1.5: swap cloud kernel -> generic (cloud kernel has NO USB stack; decoder VM needs RX888 USB passthrough — VM101 lesson 2026-07-25)"
$SSH "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq linux-image-amd64 >/dev/null"
CLOUDPKGS=$($SSH "dpkg -l | awk '/^ii  linux-image.*cloud/{print \$2}' | tr '\n' ' '")
say "cloud kernel packages: $CLOUDPKGS"
if [ -n "${CLOUDPKGS// }" ]; then
    $SSH "for p in $CLOUDPKGS; do echo \"\$p \$p/prompt-remove-running-kernel boolean false\" | sudo debconf-set-selections; done"
    $SSH "sudo DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq $CLOUDPKGS >/dev/null && sudo update-grub >/dev/null 2>&1"
fi
say "rebooting build VM onto generic kernel"
$SSH "sudo reboot" 2>/dev/null; sleep 10
for i in $(seq 1 36); do $SSH true 2>/dev/null && break; sleep 5; done
KVER=$($SSH "uname -r" 2>/dev/null)
say "kernel after swap: $KVER"
case "$KVER" in *cloud*|"") say "FATAL: still on cloud kernel (or VM dead) — kernel swap failed"; exit 1;; esac
$SSH "dpkg -l | grep -q 'linux-image.*cloud'" && { say "FATAL: cloud kernel package still installed"; exit 1; }
$SSH "ls /lib/modules/\$(uname -r)/kernel/drivers/usb/host/ | grep -q xhci" || { say "FATAL: no xhci modules on new kernel"; exit 1; }
say "generic kernel active, USB (xhci) modules present"

say "stage 2+3: components + capture-prep (long — ka9q compile)"
$SSH "setsid ./provision-components.sh </dev/null >/dev/null 2>&1 &"
for i in $(seq 1 240); do $SSH "grep -q 'GOLDEN PREP DONE' provision.log" 2>/dev/null && break; sleep 30; done
$SSH "grep -q 'GOLDEN PREP DONE' provision.log" || { say "FATAL: stage2/3 timeout"; $SSH "tail -30 provision.log"; exit 1; }
say "stage 2+3 done"
$SSH "grep '###' provision.log | tail -8"
$SSH "cat capture-gate.json 2>/dev/null | head -5"
# a not-ready gate means the template is missing components/artefacts — refuse to ship
if ! $SSH "grep -q '\"ready\": true' capture-gate.json"; then
    say "FATAL: capture gate NOT ready — template unusable; provision.log is inside golden-v3.qcow2"
    exit 1
fi
say "capture gate READY"

say "recording repo revisions for the build manifest"
$SSH "for d in /opt/git/sigmond/*/; do printf '%s %s\n' \"\$(basename \$d)\" \"\$(git -C \$d rev-parse --short HEAD 2>/dev/null)\"; done" | tee golden-v3-revs.txt

say "shutting down VM (halt, not reboot — no machine-id now)"
$SSH "sudo shutdown -h now" 2>/dev/null
for i in $(seq 1 24); do pgrep -f "name goldenv3" >/dev/null || break; sleep 5; done
pgrep -f "name goldenv3" >/dev/null && { say "force stop"; sudo pkill -f "name goldenv3"; sleep 3; }

say "compacting template"
qemu-img convert -O qcow2 -c golden-v3.qcow2 sigmond-decoder-template-v3.qcow2
ls -la sigmond-decoder-template-v3.qcow2
say "GOLDEN VM BUILD COMPLETE"
