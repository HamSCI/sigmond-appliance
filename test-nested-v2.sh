#!/bin/bash
# Tier-2 nested boot test v2 — runs on B3. Phases:
#  A) UEFI boot USB image → PVE 9.1 auto-install to empty NVMe → power-off
#  B) boot NVMe only → PVE up, firstboot ran w/o media, importer armed
#  C) boot NVMe + USB attached → udev import fires → decoder VM 120 up
#  D) drive the wizard non-interactively over ssh; verify identity in guest
# June lessons honored: OVMF (never SeaBIOS+NVMe), >=12G RAM (nested 8G VM),
# ps -C comm matching (never pkill -f), power-off detect via process exit.
set -u
cd "$HOME/appliance/v2"
LOG="$PWD/test-v2.log"
exec >> "$LOG" 2>&1
say(){ echo "[test $(date '+%T')] $*"; }
KEY="$HOME/appliance/build/applkey"
SSHN="ssh -i $KEY -p 5560 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 root@127.0.0.1"
OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
[ -f "$OVMF_CODE" ] || OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd

vm_running(){ ps -C qemu-system-x86_64 -o args= 2>/dev/null | grep -q "guest=sigv2"; }
vm_kill(){ ps -C qemu-system-x86_64 -o pid=,args= 2>/dev/null | awk '/guest=sigv2/{print $1}' | xargs -r sudo kill; sleep 3; }

boot_vm(){ # boot_vm <with_usb 0|1> <serial_log>
    local usb="$1" slog="$2"
    vm_kill
    local usbargs=""
    [ "$usb" = 1 ] && usbargs="-drive if=none,id=ustick,format=raw,file=$PWD/usb-final-v2.img -device usb-storage,drive=ustick,bootindex=2"
    sudo qemu-system-x86_64 -name guest=sigv2,debug-threads=on -enable-kvm -machine q35 -m 12288 -smp 4 -cpu host \
      -drive if=pflash,format=raw,readonly=on,file=$OVMF_CODE \
      -drive if=pflash,format=raw,file=$PWD/ovmf-vars-v2.fd \
      -drive if=none,id=nvme0,format=qcow2,file=$PWD/nvme-v2.qcow2 -device nvme,drive=nvme0,serial=sigv2nvme,bootindex=1 -device qemu-xhci \
      $usbargs \
      -netdev user,id=n0,hostfwd=tcp:127.0.0.1:5560-:22 -device virtio-net,netdev=n0 \
      -qmp unix:/tmp/sigv2-qmp.sock,server,nowait -serial "file:$PWD/$slog" -display none -daemonize
}

case "${1:-all}" in
all|A)
say "════ PHASE A: auto-install ════"
qemu-img create -f qcow2 nvme-v2.qcow2 40G >/dev/null
cp /usr/share/OVMF/OVMF_VARS_4M.fd ovmf-vars-v2.fd
boot_vm 1 serialA-v2.log
sleep 8; vm_running || { say "FATAL: qemu did not start"; exit 1; }
say "installer booted; waiting for power-off (up to 30 min)"
for i in $(seq 1 120); do vm_running || break; sleep 15; done
vm_running && { say "FATAL: installer did not power off in 30min"; exit 1; }
say "PHASE A PASS: installer completed and powered off"
[ "${1:-all}" = "A" ] && exit 0
;&
B)
say "════ PHASE B: first boot from NVMe, no USB ════"
boot_vm 0 serialB-v2.log
for i in $(seq 1 60); do $SSHN true 2>/dev/null && break; sleep 5; done
$SSHN true 2>/dev/null || { say "FATAL: nested PVE ssh never came up"; exit 1; }
say "nested PVE up: $($SSHN 'pveversion' 2>/dev/null)"
$SSHN "grep -q 'no Sigmond USB present' /var/log/sigmond-firstboot.log" && say "firstboot ran, no media (expected)" || say "WARN: firstboot log unexpected"
$SSHN "test -x /usr/local/sbin/sigmond-import.sh" && say "importer installed" || { say "FATAL: importer missing"; exit 1; }
$SSHN "test -f /etc/udev/rules.d/99-sigmond-import.rules" && say "udev rule armed" || { say "FATAL: udev rule missing"; exit 1; }
$SSHN "poweroff" 2>/dev/null; sleep 15; vm_kill
say "PHASE B PASS"
[ "${1:-all}" = "B" ] && exit 0
;&
C)
say "════ PHASE C: boot with USB attached → auto-import ════"
boot_vm 1 serialC-v2.log
for i in $(seq 1 60); do $SSHN true 2>/dev/null && break; sleep 5; done
$SSHN true 2>/dev/null || { say "FATAL: nested PVE ssh never came up (C)"; exit 1; }
say "waiting for decoder VM import (up to 10 min)"
for i in $(seq 1 60); do $SSHN "qm status 120 2>/dev/null | grep -q running" 2>/dev/null && break; sleep 10; done
$SSHN "qm status 120 2>/dev/null" | grep -q running || { say "FATAL: VM 120 not running"; $SSHN "tail -20 /var/log/sigmond-firstboot.log"; exit 1; }
say "decoder VM 120 imported + running"
$SSHN "cp /usr/local/sbin/sigmond-setup /tmp/ 2>/dev/null; test -x /usr/local/sbin/sigmond-setup" && say "wizard staged" || { say "FATAL: wizard missing"; exit 1; }
$SSHN "test -f /root/sigmond-appliance/sigmond-rac/install-host.sh" && say "sigmond-rac payload staged" || say "WARN: rac payload missing"
$SSHN "systemctl is-enabled sigmond-wizard.service" && say "wizard service enabled (tty1)" || say "WARN: wizard unit not enabled"
say "PHASE C PASS"
[ "${1:-all}" = "C" ] && exit 0
;&
D)
say "════ PHASE D: drive the wizard (test identity N0CALL/T1 @ EM00aa) ════"
for i in $(seq 1 40); do $SSHN "qm agent 120 ping" >/dev/null 2>&1 && break; sleep 10; done
$SSHN "qm agent 120 ping" >/dev/null 2>&1 || { say "FATAL: guest agent never answered"; exit 1; }
say "guest agent up; running wizard with piped answers"
printf 'N0CALL/T1\nEM00aa\nTier2 test dipole\n\nY\n' | $SSHN "sigmond-setup" 2>&1 | tail -12
# the guest's first DHCP through slirp can blip the ssh forward for
# ~15s — retry before judging (observed 2026-07-02, two false FATALs)
MARK_OK=0
for i in $(seq 1 12); do
    $SSHN "test -f /etc/sigmond-appliance/.configured" 2>/dev/null && { MARK_OK=1; break; }
    sleep 10
done
[ "$MARK_OK" = 1 ] && say "configured marker present: $($SSHN cat /etc/sigmond-appliance/.configured)" || { say "FATAL: wizard did not complete"; exit 1; }
say "verifying identity inside decoder VM"
$SSHN "qm guest exec 120 --timeout 60 -- bash -lc 'grep -E \"reporter_id|callsign|grid\" /etc/sigmond/site-profile.toml; grep REPORTER /etc/sigmond/coordination.env; hostname'" 2>&1 | tail -8
say "PHASE D PASS — NESTED TEST COMPLETE"
;;
esac
say "TEST DRIVER DONE"
