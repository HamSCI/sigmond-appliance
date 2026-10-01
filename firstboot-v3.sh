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
# ── shared address helpers, used by BOTH sigmond-netfix and sigmond-issue ──
# One definition, sourced by both.  They were previously defined inside
# netfix and called from the panel, where they did not exist.
mkdir -p /usr/local/lib
cat > /usr/local/lib/sigmond-net.sh <<'NETLIBEOF'
# Shared by sigmond-netfix and sigmond-issue.  Keep it dependency-free: it is
# sourced very early at boot, before anything else is guaranteed to exist.

# ⛔ Every address probe here used to be `ip -4` ONLY.  On an IPv6-only LAN
# that returns nothing, net_dead() fires, and the operator is told the install
# cannot continue -- on a machine that is perfectly reachable over v6.  A
# station bound for McMurdo (IPv6-only, 2026-09) would have read as bricked.
#
# IPv4 still WINS when both exist: it is what the fleet's reach, frp registry
# and internal 10.99.0.0/30 management link all speak today.  v6 is the
# fallback that keeps a v6-only site alive, not a new preference.
#
# Link-local (fe80::) is deliberately excluded: without a scope id it is not
# an address anyone can connect to, and reporting one as "the station's
# address" is worse than reporting none.
cur_ip(){
    local _dev="${1:-vmbr0}" _a
    _a=$(ip -4 -o addr show "$_dev" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    [ -n "$_a" ] && { printf '%s\n' "$_a"; return 0; }
    ip -6 -o addr show "$_dev" scope global 2>/dev/null \
        | grep -v -e temporary -e deprecated \
        | awk '{print $4}' | cut -d/ -f1 | head -1
}

# A v6 literal needs brackets in a URL and in anything that appends :port.
# `https://2001:db8::1:8006` is not a URL; `https://[2001:db8::1]:8006` is.
ipurl(){ case "${1:-}" in *:*) printf '[%s]\n' "$1";; *) printf '%s\n' "${1:-}";; esac; }

# ⛔ "HAS A DEFAULT ROUTE" IS NOT "HAS A GATEWAY THAT WORKS".
# The PVE installer fossilises an unroutable 192.168.100.2/24 on vmbr0 when its
# DHCP finds nothing, and the kernel installs `default via 192.168.100.1 dev
# vmbr0 ... linkdown`.  Anything that takes `ip route show default | awk
# '{print $3}'` therefore gets a gateway that answers nothing -- and on a host
# with BOTH families, the first line may be an IPv6 link-local, which is not an
# address an IPv4-only guest can use at all.
#
# That mistake cost us the CLAT gate on 2026-09-30 (see sigmond-wait-nat64), so
# ask the question once, here, properly: the gateway of an IPv4 default route
# that is not the installer's fallback and whose interface has CARRIER.
# Prints nothing when there is no such gateway -- callers must handle that.
usable_gw4(){
    local _r _d
    while read -r _r; do
        [ -n "$_r" ] || continue
        case "$_r" in
            *linkdown*)           continue ;;
            *"via 192.168.100."*) continue ;;
        esac
        # ⛔ A default route need not HAVE a gateway.  clatd installs
        #     default dev clat scope link
        # -- point-to-point, no `via` at all -- and `awk '{print $3}'` on that
        # yields the word "clat".  The console then pinged "clat" and announced
        # "gateway clat DOES NOT RESPOND <- this host cannot reach the LAN"
        # about a host whose IPv4 was working perfectly through that very
        # route (AI6VN-PM v3.62, 2026-09-30).  No `via`, no gateway to report.
        case "$_r" in *" via "*) ;; *) continue ;; esac
        _d=${_r#*" dev "}; _d=${_d%% *}
        [ -n "$_d" ] || continue
        [ "$(cat "/sys/class/net/$_d/carrier" 2>/dev/null)" = 1 ] || continue
        printf '%s\n' "$_r" | awk '{print $3}'
        return 0
    done <<GWEOF
$(ip -4 route show default 2>/dev/null)
GWEOF
    return 1
}
NETLIBEOF
chmod 0644 /usr/local/lib/sigmond-net.sh

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

# cur_ip() and ipurl() now live in /usr/local/lib/sigmond-net.sh, written
# above, because sigmond-issue needs them too.  They used to be defined HERE
# and called THERE, which is not a thing shell does: every panel refresh on
# v3.52 printed
#     sigmond-issue: line 6:   cur_ip: command not found
#     sigmond-issue: line 313: ipurl: command not found
# and the panel lost the host address and the Proxmox URL -- on exactly the
# console an operator stares at when the network is already misbehaving
# (rob, installing v3.52, 2026-09-23).
. /usr/local/lib/sigmond-net.sh 2>/dev/null || {
    echo "[netfix] FATAL: /usr/local/lib/sigmond-net.sh missing" | tee /dev/console
    exit 1
}

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
"##  3) Or join Wi-Fi — this host has a radio and the tools are already" \
"##     installed, so no network is needed to get onto a network:" \
"##        sigmond-wifi scan" \
"##        echo -n '''your-passphrase''' | sigmond-wifi join YourAP" \
"##     On a DASI station Wi-Fi is often the BETTER link: an Ethernet" \
"##     cable entering the shack is a conducted noise path into the HF" \
"##     receiver. It handles an IPv6-only access point too." \
"##" \
"##  Current state is recorded in" \
"##     /etc/sigmond-appliance/.network-unreachable" \
"########################################################################" \
"" ; do
        echo "$line" >/dev/console 2>/dev/null
        echo "$line" >>"$LOG" 2>/dev/null
    done
}

# ── ⛔ a Wi-Fi NIC must NEVER be a bridge port ──────────────────────────────
# 802.11 station mode will not carry arbitrary source MACs, so a managed-mode
# wlan cannot be bridged (that needs 4addr/WDS, which an ordinary AP will not
# give us).  The bridge therefore never comes up -- and the attempt leaves
# `disable_ipv6=1` on the wlan, which kills IPv6 on it completely: no
# link-local, so no router solicitation, so no address and no route.
#
# The Proxmox installer does exactly this when Wi-Fi is the only link at
# install time: it picks the wlan as the management interface and writes
# `bridge-ports wlp3s0`.  Measured on AI6VN-PM 2026-09-29 (v3.56, installed
# over Wi-Fi): vmbr0 DOWN with zero members, wlp3s0 associated at -39 dBm with
# disable_ipv6=1 and not one IPv6 address.  The station looked connected and
# was unreachable.
#
# Repair it: take the wlan out of the bridge, give it its own stanza, and put
# IPv6 back.  The decoder VM does not need vmbr0 to have a port -- it lives on
# the host-only vmbr1 and is NATed out of whatever uplink exists.
_wl_bridged=""
for _p in $(sed -n 's/^[[:space:]]*bridge-ports[[:space:]]\+//p' "$IFACES" 2>/dev/null); do
    [ "$_p" = none ] && continue
    [ -e "/sys/class/net/$_p/wireless" ] && _wl_bridged="$_p"
done
if [ -n "$_wl_bridged" ]; then
    say "vmbr0 is bridged onto Wi-Fi NIC $_wl_bridged — that cannot work; un-bridging"
    cp -a "$IFACES" "$IFACES.pre-unbridge" 2>/dev/null
    sed -i "s|^\([[:space:]]*\)bridge-ports[[:space:]]\+$_wl_bridged[[:space:]]*$|\1bridge-ports none|" "$IFACES"
    if ! grep -qE "^iface[[:space:]]+$_wl_bridged[[:space:]]+inet6" "$IFACES"; then
        # accept_ra=2 because this host FORWARDS (it routes for the decoder VM)
        # and Linux ignores RAs on a forwarding interface at the default 1.
        printf '\nauto %s\niface %s inet6 auto\n\tpost-up sysctl -qw net.ipv6.conf.%s.disable_ipv6=0 || true\n\tpost-up sysctl -qw net.ipv6.conf.%s.accept_ra=2 || true\n\tpost-up sysctl -qw net.ipv6.conf.%s.accept_ra_defrtr=1 || true\n' \
            "$_wl_bridged" "$_wl_bridged" "$_wl_bridged" "$_wl_bridged" "$_wl_bridged" >> "$IFACES"
    fi
    # Undo the damage the failed enslavement already did, now, without a reboot.
    ip link set "$_wl_bridged" nomaster 2>/dev/null
    sysctl -qw "net.ipv6.conf.$_wl_bridged.disable_ipv6=0" 2>/dev/null
    sysctl -qw "net.ipv6.conf.$_wl_bridged.accept_ra=2" 2>/dev/null
    sysctl -qw "net.ipv6.conf.$_wl_bridged.accept_ra_defrtr=1" 2>/dev/null
    say "  $_wl_bridged is now standalone with IPv6 enabled (backup: $IFACES.pre-unbridge)"
fi

