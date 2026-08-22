#!/bin/bash
# Tier-2 nested boot test v3 — runs on B3. Phases:
#  A) UEFI boot USB image → PVE 9.1 auto-install to empty NVMe → power-off
#  B) boot NVMe only → PVE up, firstboot ran w/o media, importer armed
#  C) boot NVMe + USB → udev import → VM 100 created + HOST TUNED (grub
#     isolcpus/vfio/hookscript/affinity) → QMP-detach the USB → importer
#     reboots the nested host → VM 100 autostart. In the NEST there is no
#     IOMMU, so hostpci start fails by design: strip hostpci, start VM —
#     passthrough itself is real-hardware scope (BIOS checklist).
#  D) drive the wizard non-interactively; verify identity + PSWS in guest;
#     verify GENERIC kernel (USB stack) + hamsci login in the decoder VM.
# June lessons: OVMF (never SeaBIOS+NVMe), >=12G RAM, ps -C comm matching,
# power-off detect via process exit, identical PCI topology across boots
# (xhci declared before usb-storage, always present).
set -u
cd "$HOME/appliance/v3"
LOG="$PWD/test-v3.log"
exec >> "$LOG" 2>&1
say(){ echo "[test $(date '+%T')] $*"; }
KEY="$HOME/appliance/build/applkey"
# --release builds strip root-ssh-keys from answer-v3.toml on purpose
# (build-usb-v3.sh RELEASE branch) so the test key never lands on a
# shipping image. Those images still take the documented image-default
# root password (firstboot-v3.sh: "console/SSH login: root / hamsci-sigmond").
# Overridable, not a new secret — this password is already public in the
# wizard output and project docs.
SSHPASSWORD="${SIGMOND_TEST_PASSWORD:-hamsci-sigmond}"
SSHOPTS="-p 5561 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 root@127.0.0.1"
SSHKEY="ssh -i $KEY $SSHOPTS"
SSHPW="sshpass -p $SSHPASSWORD ssh $SSHOPTS"
SSHN=""  # resolved once by resolve_ssh(); every call site below reads $SSHN
OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
[ -f "$OVMF_CODE" ] || OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd
USBIMG="${USBIMG:-$(ls -t sigmond-appliance-v3*.img 2>/dev/null | head -1)}"
[ -n "$USBIMG" ] || { say "FATAL: no sigmond-appliance-v3*.img found"; exit 1; }
say "USB image under test: $USBIMG"
VMID=100

vm_running(){ ps -C qemu-system-x86_64 -o args= 2>/dev/null | grep -q "guest=sigv3"; }
vm_kill(){ ps -C qemu-system-x86_64 -o pid=,args= 2>/dev/null | awk '/guest=sigv3/{print $1}' | xargs -r kill; sleep 3; }
qmp(){ python3 - "$1" <<'PYEOF'
import json, socket, sys
cmd = json.loads(sys.argv[1])
s = socket.socket(socket.AF_UNIX); s.connect("/tmp/sigv3-qmp.sock")
f = s.makefile("rw")
f.readline()
f.write(json.dumps({"execute":"qmp_capabilities"})+"\n"); f.flush(); f.readline()
f.write(json.dumps(cmd)+"\n"); f.flush()
print(f.readline().strip())
PYEOF
}

