#!/bin/bash
# Tier-2 nested boot test v3 — runs on B3. Phases:
#  A) UEFI boot USB image → PVE 9.1 auto-install to empty NVMe → power-off
#  B) boot NVMe only → PVE up, firstboot ran w/o media, importer armed
#  C) boot NVMe + USB → udev import → VM 100 created + HOST TUNED (grub
#     isolcpus/vfio/hookscript/affinity) → QMP-detach the USB → importer
#     reboots the nested host → VM 100 autostart. In the NEST there is no
#     IOMMU, so hostpci start fails by design: strip hostpci, start VM —
#     passthrough itself is real-hardware scope (BIOS checklist).
#  D) drive the wizard non-interactively; verify identity + PSWS in guest;
#     verify GENERIC kernel (USB stack) + hamsci login in the decoder VM.
# June lessons: OVMF (never SeaBIOS+NVMe), >=12G RAM, ps -C comm matching,
# power-off detect via process exit, identical PCI topology across boots
# (xhci declared before usb-storage, always present).
set -u
cd "$HOME/appliance/v3"
LOG="$PWD/test-v3.log"
exec >> "$LOG" 2>&1
say(){ echo "[test $(date '+%T')] $*"; }

# >>> phase_d_verdict (test-phase-d-verdict.sh loads exactly this block)
# Phase D's metrology verdict over the guest probe's KEY:N lines.  Prints
#   METROLOGY_OK        metrology units are running
#   NO_SDR_EXPECTED     zero units, and the guest has NO SDR on its bus, and
#                       bring-up deferred the radio half for exactly that reason
#                       and failed nothing else -- the nest's normal case.  Two
#                       signatures qualify: firstrun's marker reads
#                       result=awaiting-sdr (sigmond 7966e69 on, 2026-10-04), or
#                       the older images' stop at 'radiod configured'
#   FATAL_NO_METROLOGY  anything else with zero units (ad154d3's defect)
# and returns 1 only for the FATAL.  A missing key reads as the unsafe value,
# so a garbled reply can never pass.
#
# Why the exception exists: this nest has no RX888 (passthrough is real-
# hardware scope), so `smd config init radiod` finds no card, the hard
# checkpoint aborts bring-up, and no metrology can exist.  Without it the
# assertion could only ever FATAL here -- v3.64 was the first real nest run
# after ad154d3 and failed on exactly that.  The metrology claim itself is
# then proven on hardware (B4), never here.
phase_d_verdict() {
    local r="$1" k
    # Not anchored to ^: qm guest exec returns JSON, whose "out-data" joins the
    # lines with a literal \n.  (No key is a suffix of another, so an
    # unanchored match cannot confuse them -- keep it that way.)
    _pdv() { echo "$r" | grep -oE "$1:[0-9]+" | head -1 | cut -d: -f2; }
    local count sdr rstep rchk ochk ostep await
    count=$(_pdv COUNT);  sdr=$(_pdv SDRDEV)
    rstep=$(_pdv RADIODSTEP); rchk=$(_pdv RADIODCHK)
    ochk=$(_pdv OTHERCHK);  ostep=$(_pdv OTHERSTEP)
    await=$(_pdv AWAITSDR)
    [ -n "$count" ] || { echo FATAL_NO_METROLOGY; return 1; }
    if [ "$count" -gt 0 ]; then echo METROLOGY_OK; return 0; fi
    # The honest partial: no card, the marker says so (never "done"), and no
    # other step or checkpoint failed.  A card on the bus with this marker is
    # the defect, not the exception.
    if [ "${sdr:-1}" = 0 ] && [ "${await:-0}" -gt 0 ] \
       && [ "${ochk:-1}" = 0 ] && [ "${ostep:-1}" = 0 ]; then
        echo NO_SDR_EXPECTED; return 0
    fi
    if [ "${sdr:-1}" = 0 ] && [ "${rstep:-0}" -gt 0 ] && [ "${rchk:-0}" -gt 0 ] \
       && [ "${ochk:-1}" = 0 ] && [ "${ostep:-1}" = 0 ]; then
        echo NO_SDR_EXPECTED; return 0
    fi
    echo FATAL_NO_METROLOGY; return 1
}
# <<< phase_d_verdict

# >>> remote_rig (test-remote-rig-lines.sh loads exactly this block)
# The readers for the remote-access checks of Phase D (sigmond
# tasks/plan-remote-access.md).
#
# wizard_answers <racq>: the wizard's answers, one per line, in the order it
# asks.  racq=1 for a wizard that still asks "Enable remote access? [Y/n]"
# (v3.70 and earlier: the update rig's base image); racq=0 for one that asks
# nothing about it.  One answer too many or too few shifts every answer after
# it, and the wizard then reads a PSWS id as a heartbeat host.
wizard_answers() {
    local a=(
        'N0CALL/T1'          # reporter id
        'EM00aa'             # grid square
        'Tier2 test dipole'  # antenna description
        'n'                  # is this a DASI station?
    )
    # v3.70 and earlier asked "Enable remote access? [Y/n]" at this point.
    [ "$1" = 1 ] && a+=( 'n' )
    a+=(
        'S000999'            # PSWS station id
        '172'                # GRAPE instrument id
        '84'                 # magnetometer instrument id
        ''                   # heartbeat: send them? (blank = Y, the default)
        ''                   # heartbeat: collector host (blank = wd30.wsprdaemon.org)
        ''                   # heartbeat: collector port (blank = 38222)
        ''                   # station designator (blank = default from reporter)
        'Y'                  # apply
    )
    printf '%s\n' "${a[@]}"
}
# rr_state <file>: on | off | down from the switch's answer, or nothing.  The
# answer names its state on a line that reads exactly one of three strings.
# For `smd remote on` that line follows the registration's own lines, so the
# first line of the answer proves nothing.
rr_state() {
    LC_ALL=C awk '
        $0 == "Remote access: on"                { print "on";   exit }
        $0 == "Remote access: off"               { print "off";  exit }
        $0 == "Remote access: wanted on, not up" { print "down"; exit }' "$1" 2>/dev/null
}
# rr_tok <KEY> <text>: the value of the first line that reads KEY:value, or
# nothing.  The probes that run on the nested host print their facts as such
# lines and end with END:1.  The key is matched as plain text from the start of
# the line, so a longer key, an indented line or a dot in the key cannot answer
# for it.  A value may hold colons and spaces ("root:root 755").
rr_tok() {
    printf '%s\n' "$2" | LC_ALL=C awk -v k="$1" 'index($0, k ":") == 1 { print substr($0, length(k) + 2); exit }'
}
# nh_ok <answer>: a probe on the nested host answered, if a line of its answer
# reads END:1.  An ssh that died prints none, and the rig then calls that "no
# answer", never "the station fails the check".
nh_ok() {
    printf '%s\n' "$1" | grep -qx 'END:1'
}
# rr_khkey <file>: the host key in the VM's rac-switch.known_hosts, as a guest
# probe handed the file back; nothing when it holds none.  The key comes from
# the first line whose second field reads ssh-ed25519: a profile script in the
# guest may print a line of its own ahead of the file's.
rr_khkey() {
    LC_ALL=C awk '$2 == "ssh-ed25519" { print $3; exit }' "$1" 2>/dev/null
}
# <<< remote_rig

# >>> qga_rig (test-qga-rig-lines.sh loads exactly this block)
# The guest-agent checks of Phase D (sigmond tasks/plan-guest-agent-requests.md).
#
# Each function below prints a script for the NESTED HOST; the rig pipes it to
# `$SSHN "bash -s <vmid>"`.  A script prints its facts as KEY:value lines and
# ends with END:1, so that rr_tok and nh_ok (the remote_rig block) can read
# them.  The scripts read four names from the environment, for the hermetic
# test alone: QGA_PANEL (the panel script), QGA_ISSUE (the file it paints),
# QGA_NOTE (the line a reset leaves) and QGA_DIR (the agents' sockets).
#
# qga_probe_panel: has this image's panel the fix?  PANELFIX:1 when the panel
# script carries the reset; 0 for a panel from before v3.71.
qga_probe_panel() {
    cat <<'QGAEOF'
P="${QGA_PANEL:-/usr/local/sbin/sigmond-issue}"
grep -q 'qga_reset' "$P" 2>/dev/null && echo PANELFIX:1 || echo PANELFIX:0
echo END:1
QGAEOF
}
# qga_probe_refresh: twelve panel refreshes, one ping after each.  The panel's
# own timer stands still meanwhile, because a refresh that finds another one
# running does nothing.  SILENT counts the pings that got no answer; NOTE
# holds the line a reset left, or "none".
qga_probe_refresh() {
    cat <<'QGAEOF'
VMID="$1"
P="${QGA_PANEL:-/usr/local/sbin/sigmond-issue}"
N="${QGA_NOTE:-/run/sigmond/qga-reset}"
systemctl stop sigmond-issue.timer >/dev/null 2>&1
trap 'systemctl start sigmond-issue.timer >/dev/null 2>&1' EXIT
n=0
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    SIGMOND_VMID="$VMID" "$P" >/dev/null 2>&1
    timeout 10 qm agent "$VMID" ping >/dev/null 2>&1 || n=$((n+1))
done
echo "SILENT:$n"
if [ -e "$N" ]; then echo "NOTE:$(head -1 "$N")"; else echo "NOTE:none"; fi
echo END:1
QGAEOF
}
# qga_probe_deafen: send the request the panel of v3.70 sent, a command that
# holds box-drawing bytes, until the agent stands deaf.  Proxmox writes such a
# request short; about one time in six the agent's parser then waits for the
# rest for good.  The other times the agent drops the NEXT request and
# recovers, so one lost ping proves nothing: deaf means three pings in a row
# without an answer.  DEAF holds the try that did it, or 0 when none of the
# tries did.  The panel's, the heartbeat's and the pairing's timers stand still from here
# until qga_probe_heal has run, so that the rig's own refresh does the healing.
qga_probe_deafen() {
    cat <<'QGAEOF'
VMID="$1"; TRIES="${2:-40}"
N="${QGA_NOTE:-/run/sigmond/qga-reset}"
# Three things on the host heal a deaf agent: the panel, the heartbeat and the
# pairing.  Hold all three still, and wait out a run already going (the
# pairing's timer, started again by remote-access check 5, fires one), or that
# run heals the agent first and the note names it, not the panel.
systemctl stop sigmond-issue.timer pm-heartbeat.timer sigmond-rac-pair.timer sigmond-rac-pair.path >/dev/null 2>&1
for w in $(seq 1 90); do
    busy=0
    for u in sigmond-issue.service pm-heartbeat.service sigmond-rac-pair.service; do
        case "$(systemctl is-active "$u" 2>/dev/null)" in activating|active|reloading|deactivating) busy=1 ;; esac
    done
    [ "$busy" = 0 ] && break
    sleep 1
done
rm -f "$N" "$N.seen"
poison=$(printf 'true # \342\224\200\342\224\200\342\224\200 \302\273')
deaf=0
for i in $(seq 1 "$TRIES"); do
    timeout 15 qm guest exec "$VMID" --timeout 5 -- /bin/bash -c "$poison" >/dev/null 2>&1
    s=0
    for j in 1 2 3; do
        sleep 2
        timeout 10 qm agent "$VMID" ping >/dev/null 2>&1 || s=$((s+1))
    done
    if [ "$s" = 3 ]; then deaf=$i; break; fi
done
echo "DEAF:$deaf"
echo END:1
QGAEOF
}
# qga_probe_heal: one panel refresh, then one ping.  HEARS:1 when the agent
# answers; NOTE holds the line the reset left; PANELSILENT:1 when the panel
# still says that the agent does not answer.  All the timers start again here,
# whatever the refresh did.
qga_probe_heal() {
    cat <<'QGAEOF'
VMID="$1"
P="${QGA_PANEL:-/usr/local/sbin/sigmond-issue}"
I="${QGA_ISSUE:-/etc/issue}"
N="${QGA_NOTE:-/run/sigmond/qga-reset}"
trap 'systemctl start sigmond-issue.timer pm-heartbeat.timer sigmond-rac-pair.timer sigmond-rac-pair.path >/dev/null 2>&1' EXIT
SIGMOND_VMID="$VMID" "$P" >/dev/null 2>&1
if timeout 10 qm agent "$VMID" ping >/dev/null 2>&1; then echo HEARS:1; else echo HEARS:0; fi
if [ -e "$N" ]; then echo "NOTE:$(head -1 "$N")"; else echo "NOTE:none"; fi
grep -q 'guest agent does not answer' "$I" 2>/dev/null && echo PANELSILENT:1 || echo PANELSILENT:0
# RESETHEX: the raw bytes the agent sends back to one more parser reset, in
# hex, read until 4242 arrives or 4 seconds pass; "none" when it sends nothing.
# The rig prints it once, so that a real run measures what the agent sends.
HEX=$(timeout 10 python3 -c 'import socket,sys,time
s=socket.socket(socket.AF_UNIX); end=time.monotonic()+4; got=b""
try:
    s.settimeout(4); s.connect(sys.argv[1]+"/"+sys.argv[2]+".qga")
    s.sendall(b"\xff"+b"{\"execute\":\"guest-sync-delimited\",\"arguments\":{\"id\":4242}}\n")
    while b"4242" not in got:
        left=end-time.monotonic()
        if left<=0: break
        s.settimeout(left); d=s.recv(4096)
        if not d: break
        got+=d
except Exception: pass
print(got.hex() if got else "none")' "${QGA_DIR:-/var/run/qemu-server}" "$VMID" 2>/dev/null </dev/null)
echo "RESETHEX:${HEX:-none}"
echo END:1
QGAEOF
}
# qga_probe_bringup: one panel refresh, then what its bring-up line says, one
# token per sentence the panel can print.  UNIT holds the state of the
# bring-up unit before and after the refresh, joined by a slash, so that the
# rig judges the BUILDING token only when the unit ran through the whole
# refresh.
qga_probe_bringup() {
    cat <<'QGAEOF'
VMID="$1"
P="${QGA_PANEL:-/usr/local/sbin/sigmond-issue}"
I="${QGA_ISSUE:-/etc/issue}"
unit(){ timeout 20 qm guest exec "$VMID" --timeout 10 -- /bin/systemctl is-active sigmond-firstrun-bringup 2>/dev/null \
          | grep -oE '"out-data" *: *"[a-z]+' | grep -oE '[a-z]+$' | head -1; }
# Hold the panel's timer still and wait out a refresh already running, as the
# deafen probe does.  The heal probe's EXIT trap restarts the timer, and when
# its 5-minute interval has passed systemd fires a refresh at once; that
# refresh then holds the panel's lock, our refresh exits on it, and /etc/issue
# shows only the "starting" placeholder (nested D, 2026-10-21, twice).
trap 'systemctl start sigmond-issue.timer >/dev/null 2>&1' EXIT
systemctl stop sigmond-issue.timer >/dev/null 2>&1
for w in $(seq 1 90); do
    case "$(systemctl is-active sigmond-issue.service 2>/dev/null)" in
        activating|active|reloading|deactivating) sleep 1 ;;
        *) break ;;
    esac
done
u1=$(unit)
SIGMOND_VMID="$VMID" "$P" >/dev/null 2>&1
u2=$(unit)
echo "UNIT:${u1:-none}/${u2:-none}"
t(){ grep -q "$2" "$I" 2>/dev/null && echo "$1:1" || echo "$1:0"; }
t BUILDING 'STATION IS STILL BUILDING'
t NOWEB    'BRING-UP FINISHED BUT ka9q-web IS NOT RUNNING'
t NOSDR    'bring-up ran WITHOUT the radio'
t RETRY    'BRING-UP FAILED -- it tries again'
t GAVEUP   'BRING-UP FAILED THREE TIMES'
t STOPPED  'BRING-UP WAS STOPPED BEFORE IT FINISHED'
t SILENT   'guest agent does not answer'
# STARTING:1 means /etc/issue still holds the placeholder: our refresh did not
# run to the end, so the tokens above say nothing about the panel.
t STARTING 'It is not up yet\.'
echo END:1
QGAEOF
}
# qga_fatal <message> <answer>: a guest-agent check failed; shows the answer
# of the probe that the verdict rests on.
qga_fatal(){ say "FATAL: $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      /' | tail -14; exit 1; }
# <<< qga_rig

# >>> sink_part2 (test-nested-sink-part2.sh loads exactly this block)
# The sink switches, step 2b part 2 (sigmond tasks/spec-sink-2b-part2.md
# §13.1).  With an hs-uploader that offers `gate`, the manifest step carries
# [uploads] over into the switch files under /etc/hs-uploader/sinks/, writes
# the carry-over marker, renders the manifest without `discard` or a banner,
# and moves the heartbeat into pipelines.d/sigmond.toml.  `smd sink fill`
# then lowers every in-process sender (the levers) and restarts each touched
# unit alone, once, never radiod.
#
# The guest scripts below print KEY:value lines and sections between
# "==SP2 <NAME>==" and "==SP2 END==", and end with END:1.  They hold only
# ASCII, and travel base64-encoded (sp2_gx).  The readers run on this host:
# sp2_unwrap turns qm's JSON reply into the command's own lines, and the
# *_facts functions reduce those to KEY:value lines.  Each verdict prints
# one "FAIL: <why>" or "UNCHECKED: <what>" line per finding, and nothing
# when all holds.  A reply with no END:1 is no verdict at all.

# The phrases the rig reads from `smd sink status`.  Part 2's switch view
# keeps part 1's words whole (sigmond Task 21, fix round 1).
SP2_UPLOAD_PHRASE='site sink: upload (store and send)'
SP2_OFF_PHRASE='site sink: off'

# The fill, as the rig runs it in the guest.  The exit code comes from a
# variable, never through a pipe.  SP2_SMD exists for the hermetic test.
SP2_FILL='o=$(cd / && "${SP2_SMD:-smd}" sink fill --reason rig 2>&1); rc=$?
printf "%s\n" "$o"
echo "FILLRC:$rc"
echo "END:1"'

# sp2_unwrap <raw> <out>: qm guest exec's JSON reply -> out-data plus
# err-data, as the guest printed them.  Returns 1 when the reply holds no
# JSON object (the channel failed).  Text the channel double-encoded stays
# double-encoded; every pattern below is ASCII.
sp2_unwrap() {
    python3 - "$1" "$2" <<'PY'
import json, sys
raw = open(sys.argv[1], 'rb').read().decode('utf-8', 'replace')
d = None
for cand in (raw, raw[raw.find('{'):raw.rfind('}') + 1]):
    if not cand:
        continue
    try:
        d = json.loads(cand)
        break
    except ValueError:
        continue
if not isinstance(d, dict) or not ('out-data' in d or 'exitcode' in d):
    sys.exit(1)
with open(sys.argv[2], 'w', encoding='utf-8') as fh:
    fh.write((d.get('out-data') or '') + (d.get('err-data') or ''))
PY
}

# sp2_tok <file> <KEY>: the value of the first KEY:value line, or nothing.
sp2_tok() {
    LC_ALL=C awk -v k="$2" 'index($0, k ":") == 1 { print substr($0, length(k) + 2); exit }' "$1" 2>/dev/null
}

# sp2_probe_script: the guest script for the fresh station's facts.
# SP2_ROOT, SP2_SMD and SP2_HSU exist for the hermetic test alone.
sp2_probe_script() {
    cat <<'SP2EOF'
set -u
export PYTHONDONTWRITEBYTECODE=1
R="${SP2_ROOT:-}"
SMD="${SP2_SMD:-smd}"
HSU="${SP2_HSU:-/opt/hs-uploader/venv/bin/hs-uploader}"
M="$R/etc/hs-uploader/pipelines.toml"
PD="$R/etc/hs-uploader/pipelines.d"
S="$PD/sigmond.toml"
K="$R/var/lib/hs-uploader/carry-over-v1.done"
if [ -e "$K" ]; then echo "MARKER:1"; else echo "MARKER:0"; fi
if [ -r "$M" ]; then
    echo "MANIFEST:1"
    echo "BANNER:$(grep -c 'SITE SINK OFF' "$M")"
    echo "HBLEG:$(grep -cE '^name = "heartbeat"$' "$M")"
    echo "DISC:$(cat "$M" "$PD"/*.toml 2>/dev/null | grep -cE '^[[:space:]]*discard[[:space:]]*=')"
else
    echo "MANIFEST:0"
fi
if [ -r "$S" ]; then
    echo "SIGTOML:1"
    echo "HBSIG:$(grep -cE '^name = "heartbeat"$' "$S")"
    echo "UNGOVERNED:$(grep -cE '^governed = false$' "$S")"
else
    echo "SIGTOML:0"
fi
echo "==SP2 MANIFEST-STEP=="
o=$(cd / && "$SMD" admin uploader manifest 2>&1); rc=$?
printf '%s\n' "$o"
echo "==SP2 END=="
echo "STEPRC:$rc"
echo "==SP2 STATUS-JSON=="
o=$(cd / && "$HSU" sink status --json 2>/dev/null); rc=$?
printf '%s\n' "$o"
echo "==SP2 END=="
echo "STATUSRC:$rc"
echo "END:1"
SP2EOF
}

# sp2_facts <file>: the probe's lines (sp2_unwrap's output) -> KEY:value.
# The features line is the one smd prints, "uploader: hs-uploader features:
# <words>", found anywhere on its line (a warning sign the channel
# double-encodes may stand ahead of it); a line without the "uploader: "
# prefix is not it.  The status JSON gives the site's state, whether
# hs-uploader enforces the switches, and each client's own file.
sp2_facts() {
    python3 - "$1" <<'PY'
import json, re, sys
FEATURES = 'uploader: hs-uploader features: '
lines = open(sys.argv[1], encoding='utf-8', errors='replace').read().splitlines()
sect, body, toks = None, {}, []
for ln in lines:
    s = ln.strip()
    if s.startswith('==SP2 ') and s.endswith('=='):
        name = s[6:-2]
        sect = None if name == 'END' else name
        if sect:
            body[sect] = []
        continue
    if sect:
        body[sect].append(ln)
    elif re.fullmatch(r'[A-Z][A-Z0-9_]*:-?[0-9]+', s):
        toks.append(s)
out = list(toks)
step = body.get('MANIFEST-STEP', [])
words = None
for ln in step:
    i = ln.find(FEATURES)
    if i >= 0:
        words = ln[i + len(FEATURES):].split()
        break
out.append('F_LINE:%d' % (words is not None))
words = words or []
out.append('F_WORDS:%s' % (','.join(words) or '-'))
out.append('F_GATE:%d' % ('gate' in words))
out.append('F_NONE:%d' % ('none' in words))
out.append('SMDERR:%d' % sum('smd: uploader: ' in ln for ln in step))
text = '\n'.join(body.get('STATUS-JSON', []))
try:
    d = json.loads(text)
    if not isinstance(d, dict):
        raise ValueError('not an object')
    clients = [c for c in d.get('clients') or [] if isinstance(c, dict)]
    notup = sorted(str(c.get('client')) for c in clients
                   if c.get('file_state') != 'upload')
    out += ['ST_JSON:1',
            'ST_SCHEMA:%s' % d.get('schema'),
            'ST_ENFORCED:%d' % (d.get('enforced') is True),
            'ST_SITE:%s' % ((d.get('site') or {}).get('state') or '-'),
            'ST_NCLIENTS:%d' % len(clients),
            'ST_NOTUPLOAD:%s' % (','.join(notup) or '-'),
            'ST_ERRORS:%d' % len(d.get('errors') or []),
            'ST_REFUSED:%d' % len(d.get('refused_files') or [])]
except ValueError:
    out.append('ST_JSON:0')
print('\n'.join(out))
PY
}

# sp2_verdict <facts-file>: the fresh station after bring-up (§13.1).  It
# ends with VERDICT:done, which sp2_report requires.
sp2_verdict() {
    _sp2_verdict_body "$1"
    echo "VERDICT:done"
}
_sp2_verdict_body() {
    local f="$1" v
    _sp2t(){ sp2_tok "$f" "$1"; }
    [ "$(_sp2t END)" = 1 ] || { echo "FAIL: the switch probe gave no answer (guest exec failed; not a verdict)"; return; }
    [ "$(_sp2t STEPRC)" = 0 ] \
        || echo "FAIL: smd admin uploader manifest exited $(_sp2t STEPRC)"
    v="$(_sp2t SMDERR)"
    [ "$v" = 0 ] || echo "FAIL: smd admin uploader manifest printed ${v:-?} 'smd: uploader:' error line(s)"
    [ "$(_sp2t F_LINE)" = 1 ] \
        || echo "FAIL: smd admin uploader manifest printed no 'uploader: hs-uploader features:' line"
    [ "$(_sp2t F_LINE)" = 1 ] && [ "$(_sp2t F_GATE)" != 1 ] \
        && echo "FAIL: hs-uploader offers no gate (features: $(_sp2t F_WORDS)); the switch files govern nothing"
    [ "$(_sp2t MARKER)" = 1 ] \
        || echo "FAIL: no carry-over marker at /var/lib/hs-uploader/carry-over-v1.done after bring-up"
    if [ "$(_sp2t ST_JSON)" != 1 ]; then
        echo "FAIL: hs-uploader sink status --json gave no JSON (exit $(_sp2t STATUSRC))"
    else
        [ "$(_sp2t ST_ENFORCED)" = 1 ] \
            || echo "FAIL: hs-uploader sink status says it enforces nothing (it finds no marker)"
        v="$(_sp2t ST_SITE)"
        [ "$v" = off ] || echo "FAIL: the site switch reads '$v' on a fresh install, not off"
        if [ "$(_sp2t ST_NCLIENTS)" = 0 ]; then
            echo "UNCHECKED: every client at upload (hs-uploader names no client in this nest)"
        else
            v="$(_sp2t ST_NOTUPLOAD)"
            [ "$v" = - ] || echo "FAIL: client switch file(s) not at upload on a fresh install: $v"
        fi
    fi
    [ "$(_sp2t MANIFEST)" = 1 ] || { echo "FAIL: no /etc/hs-uploader/pipelines.toml after bring-up"; return; }
    v="$(_sp2t DISC)"
    [ "$v" = 0 ] || echo "FAIL: ${v:-?} discard line(s) in the manifest; the gate form renders none"
    v="$(_sp2t BANNER)"
    [ "$v" = 0 ] || echo "FAIL: pipelines.toml still carries the SITE SINK OFF banner (part 1's form)"
    v="$(_sp2t HBLEG)"
    [ "$v" = 0 ] || echo "FAIL: the heartbeat still sits in the legacy manifest"
    if [ "$(_sp2t SIGTOML)" != 1 ]; then
        echo "FAIL: no pipelines.d/sigmond.toml; the heartbeat has no home"
    else
        [ "$(_sp2t HBSIG)" = 1 ] || echo "FAIL: pipelines.d/sigmond.toml carries no heartbeat pipeline"
        [ "$(_sp2t UNGOVERNED)" = 1 ] || echo "FAIL: the heartbeat in sigmond.toml is not governed = false"
    fi
}

# sp2_report <verdict> <context>: a verdict without its VERDICT:done line
# crashed or was cut short, and is FATAL as no verdict.  Otherwise each
# UNCHECKED line is said and kept for the closing line (sink_unchecked), and
# any FAIL line is FATAL, showing the probe's last lines.  `say` and
# `sink_unchecked` are the rig's.
sp2_report(){
    local l n=0
    if ! grep -qx 'VERDICT:done' "$1" 2>/dev/null; then
        say "FATAL: the verdict did not finish (it crashed or was cut short; not a verdict)"
        sed 's/^/      /' "$1" 2>/dev/null | tail -10
        exit 1
    fi
    while IFS= read -r l; do
        case "$l" in
            UNCHECKED:*) say "⚠ NOT EVALUATED: ${l#UNCHECKED: }"; sink_unchecked "${l#UNCHECKED: }" ;;
            FAIL:*)      say "FATAL: ${l#FAIL: }"; n=$((n + 1)) ;;
        esac
    done < "$1"
    [ "$n" = 0 ] || { sed 's/^/      /' "$2" | tail -20; exit 1; }
}

