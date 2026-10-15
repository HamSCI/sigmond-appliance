#!/bin/bash
# test-vm6proxy.sh -- the IPv6 relay installs on every host, quietly where the
# kernel has no IPv6, and without waiting on any unit.
#
# Why: up to v3.71 the relay's units were written only by the IPv6-only gateway
# path, so a dual-stack site had no IPv6 way to the decoder VM's pages, and
# sigmond-check (v3.72 #14) read FAIL "the IPv6 relay is not installed" on every
# page line there.  v3.72 #15 installs it from the importer for every host.
#
# This runs the real sigmond-vm6proxy against a temporary unit directory, with
# a stub systemctl on PATH that records every call.  No root, no network.
#
#   usage: ./test-vm6proxy.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok(){  printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad(){ printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

mkdir -p "$T/bin" "$T/units"
cat > "$T/bin/systemctl" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
# `show -p IPAddressDeny --value <unit>` answers $STUB_DENY (the effective list).
[ "${1:-}" = show ] && printf '%s\n' "${STUB_DENY:-}"
exit 0
STUB
chmod +x "$T/bin/systemctl"
export SYSTEMCTL_LOG="$T/systemctl.log"
# A stub `ip` that prints the routing table the test chose, so allow-refresh
# can be run against any network without touching this machine's.
# `ip ... addr ...` prints $IP_ADDRS; `ip ... route ... default` prints
# $IP_DEFAULT; any other `ip ... route ...` prints $IP_ROUTES.
cat > "$T/bin/ip" <<'STUB'
#!/bin/bash
case " $* " in
    *" addr "*)  [ -f "$IP_ADDRS" ] && cat "$IP_ADDRS" ;;
    *" route "*" default "*) [ -f "$IP_DEFAULT" ] && cat "$IP_DEFAULT" ;;
    *" route "*) [ -f "$IP_ROUTES" ] && cat "$IP_ROUTES" ;;
esac
exit 0
STUB
chmod +x "$T/bin/ip"
export IP_ROUTES="$T/routes" IP_ADDRS="$T/addrs" IP_DEFAULT="$T/default"
: > "$IP_ROUTES"; : > "$IP_ADDRS"; : > "$IP_DEFAULT"
DROPIN="$T/units/sigmond-vm6proxy@.socket.d/10-allow-local.conf"
# The administrator's override file, and the owner the script demands of it
# (root in production; the test runs as itself, so it names its own uid).
export SIGMOND_VM6PROXY_ALLOW_FILE="$T/allow.conf" SIGMOND_VM6PROXY_TEST_OWNER="$(id -u)"

run_install(){
    : > "$SYSTEMCTL_LOG"
    PATH="$T/bin:$PATH" SIGMOND_VM6PROXY_TEST=1 SIGMOND_VM6PROXY_UNITDIR="$T/units" SIGMOND_MGMT_VM=127.0.0.9 \
        bash "$HERE/sigmond-vm6proxy" install > "$T/out" 2>&1
}

echo "sigmond-vm6proxy install: the units it writes"
run_install; rc=$?
[ "$rc" = 0 ] && ok "install exits 0" || bad "install exits 0" "rc=$rc: $(cat "$T/out")"

PORTS="8000 8081 8082 8765 2222"
for p in $PORTS; do
    s="$T/units/sigmond-vm6proxy@$p.socket"; v="$T/units/sigmond-vm6proxy@$p.service"
    if [ ! -f "$s" ] || [ ! -f "$v" ]; then
        bad ":$p has a socket and a service" "missing under $T/units"; continue
    fi
    # The Condition must sit in [Unit]: systemd ignores it anywhere else.
    for f in "$s" "$v"; do
        if awk '/^\[/{sec=$0} sec=="[Unit]" && $0=="ConditionPathExists=/proc/net/if_inet6"{found=1} END{exit !found}' "$f"; then
            ok "$(basename "$f") skips a host with IPv6 off in the kernel"
        else
            bad "$(basename "$f") skips a host with IPv6 off in the kernel" \
                "no ConditionPathExists=/proc/net/if_inet6 in [Unit]"
        fi
    done
    grep -qx 'BindIPv6Only=ipv6-only' "$s" && ok ":$p binds IPv6 only" \
        || bad ":$p binds IPv6 only" "$(cat "$s")"
    grep -qx "ListenStream=\[::\]:$p" "$s" && ok ":$p listens on [::]:$p" \
        || bad ":$p listens on [::]:$p" "$(cat "$s")"