boot_vm(){ # boot_vm <with_usb 0|1> <serial_log>
    local usb="$1" slog="$2"
    vm_kill
    local usbargs=""
    [ "$usb" = 1 ] && usbargs="-drive if=none,id=ustick,format=raw,file=$PWD/$USBIMG -device usb-storage,id=usbdev,drive=ustick,bootindex=2"
    # Launched as its OWN transient systemd unit, not backgrounded with
    # qemu's -daemonize. -daemonize only detaches from the shell's
    # session/process group via a double-fork+setsid; the resulting process
    # still inherits the cgroup of whoever launched it. Under
    # `systemd-run --unit=...` (this driver, when run that way;
    # KillMode=control-group is the transient-unit default) that meant the
    # guest was SIGTERM'd the instant this script exited, pass OR fail,
    # destroying post-mortem evidence on every FATAL (2026-08-16
    # investigation). `systemd-run` here creates a sibling top-level unit,
    # independent of whatever unit (if any) is running this script, so the
    # driver's exit never reaches it — verified directly (guest unit stays
    # active/running after a `--wait`ed driver unit exits; a plain
    # backgrounded child in the driver's own cgroup does not). RuntimeMaxSec
    # is a backstop, not the normal path: vm_kill (called at the top of
    # every boot_vm, and explicitly after Phase B/D power-offs) is still how
    # the guest is normally stopped, by pid, same as before — that still
    # works unchanged since systemd notices the tracked pid exit and
    # (--collect) forgets the unit. The bound just guarantees that even an
    # abnormal driver exit that skips vm_kill can't orphan a 12G/8vCPU guest
    # forever: 1h comfortably covers a full single-phase run (the whole
    # 4-phase test is documented as 20-30min) plus real post-mortem time.
    # -smp 8 cores=4 threads=2: nested PVE sees real HT pairs so the
    # importer's pinned layout path is exercised, not the fallback.
    local unit="sigv3-qemu-$$-$(date +%s)"
    say "qemu unit: $unit (post-mortem: journalctl -u $unit)"
    systemd-run --unit="$unit" --collect --property=RuntimeMaxSec=3600 -- \
      qemu-system-x86_64 -name guest=sigv3,debug-threads=on -enable-kvm -machine q35 -m 12288 \
      -smp 8,sockets=1,cores=4,threads=2 -cpu host,topoext=on \
      -drive if=pflash,format=raw,readonly=on,file=$OVMF_CODE \
      -drive if=pflash,format=raw,file=$PWD/ovmf-vars-v3.fd \
      -drive if=none,id=nvme0,format=qcow2,file=$PWD/nvme-v3.qcow2 -device nvme,drive=nvme0,serial=sigv3nvme,bootindex=1 -device qemu-xhci \
      $usbargs \
      -netdev user,id=n0,hostfwd=tcp:127.0.0.1:5561-:22 -device virtio-net,netdev=n0 \
      -qmp unix:/tmp/sigv3-qmp.sock,server,nowait -serial "file:$PWD/$slog" -display none
}

# resolve_ssh <tries> <delay> [label]: wait for the nested host's ssh to
# answer and pin $SSHN to whichever auth method it accepts — key first
# (fast path, works on non-release builds), password fallback (release
# builds, whose test key build-usb-v3.sh strips on purpose). Resolves once:
# if $SSHN is already pinned from an earlier call in this run, it just
# retries that same command — it does not re-probe both methods every time.
# On total failure it tells apart "host never came up" (qemu process gone)
# from "host answered but no credential worked" (both auths rejected) —
# those used to produce the same message, which is what made this bug take
# an investigation to find.
resolve_ssh(){
    local tries="$1" delay="$2" label="${3:-}" i
    if [ -n "$SSHN" ]; then
        for i in $(seq 1 "$tries"); do $SSHN true 2>/dev/null && return 0; sleep "$delay"; done
        say "FATAL: nested PVE ssh never came back${label:+ ($label)}"; return 1
    fi
    for i in $(seq 1 "$tries"); do
        if $SSHKEY true 2>/dev/null; then SSHN="$SSHKEY"; say "auth: ssh test key accepted"; return 0; fi
        if $SSHPW true 2>/dev/null; then SSHN="$SSHPW"; say "auth: test key not accepted, falling back to image-default password (release build)"; return 0; fi
        sleep "$delay"
    done
    if vm_running; then
        say "FATAL: nested host is up but neither ssh key nor password auth worked${label:+ ($label)}"
    else
        say "FATAL: nested PVE ssh never came up${label:+ ($label)}"
    fi
    return 1
}

# wait_firstboot_complete <tries> <delay>: poll the nested host over ssh for
# firstboot-v3.sh's own completion line, "first-boot v3 complete" — the last
# thing it writes to $LOG (firstboot-v3.sh:552), after installing the
# importer/wizard/finalizer hooks and running the importer once itself.
# sshd answering is NOT that signal: firstboot depends on
# After=pveproxy.service and takes ~85s end to end, while ssh can answer in
# under 20s — checking firstboot's products (the log line, the importer
# script) right after ssh connects races a boot sequence firstboot hasn't
# necessarily finished yet (always racy; only stopped losing the race when
# the ssh-auth path got faster — 2026-08-16 investigation). Callers still
# check the actual products afterward; this only gates on firstboot having
# truly finished before those checks run, so "never completed" (this
# function's timeout) and "completed but a product is missing" (a later
# check's own FATAL) stay distinguishable instead of looking identical.
wait_firstboot_complete(){
    local tries="$1" delay="$2" i
    for i in $(seq 1 "$tries"); do
        $SSHN "grep -q 'first-boot v3 complete' /var/log/sigmond-firstboot.log" 2>/dev/null && return 0
        sleep "$delay"
    done
    return 1
}

