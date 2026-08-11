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
#          remote access (RAC) — just Y/n. The RAC registrar ($RAC_SERVER,
#              configurable via SIGMOND_RAC_SERVER/_REGISTRAR) auto-assigns
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
#              --rac-upgrade   climb to a more secure gateway tier if one
#                              has since come up (see the RAC ladder below)
set -u
VMID="${SIGMOND_VMID:-120}"
# ── RAC endpoint ladder ────────────────────────────────────────────────
# Two policies, split on whether this is a DASI station (rob 2026-08-09):
#
#   dasi      Prefer the HamSCI gateway, and rather than finish with no
#             remote access at all, walk all the way down to an unsecured
#             tunnel.  These boxes sit in a physically secure location, and
#             a station nobody can reach is a station nobody can support.
#   standard  Ordinary WsprDaemon-group installs never touch vpn.hamsci.org
#             and are secure-only — no unsecured fallback, ever.
#
# I flagged that silently downgrading to an unsecured transport is a genuine
# weakening; rob scoped it to DASI deliberately rather than dropping it, and
# every tier below announces itself on the console and in $LOG.
#
# Why a ladder at all: vpn.hamsci.org's secure stack has never answered, so
# EVERY greenfield install since 2026-07-30 finished with RAC dead and nobody
# noticed until someone needed remote support (found on B4, 2026-08-06).
#
# What secure/unsecured actually MEANS (mjh 2026-08-09, correcting the
# v3.25/v3.26 guess): it is the frps TUNNEL port —
#   secure    = TLS frps on 35736 + frpc [transport.tls] with the pinned CA
#   unsecured = legacy plain frps on 35735 + TLS off
# The REGISTRAR (account-creation API) is a separate, tier-independent thing:
# plain http on 35737, the only registrar either gateway serves.  v3.25/26
# implemented "secure" as an https registrar on 35737 — nothing serves that,
# so every install quietly fell through to an unsecured rung.
#
# Tier fields:  label|server|registrar|tls|frps_port
#
# DASI stations get a REGISTRAR-LESS rung (rob 2026-08-09): both gateways
# keep their registration pages WireGuard-only by policy (exposing them
# publicly is a hole rob won't open — gw2's :35737 is firewalled to known
# sites), so a greenfield DASI box cannot self-register with the HamSCI
# gateway.  Instead DASI-N maps DETERMINISTICALLY to RAC 220+N (DASI-001 ->
# RAC #221) and to the standard port bands, and "is it free?" is answered
# by ATTEMPTING the tunnel — frps refuses a taken name/port — never by
# probing.  Port bands measured live on gw2 (RAC #151, 2026-08-09):
RAC_BASE_VMSSH=35800; RAC_BASE_VMWEB=45800
RAC_BASE_HSSH=50800;  RAC_BASE_HUI=55800
# Profile + DASI number stick across --reconfigure via /etc/sigmond-appliance.
RAC_PROFILE="${SIGMOND_RAC_PROFILE:-$(cat /etc/sigmond-appliance/rac-profile 2>/dev/null || echo dasi)}"
DASI_NUM="${SIGMOND_DASI_NUMBER:-$(cat /etc/sigmond-appliance/dasi-number 2>/dev/null)}"
HAMSCI_TOKEN="${SIGMOND_RAC_HAMSCI_TOKEN:-}"
RAC_REG_PORT="${SIGMOND_RAC_REG_PORT:-35737}"
RAC_PORT_SECURE="${SIGMOND_RAC_PORT_SECURE:-35736}"
RAC_PORT_UNSEC="${SIGMOND_RAC_PORT_UNSECURED:-35735}"
_hs="vpn.hamsci.org"
_wd="gw2.wsprdaemon.org"
build_rac_tiers() {
    case "$RAC_PROFILE" in
        standard)
            RAC_TIERS="wsprdaemon (secure)|$_wd|http://$_wd:$RAC_REG_PORT/register|on|$RAC_PORT_SECURE"
            ;;
        *)
            if [ -n "$DASI_NUM" ]; then
                # vpn.hamsci.org runs frps-secure on 35736 with account-less
                # TOFU auth (verified end-to-end 2026-08-09): no registrar,
                # no Linux accounts — the station's pubkey rides the login as
                # metadata and is trusted-on-first-use, keyed by DASI id.
                # DIRECT = deterministic RAC/ports claimed by ATTEMPT.
                # tls=opp: encrypted against the self-signed cert without
                # pinning; graduates to tls=on when the VPN gets a fleet-CA
                # cert (one tier-table field).  No token needed (pubkey is
                # the gate; the server's auth.token is empty).
                # Rung 2 (unsecured VPN) is the interim path that works TODAY:
                # vpn's legacy frps on 35735 is open (empty token, no plugin),
                # reachable through the firewall now, so a DASI box gets a
                # HamSCI tunnel before 35736 is opened.  Same DIRECT
                # deterministic RAC/ports + pubkey metadata; tls=off means the
                # pubkey rides but isn't verified there — the shared-open port
                # is the admission, a working tunnel the point (proven from
                # the AI6VN box 2026-08-09).  --rac-upgrade climbs to the TOFU
                # rung once 35736 opens.
                RAC_TIERS="HamSCI secure (TOFU)|$_hs|DIRECT|opp|$RAC_PORT_SECURE
HamSCI unsecured (direct)|$_hs|DIRECT|off|$RAC_PORT_UNSEC
wsprdaemon (secure)|$_wd|http://$_wd:$RAC_REG_PORT/register|on|$RAC_PORT_SECURE
wsprdaemon (UNSECURED)|$_wd|http://$_wd:$RAC_REG_PORT/register|off|$RAC_PORT_UNSEC"
            else
                RAC_TIERS="HamSCI (secure)|$_hs|http://$_hs:$RAC_REG_PORT/register|on|$RAC_PORT_SECURE
HamSCI (UNSECURED)|$_hs|http://$_hs:$RAC_REG_PORT/register|off|$RAC_PORT_UNSEC
wsprdaemon (secure)|$_wd|http://$_wd:$RAC_REG_PORT/register|on|$RAC_PORT_SECURE
wsprdaemon (UNSECURED)|$_wd|http://$_wd:$RAC_REG_PORT/register|off|$RAC_PORT_UNSEC"
            fi
            ;;
    esac
    # An explicitly pinned endpoint is an instruction, not a preference: it
    # replaces the ladder outright rather than becoming its first rung.
    if [ -n "${SIGMOND_RAC_SERVER:-}" ] || [ -n "${SIGMOND_RAC_REGISTRAR:-}" ]; then
        _ps="${SIGMOND_RAC_SERVER:-$_wd}"
        RAC_TIERS="pinned|$_ps|${SIGMOND_RAC_REGISTRAR:-http://$_ps:$RAC_REG_PORT/register}|${SIGMOND_RAC_TLS:-on}|${SIGMOND_RAC_FRPS_PORT:-$RAC_PORT_SECURE}"
    fi
}
build_rac_tiers
RAC_SERVER="$(echo "$RAC_TIERS" | head -1 | cut -d'|' -f2)"
RAC_TLS="on"
RAC_TIER_LABEL=""
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
    --rac-upgrade)
        # rob 2026-08-09: a station that had to settle for a lower tier should
        # be able to climb once a better gateway comes up, without a rebuild.
        # This probes the ladder top-down and only acts if something strictly
        # better than the current tier answers.
        CUR=$(cat "$MARK_DIR/rac-tier" 2>/dev/null || echo "(none)")
        echo "current RAC tier: $CUR"
        echo "probing the ladder, best first:"
        BEST=""; BEST_LBL=""
        while IFS='|' read -r _l _c _r _t _p; do
            [ -n "$_c" ] || continue
            # a tier is up iff its frps TUNNEL port answers (35736 TLS /
            # 35735 legacy); the registrar is shared and proves nothing
            if timeout 5 bash -c "exec 3<>/dev/tcp/$_c/$_p" 2>/dev/null; then
                echo "  $_l — ANSWERS ($_c:$_p)"
                [ -z "$BEST" ] && { BEST="$_r"; BEST_LBL="$_l"; }
            else
                echo "  $_l — no answer ($_c:$_p)"
            fi
        done <<TIEREOF
