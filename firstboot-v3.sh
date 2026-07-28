#!/bin/bash
# Sigmond appliance first-boot v3: arm the USB-hotplug decoder importer (udev)
# + site wizard + finalizer.  v3 additions over v2:
#   - versioned appliance (@@VERSION@@ baked by build-usb-v3.sh): version in
#     the PVE hostname (answer file), the VM name, /etc/motd, version file.
#   - importer sizes the VM to the host (all CPUs minus one HT pair, RAM
#     minus 2G) using sigmond's own scripts/proxmox layout code (payload).
#   - NEW ORDER (keyboard-safety): import → VM runs UNPINNED → wizard on
#     the console (USB keyboard still on the host) → wizard completion
#     triggers the FINALIZER: VM shutdown → host-apply VM-mode (grub
#     isolcpus/IOMMU, vfio, cpu-pin hookscript, qm affinity/args, USB
#     controller passthrough) → operator removes stick → one reboot →
#     VM autostarts pinned with the SDR passed through.  After that
#     reboot the host may have NO local USB input (all controllers can
#     belong to the VM) — by then nothing needs typing; sigmond-setup
#     remains available over ssh.
#   - decoder VM is VMID 100 (fleet convention).
set +e
LOG=/var/log/sigmond-firstboot.log
VERSION="@@VERSION@@"
say(){ local m="[sigmond $(date '+%T')] $*"; echo "$m"; echo "$m" >>"$LOG" 2>/dev/null; echo "$m" >/dev/console 2>/dev/null; }
say "first-boot v3 ($VERSION): installing importer + wizard + finalizer hooks"
mkdir -p /etc/sigmond-appliance
echo "$VERSION" > /etc/sigmond-appliance/version

# ── importer ──────────────────────────────────────────────────────────────
cat > /usr/local/sbin/sigmond-import.sh <<'IMPEOF'
#!/bin/bash
set +e
exec 9>/run/sigmond-import.lock; flock -n 9 || exit 0
LOG=/var/log/sigmond-firstboot.log
VERSION="$(cat /etc/sigmond-appliance/version 2>/dev/null || echo v3)"
VTAG="${VERSION//./-}"
VMID="${SIGMOND_VMID:-100}"; TPL_NAME="sigmond-decoder-template-v3.qcow2"
APP=/root/sigmond-appliance
say(){ local m="[sigmond $(date '+%T')] $*"; echo "$m" >>"$LOG" 2>/dev/null; echo "$m" >/dev/console 2>/dev/null; }
if qm config "$VMID" 2>/dev/null | grep -q '^scsi0:'; then exit 0; fi
if qm status "$VMID" >/dev/null 2>&1; then qm stop "$VMID" 2>/dev/null; sleep 2; qm destroy "$VMID" --purge 2>/dev/null; fi
MEDIA=""
for t in $(seq 1 12); do
  for d in $(lsblk -dnro PATH,TYPE | awk '$2=="disk"{print $1}'); do
    [ "$(blkid -s LABEL -o value "$d" 2>/dev/null)" = "PVE" ] && [ "$(blkid -s TYPE -o value "$d" 2>/dev/null)" = "iso9660" ] && { MEDIA="$d"; break; }
  done
  [ -n "$MEDIA" ] && break; sleep 5
done
[ -z "$MEDIA" ] && { say "import: no Sigmond USB present"; exit 0; }
say "─────────────────────────────────────────────────────────"
say " Sigmond USB detected ($MEDIA)."
say " Importing the decoder VM (~3 min). LEAVE THE STICK IN."
say "─────────────────────────────────────────────────────────"
VB=$(od -An -tu4 -j $((16*2048+80)) -N4 "$MEDIA" 2>/dev/null | tr -d ' ')
OFF=$(( VB*2048 )); OFF=$(( (OFF+1048575)/1048576*1048576 ))
mkdir -p /mnt/sig-media
LO=$(losetup -f -o "$OFF" --show "$MEDIA" 2>/dev/null)
[ -z "$LO" ] && { say "import: losetup failed"; exit 1; }
mount -o ro "$LO" /mnt/sig-media 2>/dev/null || { say "import: mount failed"; losetup -d "$LO"; exit 1; }
[ -f "/mnt/sig-media/$TPL_NAME" ] || { say "import: template missing"; umount /mnt/sig-media; losetup -d "$LO"; exit 1; }