done
grep -q 'ExecStart=.* 127.0.0.9:22$' "$T/units/sigmond-vm6proxy@2222.service" \
    && ok "2222 relays to the VM's 22 at the address it was given" \
    || bad "2222 relays to the VM's 22 at the address it was given" \
           "$(cat "$T/units/sigmond-vm6proxy@2222.service")"

echo
echo "sigmond-vm6proxy install: how it starts the sockets"
LOG=$(cat "$SYSTEMCTL_LOG")
grep -qx 'daemon-reload' "$SYSTEMCTL_LOG" && ok "it reloads systemd" || bad "it reloads systemd" "$LOG"
for p in $PORTS; do
    grep -qx "enable sigmond-vm6proxy@$p.socket" "$SYSTEMCTL_LOG" \
        && ok ":$p enabled" || bad ":$p enabled" "$LOG"
    grep -qx "start --no-block sigmond-vm6proxy@$p.socket" "$SYSTEMCTL_LOG" \
        && ok ":$p started without waiting" || bad ":$p started without waiting" "$LOG"
done
# The importer and the v6 gateway both run it, and the gateway runs from units
# that are part of getting the network online: nothing there may wait on a unit.
if grep -q -e '--now' "$SYSTEMCTL_LOG"; then
    bad "no blocking enable --now" "$LOG"
else
    ok "no blocking enable --now"
fi

echo
echo "sigmond-vm6proxy install: idempotent"
sum1=$(cd "$T/units" && find . -type f | sort | xargs -r sha256sum | sha256sum)
run_install
sum2=$(cd "$T/units" && find . -type f | sort | xargs -r sha256sum | sha256sum)
nunits=$(find "$T/units" -type f -name 'sigmond-vm6proxy@*' | wc -l)
[ "$nunits" = 10 ] && [ "$sum1" = "$sum2" ] && ok "a second install writes the same bytes" \
    || bad "a second install writes the same bytes" "$nunits unit files"
grep -qx 'daemon-reload' "$SYSTEMCTL_LOG" && ok "and reloads and enables again" \
    || bad "and reloads and enables again" "$(cat "$SYSTEMCTL_LOG")"

grep -q 'restart' "$SYSTEMCTL_LOG" && bad "and restarts nothing" "$(cat "$SYSTEMCTL_LOG")" \
    || ok "and restarts nothing"

echo
echo "the relay answers local networks only (Michael, 2026-10-15)"
# A global IPv6 address is reachable from the whole internet wherever the site
# router does not filter inbound IPv6.  NAT gives IPv4 "local only" for free;
# here the socket units must say it.
for p in $PORTS; do
    s="$T/units/sigmond-vm6proxy@$p.socket"; v="$T/units/sigmond-vm6proxy@$p.service"
    if awk '/^\[/{sec=$0} sec=="[Socket]" && $0=="IPAddressDeny=any"{found=1} END{exit !found}' "$s" \
       && awk '/^\[/{sec=$0} sec=="[Socket]" && $0=="IPAddressAllow=localhost link-local"{found=1} END{exit !found}' "$s"; then
        ok ":$p socket denies all but localhost and link-local (no blanket fc00::/7)"
    else
        bad ":$p socket denies all but localhost and link-local (no blanket fc00::/7)" "$(cat "$s")"
    fi
    # proxyd connects OUT to the VM over IPv4; a filter on the service would cut that.
    grep -q 'IPAddress' "$v" && bad ":$p service carries no address filter" "$(cat "$v")" \
        || ok ":$p service carries no address filter"
done

refresh(){
    : > "$SYSTEMCTL_LOG"
    PATH="$T/bin:$PATH" SIGMOND_VM6PROXY_TEST=1 SIGMOND_VM6PROXY_UNITDIR="$T/units" \
        bash "$HERE/sigmond-vm6proxy" allow-refresh > "$T/out" 2>&1
}
allow_line(){ grep '^IPAddressAllow=' "$DROPIN" 2>/dev/null; }

