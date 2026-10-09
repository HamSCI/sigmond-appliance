#!/bin/bash
# test-panel-remote.sh — the console panel's remote-access block: three
# states, not two.  No VM, no root; about a second.
#
# Why: until v3.70 the panel printed "OFFLINE — check: journalctl -u
# sigmond-rac-host" whenever the tunnel's unit did not run.  An operator who
# had turned remote access off on purpose read a fault on the console, and so
# did whoever came to chase it (sigmond tasks/plan-remote-access.md section 4).
# From v3.71 the panel asks the switch script, which tells a decision from a
# fault:
#     on     the tunnel runs; the channels follow
#     off    the operator holds it off; say since when, and how to turn it on
#     down   wanted on and not up; this one stays the fault
#
# The block under test is cut out of firstboot-v3.sh from between its two
# markers, so this runs what ships.  A stub stands in for the switch script
# and writes the state file the real one leaves.
#
#   usage: ./test-panel-remote.sh [path/to/firstboot-v3.sh]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:-$HERE/firstboot-v3.sh}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok(){  printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad(){ printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
has(){   case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing: $3" ;; esac; }
lacks(){ case "$2" in *"$3"*) bad "$1" "found: $3" ;; *) ok "$1" ;; esac; }

sed -n '/^# >>> rac_block/,/^# <<< rac_block/p' "$SRC" > "$T/block.sh"
[ -s "$T/block.sh" ] || { echo "FAIL: no rac_block between its markers in $SRC"; exit 1; }
bash -n "$T/block.sh" || { echo "FAIL: the rac_block does not parse"; exit 1; }

cat > "$T/frpc-host.toml" <<'TOML'
serverAddr = "gw2.wsprdaemon.org"
user = "0123456789abcdef"
[[proxies]]
name = "AC0G_B4-vm-ssh"
remotePort = 36307
[[proxies]]
name = "AC0G_B4-vm-web"
remotePort = 46307
[[proxies]]
name = "AC0G_B4-vm-station"
remotePort = 49307
[[proxies]]
name = "AC0G_B4-vm-gmag"
remotePort = 50307
[[proxies]]
name = "AC0G_B4-host-ssh"
remotePort = 51307
[[proxies]]
name = "AC0G_B4-host-ui"
remotePort = 56307
TOML

