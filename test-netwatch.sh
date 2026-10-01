#!/bin/bash
# test-netwatch.sh — sigmond-netwatch heals a DEAD uplink and never touches a live one.
#
# ⛔ WHY THIS EXISTS.  sigmond-netfix ran ONCE, at boot, and nothing re-ran it:
# no timer, no udev rule.  Every network fault was therefore permanent until
# somebody power-cycled the machine -- and this host has NO keyboard (both USB
# controllers are vfio-pci for the decoder VM; `lsusb` returns nothing), so
# there is no local recovery at all.  rob, 2026-10-01: "I don't really
# understand how I could manually execute this if I lost connection ...
# shouldn't there be some background polling."
#
# ⛔ THE DANGEROUS HALF IS THE ONE THAT DOES NOTHING.  A watchdog that switches
# a WORKING uplink can strand a station nobody can reach, and will flap between
# two marginal links forever.  So the contract is asymmetric on purpose:
#   dead uplink  -> run netfix (it cannot make a dead link worse)
#   live uplink  -> NEVER run netfix, no matter what else appears
# Most of the assertions below exist to hold that second line down.  If someone
# "improves" this into an auto-switcher, test_live_* are what should stop them.
#
#   usage: ./test-netwatch.sh [path/to/firstboot-v3.sh]
set -u
SRC="${1:-$(dirname "$0")/firstboot-v3.sh}"
[ -f "$SRC" ] || { echo "FATAL: no firstboot-v3.sh at $SRC"; exit 1; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
chk(){ # chk <desc> <got> <want>
    if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ok    %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAIL  %s\n        want: %s\n        got : %s\n' "$1" "$3" "$2"; fi; }

# ── extract the script exactly as firstboot writes it ───────────────────────
awk "/^cat > \/usr\/local\/sbin\/sigmond-netwatch <<'NETWATCHEOF'\$/,/^NETWATCHEOF\$/" "$SRC" \
    | sed '1d;$d' > "$WORK/sigmond-netwatch"
chmod +x "$WORK/sigmond-netwatch"
[ -s "$WORK/sigmond-netwatch" ] || { echo "FATAL: could not extract sigmond-netwatch from $SRC"; exit 1; }
bash -n "$WORK/sigmond-netwatch" || { echo "FATAL: extracted script does not parse"; exit 1; }

# ── fakes ───────────────────────────────────────────────────────────────────
# usable_gw4 is the real decision input; the lib is faked so the test drives it.
mkdir -p "$WORK/bin" "$WORK/state" "$WORK/sysnet"
cat > "$WORK/netlib.sh" <<'LIB'
usable_gw4(){ [ -n "${FAKE_GW4:-}" ] && printf '%s\n' "$FAKE_GW4"; }
LIB

# ping answers according to FAKE_PING4 / FAKE_PING6 -- "has a route" and "the
# next hop answers" are different questions and this test keeps them separate.
cat > "$WORK/bin/ping" <<'PING'
#!/bin/bash
for a in "$@"; do [ "$a" = "-6" ] && { [ "${FAKE_PING6:-0}" = 1 ]; exit $?; }; done
[ "${FAKE_PING4:-0}" = 1 ]
PING

cat > "$WORK/bin/ip" <<'IP'
#!/bin/bash
case "$*" in
  *"-6 route show default"*) printf '%s\n' "${FAKE_V6ROUTE:-}" ;;
  *) : ;;
esac
IP

# systemctl records what it was asked to start -- the whole point of the test.
cat > "$WORK/bin/systemctl" <<'SC'
#!/bin/bash
printf '%s\n' "$*" >> "$SC_CALLS"
SC
chmod +x "$WORK/bin/ping" "$WORK/bin/ip" "$WORK/bin/systemctl"

nic(){ # nic <name> [wireless] -- a NIC with a cable in it
    mkdir -p "$WORK/sysnet/$1"; : > "$WORK/sysnet/$1/device"; echo "${2:-1}" > "$WORK/sysnet/$1/carrier"
    [ "${3:-}" = "wireless" ] && : > "$WORK/sysnet/$1/wireless"; return 0; }

run(){ # run -> stdout: the systemctl calls this tick made
    : > "$WORK/calls"
    PATH="$WORK/bin:$PATH" SC_CALLS="$WORK/calls" \
    SIGMOND_NETLIB="$WORK/netlib.sh" SIGMOND_SYSNET="$WORK/sysnet" \
    SIGMOND_NETWATCH_STATE="$WORK/state" SIGMOND_NETWATCH_LOG="$WORK/log" \
    SIGMOND_NETWATCH_COOLDOWN="${CD:-900}" \
    FAKE_GW4="${FAKE_GW4:-}" FAKE_PING4="${FAKE_PING4:-0}" \
    FAKE_PING6="${FAKE_PING6:-0}" FAKE_V6ROUTE="${FAKE_V6ROUTE:-}" \
        bash "$WORK/sigmond-netwatch"
    grep -c 'start .*sigmond-netfix' "$WORK/calls" 2>/dev/null | tr -d ' '; }