# sp2_pre_script: the carry-over's own rule for which clients it governs
# (sigmond sink_carryover._read_station), read here in the guest, never by
# calling sigmond: an enabled client whose deploy.toml, at a fixed path,
# declares at least one [[hs_uploader.pipeline]].  The fixed paths are
# _deploy_fixed's: topology.toml's [sigmond] client_dir, then
# /opt/git/sigmond, each /<client>/deploy.toml.  One line per client:
#   PRE|<client>|<switch file 0/1>|<enabled 0/1>|<governed 1/0/nofixed>
#   ROWS|<client>|<sink.db rows stored under its producer name>
# "nofixed": no deploy.toml at a fixed path (the carry-over may still find
# one by asking the client).  Rows a disabled client left in sink.db can
# make the carry-over govern it too.  Reads only.  SP2_ROOT exists for the
# hermetic test.
sp2_pre_script() {
    cat <<'SP2EOF'
python3 -B - "${SP2_ROOT:-}" <<'PY'
import os, sqlite3, sys, tomllib, urllib.parse
R = sys.argv[1]
def load(path):
    try:
        with open(path, 'rb') as fh:
            d = tomllib.load(fh)
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return None
topo = load(R + '/etc/sigmond/topology.toml') or {}
comp = topo.get('component') if isinstance(topo.get('component'), dict) else {}
sig = topo.get('sigmond') if isinstance(topo.get('sigmond'), dict) else {}
bases = [b for b in (sig.get('client_dir'), '/opt/git/sigmond') if isinstance(b, str) and b]
rows = {}
db = R + '/var/lib/sigmond/sink.db'
if os.path.lexists(db):
    try:
        con = sqlite3.connect('file:' + urllib.parse.quote(db) + '?mode=ro', uri=True)
        try:
            cols = {r[1] for r in con.execute('PRAGMA table_info(pending_uploads)')}
            if 'producer' in cols:
                rows = dict(con.execute("SELECT producer, count(*) FROM pending_uploads "
                                        "WHERE producer != '' GROUP BY producer"))
        finally:
            con.close()
    except sqlite3.Error as exc:
        print('PRENOTE|cannot read sink.db (%s); its rows were not counted' % type(exc).__name__)
for c in ('psk-recorder', 'meteor-scatter', 'wspr-recorder', 'mag-recorder'):
    f = 1 if os.path.lexists(R + '/etc/hs-uploader/sinks/%s.toml' % c) else 0
    e = 1 if isinstance(comp.get(c), dict) and comp[c].get('enabled') is True else 0
    g = 'nofixed'
    for b in bases:
        path = R + b.rstrip('/') + '/' + c + '/deploy.toml'
        if os.path.isfile(path):
            d = load(path) or {}
            hu = d.get('hs_uploader') if isinstance(d.get('hs_uploader'), dict) else {}
            decls = hu.get('pipeline')
            g = '1' if isinstance(decls, list) and decls else '0'
            break
    print('PRE|%s|%d|%d|%s' % (c, f, e, g))
    print('ROWS|%s|%d' % (c, rows.get(c, 0)))
PY
SP2EOF
}

# sp2_plant_script: the guest script that plants what `smd sink fill` must
# lower (§13.1): a psk-recorder instance sending direct, a meteor-scatter
# instance with no delivery mode and a callsign and grid, wspr-uploader
# enabled, and mag-recorder's fallback uploader enabled.
#
# First, before it changes anything, it prints sp2_pre_script's facts: the
# carry-over must have written a file for every client it governs, and the
# plant must never hide one it did not write.  The plant writes a switch file (at upload, through hs-uploader's
# own `sink set`) only for a client that topology leaves disabled, and says
# so (NOTE|...).  A client this image does not install, or that topology
# disables, gets no instance: the lever step cannot reach it.
#
# Each planted instance runs a stand-in process: a runtime drop-in under
# /run/systemd/system/<unit>.d/ makes it `sleep infinity`, so it holds still
# without a radio and its restart can be counted.  Its environment files stay
# the unit's own, which is all the lever step reads.
#
# Every file it edits is backed up first, every file it creates is noted, and
# each drop-in is recorded, in /run/sp2-rig/undo (sp2_unplant_script).
# Edits keep each file's owner and mode.  Planted instances go to
# /run/sp2-rig/planted.
sp2_plant_script() {
    sp2_pre_script
    cat <<'SP2EOF'
set -u
export PYTHONDONTWRITEBYTECODE=1
HSU=/opt/hs-uploader/venv/bin/hs-uploader
SINKS=/etc/hs-uploader/sinks
D=/run/sp2-rig
rm -rf "$D"; mkdir -p "$D/backup"; : > "$D/planted"; : > "$D/undo"
topo_on(){ python3 -B - "$1" <<'PY'
import sys, tomllib
try:
    with open('/etc/sigmond/topology.toml', 'rb') as fh:
        c = tomllib.load(fh).get('component', {}).get(sys.argv[1], {})
    print(1 if c.get('enabled') is True else 0)
except Exception:
    print(0)
PY
}
# keep FILE: back FILE up once before its first edit, or note it as new.
keep(){
    local f="$1" b
    grep -qF "|$f|" "$D/undo" && return 0
    if [ -e "$f" ]; then
        b="$D/backup/$(printf '%s' "$f" | md5sum | cut -c1-16)"
        cp -p "$f" "$b" && printf 'RESTORE|%s|%s|\n' "$f" "$b" >> "$D/undo"
    else
        printf 'REMOVE|%s|\n' "$f" >> "$D/undo"
    fi
}
# inst_for CLIENT: the instance to plant, in storage form (AC0G=B4).  An env
# file named the way systemd escapes it (AC0G\x3dB4.env) is unescaped, never
# escaped twice.  With none, the rig invents N0CALL=T1.  SP2_ROOT exists for
# the hermetic test of this function alone.
inst_for(){
    local f s
    for f in "${SP2_ROOT:-}/etc/$1/env/"*.env; do
        [ -e "$f" ] || continue
        s=$(basename "$f" .env)
        case "$s" in *'\x'*) continue ;; esac
        echo "$s"; return
    done
    for f in "${SP2_ROOT:-}/etc/$1/env/"*.env; do
        [ -e "$f" ] || continue
        systemd-escape --unescape -- "$(basename "$f" .env)"; return
    done
    echo 'N0CALL=T1'
}
# set_env FILE KEY VALUE: drop every KEY= line, then append KEY=VALUE unless
# VALUE is empty.  Rewrites in place, so owner and mode stay.
set_env(){ python3 -B - "$1" "$2" "$3" <<'PY'
import os, re, sys
path, key, value = sys.argv[1:4]
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, 'a+') as fh:
    fh.seek(0)
    keep = [l for l in fh.read().splitlines()
            if not re.match(r'\s*(export\s+)?' + re.escape(key) + r'=', l)]
    if value:
        keep.append(key + '=' + value)
    fh.seek(0); fh.truncate(); fh.write('\n'.join(keep) + '\n')
PY
}
# set_toml FILE TABLE KEY VALUE: KEY = VALUE (TOML text) inside [TABLE],
# replacing the key's line or adding it under the header, or the table.
set_toml(){ python3 -B - "$@" <<'PY'
import re, sys
path, table, key, value = sys.argv[1:5]
with open(path, 'r+') as fh:
    lines = fh.read().splitlines()
    head = [i for i, l in enumerate(lines) if l.strip() == '[' + table + ']']
    if not head:
        lines += ['', '[' + table + ']', key + ' = ' + value]
    else:
        i, end = head[0], len(lines)
        for j in range(i + 1, len(lines)):
            if lines[j].lstrip().startswith('['):
                end = j; break
        hit = [j for j in range(i + 1, end)
               if re.match(r'\s*' + re.escape(key) + r'\s*=', lines[j])]
        if hit:
            lines[hit[0]] = key + ' = ' + value
        else:
            lines.insert(i + 1, key + ' = ' + value)
    fh.seek(0); fh.truncate(); fh.write('\n'.join(lines) + '\n')
PY
}
# switch_for CLIENT TAG ENABLED: pre (the carry-over wrote it), missing (an
# enabled client without one: the verdict fails it), made (a disabled
# client, written here), or failed.
switch_for(){
    if [ -e "$SINKS/$1.toml" ]; then echo "$2_SWITCH:pre"; return; fi
    if [ "$3" = 1 ]; then echo "$2_SWITCH:missing"; return; fi
    if (cd / && "$HSU" sink set "$1" upload --reason 'rig: plant (client disabled in topology)' --by 'test-nested-v3') >/dev/null 2>&1; then
        echo "$2_SWITCH:made"
        echo "NOTE|$1 is disabled in topology: the rig wrote its switch file at upload so that smd sink fill names it; the file stays"
    else
        echo "$2_SWITCH:failed"
    fi
}
plant_instance(){ # CLIENT TAG KEY VALUE
    local c="$1" tag="$2" i u f dd inv wa topo cfg
    if ! systemctl cat "$c@.service" >/dev/null 2>&1; then echo "$tag:0"; return; fi
    echo "$tag:1"
    topo=$(topo_on "$c"); echo "${tag}_TOPO:$topo"
    [ "$topo" = 1 ] || return 0
    switch_for "$c" "$tag" "$topo"
    i=$(inst_for "$c"); u="$c@$(systemd-escape -- "$i").service"; f="/etc/$c/env/$i.env"
    if [ -e "$f" ]; then inv=0; else inv=1; fi
    if [ "$(systemctl is-active "$u" 2>/dev/null)" = active ]; then wa=1; else wa=0; fi
    keep "$f"
    set_env "$f" "$3" "$4"
    echo "${tag}_ENVSET:$?"
    if [ "$c" = meteor-scatter ]; then
        cfg=/etc/meteor-scatter/meteor-scatter-config.toml
        [ -e "/etc/meteor-scatter/$i.toml" ] && cfg="/etc/meteor-scatter/$i.toml"
        keep "$cfg"
        [ -e "$cfg" ] || { mkdir -p /etc/meteor-scatter; : > "$cfg"; }
        set_toml "$cfg" station callsign '"N0CALL"' && set_toml "$cfg" station grid_square '"EM00aa"'
        echo "${tag}_CFGSET:$?"
    fi
    dd="/run/systemd/system/$u.d"
    mkdir -p "$dd"
    printf '[Service]\nType=simple\nExecStartPre=\nExecStart=\nExecStart=/bin/sleep infinity\nExecStartPost=\nExecStop=\nExecReload=\nWatchdogSec=0\n' > "$dd/sp2-standin.conf"
    printf 'DROPIN|%s|%s|%s|%s|\n' "$u" "$dd" "$wa" "$inv" >> "$D/undo"
    systemctl daemon-reload >/dev/null 2>&1
    systemctl restart "$u" >/dev/null 2>&1; echo "${tag}_START:$?"
    echo "${tag}_INVENTED:$inv"
    printf 'PLANTED|%s|%s|%s\n' "$c" "$u" "$f" | tee -a "$D/planted"
}
plant_instance psk-recorder PSK PSK_DELIVERY_PIPELINES direct
plant_instance meteor-scatter MS METEOR_SCATTER_DELIVERY_MODE ''
if systemctl cat wspr-uploader.service >/dev/null 2>&1; then
    echo "WU:1"
    prev=$(systemctl show -p UnitFileState --value wspr-uploader.service 2>/dev/null)
    if [ "$(systemctl is-active wspr-uploader.service 2>/dev/null)" = active ]; then ran=1; else ran=0; fi
    printf 'UNITFILE|wspr-uploader.service|%s|%s|\n' "$prev" "$ran" >> "$D/undo"
    systemctl enable wspr-uploader.service >/dev/null 2>&1; echo "WU_ENABLE:$?"
    switch_for wspr-recorder WU "$(topo_on wspr-recorder)"
else
    echo "WU:0"
fi
MAGC=/etc/mag-recorder/mag-recorder-config.toml
if [ -f "$MAGC" ]; then
    echo "MAG:1"
    keep "$MAGC"
    set_toml "$MAGC" uploader enabled true; echo "MAG_SET:$?"
    switch_for mag-recorder MAG "$(topo_on mag-recorder)"
else
    echo "MAG:0"
fi
echo "END:1"
SP2EOF
}

# sp2_unplant_script: undo the plant from /run/sp2-rig/undo, after the
# verdict's reads.  Edited files come back from their backups and created
# ones go; each stand-in drop-in file goes (its directory too, once empty);
# then an invented instance stops, and an instance that ran before the plant
# restarts on its own process (one that did not run stops).  wspr-uploader
# is enabled again if it stood enabled, and started again if it ran.  The
# lever values the fill wrote go with the restored files.  Switch files the
# plant made stay (removing one would read off).  Every step's exit code is
# read; a step that fails prints RESIDUE|<step>|<rc>, which the rig says as
# plant residue.  SP2_RUN and SP2_SYSTEMCTL exist for the hermetic test.
sp2_unplant_script() {
    cat <<'SP2EOF'
set -u
D="${SP2_RUN:-/run/sp2-rig}"
SC="${SP2_SYSTEMCTL:-systemctl}"
[ -r "$D/undo" ] || { echo "UNDO:0"; echo "END:1"; exit 0; }
echo "UNDO:1"
step(){ # <what> <command...>: run it, and say RESIDUE when it fails
    local what="$1" rc; shift
    "$@" >/dev/null 2>&1; rc=$?
    [ "$rc" = 0 ] || echo "RESIDUE|$what|$rc"
    return "$rc"
}
reload=0
while IFS='|' read -r kind a b c d _; do
    case "$kind" in
        RESTORE) step "restore $a" cp -p -- "$b" "$a" && echo "RESTORED|$a" ;;
        REMOVE)  step "remove $a" rm -f -- "$a" && echo "REMOVED|$a" ;;
        DROPIN)
            reload=1
            if step "remove $b/sp2-standin.conf" rm -f -- "$b/sp2-standin.conf"; then
                echo "DROPIN-REMOVED|$a"
                # the directory goes only when nothing else lives in it
                [ -d "$b" ] && [ -z "$(ls -A "$b" 2>/dev/null)" ] && step "rmdir $b" rmdir -- "$b"
            fi ;;
    esac
done < "$D/undo"
[ "$reload" = 1 ] && step "systemctl daemon-reload" "$SC" daemon-reload
while IFS='|' read -r kind a b c d _; do
    case "$kind" in
        DROPIN)
            if [ "$d" = 1 ] || [ "$c" != 1 ]; then
                step "systemctl stop $a" "$SC" stop "$a" && echo "STOPPED|$a"
                "$SC" reset-failed "$a" >/dev/null 2>&1   # nothing to reset is no failure
            else
                step "systemctl restart $a" "$SC" restart "$a" && echo "RESTARTED|$a"
            fi ;;
        UNITFILE)
            if [ "$b" = enabled ]; then
                step "systemctl enable $a" "$SC" enable "$a" && echo "REENABLED|$a"
            fi
            if [ "$c" = 1 ]; then
                step "systemctl start $a" "$SC" start "$a" && echo "STARTED|$a"
            fi ;;
    esac
done < "$D/undo"
echo "END:1"
SP2EOF
}

# sp2_state_script <before|after>: start times (ActiveEnterTimestampMonotonic)
# of every recorder instance systemd knows, every planted one, and
# hs-uploader; every radiod unit's, with an independent count of the radiod
# units running (RADIODN); and what each lever file says.  "before" reads the
# units twice, SP2_SLEEP (10) s apart, keeps the unit list for "after", and
# stamps the moment the fill may begin (T0, wall and monotonic); "after"
# counts each unit's "Started" journal lines since T0.  SP2_RUN, SP2_ROOT,
# SP2_SYSTEMCTL, SP2_JOURNALCTL and SP2_SLEEP exist for the hermetic test.
sp2_state_script() {
    printf 'PHASE=%s\n' "$1"
    cat <<'SP2EOF'
set -u
D="${SP2_RUN:-/run/sp2-rig}"
R="${SP2_ROOT:-}"
SC="${SP2_SYSTEMCTL:-systemctl}"
JC="${SP2_JOURNALCTL:-journalctl}"
mkdir -p "$D"
listunits(){
    {
        cut -d'|' -f3 "$D/planted" 2>/dev/null
        "$SC" list-units --type=service --all --plain --no-legend \
            'psk-recorder@*' 'wspr-recorder@*' 'meteor-scatter@*' 'mag-recorder*' 2>/dev/null | awk '{ print $1 }'
        echo hs-uploader.service
    } | awk 'NF && !seen[$0]++'
}
rec(){ # TAG
    local u
    while IFS= read -r u; do
        [ -n "$u" ] || continue
        "$SC" show -p ActiveState -p ActiveEnterTimestampMonotonic "$u" 2>/dev/null \
            | awk -F= -v t="$1" -v u="$u" '
                $1 == "ActiveState" { st = $2 } $1 == "ActiveEnterTimestampMonotonic" { mo = $2 }
                END { printf "UNIT|%s|%s|%s|%s\n", t, u, st, mo }'
    done < "$D/units"
    "$SC" show -p Id -p ActiveState -p ActiveEnterTimestampMonotonic 'radiod@*' radiod.service 2>/dev/null \
        | awk -F= -v t="$1" '
            $1 == "Id" { id = $2 } $1 == "ActiveState" { st = $2 }
            $1 == "ActiveEnterTimestampMonotonic" { mo = $2 }
            /^$/ { if (id != "") printf "RADIOD|%s|%s|%s|%s\n", t, id, st, mo; id = st = mo = "" }
            END { if (id != "") printf "RADIOD|%s|%s|%s|%s\n", t, id, st, mo }'
    printf 'RADIODN|%s|%s\n' "$1" "$("$SC" list-units --type=service --state=active --plain --no-legend 'radiod@*' radiod.service 2>/dev/null | grep -c .)"
}
envval(){ # FILE KEY
    [ -r "$1" ] || { echo NOFILE; return; }
    v=$(grep -E "^[[:space:]]*(export[[:space:]]+)?$2=" "$1" | tail -1 | sed "s/^[^=]*=//; s/^[\"']//; s/[\"']\$//")
    echo "${v:-UNSET}"
}
facts(){
    while IFS='|' read -r _ c u f; do
        case "$c" in
            psk-recorder)   echo "LEVER|psk-recorder|$(envval "$f" PSK_DELIVERY_PIPELINES)" ;;
            meteor-scatter) echo "LEVER|meteor-scatter|$(envval "$f" METEOR_SCATTER_DELIVERY_MODE)" ;;
        esac
    done < "$D/planted"
    "$SC" show -p UnitFileState -p ActiveState wspr-uploader.service 2>/dev/null \
        | awk -F= '$1 == "UnitFileState" { f = $2 } $1 == "ActiveState" { a = $2 }
                   END { printf "WUSTATE|%s|%s\n", f, a }'
    python3 -B - "$R/etc/mag-recorder/mag-recorder-config.toml" <<'PY'
import sys, tomllib
try:
    with open(sys.argv[1], 'rb') as fh:
        up = tomllib.load(fh).get('uploader', {})
    v = up.get('enabled', 'absent') if isinstance(up, dict) else 'absent'
    print('MAGEN|' + ('bool:' + str(v).lower() if isinstance(v, bool) else repr(v)))
except FileNotFoundError:
    print('MAGEN|nofile')
except Exception as exc:
    print('MAGEN|unreadable:' + type(exc).__name__)
PY
}
mono(){ python3 -c 'import time; print(time.monotonic_ns() // 1000)'; }
touch "$D/planted"
if [ "$PHASE" = before ]; then
    listunits > "$D/units"
    rec 1
    sleep "${SP2_SLEEP:-10}"
    rec 2
    facts
    t0=$(date +%s); m0=$(mono)
    printf '%s %s\n' "$t0" "$m0" > "$D/t0"
    echo "T0:$t0"; echo "T0MONO:$m0"
else
    [ -s "$D/units" ] || listunits > "$D/units"
    rec A
    facts
    t0=""; read -r t0 m0 < "$D/t0" 2>/dev/null
    if [ -n "$t0" ]; then
        while IFS= read -r u; do
            n=$("$JC" -u "$u" --since "@$t0" -o cat --no-pager 2>/dev/null | grep -c '^Started ')
            printf 'STARTS|%s|%s\n' "$u" "$n"
        done < "$D/units"
        echo "T0:$t0"
    fi
fi
echo "END:1"
SP2EOF
}

# sp2_fill_facts <file>: `smd sink fill`'s output -> KEY:value, plus one
# CHANGED|<path> line per lever file it wrote and one RESTART|<unit>|<times>
# line per unit it says it restarted (the lever step's and the stale-writer
# step's lines together).
sp2_fill_facts() {
    python3 - "$1" <<'PY'
import re, sys
lines = open(sys.argv[1], encoding='utf-8', errors='replace').read().splitlines()
chg = {'psk-recorder': 0, 'meteor-scatter': 0, 'wspr-recorder': 0, 'mag': 0}
restarts, toks, changed = {}, [], []
n = dict(wu=0, failed=0, armed=0, site=0, hsu=0)
for ln in lines:
    s = ln.strip()
    if re.fullmatch(r'[A-Z][A-Z0-9_]*:-?[0-9]+', s):
        toks.append(s)
    m = re.search(r'lever: changed (\S+)', ln)
    if m:
        p = m.group(1)
        changed.append(p)
        if p.endswith('/mag-recorder/mag-recorder-config.toml'):
            chg['mag'] += 1
        for c in ('psk-recorder', 'meteor-scatter', 'wspr-recorder'):
            if '/%s/env/' % c in p:
                chg[c] += 1
    m = re.search(r'(?:lever|stale writer): restarted (\S+)', ln)
    if m:
        restarts[m.group(1)] = restarts.get(m.group(1), 0) + 1
    n['wu'] += 'lever: stopped and disabled wspr-uploader.service' in ln
    n['failed'] += bool(re.search(r'lever( step)?: FAILED|stale-writer restarts: FAILED', ln))
    n['armed'] += 'lever: still armed' in ln
    n['site'] += 'site sink switch set to fill' in ln
    # The daemon restarts when the step lands a changed manifest, or
    # when it started before the manifest on disk (commands/uploader.py).
    n['hsu'] += bool(re.search(r'restarting hs-uploader|uploader: wrote \S*pipelines', ln))
out = toks + ['CHG_PSK:%d' % chg['psk-recorder'], 'CHG_MS:%d' % chg['meteor-scatter'],
              'CHG_WSPR:%d' % chg['wspr-recorder'], 'CHG_MAG:%d' % chg['mag'],
              'WU_DISABLED:%d' % n['wu'], 'LV_FAILED:%d' % n['failed'],
              'LV_ARMED:%d' % n['armed'],
              'SITE_FILL:%d' % n['site'], 'HSU_RESTART:%d' % n['hsu'],
              'RESTARTED:%d' % len(restarts)]
out += ['CHANGED|%s' % p for p in changed]
out += ['RESTART|%s|%d' % (u, k) for u, k in sorted(restarts.items())]
print('\n'.join(out))
PY
}

