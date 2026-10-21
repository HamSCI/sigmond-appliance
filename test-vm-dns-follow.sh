#!/bin/bash
# test-vm-dns-follow.sh — the decoder VM's resolver follows the host's
# resolv.conf instead of freezing the install site's resolver.
#
# AC1SN (DASI-017) was installed on a school LAN whose resolver is 192.168.1.1,
# and both places that write /etc/dnsmasq.d/sigmond-vm.conf wrote
#     no-resolv
#     server=192.168.1.1
# On 2026-10-16 the unit moved to a home LAN (10.0.0.0/24).  The host took a
# new lease and a new resolv.conf; the VM kept asking 192.168.1.1, so it had no
# DNS -- git fetches and every upload failed -- until the file was edited by
# hand.  The pin is only right when resolv.conf names nothing usable (empty or
# loopback); then the fallback chain decides, exactly as before.
#
# Both writers are extracted verbatim from firstboot-v3.sh (sigmond-import.sh
# and sigmond-v6-gateway), pointed at a scratch resolv.conf and dnsmasq.d, and
# run.  Pass a different firstboot-v3.sh as $1 to run this against a mutant.
set -u
cd "$(dirname "$(readlink -f "$0")")"
FB="${1:-firstboot-v3.sh}"
[ -f "$FB" ] || { echo "FATAL: no firstboot-v3.sh at $FB"; exit 1; }
pass=0; fail=0
ok(){  printf '  ✓ %s\n' "$1"; pass=$((pass+1)); }
bad(){ printf '  ✗ %s\n     %s\n' "$1" "$2"; fail=$((fail+1)); }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Pull each writer out, from its resolv.conf read to the end of its heredoc, and
# redirect its absolute paths into $TMP.
python3 - "$FB" "$TMP" <<'PYX'
import re, sys, pathlib
s = pathlib.Path(sys.argv[1]).read_text(); t = sys.argv[2]
def grab(heredoc, start, end):
    body = re.search(r"<<'%s'\n(.*?)\n%s\n" % (heredoc, heredoc), s, re.S)
    if not body: raise SystemExit("no heredoc " + heredoc)
    b = body.group(1)
    i = b.index(start); j = b.index(end, i) + len(end)
    return b[i:j]
def fix(c):
    return (c.replace("/etc/resolv.conf", t + "/resolv.conf")
             .replace("/etc/dnsmasq.d", t + "/dnsmasq.d")
             .replace("/usr/local/lib/sigmond-net.sh", t + "/sigmond-net.sh"))
# Only the resolver logic: never the vmbr1 / ifup / iptables lines that sit
# between the two halves of the install writer.
imp = (grab("IMPEOF", "PM_DNS=$(awk", "PM_DNS=1.1.1.1") + "\n"
       + grab("IMPEOF", "if command -v dnsmasq >/dev/null 2>&1; then\n    # ⛔ FOLLOW", "\nDNSEOF")
       + "\nfi\n")
v6  = grab("V6GWEOF", "    up=$(awk", "\nCONF")
pathlib.Path(t, "imp.sh").write_text("set -u\nMGMT_PM=10.99.0.1\n" + fix(imp) + "\n")
pathlib.Path(t, "v6.sh").write_text("set -u\nMGMT_PM_IP=10.99.0.1\n" + fix(v6) + "\n")
PYX
# dnsmasq only has to exist for `command -v`; it is never run.
mkdir -p "$TMP/bin"; printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/dnsmasq"; chmod +x "$TMP/bin/dnsmasq"
export PATH="$TMP/bin:$PATH"
[ -s "$TMP/imp.sh" ] && [ -s "$TMP/v6.sh" ] || { echo "FATAL: extraction failed"; exit 1; }
# usable_gw4 stand-in: the gateway the fallback chain would find.
printf 'usable_gw4(){ echo 192.168.7.1; }\n' > "$TMP/sigmond-net.sh"
mkdir -p "$TMP/dnsmasq.d"

conf="$TMP/dnsmasq.d/sigmond-vm.conf"
run(){ # run <script> <resolv.conf contents>
    rm -f "$conf"; printf '%b' "$2" > "$TMP/resolv.conf"
    bash "$TMP/$1" > "$TMP/out" 2>&1 || { cat "$TMP/out"; return 1; }
}
follows(){ ! grep -q '^no-resolv' "$conf" && ! grep -q '^server=' "$conf"; }

for w in imp v6; do
    case $w in imp) name="install (sigmond-import.sh)";; v6) name="IPv6-only gateway (sigmond-v6-gateway)";; esac
    echo "── $name ──"
    run $w.sh 'nameserver 192.168.1.1\n'
    follows && ok "a real resolver in resolv.conf: no pin, dnsmasq follows the file" \
        || bad "the resolver was frozen into sigmond-vm.conf" "$(grep -E '^(no-resolv|server=)' "$conf" | tr '\n' ' ')"
    grep -q '^listen-address=10.99.0.1' "$conf" && grep -q '^filter-AAAA' "$conf" \
        && ok "the rest of the config is unchanged" || bad "config lost its other lines" "$(cat "$conf")"
    run $w.sh 'nameserver 127.0.0.53\n'
    grep -q '^no-resolv' "$conf" && grep -q '^server=' "$conf" \
        && ok "loopback in resolv.conf: still pinned (the fallback case)" \
        || bad "loopback resolv.conf no longer pinned" "dnsmasq would forward to itself / nothing"
done

echo "── install: the fallback chain still decides the pinned server ──"
run imp.sh 'nameserver 127.0.0.53\n'
grep -q '^server=192.168.7.1$' "$conf" && ok "loopback -> pinned to the usable gateway" \
    || bad "fallback server wrong" "$(grep '^server=' "$conf")"
run imp.sh ''
grep -q '^server=192.168.7.1$' "$conf" && ok "empty resolv.conf -> pinned to the usable gateway" \
    || bad "fallback server wrong" "$(grep '^server=' "$conf")"

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
