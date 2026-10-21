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
      out=$(grep -E "^[0-9]+: $dev " "$STUB_ADDR" 2>/dev/null)
      case "$args" in
        *"-4"*) printf '%s\n' "$out" | grep "inet " ;;
        *"-6"*) printf '%s\n' "$out" | grep "inet6" ;;
        *)      printf '%s\n' "$out" ;;
      esac ;;
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

# ── the guard must not fire before the v6 config is PERSISTENT ─────────────
# rob, 2026-10-21, a wired IPv6-only Bud Pro box.  On a FIRST boot vmbr0
# already has a SLAAC address and a default route -- IPv6 forwarding is still
# 0, because only the inet6 stanza's post-up turns it on, so accept_ra=1 is
# honoured.  An unconditional guard therefore ran INSTEAD of the branch that
# removes the fossil 192.168.100.2, strips the dead static stanza and writes
# the stanza that makes the site survive a reboot.
echo "── first boot must fall through; later boots may short-circuit ───"
python3 - "$TMP/netfix.sh" "$TMP/cond.sh" <<'PYX'
import re, sys, pathlib
s = pathlib.Path(sys.argv[1]).read_text()
m = re.search(r'(_v4_unusable=no\n.*?v6_uplink_on vmbr0; then)', s, re.S)
if not m: raise SystemExit("could not isolate the guard condition")
cond = m.group(1)
cond = cond[:-len("; then")] + "; then echo FIRE; else echo SKIP; fi\n"
pathlib.Path(sys.argv[2]).write_text(cond)
PYX
if [ -s "$TMP/cond.sh" ]; then
  decide(){ # decide <name> <expect FIRE|SKIP> <IP> <ifaces> <addr> <route>
      printf '%s\n' "$4" > "$TMP/ifaces"
      printf '%s\n' "$5" > "$STUB_ADDR"
      printf '%s\n' "$6" > "$STUB_ROUTE"
      got=$(IP="$3" IFACES="$TMP/ifaces" bash -c ". '$TMP/net.sh' 2>/dev/null; . '$TMP/cond.sh'" 2>/dev/null | tail -1)
      if [ "$got" = "$2" ]; then ok "$1"
      else bad "$1" "guard said $got, expected $2"; fi
  }
  V6ADDR="1: vmbr0    inet6 fd4f:a955:ac3d:1:8647:9ff:fe1b:29ee/64 scope global"
  FOSSIL="1: vmbr0    inet 192.168.100.2/24 scope global"
  RT="default via fe80::4a6d:6065 dev vmbr0 proto ra metric 1024 pref medium"
  RADIO="default via fe80::dea6:32ff dev wlp3s0 proto ra metric 1024 pref medium"

  decide "FIRST BOOT (no inet6 stanza, fossil present) falls through" SKIP \
      "192.168.100.2" "iface vmbr0 inet static
	address 192.168.100.2/24" "$V6ADDR
$FOSSIL" "$RT"

  decide "a later boot (stanza written, fossil gone) short-circuits" FIRE \
      "" "iface vmbr0 inet6 auto" "$V6ADDR" "$RT"

  decide "stanza written but the fossil is STILL on vmbr0 falls through" SKIP \
      "192.168.100.2" "iface vmbr0 inet6 auto" "$V6ADDR
$FOSSIL" "$RT"

  decide "stanza written, fossil gone, but the route is via the RADIO" SKIP \
      "" "iface vmbr0 inet6 auto" "$V6ADDR" "$RADIO"

  # ⛔ Isolates the PERSISTENCE requirement from the fossil requirement.
  # Without this case every first-boot scenario also carries the fossil, so
  # the fossil check alone would satisfy the suite and dropping the stanza
  # check would go unnoticed.  vmbr0 can hold a SLAAC address with no fossil
  # (the installer found a v4 lease once, or someone cleared it by hand); the
  # stanza still has to be written or the next boot has no config at all.
  decide "no stanza and no fossil either still falls through" SKIP \
      "" "iface vmbr0 inet static" "$V6ADDR" "$RT"

  # ⛔ Another interface's inet6 stanza is NOT vmbr0's.  firstboot writes
  # `iface <wifi> inet6 auto` for a bridged radio (the _wl_bridged branch), so
  # a dual-homed host really does carry one while vmbr0 has none.  A
  # persistence test that greps for "inet6" anywhere in the file would read
  # the radio's stanza as vmbr0's and short-circuit a first boot.
  decide "another interface's inet6 stanza does not count as vmbr0's" SKIP \
      "" "iface vmbr0 inet static
iface wlp3s0 inet6 auto" "$V6ADDR" "$RT"

  decide "a real IPv4 address never takes the IPv6 path" SKIP \
      "192.168.1.50" "iface vmbr0 inet6 auto" "$V6ADDR
1: vmbr0    inet 192.168.1.50/24 scope global" "$RT"
else
  bad "could not isolate the guard condition" "the guard was restructured"
fi

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
