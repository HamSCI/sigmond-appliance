#!/bin/bash
# test-qga-rig-lines.sh — the scripts the nested rig runs on its Proxmox host
# for the guest-agent checks.  No VM, no root; about a second.
#
# Why: a rig check that cannot fail proves nothing, and a rig run costs forty
# minutes.  Each script here runs against stand-ins for qm, systemctl and the
# panel, once in the state it must report as good and once in the state it
# must report as bad.  The block under test is cut out of test-nested-v3.sh
# from between its two markers, so this runs what the rig sends.
#
#   usage: ./test-qga-rig-lines.sh [path/to/test-nested-v3.sh]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:-$HERE/test-nested-v3.sh}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok(){  printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad(){ printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
has(){   case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing: $3 in: $(printf '%s' "$2" | tr '\n' ' ')" ;; esac; }
lacks(){ case "$2" in *"$3"*) bad "$1" "found: $3" ;; *) ok "$1" ;; esac; }

sed -n '/^# >>> qga_rig/,/^# <<< qga_rig/p' "$SRC" > "$T/block.sh"
[ -s "$T/block.sh" ] || { echo "FAIL: no qga_rig block between its markers in $SRC"; exit 1; }
bash -n "$T/block.sh" || { echo "FAIL: the qga_rig block does not parse"; exit 1; }
. "$T/block.sh"

