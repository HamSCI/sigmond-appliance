#!/bin/bash
# test-vm-console.sh — the split console ships, and its two copies cannot drift.
#
# ⛔ WHY THE DRIFT CHECK.  The VM-side files exist TWICE on purpose: readable
# and reviewable in vm-console/, and embedded in firstboot-v3.sh because the
# template must stand alone (it cannot git-pull at first boot). Two copies of
# anything is how they diverge, and this pair diverging is especially bad: the
# repo copy is what a human reads and fixes, while the EMBEDDED copy is what
# every station actually runs. A fix applied to the readable one and not the
# shipped one would look done and change nothing.
#
# ⛔ WHY IT MUST SHIP AT ALL.  The Proxmox host has no keyboard and no USB —
# both controllers are vfio-pci for the decoder VM. When the network is the
# broken thing, the only way in is: type in the VM, read on the host's monitor,
# over the 10.99.0.0/30 link that has no physical port. A recovery path you
# have to install over the network is not a recovery path, so it cannot be a
# manual post-install step.
#
#   usage: ./test-vm-console.sh [path/to/firstboot-v3.sh]
set -u
SRC="${1:-$(dirname "$0")/firstboot-v3.sh}"
DIR="$(dirname "$SRC")"
[ -f "$SRC" ] || { echo "FATAL: no firstboot-v3.sh at $SRC"; exit 1; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
chk(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ok    %s\n' "$1"
       else FAIL=$((FAIL+1)); printf '  FAIL  %s\n        want: %s\n        got : %s\n' "$1" "$3" "$2"; fi; }

ex(){ local s e
  s=$(grep -nF "$1" "$SRC" | head -1 | cut -d: -f1)
  e=$(awk -v s="$s" -v m="$2" 'NR>s && $0==m{print NR; exit}' "$SRC")
  [ -n "$s" ] && [ -n "$e" ] || { echo "FATAL: cannot extract $2 from $SRC"; exit 1; }
  sed -n "$((s+1)),$((e-1))p" "$SRC" > "$3"; }

echo "── the embedded copies are byte-for-byte the reviewable ones ──────────"
ex "cat > /usr/local/share/sigmond/vm-console/sigmond-console-bridge <<'VMBRIDGEEOF'"   VMBRIDGEEOF  "$WORK/bridge"
ex "cat > /usr/local/share/sigmond/vm-console/sigmond-console-askpass <<'VMASKPASSEOF'" VMASKPASSEOF "$WORK/askpass"
ex "cat > /usr/local/share/sigmond/vm-console/getty-override.conf <<'VMGETTYEOF'"       VMGETTYEOF   "$WORK/getty"
for p in bridge:sigmond-console-bridge askpass:sigmond-console-askpass \
         getty:getty@tty1.service.d-sigmond-console-bridge.conf; do
    t="${p%%:*}"; f="${p##*:}"
    if cmp -s "$WORK/$t" "$DIR/vm-console/$f"; then chk "embedded $t matches vm-console/$f" ok ok
    else chk "embedded $t matches vm-console/$f" "DIFFERS ($(wc -c <"$WORK/$t") vs $(wc -c <"$DIR/vm-console/$f") bytes)" ok; fi
done
chk "the embedded bridge parses"  "$(bash -n "$WORK/bridge"  2>&1; echo $?)" "0"
chk "the embedded askpass parses" "$(bash -n "$WORK/askpass" 2>&1; echo $?)" "0"

echo "── it is installed by the BUILD, not by a human ───────────────────────"
chk "the import pushes it into the guest" \
    "$(grep -c 'split console installed in the VM' "$SRC")" "1"
chk "  ...via qm guest exec, from the staged copies" \
    "$(grep -c "base64 -w0 /usr/local/share/sigmond/vm-console/sigmond-console-bridge" "$SRC")" "1"
# ⛔ A station with no console bridge is diminished, not broken. Failing the
# import over it would trade a missing convenience for a dead install.
chk "a failed push WARNS, never aborts the import" \
    "$(grep -A3 'could not install the VM console bridge' "$SRC" | grep -c 'exit 1')" "0"
# Presence, not a count: how many times the helper is MENTIONED is incidental
# and a brittle thing to assert. What matters is that it exists as a command.
chk "and it names a retry command that exists" \
    "$(grep -c 'chmod +x /usr/local/sbin/sigmond-vm-console-push' "$SRC")" "1"

echo "── the host half is still there to receive it ─────────────────────────"
chk "relay binds the /30 ONLY, never 0.0.0.0" \
    "$(grep -c 'TCP4-LISTEN:7790,bind=10.99.0.1' "$SRC")" "1"
# Assert it on the ExecStart line itself, not anywhere in the file -- the
# comment above it also says max-children and would satisfy a bare count.
chk "one session at a time (bytes would interleave)" \
    "$(grep -c '^ExecStart=.*TCP4-LISTEN:7790.*max-children=1' "$SRC")" "1"
# Two distinct halves: the paint script HOLDS the flag, the panel HONOURS it.
# Either one alone is the bug -- a held flag nobody checks, or a check against
# a flag nobody sets -- so assert both, not a total.
chk "the paint script holds the session flag" \
    "$(grep -c 'FLAG=/run/sigmond/console-session' "$SRC")" "1"
chk "and the panel refuses to repaint over it" \
    "$(grep -c '\[ ! -e /run/sigmond/console-session \]' "$SRC")" "1"

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
