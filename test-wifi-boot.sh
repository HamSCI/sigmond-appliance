#!/bin/bash
# test-wifi-boot.sh — does a Wi-Fi-only station survive a reboot?
#
# ⛔ THE FAILURE THIS GUARDS
# rob installed v3.57 on AI6VN-PM (2026-09-30) with no cable.  The wizard's
# Wi-Fi step joined an AP and took an IPv6 address; the finalizer power-cycled
# the host as designed; and the station came back declaring
#     INSTALL CANNOT CONTINUE NORMALLY: NO NETWORK CABLE DETECTED
# on a machine whose radio was its intended and only uplink.  Two independent
# defects stacked:
#
#   1. `sigmond-wifi join` persisted the ASSOCIATION and nothing else.  Every
#      address came from one imperative run -- dhclient, the RA wait, and the
#      accept_ra=2 sysctl a FORWARDING host needs for SLAAC to work at all.
#      None of it survived the reboot, so the radio came back associated and
#      addressless.
#   2. `sigmond-netfix` asked "which NIC can I bridge?" and reported the answer
#      as "is this machine on the network?".  It skips Wi-Fi for a sound reason
#      (managed mode cannot be bridged) and therefore never looked at the one
#      interface that was up.
#
# Both are behavioural, so these are behavioural tests: the real netfix, lifted
# out of firstboot-v3.sh, and the real sigmond-wifi, each run against a fake
# /sys and fake system dirs in a mount namespace.  Nothing is grepped for
# strings -- a station is judged dead or alive by what the code DOES.
#
# Needs unshare(1) with user namespaces (Debian 13 default).  No root, no
# network, no VM: runs in about a second.
set -u
cd "$(dirname "$0")" || exit 1
REPO="$PWD"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok(){   PASS=$((PASS+1)); printf '  ok    %s\n' "$*"; }
bad(){  FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$*"; }
check(){ # check <desc> <haystack-file> <needle>
    if grep -qF -- "$3" "$2"; then ok "$1"; else bad "$1 (missing: $3)"; fi; }
check_not(){
    if grep -qF -- "$3" "$2"; then bad "$1 (unexpected: $3)"; else ok "$1"; fi; }

# ── lift netfix out of firstboot, so the test exercises what ships ──────────
awk '/^cat > \/usr\/local\/sbin\/sigmond-netfix <<.NETFIXEOF.$/{f=1;next} /^NETFIXEOF$/{f=0} f' \
    firstboot-v3.sh > "$WORK/sigmond-netfix"
[ -s "$WORK/sigmond-netfix" ] || { echo "FATAL: could not extract netfix from firstboot-v3.sh"; exit 1; }
chmod +x "$WORK/sigmond-netfix"
bash -n "$WORK/sigmond-netfix" || { echo "FATAL: extracted netfix does not parse"; exit 1; }
bash -n sigmond-wifi        || { echo "FATAL: sigmond-wifi does not parse"; exit 1; }

# ── a fake machine ──────────────────────────────────────────────────────────
# $1 = wifi address state: none | v6 | v4
# $2 = saved profile? yes | no
build_fake(){
    local wifi_addr="$1" profile="$2" root="$WORK/root"
    rm -rf "$root"; mkdir -p \
        "$root/sys" "$root/etc/network" "$root/etc/sigmond-appliance" \
        "$root/etc/systemd/system" "$root/etc/wpa_supplicant" \
        "$root/usrlocallib" "$root/varlib/sigmond" "$root/varlog" "$root/bin"

    # Two Ethernet ports, both dark; one radio.  `device` marks them physical,
    # `wireless` marks the radio -- exactly what netfix keys off.
    local n
    for n in eno1 eno2; do
        mkdir -p "$root/sys/$n/device"; echo 0 > "$root/sys/$n/carrier"
    done
    mkdir -p "$root/sys/wlp3s0/device" "$root/sys/wlp3s0/wireless"
    echo 1 > "$root/sys/wlp3s0/carrier"

    # ⛔ Debian's /usr/bin/awk is a symlink into /etc/alternatives, so binding a
    # fake /etc over the real one DELETES awk -- and cur_ip() parses `ip` output
    # with awk.  Every address came back empty, wifi_uplink() returned nothing,
    # and the suite reported the exact product bug it was written to detect,
    # from a cause that was purely the harness.  Carry the alternatives in.
    cp -a /etc/alternatives "$root/etc/" 2>/dev/null || true

    printf 'auto vmbr0\niface vmbr0 inet static\n\taddress 192.168.100.2/24\n\tgateway 192.168.100.1\n\tbridge-ports eno1\n' \
        > "$root/etc/network/interfaces"
    cp /dev/null "$root/varlog/sigmond-firstboot.log"
    [ "$profile" = yes ] && echo "TestAP" > "$root/varlib/sigmond/wifi-ssid"

    # The real helper library, lifted from firstboot the same way.
    awk '/^cat > \/usr\/local\/lib\/sigmond-net.sh <<.NETLIBEOF.$/{f=1;next} /^NETLIBEOF$/{f=0} f' \
        "$REPO/firstboot-v3.sh" > "$root/usrlocallib/sigmond-net.sh"
    [ -s "$root/usrlocallib/sigmond-net.sh" ] || { echo "FATAL: could not extract sigmond-net.sh"; exit 1; }

    # ── stubs ───────────────────────────────────────────────────────────────
    # `ip` is the only one that needs real behaviour: every decision in netfix
    # turns on what it reports for an interface.
    cat > "$root/bin/ip" <<'STUBEOF'
#!/bin/bash
# Only `addr show` needs real behaviour: every decision netfix and sigmond-wifi
# make turns on what this reports.  Everything else is logged and succeeds.
echo "ip $*" >> "$STUBLOG"
case " $* " in *" del "*|*" flush "*|*" add "*|*" set "*) exit 0 ;; esac
case " $* " in *" addr "*|*" address "*) ;; *) exit 0 ;; esac

