#!/bin/bash
# test-prefer-wired.sh — on a dual-homed host the CABLE must win, and the
# radio must survive as a fallback.
#
# ⛔ WHY THIS EXISTS.  AI6VN, 2026-10-15.  The host had a cable and an
# associated radio, each taking a global address and a default route from its
# own router.  Both routers advertise `pref medium`, so the kernel installed
# BOTH default routes at metric 1024 -- a dead tie it then breaks arbitrarily.
# The radio won.  Nothing was misconfigured; the station simply had no basis
# to prefer either.  rob: "it should be choosing the wired interface as its
# preferred route."
#
# ⛔ THE DANGEROUS HALF IS THE ONE THAT ACTS.  Most DASI stations run
# cable-free on purpose.  Demoting the radio's default route there would
# strand a station nobody can reach, so the guard -- act ONLY when both
# carriers are really up -- is the assertion that matters most here.  The
# second is that we never reach for accept_ra_defrtr=0, which also makes
# wired win but by DELETING the fallback.
#
#   usage: ./test-prefer-wired.sh [path/to/firstboot-v3.sh]
set -u
SRC="${1:-$(dirname "$0")/firstboot-v3.sh}"
[ -f "$SRC" ] || { echo "FATAL: no firstboot-v3.sh at $SRC"; exit 1; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
chk(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ok    %s\n' "$1"
       else FAIL=$((FAIL+1)); printf '  FAIL  %s\n        want: %s\n        got : %s\n' "$1" "$3" "$2"; fi; }
has(){ case "$2" in *"$3"*) PASS=$((PASS+1)); printf '  ok    %s\n' "$1";;
       *) FAIL=$((FAIL+1)); printf '  FAIL  %s\n        missing: %s\n' "$1" "$3";; esac; }
lacks(){ case "$2" in *"$3"*) FAIL=$((FAIL+1)); printf '  FAIL  %s\n        present: %s\n' "$1" "$3";;
       *) PASS=$((PASS+1)); printf '  ok    %s\n' "$1";; esac; }

# ── extract exactly what firstboot writes ───────────────────────────────────
awk "/^cat > \/usr\/local\/sbin\/sigmond-prefer-wired <<'PWEOF'\$/,/^PWEOF\$/" "$SRC" \
    | sed '1d;$d' > "$WORK/sigmond-prefer-wired"
[ -s "$WORK/sigmond-prefer-wired" ] || { echo "FATAL: could not extract sigmond-prefer-wired"; exit 1; }
bash -n "$WORK/sigmond-prefer-wired" || { echo "FATAL: extracted script does not parse"; exit 1; }

UNIT=$(awk "/^cat > \/etc\/systemd\/system\/sigmond-prefer-wired.service <<'PWSVCEOF'\$/,/^PWSVCEOF\$/" "$SRC" | sed '1d;$d')

# ── fakes ───────────────────────────────────────────────────────────────────
mkdir -p "$WORK/bin"
for t in sysctl ip rdisc6 logger; do
    cat > "$WORK/bin/$t" <<EOF
#!/bin/bash
printf '$t %s\n' "\$*" >> "\$CALLS"
EOF
    chmod +x "$WORK/bin/$t"
done
# ip must still answer the route query the script ends with
cat > "$WORK/bin/ip" <<'IPEOF'
#!/bin/bash
printf 'ip %s\n' "$*" >> "$CALLS"
case "$*" in *"route show default"*) printf '%s\n' "${FAKE_ROUTES:-}" ;; esac
IPEOF
printf '#!/bin/bash\nexit 0\n' > "$WORK/bin/sleep"; chmod +x "$WORK/bin/sleep"
printf '#!/bin/bash\necho 6.17.2-1-pve\n' > "$WORK/bin/uname"
chmod +x "$WORK/bin/ip" "$WORK/bin/uname"

nic(){ # nic <name> <carrier> [wireless]
    mkdir -p "$WORK/sysnet/$1"; echo "$2" > "$WORK/sysnet/$1/carrier"
    [ "${3:-}" = wireless ] && : > "$WORK/sysnet/$1/wireless"; return 0; }
kernel_supports(){ mkdir -p "$WORK/proc6/$1"; echo 1024 > "$WORK/proc6/$1/ra_defrtr_metric"; }
reset(){ rm -rf "$WORK/sysnet" "$WORK/proc6" "$WORK/calls"; mkdir -p "$WORK/sysnet" "$WORK/proc6"; : > "$WORK/calls"; }

