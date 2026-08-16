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
#     controller passthrough) → operator removes stick → POWER OFF →
#     operator powers back on (the power-off is also the RX888's reset) →
#     VM autostarts pinned with the SDR passed through.  After that
#     power-on the host may have NO local USB input (all controllers can
#     belong to the VM) — by then nothing needs typing; sigmond-setup
#     remains available over ssh.
#   - decoder VM is VMID 100 (fleet convention).
set +e
LOG=/var/log/sigmond-firstboot.log
VERSION="@@VERSION@@"
# The one-time leading newline: getty@tty1 stays ALIVE next to firstboot, so
# its "login:" prompt sits mid-line on the console and our first write would
# land on that same line (mjh, v3.26 test 2026-08-09 — same bug class as the
# wizard's first line, different actor).  Drop to a fresh line once per
# process before the first console write.
say(){ local m="[sigmond $(date '+%T')] $*"; echo "$m"; echo "$m" >>"$LOG" 2>/dev/null
      [ -z "$_SAY_NL" ] && { _SAY_NL=1; printf '\n' >/dev/console 2>/dev/null; }
      echo "$m" >/dev/console 2>/dev/null; }
say "first-boot v3 ($VERSION): installing importer + wizard + finalizer hooks"
mkdir -p /etc/sigmond-appliance
echo "$VERSION" > /etc/sigmond-appliance/version

# ── host networking: DHCP on vmbr0 ────────────────────────────────────────
# The PVE installer answers "from-dhcp", but when no lease arrives in its
# window (late NIC link, installer-env firmware) it silently falls back to
# 192.168.100.2/24 — and PVE ALWAYS writes a STATIC config from whatever
# the installer ended up with, fossilizing the bogus address (observed on
# rob's LAN 2026-07-28: appliance came up 192.168.100.0/24 on a
# 192.168.1.0/24 network). The appliance must take whatever the site LAN
# offers: convert vmbr0 to DHCP, keep /etc/hosts pinned to the live lease
# (PVE tools resolve the node name via /etc/hosts), and fall back to the
# installer's static config only if DHCP times out on the real hardware.
if grep -q '^iface vmbr0 inet static' /etc/network/interfaces; then
  say "converting vmbr0 to DHCP (installer wrote static $(hostname -I 2>/dev/null | awk '{print $1}'))"
  cp /etc/network/interfaces /etc/network/interfaces.sigmond-static-bak
  sed -i -e '/^iface vmbr0 inet static/,/^\s*$/{/^\s*address\s/d;/^\s*gateway\s/d;}' \
         -e 's/^iface vmbr0 inet static/iface vmbr0 inet dhcp/' /etc/network/interfaces
  mkdir -p /etc/dhcp/dhclient-exit-hooks.d
  cat > /etc/dhcp/dhclient-exit-hooks.d/sigmond-pve-hosts <<'HOOKEOF'
# Sigmond appliance: keep the node's /etc/hosts line on the current DHCP
# lease — PVE resolves its own hostname via /etc/hosts (static-IP design).
case "$reason" in
  BOUND|RENEW|REBIND|REBOOT)
    H=$(hostname)
    if [ -n "$new_ip_address" ] && grep -qE "^[0-9.]+[[:space:]].*\b$H\b" /etc/hosts; then
      sed -i -E "s/^[0-9.]+([[:space:]].*\b$H\b)/$new_ip_address\1/" /etc/hosts
    fi
  ;;
esac
HOOKEOF
  chmod 644 /etc/dhcp/dhclient-exit-hooks.d/sigmond-pve-hosts
  if command -v ifreload >/dev/null 2>&1; then ifreload -a 2>/dev/null; else ifdown vmbr0 2>/dev/null; ifup vmbr0 2>/dev/null; fi
  HOSTIP=""
  for i in $(seq 1 12); do
    HOSTIP=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -n "$HOSTIP" ] && break
    sleep 5
  done
  if [ -n "$HOSTIP" ]; then
    say "vmbr0 DHCP lease: $HOSTIP"
  else
    say "WARNING: no DHCP lease after 60s — restoring the installer's static config"
    cp /etc/network/interfaces.sigmond-static-bak /etc/network/interfaces
    if command -v ifreload >/dev/null 2>&1; then ifreload -a 2>/dev/null; else ifdown vmbr0 2>/dev/null; ifup vmbr0 2>/dev/null; fi
  fi
