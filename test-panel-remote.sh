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
# at <seconds> : the UTC stamp the switch writes as checked_at, that many
# seconds from now (negative = in the past).
at(){ date -u -d "@$(( $(date -u +%s) + $1 ))" +%Y-%m-%dT%H:%M:%SZ; }

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
# switch script), no-exec (the script is there without its execute bit),
# switch-leaves (the script exits 1 and writes nothing), preseed (the state
# file already stands in the run dir before the panel asks), no-toml,
# unit-active (for the text of v3.70 and before).  marks/rac-pairing holds
# the outcome the wizard's pairing recorded; scene() writes `paired`, and
# unpaired() below replaces or removes it.
# $BLOCK names the block to run; the control below points it at a mutant.
# The stub switch records its arguments (switch.calls) and what it inherited
# (switch.env); the stub timeout records its own (timeout.calls).  The panel
# runs with stdin on a scratch file and fd 9 open, as sigmond-issue does with
# its lock, so the stub can tell whether the block took them away.
BLOCK="$T/block.sh"
panel(){
    local d="$1"
    (
        export RAC_MARKS="$d/marks" RAC_STATE_FILE="$d/run/rac-state" RAC_TOML="$d/frpc-host.toml"
        export RAC_SWITCH="$d/switch"
        mkdir -p "$d/marks" "$d/run"
        : > "$d/stdin-marker"; exec 0< "$d/stdin-marker" 9> "$d/lock9"
        [ -e "$d/no-toml" ] || cp "$T/frpc-host.toml" "$d/frpc-host.toml"
        if [ ! -e "$d/no-switch" ]; then
            { echo '#!/bin/bash'
              echo "echo \"\$*\" >> '$d/switch.calls'"
              echo "echo \"stdin=\$(readlink /proc/\$\$/fd/0) fd9=\$([ -e /proc/\$\$/fd/9 ] && echo open || echo closed)\" >> '$d/switch.env'"
              if [ -e "$d/switch-leaves" ]; then echo 'exit 1'
              else echo "[ -e '$d/state' ] && cp '$d/state' '$d/run/rac-state'"; echo 'exit 0'; fi; } > "$d/switch"
            chmod 755 "$d/switch"
            [ -e "$d/no-exec" ] && chmod 644 "$d/switch"
        fi
        [ -e "$d/preseed" ] && cp "$d/state" "$d/run/rac-state"
        HOSTIP=192.168.1.50
        ipurl(){ printf '%s\n' "${1:-}"; }
        systemctl(){ [ "$1" = is-active ] && [ -e "$d/unit-active" ]; }
        curl(){ printf '{"tcp":[{"status":"running"},{"status":"running"},{"status":"running"},{"status":"running"},{"status":"running"},{"status":"running"}]}\n'; }
        timeout(){ echo "$*" >> "$d/timeout.calls"; [ "${1:-}" = -k ] && shift 2; shift; "$@"; }
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
    # The two machines have paired, as on every station the wizard finished.
    echo "paired 2026-10-09T18:20:00Z" > "$d/marks/rac-pairing"
    echo "$d"
}
# unpaired <scene dir> <how> : what stands where the pairing's outcome belongs.
#   none     no file: the wizard's pairing never ran on this host
#   failed   the last pairing failed
#   <text>   that text, as the file's whole content
unpaired(){
    case "$2" in
        none)   rm -f "$1/marks/rac-pairing" ;;
        failed) echo "not-paired 2026-10-09T18:20:00Z the guest agent in VM 100 does not answer" > "$1/marks/rac-pairing" ;;
        *)      printf '%s' "$2" > "$1/marks/rac-pairing" ;;
    esac
}
VMLINE="log in to the decoder VM (ssh -p 2222 sigmond@192.168.1.50) and type:"
HOSTON="type on another computer:  ssh root@192.168.1.50 'sigmond-setup --rac-on'"
HOSTOFF="type on another computer:  ssh root@192.168.1.50 'sigmond-setup --rac-off'"

