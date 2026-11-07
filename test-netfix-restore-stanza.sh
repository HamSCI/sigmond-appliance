#!/bin/bash
# test-netfix-restore-stanza.sh — restoring vmbr0 must not restore anything else.
#
# KPH1-PM 2026-11-07: vmbr1 lost, VM never started.  netfix's static backup of
# /etc/network/interfaces was written at 20:49Z; the appliance installer
# appended the host-only vmbr1 (10.99.0.1/30 + post-up MASQUERADE) at ~20:55Z.
# At the 21:03Z boot the USB NIC vmbr0 bridged was missing, the "older netfix
# stranded it" repair fired and did
#     cp -a "$IFACES.netfix-static-bak" "$IFACES"
# -- restoring the 20:49 file wholesale and deleting vmbr1.  Every VM start
# then failed with "bridge 'vmbr1' does not exist".
#
# This lifts the SHIPPED restore_vmbr0_stanza out of firstboot-v3.sh and runs
# it against that exact pair of files.
set -u
# ⛔ TAKE THE FILE UNDER TEST AS AN ARGUMENT, so a mutant can be pointed at.
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
[ -s "$TMP/netfix.sh" ] || { echo "FATAL: extraction failed"; exit 1; }
code(){ grep -vE '^[[:space:]]*#' "$1"; }     # assert against code, not comments
code "$TMP/netfix.sh" > "$TMP/netfix.code"

echo "── no whole-file restore of the static backup remains ─────────────"
if grep -nE 'cp[[:space:]].*netfix-static-bak"?[[:space:]]+"?\$IFACES"?([[:space:];]|$)' "$TMP/netfix.code"; then
    bad "netfix still copies the whole backup over the live file" \
        "that is the line that deleted vmbr1 on KPH1-PM"
else
    ok "no 'cp ... netfix-static-bak \$IFACES' in netfix's code"
fi
n=$(grep -c 'restore_vmbr0_stanza "\$IFACES.netfix-static-bak" "\$IFACES"' "$TMP/netfix.code")
[ "$n" -ge 2 ] \
    && ok "both restore paths go through restore_vmbr0_stanza ($n call sites)" \
    || bad "only $n restore path(s) use restore_vmbr0_stanza" "expected the repair AND the no-lease rollback"
grep -q 'netfix-dhcp-bak' "$TMP/netfix.code" \
    && ok "the .netfix-dhcp-bak safety copy is still taken" \
    || bad "no .netfix-dhcp-bak copy" "the pre-restore file must survive somewhere"

echo "── lift the shipped function ──────────────────────────────────────"
sed -n "/^_ifaces_stanza_awk='/,/^restore_vmbr0_stanza(){/p" "$TMP/netfix.sh" > "$TMP/fn.sh"
sed -n '/^restore_vmbr0_stanza(){/,/^}$/p' "$TMP/netfix.sh" | sed 1d >> "$TMP/fn.sh"
grep -q '^restore_vmbr0_stanza(){' "$TMP/fn.sh" && grep -q '^stanza_of(){' "$TMP/fn.sh" \
    || { echo "FATAL: could not lift restore_vmbr0_stanza"; exit 1; }
bash -n "$TMP/fn.sh" || { echo "FATAL: lifted function does not parse"; exit 1; }
SAYLOG="$TMP/say.log"
say(){ echo "$*" >> "$SAYLOG"; }
. "$TMP/fn.sh"

# KPH1-PM's live file at 21:03Z: vmbr0 converted to dhcp, vmbr1 appended after.
cat > "$TMP/cur" <<'EOF'
auto lo
iface lo inet loopback

iface enxa0cec8077b4d inet manual

auto vmbr0
iface vmbr0 inet dhcp
	bridge-ports enxa0cec8077b4d
	bridge-stp off
	bridge-fd 0

