#!/bin/bash
# test-netfix-ipv6-site.sh — an IPv6-only site is not a broken site.
#
# Chris, Jenny Jump, v3.70, 2026-10-20 (v3.74 row 3): first boot printed
#   vmbr0 is on the PVE installer fallback 192.168.100.2 — that address is
#   not routable here
# and then hunted every port with dhclient.  The station was up and serving
# over IPv6 the whole time; the screen read as a fault and he concluded the
# installer had never got an IPv6 address.
#
# The hunt is also slow and destructive there -- 25 s of dhclient per port and
# `ip addr flush` on each candidate -- and it runs on EVERY boot, because an
# IPv6-only site never acquires the IPv4 that would quiet it.
#
# The guard must be scoped to vmbr0.  A bare `ip -6 route show default` is
# true because of the RADIO on a dual-homed host (AI6VN-PM carries both, each
# with its own RA), and would excuse a bridge that reaches nothing.
set -u
cd "$(dirname "$(readlink -f "$0")")"
FB="${1:-firstboot-v3.sh}"
[ -f "$FB" ] || { echo "FATAL: no firstboot-v3.sh at $FB"; exit 1; }
pass=0; fail=0
ok(){  printf '  ✓ %s\n' "$1"; pass=$((pass+1)); }
bad(){ printf '  ✗ %s\n     %s\n' "$1" "$2"; fail=$((fail+1)); }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# ── extract the shared net lib and the netfix script verbatim ──────────────
python3 - "$FB" "$TMP/net.sh" "$TMP/netfix.sh" <<'PYX'
import re, sys, pathlib
s = pathlib.Path(sys.argv[1]).read_text()
lib = re.search(r"cat > /usr/local/lib/sigmond-net\.sh <<'NETLIBEOF'\n(.*?)\nNETLIBEOF\n", s, re.S)
if not lib: raise SystemExit("could not extract sigmond-net.sh")
pathlib.Path(sys.argv[2]).write_text(lib.group(1))
nf = re.search(r"cat > /usr/local/sbin/sigmond-netfix <<'NETFIXEOF'\n(.*?)\nNETFIXEOF\n", s, re.S)
if not nf: raise SystemExit("could not extract sigmond-netfix")
pathlib.Path(sys.argv[3]).write_text(nf.group(1))
PYX
[ -s "$TMP/net.sh" ] && [ -s "$TMP/netfix.sh" ] || { echo "FATAL: extraction failed"; exit 1; }
bash -n "$TMP/net.sh"    || { echo "FATAL: extracted net.sh does not parse"; exit 1; }
bash -n "$TMP/netfix.sh" || { echo "FATAL: extracted netfix does not parse"; exit 1; }

# ── a stub `ip` driven by two files: the addr table and the route table ────
mkdir -p "$TMP/bin"
cat > "$TMP/bin/ip" <<'IPEOF'
#!/bin/bash
# ip -6 -o addr show <dev> scope global   |   ip -6 route show default
args="$*"
case "$args" in
  *"addr show"*)
      dev=""; for w in $args; do [ "$prev" = show ] && dev="$w"; prev="$w"; done
      grep -E "^[0-9]+: $dev " "$STUB_ADDR" 2>/dev/null ;;
  *"route show default"*)
      cat "$STUB_ROUTE" 2>/dev/null ;;
esac
exit 0
IPEOF
chmod +x "$TMP/bin/ip"
export PATH="$TMP/bin:$PATH"
export STUB_ADDR="$TMP/addr" STUB_ROUTE="$TMP/route"

# shellcheck disable=SC1090
. "$TMP/net.sh" 2>/dev/null
type v6_uplink_on >/dev/null 2>&1 \
    && ok "v6_uplink_on() is defined in the shared net lib" \
    || { bad "v6_uplink_on() is missing from sigmond-net.sh" \
             "netfix sources this lib; without the helper the guard cannot be scoped"
         echo; echo "passed: $pass   failed: $fail"; exit 1; }

try(){ # try <name> <expect 0|1> <addr lines> <route lines>
    printf '%s\n' "$3" > "$STUB_ADDR"
    printf '%s\n' "$4" > "$STUB_ROUTE"
    if v6_uplink_on vmbr0; then got=0; else got=1; fi
    if [ "$got" = "$2" ]; then ok "$1"
    else bad "$1" "v6_uplink_on vmbr0 returned $got, expected $2"; fi
}