echo
echo "allow-refresh: the prefixes of this host's own addresses, never its routes"
# Security review 2026-10-15: anyone on the LAN can send a router
# advertisement.  A forged RA announcing an on-link ::/1 or 2000::/3 makes the
# kernel add that route; a list built from routes would then let most of the
# internet in.  So routes count for nothing: only the host's own configured
# global addresses, each masked to its prefix, and only /48 to /64.
cat > "$IP_ROUTES" <<'R'
::/1 dev vmbr0 proto ra metric 1024 expires 86000sec pref medium
2000::/3 dev vmbr0 proto ra metric 1024 expires 86000sec pref medium
2601:db8:1:2::/64 dev vmbr0 proto kernel metric 256 expires 86000sec pref medium
2001:db8:7::/64 dev vmbr0 proto kernel metric 256 pref medium
default via fe80::1 dev vmbr0 proto ra metric 1024 expires 1700sec pref medium
R
cat > "$IP_ADDRS" <<'A'
2: vmbr0    inet6 2601:db8:1:2:aaaa:bbbb:cccc:dddd/64 scope global temporary dynamic \       valid_lft 86000sec preferred_lft 14000sec
2: vmbr0    inet6 2601:db8:1:2:21b:21ff:fe3a:4b5c/64 scope global dynamic mngtmpaddr noprefixroute \       valid_lft 86000sec preferred_lft 14000sec
2: vmbr0    inet6 2601:db8:abcd:0:1:2:3:4/48 scope global \       valid_lft forever preferred_lft forever
2: vmbr0    inet6 2601:db8:4400::5/40 scope global \       valid_lft forever preferred_lft forever
2: vmbr0    inet6 2601:db8:1:2::77/128 scope global dynamic noprefixroute \       valid_lft 7000sec preferred_lft 7000sec
2: vmbr0    inet6 2601:db8:9:9:1:2:3:4/64 scope global tentative \       valid_lft forever preferred_lft forever
2: vmbr0    inet6 2601:db8:8:8:1:2:3:4/64 scope global dadfailed tentative \       valid_lft forever preferred_lft forever
2: vmbr0    inet6 fd00:1::21b:21ff:fe3a:4b5c/64 scope global dynamic mngtmpaddr \       valid_lft 86000sec preferred_lft 14000sec
2: vmbr0    inet6 2601:db8:6:6::1/64 scope global deprecated dynamic \       valid_lft 3000sec preferred_lft 0sec
A
refresh; rc=$?
[ "$rc" = 0 ] && ok "allow-refresh exits 0" || bad "allow-refresh exits 0" "rc=$rc: $(cat "$T/out")"
[ "$(allow_line)" = "IPAddressAllow=localhost link-local 2601:db8:1:2::/64 2601:db8:abcd::/48 fd00:1::/64" ] \
    && ok "the SLAAC /64 joins once (stable + temporary), a /48 and the uplink's own ULA /64 too, host bits masked" \
    || bad "the SLAAC /64 joins once (stable + temporary), a /48 and the uplink's own ULA /64 too, host bits masked" "got: $(allow_line)"
for x in '::/1' '2000::/3' '2001:db8:7::/64' '/40' '/128' '2601:db8:4400' '2601:db8:9:9' '2601:db8:8:8' '2601:db8:6:6' 'fc00::/7'; do
    allow_line | grep -qF -- "$x" && bad "not in the list: $x" "got: $(allow_line)" || ok "not in the list: $x"
done
grep -q '^\[Socket\]' "$DROPIN" 2>/dev/null && ok "the drop-in sets [Socket]" \
    || bad "the drop-in sets [Socket]" "$(cat "$DROPIN" 2>/dev/null)"
# Allow without Deny filters nothing.  An older sigmond-vm6proxy rewrites the
# socket units without Deny; the drop-in must still deny on its own.
grep -qx 'IPAddressDeny=any' "$DROPIN" 2>/dev/null && ok "the drop-in denies everything else itself" \
    || bad "the drop-in denies everything else itself" "$(cat "$DROPIN" 2>/dev/null)"
grep -qx 'daemon-reload' "$SYSTEMCTL_LOG" && ok "a new list reloads systemd" \
    || bad "a new list reloads systemd" "$(cat "$SYSTEMCTL_LOG")"
# A reload applies the new list to the live listener (final review, systemd
# 257).  A socket restart would also restart proxyd (Requires=) and drop
# every relayed session.
grep -q 'restart' "$SYSTEMCTL_LOG" && bad "allow-refresh restarts nothing" "$(cat "$SYSTEMCTL_LOG")" \
    || ok "allow-refresh restarts nothing"

before=$(sha256sum "$DROPIN" 2>/dev/null); touch -d '2000-01-01' "$DROPIN" 2>/dev/null
refresh
[ "$(sha256sum "$DROPIN" 2>/dev/null)" = "$before" ] && [ "$(stat -c %Y "$DROPIN" 2>/dev/null)" = "$(date -d '2000-01-01' +%s)" ] \
    && ok "an identical refresh rewrites nothing" \
    || bad "an identical refresh rewrites nothing"