echo "── on: the tunnel runs, and the panel does NOT explain switching it off ─"
# ⛔ THIS ASSERTION IS INVERTED ON PURPOSE (rob, 2026-10-15: "Remote access
# useful, turn off -- forget about turning it off").  Until v3.72 the ON block
# printed a full off-switch command.  It was the widest row on the panel: when
# the host is paired it embeds the VM ssh command, and therefore a SECOND copy
# of the 39-character IPv6 literal, all so a reader standing at a working
# station can learn how to break their own access.  The OFF states keep their
# "to turn it on" line (asserted further down) -- that one is the way out of a
# state the operator is actually stuck in.
d=$(scene on 507 state=on registered=yes tunnel=running channels_up=6 channels_declared=6 changed_at=2026-10-09T18:22:05Z "checked_at=$(at 0)")
out=$(panel "$d")
has   "it reads ON with the RAC number and gateway" "$out" "Remote access   ON — RAC 507 on gw2.wsprdaemon.org  (wsprdaemon (secure))"
has   "it counts the channels the switch counted"   "$out" "status   6/6 channels up"
lacks "it does NOT tell a working station how to turn itself off" "$out" "to turn it off"
lacks "...and so carries no second copy of the host address"      "$out" "smd remote off"
has   "the admin channels keep their whole command" "$out" "ssh -p 51307 root@gw2.wsprdaemon.org"
has   "the audience split survives"                 "$out" "ADMINISTRATORS ONLY"
has   "all four VM channels are listed"             "$out" "magnetometer :50307"
lacks "it prints no fault word"                     "$out" "OFFLINE"
[ "$(cat "$d/switch.calls")" = status ] && ok "the panel asks the switch for status, once, and nothing else" \
    || bad "the panel asks the switch for status, once, and nothing else" "$(cat "$d/switch.calls" 2>/dev/null)"
# The call is bounded, and the switch inherits neither the panel's stdin nor
# its lock: an orphan holding fd 9 would wedge every later refresh.
[ "$(cat "$d/timeout.calls" 2>/dev/null)" = "-k 5 20 $d/switch status" ] \
    && ok "the switch runs under timeout -k 5 20" \
    || bad "the switch runs under timeout -k 5 20" "$(cat "$d/timeout.calls" 2>/dev/null)"
[ "$(cat "$d/switch.env" 2>/dev/null)" = "stdin=/dev/null fd9=closed" ] \
    && ok "the switch gets no stdin and not the panel's lock on fd 9" \
    || bad "the switch gets no stdin and not the panel's lock on fd 9" "$(cat "$d/switch.env" 2>/dev/null)"

d=$(scene on-partial 507 state=on registered=yes tunnel=running channels_up=4 channels_declared=6 "checked_at=$(at 0)")
has   "a partial tunnel shows its real count"       "$(panel "$d")" "status   4/6 channels up"

echo "── off: a decision, never a fault ─────────────────────────────────"
d=$(scene off 507 state=off registered=yes tunnel=stopped channels_up=0 channels_declared=6 changed_at=2026-10-09T18:22:05Z changed_by=vm "checked_at=$(at 0)")
out=$(panel "$d")
has   "it says OFF, by the operator's choice"       "$out" "Remote access   OFF, by the operator's choice (since 2026-10-09T18:22:05Z) — not a fault"
has   "it says the registration stays"              "$out" "The registration stays (RAC 507 on gw2.wsprdaemon.org)."
has   "it names the command that turns it on"       "$out" "and type:  smd remote on"
lacks "it prints no fault word"                     "$out" "OFFLINE"
lacks "it sends nobody to the journal"              "$out" "journalctl"
lacks "it lists no channel nobody can reach"        "$out" "ADMINISTRATORS ONLY"
lacks "an ordinary off carries no warning"          "$out" "NOTE:"

d=$(scene off-never - state=off registered=no tunnel=stopped wish_source=units "checked_at=$(at 0)")
touch "$d/no-toml"
out=$(panel "$d")
has   "a station that never registered says so"     "$out" "Remote access   off — this station has not registered for it"
has   "and still names the command"                 "$out" "and type:  smd remote on"
lacks "it does not send the reader to the wizard"   "$out" "sigmond-setup --reconfigure"

