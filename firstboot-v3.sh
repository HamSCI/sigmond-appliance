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

# ── host networking: vmbr0 must be on a NIC that can REACH the LAN ────────
# Installed as a script + boot unit rather than done inline, because the
# failure it fixes is not a one-time event: a cable moved to the other socket
# must heal the machine on the next boot, with nobody at the console.
cat > /usr/local/sbin/sigmond-netfix <<'NETFIXEOF'
#!/bin/bash
# sigmond-netfix — make sure vmbr0 is on a NIC that can actually reach the LAN.
#
# ⛔ WHY THIS EXISTS
# The PVE installer asks for DHCP, and when no lease arrives in its window it
# silently falls back to a STATIC 192.168.100.2/24 and fossilizes it.  If the
# port it bound vmbr0 to has no carrier at all -- a second NIC, a dead port, a
# cable in the other socket -- no amount of waiting helps, and the install ends
# as a machine on an address nobody can route to.
#
# That is a DEAD INSTALL.  The operator cannot ssh in, the Proxmox UI is on the
# same unreachable address, RAC never registers because there is no route out,
# and on an appliance whose USB controller goes to the decoder VM there may be
# no working keyboard either.  It happened to AI6VN on 2026-09-21 with a v3.48
# stick: vmbr0 bound to a NIC with no link light while the live cable sat in
# the other socket.  rob: "this would be a real pain in the field ... it's
# basically a dead install so we've got to address that."
#
# So: never accept the fallback.  Look at every physical NIC, find one with
# CARRIER that a DHCP server actually answers on, and rebind vmbr0 to it.
#
# Runs at every boot, not once, so moving the cable to a different socket
# heals the machine by itself.
set -u
LOG=/var/log/sigmond-firstboot.log
say(){ local m="[netfix $(date '+%T')] $*"; echo "$m" >>"$LOG" 2>/dev/null
       echo "$m" >/dev/console 2>/dev/null; echo "$m"; }

IFACES=/etc/network/interfaces
FALLBACK_NET='192\.168\.100\.'

reload_net(){
    if command -v ifreload >/dev/null 2>&1; then ifreload -a 2>/dev/null
    else ifdown vmbr0 2>/dev/null; ifup vmbr0 2>/dev/null; fi
}

cur_ip(){ ip -4 -o addr show vmbr0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1; }

# An install that cannot get an address is FINISHED -- not degraded.  There is
# no ssh, no Proxmox UI, no RAC, and on this appliance possibly no keyboard.
# So say so on the CONSOLE, in full, with the exact command that fixes it.  A
# log line nobody can read is not a warning (rob, 2026-09-21: "that's an error
# condition that should be flagged at install time").
net_dead(){
    local title="$1" why="$2" nics="$3" line
    mkdir -p /etc/sigmond-appliance 2>/dev/null
    { echo "$title"; echo "$why"; echo "nics:$nics"; date -Iseconds; } \
        > /etc/sigmond-appliance/.network-unreachable 2>/dev/null
    for line in \
"" \
"########################################################################" \
"##  INSTALL CANNOT CONTINUE NORMALLY: $title" \
"##" \
"##  $why" \
"##     $nics" \
"##" \
"##  Without an address this machine has NO ssh, NO web UI and NO remote" \
"##  access, and its keyboard may be handed to the decoder VM later. It" \
"##  must be given a working address NOW." \
"##" \
"##  1) Preferred: plug the cable into a port with a link light and" \
"##     reboot. This check runs at every boot and will bind to whichever" \
"##     port answers." \
"##" \
"##  2) Or set a static address by hand and PROVE it works:" \
"##        sigmond-setnet 10.0.0.50/24 10.0.0.1" \
"##     It refuses to keep an address whose gateway does not answer, so" \
"##     it cannot strand you the way the installer default did." \
"##" \
"##  Current state is recorded in" \
"##     /etc/sigmond-appliance/.network-unreachable" \
"########################################################################" \
"" ; do
        echo "$line" >/dev/console 2>/dev/null
        echo "$line" >>"$LOG" 2>/dev/null
    done
}

# ── is there anything to do? ────────────────────────────────────────────────
# Only act when vmbr0 has NO address or is sitting on the installer's
# fallback.  A station with a real lease is never touched -- this must not
# renumber a working site.
IP="$(cur_ip)"
case "$IP" in
    "")          say "vmbr0 has no IPv4 — looking for a NIC that does" ;;
    192.168.100.*) say "vmbr0 is on the PVE installer fallback $IP — that address is not routable here" ;;
    *)
        # A REAL address, so the NIC hunt below is not needed.  But PVE writes
        # a STATIC stanza even when its own DHCP succeeded, which fossilizes
        # whatever it got: the station keeps that address after the lease
        # changes or the site renumbers (rob's LAN, 2026-07-28).  De-fossilize
        # here -- this is the original firstboot behaviour, and dropping it
        # when netfix took over was a regression the nested test caught
        # ("FATAL: vmbr0 not on DHCP (static-fossilization bug)").
        grep -q '^iface vmbr0 inet static' "$IFACES" 2>/dev/null || exit 0
        say "vmbr0 has $IP but is configured STATIC — converting to DHCP so it cannot fossilize"
        cp -a "$IFACES" "$IFACES.netfix-static-bak"
        sed -i -e '/^iface vmbr0 inet static/,/^[[:space:]]*$/{/^[[:space:]]*address[[:space:]]/d;/^[[:space:]]*gateway[[:space:]]/d;}' \
               -e 's/^iface vmbr0 inet static/iface vmbr0 inet dhcp/' "$IFACES"
        reload_net
        for i in $(seq 1 12); do NEW="$(cur_ip)"; [ -n "$NEW" ] && break; sleep 5; done
        if [ -n "${NEW:-}" ]; then
            say "vmbr0 now takes DHCP; lease $NEW"
            H=$(hostname)
            grep -qE "^[0-9.]+[[:space:]].*\b$H\b" /etc/hosts 2>/dev/null && \
                sed -i -E "s/^[0-9.]+([[:space:]].*\b$H\b)/$NEW\1/" /etc/hosts
        else
            # Never trade a working address for none.
            say "WARNING: no lease after 60s — restoring the static config ($IP)"
            cp -a "$IFACES.netfix-static-bak" "$IFACES"
            reload_net
        fi
        exit 0 ;;