[ -s "$SYSTEMCTL_LOG" ] && bad "and reloads and restarts nothing" "$(cat "$SYSTEMCTL_LOG")" \
    || ok "and reloads and restarts nothing"

printf '2000::/3 dev vmbr0 proto ra metric 1024 pref medium\n' > "$IP_ROUTES"
: > "$IP_ADDRS"
refresh
[ "$(allow_line)" = "IPAddressAllow=localhost link-local" ] \
    && ok "no global IPv6: the local list alone" \
    || bad "no global IPv6: the local list alone" "got: $(allow_line)"
grep -qx 'IPAddressDeny=any' "$DROPIN" && ok "and it still denies" || bad "and it still denies" "$(cat "$DROPIN")"
grep -qx 'daemon-reload' "$SYSTEMCTL_LOG" && ! grep -q restart "$SYSTEMCTL_LOG" \
    && ok "the shrink reloads and restarts nothing" || bad "the shrink reloads and restarts nothing" "$(cat "$SYSTEMCTL_LOG")"

# Stateful DHCPv6 (IA_NA) gives a /128 and no prefix.  The host's own /128 on
# the uplink stands for its /64; a /128 anywhere else counts for nothing.
cat > "$IP_ADDRS" <<'A'
2: vmbr0    inet6 2601:db8:77:1::5/128 scope global dynamic noprefixroute \       valid_lft 7000sec preferred_lft 7000sec
6: tailscale0    inet6 fd7a:115c:a1e0::5/128 scope global \       valid_lft forever preferred_lft forever
A
refresh
# Nothing on the host proves which /64 a DHCPv6 /128 sits in, and one shared
# /64 can hand /128s to unrelated machines (review of 1334bc0).  Fail closed.
[ "$(allow_line)" = "IPAddressAllow=localhost link-local" ] \
    && ok "an own /128 (DHCPv6) adds nothing: local list only" \
    || bad "an own /128 (DHCPv6) adds nothing: local list only" "got: $(allow_line)"

echo
echo "the administrator's override file"
: > "$IP_ADDRS"
printf '# the station LAN, numbered by DHCPv6\n2601:db8:aa:bb::/64\n\n2601:db8:77:1::5/128   # one host\n' > "$T/allow.conf"
chmod 644 "$T/allow.conf"
refresh
[ "$(allow_line)" = "IPAddressAllow=localhost link-local 2601:db8:77:1::5/128 2601:db8:aa:bb::/64" ] \
    && ok "a valid /64 and a /128 from the file join the list" \
    || bad "a valid /64 and a /128 from the file join the list" "got: $(allow_line) $(cat "$T/out")"
grep -q 'WARNING' "$T/out" && bad "a clean file draws no warning" "$(cat "$T/out")" || ok "a clean file draws no warning"
PATH="$T/bin:$PATH" SIGMOND_VM6PROXY_TEST=1 SIGMOND_VM6PROXY_UNITDIR="$T/units" SIGMOND_MGMT_VM=127.0.0.9 STUB_DENY="::/0" \
    bash "$HERE/sigmond-vm6proxy" status > "$T/st" 2>&1
grep -q '2601:db8:aa:bb::/64.*override file' "$T/st" && ok "status names the override file as its source" \
    || bad "status names the override file as its source" "$(cat "$T/st")"

printf '::/0\n2601::/32\nnot-a-prefix\n10.0.0.0/8\n2601:db8:aa:bb::/64\n' > "$T/allow.conf"
refresh
[ "$(allow_line)" = "IPAddressAllow=localhost link-local 2601:db8:aa:bb::/64" ] \
    && ok "::/0, a /32, garbage and IPv4 are skipped; the good line stays" \
    || bad "::/0, a /32, garbage and IPv4 are skipped; the good line stays" "got: $(allow_line)"
for n in 1 2 3 4; do
    grep -q "WARNING.*line $n" "$T/out" && ok "a warning names line $n" || bad "a warning names line $n" "$(cat "$T/out")"
done

printf '2601:db8:aa:bb::/64\n' > "$T/allow.conf"; chmod 666 "$T/allow.conf"
refresh
[ "$(allow_line)" = "IPAddressAllow=localhost link-local" ] && grep -q 'WARNING.*writable' "$T/out" \
    && ok "a group- or world-writable file is ignored, with a warning" \
    || bad "a group- or world-writable file is ignored, with a warning" "got: $(allow_line) $(cat "$T/out")"
