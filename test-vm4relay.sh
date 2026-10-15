#!/bin/bash
# test-vm4relay.sh -- the decoder VM's IPv4 ports answer the station's own
# network only (v3.72 #23).
#
# Why: the host forwarded 8000, 8081, 8082, 8765 and 2222 to the VM with
# PREROUTING DNAT rules that matched any interface and any source.  A
# Tailscale or ZeroTier peer of the host, or the whole internet at a site
# where the host holds a public IPv4 address with no NAT, reached the VM,
# ssh included.  sigmond-vm4relay moves the DNAT into a chain of its own,
# entered only from the uplink, that forwards only the host's own LAN subnets
# and the RFC 1918 ranges.
#
# This runs the real script against REAL iptables (nft and, when present,
# legacy) inside an unprivileged user+network+mount namespace, with stubs for
# `ip` (the host's addresses and default routes) and `systemctl`.  No root, no
# effect on this machine.  Needs unshare(1) with user namespaces.
#
#   usage: ./test-vm4relay.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -z "${VM4_IN_NS:-}" ]; then
    exec unshare -rnm env VM4_IN_NS=1 bash "$0" "$@"
fi
# A private /run: iptables takes its lock there.
mount -t tmpfs tmpfs /run || { echo "FAIL: cannot mount a private /run"; exit 1; }
export PATH="/usr/sbin:/sbin:$PATH"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# VM4_BACKEND=legacy runs the same tests against iptables-legacy.
if [ "${VM4_BACKEND:-nft}" = legacy ]; then
    mkdir -p "$T/be"
    ln -s "$(command -v iptables-legacy)" "$T/be/iptables"
    ln -s "$(command -v iptables-legacy-restore)" "$T/be/iptables-restore"
    export PATH="$T/be:$PATH"
fi
echo "backend: $(iptables -V)"
pass=0; fail=0
ok(){  printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad(){ printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
has(){   grep -qxF -- "$3" "$2" && ok "$1" || bad "$1" "missing: $3"; }
lacks(){ grep -qF -- "$3" "$2" && bad "$1" "found: $3" || ok "$1"; }

mkdir -p "$T/bin" "$T/units"
cat > "$T/bin/systemctl" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
exit 0
STUB
# `ip -4 ... addr ...` prints $IP4_ADDRS; `ip -4 route show default` prints $IP4_DEFAULT.
cat > "$T/bin/ip" <<'STUB'
#!/bin/bash
case " $* " in
    *" addr "*) cat "$IP4_ADDRS" 2>/dev/null ;;
    *" route "*) cat "$IP4_DEFAULT" 2>/dev/null ;;
esac
exit 0
STUB
# iptables-restore: log each call, then run the real one (or fail on demand).
REAL_RESTORE=$(command -v iptables-restore)
cat > "$T/bin/iptables-restore" <<STUB
#!/bin/bash
echo "call \$*" >> "\$RESTORE_LOG"
[ -e "\$RESTORE_FAIL" ] && { cat >/dev/null; echo "iptables-restore: forced failure" >&2; exit 1; }
exec $REAL_RESTORE "\$@"
STUB
chmod +x "$T/bin/"*
export SYSTEMCTL_LOG="$T/systemctl.log" IP4_ADDRS="$T/addrs" IP4_DEFAULT="$T/default"
export RESTORE_LOG="$T/restore.log" RESTORE_FAIL="$T/restore.fail"
IFACES="$T/interfaces"
# A fake /sys/class/net: what each device IS decides whether it is an uplink.
SYSNET="$T/sys"
mkdev(){   # mkdev <name> <type> [wireless] [device] [tun]
    local d="$SYSNET/$1"; mkdir -p "$d"; echo "$2" > "$d/type"; shift 2
    for f in "$@"; do
        case "$f" in
            wireless) mkdir -p "$d/wireless" ;;
            device)   mkdir -p "$d/device" ;;
            tun)      echo 0x1002 > "$d/tun_flags" ;;
        esac
    done
}
mkdev vmbr0 1; mkdev vmbr1 1; mkdev lo 772
mkdev enp1s0 1 device; mkdev wlp2s0 1 wireless device
mkdev ppp0 512; mkdev nordlynx 65534; mkdev wg0 65534; mkdev tun0 65534 tun
mkdev tailscale0 65534 tun; mkdev zt0 1 tun
# Ethernet-typed but not hardware (a veth, another bridge), and a tap that
# claims a device: none is an uplink.
mkdev veth0 1; mkdev vmbr9 1; mkdev tapx 1 device tun
# What a traversal name would find if it were ever used as a path.
mkdir -p "$T/etc/device"; echo 1 > "$T/etc/type"
STATEDIR="$T/state"; mkdir -p "$STATEDIR"
# The administrator's override file, and the owner the script demands of it
# (root in production; inside the namespace the test runs as uid 0 already).
ALLOW="$T/etc/vm4relay-allow.conf"; mkdir -p "$T/etc"; chmod 755 "$T/etc"