# panel <scene dir> : run the block as sigmond-issue would, print $RACBLOCK.
# A scene holds: marks/ (rac-number, rac-tier, ...), state (what the switch
# writes; absent = the switch leaves none), no-switch (this host has no
# switch script), no-toml, unit-active (for the text of v3.70 and before).
# $BLOCK names the block to run; the control below points it at a mutant.
BLOCK="$T/block.sh"
panel(){
    local d="$1"
    (
        export RAC_MARKS="$d/marks" RAC_STATE_FILE="$d/run/rac-state" RAC_TOML="$d/frpc-host.toml"
        export RAC_SWITCH="$d/switch"
        mkdir -p "$d/marks" "$d/run"
        [ -e "$d/no-toml" ] || cp "$T/frpc-host.toml" "$d/frpc-host.toml"
        if [ ! -e "$d/no-switch" ]; then
            { echo '#!/bin/bash'
              echo "echo \"\$*\" >> '$d/switch.calls'"
              echo "[ -e '$d/state' ] && cp '$d/state' '$d/run/rac-state'"
              echo 'exit 0'; } > "$d/switch"
            chmod 755 "$d/switch"
        fi
        HOSTIP=192.168.1.50
        ipurl(){ printf '%s\n' "${1:-}"; }
        systemctl(){ [ "$1" = is-active ] && [ -e "$d/unit-active" ]; }
        curl(){ printf '{"tcp":[{"status":"running"},{"status":"running"},{"status":"running"},{"status":"running"},{"status":"running"},{"status":"running"}]}\n'; }
        timeout(){ shift; "$@"; }
        # shellcheck disable=SC1090
        . "$BLOCK"
        printf '%s\n' "$RACBLOCK"
    )
}
scene(){   # scene <name> <rac-number|-> [state lines...]
    local d="$T/$1" n="$2"; shift 2
    mkdir -p "$d/marks"
    [ "$n" = - ] || { echo "$n" > "$d/marks/rac-number"; echo "wsprdaemon (secure)" > "$d/marks/rac-tier"; }
    [ $# -gt 0 ] && printf '%s\n' "$@" > "$d/state"
    echo "$d"
}

echo "── on: the tunnel runs, and the panel says how to turn it off ─────"
d=$(scene on 507 state=on registered=yes tunnel=running channels_up=6 channels_declared=6 changed_at=2026-10-09T18:22:05Z)
out=$(panel "$d")
has   "it reads ON with the RAC number and gateway" "$out" "Remote access   ON — RAC 507 on gw2.wsprdaemon.org  (wsprdaemon (secure))"
has   "it counts the channels the switch counted"   "$out" "status   6/6 channels up"
has   "it names the command, and where to type it"  "$out" "log in to the decoder VM (ssh -p 2222 sigmond@192.168.1.50) and type:  smd remote off"
has   "the admin channels keep their whole command" "$out" "ssh -p 51307 root@gw2.wsprdaemon.org"
has   "the audience split survives"                 "$out" "ADMINISTRATORS ONLY"
has   "all four VM channels are listed"             "$out" "magnetometer :50307"
lacks "it prints no fault word"                     "$out" "OFFLINE"
[ "$(cat "$d/switch.calls")" = status ] && ok "the panel asks the switch for status, once, and nothing else" \
    || bad "the panel asks the switch for status, once, and nothing else" "$(cat "$d/switch.calls" 2>/dev/null)"

d=$(scene on-partial 507 state=on registered=yes tunnel=running channels_up=4 channels_declared=6)
has   "a partial tunnel shows its real count"       "$(panel "$d")" "status   4/6 channels up"

echo "── off: a decision, never a fault ─────────────────────────────────"
d=$(scene off 507 state=off registered=yes tunnel=stopped channels_up=0 channels_declared=6 changed_at=2026-10-09T18:22:05Z changed_by=vm)
out=$(panel "$d")
has   "it says OFF, by the operator's choice"       "$out" "Remote access   OFF, by the operator's choice (since 2026-10-09T18:22:05Z) — not a fault"
has   "it says the registration stays"              "$out" "The registration stays (RAC 507 on gw2.wsprdaemon.org)."
has   "it names the command that turns it on"       "$out" "and type:  smd remote on"
lacks "it prints no fault word"                     "$out" "OFFLINE"
lacks "it sends nobody to the journal"              "$out" "journalctl"
lacks "it lists no channel nobody can reach"        "$out" "ADMINISTRATORS ONLY"

d=$(scene off-never - state=off registered=no tunnel=stopped wish_source=units)
touch "$d/no-toml"
out=$(panel "$d")
has   "a station that never registered says so"     "$out" "Remote access   off — this station has not registered for it"
has   "and still names the command"                 "$out" "and type:  smd remote on"
lacks "it does not send the reader to the wizard"   "$out" "sigmond-setup --reconfigure"

echo "── down: wanted on and not up stays the fault ─────────────────────"
d=$(scene down-stopped 507 state=down registered=yes tunnel=stopped channels_up=0 channels_declared=6)
out=$(panel "$d")
has   "a stopped tunnel reads WANTED ON, BUT NOT UP" "$out" "WANTED ON, BUT NOT UP — the tunnel service does not run (RAC 507)"
has   "it gives a whole command for another computer" "$out" "ssh root@192.168.1.50 'journalctl -u sigmond-rac-host -n 50'"

d=$(scene down-running 507 state=down registered=yes tunnel=running channels_up=0 channels_declared=6)
has   "a running tunnel with no channel says 0/6"   "$(panel "$d")" "WANTED ON, BUT NOT UP — RAC 507 on gw2.wsprdaemon.org: 0/6 channels accepted"

d=$(scene down-unregistered - state=down registered=no tunnel=stopped)
touch "$d/no-toml"
out=$(panel "$d")
has   "an unregistered station says so"             "$out" "WANTED ON, NOT REGISTERED YET — no gateway has answered"
has   "and says the host keeps trying"              "$out" "tries again every 10 minutes"
lacks "it does not send the reader to the wizard"   "$out" "sigmond-setup --reconfigure"

echo "── a host without the switch script keeps the v3.70 text ──────────"
d=$(scene legacy-up 507); touch "$d/no-switch" "$d/unit-active"
out=$(panel "$d")
has   "a running tunnel reads online, as before"    "$out" "status   online — 6/6 channels up"
d=$(scene legacy-down 507); touch "$d/no-switch"
has   "a stopped one reads OFFLINE, as before"      "$(panel "$d")" "status   OFFLINE — check: journalctl -u sigmond-rac-host -n 50"
d=$(scene legacy-none -); touch "$d/no-switch" "$d/no-toml"
has   "an unconfigured one reads LAN-only, as before" "$(panel "$d")" "not configured — this station is LAN-only"
d=$(scene switch-silent 507)          # a switch script that leaves no state file
has   "a switch that leaves no state falls back to the old text" "$(panel "$d")" "status   OFFLINE"

echo "── positive control ───────────────────────────────────────────────"
# The fixture must reproduce the defect, or the 'ok' lines above prove
# nothing about it.  This is the v3.70 panel's own expression: fed the very
# scene of a deliberate off, it must print the fault text.
old_rstat(){
    local d="$1" RSTAT
    systemctl(){ [ "$1" = is-active ] && [ -e "$d/unit-active" ]; }
    RSTAT="OFFLINE — check: journalctl -u sigmond-rac-host -n 50"
    if systemctl is-active --quiet sigmond-rac-host 2>/dev/null; then RSTAT="online"; fi
    printf '%s\n' "$RSTAT"
}
case "$(old_rstat "$T/off")" in
    OFFLINE*) ok "control: the v3.70 expression calls a deliberate off OFFLINE" ;;
    *) bad "control: the v3.70 expression calls a deliberate off OFFLINE" "this fixture does not reproduce the defect" ;;
