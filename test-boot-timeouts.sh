#!/bin/bash
# test-boot-timeouts.sh — dhclient must give up before systemd kills ifup.
#
# AI6VN-PM 2026-10-28.  networking.service carries a sigmond drop-in capping
# TimeoutStartSec at 45s, as a last resort against a boot that never finishes.
# dhclient's own default timeout is 60s -- LONGER -- so at a site with no
# DHCPv4 server dhclient could never give up first and systemd killed ifup on
# every boot.  Arithmetic, not a race.
#
# The damage is not confined to the interface being leased: ifup walks
# /etc/network/interfaces in order, so every stanza below the kill point is
# never configured.  vmbr1 (10.99.0.1) is below vmbr0, so dnsmasq -- whose
# listen-address is exactly that -- could not bind, and with the stock
# Restart=no it stayed dead.  The decoder VM had no DNS at all for the rest of
# the boot, while every health check it has kept passing.
#
# Pass a different firstboot-v3.sh as $1 to run this against a mutant.
set -u
cd "$(dirname "$(readlink -f "$0")")"
FB="${1:-firstboot-v3.sh}"
[ -f "$FB" ] || { echo "FATAL: no firstboot-v3.sh at $FB"; exit 1; }
pass=0; fail=0
ok(){  printf '  ✓ %s\n' "$1"; pass=$((pass+1)); }
bad(){ printf '  ✗ %s\n     %s\n' "$1" "$2"; fail=$((fail+1)); }

# Both numbers, read out of the HEREDOCS THAT WRITE THEM -- not merely the
# last match in the file.  An earlier draft of this test used `grep | tail -1`
# and read TimeoutStartSec=60 from an unrelated unit: it would have passed
# with the two numbers inverted, which is the whole bug.
read -r net_to dh_to <<<"$(python3 - "$FB" <<'PYX'
import re, sys, pathlib
s = pathlib.Path(sys.argv[1]).read_text()
def block(marker):
    m = re.search(r"networking\.service\.d/[\w.-]+ <<'%s'\n(.*?)\n%s\n" % (marker, marker), s, re.S)
    if not m:
        m = re.search(r"<<'%s'\n(.*?)\n%s\n" % (marker, marker), s, re.S)
    return m.group(1) if m else ""
net = re.search(r"^TimeoutStartSec=(\d+)", block("NETTOEOF"), re.M)
dh  = re.search(r"^timeout (\d+);", block("DHCPTOEOF"), re.M)
print((net.group(1) if net else ""), (dh.group(1) if dh else ""))
PYX
)"

echo "── the two numbers that have to be in the right order ──"
if [ -n "$net_to" ] && [ -n "$dh_to" ]; then
    ok "networking.service TimeoutStartSec=${net_to}s, dhclient timeout=${dh_to}s"
else
    bad "could not read both timeouts" "networking='${net_to:-unset}' dhclient='${dh_to:-unset}'"
fi

if [ -n "$net_to" ] && [ -n "$dh_to" ] && [ "$dh_to" -lt "$net_to" ]; then
    ok "dhclient gives up first, so ifup finishes the file"
else
    bad "dhclient outlasts the cap: ifup is killed mid-file and every stanza below is never configured" \
        "dhclient=${dh_to:-unset}s >= networking=${net_to:-unset}s"
fi

# Margin: giving up at 44s of a 45s cap finishes nothing.
if [ -n "$net_to" ] && [ -n "$dh_to" ] && [ $(( net_to - dh_to )) -ge 15 ]; then
    ok "$(( net_to - dh_to ))s left for the rest of ifup after dhclient gives up"
else
    bad "no room to finish ifup after dhclient gives up" \
        "only $(( ${net_to:-0} - ${dh_to:-0} ))s of margin"
fi

echo "── the resolver has to come back ──"
if grep -q 'dnsmasq.service.d' "$FB" && grep -A3 'dnsmasq.service.d/10-sigmond-restart.conf' "$FB" | grep -q '^Restart=on-failure'; then
    ok "dnsmasq carries Restart=on-failure (the stock unit is Restart=no)"
else
    bad "dnsmasq keeps the stock Restart=no: one failed bind at boot and the VM has no DNS until a human intervenes" \
        "$(grep -c 'dnsmasq.service.d' "$FB") dnsmasq drop-in references"
fi

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
