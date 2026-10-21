#!/bin/bash
# test-netfix-marker.sh — a host with a real address never keeps telling the
# operator it has none.
#
# AC1SN (DASI-017), 2026-10-17 19:20 UTC: the cable was pulled while the host
# was up (the unit was being moved).  netfix waited 30 s for a link, wrote
# /etc/sigmond-appliance/.network-unreachable, and the panel began printing
#   !! THIS HOST HAS NO WORKING NETWORK ADDRESS — NO NETWORK CABLE DETECTED
#   !!   The addresses below are NOT reachable.
# The cable went back in and every later netfix run found vmbr0 holding a
# good address -- and took the healthy branch, whose exits never removed the
# marker.  Only the branches that REPAIR something did.  Three days later the
# station was on a working LAN, reachable over the RAC, and its console still
# said it had no network.  rob: "this is not a problem with his site in
# particular. It seems to be a bug in Sigmond."
set -u
# Take the file under test as an argument, so a mutant can be pointed at.
cd "$(dirname "$(readlink -f "$0")")"
FB="${1:-firstboot-v3.sh}"
[ -f "$FB" ] || { echo "FATAL: no firstboot-v3.sh at $FB"; exit 1; }
pass=0; fail=0
ok(){  printf '  ✓ %s\n' "$1"; pass=$((pass+1)); }
bad(){ printf '  ✗ %s\n     %s\n' "$1" "$2"; fail=$((fail+1)); }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

python3 - "$FB" "$TMP/netfix.sh" <<'PYX'
import re, sys, pathlib
s = pathlib.Path(sys.argv[1]).read_text()
m = re.search(r"cat > /usr/local/sbin/sigmond-netfix <<'NETFIXEOF'\n(.*?)\nNETFIXEOF\n", s, re.S)
if not m: raise SystemExit("could not extract sigmond-netfix")
pathlib.Path(sys.argv[2]).write_text(m.group(1))
PYX
[ -s "$TMP/netfix.sh" ] || { echo "FATAL: extraction failed"; exit 1; }
grep -vE '^[[:space:]]*#' "$TMP/netfix.sh" > "$TMP/netfix.code"   # code, not comments

# The healthy branch: from the `*)` arm of `case "$IP" in` to its `esac`.
python3 - "$TMP/netfix.code" "$TMP/healthy" <<'PYX'
import re, sys, pathlib
s = pathlib.Path(sys.argv[1]).read_text()
m = re.search(r'case "\$IP" in\n(.*?)\nesac', s, re.S)
if not m: raise SystemExit("no case \"$IP\" in ... esac")
arm = m.group(1).split("\n    *)\n", 1)
if len(arm) != 2: raise SystemExit("no *) arm")
pathlib.Path(sys.argv[2]).write_text(arm[1])
PYX
[ -s "$TMP/healthy" ] || { echo "FATAL: could not isolate the healthy branch"; exit 1; }

echo "── the real-address branch clears the no-network marker ──────────"
rm_line=$(grep -n 'rm -f /etc/sigmond-appliance/.network-unreachable' "$TMP/healthy" | head -1 | cut -d: -f1)
[ -n "$rm_line" ] && ok "the healthy branch removes .network-unreachable" \
    || bad "the healthy branch never removes .network-unreachable" \
           "a host that recovered by itself shows 'NO WORKING NETWORK ADDRESS' forever"

echo "── it does so before ANY exit of that branch ─────────────────────"
first_exit=$(grep -n 'exit 0' "$TMP/healthy" | head -1 | cut -d: -f1)
if [ -n "$rm_line" ] && [ -n "$first_exit" ] && [ "$rm_line" -lt "$first_exit" ]; then
    ok "marker removed (line $rm_line) before the branch's first exit (line $first_exit)"
else
    bad "an exit in the healthy branch comes before the marker is removed" \
        "the common case -- DHCP stanza, '|| exit 0' -- would keep the stale alarm"
fi

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