relay(){   # relay <args...>  -> $T/out, returns the script's status
    : > "$SYSTEMCTL_LOG"; : > "$RESTORE_LOG"
    PATH="$T/bin:$PATH" SIGMOND_VM4RELAY_TEST=1 SIGMOND_VM4RELAY_UNITDIR="$T/units" \
        SIGMOND_VM4RELAY_INTERFACES="$IFACES" SIGMOND_MGMT_VM="${VM:-10.99.0.2}" \
        SIGMOND_VM4RELAY_SYSNET="$SYSNET" SIGMOND_VM4RELAY_STATEDIR="$STATEDIR" \
        SIGMOND_VM4RELAY_LOCK_WAIT="${LOCK_WAIT:-30}" SIGMOND_VM4RELAY_ALLOW_FILE="${ALLOW_FILE:-$ALLOW}" \
        SIGMOND_VM4RELAY_TEST_OWNER="${TEST_OWNER:-$(id -u)}" \
        bash "$HERE/sigmond-vm4relay" "$@" > "$T/out" 2>&1
}
reset_nat(){ iptables -t nat -F; iptables -t nat -X 2>/dev/null; :; }
snap(){ iptables -t nat -S > "$T/nat"; iptables -t nat -S SIGMOND-VM4 > "$T/chain" 2>/dev/null; }
OLD_RULES(){   # the rules firstboot used to write, with no -i and no source
    iptables -t nat -A PREROUTING -p tcp --dport 8000 -j DNAT --to-destination 10.99.0.2:8000
    iptables -t nat -A PREROUTING -p tcp --dport 8081 -j DNAT --to-destination 10.99.0.2:8081
    iptables -t nat -A PREROUTING -p tcp --dport 8082 -j DNAT --to-destination 10.99.0.2:8082
    iptables -t nat -A PREROUTING -p tcp --dport 8765 -j DNAT --to-destination 10.99.0.2:8765
    iptables -t nat -A PREROUTING -p tcp --dport 2222 -j DNAT --to-destination 10.99.0.2:22
}
PORTS="8000:8000 8081:8081 8082:8082 8765:8765 2222:22"
OLD_LINE(){ echo "    post-up iptables -t nat -C PREROUTING -p tcp --dport $1 -j DNAT --to-destination 10.99.0.2:$2 2>/dev/null || iptables -t nat -A PREROUTING -p tcp --dport $1 -j DNAT --to-destination 10.99.0.2:$2"; }
write_ifaces(){
    {
        echo "auto lo"
        echo "iface lo inet loopback"
        echo ""
        echo "auto vmbr0"
        echo "iface vmbr0 inet dhcp"
        echo "    bridge-ports enp1s0"
        echo ""
        echo "auto vmbr1"
        echo "iface vmbr1 inet static"
        echo "    address 10.99.0.1/30"
        echo "    post-up sysctl -q -w net.ipv4.ip_forward=1"
        echo "    post-up iptables -t nat -C POSTROUTING -s 10.99.0.0/30 -o vmbr0 -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 10.99.0.0/30 -o vmbr0 -j MASQUERADE"
        for pair in $PORTS; do OLD_LINE "${pair%%:*}" "${pair##*:}"; done
        echo "    post-up iptables -t nat -C PREROUTING -p tcp --dport 9000 -j DNAT --to-destination 10.99.0.2:9000 2>/dev/null || true"
        # The exact shape, to ANOTHER host on one of the relay's ports: it stays.
        echo "    post-up iptables -t nat -C PREROUTING -p tcp --dport 8081 -j DNAT --to-destination 192.168.1.77:8081 2>/dev/null || iptables -t nat -A PREROUTING -p tcp --dport 8081 -j DNAT --to-destination 192.168.1.77:8081"
        # The exact shape, but a port pair that is not the relay's: it stays.
        echo "    post-up iptables -t nat -C PREROUTING -p tcp --dport 9000 -j DNAT --to-destination 10.99.0.2:9000 2>/dev/null || iptables -t nat -A PREROUTING -p tcp --dport 9000 -j DNAT --to-destination 10.99.0.2:9000"
    } > "$IFACES"
}