# Stage appliance extras onto the host: wizard, sigmond checkout (host
# tuning scripts + cpu-pin template), sigmond-rac payload, quickstart.
mkdir -p "$APP"
cp /mnt/sig-media/sigmond-wizard.sh /usr/local/sbin/sigmond-setup 2>/dev/null && chmod +x /usr/local/sbin/sigmond-setup
cp /mnt/sig-media/QUICKSTART.txt "$APP"/ 2>/dev/null
cp /mnt/sig-media/wisdomf-seed "$APP"/ 2>/dev/null
[ -f /mnt/sig-media/sigmond-rac.tar.gz ] && tar xzf /mnt/sig-media/sigmond-rac.tar.gz -C "$APP" 2>/dev/null
[ -f /mnt/sig-media/sigmond.tar.gz ] && tar xzf /mnt/sig-media/sigmond.tar.gz -C "$APP" 2>/dev/null
SIG="$APP/sigmond"
STORE="$(pvesm status -content images 2>/dev/null|awk 'NR>1{print $1;exit}')"; [ -z "$STORE" ] && STORE=local-lvm
say "import: copying decoder template to $STORE"
cp "/mnt/sig-media/$TPL_NAME" /tmp/decoder.qcow2; CPRC=$?
umount /mnt/sig-media 2>/dev/null; losetup -d "$LO" 2>/dev/null
[ $CPRC -ne 0 ] && { say "import: copy failed rc=$CPRC"; rm -f /tmp/decoder.qcow2; exit 1; }

# ── size the VM to this host: all CPUs minus one HT pair, RAM minus 2G ──
MEMTOT=$(free -m | awk 'NR==2{print $2}')
VMMEM=$(( MEMTOT - 2048 )); [ "$VMMEM" -lt 4096 ] && VMMEM=4096
LAYOUT_OK=0
if [ -x "$SIG/scripts/proxmox/host-discover.sh" ]; then
  declare -A KV
  while IFS='=' read -r k v; do
    [[ "$k" =~ ^[A-Z_]+$ ]] && KV[$k]=$(eval "printf '%s' $v")
  done < <(bash "$SIG/scripts/proxmox/host-discover.sh" --no-vm 2>>"$LOG")
  if [ "${KV[DISCOVERY_RESULT]:-}" = "ok" ]; then
    LAYOUT_VARS="$(PYTHONPATH="$SIG/lib" python3 -c '
import sys
from sigmond.cpu import parse_ht_pairs, compute_host_cpu_layout, layout_shell_vars
pairs = parse_ht_pairs(sys.argv[1])
lay = compute_host_cpu_layout(pairs, local_radiod_count=1)
print(layout_shell_vars(lay))
' "${KV[HT_PAIRS]}" 2>>"$LOG")" && LAYOUT_OK=1
  fi
fi
if [ "$LAYOUT_OK" = 1 ]; then
  eval "$LAYOUT_VARS"
  say "import: CPU layout ok — VM gets ${VM_VCPU_COUNT} vCPUs (radiod pair ${RADIOD_CPUS}), ${VMMEM}M RAM"
  CORES_ARGS="--cores $VM_CORES --sockets 1"
  # persist everything the finalizer needs for host-apply VM-mode
  { echo "# sigmond-appliance $VERSION layout $(date -Iseconds)"
    echo "USB_VID_DID=${KV[USB_VID_DID]}"
    echo "CPU_VENDOR=${KV[CPU_VENDOR]}"
    echo "$LAYOUT_VARS"; } > /etc/sigmond-appliance/layout.env
else
  VM_VCPU_COUNT=$(( $(nproc) - 2 )); [ "$VM_VCPU_COUNT" -lt 2 ] && VM_VCPU_COUNT=2
  CORES_ARGS="--cores $VM_VCPU_COUNT --sockets 1"
  say "import: WARNING — CPU layout discovery failed; VM gets $VM_VCPU_COUNT cores UNPINNED (see $LOG)"
fi

qm create "$VMID" --name "sigmond-decoder-${VTAG}" --machine q35 --memory "$VMMEM" $CORES_ARGS \
  --cpu host --net0 virtio,bridge=vmbr0 --ostype l26 --scsihw virtio-scsi-single \
  --agent 1 --serial0 socket --onboot 1