# sp2_lever_verdict <plant> <before> <fill-facts> <after>: the carry-over
# wrote a switch file for every enabled client; each lever written; each
# unit smd names restarted once and every other one unmoved; radiod's start
# time unchanged.  <plant>, <before> and <after> are sp2_unwrap's output of
# the three guest scripts.  It ends with VERDICT:done; a crash leaves the
# line out, and the exit code, read into a variable, says so too.
sp2_lever_verdict() {
    local rc
    python3 - "$@" <<'PY'
import sys
def read(p):
    return open(p, encoding='utf-8', errors='replace').read().splitlines()
plant, before, fill, after = (read(p) for p in sys.argv[1:5])
def tok(lines, k):
    for l in lines:
        if l.startswith(k + ':'):
            return l[len(k) + 1:].strip()
    return None
def recs(lines, kind):
    return [l.split('|')[1:] for l in lines if l.startswith(kind + '|')]
def num(s):
    try:
        return int(s)
    except (TypeError, ValueError):
        return None
def done():
    print('VERDICT:done')
    sys.exit(0)
for name, lines in (('plant', plant), ('before', before), ('smd sink fill', fill), ('after', after)):
    if tok(lines, 'END') != '1':
        print('FAIL: the %s probe gave no answer (guest exec failed; not a verdict)' % name)
        done()
# The carry-over, read before the plant touched anything, by its own rule:
# an enabled client whose deploy.toml at a fixed path declares pipelines.
rows = {r[0]: num(r[1]) for r in recs(plant, 'ROWS')}
for c, exists, enabled, governed in (r[:4] for r in recs(plant, 'PRE')):
    if exists == '1':
        continue
    if enabled == '1' and governed == '1':
        print('FAIL: the carry-over wrote no switch file for an enabled client: %s' % c)
    elif enabled == '1' and governed == 'nofixed':
        print('UNCHECKED: whether the carry-over owed %s a switch file (enabled, but no deploy.toml at a fixed path)' % c)
    elif enabled != '1' and (rows.get(c) or 0) > 0:
        print('UNCHECKED: whether the carry-over owed %s a switch file (disabled, but %d sink.db row(s) carry its name)' % (c, rows[c]))
if tok(fill, 'FILLRC') != '0':
    print('FAIL: smd sink fill --reason rig exited %s' % tok(fill, 'FILLRC'))
if tok(fill, 'SITE_FILL') != '1':
    print('FAIL: smd sink fill did not say it set the site switch to fill')
if tok(fill, 'LV_FAILED') != '0':
    print('FAIL: the lever step reported %s FAILED line(s)' % tok(fill, 'LV_FAILED'))
if tok(fill, 'LV_ARMED') != '0':
    print('FAIL: the lever step reported %s sender(s) still armed' % tok(fill, 'LV_ARMED'))
restarted = {u: int(k) for u, k in recs(fill, 'RESTART')}
for u, k in sorted(restarted.items()):
    if k != 1:
        print('FAIL: smd sink fill says it restarted %s %d times; each touched unit restarts once' % (u, k))
changed = {r[0] for r in recs(fill, 'CHANGED')}
b1 = {r[1]: (r[2], r[3]) for r in recs(before, 'UNIT') if r[0] == '1'}
b2 = {r[1]: (r[2], r[3]) for r in recs(before, 'UNIT') if r[0] == '2'}
a = {r[1]: (r[2], r[3]) for r in recs(after, 'UNIT') if r[0] == 'A'}
starts = {r[0]: r[1] for r in recs(after, 'STARTS')}
t0 = num(tok(before, 'T0MONO'))
if t0 is None:
    print('FAIL: the before probe stamped no T0 (not a verdict)')
    done()
# Each planted instance: its lever written; smd names its restart once.
lev_after = {r[0]: r[1] for r in recs(after, 'LEVER')}
want = {'psk-recorder': ('PSK', 'CHG_PSK', 'server-raw'),
        'meteor-scatter': ('MS', 'CHG_MS', 'off')}
planted = {r[0]: (r[1], r[2]) for r in recs(plant, 'PLANTED')}
def switch_ok(tag, c):
    s = tok(plant, tag + '_SWITCH')
    if s == 'failed':
        print('FAIL: the rig could not write a switch file for %s (not a verdict on smd)' % c)
    elif s == 'missing':
        print('UNCHECKED: the %s lever (%s has no switch file, so smd sink fill does not reach it)' % (c, c))
    return s in ('pre', 'made')
for c, (tag, chg, val) in want.items():
    if tok(plant, tag) != '1':
        print('UNCHECKED: the %s lever (this image installs no %s@.service)' % (c, c))
        continue
    if tok(plant, tag + '_TOPO') != '1':
        print('UNCHECKED: the %s lever (topology leaves %s disabled, so the lever step cannot reach it)' % (c, c))
        continue
    if not switch_ok(tag, c):
        continue
    if c not in planted or tok(plant, tag + '_ENVSET') != '0':
        print('FAIL: the rig could not plant a %s instance (not a verdict on smd)' % c)
        continue
    u, f = planted[c]
    if (num(tok(fill, chg)) or 0) < 1 or f not in changed:
        print('FAIL: smd sink fill did not write the %s lever at %s' % (c, f))
    if lev_after.get(c) != val:
        print('FAIL: %s\'s env file reads %r after the fill; the lever is %s' % (c, lev_after.get(c), val))
    if restarted.get(u) != 1:
        print('FAIL: smd sink fill did not say it restarted %s once' % u)
# Every unit watched: restarted once when smd names it (hs-uploader too when
# the step says it restarted the daemon), otherwise not at all.
hsu_named = tok(fill, 'HSU_RESTART') not in (None, '0')
for u, st in sorted(b2.items()):
    named = u in restarted or (u == 'hs-uploader.service' and hsu_named)
    aa = a.get(u)
    if not named:
        if aa != st:
            if b1.get(u) != st:
                # it moved between the two pre-fill reads too: a unit that
                # restarts on its own says nothing about the fill
                print('UNCHECKED: %s did not hold still before the fill (%s, then %s), and moved during it (-> %s)' % (u, b1.get(u), st, aa))
            else:
                print('FAIL: %s moved during the fill (%s -> %s), and smd sink fill names no restart of it' % (u, st, aa))
        continue
    one = b1.get(u)
    if not one or one != st or one[0] != 'active':
        print('UNCHECKED: the restart count of %s (it did not run steadily before the fill: %s, then %s)' % (u, one, st))
        continue
    if not aa or aa[0] != 'active' or num(aa[1]) is None or num(aa[1]) <= t0:
        print('FAIL: %s did not start again after the fill began (after: %s; fill began at %s us)' % (u, aa, t0))
    elif starts.get(u) != '1':
        print('FAIL: %s started %s times since the fill began; it must restart once' % (u, starts.get(u)))
for u in sorted(set(restarted) - set(b2)):
    print('UNCHECKED: the restart of %s (smd names it; the rig did not watch it)' % u)
# wspr-uploader: stopped and disabled.
wu = recs(after, 'WUSTATE')
if tok(plant, 'WU') != '1':
    print('UNCHECKED: the wspr-uploader lever (this image installs no wspr-uploader.service)')
elif tok(plant, 'WU_ENABLE') != '0':
    print('FAIL: the rig could not enable wspr-uploader (not a verdict on smd)')
elif switch_ok('WU', 'wspr-recorder'):
    if tok(fill, 'WU_DISABLED') != '1':
        print('FAIL: smd sink fill did not stop and disable wspr-uploader.service')
    if not wu or wu[0][0] != 'disabled' or wu[0][1] not in ('inactive', 'failed'):
        print('FAIL: wspr-uploader.service reads %s after the fill; the lever is disable --now' % (wu[0] if wu else 'nothing'))
# mag-recorder: [uploader] enabled = false, a boolean.
mag = recs(after, 'MAGEN')
if tok(plant, 'MAG') != '1':
    print('UNCHECKED: the mag-recorder lever (this image writes no mag-recorder-config.toml)')
elif tok(plant, 'MAG_SET') != '0':
    print('FAIL: the rig could not arm the mag fallback (not a verdict on smd)')
elif switch_ok('MAG', 'mag-recorder'):
    if tok(fill, 'CHG_MAG') != '1':
        print('FAIL: smd sink fill did not write the mag-recorder lever')
    if not mag or mag[0][0] != 'bool:false':
        print('FAIL: mag-recorder\'s [uploader] enabled reads %s after the fill, not the boolean false' % (mag[0][0] if mag else 'nothing'))
# radiod: never restarted.  RADIODN counts the running radiod units apart
# from the RADIOD records, so a reader that loses them fails, never passes.
rb = {r[1]: (r[2], r[3]) for r in recs(before, 'RADIOD') if r[0] == '2'}
ra = {r[1]: (r[2], r[3]) for r in recs(after, 'RADIOD') if r[0] == 'A'}
nb = {r[0]: num(r[1]) for r in recs(before, 'RADIODN')}.get('2')
na = {r[0]: num(r[1]) for r in recs(after, 'RADIODN')}.get('A')
moved = sorted(u for u in set(rb) | set(ra) if rb.get(u) != ra.get(u))
for u in moved:
    print('FAIL: radiod moved during the fill: %s %s -> %s' % (u, rb.get(u), ra.get(u)))
runs_b = sum(st == 'active' for st, _ in rb.values())
runs_a = sum(st == 'active' for st, _ in ra.values())
if nb is None or na is None:
    print('FAIL: the probes did not count the running radiod units (not a verdict)')
elif runs_b != nb or runs_a != na:
    print('FAIL: %d/%d radiod unit(s) run (before/after), but the start times of %d/%d were read' % (nb, na, runs_b, runs_a))
elif not moved and nb == 0 and na == 0:
    print("UNCHECKED: radiod's start time across the fill (no radiod unit runs in this nest)")
done()
PY
    rc=$?
    [ "$rc" = 0 ] || echo "FAIL: the lever verdict exited $rc (not a verdict)"
}
# <<< sink_part2
# sp2_gx <timeout> <script> <raw>: run a guest script through qm guest exec,
# base64-encoded so the request holds only ASCII; qm's reply lands in <raw>.
sp2_gx(){
    $SSHN "qm guest exec $VMID --timeout $1 -- bash -lc \"echo $(printf '%s\n' "$2" | base64 -w0) | base64 -d > /tmp/sig-sp2.sh; bash /tmp/sig-sp2.sh\"" > "$3" 2>&1
}

KEY="$HOME/appliance/build/applkey"
# --release builds strip root-ssh-keys from answer-v3.toml on purpose
# (build-usb-v3.sh RELEASE branch) so the test key never lands on a
# shipping image. Those images still take the documented image-default
# root password (firstboot-v3.sh: "console/SSH login: root / hamsci-sigmond").
# Overridable, not a new secret — this password is already public in the
# wizard output and project docs.
SSHPASSWORD="${SIGMOND_TEST_PASSWORD:-hamsci-sigmond}"
SSHOPTS="-p 5561 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 root@127.0.0.1"
SSHKEY="ssh -i $KEY $SSHOPTS"
SSHPW="sshpass -p $SSHPASSWORD ssh $SSHOPTS"
SSHN=""  # resolved once by resolve_ssh(); every call site below reads $SSHN
OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
[ -f "$OVMF_CODE" ] || OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd
USBIMG="${USBIMG:-$(ls -t sigmond-appliance-v3*.img 2>/dev/null | head -1)}"
[ -n "$USBIMG" ] || { say "FATAL: no sigmond-appliance-v3*.img found"; exit 1; }