$RAC_TIERS
TIEREOF
        if [ -z "$BEST" ]; then
            echo "no gateway tier is reachable right now — nothing to do."
            exit 1
        fi
        if [ "$BEST_LBL" = "$CUR" ]; then
            echo "already on the best tier that answers ($CUR) — nothing to do."
            exit 0
        fi
        echo ""
        echo "a better tier is available: $BEST_LBL  (currently $CUR)"
        echo "re-registering re-runs the setup questions; the RAC number is sticky,"
        echo "so the station keeps its assigned channels."
        rd -r -p "upgrade now? [y/N] " _u
        case "${_u:-N}" in
            [Yy]*) exec "$0" --reconfigure ;;
            *) echo "left on $CUR; run this again any time." ; exit 0 ;;
        esac
        ;;
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

# rd — read that ABORTS on EOF instead of letting a validation loop spin
# forever when piped stdin runs dry (nested-test hang, 2026-08-11).  On a
# live tty read only fails on EOF (Ctrl-D), where aborting is also right.
rd(){ read "$@" || { echo; say "stdin closed (EOF) — aborting wizard; nothing applied. Rerun: sigmond-setup"; exit 1; }; }

gexec(){ # gexec <timeout-s> <command...>  → runs in guest, echoes exitcode
    local t="$1"; shift
    local out rc
    out=$(qm guest exec "$VMID" --timeout "$t" -- bash -lc "$*" 2>&1)
    rc=$(echo "$out" | grep -o '"exitcode" *: *[0-9-]*' | grep -o '[0-9-]*$' | head -1)
    echo "$out" >> "$LOG"
    [ "${rc:-1}" = "0" ]
}

# ── prompts ─────────────────────────────────────────────────────────────────
# Each question is a function so the final review screen can re-run any
# single one: the operator sees everything they typed and picks a number
# to fix a mistake BEFORE anything is applied (rob mistyped his reporter
# ID on the first Kamrui install, 2026-07-27 — the old flow's only exits
# were apply-it-wrong or abort-and-reinstall).
echo ""
echo "──────────────────────────────────────────────────────"
echo "  Sigmond station setup — a few questions and you're on the air"
echo "  (you'll get a review screen to fix any answer before it's applied)"
echo "──────────────────────────────────────────────────────"

# ── external-device pre-flight ─────────────────────────────────────────────
# Runs BEFORE the questions.  USB controller passthrough to the VM is
# configured by firstboot AFTER this wizard (and needs a reboot), so at this
# moment every external device is on the PROXMOX HOST — host lsusb is the
# right place to look, not `gexec lsusb`.
#
# This NEVER blocks.  A station with nothing plugged in must still reach the
# end of the wizard, because the single most valuable outcome of a failed
# install is a working RAC tunnel: it lets a remote admin connect and finish
# the job.  So we report what is missing, plainly, and carry on.
HAVE_GPSDO=0; HAVE_RX888=0; HAVE_TS1=0; HAVE_MAG=0; GPSDO_MODEL=""

preflight_devices() {
    local usb; usb=$(lsusb 2>/dev/null || true)
    # RX888 — same PID set the SDR sentinel matches on (line ~397).
    echo "$usb" | grep -qiE '04b4:00(f[013]|bc)|f4b3:0100' && HAVE_RX888=1
    # Leo Bodnar GPSDOs, per gpsdo-monitor/models/registry.py:
    #   LBE-1420 0x2443 · LBE-1421 0x2444 · LBE-1423 0x226f · LBE-Mini 0x2211
    if   echo "$usb" | grep -qiE '1dd2:2211'; then HAVE_GPSDO=1; GPSDO_MODEL="LBE-Mini"
    elif echo "$usb" | grep -qiE '1dd2:2444'; then HAVE_GPSDO=1; GPSDO_MODEL="LBE-1421"
    elif echo "$usb" | grep -qiE '1dd2:2443'; then HAVE_GPSDO=1; GPSDO_MODEL="LBE-1420"
    elif echo "$usb" | grep -qiE '1dd2:226f'; then HAVE_GPSDO=1; GPSDO_MODEL="LBE-1423"
    fi
    # TS-1 TimeSync: the USB interface enumerates as an Adafruit SAMD21
    # module, so the VID/PID alone is not proof — confirmed by asking the
    # CLI, which answers with a "TimeSync vN.N, Board ID #..." banner.
    echo "$usb" | grep -qiE '239a:801e' && HAVE_TS1=1
    # RM3100 magnetometer via the Pololu isolated USB-I2C adapter.
    echo "$usb" | grep -qiE '1ffb:250[23]' && HAVE_MAG=1

    echo ""
    echo "  ── Attached equipment ───────────────────────────────"
    if [ "$HAVE_RX888" = 1 ]; then echo "  ✓ RX888 SDR"
    else echo "  ✗ RX888 SDR          — NOT DETECTED (no HF reception until fitted)"; fi
    if [ "$HAVE_GPSDO" = 1 ]; then echo "  ✓ GPSDO ($GPSDO_MODEL)"
    else echo "  ✗ GPSDO              — NOT DETECTED (timing falls back to NTP)"; fi
    if [ "$HAVE_TS1" = 1 ]; then echo "  ✓ TS-1 TimeSync injector"
    else echo "  ✗ TS-1 TimeSync      — NOT DETECTED (no ns-class timing)"; fi
    if [ "$HAVE_MAG" = 1 ]; then echo "  ✓ RM3100 magnetometer"
    else echo "  ✗ RM3100 magnetometer — NOT DETECTED (no magnetometer data)"; fi

    if [ "$HAVE_RX888" = 0 ] || [ "$HAVE_GPSDO" = 0 ] || [ "$HAVE_TS1" = 0 ] || [ "$HAVE_MAG" = 0 ]; then
        echo ""
        echo "  Missing equipment does not stop this install.  The station will"
        echo "  come up with whatever is fitted, and anything added later is"
        echo "  picked up automatically (the SDR sentinel watches for a late or"
        echo "  replugged RX888).  Setup continues."
    fi
    echo "──────────────────────────────────────────────────────"
}