qm importdisk "$VMID" /tmp/decoder.qcow2 "$STORE"
DISK="$(qm config "$VMID"|awk -F': ' '/^unused0:/{print $2;exit}')"
[ -z "$DISK" ] && { say "import: no unused0"; qm destroy "$VMID" --purge 2>/dev/null; rm -f /tmp/decoder.qcow2; exit 1; }
qm set "$VMID" --scsi0 "$DISK" --boot order=scsi0
qm resize "$VMID" scsi0 32G 2>/dev/null && say "import: decoder disk grown to 32G"
rm -f /tmp/decoder.qcow2

# host RAC (inert until /etc/sigmond/frpc-host.toml is filled by the wizard)
[ -x "$APP/sigmond-rac/install-host.sh" ] && bash "$APP/sigmond-rac/install-host.sh" >>"$LOG" 2>&1 \
  && say "import: host RAC installed (inert until configured)"

if qm start "$VMID"; then
  say "─────────────────────────────────────────────────────────"
  say " ✓ Decoder VM $VMID (sigmond-decoder-${VTAG}) is running."
  say "   LEAVE THE USB STICK IN — the site setup wizard starts"
  say "   on this console next (or run it via ssh: sigmond-setup)."
  say "   Host tuning + reboot happen AFTER the wizard."
  say "─────────────────────────────────────────────────────────"
  touch /etc/sigmond-appliance/.vm-imported
  systemctl daemon-reload
  systemctl enable sigmond-wizard.service sigmond-finalize.path 2>/dev/null
  systemctl start --no-block sigmond-finalize.path 2>/dev/null
  systemctl --no-block restart sigmond-wizard.service 2>/dev/null
  say "site wizard starting on the console"
else
  say "import: qm start failed"; exit 1
fi
IMPEOF
chmod +x /usr/local/sbin/sigmond-import.sh

# ── finalizer: runs when the wizard marks .configured ────────────────────
cat > /usr/local/sbin/sigmond-finalize.sh <<'FINEOF'
#!/bin/bash
# Sigmond appliance finalizer: after the site wizard completes, bind host
# tuning to the decoder VM (sigmond scripts/proxmox host-apply VM-mode),
# then have the operator pull the stick and reboot into production.
set +e
exec 8>/run/sigmond-finalize.lock; flock -n 8 || exit 0
LOG=/var/log/sigmond-firstboot.log
VMID="${SIGMOND_VMID:-100}"
APP=/root/sigmond-appliance
SIG="$APP/sigmond"
say(){ local m="[sigmond $(date '+%T')] $*"; echo "$m" >>"$LOG" 2>/dev/null; echo "$m" >/dev/console 2>/dev/null; }
[ -f /etc/sigmond-appliance/.configured ] || exit 0
# defense in depth for the blank-console bug: a still-enabled wizard unit
# kills getty@tty1 every boot via Conflicts even when its Condition fails
systemctl disable sigmond-wizard.service 2>/dev/null
[ -f /etc/sigmond-appliance/.finalized ] && exit 0

if [ ! -f /etc/sigmond-appliance/layout.env ]; then
  say "finalize: no CPU layout saved — leaving VM untuned (unpinned, no passthrough)."
  say "finalize: tune later from a sigmond checkout: scripts/proxmox/bootstrap.sh"
  touch /etc/sigmond-appliance/.finalized
  exit 0
fi
. /etc/sigmond-appliance/layout.env

say "─────────────────────────────────────────────────────────"
say " Site wizard done. Binding host tuning to VM $VMID:"
say " CPU isolation + pinning, USB controller passthrough."
say " The decoder VM restarts once, pinned, after a reboot."
say "─────────────────────────────────────────────────────────"
qm shutdown "$VMID" --timeout 120 2>/dev/null
qm stop "$VMID" 2>/dev/null

cp "$SIG/scripts/proxmox/cpu-pin-VMID.sh.template" /tmp/cpu-pin-VMID.sh.template
if VMID="$VMID" USB_VID_DID="$USB_VID_DID" CPU_VENDOR="$CPU_VENDOR" \
   ISOLCPUS_RANGE="$ISOLCPUS_RANGE" VM_VCPU_COUNT="$VM_VCPU_COUNT" \
   VM_CORES="$VM_CORES" VM_THREADS="$VM_THREADS" RADIOD_CPUS="$RADIOD_CPUS" \
   WORKER_CPUS="$WORKER_CPUS" VCPU_TO_PCPU="$VCPU_TO_PCPU" \
   bash "$SIG/scripts/proxmox/host-apply.sh" >>"$LOG" 2>&1; then
  mkdir -p /etc/sigmond
  { echo "# written by sigmond-appliance finalize $(date -Iseconds)"
    echo "LOCAL_RADIOD_COUNT=1"
    grep -v '^#' /etc/sigmond-appliance/layout.env; } > /etc/sigmond/host-layout.env
  say "finalize: host tuned (grub isolcpus/IOMMU, vfio, cpu-pin hookscript, qm bind)"