# ── ⛔ A RADIO WITH AN ADDRESS IS NOT A DEAD INSTALL ────────────────────────
# Everything below hunts for a NIC to put vmbr0 on, and it skips Wi-Fi for a
# good reason (a managed-mode wlan cannot be bridged).  But "no NIC I can
# bridge" is not the same question as "is this machine on the network", and
# conflating them condemned a perfectly connected station.
#
# Measured on rob's AI6VN-PM, v3.57, 2026-09-30: the wizard's Wi-Fi step joined
# an AP and took an IPv6 address, the finalizer power-cycled as designed, and
# the next boot printed NO NETWORK CABLE DETECTED -- naming the two dark
# Ethernet ports and never once looking at the radio that was the machine's
# only uplink.  The operator is then sent to find a cable for a host that
# needs none, which is the whole point of the Wi-Fi support.
#
# So: ask the radio first, and if it is merely unaddressed, ADDRESS IT.  At
# this point in a boot sigmond-wifi-up.service has usually run already; this is
# the backstop for when it has not (a slow association, or a station whose
# profile predates that unit).
wifi_uplink(){
    local d n a
    for d in /sys/class/net/*/wireless; do
        [ -e "$d" ] || continue
        n=$(basename "$(dirname "$d")")
        a=$(cur_ip "$n")
        [ -n "$a" ] && { printf '%s %s\n' "$n" "$a"; return 0; }
    done
    return 1
}
WIFI_UP="$(wifi_uplink || true)"
if [ -z "$WIFI_UP" ] && [ -s /var/lib/sigmond/wifi-ssid ] \
   && [ -x /usr/local/sbin/sigmond-wifi ]; then
    say "a saved Wi-Fi profile exists but the radio has no address — bringing it up"
    # ⛔ BOUNDED.  This is a backstop for when sigmond-wifi-up.service has not
    # run; at boot it usually HAS, and is still working.  Unbounded, this call
    # inherits everything that run is waiting on and spends netfix's whole
    # TimeoutStartSec -- which is what happened on AI6VN-PM v3.61 2026-09-30:
    # netfix was killed at 16:38:49 having reached no conclusion at all, so it
    # never cleared the stale dead-install verdict, and the console kept showing
    # NO NETWORK CABLE DETECTED on a working station.
    # `sigmond-wifi up` takes a lock, so the usual outcome here is that it sees
    # the unit's run and returns quickly.
    timeout "${SIGMOND_WIFI_BACKSTOP_WAIT:-90}" /usr/local/sbin/sigmond-wifi up >>"$LOG" 2>&1
    WIFI_UP="$(wifi_uplink || true)"
fi
[ -n "$WIFI_UP" ] && say "Wi-Fi uplink is live: $WIFI_UP"

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
# ⛔ TWO DIFFERENT QUESTIONS, AND CONFLATING THEM DECLARES A HEALTHY MACHINE
# DEAD.  "Which NICs may I run dhclient on?" excludes bridge members, because
# probing vmbr0's own port and then flushing it tears down the bridge we are
# repairing.  "Which NICs have a cable in them?" excludes NOTHING -- carrier
# is a property of the socket, and an enslaved port is the MOST likely place
# to find a live cable, since that is the one the installer chose.
#
# Until now both used one list.  So on the ordinary case -- the live cable in
# the NIC vmbr0 already owns, the second socket empty -- every candidate was
# skipped, LIVE came back empty, and netfix printed "NO NETWORK CABLE
# DETECTED" at the console of a machine whose link light was on.  rob hit
# exactly that installing v3.52 on 2026-09-23: "there is a link light on that
# port".  The operator is then told to check a cable that is already fine,
# while the real fault (no DHCP answer, or a lease that never reached vmbr0)
# goes unnamed.
ALLPHYS=""; PROBE=""
for d in /sys/class/net/*; do
    n=$(basename "$d")
    case "$n" in lo|vmbr*|tap*|fwbr*|fwln*|fwpr*|veth*|bond*|dummy*|wg*|tun*) continue ;; esac
    [ -e "$d/device" ] || continue          # physical only
    # A Wi-Fi NIC is not a bridge-port candidate: see the un-bridge block above.
    # Without this, netfix would "fix" a dead vmbr0 by binding it to the wlan
    # and reproduce the exact fault it just repaired.
    [ -e "$d/wireless" ] && { say "  $n is Wi-Fi — never a bridge port"; continue; }
    ip link set "$n" up 2>/dev/null         # a down NIC reports no carrier
    ALLPHYS="$ALLPHYS $n"
    if [ -e "$d/master" ]; then
        say "  $n is enslaved to $(basename "$(readlink -f "$d/master")" 2>/dev/null) — link still counts, but not probed"
    else
        PROBE="$PROBE $n"
    fi
done
[ -n "$ALLPHYS" ] || { say "no physical NICs found — cannot fix networking"; exit 1; }

# Autonegotiation is not instant.  A fixed 4 s sleep was ROUTINELY too short
# on gigabit copper (and far too short behind a switch running STP), so a
# perfectly good port could read carrier=0 and be written off.  Poll instead:
# stop the moment anything comes up, and only spend the full budget when
# nothing does.
CARRIER_WAIT="${SIGMOND_CARRIER_WAIT:-30}"
_waited=0
while [ "$_waited" -lt "$CARRIER_WAIT" ]; do
    for n in $ALLPHYS; do
        [ "$(cat "/sys/class/net/$n/carrier" 2>/dev/null)" = "1" ] && break 2
    done
    sleep 2; _waited=$(( _waited + 2 ))
    [ $(( _waited % 10 )) -eq 0 ] && say "  waiting for link ... ${_waited}s of ${CARRIER_WAIT}s"
done
[ "$_waited" -gt 0 ] && say "  link settled after ${_waited}s"

LIVE=""; DEAD=""; LIVE_ENSLAVED=""
for n in $ALLPHYS; do
    if [ "$(cat "/sys/class/net/$n/carrier" 2>/dev/null)" = "1" ]; then
        case " $PROBE " in
            *" $n "*) LIVE="$LIVE $n" ;;
            *)        LIVE_ENSLAVED="$LIVE_ENSLAVED $n" ;;
        esac
    else
        DEAD="$DEAD $n"
    fi
done
say "link up:${LIVE:- none}${LIVE_ENSLAVED:+ ; link up but enslaved:$LIVE_ENSLAVED}${DEAD:+ ; no link:$DEAD}"

if [ -z "$LIVE" ] && [ -z "$LIVE_ENSLAVED" ]; then
    # No cable anywhere -- but the radio may BE the uplink, by design.
    if [ -n "$WIFI_UP" ]; then
        say "no Ethernet link on$ALLPHYS — but this station is on Wi-Fi ($WIFI_UP)"
        say "  that is a supported configuration: a DASI station runs cable-free"
        say "  on purpose (an Ethernet run into the shack is a conducted noise"
        say "  path into the HF receiver). vmbr0 stays portless; the decoder VM"
        say "  reaches the site through this host, not through a bridge."
        # The installer's fallback address must not survive here.  Left in
        # place it answers "yes" to every later "do we have IPv4?" test --
        # including the one sigmond-v6-gateway keys off -- while routing
        # nowhere.  Same reasoning as the v6-only branch below.
        if ip -4 -o addr show vmbr0 2>/dev/null | grep -q "$FALLBACK_NET"; then
            ip addr del 192.168.100.2/24 dev vmbr0 2>/dev/null \
                && say "  removed the unroutable installer fallback 192.168.100.2 from vmbr0"
            sed -i -e '/^iface vmbr0 inet static/,/^[[:space:]]*$/{/^[[:space:]]*address[[:space:]]/d;/^[[:space:]]*gateway[[:space:]]/d;}' \
                "$IFACES" 2>/dev/null
        fi
        # ⛔ And masquerade the decoder VM out of the RADIO.  The vmbr1 stanza
        # written by the importer masquerades `-o vmbr0` and `-o clat` only --
        # both correct for the sites they were written for, and neither one is
        # the uplink here.  Without this rule the VM is routed to a host that
        # drops it: the station looks fine and decodes nothing.
        # 10.99.0.0/30 is the host-only management net (MGMT_NET in the
        # importer); netfix is a standalone script and cannot see that variable.
        _wdev="${WIFI_UP%% *}"
        if ! iptables -t nat -C POSTROUTING -s 10.99.0.0/30 -o "$_wdev" -j MASQUERADE 2>/dev/null; then
            iptables -t nat -A POSTROUTING -s 10.99.0.0/30 -o "$_wdev" -j MASQUERADE 2>/dev/null \
                && say "  decoder VM is now NATed out $_wdev"
        fi
        rm -f /etc/sigmond-appliance/.network-unreachable 2>/dev/null
        exit 0
    fi
    net_dead "NO NETWORK CABLE DETECTED" \
             "None of this machine's network ports has a link signal:" \
             "$ALLPHYS"
    exit 1
fi
if [ -z "$LIVE" ]; then
    # Cable IS in, in the port the bridge already owns.  Nothing to re-bind:
    # the fault is upstream of us (no DHCP answer, or a v6-only LAN), and
    # saying "no cable" here would send the operator to the one thing that is
    # demonstrably fine.
    say "the only port with a link ($LIVE_ENSLAVED) is already vmbr0's — not a cabling fault"
    say "retrying DHCP on vmbr0 itself before giving up"
    timeout 30 dhclient -1 -v vmbr0 >>"$LOG" 2>&1
    # ⛔ "has an address" is NOT "is fine".  cur_ip() happily returns the PVE
    # installer's fossilised 192.168.100.2, which this function has ALREADY
    # condemned as unroutable a few lines above.  Accepting it here declared
    # success, exited, and skipped the IPv6 probe entirely -- so on a v6-only
    # LAN the station sat on an unroutable IPv4 address forever while a perfectly
    # good RA went unanswered.  Measured in the nested v6-only test,
    # 2026-09-28: "vmbr0 now has 192.168.100.2 — nothing further to do".
    _got="$(cur_ip vmbr0)"
    case "$_got" in
        ""|192.168.100.*) _got="" ;;
    esac
    if [ -n "$_got" ]; then
        say "vmbr0 now has $_got — nothing further to do"
        exit 0
    fi
    # No usable IPv4.  Before declaring the port dead, ask the OTHER family:
    # a v6-only site answers no DHCP and still works perfectly.
    say "no usable IPv4 on vmbr0 — trying IPv6 (SLAAC, then DHCPv6)"
    # A Proxmox host forwards for the decoder VM, and Linux IGNORES router
    # advertisements on a forwarding interface unless accept_ra is 2.
    sysctl -qw net.ipv6.conf.vmbr0.accept_ra=2 2>/dev/null
    sysctl -qw net.ipv6.conf.vmbr0.accept_ra_defrtr=1 2>/dev/null
    sysctl -qw net.ipv6.conf.vmbr0.disable_ipv6=0 2>/dev/null
    ip link set vmbr0 up 2>/dev/null
    _got6=""
    for _r in $(seq 1 "${SIGMOND_RA_WAIT:-12}"); do
        _got6=$(ip -6 -o addr show vmbr0 scope global 2>/dev/null \
                | grep -v -e temporary -e deprecated | awk '{print $4; exit}')
        [ -n "$_got6" ] && break
        sleep 2
    done
    if [ -z "$_got6" ] && command -v dhclient >/dev/null 2>&1; then
        say "no router advertisement — trying DHCPv6"
        timeout 25 dhclient -6 -1 -v vmbr0 >>"$LOG" 2>&1
        _got6=$(ip -6 -o addr show vmbr0 scope global 2>/dev/null \
                | grep -v -e temporary -e deprecated | awk '{print $4; exit}')
    fi
    if [ -n "$_got6" ]; then
        # Drop the fossil: leaving an unroutable IPv4 on the bridge makes every
        # later "do we have IPv4?" test lie, and sigmond-v6-gateway keys off
        # exactly that question.
        ip addr del 192.168.100.2/24 dev vmbr0 2>/dev/null \
            && say "removed the unroutable installer fallback 192.168.100.2"
        sed -i -e '/^iface vmbr0 inet static/,/^[[:space:]]*$/{/^[[:space:]]*address[[:space:]]/d;/^[[:space:]]*gateway[[:space:]]/d;}' \
            /etc/network/interfaces 2>/dev/null
        if ! grep -q '^iface vmbr0 inet6' /etc/network/interfaces 2>/dev/null; then
            printf 'iface vmbr0 inet6 auto\n\tpost-up sysctl -qw net.ipv6.conf.vmbr0.accept_ra=2 || true\n\tpost-up sysctl -qw net.ipv6.conf.all.forwarding=1 || true\n' \
                >> /etc/network/interfaces
        fi
        say "vmbr0 is IPv6-only at $_got6 — this site has no IPv4, and that is fine"
        exit 0
    fi
    net_dead "NETWORK PORT IS CONNECTED, BUT NOTHING ANSWERED" \
             "The cable is in and the link is up on:" \
             "$LIVE_ENSLAVED"
    exit 1
fi

# ── try DHCP on each live NIC, standalone, before committing ────────────────
# Carrier alone is not enough: a switch port can be up with nothing behind it.
# Probe with dhclient on the bare interface so a failure costs nothing.
# ⛔ AND PROBE BOTH FAMILIES.  cur_ip() learned to REPORT an IPv6 address
# (d696800), but this loop -- the one that DECIDES whether the install is
# dead -- still asked dhclient for IPv4 and nothing else.  So on an
# IPv6-only LAN every port would come back "no DHCP answer", net_dead would
# fire, and the console would tell the operator the install cannot continue
# on a machine that is perfectly reachable over v6.  Fixing the reporting
# path without the decision path leaves the dead-install behaviour intact.
#
# Order is deliberate: IPv4 first, because it is what the fleet's reach, the
# frp registry and the 10.99.0.0/30 management link all speak.  v6 is the
# fallback that keeps a v6-only site alive, not a new preference.
#
# v6 needs no DHCP at all on most networks: SLAAC hands out an address from
# a router advertisement, so the probe is "bring the link up and WAIT",
# with DHCPv6 tried only if no RA arrives.
WINNER=""; WINNER_FAMILY=""
v6_global(){ ip -6 -o addr show "$1" scope global 2>/dev/null \
    | grep -v -e tentative -e deprecated | awk '{print $4}' | cut -d/ -f1 | head -1; }

for n in $LIVE; do
    say "trying IPv4 DHCP on $n ..."
    timeout 25 dhclient -1 -v "$n" >>"$LOG" 2>&1
    got=$(ip -4 -o addr show "$n" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    dhclient -r "$n" >/dev/null 2>&1
    if [ -n "$got" ]; then
        ip addr flush dev "$n" 2>/dev/null
        say "  $n got $got (IPv4) — using it for vmbr0"
        WINNER="$n"; WINNER_FAMILY=inet; break
    fi
    say "  $n has link but no IPv4 DHCP answer — trying IPv6"

    # SLAAC: an RA can take a few seconds.  Accept a global v6 the moment
    # one appears rather than burning the whole budget.
    sysctl -qw "net.ipv6.conf.$n.accept_ra=2" 2>/dev/null
    sysctl -qw "net.ipv6.conf.$n.disable_ipv6=0" 2>/dev/null
    got6=""
    for _r in $(seq 1 "${SIGMOND_RA_WAIT:-12}"); do
        got6="$(v6_global "$n")"; [ -n "$got6" ] && break
        sleep 2
    done
    if [ -z "$got6" ] && command -v dhclient >/dev/null 2>&1; then
        say "  no router advertisement on $n — trying DHCPv6"
        timeout 25 dhclient -6 -1 -v "$n" >>"$LOG" 2>&1
        got6="$(v6_global "$n")"
        dhclient -6 -r "$n" >/dev/null 2>&1
    fi
    ip addr flush dev "$n" 2>/dev/null
    if [ -n "$got6" ]; then
        say "  $n got $got6 (IPv6) — using it for vmbr0"
        WINNER="$n"; WINNER_FAMILY=inet6; break
    fi
    say "  $n has link but offered no address in either family"
done
if [ -z "$WINNER" ]; then
    # Same distinction as the no-cable branch: a cable that offers nothing is
    # not a dead machine when the radio is already carrying the station.
    if [ -n "$WIFI_UP" ]; then
        say "no port offered an address, but this station is on Wi-Fi ($WIFI_UP) — leaving it alone"
        rm -f /etc/sigmond-appliance/.network-unreachable 2>/dev/null
        exit 0
    fi
    net_dead "NO ADDRESS OFFERED, IPv4 OR IPv6" \
             "These ports have a cable, but nothing answered on either family:" \
             "$LIVE"
    exit 1
fi
say "selected $WINNER (${WINNER_FAMILY})"

# ── rebind vmbr0 to the winner, as DHCP ─────────────────────────────────────
cp -a "$IFACES" "$IFACES.netfix-bak-$(date -u +%Y%m%dT%H%M%SZ)" 2>/dev/null
python3 - "$IFACES" "$WINNER" "${WINNER_FAMILY:-inet}" <<'PY'
import re, sys
path, nic, family = sys.argv[1], sys.argv[2], sys.argv[3]

# ⛔ WRITE THE STANZA FOR THE FAMILY WE ACTUALLY FOUND.  This used to emit
# `iface vmbr0 inet dhcp` unconditionally.  On the v6-only path that is a
# request for an IPv4 lease nobody is offering: the probe would correctly
# find a v6 address, and then the bridge would be configured to go looking
# for v4 and come up with nothing -- the repair writing its own failure.
#
# `inet6 auto` is SLAAC, which is how the overwhelming majority of v6
# networks hand out addresses.  ifupdown accepts `inet6 dhcp` too, but we
# only get here having already proven which one answered.
s = open(path).read()
if family == "inet6":
    body = ("iface vmbr0 inet6 auto\n"
            f"\tbridge-ports {nic}\n"
            "\tbridge-stp off\n"
            "\tbridge-fd 0\n"
            # accept_ra=2 because a Proxmox host FORWARDS, and the kernel
            # ignores router advertisements on a forwarding interface unless
            # told otherwise.  Without this the bridge never takes the RA and
            # the address we just proved exists never appears.
            "\tpost-up sysctl -qw net.ipv6.conf.vmbr0.accept_ra=2 || true\n"
            "\tpost-up sysctl -qw net.ipv6.conf.all.forwarding=1 || true\n")
else:
    body = ("iface vmbr0 inet dhcp\n"
            f"\tbridge-ports {nic}\n"
            "\tbridge-stp off\n"
            "\tbridge-fd 0\n")

# Replace whichever family's stanza is present, so repeated runs do not
# stack a v4 and a v6 block for the same bridge.
for fam in ("inet", "inet6"):
    s = re.sub(rf'^iface vmbr0 {fam} \w+\n(?:[ \t]+.*\n|\n)*', '', s, flags=re.M)
if re.search(r'^auto vmbr0$', s, re.M):
    s = re.sub(r'^auto vmbr0$', 'auto vmbr0\n' + body.rstrip('\n'), s, count=1, flags=re.M)
else:
    s = s.rstrip('\n') + "\n\nauto vmbr0\n" + body
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

# ─── sigmond-v6-gateway: make an IPv6-only site usable ───────────────────────
# Validated on a real NAT64/DNS64 network (AI6VN-PM against a bench gateway,
# 2026-09-28).  Everything here is a NO-OP on an IPv4 site, by construction:
# each step checks the condition it needs rather than assuming the site shape.
#
# The decoder VM stays IPv4 forever and never learns IPv6.  This host is the
# translation boundary -- see sigmond/tasks/plan-ipv6-support.md §3.
cat > /usr/local/sbin/sigmond-v6-gateway <<'V6GWEOF'
#!/bin/bash
# sigmond-v6-gateway — give an IPv6-only site a working station.
# Idempotent and safe to re-run.  Exits 0 doing nothing on an IPv4 site.
set -u
export PATH=$PATH:/usr/sbin:/sbin
TAG=sigmond-v6-gateway
say(){ printf '%s\n' "$*"; logger -t "$TAG" -- "$*" 2>/dev/null || true; }

DEV="${SIGMOND_V6_DEV:-vmbr0}"
MGMT_VM_NET="${SIGMOND_MGMT_NET:-10.99.0.0/30}"
MGMT_PM_IP="${SIGMOND_MGMT_PM:-10.99.0.1}"
MGMT_VM_IP="${SIGMOND_MGMT_VM:-10.99.0.2}"

have4=$(ip -4 -o addr show dev "$DEV" scope global 2>/dev/null | wc -l)
have6=$(ip -6 -o addr show dev "$DEV" scope global 2>/dev/null | grep -vc -e temporary -e deprecated)

if [ "$have4" -gt 0 ]; then
    say "$DEV has IPv4 — nothing to do (this runs only on an IPv6-only site)"
    exit 0
fi
if [ "$have6" -eq 0 ]; then
    say "$DEV has neither family yet — too early; re-run after the link comes up"
    exit 0
fi

# 1. A RESOLVER.  Nothing on Proxmox consumes RDNSS: no rdnssd, no
#    systemd-resolved.  A v6-only station therefore boots with resolv.conf
#    still naming a dead IPv4 server and cannot resolve anything -- which also
#    blocks RFC 7050 NAT64 discovery, so nothing downstream can work either.
cur_ns=$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf 2>/dev/null)
ns_ok=0
[ -n "${cur_ns:-}" ] && timeout 3 getent hosts ipv4only.arpa >/dev/null 2>&1 && ns_ok=1
if [ "$ns_ok" -eq 0 ]; then
    rdnss=""
    if command -v rdisc6 >/dev/null 2>&1; then
        rdnss=$(rdisc6 -1 -w 3000 "$DEV" 2>/dev/null | awk '/Recursive DNS server/{getline; print $1; exit}')
    fi
    if [ -n "$rdnss" ]; then
        cp -p /etc/resolv.conf /etc/resolv.conf.sigmond-pre-v6 2>/dev/null
        printf 'nameserver %s\n' "$rdnss" > /etc/resolv.conf
        say "resolver set from the RA's RDNSS: $rdnss"
    else
        say "WARNING: no usable resolver and the RA advertised no RDNSS."
        say "  This station cannot resolve names. Set one by hand in /etc/resolv.conf."
        exit 1
    fi
fi

# 2. THE CLAT.  clatd discovers the site's NAT64 prefix by RFC 7050 and gives
#    this host an IPv4 default route over a translating tun device, so IPv4
#    LITERALS work -- which plain NAT64+DNS64 does not provide.  clatd checks
#    for existing IPv4 connectivity and stands down by itself, so enabling it
#    is harmless anywhere.
if command -v clatd >/dev/null 2>&1; then
    # ⛔ clatd MUST NOT be left to race the resolver.  Its RFC 7050 discovery
    # needs a working DNS64, which on an IPv6-only site arrives by RA/rdnssd
    # after the link comes up; when discovery finds nothing clatd exits ZERO, so
    # systemd records success and NEVER retries.  A boot-order race then becomes
    # a permanent outage -- and because the IPv4-only decoder VM reaches the
    # world only through this CLAT, that outage is the VM's entire internet.
    # AI6VN-PM lost five component installs to exactly this on 2026-09-29.
    #
    # Gate the start on discovery actually working, and retry on failure.  This
    # is a persistent drop-in, not a first-boot-only fix: the race is a race at
    # EVERY boot, so the repair has to live in the unit.
    # The helper is installed by first-boot, off the media, while the media is
    # still mounted.  Do NOT try to fetch it from /mnt/sig-media here: this
    # script also runs long after first-boot (sigmond-wifi calls it when it
    # joins an IPv6-only AP), when that path is unmounted and empty.  That is
    # exactly how v3.56 shipped an ungated clatd.  Fall back to the media only
    # if it happens to still be there, which is the first-boot case.
    if [ ! -x /usr/local/sbin/sigmond-wait-nat64 ] \
       && [ -f /mnt/sig-media/sigmond-wait-nat64 ]; then
        install -m 755 /mnt/sig-media/sigmond-wait-nat64 \
            /usr/local/sbin/sigmond-wait-nat64 2>/dev/null
    fi
    if [ -x /usr/local/sbin/sigmond-wait-nat64 ]; then
        mkdir -p /etc/systemd/system/clatd.service.d
        cat > /etc/systemd/system/clatd.service.d/10-sigmond-wait-nat64.conf <<'CLATD_EOF'
# Installed by sigmond firstboot.  See /usr/local/sbin/sigmond-wait-nat64 for
# the full reasoning; in short, clatd's PLAT discovery needs the DNS64 resolver
# that RA/rdnssd supplies seconds later, and clatd exits 0 -- "success" -- when
# it finds nothing, so without this it never tries again.
[Unit]
After=network-online.target rdnssd.service
Wants=network-online.target

[Service]
ExecStartPre=/usr/local/sbin/sigmond-wait-nat64
# on-failure, not always: a clatd that stands down because the site has native
# IPv4 has nothing to retry, but a lost discovery race must self-heal.
Restart=on-failure
RestartSec=30
CLATD_EOF
        systemctl daemon-reload >/dev/null 2>&1
    else
        say "WARNING: sigmond-wait-nat64 missing — clatd runs UNGATED, so a lost"
        say "  NAT64-discovery race will be permanent (it exits 0 on no prefix)"
    fi
    systemctl enable clatd >/dev/null 2>&1
    # ⛔ --no-block, OR THIS SCRIPT'S CALLER DIES.  clatd's ExecStartPre is the
    # gate above, which waits up to SIGMOND_NAT64_WAIT (180 s) for RFC 7050
    # discovery.  A blocking `systemctl restart` therefore inherits that 180 s
    # -- and sigmond-wifi-up.service, which calls this script, has
    # TimeoutStartSec=3min.  The two numbers are identical, so a slow discovery
    # kills the caller with certainty.  Measured on AI6VN-PM v3.59, 2026-09-30:
    #
    #   04:49:56 sigmond-wifi: running sigmond-v6-gateway on wlp3s0
    #   04:52:27 sigmond-wifi-up.service: start operation timed out. Terminating.
    #
    # The radio had already been addressed, so the damage was not the address --
    # it was that everything AFTER this line was skipped, and the unit was left
    # `failed` on a host that was working.  The IPv6->VM relay is one of the
    # things that comes after, so on precisely the boot where discovery is slow,
    # the relay would never be installed.
    #
    # Nothing here needs clatd to have finished: the wait below reports on it,
    # and clatd's own Restart=on-failure carries the retry.
    systemctl restart --no-block clatd >/dev/null 2>&1
    for i in $(seq 1 15); do ip link show clat >/dev/null 2>&1 && break; sleep 2; done
    if ip link show clat >/dev/null 2>&1; then
        say "CLAT up: $(ip -4 -o addr show clat | awk '{print $4}') (464XLAT active)"
    else
        say "CLAT not up yet — clatd is still waiting for NAT64 discovery, and"
        say "  systemd will retry it; this is not a failure of this script"
    fi
else
    say "WARNING: clatd is not installed; the VM will have no IPv4 path off-site"
fi

# 3. A RESOLVER FOR THE VM.  The guest is IPv4-only and cannot reach the site's
#    IPv6 resolver at all.  Serve DNS to it over IPv4 on the host-only /30 and
#    forward upstream over IPv6.  filter-AAAA because the site resolver is a
#    DNS64: it synthesises AAAA for every name, and handing those to a guest
#    with no IPv6 route buys only a happy-eyeballs stall before the fallback.
if command -v dnsmasq >/dev/null 2>&1; then
    up=$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf)
    mkdir -p /etc/dnsmasq.d
    cat > /etc/dnsmasq.d/sigmond-vm.conf <<CONF
# Managed by sigmond-v6-gateway. Serves the decoder VM only.
interface=vmbr1
listen-address=${MGMT_PM_IP}
bind-interfaces
no-dhcp-interface=vmbr1
no-resolv
server=${up}
# The guest is IPv4-only with no IPv6 route; synthesised AAAA are unusable.
filter-AAAA
CONF
    systemctl enable dnsmasq >/dev/null 2>&1
    # ⛔ --no-block, for the same reason as clatd above and then some: dnsmasq is
    # `After=network-online.target`, and this script runs from units that are
    # part of getting the network online.  A BLOCKING restart therefore waits on
    # a target that cannot be reached until we return -- a straight deadlock,
    # broken only by our caller's timeout.  Measured on AI6VN-PM v3.61,
    # 2026-09-30: sigmond-wifi-up and sigmond-netfix both wedged here and were
    # killed at 10 min and 5 min respectively; everything came up correctly the
    # moment they died.
    #
    # ⚠ The rule, not just this line: NOTHING in this script may start or
    # restart another unit synchronously.
    systemctl restart --no-block dnsmasq >/dev/null 2>&1
    say "VM resolver: dnsmasq on ${MGMT_PM_IP} re-pointed at ${up} (starting)"
    say "  (firstboot already stood this up; this only follows the resolver"
    say "   change that arriving on a v6-only site causes)"
else
    say "WARNING: dnsmasq not installed; the VM will have no resolver"
fi

# 4. The VM's egress.  Written by the vmbr1 stanza too, but re-assert it here:
#    a host that reached this point has no IPv4 on $DEV, so the vmbr0 rule
#    matches nothing and this is the only one that carries the guest.
iptables -t nat -C POSTROUTING -s "$MGMT_VM_NET" -o clat -j MASQUERADE 2>/dev/null \
  || iptables -t nat -A POSTROUTING -s "$MGMT_VM_NET" -o clat -j MASQUERADE

# 5. INBOUND, which egress does not give us.  The host forwards the VM's
#    operator-facing ports with `iptables -t nat ... DNAT --to 10.99.0.2:PORT`,
#    and a NAT rule cannot change address family.  The VM is IPv4-only by
#    design (plan-ipv6-support.md §3: the VM never learns IPv6, the host
#    translates), so on a v6-only site an operator reaching this host over IPv6
#    finds its own sshd answering and every forwarded port of the VM dead.
#    rob hit exactly that on the v3.59 install, 2026-09-30: "vm web and station
#    web are down on the dashboard", with station-web and ka9q-web both fine
#    inside the VM and `ip6tables -t nat -S PREROUTING` empty.
#    systemd-socket-proxyd relays v6 -> the host-only /30. Nothing to install.
if [ -x /usr/local/sbin/sigmond-vm6proxy ]; then
    say "IPv6 -> VM relay (DNAT cannot cross address families):"
    SIGMOND_MGMT_VM="$MGMT_VM_IP" /usr/local/sbin/sigmond-vm6proxy install 2>&1 \
        | while IFS= read -r _l; do say "  $_l"; done
else
    say "WARNING: sigmond-vm6proxy missing — the VM's web ports stay unreachable"
    say "  over IPv6; only the host itself will answer."
fi
say "done"
V6GWEOF
chmod +x /usr/local/sbin/sigmond-v6-gateway
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
    echo "reach this host at: ssh root@${ADDR%%/*}   https://$(ipurl "${ADDR%%/*}"):8006"
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
# ⛔ AND EVERYTHING ELSE THAT IS NOT [A-Za-z0-9-].  VTAG becomes a VM name, and
# `qm create --name` requires a valid DNS label: a `--dev` build stamps
# v0.0-dev+<sha>, and the surviving `+` makes qm refuse with
#     400 Parameter verification failed.
#     name: invalid format - value does not look like a valid DNS name
# so the host installs perfectly and then has NO DECODER VM.  build-usb-v3.sh
# already carries this second line -- and a comment about the identical `+`
# breaking prepare-iso -- but the copy here never got it, which made --dev
# builds (the mode for exercising the pipeline without minting a release)
# unable to complete.  Four nested runs failed on this before the import path
# was made to report what qm actually said.
VTAG="${VTAG//[^A-Za-z0-9-]/-}"
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
cp /mnt/sig-media/sigmond-net-probe "$APP"/ 2>/dev/null
# ⛔ THE STEP THAT WAS MISSING.  build-usb-v3.sh puts operator/toprc on the
# media and firstboot installs it FROM "$APP/toprc" -- but nothing ever copied
# it between the two, so the guard `[ -f "$APP/toprc" ]` was false on every
# build and the block skipped in silence.  rob asked for top's P (processor)
# column and it never shipped in any image: v3.63 has it on neither the media
# payload nor any user's config, and the firstboot log contains neither the
# success line nor the failure line (2026-09-30).
cp /mnt/sig-media/toprc "$APP"/ 2>/dev/null
if [ -f /mnt/sig-media/sigmond-wifi ]; then
    install -m 755 /mnt/sig-media/sigmond-wifi /usr/local/sbin/sigmond-wifi
fi
# ⛔ INSTALL THE CLAT GATE HERE, WHILE THE MEDIA IS STILL MOUNTED.
# v3.56 installed it from inside sigmond-v6-gateway instead — and that helper
# runs LATER: when sigmond-wifi joins an IPv6-only AP, or on any later boot, by
# which time /mnt/sig-media is unmounted and empty.  The `install` failed
# silently (2>/dev/null), the `[ -x ... ]` guard was false, and the clatd
# drop-in was never written, so clatd stayed ungated and exited 0 exactly as
# before.  Measured on AI6VN-PM 2026-09-29 running v3.56: the gate was in
# sigmond-v6-gateway, /usr/local/sbin/sigmond-wait-nat64 did not exist, and the
# decoder VM had no IPv4 egress — the very failure v3.56 exists to prevent.
#
# Anything the running system needs must be copied off the stick during
# first-boot.  The media is not a runtime resource.
# Same rule as the CLAT gate: copy it off the media NOW, while the media is
# mounted.  The v6 gateway that invokes it runs later, when /mnt/sig-media is
# gone.
if [ -f /mnt/sig-media/sigmond-vm6proxy ]; then
    install -m 755 /mnt/sig-media/sigmond-vm6proxy /usr/local/sbin/sigmond-vm6proxy
    say "IPv6->VM relay installed: /usr/local/sbin/sigmond-vm6proxy"
else
    say "WARNING: sigmond-vm6proxy not on the media — on an IPv6-only site the"
    say "  decoder VM's web ports will be unreachable (DNAT cannot cross families)"
fi
if [ -f /mnt/sig-media/sigmond-wait-nat64 ]; then
    install -m 755 /mnt/sig-media/sigmond-wait-nat64 /usr/local/sbin/sigmond-wait-nat64
    say "clat gate installed: /usr/local/sbin/sigmond-wait-nat64"
else
    say "WARNING: sigmond-wait-nat64 not on the media — clatd will be ungated;"
    say "  a lost NAT64-discovery race would then be permanent (see its header)"
fi
# ─── offline packages, BEFORE anything expects a network ─────────────────────
# A greenfield IPv6-only site cannot use apt at all: reaching the IPv4 mirrors
# needs the CLAT, the CLAT is clatd, and installing clatd needs apt.  A host
# with no Ethernet has the same loop with wpasupplicant.  These ride on the
# stick for exactly that reason, so apply them now -- before netfix, before the
# v6 gateway, before the wizard offers Wi-Fi.
#
# dpkg -i, not apt: apt would try to reach a mirror.  Order is not known, so
# run the whole set twice -- the second pass satisfies dependencies the first
# pass installed.  Already-installed packages are skipped, so this is a no-op
# on a station that has them.
if [ -d /mnt/sig-media/offline-debs ] && ls /mnt/sig-media/offline-debs/*.deb >/dev/null 2>&1; then
    mkdir -p "$APP"/offline-debs
    cp /mnt/sig-media/offline-debs/*.deb "$APP"/offline-debs/ 2>/dev/null
    _nd=$(ls "$APP"/offline-debs/*.deb 2>/dev/null | wc -l)
    DEBIAN_FRONTEND=noninteractive dpkg -i "$APP"/offline-debs/*.deb >>"$LOG" 2>&1 || true
    DEBIAN_FRONTEND=noninteractive dpkg -i "$APP"/offline-debs/*.deb >>"$LOG" 2>&1 || true
    # ⛔ AND CONFIGURE.  dpkg -i can leave a package "install ok unpacked" when a
    # dependency is missing, and an UNPACKED wpasupplicant is actively harmful:
    # it installs the /etc/network/if-{pre-,}up.d/wpasupplicant symlinks while
    # their targets are still .dpkg-new, and ifupdown2 then FAILS EVERY
    # INTERFACE BRING-UP with ENOENT.  On the nested v6 test that took vmbr1
    # down and the decoder VM never imported.  A half-installed payload is worse
    # than no payload.
    DEBIAN_FRONTEND=noninteractive dpkg --configure -a >>"$LOG" 2>&1 || true
    _unpacked=$(dpkg-query -W -f='${Package} ${Status}\n' 2>/dev/null \
                | awk '$NF=="unpacked"{print $1}' | tr '\n' ' ')
    if [ -n "$_unpacked" ]; then
        say "⛔ offline packages LEFT UNCONFIGURED:$_unpacked"
        say "  the payload is missing one of their dependencies. An unpacked"
        say "  wpasupplicant breaks ifupdown2 on EVERY interface, so removing"
        say "  its hooks now rather than leaving the host unable to bring up"
        say "  vmbr1 (which is how the decoder VM reaches anything)."
        rm -f /etc/network/if-pre-up.d/wpasupplicant /etc/network/if-up.d/wpasupplicant \
              /etc/network/if-down.d/wpasupplicant /etc/network/if-post-down.d/wpasupplicant 2>/dev/null
    fi
    _missing=""
    for _b in clatd tayga dnsmasq rdisc6 wpa_supplicant iw btop tmux; do
        command -v "$_b" >/dev/null 2>&1 || _missing="$_missing $_b"
    done
    if [ -z "$_missing" ] && [ -z "$_unpacked" ]; then
        say "offline packages: $_nd .deb applied and configured — clatd, tayga, dnsmasq, rdisc6, wpa_supplicant, iw, btop, tmux all present"
    else
        say "⚠ offline packages: applied $_nd .deb; missing binaries:${_missing:- none}"
        say "  an IPv6-only or Wi-Fi-only site may NOT come up; see $LOG"
    fi
else
    say "⚠ no offline-debs on the media — IPv6-only and Wi-Fi-only installs cannot work"
fi
if [ -f "$APP"/sigmond-net-probe ]; then
    chmod +x "$APP"/sigmond-net-probe 2>/dev/null
    ln -sf "$APP"/sigmond-net-probe /usr/local/sbin/sigmond-net-probe 2>/dev/null
    # Record ONE reading at install, when the station is on the network it
    # will actually live on.  A v6-only site (McMurdo) then reports its own
    # topology instead of us inferring it from Scranton months later.  Never
    # fail firstboot over a diagnostic.
    "$APP"/sigmond-net-probe --json > "$APP"/network-probe.json 2>/dev/null || true
    "$APP"/sigmond-net-probe        > "$APP"/network-probe.txt  2>/dev/null || true
    say "network: $(sed -n 's/.*"family":"\([^"]*\)".*/\1/p' "$APP"/network-probe.json 2>/dev/null)$(grep -q '"nat64":"yes"' "$APP"/network-probe.json 2>/dev/null && echo ' (NAT64 present)')"
fi
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
# top's CPU column for the host's root shell.  Stock top omits P (last-used
# CPU) entirely, and on this fleet that is not cosmetic: radiod is pinned to
# one hyperthread sibling pair and the decoders to the remaining cores, so
# "is this process on the core it is supposed to be on?" gets asked
# constantly — chasing affinity, checking a taskset took, working out why a
# box is loaded.  Without P the answer needs a separate `ps -o psr` each time.
#
# ~/.config/procps/toprc is the path modern top prefers (~/.toprc is legacy).
# NEVER overwrite an existing file — a hand-tuned config is someone's work —
# and never fail the boot over a column layout.
# ⛔ SYSTEM-WIDE, not per-user.  rob, 2026-09-30: "make it a global so that any
# user who invokes top gets that processor column, rather than trying to patch
# it into each of the users' private toprcs."  He was right twice over: the
# per-user approach also has to GUESS which accounts a human will use, and it
# guessed wrong -- the decoder VM seeded only the installer's account and
# `sigmond`, while rob logs in as `hamsci` and saw stock columns.
#
# procps-ng 4.x supports exactly this: /etc/topdefaultrc holds "defaults for
# users who have not saved their own configuration file", in the same format
# as a personal one (top(1) 6c).  A user who later presses `W` writes their own
# file and takes over, which is the right precedence.
#
# ⚠ /etc/toprc IS A DIFFERENT FILE AND MUST NOT BE USED FOR THIS.  That is the
# SYSTEM RESTRICTIONS file (top(1) 6d): its presence FORBIDS ordinary users
# from kill, renice and changing the delay.  Writing a field layout there would
# silently take capabilities away from every operator on the box.
if [ -f "$APP/toprc" ]; then
  if install -m 644 "$APP/toprc" /etc/topdefaultrc 2>/dev/null; then
    say "host: top shows the CPU (P) column for every user (/etc/topdefaultrc)"
  else
    say "host: WARNING could not write /etc/topdefaultrc — top keeps stock columns"
  fi
else
  # ⛔ Say so.  The old code could not distinguish "already present" from
  # "never shipped", and that silence is why this went unnoticed through
  # every build up to v3.63.
  say "host: WARNING toprc not on the media — top will keep its default columns"
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
  # ⛔ Not `ip route show default | awk '{print $3}'`.  That takes the FIRST
  # default route of either family, which on this appliance can be the PVE
  # installer's dead 192.168.100.1, or an IPv6 link-local -- and the guest is
  # IPv4-only, so neither is a resolver it can use.  usable_gw4() asks properly.
  127.*|"") PM_DNS=$(. /usr/local/lib/sigmond-net.sh 2>/dev/null && usable_gw4) ;;
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
    # ⛔ AND out the CLAT.  On an IPv6-only site vmbr0 has NO IPv4 address, so
    # the rule above matches nothing and the VM -- which is IPv4-only and can
    # never be anything else -- is cut off completely.  clatd puts the host's
    # IPv4 default route on a 'clat' tun device; masquerading out that too is
    # the single line that restores the VM.  Measured on AI6VN-PM 2026-09-28:
    # VM dead before, working immediately after.  Harmless where clat never
    # exists -- iptables accepts an interface name that is not present yet.
    post-up iptables -t nat -C POSTROUTING -s ${MGMT_NET} -o clat -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s ${MGMT_NET} -o clat -j MASQUERADE
    post-up iptables -t nat -C PREROUTING -p tcp --dport 8000 -j DNAT --to-destination ${MGMT_VM}:8000 2>/dev/null || iptables -t nat -A PREROUTING -p tcp --dport 8000 -j DNAT --to-destination ${MGMT_VM}:8000
    post-up iptables -t nat -C PREROUTING -p tcp --dport 8081 -j DNAT --to-destination ${MGMT_VM}:8081 2>/dev/null || iptables -t nat -A PREROUTING -p tcp --dport 8081 -j DNAT --to-destination ${MGMT_VM}:8081
    post-up iptables -t nat -C PREROUTING -p tcp --dport 8082 -j DNAT --to-destination ${MGMT_VM}:8082 2>/dev/null || iptables -t nat -A PREROUTING -p tcp --dport 8082 -j DNAT --to-destination ${MGMT_VM}:8082
    post-up iptables -t nat -C PREROUTING -p tcp --dport 8765 -j DNAT --to-destination ${MGMT_VM}:8765 2>/dev/null || iptables -t nat -A PREROUTING -p tcp --dport 8765 -j DNAT --to-destination ${MGMT_VM}:8765
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
# The CLAT path, for an IPv6-only site.  See the comment on the vmbr1 stanza.
iptables -t nat -C POSTROUTING -s "$MGMT_NET" -o clat -j MASQUERADE 2>/dev/null \
  || iptables -t nat -A POSTROUTING -s "$MGMT_NET" -o clat -j MASQUERADE