fam=4; scope=any; dev=""
for a in "$@"; do
    case "$a" in
        -4) fam=4 ;;
        -6) fam=6 ;;
        global) scope=global ;;
        link) scope=link ;;
        -o|-br|addr|address|show|scope|dev) ;;
        *) dev="$a" ;;
    esac
done

# A link-local always exists on an up radio; sigmond-wifi bounces the link if
# this comes back empty, which would be a fake failure, not a real one.
if [ "$fam" = 6 ] && [ "$scope" = link ]; then
    [ "$dev" = wlp3s0 ] && echo "3: wlp3s0    inet6 fe80::1/64 scope link"
    exit 0
fi
case "$dev:$fam:${WIFI_ADDR:-none}" in
    wlp3s0:6:v6) echo "3: wlp3s0    inet6 2001:db8::5/64 scope global" ;;
    wlp3s0:4:v4) echo "3: wlp3s0    inet 192.168.9.5/24 scope global" ;;
esac
# A wired port that a DHCP server actually answers on.
[ "$dev" = eno1 ] && [ "$fam" = 4 ] && [ -n "${ENO1_V4:-}" ] \
    && echo "2: eno1    inet $ENO1_V4/24 scope global"
[ "$dev" = vmbr0 ] && [ "$fam" = 4 ] && [ -n "${VMBR0_V4:-}" ] \
    && echo "4: vmbr0    inet $VMBR0_V4/24 scope global"
exit 0
STUBEOF
    for n in iptables sysctl dhclient ifreload ifup ifdown logger wpa_cli wpa_supplicant wpa_passphrase iw pkill systemctl hostname; do
        printf '#!/bin/bash\necho "%s $*" >> "$STUBLOG"\nexit 0\n' "$n" > "$root/bin/$n"
    done
    # A tracer for the backstop: did netfix actually try to bring the radio up?
    cat > "$root/bin/sigmond-wifi" <<'STUBEOF'