# ── GPSDO → Maidenhead ─────────────────────────────────────────────────────
# gpsdo-monitor computes this properly (nmea.py maidenhead(), and its own
# comment says the position exists for "the station's grid square at install
# time") — but it lives in the decoder VM, which cannot see the GPSDO until
# passthrough happens after this wizard.  So read NMEA straight off the
# device here.  This value is only the PROMPT DEFAULT; the authoritative
# position is re-asserted from the GPSDO after bring-up by
# sigmond-location-check ("location authority first (GPSDO definitive)").
gpsdo_grid() {
    [ "$HAVE_GPSDO" = 1 ] || return 1
    # Find the GPSDO's OWN serial node.  Never walk /dev/ttyACM* blindly:
    # on a DASI2 box ttyACM0 is usually the TS-1 TimeSync CLI, and opening
    # a CDC port asserts DTR -- that is how the TS-1's console was wedged
    # during testing on 2026-08-08.  gpsdo-monitor solves this the same way
    # (nmea.py: "Return /dev/ttyACM* nodes whose owning USB device matches").
    local port=""
    for cand in /dev/serial/by-id/*Leo_Bodnar*; do
        [ -e "$cand" ] || continue
        port=$(readlink -f "$cand"); break
    done
    # LBE-Mini (0x2211) is HID-only -- UBX on interrupt-IN, no serial node
    # at all (verified on a v3.22 install: bInterfaceClass 3, 1 endpoint).
    # Nothing to parse here; the VM sets the grid later from the real
    # gpsdo-monitor, which speaks UBX properly.
    [ -n "$port" ] || return 1
    # -hupcl and clocal suppress the DTR toggle on open.
    stty -F "$port" 9600 raw -echo clocal -hupcl 2>/dev/null || true
    local sentence
    sentence=$(timeout 6 grep -m1 -E '^\$G[PNLA]RMC,' < "$port" 2>/dev/null || true)
    [ -n "$sentence" ] || return 1
    # Field layout per gpsdo-monitor/nmea.py:
    #   $xxRMC,utc,status,lat,N/S,lon,E/W,sog,cog,date,magvar,...
    echo "$sentence" | awk -F, '
        $3 != "A" { exit 1 }
        {
          lat = int($4/100) + ($4 - int($4/100)*100)/60; if ($5 == "S") lat = -lat
          lon = int($6/100) + ($6 - int($6/100)*100)/60; if ($7 == "W") lon = -lon
          if (lat == 0 && lon == 0) exit 1
          L = lon + 180; A = lat + 90
          f1 = int(L/20); f2 = int(A/10)
          s1 = int((L - f1*20)/2); s2 = int(A - f2*10)
          u1 = int((L - f1*20 - s1*2) * 12); u2 = int((A - f2*10 - s2) * 24)
          printf "%c%c%d%d%c%c\n", 65+f1, 65+f2, s1, s2, 97+u1, 97+u2
        }'
}

ask_reporter() {
    REPORTER=""
    while [ -z "$REPORTER" ]; do
        rd -r -p "Reporter ID (your callsign, optionally /suffix — e.g. AC0G/B4): " REPORTER
        REPORTER=$(echo "$REPORTER" | tr '[:lower:]' '[:upper:]' | tr -d ' ')
        echo "$REPORTER" | grep -qE '^[A-Z0-9]{3,}(/[A-Z0-9]+)?$' || { echo "  ✗ that doesn't look like a callsign"; REPORTER=""; }
    done
    CALLSIGN="${REPORTER%%/*}"
}

ask_grid() {
    # Offer the GPSDO's own position as the default so the operator confirms
    # rather than types.  Falls back to a bare prompt when there is no GPSDO,
    # no fix yet, or the device is not on a port we can read.
    local GRID_DEFAULT=""
    if [ "$HAVE_GPSDO" = 1 ]; then
        printf "Reading position from the GPSDO (%s)... " "$GPSDO_MODEL"
        GRID_DEFAULT=$(gpsdo_grid || true)
        if [ -n "$GRID_DEFAULT" ]; then
            echo "$GRID_DEFAULT"
        else
            echo "not readable here"
            # Either an LBE-Mini (HID/UBX only, no serial node) or no fix
            # yet.  Not a problem: sigmond-location-check runs before
            # bring-up and treats a live GPSDO position as DEFINITIVE,
            # rewriting site-profile grid/lat/lon and propagating to
            # hf-timestd, the metrology envs and mag-recorder via
            # sigmond-site-timing.  Whatever is entered now is provisional.
            echo "  (your GPSDO will set the grid automatically after setup —"
            echo "   the value below is only used until then)"
        fi
    fi
    GRID=""
    while [ -z "$GRID" ]; do
        if [ -n "$GRID_DEFAULT" ]; then
            rd -r -p "Grid square (Maidenhead) [$GRID_DEFAULT]: " GRID
            GRID="${GRID:-$GRID_DEFAULT}"
        else
            rd -r -p "Grid square (Maidenhead, e.g. EM38ww): " GRID
        fi
        GRID=$(echo "$GRID" | tr -d ' ')
        echo "$GRID" | grep -qE '^[A-Ra-r]{2}[0-9]{2}([A-Xa-x]{2})?$' || { echo "  ✗ 4 or 6 character Maidenhead locator, please"; GRID=""; }
    done
}

ask_antenna() {
    rd -r -p "Antenna description (optional, Enter to skip): " ANTENNA
}

ask_rac() {
    echo ""
    # Station class decides the gateway ladder (rob 2026-08-09): DASI = the
    # HamSCI-managed install shape, prefers vpn.hamsci.org and may walk down
    # to an unsecured tunnel; everything else is an ordinary WsprDaemon-group
    # station, gw2 secure ONLY.  Default follows the image profile so later
    # image builds can flip it (SIGMOND_RAC_PROFILE=standard -> default No).
    if [ "$RAC_PROFILE" = "standard" ]; then _dp="y/N"; else _dp="Y/n"; fi
    rd -r -p "Is this a DASI (HamSCI) station? [$_dp] " _dq
    _ddef="Y"; [ "$RAC_PROFILE" = "standard" ] && _ddef="N"
    case "${_dq:-$_ddef}" in
        [Nn]*) RAC_PROFILE="standard" ;;
        *)     RAC_PROFILE="dasi" ;;
    esac
    if [ "$RAC_PROFILE" = "dasi" ]; then
        while :; do
            rd -r -p "DASI unit number (1-99, e.g. 3 for DASI-003${DASI_NUM:+; current $DASI_NUM}; Enter to skip): " _dn
            _dn="${_dn:-$DASI_NUM}"
            [ -z "$_dn" ] && break
            echo "$_dn" | grep -qE '^[1-9][0-9]?$' && { DASI_NUM="$_dn"; break; }
            echo "  ✗ DASI numbers are 1-99 (DASI-001 … DASI-099)"
        done
        if [ -n "$DASI_NUM" ]; then
            _rn=$((220 + DASI_NUM))
            echo "  DASI-$(printf '%03d' "$DASI_NUM") maps deterministically to RAC #$_rn:"
            echo "    VM ssh :$((RAC_BASE_VMSSH+_rn)) · ka9q-web :$((RAC_BASE_VMWEB+_rn)) · host ssh :$((RAC_BASE_HSSH+_rn)) · host UI :$((RAC_BASE_HUI+_rn))"
            echo "  Secure HamSCI access (vpn.hamsci.org:35736, TLS + trust-on-first-use)"
            echo "  needs no token or account — this station's key is filed on first connect."
        else
            echo "  No DASI number — the secure HamSCI rung is skipped; falling back to gw2."
        fi
    fi
    build_rac_tiers
    echo ""
    echo "Remote access (RAC) is a reverse tunnel to the fleet gateway so the"
    echo "admin can reach this station for support.  Keys, credentials and"
    echo "channel numbers are all handled automatically, and you can turn it"
    echo "off any time with:  sigmond-setup --rac-off"
    echo ""
    if [ "$RAC_PROFILE" = "standard" ]; then
        echo "  Gateway: $RAC_SERVER, secure only."
    else
        echo "  Gateways are tried in order, most secure first:"
        echo "$RAC_TIERS" | while IFS='|' read -r _l _c _r _t _p; do
            [ -n "$_c" ] && echo "    · $_l  ($_c:$_p)"
        done
        echo "  The tier that answers is reported at the end of the install."
    fi
    # When equipment is missing this is the single most valuable thing the
    # install can still achieve: it is how someone remote reaches the station
    # to help finish it.  Say so at the moment of the decision.
    if [ "$HAVE_RX888" = 0 ] || [ "$HAVE_GPSDO" = 0 ] || [ "$HAVE_TS1" = 0 ] || [ "$HAVE_MAG" = 0 ]; then
        echo ""
        echo "  ** Some equipment was not detected (see above).  Enabling remote"
        echo "     access is strongly recommended: it lets the fleet admin connect"
        echo "     and help finish the install once the missing parts are fitted. **"
    fi
    rd -r -p "Enable remote access? [Y/n] " RAC_EN
    RAC_NUM=""
    case "${RAC_EN:-Y}" in [Nn]*) ;; *) RAC_NUM="auto";; esac
}

ask_psws() {
    echo ""
    echo "HamSCI PSWS (space-weather / GRAPE uploads) — optional. If this station"
    echo "has a PSWS account (https://pswsnetwork.eng.ua.edu/), enter its IDs now."
    echo "The upload KEY is registered later from any SSH session — the VM's login"
    echo "banner walks you through it (no copy-paste needed on this console)."
    PSWS_ID=""
    while :; do
        rd -r -p "PSWS station ID (e.g. S000123, Enter to skip): " PSWS_ID
        PSWS_ID=$(echo "$PSWS_ID" | tr '[:lower:]' '[:upper:]' | tr -d ' ')
        [ -z "$PSWS_ID" ] && break
        echo "$PSWS_ID" | grep -qE '^S[0-9]{6}$' && break
        echo "  ✗ PSWS station IDs look like S000123 (S + 6 digits)"
    done
    PSWS_GRAPE=""; PSWS_MAG=""; PSWS_MAG_STATION=""
    if [ -n "$PSWS_ID" ]; then
        rd -r -p "  GRAPE instrument ID from the portal (e.g. 172, Enter if none): " PSWS_GRAPE
        PSWS_GRAPE=$(echo "$PSWS_GRAPE" | tr -d ' ')
        rd -r -p "  magnetometer instrument number from the portal (e.g. 84, Enter if none): " PSWS_MAG
        PSWS_MAG=$(echo "$PSWS_MAG" | tr -d ' ')
        PSWS_MAG_STATION=""
        if [ -n "$PSWS_MAG" ]; then
            rd -r -p "  magnetometer PSWS station ID (Enter if same as $PSWS_ID): " PSWS_MAG_STATION
            PSWS_MAG_STATION=$(echo "$PSWS_MAG_STATION" | tr '[:lower:]' '[:upper:]' | tr -d ' ')
        fi
    fi
}

ask_names() {
    # Station naming convention (rob 2026-07-29): the decoder VM carries the
    # station designator, the Proxmox host carries designator-PM. Default
    # derives from the reporter ID (AC0G/B4 → AC0G-B4), but multi-station
    # sites or generic deployments can override (DASI2-01 / DASI2-01-PM).
    local DES_DEFAULT
    DES_DEFAULT=$(echo "$REPORTER" | tr '/' '-')
    echo ""
    echo "Station names: the decoder VM takes the station designator and the"
    echo "Proxmox host takes designator-PM (e.g. AC0G-B4 + AC0G-B4-PM, or"
    echo "DASI2-01 + DASI2-01-PM for numbered deployments)."
    rd -r -p "Station designator [$DES_DEFAULT]: " DES
    DES=$(echo "${DES:-$DES_DEFAULT}" | tr -cd 'A-Za-z0-9-')
    [ -z "$DES" ] && DES="$DES_DEFAULT"
    VMNAME="$DES"
    PMNAME="$DES-PM"
}

# ── take the console cleanly ────────────────────────────────────────────
# sigmond-wizard.service has Conflicts=getty@tty1, but systemd stops getty
# ASYNCHRONOUSLY: getty routinely gets "login:" onto the screen just before
# it dies.  v3.25 printed blank lines first, but blank lines can't win a
# race — "login:" can land AFTER they've flushed, putting the banner back
# on the login line (mjh, v3.25 test 2026-08-09).  So wait for getty@tty1
# to actually be gone (bounded) before emitting the first byte; the leading
# blank line then lands below whatever getty last wrote.
for _i in $(seq 1 50); do
    _gst=$(systemctl show -p ActiveState --value getty@tty1.service 2>/dev/null)
    case "$_gst" in active|activating|deactivating) sleep 0.2 ;; *) break ;; esac
done
sleep 1
printf '\n\n'
echo "════════════════════════════════════════════════════════════════"
echo "  Sigmond appliance — first-boot station setup"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "  This asks a short series of questions about the station, then"
echo "  configures the Proxmox host and the decoder VM.  Nothing is"
echo "  applied until you confirm at the review screen."
echo ""
rd -r -p "  Press Enter to begin: " _ || true
echo ""

preflight_devices
ask_reporter
ask_grid
ask_antenna
ask_rac
ask_psws
ask_names

# ── review: everything on one screen, any entry editable ───────────────────
while :; do
    echo ""
    echo "  ── Review — nothing is applied yet ──────────────────"
    echo "  1) Reporter:  $REPORTER"
    echo "  2) Grid:      $GRID"
    echo "  3) Antenna:   ${ANTENNA:-(none)}"
    echo "  4) Remote:    $( [ -n "$RAC_NUM" ] && echo 'enabled — VM ssh/web + host ssh + Proxmox UI (number auto-assigned)' || echo 'disabled' )"
    if [ -n "$PSWS_ID" ]; then
        echo "  5) PSWS:      station $PSWS_ID${PSWS_GRAPE:+  grape=$PSWS_GRAPE}${PSWS_MAG:+  mag=$PSWS_MAG}${PSWS_MAG_STATION:+ (station $PSWS_MAG_STATION)}  (key registered after install)"
    else
        echo "  5) PSWS:      (skipped)"
    fi
    echo "  6) Names:     VM $VMNAME · Proxmox host $PMNAME"
    echo "  ─────────────────────────────────────────────────────"
    rd -r -p "Apply? [Y = apply / 1-6 = re-edit that entry / n = abort] " OK
    case "${OK:-Y}" in
        1) ask_reporter;;
        2) ask_grid;;
        3) ask_antenna;;
        4) ask_rac;;
        5) ask_psws;;
        6) ask_names;;
        [Nn]*) say "aborted by operator — nothing was applied. Rerun any time: sigmond-setup"; exit 1;;
        [Yy]*|"") break;;
        *) echo "  ✗ Y, n, or an entry number 1-6";;
    esac
done

# ── station names: VM = designator, Proxmox host = designator-PM ────────────
# Applied FIRST: everything after this uses qm, and a Proxmox single-node
# rename moves the node's config dir — do it before touching the VM, verify
# qm still works, and revert if it doesn't. pmxcfs keys node data by
# hostname: restart pve-cluster, then adopt the VM configs into the new
# node dir.
OLDHOST=$(hostname)
if [ "$PMNAME" != "$OLDHOST" ]; then
    say "renaming Proxmox host: $OLDHOST → $PMNAME"
    hostnamectl set-hostname "$PMNAME" 2>/dev/null || hostname "$PMNAME"
    sed -i "s/\b$OLDHOST\b/$PMNAME/g" /etc/hosts 2>/dev/null
    [ -f /etc/postfix/main.cf ] && sed -i "s/\b$OLDHOST\b/$PMNAME/g" /etc/postfix/main.cf 2>/dev/null
    systemctl restart pve-cluster 2>/dev/null
    # wait for pmxcfs to mount, then create the new node dir OURSELVES:
    # pmxcfs materializes nodes/<name> lazily — sometimes minutes after the
    # restart (observed 2026-07-29: a 54s wait wasn't enough, which made the
    # guard revert two good renames). mkdir inside the fuse fs is legal and
    # deterministic.
    for i in $(seq 1 15); do [ -d /etc/pve/nodes ] && break; sleep 2; done
    mkdir -p "/etc/pve/nodes/$PMNAME/qemu-server" 2>/dev/null
    [ -d "/etc/pve/nodes/$OLDHOST/qemu-server" ] && \
        mv "/etc/pve/nodes/$OLDHOST/qemu-server/"*.conf "/etc/pve/nodes/$PMNAME/qemu-server/" 2>/dev/null
    systemctl restart pveproxy pvedaemon 2>/dev/null
    # pmxcfs can take a while to settle after the restart — a single-shot
    # qm check 3s in reverted a PERFECTLY GOOD rename (nested run
    # 2026-07-29); give it up to 45s before declaring the rename broken
    QOK=0
    for i in $(seq 1 15); do
        qm status "$VMID" >/dev/null 2>&1 && { QOK=1; break; }
        sleep 3
    done
    if [ "$QOK" = 1 ]; then
        # confs adopted + qm healthy: retire the old node dir (a leftover
        # empty node lingers in the GUI forever otherwise)
        rm -rf "/etc/pve/nodes/$OLDHOST" 2>/dev/null
    else
        say "WARN: node rename broke qm — reverting to $OLDHOST"
        hostnamectl set-hostname "$OLDHOST" 2>/dev/null || hostname "$OLDHOST"
        sed -i "s/\b$PMNAME\b/$OLDHOST/g" /etc/hosts 2>/dev/null
        systemctl restart pve-cluster 2>/dev/null; sleep 5
        [ -d "/etc/pve/nodes/$PMNAME/qemu-server" ] && \
            mv "/etc/pve/nodes/$PMNAME/qemu-server/"*.conf "/etc/pve/nodes/$OLDHOST/qemu-server/" 2>/dev/null
        rm -rf "/etc/pve/nodes/$PMNAME" 2>/dev/null
        systemctl restart pveproxy pvedaemon 2>/dev/null; sleep 3
        PMNAME="$OLDHOST"
    fi
fi
qm set "$VMID" --name "$VMNAME" >/dev/null 2>&1 && say "decoder VM named $VMNAME"

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
    [ -n "$PSWS_MAG_STATION" ] && PSWS_TOML="$PSWS_TOML

[psws.stations]
\"mag-recorder\" = \"$PSWS_MAG_STATION\""
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
hostname = "$VMNAME"
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

# mag-recorder identity: render pushes the SITE PSWS station id, but the
# magnetometer often lives under its OWN portal station, and the config's
# callsign/grid stay template placeholders (field gap, AC0G-B4 2026-07-30).
# Fill them here.
if [ -n "${PSWS_MAG:-}" ]; then
    MAGST="${PSWS_MAG_STATION:-$PSWS_ID}"
    gexec 30 "C=/etc/mag-recorder/mag-recorder-config.toml; [ -f \$C ] && { sed -i -e \"s|^psws_station_id  = .*|psws_station_id  = \\\"$MAGST\\\"|\" -e \"s|^callsign         = \\\"<YOUR_CALL>\\\"|callsign         = \\\"$CALLSIGN\\\"|\" -e \"s|^grid_square      = \\\"<YOUR_GRID>\\\"|grid_square      = \\\"$GRID\\\"|\" \$C; systemctl try-restart mag-recorder 2>/dev/null; }; true" \
        || say "WARN: could not fill mag-recorder identity"
fi

# ── FFT wisdom seed + SDR bring-up sentinel ────────────────────────────────
# TWO structural gaps found on B4 + rob's Kamrui (2026-07-27/28, root-caused
# in smd @9b015f2): (a) NOTHING in the wizard/clone flow ever mints a radiod
# instance — `config render` only renders config for existing instances, and
# minting lives solely in `smd config init radiod`, reached via `smd bringup`;
# (b) nothing reacts to an RX888 that appears (or gets replugged out of an
# FX3 wedge) after setup. Net effect: every appliance deploy ended with
# radiod never started. The sentinel closes both: every 2 min, if an SDR is
# on the bus and no radiod instance exists, it runs the full non-interactive
# dasi2 bringup (identity comes from site-profile.toml, which bringup reads
# when flags are omitted).
# Also: `smd apply` refuses to START radiod until /etc/fftw/wisdomf exists,
# and the in-VM planner grinds >1 h on first boot — seed wisdom from the
# build fleet first (fftw silently ignores entries foreign to the CPU).
# appliance version visible inside the VM too (rob 2026-07-30) — same
# path as on the host; placed after personalize so identity reset can't
# touch it
gexec 15 "mkdir -p /etc/sigmond-appliance && echo '$(cat /etc/sigmond-appliance/version 2>/dev/null || echo unknown)' > /etc/sigmond-appliance/version" \
    || say "WARN: could not stamp appliance version into the VM"

if [ -f /root/sigmond-appliance/wisdomf-seed ]; then
    say "seeding FFT wisdom into the VM (radiod start is gated on it)"
    gexec 30 "[ -s /etc/fftw/wisdomf ] || { mkdir -p /etc/fftw; echo $(base64 -w0 /root/sigmond-appliance/wisdomf-seed) | base64 -d > /etc/fftw/wisdomf; }" \
        || say "WARN: could not seed FFT wisdom — first radiod start waits on the planner"
fi
# sigmond-site-timing: everything the timing chain needs from the local
# site, discovered and wired automatically after bringup (rob 2026-07-29:
# NO manual-only fixes — whatever the live station needed by hand must be
# in the greenfield flow). The script rides the stick as its own payload
# file (staged by the importer); the sentinel runs it after each
# successful bringup, and it is safe to rerun any time.
say "installing the site-timing auto-wiring helper in the VM"
if [ -f /root/sigmond-appliance/sigmond-site-timing ]; then
    gexec 60 "echo $(base64 -w0 /root/sigmond-appliance/sigmond-site-timing) | base64 -d > /usr/local/sbin/sigmond-site-timing && chmod 755 /usr/local/sbin/sigmond-site-timing" \
        || say "WARN: could not install sigmond-site-timing"
else
    say "WARN: sigmond-site-timing not staged — timing chain will need manual wiring"
fi
# location authority: GPSDO position is definitive over operator entry
# (rob 2026-08-04) — ticked by the sentinel; staged from the stick
if [ -f /root/sigmond-appliance/sigmond-location-check ]; then
    gexec 60 "echo $(base64 -w0 /root/sigmond-appliance/sigmond-location-check) | base64 -d > /usr/local/sbin/sigmond-location-check && chmod 755 /usr/local/sbin/sigmond-location-check" \
        || say "WARN: could not install sigmond-location-check"
fi
say "installing the SDR bring-up sentinel in the VM"
SENT_B64=$(base64 -w0 <<'SENTEOF'
#!/bin/bash
# sigmond-sdr-sentinel — bridge between "RX888 attached" and "radiod decoding".
# Installed by sigmond-setup. Nothing in smd mints a radiod instance outside
# of bringup, and nothing watches for late/replugged SDRs — this does both.
exec 9>/run/sigmond-sdr-sentinel.lock; flock -n 9 || exit 0
# location authority first (GPSDO definitive) — near-free when unchanged
[ -x /usr/local/sbin/sigmond-location-check ] && /usr/local/sbin/sigmond-location-check
ls /etc/radio/radiod@*.conf >/dev/null 2>&1 && exit 0            # already minted
[ -s /etc/sigmond/site-profile.toml ] || exit 0                  # no identity yet
lsusb 2>/dev/null | grep -qiE '04b4:00(f[013]|bc)|f4b3:0100' || exit 0   # no SDR
echo "RX888 present and no radiod instance — running smd bringup dasi2" \
  | systemd-cat -t sigmond-sdr-sentinel -p notice
smd bringup dasi2 --non-interactive
RC=$?
# on success, wire the timing chain to the local site (idempotent)
[ $RC -eq 0 ] && [ -x /usr/local/sbin/sigmond-site-timing ] && /usr/local/sbin/sigmond-site-timing
exit $RC
SENTEOF
)
SENTINST=$(cat <<INSTEOF
echo $SENT_B64 | base64 -d > /usr/local/sbin/sigmond-sdr-sentinel
chmod 755 /usr/local/sbin/sigmond-sdr-sentinel
cat > /etc/systemd/system/sigmond-sdr-sentinel.service <<'UEOF'
[Unit]
Description=Sigmond SDR sentinel: bring up radiod when an RX888 is present
[Service]
Type=oneshot
TimeoutStartSec=3600
ExecStart=/usr/local/sbin/sigmond-sdr-sentinel
UEOF
cat > /etc/systemd/system/sigmond-sdr-sentinel.timer <<'TEOF'
[Unit]
Description=Periodic SDR sentinel (mints radiod once an RX888 is attached)
[Timer]
OnBootSec=75
OnUnitActiveSec=120
[Install]
WantedBy=timers.target
TEOF
systemctl daemon-reload
systemctl enable --now sigmond-sdr-sentinel.timer
INSTEOF
)
gexec 60 "echo $(echo "$SENTINST" | base64 -w0) | base64 -d > /tmp/sig-sentinel-install.sh && bash /tmp/sig-sentinel-install.sh && rm -f /tmp/sig-sentinel-install.sh" \
    || say "WARN: could not install the SDR sentinel — run 'smd bringup dasi2' in the VM manually"

# ── relocation / reconfigure propagation (rob 2026-08-04) ──────────────────
# When bringup has already run (radiod conf exists — i.e. this is a
# reconfigure, e.g. a station staged at one site being re-gridded at its
# deployment site), rerun the site wiring so identity flows into
# hf-timestd/[station], the metrology channel envs, and mag-recorder, and
# bounce the recorders so uploads carry the new grid immediately.
if gexec 15 "ls /etc/radio/radiod@*.conf >/dev/null 2>&1"; then
    say "existing station detected — re-applying site wiring (relocation-safe)"
    gexec 300 "[ -x /usr/local/sbin/sigmond-site-timing ] && /usr/local/sbin/sigmond-site-timing; true" \
        || say "WARN: site wiring rerun failed — check journal -t sigmond-site-timing in the VM"
    gexec 60 "systemctl try-restart 'wspr-recorder@*' 'psk-recorder@*' 'meteor-scatter@*' 2>/dev/null; true"
fi

# ── site-keys restore (optional, rob 2026-07-29) ────────────────────────────
# A returning station's registered keys ride the stick: after burning, the
# stick's small FAT (EFI) volume accepts `site-keys.tar.gz`, created on the
# old station with:
#   tar czf site-keys.tar.gz -C / etc/hs-uploader/keys home/timestd/.ssh
# The importer staged it; restore AFTER config render (which generates a
# fresh key when absent) so the registered key wins, then fix ownership.
KEYS_RESTORED=""
if [ -f /root/sigmond-appliance/site-keys.tar.gz ]; then
    say "restoring site keys from the install stick"
    if gexec 60 "echo $(base64 -w0 /root/sigmond-appliance/site-keys.tar.gz) | base64 -d | tar xzf - -C / etc/hs-uploader/keys home/timestd/.ssh 2>/dev/null; chown -R hsupload:sigmond /etc/hs-uploader/keys 2>/dev/null || chown -R root:sigmond /etc/hs-uploader/keys 2>/dev/null; chmod 600 /etc/hs-uploader/keys/id_ed25519* 2>/dev/null; chmod 644 /etc/hs-uploader/keys/*.pub 2>/dev/null; chown -R timestd:timestd /home/timestd/.ssh 2>/dev/null; chmod 700 /home/timestd/.ssh 2>/dev/null; ls /etc/hs-uploader/keys/id_ed25519_host"; then
        KEYS_RESTORED=1
        say "site keys restored (hs-uploader + timestd)"
    else
        say "WARN: site-keys restore failed — see $LOG"
    fi
fi

RADIOD_STATE="unknown"
if gexec 15 "lsusb | grep -qiE '04b4:00(f[013]|bc)|f4b3:0100'"; then
    say "RX888 detected — starting SDR bring-up now (takes a few minutes)..."
    gexec 30 "systemctl start --no-block sigmond-sdr-sentinel.service" || true
    RADIOD_STATE="bringup launched — still settling; check later with: sigmond-vm smd admin validate"
    for i in $(seq 1 30); do
        if gexec 15 "systemctl list-units --state=active 'radiod@*' --no-legend 2>/dev/null | grep -q radiod@"; then
            RADIOD_STATE="radiod ACTIVE ✓ (decoding starts within ~2 min cycles)"
            break
        fi
        sleep 10
    done
elif [ "$HAVE_RX888" = 1 ]; then
    # The pre-flight saw an RX888 on this machine, but the VM cannot.  This is
    # the first-install USB handoff, and it is expected exactly once:
    #
    #   1. the host boots and enumerates the RX888 in its FX3 boot ROM
    #      (04b4:00f3, USB 2.0) -- the host has no rx888_boot, so it sits
    #      there claimed but unloaded;
    #   2. firstboot binds the USB controllers to the VM and reboots;
    #   3. the FX3 is handed across mid-state and never re-enumerates in the
    #      guest -- no `add` uevent, so 70-rx888-boot.rules never fires
    #      rx888_boot.service, so no firmware, so no RX888.
    #
    # On EVERY later boot the controllers are already assigned at boot and the
    # host never touches the device, so the guest enumerates it cleanly.  That
    # is why this is an install-only problem (rob, 2026-08-09).
    #
    # A warm reboot does NOT clear it: the FX3 stays latched as long as VBUS is
    # maintained.  Only removing power -- or physically replugging the RX888 --
    # resets it.  Say so plainly, because "reboot" is what an operator will try
    # first and it will not work.
    say ""
    say "  ── RX888 not visible to the decoder VM ──────────────"
    say "  An RX888 was detected on this machine, but the VM cannot see it."
    say "  This is EXPECTED on a first install: the SDR was handed across to"
    say "  the VM mid-state and needs its power removed to reset."
    say ""
    say "  ==> The installer POWERS THIS MACHINE OFF at the end of setup;"
    say "      that power-off is exactly the reset the SDR needs (a reboot"
    say "      would NOT be — the FX3 stays latched while USB power is held)."
    say ""
    say "  Nothing else needs doing — after you power back on, radiod comes up"
    say "  automatically within ~2 min, and this will not recur on later boots."
    say "  If the SDR STILL fails to appear then, unplug and replug the"
    say "  RX888's USB cable (some boards keep USB power even in soft-off)."
    say "──────────────────────────────────────────────────────"
    RADIOD_STATE="RX888 present on the host but NOT yet visible to the VM —
            expected on a first install; the POWER-OFF at the end of setup
            resets it, and radiod starts automatically ~2 min after the
            next power-on"
    # The wizard's transcript does not survive the power-off that follows, so
    # the operator never sees the paragraph above (rob 2026-08-09: "after the
    # reboot I did not see any mention of the need to re-plug or power cycle").
    # Leave a marker: the console access panel repeats the instruction on every
    # boot, and clears it by itself once the SDR turns up.
    : > "$MARK_DIR/.rx888-needs-powercycle"
else
    RADIOD_STATE="NO RX888 on the VM's USB bus — plug it in (or re-seat its USB
            cable if it was already in: a wedged FX3 needs a physical replug);
            the sentinel then brings radiod up automatically within ~2 min"
fi
say "SDR/radiod: $RADIOD_STATE"

# ── host RAC (optional) ─────────────────────────────────────────────────────
# ── operator access to the decoder VM ──────────────────────────────
# The operator account is the 'sigmond' user — remote root ssh login is
# DISABLED (root stays usable on the console / qm terminal for recovery).
# sigmond gets the SAME password as this host's root (hash copy — one
# password for the whole appliance), this host's SSH key, and sudo.
say "setting up VM accounts (ONE password — every account tracks this host's root)"
gexec 30 "id sigmond >/dev/null 2>&1 || useradd -m -s /bin/bash sigmond; usermod -s /bin/bash sigmond; getent group sudo >/dev/null && usermod -aG sudo sigmond || true" \
    || say "WARN: could not ensure sigmond operator user in VM"
# operator accounts must read fleet state: smd status parses
# group-readable client configs (hamsci hit Errno 13 on
# timestd-config.toml, 2026-07-30) — grant the service groups
gexec 30 "for u in hamsci sigmond; do for g in sigmond timestd pskrec wsprrec radio; do getent group \$g >/dev/null && usermod -aG \$g \$u; done; done; true" \
    || say "WARN: could not add operator accounts to service groups"
HASH=$(getent shadow root | cut -d: -f2)
if [ -n "$HASH" ] && [ "$HASH" != "*" ] && [ "$HASH" != "!" ]; then
    gexec 30 "usermod -p '$HASH' sigmond && usermod -p '$HASH' root && usermod -p '$HASH' hamsci" \
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
# operator comfort (rob 2026-07-30): tmux mouse mode for every login user
# (btop + tmux binaries are baked into the template since v3.16)
gexec 30 "for h in /root /home/hamsci /home/sigmond /etc/skel; do [ -d \$h ] && { echo 'set -g mouse on' > \$h/.tmux.conf; o=\$(stat -c %U \$h 2>/dev/null); [ \"\$o\" != root ] && chown \$o: \$h/.tmux.conf; }; done; true" \
    || say "WARN: could not install .tmux.conf in the VM"
# operator shell helpers: rob's tm() tmux picker + ll/lrt aliases,
# system-wide via /etc/profile.d (bash-guarded; staged from the stick)
if [ -f /root/sigmond-appliance/sigmond-operator.sh ]; then
    gexec 30 "echo $(base64 -w0 /root/sigmond-appliance/sigmond-operator.sh) | base64 -d > /etc/profile.d/sigmond-operator.sh && chmod 644 /etc/profile.d/sigmond-operator.sh; grep -q sigmond-operator /etc/bash.bashrc 2>/dev/null || echo '[ -f /etc/profile.d/sigmond-operator.sh ] && . /etc/profile.d/sigmond-operator.sh' >> /etc/bash.bashrc" \
        || say "WARN: could not install operator shell helpers in the VM"
fi
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
        REG=""
        RAC_TRIED=""
        while IFS='|' read -r _lbl _cand _cand_reg _tls _fport; do
        [ -n "$_cand" ] || continue
        RAC_TRIED="${RAC_TRIED:+$RAC_TRIED, }$_lbl"
        say "trying $_lbl — $_cand:$_fport (registrar $_cand_reg)"
        case "$_tls" in
            off) say "  NOTE: this tier is UNSECURED (no TLS, legacy frps)." ;;
            opp) say "  NOTE: encrypted (TLS) but the server is unauthenticated" ;;
        esac
        # The tier IS its tunnel port: if no frps listens there, the tier is
        # down no matter what the (shared) registrar would say — probe it
        # first so a dead secure stack can't register and then fail late.
        if ! timeout 5 bash -c "exec 3<>/dev/tcp/$_cand/$_fport" 2>/dev/null; then
            say "  $_lbl did not answer (no frps on $_cand:$_fport)"
            continue
        fi
        if [ "$_cand_reg" = "DIRECT" ]; then
            # Registrar-less DASI rung: deterministic RAC + ports, verified
            # by ATTEMPT — a throwaway frpc claims all 4 proxies and the
            # frps itself refuses a taken name/port.  The live tunnel (if
            # any) is untouched: separate config, separate admin port.
            _racn=$((220 + DASI_NUM))
            _pvs=$((RAC_BASE_VMSSH+_racn)); _pvw=$((RAC_BASE_VMWEB+_racn))
            _phs=$((RAC_BASE_HSSH+_racn)); _phu=$((RAC_BASE_HUI+_racn))
            _duser="DASI-$(printf '%03d' "$DASI_NUM")"
            say "  deterministic mapping: $_duser -> RAC #$_racn (attempting, not probing)"
            _tf=$(mktemp /tmp/frpc-dasi-XXXXXX.toml)
            _dtls=true; [ "$_tls" = "off" ] && _dtls=false
            {
                printf 'serverAddr = "%s"\nserverPort = %s\nuser = "%s"\nloginFailExit = true\n' "$_cand" "$_fport" "$_duser"
                # the pubkey rides EVERY login as metadata — today the server
                # ignores it; a future Login plugin on the VPN turns it into
                # per-unit admission (TOFU) with no Linux accounts (rob).
                printf '[metadatas]\npubkey = "%s"\nsite = "%s"\ndasi = "%s"\n' "$(cat /root/.ssh/id_ed25519.pub)" "$SITE" "$_duser"
                # TOFU: the pubkey (above) is the credential; the server's
                # auth.token is empty, so the client sends an empty token too.
                printf '[auth]\nmethod = "token"\ntoken = ""\n'
                printf '[transport.tls]\nenable = %s\n' "$_dtls"
                printf '[webServer]\naddr = "127.0.0.1"\nport = 7502\n'
                for _spec in "vm-ssh:12222:$_pvs" "vm-web:12223:$_pvw" "host-ssh:22:$_phs" "host-ui:8006:$_phu"; do
                    IFS=: read -r _n _lp _rp <<<"$_spec"
                    printf '[[proxies]]\nname = "%s-%s"\ntype = "tcp"\nlocalIP = "127.0.0.1"\nlocalPort = %s\nremotePort = %s\n' "$SITE" "$_n" "$_lp" "$_rp"
                done
            } > "$_tf"
            /usr/local/sbin/frpc -c "$_tf" >>"$LOG" 2>&1 &
            _tpid=$!
            _drun=0; _derr=""
            for _i in 1 2 3 4 5 6 7 8; do
                sleep 3
                kill -0 "$_tpid" 2>/dev/null || break
                _api=$(curl -s http://127.0.0.1:7502/api/status 2>/dev/null)
                _drun=$(echo "$_api" | grep -o '"status":"running"' | wc -l)
                _derr=$(echo "$_api" | grep -o '"err":"[^"]\{1,\}"' | head -3)
                [ "$_drun" -ge 4 ] && break
            done
            kill "$_tpid" 2>/dev/null; wait "$_tpid" 2>/dev/null; rm -f "$_tf"
            if [ "$_drun" -ge 4 ]; then
                say "  RAC #$_racn is free on $_cand — claiming it"
                REG="RACN=$_racn RUSER=$_duser RTOKEN=$HAMSCI_TOKEN P_VMSSH=$_pvs P_VMWEB=$_pvw P_HSSH=$_phs P_HUI=$_phu SRV=$_cand SPORT=$_fport"
            elif echo "$_derr" | grep -qi "port already"; then
                say "  ** RAC #$_racn ports are TAKEN on $_cand — is another unit already"
                say "  ** using DASI number $DASI_NUM?  Choose a different number via"
                say "  ** sigmond-setup --reconfigure, or let the ladder continue below."
            else
                say "  HamSCI direct attempt failed (${_derr:-login refused — check the token}); see $LOG"
            fi
        else
        REG=$(python3 - "$SITE" "$(cat /root/.ssh/id_ed25519.pub)" "$_cand_reg" <<'PYEOF' 2>>"$LOG"
import json, re, sys, urllib.error, urllib.request
site, pub, registrar = sys.argv[1], sys.argv[2], sys.argv[3]
req = urllib.request.Request(
    registrar,
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
        fi
        if [ -n "$REG" ]; then
            RAC_SERVER="$_cand"
            RAC_REGISTRAR="$_cand_reg"
            RAC_TLS="$_tls"
            RAC_PORT="$_fport"
            RAC_TIER_LABEL="$_lbl"
            break
        fi
        say "  $_lbl frps answered on :$_fport but its registrar did not"
        done <<TIEREOF
$RAC_TIERS
TIEREOF
        if [ -z "$REG" ]; then
            RAC_STATE="FAILED — no gateway tier answered (tried: $RAC_TRIED; see $LOG), rerun: sigmond-setup --reconfigure"
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

            # transport follows the tier that actually answered: a secure
            # tier pins the fleet CA, opportunistic (opp) encrypts without
            # pinning (server cert is self-signed — vpn.hamsci.org today),
            # and an unsecured one has no TLS at all.
            case "$RAC_TLS" in
                off) RAC_TLS_BLOCK="[transport.tls]
enable = false" ;;
                opp) RAC_TLS_BLOCK="[transport.tls]
enable = true" ;;
                *)   RAC_TLS_BLOCK="[transport.tls]
enable = true
trustedCaFile = \"/etc/sigmond/frps-ca.crt\"" ;;
            esac
            # record the tier so 'sigmond-setup --rac-upgrade' can tell whether
            # a better one has since come up
            printf '%s\n' "$RAC_TIER_LABEL" > "$MARK_DIR/rac-tier"
            printf '%s\n' "$RAC_REGISTRAR" > "$MARK_DIR/rac-registrar"
            say "writing /etc/sigmond/frpc-host.toml (4 channels, one tunnel)"
            cat > /etc/sigmond/frpc-host.toml <<TOMLEOF
# Written by sigmond-setup $(date -u +%F) — RAC #$RACN (auto-assigned), site $SITE.
# ONE frpc on the Proxmox host carries all four channels; the vm-*
# channels ride the local relays (12222/12223) that resolve the VM's
# current IP per connection, so this file never needs the VM's address.
# serverPort comes from the TIER that answered (35736 TLS / 35735 legacy),
# not from the registrar's reply — the registrar only knows the legacy stack.
serverAddr = "$SRV"
serverPort = ${RAC_PORT:-$SPORT}
user = "$RUSER"

# The station's pubkey rides every login as metadata (any tier): servers
# ignore it today; a Login plugin can enforce per-unit admission (TOFU)
# from it later — no per-client accounts needed (rob 2026-08-09).
[metadatas]
pubkey = "$(cat /root/.ssh/id_ed25519.pub)"
site = "$SITE"
dasi = "${DASI_NUM:+DASI-$(printf '%03d' "$DASI_NUM")}"

[auth]
method = "token"
token = "$RTOKEN"

$RAC_TLS_BLOCK

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
                RAC_STATE="#$RACN live on $SRV via $RAC_TIER_LABEL — VM ssh :$P_VMSSH · VM web :$P_VMWEB · host ssh :$P_HSSH · Proxmox UI :$P_HUI (off: sigmond-setup --rac-off)"
                if [ "$RAC_TLS" = "off" ]; then
                    RAC_STATE="$RAC_STATE
              ** this tunnel is UNSECURED (no TLS) — the secure gateways did
                 not answer.  Once one is available run: sigmond-setup --rac-upgrade **"
                fi
                echo "$RACN" > "$MARK_DIR/rac-number"
            else
                RAC_STATE="FAILED — registered, but only $RUNNING/4 channels came up; journalctl -u sigmond-rac-host"
                say "WARN: $RAC_STATE"
            fi
        fi
    fi
fi

PSWS_STATE="skipped — add later: sigmond-setup --reconfigure"
if [ -n "$PSWS_ID" ] && [ -n "$KEYS_RESTORED" ]; then
    if gexec 90 "smd psws verify"; then
        PSWS_STATE="station $PSWS_ID — registered key RESTORED from the stick, verify PASSED ✓"
    else
        PSWS_STATE="station $PSWS_ID — key restored from the stick; verify pending
            (portal may still need the key; check with: smd psws verify)"
    fi
elif [ -n "$PSWS_ID" ]; then
    PSWS_STATE="station $PSWS_ID — IDs recorded, UPLOAD KEY NOT YET REGISTERED.
            Finish from any computer: log into the VM (sigmond-vm) — the
            login banner shows the key to paste into the PSWS portal,
            then run:  smd psws verify"
fi

echo "$REPORTER $GRID $(date -u +%F)" > "$CONF_MARK"
# Station class + DASI number stick across --reconfigure / --rac-upgrade.
printf '%s\n' "$RAC_PROFILE" > "$MARK_DIR/rac-profile"
[ -n "$DASI_NUM" ] && printf '%s\n' "$DASI_NUM" > "$MARK_DIR/dasi-number"

# The wizard unit must NOT stay enabled once configured: its
# Conflicts=getty@tty1 stop job fires even when the Condition check fails
# (conditions don't remove Conflicts from the boot transaction — same bug
# class as the dasi-install tty takeover, 2026-07-26), which left every
# post-wizard boot with a BLANK console: no login prompt, no access panel
# (observed on B4 v3.1 and rob's Kamrui, 2026-07-27/28).
# disable ONLY — do NOT start getty here: Conflicts is symmetric, so a
# getty start at this point SIGTERMs the wizard itself mid-run (v3.6 field
# run 2026-07-29: summary never written/shown). The unit's ExecStopPost
# already hands the console to getty when the wizard exits.
systemctl disable sigmond-wizard.service 2>/dev/null

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
   login:   sigmond or hamsci — SAME password as this host's root
            (ONE password per appliance; remote root ssh is disabled)
   shell:   sigmond-vm   ← run this on the host: finds the VM's
            current IP and logs you in as sigmond ($SSH_STATE)
   ssh:     ssh sigmond@${VMIP:-<vm-ip>}   (from other machines;
            sigmond-vm --ip prints the current address)
   console: qm terminal $VMID  (Ctrl+O exits; sigmond or root)
 SDR/radiod: $RADIOD_STATE
 RAC:       $RAC_STATE
 PSWS:      $PSWS_STATE
 Rerun wizard:  sigmond-setup --reconfigure
 This summary is saved in /root/sigmond-setup-summary.txt
──────────────────────────────────────────────────────
SEOF
)
echo "$SUMMARY" | tee -a "$LOG"
echo "$SUMMARY" > /root/sigmond-setup-summary.txt
# The persistent, boot-surviving login panel is sigmond-issue's job
# (pvebanner rewrites /etc/issue every boot and DHCP addresses go stale —
# it regenerates with live IPs).  Fall back to the old one-shot append on
# hosts that don't have it yet.
if [ -x /usr/local/sbin/sigmond-issue ]; then
    SIGMOND_VMID="$VMID" /usr/local/sbin/sigmond-issue || true
else
    for f in /etc/issue /etc/motd; do
        sed -i '/^─* Sigmond setup ─*$/,/^─* end Sigmond setup ─*$/d' "$f" 2>/dev/null
        { echo "────── Sigmond setup ──────"
          echo "$SUMMARY"
          echo "────── end Sigmond setup ──────"; } >> "$f"
    done
fi
echo ""
rd -r -p "Press Enter to finish (this summary stays on the login screen)... " _ 2>/dev/null || true
exit 0