case "${1:-all}" in
all|A)
say "════ PHASE A: auto-install ($USBIMG) ════"
qemu-img create -f qcow2 nvme-v3.qcow2 40G >/dev/null
cp /usr/share/OVMF/OVMF_VARS_4M.fd ovmf-vars-v3.fd
boot_vm 1 serialA-v3.log
sleep 8; vm_running || { say "FATAL: qemu did not start"; exit 1; }
say "installer booted; waiting for power-off (up to 30 min)"
for i in $(seq 1 120); do vm_running || break; sleep 15; done
vm_running && { say "FATAL: installer did not power off in 30min"; exit 1; }
say "PHASE A PASS: installer completed and powered off"
[ "${1:-all}" = "A" ] && exit 0
;&
B)
say "════ PHASE B: first boot from NVMe, no USB ════"
boot_vm 0 serialB-v3.log
resolve_ssh 60 5 B || exit 1
say "nested PVE up: $($SSHN 'pveversion; hostname' 2>/dev/null)"
$SSHN "hostname | grep -q 'sigmond-appliance-v3'" && say "versioned hostname OK" || say "WARN: hostname not versioned: $($SSHN hostname)"
say "waiting for firstboot to complete (up to 3 min)"
wait_firstboot_complete 36 5 || { say "FATAL: firstboot never completed (no 'first-boot v3 complete' in /var/log/sigmond-firstboot.log within 3 min of ssh coming up)"; exit 1; }
say "firstboot completed"
$SSHN "grep -q 'no Sigmond USB present' /var/log/sigmond-firstboot.log" && say "firstboot ran, no media (expected)" || say "WARN: firstboot log unexpected"
$SSHN "test -x /usr/local/sbin/sigmond-import.sh" && say "importer installed" || { say "FATAL: firstboot completed but importer is missing"; exit 1; }
$SSHN "test -f /etc/udev/rules.d/99-sigmond-import.rules" && say "udev rule armed" || { say "FATAL: udev rule missing"; exit 1; }
$SSHN "cat /etc/sigmond-appliance/version" && say "version file present" || say "WARN: version file missing"
$SSHN "grep -q '^iface vmbr0 inet dhcp' /etc/network/interfaces" \
    && say "vmbr0 converted to DHCP ✓" \
    || { say "FATAL: vmbr0 not on DHCP (static-fossilization bug)"; $SSHN "cat /etc/network/interfaces"; exit 1; }