else
  say "finalize: WARNING — host-apply failed (see $LOG); VM left untuned"
  qm start "$VMID" 2>/dev/null
  touch /etc/sigmond-appliance/.finalized
  exit 0
fi
touch /etc/sigmond-appliance/.finalized

say "─────────────────────────────────────────────────────────"
say " >>> REMOVE THE USB STICK NOW <<<"
say " The system reboots into production automatically once"
say " the stick is removed (decoder VM autostarts, pinned,"
say " with the SDR passed through)."
say "─────────────────────────────────────────────────────────"
# Rebooting with the stick in risks a BIOS USB-first loop back into the
# PVE installer — wait for removal (up to 60 min), then reboot.
GONE=0
for i in $(seq 1 720); do
  GONE=1
  for d in $(lsblk -dnro PATH,TYPE 2>/dev/null | awk '$2=="disk"{print $1}'); do
    [ "$(blkid -s LABEL -o value "$d" 2>/dev/null)" = "PVE" ] && GONE=0
  done
  [ "$GONE" = 1 ] && break
  sleep 5
done
if [ "$GONE" = 1 ]; then
  say "stick removed — rebooting now"
  sleep 3; reboot
else
  say "WARNING: stick still present after 60 min — NOT rebooting."
  say "Remove it and run:  reboot"
fi
FINEOF
chmod +x /usr/local/sbin/sigmond-finalize.sh

cat > /etc/systemd/system/sigmond-import.service <<'SVCEOF'
[Unit]
Description=Sigmond decoder VM import from install USB
After=pveproxy.service
[Service]
Type=oneshot
Environment=SIGMOND_VMID=100
ExecStart=/usr/local/sbin/sigmond-import.sh
SVCEOF

cat > /etc/systemd/system/sigmond-finalize.path <<'PATHEOF'
[Unit]
Description=Trigger Sigmond finalizer when the site wizard completes
[Path]
PathExists=/etc/sigmond-appliance/.configured
[Install]
WantedBy=multi-user.target
PATHEOF

cat > /etc/systemd/system/sigmond-finalize.service <<'FSVCEOF'
[Unit]
Description=Sigmond appliance finalizer (host tuning + production reboot)
ConditionPathExists=/etc/sigmond-appliance/.configured
ConditionPathExists=!/etc/sigmond-appliance/.finalized
[Service]
Type=oneshot
Environment=SIGMOND_VMID=100
ExecStart=/usr/local/sbin/sigmond-finalize.sh
FSVCEOF

cat > /etc/systemd/system/sigmond-wizard.service <<'WIZEOF'
[Unit]
Description=Sigmond first-boot site wizard (console)
# NO After=sigmond-import.service: the importer starts us synchronously,
# so that ordering deadlocks (job queued forever, black console —
# observed on real hardware 2026-07-02). The .vm-imported Condition
# already guarantees we only run post-import.
After=multi-user.target
ConditionPathExists=/etc/sigmond-appliance/.vm-imported
ConditionPathExists=!/etc/sigmond-appliance/.configured
Conflicts=getty@tty1.service
[Service]
Type=simple
Environment=SIGMOND_VMID=100
# make VT1 the visible console before we draw on it
ExecStartPre=-/usr/bin/chvt 1
ExecStart=/usr/local/sbin/sigmond-setup
StandardInput=tty
StandardOutput=tty
# bash read -p writes its prompts to STDERR — without this the wizard
# waits on invisible questions (black screen, 2026-07-02)
StandardError=tty
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
# no auto-restart: a crash-loop re-clears the tty every cycle (black
# screen); on any exit hand the console back to a login prompt instead
Restart=no
ExecStopPost=/bin/systemctl --no-block start getty@tty1.service
[Install]
WantedBy=multi-user.target
WIZEOF