# The stand-ins.  A scene directory $D holds: deaf (no ping answers), lose-next
# (the next ping alone gets no answer), deaf-at (the poison request with this
# number deafens the agent), unit (what systemctl is-active prints in the VM),
# unit-after (what it prints once the panel has run), panel-heals (a refresh
# brings the agent back and leaves its line), issue.txt (what a refresh paints).
mkdir -p "$T/bin"
cat > "$T/bin/qm" <<'EOF'
#!/bin/bash
case "$1" in
    agent)
        [ -e "$D/deaf" ] && exit 255
        [ -e "$D/lose-next" ] && { rm -f "$D/lose-next"; exit 255; }
        exit 0 ;;
    guest)
        case "$*" in
            *is-active*)
                [ -e "$D/deaf" ] && exit 255
                printf '{\n   "exitcode" : 3,\n   "exited" : 1,\n   "out-data" : "%s\\n"\n}\n' "$(cat "$D/unit" 2>/dev/null)" ;;
            *)
                n=$(( $(cat "$D/count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$D/count"
                printf '%s\0' "$@" > "$D/poison.$n"
                if [ "$n" = "$(cat "$D/deaf-at" 2>/dev/null)" ]; then : > "$D/deaf"; else : > "$D/lose-next"; fi ;;
        esac ;;
esac
EOF
cat > "$T/bin/systemctl" <<'EOF'
#!/bin/bash
echo "$*" >> "$D/systemctl.calls"
EOF
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/bin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/sleep"
cat > "$T/panel" <<'EOF'
#!/bin/bash
# qga_reset: the word the rig looks for in a panel that carries the fix
echo "vmid=$SIGMOND_VMID" >> "$D/panel.calls"
[ -e "$D/issue.txt" ] && cp "$D/issue.txt" "$QGA_ISSUE"
[ -e "$D/unit-after" ] && cp "$D/unit-after" "$D/unit"
if [ -e "$D/panel-heals" ]; then rm -f "$D/deaf"; echo "2026-10-10T03:00:00Z panel" > "$QGA_NOTE"; fi
exit 0
EOF
chmod 755 "$T/bin/"* "$T/panel"

# run <scene> <probe function> [args...] : the probe's answer in the scene.
run(){
    local d="$T/$1"; shift; local probe="$1"; shift
    mkdir -p "$d"
    "$probe" | D="$d" QGA_PANEL="${QGA_PANEL_OVERRIDE:-$T/panel}" QGA_ISSUE="$d/issue" QGA_NOTE="$d/qga-reset" \
        PATH="$T/bin:$PATH" bash -s 100 "$@" 2>&1
}

echo "== is the fix in this image's panel?"
has   "a panel with the reset: PANELFIX:1"            "$(run p1 qga_probe_panel)" "PANELFIX:1"
printf '#!/bin/bash\n# a panel from v3.70\n' > "$T/oldpanel"
has   "a panel from before v3.71: PANELFIX:0"         "$(QGA_PANEL_OVERRIDE=$T/oldpanel run p2 qga_probe_panel)" "PANELFIX:0"
has   "no panel at all: PANELFIX:0"                   "$(QGA_PANEL_OVERRIDE=$T/absent run p3 qga_probe_panel)" "PANELFIX:0"

echo "== twelve refreshes, a ping after each"
out=$(run r1 qga_probe_refresh)
has   "a hearing agent: SILENT:0"                     "$out" "SILENT:0"
has   "no reset happened: NOTE:none"                  "$out" "NOTE:none"
has   "the answer ends END:1"                         "$out" "END:1"
[ "$(wc -l < "$T/r1/panel.calls")" = 12 ] && ok "the panel ran twelve times" || bad "the panel ran twelve times" "$(wc -l < "$T/r1/panel.calls")"
grep -qx 'vmid=100' "$T/r1/panel.calls" && ok "the panel got the VM's number" || bad "the panel got the VM's number" "$(head -1 "$T/r1/panel.calls")"
[ "$(tr '\n' '|' < "$T/r1/systemctl.calls")" = "stop sigmond-issue.timer|start sigmond-issue.timer|" ] \
    && ok "the panel's timer stops, and starts again at the end" \
    || bad "the panel's timer stops, and starts again at the end" "$(tr '\n' '|' < "$T/r1/systemctl.calls")"
mkdir -p "$T/r2"; : > "$T/r2/deaf"
has   "a deaf agent: SILENT:12"                       "$(run r2 qga_probe_refresh)" "SILENT:12"
mkdir -p "$T/r3"; echo "2026-10-10T02:00:00Z panel" > "$T/r3/qga-reset"
has   "a reset's line comes back whole"               "$(run r3 qga_probe_refresh)" "NOTE:2026-10-10T02:00:00Z panel"

echo "== deafening the agent"
mkdir -p "$T/d1"; echo 3 > "$T/d1/deaf-at"; : > "$T/d1/qga-reset"; : > "$T/d1/qga-reset.seen"
out=$(run d1 qga_probe_deafen 40)
has   "the third request deafens: DEAF:3"             "$out" "DEAF:3"
[ "$(cat "$T/d1/count")" = 3 ] && ok "it stops at the request that did it" || bad "it stops at the request that did it" "$(cat "$T/d1/count")"
LC_ALL=C grep -q -P '[^\x00-\x7F]' "$T/d1/poison.1" && ok "the request holds bytes above 0x7F (else it deafens nothing)" \
    || bad "the request holds bytes above 0x7F" "$(tr '\0' ' ' < "$T/d1/poison.1")"
[ "$(tr '\n' '|' < "$T/d1/systemctl.calls")" = "stop sigmond-issue.timer pm-heartbeat.timer|" ] \
    && ok "both timers stop, and stay stopped for the heal" \
    || bad "both timers stop, and stay stopped" "$(tr '\n' '|' < "$T/d1/systemctl.calls")"
[ ! -e "$T/d1/qga-reset" ] && [ ! -e "$T/d1/qga-reset.seen" ] && ok "an earlier reset's line is cleared first" || bad "an earlier reset's line is cleared first" "still there"
mkdir -p "$T/d2"; echo 99 > "$T/d2/deaf-at"
out=$(run d2 qga_probe_deafen 5)
has   "one lost ping per try is not deafness: DEAF:0" "$out" "DEAF:0"
[ "$(cat "$T/d2/count")" = 5 ] && ok "it gives up after the tries it was given" || bad "it gives up after the tries it was given" "$(cat "$T/d2/count")"

echo "== the heal"
mkdir -p "$T/h1"; : > "$T/h1/deaf"; : > "$T/h1/panel-heals"; echo "all quiet" > "$T/h1/issue.txt"
out=$(run h1 qga_probe_heal)
has   "a refresh that heals: HEARS:1"                 "$out" "HEARS:1"
has   "the reset's line names the panel"              "$out" "NOTE:2026-10-10T03:00:00Z panel"
has   "the panel no longer says the agent is silent"  "$out" "PANELSILENT:0"
[ "$(tr '\n' '|' < "$T/h1/systemctl.calls")" = "start sigmond-issue.timer pm-heartbeat.timer|" ] \
    && ok "both timers start again" || bad "both timers start again" "$(tr '\n' '|' < "$T/h1/systemctl.calls")"
mkdir -p "$T/h2"; : > "$T/h2/deaf"; echo " .. the decoder VM's guest agent does not answer, so" > "$T/h2/issue.txt"
out=$(run h2 qga_probe_heal)
has   "a refresh that does not heal: HEARS:0"         "$out" "HEARS:0"
has   "no line of a reset: NOTE:none"                 "$out" "NOTE:none"
has   "the panel says the agent is silent"            "$out" "PANELSILENT:1"
grep -q 'start sigmond-issue.timer pm-heartbeat.timer' "$T/h2/systemctl.calls" && ok "the timers start again all the same" || bad "the timers start again all the same" "not started"

echo "== the bring-up line"
mkdir -p "$T/b1"; echo activating > "$T/b1/unit"; echo " >> STATION IS STILL BUILDING -- this is normal, not a fault." > "$T/b1/issue.txt"
out=$(run b1 qga_probe_bringup)
has   "a running unit reads on both sides"            "$out" "UNIT:activating/activating"
has   "the panel says it builds: BUILDING:1"          "$out" "BUILDING:1"
has   "and raises no ka9q-web alarm: NOWEB:0"         "$out" "NOWEB:0"
mkdir -p "$T/b2"; echo inactive > "$T/b2/unit"; echo " .. bring-up ran WITHOUT the radio: no SDR stood on the USB bus." > "$T/b2/issue.txt"
out=$(run b2 qga_probe_bringup)
has   "a finished unit reads inactive"                "$out" "UNIT:inactive/inactive"
has   "no radio: NOSDR:1"                             "$out" "NOSDR:1"
has   "no radio: BUILDING:0"                          "$out" "BUILDING:0"
mkdir -p "$T/b3"; echo inactive > "$T/b3/unit"; echo " !! BRING-UP FINISHED BUT ka9q-web IS NOT RUNNING" > "$T/b3/issue.txt"
has   "the false alarm of v3.70 would show: NOWEB:1"  "$(run b3 qga_probe_bringup)" "NOWEB:1"
mkdir -p "$T/b4"; : > "$T/b4/deaf"; echo " .. the decoder VM's guest agent does not answer, so" > "$T/b4/issue.txt"
out=$(run b4 qga_probe_bringup)
has   "a deaf agent: no unit state"                   "$out" "UNIT:none/none"
has   "a deaf agent: SILENT:1"                        "$out" "SILENT:1"
mkdir -p "$T/b5"; echo activating > "$T/b5/unit"; echo inactive > "$T/b5/unit-after"
has   "a unit that ends during the refresh shows both" "$(run b5 qga_probe_bringup)" "UNIT:activating/inactive"
for k in RETRY GAVEUP STOPPED; do has "the answer carries a $k token" "$out" "$k:0"; done

echo "== the probes themselves stay ASCII"
[ "$(LC_ALL=C grep -c -P '[^\x00-\x7F]' "$T/block.sh")" = 0 ] && ok "the block holds no byte above 0x7F" \
    || bad "the block holds no byte above 0x7F" "$(LC_ALL=C grep -n -P '[^\x00-\x7F]' "$T/block.sh" | head -2)"

echo
echo "passed $pass, failed $fail"
[ "$fail" = 0 ]