# ─── a resolver for the decoder VM, on EVERY site ────────────────────────────
# The VM is IPv4-only and always will be, and it has exactly one link: this
# host.  Handing it the SITE's resolver worked by luck on an IPv4 LAN and failed
# outright on an IPv6-only one, where the site resolver is an IPv6 address the
# guest cannot reach -- routing fine, name resolution dead.
#
# So the host answers DNS for it, always, at the /30 address the VM already
# calls its gateway.  One rule on every site in either family, instead of a
# special case that only exists where someone remembered to add it.
if command -v dnsmasq >/dev/null 2>&1; then
    mkdir -p /etc/dnsmasq.d
    cat > /etc/dnsmasq.d/sigmond-vm.conf <<DNSEOF
# Managed by sigmond firstboot. Serves the decoder VM and nothing else.
# bind-interfaces + listen-address: never answer on the site LAN.
interface=vmbr1
listen-address=${MGMT_PM}
bind-interfaces
no-dhcp-interface=vmbr1
no-resolv
server=${PM_DNS}
# The guest is IPv4-only with no IPv6 route of any kind.  On a NAT64 site the
# upstream is a DNS64 and will synthesise AAAA for every name; handing those to
# the guest buys only a happy-eyeballs stall before it falls back to A.
filter-AAAA
DNSEOF
    systemctl enable dnsmasq >/dev/null 2>&1
    if systemctl restart dnsmasq >/dev/null 2>&1; then
        say "VM resolver: dnsmasq on ${MGMT_PM} -> ${PM_DNS} (the VM asks its gateway, not the site)"
    else
        say "⚠ dnsmasq would not start — the decoder VM will have NO name resolution"
        journalctl -u dnsmasq -n 5 --no-pager >>"$LOG" 2>&1
    fi