esac

# ── candidate NICs: physical, not the bridge, not virtual ───────────────────
# Ordered carrier-first so a live cable wins over a dead one regardless of
# what the installer picked.
CANDS=""
for d in /sys/class/net/*; do
    n=$(basename "$d")
    case "$n" in lo|vmbr*|tap*|fwbr*|fwln*|fwpr*|veth*|bond*|dummy*|wg*|tun*) continue ;; esac
    [ -e "$d/device" ] || continue          # physical only
    # ⛔ NEVER probe a NIC already enslaved to a bridge.  Running dhclient on
    # a bridge member and then flushing it tears down the very bridge we are
    # trying to repair -- vmbr0's own port would otherwise be fair game here,
    # which is a repair that breaks the thing it repairs.
    if [ -e "$d/master" ]; then
        say "  skipping $n — already enslaved to $(basename "$(readlink -f "$d/master")" 2>/dev/null)"
        continue
    fi
    ip link set "$n" up 2>/dev/null         # a down NIC reports no carrier
    CANDS="$CANDS $n"
done
[ -n "$CANDS" ] || { say "no physical NICs found — cannot fix networking"; exit 1; }
sleep 4                                     # let link negotiate after the ups

LIVE=""; DEAD=""
for n in $CANDS; do
    if [ "$(cat "/sys/class/net/$n/carrier" 2>/dev/null)" = "1" ]; then
        LIVE="$LIVE $n"
    else
        DEAD="$DEAD $n"
    fi
done
say "NICs with link:${LIVE:- none}${DEAD:+ ; no link:$DEAD}"
if [ -z "$LIVE" ]; then
    net_dead "NO NETWORK CABLE DETECTED" \
             "None of this machine's network ports has a link signal:" \
             "$CANDS"
    exit 1
fi

# ── try DHCP on each live NIC, standalone, before committing ────────────────
# Carrier alone is not enough: a switch port can be up with nothing behind it.
# Probe with dhclient on the bare interface so a failure costs nothing.
WINNER=""
for n in $LIVE; do
    say "trying DHCP on $n ..."
    timeout 25 dhclient -1 -v "$n" >>"$LOG" 2>&1
    got=$(ip -4 -o addr show "$n" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    dhclient -r "$n" >/dev/null 2>&1
    ip addr flush dev "$n" 2>/dev/null
    if [ -n "$got" ]; then
        say "  $n got $got — using it for vmbr0"
        WINNER="$n"; break
    fi
    say "  $n has link but no DHCP answer"
done
if [ -z "$WINNER" ]; then
    net_dead "NO DHCP SERVER ANSWERED" \
             "These ports have a cable, but nothing offered an address:" \
             "$LIVE"
    exit 1
fi

# ── rebind vmbr0 to the winner, as DHCP ─────────────────────────────────────
cp -a "$IFACES" "$IFACES.netfix-bak-$(date -u +%Y%m%dT%H%M%SZ)" 2>/dev/null
python3 - "$IFACES" "$WINNER" <<'PY'
import re, sys
path, nic = sys.argv[1], sys.argv[2]
s = open(path).read()
m = re.search(r'^iface vmbr0 inet \w+\n(?:[ \t]+.*\n|\n)*', s, re.M)
block = ("iface vmbr0 inet dhcp\n"
         f"\tbridge-ports {nic}\n"
         "\tbridge-stp off\n"
         "\tbridge-fd 0\n")
if m:
    s = s[:m.start()] + block + s[m.end():]
else:
    s += "\nauto vmbr0\n" + block
if not re.search(r'^auto vmbr0$', s, re.M):
    s = s.replace("iface vmbr0 inet dhcp", "auto vmbr0\niface vmbr0 inet dhcp", 1)
open(path, "w").write(s)
PY
reload_net
for i in $(seq 1 12); do IP="$(cur_ip)"; [ -n "$IP" ] && break; sleep 5; done

case "${IP:-}" in
    ""|192.168.100.*)
        say "WARNING: vmbr0 still has no usable address after rebinding to $WINNER" ;;
    *)
        rm -f /etc/sigmond-appliance/.network-unreachable 2>/dev/null
        say "vmbr0 is now on $WINNER with $IP"
        # PVE resolves its own node name through /etc/hosts; keep it on the
        # live lease or pvecm/pveproxy misbehave.
        H=$(hostname)
        if grep -qE "^[0-9.]+[[:space:]].*\b$H\b" /etc/hosts 2>/dev/null; then
            sed -i -E "s/^[0-9.]+([[:space:]].*\b$H\b)/$IP\1/" /etc/hosts
        fi ;;
esac
exit 0
NETFIXEOF
chmod +x /usr/local/sbin/sigmond-netfix

cat > /usr/local/sbin/sigmond-setnet <<'SETNETEOF'
#!/bin/bash
# sigmond-setnet <addr>/<cidr> <gateway> [nic] — give this host a STATIC
# address, and prove it works before keeping it.
#
# The installer's own fallback is the cautionary tale: it wrote an address
# nobody could route to and never checked, leaving a machine that looked
# configured and was unreachable.  This does the opposite -- it configures,
# TESTS, and rolls back on failure, so a typo costs nothing.
set -u
usage(){ echo "usage: sigmond-setnet <addr>/<cidr> <gateway> [nic]"; \
         echo "   eg: sigmond-setnet 10.0.0.50/24 10.0.0.1"; exit 2; }
[ $# -ge 2 ] || usage
ADDR="$1"; GW="$2"; NIC="${3:-}"
case "$ADDR" in */*) : ;; *) echo "address must include the prefix, eg 10.0.0.50/24"; exit 2 ;; esac
IFACES=/etc/network/interfaces

