#!/bin/bash
# sigmond-wizard — first-boot site-identity wizard for the Sigmond appliance.
# Runs on the Proxmox HOST console (tty1 via sigmond-wizard.service, or
# rerun any time as `sigmond-setup`).  Prompts for the few per-site facts,
# pushes them into the decoder VM via the qemu guest agent, and (optionally)
# activates the host-side RAC tunnel.
#
# Prompts: reporter ID (required)   e.g. AC0G/B4 — drives ALL upload paths
#          grid square (required)   e.g. EM38ww
#          antenna     (optional)   free text
#          RAC user + token (optional; from the WsprDaemon admin) — activates
#                                   the HOST tunnel (host SSH + Proxmox GUI)
set -u
VMID="${SIGMOND_VMID:-120}"
MARK_DIR=/etc/sigmond-appliance
CONF_MARK="$MARK_DIR/.configured"
LOG=/var/log/sigmond-wizard.log
say(){ echo "[wizard] $*" | tee -a "$LOG"; }

mkdir -p "$MARK_DIR"
if [ -e "$CONF_MARK" ] && [ "${1:-}" != "--reconfigure" ]; then
    say "already configured ($(cat "$CONF_MARK")). Run 'sigmond-setup --reconfigure' to redo."
    exit 0
fi

# ── wait for decoder VM + guest agent ───────────────────────────────────────
say "waiting for decoder VM $VMID and its guest agent..."
for i in $(seq 1 60); do
    qm agent "$VMID" ping >/dev/null 2>&1 && break
    [ "$i" = 1 ] && qm start "$VMID" >/dev/null 2>&1
    sleep 5
done
if ! qm agent "$VMID" ping >/dev/null 2>&1; then
    say "ERROR: guest agent in VM $VMID not answering — is the decoder VM imported and running?"
    say "        (plug in the Sigmond USB to trigger import, then rerun sigmond-setup)"
    exit 1
fi

gexec(){ # gexec <timeout-s> <command...>  → runs in guest, echoes exitcode
    local t="$1"; shift
    local out rc
    out=$(qm guest exec "$VMID" --timeout "$t" -- bash -lc "$*" 2>&1)
    rc=$(echo "$out" | grep -o '"exitcode" *: *[0-9-]*' | grep -o '[0-9-]*$' | head -1)
    echo "$out" >> "$LOG"
    [ "${rc:-1}" = "0" ]
}

# ── prompts ─────────────────────────────────────────────────────────────────
echo ""
echo "──────────────────────────────────────────────────────"
echo "  Sigmond station setup — a few questions and you're on the air"
echo "──────────────────────────────────────────────────────"

REPORTER=""
while [ -z "$REPORTER" ]; do
    read -r -p "Reporter ID (your callsign, optionally /suffix — e.g. AC0G/B4): " REPORTER
    REPORTER=$(echo "$REPORTER" | tr '[:lower:]' '[:upper:]' | tr -d ' ')
    echo "$REPORTER" | grep -qE '^[A-Z0-9]{3,}(/[A-Z0-9]+)?$' || { echo "  ✗ that doesn't look like a callsign"; REPORTER=""; }
done
CALLSIGN="${REPORTER%%/*}"

GRID=""
while [ -z "$GRID" ]; do
    read -r -p "Grid square (Maidenhead, e.g. EM38ww): " GRID
    GRID=$(echo "$GRID" | tr -d ' ')
    echo "$GRID" | grep -qE '^[A-Ra-r]{2}[0-9]{2}([A-Xa-x]{2})?$' || { echo "  ✗ 4 or 6 character Maidenhead locator, please"; GRID=""; }
done

read -r -p "Antenna description (optional, Enter to skip): " ANTENNA

echo ""
echo "Remote access (RAC) lets the WsprDaemon admins reach this station."
read -r -p "RAC user (optional, from your WD admin — Enter to skip): " RAC_USER
RAC_TOKEN=""
if [ -n "$RAC_USER" ]; then
    read -r -p "RAC token: " RAC_TOKEN
fi

echo ""
echo "  Reporter: $REPORTER   Grid: $GRID"
[ -n "$ANTENNA" ]  && echo "  Antenna:  $ANTENNA"
[ -n "$RAC_USER" ] && echo "  RAC:      $RAC_USER (host tunnel will be activated)"
read -r -p "Apply? [Y/n] " OK
case "${OK:-Y}" in [Nn]*) say "aborted by operator"; exit 1;; esac

# ── push identity into the decoder VM ───────────────────────────────────────
say "writing site-profile.toml into VM $VMID"
PROFILE=$(cat <<PEOF
# Written by the Sigmond appliance first-boot wizard $(date -u +%Y-%m-%dT%H:%MZ)
[station]
callsign    = "$CALLSIGN"
grid_square = "$GRID"
description = "$ANTENNA"

[reporters]
reporter_id = "$REPORTER"

[host]
hostname = "sigmond-decoder"
PEOF
)
B64=$(echo "$PROFILE" | base64 -w0)
gexec 30 "echo $B64 | base64 -d > /etc/sigmond/site-profile.toml" \
    || { say "ERROR: could not write site-profile.toml in guest"; exit 1; }

say "personalizing VM (new machine-id, SSH host keys, hostname)..."
gexec 600 "smd admin personalize --reset-identity --yes" \
    || { say "ERROR: personalize failed — see $LOG"; exit 1; }
say "rendering site config in VM..."
gexec 600 "smd config render" \
    || say "WARN: smd config render reported issues (continuing; rerun inside VM)"

# ── host RAC (optional) ─────────────────────────────────────────────────────
RAC_STATE="skipped"
if [ -n "$RAC_USER" ]; then
    say "activating host RAC tunnel"
    TPL=/etc/sigmond/frpc-host.toml.template
    if [ ! -f "$TPL" ] && [ -x /root/sigmond-appliance/sigmond-rac/install-host.sh ]; then
        (cd /root/sigmond-appliance/sigmond-rac && ./install-host.sh) >>"$LOG" 2>&1
    fi
    if [ -f "$TPL" ]; then
        sed -e "s|<RAC_USER_FROM_WD_ADMIN>|$RAC_USER|" \
            -e "s|<RAC_TOKEN_FROM_WD_ADMIN>|$RAC_TOKEN|" "$TPL" \
            > /etc/sigmond/frpc-host.toml
        chmod 600 /etc/sigmond/frpc-host.toml
        systemctl enable --now sigmond-rac-host.service >>"$LOG" 2>&1 \
            || systemctl enable --now wd-rac.service >>"$LOG" 2>&1
        RAC_STATE="activated as $RAC_USER (host SSH + Proxmox GUI via gw2)"
    else
        RAC_STATE="FAILED — sigmond-rac payload missing; run install-host.sh manually"
        say "WARN: $RAC_STATE"
    fi
fi

echo "$REPORTER $GRID $(date -u +%F)" > "$CONF_MARK"
say "──────────────────────────────────────────────────────"
say "  Station configured: $REPORTER @ $GRID"
say "  Decoder VM:  $VMID (personalized; decode chain will start per hardware)"
say "  RAC:         $RAC_STATE"
say "  Proxmox GUI: https://<this-host>:8006    Rerun wizard: sigmond-setup --reconfigure"
say "──────────────────────────────────────────────────────"
exit 0