# USBIMG may arrive as a bare filename (the default, found relative to $PWD)
# or as an absolute path from a caller that resolved it already.  Normalise
# ONCE, here, so nothing downstream has to guess.
#
# ⛔ And CHECK IT EXISTS.  On 2026-09-23 a chain script passed an absolute
# path, the qemu line pasted $PWD in front of it, and qemu was handed
# /root/appliance/v3//root/appliance/v3/...img.  The run died in 11 seconds
# with "FATAL: qemu did not start", which reads as a broken image or a
# broken hypervisor; the actual message -- "Could not open ...: No such file
# or directory" -- was only in the systemd journal of a transient unit. A
# path bug should never cost a post-mortem.
case "$USBIMG" in
    /*) USBIMG_PATH="$USBIMG" ;;
    *)  USBIMG_PATH="$PWD/$USBIMG" ;;
esac
if [ ! -f "$USBIMG_PATH" ]; then
    say "FATAL: USB image not found: $USBIMG_PATH"
    say "  USBIMG was: $USBIMG"
    say "  pass a bare filename in $PWD, or an absolute path — both work."
    exit 1
fi
say "USB image under test: $USBIMG"
VMID=100

vm_running(){ ps -C qemu-system-x86_64 -o args= 2>/dev/null | grep -q "guest=sigv3"; }
vm_kill(){ ps -C qemu-system-x86_64 -o pid=,args= 2>/dev/null | awk '/guest=sigv3/{print $1}' | xargs -r kill; sleep 3; }
qmp(){ python3 - "$1" <<'PYEOF'
import json, socket, sys
cmd = json.loads(sys.argv[1])
s = socket.socket(socket.AF_UNIX); s.connect("/tmp/sigv3-qmp.sock")
f = s.makefile("rw")
f.readline()
f.write(json.dumps({"execute":"qmp_capabilities"})+"\n"); f.flush(); f.readline()
f.write(json.dumps(cmd)+"\n"); f.flush()
print(f.readline().strip())
PYEOF
}

boot_vm(){ # boot_vm <with_usb 0|1> <serial_log>
    local usb="$1" slog="$2"
    vm_kill
    local usbargs=""
    [ "$usb" = 1 ] && usbargs="-drive if=none,id=ustick,format=raw,file=$USBIMG_PATH -device usb-storage,id=usbdev,drive=ustick,bootindex=2"
    # Launched as its OWN transient systemd unit, not backgrounded with
    # qemu's -daemonize. -daemonize only detaches from the shell's
    # session/process group via a double-fork+setsid; the resulting process
    # still inherits the cgroup of whoever launched it. Under
    # `systemd-run --unit=...` (this driver, when run that way;
    # KillMode=control-group is the transient-unit default) that meant the
    # guest was SIGTERM'd the instant this script exited, pass OR fail,
    # destroying post-mortem evidence on every FATAL (2026-08-16
    # investigation). `systemd-run` here creates a sibling top-level unit,
    # independent of whatever unit (if any) is running this script, so the
    # driver's exit never reaches it — verified directly (guest unit stays
    # active/running after a `--wait`ed driver unit exits; a plain
    # backgrounded child in the driver's own cgroup does not). RuntimeMaxSec
    # is a backstop, not the normal path: vm_kill (called at the top of
    # every boot_vm, and explicitly after Phase B/D power-offs) is still how
    # the guest is normally stopped, by pid, same as before — that still
    # works unchanged since systemd notices the tracked pid exit and
    # (--collect) forgets the unit. The bound just guarantees that even an
    # abnormal driver exit that skips vm_kill can't orphan a 12G/8vCPU guest
    # forever: 1h comfortably covers a full single-phase run (the whole
    # 4-phase test is documented as 20-30min) plus real post-mortem time.
    # -smp 8 cores=4 threads=2: nested PVE sees real HT pairs so the
    # importer's pinned layout path is exercised, not the fallback.
    local unit="sigv3-qemu-$$-$(date +%s)"
    say "qemu unit: $unit (post-mortem: journalctl -u $unit)"
    systemd-run --unit="$unit" --collect --property=RuntimeMaxSec=3600 -- \
      qemu-system-x86_64 -name guest=sigv3,debug-threads=on -enable-kvm -machine q35 -m 12288 \
      -smp 8,sockets=1,cores=4,threads=2 -cpu host,topoext=on \
      -drive if=pflash,format=raw,readonly=on,file=$OVMF_CODE \
      -drive if=pflash,format=raw,file=$PWD/ovmf-vars-v3.fd \
      -drive if=none,id=nvme0,format=qcow2,file=$PWD/nvme-v3.qcow2 -device nvme,drive=nvme0,serial=sigv3nvme,bootindex=1 -device qemu-xhci \
      $usbargs \
      -netdev user,id=n0,hostfwd=tcp:127.0.0.1:5561-:22 -device virtio-net,netdev=n0 \
      -qmp unix:/tmp/sigv3-qmp.sock,server,nowait -serial "file:$PWD/$slog" -display none
}

# resolve_ssh <tries> <delay> [label]: wait for the nested host's ssh to
# answer and pin $SSHN to whichever auth method it accepts — key first
# (fast path, works on non-release builds), password fallback (release
# builds, whose test key build-usb-v3.sh strips on purpose). Resolves once:
# if $SSHN is already pinned from an earlier call in this run, it just
# retries that same command — it does not re-probe both methods every time.
# On total failure it tells apart "host never came up" (qemu process gone)
# from "host answered but no credential worked" (both auths rejected) —
# those used to produce the same message, which is what made this bug take
# an investigation to find.
resolve_ssh(){
    local tries="$1" delay="$2" label="${3:-}" i
    if [ -n "$SSHN" ]; then
        for i in $(seq 1 "$tries"); do $SSHN true 2>/dev/null && return 0; sleep "$delay"; done
        say "FATAL: nested PVE ssh never came back${label:+ ($label)}"; return 1
    fi
    for i in $(seq 1 "$tries"); do
        if $SSHKEY true 2>/dev/null; then SSHN="$SSHKEY"; say "auth: ssh test key accepted"; return 0; fi
        if $SSHPW true 2>/dev/null; then SSHN="$SSHPW"; say "auth: test key not accepted, falling back to image-default password (release build)"; return 0; fi
        sleep "$delay"
    done
    if vm_running; then
        say "FATAL: nested host is up but neither ssh key nor password auth worked${label:+ ($label)}"
    else
        say "FATAL: nested PVE ssh never came up${label:+ ($label)}"
    fi
    return 1
}

# wait_firstboot_complete <tries> <delay>: poll the nested host over ssh for
# firstboot-v3.sh's own completion line, "first-boot v3 complete" — the last
# thing it writes to $LOG (firstboot-v3.sh:552), after installing the
# importer/wizard/finalizer hooks and running the importer once itself.
# sshd answering is NOT that signal: firstboot depends on
# After=pveproxy.service and takes ~85s end to end, while ssh can answer in
# under 20s — checking firstboot's products (the log line, the importer
# script) right after ssh connects races a boot sequence firstboot hasn't
# necessarily finished yet (always racy; only stopped losing the race when
# the ssh-auth path got faster — 2026-08-16 investigation). Callers still
# check the actual products afterward; this only gates on firstboot having
# truly finished before those checks run, so "never completed" (this
# function's timeout) and "completed but a product is missing" (a later
# check's own FATAL) stay distinguishable instead of looking identical.
wait_firstboot_complete(){
    local tries="$1" delay="$2" i
    for i in $(seq 1 "$tries"); do
        $SSHN "grep -q 'first-boot v3 complete' /var/log/sigmond-firstboot.log" 2>/dev/null && return 0
        sleep "$delay"
    done
    return 1
}

case "${1:-all}" in
all|A)
say "════ PHASE A: auto-install ($USBIMG) ════"
qemu-img create -f qcow2 nvme-v3.qcow2 40G >/dev/null
cp /usr/share/OVMF/OVMF_VARS_4M.fd ovmf-vars-v3.fd
boot_vm 1 serialA-v3.log
sleep 8; vm_running || { say "FATAL: qemu did not start"; exit 1; }
say "installer booted; waiting for power-off (up to 30 min)"
for i in $(seq 1 120); do vm_running || break; sleep 15; done
vm_running && { say "FATAL: installer did not power off in 30min"; exit 1; }
say "PHASE A PASS: installer completed and powered off"
[ "${1:-all}" = "A" ] && exit 0
;&
B)
say "════ PHASE B: first boot from NVMe, no USB ════"
boot_vm 0 serialB-v3.log
resolve_ssh 60 5 B || exit 1
say "nested PVE up: $($SSHN 'pveversion; hostname' 2>/dev/null)"
$SSHN "hostname | grep -q 'sigmond-appliance-v3'" && say "versioned hostname OK" || say "WARN: hostname not versioned: $($SSHN hostname)"
say "waiting for firstboot to complete (up to 3 min)"
wait_firstboot_complete 36 5 || { say "FATAL: firstboot never completed (no 'first-boot v3 complete' in /var/log/sigmond-firstboot.log within 3 min of ssh coming up)"; exit 1; }
say "firstboot completed"
$SSHN "grep -q 'no Sigmond USB present' /var/log/sigmond-firstboot.log" && say "firstboot ran, no media (expected)" || say "WARN: firstboot log unexpected"
$SSHN "test -x /usr/local/sbin/sigmond-import.sh" && say "importer installed" || { say "FATAL: firstboot completed but importer is missing"; exit 1; }
$SSHN "test -f /etc/udev/rules.d/99-sigmond-import.rules" && say "udev rule armed" || { say "FATAL: udev rule missing"; exit 1; }
$SSHN "cat /etc/sigmond-appliance/version" && say "version file present" || say "WARN: version file missing"
$SSHN "grep -q '^iface vmbr0 inet dhcp' /etc/network/interfaces" \
    && say "vmbr0 converted to DHCP ✓" \
    || { say "FATAL: vmbr0 not on DHCP (static-fossilization bug)"; $SSHN "cat /etc/network/interfaces"; exit 1; }
HIP=$($SSHN "hostname -I | awk '{print \$1}'" 2>/dev/null)
$SSHN "grep -q \"^$HIP[[:space:]]\" /etc/hosts" && say "/etc/hosts pinned to live lease ($HIP) ✓" || say "WARN: /etc/hosts not on live lease"
# ⛔ A LEASE NOBODY IS RENEWING IS NOT AN UPLINK — and every check above passes
# anyway.  `ifup` starts dhclient as a CHILD of sigmond-netfix.service, and
# with RemainAfterExit=no systemd reaped that cgroup the instant ExecStart
# returned: the daemon holding the lease died one second after binding.  The
# address, the route, the stanza and /etc/hosts were all still correct, so this
# phase passed — and the host silently lost IPv4 at lease expiry, twenty
# minutes later, long after the test had moved on.  Measured on AI6VN-PM
# 2026-10-01: bound 03:37:40, reaped 03:37:41, gone by 04:21.
# Assert the RENEWER, not just the lease. This is the only check here that
# would have caught it, and it costs one ssh.
if $SSHN "pgrep -x dhclient >/dev/null"; then
    say "dhclient is running — the lease will be renewed ✓"
else
    say "FATAL: no dhclient process; the lease at $HIP will expire and never renew"
    $SSHN "systemctl show sigmond-netfix -p RemainAfterExit -p KillMode; ip -4 -o addr show vmbr0"
    exit 1
fi
$SSHN "poweroff" 2>/dev/null; sleep 15; vm_kill
say "PHASE B PASS"
[ "${1:-all}" = "B" ] && exit 0
;&
C)
say "════ PHASE C: boot with USB attached → auto-import, VM runs UNPINNED ════"
boot_vm 1 serialC-v3.log
resolve_ssh 60 5 C || exit 1
say "waiting for decoder VM import (up to 10 min)"
for i in $(seq 1 60); do $SSHN "qm status $VMID 2>/dev/null | grep -q running" 2>/dev/null && break; sleep 10; done
$SSHN "qm status $VMID 2>/dev/null" | grep -q running || { say "FATAL: VM $VMID not running"; $SSHN "tail -20 /var/log/sigmond-firstboot.log"; exit 1; }
say "decoder VM $VMID imported + running (unpinned, pre-wizard)"
CFG=$($SSHN "qm config $VMID" 2>/dev/null)
echo "$CFG" | grep -q "name: sigmond-decoder-v3" && say "VM name versioned OK" || { say "FATAL: VM name wrong"; echo "$CFG"; exit 1; }
echo "$CFG" | grep -qE "^memory: (10240|[0-9]{5})" && say "memory sized to host ($(echo "$CFG"|awk '/^memory:/{print $2}')M)" || say "WARN: memory=$(echo "$CFG"|awk '/^memory:/{print $2}')"
$SSHN "test -f /etc/sigmond-appliance/layout.env" && say "CPU layout saved for finalizer" || say "WARN: layout.env missing (fallback path)"
$SSHN "test -f /root/sigmond-appliance/sigmond/scripts/proxmox/host-apply.sh" && say "sigmond checkout staged" || { say "FATAL: sigmond payload missing"; exit 1; }
$SSHN "test -x /usr/local/sbin/sigmond-setup" && say "wizard staged" || { say "FATAL: wizard missing"; exit 1; }
$SSHN "test -x /usr/local/sbin/sigmond-finalize.sh" && say "finalizer staged" || { say "FATAL: finalizer missing"; exit 1; }
$SSHN "systemctl is-enabled sigmond-wizard.service >/dev/null" && say "wizard service enabled (tty1)" || say "WARN: wizard unit not enabled"
$SSHN "systemctl is-active sigmond-finalize.path >/dev/null" && say "finalize path unit watching" || say "WARN: finalize path unit not active"
$SSHN "test -f /root/sigmond-appliance/sigmond-rac/install-host.sh" && say "sigmond-rac payload staged" || say "WARN: rac payload missing"

# ── the pristine snapshot ───────────────────────────────────────────────────
# Shipped in v3.44 with NO coverage here, and it silently did not exist on the
# first real install -- the operator's only signal was an absence.  An
# untested feature in an image is indistinguishable from a missing one, so
# assert it where it is created.
$SSHN "qm listsnapshot $VMID 2>/dev/null | grep -q pristine" \
  && say "pristine snapshot taken before first boot ✓" \
  || { say "FATAL: no 'pristine' snapshot on VM $VMID — qm rollback is unavailable to the operator"
       $SSHN "qm listsnapshot $VMID; grep -i pristine /var/log/sigmond-firstboot.log | tail -5"; exit 1; }

# ── the decoder VM is BEHIND the host, not on the site LAN ─────────────────
# The whole point is that the VM's address stops depending on a network we do
# not control.  Assert the shape, not just that something came up: one NIC,
# on the host-only bridge, at the fixed address, reachable FROM THE HOST --
# which is the only opinion that matters and the one Scranton proved can
# differ from "the VM has an IP".
echo "$CFG" | grep -q "^net0:.*bridge=vmbr1" \
  && say "decoder VM NIC on the host-only bridge ✓" \
  || { say "FATAL: net0 is not on vmbr1 — the VM is still on the site LAN"; echo "$CFG" | grep ^net; exit 1; }
echo "$CFG" | grep -q "^net1:" \
  && { say "FATAL: VM has a second NIC — it must have exactly one, on vmbr1"; exit 1; } \
  || say "decoder VM has exactly one NIC ✓"
$SSHN "ip -4 addr show vmbr1 2>/dev/null | grep -q 10.99.0.1" \
  && say "host-only bridge vmbr1 up at 10.99.0.1 ✓" \
  || { say "FATAL: vmbr1 is not up on the host"; $SSHN "ip -4 -br addr; grep -A6 'iface vmbr1' /etc/network/interfaces"; exit 1; }
$SSHN "sysctl -n net.ipv4.ip_forward | grep -q 1" \
  && say "host routes for the VM ✓" || { say "FATAL: ip_forward off — the VM has no route out"; exit 1; }
$SSHN "iptables -t nat -S POSTROUTING | grep -q '10.99.0.0/30.*MASQUERADE'" \
  && say "host NATs for the VM ✓" || { say "FATAL: no MASQUERADE for 10.99.0.0/30"; $SSHN "iptables -t nat -S"; exit 1; }
# v3.72 #23/#24: an image that ships sigmond-vm4relay puts the DNAT in
# SIGMOND-VM4, entered from vmbr0 only, and the FORWARD guard first in mangle
# FORWARD.  An older image (the update test installs the blessed baseline with
# this same harness) has the unrestricted rules by design: judge it by what it
# ships, and still demand that every operator port is forwarded.
if $SSHN "test -x /usr/local/sbin/sigmond-vm4relay"; then
  $SSHN "iptables -t nat -S PREROUTING | grep -qx -- '-A PREROUTING -i vmbr0 -j SIGMOND-VM4'" \
    || { say "FATAL: PREROUTING does not enter SIGMOND-VM4 from vmbr0"; $SSHN "iptables -t nat -S"; exit 1; }
  for _p in 8000 8081 8082 2222; do
    $SSHN "iptables -t nat -S SIGMOND-VM4 | grep -q -- '-s 192.168.0.0/16 .*dport $_p .*DNAT'" \
      || { say "FATAL: port $_p not forwarded to the VM -- an operator-facing service vanished from the LAN"; $SSHN "iptables -t nat -S"; exit 1; }
  done
  $SSHN "iptables -t nat -S PREROUTING | grep -q 'dport .*-j DNAT --to-destination 10.99.0.2'" \
    && { say "FATAL: an unrestricted PREROUTING DNAT rule to the VM remains"; exit 1; }
  $SSHN "iptables -t mangle -S FORWARD | grep -m1 '^-A ' | grep -qx -- '-A FORWARD -o vmbr1 -j SIGMOND-VM4F'" \
    || { say "FATAL: the FORWARD guard SIGMOND-VM4F is not first in mangle FORWARD (v3.72 #24)"; $SSHN "iptables -t mangle -S"; exit 1; }
  say "operator ports 8000/8081/8082/2222 forwarded from the station's own network; FORWARD guarded ✓"
else
  for _p in 8000 8081 8082 2222; do
    $SSHN "iptables -t nat -S PREROUTING | grep -q -- 'dport $_p .*DNAT --to-destination 10.99.0.2'" \
      || { say "FATAL: port $_p not forwarded to the VM -- an operator-facing service vanished from the LAN"; $SSHN "iptables -t nat -S"; exit 1; }
  done
  say "operator ports 8000/8081/8082/2222 forwarded from the host (pre-v3.72 image: no sigmond-vm4relay) ✓"
fi
# Reachability last, and at LAYER 3 -- the config can be perfect and the link
# still dead.  ⚠ Not TCP 22: at this point the wizard has not run, so the
# decoder VM has no ssh policy and nothing is listening on 22.  The first
# version of this check tested port 22 here and failed v3.45 on a station
# whose networking was entirely correct -- the guest had 10.99.0.2/30 on
# ens18, on vmbr1, the whole time.  Testing a service that does not exist yet
# tells you nothing about the link.  Phase D asserts ssh, after the wizard.
_vmok=0
for i in $(seq 1 18); do
  $SSHN "ping -c1 -W2 10.99.0.2 >/dev/null 2>&1" && { _vmok=1; break; }
  sleep 10
done
[ "$_vmok" = 1 ] && say "host reaches the VM at 10.99.0.2 ✓" \
  || { say "FATAL: VM unreachable at 10.99.0.2 from its own hypervisor (the Scranton failure mode)"
       $SSHN "qm guest exec $VMID -- /bin/bash -c 'ip -4 -br addr; ip route; ss -ltn'; ip -4 -br addr show vmbr1; tail -20 /var/log/sigmond-firstboot.log"; exit 1; }
# The address the guest actually holds must be the one we intend -- a lease
# from somewhere would also answer a ping.
$SSHN "qm guest exec $VMID --timeout 30 -- /bin/bash -c 'ip -4 -br addr show scope global'" 2>/dev/null \
  | grep -q "10.99.0.2/30" \
  && say "guest holds the fixed address 10.99.0.2/30 ✓" \
  || say "WARN: could not confirm the guest's address is the fixed one"

say "PHASE C PASS"
[ "${1:-all}" = "C" ] && exit 0
;&
D)
say "════ PHASE D: wizard → finalizer → tuning reboot → pinned production ════"
# standalone `D` invocations start with $SSHN unresolved (no B/C ran in
# this process); resolve_ssh no-ops quickly if it's already pinned.
resolve_ssh 60 5 D || exit 1
# require 2 consecutive agent pings — a lone success during guest boot
# can be followed by an agent restart (observed 2026-07-26, false FATAL)
AGENT_OK=0
for i in $(seq 1 40); do
    if $SSHN "qm agent $VMID ping" >/dev/null 2>&1; then
        AGENT_OK=$((AGENT_OK+1)); [ "$AGENT_OK" -ge 2 ] && break; sleep 3
    else
        AGENT_OK=0; sleep 10
    fi
done
[ "$AGENT_OK" -ge 2 ] || { say "FATAL: guest agent never answered"; exit 1; }
say "verifying decoder VM internals: generic kernel (USB stack) + hamsci login"
GK=$($SSHN "qm guest exec $VMID --timeout 60 -- bash -lc 'uname -r; ls /lib/modules/\$(uname -r)/kernel/drivers/usb/host/ | grep -c xhci; id hamsci'" 2>&1)
echo "$GK" | tail -4
echo "$GK" | grep -q 'cloud' && { say "FATAL: decoder VM still on CLOUD kernel (no USB stack)"; exit 1; }
echo "$GK" | grep -q 'hamsci' || { say "FATAL: hamsci user missing in decoder VM"; exit 1; }
# ⛔ RUN THIS ONLY AFTER THE AGENT WAIT ABOVE.  It first sat in Phase C,
# four seconds after VM import, where `qm guest exec` answers "QEMU guest
# agent is not running" -- and the probe reported that as a LEAK on
# 2026-09-23, then as "could not tell" once it learned to distinguish the
# two.  The agent is confirmed up by the two-ping gate above, and the
# wizard has still not run, so this window is both answerable and
# genuinely pre-configuration.
#
# Match an UNCOMMENTED section header only: capture-prep writes the
# site-profile SCAFFOLD into the template and that scaffold documents the
# block as a commented example (site_profile.py:75).  An example in a
# comment is documentation; a section at line start is configuration.
# The golden template must carry NO [heartbeat] config.  This check used to
# live AFTER the wizard, where it asserted "not enabled" — which stopped
# being true in v3.52 once the wizard began enabling the heartbeat by
# default.  Leak-detection belongs here, before anything configures the
# station; the post-wizard block now asserts the configured state instead.
# ⛔ Match an UNCOMMENTED section header only.  capture-prep writes the
# site-profile SCAFFOLD into the template, and that scaffold documents the
# block as a commented example ("# [heartbeat]  # fleet situational-awareness
# ...", site_profile.py:75).  A bare `grep "\[heartbeat\]"` matches the
# comment and reports a leak that is not there — it did, on 2026-09-23.
# An example in a comment is documentation; a section at line start is config.
HBLEAK=$($SSHN "qm guest exec $VMID --timeout 30 -- bash -lc 'grep -qE \"^[[:space:]]*\\[heartbeat\\]\" /etc/sigmond/site-profile.toml 2>/dev/null && echo LEAKED || echo CLEAN'" 2>&1)
case "$HBLEAK" in
    *CLEAN*)  say "golden template carries no heartbeat config ✓" ;;
    *LEAKED*) say "FATAL: a live [heartbeat] section leaked into the golden template"; echo "$HBLEAK" | head -6; exit 1 ;;
    # Neither token means the probe failed to answer.  Say THAT, rather than
    # reporting a leak — "could not tell" and "found a leak" are different
    # facts, and conflating them cost a diagnosis today.
    *) say "FATAL: heartbeat leak probe returned neither CLEAN nor LEAKED"; echo "$HBLEAK" | head -6; exit 1 ;;
esac

# The site sink switch belongs to the station.  The wizard writes it on a
# FRESH install only, and `smd sink status` reads coordination.toml, so
# neither file in the golden template may carry a live [uploads].
UPLEAK=$($SSHN "qm guest exec $VMID --timeout 30 -- bash -lc 'grep -qsE \"^[[:space:]]*\\[uploads\\]\" /etc/sigmond/site-profile.toml /etc/sigmond/coordination.toml && echo LEAKED || echo CLEAN'" 2>&1)
case "$UPLEAK" in
    *CLEAN*)  say "golden template carries no [uploads] ✓" ;;
    *LEAKED*) say "FATAL: a live [uploads] section leaked into the golden template"; echo "$UPLEAK" | head -6; exit 1 ;;
    *) say "FATAL: uploads leak probe returned neither CLEAN nor LEAKED"; echo "$UPLEAK" | head -6; exit 1 ;;
esac

say "staging a test site-keys tarball (exercises the stick key-restore path)"
$SSHN "mkdir -p /root/sigmond-appliance /tmp/sk/etc/hs-uploader/keys /tmp/sk/home/timestd/.ssh && echo TESTPRIV > /tmp/sk/etc/hs-uploader/keys/id_ed25519_host && echo TESTPUB > /tmp/sk/etc/hs-uploader/keys/id_ed25519_host.pub && echo TESTRSA > /tmp/sk/home/timestd/.ssh/id_rsa_psws && tar czf /root/sigmond-appliance/site-keys.tar.gz -C /tmp/sk etc home && rm -rf /tmp/sk"
say "guest kernel + hamsci OK; running wizard with piped answers (identity N0CALL/T1 @ EM00aa)"
# ⛔ ONE ANSWER PER PROMPT, IN ORDER, EACH LABELLED.  This was a bare
# printf of eleven unlabelled lines, and on 2026-09-23 a wizard change
# (magnetometer-station prompt removed, three heartbeat prompts added)
# silently shifted every answer after the eighth: the wizard consumed the
# designator answer as a heartbeat host, ran out of input, and Phase D
# failed with "wizard did not complete" — a message that says nothing
# about which prompt moved.
#
# Labelling them makes the mapping checkable by eye and gives the next
# wizard change an obvious place to add its answer.  The wizard's rd()
# guard still aborts loudly on desync (2026-08-11), which is how the
# breakage surfaced at all rather than producing a mis-configured station.
# From v3.71 the wizard asks nothing about remote access: every install
# registers and brings the tunnel up.  The update rig runs these phases on the
# previous blessed image, whose wizard still asks.  So ask the wizard under
# test which one it is, and answer accordingly (wizard_answers, above).
# MISSING is its own token: a grep on a file that is not there exits 2, and
# "no wizard" must not read as "a wizard that does not ask".
case "$($SSHN "test -r /usr/local/sbin/sigmond-setup || { echo RACQ:MISSING; exit 0; }; grep -q 'Enable remote access?' /usr/local/sbin/sigmond-setup && echo RACQ:YES || echo RACQ:NO" 2>&1)" in
    *RACQ:YES*) RACQ=1 ;;
    *RACQ:NO*)  RACQ=0 ;;
    *) say "FATAL: could not read the host's wizard to decide its answers"; exit 1 ;;
esac
if [ "$RACQ" = 1 ] && [ "${SINK_BASE_IMAGE:-0}" != 1 ]; then
    say "FATAL: the image under test still asks 'Enable remote access?'"
    say "  only the update rig's base image may; test-update-v3.sh sets SINK_BASE_IMAGE=1 for that run"
    exit 1
fi
# ⛔ SUDO MUST COME OFF THE STICK.  When the host has no sudo, the wizard fetches
# it with apt, and this nest has internet through qemu's user network.  A stick
# built without the package would then pass every later check.  So ask dpkg
# BEFORE the wizard runs; check 1 asks the wizard's log again afterwards.
# build-usb-v3.sh prefers the rig's own copy of offline-debs, so a forgotten
# sync of that directory yields exactly such a stick.  Only a v3.71 stick
# carries the package: the update rig's base image does not (RACQ=1).
if [ "$RACQ" = 0 ]; then
    SUDOPRE=$($SSHN "dpkg-query -W -f='\${Status}' sudo 2>/dev/null | grep -q 'install ok installed' && echo SUDOPRE:1 || echo SUDOPRE:0; echo END:1" 2>&1)
    nh_ok "$SUDOPRE" || { say "FATAL: the nested host gave no answer to the sudo probe (ssh failed; not a verdict on the stick)"; exit 1; }
    [ "$(rr_tok SUDOPRE "$SUDOPRE")" = 1 ] \
        || { say "FATAL: sudo is not installed on the nested host before the wizard runs: the stick carried no sudo package (is offline-debs/ in the rig's copy up to date? build-usb-v3.sh prefers it)"; exit 1; }
    say "sudo is installed before the wizard runs (it came off the stick) ✓"
fi
# ⛔ PIN THE GATEWAY BEFORE THE WIZARD RUNS.  This nest reaches the internet
# through qemu's user network, and a v3.71 wizard registers without asking.
# Unpinned, every run of this rig would register "N0CALL_T1" with the real
# gateway.  The pin names this host's own loopback, where nothing listens
# until the stand-in further down starts.  The wizard reads the pin at start,
# and so does the retry timer.  A wizard from before v3.71 ignores the file.
# The rig goes on only when the pin reads back: a pin it cannot confirm is a
# pin it cannot trust, and the next step could register a test station.
case "$($SSHN "mkdir -p /etc/sigmond-appliance && printf '%s\n' SIGMOND_RAC_SERVER=127.0.0.1 SIGMOND_RAC_REGISTRAR=http://127.0.0.1:35737/register SIGMOND_RAC_TLS=off SIGMOND_RAC_FRPS_PORT=35735 > /etc/sigmond-appliance/rac-endpoint.env && grep -qx 'SIGMOND_RAC_SERVER=127.0.0.1' /etc/sigmond-appliance/rac-endpoint.env && echo PIN:OK" 2>&1)" in
    *PIN:OK*) ;;
    *) say "FATAL: could not pin the gateway on the nested host (the pin did not read back)"; exit 1 ;;
esac
mapfile -t WIZARD_ANSWERS < <(wizard_answers "$RACQ")
say "wizard answers: ${#WIZARD_ANSWERS[@]} (remote-access question: $([ "$RACQ" = 1 ] && echo asked || echo not asked))"
# The same four variables go into the wizard's own environment as well.  A
# wizard from before v3.71 honours the environment and ignores the file, and
# against such a wizard the answer `n` would be the only other guard.
printf '%s\n' "${WIZARD_ANSWERS[@]}" | $SSHN "SIGMOND_RAC_SERVER=127.0.0.1 SIGMOND_RAC_REGISTRAR=http://127.0.0.1:35737/register SIGMOND_RAC_TLS=off SIGMOND_RAC_FRPS_PORT=35735 sigmond-setup" 2>&1 | tail -40
MARK_OK=0
for i in $(seq 1 12); do
    $SSHN "test -f /etc/sigmond-appliance/.configured" 2>/dev/null && { MARK_OK=1; break; }
    sleep 10
done
[ "$MARK_OK" = 1 ] && say "configured marker present: $($SSHN cat /etc/sigmond-appliance/.configured)" || { say "FATAL: wizard did not complete"; exit 1; }
# NO in-guest verification here: .configured fires the finalizer, which
# SHUTS THE VM DOWN for host tuning (raced 2026-07-26, false FATAL).
# Identity + PSWS are verified after the production reboot below.

say "── finalizer: waiting for host tuning (REMOVE-THE-STICK prompt, up to 10 min)"
for i in $(seq 1 60); do $SSHN "grep -q 'REMOVE THE USB STICK' /var/log/sigmond-firstboot.log" 2>/dev/null && break; sleep 10; done
$SSHN "grep -q 'REMOVE THE USB STICK' /var/log/sigmond-firstboot.log" 2>/dev/null || { say "FATAL: finalizer never reached stick-removal prompt"; $SSHN "tail -30 /var/log/sigmond-firstboot.log"; exit 1; }
say "finalizer tuned the host; verifying artifacts"
CFG=$($SSHN "qm config $VMID" 2>/dev/null)
echo "$CFG" | grep -q "^hookscript:" && say "cpu-pin hookscript bound" || say "WARN: no hookscript"
echo "$CFG" | grep -q "^affinity:" && say "affinity set: $(echo "$CFG"|awk '/^affinity:/{print $2}')" || say "WARN: no affinity"
echo "$CFG" | grep -q "topoext=on" && say "-smp/topoext args set" || say "WARN: no -smp args"
echo "$CFG" | grep -q "^hostpci0:" && say "USB controller passthrough bound" || say "WARN: no hostpci bound (check log)"
$SSHN "grep -q isolcpus /etc/default/grub.d/sigmond.cfg" && say "grub isolcpus staged" || say "WARN: grub sigmond.cfg missing"
$SSHN "test -f /etc/modprobe.d/vfio.conf" && say "vfio.conf staged" || say "WARN: vfio.conf missing"
$SSHN "test -f /etc/sigmond/host-layout.env" && say "host-layout.env saved" || say "WARN: host-layout.env missing"

say "detaching USB stick via QMP (device_del usbdev)"
qmp '{"execute":"device_del","arguments":{"id":"usbdev"}}'
# v3.28+ semantics: after stick removal the appliance POWERS OFF (by
# design — the operator's manual power-on resets the RX888's VBUS).  So:
# wait for ssh to drop, wait for the guest to power off (qemu exits),
# then "press the power button" — relaunch from NVMe.
say "waiting for finalizer-driven power-off (ssh drop + qemu exit, up to 10 min)"
DROPPED=0
for i in $(seq 1 60); do $SSHN true 2>/dev/null || { DROPPED=1; break; }; sleep 5; done
[ "$DROPPED" = 1 ] || { say "FATAL: nested host never went down after stick removal"; exit 1; }
say "ssh dropped; waiting for guest power-off (qemu exit)"
QOFF=0
for i in $(seq 1 36); do pgrep -f "guest=sigv[3]" >/dev/null || { QOFF=1; break; }; sleep 5; done
[ "$QOFF" = 1 ] || { say "FATAL: guest did not power off within 3 min of ssh drop"; exit 1; }
say "guest powered off (v3.28+ by-design); powering back on from NVMe"
boot_vm 0 serialE-v3.log
for i in $(seq 1 90); do $SSHN true 2>/dev/null && break; sleep 5; done
$SSHN true 2>/dev/null || { say "FATAL: nested PVE did not come back after power-on"; exit 1; }
$SSHN "grep -qw 'isolcpus=${ISOL:-}' /proc/cmdline 2>/dev/null || grep -qw isolcpus /proc/cmdline" && say "isolcpus ACTIVE on rebooted host" || say "WARN: isolcpus not in cmdline"
say "checking VM $VMID autostart (nest has no IOMMU: hostpci start fails by design)"
VMUP=0
for i in $(seq 1 18); do $SSHN "qm status $VMID 2>/dev/null | grep -q running" 2>/dev/null && { VMUP=1; break; }; sleep 10; done
if [ "$VMUP" = 0 ]; then
    say "VM not running (expected in nest with hostpci bound) — stripping hostpci for nested continuation"
    PCIS=$($SSHN "qm config $VMID | grep -oE '^hostpci[0-9]+' | paste -sd,")
    [ -n "$PCIS" ] && $SSHN "qm set $VMID --delete $PCIS"
    $SSHN "qm start $VMID" || { say "FATAL: VM $VMID won't start even without hostpci"; exit 1; }
    for i in $(seq 1 30); do $SSHN "qm status $VMID | grep -q running" 2>/dev/null && { VMUP=1; break; }; sleep 10; done
fi
[ "$VMUP" = 1 ] || { say "FATAL: VM $VMID not running post-reboot"; exit 1; }
say "decoder VM $VMID running pinned-config post-reboot; verifying 1:1 vCPU pinning"
$SSHN "QP=\$(cat /var/run/qemu-server/$VMID.pid); for tid in \$(ps -T -p \$QP -o tid=); do case \"\$(cat /proc/\$tid/comm)\" in CPU*KVM) taskset -pc \$tid;; esac; done" 2>&1 | tail -8
for i in $(seq 1 30); do $SSHN "qm agent $VMID ping" >/dev/null 2>&1 && break; sleep 10; done
say "verifying VM account password hash matches PM root (the wizard hash-copy path)"
RHASH=$($SSHN "getent shadow root | cut -d: -f2" 2>/dev/null)
# ⛔ A ping is not a ready agent.  v3.67 (2026-10-05 00:11:54Z) failed here
# twice: qemu-ga answered guest-ping 6 s after it started, then the PM logged
# "qga command 'guest-exec' failed - got timeout" while the guest was still
# booting.  The exec never reached the agent, VHASH came back empty, and the
# FATAL blamed the wizard's hash copy — which a later probe showed matched.
# So retry until the exec actually returns output, and only then judge.
VHASH=""
for i in $(seq 1 12); do
    VHASH=$($SSHN "qm guest exec $VMID --timeout 20 -- bash -c 'getent shadow hamsci | cut -d: -f2' 2>/dev/null" | grep -o '"out-data" *: *"[^"]*"' | sed 's/.*: *"//;s/\\n"$//;s/"$//')
    [ -n "$VHASH" ] && break
    sleep 10
done
[ -n "$VHASH" ] || { say "FATAL: guest exec never returned output in 12 tries — guest agent not executing (not a hash verdict)"; exit 1; }
if [ -n "$RHASH" ] && [ "$VHASH" = "$RHASH" ]; then
    say "VM password hash matches PM root ✓"
else
    say "FATAL: VM hamsci hash does not match PM root (wizard hash-copy mangled: pm=${RHASH:0:12}... vm=${VHASH:0:12}...)"; exit 1
fi

say "verifying identity inside decoder VM (post-reboot)"
$SSHN "qm guest exec $VMID --timeout 60 -- bash -lc 'grep -E \"reporter_id|callsign|grid\" /etc/sigmond/site-profile.toml; grep REPORTER /etc/sigmond/coordination.env; hostname'" 2>&1 | tail -8
say "verifying two-phase PSWS enrollment in decoder VM"
PSWS_OUT=$($SSHN "qm guest exec $VMID --timeout 60 -- bash -lc 'grep -A3 \"\\[psws\\]\" /etc/sigmond/site-profile.toml; smd psws status; test -x /etc/update-motd.d/70-sigmond-psws && echo MOTD-HOOK-OK; test -f /etc/hs-uploader/keys/id_ed25519_host.pub && echo STATION-KEY-OK; smd psws motd'" 2>&1)
echo "$PSWS_OUT" | tail -20
echo "$PSWS_OUT" | grep -q 'S000999'        || { say "FATAL: PSWS station id missing from site profile"; exit 1; }
echo "$PSWS_OUT" | grep -q 'MOTD-HOOK-OK'   || { say "FATAL: PSWS motd hook not installed"; exit 1; }
echo "$PSWS_OUT" | grep -q 'STATION-KEY-OK' || { say "FATAL: station key not generated"; exit 1; }
echo "$PSWS_OUT" | grep -qi 'not finished\|NOT YET\|verify' || { say "FATAL: pending-enrollment banner missing"; exit 1; }

# The heartbeat prompt shipped in v3.52 and nothing tested it.  Assert what
# the wizard was asked for actually reached the profile -- above all the
# PORT: site_profile.py defaults [heartbeat].port to 22 and the collector
# answers only on 38222, so a profile carrying the host WITHOUT a port
# produces a station that reports nowhere and looks configured.
say "verifying the fleet heartbeat the wizard was asked to enable"
HB_OUT=$($SSHN "qm guest exec $VMID --timeout 60 -- bash -lc 'grep -A4 \"\\[heartbeat\\]\" /etc/sigmond/site-profile.toml'" 2>&1)
echo "$HB_OUT" | tail -6
echo "$HB_OUT" | grep -qE 'enabled[[:space:]]*=[[:space:]]*true' \
    || { say "FATAL: heartbeat not enabled in site profile"; exit 1; }
echo "$HB_OUT" | grep -q 'wd30.wsprdaemon.org' \
    || { say "FATAL: heartbeat collector host missing from site profile"; exit 1; }
echo "$HB_OUT" | grep -qE 'port[[:space:]]*=[[:space:]]*38222' \
    || { say "FATAL: heartbeat port not 38222 — the code default of 22 never delivers"; exit 1; }
say "heartbeat enabled, host and port 38222 written ✓"

# Every site sink check that does not run, or does not conclude, adds a phrase
# here.  One line before PHASE D PASS repeats them, so a reader of the verdict
# line learns what the pass left unchecked.  The phrase must keep the words
# NOT EVALUATED around it: test-update-v3.sh copies those lines into its log.
SINK_UNCHECKED=""
sink_unchecked(){ case "; $SINK_UNCHECKED;" in *"; $*;"*) return 0 ;; esac; SINK_UNCHECKED="${SINK_UNCHECKED:+$SINK_UNCHECKED; }$*"; }

# test-update-v3.sh runs these phases against the PREVIOUS blessed image,
# whose wizard writes no [uploads] and whose sigmond has no `smd sink`.  Ask
# the host's wizard what it does.  Only that base image may lack the switch:
# test-update-v3.sh sets SINK_BASE_IMAGE=1 for its run, and there the checks
# are skipped, loudly.  Anywhere else a wizard without it is FATAL, because
# bless gate 5 reads only PHASE D PASS, and a pass with every site sink check
# skipped would bless an image that never sets the switch.
case "$($SSHN "grep -q '^uploads_toml()' /usr/local/sbin/sigmond-setup && echo SINKWIZ:YES || echo SINKWIZ:NO" 2>&1)" in
    *SINKWIZ:YES*) SINKWIZ=1 ;;
    *SINKWIZ:NO*)  SINKWIZ=0
                   if [ "${SINK_BASE_IMAGE:-0}" != 1 ]; then
                       say "FATAL: the image under test has no site sink wizard (its wizard defines no uploads_toml())"
                       say "  only the update rig's base image may lack it; test-update-v3.sh sets SINK_BASE_IMAGE=1 for that run"
                       exit 1
                   fi
                   say "⚠ SITE SINK ASSERTIONS NOT EVALUATED — this image's wizard predates"
                   say "  the site sink switch (pre-v3.69); expected only on the update rig's base image"
                   sink_unchecked "all of them (this image's wizard defines no uploads_toml(); it predates the site sink switch, or the wizard renamed it)" ;;
    *) say "FATAL: could not read the host's wizard to decide the site sink checks"; exit 1 ;;
esac
if [ "$SINKWIZ" = 1 ]; then
    say "verifying the site sink switch starts off on a fresh install"
    # One KEY:N token per file.  qm guest exec returns JSON whose "out-data"
    # carries every output line on ONE line, so grep -c over $SINK_OUT can never
    # count past 1; read tokens instead, as phase_d_verdict does.
    SINK_OUT=$($SSHN "qm guest exec $VMID --timeout 60 -- bash -lc 'for f in site-profile coordination; do echo \"\$f:\$(grep -A3 \"^\\[uploads\\]\" /etc/sigmond/\$f.toml 2>/dev/null | grep -cE \"^mode *= *.discard.\")\"; done; smd sink status 2>&1'" 2>&1)
    echo "$SINK_OUT" | tail -12
    _sp=$(echo "$SINK_OUT" | grep -oE 'site-profile:[0-9]+' | head -1 | cut -d: -f2)
    _co=$(echo "$SINK_OUT" | grep -oE 'coordination:[0-9]+' | head -1 | cut -d: -f2)
    [ -n "$_sp" ] && [ -n "$_co" ] \
        || { say "FATAL: the site sink probe returned no answer (guest exec failed, not a verdict)"; exit 1; }
    [ "$_sp" -ge 1 ] || { say "FATAL: site-profile.toml carries no [uploads] mode = \"discard\" after a fresh install"; exit 1; }
    [ "$_co" -ge 1 ] || { say "FATAL: coordination.toml carries no [uploads] mode = \"discard\"; smd config render did not copy it"; exit 1; }
    echo "$SINK_OUT" | grep -qF "$SP2_OFF_PHRASE" \
        || { say "FATAL: smd sink status does not report site sink: off"; exit 1; }
    say "site sink switch off in both files and in smd sink status ✓"
fi
say "PSWS: ids recorded, key generated, banner armed — pending verify (as designed)"

say "── v3.4 fixes: wizard unit disabled, getty alive, panel, sentinel, wisdom"
$SSHN "systemctl is-enabled sigmond-wizard.service 2>&1" | grep -q disabled \
    && say "wizard unit disabled post-config ✓" \
    || { say "FATAL: sigmond-wizard.service still enabled — blank-console bug"; exit 1; }
$SSHN "systemctl is-active getty@tty1.service" 2>/dev/null | grep -q '^active' \
    && say "getty@tty1 alive on rebooted host ✓" \
    || { say "FATAL: getty@tty1 not active (blank console)"; exit 1; }
$SSHN "grep -q 'Sigmond appliance' /etc/issue" 2>/dev/null \
    && say "access panel present in /etc/issue ✓" || say "WARN: no access panel in /etc/issue"
# The location-authority timer replaced sigmond-sdr-sentinel on 2026-09-02.
# The sentinel also ran `smd bringup` whenever it saw an RX888, which started a
# station's whole stack unattended; `smd adopt` replaced that and asks first.
# So this asserts BOTH that the survivor is armed and that the retired one is
# gone — a leftover sentinel would quietly restore the auto-start.
V34=$($SSHN "qm guest exec $VMID --timeout 60 -- bash -lc 'echo LOC-\$(systemctl is-enabled sigmond-location-check.timer 2>&1); echo SENT-\$(systemctl is-enabled sigmond-sdr-sentinel.timer 2>&1); test -s /etc/fftw/wisdomf && echo WISDOM-OK; test -x /usr/local/sbin/sigmond-site-timing && echo TIMING-OK; grep -q \"^v3\" /etc/sigmond-appliance/version 2>/dev/null && echo VMVER-OK'" 2>&1)
echo "$V34" | grep -q "LOC-enabled" || { say "FATAL: location-check timer not enabled in VM"; exit 1; }
echo "$V34" | grep -q "SENT-enabled" && { say "FATAL: retired sdr-sentinel timer still armed in VM"; exit 1; }
echo "$V34" | grep -q WISDOM-OK || { say "FATAL: FFT wisdom not seeded in VM"; exit 1; }
echo "$V34" | grep -q TIMING-OK || { say "FATAL: sigmond-site-timing not installed in VM"; exit 1; }
echo "$V34" | grep -q VMVER-OK  || { say "FATAL: appliance version not stamped into VM"; exit 1; }
UT=$($SSHN "qm guest exec $VMID --timeout 30 -- bash -lc 'command -v btop; command -v tmux; cat /home/hamsci/.tmux.conf 2>/dev/null'" 2>&1)
echo "$UT" | grep -q "bin/btop" && echo "$UT" | grep -q "bin/tmux" && echo "$UT" | grep -q "mouse on" \
    && say "operator utils (btop/tmux + tmux.conf) ✓" \
    || { say "FATAL: btop/tmux/.tmux.conf missing in VM"; exit 1; }
$SSHN "test -f /etc/profile.d/sigmond-operator.sh" \
    && say "operator helpers on host ✓" || { say "FATAL: sigmond-operator.sh missing on host"; exit 1; }
TMF=$($SSHN "qm guest exec $VMID --timeout 30 -- bash -lc 'bash -lc \"type tm; alias ll lrt\" 2>&1'" 2>&1)
echo "$TMF" | grep -q "tm is a function" && echo "$TMF" | grep -q "ls -lrt" \
    && say "tm()/ll/lrt live in VM login shells ✓" \
    || { say "FATAL: operator helpers not active in VM"; echo "$TMF" | head -3; exit 1; }
GRP=$($SSHN "qm guest exec $VMID --timeout 30 -- bash -lc 'id hamsci'" 2>&1)
echo "$GRP" | grep -q "timestd" && echo "$GRP" | grep -q "sigmond" \
    && say "operator service-group membership ✓" \
    || { say "FATAL: hamsci missing service groups"; exit 1; }
MAGC=$($SSHN "qm guest exec $VMID --timeout 30 -- bash -lc 'grep -E \"psws_station_id|^callsign|^grid_square\" /etc/mag-recorder/mag-recorder-config.toml'" 2>&1)
# ⛔ This asserted S000998 — the SEPARATE magnetometer station the wizard
# used to ask for — and its message read "own PSWS station".  Both encoded
# the behaviour v3.52 deliberately ended: one site, one PSWS station id,
# instruments distinguished by instrument id.  The magnetometer now reports
# under the SITE station, and that is the invariant worth asserting.
echo "$MAGC" | grep -q "S000999" && echo "$MAGC" | grep -q "N0CALL" && echo "$MAGC" | grep -q "EM00aa" \
    && say "mag-recorder identity filled under the SITE PSWS station ✓" \
    || { say "FATAL: mag-recorder identity not filled (expected site station S000999)"; echo "$MAGC" | head -3; exit 1; }
echo "$MAGC" | grep -q "S000998" \
    && { say "FATAL: mag-recorder carries a SEPARATE PSWS station — [psws.stations] has come back"; echo "$MAGC" | head -3; exit 1; } || true
say "location authority armed (sentinel retired) + wisdom seeded + site-timing staged in VM ✓"
$SSHN "hostname" | grep -q "N0CALL-T1-PM" \
    && say "Proxmox host renamed to N0CALL-T1-PM ✓" \
    || { say "FATAL: host not renamed (naming convention)"; $SSHN hostname; exit 1; }
$SSHN "qm config $VMID | grep -q '^name: N0CALL-T1$'" \
    && say "decoder VM named N0CALL-T1 ✓" \
    || { say "FATAL: VM not renamed"; $SSHN "qm config $VMID | grep name"; exit 1; }
GH=$($SSHN "qm guest exec $VMID --timeout 30 -- bash -lc hostname" 2>/dev/null)
echo "$GH" | grep -qi "N0CALL-T1" && say "VM guest hostname N0CALL-T1 ✓" || say "WARN: guest hostname: $GH"
KR=$($SSHN "qm guest exec $VMID --timeout 30 -- bash -lc 'cat /etc/hs-uploader/keys/id_ed25519_host; stat -c %U:%G /etc/hs-uploader/keys/id_ed25519_host; cat /home/timestd/.ssh/id_rsa_psws 2>/dev/null'" 2>&1)
# pre-bringup the hsupload user doesn't exist yet (born at bringup, when
# site-timing completes the chown) — root:sigmond is the correct interim
echo "$KR" | grep -q TESTPRIV && echo "$KR" | grep -qE "(hsupload|root):sigmond" && echo "$KR" | grep -q TESTRSA \
    && say "site-keys restored from stick with correct ownership ✓" \
    || { say "FATAL: site-keys restore path failed"; echo "$KR" | head -5; exit 1; }
say "── location authority: fake GPSDO announces Scranton (FN21ej)"
LC=$($SSHN "qm guest exec $VMID --timeout 120 -- bash -lc 'test -x /usr/local/sbin/sigmond-location-check || { echo NOT-STAGED; exit 0; }; mkdir -p /run/gpsdo && printf \"{\\\"health\\\": {\\\"latitude\\\": 41.4, \\\"longitude\\\": -75.66, \\\"gps_fix\\\": \\\"3D\\\", \\\"sats_used\\\": 8, \\\"fix_age_sec\\\": 1}}\" > /run/gpsdo/TEST.json; /usr/local/sbin/sigmond-location-check; grep -E \"grid_square|latitude|longitude\" /etc/sigmond/site-profile.toml | head -3'" 2>&1)
echo "$LC" | grep -q NOT-STAGED && { say "FATAL: sigmond-location-check not staged"; exit 1; }
echo "$LC" | grep -q 'FN21ej' && echo "$LC" | grep -q '41.4' \
    && say "location authority re-gridded the station from the (fake) GPSDO ✓" \
    || { say "FATAL: location authority did not apply GPSDO position"; echo "$LC" | head -4; exit 1; }
say "── fleet awareness: heartbeat CLI contract on a CONFIGURED station"
# The original contract (fleet-awareness plan, Phase 6) asserted exit 2 +
# "not enabled", because no wizard had ever written a [heartbeat] block and
# the only thing worth proving here was that no config had leaked into the
# template.  v3.52's wizard enables the heartbeat, so after it runs exit 2
# would mean the wizard's answer never reached the profile.
#
# The leak check moved to Phase C, before anything configures the station.
# What belongs HERE is the other half, which the old comment said was
# "proven live on a configured station, not here": the exit-0 path.  It now
# exercises the whole route — wizard answer, site profile, config render,
# CLI — instead of only proving the CLI exists.  It also checks the timer
# itself and a REAL (non-dry-run) emit: the v3.52 test checked config and a
# dry run and passed, on a station whose wizard wrote [heartbeat] but never
# enabled sigmond-heartbeat.timer, so it never reported (sigmond#94).
# ⛔ Do NOT let the heartbeat PAYLOAD into this output.  `qm guest exec`
# truncates (out-truncated), the payload is a full JSON document, and the
# rc we care about trails it — so a long payload would silently carry the
# verdict off the end.  Redirect the payload to a file in the guest and
# return only the two facts: the exit code, and whether it said "not
# enabled".
HB=$($SSHN "qm guest exec $VMID --timeout 30 -- bash -lc 'o=\$(smd admin heartbeat emit --dry-run 2>&1); echo rc=\$?; echo notenabled=\$(printf %s \"\$o\" | grep -ci \"not enabled\")'" 2>&1)
echo "$HB" | grep -q "rc=0" \
    && say "heartbeat emit --dry-run: exit 0 on the configured station ✓" \
    || { say "FATAL: heartbeat not emitting after the wizard enabled it"; echo "$HB" | head -6; exit 1; }
echo "$HB" | grep -q "notenabled=0" \
    || { say "FATAL: heartbeat reports NOT ENABLED after the wizard enabled it"; echo "$HB" | head -6; exit 1; }
$SSHN "qm guest exec $VMID --timeout 30 -- bash -lc 'systemctl list-unit-files sigmond-heartbeat.timer sigmond-gap-hourly.timer'" 2>&1 | grep -q "sigmond-heartbeat.timer" \
    && say "heartbeat + gap-hourly units present in image ✓" \
    || { say "FATAL: awareness units missing from image"; exit 1; }
$SSHN "qm guest exec $VMID --timeout 30 -- bash -lc 'echo HBT-\$(systemctl is-enabled sigmond-heartbeat.timer 2>&1)'" 2>&1 | grep -q "HBT-enabled" \
    && say "sigmond-heartbeat.timer enabled by the wizard ✓" \
    || { say "FATAL: the wizard enabled the heartbeat but not its timer — the station will never report (sigmond#94)"; exit 1; }
HBN=$($SSHN "qm guest exec $VMID --timeout 30 -- bash -lc 'smd admin heartbeat emit >/dev/null 2>&1; echo count=\$(ls /var/lib/sigmond/heartbeat/*.json 2>/dev/null | wc -l)'" 2>&1)
echo "$HBN" | grep -qE "count=[1-9][0-9]*" \
    && say "heartbeat emit wrote a spool file in /var/lib/sigmond/heartbeat ✓" \
    || { say "FATAL: heartbeat emit did not write a spool file under /var/lib/sigmond/heartbeat"; echo "$HBN" | head -6; exit 1; }
# The PM (this nested PVE host, not the VM) ships its own heartbeat emitter
# too, but nothing ever ran it, so every PM row on the fleet board stayed
# silent after a fresh install (sigmond-appliance#9).  Checked directly on
# the PM with $SSHN, not qm guest exec — pm-heartbeat.timer runs on the host.
$SSHN "systemctl is-enabled pm-heartbeat.timer 2>&1" | grep -q "^enabled$" \
    && say "pm-heartbeat.timer enabled on the PM ✓" \
    || { say "FATAL: pm-heartbeat.timer not enabled on the PM — the host heartbeat never got wired up (sigmond-appliance#9)"; exit 1; }
$SSHN "test -f /etc/pm-heartbeat/config.toml" \
    && say "pm-heartbeat config.toml present on the PM ✓" \
    || { say "FATAL: /etc/pm-heartbeat/config.toml missing on the PM (sigmond-appliance#9)"; exit 1; }
say "── gmag-webui (v3.34): pinned Deno + dashboard unit baked into the VM"
# sigmond 9833c25 added gmag-webui (HamSCI magnetometer dashboard) as a dasi2
# core client installed by the smd-native recipe: a pinned Deno under
# /usr/local/lib/deno/<ver>/ with /usr/local/bin/deno, the checkout under
# /opt/git/sigmond/gmag-webui, our gmag-webui.service, .env PORT=8082.  The
# nest has no magnetometer so the unit is DORMANT (not started) — assert the
# payload, not the listener.
GW=$($SSHN "qm guest exec $VMID --timeout 60 -- bash -lc '/usr/local/bin/deno --version 2>/dev/null | head -1; test -f /opt/git/sigmond/gmag-webui/ts/main.ts && echo CHECKOUT-OK; test -f /opt/git/sigmond/gmag-webui/.env && grep -q 8082 /opt/git/sigmond/gmag-webui/.env && echo ENV-OK; systemctl cat gmag-webui.service >/dev/null 2>&1 && echo UNIT-OK; id gmagweb >/dev/null 2>&1 && echo USER-OK'" 2>&1)
echo "$GW" | grep -q "deno [0-9]"   || { say "FATAL: pinned deno missing from VM"; echo "$GW" | head -4; exit 1; }
echo "$GW" | grep -q CHECKOUT-OK   || { say "FATAL: gmag-webui checkout missing from VM"; echo "$GW" | head -4; exit 1; }
echo "$GW" | grep -q ENV-OK        || { say "FATAL: gmag-webui .env (PORT=8082) missing"; echo "$GW" | head -4; exit 1; }
echo "$GW" | grep -q UNIT-OK       || { say "FATAL: gmag-webui.service not installed"; echo "$GW" | head -4; exit 1; }
echo "$GW" | grep -q USER-OK       || { say "FATAL: gmagweb service user missing"; echo "$GW" | head -4; exit 1; }
say "gmag-webui payload in VM: $(echo "$GW" | grep -o 'deno [0-9][^ ]*' | head -1) + checkout + .env + unit + user ✓"
say "── chrony refclocks: sigmond-site-timing converges on ONE drop-in"
# ⛔ The duplicate-refclock regression, exercised rather than assumed.
#
# hf-timestd's installer writes /etc/chrony/conf.d/timestd-refclocks.conf and
# retires a legacy chrony-timestd-refclocks.conf.  sigmond-site-timing used to
# copy the same source back under that legacy name, so chrony loaded
# `refclock SHM 1 FUSE` and `refclock SHM 2 HPPS` TWICE and the second copy of
# each sat at Reach 0 forever — it reads the same SHM segment after the first
# has consumed the sample.  Live on AC0G-ND 2026-09-03, hand-cleaned on B4
# 2026-08-16 without the code being fixed, so it recurred on every station
# built since.  7d5865a fixed it.
#
# ⚠ An earlier version of this check simply counted the drop-ins here and
# demanded exactly one.  It could never pass.  In the NEST there is no RX888,
# so `smd bringup` never writes /etc/radio/radiod@*.conf, so the wizard's
# relocation branch never reruns sigmond-site-timing, so NOTHING creates the
# drop-in and the count is 0.  hf-timestd's own installer does not create it
# either: with no station config in a golden template it stops after phase 4b
# ("Install partially complete — phases 5-8 deferred"), and the refclock block
# is phase 6.  So the assertion asserted a live-station post-condition in a
# hardware-free nest, and v3.37 failed on it — the first build to run it.
#
# Counting a file the environment cannot produce proves nothing.  Running the
# script that produces it proves the fix, and does so here, without hardware:
# plant the legacy duplicate exactly as an older image would have left it, run
# sigmond-site-timing, and require it to converge on one canonical file.
# The VM-side script echoes tokens rather than returning a file list: qm guest
# exec wraps stdout in JSON with escaped newlines, and every other check in
# this phase greps for tokens for exactly that reason.
RCSCRIPT='
set -u
CD=/etc/chrony/conf.d
echo "PRE:$(ls -1 $CD/*refclocks*.conf 2>/dev/null | wc -l)"
# Plant the legacy duplicate exactly as an older image would have left it.
install -m 0644 /opt/git/sigmond/hf-timestd/config/chrony-timestd-refclocks.conf \
        $CD/chrony-timestd-refclocks.conf || { echo "PLANT-FAILED"; exit 0; }
echo "PLANTED:$(ls -1 $CD/*refclocks*.conf 2>/dev/null | wc -l)"
# Run twice: once to converge, once to prove it stays converged (the sentinel
# reruns it after every bringup).
/usr/local/sbin/sigmond-site-timing >/dev/null 2>&1 || true
/usr/local/sbin/sigmond-site-timing >/dev/null 2>&1 || true
echo "ACTIVE:$(ls -1 $CD/*refclocks*.conf 2>/dev/null | wc -l)"
[ -f $CD/timestd-refclocks.conf ] && echo "CANON-OK"
[ -e $CD/chrony-timestd-refclocks.conf.legacy-disabled ] && echo "RETIRED-OK"
[ -e $CD/chrony-timestd-refclocks.conf ] && echo "LEGACY-STILL-ACTIVE"
true
'
RCOUT=$($SSHN "qm guest exec $VMID --timeout 600 -- bash -lc \"echo $(echo "$RCSCRIPT" | base64 -w0) | base64 -d | bash\"" 2>&1)
echo "$RCOUT" | grep -q "PLANT-FAILED" \
    && { say "FATAL: could not plant the legacy duplicate — check the source file in the VM"; echo "$RCOUT" | head -6; exit 1; }
# PRE is 1 in a passing run, not 0: the location-authority check above moves
# the station's position, and that path runs sigmond-site-timing, which writes
# the canonical drop-in.  So planting the legacy name on top reproduces AC0G-ND
# exactly — canonical AND legacy present together — which is a stronger start
# than an empty conf.d.  Either value is fine here; the assertions below are
# about what site-timing CONVERGES to, and PRE only says where it started.
say "refclock drop-ins: $(echo "$RCOUT" | grep -oE 'PRE:[0-9]+' | head -1) before -> $(echo "$RCOUT" | grep -oE 'PLANTED:[0-9]+' | head -1) with the legacy duplicate planted -> $(echo "$RCOUT" | grep -oE 'ACTIVE:[0-9]+' | head -1) after site-timing"
# Compare the NUMBER, not the string: `grep -q ACTIVE:1` also matches
# ACTIVE:10, which is the shape of the very failure this is here to catch.
RCACT=$(echo "$RCOUT" | grep -oE 'ACTIVE:[0-9]+' | head -1 | cut -d: -f2)
[ "${RCACT:-x}" = "1" ] \
    && say "site-timing converged on exactly one active refclock drop-in ✓" \
    || { say "FATAL: site-timing left ${RCACT:-?} active refclock drop-in(s) — the FUSE/HPPS duplicate is back"; \
         echo "$RCOUT" | head -8; \
         $SSHN "qm guest exec $VMID --timeout 30 -- bash -lc 'ls -l /etc/chrony/conf.d/'" 2>&1 | head -8; exit 1; }
echo "$RCOUT" | grep -q "CANON-OK" \
    && say "the surviving drop-in carries the canonical name ✓" \
    || { say "FATAL: canonical timestd-refclocks.conf absent after site-timing"; echo "$RCOUT" | head -8; exit 1; }
echo "$RCOUT" | grep -q "RETIRED-OK" \
    && say "the planted legacy duplicate was retired, not deleted ✓" \
    || { say "FATAL: site-timing did not retire the legacy duplicate"; echo "$RCOUT" | head -8; exit 1; }
echo "$RCOUT" | grep -q "LEGACY-STILL-ACTIVE" \
    && { say "FATAL: chrony-timestd-refclocks.conf is still an ACTIVE .conf — chrony would load FUSE/HPPS twice"; echo "$RCOUT" | head -8; exit 1; } \
    || say "legacy name no longer matches conf.d/*.conf ✓"

# ── the VM is reachable as a SERVICE, now that the wizard has run ──────────
# This is where the Scranton failure mode would actually show: the hypervisor
# able to configure the VM but unable to open a socket to it.  Phase C checks
# the LINK (ping); only here, after the wizard has set the ssh policy, does
# port 22 mean anything.
_sshok=0
for i in $(seq 1 18); do
  $SSHN "timeout 3 bash -c 'echo >/dev/tcp/10.99.0.2/22'" 2>/dev/null && { _sshok=1; break; }
  sleep 10
done
[ "$_sshok" = 1 ] && say "host can open TCP 22 to the VM at 10.99.0.2 ✓" \
  || { say "FATAL: VM ssh unreachable at 10.99.0.2 after the wizard"
       $SSHN "qm guest exec $VMID -- /bin/bash -c 'ss -ltn; systemctl is-active ssh'"; exit 1; }
# And the forwards the operator will actually use must answer through the host.
$SSHN "timeout 5 bash -c 'echo >/dev/tcp/127.0.0.1/2222'" 2>/dev/null \
  && say "host:2222 -> VM:22 forward works ✓" \
  || say "WARN: host:2222 forward did not answer (VM ssh is up, DNAT may need a hairpin route)"

# ── ONE bring-up ran, not two ─────────────────────────────────────────────
# The wizard used to launch its own `smd bringup` in a transient unit while
# sigmond-firstrun-bringup.service could be running the same thing, with no
# mutual exclusion.  Both contend for the lifecycle lock and the loser does
# not wait -- it FAILS the step.  On AI6VN (v3.50, 2026-09-21) that cost ten
# consecutive `smd install` steps and the station came up without ka9q-web,
# while every surface still reported a successful install.
#
# Assert the OUTCOME, not the implementation: no step may have died on the
# lock.  A future refactor that reintroduces a second bring-up by some other
# route fails here too, which a check for the old unit name would not.
say "checking that bring-up did not fight itself for the lifecycle lock"
BUOUT=$($SSHN "qm guest exec $VMID --timeout 60 -- bash -lc '
    L=/var/log/sigmond/firstrun-bringup.log
    [ -r \$L ] || { echo NOLOG; exit 0; }
    echo LOCKHITS:\$(grep -ci \"lifecycle lock held\" \$L 2>/dev/null)
    echo STEPFAIL:\$(grep -c \"step exited [1-9]\" \$L 2>/dev/null)
    systemctl is-active sigmond-wizard-bringup.service 2>/dev/null \
        | sed \"s/^/TRANSIENT:/\"
'" 2>&1)
case "$BUOUT" in
  *NOLOG*) say "WARN: no firstrun-bringup.log in the VM — bring-up may not have run at all" ;;
  *)
    _lh=$(echo "$BUOUT" | grep -oE 'LOCKHITS:[0-9]+' | head -1 | cut -d: -f2)
    _sf=$(echo "$BUOUT" | grep -oE 'STEPFAIL:[0-9]+' | head -1 | cut -d: -f2)
    [ "${_lh:-0}" = "0" ] \
        && say "no step lost the lifecycle lock ✓" \
        || { say "FATAL: ${_lh} bring-up step(s) failed on 'lifecycle lock held' —"
             say "  two bring-ups ran concurrently; this is the AI6VN race."
             $SSHN "qm guest exec $VMID --timeout 30 -- bash -lc 'grep -i \"lifecycle lock held\" /var/log/sigmond/firstrun-bringup.log | head -5'" 2>&1
             exit 1; }
    [ "${_sf:-0}" = "0" ] \
        && say "every bring-up step exited 0 ✓" \
        || say "WARN: ${_sf} bring-up step(s) exited non-zero for other reasons — check the log"
    echo "$BUOUT" | grep -q 'TRANSIENT:active' \
        && say "WARN: the retired sigmond-wizard-bringup transient unit is running" \
        || say "no second bring-up unit was created ✓"
    ;;
esac

# ── did the station actually WIRE ITSELF UP? ───────────────────────────────
# ⛔ Phase D used to end here, and everything above is satisfied by a station
# that installs cleanly and MEASURES NOTHING.  That is not hypothetical: the
# wizard runs sigmond-site-timing before bring-up exists, its step 3 skips,
# and the station ends with ZERO timestd-metrology@ units, fusion reading
# "0 entries from 6 channels", no T3 -- every unit green.  B4 ran that way
# from its reflash until 2026-09-23; rob's v3.53 lab station did the same.
# v3.54 fixes it (sigmond af5aba3, re-running the wiring after bring-up), and
# until this block existed the fix was proven only by hand, on one station.
#
# ⚠ It also repairs a weakness in the checks ABOVE.  "no step lost the
# lifecycle lock ✓" is trivially true of a bring-up that ran for five seconds
# and got nowhere -- a pass that means nothing.  So establish COMPLETION
# first, and make every claim conditional on it.
# ── the guest agent, part 1: does this image's panel carry the fix? ─────────
# Asked once, before bring-up, because the first check must run WHILE the
# station builds.  An image from before v3.71 (the update rig's base) carries
# no parser reset; every guest-agent check then says so and judges nothing.
QGA_PF=$(qga_probe_panel | $SSHN "bash -s" 2>&1)
QGA_PANELFIX=$(rr_tok PANELFIX "$QGA_PF")
QGA_BUILD=""; QGA_UNCHECKED=""
if [ "${QGA_PANELFIX:-0}" != 1 ]; then
    say "⚠ GUEST-AGENT CHECKS NOT EVALUATED — this image's panel predates v3.71"
    QGA_UNCHECKED="all of them (this image's panel carries no parser reset)"
fi

say "waiting for first-run bring-up to COMPLETE (its marker), up to ${BRINGUP_WAIT_MIN:-25} min"
_done=0
for _i in $(seq 1 $(( ${BRINGUP_WAIT_MIN:-25} * 4 )) ); do
    $SSHN "qm guest exec $VMID --timeout 30 -- /bin/bash -c 'test -e /var/lib/sigmond/.firstrun-bringup-done'" 2>/dev/null \
        | grep -q '"exitcode" : 0' && { _done=1; break; }
    # Thirty seconds into the wait, once: one panel refresh while bring-up
    # runs, and what the panel then says (judged below the loop).
    if [ "$_i" = 2 ] && [ "${QGA_PANELFIX:-0}" = 1 ]; then
        QGA_BUILD=$(qga_probe_bringup | $SSHN "bash -s $VMID" 2>&1)
    fi
    [ $(( _i % 8 )) -eq 0 ] && say "  … still bringing up ($(( _i / 4 )) min)"
    sleep 15
done

# ── the guest agent, part 2: what the panel said while the station built ───
# Judged only when the bring-up unit ran through the whole refresh: a unit
# that ended meanwhile leaves the panel free to say either thing.
if [ "${QGA_PANELFIX:-0}" = 1 ]; then
    if nh_ok "$QGA_BUILD" && [ "$(rr_tok UNIT "$QGA_BUILD")" = activating/activating ]; then
        [ "$(rr_tok BUILDING "$QGA_BUILD")" = 1 ] \
            || qga_fatal "bring-up ran through a whole panel refresh, and the panel did not say STATION IS STILL BUILDING: its status request does not run, or its answer is not read" "$QGA_BUILD"
        [ "$(rr_tok NOWEB "$QGA_BUILD")" = 0 ] \
            || qga_fatal "the panel raised BRING-UP FINISHED BUT ka9q-web IS NOT RUNNING while bring-up still ran" "$QGA_BUILD"
        say "while the station built, the panel said so and raised no alarm ✓"
    else
        say "⚠ the panel's line DURING bring-up was not evaluated (the unit read '$(rr_tok UNIT "$QGA_BUILD")' around the refresh, not activating/activating)"
        QGA_UNCHECKED="${QGA_UNCHECKED:+$QGA_UNCHECKED; }the panel's line during bring-up"
    fi
fi

if [ "$_done" != 1 ]; then
    # NOT a FATAL: the nested guest has no RX888 and is slower than iron, so a
    # long bring-up is plausible.  But say plainly that nothing below was
    # checked -- an unevaluated assertion reported as silence is how the
    # original defect survived.
    say "WARN: bring-up did not finish within ${BRINGUP_WAIT_MIN:-25} min"
    say "  ⚠ THE METROLOGY ASSERTION WAS NOT EVALUATED — this run does not"
    say "    show whether the station wires its timing chain."
    [ "${SINKWIZ:-0}" = 1 ] && say "  ⚠ THE SITE SINK MANIFEST AND smd sink upload CHECKS WERE NOT EVALUATED either."
    [ "${SINKWIZ:-0}" = 1 ] && sink_unchecked "the switch files, the carry-over marker, the gate render, the levers of smd sink fill (or, on the base image, the manifest banner and per-pipeline discard), wspr-recorder's in-process sender and smd sink upload (bring-up did not finish)"
    say "  ⚠ THE v3.70 SINK FOUNDATION CHECKS WERE NOT EVALUATED either."
    sink_unchecked "the v3.70 sink foundation: send-record version, psk-recorder's sink writer, sink.db columns (bring-up did not finish)"
else
    say "bring-up completed (marker present)"
    if [ "${SINKWIZ:-0}" = 1 ]; then
        # Step 2b part 2 (sigmond tasks/spec-sink-2b-part2.md §13.1).  An
        # hs-uploader that offers `gate` reads the switch files under
        # /etc/hs-uploader/sinks/, so the manifest step carries [uploads] over
        # into them, writes the carry-over marker, renders no discard and no
        # banner, and moves the heartbeat to pipelines.d/sigmond.toml.  The
        # readers live in the sink_part2 block (test-nested-sink-part2.sh feeds
        # them real output).  Only the update rig's base image, which predates
        # part 2, may lack gate; it takes part 1's banner and discard checks.
        say "verifying the switch files, the carry-over marker and the gate render"
        SP2D=$(mktemp -d)
        sp2_gx 180 "$(sp2_probe_script)" "$SP2D/probe.raw"
        sp2_unwrap "$SP2D/probe.raw" "$SP2D/probe.txt" \
            || { say "FATAL: the switch probe returned no answer (guest exec failed, not a verdict)"; head -6 "$SP2D/probe.raw"; exit 1; }
        sp2_facts "$SP2D/probe.txt" > "$SP2D/probe.facts"
        [ "$(sp2_tok "$SP2D/probe.facts" END)" = 1 ] \
            || { say "FATAL: the switch probe returned no answer (guest exec failed, not a verdict)"; tail -6 "$SP2D/probe.txt"; exit 1; }
        say "  hs-uploader features: $(sp2_tok "$SP2D/probe.facts" F_WORDS)"
        if [ "$(sp2_tok "$SP2D/probe.facts" F_GATE)" = 1 ] || [ "${SINK_BASE_IMAGE:-0}" != 1 ]; then
            SP2=1
            sp2_verdict "$SP2D/probe.facts" > "$SP2D/probe.verdict"
            sp2_report "$SP2D/probe.verdict" "$SP2D/probe.txt"
            say "site switch off, the marker, gate, no discard, the heartbeat in sigmond.toml, each client's own file at upload (unless NOT EVALUATED above) ✓"
        else
            SP2=0
            say "this base image's hs-uploader offers no gate: part 1's manifest checks follow"
            # The manifest shows what hs-uploader will do.  Its banner names the mode
            # it rendered: SITE SINK OFF, or the legacy hold that an hs-uploader too
            # old to discard falls back to.  Every [[pipeline]] but the heartbeat
            # must carry discard = true.
            DISC=$($SSHN "qm guest exec $VMID --timeout 30 -- bash -lc '
                M=/etc/hs-uploader/pipelines.toml
                [ -r \$M ] || { echo NOMANIFEST; exit 0; }
                echo BANNER:\$(grep -c \"SITE SINK OFF\" \$M)
                echo PIPES:\$(grep -c \"^\\[\\[pipeline\\]\\]\" \$M)
                echo HB:\$(grep -c \"^name = .heartbeat.\" \$M)
                echo DISC:\$(grep -c \"^discard = true\" \$M)
            '" 2>&1)
            _b=$(echo "$DISC" | grep -oE 'BANNER:[0-9]+' | head -1 | cut -d: -f2)
            _p=$(echo "$DISC" | grep -oE 'PIPES:[0-9]+'  | head -1 | cut -d: -f2)
            _h=$(echo "$DISC" | grep -oE 'HB:[0-9]+'     | head -1 | cut -d: -f2)
            _d=$(echo "$DISC" | grep -oE 'DISC:[0-9]+'   | head -1 | cut -d: -f2)
            case "$DISC" in
              *NOMANIFEST*) say "FATAL: no /etc/hs-uploader/pipelines.toml after a completed bring-up"; exit 1 ;;
            esac
            [ -n "$_b" ] && [ -n "$_p" ] && [ -n "$_h" ] && [ -n "$_d" ] \
                || { say "FATAL: the manifest probe returned no answer (guest exec failed, not a verdict)"; echo "$DISC" | head -6; exit 1; }
            [ "$_b" -ge 1 ] \
                || { say "FATAL: pipelines.toml does not render SITE SINK OFF while the site sink switch reads off"
                     say "  (an hs-uploader that cannot discard makes sigmond render the legacy hold)"; exit 1; }
            _data=$(( _p - _h ))
            if [ "$_data" -eq 0 ]; then
                say "WARN: the manifest renders SITE SINK OFF but holds no data pipeline in this nest;"
                say "  the per-pipeline discard = true was NOT evaluated"
                sink_unchecked "per-pipeline discard = true and its release by smd sink upload (the nest's manifest holds only the heartbeat)"
            elif [ "$_d" -eq "$_data" ]; then
                say "all ${_data} data pipeline(s) render discard = true while the site sink switch reads off ✓"
            else
                say "FATAL: ${_d} of ${_data} data pipeline(s) carry discard = true"; exit 1
            fi
        fi
        # wspr-recorder runs its own in-process sender when its environment
        # carries WD_RECEIVER_GRID (wspr_recorder/hs_uploader_shim.py from_env),
        # and the site sink switch does not govern that sender.  A fresh station
        # keeps it off only because nothing writes the variable.  Count it in
        # both files wspr-recorder@.service loads: every instance env, and
        # coordination.env.  A missing file counts 0.
        WDG=$($SSHN "qm guest exec $VMID --timeout 30 -- bash -lc '
            echo WSPRENVS:\$(ls -1 /etc/wspr-recorder/env/*.env 2>/dev/null | wc -l)
            echo WDGRID:\$(cat /etc/wspr-recorder/env/*.env /etc/sigmond/coordination.env 2>/dev/null | grep -cE \"^[[:space:]]*WD_RECEIVER_GRID=\")
        '" 2>&1)
        _we=$(echo "$WDG" | grep -oE 'WSPRENVS:[0-9]+' | head -1 | cut -d: -f2)
        _wg=$(echo "$WDG" | grep -oE 'WDGRID:[0-9]+'   | head -1 | cut -d: -f2)
        [ -n "$_we" ] && [ -n "$_wg" ] \
            || { say "FATAL: the wspr-recorder env probe returned no answer (guest exec failed, not a verdict)"; echo "$WDG" | head -4; exit 1; }
        [ "$_wg" = 0 ] \
            || { say "FATAL: ${_wg} WD_RECEIVER_GRID line(s) in wspr-recorder's environment:"
                 say "  wspr-recorder's in-process sender is armed; the site sink switch does not govern it"; exit 1; }
        if [ "$_we" = 0 ]; then
            say "WARN: no wspr-recorder instance env in this nest; its in-process sender was NOT evaluated"
            sink_unchecked "wspr-recorder's in-process sender (this nest wrote no wspr-recorder instance env)"
        else
            say "no WD_RECEIVER_GRID in ${_we} wspr-recorder instance env(s) or coordination.env: its in-process sender stays off ✓"
        fi
        if [ "${SP2:-0}" = 1 ]; then
            # The levers (§13.1): plant what `smd sink fill` must lower, then
            # lower the site to fill.  Each lever must land, each touched unit
            # restart once (ActiveEnterTimestampMonotonic, and its journal's
            # "Started" lines since the fill began), every other unit and
            # radiod keep their start time.  `smd sink upload` below raises
            # the site again; raising restores no lever (spec §8.2).
            say "── the levers: plant in-process senders, then smd sink fill --reason rig"
            sp2_gx 300 "$(sp2_plant_script)" "$SP2D/plant.raw"
            sp2_unwrap "$SP2D/plant.raw" "$SP2D/plant.txt" \
                || { say "FATAL: the plant probe returned no answer (guest exec failed, not a verdict)"; head -6 "$SP2D/plant.raw"; exit 1; }
            sed 's/^/      plant| /' "$SP2D/plant.txt" | tail -24
            sp2_gx 120 "$(sp2_state_script before)" "$SP2D/before.raw"
            sp2_unwrap "$SP2D/before.raw" "$SP2D/before.txt" \
                || { say "FATAL: the start-time probe returned no answer (guest exec failed, not a verdict)"; head -6 "$SP2D/before.raw"; exit 1; }
            sp2_gx 900 "$SP2_FILL" "$SP2D/fill.raw"
            sp2_unwrap "$SP2D/fill.raw" "$SP2D/fill.txt" \
                || { say "FATAL: smd sink fill returned no answer (guest exec failed, not a verdict)"; head -6 "$SP2D/fill.raw"; exit 1; }
            sed 's/^/      fill| /' "$SP2D/fill.txt" | tail -30
            sp2_fill_facts "$SP2D/fill.txt" > "$SP2D/fill.facts"
            sp2_gx 120 "$(sp2_state_script after)" "$SP2D/after.raw"
            sp2_unwrap "$SP2D/after.raw" "$SP2D/after.txt" \
                || { say "FATAL: the start-time probe after the fill returned no answer (guest exec failed, not a verdict)"; head -6 "$SP2D/after.raw"; exit 1; }
            sp2_lever_verdict "$SP2D/plant.txt" "$SP2D/before.txt" "$SP2D/fill.facts" "$SP2D/after.txt" > "$SP2D/lever.verdict"
            # Undo the plant before judging, so a FATAL leaves no residue
            # either.  What cannot be undone is said before later phases run.
            sp2_gx 300 "$(sp2_unplant_script)" "$SP2D/unplant.raw"
            if sp2_unwrap "$SP2D/unplant.raw" "$SP2D/unplant.txt" && [ "$(sp2_tok "$SP2D/unplant.txt" END)" = 1 ]; then
                sed 's/^/      unplant| /' "$SP2D/unplant.txt" | tail -24
                say "the plant undone: edited files restored, invented instances stopped and removed, stand-in drop-ins gone"
                say "  (a PLANT RESIDUE line below names any undo step that failed);"
                say "  switch files the plant made for disabled clients stay, at upload"
                while IFS='|' read -r _ _sp2w _sp2rc; do
                    say "⚠ PLANT RESIDUE: the undo step '$_sp2w' failed (exit $_sp2rc); later phases see what it left"
                done < <(grep '^RESIDUE|' "$SP2D/unplant.txt")
            else
                say "⚠ PLANT RESIDUE: the undo probe returned no answer; the planted instances, stand-in drop-ins"
                say "  and edited env/config files (lever values in place) remain for the phases below"
            fi
            sp2_report "$SP2D/lever.verdict" "$SP2D/after.txt"
            say "smd sink fill: the carry-over wrote every enabled client's switch file; each lever it could reach written, each unit it named restarted once, nothing else moved ✓"
        fi
    fi
    MET=$($SSHN "qm guest exec $VMID --timeout 60 -- bash -lc '
        L=/var/log/sigmond/firstrun-bringup.log
        echo WIRED:\$(grep -c \"re-running site wiring\" \$L 2>/dev/null)
        echo COUNT:\$(systemctl list-units \"timestd-metrology@*\" --no-legend --plain 2>/dev/null | wc -l)
        echo ENVS:\$(ls -1 /etc/hf-timestd/metrology-channels/ 2>/dev/null | wc -l)
        echo SDRDEV:\$(grep -l 04b4 /sys/bus/usb/devices/*/idVendor 2>/dev/null | wc -l)
        echo RADIODSTEP:\$(grep -c \"step exited [1-9]: .*config init radiod\" \$L 2>/dev/null)
        echo RADIODCHK:\$(grep -c \"checkpoint: radiod configured FAILED\" \$L 2>/dev/null)
        echo OTHERCHK:\$(grep \"checkpoint: .* FAILED\" \$L 2>/dev/null | grep -vc \"radiod configured\")
        echo OTHERSTEP:\$(grep \"step exited [1-9]\" \$L 2>/dev/null | grep -v \"config init radiod\" | grep -vc sigmond-sdr-recover)
        echo NOSDRMSG:\$(grep -c \"no recognised SDRs detected\" \$L 2>/dev/null)
        echo AWAITSDR:\$(grep -c \"^result=awaiting-sdr\" /var/lib/sigmond/.firstrun-bringup-done 2>/dev/null)
    '" 2>&1)
    _w=$(echo "$MET" | grep -oE 'WIRED:[0-9]+' | head -1 | cut -d: -f2)
    _c=$(echo "$MET" | grep -oE 'COUNT:[0-9]+' | head -1 | cut -d: -f2)
    _e=$(echo "$MET" | grep -oE 'ENVS:[0-9]+'  | head -1 | cut -d: -f2)
    [ "${_w:-0}" -gt 0 ] \
        && say "site wiring re-ran after bring-up ✓" \
        || say "WARN: no 're-running site wiring' line — is this image older than sigmond af5aba3?"
    _v=$(phase_d_verdict "$MET")
    if [ "$_v" = METROLOGY_OK ]; then
        say "metrology channels running: ${_c} (channel envs: ${_e:-?}) ✓"
    elif [ "$_v" = NO_SDR_EXPECTED ]; then
        say "no SDR on the guest's USB bus; bring-up deferred the radio half for"
        say "  exactly that reason, and no other step or checkpoint failed ✓"
        say "  ⚠ THE METROLOGY ASSERTION WAS NOT EVALUATED — this nest has no RX888."
        say "    Prove metrology on hardware (B4) before rolling this image."
    else
        say "FATAL: ZERO timestd-metrology@ units after a completed bring-up."
        say "  The station installed cleanly and measures nothing — the exact"
        say "  defect v3.54 exists to close. Do not ship this image."
        $SSHN "qm guest exec $VMID --timeout 30 -- bash -lc 'tail -20 /var/log/sigmond/firstrun-bringup.log; ls -la /etc/hf-timestd/ 2>&1'" 2>&1
        exit 1
    fi

    if [ "${SINKWIZ:-0}" = 1 ]; then
        # Show that `smd sink upload` works as root in the image and leaves no
        # pipeline discarding.  The nest has no RX888, so nothing real ships.
        # Read the switch back from `smd sink status`, never from the command's
        # own success line ("site sink: upload — every data pipeline is back in
        # the manifest").  Read the manifest back too: policy_banner returns
        # nothing in upload mode, so BANNEROFF:0 shows the manifest was
        # regenerated even when it holds no data pipeline.
        say "raising the site sink switch: smd sink upload"
        UP=$($SSHN "qm guest exec $VMID --timeout 120 -- bash -lc 'smd sink upload 2>&1; M=/etc/hs-uploader/pipelines.toml; echo DISCLEFT:\$(grep -c \"^discard = true\" \$M); echo BANNEROFF:\$(grep -c \"SITE SINK OFF\" \$M); echo PIPES:\$(grep -c \"^\\[\\[pipeline\\]\\]\" \$M); echo HB:\$(grep -c \"^name = .heartbeat.\" \$M); smd sink status 2>&1'" 2>&1)
        echo "$UP" | tail -12
        case "$UP" in
          *"refusing while packaging runs"*)
            say "WARN: smd sink upload refused because GRAPE or magnetometer packaging ran in the nest;"
            say "  raising the switch was NOT evaluated"
            sink_unchecked "smd sink upload (it refused while packaging ran in the nest)" ;;
          *)
            _dl=$(echo "$UP" | grep -oE 'DISCLEFT:[0-9]+'  | head -1 | cut -d: -f2)
            _bo=$(echo "$UP" | grep -oE 'BANNEROFF:[0-9]+' | head -1 | cut -d: -f2)
            _up=$(echo "$UP" | grep -oE 'PIPES:[0-9]+'     | head -1 | cut -d: -f2)
            _uh=$(echo "$UP" | grep -oE 'HB:[0-9]+'        | head -1 | cut -d: -f2)
            [ -n "$_dl" ] && [ -n "$_bo" ] && [ -n "$_up" ] && [ -n "$_uh" ] \
                || { say "FATAL: the smd sink upload probe returned no answer (guest exec failed, not a verdict)"; exit 1; }
            [ "$_dl" = 0 ] || { say "FATAL: ${_dl} pipeline(s) still carry discard = true after smd sink upload"; exit 1; }
            [ "$_bo" = 0 ] || { say "FATAL: pipelines.toml still renders SITE SINK OFF after smd sink upload; the manifest was not regenerated"; exit 1; }
            echo "$UP" | grep -qF "$SP2_UPLOAD_PHRASE" \
                || { say "FATAL: smd sink status does not report upload after smd sink upload"; exit 1; }
            if [ "${SP2:-0}" = 1 ]; then
                say "smd sink upload raised the site sink switch; the gate form renders no discard ✓"
            elif [ "$_up" -eq "$_uh" ]; then
                say "smd sink upload raised the site sink switch; no pipeline discards (the manifest holds only the heartbeat in this nest, so no data pipeline was released)"
                sink_unchecked "per-pipeline discard = true and its release by smd sink upload (the nest's manifest holds only the heartbeat)"
            else
                say "smd sink upload raised the site sink switch; no pipeline discards ✓"
            fi ;;
        esac
    fi

    # ── the v3.70 sink foundation ───────────────────────────────────────────
    # Three facts about the image's sink code (tasks/plan-sink-control.md §10.4):
    #   1. bring-up ran `hs-uploader migrate`, and watermarks.db now sits at
    #      this release's schema version with nothing pending (D10);
    #   2. psk-recorder's venv writes through hs-uploader's writer, not
    #      sigmond's bundled copy (D14);
    #   3. a sink.db that holds pending_uploads carries producer and local (D12).
    # This runs after `smd sink upload`, whose manifest write runs migrate too.
    # On a fresh install bring-up's migrate can meet no watermarks.db at all:
    # the daemon creates its store on its first start, after that migrate, and
    # migrate never creates one.  The bring-up log says which happened.
    #
    # test-update-v3.sh runs these phases on the PREVIOUS blessed image, whose
    # hs-uploader has no `migrate`.  Only that run, with SINK_BASE_IMAGE=1, may
    # skip these checks; anywhere else such an image FATALs, for the reason the
    # SINKWIZ gate gives.  One KEY:N token per fact, as above.
    say "── v3.70 sink foundation: the send-record version, psk-recorder's sink writer, sink.db's columns"
    F70SCRIPT=$(cat <<'F70EOF'
set -u
export PYTHONDONTWRITEBYTECODE=1
EXE=/opt/hs-uploader/venv/bin/hs-uploader
W=/var/lib/hs-uploader/watermarks.db
L=/var/log/sigmond/firstrun-bringup.log
PSKPY=/opt/git/sigmond/psk-recorder/venv/bin/python3
S=/var/lib/sigmond/sink.db
[ -x "$EXE" ] || { echo "HSUEXE:0"; exit 0; }
echo "HSUEXE:1"
# 1. The send-record version, read as hsupload (the store's owner and the
#    daemon's user) from the unit's working directory.  An hs-uploader that
#    predates v3.70 answers "invalid choice: 'migrate'".
o=$(cd /opt/hs-uploader && runuser -u hsupload -- /usr/bin/env PYTHONDONTWRITEBYTECODE=1 "$EXE" migrate --check --db "$W" 2>&1)
rc=$?
printf '%s\n' "$o" | head -6 | sed 's/^/migrate-check| /'
if printf '%s\n' "$o" | grep -q "invalid choice: 'migrate'"; then echo "MIGCLI:0"; exit 0; fi
echo "MIGCLI:1"
echo "MIGRC:$rc"
echo "MIGVER:$(printf '%s\n' "$o" | sed -n 's/^watermarks\.db: version \([0-9][0-9]*\)$/\1/p' | head -1)"
echo "MIGPEND:$(printf '%s\n' "$o" | grep -c '^  pending ')"
echo "MIGNEWER:$(printf '%s\n' "$o" | grep -c 'newer than this hs-uploader')"
echo "MIGNOSTORE:$(printf '%s\n' "$o" | grep -c '^watermarks\.db: not found at ')"
# What bring-up's own migrate reported.  Bring-up's manifest step prints
# migrate's lines, and firstrun-bringup.log takes every step's output.
if [ -r "$L" ]; then
    echo "BULOG:1"
    echo "BULOGV:$(grep -c 'watermarks\.db: version [0-9]' "$L")"
    echo "BULOGNF:$(grep -c 'watermarks\.db: not found at ' "$L")"
else
    echo "BULOG:0"
fi
# 2. The writer psk-recorder's venv imports.  -B: write no bytecode into the
#    checkouts as root.
if [ -x "$PSKPY" ]; then
    echo "PSKVENV:1"
    io=$(cd / && "$PSKPY" -B -c "import sigmond.hamsci_sink as s; print(s.SINK_IMPL)" 2>&1)
    echo "IMPLRC:$?"
    echo "IMPLHS:$(printf '%s\n' "$io" | grep -cx 'hs_uploader')"
    echo "IMPLBUN:$(printf '%s\n' "$io" | grep -cx 'bundled')"
    printf '%s\n' "$io" | tail -3 | sed 's/^/sink-impl| /'
else
    echo "PSKVENV:0"
fi
# 3. sink.db's columns, read-only.  Bring-up creates sink.db as an empty
#    file; pending_uploads appears only once a writer opens it.
if [ -e "$S" ]; then
    echo "SINKDB:1"
    python3 -B - "$S" 2>&1 <<'PY'
import pathlib, sqlite3, sys
try:
    p = pathlib.Path(sys.argv[1]).resolve()
    c = sqlite3.connect(p.as_uri() + "?mode=ro", uri=True, timeout=10)
    n = c.execute("SELECT count(*) FROM sqlite_master WHERE type = 'table' "
                  "AND name = 'pending_uploads'").fetchone()[0]
    print("SINKTAB:%d" % (1 if n else 0))
    if n:
        cols = {r[1] for r in c.execute("PRAGMA table_info(pending_uploads)")}
        print("SINKPROD:%d" % ("producer" in cols))
        print("SINKLOCAL:%d" % ("local" in cols))
except Exception as exc:
    print("sink-read| %s: %s" % (type(exc).__name__, exc))
PY
else
    echo "SINKDB:0"
fi
exit 0
F70EOF
)
    F70=$($SSHN "qm guest exec $VMID --timeout 120 -- bash -lc \"echo $(printf '%s\n' "$F70SCRIPT" | base64 -w0) | base64 -d > /tmp/sig-f70.sh; bash /tmp/sig-f70.sh\"" 2>&1)
    echo "$F70" | tail -12
    _f70(){ echo "$F70" | grep -oE "$1:[0-9]+" | head -1 | cut -d: -f2; }
    _hx=$(_f70 HSUEXE); _mcli=$(_f70 MIGCLI)
    [ -n "$_hx" ] || { say "FATAL: the v3.70 sink foundation probe returned no answer (guest exec failed, not a verdict)"; echo "$F70" | head -6; exit 1; }
    [ "$_hx" = 1 ] || { say "FATAL: no /opt/hs-uploader/venv/bin/hs-uploader after a completed bring-up"; exit 1; }
    [ -n "$_mcli" ] || { say "FATAL: the hs-uploader migrate probe returned no answer (not a verdict)"; echo "$F70" | head -6; exit 1; }
    if [ "$_mcli" = 0 ]; then
        if [ "${SINK_BASE_IMAGE:-0}" != 1 ]; then
            say "FATAL: the image under test has no hs-uploader migrate (its hs-uploader predates v3.70)"
            say "  only the update rig's base image may lack it; test-update-v3.sh sets SINK_BASE_IMAGE=1 for that run"
            exit 1
        fi
        say "⚠ v3.70 SINK FOUNDATION ASSERTIONS NOT EVALUATED — this image's hs-uploader has no"
        say "  migrate (pre-v3.70); expected only on the update rig's base image"
        sink_unchecked "the v3.70 sink foundation (this image's hs-uploader has no migrate; it predates v3.70)"
    else
        # 1. the send-record version, and bring-up's own migrate
        _mrc=$(_f70 MIGRC); _mver=$(_f70 MIGVER); _mpend=$(_f70 MIGPEND)
        _mnew=$(_f70 MIGNEWER); _mnone=$(_f70 MIGNOSTORE)
        _bl=$(_f70 BULOG); _blv=$(_f70 BULOGV); _blnf=$(_f70 BULOGNF)
        [ -n "$_mrc" ] && [ -n "$_mpend" ] && [ -n "$_mnew" ] && [ -n "$_mnone" ] && [ -n "$_bl" ] \
            || { say "FATAL: the send-record version probe returned no answer (not a verdict)"; echo "$F70" | head -6; exit 1; }
        [ "$_mrc" = 0 ] || { say "FATAL: hs-uploader migrate --check exited $_mrc"; echo "$F70" | head -6; exit 1; }
        if [ "$_bl" = 1 ]; then
            [ -n "$_blv" ] && [ -n "$_blnf" ] \
                || { say "FATAL: the bring-up log probe returned no answer (not a verdict)"; exit 1; }
            if [ "$_blv" -ge 1 ]; then
                say "bring-up's manifest step ran hs-uploader migrate on the store ✓"
            elif [ "$_blnf" -ge 1 ]; then
                say "bring-up's manifest step ran hs-uploader migrate before the daemon had created its store ✓"
            else
                say "FATAL: firstrun-bringup.log carries no 'watermarks.db:' line: bring-up never ran hs-uploader migrate (D10)"; exit 1
            fi
        else
            say "WARN: no firstrun-bringup.log in the VM; bring-up's own migrate was NOT evaluated"
            sink_unchecked "bring-up's own hs-uploader migrate (no firstrun-bringup.log)"
        fi
        # Did a manifest write run migrate after bring-up?  smd sink upload's
        # did, unless it refused while packaging ran.
        _later=0
        if [ "${SINKWIZ:-0}" = 1 ]; then
            case "${UP:-}" in *"refusing while packaging runs"*) ;; *) _later=1 ;; esac
        fi
        if [ "$_mnone" -ge 1 ]; then
            say "WARN: no watermarks.db: the daemon has not created its store, so the send-record version was NOT evaluated"
            sink_unchecked "the send-record version (no watermarks.db: the daemon has not created its store)"
        elif [ -z "$_mver" ]; then
            say "FATAL: hs-uploader migrate --check printed no 'watermarks.db: version N' line"; echo "$F70" | head -6; exit 1
        elif [ "$_mnew" -ge 1 ]; then
            say "FATAL: watermarks.db reads version $_mver, newer than this image's hs-uploader knows"; exit 1
        elif [ "$_mpend" = 0 ] && [ "$_mver" -ge 1 ]; then
            say "watermarks.db at version $_mver with nothing pending (hs-uploader migrate --check) ✓"
        elif [ "$_later" = 0 ] && [ "$_bl" = 0 ]; then
            say "WARN: watermarks.db reads version $_mver with $_mpend migration(s) pending.  No bring-up log"
            say "  says why, and smd sink upload ran no migrate, so the version was NOT evaluated"
            sink_unchecked "the send-record version (no bring-up log, and smd sink upload ran no migrate)"
        elif [ "$_later" = 0 ] && [ "$_blv" = 0 ] && [ "$_blnf" -ge 1 ]; then
            say "WARN: watermarks.db reads version $_mver with $_mpend migration(s) pending.  Bring-up's migrate"
            say "  ran before the daemon created the store, and smd sink upload ran no migrate, so the version"
            say "  was NOT evaluated"
            sink_unchecked "the send-record version (bring-up's migrate ran before the daemon created watermarks.db, and smd sink upload ran no migrate)"
        else
            say "FATAL: watermarks.db reads version $_mver with $_mpend migration(s) pending; neither bring-up"
            say "  nor a later manifest write brought it to this release's version (D10)"; exit 1
        fi
        # 2. psk-recorder's sink writer
        _pv=$(_f70 PSKVENV)
        [ -n "$_pv" ] || { say "FATAL: the psk-recorder sink writer probe returned no answer (not a verdict)"; exit 1; }
        if [ "$_pv" = 0 ]; then
            say "WARN: no psk-recorder venv in this nest; its sink writer was NOT evaluated"
            sink_unchecked "psk-recorder's sink writer (no psk-recorder venv in this nest)"
        else
            _irc=$(_f70 IMPLRC); _ihs=$(_f70 IMPLHS); _ibn=$(_f70 IMPLBUN)
            [ -n "$_irc" ] && [ -n "$_ihs" ] && [ -n "$_ibn" ] \
                || { say "FATAL: the psk-recorder sink writer probe returned no answer (not a verdict)"; exit 1; }
            [ "$_irc" = 0 ] || { say "FATAL: importing sigmond.hamsci_sink in psk-recorder's venv exited $_irc"; echo "$F70" | head -6; exit 1; }
            if [ "$_ihs" = 1 ]; then
                say "psk-recorder's venv writes through hs_uploader.sink (SINK_IMPL = hs_uploader) ✓"
            elif [ "$_ibn" = 1 ]; then
                say "FATAL: psk-recorder's venv fell back to sigmond's bundled writer (SINK_IMPL = bundled):"
                say "  the hs-uploader in that venv has no hs_uploader.sink"; exit 1
            else
                say "FATAL: sigmond.hamsci_sink.SINK_IMPL printed neither hs_uploader nor bundled"; echo "$F70" | head -6; exit 1
            fi
        fi
        # 3. sink.db's columns
        _sdb=$(_f70 SINKDB)
        [ -n "$_sdb" ] || { say "FATAL: the sink.db probe returned no answer (not a verdict)"; exit 1; }
        if [ "$_sdb" = 0 ]; then
            say "WARN: no /var/lib/sigmond/sink.db; its producer and local columns were NOT evaluated"
            sink_unchecked "sink.db's producer and local columns (no /var/lib/sigmond/sink.db)"
        else
            _stab=$(_f70 SINKTAB)
            [ -n "$_stab" ] || { say "FATAL: the sink.db probe could not read the file (not a verdict)"; echo "$F70" | head -6; exit 1; }
            if [ "$_stab" = 0 ]; then
                say "WARN: no writer has opened sink.db in this nest (it has no RX888), so it holds no pending_uploads;"
                say "  its producer and local columns were NOT evaluated"
                sink_unchecked "sink.db's producer and local columns (no writer has created pending_uploads in this nest)"
            else
                _sprod=$(_f70 SINKPROD); _sloc=$(_f70 SINKLOCAL)
                [ -n "$_sprod" ] && [ -n "$_sloc" ] \
                    || { say "FATAL: the sink.db column probe returned no answer (not a verdict)"; exit 1; }
                [ "$_sprod" = 1 ] && [ "$_sloc" = 1 ] \
                    || { say "FATAL: sink.db's pending_uploads lacks producer ($_sprod) or local ($_sloc)"; exit 1; }
                say "sink.db's pending_uploads carries producer and local ✓"
            fi
        fi
    fi
fi

# ── remote access: every install registers, and the operator holds the switch ─
# sigmond tasks/plan-remote-access.md.  The nest has no gateway, so what it
# can prove stops short of a running tunnel:
#   1. an install with no gateway in reach finishes, wants remote access on,
#      and keeps trying;
#   2. the decoder VM can ask the host, and only for the three words;
#   3. a stand-in registrar registers the station;
#   4. off stops the host's units and stays off across a reboot; on undoes it;
#   5. the pairing survives a change of the host's sshd key.
# A tunnel that carries traffic is proven on hardware (AC0G-ND).
#
# Every probe tells "the channel gave no answer" (the rig's fault) from "the
# check failed" (the station's).  A probe in the guest goes through gq, which
# returns 1 when no exit status came back, and the caller then says the channel
# gave no answer.  A probe on the nested host ends with END:1 and counts only
# when that token came back (nh_ok): an ssh that died would otherwise read as a
# station that fails the check.
RAC_UNCHECKED=""
if [ "$RACQ" = 1 ]; then
    say "⚠ REMOTE ACCESS CHECKS NOT EVALUATED — this image's wizard predates v3.71"
    RAC_UNCHECKED="all of them (this image's wizard still asks 'Enable remote access?')"
else
    # gq <timeout> <tag> <snippet>: run the snippet as root in the decoder VM
    # through qm guest exec.  It travels base64-encoded, so the request holds
    # ASCII only.  Leaves the output in the file $GQ_OUT and the snippet's
    # exit status in $GQ_RC; returns 1 when the channel gave no status.
    # The snippet runs with stdin from /dev/null.  The guest's bash reads this
    # script from a pipe, and a command inside the snippet that reads stdin (a
    # bare ssh does) would take the lines after the snippet with it: the status
    # line would never print, and a working probe would read as "the channel
    # gave no answer".
    gq(){
        local t="$1" raw="$PWD/rr-$2.json" b64
        GQ_OUT="$PWD/rr-$2.out"; GQ_RC=""
        b64=$(printf '(\n%s\n) </dev/null > /tmp/rr.out 2>&1\nprintf "RRRC=%%s\\n" "$?"\ncat /tmp/rr.out\n' "$3" | base64 -w0)
        $SSHN "qm guest exec $VMID --timeout $t -- bash -lc \"echo $b64 | base64 -d | bash\"" > "$raw" 2>&1
        python3 - "$raw" "$GQ_OUT" <<'PYEOF'
import json, sys
raw = open(sys.argv[1], errors="replace").read()
try:
    d = json.loads(raw[raw.find("{"):raw.rfind("}") + 1])
except Exception:
    d = {}
open(sys.argv[2], "w").write((d.get("out-data") or "") + (d.get("err-data") or ""))
PYEOF
        GQ_RC=$(sed -n 's/^RRRC=\([0-9][0-9]*\)$/\1/p' "$GQ_OUT" | head -1)
        sed -i '/^RRRC=[0-9][0-9]*$/d' "$GQ_OUT"
        [ -n "$GQ_RC" ]
    }
    # rr_fatal <message>: a check on a GUEST probe failed; shows that probe's
    # capture ($GQ_OUT).  rr_hfatal <message> <answer>: a check on a probe on the
    # nested HOST failed; shows that probe's own answer, never a guest capture
    # left over from an earlier step.
    rr_fatal(){ say "FATAL: $1"; [ -f "${GQ_OUT:-}" ] && sed 's/^/      /' "$GQ_OUT" | tail -12; exit 1; }
    rr_hfatal(){ say "FATAL: $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      /' | tail -12; exit 1; }
    # remote <word> <tag>: smd remote <word> in the VM; sets RR (on|off|down) and GQ_RC.
    remote(){
        gq 240 "$2" "smd remote $1" || rr_fatal "smd remote $1: the guest-exec channel gave no answer (not a verdict)"
        RR=$(rr_state "$GQ_OUT")
    }
    PAIRSSH='ssh -T -i /etc/sigmond/rac-switch.key -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/etc/sigmond/rac-switch.known_hosts -o GlobalKnownHostsFile=/dev/null -o ConnectTimeout=8 -o LogLevel=ERROR sigmond-remote@10.99.0.1'
    # The account the panel tells an operator to log in with, and the wizard
    # gives passwordless sudo (sigmond-wizard.sh, "operator access to the
    # decoder VM").
    RR_OPERATOR=sigmond

    say "── remote access 1: no gateway in reach, and the install finished all the same"
    R1=$($SSHN "echo WISH:\$(cat /etc/sigmond-appliance/rac-desired 2>/dev/null); test -e /etc/sigmond/frpc-host.toml && echo REG:1 || echo REG:0; echo TIMER:\$(systemctl is-enabled sigmond-rac-register.timer 2>&1); command -v sudo >/dev/null && command -v visudo >/dev/null && echo SUDO:1 || echo SUDO:0; visudo -c -q -f /etc/sudoers.d/sigmond-remote >/dev/null 2>&1 && echo SUDOERS:1 || echo SUDOERS:0; echo KEYLINES:\$(grep -c . /var/lib/sigmond-remote/.ssh/authorized_keys 2>/dev/null); grep -c '^restrict,from=\"10.99.0.2\",command=\"sudo -n /usr/local/sbin/sigmond-rac-switch\" ssh-ed25519 ' /var/lib/sigmond-remote/.ssh/authorized_keys 2>/dev/null | sed 's/^/KEYOK:/'; dpkg-query -W -f='\${Status}' sudo 2>/dev/null | grep -q 'install ok installed' && echo SUDOPKG:1 || echo SUDOPKG:0; echo FETCHED:\$(grep -c 'this host has no sudo; installing it' /var/log/sigmond-wizard.log 2>/dev/null); echo END:1" 2>&1)
    echo "$R1" | sed 's/^/      /'
    nh_ok "$R1" || { say "FATAL: the nested host gave no answer to the install probe (ssh failed; not a verdict on remote access)"; exit 1; }
    echo "$R1" | grep -qx 'WISH:on'      || { say "FATAL: a fresh install does not want remote access on (/etc/sigmond-appliance/rac-desired)"; exit 1; }
    echo "$R1" | grep -qx 'REG:0'        || { say "FATAL: the nest registered with a gateway — the pin did not hold"; exit 1; }
    echo "$R1" | grep -qx 'TIMER:enabled' || { say "FATAL: the retry timer is not armed on an unregistered station that wants remote access"; exit 1; }
    echo "$R1" | grep -qx 'SUDOPKG:1'    || { say "FATAL: sudo is not installed on the host — the stick's offline-debs did not carry or configure it"; exit 1; }
    echo "$R1" | grep -qx 'SUDO:1'       || { say "FATAL: sudo or visudo missing from the host's PATH"; exit 1; }
    echo "$R1" | grep -qx 'SUDOERS:1'    || { say "FATAL: /etc/sudoers.d/sigmond-remote missing or refused by visudo"; exit 1; }
    echo "$R1" | grep -qx 'KEYLINES:1'   || { say "FATAL: the pairing account must hold exactly one key line"; exit 1; }
    echo "$R1" | grep -qx 'KEYOK:1'      || { say "FATAL: the pairing account's key line lacks restrict, from= or the forced command"; exit 1; }
    # The wizard fetches sudo with apt when the host has none (sigmond-wizard.sh,
    # rac_pair_locked), and this nest has internet.  Its log says so: a sudo that
    # did not come off the stick is a stick that lacks it (the same fault the
    # dpkg probe before the wizard catches, seen from the other side).
    [ -n "$(rr_tok FETCHED "$R1")" ] \
        || rr_hfatal "/var/log/sigmond-wizard.log is unreadable on the nested host: the wizard's pairing left no log to read" "$R1"
    [ "$(rr_tok FETCHED "$R1")" = 0 ] \
        || rr_hfatal "the wizard fetched sudo with apt (its log says 'this host has no sudo; installing it'): sudo did not come off the stick" "$R1"

    # 1a. The retry service leaves one journal line per reason, never one per
    # try.  The unit sets LogLevelMax=notice and SyslogLevel=notice; this proves
    # they hold on this systemd.  The reason note is removed first, so the first
    # try MUST print its reason line and the second must print nothing: exactly
    # one line, and it begins as rac_retry's line does (sigmond-wizard.sh).
    # journalctl's own status must read 0 and its stderr stays out of the counted
    # lines: an error line would otherwise read as "one line, no noise".
    # (The probe is a function run with stdin from /dev/null: bash reads this
    # script from ssh's stdin, and a command inside it must not take the rest.)
    R1A=$($SSHN "bash -s" 2>&1 <<'RR1AEOF'
main(){
    rm -f /run/sigmond/rac-retry.reason
    T0=$(date '+%Y-%m-%d %H:%M:%S')
    sleep 1
    systemctl start sigmond-rac-register.service; echo START1:$?
    systemctl start sigmond-rac-register.service; echo START2:$?
    journalctl --sync >/dev/null 2>&1
    sleep 2
    journalctl -q --no-pager -u sigmond-rac-register.service --since "$T0" -o cat > /tmp/rr1a.journal 2> /tmp/rr1a.err
    echo JRC:$?
    echo JERR:$(grep -c . /tmp/rr1a.err)
    echo JLINES:$(grep -c . /tmp/rr1a.journal)
    echo JREASON:$(grep -c '^remote access: not registered yet' /tmp/rr1a.journal)
    echo JNOISE:$(grep -c -E 'Started|Finished|Deactivated|Consumed' /tmp/rr1a.journal)
    sed 's/^/JLINE: /' /tmp/rr1a.journal
    sed 's/^/JERRLINE: /' /tmp/rr1a.err
    rm -f /tmp/rr1a.journal /tmp/rr1a.err
    echo END:1
}
main </dev/null
RR1AEOF
)
    echo "$R1A" | sed 's/^/      /'
    nh_ok "$R1A" || rr_hfatal "the nested host gave no answer to the retry-service probe (ssh failed; not a verdict)" "$R1A"
    [ "$(rr_tok START1 "$R1A")" = 0 ] && [ "$(rr_tok START2 "$R1A")" = 0 ] \
        || rr_hfatal "systemctl start sigmond-rac-register.service failed (exit $(rr_tok START1 "$R1A") and $(rr_tok START2 "$R1A")): the retry service must end quietly when no gateway answers" "$R1A"
    [ "$(rr_tok JRC "$R1A")" = 0 ] \
        || rr_hfatal "journalctl failed (exit '$(rr_tok JRC "$R1A")'): the journal query did not run, so the retry service's lines were not counted" "$R1A"
    R1A_LINES=$(rr_tok JLINES "$R1A"); R1A_REASON=$(rr_tok JREASON "$R1A"); R1A_NOISE=$(rr_tok JNOISE "$R1A")
    [ -n "$R1A_LINES" ] && [ -n "$R1A_REASON" ] && [ -n "$R1A_NOISE" ] \
        || rr_hfatal "the retry-service probe returned no journal count (not a verdict)" "$R1A"
    [ "$R1A_NOISE" = 0 ] \
        || rr_hfatal "systemd's own lines (Started, Finished, Deactivated or Consumed) reached the retry service's journal: LogLevelMax=notice did not hold" "$R1A"
    [ "$R1A_LINES" -le 1 ] \
        || rr_hfatal "two tries of the retry service wrote $R1A_LINES journal lines; it must write exactly one, for the reason that was new" "$R1A"
    [ "$R1A_LINES" = 1 ] && [ "$R1A_REASON" = 1 ] \
        || rr_hfatal "two tries of the retry service wrote $R1A_LINES journal line(s), $R1A_REASON of them 'remote access: not registered yet ...': the first try, with no reason on file, must print its reason, so either the query does not see this unit or the service stays silent" "$R1A"
    say "  1a: two tries of the retry service left exactly one journal line, the reason, and none of systemd's own ✓"

    # 1b. The host's half of the pairing, as files.  The account must not own
    # the file that holds its key (it could then change its own key), and
    # sudo must give it one command.
    R1B=$($SSHN "bash -s" 2>&1 <<'RR1BEOF'
main(){
    H=/var/lib/sigmond-remote
    A=$H/.ssh/authorized_keys
    echo AKLINES:$({ wc -l < "$A"; } 2>/dev/null)
    echo AKBEGIN:$(head -1 "$A" 2>/dev/null | grep -c '^restrict,from="')
    echo AKCMD:$(head -1 "$A" 2>/dev/null | grep -cF 'command="sudo -n /usr/local/sbin/sigmond-rac-switch"')
    echo HOMEOWN:$(stat -c '%U:%G %a' "$H" 2>/dev/null)
    echo SSHOWN:$(stat -c '%U:%G %a' "$H/.ssh" 2>/dev/null)
    echo AKOWN:$(stat -c '%U:%G %a' "$A" 2>/dev/null)
    sudo -l -U sigmond-remote 2>&1 | sed -n '/may run the following commands/,$p' | tail -n +2 > /tmp/rr1b.sudo
    echo SUDORULES:$(grep -c . /tmp/rr1b.sudo)
    echo SUDOPATHS:$(grep -o '/[A-Za-z0-9_./-]*' /tmp/rr1b.sudo | sort -u | paste -sd,)
    echo SUDONOPW:$(grep -c 'NOPASSWD' /tmp/rr1b.sudo)
    sed 's/^/SUDOLINE: /' /tmp/rr1b.sudo
    rm -f /tmp/rr1b.sudo
    echo END:1
}
main </dev/null
RR1BEOF
)
    echo "$R1B" | sed 's/^/      /'
    nh_ok "$R1B" || rr_hfatal "the nested host gave no answer to the pairing-files probe (ssh failed; not a verdict)" "$R1B"
    [ "$(rr_tok AKLINES "$R1B")" = 1 ] || rr_hfatal "authorized_keys of the pairing account must hold exactly one line, got '$(rr_tok AKLINES "$R1B")'" "$R1B"
    [ "$(rr_tok AKBEGIN "$R1B")" = 1 ] || rr_hfatal "the key line does not begin 'restrict,from=\"'" "$R1B"
    [ "$(rr_tok AKCMD "$R1B")" = 1 ]   || rr_hfatal "the key line does not hold command=\"sudo -n /usr/local/sbin/sigmond-rac-switch\"" "$R1B"
    [ "$(rr_tok HOMEOWN "$R1B")" = "root:root 755" ] || rr_hfatal "/var/lib/sigmond-remote must read root:root 755 (the account must not own its home), got '$(rr_tok HOMEOWN "$R1B")'" "$R1B"
    [ "$(rr_tok SSHOWN "$R1B")" = "root:root 755" ]  || rr_hfatal "/var/lib/sigmond-remote/.ssh must read root:root 755, got '$(rr_tok SSHOWN "$R1B")'" "$R1B"
    [ "$(rr_tok AKOWN "$R1B")" = "root:root 644" ]   || rr_hfatal "authorized_keys must read root:root 644 (the account must not write its own key file), got '$(rr_tok AKOWN "$R1B")'" "$R1B"
    [ "$(rr_tok SUDORULES "$R1B")" = 1 ] && [ "$(rr_tok SUDONOPW "$R1B")" = 1 ] \
        || rr_hfatal "sudo -l -U sigmond-remote must list exactly one rule, without a password; it lists '$(rr_tok SUDORULES "$R1B")' rule(s)" "$R1B"
    [ "$(rr_tok SUDOPATHS "$R1B")" = /usr/local/sbin/sigmond-rac-switch ] \
        || rr_hfatal "sudo -l -U sigmond-remote must name /usr/local/sbin/sigmond-rac-switch and no other command, got '$(rr_tok SUDOPATHS "$R1B")'" "$R1B"
    say "  1b: one restricted key line, root owns the key file and its directories, sudo allows the one script ✓"

    # 1c. The pairing arms its re-assertion before it proves anything (the
    # wizard's rac_pair_locked), so on a host with the private link these units
    # stand armed however the first proof went.  Check 5 depends on them.
    R1C=$($SSHN "echo PATHACTIVE:\$(systemctl is-active sigmond-rac-pair.path 2>&1); echo PATHENABLED:\$(systemctl is-enabled sigmond-rac-pair.path 2>&1); echo TIMERENABLED:\$(systemctl is-enabled sigmond-rac-pair.timer 2>&1); echo END:1" 2>&1)
    echo "$R1C" | sed 's/^/      /'
    nh_ok "$R1C" || rr_hfatal "the nested host gave no answer to the re-assertion probe (ssh failed; not a verdict)" "$R1C"
    [ "$(rr_tok PATHACTIVE "$R1C")" = active ] && [ "$(rr_tok PATHENABLED "$R1C")" = enabled ] \
        || rr_hfatal "sigmond-rac-pair.path is not armed (active '$(rr_tok PATHACTIVE "$R1C")', enabled '$(rr_tok PATHENABLED "$R1C")'): a change of the host's sshd key would not re-assert the pairing" "$R1C"
    [ "$(rr_tok TIMERENABLED "$R1C")" = enabled ] \
        || rr_hfatal "sigmond-rac-pair.timer is not enabled: nothing re-asserts the pairing after a boot" "$R1C"
    say "  1c: the pairing's re-assertion path and timer stand armed ✓"
    say "wish on, not registered, retry timer armed, sudo and the pairing in place ✓"

    say "── remote access 2: the VM asks, and only for the three words"
    remote status rr2-status
    [ "$RR" = down ] && [ "$GQ_RC" = 3 ] || rr_fatal "smd remote status: want 'wanted on, not up' and exit 3 on an unregistered station, got '${RR:-nothing}' exit $GQ_RC"
    RR2_STATE=$RR
    grep -q 'tries again every 10 minutes' "$GQ_OUT" || rr_fatal "the answer does not say the host keeps trying"
    gq 60 rr2-fourth "$PAIRSSH restart" || rr_fatal "the refusal probe gave no answer"
    [ "$GQ_RC" = 2 ] || rr_fatal "a fourth word must be refused with exit 2, got $GQ_RC"
    gq 60 rr2-extra "$PAIRSSH 'status; id'" || rr_fatal "the refusal probe gave no answer"
    [ "$GQ_RC" = 2 ] && ! grep -q 'uid=' "$GQ_OUT" || rr_fatal "extra words after 'status' must be refused and must run nothing (exit $GQ_RC)"
    gq 60 rr2-none "$PAIRSSH </dev/null" || rr_fatal "the refusal probe gave no answer"
    [ "$GQ_RC" = 2 ] || rr_fatal "a login with no word must be refused with exit 2, got $GQ_RC (did it get a shell?)"
    # A second key is refused by sshd itself.  Exit 255 and no state also
    # describe a timeout or a host-key mismatch, so the refusal must say so.
    gq 60 rr2-key2 "rm -f /tmp/rr-k2 /tmp/rr-k2.pub; ssh-keygen -q -t ed25519 -N '' -f /tmp/rr-k2; ${PAIRSSH/-i \/etc\/sigmond\/rac-switch.key/-i \/tmp\/rr-k2} status; rc=\$?; rm -f /tmp/rr-k2 /tmp/rr-k2.pub; exit \$rc" || rr_fatal "the second-key probe gave no answer"
    [ "$GQ_RC" = 255 ] && [ -z "$(rr_state "$GQ_OUT")" ] || rr_fatal "a second key must be refused by sshd (exit 255, no state), got exit $GQ_RC"
    grep -q 'Permission denied' "$GQ_OUT" \
        || rr_fatal "the second key failed with exit 255 but not with 'Permission denied': a timeout or a host-key mismatch also ends so, and neither shows that sshd refused the key"

    # 2a. No terminal.  The key line says `restrict`, which takes the pty away.
    # With -tt the OpenSSH client treats a refused terminal as fatal: it prints
    # "PTY allocation request failed on channel 0" and ends without the forced
    # command's answer.  So a correct system shows the PTY line, no state line
    # and a nonzero exit (the number is not pinned; it is printed).  A granted
    # terminal would show a state line and no PTY line, and that is the failure
    # this check exists to catch.  ssh may log the refusal below the pairing's
    # own LogLevel=ERROR, so this probe asks for INFO.
    PAIRSSH_TT="${PAIRSSH/ssh -T /ssh -tt }"
    PAIRSSH_TT="${PAIRSSH_TT/LogLevel=ERROR/LogLevel=INFO}"
    gq 60 rr2-pty "$PAIRSSH_TT status" || rr_fatal "the no-terminal probe gave no answer"
    PTY_RC=$GQ_RC
    if ! grep -q 'PTY allocation request failed' "$GQ_OUT"; then
        if [ -n "$(rr_state "$GQ_OUT")" ]; then
            rr_fatal "the pairing key was granted a terminal: ssh -tt got no 'PTY allocation request failed' and the switch answered '$(rr_state "$GQ_OUT")' (exit $PTY_RC); is 'restrict' missing from the key line, or does sshd grant a pty?"
        fi
        rr_fatal "ssh -tt printed no 'PTY allocation request failed' (exit $PTY_RC): the refusal of a terminal did not show"
    fi
    [ -z "$(rr_state "$GQ_OUT")" ] \
        || rr_fatal "the switch answered '$(rr_state "$GQ_OUT")' through a terminal that sshd refused (exit $PTY_RC): with -tt the client must end when the terminal is refused"
    [ "$PTY_RC" != 0 ] \
        || rr_fatal "ssh -tt ended with exit 0 although the terminal was refused"
    say "  2a: ssh -tt got no terminal, and ended (exit $PTY_RC) without the switch's answer ✓"

    # 2b. A variable the VM sends has no effect.  The switch is run on the nested
    # host itself, as root, in both of its forms; a probe through sshd and sudo
    # would prove nothing, since sshd's AcceptEnv drops the variable and sudo's
    # env_reset would drop it next, before the switch ever saw it.
    #   - forced-command form (no argument, the word in SSH_ORIGINAL_COMMAND):
    #     the switch unsets its SIGMOND_RAC_* overrides, so SIGMOND_RAC_RUN_DIR
    #     must change nothing: no /tmp/rr-env-probe.
    #   - control (one argument): the switch honours the override, so
    #     /tmp/rr-env-ctl MUST appear.  Without the control the first half could
    #     not fail either.
    # Both directories go afterwards, and a plain status leaves a fresh
    # /run/sigmond/rac-state for the checks that follow.
    R2B=$($SSHN "bash -s" 2>&1 <<'RR2BEOF'
main(){
    S=/usr/local/sbin/sigmond-rac-switch
    rm -rf /tmp/rr-env-probe /tmp/rr-env-ctl
    SSH_ORIGINAL_COMMAND=status SIGMOND_RAC_RUN_DIR=/tmp/rr-env-probe "$S" > /tmp/rr2b.fwd 2>&1
    echo FWDRC:$?
    test -e /tmp/rr-env-probe && echo FWDDIR:1 || echo FWDDIR:0
    echo FWDSTATE:$(sed -n 's/^Remote access: //p' /tmp/rr2b.fwd | head -1)
    SIGMOND_RAC_RUN_DIR=/tmp/rr-env-ctl "$S" status > /tmp/rr2b.ctl 2>&1
    echo CTLRC:$?
    test -e /tmp/rr-env-ctl && echo CTLDIR:1 || echo CTLDIR:0
    rm -rf /tmp/rr-env-probe /tmp/rr-env-ctl /tmp/rr2b.fwd /tmp/rr2b.ctl
    "$S" status > /dev/null 2>&1
    echo FINALRC:$?
    echo END:1
}
main </dev/null
RR2BEOF
)
    echo "$R2B" | sed 's/^/      /'
    nh_ok "$R2B" || rr_hfatal "the nested host gave no answer to the sent-variable probe (ssh failed; not a verdict)" "$R2B"
    case "$RR2_STATE" in down) R2B_WANT="wanted on, not up" ;; *) R2B_WANT="$RR2_STATE" ;; esac
    { [ "$(rr_tok FWDRC "$R2B")" = 0 ] || [ "$(rr_tok FWDRC "$R2B")" = 3 ]; } && [ "$(rr_tok FWDSTATE "$R2B")" = "$R2B_WANT" ] \
        || rr_hfatal "the switch in its forced-command form (no argument, SSH_ORIGINAL_COMMAND=status) must answer '$R2B_WANT' with exit 0 or 3, got '$(rr_tok FWDSTATE "$R2B")' exit '$(rr_tok FWDRC "$R2B")'" "$R2B"
    { [ "$(rr_tok CTLRC "$R2B")" = 0 ] || [ "$(rr_tok CTLRC "$R2B")" = 3 ]; } && [ "$(rr_tok CTLDIR "$R2B")" = 1 ] \
        || rr_hfatal "the control failed: with one argument the switch did not make SIGMOND_RAC_RUN_DIR=/tmp/rr-env-ctl (exit '$(rr_tok CTLRC "$R2B")'), so this probe has no power to show that the forced-command form ignores the variable" "$R2B"
    [ "$(rr_tok FWDDIR "$R2B")" = 0 ] \
        || rr_hfatal "the switch acted on a variable it was sent: in its forced-command form SIGMOND_RAC_RUN_DIR made /tmp/rr-env-probe" "$R2B"
    { [ "$(rr_tok FINALRC "$R2B")" = 0 ] || [ "$(rr_tok FINALRC "$R2B")" = 3 ]; } \
        || rr_hfatal "the plain status that refreshes /run/sigmond/rac-state failed (exit '$(rr_tok FINALRC "$R2B")')" "$R2B"
    say "  2b: the forced-command form ignored SIGMOND_RAC_RUN_DIR, and the one-argument control honoured it ✓"

    # 2c. The operator reaches the switch without a password.  The pairing key
    # belongs to root, so smd remote run by a plain account re-runs itself under
    # sudo, and the operator's passwordless sudo must carry it.  With no
    # terminal, a password prompt fails at once instead of waiting.
    gq 120 rr2-operator "su - $RR_OPERATOR -c 'smd remote status </dev/null'" || rr_fatal "the operator probe gave no answer"
    if grep -Eq 'sudo: (a password is required|a terminal is required|no tty present)|incorrect password|Sorry, try again' "$GQ_OUT"; then
        rr_fatal "the VM's operator account '$RR_OPERATOR' met a sudo password prompt running smd remote status"
    fi
    { [ "$GQ_RC" = 0 ] || [ "$GQ_RC" = 3 ]; } && [ -n "$(rr_state "$GQ_OUT")" ] \
        || rr_fatal "smd remote status as '$RR_OPERATOR' must end with a state and exit 0 or 3, got exit $GQ_RC and '$(rr_state "$GQ_OUT")'"
    say "  2c: '$RR_OPERATOR' ran smd remote status with no password: $(rr_state "$GQ_OUT"), exit $GQ_RC ✓"

    # 2d. The login banner.  The pairing plants /etc/update-motd.d/72-sigmond-remote;
    # it prints the last answer on file, which the status above just left.
    # run-parts is how a login finds the hook (name, executable bit).  The
    # regex limits it to this one hook: the other hooks call smd too, and the
    # guest agent runs one smd per request.
    gq 60 rr2-motd "run-parts --regex '^72-sigmond-remote\$' /etc/update-motd.d 2>/dev/null" || rr_fatal "the login-banner probe gave no answer"
    grep -q '^Remote access: ' "$GQ_OUT" \
        || rr_fatal "run-parts /etc/update-motd.d prints no 'Remote access:' line after a status (is /etc/update-motd.d/72-sigmond-remote missing, not executable or silent?)"
    ! grep -q 'state not read yet' "$GQ_OUT" \
        || rr_fatal "the login banner says the state was not read yet, though smd remote status had just run: smd remote motd cannot read the answer status left"
    grep -q '^Remote access: wanted on, NOT UP' "$GQ_OUT" \
        || rr_fatal "the login banner does not repeat the last answer (the station is wanted on and not up)"
    say "  2d: the login banner repeats the last answer ✓"
    say "status answered; a fourth word, extra words, no word and a second key all refused ✓"

    say "── remote access 3: a stand-in gateway registers the station"
    # A registrar on :35737 and a bare listener on :35735, on the nested host's
    # loopback.  The registrar answers as the real one does; the listener only
    # accepts, so frpc can never log in and no channel ever comes up.  It writes
    # each request body to /root/rac-standin.body, one JSON object per line, so
    # the check below reads values and not only key names.
    $SSHN "cat > /root/rac-standin.py" <<'STANDINEOF'
import http.server, json, socket, threading
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(n))
        open("/root/rac-standin.body", "a").write(json.dumps(body, sort_keys=True) + "\n")
        out = json.dumps({"user": "0123456789abcdef", "token": "nestedrigtoken01", "rac": 599,
                          "server_addr": "127.0.0.1", "server_port": 35735,
                          "ports": {"vm_ssh": 36399, "vm_web": 46399,
                                    "host_ssh": 51399, "host_ui": 56399}}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out)
    def log_message(self, *a): pass