if [ -z "$NIC" ]; then
    for d in /sys/class/net/*; do
        n=$(basename "$d")
        case "$n" in lo|vmbr*|tap*|fwbr*|fwln*|fwpr*|veth*|bond*|dummy*|wg*|tun*) continue ;; esac
        [ -e "$d/device" ] || continue
        ip link set "$n" up 2>/dev/null
        [ "$(cat "$d/carrier" 2>/dev/null)" = "1" ] && { NIC="$n"; break; }
    done
    [ -n "$NIC" ] || { echo "no NIC has a link signal — plug in a cable first"; exit 1; }
    echo "using $NIC (it has a link signal)"
fi

BAK="$IFACES.setnet-bak-$(date -u +%Y%m%dT%H%M%SZ)"
cp -a "$IFACES" "$BAK"
python3 - "$IFACES" "$NIC" "$ADDR" "$GW" <<'PY2'
import re, sys
path, nic, addr, gw = sys.argv[1:5]
s = open(path).read()
block = (f"iface vmbr0 inet static\n\taddress {addr}\n\tgateway {gw}\n"
         f"\tbridge-ports {nic}\n\tbridge-stp off\n\tbridge-fd 0\n")
m = re.search(r'^iface vmbr0 inet \w+\n(?:[ \t]+.*\n|\n)*', s, re.M)
s = (s[:m.start()] + block + s[m.end():]) if m else (s + "\nauto vmbr0\n" + block)
if not re.search(r'^auto vmbr0$', s, re.M):
    s = s.replace("iface vmbr0 inet static", "auto vmbr0\niface vmbr0 inet static", 1)
open(path, "w").write(s)
PY2
if command -v ifreload >/dev/null 2>&1; then ifreload -a 2>/dev/null
else ifdown vmbr0 2>/dev/null; ifup vmbr0 2>/dev/null; fi
sleep 3

# PROVE it: the gateway must answer.  An address without a reachable gateway
# is exactly the state this tool exists to prevent.
if ping -c 3 -W 2 "$GW" >/dev/null 2>&1; then
    echo "OK: $ADDR is up on $NIC and the gateway $GW answers"
    H=$(hostname)
    grep -qE "^[0-9.]+[[:space:]].*\b$H\b" /etc/hosts 2>/dev/null && \
        sed -i -E "s|^[0-9.]+([[:space:]].*\b$H\b)|${ADDR%%/*}\1|" /etc/hosts
    rm -f /etc/sigmond-appliance/.network-unreachable
    echo "reach this host at: ssh root@${ADDR%%/*}   https://${ADDR%%/*}:8006"
    exit 0
fi

echo "FAILED: gateway $GW did not answer from $ADDR on $NIC"
echo "rolling back — the previous config is restored, nothing is stranded"
cp -a "$BAK" "$IFACES"
if command -v ifreload >/dev/null 2>&1; then ifreload -a 2>/dev/null
else ifdown vmbr0 2>/dev/null; ifup vmbr0 2>/dev/null; fi
echo "check the address, prefix, gateway and cable, then try again"
exit 1
SETNETEOF
chmod +x /usr/local/sbin/sigmond-setnet

cat > /etc/systemd/system/sigmond-netfix.service <<'NFSVCEOF'
[Unit]
Description=Sigmond: keep vmbr0 on a NIC that can reach the LAN
# Before pve-guests and the importer: everything downstream assumes the host
# has a routable address, and RAC cannot register without one.
Before=pve-guests.service sigmond-import.service
Wants=network.target
After=network.target
[Service]
Type=oneshot
RemainAfterExit=no
ExecStart=/usr/local/sbin/sigmond-netfix
# Never fail the boot over it: a host that will not finish booting is worse
# than one on the wrong address, and this runs again next boot.
SuccessExitStatus=0 1
TimeoutStartSec=5min
[Install]
WantedBy=multi-user.target
NFSVCEOF
systemctl enable sigmond-netfix.service 2>/dev/null

# Run it now, before anything else needs the network.
/usr/local/sbin/sigmond-netfix

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
# reaching GitHub. Never fail firstboot over this file -- every branch below
# just logs one clear line and moves on:
#   - absent: expected on any image built before this shipped.
#   - present but truncated/malformed: gated on BOTH the "components
#     (live):" header AND a row-count floor -- the same two-part check
#     build-golden-vm.sh/build-usb-v3.sh use for manifest-raw.txt, ported
#     in full here, not just the header half. A capture cut off right
#     after the header (partial stick write, media fault, hand-edit)
#     still contains that header and would pass a bare grep -q, installing
#     a manifest that lies about having zero (or a handful of) component
#     pins. manifest_drift() reports an absent manifest honestly ("cannot
#     be assessed"); a header-only file would instead read as every live
#     component having drifted -- a permanent false total-drift alarm
#     baked in at first boot, worse than no signal at all. 10 is the same
#     floor build-usb-v3.sh uses, for the same reason: well under today's
#     ~20-22 component count, comfortably above anything a truncated
#     capture produces.
#   - present and valid but install fails (I/O error, disk pressure): report
#     the failure explicitly, matching the decoder-copy failure path above.
MF=/mnt/sig-media/manifest.txt
if [ ! -f "$MF" ]; then
  say "import: no component pin manifest on this image (built before manifest support) — drift check unavailable"
else
  # grep -c prints 0 and exits 1 on zero matches -- `|| true` is required
  # so a bare assignment from it can't silently abort under set -e (this
  # heredoc runs under set +e today, but the idiom is kept in step with
  # the build-side code it mirrors so it stays correct if that ever changes).
  NCOMP_MF=$(grep -c '^    [A-Za-z]' "$MF" 2>/dev/null || true); NCOMP_MF=${NCOMP_MF:-0}
  if grep -q 'components (live):' "$MF" 2>/dev/null && [ "$NCOMP_MF" -ge 10 ]; then
    if install -m 0644 -o root -g root "$MF" /etc/sigmond-appliance/manifest.txt; then
      say "import: component pin manifest installed (/etc/sigmond-appliance/manifest.txt)"
    else
      say "import: manifest.txt present and valid but install failed — drift check unavailable"
    fi
  else
    say "import: manifest.txt present but truncated/malformed ($NCOMP_MF component line(s)) — treating as absent — drift check unavailable"
  fi
fi
[ -f "$APP/sigmond-operator.sh" ] && install -m 644 "$APP/sigmond-operator.sh" /etc/profile.d/sigmond-operator.sh
# profile.d only reaches LOGIN shells — hook bash.bashrc so interactive
# non-login shells (plain `bash`, some tmux configs) get the helpers too
grep -q sigmond-operator /etc/bash.bashrc 2>/dev/null || echo '[ -f /etc/profile.d/sigmond-operator.sh ] && . /etc/profile.d/sigmond-operator.sh' >> /etc/bash.bashrc
# tmux mouse support for the host's root shell.  The decoder VM already gets
# this from sigmond's install.sh (it seeds ~/.tmux.conf for the operator
# accounts), but nothing did it on the Proxmox side, so scroll and pane
# selection were dead in every host tmux (rob 2026-09-15).  Idempotent, and
# appended rather than written, so a hand-tuned config survives.  Never
# allowed to fail the boot: a scroll-wheel setting is the least important
# thing happening here.
if ! grep -Eq '^[[:space:]]*set(-option)?[[:space:]]+(-g[[:space:]]+)?mouse[[:space:]]' /root/.tmux.conf 2>/dev/null; then
  { echo '# added by sigmond firstboot — tmux mouse support'
    echo 'set -g mouse on'
  } >> /root/.tmux.conf 2>/dev/null \
    && say "host: tmux mouse support enabled for root" \
    || say "host: could not write /root/.tmux.conf (tmux mouse stays off)"
fi
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

# ── the decoder VM lives BEHIND this host, never on the site LAN ───────────
#
# It used to get its own DHCP lease on vmbr0.  That made its address a
# property of a network we do not control, and everything downstream had to
# cope: the port relay had to guess which of its addresses was reachable, the
# console panel advertised one that might not be, and the address changed
# under us at every lease.  Where a site puts the host and its own VM in
# different VLANs it is not merely awkward but fatal -- Scranton's DASI-019
# answered ICMP in 8.9 ms via a hairpin through the NAT gateway while
# refusing TCP 22 from the hypervisor beside it, and every vm-* RAC channel
# was dead (2026-09-19).
#
# So the VM gets ONE link, a host-only /30 with a fixed address, and this
# host routes and NATs for it.  Same on every station, on a flat LAN or a
# VLAN-split campus: 10.99.0.2, always, reachable from here, always.
# rob, 2026-09-20: "this should behave the same way as the [VLAN]
# environment in the penthouse."
MGMT_PM=10.99.0.1
MGMT_VM=10.99.0.2
MGMT_NET=10.99.0.0/30
# The VM resolves through THIS host, so it must use a resolver THIS host can
# reach.  Do not assume a public one: Scranton's PM sits on a VLAN where
# UDP/53 to 1.1.1.1 and 8.8.8.8 is filtered outright and only its own
# gateway answers.  Take whatever actually works here; fall back to the
# default gateway, which is a resolver on most small networks, and only then
# to a public one.
PM_DNS=$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf 2>/dev/null)
case "$PM_DNS" in
  127.*|"") PM_DNS=$(ip route show default 2>/dev/null | awk '{print $3; exit}') ;;
esac
[ -n "$PM_DNS" ] || PM_DNS=1.1.1.1

if ! grep -q "iface vmbr1" /etc/network/interfaces 2>/dev/null; then
  cat >> /etc/network/interfaces <<NETEOF

# Host-only management bridge for the decoder VM (sigmond-appliance).
# No physical port and no DHCP: the VM's address must not depend on the site
# network.  This host is its only route out -- see the post-up rules.
auto vmbr1
iface vmbr1 inet static
    address ${MGMT_PM}/30
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up sysctl -q -w net.ipv4.ip_forward=1
    post-up iptables -t nat -C POSTROUTING -s ${MGMT_NET} -o vmbr0 -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s ${MGMT_NET} -o vmbr0 -j MASQUERADE
    post-up iptables -t nat -C PREROUTING -p tcp --dport 8000 -j DNAT --to-destination ${MGMT_VM}:8000 2>/dev/null || iptables -t nat -A PREROUTING -p tcp --dport 8000 -j DNAT --to-destination ${MGMT_VM}:8000
    post-up iptables -t nat -C PREROUTING -p tcp --dport 8081 -j DNAT --to-destination ${MGMT_VM}:8081 2>/dev/null || iptables -t nat -A PREROUTING -p tcp --dport 8081 -j DNAT --to-destination ${MGMT_VM}:8081
    post-up iptables -t nat -C PREROUTING -p tcp --dport 8082 -j DNAT --to-destination ${MGMT_VM}:8082 2>/dev/null || iptables -t nat -A PREROUTING -p tcp --dport 8082 -j DNAT --to-destination ${MGMT_VM}:8082
    post-up iptables -t nat -C PREROUTING -p tcp --dport 2222 -j DNAT --to-destination ${MGMT_VM}:22 2>/dev/null || iptables -t nat -A PREROUTING -p tcp --dport 2222 -j DNAT --to-destination ${MGMT_VM}:22
NETEOF
  say "import: host-only bridge vmbr1 (${MGMT_PM}/30) added to /etc/network/interfaces"
fi
# Bring it up now -- the VM is about to be created on it.
ifup vmbr1 >>"$LOG" 2>&1 || ifreload -a >>"$LOG" 2>&1 || true
sysctl -q -w net.ipv4.ip_forward=1
printf 'net.ipv4.ip_forward = 1\n' > /etc/sysctl.d/99-sigmond-vm-router.conf
iptables -t nat -C POSTROUTING -s "$MGMT_NET" -o vmbr0 -j MASQUERADE 2>/dev/null \
  || iptables -t nat -A POSTROUTING -s "$MGMT_NET" -o vmbr0 -j MASQUERADE
# The VM's operator-facing services must not vanish from the LAN just
# because it moved behind us.  Reach them at THIS host's address -- the same
# one already used for ssh and the Proxmox UI, so one address per station
# instead of two.  Measured on a running station rather than assumed: the
# decoder VM binds externally on 22, 8000 (station-web), 8081 (ka9q-web) and
# 8082 (gmag-webui).  ssh is forwarded on 2222 because this host's own sshd
# owns 22.
for _pf in 8000:8000 8081:8081 8082:8082 2222:22; do
  _hp=${_pf%%:*}; _gp=${_pf##*:}
  iptables -t nat -C PREROUTING -p tcp --dport "$_hp" -j DNAT --to-destination "${MGMT_VM}:${_gp}" 2>/dev/null \
    || iptables -t nat -A PREROUTING -p tcp --dport "$_hp" -j DNAT --to-destination "${MGMT_VM}:${_gp}"
done
if ip -4 addr show vmbr1 2>/dev/null | grep -q "$MGMT_PM"; then
  say "import: vmbr1 up — VM will be at ${MGMT_VM}, NATed out vmbr0, :8081 forwarded here"
else
  say "import: WARNING — vmbr1 did not come up; the VM may be unreachable from this host"
fi

qm create "$VMID" --name "sigmond-decoder-${VTAG}" --machine q35 --memory "$VMMEM" $CORES_ARGS \
  --cpu host --net0 virtio,bridge=vmbr1 --ostype l26 --scsihw virtio-scsi-single \
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

# Keep the decoder VM exactly as it was distributed, before it has ever run.
# Taken HERE -- after import and resize, before the first `qm start` -- so it
# captures the image's own state with no first-boot machine-id, no wizard
# identity, no bring-up, nothing site-specific.  An operator who has tangled a
# station's configuration can get back to a KNOWN state without another USB
# install and another trip to the site (rob 2026-09-18).
#
#     qm rollback 100 pristine
#
# Cost is a snapshot on the decoder disk: near zero at first (copy-on-write)
# and growing only as the live VM diverges from it.  Never fail the install
# over it -- a storage backend that cannot snapshot is a smaller problem than
# an install that stops.
if qm snapshot "$VMID" pristine \
     --description "decoder VM as distributed in sigmond-appliance @@VERSION@@, before first boot. Restore with: qm rollback $VMID pristine" >>"$LOG" 2>&1; then
  say "import: 'pristine' snapshot taken — revert any time with: qm rollback $VMID pristine"
else
  say "import: WARNING — could not take the 'pristine' snapshot (storage may not support it); continuing"
fi

# host RAC (inert until /etc/sigmond/frpc-host.toml is filled by the wizard)
[ -x "$APP/sigmond-rac/install-host.sh" ] && bash "$APP/sigmond-rac/install-host.sh" >>"$LOG" 2>&1 \
  && say "import: host RAC installed (inert until configured)"

if qm start "$VMID"; then
  # ── give the guest its fixed address ────────────────────────────────────
  #
  # There is no DHCP server on vmbr1 by design, so the VM boots with no IPv4
  # and we cannot reach it over the network to fix that.  The qemu guest
  # agent does not need one: it speaks over virtio-serial.  That is the whole
  # reason this is safe to do -- a mistake in the config below locks nobody
  # out, because the channel that delivers it is not the network it
  # configures.
  #
  # Sorts before the template's 99-dhcp-*.network, so it wins the match.  The
  # VM has exactly one NIC now, so `en*` is unambiguous.
  _mgmt_conf=$(printf '%s\n' \
    '# The decoder VM has ONE link: a host-only /30 to the Proxmox host,' \
    '# which routes and NATs for it.  Written by the appliance importer.' \
    '# Do not add a site-LAN NIC here -- the address must not depend on a' \
    '# network we do not control (see firstboot-v3.sh).' \
    '[Match]' \
    'Name=en*' \
    '' \
    '[Network]' \
    "Address=${MGMT_VM}/30" \
    "Gateway=${MGMT_PM}" \
    "DNS=${PM_DNS}" | base64 -w0)

  say "import: waiting for the decoder VM's guest agent to give it its address…"
  _agent_ok=0
  for _i in $(seq 1 60); do
    qm agent "$VMID" ping >/dev/null 2>&1 && { _agent_ok=1; break; }
    [ $((_i % 12)) -eq 0 ] && say "import:   … still waiting for the guest agent ($((_i / 12)) min)"
    sleep 5
  done
  if [ "$_agent_ok" = 1 ]; then
    qm guest exec "$VMID" --timeout 60 -- /bin/bash -c \
      "printf %s '$_mgmt_conf' | base64 -d > /etc/systemd/network/10-sigmond-mgmt.network
       chmod 644 /etc/systemd/network/10-sigmond-mgmt.network
       networkctl reload 2>/dev/null; sleep 2; networkctl reconfigure en0 ens18 eth0 2>/dev/null
       systemctl restart systemd-networkd 2>/dev/null; true" >>"$LOG" 2>&1
    # Verify from HERE, which is the only opinion that matters: the host must
    # be able to reach the VM's address.  Saying "configured" without
    # checking is how the Scranton channels looked healthy while being dead.
    #
    # ⚠ ICMP, not TCP 22.  The first version of this checked port 22 and
    # failed the whole nested test on a station whose networking was
    # perfect: at IMPORT time the wizard has not run yet, so the decoder VM
    # has no ssh policy and nothing is listening.  Testing a service that
    # does not exist yet says nothing about the link.  The ssh check belongs
    # after the wizard, and the test asserts it there.
    _reach=0
    for _i in $(seq 1 24); do
      if ping -c1 -W2 "$MGMT_VM" >/dev/null 2>&1; then _reach=1; break; fi
      sleep 5
    done
    if [ "$_reach" = 1 ]; then
      say "import: decoder VM reachable at ${MGMT_VM} from this host ✓"
    else
      say "import: WARNING — no reply from ${MGMT_VM}; the VM is on vmbr1 but the link is not working"
      say "import:   diagnose: qm guest exec $VMID -- ip -4 -br addr;  ip -4 -br addr show vmbr1"
      qm guest exec "$VMID" --timeout 30 -- /bin/bash -c "ip -4 -br addr; ip route; ss -ltn" >>"$LOG" 2>&1
    fi
  else
    say "import: WARNING — guest agent never answered; VM has no management address yet"
    say "import:   fix by hand: qm guest exec $VMID -- ip addr add ${MGMT_VM}/30 dev ens18"
  fi

  say "─────────────────────────────────────────────────────────"
  say " ✓ Decoder VM $VMID (sigmond-decoder-${VTAG}) is running."
  say "   A 'pristine' snapshot of this VM was taken before it booted:"
  say "     qm rollback $VMID pristine   — back to the as-shipped VM, any time."
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
# Mark done AND retire our own trigger.  Left enabled, the .path re-fires on
# the still-present .configured every boot, the service is Condition-skipped,
# and the path unit fails with trigger-limit-hit (belt to the Condition on the
# .path unit itself, which only helps once systemd re-reads it at next boot).
finalized(){ touch /etc/sigmond-appliance/.finalized
             systemctl disable sigmond-finalize.path 2>/dev/null; }

if [ ! -f /etc/sigmond-appliance/layout.env ]; then
  say "finalize: no CPU layout saved — leaving VM untuned (unpinned, no passthrough)."
  say "finalize: tune later from a sigmond checkout: scripts/proxmox/bootstrap.sh"
  finalized
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
  finalized
  exit 0
fi
finalized

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
# Once finalized this path must not come up again: .configured is still there,
# so it would re-fire against a service whose own Condition now fails, hit
# systemd's trigger limit within a second, and sit `failed` for the life of
# the host (AI6VN-PM v3.37, 2026-09-05).
ConditionPathExists=!/etc/sigmond-appliance/.finalized
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
HOSTIP=$(ip -4 -o addr show vmbr0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
# ⚠ NOT `hostname -I | awk '{print $1}'`: that lists EVERY address, and since
# the decoder VM moved behind a host-only bridge this host also holds
# 10.99.0.1.  Ordering is not guaranteed, so the panel/summary could announce
# the management /30 -- an address reachable only from the VM -- as the
# station's address (rob, 2026-09-21: "it was using 10.99.0 ... I think you
# need to exclude 10.99").  Ask vmbr0 directly, and fall back excluding it.
[ -n "$HOSTIP" ] || HOSTIP=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -vE '^(10\.99\.0\.|127\.)' | head -1)
VMIP=""
for i in 1 2 3 4 5 6; do
  # Print the VM address THIS HOST can actually reach.  Taking whichever
  # address the guest agent happened to list first assumes they are all
  # equally reachable from here, and that is false wherever the site puts the
  # PM and its own VM in different VLANs: the panel then advertises a campus
  # address nobody standing at this console can use, and the operator has no
  # way to tell it apart from a working one (DASI-019 Scranton, 2026-09-19).
  # Addresses on a network this host is directly attached to sort first;
  # where everything is equally reachable the choice is unchanged.
  VMIP=$(qm agent "$VMID" network-get-interfaces 2>/dev/null | python3 -c '
import json, re, socket, struct, subprocess, sys

def local_nets():
    try:
        out = subprocess.run(["ip", "-4", "-o", "addr", "show"],
                             capture_output=True, text=True, timeout=10).stdout
    except Exception:
        return []
    nets = []
    for m in re.finditer(r"inet (\d+\.\d+\.\d+\.\d+)/(\d+)", out):
        addr, plen = m.group(1), int(m.group(2))
        if addr.startswith("127."):
            continue
        a = struct.unpack("!I", socket.inet_aton(addr))[0]
        mask = (0xFFFFFFFF << (32 - plen)) & 0xFFFFFFFF
        nets.append((a & mask, mask))
    return nets

cands = []
try:
    for i in json.load(sys.stdin):
        if i.get("name", "").startswith(("en", "eth")):
            for a in i.get("ip-addresses", []):
                if a["ip-address-type"] == "ipv4" and not a["ip-address"].startswith("127"):
                    cands.append(a["ip-address"])
except Exception:
    pass
if cands:
    nets = local_nets()
    def is_local(ip):
        v = struct.unpack("!I", socket.inet_aton(ip))[0]
        return any((v & m) == n for n, m in nets)
    cands.sort(key=lambda ip: 0 if is_local(ip) else 1)
    print(cands[0])' 2>/dev/null)
  [ -n "$VMIP" ] && break
  sleep 10
done
# Agent-free fallback: a wedged qemu-guest-agent (seen after any guest-exec
# that outlives its --timeout, AI6VN 2026-09-06/09) must not blank the
# panel.  The host's bridge already knows the VM's address from ARP: look up
# the VM's NIC MAC in the neighbour table.
if [ -z "$VMIP" ]; then
  _mac=$(qm config "$VMID" 2>/dev/null | grep -oE "(virtio|e1000|vmxnet3|rtl8139)=[0-9A-Fa-f:]{17}" | head -1 | cut -d= -f2 | tr A-Z a-z)
  [ -n "$_mac" ] && VMIP=$(ip -4 neigh show 2>/dev/null | awk -v m="$_mac" 'tolower($5)==m && $1 !~ /^169\.254\./ {print $1; exit}')
  [ -n "$VMIP" ] && VMIP="$VMIP (via ARP — guest agent not answering)"
fi
# ── is the station still BUILDING? ─────────────────────────────────────────
# ⛔ "still installing" and "broken" looked identical from outside, and that
# cost real time three times on 2026-09-20/21: the panel printed a ka9q-web
# URL that could not answer yet, the dashboard showed the channel down, and
# the only place the truth existed was firstrun-bringup.log inside the VM --
# reachable solely by someone with shell on this host AND a responsive guest
# agent.  rob concluded twice that a healthy station was broken; so did I.
#
# So say it here, where the operator is already looking.  A short agent
# timeout on purpose: during bring-up the VM is saturated building venvs and
# the agent often will not answer, and "VM busy" is itself the answer.
BRINGUP=""
_bu=$(timeout 12 qm guest exec "$VMID" --timeout 8 -- /bin/bash -c \
        'systemctl is-active sigmond-firstrun-bringup 2>/dev/null; \
         sed "s/\x1b\[[0-9;]*m//g" /var/log/sigmond/firstrun-bringup.log 2>/dev/null \
           | grep -E "^───|» " | tail -1 | cut -c1-58' 2>/dev/null \
      | python3 -c 'import json,sys
try: print((json.load(sys.stdin).get("out-data") or "").strip())
except Exception: pass' 2>/dev/null)
case "$_bu" in
    activating*)
        _stage=$(printf '%s' "$_bu" | tail -1)
        BRINGUP=" >> STATION IS STILL BUILDING -- this is normal, not a fault.
 >>   First-run bring-up is RUNNING (clones, builds ~25 components; tens of
 >>   minutes on a cold box).  ka9q-web and station-web start near the END,
 >>   so their links below will not answer until it finishes.
 >>   last step: ${_stage:-(starting)}
 >>   watch it:  qm guest exec $VMID -- tail -5 /var/log/sigmond/firstrun-bringup.log
"
        ;;
    failed*|inactive*)
        # inactive is the normal finished state too, so only shout when the
        # marker says it ran and the services it should have started are not up.
        if ! qm guest exec "$VMID" --timeout 8 -- /bin/bash -c \
               'systemctl is-active ka9q-web >/dev/null' >/dev/null 2>&1; then
            BRINGUP=" !! BRING-UP FINISHED BUT ka9q-web IS NOT RUNNING
 !!   check:  qm guest exec $VMID -- tail -30 /var/log/sigmond/firstrun-bringup.log
 !!   re-run: qm guest exec $VMID -- smd bringup dasi2
"
        fi
        ;;
    "")
        BRINGUP=" .. decoder VM guest agent did not answer (it is often saturated
 ..   while the station builds) -- bring-up state unknown from here.
"
        ;;
esac

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
# Is the VM behind this host on the management /30, or on the site LAN?
# The panel must not send an operator to an address that only works from
# here: ka9q-web on a NATed VM is reachable at THIS host's address (the
# importer DNATs :8081), and saying otherwise is how someone concludes the
# station is broken when it is fine.
VMBEHIND=""
KA9QURL="http://${VMIP:-<starting>}:8081"
case "${VMIP:-}" in
  10.99.0.*)
    VMBEHIND="   (private link to this host — not on your LAN)"
    KA9QURL="http://${HOSTIP:-<no-ip-yet>}:8081        <- via this host
   station-web  http://${HOSTIP:-<no-ip-yet>}:8000
   VM ssh     ssh -p 2222 sigmond@${HOSTIP:-<no-ip-yet>}   (or: sigmond-vm)"
    ;;
esac

PWLINE="the password you set at install"
_h=$(awk -F: '$1=="root"{print $2}' /etc/shadow 2>/dev/null)
case "$_h" in
  \$*) [ "$(perl -e 'print crypt($ARGV[1], $ARGV[0])' "$_h" hamsci-sigmond 2>/dev/null)" = "$_h" ] \
          && PWLINE="hamsci-sigmond   <-- image default, CHANGE IT" ;;
esac

# Remote access (RAC).  The panel used to show LAN addresses only, so an
# operator standing at the console could not tell whether the station had
# reached its gateway, which number it got, or WHICH gateway it registered
# with — and getting that wrong is exactly how installs ended up on the
# wrong VPN (rob 2026-09-15).  Everything needed is already on disk: the
# wizard records number/tier/registrar under /etc/sigmond-appliance and the
# live tunnel in /etc/sigmond/frpc-host.toml (root-only, and this runs as
# root).  Ports are READ from that file, never recomputed from the
# base+RAC scheme, so the panel cannot drift from the real tunnel.
RACBLOCK=""
RACN=$(cat /etc/sigmond-appliance/rac-number 2>/dev/null)
if [ -n "$RACN" ] && [ -r /etc/sigmond/frpc-host.toml ]; then
    RSRV=$(awk -F'"' '/^serverAddr/{print $2; exit}' /etc/sigmond/frpc-host.toml)
    RUSR=$(awk -F'"' '/^user *=/{print $2; exit}' /etc/sigmond/frpc-host.toml)
    RTIER=$(cat /etc/sigmond-appliance/rac-tier 2>/dev/null)
    RREG=$(cat /etc/sigmond-appliance/rac-registrar 2>/dev/null)
    # name= / remotePort= pairs, in file order
    eval "$(awk -F'"' '/^name *=/{n=$2}
                       /^remotePort *=/{split($0,a,"="); gsub(/[ \t]/,"",a[2]);
                                        if (n ~ /-vm-ssh$/)   print "P_VMSSH=" a[2];
                                        else if (n ~ /-vm-web$/)  print "P_VMWEB=" a[2];
                                        else if (n ~ /-host-ssh$/) print "P_HSSH=" a[2];
                                        else if (n ~ /-host-ui$/)  print "P_HUI=" a[2]}' \
              /etc/sigmond/frpc-host.toml)"
    # Live state, not a claim: frpc publishes per-proxy status on its local
    # admin API, and that is the only thing that proves the gateway accepted
    # the channels.  Fall back to the unit state if the API is not up.
    RSTAT="OFFLINE — check: journalctl -u sigmond-rac-host -n 50"
    if systemctl is-active --quiet sigmond-rac-host 2>/dev/null; then
        _run=$(curl -s --max-time 3 http://127.0.0.1:7500/api/status 2>/dev/null \
                 | grep -o '"status":"running"' | wc -l | tr -d ' ')
        # Count the channels this station ACTUALLY declares, never a literal.
        # It was hardcoded to 4 and the station now ships 6, so a fully
        # healthy host advertised "6/4 channels up" (rob, 2026-09-21).
        _decl=$(grep -c '^name *=' /etc/sigmond/frpc-host.toml 2>/dev/null)
        [ "${_decl:-0}" -gt 0 ] || _decl=$_run
        if [ "${_run:-0}" -gt 0 ]; then RSTAT="online — $_run/$_decl channels up"
        else RSTAT="service running, no channel accepted yet"; fi
    fi
    RACBLOCK=" Remote access  RAC $RACN on ${RSRV:-<no server>}${RTIER:+  (tier: $RTIER)}
   status     $RSTAT
   host ssh   ssh -p ${P_HSSH:-?} ${RUSR:-<user>}@${RSRV:-<server>}
   host UI    https://${RSRV:-<server>}:${P_HUI:-?}
   VM ssh     ssh -p ${P_VMSSH:-?} ${RUSR:-<user>}@${RSRV:-<server>}
   VM web     http://${RSRV:-<server>}:${P_VMWEB:-?}${RREG:+
   registrar  $RREG}
"
elif [ -n "$RACN" ]; then
    RACBLOCK=" Remote access  RAC $RACN assigned, but /etc/sigmond/frpc-host.toml is missing
   ==> the tunnel is NOT configured; rerun: sigmond-setup --reconfigure
"
else
    RACBLOCK=" Remote access  not configured — this station is LAN-only
   ==> to enable off-site access: sigmond-setup --reconfigure
"
fi

# A host with no usable address must not render a panel that looks normal.
# The addresses below would all be the installer's unreachable fallback, and
# an operator reading them has no way to tell (rob, 2026-09-21).
NETWARN=""
if [ -f /etc/sigmond-appliance/.network-unreachable ]; then
    NETWARN=" !! THIS HOST HAS NO WORKING NETWORK ADDRESS
 !!   $(head -1 /etc/sigmond-appliance/.network-unreachable 2>/dev/null)
 !!   The addresses below are NOT reachable. Fix with either:
 !!     - plug the cable into a port with a link light, then reboot
 !!     - sigmond-setnet <addr>/<cidr> <gateway>    (verifies before keeping)
"
fi

# ── network health, from THIS host's own view ──────────────────────────────
# The panel refreshes every 5 minutes but said nothing about the physical
# link, so moving a cable to the wrong socket produced no visible change at
# all -- the operator sees a normal-looking panel while the machine is on its
# way to being unreachable (rob, 2026-09-21: "I just moved the cable over to
# the NIC that isn't working and there was no indication of that on the
# panel").  Everything here is local and cheap: no guest agent, no network
# round trip except one gateway ping.
NICLINES=""
_vmbr_port=$(awk '/^iface vmbr0/{f=1} f&&/bridge-ports/{print $2; exit}' /etc/network/interfaces 2>/dev/null)
for _d in /sys/class/net/*; do
    _n=$(basename "$_d")
    case "$_n" in lo|vmbr*|tap*|fwbr*|fwln*|fwpr*|veth*|bond*|dummy*|wg*|tun*) continue ;; esac
    [ -e "$_d/device" ] || continue
    if [ "$(cat "$_d/carrier" 2>/dev/null)" = "1" ]; then _c="LINK UP  "; else _c="NO LINK  "; fi
    _mark=""
    [ "$_n" = "$_vmbr_port" ] && _mark="  <- vmbr0 uses this one"
    NICLINES="$NICLINES   $(printf '%-9s %s' "$_n" "$_c")$_mark
"
done
# A gateway that does not answer is the difference between "configured" and
# "reachable", and only the second one matters to an operator.
_gw=$(ip route show default 2>/dev/null | awk '{print $3; exit}')
if [ -n "$_gw" ]; then
    if ping -c1 -W2 "$_gw" >/dev/null 2>&1; then _gwl="gateway $_gw responds"
    else _gwl="gateway $_gw DOES NOT RESPOND  <- this host cannot reach the LAN"; fi
else
    _gwl="NO DEFAULT ROUTE  <- this host cannot reach anything"
fi
# Warn when the cable is in a port vmbr0 is not using -- the exact trap.
_stray=""
for _d in /sys/class/net/*; do
    _n=$(basename "$_d"); [ -e "$_d/device" ] || continue
    case "$_n" in lo|vmbr*|tap*|fwbr*|fwln*|fwpr*|veth*|bond*|dummy*|wg*|tun*) continue ;; esac
    if [ "$(cat "$_d/carrier" 2>/dev/null)" = "1" ] && [ "$_n" != "$_vmbr_port" ]; then
        _stray=" !! $_n has a cable but vmbr0 uses ${_vmbr_port:-?}. If the network
 !!   is not working, move the cable, or reboot: the host re-binds vmbr0 to
 !!   whichever port answers DHCP.
"
    fi
done

PANEL=$(cat <<PEOF
════ Sigmond appliance $VERSION ${CONF:+— station ${CONF%% *}} ════
 THIS CONSOLE IS READ-ONLY — the keyboard does not work here.  Its USB
 controller was passed through to the decoder VM, so nothing you type on
 this machine registers.  Reach the station from another computer using
 the addresses below.

${NETWARN}${BRINGUP}${RXWARN}
 Network
${NICLINES}   ${_gwl}
${_stray}
 Proxmox host ${HOSTIP:-<no-ip-yet>}
   ssh        ssh root@${HOSTIP:-<no-ip-yet>}
   web UI     https://${HOSTIP:-<no-ip-yet>}:8006
   login      root / $PWLINE

 Decoder VM   ${VMIP:-<starting — this panel refreshes every 5 min>}${VMBEHIND}
   ssh        ssh sigmond@${VMIP:-<starting>}      (also: hamsci@)
   ka9q-web   ${KA9QURL}
   login      sigmond / $PWLINE

${RACBLOCK}
 From the host over ssh:  sigmond-vm        (shell in the decoder VM)
                          qm terminal $VMID  (its console)
                          sigmond-setup --reconfigure   (rerun the wizard)
════ end Sigmond panel ════
PEOF
)
for f in /etc/issue /etc/motd; do
    # remove the old panel AND the trailing blank lines: appending '\n\n'
    # while deleting only the block leaked one blank line per refresh —
    # ~1000 lines in /etc/issue after 3 days (AI6VN 2026-09-09).  Two sed
    # passes: the N in the blank-collapse loop must not swallow a panel line.
    sed -i '/^════ Sigmond appliance /,/^════ end Sigmond panel ════/d' "$f" 2>/dev/null
    sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$f" 2>/dev/null
    printf '\n%s\n' "$PANEL" >> "$f"
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

HOSTIP=$(ip -4 -o addr show vmbr0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
# ⚠ NOT `hostname -I | awk '{print $1}'`: that lists EVERY address, and since
# the decoder VM moved behind a host-only bridge this host also holds
# 10.99.0.1.  Ordering is not guaranteed, so the panel/summary could announce
# the management /30 -- an address reachable only from the VM -- as the
# station's address (rob, 2026-09-21: "it was using 10.99.0 ... I think you
# need to exclude 10.99").  Ask vmbr0 directly, and fall back excluding it.
[ -n "$HOSTIP" ] || HOSTIP=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -vE '^(10\.99\.0\.|127\.)' | head -1)
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
