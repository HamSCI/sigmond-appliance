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
echo "Remote access (RAC) is a reverse tunnel to the WsprDaemon gateway so the"
echo "fleet admin can reach this station for support. The username + token are"
echo "issued by the WsprDaemon admin. No credentials? Just press Enter to skip"
echo "— you can add them any time with:  sigmond-setup --reconfigure"
read -r -p "RAC user (Enter to skip): " RAC_USER
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
# ── operator access to the decoder VM ──────────────────────────────
# The operator account is the 'sigmond' user — remote root ssh login is
# DISABLED (root stays usable on the console / qm terminal for recovery).
# sigmond gets the SAME password as this host's root (hash copy — one
# password for the whole appliance), this host's SSH key, and sudo.
say "setting up VM operator account 'sigmond' (same password as this host's root)"
gexec 30 "id sigmond >/dev/null 2>&1 || useradd -m -s /bin/bash sigmond; usermod -s /bin/bash sigmond; getent group sudo >/dev/null && usermod -aG sudo sigmond || true" \
    || say "WARN: could not ensure sigmond operator user in VM"
HASH=$(getent shadow root | cut -d: -f2)
if [ -n "$HASH" ] && [ "$HASH" != "*" ] && [ "$HASH" != "!" ]; then
    gexec 30 "usermod -p '$HASH' sigmond && usermod -p '$HASH' root" \
        || say "WARN: could not set VM account passwords"
fi
[ -f /root/.ssh/id_ed25519 ] || ssh-keygen -q -t ed25519 -N "" -f /root/.ssh/id_ed25519
PUB=$(cat /root/.ssh/id_ed25519.pub)
# Install the key in sigmond's REAL home — the template's service account
# may not live in /home/sigmond (hardcoding that put the key where sshd
# never looks: observed 'Permission denied (publickey)' 2026-07-03).
# Ownership/modes matter too: sshd StrictModes rejects root-owned homes.
gexec 30 "H=\$(getent passwd sigmond | cut -d: -f6); case \"\$H\" in ''|/|/nonexistent) usermod -d /home/sigmond sigmond; H=/home/sigmond;; esac; G=\$(id -gn sigmond); mkdir -p \"\$H\"; chown sigmond:\"\$G\" \"\$H\"; install -d -m 700 -o sigmond -g \"\$G\" \"\$H/.ssh\"; grep -qF '$PUB' \"\$H/.ssh/authorized_keys\" 2>/dev/null || echo '$PUB' >> \"\$H/.ssh/authorized_keys\"; chown sigmond:\"\$G\" \"\$H/.ssh/authorized_keys\"; chmod 600 \"\$H/.ssh/authorized_keys\"" \
    || say "WARN: could not install host ssh key for sigmond"
# ssh policy: password login ON, remote root OFF. Cloud-init images ship
# PasswordAuthentication no in 50-cloud-init.conf; OpenSSH takes the FIRST
# value it sees and reads sshd_config.d alphabetically — 10- beats 50-.
# AuthorizedKeysFile: sigmond's home IS the source tree (/opt/git/sigmond,
# group-writable+setgid), which StrictModes rightly distrusts — so keys
# also live in root-owned /etc/ssh/authorized_keys.d/%u (observed
# 2026-07-03: key refused from ~/.ssh, password fine).
gexec 30 "install -d -m 755 /etc/ssh/authorized_keys.d && printf '%s\n' '$PUB' > /etc/ssh/authorized_keys.d/sigmond && chmod 644 /etc/ssh/authorized_keys.d/sigmond && install -d /etc/ssh/sshd_config.d && printf 'PasswordAuthentication yes\nPermitRootLogin no\nAuthorizedKeysFile .ssh/authorized_keys /etc/ssh/authorized_keys.d/%%u\n' > /etc/ssh/sshd_config.d/10-sigmond-operator.conf && rm -f /etc/ssh/sshd_config.d/50-sigmond-no-root.conf && { systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || systemctl restart sshd; }" \
    || say "WARN: could not set VM ssh policy (password on / remote root off)"