# The switch's exit-4 case, or a unit someone started by hand: off, and the
# tunnel runs.  Calling that "not a fault" while the door stands open misleads.
d=$(scene off-open 507 state=off registered=yes tunnel=running channels_up=6 channels_declared=6 changed_at=2026-10-09T18:22:05Z changed_by=vm "checked_at=$(at 0)")
out=$(panel "$d")
has   "an off with a running tunnel still says OFF"  "$out" "Remote access   OFF, by the operator's choice (since 2026-10-09T18:22:05Z)"
lacks "but no longer calls it 'not a fault'"         "$out" "not a fault"
has   "it says the station can still be reached"     "$out" "   NOTE: the tunnel service still runs, so this station can still be reached."
has   "it gives the whole command that closes it"    "$out" "   ==> to close it, log in to the decoder VM (ssh -p 2222 sigmond@192.168.1.50) and type:  smd remote off"
lacks "it does not also offer to turn it on"         "$out" "to turn it on"
lacks "it lists no channel"                          "$out" "ADMINISTRATORS ONLY"

echo "── down: wanted on and not up stays the fault ─────────────────────"
d=$(scene down-stopped 507 state=down registered=yes tunnel=stopped channels_up=0 channels_declared=6 "checked_at=$(at 0)")
out=$(panel "$d")
has   "a stopped tunnel reads WANTED ON, BUT NOT UP" "$out" "WANTED ON, BUT NOT UP — the tunnel service does not run (RAC 507)"
has   "it gives a whole command for another computer" "$out" "ssh root@192.168.1.50 'journalctl -u sigmond-rac-host -n 50'"

d=$(scene down-running 507 state=down registered=yes tunnel=running channels_up=0 channels_declared=6 "checked_at=$(at 0)")
has   "a running tunnel with no channel says 0/6"   "$(panel "$d")" "WANTED ON, BUT NOT UP — RAC 507 on gw2.wsprdaemon.org: 0/6 channels accepted"

d=$(scene down-unregistered - state=down registered=no tunnel=stopped "checked_at=$(at 0)")
touch "$d/no-toml"
out=$(panel "$d")
has   "an unregistered station says so"             "$out" "WANTED ON, NOT REGISTERED YET — no gateway has answered"
has   "and says the host keeps trying"              "$out" "tries again every 10 minutes"
lacks "it does not send the reader to the wizard"   "$out" "sigmond-setup --reconfigure"
# `off` never touches the retry timer: the host registers when a gateway
# answers, and then stays off.  The panel must promise that and no more.
has   "it says what off does for such a station"    "$out" "   To keep the tunnel down once the station registers, $VMLINE  smd remote off"
lacks "it does not promise that off stops the retries" "$out" "stop it trying"

echo "── the VM's command only where a pairing stands ───────────────────"
# `smd remote` reaches the host through the pairing.  A host with the old
# layout has no private link and can never pair; a pairing that failed leaves
# the VM answering "holds no pairing".  There the panel names the host's own
# switch, which works on every host.  One line of the wizard's decides:
# marks/rac-pairing, first word `paired`.
# ⛔ `u-on` IS DELIBERATELY ABSENT FROM THIS TABLE.  A healthy ON station now
# prints no switch line at all, so there is no command here to attribute to
# either the host or the VM.  It gets its own check below instead, which is
# stronger: NEITHER command may appear, under EVERY pairing state.
states=(
 "u-off|507|state=off registered=yes tunnel=stopped channels_up=0 channels_declared=6 changed_at=2026-10-09T18:22:05Z|==> to turn it on, |on"
 "u-off-never|-|state=off registered=no tunnel=stopped wish_source=units|==> to turn it on, |on"
 "u-off-open|507|state=off registered=yes tunnel=running channels_up=6 channels_declared=6|==> to close it, |off"
 "u-down-unreg|-|state=down registered=no tunnel=stopped|To keep the tunnel down once the station registers, |off"
)
for how in none failed; do
    for row in "${states[@]}"; do
        IFS='|' read -r name racn lines lead word <<<"$row"
        # shellcheck disable=SC2086
        d=$(scene "$name-$how" "$racn" $lines "checked_at=$(at 0)")
        [ "$racn" = - ] && touch "$d/no-toml"
        unpaired "$d" "$how"
        out=$(panel "$d")
        [ "$word" = on ] && want="$HOSTON" || want="$HOSTOFF"
        has   "$name, pairing $how: the host's own switch, as a whole command" "$out" "${lead}${want}"
        lacks "$name, pairing $how: no smd remote"                              "$out" "smd remote"
        lacks "$name, pairing $how: no login to the decoder VM"                 "$out" "log in to the decoder VM"
    done
