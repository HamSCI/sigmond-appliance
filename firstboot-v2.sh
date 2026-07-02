#!/bin/bash
# Sigmond appliance first-boot v2: arm the USB-hotplug decoder importer (udev)
# + stage the site wizard.  Import copies from the USB: decoder template,
# wizard script, sigmond-rac payload.  After import the wizard owns tty1
# until the operator completes setup (rerunnable later as sigmond-setup).
set +e
LOG=/var/log/sigmond-firstboot.log
say(){ local m="[sigmond $(date '+%T')] $*"; echo "$m"; echo "$m" >>"$LOG" 2>/dev/null; echo "$m" >/dev/console 2>/dev/null; }
say "first-boot v2: installing USB-hotplug importer + wizard hooks"

cat > /usr/local/sbin/sigmond-import.sh <<'IMPEOF'
#!/bin/bash
set +e
exec 9>/run/sigmond-import.lock; flock -n 9 || exit 0
LOG=/var/log/sigmond-firstboot.log
VMID="${SIGMOND_VMID:-120}"; TPL_NAME="sigmond-decoder-template-v2.qcow2"
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
say " Importing the decoder VM (~2 min). LEAVE THE STICK IN."
say "─────────────────────────────────────────────────────────"
VB=$(od -An -tu4 -j $((16*2048+80)) -N4 "$MEDIA" 2>/dev/null | tr -d ' ')
OFF=$(( VB*2048 )); OFF=$(( (OFF+1048575)/1048576*1048576 ))
mkdir -p /mnt/sig-media
LO=$(losetup -f -o "$OFF" --show "$MEDIA" 2>/dev/null)
[ -z "$LO" ] && { say "import: losetup failed"; exit 1; }
mount -o ro "$LO" /mnt/sig-media 2>/dev/null || { say "import: mount failed"; losetup -d "$LO"; exit 1; }
[ -f "/mnt/sig-media/$TPL_NAME" ] || { say "import: template missing"; umount /mnt/sig-media; losetup -d "$LO"; exit 1; }
# Stage appliance extras (wizard + host RAC payload) onto the host
mkdir -p /root/sigmond-appliance
cp /mnt/sig-media/sigmond-wizard.sh /usr/local/sbin/sigmond-setup 2>/dev/null && chmod +x /usr/local/sbin/sigmond-setup
[ -f /mnt/sig-media/sigmond-rac.tar.gz ] && tar xzf /mnt/sig-media/sigmond-rac.tar.gz -C /root/sigmond-appliance 2>/dev/null
STORE="$(pvesm status -content images 2>/dev/null|awk 'NR>1{print $1;exit}')"; [ -z "$STORE" ] && STORE=local-lvm
say "import: copying template to $STORE"
cp "/mnt/sig-media/$TPL_NAME" /tmp/decoder.qcow2; CPRC=$?
umount /mnt/sig-media 2>/dev/null; losetup -d "$LO" 2>/dev/null
[ $CPRC -ne 0 ] && { say "import: copy failed rc=$CPRC"; rm -f /tmp/decoder.qcow2; exit 1; }
qm create "$VMID" --name sigmond-decoder --memory 8192 --cores 4 --cpu host --net0 virtio,bridge=vmbr0 --ostype l26 --scsihw virtio-scsi-single --agent 1
qm importdisk "$VMID" /tmp/decoder.qcow2 "$STORE"
DISK="$(qm config "$VMID"|awk -F': ' '/^unused0:/{print $2;exit}')"
[ -z "$DISK" ] && { say "import: no unused0"; qm destroy "$VMID" --purge 2>/dev/null; rm -f /tmp/decoder.qcow2; exit 1; }
qm set "$VMID" --scsi0 "$DISK" --boot order=scsi0 --onboot 1; rm -f /tmp/decoder.qcow2
if qm start "$VMID"; then
  say "─────────────────────────────────────────────────────────"
  say " ✓ Decoder VM $VMID is installed and running."
  say "   1) REMOVE the USB stick now."
  say "   2) The site setup wizard starts on this console next"
  say "      (or run it any time:  sigmond-setup)"
  say "─────────────────────────────────────────────────────────"
  mkdir -p /etc/sigmond-appliance; touch /etc/sigmond-appliance/.vm-imported
  systemctl daemon-reload; systemctl enable sigmond-wizard.service 2>/dev/null
  systemctl restart sigmond-wizard.service 2>/dev/null
  say "site wizard starting on the console (also: run 'sigmond-setup' any time)"
else
  say "import: qm start failed"; exit 1
fi
IMPEOF
chmod +x /usr/local/sbin/sigmond-import.sh

cat > /etc/systemd/system/sigmond-import.service <<'SVCEOF'
[Unit]
Description=Sigmond decoder VM import from install USB
After=pveproxy.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/sigmond-import.sh
SVCEOF

cat > /etc/systemd/system/sigmond-wizard.service <<'WIZEOF'
[Unit]
Description=Sigmond first-boot site wizard (console)
After=multi-user.target sigmond-import.service
ConditionPathExists=/etc/sigmond-appliance/.vm-imported
ConditionPathExists=!/etc/sigmond-appliance/.configured
Conflicts=getty@tty1.service
[Service]
Type=idle
# make VT1 the visible console before we draw on it
ExecStartPre=-/usr/bin/chvt 1
ExecStart=/usr/local/sbin/sigmond-setup
StandardInput=tty
StandardOutput=tty
# bash read -p writes its prompts to STDERR — without this the wizard
# waits on invisible questions (observed as a black screen, 2026-07-02)
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

cat > /etc/udev/rules.d/99-sigmond-import.rules <<'UDEVEOF'
ACTION=="add", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", ENV{ID_FS_TYPE}=="iso9660", ENV{ID_FS_LABEL}=="PVE", RUN+="/usr/bin/systemctl start --no-block sigmond-import.service"
UDEVEOF
udevadm control --reload-rules 2>/dev/null; systemctl daemon-reload 2>/dev/null
say "─────────────────────────────────────────────────────────"
say " Sigmond appliance: Proxmox is installed and running."
say " NEXT STEP: plug in the Sigmond install USB stick."
say " The decoder VM will then install itself automatically."
say "─────────────────────────────────────────────────────────"
/usr/local/sbin/sigmond-import.sh
say "first-boot v2 complete"
exit 0
