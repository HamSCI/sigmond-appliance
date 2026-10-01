#!/bin/bash
# test-netsel.sh — the uplink selector must never be able to strand the host.
#
# ⛔ TWO WAYS THIS COULD BRICK A STATION, and both are one-way trips on a
# machine with no keyboard:
#
# 1. A STALE PREFERENCE. The operator pins enp2s0, the cable moves, and six
#    months later someone reboots. If the preference were a COMMAND, netfix
#    would honour a dead port and skip the live one. It must be a preference:
#    tried first, then the ordinary carrier-first search still runs and wins.
#
# 2. `ipv6 off` ON AN IPv6-ONLY SITE. There, IPv4 reaches the world through
#    the CLAT — 464XLAT — which runs OVER IPv6. "I have an IPv4 default route"
#    is therefore NOT evidence that IPv6 is expendable; `default dev clat` is
#    exactly the case where disabling IPv6 removes the host's only path. The
#    guard must demand a NATIVE IPv4 gateway (` via `), not merely a route.
#
#   usage: ./test-netsel.sh [path/to/firstboot-v3.sh]
set -u
SRC="${1:-$(dirname "$0")/firstboot-v3.sh}"
[ -f "$SRC" ] || { echo "FATAL: no firstboot-v3.sh at $SRC"; exit 1; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
chk(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ok    %s\n' "$1"
       else FAIL=$((FAIL+1)); printf '  FAIL  %s\n        want: %s\n        got : %s\n' "$1" "$3" "$2"; fi; }

ex(){ local s e
  s=$(grep -nF "$1" "$SRC" | head -1 | cut -d: -f1)
  e=$(awk -v s="$s" -v m="$2" 'NR>s && $0==m{print NR; exit}' "$SRC")
  [ -n "$s" ] && [ -n "$e" ] || { echo "FATAL: cannot extract $2"; exit 1; }
  sed -n "$((s+1)),$((e-1))p" "$SRC" > "$3"; }
ex "cat > /usr/local/sbin/sigmond-netsel <<'NETSELEOF'" NETSELEOF "$WORK/netsel"
ex "cat > /usr/local/sbin/sigmond-netfix <<'NETFIXEOF'" NETFIXEOF "$WORK/netfix"
chmod +x "$WORK/netsel"
[ -s "$WORK/netsel" ] && [ -s "$WORK/netfix" ] || { echo "FATAL: empty extraction"; exit 1; }
bash -n "$WORK/netsel" || { echo "FATAL: netsel does not parse"; exit 1; }

echo "── the preference is a PREFERENCE, not a command ──────────────────────"
# netfix's ordering block, read as source: the fallback arm must still run.
chk "an unknown preference is ignored, not fatal" \
    "$(grep -c "is not a probeable NIC here — ignoring it" "$WORK/netfix")" "1"
chk "  ...and it does not exit" \
    "$(awk '/is not a probeable NIC here/{print; exit}' "$WORK/netfix" | grep -c 'exit')" "0"
chk "a preference only REORDERS the probe list" \
    "$(grep -c 'PROBE=.*sed .s/ \$_pref / /' "$WORK/netfix")" "1"
chk "'auto' and empty both mean no preference" \
    "$(grep -c 'case "\$_pref" in auto|"") _pref="" ;; esac' "$WORK/netfix")" "1"

echo "── ipv6 off refuses when IPv4 is not NATIVE ───────────────────────────"
# Fake `ip` so the guard sees a CLAT-only world: a default route exists, but
# it has no ` via ` — which is precisely what 464XLAT looks like.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/ip" <<'IP'
#!/bin/bash
case "$*" in
  *"-4 route show default"*) printf '%s\n' "${FAKE_V4ROUTE:-}" ;;
  *"-6 route show default"*) printf '%s\n' "${FAKE_V6ROUTE:-}" ;;
  *) : ;;
esac
IP
cat > "$WORK/bin/sysctl" <<'S'
#!/bin/bash
exit 0
S
cat > "$WORK/bin/ping" <<'P'
#!/bin/bash
exit 0
P
# ⛔ FAKE `id`, or every assertion below passes for the WRONG REASON.  netsel
# refuses to run as non-root, so without this the "refuses" cases all pass on
# the root check and never reach the guard they claim to test — while the one
# "allows" case fails and reveals it.  A suite where the negatives pass and the
# positive fails is a suite testing nothing.
cat > "$WORK/bin/id" <<'I'
#!/bin/bash
[ "${1:-}" = -u ] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
I
chmod +x "$WORK/bin"/*
mkdir -p "$WORK/sysnet/enp1s0"; : > "$WORK/sysnet/enp1s0/device"; echo 1 > "$WORK/sysnet/enp1s0/carrier"

run(){ PATH="$WORK/bin:$PATH" SIGMOND_UPLINK_PREF="$WORK/pref" SIGMOND_SYSNET="$WORK/sysnet" \
       FAKE_V4ROUTE="${V4:-}" FAKE_V6ROUTE="${V6:-}" \
       bash "$WORK/netsel" "$@" 2>&1; }

# ⛔ THE CASE THAT MATTERS: clat-only. A route with no gateway.
V4="default dev clat scope link metric 2048" V6="default via fe80::1 dev wlp3s0"
out=$(run ipv6 off); rc=$?
chk "CLAT-only: refuses to disable IPv6" "$rc" "1"
chk "  ...and says why (the CLAT runs over IPv6)" \
    "$(printf '%s' "$out" | grep -c 'CLAT runs over IPv6')" "1"

# A NATIVE v4 gateway is the only thing that makes it safe.
V4="default via 10.22.23.1 dev vmbr0" V6="default via fe80::1 dev wlp3s0"
out=$(run ipv6 off); rc=$?
chk "native IPv4 gateway: allows it" "$rc" "0"
chk "  ...and warns that clatd + the v6 relays go inert" \
    "$(printf '%s' "$out" | grep -c 'inert')" "1"

# No IPv4 at all is the same refusal.
V4="" V6="default via fe80::1 dev wlp3s0"
chk "no IPv4 at all: refuses" "$(run ipv6 off >/dev/null 2>&1; echo $?)" "1"

echo "── selecting a NIC ────────────────────────────────────────────────────"
V4="default via 10.22.23.1 dev vmbr0" V6=""
chk "refuses an interface that does not exist" \
    "$(run eth99 >/dev/null 2>&1; echo $?)" "1"
chk "  ...without writing a preference file" \
    "$([ -e "$WORK/pref" ] && echo written || echo clean)" "clean"

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
