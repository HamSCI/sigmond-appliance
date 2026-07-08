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
#          remote access (RAC) — just Y/n. The gw2 registrar auto-assigns
#              a free RAC number (sites are identified by reporter ID;
#              the number is plumbing) and the wizard brings up ONE
#              host-side frpc carrying FOUR channels: VM ssh (35800+n),
#              VM ka9q-web (45800+n), host ssh (50800+n), Proxmox UI
#              (55800+n). The vm-* channels go through local relays that
#              ask the guest agent for the VM's CURRENT IP per connection,
#              so they survive DHCP changes AND the host stays reachable
#              even when the VM is down.
#
# Subcommands: --reconfigure   rerun the wizard (RAC number is sticky)
#              --rac-off       drop the remote-access tunnel (config kept)
#              --rac-on        bring it back up
set -u
VMID="${SIGMOND_VMID:-120}"
MARK_DIR=/etc/sigmond-appliance
CONF_MARK="$MARK_DIR/.configured"
LOG=/var/log/sigmond-wizard.log
say(){ echo "[wizard] $*" | tee -a "$LOG"; }

mkdir -p "$MARK_DIR"

# ── RAC on/off switches (no wizard rerun needed) ────────────────────────────
case "${1:-}" in
    --rac-off)
        systemctl disable --now sigmond-rac-host.service \
            sigmond-vm-ssh-relay.socket sigmond-vm-web-relay.socket 2>/dev/null
        say "remote access (RAC) disabled — tunnel is down, config kept."
        say "re-enable any time:  sigmond-setup --rac-on"
        exit 0;;
    --rac-on)
        if [ ! -f /etc/sigmond/frpc-host.toml ]; then
            say "no RAC config on this host yet — run: sigmond-setup --reconfigure"
            exit 1
        fi
        systemctl enable --now sigmond-vm-ssh-relay.socket \
            sigmond-vm-web-relay.socket 2>/dev/null
        systemctl enable --now sigmond-rac-host.service
        say "remote access (RAC) re-enabled$( [ -s "$MARK_DIR/rac-number" ] && echo " (RAC #$(cat "$MARK_DIR/rac-number"))" )"
        exit 0;;
esac

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
echo "fleet admin can reach this station for support. Everything — keys,"
echo "credentials, channel numbers — is handled automatically, and you can"
echo "turn it off any time with:  sigmond-setup --rac-off"
read -r -p "Enable remote access? [Y/n] " RAC_EN
RAC_NUM=""
case "${RAC_EN:-Y}" in [Nn]*) ;; *) RAC_NUM="auto";; esac

echo ""
echo "HamSCI PSWS (space-weather / GRAPE uploads) — optional. If this station"
echo "has a PSWS account (https://pswsnetwork.caps.ua.edu/), enter its IDs now."
echo "The upload KEY is registered later from any SSH session — the VM's login"
echo "banner walks you through it (no copy-paste needed on this console)."
PSWS_ID=""
while :; do
    read -r -p "PSWS station ID (e.g. S000123, Enter to skip): " PSWS_ID
    PSWS_ID=$(echo "$PSWS_ID" | tr '[:lower:]' '[:upper:]' | tr -d ' ')
    [ -z "$PSWS_ID" ] && break
    echo "$PSWS_ID" | grep -qE '^S[0-9]{6}$' && break
    echo "  ✗ PSWS station IDs look like S000123 (S + 6 digits)"
done
PSWS_GRAPE=""; PSWS_MAG=""
if [ -n "$PSWS_ID" ]; then
    read -r -p "  GRAPE instrument ID from the portal (e.g. 172, Enter if none): " PSWS_GRAPE
    PSWS_GRAPE=$(echo "$PSWS_GRAPE" | tr -d ' ')
    read -r -p "  magnetometer device ID (e.g. RM3100, Enter if none): " PSWS_MAG
    PSWS_MAG=$(echo "$PSWS_MAG" | tr -d ' ')
fi

