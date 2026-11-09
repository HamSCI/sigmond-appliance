#!/bin/bash
# test-radionet.sh — the site radio network keeps radiod multicast off the LAN
# and still delivers any stream a VM on another host asks for.
#
# ⛔ WHY THIS EXISTS.  Most sites have an unmanaged switch and a Wi-Fi AP on
# the station LAN.  The switch floods multicast like broadcast, and the AP
# repeats it to every Wi-Fi client, so radiod streams (tens to hundreds of
# Mb/s) can make the LAN unusable.  sigmond-radionet carries them between the
# hosts in a VXLAN tunnel (unicast on the LAN) and IGMP snooping lets a stream
# into the tunnel only while someone across it has joined.  Two settings make
# or break that, and both broke once in the field:
#   - the tunnel port must NOT be a multicast router port, or every local
#     stream is copied to every peer (KFS 2026-11-09: 180 Mb/s from one host);
#   - with flooding into the tunnel off, link-local multicast (224.0.0.0/24:
#     IGMPv3 reports on .22, mDNS on .251) must still be copied in from the
#     local VMs, or a VM can neither join nor resolve a radiod on another host
#     (KPH 2026-11-09: `control` on KPH1 could not resolve KPH2, 0 packets).
#
#   usage: ./test-radionet.sh [path/to/firstboot-v3.sh]
set -u
SRC="${1:-$(dirname "$0")/firstboot-v3.sh}"
[ -f "$SRC" ] || { echo "FATAL: no firstboot-v3.sh at $SRC"; exit 1; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
chk(){ # chk <desc> <got> <want>
    if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ok    %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAIL  %s\n        want: %s\n        got : %s\n' "$1" "$3" "$2"; fi; }
has(){ grep -qE -- "$2" "$1" && echo yes || echo no; }

# ── extract the script exactly as firstboot writes it ───────────────────────
awk "/^cat > \/usr\/local\/sbin\/sigmond-radionet <<'RADIONETEOF'\$/,/^RADIONETEOF\$/" "$SRC" \
    | sed '1d;$d' > "$WORK/sigmond-radionet"
[ -s "$WORK/sigmond-radionet" ] || { echo "FATAL: could not extract sigmond-radionet from $SRC"; exit 1; }
bash -n "$WORK/sigmond-radionet" || { echo "FATAL: extracted script does not parse"; exit 1; }
S="$WORK/sigmond-radionet"

echo "snooping inside the tunnel"
chk "snooping on"                 "$(has "$S" 'echo 1 > .*/bridge/multicast_snooping')" yes
chk "bridge is the querier"       "$(has "$S" 'echo 1 > .*/bridge/multicast_querier')" yes
chk "IGMPv3"                      "$(has "$S" 'echo 3 > .*/bridge/multicast_igmp_version')" yes
chk "tunnel never a router port"  "$(has "$S" 'bridge link set dev "\$VX" mcast_router 0 mcast_flood off')" yes

echo "joins and names still cross"
chk "copy hook on local VM ports" "$(has "$S" 'type filter hook ingress devices = \{ \$list \}')" yes
chk "copies all of 224.0.0.0/24"  "$(has "$S" 'ip daddr 224\.0\.0\.0/24 counter dup to "\$VX"')" yes
chk "never copies data groups"    "$(grep -E 'dup to' "$S" | grep -vc '224\.0\.0\.0/24')" 0
chk "tunnel port excluded"        "$(has "$S" 'grep -vx "\$VX"')" yes
chk "rule reinstalled every run"  "$(grep -c '^delete table netdev radionet$' "$S")" 1

echo "units"
chk "timer enabled by firstboot"  "$(has "$SRC" '^systemctl enable sigmond-radionet.timer')" yes
chk "runs every 2 minutes"        "$(awk "/^cat > \/etc\/systemd\/system\/sigmond-radionet.timer/,/^RNTMREOF\$/" "$SRC" | grep -c '^OnUnitActiveSec=2min')" 1

echo "inert without a site config"
if [ ! -e /etc/sigmond/radionet.conf ]; then
    out=$(bash "$S" 2>&1); rc=$?
    chk "exit 0 with no radionet.conf" "$rc" 0
    chk "says nothing to do"           "$(echo "$out" | grep -c 'nothing to do')" 1
else
    echo "  skip  /etc/sigmond/radionet.conf exists here (a live host); not running the script"
fi

echo; echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