done
# The same five states on a paired station name the VM's command and never the host's.
for row in "${states[@]}"; do
    IFS='|' read -r name racn lines lead word <<<"$row"
    # shellcheck disable=SC2086
    d=$(scene "$name-paired" "$racn" $lines "checked_at=$(at 0)")
    [ "$racn" = - ] && touch "$d/no-toml"
    out=$(panel "$d")
    has   "$name, paired: the VM's command"            "$out" "${lead}${VMLINE}  smd remote $word"
    lacks "$name, paired: not the host's own switch"   "$out" "sigmond-setup --rac-"
done
# A healthy ON station offers NO off-switch, whatever its pairing state --
# the one case where pairing genuinely makes no difference, because neither
# command is printed. (rob 2026-10-15)
for how in none failed paired; do
    d=$(scene "u-on-noswitch-$how" 507 state=on registered=yes tunnel=running \
              channels_up=6 channels_declared=6 "checked_at=$(at 0)")
    [ "$how" = paired ] || unpaired "$d" "$how"
    out=$(panel "$d")
    lacks "ON/$how: no off-switch command at all"   "$out" "to turn it off"
    lacks "ON/$how: not the VM's smd remote off"    "$out" "smd remote off"
    lacks "ON/$how: not the host's own switch"      "$out" "sigmond-setup --rac-off"
    # ...but it must still say it is ON and count the channels, or we have
    # deleted the block rather than trimmed it.
    has   "ON/$how: still reports the state"        "$out" "Remote access   ON — RAC 507"
    has   "ON/$how: still counts the channels"      "$out" "status   6/6 channels up"
done

# Only the first word `paired` earns the VM's command.
for text in "" "paired" "pairedX 2026-10-09T18:20:00Z" "  paired 2026-10-09T18:20:00Z" "PAIRED 2026-10-09T18:20:00Z" \
            "not-paired 2026-10-09T18:20:00Z paired once before" $'\npaired 2026-10-09T18:20:00Z'; do
    d=$(scene "word-$(printf '%s' "$text" | cksum | cut -d' ' -f1)" 507 state=off registered=yes tunnel=stopped channels_declared=6 "checked_at=$(at 0)")
    unpaired "$d" "$text"
    out=$(panel "$d")
    if [ "$text" = paired ]; then has "the word 'paired' alone counts as paired" "$out" "$VMLINE  smd remote on"
    else has "a file reading '$(printf '%s' "$text" | head -c 24 | tr '\n' '/')' is no pairing" "$out" "$HOSTON"; fi
done
# The fault lines that name no switch stay as they are, paired or not.
d=$(scene u-down-stopped 507 state=down registered=yes tunnel=stopped channels_up=0 channels_declared=6 "checked_at=$(at 0)")
unpaired "$d" none
out=$(panel "$d")
has   "a stopped tunnel on an unpaired host keeps its check line" "$out" "==> check: ssh root@192.168.1.50 'journalctl -u sigmond-rac-host -n 50'"
lacks "and names no switch"                          "$out" "sigmond-setup --rac-"