def frps():
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", 35735)); s.listen(8)
    while True:
        c, _ = s.accept(); c.close()
threading.Thread(target=frps, daemon=True).start()
http.server.ThreadingHTTPServer(("127.0.0.1", 35737), H).serve_forever()
STANDINEOF
    $SSHN "rm -f /root/rac-standin.body; systemctl reset-failed rac-standin 2>/dev/null; systemd-run --unit=rac-standin --collect --quiet python3 /root/rac-standin.py && sleep 3 && systemctl is-active --quiet rac-standin" \
        || { say "FATAL: the stand-in gateway did not start on the nested host"; exit 1; }
    remote on rr3-on
    [ "$RR" = down ] && [ "$GQ_RC" = 3 ] || rr_fatal "smd remote on against the stand-in: want 'wanted on, not up' exit 3 (registered, no channel), got '${RR:-nothing}' exit $GQ_RC"
    R3=$($SSHN "echo RACN:\$(cat /etc/sigmond-appliance/rac-number 2>/dev/null); grep -c '^user = \"0123456789abcdef\"' /etc/sigmond/frpc-host.toml 2>/dev/null | sed 's/^/TOML:/'; grep -c '^name = ' /etc/sigmond/frpc-host.toml 2>/dev/null | sed 's/^/PROXIES:/'; echo UNIT:\$(systemctl is-enabled sigmond-rac-host 2>&1); echo TIMER:\$(systemctl is-enabled sigmond-rac-register.timer 2>&1); echo END:1" 2>&1)
    echo "$R3" | sed 's/^/      /'
    nh_ok "$R3" || { say "FATAL: the nested host gave no answer to the registration probe (ssh failed; not a verdict)"; exit 1; }
    echo "$R3" | grep -qx 'RACN:599'      || { say "FATAL: the registration's RAC number did not reach /etc/sigmond-appliance/rac-number"; exit 1; }
    echo "$R3" | grep -qx 'TOML:1'        || { say "FATAL: frpc-host.toml does not carry the registered account"; exit 1; }
    echo "$R3" | grep -qx 'PROXIES:6'     || { say "FATAL: frpc-host.toml does not declare six channels"; exit 1; }
    echo "$R3" | grep -qx 'UNIT:enabled'  || { say "FATAL: sigmond-rac-host is not enabled after smd remote on"; exit 1; }
    echo "$R3" | grep -qx 'TIMER:disabled' || { say "FATAL: the retry timer is still armed after the station registered"; exit 1; }
    # What the registration carried, by value.  The wizard posts {"site", "pubkey"}
    # (sigmond-wizard.sh, rac_ladder): the station's name, which is the reporter
    # id upper-cased with / as _, and the whole line of the host's public key,
    # comment field included, as $(cat id_ed25519.pub) reads it.
    R3B=$($SSHN "python3 -" 2>&1 <<'RR3BEOF'
import json
try:
    text = open("/root/rac-standin.body").read()
except OSError:
    text = ""
rows = [json.loads(l) for l in text.splitlines() if l.strip()]
try:
    pub = open("/root/.ssh/id_ed25519.pub").read().rstrip("\n")
except OSError:
    pub = None
ok = len(rows) > 0
print("BODIES:%d" % len(rows))
print("SITEOK:%d" % (ok and all(r.get("site") == "N0CALL_T1" for r in rows)))
print("PUBOK:%d" % (ok and pub is not None and all(r.get("pubkey") == pub for r in rows)))
print("KEYSOK:%d" % (ok and all(sorted(r) == ["pubkey", "site"] for r in rows)))
print("SITEGOT:%s" % (rows[0].get("site") if ok else ""))
print("END:1")
RR3BEOF
)
    echo "$R3B" | sed 's/^/      /'
    nh_ok "$R3B" || { say "FATAL: the nested host gave no answer to the registration-body probe (ssh failed or python3 died; not a verdict)"; exit 1; }
    [ "$(rr_tok BODIES "$R3B")" -ge 1 ] 2>/dev/null || { say "FATAL: the stand-in saw no registration request, though the station registered"; exit 1; }
    [ "$(rr_tok SITEOK "$R3B")" = 1 ] || { say "FATAL: the registration named the station '$(rr_tok SITEGOT "$R3B")', not N0CALL_T1"; exit 1; }
    [ "$(rr_tok PUBOK "$R3B")" = 1 ]  || { say "FATAL: the registration's pubkey is not the content of /root/.ssh/id_ed25519.pub on the host"; exit 1; }
    [ "$(rr_tok KEYSOK "$R3B")" = 1 ] || { say "FATAL: registration sent something besides the station's name and the host's public key"; exit 1; }
    say "registered through the stand-in: RAC 599, six channels declared, name N0CALL_T1 and the host's key sent and nothing else ✓"

    say "── remote access 4: off stops the host's units and survives a reboot"
    remote off rr4-off
    [ "$RR" = off ] && [ "$GQ_RC" = 0 ] || rr_fatal "smd remote off: want 'off' exit 0, got '${RR:-nothing}' exit $GQ_RC"
    # All four relay sockets (the switch's SOCKETS list, sigmond-wizard.sh).
    rac_units(){ $SSHN "echo WISH:\$(cat /etc/sigmond-appliance/rac-desired 2>/dev/null); echo BY:\$(awk '{print \$3}' /etc/sigmond-appliance/rac-changed 2>/dev/null); echo UNIT:\$(systemctl is-enabled sigmond-rac-host 2>&1)/\$(systemctl is-active sigmond-rac-host 2>&1); for s in ssh web station gmag; do echo SOCK_\$s:\$(systemctl is-enabled sigmond-vm-\$s-relay.socket 2>&1)/\$(systemctl is-active sigmond-vm-\$s-relay.socket 2>&1); done; test -s /etc/sigmond/frpc-host.toml && echo TOMLKEPT:1 || echo TOMLKEPT:0; echo END:1" 2>&1; }
    R4=$(rac_units); echo "$R4" | sed 's/^/      /'
    nh_ok "$R4" || { say "FATAL: the nested host gave no answer to the unit probe after smd remote off (ssh failed; not a verdict)"; exit 1; }
    echo "$R4" | grep -qx 'WISH:off' && echo "$R4" | grep -qx 'BY:vm' \
        || { say "FATAL: the host did not record the wish off, asked from the VM"; exit 1; }
    echo "$R4" | grep -qx 'UNIT:disabled/inactive' || { say "FATAL: sigmond-rac-host still enabled or running after smd remote off"; exit 1; }
    for s in ssh web station gmag; do
        echo "$R4" | grep -qx "SOCK_$s:disabled/inactive" || { say "FATAL: the $s relay socket is still enabled or listening after smd remote off"; exit 1; }
    done
    echo "$R4" | grep -qx 'TOMLKEPT:1' || { say "FATAL: smd remote off removed the registration"; exit 1; }
    say "rebooting the nested host: the switch must still read off afterwards"
    # Wait for a NEW boot, not for ssh: a host that is still shutting down
    # answers ssh too, and the checks below would then run against the old boot.
    BOOT0=$($SSHN "cat /proc/sys/kernel/random/boot_id" 2>/dev/null)
    [ -n "$BOOT0" ] || { say "FATAL: could not read the nested host's boot id before the reboot (ssh gave no answer)"; exit 1; }
    $SSHN "systemctl stop rac-standin 2>/dev/null; reboot" >/dev/null 2>&1
    sleep 20
    BOOT1=""
    for i in $(seq 1 90); do
        BOOT1=$($SSHN "cat /proc/sys/kernel/random/boot_id" 2>/dev/null)
        [ -n "$BOOT1" ] && [ "$BOOT1" != "$BOOT0" ] && break
        sleep 5
    done
    { [ -n "$BOOT1" ] && [ "$BOOT1" != "$BOOT0" ]; } || { say "FATAL: nested host did not come back from the reboot (boot id now '${BOOT1:-unreadable}', before '$BOOT0')"; exit 1; }
    for i in $(seq 1 30); do $SSHN "qm status $VMID 2>/dev/null | grep -q running" 2>/dev/null && break; sleep 10; done
    AOK=0; for i in $(seq 1 40); do if $SSHN "qm agent $VMID ping" >/dev/null 2>&1; then AOK=$((AOK+1)); [ "$AOK" -ge 2 ] && break; sleep 3; else AOK=0; sleep 10; fi; done
    [ "$AOK" -ge 2 ] || { say "FATAL: guest agent never answered after the reboot"; exit 1; }
    R4=$(rac_units); echo "$R4" | sed 's/^/      /'
    nh_ok "$R4" || { say "FATAL: the nested host gave no answer to the unit probe after the reboot (ssh failed; not a verdict)"; exit 1; }
    echo "$R4" | grep -qx 'UNIT:disabled/inactive' && echo "$R4" | grep -qx 'WISH:off' \
        || { say "FATAL: remote access did not stay off across a reboot"; exit 1; }
    # A ping is not a ready agent (see the password-hash check earlier in this
    # phase): the first guest-exec after a boot can time out.  So a missing
    # answer is tried again, and only an answer that is wrong counts.
    RRTRY=""; RRCH=0
    for i in $(seq 1 12); do
        if gq 240 rr4-status "smd remote status"; then RRCH=1; RRTRY="$(rr_state "$GQ_OUT")/$GQ_RC"; [ "$RRTRY" = off/0 ] && break; fi
        sleep 10
    done
    [ "$RRCH" = 1 ] || rr_fatal "smd remote status after the reboot: the guest-exec channel gave no answer in 12 tries (not a verdict)"
    [ "$RRTRY" = off/0 ] || rr_fatal "smd remote status after the reboot: want 'off' exit 0, got $RRTRY"
    # sigmond-issue takes a lock and skips a run while another holds it, so a
    # skipped run leaves the old panel: try again before judging.
    PANEL=""
    for i in $(seq 1 6); do
        PANEL=$($SSHN "SIGMOND_VMID=$VMID /usr/local/sbin/sigmond-issue >/dev/null 2>&1; grep -q \"OFF, by the operator's choice\" /etc/issue && echo PANEL:offchoice || echo PANEL:other; grep -q 'STATE NOT READ' /etc/issue && echo NOTREAD:1 || echo NOTREAD:0; grep -q 'OFFLINE' /etc/issue && echo OFFLINE:1 || echo OFFLINE:0; head -1 /etc/sigmond-appliance/rac-pairing 2>/dev/null | grep -q '^paired ' && echo PAIRREC:1 || echo PAIRREC:0; grep -q '==> to turn it on, log in to the decoder VM (ssh -p 2222 sigmond@.*) and type:  smd remote on' /etc/issue && echo VMCMD:1 || echo VMCMD:0; grep -q 'sigmond-setup --rac-o' /etc/issue && echo HOSTCMD:1 || echo HOSTCMD:0; echo END:1" 2>&1)
        [ "$(rr_tok PANEL "$PANEL")" = offchoice ] && break
        sleep 5
    done
    echo "$PANEL" | sed 's/^/      /'
    nh_ok "$PANEL" || { say "FATAL: the nested host gave no answer to the console-panel probe (ssh failed; not a verdict)"; exit 1; }
    [ "$(rr_tok NOTREAD "$PANEL")" = 0 ] || { say "FATAL: the console panel prints STATE NOT READ: the switch left no fresh state file"; exit 1; }
    [ "$(rr_tok OFFLINE "$PANEL")" = 0 ] || { say "FATAL: the console panel prints the pre-v3.71 OFFLINE text for a deliberate off"; exit 1; }
    [ "$(rr_tok PANEL "$PANEL")" = offchoice ] || { say "FATAL: the console panel does not show a deliberate off as the operator's choice"; exit 1; }
    # The VM has just worked the switch twice through the pairing (off, then
    # status after the reboot), so the wizard's pairing must have recorded
    # `paired` (sigmond-wizard.sh, rac_pair_record), and the panel must then send
    # the reader to the decoder VM for `smd remote on`.  Without that record the
    # panel names the host's own switch.
    [ "$(rr_tok PAIRREC "$PANEL")" = 1 ] || { say "FATAL: /etc/sigmond-appliance/rac-pairing does not begin 'paired ' on a station whose VM works the switch"; $SSHN "cat /etc/sigmond-appliance/rac-pairing" 2>&1 | sed 's/^/      /'; exit 1; }
    [ "$(rr_tok VMCMD "$PANEL")" = 1 ]   || { say "FATAL: the console panel of a paired station, in the off state, does not tell the reader to log in to the decoder VM and type smd remote on"; $SSHN "grep -A4 'Remote access' /etc/issue" 2>&1 | sed 's/^/      /'; exit 1; }
    [ "$(rr_tok HOSTCMD "$PANEL")" = 0 ] || { say "FATAL: the console panel of a paired station names the host's own switch (sigmond-setup --rac-on or --rac-off)"; exit 1; }
    say "off held across the reboot, and the panel calls it the operator's choice ✓"
    say "the pairing stands recorded as paired, and the panel names the decoder VM and smd remote on ✓"
    $SSHN "systemd-run --unit=rac-standin --collect --quiet python3 /root/rac-standin.py && sleep 3" >/dev/null 2>&1
    remote on rr4-on
    [ "$RR" = down ] && [ "$GQ_RC" = 3 ] || rr_fatal "smd remote on after the reboot: want 'wanted on, not up' exit 3, got '${RR:-nothing}' exit $GQ_RC"
    R4=$(rac_units)
    nh_ok "$R4" || { say "FATAL: the nested host gave no answer to the unit probe after smd remote on (ssh failed; not a verdict)"; exit 1; }
    echo "$R4" | grep -qx 'WISH:on' && echo "$R4" | grep -q '^UNIT:enabled/' \
        || { say "FATAL: smd remote on did not enable the host's units again"; echo "$R4" | sed 's/^/      /'; exit 1; }
    for s in ssh web station gmag; do
        echo "$R4" | grep -q "^SOCK_$s:enabled/" || { say "FATAL: smd remote on did not enable the $s relay socket again"; echo "$R4" | sed 's/^/      /'; exit 1; }
    done
    say "on enabled the tunnel and the relays again ✓"

    say "── remote access 5: the pairing survives a change of the host's sshd key"
    # What an identity restore does (AC0G-B4, 2026-10-01): the host's sshd key
    # changes under a VM that pinned the old one.  The host must re-assert the
    # pairing by itself; nobody types anything.
    #
    # Two things re-assert the pairing: sigmond-rac-pair.path, which watches
    # /etc/ssh/ssh_host_ed25519_key.pub (the .pub file, not the private key),
    # and sigmond-rac-pair.timer, which falls due about 4 to 5 minutes after
    # every boot (OnBootSec=4min) and then every 6 hours.  This check starts a
    # few minutes after check 4's reboot, so a dead path unit would still pass
    # if the boot timer repaired the pairing inside the window.  So the rig holds
    # the timer, and waits until the service is idle, before the key changes: a
    # timer run in flight could read the old key, fail its proof and leave
    # nothing to retry for 6 hours.  Then only the path unit can repair the
    # pairing, and the evidence is one only it can produce: the VM's
    # known_hosts comes to hold the host's NEW key.  The timer starts again
    # afterwards, whatever the verdict (starting it fires one more run at once,
    # which is why it waits until the evidence is in).
    rr5_timer_back(){ $SSHN "systemctl start sigmond-rac-pair.timer" >/dev/null 2>&1; }
    R5A=$($SSHN "bash -s" 2>&1 <<'RR5AEOF'
main(){
    systemctl stop sigmond-rac-pair.timer; echo STOPRC:$?
    for i in $(seq 1 18); do
        s=$(systemctl is-active sigmond-rac-pair.service 2>&1)
        case "$s" in active|activating|deactivating|reloading) sleep 5 ;; *) break ;; esac
    done
    echo PAIRSVC:$(systemctl is-active sigmond-rac-pair.service 2>&1)
    echo TIMERNOW:$(systemctl is-active sigmond-rac-pair.timer 2>&1)
    echo END:1
}
main </dev/null
RR5AEOF
)
    echo "$R5A" | sed 's/^/      /'
    # A dead ssh says nothing about whether the stop went through, so the timer
    # is started again before the rig gives up here as well.
    nh_ok "$R5A" || { rr5_timer_back; rr_hfatal "the nested host gave no answer when the rig held the pairing timer (ssh failed; not a verdict)" "$R5A"; }
    if [ "$(rr_tok STOPRC "$R5A")" != 0 ] || [ "$(rr_tok TIMERNOW "$R5A")" = active ]; then
        rr5_timer_back
        rr_hfatal "the rig could not stop sigmond-rac-pair.timer (stop exit '$(rr_tok STOPRC "$R5A")', state '$(rr_tok TIMERNOW "$R5A")'); this is the rig's own step, not the station's" "$R5A"
    fi
    case "$(rr_tok PAIRSVC "$R5A")" in
        active|activating|deactivating|reloading)
            rr5_timer_back
            rr_hfatal "sigmond-rac-pair.service still runs 90 s after the rig stopped its timer ('$(rr_tok PAIRSVC "$R5A")'); the rig's own step cannot go on with a pairing in flight" "$R5A" ;;
    esac
    # The order the brief gives: remove, make the new pair, restart sshd.  The
    # swap runs as a transient unit of its own and writes its result to a file:
    # restarting sshd may end the ssh session that asked for it, and a dropped
    # session must not read as a failed swap.
    $SSHN "cat > /tmp/rr5-swap.sh" <<'RR5SWAPEOF'
