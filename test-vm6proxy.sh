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
sum1=$(cd "$T/units" && sha256sum -- * 2>/dev/null | sha256sum)
run_install
sum2=$(cd "$T/units" && sha256sum -- * 2>/dev/null | sha256sum)
nunits=$(find "$T/units" -type f | wc -l)
[ "$nunits" = 10 ] && [ "$sum1" = "$sum2" ] && ok "a second install writes the same bytes" \
    || bad "a second install writes the same bytes" "$nunits unit files"
grep -qx 'daemon-reload' "$SYSTEMCTL_LOG" && ok "and reloads and enables again" \
    || bad "and reloads and enables again" "$(cat "$SYSTEMCTL_LOG")"

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