#!/bin/bash
echo "sigmond-wifi $*" >> "$STUBLOG"
[ "${1:-}" = up ] && [ "${WIFI_UP_SUCCEEDS:-no}" = yes ] && export WIFI_ADDR=v6
exit 0
STUBEOF
    chmod +x "$root"/bin/*
}

# Run a command with the fake machine mounted over the real paths.
in_fake(){
    local root="$WORK/root"
    unshare -rm bash -c '
        set -e
        root="$1"; shift
        mount --bind "$root/sys"         /sys/class/net
        mount --bind "$root/etc"         /etc
        mount --bind "$root/usrlocallib" /usr/local/lib
        mount --bind "$root/varlib"      /var/lib
        mount --bind "$root/varlog"      /var/log
        # netfix reaches the Wi-Fi tool by ABSOLUTE path, not through PATH
        # ([ -x /usr/local/sbin/sigmond-wifi ]), so the stubs have to live
        # where it looks or the backstop silently never fires.
        mount --bind "$root/bin" /usr/local/sbin
        export PATH="$root/bin:$PATH"
        exec "$@"
    ' _ "$root" "$@"
}

# Both scripts poll hardware that does not exist here.  Left at their shipped
# defaults (30 s for carrier, 12 × 2 s for a router advertisement, per netfix
# run) this suite takes minutes; the waits themselves are not what is under
# test.  Shrink them through the same knobs an operator would use.
export SIGMOND_CARRIER_WAIT=2 SIGMOND_RA_WAIT=1 SIGMOND_WIFI_ASSOC_WAIT=2

# ⛔ net_dead() writes its banner to /dev/console and the log -- NOT to stdout.
# Reading only stdout made a test that could not see the very failure it exists
# to catch, and it passed for exactly that reason.  Collect both.
run_netfix(){ # run_netfix <outfile>
    local out="$1"
    in_fake bash "$WORK/sigmond-netfix" > "$out" 2>&1
    local rc=$?
    cat "$WORK/root/varlog/sigmond-firstboot.log" >> "$out" 2>/dev/null
    return $rc
}

# ═══════════════════════════════════════════════════════════════════════════
echo
echo "netfix: a radio with an address is not a dead install"
echo "─────────────────────────────────────────────────────"

# ── 1. the regression itself ────────────────────────────────────────────────
build_fake v6 yes
OUT="$WORK/out1"; export STUBLOG="$WORK/stub1"; : > "$STUBLOG"
# ⛔ export, do not prefix.  Assignments written in front of a FUNCTION call
# stay in the calling shell and are NOT exported to the processes it spawns, so
# the stubs inside the namespace never saw them and every netfix case read as
# "no Wi-Fi" -- a harness bug that mimicked the product bug exactly.
export WIFI_ADDR=v6 VMBR0_V4=192.168.100.2
run_netfix "$OUT"
rc=$?
check_not "does not declare a Wi-Fi station dead" "$OUT" "NO NETWORK CABLE DETECTED"
check     "names the live radio"                  "$OUT" "Wi-Fi uplink is live: wlp3s0"
check     "says the config is supported"          "$OUT" "supported configuration"
[ "$rc" = 0 ] && ok "exits 0" || bad "exits 0 (got $rc)"
check     "NATs the decoder VM out the radio"     "$STUBLOG" "POSTROUTING -s 10.99.0.0/30 -o wlp3s0 -j MASQUERADE"
check     "drops the installer's fallback address" "$STUBLOG" "addr del 192.168.100.2/24 dev vmbr0"

# ── 2. the real dead install must STILL be reported ─────────────────────────
# Mutation guard: if the fix above were "never call net_dead", this fails.
build_fake none no
OUT="$WORK/out2"; export STUBLOG="$WORK/stub2"; : > "$STUBLOG"
export WIFI_ADDR=none VMBR0_V4=
run_netfix "$OUT"
rc=$?
check "still reports a genuinely dead install" "$OUT" "NO NETWORK CABLE DETECTED"
[ "$rc" = 1 ] && ok "exits 1 when truly dead" || bad "exits 1 when truly dead (got $rc)"

# ── 3. the backstop: saved profile, radio not yet addressed ─────────────────
build_fake none yes
OUT="$WORK/out3"; export STUBLOG="$WORK/stub3"; : > "$STUBLOG"
export WIFI_ADDR=none VMBR0_V4= WIFI_UP_SUCCEEDS=no
run_netfix "$OUT"
check "tries to bring a saved profile up" "$STUBLOG" "sigmond-wifi up"
check "says why"                          "$OUT"     "saved Wi-Fi profile exists but the radio has no address"

# ── 3b. a LIVE CABLE still wins — the new early exit must not fire ─────────
# The Wi-Fi branch is an early `exit 0`. If it ever fired while a cable was
# live, netfix would stop repairing vmbr0 on every ordinary wired station --
# a far bigger regression than the bug it fixes.
build_fake v6 yes
echo 1 > "$WORK/root/sys/eno1/carrier"          # cable in eno1
OUT="$WORK/out3b"; export STUBLOG="$WORK/stub3b"; : > "$STUBLOG"
export WIFI_ADDR=v6 VMBR0_V4=192.168.100.2 WIFI_UP_SUCCEEDS=no ENO1_V4=10.0.0.50
run_netfix "$OUT"
unset ENO1_V4
check_not "does not short-circuit while a cable works" "$OUT" "this station is on Wi-Fi"
check     "probes the live wired port"                 "$OUT" "trying IPv4 DHCP on eno1"
check     "and rebinds vmbr0 to it"                    "$OUT" "selected eno1"

# ═══════════════════════════════════════════════════════════════════════════
echo
echo "sigmond-wifi: addressing must survive the reboot"
echo "─────────────────────────────────────────────────"

# ── 4. join installs AND enables the boot unit ──────────────────────────────
build_fake v6 no
OUT="$WORK/out4"; export STUBLOG="$WORK/stub4"; : > "$STUBLOG"
cat > "$WORK/root/bin/wpa_cli" <<'EOF'
#!/bin/bash
echo "wpa_cli $*" >> "$STUBLOG"
case "$*" in *status*) echo "wpa_state=COMPLETED"; echo "freq=5180";; *list_networks*) echo "0 TestAP any [CURRENT]";; esac
EOF
printf '#!/bin/bash\necho "wpa_passphrase $*" >> "$STUBLOG"\nprintf "network={\\n\\tssid=\\"%%s\\"\\n\\tpsk=abc\\n}\\n" "$1"\n' > "$WORK/root/bin/wpa_passphrase"
chmod +x "$WORK/root/bin/wpa_cli" "$WORK/root/bin/wpa_passphrase"
export SIGMOND_WIFI_DEV=wlp3s0 WIFI_ADDR=v6
printf 'secretpass' | in_fake bash "$REPO/sigmond-wifi" join TestAP > "$OUT" 2>&1
UNIT="$WORK/root/etc/systemd/system/sigmond-wifi-up.service"
[ -f "$UNIT" ] && ok "join writes sigmond-wifi-up.service" || bad "join writes sigmond-wifi-up.service"
if [ -f "$UNIT" ]; then
    check "unit runs the addressing path"  "$UNIT" "ExecStart=/usr/local/sbin/sigmond-wifi up"
    check "unit is ordered after wpa"      "$UNIT" "After=wpa_supplicant@wlp3s0.service"
    check "unit pins the radio it joined"  "$UNIT" "Environment=SIGMOND_WIFI_DEV=wlp3s0"
fi
check "join enables it"       "$STUBLOG" "systemctl enable sigmond-wifi-up.service"
check "join saves the ssid"   "$OUT"     "addressing will be re-applied at every boot"

# ── 5. `up` waits for association, then addresses ───────────────────────────
OUT="$WORK/out5"; export STUBLOG="$WORK/stub5"; : > "$STUBLOG"
export SIGMOND_WIFI_DEV=wlp3s0 WIFI_ADDR=v6
in_fake bash "$REPO/sigmond-wifi" up > "$OUT" 2>&1
check "up re-applies accept_ra=2" "$STUBLOG" "net.ipv6.conf.wlp3s0.accept_ra=2"
check "up asks for an address"    "$OUT"     "IPv6: 2001:db8::5/64"

# ── 6. `up` refuses when the radio never associates ─────────────────────────
printf '#!/bin/bash\necho "wpa_cli $*" >> "$STUBLOG"\ncase "$*" in *status*) echo "wpa_state=SCANNING";; esac\n' \
    > "$WORK/root/bin/wpa_cli"; chmod +x "$WORK/root/bin/wpa_cli"
OUT="$WORK/out6"; export STUBLOG="$WORK/stub6"; : > "$STUBLOG"
export SIGMOND_WIFI_DEV=wlp3s0 WIFI_ADDR=none SIGMOND_WIFI_ASSOC_WAIT=1
in_fake bash "$REPO/sigmond-wifi" up > "$OUT" 2>&1
rc=$?
check "up reports a failed association" "$OUT" "did not associate"
[ "$rc" = 1 ] && ok "up exits 1 when unassociated" || bad "up exits 1 when unassociated (got $rc)"

# ── 7. forget takes the boot unit with it ───────────────────────────────────
OUT="$WORK/out7"; export STUBLOG="$WORK/stub7"; : > "$STUBLOG"
export SIGMOND_WIFI_DEV=wlp3s0
in_fake bash -c 'bash "$0" forget; [ -f /etc/systemd/system/sigmond-wifi-up.service ] && echo UNIT-SURVIVED' \
    "$REPO/sigmond-wifi" > "$OUT" 2>&1
check_not "forget removes the boot unit" "$OUT" "UNIT-SURVIVED"
check     "forget disables it"           "$STUBLOG" "systemctl disable --now sigmond-wifi-up.service"

# ═══════════════════════════════════════════════════════════════════════════
echo
echo "clat gate: the installer's fossil is not an IPv4 uplink"
echo "────────────────────────────────────────────────────────"
# The same station, the same boot.  sigmond-wait-nat64 exists to hold clatd back
# until NAT64 discovery works; on AI6VN-PM it waved clatd straight through
# because it counted `default via 192.168.100.1 dev vmbr0 ... linkdown` -- the
# PVE installer's unroutable fallback -- as a working IPv4 uplink.  clatd then
# lost the discovery race and exited 0, permanently, leaving the IPv4-only
# decoder VM with no egress.

gate_run(){ # gate_run <route-output> <carrier-of-that-dev> <dns64?>
    local route="$1" carrier="$2" dns64="$3" root="$WORK/gate"
    rm -rf "$root"; mkdir -p "$root/bin" "$root/sys/vmbr0" "$root/sys/wlp3s0" "$root/sys/eno1"
    printf '%s\n' "$carrier" > "$root/sys/vmbr0/carrier"
    printf '%s\n' "$carrier" > "$root/sys/eno1/carrier"
    printf '1\n'             > "$root/sys/wlp3s0/carrier"
    printf '#!/bin/bash\n[ "$*" = "-4 route show default" ] && printf "%%s\\n" "$ROUTE"\nexit 0\n' \
        > "$root/bin/ip"
    # getent is how RFC 7050 discovery is actually performed here.
    if [ "$dns64" = yes ]; then
        printf '#!/bin/bash\necho "fd4f:a955:ac3d:64::c000:ab STREAM ipv4only.arpa"\n' > "$root/bin/getent"
    else
        printf '#!/bin/bash\nexit 2\n' > "$root/bin/getent"
    fi
    chmod +x "$root"/bin/*
    ROUTE="$route" SIGMOND_NAT64_WAIT=1 SIGMOND_NAT64_INTERVAL=1 \
        unshare -rm bash -c '
            root="$1"; shift
            mount --bind "$root/sys" /sys/class/net
            export PATH="$root/bin:$PATH"
            exec "$@"
        ' _ "$root" bash "$REPO/sigmond-wait-nat64"
}

FOSSIL='default via 192.168.100.1 dev vmbr0 proto kernel onlink linkdown'
REAL='default via 10.0.0.1 dev eno1 proto dhcp metric 100'

# -- 8. the regression: the fossil must not count as IPv4 --------------------
OUT="$WORK/out8"; gate_run "$FOSSIL" 0 yes > "$OUT" 2>&1; rc=$?
check_not "fossil route is not called a working uplink" "$OUT" "no CLAT needed"
check     "gate waits and finds the NAT64 prefix"       "$OUT" "NAT64 prefix discoverable"
[ "$rc" = 0 ] && ok "gate lets clatd start once discovery works" \
               || bad "gate lets clatd start once discovery works (got $rc)"

# -- 9. a REAL IPv4 uplink still stands clatd down ---------------------------
# Mutation guard: if the fix were "never take the shortcut", this fails and the
# gate would spin for its full deadline on every ordinary dual-stack site.
OUT="$WORK/out9"; gate_run "$REAL" 1 no > "$OUT" 2>&1; rc=$?
check "real IPv4 route still short-circuits" "$OUT" "no CLAT needed"
[ "$rc" = 0 ] && ok "and exits 0" || bad "and exits 0 (got $rc)"

# -- 10b. a route out a port with no cable is not an uplink either -----------
# Not every dead route carries the `linkdown` annotation -- a static route
# written while the cable was out looks perfectly ordinary.  Carrier is the
# question that does not depend on how the route was phrased.
OUT="$WORK/out10b"; gate_run "$REAL" 0 yes > "$OUT" 2>&1; rc=$?
check_not "route out a dark port is not an uplink" "$OUT" "no CLAT needed"
check     "and the gate does its real job instead" "$OUT" "NAT64 prefix discoverable"

# -- 10. no IPv4, no DNS64 yet: hold clatd back ------------------------------
OUT="$WORK/out10"; gate_run "$FOSSIL" 0 no > "$OUT" 2>&1; rc=$?
check "holds clatd back when nothing is discoverable" "$OUT" "not starting clatd yet"
[ "$rc" = 1 ] && ok "and exits 1 so systemd retries" || bad "and exits 1 so systemd retries (got $rc)"

# ═══════════════════════════════════════════════════════════════════════════
echo
echo "usable_gw4: the shared answer to 'is there a gateway that works?'"
echo "──────────────────────────────────────────────────────────────────"
# The CLAT gate got this wrong once; two more callers asked the same question
# the same naive way (the decoder VM's resolver fallback, and the console
# panel's gateway line). The helper now owns it, so it needs its own guards.

gw_run(){ # gw_run <route-output> <carrier-of-eno1> [carrier-of-vmbr0]
    local route="$1" carrier="$2" vcarrier="${3:-0}" root="$WORK/gw"
    rm -rf "$root"; mkdir -p "$root/bin" "$root/lib" "$root/sys/vmbr0" "$root/sys/eno1"
    printf '%s\n' "$vcarrier" > "$root/sys/vmbr0/carrier"
    printf '%s\n' "$carrier"  > "$root/sys/eno1/carrier"
    awk '/^cat > \/usr\/local\/lib\/sigmond-net.sh <<.NETLIBEOF.$/{f=1;next} /^NETLIBEOF$/{f=0} f' \
        "$REPO/firstboot-v3.sh" > "$root/lib/sigmond-net.sh"
    printf '#!/bin/bash\n[ "$*" = "-4 route show default" ] && printf "%%s\\n" "$ROUTE"\nexit 0\n' \
        > "$root/bin/ip"; chmod +x "$root/bin/ip"
    ROUTE="$route" unshare -rm bash -c '
        root="$1"; shift
        mount --bind "$root/sys" /sys/class/net
        export PATH="$root/bin:$PATH"
        . "$root/lib/sigmond-net.sh"
        usable_gw4
    ' _ "$root"
}

got=$(gw_run "$FOSSIL" 0); rc=$?
[ -z "$got" ] && [ "$rc" != 0 ] && ok "fossil gateway yields nothing" \
    || bad "fossil gateway yields nothing (got '$got' rc=$rc)"

got=$(gw_run "$REAL" 1)
[ "$got" = "10.0.0.1" ] && ok "a real gateway is returned" \
    || bad "a real gateway is returned (got '$got')"

got=$(gw_run "$REAL" 0)
[ -z "$got" ] && ok "a gateway out a dark port yields nothing" \
    || bad "a gateway out a dark port yields nothing (got '$got')"

# The case that makes the fossil check load-bearing: the cable IS in the port
# vmbr0 owns, so carrier is 1 and there is no `linkdown` flag -- the installer's
# DHCP simply went unanswered. Carrier cannot catch this one; only knowing the
# address is the fallback can.
got=$(gw_run "default via 192.168.100.1 dev vmbr0 proto kernel onlink" 0 1)
[ -z "$got" ] && ok "fossil on a LIVE port still yields nothing" \
    || bad "fossil on a LIVE port still yields nothing (got '$got')"

got=$(gw_run "$FOSSIL
$REAL" 1)
[ "$got" = "10.0.0.1" ] && ok "picks the real route past the fossil" \
    || bad "picks the real route past the fossil (got '$got')"

echo
echo "─────────────────────────────────────────────────"
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
