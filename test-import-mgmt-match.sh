#!/bin/bash
# test-import-mgmt-match.sh — the decoder VM's management network must match
# net0 alone.  `Name=en*` caught USB Ethernet adapters (v3.88), and
# `Driver=virtio_net` caught the radionet NIC on vmbr9 (IPv6 lab, 2026-11-11):
# both VMs put 10.99.0.2/30 on ens18 AND ens19.
set -u
cd "$(dirname "$(readlink -f "$0")")"
FB="${1:-firstboot-v3.sh}"
pass=0; fail=0
ok(){  printf '  ✓ %s\n' "$1"; pass=$((pass+1)); }
bad(){ printf '  ✗ %s\n     %s\n' "$1" "$2"; fail=$((fail+1)); }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
python3 - "$FB" "$TMP/imp.sh" <<'PYX'
import re, sys, pathlib
s = pathlib.Path(sys.argv[1]).read_text()
m = re.search(r"cat > /usr/local/sbin/sigmond-import.sh <<'IMPEOF'\n(.*?)\nIMPEOF\n", s, re.S)
if not m: raise SystemExit("could not extract sigmond-import.sh")
pathlib.Path(sys.argv[2]).write_text(m.group(1))
PYX
grep -vE '^[[:space:]]*#' "$TMP/imp.sh" > "$TMP/code"
blk=$(awk '/_mgmt_conf=\$\(printf/{f=1} f{print} f&&/base64/{exit}' "$TMP/code")
printf '%s' "$blk" | grep -q '"\$_mgmt_match"' && ok "the [Match] line is net0's computed match" \
    || bad "the [Match] line is not the computed match" "$(printf '%s' "$blk" | grep -A1 Match | tail -1)"
printf '%s' "$blk" | grep -qE "^[[:space:]]*'(Driver=virtio_net|Name=en\*)'" \
    && bad "a fixed driver/name match is still in the [Match]" "" || ok "no fixed driver or name match"
grep -q '_mgmt_match="MACAddress=\$_net0_mac"' "$TMP/code" && ok "net0's MAC is the match" || bad "no MACAddress match" ""
grep -q '_mgmt_match="Driver=virtio_net"' "$TMP/code" && ok "driver match kept only as the fallback" || bad "no fallback" ""
sedx=$(grep -o "sed -n 's/^net0:[^']*'" "$TMP/code" | head -1 | sed "s/^sed -n //; s/^'//; s/'\$//")
cfg='boot: order=scsi0
net0: virtio=BC:24:11:94:78:5B,bridge=vmbr1
net1: virtio=BC:24:11:8C:89:25,bridge=vmbr9,mtu=1'
got=$(printf '%s\n' "$cfg" | sed -n "$sedx" | tr 'A-F' 'a-f')
[ "$got" = bc:24:11:94:78:5b ] && ok "net0's MAC read, not net1's ($got)" || bad "MAC extraction" "got '$got'"
got=$(printf 'net1: virtio=BC:24:11:8C:89:25,bridge=vmbr9\n' | sed -n "$sedx")
[ -z "$got" ] && ok "no net0 line: nothing read (falls back)" || bad "read a MAC from net1" "$got"
echo; echo "$pass passed, $fail failed"; [ "$fail" -eq 0 ]