fi

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
say(){ local m="[sigmond $(date '+%T')] $*"; echo "$m" >>"$LOG" 2>/dev/null
      [ -z "$_SAY_NL" ] && { _SAY_NL=1; printf '\n' >/dev/console 2>/dev/null; }
      echo "$m" >/dev/console 2>/dev/null; }
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
cp /mnt/sig-media/sigmond-site-timing "$APP"/ 2>/dev/null
# operator shell helpers (rob's tm/ll/lrt): host now, VM via the wizard
cp /mnt/sig-media/sigmond-operator.sh "$APP"/ 2>/dev/null
cp /mnt/sig-media/sigmond-location-check "$APP"/ 2>/dev/null
# component pin manifest (Stage 3): the record of what this image was built
# from, so a host can later answer "am I what my image says I am" without
# reaching GitHub. Absent on any image built before this shipped -- that is
# expected, not an error: log one line and move on. Never fail firstboot
# over an optional file.
if [ -f /mnt/sig-media/manifest.txt ]; then
  install -m 0644 -o root -g root /mnt/sig-media/manifest.txt /etc/sigmond-appliance/manifest.txt \
    && say "import: component pin manifest installed (/etc/sigmond-appliance/manifest.txt)"
else
  say "import: no component pin manifest on this image (built before manifest support) — drift check unavailable"
fi
[ -f "$APP/sigmond-operator.sh" ] && install -m 644 "$APP/sigmond-operator.sh" /etc/profile.d/sigmond-operator.sh
# profile.d only reaches LOGIN shells — hook bash.bashrc so interactive
# non-login shells (plain `bash`, some tmux configs) get the helpers too
grep -q sigmond-operator /etc/bash.bashrc 2>/dev/null || echo '[ -f /etc/profile.d/sigmond-operator.sh ] && . /etc/profile.d/sigmond-operator.sh' >> /etc/bash.bashrc
# optional site-keys tarball: a returning station's registered upload/PSWS
# keys, dropped by the operator onto the stick's FAT (EFI) volume after
# burning (writable from Mac/Windows). Staged here; the wizard restores it
# into the decoder VM so the PSWS portal registration survives greenfields.
ESPP=$(lsblk -nrpo NAME,TYPE "$MEDIA" 2>/dev/null | awk '$2=="part"{n++; if(n==2)print $1}')
if [ -n "$ESPP" ]; then
  mkdir -p /mnt/sig-esp
  if mount -o ro "$ESPP" /mnt/sig-esp 2>/dev/null; then
    [ -f /mnt/sig-esp/site-keys.tar.gz ] && cp /mnt/sig-esp/site-keys.tar.gz "$APP"/ \
      && say "import: site-keys.tar.gz staged from the stick (key restore armed)"
    umount /mnt/sig-esp 2>/dev/null
  fi
