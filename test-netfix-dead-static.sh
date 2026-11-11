#!/bin/bash
# test-netfix-dead-static.sh — when no DHCP lease comes, netfix must not put
# back a static IPv4 whose gateway is not on this network, if the bridge has
# IPv6.  i5-6500T, v3.90, 2026-11-11: the stanza held rob's HamLAN address
# (10.22.23.78 gw 10.22.23.1), the box was cabled to the IPv6-only lab VLAN,
# netfix restored the dead address, first boot called the site "ipv4-only",
# vmbr0 never took the RA, and the wizard could not resolve github.com.
set -u
cd "$(dirname "$(readlink -f "$0")")"
FB="${1:-firstboot-v3.sh}"
[ -f "$FB" ] || { echo "FATAL: no firstboot-v3.sh at $FB"; exit 1; }
pass=0; fail=0
ok(){  printf '  ✓ %s\n' "$1"; pass=$((pass+1)); }
bad(){ printf '  ✗ %s\n     %s\n' "$1" "$2"; fail=$((fail+1)); }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
python3 - "$FB" "$TMP/netfix.sh" <<'PYX'
import re, sys, pathlib
s = pathlib.Path(sys.argv[1]).read_text()
m = re.search(r"cat > /usr/local/sbin/sigmond-netfix <<'NETFIXEOF'\n(.*?)\nNETFIXEOF\n", s, re.S)
if not m: raise SystemExit("could not extract sigmond-netfix")
pathlib.Path(sys.argv[2]).write_text(m.group(1))
PYX
grep -vE '^[[:space:]]*#' "$TMP/netfix.sh" > "$TMP/code"
bash -n "$TMP/netfix.sh" && ok "netfix parses" || bad "netfix does not parse" ""

echo "── the no-lease branch asks the static gateway before restoring ───"
L_ping=$(grep -n 'ping -c2 -W1 -I vmbr0 "\$_st_gw"' "$TMP/code" | head -1 | cut -d: -f1)
L_v6=$(grep -n 'v6_uplink_on vmbr0; then' "$TMP/code" | head -1 | cut -d: -f1)
L_restore=$(grep -n 'restoring the static config' "$TMP/code" | head -1 | cut -d: -f1)
[ -n "$L_ping" ] && [ -n "$L_restore" ] && [ "$L_ping" -lt "$L_restore" ] \
    && ok "the gateway is pinged before the static stanza is restored" \
    || bad "no gateway check before the restore" "ping=$L_ping restore=$L_restore"
[ -n "$L_v6" ] && [ "$L_v6" -lt "$L_restore" ] \
    && ok "the IPv6 branch comes before the restore" \
    || bad "no IPv6 branch before the restore" "v6=$L_v6 restore=$L_restore"
grep -q '\[ "\$_gw_alive" = no \] && v6_uplink_on vmbr0' "$TMP/code" \
    && ok "IPv6-only needs BOTH a dead gateway and a live v6 uplink on vmbr0" \
    || bad "the IPv6-only decision is not gated on both" "a real static-IPv4 site could lose its address"
grep -q 'net.ipv6.conf.vmbr0.accept_ra=2' "$TMP/code" \
    && ok "accept_ra=2 is set so a forwarding bridge takes the RA" \
    || bad "accept_ra not raised" "vmbr0 ignores RAs at accept_ra=1 while forwarding"

echo "── what the IPv6 branch leaves behind ─────────────────────────────"
blk=$(awk '/\[ "\$_gw_alive" = no \] && v6_uplink_on vmbr0; then/{f=1} f{print} f&&/^            fi$/{exit}' "$TMP/code")
printf '%s' "$blk" | grep -q 'iface vmbr0 inet manual' && ok "no IPv4 method left to wait on at the next boot" || bad "the dhcp stanza is left in place" "next boot waits for a lease that cannot come"
printf '%s' "$blk" | grep -q 'iface vmbr0 inet6 auto' && ok "an inet6 auto stanza is written" || bad "no inet6 stanza" ""
printf '%s' "$blk" | grep -q 'ip -4 addr flush dev vmbr0' && ok "the dead IPv4 is removed (later 'do we have IPv4?' tests must say no)" || bad "the dead IPv4 stays" "first boot would call the site ipv4-only"
printf '%s' "$blk" | grep -q 'exit 0' && ok "the branch exits before the restore" || bad "falls through to the restore" ""

echo "── the helpers on a real stanza ───────────────────────────────────"
cat > "$TMP/ifaces" <<'IF'
auto lo
iface lo inet loopback

iface eno1 inet manual

auto vmbr0
iface vmbr0 inet static
	address 10.22.23.78/24
	gateway 10.22.23.1
	bridge-ports eno1
	bridge-stp off
	bridge-fd 0

iface vmbr1 inet static
	address 10.99.0.1/30
	gateway 10.99.0.9
IF
awk_addr=$(grep -o "_st_addr=\$(awk '[^']*'" "$TMP/code" | head -1 | sed "s/^_st_addr=\$(awk '//; s/'\$//")
awk_gw=$(grep -o "_st_gw=\$(awk '[^']*'" "$TMP/code" | head -1 | sed "s/^_st_gw=\$(awk '//; s/'\$//")
a=$(awk "$awk_addr" "$TMP/ifaces"); g=$(awk "$awk_gw" "$TMP/ifaces")
[ "$a" = 10.22.23.78/24 ] && ok "address read from vmbr0's stanza only ($a)" || bad "address parse" "got '$a'"
[ "$g" = 10.22.23.1 ] && ok "gateway read from vmbr0's stanza only, not vmbr1's ($g)" || bad "gateway parse" "got '$g'"
printf 'search local\nnameserver fd4f:a955:ac3d:1::1\nnameserver 10.22.23.1\nnameserver 10.22.23.10\n' > "$TMP/resolv"
_st_gw=10.22.23.1
sed "/^nameserver ${_st_gw//./\\.}\$/d" "$TMP/resolv" > "$TMP/resolv.new" && mv "$TMP/resolv.new" "$TMP/resolv"   # portable: no -i
grep -qx 'nameserver 10.22.23.1' "$TMP/resolv" && bad "the dead resolver stays" "" || ok "the dead LAN's resolver line is removed"
grep -qx 'nameserver 10.22.23.10' "$TMP/resolv" && ok "a different resolver (10.22.23.10) is kept" || bad "dots were not escaped" "10.22.23.10 removed too"

echo; echo "$pass passed, $fail failed"; [ "$fail" -eq 0 ]