chmod 644 "$T/allow.conf"
: > "$SYSTEMCTL_LOG"
PATH="$T/bin:$PATH" SIGMOND_VM6PROXY_TEST=1 SIGMOND_VM6PROXY_UNITDIR="$T/units" SIGMOND_VM6PROXY_TEST_OWNER=0 \
    bash "$HERE/sigmond-vm6proxy" allow-refresh > "$T/out" 2>&1
if [ "$(id -u)" = 0 ]; then
    ok "skipped as root (the file is root's)"
else
    [ "$(allow_line)" = "IPAddressAllow=localhost link-local" ] && grep -q 'WARNING.*not owned by root' "$T/out" \
        && ok "a file not owned by root is ignored, with a warning" \
        || bad "a file not owned by root is ignored, with a warning" "got: $(allow_line) $(cat "$T/out")"
fi
rm -f "$T/allow.conf"
cat > "$IP_ADDRS" <<'A'
2: vmbr0    inet6 2601:db8:1:2:21b:21ff:fe3a:4b5c/64 scope global dynamic mngtmpaddr \       valid_lft 86000sec preferred_lft 14000sec
A
refresh
PATH="$T/bin:$PATH" SIGMOND_VM6PROXY_TEST=1 SIGMOND_VM6PROXY_UNITDIR="$T/units" SIGMOND_MGMT_VM=127.0.0.9 STUB_DENY="::/0" \
    bash "$HERE/sigmond-vm6proxy" status > "$T/st" 2>&1
grep -q '2601:db8:1:2::/64.*own address' "$T/st" && ok "status names an own address as its source" \
    || bad "status names an own address as its source" "$(cat "$T/st")"
grep -q 'DHCPv6' "$HERE/INSTALL.md" && grep -q '/etc/sigmond/vm6proxy-allow.conf' "$HERE/INSTALL.md" \
    && ok "INSTALL.md names the override file" || bad "INSTALL.md names the override file"
: > "$IP_ADDRS"

echo
echo "allow-refresh: addresses on the uplink only"
# Security review 2026-10-15: a VPN or a second uplink holding a global
# address must not open its whole prefix.  The uplink is the device that
# carries the default IPv6 route (vmbr0 when there is none); never vmbr1, never
# a tunnel.
: > "$IP_ROUTES"
cat > "$IP_ADDRS" <<'A'
2: vmbr0    inet6 2601:db8:1:2:21b:21ff:fe3a:4b5c/64 scope global dynamic mngtmpaddr \       valid_lft 86000sec preferred_lft 14000sec
5: wg0    inet6 2602:f00:5:6::2/64 scope global \       valid_lft forever preferred_lft forever
6: tailscale0    inet6 2603:f00:7:8::2/64 scope global \       valid_lft forever preferred_lft forever
6: tailscale0    inet6 fd7a:115c:a1e0:ab12:4843:cd96:6258:b240/64 scope global \       valid_lft forever preferred_lft forever
4: wlp2s0    inet6 2604:f00:9:a:1:2:3:4/64 scope global dynamic mngtmpaddr \       valid_lft 86000sec preferred_lft 14000sec
3: vmbr1    inet6 2605:f00:b:c::1/64 scope global \       valid_lft forever preferred_lft forever
A
printf 'default via fe80::1 dev vmbr0 proto ra metric 1024 expires 1700sec pref medium\n' > "$IP_DEFAULT"
refresh
[ "$(allow_line)" = "IPAddressAllow=localhost link-local 2601:db8:1:2::/64" ] \
    && ok "default via vmbr0: only vmbr0's /64, not wg0, tailscale0, wlp2s0 or vmbr1" \
    || bad "default via vmbr0: only vmbr0's /64, not wg0, tailscale0, wlp2s0 or vmbr1" "got: $(allow_line)"
printf 'default via fe80::1 dev wlp2s0 proto ra metric 600 pref medium\n' > "$IP_DEFAULT"
refresh
[ "$(allow_line)" = "IPAddressAllow=localhost link-local 2604:f00:9:a::/64" ] \
    && ok "default via Wi-Fi: the Wi-Fi /64 alone" \
    || bad "default via Wi-Fi: the Wi-Fi /64 alone" "got: $(allow_line)"
printf 'default dev wg0 metric 50 pref medium\ndefault dev tun0 metric 60 pref medium\n' > "$IP_DEFAULT"
refresh
[ "$(allow_line)" = "IPAddressAllow=localhost link-local 2601:db8:1:2::/64" ] \
    && ok "default via a tunnel only: vmbr0, never the tunnel" \
    || bad "default via a tunnel only: vmbr0, never the tunnel" "got: $(allow_line)"