fi
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
# size the decoder disk to the host's storage: the full timing chain's
# 6-channel raw archive needs ~77G baseline (metrology preflight starved
# at a fixed 32G, 2026-07-29). Thin-provisioned, so generosity is cheap:
# 75% of the store's free space, capped 256G, floor 32G.
AVAIL_G=$(pvesm status 2>/dev/null | awk -v s="$STORE" '$1==s{print int($6/1048576)}')
TARGET_G=$(( ${AVAIL_G:-0} * 3 / 4 ))
[ "$TARGET_G" -gt 256 ] && TARGET_G=256
[ "$TARGET_G" -lt 32 ] && TARGET_G=32
qm resize "$VMID" scsi0 "${TARGET_G}G" 2>/dev/null && say "import: decoder disk grown to ${TARGET_G}G (store had ${AVAIL_G}G free)"
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
say(){ local m="[sigmond $(date '+%T')] $*"; echo "$m" >>"$LOG" 2>/dev/null
      [ -z "$_SAY_NL" ] && { _SAY_NL=1; printf '\n' >/dev/console 2>/dev/null; }
      echo "$m" >/dev/console 2>/dev/null; }
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
say " >>> INSTALL COMPLETE — REMOVE THE USB STICK NOW <<<"
say " As soon as the stick is removed this machine POWERS OFF."
say " Power it back on to finish the installation.  The full"
say " power-off also resets the RX888 SDR, so on that power-on"
say " the decoder VM can finally see it."
say "─────────────────────────────────────────────────────────"
# Wait for removal before acting (up to 60 min): booting with the stick in
# risks a BIOS USB-first loop back into the PVE installer, and acting only
# after removal proves the operator has read the instruction.
# poweroff, NOT reboot (rob 2026-08-09): a warm reboot never drops VBUS, so
# the RX888's FX3 stays latched mid-handoff and the SDR is invisible to the
# VM.  A real power-off is the reset it needs — the operator's power-on
# doubles as the RX888 power-cycle.
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
  say "stick removed — POWERING OFF now."
  say "Power the machine back on to finish the installation."
  sleep 3; poweroff
else
  say "WARNING: stick still present after 60 min — NOT powering off."
  say "Remove it, run:  poweroff   — then power the machine back on."
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
# TTYReset=no ON PURPOSE: a reset blanks VT1 when the wizard exits, taking
# the install transcript with it (rob 2026-08-09).  The wizard only ever uses
# plain `read`, so it leaves no terminal modes behind that need resetting.
# TTYVHangup stays — that runs at START, to take the console off getty.
TTYReset=no
TTYVHangup=yes
# no auto-restart: a crash-loop re-clears the tty every cycle (black
# screen); on any exit hand the console back to a login prompt instead
Restart=no
ExecStopPost=/bin/systemctl --no-block start getty@tty1.service
[Install]
WantedBy=multi-user.target
WIZEOF

# ── keep the console readable after the wizard exits ─────────────────────
# The wizard hands the console back with ExecStopPost=start getty@tty1, and
# that wipes every line sigmond just printed (rob 2026-08-09: "at the end it
# clears the console screen so I don't get to see what it was doing").
# agetty is NOT the culprit — Debian already passes --noclear --noreset.
# It is systemd's TTYVTDisallocate=yes, which deallocates the VT itself.
# So override exactly that one setting and leave ExecStart alone.
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/10-sigmond-noclear.conf <<'GTEOF'
[Service]
# preserve the install transcript on VT1 — see sigmond-wizard.service
TTYVTDisallocate=no
GTEOF
systemctl daemon-reload 2>/dev/null

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
# Is host root still on the image default?  If so we can print it outright,
# which is the whole point of this panel — an operator who cannot type here
# and does not know the password has no way in at all.  If it was changed we
# must not guess, so we say where it came from instead.
# RX888 handoff notice.  The wizard leaves a marker when it saw an RX888 on
# the host that the VM could not see; that instruction has to survive the
# reboot which immediately follows, so it lives here rather than only in the
# install transcript.  Re-checked on every refresh and removed once the SDR
# actually turns up, so it cannot linger as a stale scare.
RXWARN=""
if [ -f /etc/sigmond-appliance/.rx888-needs-powercycle ]; then
    if qm guest exec "$VMID" -- /usr/bin/lsusb 2>/dev/null \
         | grep -qiE '04b4:00(f[013]|bc)|f4b3:0100'; then
        rm -f /etc/sigmond-appliance/.rx888-needs-powercycle
    else
        RXWARN=" !! RX888 NOT VISIBLE TO THE DECODER VM
 !!   The SDR was handed to the VM part-way through its USB start-up and
 !!   stays latched until its power is removed.  A REBOOT IS NOT ENOUGH.
 !!   ==> Unplug and replug the RX888's USB cable, or power the machine
 !!       fully OFF then on (some boards keep USB power in soft-off — if
 !!       you already power-cycled and still see this, replug the cable).
 !!       radiod then starts by itself within about 2 minutes, this
 !!       notice clears, and it will not happen again on later boots.