# ── persistent access panel on the console login screen ──────────────────
# pvebanner.service rewrites /etc/issue at every boot, wiping anything the
# wizard pinned there; and DHCP addresses go stale.  sigmond-issue rebuilds
# a live who/where/how-to-login panel each boot (rob 2026-07-27: the login
# screen must show IPs + logins for BOTH the host and the decoder VM).
cat > /usr/local/sbin/sigmond-issue <<'ISSEOF'
#!/bin/bash
# Regenerate the Sigmond access panel in /etc/issue + /etc/motd (markered).
VMID="${SIGMOND_VMID:-100}"
VERSION="$(cat /etc/sigmond-appliance/version 2>/dev/null || echo '?')"
CONF="$(cat /etc/sigmond-appliance/.configured 2>/dev/null)"
HOSTIP=$(hostname -I 2>/dev/null | awk '{print $1}')
VMIP=""
for i in 1 2 3 4 5 6; do
  VMIP=$(qm agent "$VMID" network-get-interfaces 2>/dev/null | python3 -c '
import json,sys
try:
    for i in json.load(sys.stdin):
        if i.get("name","").startswith(("en","eth")):
            for a in i.get("ip-addresses",[]):
                if a["ip-address-type"]=="ipv4" and not a["ip-address"].startswith("127"):
                    print(a["ip-address"]); raise SystemExit
except Exception: pass' 2>/dev/null)
  [ -n "$VMIP" ] && break
  sleep 10
done
PANEL=$(cat <<PEOF
════ Sigmond appliance $VERSION ${CONF:+— station ${CONF%% *}} ════
 Proxmox host:  ssh root@${HOSTIP:-<no-ip-yet>}
                web UI  https://${HOSTIP:-<no-ip-yet>}:8006
                password: set at install (image default hamsci-sigmond — change it!)
 Decoder VM:    ssh sigmond@${VMIP:-<vm-starting>}   (same password as host root)
                ssh hamsci@${VMIP:-<vm-starting>}    (image default sigmond-hamsci)
                from this host:  sigmond-vm     console:  qm terminal $VMID
 Wizard rerun:  sigmond-setup --reconfigure
PEOF
)
for f in /etc/issue /etc/motd; do
    sed -i '/^════ Sigmond appliance /,/^ Wizard rerun:/d' "$f" 2>/dev/null
    printf '%s\n\n' "$PANEL" >> "$f"
done
exit 0
ISSEOF
chmod +x /usr/local/sbin/sigmond-issue

cat > /etc/systemd/system/sigmond-issue.service <<'ISVCEOF'
[Unit]
Description=Sigmond access panel on the login screen (live IPs)
# after pvebanner has done its /etc/issue rewrite, and late enough that
# the decoder VM (onboot) has an address; the script itself retries the
# guest-agent query for ~60s.
After=multi-user.target pvebanner.service pve-guests.service
[Service]
Type=oneshot
Environment=SIGMOND_VMID=100
ExecStart=/usr/local/sbin/sigmond-issue
[Install]
WantedBy=multi-user.target
ISVCEOF
systemctl daemon-reload 2>/dev/null; systemctl enable sigmond-issue.service 2>/dev/null

cat > /etc/udev/rules.d/99-sigmond-import.rules <<'UDEVEOF'
ACTION=="add", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", ENV{ID_FS_TYPE}=="iso9660", ENV{ID_FS_LABEL}=="PVE", RUN+="/usr/bin/systemctl start --no-block sigmond-import.service"
UDEVEOF
udevadm control --reload-rules 2>/dev/null; systemctl daemon-reload 2>/dev/null

grep -q "Sigmond appliance" /etc/motd 2>/dev/null || cat >> /etc/motd <<MOTDEOF

  ==== Sigmond appliance $VERSION ====
  Decoder VM: 100 (sigmond-decoder-${VERSION//./-})   Wizard: sigmond-setup
MOTDEOF

HOSTIP=$(hostname -I 2>/dev/null | awk '{print $1}')
say "─────────────────────────────────────────────────────────"
say " Sigmond appliance $VERSION: Proxmox is installed and running."
say "   console/SSH login: root / hamsci-sigmond  (CHANGE IT: 'passwd')"
say "   ssh root@${HOSTIP:-<host-ip>}    web GUI: https://${HOSTIP:-<host-ip>}:8006"
say " NEXT STEP: plug in the Sigmond install USB stick."
say " The decoder VM then installs itself automatically."
say "─────────────────────────────────────────────────────────"
/usr/local/sbin/sigmond-import.sh
say "first-boot v3 complete"
exit 0