source /etc/network/interfaces.d/*

# Host-only management bridge for the decoder VM (sigmond-appliance).
# No physical port and no DHCP: the VM's address must not depend on the site
# network.  This host is its only route out -- see the post-up rules.
auto vmbr1
iface vmbr1 inet static
    address 10.99.0.1/30
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up sysctl -q -w net.ipv4.ip_forward=1
    post-up iptables -t nat -C POSTROUTING -s 10.99.0.0/30 -o vmbr0 -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 10.99.0.0/30 -o vmbr0 -j MASQUERADE
    # ⛔ AND out the CLAT.  On an IPv6-only site vmbr0 has NO IPv4 address, so

    post-up iptables -t nat -C POSTROUTING -s 10.99.0.0/30 -o clat -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 10.99.0.0/30 -o clat -j MASQUERADE
EOF
# The 20:49Z backup: static vmbr0 on the same port, no vmbr1.
cat > "$TMP/bak" <<'EOF'
auto lo
iface lo inet loopback

iface enxa0cec8077b4d inet manual

auto vmbr0
iface vmbr0 inet static
	address 10.14.70.11/24
	gateway 10.14.70.1
	bridge-ports enxa0cec8077b4d
	bridge-stp off
	bridge-fd 0

source /etc/network/interfaces.d/*
EOF

echo "── KPH1-PM: dhcp vmbr0 + vmbr1, static backup without vmbr1 ───────"
cp "$TMP/cur" "$TMP/t1"
if restore_vmbr0_stanza "$TMP/bak" "$TMP/t1"; then ok "restore returned success"
else bad "restore returned failure" "$(cat "$TMP/t1")"; fi
grep -q '^iface vmbr0 inet static' "$TMP/t1" \
    && ok "vmbr0 is static again" || bad "vmbr0 is not static" "$(cat "$TMP/t1")"
grep -qE '^[[:space:]]+address 10\.14\.70\.11/24' "$TMP/t1" \
    && grep -qE '^[[:space:]]+gateway 10\.14\.70\.1$' "$TMP/t1" \
    && ok "vmbr0 has 10.14.70.11/24 via 10.14.70.1" || bad "vmbr0 address/gateway missing" "$(cat "$TMP/t1")"
grep -q 'inet dhcp' "$TMP/t1" \
    && bad "a dhcp vmbr0 stanza survived" "$(cat "$TMP/t1")" || ok "no dhcp stanza left behind"
[ "$(grep -c '^iface vmbr0' "$TMP/t1")" = 1 ] && [ "$(grep -c '^auto vmbr0' "$TMP/t1")" = 1 ] \
    && ok "exactly one auto vmbr0 / iface vmbr0" || bad "duplicate or missing vmbr0 headers" "$(cat "$TMP/t1")"
grep -q '^iface vmbr1 inet static' "$TMP/t1" && grep -q '^auto vmbr1' "$TMP/t1" \
    && ok "vmbr1 is still present" || bad "vmbr1 is GONE" "this is KPH1-PM: the VM can never start"
[ "$(grep -c 'post-up iptables -t nat.*MASQUERADE' "$TMP/t1")" = 2 ] \
    && ok "both vmbr1 MASQUERADE post-up lines survive" || bad "vmbr1's post-up lines were lost" "$(cat "$TMP/t1")"
grep -q 'post-up sysctl -q -w net.ipv4.ip_forward=1' "$TMP/t1" \
    && ok "vmbr1's ip_forward post-up survives" || bad "ip_forward post-up lost" ""
grep -q '^# Host-only management bridge' "$TMP/t1" \
    && ok "vmbr1's leading comment block survives" || bad "vmbr1's comment was eaten" "$(cat "$TMP/t1")"
grep -q '^source /etc/network/interfaces.d/\*' "$TMP/t1" \
    && ok "the source line survives" || bad "source line lost" ""
[ "$(grep -c '^iface enxa0cec8077b4d inet manual' "$TMP/t1")" = 1 ] \
    && ok "the port's inet manual stanza is present once" || bad "port stanza missing or duplicated" "$(cat "$TMP/t1")"
# Everything outside vmbr0's stanza must be byte-identical to the live file.
strip0(){ awk '/^(auto|iface)[ \t]+vmbr0([ \t]|$)/{s=1;next} /^[^ \t]/{s=0} !s' "$1" | grep -v '^[[:space:]]*$'; }
if diff <(strip0 "$TMP/cur") <(strip0 "$TMP/t1") >/dev/null; then
    ok "every non-vmbr0 line is unchanged"
else
    bad "lines outside vmbr0 changed" "$(diff <(strip0 "$TMP/cur") <(strip0 "$TMP/t1"))"
fi
if command -v ifquery >/dev/null 2>&1; then
    ifquery -i "$TMP/t1" vmbr1 >/dev/null 2>&1 && ok "ifquery parses vmbr1 in the result" \
        || bad "ifquery cannot parse vmbr1 in the result" "$(ifquery -i "$TMP/t1" vmbr1 2>&1)"
fi
# A second run is a no-op: the function is idempotent.
cp "$TMP/t1" "$TMP/t1b"; restore_vmbr0_stanza "$TMP/bak" "$TMP/t1b"
diff -q "$TMP/t1" "$TMP/t1b" >/dev/null \
    && ok "restoring twice changes nothing" || bad "not idempotent" "$(diff "$TMP/t1" "$TMP/t1b")"

echo "── vmbr0 after vmbr1, and the port stanza missing from the live file"
cat > "$TMP/cur2" <<'EOF'
auto lo
iface lo inet loopback

auto vmbr1
iface vmbr1 inet static
    address 10.99.0.1/30
    bridge-ports none
    post-up iptables -t nat -A POSTROUTING -s 10.99.0.0/30 -o vmbr0 -j MASQUERADE

auto vmbr9
iface vmbr9 inet manual
    bridge-ports none

auto vmbr0
iface vmbr0 inet dhcp
	bridge-ports enp1s0
	bridge-stp off
	bridge-fd 0
EOF
cp "$TMP/cur2" "$TMP/t2"
restore_vmbr0_stanza "$TMP/bak" "$TMP/t2"
grep -q '^iface vmbr0 inet static' "$TMP/t2" && grep -q '^iface vmbr1 inet static' "$TMP/t2" \
    && grep -q '^iface vmbr9 inet manual' "$TMP/t2" \
    && ok "vmbr0 static, vmbr1 and vmbr9 kept when vmbr0 is the LAST stanza" \
    || bad "trailing-stanza case broken" "$(cat "$TMP/t2")"
grep -q '^iface enxa0cec8077b4d inet manual' "$TMP/t2" \
    && ok "the backup's bridge-port stanza is brought along when the live file lacks it" \
    || bad "bridge-port iface X inet manual not restored" "$(cat "$TMP/t2")"

echo "── refuses, and leaves the file alone, when the backup has no vmbr0"
printf 'auto lo\niface lo inet loopback\n' > "$TMP/bak_none"
cp "$TMP/cur" "$TMP/t3"
if restore_vmbr0_stanza "$TMP/bak_none" "$TMP/t3"; then
    bad "it claimed success with no vmbr0 in the backup" ""
else
    ok "returns failure"
fi
cmp -s "$TMP/cur" "$TMP/t3" && ok "the live file is untouched" || bad "the live file changed" "$(diff "$TMP/cur" "$TMP/t3")"

echo "── belt and braces: vmbr1 comes back even if the splice drops it ──"
# Simulate a mis-parse: break the splice so a vmbr0 stanza never ends (hdr()
# only recognises vmbr0's own headers), which swallows everything after it --
# vmbr1 included.  The guard must notice and put vmbr1 back.
(
  . "$TMP/fn.sh"
  _ifaces_stanza_awk='
function mine(l) { return l ~ ("^(auto|allow-[^ \t]+)[ \t]+" N "[ \t]*$") || l ~ ("^iface[ \t]+" N "[ \t]") }
function hdr(l)  { return mine(l) }
'
  cp "$TMP/cur" "$TMP/t4"; : > "$SAYLOG"
  restore_vmbr0_stanza "$TMP/bak" "$TMP/t4" >/dev/null 2>&1
  grep -q '^iface vmbr1 inet static' "$TMP/t4" && echo HAS_VMBR1
  grep -q 'dropped vmbr1' "$SAYLOG" && echo GUARD_FIRED
) > "$TMP/t4.out"
grep -q GUARD_FIRED "$TMP/t4.out" \
    && ok "with a broken splice the vmbr1 guard fires" \
    || bad "the guard did not fire on a broken splice" "(mutation did not drop vmbr1, or guard missing)"
grep -q HAS_VMBR1 "$TMP/t4.out" \
    && ok "and vmbr1 is in the result regardless" || bad "vmbr1 lost despite the guard" ""

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