HIP=$($SSHN "hostname -I | awk '{print \$1}'" 2>/dev/null)
$SSHN "grep -q \"^$HIP[[:space:]]\" /etc/hosts" && say "/etc/hosts pinned to live lease ($HIP) ✓" || say "WARN: /etc/hosts not on live lease"
$SSHN "poweroff" 2>/dev/null; sleep 15; vm_kill
say "PHASE B PASS"
[ "${1:-all}" = "B" ] && exit 0
;&
C)
say "════ PHASE C: boot with USB attached → auto-import, VM runs UNPINNED ════"
boot_vm 1 serialC-v3.log
resolve_ssh 60 5 C || exit 1
say "waiting for decoder VM import (up to 10 min)"
for i in $(seq 1 60); do $SSHN "qm status $VMID 2>/dev/null | grep -q running" 2>/dev/null && break; sleep 10; done
$SSHN "qm status $VMID 2>/dev/null" | grep -q running || { say "FATAL: VM $VMID not running"; $SSHN "tail -20 /var/log/sigmond-firstboot.log"; exit 1; }
say "decoder VM $VMID imported + running (unpinned, pre-wizard)"
CFG=$($SSHN "qm config $VMID" 2>/dev/null)
echo "$CFG" | grep -q "name: sigmond-decoder-v3" && say "VM name versioned OK" || { say "FATAL: VM name wrong"; echo "$CFG"; exit 1; }
echo "$CFG" | grep -qE "^memory: (10240|[0-9]{5})" && say "memory sized to host ($(echo "$CFG"|awk '/^memory:/{print $2}')M)" || say "WARN: memory=$(echo "$CFG"|awk '/^memory:/{print $2}')"
$SSHN "test -f /etc/sigmond-appliance/layout.env" && say "CPU layout saved for finalizer" || say "WARN: layout.env missing (fallback path)"
$SSHN "test -f /root/sigmond-appliance/sigmond/scripts/proxmox/host-apply.sh" && say "sigmond checkout staged" || { say "FATAL: sigmond payload missing"; exit 1; }
$SSHN "test -x /usr/local/sbin/sigmond-setup" && say "wizard staged" || { say "FATAL: wizard missing"; exit 1; }
$SSHN "test -x /usr/local/sbin/sigmond-finalize.sh" && say "finalizer staged" || { say "FATAL: finalizer missing"; exit 1; }
$SSHN "systemctl is-enabled sigmond-wizard.service >/dev/null" && say "wizard service enabled (tty1)" || say "WARN: wizard unit not enabled"
$SSHN "systemctl is-active sigmond-finalize.path >/dev/null" && say "finalize path unit watching" || say "WARN: finalize path unit not active"
$SSHN "test -f /root/sigmond-appliance/sigmond-rac/install-host.sh" && say "sigmond-rac payload staged" || say "WARN: rac payload missing"
say "PHASE C PASS"
[ "${1:-all}" = "C" ] && exit 0
;&
D)
say "════ PHASE D: wizard → finalizer → tuning reboot → pinned production ════"
# standalone `D` invocations start with $SSHN unresolved (no B/C ran in
# this process); resolve_ssh no-ops quickly if it's already pinned.
resolve_ssh 60 5 D || exit 1
# require 2 consecutive agent pings — a lone success during guest boot
# can be followed by an agent restart (observed 2026-07-26, false FATAL)
AGENT_OK=0
for i in $(seq 1 40); do
    if $SSHN "qm agent $VMID ping" >/dev/null 2>&1; then
        AGENT_OK=$((AGENT_OK+1)); [ "$AGENT_OK" -ge 2 ] && break; sleep 3
    else
        AGENT_OK=0; sleep 10
    fi
done
[ "$AGENT_OK" -ge 2 ] || { say "FATAL: guest agent never answered"; exit 1; }
say "verifying decoder VM internals: generic kernel (USB stack) + hamsci login"
GK=$($SSHN "qm guest exec $VMID --timeout 60 -- bash -lc 'uname -r; ls /lib/modules/\$(uname -r)/kernel/drivers/usb/host/ | grep -c xhci; id hamsci'" 2>&1)
echo "$GK" | tail -4
echo "$GK" | grep -q 'cloud' && { say "FATAL: decoder VM still on CLOUD kernel (no USB stack)"; exit 1; }
echo "$GK" | grep -q 'hamsci' || { say "FATAL: hamsci user missing in decoder VM"; exit 1; }
say "staging a test site-keys tarball (exercises the stick key-restore path)"
$SSHN "mkdir -p /root/sigmond-appliance /tmp/sk/etc/hs-uploader/keys /tmp/sk/home/timestd/.ssh && echo TESTPRIV > /tmp/sk/etc/hs-uploader/keys/id_ed25519_host && echo TESTPUB > /tmp/sk/etc/hs-uploader/keys/id_ed25519_host.pub && echo TESTRSA > /tmp/sk/home/timestd/.ssh/id_rsa_psws && tar czf /root/sigmond-appliance/site-keys.tar.gz -C /tmp/sk etc home && rm -rf /tmp/sk"
say "guest kernel + hamsci OK; running wizard with piped answers (identity N0CALL/T1 @ EM00aa)"
# Answer sequence for the v3.29+ wizard: reporter, grid, antenna, DASI n,
# remote-access n, PSWS id, GRAPE instr, mag instr, mag station,
# designator default, apply.  (The wizard's Press-Enter gate is tty-only
# and its rd() guard aborts loudly on any desync — 2026-08-11.)
printf 'N0CALL/T1
EM00aa
Tier2 test dipole
n
n
S000999
172
84
S000998

Y
' | $SSHN "sigmond-setup" 2>&1 | tail -40
MARK_OK=0
for i in $(seq 1 12); do
    $SSHN "test -f /etc/sigmond-appliance/.configured" 2>/dev/null && { MARK_OK=1; break; }
    sleep 10
done
[ "$MARK_OK" = 1 ] && say "configured marker present: $($SSHN cat /etc/sigmond-appliance/.configured)" || { say "FATAL: wizard did not complete"; exit 1; }
# NO in-guest verification here: .configured fires the finalizer, which
# SHUTS THE VM DOWN for host tuning (raced 2026-07-26, false FATAL).
# Identity + PSWS are verified after the production reboot below.