else
    say "⚠ dnsmasq absent — the decoder VM will have NO name resolution"
fi
# The VM's operator-facing services must not vanish from the LAN just
# because it moved behind us.  Reach them at THIS host's address -- the same
# one already used for ssh and the Proxmox UI, so one address per station
# instead of two.  Measured on a running station rather than assumed: the
# decoder VM binds externally on 22, 8000 (station-web), 8081 (ka9q-web) and
# 8082 (gmag-webui).  ssh is forwarded on 2222 because this host's own sshd
# owns 22.
# 8765 is mag-usb's live sample feed: the magnetometer page is on 8082 and its
# websocket is on 8765, so forwarding one without the other gives a dashboard
# that loads and then reports "disconnected" for ever (AI6VN 2026-09-30).
for _pf in 8000:8000 8081:8081 8082:8082 8765:8765 2222:22; do
  _hp=${_pf%%:*}; _gp=${_pf##*:}
  iptables -t nat -C PREROUTING -p tcp --dport "$_hp" -j DNAT --to-destination "${MGMT_VM}:${_gp}" 2>/dev/null \
    || iptables -t nat -A PREROUTING -p tcp --dport "$_hp" -j DNAT --to-destination "${MGMT_VM}:${_gp}"
done
if ip -4 addr show vmbr1 2>/dev/null | grep -q "$MGMT_PM"; then
  say "import: vmbr1 up — VM will be at ${MGMT_VM}, NATed out vmbr0, :8081 forwarded here"
else
  say "import: WARNING — vmbr1 did not come up; the VM may be unreachable from this host"
fi

# An IPv6-only site needs a resolver, a CLAT and a resolver FOR THE VM before
# the guest can reach anything.  Runs here because vmbr1 and the NAT rules now
# exist and the site link has settled.  No-op on an IPv4 site.
if [ -x /usr/local/sbin/sigmond-v6-gateway ]; then
  SIGMOND_MGMT_NET="$MGMT_NET" SIGMOND_MGMT_PM="$MGMT_PM" SIGMOND_MGMT_VM="$MGMT_VM" \
    /usr/local/sbin/sigmond-v6-gateway 2>&1 | while IFS= read -r _l; do say "v6gw: $_l"; done
fi

if ! qm create "$VMID" --name "sigmond-decoder-${VTAG}" --machine q35 --memory "$VMMEM" $CORES_ARGS \
  --cpu host --net0 virtio,bridge=vmbr1 --ostype l26 --scsihw virtio-scsi-single \
  --agent 1 --serial0 socket --onboot 1 >>"$LOG" 2>&1; then
    say "import: qm create FAILED — see $LOG; the decoder VM cannot be created"
    rm -f /tmp/decoder.qcow2; exit 1
fi
# ⛔ CAPTURE THE OUTPUT.  These two ran with stdout and stderr going nowhere,
# so when the import failed all the operator got was "no unused0" -- a symptom
# with the cause thrown away.  On the nested IPv6 run that cost an investigation
# to get back to "what did qm actually say?", and the answer was unrecoverable
# because the failure path purges the VM and deletes the source image.
_IMPLOG=/tmp/sigmond-import.$$.log
qm importdisk "$VMID" /tmp/decoder.qcow2 "$STORE" >"$_IMPLOG" 2>&1
_IMPRC=$?
[ "$_IMPRC" -ne 0 ] && say "import: qm importdisk exited $_IMPRC"
DISK="$(qm config "$VMID"|awk -F': ' '/^unused0:/{print $2;exit}')"
if [ -z "$DISK" ]; then
    say "import: no unused0 after importdisk — the decoder VM CANNOT be created."
    say "  qm importdisk said:"
    tail -8 "$_IMPLOG" 2>/dev/null | while IFS= read -r _l; do say "    $_l"; done
    say "  storage:"
    pvesm status 2>/dev/null | awk 'NR>1{print "    "$1" "$2" "$3" avail="$6}' \
        | while IFS= read -r _l; do say "$_l"; done
    say "  source: $(ls -l /tmp/decoder.qcow2 2>/dev/null | awk '{print $5" bytes"}' || echo MISSING)"
    cat "$_IMPLOG" >>"$LOG" 2>/dev/null; rm -f "$_IMPLOG"
    qm destroy "$VMID" --purge 2>/dev/null; rm -f /tmp/decoder.qcow2; exit 1
fi
cat "$_IMPLOG" >>"$LOG" 2>/dev/null; rm -f "$_IMPLOG"
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
    '# The VM asks its own ROUTER for DNS, not whatever this host happens to' \
    '# use.  PM_DNS is the SITE resolver, and on an IPv6-only site that is an' \
    '# IPv6 address an IPv4-only guest can never reach: the VM came up with' \
    '# routing that worked and name resolution that did not.  Measured in the' \
    '# nested v6 test 2026-09-28 -- curl to a v4 LITERAL returned HTTP 301 in' \
    '# 0.16s while curl by NAME said "Could not resolve host: github.com".' \
    '# 10.99.0.1 is a constant of the host-only /30, so it is correct on every' \
    '# site in either family, and the host now runs a resolver there' \
    '# unconditionally (see the dnsmasq block by the vmbr1 setup).' \
    "DNS=${MGMT_PM}" | base64 -w0)

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
# ⛔ BEST-EFFORT, AND NEVER DURING SHUTDOWN.  Handing the console back is a
# courtesy; it must not be able to report a successful install as a failure.
#
# The finalizer reboots the host the moment the wizard marks .configured, so
# this ExecStopPost usually runs while the machine is ALREADY STOPPING.  Asking
# systemd to START a getty then is refused as destructive, systemctl exits
# 4/NOPERMISSION, and systemd marks the whole unit failed -- printing, in red,
# at the end of a wizard that completed perfectly (AI6VN-PM, v3.64, 2026-10-01
# 00:21:30 UTC):
#
#   Requested transaction contradicts existing jobs: Transaction for
#     getty@tty1.service/start is destructive (local-fs-pre.target has 'stop'
#     job queued, but 'start' is included in transaction).
#   sigmond-wizard.service: Control process exited, code=exited,
#     status=4/NOPERMISSION
#   sigmond-wizard.service: Failed with result 'exit-code'
#
# rob: "a red line is alarming to the uninitiated."  He is right, and the cure
# is not a different colour -- the install did not fail, so nothing red should
# be printed.  Two changes: skip the call entirely when the system is stopping
# (which also suppresses systemd's own "contradicts existing jobs" warning),
# and prefix with `-` so that even an unforeseen failure here cannot mark a
# finished wizard as failed.  A getty is pointless on a machine that is
# rebooting: the next boot starts one anyway.
ExecStopPost=-/bin/sh -c 'case "$(systemctl is-system-running 2>/dev/null)" in stopping|offline) exit 0 ;; esac; systemctl --no-block start getty@tty1.service
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
#
# ⛔ cur_ip() and ipurl() come from here.  They are NOT defined in this file,
# and on v3.52 they were not sourced either -- they were defined inside
# sigmond-netfix, a separate script, so every refresh printed
#     line 6:   cur_ip: command not found
#     line 313: ipurl: command not found
# and the panel showed no host address and a broken Proxmox URL.  If this
# source line ever goes away, that failure comes straight back.
. /usr/local/lib/sigmond-net.sh 2>/dev/null || {
    # Never leave the panel blank: a console with no address on it is how an
    # operator concludes the machine is dead.  Degrade to IPv4-only rather
    # than to nothing, and say so.
    cur_ip(){ ip -4 -o addr show "${1:-vmbr0}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1; }
    ipurl(){ case "${1:-}" in *:*) printf '[%s]\n' "$1";; *) printf '%s\n' "${1:-}";; esac; }
    _NETLIB_MISSING=1
}
VMID="${SIGMOND_VMID:-100}"
VERSION="$(cat /etc/sigmond-appliance/version 2>/dev/null || echo '?')"
CONF="$(cat /etc/sigmond-appliance/.configured 2>/dev/null)"
HOSTIP=$(cur_ip vmbr0)
# ⚠ NOT `hostname -I | awk '{print $1}'`: that lists EVERY address, and since
# the decoder VM moved behind a host-only bridge this host also holds
# 10.99.0.1.  Ordering is not guaranteed, so the panel/summary could announce
# the management /30 -- an address reachable only from the VM -- as the
# station's address (rob, 2026-09-21: "it was using 10.99.0 ... I think you
# need to exclude 10.99").  Ask vmbr0 directly, and fall back excluding it.
# hostname -I lists every address; drop the internal PM<->VM link, loopback
# and IPv6 link-local, which is unusable without a scope id.
# ⛔ EXCLUDE 192.0.0.0/29 TOO.  That is the CLAT's own translation endpoint
# (RFC 7335), present on every IPv6-only station, and it is not an address
# anyone can reach -- not even this host, from anywhere but itself.  Without
# this the panel advertised `ssh root@192.0.0.1`, `https://192.0.0.1:8006` and
# `http://192.0.0.1:8081` as the station's addresses, which is every URL on the
# screen wrong (AI6VN-PM v3.62, 2026-09-30).
# Prefer a real global IPv6 over any leftover IPv4: on a v6-only site the
# radio's address is the only one that works.
[ -n "$HOSTIP" ] || HOSTIP=$(ip -6 -o addr show scope global 2>/dev/null \
    | grep -v -e temporary -e deprecated -e ' lo ' \
    | awk '{print $4}' | cut -d/ -f1 | head -1)
