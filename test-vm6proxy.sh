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
exit 0
STUB
chmod +x "$T/bin/systemctl"
export SYSTEMCTL_LOG="$T/systemctl.log"
# A stub `ip` that prints the routing table the test chose, so allow-refresh
# can be run against any network without touching this machine's.
# `ip ... addr ...` prints $IP_ADDRS; `ip ... route ...` prints $IP_ROUTES.
cat > "$T/bin/ip" <<'STUB'
#!/bin/bash
case " $* " in
    *" addr "*)  [ -f "$IP_ADDRS" ] && cat "$IP_ADDRS" ;;
    *" route "*) [ -f "$IP_ROUTES" ] && cat "$IP_ROUTES" ;;
esac
exit 0
STUB
chmod +x "$T/bin/ip"
export IP_ROUTES="$T/routes" IP_ADDRS="$T/addrs"
: > "$IP_ROUTES"; : > "$IP_ADDRS"
DROPIN="$T/units/sigmond-vm6proxy@.socket.d/10-allow-local.conf"

run_install(){
    : > "$SYSTEMCTL_LOG"
    PATH="$T/bin:$PATH" SIGMOND_VM6PROXY_UNITDIR="$T/units" SIGMOND_MGMT_VM=127.0.0.9 \
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
       && awk '/^\[/{sec=$0} sec=="[Socket]" && $0=="IPAddressAllow=localhost link-local fc00::/7"{found=1} END{exit !found}' "$s"; then
        ok ":$p socket denies all but localhost, link-local and ULA"
    else
        bad ":$p socket denies all but localhost, link-local and ULA" "$(cat "$s")"
    fi
    # proxyd connects OUT to the VM over IPv4; a filter on the service would cut that.
    grep -q 'IPAddress' "$v" && bad ":$p service carries no address filter" "$(cat "$v")" \
        || ok ":$p service carries no address filter"
done

refresh(){
    : > "$SYSTEMCTL_LOG"
    PATH="$T/bin:$PATH" SIGMOND_VM6PROXY_UNITDIR="$T/units" \
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
A
refresh; rc=$?
[ "$rc" = 0 ] && ok "allow-refresh exits 0" || bad "allow-refresh exits 0" "rc=$rc: $(cat "$T/out")"
[ "$(allow_line)" = "IPAddressAllow=localhost link-local fc00::/7 2601:db8:1:2::/64 2601:db8:abcd::/48" ] \
    && ok "the SLAAC /64 joins once (stable + temporary), a /48 too, host bits masked" \
    || bad "the SLAAC /64 joins once (stable + temporary), a /48 too, host bits masked" "got: $(allow_line)"
for x in '::/1' '2000::/3' '2001:db8:7::/64' '/40' '/128' '2601:db8:4400' '2601:db8:9:9' '2601:db8:8:8' 'fd00'; do
    allow_line | grep -qF -- "$x" && bad "not in the list: $x" "got: $(allow_line)" || ok "not in the list: $x"
done
grep -q '^\[Socket\]' "$DROPIN" 2>/dev/null && ok "the drop-in sets [Socket]" \
    || bad "the drop-in sets [Socket]" "$(cat "$DROPIN" 2>/dev/null)"
grep -qx 'daemon-reload' "$SYSTEMCTL_LOG" && ok "a new list reloads systemd" \
    || bad "a new list reloads systemd" "$(cat "$SYSTEMCTL_LOG")"
for p in $PORTS; do
    grep -qx "try-restart --no-block sigmond-vm6proxy@$p.socket" "$SYSTEMCTL_LOG" \
        && ok ":$p socket restarted without waiting" \
        || bad ":$p socket restarted without waiting" "$(cat "$SYSTEMCTL_LOG")"
done
grep -E 'restart' "$SYSTEMCTL_LOG" | grep -v -- '--no-block' | grep -q . \
    && bad "no blocking restart" "$(cat "$SYSTEMCTL_LOG")" || ok "no blocking restart"
grep -E 'restart.*\.service' "$SYSTEMCTL_LOG" | grep -q . \
    && bad "only the sockets restart" "$(cat "$SYSTEMCTL_LOG")" || ok "only the sockets restart"

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
[ "$(allow_line)" = "IPAddressAllow=localhost link-local fc00::/7" ] \
    && ok "no global IPv6: the local list alone" \
    || bad "no global IPv6: the local list alone" "got: $(allow_line)"
grep -q 'try-restart --no-block sigmond-vm6proxy@8000.socket' "$SYSTEMCTL_LOG" \
    && ok "and the shrink restarts the sockets" || bad "and the shrink restarts the sockets" "$(cat "$SYSTEMCTL_LOG")"

echo
echo "install: the refresh timer"
: > "$IP_ROUTES"; : > "$IP_ADDRS"
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
echo "sigmond-vm6proxy install: a unit it cannot write is a failure"
# pm-align reports a failed install as a warning; it can only do that when the
# exit status says so.
: > "$SYSTEMCTL_LOG"
PATH="$T/bin:$PATH" SIGMOND_VM6PROXY_UNITDIR="$T/no-such-dir" SIGMOND_MGMT_VM=127.0.0.9 \
    bash "$HERE/sigmond-vm6proxy" install > "$T/out" 2>&1; rc=$?
[ "$rc" != 0 ] && ok "install exits non-zero (rc=$rc)" || bad "install exits non-zero" "rc=0: $(cat "$T/out")"
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