echo "── a file the switch did not just write is never shown as current ─"
# `status` stamps checked_at at every run.  A call that hangs, fails, or
# exits 0 without writing leaves the OLD file standing; the panel reads the
# stamp, and anything outside 300 seconds of now (either side) is no answer.
NR="Remote access   STATE NOT READ — the switch gave no fresh answer"
CMD="==> check: ssh root@192.168.1.50 '/usr/local/sbin/sigmond-rac-switch status'"
s=$(at -600)
d=$(scene stale-off 507 state=off registered=yes tunnel=stopped channels_up=0 channels_declared=6 changed_at=2026-10-09T18:22:05Z "checked_at=$s")
out=$(panel "$d")
has   "a stale off reads STATE NOT READ, with its last stamp" "$out" "$NR (last: $s)"
has   "it gives a whole command for another computer"  "$out" "$CMD"
lacks "it does not call a stale off a decision"       "$out" "not a fault"
lacks "it does not say the operator chose it"         "$out" "by the operator's choice"
lacks "it prints no OFFLINE"                          "$out" "OFFLINE"
lacks "it sends nobody to the journal"                "$out" "journalctl"
s=$(at -600)
d=$(scene stale-on 507 state=on registered=yes tunnel=running channels_up=6 channels_declared=6 "checked_at=$s")
out=$(panel "$d")
has   "a stale on reads STATE NOT READ too"           "$out" "$NR (last: $s)"
lacks "it lists no channel"                           "$out" "ADMINISTRATORS ONLY"
lacks "it lists no VM channel"                        "$out" "magnetometer"
lacks "it does not claim ON"                          "$out" "ON — RAC"
s=$(at 600)
d=$(scene future 507 state=on registered=yes tunnel=running channels_up=6 channels_declared=6 "checked_at=$s")
has   "a stamp 10 minutes ahead is no answer either"  "$(panel "$d")" "$NR (last: $s)"
d=$(scene edge-past 507 state=off registered=yes tunnel=stopped channels_declared=6 "checked_at=$(at -240)")
has   "a stamp 4 minutes old still reads as current"   "$(panel "$d")" "Remote access   OFF, by the operator's choice"
d=$(scene edge-future 507 state=off registered=yes tunnel=stopped channels_declared=6 "checked_at=$(at 240)")
has   "and so does one 4 minutes ahead"                "$(panel "$d")" "Remote access   OFF, by the operator's choice"
d=$(scene no-stamp 507 state=off registered=yes tunnel=stopped channels_declared=6)
out=$(panel "$d")
has   "a file with no checked_at reads STATE NOT READ" "$out" "$NR (last: none)"
lacks "it does not call it a decision"                "$out" "not a fault"
d=$(scene bad-stamp 507 state=off registered=yes tunnel=stopped channels_declared=6 "checked_at=now")
out=$(panel "$d")
has   "a stamp that is no time (the word 'now') is refused" "$out" "$NR (last: now)"
lacks "it does not call it a decision"                "$out" "not a fault"
s=$(at 0)
d=$(scene unknown-state 507 state=sideways registered=yes tunnel=stopped channels_declared=6 "checked_at=$s")
has   "a fresh file with an unknown state reads STATE NOT READ" "$(panel "$d")" "$NR (last: $s)"
d=$(scene switch-silent 507)          # a switch script that leaves no state file
out=$(panel "$d")
has   "a switch that leaves no file reads STATE NOT READ" "$out" "$NR (last: none)"
lacks "it falls back to no OFFLINE text"              "$out" "OFFLINE"
# The reviewer's reproduction: a three-day-old file, and a switch that fails
# and leaves it where it stands.
s=$(at -259200)
d=$(scene old-left 507 state=off registered=yes tunnel=stopped channels_up=0 channels_declared=6 changed_at=2026-10-06T18:22:05Z "checked_at=$s")
touch "$d/preseed" "$d/switch-leaves"
out=$(panel "$d")
has   "a three-day-old file left by a failing switch is refused" "$out" "$NR (last: $s)"
lacks "it does not print the old OFF"                 "$out" "not a fault"