[ -n "$HOSTIP" ] || HOSTIP=$(hostname -I 2>/dev/null | tr ' ' '\n' \
    | grep -vE '^(10\.99\.0\.|127\.|192\.0\.0\.|fe80:)' | head -1)
VMIP=""; VMNOTE=""
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
  # ⛔ KEEP THE NOTE OUT OF THE ADDRESS.  This used to append the caveat to
  # VMIP itself, and VMIP is substituted into a command line -- so the panel
  # printed
  #     ssh sigmond@10.99.0.2 (via ARP — guest agent not answering)
  # which is not a command anyone can paste, on the row an operator reaches
  # for when the guest agent is exactly what is not answering (rob's console,
  # v3.62, 2026-09-30).  Carry it as a separate label.
  [ -n "$VMIP" ] && VMNOTE=" (address via ARP — guest agent not answering)"
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
    # ⛔ ipurl(), not the bare address.  Once the panel started preferring the
    # radio's global IPv6 these became `http://fd4f:a955:ac3d:2:...:8081`,
    # which is not a URL at all -- a v6 literal needs brackets before anything
    # can append :port (rob's console, v3.62, 2026-09-30).  The web UI line
    # above always used ipurl; these two were simply missed, and it did not
    # show while HOSTIP was IPv4.  ssh takes a bare literal, so the VM ssh
    # line below is right as it stands.
    # ⛔ ALL of them, not the two we happened to think of.  The decoder VM
    # serves four operator-facing pages and the panel listed two, so the
    # magnetometer dashboard and its live feed were invisible on the console
    # even while recording (rob, v3.62, 2026-09-30) -- the same omission the
    # RAC section had.  Ports are spelled out because the operator is often
    # reading this while deciding what to forward.
    KA9QURL="http://$(ipurl "${HOSTIP:-<no-ip-yet>}"):8081        <- via this host
   station-web  http://$(ipurl "${HOSTIP:-<no-ip-yet>}"):8000
   magnetometer http://$(ipurl "${HOSTIP:-<no-ip-yet>}"):8082
   mag feed     ws://$(ipurl "${HOSTIP:-<no-ip-yet>}"):8765/   (live samples)
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
    # ⚠ This is the frp CLIENT IDENTITY (e.g. DASI-009), not an SSH account.
    # The panel used to print it as the ssh username on both RAC lines, so the
    # console offered `ssh -p 51029 DASI-009@vpn.hamsci.org` -- which cannot
    # work, on the one line an operator needs when the VM is unreachable.  It
    # is kept only for display/diagnostics; the logins are root (Proxmox host)
    # and hamsci (decoder VM), exactly as the local sections above say.
    RUSR=$(awk -F'"' '/^user *=/{print $2; exit}' /etc/sigmond/frpc-host.toml)
    RTIER=$(cat /etc/sigmond-appliance/rac-tier 2>/dev/null)
    RREG=$(cat /etc/sigmond-appliance/rac-registrar 2>/dev/null)
    # ── every declared channel, grouped by WHO CAN REACH IT ────────────────
    # ⛔ The old parser recognised exactly four suffixes and printed exactly
    # four lines.  A station that declares six channels showed "6/6 channels
    # up" and then listed four of them, so station-web and the magnetometer --
    # both perfectly reachable -- were invisible to the operator reading the
    # console (rob, v3.62, 2026-09-30).  Anything unrecognised now still gets
    # a line, named after its own suffix, because a channel nobody can see is
    # worse than a channel with an ugly name.
    #
    # The split is not cosmetic.  These are two different audiences:
    #
    #   ADMINISTRATORS  the Proxmox host's ssh and web UI.  Full control of
    #                   the machine, never published to anyone else.
    #   HamSCI USERS    the decoder VM's ssh and its web pages.  Private by
    #                   default too: they need a WireGuard config for this
    #                   gateway, unless a site administrator has deliberately
    #                   published one channel.
    #
    # Printing them as one undifferentiated list invites exactly the wrong
    # assumption -- that a port on a public hostname is a public service.
    _racline(){   # _racline <suffix> <port>
        case "$1" in
          *-host-ssh) printf '   host ssh     ssh -p %s root@%s\n' "$2" "$RSRV" ;;
          *-host-ui)  printf '   host UI      https://%s:%s\n' "$(ipurl "$RSRV")" "$2" ;;
          *-vm-ssh)   printf '   VM ssh       ssh -p %s hamsci@%s\n' "$2" "$RSRV" ;;
          *-vm-web)   printf '   ka9q-web     http://%s:%s\n' "$(ipurl "$RSRV")" "$2" ;;
          *-vm-web2)  printf '   ka9q-web #2  http://%s:%s\n' "$(ipurl "$RSRV")" "$2" ;;
          *-vm-web3)  printf '   ka9q-web #3  http://%s:%s\n' "$(ipurl "$RSRV")" "$2" ;;
          *-vm-station) printf '   station-web  http://%s:%s\n' "$(ipurl "$RSRV")" "$2" ;;
          *-vm-gmag)  printf '   magnetometer http://%s:%s\n' "$(ipurl "$RSRV")" "$2" ;;
          *-vm-grape) printf '   GRAPE charts http://%s:%s\n' "$(ipurl "$RSRV")" "$2" ;;
          *-ssh)      printf '   ssh          ssh -p %s hamsci@%s\n' "$2" "$RSRV" ;;
          *-web)      printf '   web          http://%s:%s\n' "$(ipurl "$RSRV")" "$2" ;;
          *)          printf '   %-12s port %s\n' "${1##*-}" "$2" ;;
        esac
    }
    RAC_ADMIN=""; RAC_USER=""
    while read -r _nm _pt; do
        [ -n "$_nm" ] && [ -n "$_pt" ] || continue
        case "$_nm" in
            *-host-ssh|*-host-ui) RAC_ADMIN="$RAC_ADMIN$(_racline "$_nm" "$_pt")