echo ""
echo "  Reporter: $REPORTER   Grid: $GRID"
[ -n "$ANTENNA" ]  && echo "  Antenna:  $ANTENNA"
[ -n "$RAC_NUM" ] && echo "  RAC:      enabled — VM ssh/web + host ssh + Proxmox UI (number auto-assigned)"
[ -n "$PSWS_ID" ] && echo "  PSWS:     station $PSWS_ID${PSWS_GRAPE:+  grape=$PSWS_GRAPE}${PSWS_MAG:+  mag=$PSWS_MAG}  (key registered after install)"
read -r -p "Apply? [Y/n] " OK
case "${OK:-Y}" in [Nn]*) say "aborted by operator"; exit 1;; esac

# ── push identity into the decoder VM ───────────────────────────────────────
say "writing site-profile.toml into VM $VMID"
# PSWS: ids now, key later — `smd config render` in the VM generates the
# station key, arms the login banner that shows the pubkey to register at
# the portal, and `smd psws verify` (run over ssh, where copy-paste works)
# proves the handshake.
PSWS_TOML=""
if [ -n "$PSWS_ID" ]; then
    PSWS_TOML="
[psws]
enabled    = true
station_id = \"$PSWS_ID\"

[psws.instruments]"
    [ -n "$PSWS_GRAPE" ] && PSWS_TOML="$PSWS_TOML
\"hf-timestd\"   = \"$PSWS_GRAPE\""
    [ -n "$PSWS_MAG" ] && PSWS_TOML="$PSWS_TOML
\"mag-recorder\" = \"$PSWS_MAG\""
    PSWS_TOML="$PSWS_TOML
