#!/bin/bash
# v2 golden decoder VM build driver — runs ON B3, logs to ~/appliance/v2/build.log
set -u
cd "$HOME/appliance/v2"
LOG="$PWD/build.log"
exec > "$LOG" 2>&1
say(){ echo "[driver $(date '+%T')] $*"; }
KEY="$HOME/appliance/build/applkey"
SSH="ssh -i $KEY -p 5556 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 build@127.0.0.1"
SCP="scp -i $KEY -P 5556 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

say "creating fresh build disk from debian-13 base"
sudo pkill -f "name goldenv2" 2>/dev/null; sleep 2
cp ../vmbuild/debian-13-genericcloud-amd64.qcow2 golden-v2.qcow2
qemu-img resize golden-v2.qcow2 20G

say "booting build VM (headless, ssh :5556)"
sudo qemu-system-x86_64 -name goldenv2 -enable-kvm -m 8192 -smp 4 -cpu host \
  -drive file=golden-v2.qcow2,if=virtio -drive file=../vmbuild/seed.iso,media=cdrom \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:5556-:22 -device virtio-net,netdev=n0 \
  -display none -daemonize

say "waiting for ssh"
for i in $(seq 1 60); do $SSH true 2>/dev/null && break; sleep 5; done
$SSH true || { say "FATAL: VM ssh never came up"; exit 1; }
say "VM up: $($SSH hostname 2>/dev/null)"

$SCP provision.sh provision-components.sh build@127.0.0.1: 
say "stage 1: bootstrap (clone HamSCI/sigmond + install.sh)"
$SSH "chmod +x provision*.sh && setsid ./provision.sh </dev/null >/dev/null 2>&1 &"
for i in $(seq 1 120); do $SSH "grep -q 'BOOTSTRAP DONE' provision.log" 2>/dev/null && break; sleep 15; done
$SSH "grep -q 'BOOTSTRAP DONE' provision.log" || { say "FATAL: stage1 timeout"; $SSH "tail -20 provision.log"; exit 1; }
say "stage 1 done: $($SSH "grep '###' provision.log | tail -3")"

say "stage 2+3: components + capture-prep (long — ka9q compile)"
$SSH "setsid ./provision-components.sh </dev/null >/dev/null 2>&1 &"
for i in $(seq 1 240); do $SSH "grep -q 'GOLDEN PREP DONE' provision.log" 2>/dev/null && break; sleep 30; done
$SSH "grep -q 'GOLDEN PREP DONE' provision.log" || { say "FATAL: stage2/3 timeout"; $SSH "tail -30 provision.log"; exit 1; }
say "stage 2+3 done"
$SSH "grep '###' provision.log | tail -8"
$SSH "cat capture-gate.json 2>/dev/null | head -5"

say "shutting down VM (halt, not reboot — no machine-id now)"
$SSH "sudo shutdown -h now" 2>/dev/null
for i in $(seq 1 24); do pgrep -f "name goldenv2" >/dev/null || break; sleep 5; done
pgrep -f "name goldenv2" >/dev/null && { say "force stop"; sudo pkill -f "name goldenv2"; sleep 3; }

say "compacting template"
qemu-img convert -O qcow2 -c golden-v2.qcow2 sigmond-decoder-template-v2.qcow2
ls -la sigmond-decoder-template-v2.qcow2
say "GOLDEN VM BUILD COMPLETE"