: > "$IP_DEFAULT"
refresh
[ "$(allow_line)" = "IPAddressAllow=localhost link-local 2601:db8:1:2::/64" ] \
    && ok "no IPv6 default route: vmbr0" \
    || bad "no IPv6 default route: vmbr0" "got: $(allow_line)"

echo
echo "allow-refresh: a planted python module never runs as root"
# python3 -c puts the current directory first on sys.path, so an ipaddress.py
# in the caller's cwd would run as root (security review 2026-10-15).
DECOY="$T/decoy"; mkdir -p "$DECOY"
cat > "$DECOY/ipaddress.py" <<PYEOF
open("$T/decoy-ran", "w").write("ran")
raise SystemExit(0)
PYEOF
cp "$DECOY/ipaddress.py" "$DECOY/sys.py" 2>/dev/null
rm -f "$T/decoy-ran"
( cd "$DECOY" && : > "$SYSTEMCTL_LOG" && PATH="$T/bin:$PATH" SIGMOND_VM6PROXY_TEST=1 SIGMOND_VM6PROXY_UNITDIR="$T/units" \
    PYTHONPATH="$DECOY" PYTHONSTARTUP="$DECOY/ipaddress.py" \
    bash "$HERE/sigmond-vm6proxy" allow-refresh > "$T/out" 2>&1 )
[ ! -e "$T/decoy-ran" ] && ok "a decoy ipaddress.py in cwd or PYTHONPATH does not run" \
    || bad "a decoy ipaddress.py in cwd or PYTHONPATH does not run" "marker written"
[ "$(allow_line)" = "IPAddressAllow=localhost link-local 2601:db8:1:2::/64" ] \
    && ok "and the list still comes out right" || bad "and the list still comes out right" "got: $(allow_line)"
grep -q '/usr/bin/python3 -I ' "$HERE/sigmond-vm6proxy" && ok "the script names /usr/bin/python3 -I" \
    || bad "the script names /usr/bin/python3 -I"

echo
echo "install: the refresh timer"
: > "$IP_ROUTES"; : > "$IP_ADDRS"; : > "$IP_DEFAULT"
run_install
for u in sigmond-vm6proxy-refresh.timer sigmond-vm6proxy-refresh.service; do
    [ -f "$T/units/$u" ] && ok "$u written" || bad "$u written"
done
grep -q '^OnUnitActiveSec=' "$T/units/sigmond-vm6proxy-refresh.timer" 2>/dev/null \
    && grep -q '^OnBootSec=' "$T/units/sigmond-vm6proxy-refresh.timer" \
    && ok "the timer runs after boot and then repeats" \
    || bad "the timer runs after boot and then repeats" "$(cat "$T/units/sigmond-vm6proxy-refresh.timer" 2>/dev/null)"
grep -q 'ExecStart=.*sigmond-vm6proxy allow-refresh' "$T/units/sigmond-vm6proxy-refresh.service" 2>/dev/null \
    && ok "and runs allow-refresh" || bad "and runs allow-refresh"
grep -qx 'enable sigmond-vm6proxy-refresh.timer' "$SYSTEMCTL_LOG" \
    && grep -qx 'start --no-block sigmond-vm6proxy-refresh.timer' "$SYSTEMCTL_LOG" \
    && ok "install enables the timer and starts it without waiting" \
    || bad "install enables the timer and starts it without waiting" "$(cat "$SYSTEMCTL_LOG")"
[ -f "$DROPIN" ] && ok "install writes the drop-in" || bad "install writes the drop-in"

echo
echo "install over older units restarts the sockets that changed"
sed -i '/^IPAddress/d' "$T/units/sigmond-vm6proxy@8081.socket"
run_install
grep -qx 'try-restart --no-block sigmond-vm6proxy@8081.socket' "$SYSTEMCTL_LOG" \
    && ok "the changed :8081 socket restarts" || bad "the changed :8081 socket restarts" "$(cat "$SYSTEMCTL_LOG")"
grep -q 'restart.*@8000' "$SYSTEMCTL_LOG" && bad "an unchanged socket does not" "$(cat "$SYSTEMCTL_LOG")" \
    || ok "an unchanged socket does not"