reset(){ rm -rf "$WORK/state" "$WORK/sysnet" "$WORK/log"; mkdir -p "$WORK/state" "$WORK/sysnet"
         unset FAKE_GW4 FAKE_PING4 FAKE_PING6 FAKE_V6ROUTE; }

echo "── a LIVE uplink is never touched ─────────────────────────────────────"
reset; export FAKE_GW4=192.168.1.1 FAKE_PING4=1
chk "IPv4 gateway answers -> no netfix"        "$(run)$(run)$(run)$(run)" "0000"

reset; export FAKE_V6ROUTE="default via fe80::1 dev wlp3s0 proto ra metric 1024" FAKE_PING6=1
chk "IPv6-only, router answers -> no netfix"   "$(run)$(run)$(run)$(run)" "0000"

# ⛔ The auto-switcher guard.  A cable appearing beside a WORKING link must
# change nothing: this is the case that strands a station if someone makes it
# act.  (It is also exactly rob's lab box when he plugs the cable back in.)
reset; export FAKE_V6ROUTE="default via fe80::1 dev wlp3s0 proto ra metric 1024" FAKE_PING6=1
nic enp1s0 1; nic wlp3s0 1 wireless
chk "cable appears beside a LIVE link -> still no netfix" "$(run)$(run)$(run)$(run)" "0000"
chk "  ...but it IS advertised to the panel"   "$(cat "$WORK/state/cable-available" 2>/dev/null)" "enp1s0"

echo "── a DEAD uplink is healed, but not instantly ─────────────────────────"
reset   # no gw4, no v6 route, nothing answers
chk "tick 1 of 3 -> no netfix yet"             "$(run)" "0"
chk "tick 2 of 3 -> no netfix yet"             "$(run)" "0"
chk "tick 3 of 3 -> netfix RUNS"               "$(run)" "1"

# ⛔ THE COOLDOWN MUST BE THE DECIDING FACTOR, not shadowed by something else.
# A single "tick 4 -> no netfix" assertion looks like it tests the cooldown and
# does not: running netfix CLEARS the failure counter, so ticks 4 and 5 are
# below threshold for that reason alone and the cooldown never decides
# anything.  Deleting the cooldown outright passed the entire suite (mutation
# M3, 2026-10-01).  Only at tick 6 does the threshold pass again -- that is the
# first tick where the cooldown is what says no.
chk "ticks 4-5 below threshold again"          "$(run)$(run)" "00"
chk "tick 6: threshold met, COOLDOWN says no"  "$(run)" "0"
CD=0
chk "cooldown expired -> heals again"          "$(run)" "1"
unset CD

# ⛔ A route with no answer is NOT an uplink.  This is the usable_gw4 lesson
# again: the fossil 192.168.100.1 is "a default route" and answers nothing.
reset; export FAKE_GW4=192.168.100.1 FAKE_PING4=0
chk "gateway configured but DEAD -> heals"     "$(run)$(run)$(run)" "001"

echo "── recovery resets the counter ────────────────────────────────────────"
reset
run >/dev/null; run >/dev/null                       # two failures banked
export FAKE_GW4=192.168.1.1 FAKE_PING4=1
chk "recovery clears the failure count"        "$(run)" "0"
export FAKE_PING4=0
chk "  ...so the next outage starts from 1 again" "$(run)$(run)" "00"

echo "── it refuses to guess ────────────────────────────────────────────────"
reset
mv "$WORK/netlib.sh" "$WORK/netlib.hidden"
chk "no shared net lib -> does nothing at all"  "$(run)$(run)$(run)$(run)" "0000"
mv "$WORK/netlib.hidden" "$WORK/netlib.sh"

echo "── the panel is repainted on CHANGE, not every tick ───────────────────"
# ⛔ Polling faster is not the fix; an unconditional repaint buries the console.
reset; nic enp1s0 1
run >/dev/null                                       # first sight of the cable
chk "cable appears -> panel repainted once"    "$(grep -c 'start .*sigmond-issue' "$WORK/calls" | tr -d ' ')" "1"
run >/dev/null
chk "cable still there -> NOT repainted again" "$(grep -c 'start .*sigmond-issue' "$WORK/calls" | tr -d ' ')" "0"
echo 0 > "$WORK/sysnet/enp1s0/carrier"
run >/dev/null
chk "cable removed -> repainted once"          "$(grep -c 'start .*sigmond-issue' "$WORK/calls" | tr -d ' ')" "1"

echo "── a radio is not a cable ─────────────────────────────────────────────"
reset; nic wlp3s0 1 wireless
run >/dev/null
chk "associated Wi-Fi is not advertised as a cable" \
    "$(cat "$WORK/state/cable-available" 2>/dev/null)" ""

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
