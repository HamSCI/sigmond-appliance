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
# ⛔ TAKE THE FILE UNDER TEST AS AN ARGUMENT.  This used to hardcode
# FB=firstboot-v3.sh after cd-ing to its own directory, so `./test-... /path/to/mutant`
# silently tested the REAL file instead -- and a mutation run came back all-green
# three times in a row while the mutations were real (2026-10-16).  A test that
# cannot be pointed at a mutant cannot be shown to work.
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

echo "── the conversion's own safety net must ask the RIGHT question ────"
# ⛔ AI6VN, 2026-10-15, v3.72.  The wait after converting vmbr0 to DHCP used
# cur_ip, which falls back to the global IPv6 address.  The bridge already
# held an RA address, so the very first iteration "succeeded": netfix logged
#     vmbr0 now takes DHCP; lease fd4f:a955:ac3d:1:8647:9ff:fe1b:29ee
# and skipped the restore -- the one safety net written to undo exactly this
# conversion.  /etc/network/interfaces was left saying `inet dhcp` on a site
# with no DHCPv4 server.  Nothing looked wrong until the next boot, when ifup
# waited out networking.service's 5-minute timeout; the host never reached the
# network, and with both USB controllers on vfio-pci there was no keyboard to
# rescue it.  It took the GRUB command line to get back in.
grep -q '_v4_lease' "$TMP/netfix.code" \
    && ok "the post-conversion wait has a dedicated IPv4 probe" \
    || bad "no IPv4-only probe after the conversion" \
           "cur_ip answers with an IPv6 address and the restore never runs"
grep -q 'NEW="\$(cur_ip)"' "$TMP/netfix.code" \
    && bad "the DHCP wait still uses cur_ip" \
           "an RA address satisfies it instantly; the static config is never restored" \
    || ok "the DHCP wait no longer accepts any-address-will-do"
# the probe itself must look only at IPv4, and must discount the installer fallback
_probe=$(sed -n '/_v4_lease()/,/^[[:space:]]*}/p;/_v4_lease(){/p' "$TMP/netfix.code" | head -3)
case "$_probe" in
  *"ip -4 "*) ok "the probe asks the kernel for IPv4 only" ;;
  *)          bad "the IPv4 probe does not restrict itself to -4" "$_probe" ;;
esac
case "$_probe" in
  *192\\.168\\.100\\.*|*'192\.168\.100\.'*) ok "and it discounts the installer's 192.168.100.x fallback" ;;
  *) bad "the probe counts the PVE installer fallback as a lease" \
         "that address answers nothing; it must not look like success" ;;
esac

echo "── and a bridge an OLDER netfix stranded gets repaired ────────────"
# Every image through v3.72 can leave this behind.  The fault is latent: the
# running system is fine, and it only bites at the next reboot.  So stations
# in the field are carrying it right now and nobody will know until a power
# cut. Repair on sight, while we can see the lease really is missing.
grep -q 'netfix-static-bak' "$TMP/netfix.code" \
    && ok "netfix knows about the static backup it writes" \
    || bad "no reference to the backup file" "there is then no way back"
_rep=$(grep -n 'is configured DHCP but holds no IPv4 lease' "$TMP/netfix.code" | head -1 | cut -d: -f1)
[ -n "$_rep" ] \
    && ok "there is a repair branch for an already-converted bridge (line $_rep)" \
    || bad "no repair branch" "an affected station stays armed until someone reboots it"
# ⛔ IT MUST RUN BEFORE THE REST OF NETFIX DECIDES ANYTHING.  Repairing after
# the de-fossilize branch has run would mean acting on a file we just rewrote.
_conv=$(grep -n 'converting to DHCP so it cannot fossilize' "$TMP/netfix.code" | head -1 | cut -d: -f1)
if [ -n "$_rep" ] && [ -n "$_conv" ] && [ "$_rep" -lt "$_conv" ]; then
    ok "the repair runs before the conversion branch"
else
    bad "the repair does not precede the conversion (repair=$_rep convert=$_conv)" \
        "it would judge a file netfix had already changed in this same run"
fi

echo "── behavioural: the repair fires only when it is safe ─────────────"
# ⛔ RUN THE SHIPPED CONDITION, NOT A RESTATEMENT OF IT.  The first version of
# this test re-evaluated the rule inline; deleting the real "holds no IPv4
# lease" test from firstboot-v3.sh then left every case GREEN (mutation B,
# 2026-10-16).  That is the guard that stops netfix renumbering a working DHCP
# site, so a test that cannot see it disappear is worse than no test at all.
# Lift the actual block and neutralise only its ACTIONS, keeping the decision.
mkdir -p "$TMP/rep"
sed -n "/^if grep -q .\^iface vmbr0 inet dhcp./,/^fi$/p" "$TMP/netfix.sh" > "$TMP/rep/block.sh"
grep -q 'netfix-static-bak' "$TMP/rep/block.sh" || { echo "FATAL: could not lift the repair condition"; exit 1; }
python3 - "$TMP/rep/block.sh" <<'PYR'
import sys, pathlib, re
p = pathlib.Path(sys.argv[1]); s = p.read_text()
# announce entry the instant the condition is satisfied...
s = s.replace("; then\n", "; then\n    echo REPAIR\n", 1)
# ...and make the body inert, so nothing is copied or reloaded for real.
out = []
for line in s.splitlines():
    st = line.strip()
    if st.startswith(("say ", "cp -a ", "reload_net")):
        line = "    :"
    out.append(line)