echo "the script"
[ -f "$HERE/sigmond-vm4relay" ] && bash -n "$HERE/sigmond-vm4relay" 2>/dev/null \
    && ok "sigmond-vm4relay ships and parses" || bad "sigmond-vm4relay ships and parses"
grep -qx 'VM4RELAY_FILTER=1' "$HERE/sigmond-vm4relay" 2>/dev/null \
    && ok "it carries the marker VM4RELAY_FILTER=1" || bad "it carries the marker VM4RELAY_FILTER=1"
if LC_ALL=C grep -qP '[^\x00-\x7F]' "$HERE/sigmond-vm4relay" 2>/dev/null; then
    bad "it is ASCII"
else
    ok "it is ASCII"
fi

echo
echo "an RFC 1918 LAN, a host with the old unrestricted rules"
reset_nat; OLD_RULES
iptables -t nat -A PREROUTING -p tcp --dport 9000 -j DNAT --to-destination 192.168.1.77:9000
iptables -t nat -A PREROUTING -i vmbr0 -p udp --dport 53 -j REDIRECT --to-ports 5353
# The old shape exactly, on a relay port, but to the operator's own host.
iptables -t nat -A PREROUTING -p tcp --dport 8765 -j DNAT --to-destination 192.168.1.77:8765
echo "2: vmbr0    inet 192.168.1.50/24 brd 192.168.1.255 scope global dynamic vmbr0\\       valid_lft 86000sec" > "$IP4_ADDRS"
echo "default via 192.168.1.1 dev vmbr0 proto dhcp src 192.168.1.50 metric 100" > "$IP4_DEFAULT"
write_ifaces; cp "$IFACES" "$T/ifaces.orig"
relay status
grep -q 'UNRESTRICTED' "$T/out" && ok "status reads the old rules as UNRESTRICTED" \
    || bad "status reads the old rules as UNRESTRICTED" "$(cat "$T/out")"