echo
echo "status: the effective filter of each socket"
: > "$SYSTEMCTL_LOG"
PATH="$T/bin:$PATH" SIGMOND_VM6PROXY_TEST=1 SIGMOND_VM6PROXY_UNITDIR="$T/units" SIGMOND_MGMT_VM=127.0.0.9 STUB_DENY="" \
    bash "$HERE/sigmond-vm6proxy" status > "$T/out" 2>&1
[ "$(grep -c 'NOT FILTERED' "$T/out")" = 5 ] && ok "an empty IPAddressDeny reads NOT FILTERED on every port" \
    || bad "an empty IPAddressDeny reads NOT FILTERED on every port" "$(cat "$T/out")"
grep -q 'show -p IPAddressDeny --value sigmond-vm6proxy@2222.socket' "$SYSTEMCTL_LOG" \
    && ok "it asks systemd for the effective list" || bad "it asks systemd for the effective list" "$(cat "$SYSTEMCTL_LOG")"
PATH="$T/bin:$PATH" SIGMOND_VM6PROXY_TEST=1 SIGMOND_VM6PROXY_UNITDIR="$T/units" SIGMOND_MGMT_VM=127.0.0.9 STUB_DENY="::/0 0.0.0.0/0" \
    bash "$HERE/sigmond-vm6proxy" status > "$T/out" 2>&1
! grep -q 'NOT FILTERED' "$T/out" && [ "$(grep -c 'filtered' "$T/out")" = 5 ] \
    && ok "a deny list reads filtered" || bad "a deny list reads filtered" "$(cat "$T/out")"

echo
echo "the VM address: a dotted quad or nothing"
# It reaches a root `bash -c` in the status probe.
for bad_ip in '1.2.3.4; touch '"$T"'/pwned' '256.1.1.1' '10.99.0' 'evil.example' '1.2.3.4/24'; do
    rm -rf "$T/v"; mkdir -p "$T/v"; : > "$SYSTEMCTL_LOG"
    PATH="$T/bin:$PATH" SIGMOND_VM6PROXY_TEST=1 SIGMOND_VM6PROXY_UNITDIR="$T/v" SIGMOND_MGMT_VM="$bad_ip" \
        bash "$HERE/sigmond-vm6proxy" install > "$T/out" 2>&1; rc=$?
    if [ "$rc" != 0 ] && [ -z "$(ls -A "$T/v")" ] && [ ! -e "$T/pwned" ]; then
        ok "refused: $bad_ip"
    else
        bad "refused: $bad_ip" "rc=$rc files=$(ls -A "$T/v" | wc -l) $(cat "$T/out")"
    fi
done
rm -rf "$T/v"; mkdir -p "$T/v"
PATH="$T/bin:$PATH" SIGMOND_VM6PROXY_TEST=1 SIGMOND_VM6PROXY_UNITDIR="$T/v" \
    bash "$HERE/sigmond-vm6proxy" install '1.2.3.4;id' > "$T/out" 2>&1; rc=$?
[ "$rc" != 0 ] && [ -z "$(ls -A "$T/v")" ] && ok "refused as an argument too" \
    || bad "refused as an argument too" "rc=$rc $(cat "$T/out")"

echo
echo "install --no-status: no probe"
rm -rf "$T/v"; mkdir -p "$T/v"; : > "$SYSTEMCTL_LOG"
PATH="$T/bin:$PATH" SIGMOND_VM6PROXY_TEST=1 SIGMOND_VM6PROXY_UNITDIR="$T/v" \
    bash "$HERE/sigmond-vm6proxy" install --no-status 10.99.0.2 > "$T/out" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q ' 10.99.0.2:22$' "$T/v/sigmond-vm6proxy@2222.service" \
    && ok "it installs, with the address after the flag" || bad "it installs, with the address after the flag" "rc=$rc $(cat "$T/out")"
grep -q -e 'is-active' -e '^show' "$SYSTEMCTL_LOG" || grep -q 'VM=' "$T/out" \
    && bad "and probes nothing" "$(cat "$SYSTEMCTL_LOG") $(cat "$T/out")" || ok "and probes nothing"

echo
echo "the test hook needs the test flag"
if [ "$(id -u)" = 0 ]; then
    ok "skipped as root (it would write the real unit dir)"
else
    rm -rf "$T/v"; mkdir -p "$T/v"
    PATH="$T/bin:$PATH" SIGMOND_VM6PROXY_UNITDIR="$T/v" SIGMOND_MGMT_VM=127.0.0.9 \
        bash "$HERE/sigmond-vm6proxy" install --no-status > "$T/out" 2>&1
    [ -z "$(ls -A "$T/v")" ] && ok "SIGMOND_VM6PROXY_UNITDIR alone is ignored" \
        || bad "SIGMOND_VM6PROXY_UNITDIR alone is ignored" "$(ls -A "$T/v")"