P=/etc/ssh/ssh_host_ed25519_key
{ echo OLDKEY:$(awk '{print $2}' $P.pub); } > /tmp/rr5.swap.new
rm -f $P $P.pub
ssh-keygen -q -t ed25519 -N '' -f $P && systemctl restart ssh
echo SWAPRC:$? >> /tmp/rr5.swap.new
echo SWAPEND:1 >> /tmp/rr5.swap.new
mv -f /tmp/rr5.swap.new /tmp/rr5.swap
RR5SWAPEOF
    R5L=$($SSHN "rm -f /tmp/rr5.swap /tmp/rr5.swap.new; systemctl reset-failed rr5-keyswap 2>/dev/null; systemd-run --unit=rr5-keyswap --collect --quiet bash /tmp/rr5-swap.sh; echo LAUNCHRC:\$?; echo END:1" 2>&1)
    if ! nh_ok "$R5L" || [ "$(rr_tok LAUNCHRC "$R5L")" != 0 ]; then
        rr5_timer_back
        rr_hfatal "the rig could not start the key swap on the nested host (launch exit '$(rr_tok LAUNCHRC "$R5L")'; no END:1 means ssh gave no answer); this is the rig's own step" "$R5L"
    fi
    R5B=""
    for i in $(seq 1 24); do
        R5B=$($SSHN "cat /tmp/rr5.swap 2>/dev/null; echo END:1" 2>/dev/null)
        [ "$(rr_tok SWAPEND "$R5B")" = 1 ] && break
        sleep 5
    done
    if [ "$(rr_tok SWAPEND "$R5B")" != 1 ] || [ "$(rr_tok SWAPRC "$R5B")" != 0 ]; then
        rr5_timer_back
        rr_hfatal "could not replace the nested host's sshd key (swap exit '$(rr_tok SWAPRC "$R5B")'; no SWAPEND within 2 minutes means the swap never finished); this is the rig's own step" "$R5B"
    fi
    R5C=$($SSHN "echo NEWKEY:\$(awk '{print \$2}' /etc/ssh/ssh_host_ed25519_key.pub); echo END:1" 2>&1)
    R5_OLD=$(rr_tok OLDKEY "$R5B"); R5_NEW=$(rr_tok NEWKEY "$R5C")
    if ! nh_ok "$R5C" || [ -z "$R5_NEW" ] || [ -z "$R5_OLD" ] || [ "$R5_NEW" = "$R5_OLD" ]; then
        rr5_timer_back
        rr_hfatal "the rig's key swap left no new key to compare (old '${R5_OLD:0:16}', new '${R5_NEW:0:16}'); this is the rig's own step" "$R5B"
    fi
    # Wait, at most 18 tries of 10 s, for the VM's known_hosts to hold the new
    # key.  Each try is one cat; no smd runs until the key is there.
    R5_CH=0; R5_KH=""
    for i in $(seq 1 18); do
        if gq 30 rr5-kh "cat /etc/sigmond/rac-switch.known_hosts"; then
            R5_CH=1
            R5_KH=$(rr_khkey "$GQ_OUT")
            [ "$R5_KH" = "$R5_NEW" ] && break
        fi
        sleep 10
    done
    # Then smd remote status must answer again.  The key lands before the
    # proof of the pairing ends, so a few tries are allowed.
    RRTRY=""; RR5_ST=0
    if [ "$R5_KH" = "$R5_NEW" ]; then
        for i in $(seq 1 6); do
            if gq 240 rr5-status "smd remote status"; then
                RR5_ST=1
                RRTRY="$(rr_state "$GQ_OUT")/$GQ_RC"
                case "$RRTRY" in down/3|on/0|off/0) break ;; esac
            fi
            sleep 10
        done
    fi
    rr5_timer_back
    [ "$R5_CH" = 1 ] || rr_fatal "three minutes after the host's sshd key changed, the guest-exec channel never gave an answer (not a verdict)"
    [ "$R5_KH" = "$R5_NEW" ] \
        || rr_fatal "three minutes after the host's sshd key changed, the VM's rac-switch.known_hosts still holds '${R5_KH:0:24}...', not the new key '${R5_NEW:0:24}...': with the boot timer held, only sigmond-rac-pair.path re-asserts the pairing when /etc/ssh/ssh_host_ed25519_key.pub changes, and it did not"
    say "  the VM's known_hosts came to hold the host's new key, with the boot timer held ✓"
    [ "$RR5_ST" = 1 ] || rr_fatal "after the pairing re-asserted itself, the guest-exec channel never answered smd remote status (not a verdict)"
    case "$RRTRY" in
        down/3|on/0|off/0) say "the host re-asserted the pairing after its sshd key changed ($RRTRY) ✓" ;;
        *) rr_fatal "the VM holds the host's new key, yet smd remote status still fails ($RRTRY)" ;;
    esac
    $SSHN "systemctl stop rac-standin 2>/dev/null; true"
