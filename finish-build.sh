#!/bin/bash
# v2 golden build finisher: wait for provision-components (incl. capture-prep),
# VALIDATE (smd install rc=0 + capture gate ready), shutdown, compact.
set -u
cd "$HOME/appliance/v2"
exec >> "$PWD/build.log" 2>&1
say(){ echo "[finish $(date '+%T')] $*"; }
KEY="$HOME/appliance/build/applkey"
SSHV(){ ssh -i "$KEY" -p 5556 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 build@127.0.0.1 "$@"; }

say "waiting for GOLDEN PREP DONE (up to 2h)"
for i in $(seq 1 240); do
  SSHV "grep -q 'GOLDEN PREP DONE' provision.log" 2>/dev/null && break
  sleep 30
done
SSHV "grep -q 'GOLDEN PREP DONE' provision.log" || { say "FATAL: components/capture timeout"; SSHV "tail -30 provision.log"; exit 1; }

say "validating"
INSTALL_RC=$(SSHV "grep -o 'smd install exit=[0-9]*' provision.log | tail -1")
CAPTURE_RC=$(SSHV "grep -o 'capture-prep exit=[0-9]*' provision.log | tail -1")
GATE=$(SSHV "grep -o '\"ready\": *[a-z]*' capture-gate.json 2>/dev/null | head -1")
say "markers: $INSTALL_RC / $CAPTURE_RC / gate=$GATE"
echo "$INSTALL_RC" | grep -q "exit=0" || { say "FATAL: smd install failed"; SSHV "grep -B2 -A8 'smd install exit' provision.log | tail -20"; exit 1; }
echo "$GATE" | grep -q "true" || { say "FATAL: capture gate not ready"; SSHV "cat capture-gate.json"; exit 1; }

say "shutting down VM (halt)"
SSHV "sudo shutdown -h now" 2>/dev/null
for i in $(seq 1 36); do pgrep -f "name goldenv2" >/dev/null || break; sleep 5; done
pgrep -f "name goldenv2" >/dev/null && { say "force stop"; sudo pkill -f "name goldenv2"; sleep 3; }

say "compacting template"
qemu-img convert -O qcow2 -c golden-v2.qcow2 sigmond-decoder-template-v2.qcow2
ls -la sigmond-decoder-template-v2.qcow2
say "GOLDEN VM BUILD COMPLETE"