fi

echo
echo "sigmond-vm6proxy install: a unit it cannot write is a failure"
# pm-align reports a failed install as a warning; it can only do that when the
# exit status says so.
: > "$SYSTEMCTL_LOG"
PATH="$T/bin:$PATH" SIGMOND_VM6PROXY_TEST=1 SIGMOND_VM6PROXY_UNITDIR="$T/no-such-dir" SIGMOND_MGMT_VM=127.0.0.9 \
    bash "$HERE/sigmond-vm6proxy" install > "$T/out" 2>&1; rc=$?
[ "$rc" != 0 ] && ok "install exits non-zero (rc=$rc)" || bad "install exits non-zero" "rc=0: $(cat "$T/out")"
grep -q 'cannot write' "$T/out" && ! grep -q -e 'line [0-9]' -e 'No such file' "$T/out" \
    && ok "it says so once, without bash's redirect error" || bad "it says so once, without bash's redirect error" "$(cat "$T/out")"
grep -q 'enable' "$SYSTEMCTL_LOG" && bad "and enables nothing" "$(cat "$SYSTEMCTL_LOG")" \
    || ok "and enables nothing"

echo
echo "firstboot: the importer installs the relay for every host"
IMPORTER="$T/importer.sh"
awk '/^cat > \/usr\/local\/sbin\/sigmond-import.sh <<.IMPEOF.$/{f=1;next} /^IMPEOF$/{f=0} f' \
    "$HERE/firstboot-v3.sh" > "$IMPORTER"
bash -n "$IMPORTER" 2>/dev/null && ok "the importer parses" || bad "the importer parses"
# Outside the v6 gateway, right after the IPv4 DNAT loop, with the same address.
_dnat=$(grep -n 'for _pf in 8000:8000 8081:8081 8082:8082 8765:8765 2222:22' "$IMPORTER" | head -1 | cut -d: -f1)
_inst=$(grep -n 'SIGMOND_MGMT_VM="$MGMT_VM" /usr/local/sbin/sigmond-vm6proxy install' "$IMPORTER" | head -1 | cut -d: -f1)
_gw=$(grep -n '/usr/local/sbin/sigmond-v6-gateway 2>&1' "$IMPORTER" | head -1 | cut -d: -f1)
if [ -n "$_dnat" ] && [ -n "$_inst" ] && [ -n "$_gw" ] && [ "$_dnat" -lt "$_inst" ] && [ "$_inst" -lt "$_gw" ]; then
    ok "it installs the relay after the DNAT rules, with MGMT_VM, before the v6 gateway"
else
    bad "it installs the relay after the DNAT rules, with MGMT_VM, before the v6 gateway" \
        "dnat=${_dnat:-none} install=${_inst:-none} gateway=${_gw:-none}"
fi
grep -q '/usr/local/sbin/sigmond-vm6proxy install --no-status' "$IMPORTER" \
    && ok "the importer does not wait on the status probe" || bad "the importer does not wait on the status probe"
V6GW="$T/v6gw.sh"
awk '/^cat > \/usr\/local\/sbin\/sigmond-v6-gateway <<.V6GWEOF.$/{f=1;next} /^V6GWEOF$/{f=0} f' \
    "$HERE/firstboot-v3.sh" > "$V6GW"
grep -q '/usr/local/sbin/sigmond-vm6proxy install --no-status' "$V6GW" \
    && ok "nor does the v6 gateway" || bad "nor does the v6 gateway"
_off=$(grep -n 'install -m 755 /mnt/sig-media/sigmond-vm6proxy' "$IMPORTER" | head -1 | cut -d: -f1)
[ -n "$_off" ] && [ -n "$_inst" ] && [ "$_off" -lt "$_inst" ] \
    && ok "and the script is copied off the media before that" \
    || bad "and the script is copied off the media before that" "copy=${_off:-none} install=${_inst:-none}"

echo
echo "build: the manifest carries the relay's hash"
n=$(grep -c 'echo "vm6proxy_sha256: ' "$HERE/build-usb-v3.sh")
[ "$n" = 2 ] && ok "both manifests (host copy and release) name vm6proxy_sha256" \
    || bad "both manifests (host copy and release) name vm6proxy_sha256" "found $n"

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
