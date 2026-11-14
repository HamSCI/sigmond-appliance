#!/bin/bash
# test-host-link-firstboot.sh — first boot installs the satellite guard's host side
# (sigmond-link, inert until the VM's [link_schedule] enables it) on every new host,
# after host-apply succeeded and before the install is marked finalized.
# Plan: sigmond docs/superpowers/plans/2026-11-14-satellite-host-guard.md, Task 2.
set -u
cd "$(dirname "$0")" || exit 1
F=firstboot-v3.sh
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok    $*"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL  $*"; }
bash -n "$F" || { echo "FATAL: $F does not parse"; exit 1; }
call=$(grep -n 'install-host-link.sh' "$F" | head -1 | cut -d: -f1)
tuned=$(grep -n 'say "finalize: host tuned' "$F" | head -1 | cut -d: -f1)
fin=$(awk -v t="${tuned:-0}" 'NR>t && /^finalized$/{print NR; exit}' "$F")
[ -n "$call" ] && ok "firstboot runs install-host-link.sh" || bad "firstboot never runs install-host-link.sh"
[ -n "$call" ] && [ -n "$tuned" ] && [ "$call" -gt "$tuned" ] && ok "after host-apply succeeded" || bad "not after host-apply's success"
[ -n "$call" ] && [ -n "$fin" ] && [ "$call" -lt "$fin" ] && ok "before finalized" || bad "not before finalized"
grep -q 'VMID="$VMID" bash "$SIG/scripts/proxmox/install-host-link.sh"' "$F" && ok "passes VMID" || bad "does not pass VMID"
grep -A1 'install-host-link.sh' "$F" | grep -q 'WARNING' && ok "a failed install is a warning, never a stop" || bad "a failed install could stop first boot"
echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
