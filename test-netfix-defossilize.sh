#!/bin/bash
# test-netfix-defossilize.sh — never wait for a DHCP lease on a bridge that
# has no cable in it.
#
# AI6VN, first v3.71 boot, 2026-10-15. From its own journal:
#
#   01:56:13 [netfix] a saved Wi-Fi profile exists but the radio has no address
#   01:56:17 [netfix] Wi-Fi uplink is live: wlp3s0 fd4f:a955:ac3d:2:...
#   01:56:17 [netfix] vmbr0 has fd4f:... but is configured STATIC — converting
#                     to DHCP so it cannot fossilize
#            dhclient: timeout failed to detect new ip addresses
#   02:01:17 start operation timed out. Terminating.   (5 min 0.138 s, FAILED)
#            3 dhclient processes left running after the unit stopped
#
# vmbr0's port is enp1s0 — the UNPLUGGED wired NIC. The uplink was the Wi-Fi
# radio, which netfix had just brought up correctly in 4 seconds and which held
# the default route. There was never a DHCP server that could answer on that
# bridge.
#
# netfix is ordered before the rest of boot, so the console held the stock
# Proxmox banner — the hypervisor's address, an unusable login prompt — for
# that entire time. rob: "it looks like it's hung ... users aren't gonna
# tolerate that, that system looks like it was dead."
#
# De-fossilizing is still right when there IS a cable: the PVE installer writes
# a static stanza even when its own DHCP succeeded, and that address outlives
# the site. The rule is about carrier, not about turning the feature off.
set -u
cd "$(dirname "$(readlink -f "$0")")"
FB=firstboot-v3.sh
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

echo "── the guard exists and is keyed on CARRIER ───────────────────────"
grep -q 'class/net/\$_defoss_port/carrier' "$TMP/netfix.code" \
    && ok "de-fossilize reads the bridge port's carrier" \
    || bad "no carrier check before de-fossilize" \
           "a cable-less bridge is converted and waits out the unit timeout"

echo "── it runs BEFORE the conversion, not after ───────────────────────"
g=$(grep -n '_defoss_port/carrier' "$TMP/netfix.code" | head -1 | cut -d: -f1)
c=$(grep -n 'converting to DHCP so it cannot fossilize' "$TMP/netfix.code" | head -1 | cut -d: -f1)
if [ -n "$g" ] && [ -n "$c" ] && [ "$g" -lt "$c" ]; then
    ok "carrier is checked at line $g, before the conversion at line $c"
else
    bad "the guard does not precede the conversion (guard=$g convert=$c)" \
        "checking after the rewrite is no guard at all"
fi

echo "── behavioural: the decision itself ───────────────────────────────"
# Lift the exact condition out of the script and exercise it against a fake
# sysfs, so this tests the shipped expression rather than a restatement.
mk(){ mkdir -p "$TMP/sys/class/net/$1"; printf '%s\n' "$2" > "$TMP/sys/class/net/$1/carrier"; }
mk enp1s0 0      # unplugged  — AI6VN
mk enp2s0 1      # plugged in — a normal wired station
cat > "$TMP/ifaces" <<'EOF'
iface vmbr0 inet static
    address 10.0.0.5/24
    bridge-ports enp1s0

EOF
# ⛔ RUN THE SHIPPED EXPRESSION, NOT A RESTATEMENT OF IT.  This used to be a
# hand-written copy of the condition, so INVERTING the real one in
# firstboot-v3.sh left every case green (mutation, 2026-10-15). Lift the actual
# lines out of the extracted script and evaluate those.
sed -n '/_defoss_port=\$(awk/,/^        fi$/p' "$TMP/netfix.sh" \
  | sed -e 's#/sys/class/net#'"$TMP"'/sys/class/net#' \
        -e 's/^        //' -e '/^say /d' -e 's/^say .*//' > "$TMP/cond.sh"
grep -q '_defoss_port' "$TMP/cond.sh" || { echo "FATAL: could not lift the condition"; exit 1; }
decide(){   # $1 = ifaces file; echoes SKIP or CONVERT
  local IFACES="$1"
  say(){ :; }
  ( set +e; . "$TMP/cond.sh" >/dev/null 2>&1; echo CONVERT ) | tail -1 | grep -q CONVERT \
    && echo CONVERT || echo SKIP
}
[ "$(decide "$TMP/ifaces")" = SKIP ] \
    && ok "AI6VN's case (port enp1s0, no carrier) -> SKIP, instantly" \
    || bad "a cable-less bridge still converts" "this is the 5-minute stall"