say "── finalizer: waiting for host tuning (REMOVE-THE-STICK prompt, up to 10 min)"
for i in $(seq 1 60); do $SSHN "grep -q 'REMOVE THE USB STICK' /var/log/sigmond-firstboot.log" 2>/dev/null && break; sleep 10; done
$SSHN "grep -q 'REMOVE THE USB STICK' /var/log/sigmond-firstboot.log" 2>/dev/null || { say "FATAL: finalizer never reached stick-removal prompt"; $SSHN "tail -30 /var/log/sigmond-firstboot.log"; exit 1; }
say "finalizer tuned the host; verifying artifacts"
CFG=$($SSHN "qm config $VMID" 2>/dev/null)
echo "$CFG" | grep -q "^hookscript:" && say "cpu-pin hookscript bound" || say "WARN: no hookscript"
echo "$CFG" | grep -q "^affinity:" && say "affinity set: $(echo "$CFG"|awk '/^affinity:/{print $2}')" || say "WARN: no affinity"
echo "$CFG" | grep -q "topoext=on" && say "-smp/topoext args set" || say "WARN: no -smp args"
echo "$CFG" | grep -q "^hostpci0:" && say "USB controller passthrough bound" || say "WARN: no hostpci bound (check log)"
$SSHN "grep -q isolcpus /etc/default/grub.d/sigmond.cfg" && say "grub isolcpus staged" || say "WARN: grub sigmond.cfg missing"
$SSHN "test -f /etc/modprobe.d/vfio.conf" && say "vfio.conf staged" || say "WARN: vfio.conf missing"
$SSHN "test -f /etc/sigmond/host-layout.env" && say "host-layout.env saved" || say "WARN: host-layout.env missing"

say "detaching USB stick via QMP (device_del usbdev)"
qmp '{"execute":"device_del","arguments":{"id":"usbdev"}}'
# v3.28+ semantics: after stick removal the appliance POWERS OFF (by
# design — the operator's manual power-on resets the RX888's VBUS).  So:
# wait for ssh to drop, wait for the guest to power off (qemu exits),
# then "press the power button" — relaunch from NVMe.
say "waiting for finalizer-driven power-off (ssh drop + qemu exit, up to 10 min)"
DROPPED=0
for i in $(seq 1 60); do $SSHN true 2>/dev/null || { DROPPED=1; break; }; sleep 5; done
[ "$DROPPED" = 1 ] || { say "FATAL: nested host never went down after stick removal"; exit 1; }
say "ssh dropped; waiting for guest power-off (qemu exit)"
QOFF=0
for i in $(seq 1 36); do pgrep -f "guest=sigv[3]" >/dev/null || { QOFF=1; break; }; sleep 5; done
[ "$QOFF" = 1 ] || { say "FATAL: guest did not power off within 3 min of ssh drop"; exit 1; }
say "guest powered off (v3.28+ by-design); powering back on from NVMe"
boot_vm 0 serialE-v3.log
for i in $(seq 1 90); do $SSHN true 2>/dev/null && break; sleep 5; done
$SSHN true 2>/dev/null || { say "FATAL: nested PVE did not come back after power-on"; exit 1; }
$SSHN "grep -qw 'isolcpus=${ISOL:-}' /proc/cmdline 2>/dev/null || grep -qw isolcpus /proc/cmdline" && say "isolcpus ACTIVE on rebooted host" || say "WARN: isolcpus not in cmdline"
say "checking VM $VMID autostart (nest has no IOMMU: hostpci start fails by design)"
VMUP=0
for i in $(seq 1 18); do $SSHN "qm status $VMID 2>/dev/null | grep -q running" 2>/dev/null && { VMUP=1; break; }; sleep 10; done
if [ "$VMUP" = 0 ]; then
    say "VM not running (expected in nest with hostpci bound) — stripping hostpci for nested continuation"
    PCIS=$($SSHN "qm config $VMID | grep -oE '^hostpci[0-9]+' | paste -sd,")
    [ -n "$PCIS" ] && $SSHN "qm set $VMID --delete $PCIS"
    $SSHN "qm start $VMID" || { say "FATAL: VM $VMID won't start even without hostpci"; exit 1; }
    for i in $(seq 1 30); do $SSHN "qm status $VMID | grep -q running" 2>/dev/null && { VMUP=1; break; }; sleep 10; done