p.write_text("\n".join(out) + "\n")
PYR
bash -n "$TMP/rep/block.sh" || { echo "FATAL: lifted repair block does not parse"; exit 1; }
grep -q 'echo REPAIR' "$TMP/rep/block.sh" || { echo "FATAL: could not instrument the repair block"; exit 1; }

decide_repair(){   # $1=ifaces  $2=bak-path  $3=has_v4(yes|no) ; echoes REPAIR or SKIP
  (
    IFACES="$1"; HAS_V4="$3"
    # the shipped condition reads "$IFACES.netfix-static-bak", so place the
    # backup exactly where the real code will look for it
    rm -f "$IFACES.netfix-static-bak"
    [ -e "$2" ] && cp -a "$2" "$IFACES.netfix-static-bak"
    ip(){ case "$*" in
            *"-4 -o addr show vmbr0"*) [ "$HAS_V4" = yes ] && echo "2: vmbr0    inet 10.0.0.5/24 brd 10.0.0.255 scope global vmbr0" ;;
          esac; }
    say(){ :; }; reload_net(){ :; }
    r=$( . "$TMP/rep/block.sh" 2>/dev/null )
    case "$r" in *REPAIR*) echo REPAIR ;; *) echo SKIP ;; esac
  )
}
printf 'iface vmbr0 inet dhcp\n    bridge-ports enp1s0\n\n' > "$TMP/rep/ifaces"
printf 'iface vmbr0 inet static\n    address 10.0.0.5/24\n    gateway 10.0.0.1\n    bridge-ports enp1s0\n\n' > "$TMP/rep/bak"
[ "$(decide_repair "$TMP/rep/ifaces" "$TMP/rep/bak" no)" = REPAIR ] \
    && ok "AI6VN's case (dhcp stanza, no lease, static backup) -> REPAIR" \
    || bad "a stranded bridge is not repaired" "this is the boot that cannot finish"
[ "$(decide_repair "$TMP/rep/ifaces" "$TMP/rep/bak" yes)" = SKIP ] \
    && ok "a bridge that DOES hold a lease is left alone (the null)" \
    || bad "it would renumber a working DHCP site" "that is the one thing netfix must never do"
printf 'iface vmbr0 inet static\n    bridge-ports enp1s0\n\n' > "$TMP/rep/bak_noaddr"
[ "$(decide_repair "$TMP/rep/ifaces" "$TMP/rep/bak_noaddr" no)" = SKIP ] \
    && ok "a backup with no address is not restored" "" \
    || bad "it restored an addressless stanza" "that leaves the bridge no better off"
[ "$(decide_repair "$TMP/rep/ifaces" "/nonexistent-backup" no)" = SKIP ] \
    && ok "no backup -> nothing to restore, and it says so rather than guessing" \
    || bad "it acted with no backup present" "there is nothing to restore from"

echo "── networking.service must not be able to strand the host ─────────"
# A kernel-cmdline systemd.default_timeout_start_sec cannot save this: the
# unit carries its own TimeoutStartSec and an explicit value beats the
# default.  Capping it is what turns "drive to the site" into "fix it over
# RAC" -- the bridge still comes up and still takes its RA address.
grep -q 'networking.service.d/10-sigmond-timeout.conf' "$FB" \
    && ok "firstboot ships a networking.service timeout drop-in" \
    || bad "no networking.service drop-in" \
           "one bad word in /etc/network/interfaces costs 5 minutes and the whole machine"
_nt=$(awk '/networking.service.d\/10-sigmond-timeout.conf <</,/^NETTOEOF$/' "$FB" \
      | grep -E '^TimeoutStartSec=' | tail -1 | cut -d= -f2)
case "$_nt" in *min) _nts=$(( ${_nt%min} * 60 ));; *s) _nts=${_nt%s};; *) _nts=$_nt;; esac
if [ -n "$_nts" ] && [ "$_nts" -le 60 ] && [ "$_nts" -ge 20 ]; then
    ok "networking.service start timeout is $_nt — past a healthy ifup, short of stranding"
else
    bad "networking.service timeout is ${_nt:-unset}" \
        "5min is what made AI6VN unreachable; under 20s would cut off a slow but healthy ifup"
fi

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