"
fi
PROFILE=$(cat <<PEOF
# Written by the Sigmond appliance first-boot wizard $(date -u +%Y-%m-%dT%H:%MZ)
[station]
callsign    = "$CALLSIGN"
grid_square = "$GRID"
description = "$ANTENNA"
$PSWS_TOML
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
# StrictModes no: operators add THEIR keys with plain ssh-copy-id, which
# only knows ~/.ssh/authorized_keys — under the group-writable home,
# StrictModes silently ignored those keys (observed: ssr/ssh-copy-id
# looped forever re-adding a key sshd refused to trust). The 'offending'
# group is sigmond's own private group, so this is safe here.
gexec 30 "install -d -m 755 /etc/ssh/authorized_keys.d && printf '%s\n' '$PUB' > /etc/ssh/authorized_keys.d/sigmond && chmod 644 /etc/ssh/authorized_keys.d/sigmond && install -d /etc/ssh/sshd_config.d && printf 'PasswordAuthentication yes\nPermitRootLogin no\nStrictModes no\nAuthorizedKeysFile .ssh/authorized_keys /etc/ssh/authorized_keys.d/%%u\n' > /etc/ssh/sshd_config.d/10-sigmond-operator.conf && rm -f /etc/ssh/sshd_config.d/50-sigmond-no-root.conf && { systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || systemctl restart sshd; }" \
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

# ── sigmond-vm: shell into the VM without knowing its (DHCP) address ────────
# The operator shouldn't have to hunt for an IP that DHCP can change —
# this helper asks the guest agent for the CURRENT address every time.
say "installing the sigmond-vm helper (ssh to the VM, IP auto-discovered)"
cat > /usr/local/bin/sigmond-vm <<'VMEOF'
#!/bin/bash
# sigmond-vm — shell into the Sigmond decoder VM as 'sigmond'; the VM's
# current IP is discovered live via the qemu guest agent (DHCP-proof).
# Installed by sigmond-setup.
#   sigmond-vm             interactive shell
#   sigmond-vm <cmd...>    run a command in the VM
#   sigmond-vm --ip        just print the VM's current IPv4
VMID="${SIGMOND_VMID:-120}"
if ! qm status "$VMID" >/dev/null 2>&1; then
    echo "sigmond-vm: VM $VMID does not exist" >&2; exit 1
fi
if ! qm status "$VMID" | grep -q running; then
    echo "sigmond-vm: VM $VMID is not running — try: qm start $VMID" >&2; exit 1
fi
IP=""
for i in 1 2 3; do
    IP=$(qm agent "$VMID" network-get-interfaces 2>/dev/null \
         | grep -oE '"ip-address" *: *"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' \
         | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | grep -v '^127\.' | head -1)
    [ -n "$IP" ] && break
    sleep 2
done
if [ -z "$IP" ]; then
    echo "sigmond-vm: the guest agent reports no IPv4 yet — check the VM's network" >&2; exit 1
fi
if [ "${1:-}" = "--ip" ]; then echo "$IP"; exit 0; fi
# dedicated known_hosts: sigmond-setup clears it when it regenerates the
# VM's host keys, so operators never see a MITM warning for their own VM
exec ssh -o StrictHostKeyChecking=accept-new \
         -o UserKnownHostsFile=/etc/sigmond-appliance/vm-known_hosts \
         sigmond@"$IP" "$@"
VMEOF
chmod +x /usr/local/bin/sigmond-vm

# ── PROVE the operator login works (don't just claim it) ───────────────────
# Key login, host→VM, via the same helper path the operator will use.
# Fresh known_hosts each run: personalize regenerates the VM's host keys,
# so a cached entry from a previous run always clashes — clear + re-seed.
rm -f "$MARK_DIR/vm-known_hosts"
SSH_STATE="not verified — VM had no IP during setup"
if [ -n "$VMIP" ]; then
    if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
           -o UserKnownHostsFile="$MARK_DIR/vm-known_hosts" sigmond@"$VMIP" true 2>>"$LOG"; then
        SSH_STATE="verified from this host ✓"
    else
        SSH_STATE="FAILED — key login from this host was refused; see $LOG"
        say "WARN: ssh sigmond@$VMIP verification FAILED"
        qm guest exec "$VMID" --timeout 15 -- bash -lc \
            "sshd -T 2>/dev/null | grep -Ei '^(passwordauthentication|permitrootlogin|pubkeyauthentication)'; getent passwd sigmond; ls -la \$(getent passwd sigmond | cut -d: -f6)/.ssh/ 2>&1" >>"$LOG" 2>&1
    fi
fi

RAC_STATE="skipped"
if [ -n "$RAC_NUM" ]; then
    say "activating remote access — registering with the gateway"
    # frpc binary, TLS CA and the host unit come from the sigmond-rac payload
    if [ ! -x /usr/local/sbin/frpc ] && [ -x /root/sigmond-appliance/sigmond-rac/install-host.sh ]; then
        (cd /root/sigmond-appliance/sigmond-rac && ./install-host.sh) >>"$LOG" 2>&1
    fi
    if [ ! -x /usr/local/sbin/frpc ] || [ ! -f /etc/sigmond/frps-ca.crt ]; then
        RAC_STATE="FAILED — sigmond-rac payload missing (frpc/CA); run install-host.sh, then sigmond-setup --reconfigure"
        say "WARN: $RAC_STATE"
    else
        # One POST does what used to be a copy-paste ritual: gw2's registrar
        # creates the station account, files our pubkey (that IS the auth —
        # the frps plugin only admits registered keys), auto-assigns a free
        # RAC number (sticky per site, so reconfigure keeps it), and
        # returns user/token/ports for the frpc config.
        SITE=$(echo "$REPORTER" | tr '[:lower:]' '[:upper:]' | tr '/' '_' | tr -cd 'A-Z0-9_-')
        REG=$(python3 - "$SITE" "$(cat /root/.ssh/id_ed25519.pub)" <<'PYEOF' 2>>"$LOG"
import json, re, sys, urllib.error, urllib.request
site, pub = sys.argv[1], sys.argv[2]
req = urllib.request.Request(
    "http://gw2.wsprdaemon.org:35737/register",
    data=json.dumps({"site": site, "pubkey": pub}).encode(),
    headers={"Content-Type": "application/json"})
try:
    r = json.load(urllib.request.urlopen(req, timeout=30))
except urllib.error.HTTPError as e:
    try: msg = json.load(e)["error"]
    except Exception: msg = str(e)
    sys.exit("gateway refused registration: %s" % msg)
except Exception as e:
    sys.exit("cannot reach the gateway registrar: %s" % e)
ok = (re.fullmatch(r"[0-9a-f]{16}", str(r.get("user", "")))
      and re.fullmatch(r"[0-9a-zA-Z]{8,64}", str(r.get("token", "")))
      and re.fullmatch(r"[a-z0-9.-]+", str(r.get("server_addr", "")))
      and isinstance(r.get("rac"), int)
      and all(isinstance(r.get("ports", {}).get(k), int)
              for k in ("vm_ssh", "vm_web", "host_ssh", "host_ui")))
if not ok:
    sys.exit("gateway returned a malformed registration")
print("RACN=%d RUSER=%s RTOKEN=%s P_VMSSH=%d P_VMWEB=%d P_HSSH=%d P_HUI=%d SRV=%s SPORT=%d" % (
    r["rac"], r["user"], r["token"], r["ports"]["vm_ssh"], r["ports"]["vm_web"],
    r["ports"]["host_ssh"], r["ports"]["host_ui"],
    r["server_addr"], int(r["server_port"])))
PYEOF
)
        if [ -z "$REG" ]; then
            RAC_STATE="FAILED — could not register with the gateway (see $LOG), rerun: sigmond-setup --reconfigure"
            say "WARN: $RAC_STATE"
        else
            eval "$REG"
            # DHCP-proof relays: frpc needs a fixed local target, but the
            # VM's address can change — so the vm-* channels point at local
            # sockets whose per-connection handler asks the guest agent for
            # the VM's CURRENT IP (same trick as sigmond-vm).
            say "installing the VM port relays (ssh, ka9q-web)"
            install -d /usr/local/lib/sigmond
            cat > /usr/local/lib/sigmond/vm-port-relay.py <<'RLEOF'
#!/usr/bin/env python3
# vm-port-relay.py <vm-port> — inetd-style relay for ONE accepted connection
# (systemd socket with Accept=yes): stdin/stdout is the client socket.
# Resolves the decoder VM's CURRENT IPv4 via the qemu guest agent on every
# connection, so the relay keeps working when DHCP moves the VM.
import os, re, select, socket, subprocess, sys

port = int(sys.argv[1])
vmid = os.environ.get("SIGMOND_VMID", "120")
try:
    out = subprocess.run(["qm", "agent", vmid, "network-get-interfaces"],
                         capture_output=True, text=True, timeout=10).stdout
except Exception:
    sys.exit(1)
ips = [ip for ip in re.findall(r'"ip-address"\s*:\s*"(\d+\.\d+\.\d+\.\d+)"', out)
       if not ip.startswith("127.")]
if not ips:
    sys.exit(1)
try:
    vm = socket.create_connection((ips[0], port), timeout=10)
except OSError:
    sys.exit(1)
vm.settimeout(None)
client_open, vm_open = True, True
try:
    while client_open or vm_open:
        watch = ([0] if client_open else []) + ([vm] if vm_open else [])
        r, _, _ = select.select(watch, [], [], 900)
        if not r:
            break  # idle 15 min
        if 0 in r:
            d = os.read(0, 65536)
            if d:
                vm.sendall(d)
            else:
                client_open = False
                try: vm.shutdown(socket.SHUT_WR)
                except OSError: pass
                if not vm_open: break
        if vm in r:
            try: d = vm.recv(65536)
            except OSError: d = b""
            if d:
                os.write(1, d)
            else:
                vm_open = False
                if not client_open: break
except (BrokenPipeError, ConnectionResetError):
    pass
finally:
    vm.close()
RLEOF
            chmod 755 /usr/local/lib/sigmond/vm-port-relay.py
            for spec in "ssh:12222:22" "web:12223:8081"; do
                IFS=: read -r RNAME RLPORT RVPORT <<<"$spec"
                cat > "/etc/systemd/system/sigmond-vm-$RNAME-relay.socket" <<SOCKEOF
[Unit]
Description=Relay 127.0.0.1:$RLPORT → decoder VM :$RVPORT (IP via guest agent)
[Socket]
ListenStream=127.0.0.1:$RLPORT
Accept=yes
[Install]
WantedBy=sockets.target
SOCKEOF
                cat > "/etc/systemd/system/sigmond-vm-$RNAME-relay@.service" <<SVCEOF
[Unit]
Description=decoder-VM $RNAME relay (%i)
CollectMode=inactive-or-failed
[Service]
Type=simple
Environment=SIGMOND_VMID=$VMID
StandardInput=socket
StandardOutput=socket
StandardError=journal
ExecStart=/usr/local/lib/sigmond/vm-port-relay.py $RVPORT
SVCEOF
            done
            systemctl daemon-reload
            systemctl enable --now sigmond-vm-ssh-relay.socket sigmond-vm-web-relay.socket >>"$LOG" 2>&1

            say "writing /etc/sigmond/frpc-host.toml (4 channels, one tunnel)"
            cat > /etc/sigmond/frpc-host.toml <<TOMLEOF
# Written by sigmond-setup $(date -u +%F) — RAC #$RACN (auto-assigned), site $SITE.
# ONE frpc on the Proxmox host carries all four channels; the vm-*
# channels ride the local relays (12222/12223) that resolve the VM's
# current IP per connection, so this file never needs the VM's address.
serverAddr = "$SRV"
serverPort = $SPORT
user = "$RUSER"

[auth]
method = "token"
token = "$RTOKEN"

[transport.tls]
enable = true
trustedCaFile = "/etc/sigmond/frps-ca.crt"

[webServer]
addr = "127.0.0.1"
port = 7500

[[proxies]]
name = "$SITE-vm-ssh"
type = "tcp"
localIP = "127.0.0.1"
localPort = 12222
remotePort = $P_VMSSH

[[proxies]]
name = "$SITE-vm-web"
type = "tcp"
localIP = "127.0.0.1"
localPort = 12223
remotePort = $P_VMWEB

[[proxies]]
name = "$SITE-host-ssh"
type = "tcp"
localIP = "127.0.0.1"
localPort = 22
remotePort = $P_HSSH

[[proxies]]
name = "$SITE-host-ui"
type = "tcp"
localIP = "127.0.0.1"
localPort = 8006
remotePort = $P_HUI
TOMLEOF
            chmod 600 /etc/sigmond/frpc-host.toml
            systemctl enable sigmond-rac-host.service >>"$LOG" 2>&1
            systemctl restart sigmond-rac-host.service >>"$LOG" 2>&1

            # PROVE the tunnel (don't just claim it): frpc's local admin API
            # reports per-proxy status once the server has accepted them.
            RUNNING=0
            for i in $(seq 1 12); do
                # grep -o|wc -l, NOT grep -c: the API is one line of JSON and
                # grep -c counts LINES — it reported 1/4 with all 4 running.
                RUNNING=$(curl -s http://127.0.0.1:7500/api/status 2>/dev/null | grep -o '"status":"running"' | wc -l)
                [ "$RUNNING" -ge 4 ] && break
                sleep 5
            done
            if [ "$RUNNING" -ge 4 ]; then
                RAC_STATE="#$RACN live on $SRV — VM ssh :$P_VMSSH · VM web :$P_VMWEB · host ssh :$P_HSSH · Proxmox UI :$P_HUI (off: sigmond-setup --rac-off)"
                echo "$RACN" > "$MARK_DIR/rac-number"
            else
                RAC_STATE="FAILED — registered, but only $RUNNING/4 channels came up; journalctl -u sigmond-rac-host"
                say "WARN: $RAC_STATE"
            fi
        fi
    fi
fi

PSWS_STATE="skipped — add later: sigmond-setup --reconfigure"
if [ -n "$PSWS_ID" ]; then
    PSWS_STATE="station $PSWS_ID — IDs recorded, UPLOAD KEY NOT YET REGISTERED.
            Finish from any computer: log into the VM (sigmond-vm) — the
            login banner shows the key to paste into the PSWS portal,
            then run:  smd psws verify"
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
   shell:   sigmond-vm   ← run this on the host: finds the VM's
            current IP and logs you in as sigmond ($SSH_STATE)
   ssh:     ssh sigmond@${VMIP:-<vm-ip>}   (from other machines;
            sigmond-vm --ip prints the current address)
   console: qm terminal $VMID  (Ctrl+O exits; sigmond or root)
 RAC:       $RAC_STATE
 PSWS:      $PSWS_STATE
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