echo "── v6_uplink_on() asks of the DEVICE ─────────────────────────────"
try "a wired IPv6-only site: vmbr0 has a global v6 and the default route" 0 \
    "1: vmbr0    inet6 fd4f:a955:ac3d:1:8647:9ff:fe1b:29ee/64 scope global" \
    "default via fe80::4a6d:6065 dev vmbr0 proto ra metric 1024 pref medium"

try "DUAL-HOMED: the v6 default route is on the RADIO, vmbr0 is not an uplink" 1 \
    "1: vmbr0    inet6 fd4f:a955:ac3d:1:8647:9ff:fe1b:29ee/64 scope global" \
    "default via fe80::dea6:32ff dev wlp3s0 proto ra metric 1024 pref medium"

try "both: vmbr0 counts when it has a default route of its own" 0 \
    "1: vmbr0    inet6 fd4f:a955:ac3d:1:8647:9ff:fe1b:29ee/64 scope global" \
    "default via fe80::dea6:32ff dev wlp3s0 proto ra metric 1024 pref medium
default via fe80::4a6d:6065 dev vmbr0 proto ra metric 1024 pref medium"

try "no global IPv6 on vmbr0 at all" 1 \
    "" \
    "default via fe80::4a6d:6065 dev vmbr0 proto ra metric 1024 pref medium"

try "a tentative address is not an uplink" 1 \
    "1: vmbr0    inet6 fd4f:a955:ac3d:1::5/64 scope global tentative" \
    "default via fe80::4a6d:6065 dev vmbr0 proto ra metric 1024 pref medium"

try "a deprecated address is not an uplink" 1 \
    "1: vmbr0    inet6 fd4f:a955:ac3d:1::5/64 scope global deprecated" \
    "default via fe80::4a6d:6065 dev vmbr0 proto ra metric 1024 pref medium"

try "vmbr0x must not satisfy the check for vmbr0 (whole-field match)" 1 \
    "1: vmbr0    inet6 fd4f:a955:ac3d:1::5/64 scope global" \
    "default via fe80::4a6d:6065 dev vmbr0x proto ra metric 1024 pref medium"

# ── the guard, in netfix, in the right place ───────────────────────────────
echo "── the guard sits ahead of the dhclient hunt ─────────────────────"
code=$(grep -vE '^[[:space:]]*#' "$TMP/netfix.sh")
g=$(printf '%s\n' "$code" | grep -n 'v6_uplink_on vmbr0' | head -1 | cut -d: -f1)
h=$(printf '%s\n' "$code" | grep -n 'dhclient' | head -1 | cut -d: -f1)
if [ -n "$g" ] && [ -n "$h" ] && [ "$g" -lt "$h" ]; then
    ok "netfix consults v6_uplink_on (line $g) before its first dhclient (line $h)"
else
    bad "netfix reaches dhclient without asking whether vmbr0 is a v6 uplink" \
        "an IPv6-only site re-hunts every port on every boot"
fi

echo "── the guard is scoped, and clears the stale alarm before exiting ─"
blk=$(printf '%s\n' "$code" | sed -n '/_v4_unusable=no/,/^fi$/p')
if [ -n "$blk" ]; then
    printf '%s\n' "$blk" | grep -q 'v6_uplink_on vmbr0' \
        && ok "the guard asks v6_uplink_on vmbr0, not a bare default-route test" \
        || bad "the guard does not call v6_uplink_on vmbr0" \
               "a bare 'ip -6 route show default' is true because of the radio"
    r=$(printf '%s\n' "$blk" | grep -n 'rm -f /etc/sigmond-appliance/.network-unreachable' | head -1 | cut -d: -f1)
    e=$(printf '%s\n' "$blk" | grep -n 'exit 0' | head -1 | cut -d: -f1)
    if [ -n "$r" ] && [ -n "$e" ] && [ "$r" -lt "$e" ]; then
        ok "it removes .network-unreachable (line $r) before its exit (line $e)"
    else
        bad "the IPv6 guard exits without clearing .network-unreachable" \
            "a healthy v6 station would keep printing NO WORKING NETWORK ADDRESS"
    fi
    printf '%s\n' "$blk" | grep -q 'exit 0' \
        && ok "it stops netfix rather than falling through to the hunt" \
        || bad "the guard does not exit" "the destructive hunt still runs"
else
    bad "could not find the IPv6-site guard in netfix" "row 3 is not implemented"
fi

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