fi

# ── the guest agent, part 3: no request deafens it, one reset heals it ─────
# sigmond tasks/plan-guest-agent-requests.md section 5.  Up to v3.70 the
# console panel sent the decoder VM a request that Proxmox wrote short, and
# about one time in six the guest agent then stood deaf for good.  Three
# things must hold on an image that carries the fix:
#   1. twelve panel refreshes leave the agent answering every ping;
#   2. an agent the rig deafens on purpose hears again after ONE refresh, and
#      the panel leaves the line the heartbeat reports from;
#   3. after bring-up the panel's line follows the marker's result, and the
#      false alarm of v3.70 does not show.
if [ "${QGA_PANELFIX:-0}" = 1 ]; then
    Q1=$(qga_probe_refresh | $SSHN "bash -s $VMID" 2>&1)
    nh_ok "$Q1" || qga_fatal "guest agent, twelve panel refreshes: the nested host gave no answer (not a verdict)" "$Q1"
    [ "$(rr_tok SILENT "$Q1")" = 0 ] \
        || qga_fatal "after twelve panel refreshes, $(rr_tok SILENT "$Q1") of twelve pings got no answer from the guest agent: a request of the panel still deafens it" "$Q1"
    say "twelve panel refreshes, twelve pings answered ✓"
    [ "$(rr_tok NOTE "$Q1")" = none ] \
        || say "NOTE: a parser reset stands on record ($(rr_tok NOTE "$Q1")). One at boot proves little; one at any other time names a cause"

    Q2=$(qga_probe_deafen | $SSHN "bash -s $VMID 30" 2>&1)
    QDEAF=$(rr_tok DEAF "$Q2")
    # The heal runs whatever the deafening answered: it also starts the two
    # timers that the deafening stopped.
    Q3=$(qga_probe_heal | $SSHN "bash -s $VMID" 2>&1)
    if ! nh_ok "$Q2" || ! nh_ok "$Q3"; then
        $SSHN "systemctl start sigmond-issue.timer pm-heartbeat.timer" >/dev/null 2>&1
        qga_fatal "guest agent, deafen and heal: the nested host gave no answer (not a verdict)" "$Q2