gexec 30 "systemctl enable --now serial-getty@ttyS0.service" || true
# Catch-all DHCP: the template's build-time NIC name never matches the
# deployed VM's (observed: no IP on real hardware) — match en* instead.
say "ensuring decoder VM networking (DHCP on any ethernet NIC)"
gexec 90 "mkdir -p /etc/systemd/network && { echo '[Match]'; echo 'Name=en*'; echo; echo '[Network]'; echo 'DHCP=yes'; } > /etc/systemd/network/99-dhcp-en.network && systemctl enable --now systemd-networkd && networkctl reload && for l in /sys/class/net/en*; do ip link set \$(basename \$l) up 2>/dev/null; done; sleep 8" \
    || say "WARN: could not configure VM networking"
# DHCP can take a while after networkctl reload — poll up to ~90 s for a
# lease instead of a single grab (one-shot came up empty on real hardware).
say "waiting for the decoder VM to get an IP address (DHCP)..."
VMIP=""
for i in $(seq 1 18); do
    VMIP=$(qm guest exec "$VMID" --timeout 15 -- bash -lc "ip -4 -br addr show scope global" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    [ -n "$VMIP" ] && break
    sleep 5
done
[ -z "$VMIP" ] && say "WARN: VM has no IPv4 address yet — check cabling/DHCP, then: qm guest exec $VMID -- ip -4 -br addr"

# ── PROVE the operator login works (don't just claim it) ───────────────────
# Key login, host→VM. Fresh known_hosts each time: personalize regenerates
# the VM's host keys, so the cached entry from a previous run always clashes.
SSH_STATE="not verified — VM had no IP during setup"
if [ -n "$VMIP" ]; then
    if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null sigmond@"$VMIP" true 2>>"$LOG"; then
        SSH_STATE="verified from this host ✓"
    else
        SSH_STATE="FAILED — key login from this host was refused; see $LOG"
        say "WARN: ssh sigmond@$VMIP verification FAILED"
        qm guest exec "$VMID" --timeout 15 -- bash -lc \
            "sshd -T 2>/dev/null | grep -Ei '^(passwordauthentication|permitrootlogin|pubkeyauthentication)'; getent passwd sigmond; ls -la \$(getent passwd sigmond | cut -d: -f6)/.ssh/ 2>&1" >>"$LOG" 2>&1
    fi
fi

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

# ── final summary ───────────────────────────────────────────────────────────
# Print it, save it (/root/sigmond-setup-summary.txt), pin it above the tty1
# login prompt (/etc/issue) and after ssh login (/etc/motd), and HOLD the
# console until the operator acknowledges — getty resets the tty the moment
# we exit, which used to erase everything (observed 2026-07-03).
HOSTIP=$(hostname -I 2>/dev/null | awk '{print $1}')
SUMMARY=$(cat <<SEOF
──────────────────────────────────────────────────────
 Sigmond station configured: $REPORTER @ $GRID
 Host (Proxmox):
   login:   root — password set at install (image default:
            hamsci-sigmond — CHANGE IT: run 'passwd')
   ssh:     ssh root@${HOSTIP:-<host-ip>}
   web GUI: https://${HOSTIP:-<host-ip>}:8006
 Decoder VM $VMID:
   IP:      ${VMIP:-none yet — check: qm guest exec $VMID -- ip -4 -br addr}
   login:   sigmond — SAME password as this host's root
            (remote root ssh login is disabled)
   ssh:     ssh sigmond@${VMIP:-<vm-ip>}   [$SSH_STATE]
   console: qm terminal $VMID  (Ctrl+O exits; sigmond or root)
 RAC:       $RAC_STATE
 Rerun wizard:  sigmond-setup --reconfigure
 This summary is saved in /root/sigmond-setup-summary.txt
──────────────────────────────────────────────────────
SEOF
)
echo "$SUMMARY" | tee -a "$LOG"
echo "$SUMMARY" > /root/sigmond-setup-summary.txt
# /etc/issue is rewritten by pvebanner.service at boot, so this only needs to
# survive until then; /etc/motd persists. Markered so re-runs don't stack.
for f in /etc/issue /etc/motd; do
    sed -i '/^─* Sigmond setup ─*$/,/^─* end Sigmond setup ─*$/d' "$f" 2>/dev/null
    { echo "────── Sigmond setup ──────"
      echo "$SUMMARY"
      echo "────── end Sigmond setup ──────"; } >> "$f"
done
echo ""
read -r -p "Press Enter to finish (this summary stays on the login screen)... " _ 2>/dev/null || true
exit 0