fi
[ "$VMUP" = 1 ] || { say "FATAL: VM $VMID not running post-reboot"; exit 1; }
say "decoder VM $VMID running pinned-config post-reboot; verifying 1:1 vCPU pinning"
$SSHN "QP=\$(cat /var/run/qemu-server/$VMID.pid); for tid in \$(ps -T -p \$QP -o tid=); do case \"\$(cat /proc/\$tid/comm)\" in CPU*KVM) taskset -pc \$tid;; esac; done" 2>&1 | tail -8
for i in $(seq 1 30); do $SSHN "qm agent $VMID ping" >/dev/null 2>&1 && break; sleep 10; done
say "verifying VM account password hash matches PM root (the wizard hash-copy path)"
RHASH=$($SSHN "getent shadow root | cut -d: -f2" 2>/dev/null)
VHASH=$($SSHN "qm guest exec $VMID --timeout 20 -- bash -c 'getent shadow hamsci | cut -d: -f2' 2>/dev/null" | grep -o '"out-data" *: *"[^"]*"' | sed 's/.*: *"//;s/\\n"$//;s/"$//')
if [ -n "$RHASH" ] && [ "$VHASH" = "$RHASH" ]; then
    say "VM password hash matches PM root ✓"
else
    say "FATAL: VM hamsci hash does not match PM root (wizard hash-copy mangled: pm=${RHASH:0:12}... vm=${VHASH:0:12}...)"; exit 1
fi

say "verifying identity inside decoder VM (post-reboot)"
$SSHN "qm guest exec $VMID --timeout 60 -- bash -lc 'grep -E \"reporter_id|callsign|grid\" /etc/sigmond/site-profile.toml; grep REPORTER /etc/sigmond/coordination.env; hostname'" 2>&1 | tail -8
say "verifying two-phase PSWS enrollment in decoder VM"
PSWS_OUT=$($SSHN "qm guest exec $VMID --timeout 60 -- bash -lc 'grep -A3 \"\\[psws\\]\" /etc/sigmond/site-profile.toml; smd psws status; test -x /etc/update-motd.d/70-sigmond-psws && echo MOTD-HOOK-OK; test -f /etc/hs-uploader/keys/id_ed25519_host.pub && echo STATION-KEY-OK; smd psws motd'" 2>&1)
echo "$PSWS_OUT" | tail -20
echo "$PSWS_OUT" | grep -q 'S000999'        || { say "FATAL: PSWS station id missing from site profile"; exit 1; }
echo "$PSWS_OUT" | grep -q 'MOTD-HOOK-OK'   || { say "FATAL: PSWS motd hook not installed"; exit 1; }
echo "$PSWS_OUT" | grep -q 'STATION-KEY-OK' || { say "FATAL: station key not generated"; exit 1; }
echo "$PSWS_OUT" | grep -qi 'not finished\|NOT YET\|verify' || { say "FATAL: pending-enrollment banner missing"; exit 1; }
say "PSWS: ids recorded, key generated, banner armed — pending verify (as designed)"

say "── v3.4 fixes: wizard unit disabled, getty alive, panel, sentinel, wisdom"
$SSHN "systemctl is-enabled sigmond-wizard.service 2>&1" | grep -q disabled \
    && say "wizard unit disabled post-config ✓" \
    || { say "FATAL: sigmond-wizard.service still enabled — blank-console bug"; exit 1; }
$SSHN "systemctl is-active getty@tty1.service" 2>/dev/null | grep -q '^active' \
    && say "getty@tty1 alive on rebooted host ✓" \
    || { say "FATAL: getty@tty1 not active (blank console)"; exit 1; }
$SSHN "grep -q 'Sigmond appliance' /etc/issue" 2>/dev/null \
    && say "access panel present in /etc/issue ✓" || say "WARN: no access panel in /etc/issue"