esac
# And the checks above must be able to fail: against a block that ignores the
# switch, the off scene's first check must not hold.
sed 's/^case "\$RSTATE" in$/case "" in/' "$T/block.sh" > "$T/block.mut"
if cmp -s "$T/block.sh" "$T/block.mut"; then
    bad "control: the mutation applies" "the block no longer branches on \$RSTATE in the form this control edits"
else
    out=$(BLOCK="$T/block.mut" panel "$T/off")
    case "$out" in
        *"by the operator's choice"*) bad "control: a block that ignores the switch fails the off check" "it still passed" ;;
        *OFFLINE*) ok "control: a block that ignores the switch prints OFFLINE for a deliberate off" ;;
        *) bad "control: a block that ignores the switch fails the off check" "unexpected: $out" ;;
    esac
fi

echo "── what pm-align still needs from this file ───────────────────────"
# A station's pm-align cuts these four files out of firstboot-v3.sh by their
# heredoc lines (sigmond scripts/proxmox/pm-align.py FIRSTBOOT_FILES).  It
# refuses a release where one has gone.
for start in "cat > /usr/local/lib/sigmond-net.sh <<'NETLIBEOF'" \
             "cat > /usr/local/sbin/sigmond-issue <<'ISSEOF'" \
             "cat > /etc/systemd/system/sigmond-issue.service <<'ISVCEOF'" \
             "cat > /etc/systemd/system/sigmond-issue.timer <<'ITEOF'"; do
    if [ "$(grep -cxF "$start" "$SRC")" = 1 ]; then ok "firstboot still writes: ${start%% <<*}"
    else bad "firstboot still writes: ${start%% <<*}" "pm-align on every station would refuse this release"; fi
done
# The block sits inside the panel script, where pm-align picks it up.
awk '/^cat > \/usr\/local\/sbin\/sigmond-issue <<.ISSEOF.$/{f=1;next} /^ISSEOF$/{f=0} f' "$SRC" > "$T/issue"
grep -q '^# >>> rac_block' "$T/issue" && ok "the block ships inside sigmond-issue" \
    || bad "the block ships inside sigmond-issue" "the markers stand outside the ISSEOF heredoc"

echo
echo "test-panel-remote.sh: $pass passed, $fail failed"
[ "$fail" = 0 ]