relay install; rc=$?
[ "$rc" = 0 ] && ok "install exits 0" || bad "install exits 0" "rc=$rc $(cat "$T/out")"
snap
for pair in $PORTS; do
    hp=${pair%%:*}; gp=${pair##*:}
    for src in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do
        has ":$hp from $src" "$T/chain" \
            "-A SIGMOND-VM4 -s $src -p tcp -m tcp --dport $hp -j DNAT --to-destination 10.99.0.2:$gp"
    done
done
[ "$(grep -c '^-A SIGMOND-VM4 ' "$T/chain")" = 15 ] && ok "15 rules: 3 sources x 5 ports (the /24 sits inside 192.168/16)" \
    || bad "15 rules: 3 sources x 5 ports" "$(cat "$T/chain")"
grep '^-A SIGMOND-VM4 ' "$T/chain" | grep -v -- ' -s ' | grep -q . \
    && bad "every chain rule matches a source" "$(cat "$T/chain")" || ok "every chain rule matches a source"
has "PREROUTING enters the chain from vmbr0" "$T/nat" "-A PREROUTING -i vmbr0 -j SIGMOND-VM4"
[ "$(grep -c -- '-j SIGMOND-VM4$' "$T/nat")" = 1 ] && ok "exactly one jump" || bad "exactly one jump" "$(cat "$T/nat")"
for pair in $PORTS; do
    hp=${pair%%:*}; gp=${pair##*:}
    lacks "the unrestricted :$hp rule is gone" "$T/nat" \
        "-A PREROUTING -p tcp -m tcp --dport $hp -j DNAT --to-destination 10.99.0.2:$gp"
done
has "an unrelated DNAT rule stays" "$T/nat" "-A PREROUTING -p tcp -m tcp --dport 9000 -j DNAT --to-destination 192.168.1.77:9000"
has "an operator's own DNAT to another host stays, even in the old shape" "$T/nat" "-A PREROUTING -p tcp -m tcp --dport 8765 -j DNAT --to-destination 192.168.1.77:8765"
has "an unrelated REDIRECT rule stays" "$T/nat" "-A PREROUTING -i vmbr0 -p udp -m udp --dport 53 -j REDIRECT --to-ports 5353"
relay status
grep -q 'UNRESTRICTED' "$T/out" && bad "status no longer reads UNRESTRICTED" "$(cat "$T/out")" \
    || ok "status no longer reads UNRESTRICTED"

echo
echo "install: the post-up lines that would bring the old rules back at boot"
n=$(grep -c '^    # disabled by sigmond-vm4relay (v3.72 #23): post-up iptables -t nat -C PREROUTING' "$IFACES")
[ "$n" = 5 ] && ok "the five DNAT post-up lines are commented out" || bad "the five DNAT post-up lines are commented out" "found $n: $(cat "$IFACES")"
grep -E '^[[:space:]]*post-up iptables -t nat -C PREROUTING -p tcp --dport (8000|8081|8082|8765|2222) -j DNAT --to-destination 10\.99\.0\.2:' "$IFACES" | grep -q . \
    && bad "no live DNAT post-up line for the five ports remains" "$(cat "$IFACES")" \
    || ok "no live DNAT post-up line for the five ports remains"
diff <(grep -v '# disabled by sigmond-vm4relay' "$IFACES") \
     <(grep -vE 'post-up iptables -t nat -C PREROUTING -p tcp --dport (8000|8081|8082|8765|2222) -j DNAT --to-destination 10\.99\.0\.2:' "$T/ifaces.orig") >/dev/null \
    && ok "every other line is untouched, the 9000 and the other-host lines included" || bad "every other line is untouched" "$(diff "$T/ifaces.orig" "$IFACES")"
ls "$T" | grep -E 'interfaces\..*(new|tmp)' && bad "no temporary file is left behind" || ok "no temporary file is left behind"
cmp -s "$IFACES.pre-vm4relay" "$T/ifaces.orig" && ok "the original is kept beside it" || bad "the original is kept beside it"
cp "$IFACES" "$T/ifaces.after1"
relay install
cmp -s "$IFACES" "$T/ifaces.after1" && ok "a second install changes nothing more" || bad "a second install changes nothing more" "$(diff "$T/ifaces.after1" "$IFACES")"
cmp -s "$IFACES.pre-vm4relay" "$T/ifaces.orig" && ok "and keeps the first backup" || bad "and keeps the first backup"

echo
echo "install: units, and nothing started synchronously"
S="$T/units/sigmond-vm4relay.service"; TM="$T/units/sigmond-vm4relay.timer"
has "the service reapplies the chain at boot" "$S" "ExecStart=/usr/local/sbin/sigmond-vm4relay refresh"
has "with the VM address" "$S" "Environment=SIGMOND_MGMT_VM=10.99.0.2"
has "it is a oneshot" "$S" "Type=oneshot"
has "it starts with the system" "$S" "WantedBy=multi-user.target"
lacks "never Before=network-online.target (a deadlock)" "$S" "Before=network-online.target"
has "the timer repeats" "$TM" "OnUnitActiveSec=15min"
grep -q '^OnBootSec=' "$TM" && ok "and runs after boot" || bad "and runs after boot"
relay install
L="$SYSTEMCTL_LOG"
has "enables the service" "$L" "enable sigmond-vm4relay.service"
has "enables the timer" "$L" "enable sigmond-vm4relay.timer"
has "starts the timer without waiting" "$L" "start --no-block sigmond-vm4relay.timer"
grep -q -e '--now' -e '^start sigmond' -e '^restart' "$L" && bad "no synchronous start" "$(cat "$L")" || ok "no synchronous start"

echo
echo "refresh: idempotent, and quiet when nothing changed"
snap; cp "$T/nat" "$T/nat.before"
relay refresh; rc=$?
snap
[ "$rc" = 0 ] && cmp -s "$T/nat" "$T/nat.before" && ok "the rules stay the same" || bad "the rules stay the same" "rc=$rc"
[ -s "$RESTORE_LOG" ] && bad "iptables-restore is not called" "$(cat "$RESTORE_LOG")" || ok "iptables-restore is not called"
[ -s "$T/out" ] && bad "it prints nothing" "$(cat "$T/out")" || ok "it prints nothing"

echo
echo "a public campus LAN (no NAT in front of the host)"
# Michael, 2026-10-15: a public own subnet is NOT allowed automatically; an
# administrator lists it in the override file.
reset_nat; rm -f "$ALLOW"
echo "2: vmbr0    inet 129.24.10.5/22 brd 129.24.11.255 scope global vmbr0\\       valid_lft forever" > "$IP4_ADDRS"
echo "default via 129.24.8.1 dev vmbr0 proto static" > "$IP4_DEFAULT"
relay refresh; snap
lacks "the host's own public /22 is not allowed by itself" "$T/chain" "129.24.8.0/22"
[ "$(grep -c '^-A SIGMOND-VM4 ' "$T/chain")" = 15 ] && ok "only the private ranges: 15 rules" || bad "only the private ranges" "$(cat "$T/chain")"
printf '# the campus LAN\n129.24.8.0/22\n' > "$ALLOW"; chmod 644 "$ALLOW"
relay refresh; snap
for pair in $PORTS; do
    hp=${pair%%:*}; gp=${pair##*:}
    has ":$hp from the listed campus /22" "$T/chain" "-A SIGMOND-VM4 -s 129.24.8.0/22 -p tcp -m tcp --dport $hp -j DNAT --to-destination 10.99.0.2:$gp"
done
[ "$(grep -c '^-A SIGMOND-VM4 ' "$T/chain")" = 20 ] && ok "20 rules: 4 sources x 5 ports" || bad "20 rules" "$(cat "$T/chain")"
lacks "never the whole internet" "$T/chain" "0.0.0.0/0"
relay status
grep -q '129.24.8.0/22 (override file)' "$T/out" && ok "status names the override file as the source" || bad "status names the override file as the source" "$(cat "$T/out")"
grep -q '192.168.0.0/16 (private range)' "$T/out" && ok "and the private ranges as theirs" || bad "and the private ranges as theirs" "$(cat "$T/out")"
printf '129.24.20.0/24\n' > "$ALLOW"
relay refresh; snap
lacks "a changed list drops the old prefix" "$T/chain" "129.24.8.0/22"
has "and takes the new one" "$T/chain" "-A SIGMOND-VM4 -s 129.24.20.0/24 -p tcp -m tcp --dport 8081 -j DNAT --to-destination 10.99.0.2:8081"
[ "$(wc -l < "$RESTORE_LOG")" = 1 ] && ok "in one atomic iptables-restore" || bad "in one atomic iptables-restore" "$(cat "$RESTORE_LOG")"
grep -q '129.24.20.0/24' "$T/out" && ok "and says what it now answers" || bad "and says what it now answers" "$(cat "$T/out")"

echo
echo "the override file: bad entries and bad files never widen the list"
printf '0.0.0.0/0\n129.0.0.0/8\n100.64.0.0/10\n100.100.1.0/24\n127.0.0.0/16\n224.1.0.0/16\nnot-a-prefix\n2601:db8::/64\n129.24.20.0/24\n' > "$ALLOW"
relay refresh; snap
for x in 0.0.0.0/0 129.0.0.0/8 100.64.0.0/10 100.100.1.0/24 127.0.0.0/16 224.1.0.0/16; do
    lacks "refused: $x" "$T/chain" " -s $x "
done
has "the good line stays" "$T/chain" "-A SIGMOND-VM4 -s 129.24.20.0/24 -p tcp -m tcp --dport 8081 -j DNAT --to-destination 10.99.0.2:8081"
has "and the private ranges stay" "$T/chain" "-A SIGMOND-VM4 -s 10.0.0.0/8 -p tcp -m tcp --dport 8081 -j DNAT --to-destination 10.99.0.2:8081"
for n in 1 2 3 4 5 6 7 8; do
    grep -q "WARNING.*line $n:" "$T/out" && ok "a warning names line $n" || bad "a warning names line $n" "$(cat "$T/out")"
done
relay refresh
grep -q 'WARNING' "$T/out" && bad "the same bad file warns once, not on every tick" "$(cat "$T/out")" \
    || ok "the same bad file warns once, not on every tick"
relay status
grep -q 'WARNING.*line 1:' "$T/out" && ok "status still shows the warnings" || bad "status still shows the warnings" "$(cat "$T/out")"

try_allow(){   # <desc> <path> <warning regex>
    ALLOW_FILE="$2" relay refresh; snap
    if [ "$(grep -c '^-A SIGMOND-VM4 ' "$T/chain")" = 15 ] && grep -qE "WARNING.*$3" "$T/out"; then
        ok "$1: ignored with a warning; the private ranges stay"
    else
        bad "$1: ignored with a warning; the private ranges stay" "$(grep -c '^-A' "$T/chain") rules | $(cat "$T/out")"
    fi
}
printf '129.24.20.0/24\n' > "$T/etc/good.conf"; chmod 644 "$T/etc/good.conf"
ln -sf "$T/etc/good.conf" "$T/etc/link.conf"
try_allow "a symlink" "$T/etc/link.conf" "cannot read"
cp "$T/etc/good.conf" "$T/etc/ww.conf"; chmod 666 "$T/etc/ww.conf"
try_allow "a world-writable file" "$T/etc/ww.conf" "writable"
mkdir -p "$T/wwdir"; chmod 777 "$T/wwdir"; cp "$T/etc/good.conf" "$T/wwdir/allow.conf"; chmod 644 "$T/wwdir/allow.conf"
try_allow "a file in a world-writable directory" "$T/wwdir/allow.conf" "directory"
mkfifo "$T/etc/fifo.conf"
try_allow "a FIFO (no hang)" "$T/etc/fifo.conf" "not a regular file"
{ printf '129.24.20.0/24\n'; head -c 70000 /dev/zero | tr '\0' '#'; printf '\n'; } > "$T/etc/big.conf"; chmod 644 "$T/etc/big.conf"
try_allow "a file over 64 KiB" "$T/etc/big.conf" "larger than 64 KiB"
TEST_OWNER=4242 try_allow "a file not owned by root" "$T/etc/good.conf" "not owned by root"
rm -f "$ALLOW"; relay refresh

echo
echo "Tailscale and CGNAT: never"
reset_nat
cat > "$IP4_ADDRS" <<'A'
2: vmbr0    inet 192.168.1.50/24 brd 192.168.1.255 scope global vmbr0\       valid_lft forever
2: vmbr0    inet 100.70.0.5/24 brd 100.70.0.255 scope global vmbr0\       valid_lft forever
2: vmbr0    inet 44.1.2.3/8 brd 44.255.255.255 scope global vmbr0\       valid_lft forever
2: vmbr0    inet 203.0.113.9/32 scope global vmbr0\       valid_lft forever
2: vmbr0    inet 198.51.100.9/31 scope global vmbr0\       valid_lft forever
7: tailscale0    inet 100.101.102.103/32 scope global tailscale0\       valid_lft forever
8: zt0    inet 172.30.5.9/16 brd 172.30.255.255 scope global zt0\       valid_lft forever
9: wg0    inet 129.99.0.2/24 scope global wg0\       valid_lft forever
A
printf 'default via 192.168.1.1 dev vmbr0 metric 100\ndefault dev tailscale0 metric 50\ndefault dev wg0 metric 60\ndefault dev zt0 metric 70\n' > "$IP4_DEFAULT"
relay refresh; snap
lacks "no 100.x source of any kind" "$T/chain" " -s 100."
lacks "no tunnel's subnet" "$T/chain" "129.99.0.0/24"
lacks "no own subnet wider than /16 (a /8)" "$T/chain" "44.0.0.0/8"
lacks "no own /32" "$T/chain" "203.0.113.9"
lacks "no own /31" "$T/chain" "198.51.100.8"
lacks "no jump from tailscale0" "$T/nat" "-i tailscale0"
lacks "no jump from wg0" "$T/nat" "-i wg0"
lacks "no jump from zt0" "$T/nat" "-i zt0"
has "the uplink still jumps" "$T/nat" "-A PREROUTING -i vmbr0 -j SIGMOND-VM4"

echo
echo "a Wi-Fi uplink"
reset_nat
cat > "$IP4_ADDRS" <<'A'
4: wlp2s0    inet 10.0.0.7/24 brd 10.0.0.255 scope global dynamic wlp2s0\       valid_lft 86000sec
A
echo "default via 10.0.0.1 dev wlp2s0 proto dhcp metric 600" > "$IP4_DEFAULT"
relay refresh; snap
has "the Wi-Fi device jumps" "$T/nat" "-A PREROUTING -i wlp2s0 -j SIGMOND-VM4"
has "and vmbr0 still does" "$T/nat" "-A PREROUTING -i vmbr0 -j SIGMOND-VM4"
: > "$IP4_DEFAULT"
relay refresh; snap
lacks "a device that stops carrying the default route loses its jump" "$T/nat" "-i wlp2s0"

echo
echo "uplinks are identified by what the device is, never by its name"
reset_nat
echo "2: vmbr0    inet 192.168.1.50/24 scope global vmbr0\\  x" > "$IP4_ADDRS"
printf 'default dev ppp0 metric 10\ndefault dev nordlynx metric 20\ndefault dev tun0 metric 30\ndefault via 192.168.1.1 dev enp1s0 metric 40\ndefault dev veth0 metric 50\ndefault dev vmbr9 metric 60\ndefault dev tapx metric 70\ndefault dev ../etc metric 80\n' > "$IP4_DEFAULT"
relay refresh; snap
lacks "ppp0 (a dial-up or PPPoE link, no device) is not an uplink" "$T/nat" "-i ppp0"
lacks "nordlynx (a VPN with an innocent name) is not an uplink" "$T/nat" "-i nordlynx"
lacks "tun0 (tun_flags) is not an uplink" "$T/nat" "-i tun0"
has "enp1s0 (a real Ethernet device) is an uplink" "$T/nat" "-A PREROUTING -i enp1s0 -j SIGMOND-VM4"
lacks "veth0 (Ethernet type, no hardware) is not an uplink" "$T/nat" "-i veth0"
lacks "another bridge is not an uplink" "$T/nat" "-i vmbr9"
lacks "a tap is never an uplink, whatever else it claims" "$T/nat" "-i tapx"
lacks "a device name is never a path" "$T/nat" "-i ../"

echo
echo "duplicate jumps converge to one"
iptables -t nat -A PREROUTING -i vmbr0 -j SIGMOND-VM4
iptables -t nat -A PREROUTING -i vmbr0 -j SIGMOND-VM4
relay refresh; snap
[ "$(grep -c -- '-A PREROUTING -i vmbr0 -j SIGMOND-VM4' "$T/nat")" = 1 ] && ok "three copies become one" \
    || bad "three copies become one" "$(cat "$T/nat")"
[ -s "$T/out" ] && ok "and that counts as a change" || bad "and that counts as a change"
relay refresh
[ -s "$T/out" ] && bad "the next refresh is quiet" "$(cat "$T/out")" || ok "the next refresh is quiet"

echo
echo "refresh puts the post-up lines right again (netfix's ifreload -a re-runs post-up)"
write_ifaces
relay refresh; rc=$?
[ "$(grep -c '^    # disabled by sigmond-vm4relay' "$IFACES")" = 5 ] && ok "refresh comments the lines out too" \
    || bad "refresh comments the lines out too" "rc=$rc $(cat "$IFACES")"
grep -q 'commented out 5' "$T/out" && ok "and says so" || bad "and says so" "$(cat "$T/out")"
relay refresh
[ -s "$T/out" ] && bad "once done, refresh is quiet again" "$(cat "$T/out")" || ok "once done, refresh is quiet again"

echo
echo "every iptables call waits for the xtables lock (-w)"
reset_nat; OLD_RULES; relay refresh
grep -q -- '-w' "$RESTORE_LOG" && ok "iptables-restore gets -w" || bad "iptables-restore gets -w" "$(cat "$RESTORE_LOG")"
# A call is `iptables` in command position: line start, or after | ; & ( or $(.
CALLS=$(grep -nE '(^|[|;&(]|\$\()[[:space:]]*iptables(-restore)?[[:space:]]' "$HERE/sigmond-vm4relay")
n_calls=$(printf '%s\n' "$CALLS" | grep -c .)
NOW=$(printf '%s\n' "$CALLS" | sed 's/^[0-9]*://' | grep -vE '(^|[|;&(]|\$\()[[:space:]]*iptables(-restore)? -w ')
if [ "$n_calls" -ge 8 ] && [ -z "$NOW" ]; then
    ok "all $n_calls iptables calls pass -w"
else
    bad "every iptables call passes -w" "calls=$n_calls without: $NOW"
fi

echo
echo "status: any DNAT to the VM outside the chain is unrestricted"
reset_nat; relay refresh
iptables -t nat -A PREROUTING -i vmbr0 -p tcp --dport 9001 -j DNAT --to-destination 10.99.0.2:9001
relay status
grep -q 'UNRESTRICTED rule still live' "$T/out" && ok "a rule of the operator's, to the VM, outside the chain" \
    || bad "a rule of the operator's, to the VM, outside the chain" "$(cat "$T/out")"
iptables -t nat -D PREROUTING -i vmbr0 -p tcp --dport 9001 -j DNAT --to-destination 10.99.0.2:9001
iptables -t nat -A PREROUTING -i vmbr0 -p tcp --dport 9001 -j DNAT --to-destination 192.168.1.77:9001
relay status
grep -q 'UNRESTRICTED' "$T/out" && bad "a DNAT to another host is not the relay's business" "$(cat "$T/out")" \
    || ok "a DNAT to another host is not the relay's business"

echo
echo "remove holds the lock"
reset_nat; relay install
( exec 8>/run/sigmond-vm4relay.lock; flock 8; sleep 20 ) & HOLDER=$!
sleep 1
LOCK_WAIT=1 relay remove; rc=$?
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
snap
[ "$rc" != 0 ] && grep -q 'SIGMOND-VM4' "$T/nat" && ok "a remove that cannot take the lock changes nothing" \
    || bad "a remove that cannot take the lock changes nothing" "rc=$rc $(cat "$T/out")"
relay remove; rc=$?
[ "$rc" = 0 ] && [ -e "$STATEDIR/vm4relay-removed" ] && ok "remove leaves a removed-by-operator mark" \
    || bad "remove leaves a removed-by-operator mark" "rc=$rc"
relay install
[ -e "$STATEDIR/vm4relay-removed" ] && bad "install clears the mark" || ok "install clears the mark"

echo
echo "failure modes"
reset_nat; OLD_RULES
echo "2: vmbr0    inet 192.168.1.50/24 scope global vmbr0\\  x" > "$IP4_ADDRS"; : > "$IP4_DEFAULT"
touch "$RESTORE_FAIL"
relay refresh; rc=$?; snap
rm -f "$RESTORE_FAIL"
[ "$rc" != 0 ] && grep -q 'iptables-restore' "$T/out" && ok "a failed restore exits non-zero and says so" \
    || bad "a failed restore exits non-zero and says so" "rc=$rc $(cat "$T/out")"
has "and changes nothing: the old rules are still there" "$T/nat" "-A PREROUTING -p tcp -m tcp --dport 8081 -j DNAT --to-destination 10.99.0.2:8081"
write_ifaces; cp "$IFACES" "$T/ifaces.fail"; rm -f "$IFACES.pre-vm4relay"
touch "$RESTORE_FAIL"
relay install; rc=$?
rm -f "$RESTORE_FAIL"
[ "$rc" != 0 ] && cmp -s "$IFACES" "$T/ifaces.fail" && ok "install whose chain fails leaves the interfaces file alone" \
    || bad "install whose chain fails leaves the interfaces file alone" "rc=$rc $(diff "$T/ifaces.fail" "$IFACES")"
for badip in '1.2.3.4; id' '256.1.1.1' 'evil' '010.99.0.2' '10.099.0.2' '0.1.2.3' '127.0.0.1' '224.0.0.1' '255.255.255.255'; do
    VM="$badip" relay refresh; rc=$?
    [ "$rc" != 0 ] && [ ! -s "$RESTORE_LOG" ] && ok "refuses VM address: $badip" || bad "refuses VM address: $badip" "rc=$rc"
done

echo
echo "remove"
relay install; relay remove; snap
grep -q 'SIGMOND-VM4' "$T/nat" && bad "chain and jumps are gone" "$(cat "$T/nat")" || ok "chain and jumps are gone"
[ -e "$T/units/sigmond-vm4relay.service" ] && bad "units are gone" || ok "units are gone"

echo
echo "firstboot and the build"
IMPORTER="$T/importer.sh"
awk '/^cat > \/usr\/local\/sbin\/sigmond-import.sh <<.IMPEOF.$/{f=1;next} /^IMPEOF$/{f=0} f' \
    "$HERE/firstboot-v3.sh" > "$IMPORTER"
bash -n "$IMPORTER" 2>/dev/null && ok "the importer parses" || bad "the importer parses"
lacks "the vmbr1 stanza writes no unrestricted DNAT post-up line" "$IMPORTER" "post-up iptables -t nat -C PREROUTING"
grep -q 'iptables -t nat -A PREROUTING' "$IMPORTER" && bad "the importer adds no unrestricted DNAT rule" \
    || ok "the importer adds no unrestricted DNAT rule"
grep -q 'SIGMOND_MGMT_VM="$MGMT_VM" /usr/local/sbin/sigmond-vm4relay install' "$IMPORTER" \
    && ok "the importer installs the IPv4 relay with MGMT_VM" || bad "the importer installs the IPv4 relay with MGMT_VM"
_off=$(grep -n 'install -m 755 /mnt/sig-media/sigmond-vm4relay /usr/local/sbin/sigmond-vm4relay' "$IMPORTER" | head -1 | cut -d: -f1)
_inst=$(grep -n '/usr/local/sbin/sigmond-vm4relay install' "$IMPORTER" | head -1 | cut -d: -f1)
[ -n "$_off" ] && [ -n "$_inst" ] && [ "$_off" -lt "$_inst" ] && ok "copied off the media first" \
    || bad "copied off the media first" "copy=${_off:-none} install=${_inst:-none}"
grep -q 'cp sigmond-vm4relay /tmp/sigpay' "$HERE/build-usb-v3.sh" && ok "the build puts it on the media" || bad "the build puts it on the media"
grep -q 'sigmond-vm6proxy sigmond-vm4relay' "$HERE/build-usb-v3.sh" && ok "the build checks it against the checkout" \
    || bad "the build checks it against the checkout"
[ "$(grep -c 'echo "vm4relay_sha256: ' "$HERE/build-usb-v3.sh")" = 2 ] && ok "both manifests carry vm4relay_sha256" \
    || bad "both manifests carry vm4relay_sha256"

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