V34=$($SSHN "qm guest exec $VMID --timeout 60 -- bash -lc 'systemctl is-enabled sigmond-sdr-sentinel.timer 2>&1; test -s /etc/fftw/wisdomf && echo WISDOM-OK; test -x /usr/local/sbin/sigmond-site-timing && echo TIMING-OK; grep -q \"^v3\" /etc/sigmond-appliance/version 2>/dev/null && echo VMVER-OK'" 2>&1)
echo "$V34" | grep -q enabled   || { say "FATAL: sdr-sentinel timer not enabled in VM"; exit 1; }
echo "$V34" | grep -q WISDOM-OK || { say "FATAL: FFT wisdom not seeded in VM"; exit 1; }
echo "$V34" | grep -q TIMING-OK || { say "FATAL: sigmond-site-timing not installed in VM"; exit 1; }
echo "$V34" | grep -q VMVER-OK  || { say "FATAL: appliance version not stamped into VM"; exit 1; }
UT=$($SSHN "qm guest exec $VMID --timeout 30 -- bash -lc 'command -v btop; command -v tmux; cat /home/hamsci/.tmux.conf 2>/dev/null'" 2>&1)
echo "$UT" | grep -q "bin/btop" && echo "$UT" | grep -q "bin/tmux" && echo "$UT" | grep -q "mouse on" \
    && say "operator utils (btop/tmux + tmux.conf) ✓" \
    || { say "FATAL: btop/tmux/.tmux.conf missing in VM"; exit 1; }
$SSHN "test -f /etc/profile.d/sigmond-operator.sh" \
    && say "operator helpers on host ✓" || { say "FATAL: sigmond-operator.sh missing on host"; exit 1; }
TMF=$($SSHN "qm guest exec $VMID --timeout 30 -- bash -lc 'bash -lc \"type tm; alias ll lrt\" 2>&1'" 2>&1)
echo "$TMF" | grep -q "tm is a function" && echo "$TMF" | grep -q "ls -lrt" \
    && say "tm()/ll/lrt live in VM login shells ✓" \
    || { say "FATAL: operator helpers not active in VM"; echo "$TMF" | head -3; exit 1; }
GRP=$($SSHN "qm guest exec $VMID --timeout 30 -- bash -lc 'id hamsci'" 2>&1)
echo "$GRP" | grep -q "timestd" && echo "$GRP" | grep -q "sigmond" \
    && say "operator service-group membership ✓" \
    || { say "FATAL: hamsci missing service groups"; exit 1; }
MAGC=$($SSHN "qm guest exec $VMID --timeout 30 -- bash -lc 'grep -E \"psws_station_id|^callsign|^grid_square\" /etc/mag-recorder/mag-recorder-config.toml'" 2>&1)
echo "$MAGC" | grep -q "S000998" && echo "$MAGC" | grep -q "N0CALL" && echo "$MAGC" | grep -q "EM00aa" \
    && say "mag-recorder identity filled (own PSWS station) ✓" \
    || { say "FATAL: mag-recorder identity not filled"; echo "$MAGC" | head -3; exit 1; }
say "SDR sentinel armed + wisdom seeded + site-timing staged in VM ✓"
$SSHN "hostname" | grep -q "N0CALL-T1-PM" \
    && say "Proxmox host renamed to N0CALL-T1-PM ✓" \
    || { say "FATAL: host not renamed (naming convention)"; $SSHN hostname; exit 1; }
$SSHN "qm config $VMID | grep -q '^name: N0CALL-T1$'" \
    && say "decoder VM named N0CALL-T1 ✓" \
    || { say "FATAL: VM not renamed"; $SSHN "qm config $VMID | grep name"; exit 1; }
GH=$($SSHN "qm guest exec $VMID --timeout 30 -- bash -lc hostname" 2>/dev/null)
echo "$GH" | grep -qi "N0CALL-T1" && say "VM guest hostname N0CALL-T1 ✓" || say "WARN: guest hostname: $GH"
KR=$($SSHN "qm guest exec $VMID --timeout 30 -- bash -lc 'cat /etc/hs-uploader/keys/id_ed25519_host; stat -c %U:%G /etc/hs-uploader/keys/id_ed25519_host; cat /home/timestd/.ssh/id_rsa_psws 2>/dev/null'" 2>&1)
# pre-bringup the hsupload user doesn't exist yet (born at bringup, when
# site-timing completes the chown) — root:sigmond is the correct interim
echo "$KR" | grep -q TESTPRIV && echo "$KR" | grep -qE "(hsupload|root):sigmond" && echo "$KR" | grep -q TESTRSA \
    && say "site-keys restored from stick with correct ownership ✓" \
    || { say "FATAL: site-keys restore path failed"; echo "$KR" | head -5; exit 1; }