sed -i 's/bridge-ports enp1s0/bridge-ports enp2s0/' "$TMP/ifaces"
[ "$(decide "$TMP/ifaces")" = CONVERT ] \
    && ok "a bridge WITH carrier still de-fossilizes (the null)" \
    || bad "a live wired bridge no longer de-fossilizes" \
           "that would re-open the static-fossilization bug the nested test catches"

sed -i 's/bridge-ports enp2s0/bridge-ports none/' "$TMP/ifaces"
[ "$(decide "$TMP/ifaces")" = CONVERT ] \
    && ok "bridge-ports none is not treated as 'no carrier'" \
    || bad "a portless bridge is skipped" "that is a different case and not ours to judge here"

echo "── the unit can no longer hold boot for five minutes ──────────────"
# ⛔ SCOPE TO THE UNIT.  firstboot-v3.sh defines many units; an unscoped grep
# finds some OTHER unit's key and passes while netfix is unbounded. Verified by
# mutation 2026-10-15: deleting netfix's timeout left netwatch's identical line
# and the test stayed green.
n=$(grep -n 'sigmond-netfix.service <<' "$FB" | cut -d: -f1)
e=$(awk -v s="$n" 'NR>s && /^NFSVCEOF$/{print NR; exit}' "$FB")
unit(){ sed -n "${n},${e}p" "$FB"; }

cnt=$(unit | grep -cE '^TimeoutStartSec=')
t=$(unit | grep -E '^TimeoutStartSec=' | tail -1 | cut -d= -f2)   # systemd takes the LAST
case "$t" in *min) tsec=$(( ${t%min} * 60 ));; *s) tsec=${t%s};; *) tsec=$t;; esac
if [ "$cnt" -eq 1 ] && [ -n "$tsec" ] && [ "$tsec" -le 120 ]; then
    ok "netfix TimeoutStartSec=$t, and it is the ONLY one in the unit"
elif [ "$cnt" -gt 1 ]; then
    bad "netfix declares TimeoutStartSec $cnt times (effective: $t)" \
        "systemd takes the LAST — a duplicate silently made this fix a no-op once already"
else
    bad "netfix start timeout is ${t:-unset}" \
        "any hang holds the console for that long; the console is the symptom"
fi

echo "── and the lease-keeping design is untouched ──────────────────────"
unit | grep -q '^KillMode=process' \
    && ok "KillMode=process still set ON NETFIX (dhclient must outlive the unit)" \
    || bad "netfix lost KillMode=process" \
           "the lease dies ~20 min later and the host silently loses IPv4"

echo "── an IPv6 address is not fossilized ──────────────────────────────"
# cur_ip() reports IPv6 when that is all the host has. AI6VN's vmbr0 held
# fd4f:a955:ac3d:1:... from RA — the router refreshes it, so there is nothing
# for `iface ... inet dhcp` to repair, and dhclient has no server to ask.
grep -q '\*:\*)' "$TMP/netfix.code" \
    && ok "the branch skips on an IPv6 address" \
    || bad "no IPv6 guard" \
           "an RA address triggers a DHCP conversion with no server to answer"

echo "── and only when vmbr0 actually carries the default route ─────────"
grep -q '_defoss_rt' "$TMP/netfix.code" \
    && ok "the branch consults the default route before converting" \
    || bad "no uplink guard" \
           "a DASI station runs cable-free on purpose; vmbr0 is often not the uplink"
# all three guards must sit BEFORE the conversion
cv=$(grep -n 'converting to DHCP so it cannot fossilize' "$TMP/netfix.code" | head -1 | cut -d: -f1)
for g in '_defoss_port/carrier' '\*:\*)' '_defoss_rt'; do
  gl=$(grep -n "$g" "$TMP/netfix.code" | head -1 | cut -d: -f1)
  if [ -n "$gl" ] && [ -n "$cv" ] && [ "$gl" -lt "$cv" ]; then
      ok "guard '$g' is at line $gl, before the conversion at $cv"
  else
      bad "guard '$g' does not precede the conversion (g=$gl conv=$cv)" \
          "a guard after the rewrite is no guard"
  fi
done

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