$Q3"
    fi
    if [ "${QDEAF:-0}" = 0 ]; then
        say "⚠ thirty non-ASCII requests left the guest agent hearing: the heal was NOT proven in this run"
        QGA_UNCHECKED="${QGA_UNCHECKED:+$QGA_UNCHECKED; }the heal (the rig could not deafen the agent)"
    else
        [ "$(rr_tok HEARS "$Q3")" = 1 ] \
            || qga_fatal "the guest agent stood deaf (after request $QDEAF), and one panel refresh did not bring it back" "$Q3"
        case "$(rr_tok NOTE "$Q3")" in
            *" panel") ;;
            *) qga_fatal "the panel healed the agent and left no line of its own in /run/sigmond/qga-reset (read: '$(rr_tok NOTE "$Q3")'): the host's heartbeat can then report no reset" "$Q3" ;;
        esac
        [ "$(rr_tok PANELSILENT "$Q3")" = 0 ] \
            || qga_fatal "the panel healed the agent and still says that it does not answer" "$Q3"
        say "a guest agent deafened on purpose (request $QDEAF) heard again after one panel refresh ✓"
        say "NOTE: the agent's raw reply to one more parser reset, in hex: $(rr_tok RESETHEX "$Q3")"
    fi

    QRES=$($SSHN "qm guest exec $VMID --timeout 30 -- /bin/bash -c 'sed -n s/^result=//p /var/lib/sigmond/.firstrun-bringup-done 2>/dev/null | head -1'" 2>/dev/null \
            | grep -o '"out-data" *: *"[a-z-]*' | grep -o '[a-z-]*$' | head -1)
    Q4=$(qga_probe_bringup | $SSHN "bash -s $VMID" 2>&1)
    nh_ok "$Q4" || qga_fatal "guest agent, the panel's bring-up line: the nested host gave no answer (not a verdict)" "$Q4"
    [ "$(rr_tok STARTING "$Q4")" = 0 ] \
        || qga_fatal "guest agent, the panel's bring-up line: /etc/issue still holds the starting placeholder, so the probe's refresh did not finish (a rig fault, not a verdict)" "$Q4"
    [ "$(rr_tok SILENT "$Q4")" = 0 ] \
        || qga_fatal "after the heal, the panel says once more that the guest agent does not answer" "$Q4"
    case "${QRES:-none}" in
        awaiting-sdr)
            [ "$(rr_tok NOSDR "$Q4")" = 1 ] && [ "$(rr_tok NOWEB "$Q4")" = 0 ] && [ "$(rr_tok BUILDING "$Q4")" = 0 ] \
                || qga_fatal "bring-up ended awaiting-sdr; the panel must say that it ran without the radio, and must not say BUILDING or raise the ka9q-web alarm" "$Q4"
            say "bring-up ended without the radio, and the panel says exactly that ✓" ;;
        ok)
            [ "$(rr_tok BUILDING "$Q4")" = 0 ] && [ "$(rr_tok NOSDR "$Q4")" = 0 ] \
                || qga_fatal "bring-up ended ok; the panel must say neither BUILDING nor that it ran without the radio" "$Q4"
            say "bring-up ended ok; the panel's ka9q-web alarm reads $(rr_tok NOWEB "$Q4") ✓" ;;
        retry)
            [ "$(rr_tok RETRY "$Q4")" = 1 ] && [ "$(rr_tok NOWEB "$Q4")" = 0 ] \
                || qga_fatal "bring-up ended retry; the panel must say that it tries again, and must not say that bring-up finished" "$Q4"
            say "bring-up ended retry, and the panel says that it tries again ✓" ;;
        gave-up)
            [ "$(rr_tok GAVEUP "$Q4")" = 1 ] \
                || qga_fatal "bring-up ended gave-up; the panel must say that it stopped trying" "$Q4"
            say "bring-up gave up, and the panel says so ✓" ;;
        *)
            say "⚠ the panel's line AFTER bring-up was not evaluated (the marker's result read '${QRES:-none}')"
            QGA_UNCHECKED="${QGA_UNCHECKED:+$QGA_UNCHECKED; }the panel's line after bring-up" ;;
    esac
fi

# What the site sink checks left unchecked, said once more beside the verdict.
# The PHASE D PASS line below stays exactly as it was: test-update-v3.sh and
# bless-release.sh match it.
if [ -n "${SINK_UNCHECKED:-}" ]; then
    say "⚠ SITE SINK CHECKS NOT EVALUATED: $SINK_UNCHECKED"
fi
if [ -n "${RAC_UNCHECKED:-}" ]; then
    say "⚠ REMOTE ACCESS CHECKS NOT EVALUATED: $RAC_UNCHECKED"
fi
if [ -n "${QGA_UNCHECKED:-}" ]; then
    say "⚠ GUEST-AGENT CHECKS NOT EVALUATED: $QGA_UNCHECKED"
fi

say "PHASE D PASS — NESTED TEST COMPLETE"
;;
esac
say "TEST DRIVER DONE"