say "── location authority: fake GPSDO announces Scranton (FN21ej)"
LC=$($SSHN "qm guest exec $VMID --timeout 120 -- bash -lc 'test -x /usr/local/sbin/sigmond-location-check || { echo NOT-STAGED; exit 0; }; mkdir -p /run/gpsdo && printf \"{\\\"health\\\": {\\\"latitude\\\": 41.4, \\\"longitude\\\": -75.66, \\\"gps_fix\\\": \\\"3D\\\", \\\"sats_used\\\": 8, \\\"fix_age_sec\\\": 1}}\" > /run/gpsdo/TEST.json; /usr/local/sbin/sigmond-location-check; grep -E \"grid_square|latitude|longitude\" /etc/sigmond/site-profile.toml | head -3'" 2>&1)
echo "$LC" | grep -q NOT-STAGED && { say "FATAL: sigmond-location-check not staged"; exit 1; }
echo "$LC" | grep -q 'FN21ej' && echo "$LC" | grep -q '41.4' \
    && say "location authority re-gridded the station from the (fake) GPSDO ✓" \
    || { say "FATAL: location authority did not apply GPSDO position"; echo "$LC" | head -4; exit 1; }
say "── fleet awareness: heartbeat CLI contract on an unconfigured image"
# Ruled contract (fleet-awareness plan, Phase 6): a fresh image has no
# [heartbeat] block, so emit --dry-run must exit 2 WITH the not-enabled
# message — that proves the CLI is wired and the awareness code rides the
# image.  Exit 0 here would mean a config leaked into the golden template;
# any other exit means the CLI is broken.  The exit-0 path is proven live
# on a configured station, not here.
HB=$($SSHN "qm guest exec $VMID --timeout 30 -- bash -lc 'smd admin heartbeat emit --dry-run; echo rc=\$?'" 2>&1)
echo "$HB" | grep -q "rc=2" && echo "$HB" | grep -q "heartbeat: not enabled" \
    && say "heartbeat emit --dry-run: exit 2 + not-enabled message ✓" \
    || { say "FATAL: heartbeat CLI contract broken on unconfigured image"; echo "$HB" | head -4; exit 1; }
$SSHN "qm guest exec $VMID --timeout 30 -- bash -lc 'systemctl list-unit-files sigmond-heartbeat.timer sigmond-gap-hourly.timer'" 2>&1 | grep -q "sigmond-heartbeat.timer" \
    && say "heartbeat + gap-hourly units present in image ✓" \
    || { say "FATAL: awareness units missing from image"; exit 1; }
say "── gmag-webui (v3.34): pinned Deno + dashboard unit baked into the VM"
# sigmond 9833c25 added gmag-webui (HamSCI magnetometer dashboard) as a dasi2
# core client installed by the smd-native recipe: a pinned Deno under
# /usr/local/lib/deno/<ver>/ with /usr/local/bin/deno, the checkout under
# /opt/git/sigmond/gmag-webui, our gmag-webui.service, .env PORT=8082.  The
# nest has no magnetometer so the unit is DORMANT (not started) — assert the
# payload, not the listener.
GW=$($SSHN "qm guest exec $VMID --timeout 60 -- bash -lc '/usr/local/bin/deno --version 2>/dev/null | head -1; test -f /opt/git/sigmond/gmag-webui/ts/main.ts && echo CHECKOUT-OK; test -f /opt/git/sigmond/gmag-webui/.env && grep -q 8082 /opt/git/sigmond/gmag-webui/.env && echo ENV-OK; systemctl cat gmag-webui.service >/dev/null 2>&1 && echo UNIT-OK; id gmagweb >/dev/null 2>&1 && echo USER-OK'" 2>&1)
echo "$GW" | grep -q "deno [0-9]"   || { say "FATAL: pinned deno missing from VM"; echo "$GW" | head -4; exit 1; }
echo "$GW" | grep -q CHECKOUT-OK   || { say "FATAL: gmag-webui checkout missing from VM"; echo "$GW" | head -4; exit 1; }
echo "$GW" | grep -q ENV-OK        || { say "FATAL: gmag-webui .env (PORT=8082) missing"; echo "$GW" | head -4; exit 1; }
echo "$GW" | grep -q UNIT-OK       || { say "FATAL: gmag-webui.service not installed"; echo "$GW" | head -4; exit 1; }
echo "$GW" | grep -q USER-OK       || { say "FATAL: gmagweb service user missing"; echo "$GW" | head -4; exit 1; }
say "gmag-webui payload in VM: $(echo "$GW" | grep -o 'deno [0-9][^ ]*' | head -1) + checkout + .env + unit + user ✓"
say "PHASE D PASS — NESTED TEST COMPLETE"
;;
esac
say "TEST DRIVER DONE"