run(){ CALLS="$WORK/calls" PATH="$WORK/bin:$PATH" \
       SIGMOND_PREFER_WIRED_SYSNET="$WORK/sysnet" \
       SIGMOND_PREFER_WIRED_PROC="$WORK/proc6" \
       FAKE_ROUTES="${FAKE_ROUTES:-}" \
       bash "$WORK/sigmond-prefer-wired" >/dev/null 2>&1
     cat "$WORK/calls"; }
# Everything the script did EXCEPT explain itself.  A refusal is supposed to
# be logged -- a silent one is indistinguishable from a crash -- so `logger`
# is not an action and must not count as one.
acted(){ printf '%s\n' "$1" | grep -v '^logger ' | grep -cv '^$'; }
says(){  printf '%s\n' "$1" | grep '^logger '; }

echo "── the dual-homed case: wired wins, radio stays ───────────────────────"
reset; nic vmbr0 1; nic wlp3s0 1 wireless; kernel_supports wlp3s0
out=$(run)
has   "the radio's RA metric is raised"      "$out" "sysctl -qw net.ipv6.conf.wlp3s0.ra_defrtr_metric=2048"
has   "wired is pinned at the better metric" "$out" "sysctl -qw net.ipv6.conf.vmbr0.ra_defrtr_metric=1024"
has   "the stale radio route is retired"     "$out" "ip -6 route del default dev wlp3s0"
has   "and a fresh RA is solicited"          "$out" "rdisc6 -1 wlp3s0"
# ⛔ THE FALLBACK IS THE POINT.  accept_ra_defrtr=0 would also make wired win,
# by deleting the Wi-Fi default route -- and then a pulled cable leaves the
# station with no path at all.
has   "the radio keeps accepting a default route" "$out" "sysctl -qw net.ipv6.conf.wlp3s0.accept_ra_defrtr=1"
lacks "it NEVER switches the radio's route off"   "$out" "accept_ra_defrtr=0"

echo "── the guard: a cable-free station must be left ALONE ─────────────────"
reset; nic vmbr0 0; nic wlp3s0 1 wireless; kernel_supports wlp3s0
out=$(run)
lacks "no cable -> no sysctl at all"   "$out" "ra_defrtr_metric=2048"
lacks "no cable -> no route deleted"   "$out" "route del"
chk   "no cable -> it takes NO action" "$(acted "$out")" "0"
has   "...and says why, rather than refusing in silence" "$(says "$out")" "not both up, leaving routes alone"

echo "── and a wired-only station is left alone too ─────────────────────────"
reset; nic vmbr0 1; nic enp1s0 1          # no wireless node anywhere
out=$(run)
chk "no radio -> nothing to prefer over, no action" "$(acted "$out")" "0"
has "...and says so"                                "$(says "$out")" "no Wi-Fi interface"

echo "── a radio that is down is not demoted ────────────────────────────────"
reset; nic vmbr0 1; nic wlp3s0 0 wireless; kernel_supports wlp3s0
out=$(run)
lacks "radio down -> left alone" "$out" "ra_defrtr_metric=2048"

echo "── an older kernel refuses rather than guessing ───────────────────────"
reset; nic vmbr0 1; nic wlp3s0 1 wireless   # no ra_defrtr_metric node
out=$(run)
chk   "unsupported kernel -> NO action at all" "$(acted "$out")" "0"
has   "...and names the reason"                "$(says "$out")" "ra_defrtr_metric unsupported"
lacks "unsupported kernel -> no route surgery" "$out" "route del"

echo "── the unit is ordered so the interfaces actually exist ───────────────"
# ⛔ NOT /etc/sysctl.d.  systemd-sysctl runs BEFORE network-pre.target, when
# ifupdown has not created vmbr0 yet; a per-interface key for a device that
# does not exist is skipped with a warning and never retried, so the
# preference would silently not survive a reboot.
has "unit waits for the network"        "$UNIT" "After=network-online.target"
has "...and pulls it in"                "$UNIT" "Wants=network-online.target"
# ⛔ Before=network-online.target is the documented deadlock in this tree.
lacks "it does not order itself BEFORE the network" "$UNIT" "Before=network-online.target"
has "it is a oneshot that stays applied" "$UNIT" "RemainAfterExit=yes"
has "it is bounded"                      "$UNIT" "TimeoutStartSec="
grep -q "systemctl enable sigmond-prefer-wired.service" "$SRC" \
    && { PASS=$((PASS+1)); echo "  ok    firstboot enables it"; } \
    || { FAIL=$((FAIL+1)); echo "  FAIL  firstboot never enables the unit"; }

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