echo "── a host without the switch script keeps the v3.70 text ──────────"
d=$(scene legacy-up 507); touch "$d/no-switch" "$d/unit-active"
out=$(panel "$d")
has   "a running tunnel reads online, as before"    "$out" "status   online — 6/6 channels up"
d=$(scene legacy-down 507); touch "$d/no-switch"
has   "a stopped one reads OFFLINE, as before"      "$(panel "$d")" "status   OFFLINE — check: journalctl -u sigmond-rac-host -n 50"
d=$(scene legacy-none -); touch "$d/no-switch" "$d/no-toml"
has   "an unconfigured one reads LAN-only, as before" "$(panel "$d")" "not configured — this station is LAN-only"
# The pairing's record plays no part in that text: byte for byte the same with
# a `paired` file, a `not-paired` one and none.
for name in legacy-up legacy-down legacy-none; do
    with=$(panel "$T/$name")
    unpaired "$T/$name" failed; failed=$(panel "$T/$name")
    unpaired "$T/$name" none;   without=$(panel "$T/$name")
    if [ -n "$with" ] && [ "$with" = "$failed" ] && [ "$with" = "$without" ]; then ok "$name: the v3.70 text does not read the pairing's record"
    else bad "$name: the v3.70 text does not read the pairing's record" "$(diff <(printf '%s\n' "$with") <(printf '%s\n' "$without") | head -4)"; fi
    lacks "$name: it names neither switch"           "$with" "sigmond-setup --rac-"
done
# A file that is not executable is no switch.  The state file stands fresh in
# the run dir, so only the execute test keeps it out of the panel.
d=$(scene no-exec 507 state=off registered=yes tunnel=stopped channels_up=0 channels_declared=6 "checked_at=$(at 0)")
touch "$d/no-exec" "$d/preseed" "$d/unit-active"
out=$(panel "$d")
has   "a script without its execute bit leaves the v3.70 text"  "$out" "status   online — 6/6 channels up"
lacks "and the state file plays no part"            "$out" "by the operator's choice"
lacks "nor does the panel print STATE NOT READ"     "$out" "STATE NOT READ"
[ ! -e "$d/switch.calls" ] && ok "the panel never ran it" || bad "the panel never ran it" "$(cat "$d/switch.calls")"

echo "── the channel lists do not move ──────────────────────────────────"
# With the tunnel on, the lists and the audience split are the v3.70 text, byte
# for byte: compare what follows the status lines, on the same inputs, between
# the switch branch and the branch every panel ran up to v3.70.
d=$(scene lists-on 507 state=on registered=yes tunnel=running channels_up=6 channels_declared=6 "checked_at=$(at 0)")
echo wd-registrar > "$d/marks/rac-registrar"
on_out=$(panel "$d")
d=$(scene lists-legacy 507); touch "$d/no-switch" "$d/unit-active"
echo wd-registrar > "$d/marks/rac-registrar"
legacy_out=$(panel "$d")
# Both blocks now open with the same three lines -- blank, header, status.
# The ON block used to carry a fourth (the off-switch command), which is why
# these offsets differed; it was dropped in v3.73 (rob 2026-10-15).
on_tail=$(printf '%s\n' "$on_out" | tail -n +4)         # past: blank, header, status
legacy_tail=$(printf '%s\n' "$legacy_out" | tail -n +4) # past: blank, header, status
if [ -n "$on_tail" ] && [ "$on_tail" = "$legacy_tail" ]; then ok "the lists and the audience split match v3.70 byte for byte"
else bad "the lists and the audience split match v3.70 byte for byte" "$(diff <(printf '%s\n' "$legacy_tail") <(printf '%s\n' "$on_tail") | head -5)"; fi
has   "the on status line keeps the registrar"      "$on_out" "status   6/6 channels up · registrar wd-registrar"

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

# And the pairing checks must be able to fail: against a block that takes every
# host for a paired one, an unpaired scene still prints the VM's command.
sed 's/^_rpaired=no$/_rpaired=yes/' "$T/block.sh" > "$T/block.mut2"
if cmp -s "$T/block.sh" "$T/block.mut2"; then
    bad "control: the pairing mutation applies" "the block no longer starts from _rpaired=no"
else
    out=$(BLOCK="$T/block.mut2" panel "$T/u-off-none")
    case "$out" in
        *"smd remote on"*) ok "control: a block that takes every host for paired names the VM's command on an unpaired one" ;;
        *) bad "control: a block that takes every host for paired fails the unpaired check" "unexpected: $out" ;;
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