" ;;
            *)                    RAC_USER="$RAC_USER$(_racline "$_nm" "$_pt")
" ;;
        esac
    done <<RACEOF
$(awk -F'"' '/^name *=/{n=$2}
             /^remotePort *=/{split($0,a,"="); gsub(/[ \t]/,"",a[2]);
                              if (n != "") print n, a[2]; n=""}' \
         /etc/sigmond/frpc-host.toml)
RACEOF
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
   status     $RSTAT${RREG:+
   registrar  $RREG}
${RAC_ADMIN:+
   -- ADMINISTRATORS ONLY -- full control of this machine, never published --
$RAC_ADMIN}${RAC_USER:+
   -- HamSCI users -- private by default, NOT public --
$RAC_USER   These need a WireGuard config for ${RSRV:-the gateway}. A site
   administrator can publish one of them individually; none is public
   just because the hostname is.
}"
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
# usable_gw4() skips the installer's dead 192.168.100.1 and anything on a port
# with no carrier, so a Wi-Fi-only station is not told its gateway is down.
_gw=$(usable_gw4 2>/dev/null)
if [ -n "$_gw" ]; then
    if ping -c1 -W2 "$_gw" >/dev/null 2>&1; then _gwl="gateway $_gw responds"
    else _gwl="gateway $_gw DOES NOT RESPOND  <- this host cannot reach the LAN"; fi
elif ip -4 route show default 2>/dev/null | grep -q " dev clat"; then
    # 464XLAT: IPv4 leaves through the CLAT, which is point-to-point and has no
    # gateway address.  Nothing to ping, and nothing wrong.
    _gwl="IPv4 via the CLAT (464XLAT) -- no gateway to ping, this is normal"
elif ip -6 route show default 2>/dev/null | grep -q .; then
    _gwl="no IPv4 gateway; this site is IPv6 -- normal here"
else
    _gwl="NO DEFAULT ROUTE  <- this host cannot reach anything"
fi
# Warn when the cable is in a port vmbr0 is not using -- the exact trap.
_stray=""
for _d in /sys/class/net/*; do
    _n=$(basename "$_d"); [ -e "$_d/device" ] || continue
    case "$_n" in lo|vmbr*|tap*|fwbr*|fwln*|fwpr*|veth*|bond*|dummy*|wg*|tun*) continue ;; esac
    # ⛔ A RADIO IS NOT A STRAY CABLE.  wlp3s0 always has carrier when it is
    # associated and is never vmbr0's port (managed mode cannot be bridged), so
    # this fired on every healthy Wi-Fi-only station and told the operator to
    # "move the cable, or reboot" -- advice that is wrong twice over, on a
    # machine that was working (AI6VN-PM v3.62, 2026-09-30).
    [ -e "$_d/wireless" ] && continue
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
   web UI     https://$(ipurl "${HOSTIP:-<no-ip-yet>}"):8006
   login      root / $PWLINE

 Decoder VM   ${VMIP:-<starting — this panel refreshes every 5 min>}${VMNOTE}${VMBEHIND}
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

HOSTIP=$(cur_ip vmbr0)
# ⚠ NOT `hostname -I | awk '{print $1}'`: that lists EVERY address, and since
# the decoder VM moved behind a host-only bridge this host also holds
# 10.99.0.1.  Ordering is not guaranteed, so the panel/summary could announce
# the management /30 -- an address reachable only from the VM -- as the
# station's address (rob, 2026-09-21: "it was using 10.99.0 ... I think you
# need to exclude 10.99").  Ask vmbr0 directly, and fall back excluding it.
# hostname -I lists every address; drop the internal PM<->VM link, loopback
# and IPv6 link-local, which is unusable without a scope id.
# ⛔ EXCLUDE 192.0.0.0/29 TOO.  That is the CLAT's own translation endpoint
# (RFC 7335), present on every IPv6-only station, and it is not an address
# anyone can reach -- not even this host, from anywhere but itself.  Without
# this the panel advertised `ssh root@192.0.0.1`, `https://192.0.0.1:8006` and
# `http://192.0.0.1:8081` as the station's addresses, which is every URL on the
# screen wrong (AI6VN-PM v3.62, 2026-09-30).
# Prefer a real global IPv6 over any leftover IPv4: on a v6-only site the
# radio's address is the only one that works.
[ -n "$HOSTIP" ] || HOSTIP=$(ip -6 -o addr show scope global 2>/dev/null \
    | grep -v -e temporary -e deprecated -e ' lo ' \
    | awk '{print $4}' | cut -d/ -f1 | head -1)
[ -n "$HOSTIP" ] || HOSTIP=$(hostname -I 2>/dev/null | tr ' ' '\n' \
    | grep -vE '^(10\.99\.0\.|127\.|192\.0\.0\.|fe80:)' | head -1)
say "─────────────────────────────────────────────────────────"
say " Sigmond appliance $VERSION: Proxmox is installed and running."
say "   console/SSH login: root / hamsci-sigmond  (CHANGE IT: 'passwd')"
say "   ssh root@${HOSTIP:-<host-ip>}    web GUI: https://$(ipurl "${HOSTIP:-<host-ip>}"):8006"
say " NEXT STEP: plug in the Sigmond install USB stick."
say " The decoder VM then installs itself automatically."
say "─────────────────────────────────────────────────────────"
/usr/local/sbin/sigmond-import.sh
say "first-boot v3 complete"
exit 0