"
    fi
fi

# libc crypt via perl, NOT openssl passwd: Debian roots are yescrypt ($y$),
# which openssl cannot compute — v3.25 said "the password you set at
# install" even on a box still on the image default (mjh 2026-08-09).
PWLINE="the password you set at install"
_h=$(awk -F: '$1=="root"{print $2}' /etc/shadow 2>/dev/null)
case "$_h" in
  \$*) [ "$(perl -e 'print crypt($ARGV[1], $ARGV[0])' "$_h" hamsci-sigmond 2>/dev/null)" = "$_h" ] \
          && PWLINE="hamsci-sigmond   <-- image default, CHANGE IT" ;;
esac

PANEL=$(cat <<PEOF
════ Sigmond appliance $VERSION ${CONF:+— station ${CONF%% *}} ════
 THIS CONSOLE IS READ-ONLY — the keyboard does not work here.  Its USB
 controller was passed through to the decoder VM, so nothing you type on
 this machine registers.  Reach the station from another computer using
 the addresses below.

${RXWARN}
 Proxmox host ${HOSTIP:-<no-ip-yet>}
   ssh        ssh root@${HOSTIP:-<no-ip-yet>}
   web UI     https://${HOSTIP:-<no-ip-yet>}:8006
   login      root / $PWLINE

 Decoder VM   ${VMIP:-<starting — this panel refreshes every 5 min>}
   ssh        ssh sigmond@${VMIP:-<starting>}      (also: hamsci@)
   ka9q-web   http://${VMIP:-<starting>}:8081
   login      sigmond / $PWLINE

 From the host over ssh:  sigmond-vm        (shell in the decoder VM)
                          qm terminal $VMID  (its console)
                          sigmond-setup --reconfigure   (rerun the wizard)
════ end Sigmond panel ════
PEOF
)
for f in /etc/issue /etc/motd; do
    sed -i '/^════ Sigmond appliance /,/^════ end Sigmond panel ════/d' "$f" 2>/dev/null
    printf '%s\n\n' "$PANEL" >> "$f"
done
# The files above only matter when getty (re)paints them — which it does
# ONCE, early in boot, BEFORE this script first runs, and never again: the
# console keyboard is dead, so no keypress can ever trigger a redraw.
# v3.25 shipped a correct panel that no operator ever saw (mjh 2026-08-09).
# Paint it straight onto VT1 ourselves.  Only on post-install boots: never
# while the wizard or finalizer own the console (that would erase the
# install transcript / the remove-the-stick instruction), and never over a
# live console login (an untuned host still has a working keyboard).
if [ -f /etc/sigmond-appliance/.finalized ] \
   && ! systemctl is-active --quiet sigmond-wizard.service 2>/dev/null \
   && ! systemctl is-active --quiet sigmond-finalize.service 2>/dev/null \
   && ! who 2>/dev/null | grep -qw tty1; then
    { printf '\033[H\033[2J'; printf '%s\n' "$PANEL"; } > /dev/tty1 2>/dev/null
fi
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
cat > /etc/systemd/system/sigmond-issue.timer <<'ITEOF'
[Unit]
Description=Refresh the Sigmond access panel (VM address appears late; DHCP moves it)
[Timer]
OnBootSec=45s
OnUnitActiveSec=5min
[Install]
WantedBy=timers.target
ITEOF
systemctl daemon-reload 2>/dev/null
systemctl enable sigmond-issue.service sigmond-issue.timer 2>/dev/null

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
