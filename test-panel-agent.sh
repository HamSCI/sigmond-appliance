#!/bin/bash
# test-panel-agent.sh — the console panel's guest-agent block: every request
# ASCII, one reset before any verdict, and a bring-up line that tells the
# truth.  No VM, no root; a few seconds.
#
# Why: up to v3.70 the panel asked the decoder VM for the last bring-up step
# with a grep for two box-drawing patterns.  Proxmox writes a request that
# holds non-ASCII characters short, and about one time in six the guest agent
# then stands deaf for good (sigmond tasks/plan-guest-agent-requests.md).
# That request never once ran, so nobody had watched the code behind it: its
# `inactive` branch raised "BRING-UP FINISHED BUT ka9q-web IS NOT RUNNING" on
# a station whose bring-up had not started.
#
# The block under test is cut out of firstboot-v3.sh from between its two
# markers, so this runs what ships.  A stub stands in for `qm` and records
# every argument; a stand-in socket plays the agent's side of a reset.
#
#   usage: ./test-panel-agent.sh [path/to/firstboot-v3.sh]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:-$HERE/firstboot-v3.sh}"
T=$(mktemp -d); trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
pass=0; fail=0
ok(){  printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad(){ printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
has(){   case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing: $3" ;; esac; }
lacks(){ case "$2" in *"$3"*) bad "$1" "found: $3" ;; *) ok "$1" ;; esac; }

sed -n '/^# >>> agent_block/,/^# <<< agent_block/p' "$SRC" > "$T/block.sh"
[ -s "$T/block.sh" ] || { echo "FAIL: no agent_block between its markers in $SRC"; exit 1; }
bash -n "$T/block.sh" || { echo "FAIL: the agent_block does not parse"; exit 1; }

# The bytes every reset must send (the same literal stands in sigmond's
# tests/test_qga_reset.py).
RESET_HEX='ff7b2265786563757465223a2267756573742d73796e632d64656c696d69746564222c22617267756d656e7473223a7b226964223a343234327d7d0a'

# agent <scene dir> : the agent's side of the socket.  It records what
# arrives, answers the sync, and from then on the scene's agent hears again.
agent(){
    local d="$1"; mkdir -p "$d/qga"
    python3 - "$d" <<'PY' &
import os, socket, sys
d = sys.argv[1]
srv = socket.socket(socket.AF_UNIX); srv.bind(d + "/qga/100.qga"); srv.listen(1)
srv.settimeout(5)          # a panel that never resets must not hang this test
open(d + "/agent.ready", "w").close()
try:
    c, _ = srv.accept()
except Exception:
    sys.exit(0)
c.settimeout(5)
data = b""
try:
    while not data.endswith(b"\n"):
        got = c.recv(4096)
        if not got: break
        data += got
except Exception:
    pass
open(d + "/reset.bytes", "wb").write(data)
try: os.unlink(d + "/deaf")
except FileNotFoundError: pass
c.sendall(b"\xff" + b'{"return": 4242}\n'); c.close()
PY
    local i; for i in $(seq 1 50); do [ -e "$d/agent.ready" ] && return 0; python3 -c 'import time; time.sleep(0.05)'; done
    echo "FAIL: the stand-in agent did not start"; exit 1
}

# panel <scene dir> : run the block as sigmond-issue would; print what it set.
# A scene holds: deaf (the agent answers nothing), status (the four lines the
# VM would send), sdr (lsusb shows an RX888), rxmark (the wizard's marker).
BLOCK="$T/block.sh"
panel(){
    local d="$1"
    (
        VMID=100
        export SIGMOND_QGA_DIR="$d/qga" SIGMOND_QGA_NOTE="$d/run/qga-reset" SIGMOND_RX888_MARK="$d/rxmark"
        mkdir -p "$d/calls"
        qm(){
            printf '%s\0' "$@" > "$d/calls/$(date +%s%N)"
            case "$1" in
                config) echo 'net0: virtio=AA:BB:CC:DD:EE:FF,bridge=vmbr1' ;;
                agent)  [ -e "$d/deaf" ] && return 255
                        [ "$3" = ping ] && return 0
                        echo '[{"name":"ens18","ip-addresses":[{"ip-address-type":"ipv4","ip-address":"10.99.0.2"}]}]' ;;
                guest)  [ -e "$d/deaf" ] && { echo "QEMU guest agent is not running" >&2; return 255; }
                        case "$*" in
                            *lsusb*) [ -e "$d/sdr" ] && echo '{"exitcode":0,"exited":1,"out-data":"Bus 002 Device 003: ID 04b4:00f1 Cypress\n"}' \
                                                      || echo '{"exitcode":0,"exited":1,"out-data":"Bus 001 Device 001: ID 1d6b:0002 Linux\n"}' ;;
                            *) python3 -c 'import json,sys; print(json.dumps({"exitcode":0,"exited":1,"out-data":open(sys.argv[1]).read()}))' "$d/status" ;;
                        esac ;;
            esac
        }
        timeout(){ printf '%s\n' "$1" >> "$d/timeout.calls"; shift; "$@"; }
        sleep(){ printf '%s\n' "$1" >> "$d/sleep.calls"; }
        ip(){ [ "$*" = "-4 neigh show" ] && echo '10.99.0.2 dev vmbr1 lladdr aa:bb:cc:dd:ee:ff REACHABLE'; }
        . "$BLOCK"
        printf 'VMIP=[%s]\nVMNOTE=[%s]\nBRINGUP=[%s]\nRXWARN=[%s]\n' "$VMIP" "$VMNOTE" "$BRINGUP" "$RXWARN"
    )
}
# scene <name> <unit> <result> <web> [step] : a scene whose agent hears.
scene(){
    local d="$T/$1"; mkdir -p "$d"
    printf 'unit=%s\nresult=%s\nweb=%s\nstep=%s\n' "$2" "$3" "$4" "${5:-}" > "$d/status"
    echo "$d"
}
# ascii <scene dir> : how many recorded requests hold a byte above 0x7F.
nonascii(){ local n=0 f; for f in "$1"/calls/*; do LC_ALL=C grep -q -P '[^\x00-\x7F]' "$f" && n=$((n+1)); done; echo "$n"; }

echo "== the bring-up line, state by state"
d=$(scene building activating none inactive "Install hf-timestd"); out=$(panel "$d")
has   "activating: says the station still builds"      "$out" "STATION IS STILL BUILDING"
has   "activating: names the last step"                "$out" "last step: Install hf-timestd"
d=$(scene notyet inactive none inactive); out=$(panel "$d")
has   "no marker: prints nothing about bring-up"       "$out" "BRINGUP=[]"
lacks "no marker: raises no ka9q-web alarm"            "$out" "ka9q-web IS NOT RUNNING"
d=$(scene stopped failed none inactive); out=$(panel "$d")
has   "unit failed: says bring-up was stopped"         "$out" "BRING-UP WAS STOPPED BEFORE IT FINISHED"
d=$(scene retry inactive retry inactive); out=$(panel "$d")
has   "retry: says it tries again at the next boot"    "$out" "BRING-UP FAILED -- it tries again"
lacks "retry: does not claim bring-up finished"        "$out" "BRING-UP FINISHED"
d=$(scene nosdr inactive awaiting-sdr inactive); out=$(panel "$d")
has   "awaiting-sdr: says it ran without the radio"    "$out" "bring-up ran WITHOUT the radio"
lacks "awaiting-sdr: does not claim bring-up finished" "$out" "BRING-UP FINISHED"
d=$(scene gaveup inactive gave-up inactive); out=$(panel "$d")
has   "gave-up: says it stopped trying"                "$out" "BRING-UP FAILED THREE TIMES"
d=$(scene done inactive ok active); out=$(panel "$d")
has   "ok, ka9q-web active: prints nothing"            "$out" "BRINGUP=[]"
d=$(scene noweb inactive ok inactive); out=$(panel "$d")
has   "ok, ka9q-web down: raises the alarm"            "$out" "BRING-UP FINISHED BUT ka9q-web IS NOT RUNNING"
d=$(scene odd unknown none inactive); out=$(panel "$d")
has   "a unit state the panel does not know, no marker: prints nothing" "$out" "BRINGUP=[]"
d=$(scene noweb inactive ok inactive); out=$(panel "$d")
lacks "no line sends smd through the guest agent"      "$out" "guest exec 100 -- smd"
has   "the alarm sends the operator into the VM"       "$out" "sigmond-vm"
has   "a hearing agent gives the VM's address"         "$out" "VMIP=[10.99.0.2]"
[ ! -e "$d/run/qga-reset" ] && ok "a hearing agent gets no reset, and no record of one" \
                             || bad "a hearing agent gets no reset" "found $d/run/qga-reset"
[ ! -e "$d/sleep.calls" ] && ok "a hearing agent costs no wait" || bad "a hearing agent costs no wait" "$(cat "$d/sleep.calls")"

echo "== every request stays ASCII"
for s in building notyet stopped retry nosdr gaveup done noweb odd; do
    n=$(nonascii "$T/$s")
    [ "$n" = 0 ] && ok "$s: no request holds a byte above 0x7F" || bad "$s: no request holds a byte above 0x7F" "$n request(s) do"
done

echo "== the status request itself, run against a stand-in VM"
# Take the request the panel really sent, point its three paths at a scratch
# tree, and run it: this proves the shipped text, not the stub's answer.
d="$T/building"; req=""
for f in "$d"/calls/*; do
    if grep -qa 'firstrun-bringup' "$f"; then req=$(tr '\0' '\n' < "$f" | sed -n '/^u=\$(systemctl/,$p'); fi
done
[ -n "$req" ] && ok "found the status request among the recorded calls" || bad "found the status request" "none recorded"
G="$T/guest"; mkdir -p "$G/bin" "$G/lib" "$G/log"
cat > "$G/bin/systemctl" <<EOF
#!/bin/bash
case "\$2" in sigmond-firstrun-bringup) cat "$G/unit";; ka9q-web) cat "$G/web";; esac
EOF
chmod 755 "$G/bin/systemctl"
guest(){ PATH="$G/bin:$PATH" /bin/bash -c "$(printf '%s' "$req" | sed "s#/var/lib/sigmond/#$G/lib/#; s#/var/log/sigmond/#$G/log/#")"; }
echo activating > "$G/unit"; echo inactive > "$G/web"
printf '2026-10-10T01:00:00+00:00 first boot\n     \033[1m\302\273 Install hf-timestd\033[0m\n     noise\n\342\224\200\342\224\200\342\224\200 Stage 4: plan \342\224\200\342\224\200\342\224\200\n     more noise\n' > "$G/log/firstrun-bringup.log"
out=$(guest)
has   "it reports the unit's state"                    "$out" "unit=activating"
has   "no marker reads as result=none"                 "$out" "result=none"
has   "it finds the last step by its box-drawing rule" "$out" "step=Stage 4: plan"
[ "$(printf '%s' "$out" | LC_ALL=C grep -c -P '[^\x00-\x7F]')" = 0 ] \
    && ok "its answer holds no byte above 0x7F" || bad "its answer holds no byte above 0x7F" "$out"
printf '2026-10-10T01:00:00+00:00 first boot\n     \302\273 Start radiod \342\200\224 already configured\n' > "$G/log/firstrun-bringup.log"
has   "it finds a step by its guillemet"               "$(guest)" "step=Start radiod  already configured"
echo inactive > "$G/unit"; printf 'attempts=2\nresult=retry\n2026-10-10T01:00:00+00:00\n' > "$G/lib/.firstrun-bringup-done"
has   "it reads the marker's result"                   "$(guest)" "result=retry"
printf '2026-09-01T00:00:00+00:00\n' > "$G/lib/.firstrun-bringup-done"
has   "a marker with no result line reads as ok"       "$(guest)" "result=ok"
rm -f "$G/log/firstrun-bringup.log"
has   "a missing log leaves the step empty"            "$(guest)" "step="

echo "== a deaf agent gets one reset, and hears again"
d=$(scene deaf inactive ok active); : > "$d/deaf"; agent "$d"; out=$(panel "$d"); wait
[ "$(od -An -tx1 "$d/reset.bytes" 2>/dev/null | tr -d ' \n')" = "$RESET_HEX" ] \
    && ok "the reset sends 0xFF and one sync request, to the byte" \
    || bad "the reset sends 0xFF and one sync request" "$(od -An -c "$d/reset.bytes" 2>/dev/null | head -3)"
has   "after the reset the agent gives the address"    "$out" "VMIP=[10.99.0.2]"
has   "the address carries no ARP note"                "$out" "VMNOTE=[]"
has   "after the reset the bring-up line reads true"   "$out" "BRINGUP=[]"
has   "the reset leaves its record, by name"           "$(cat "$d/run/qga-reset" 2>/dev/null)" " panel"
[ ! -e "$d/sleep.calls" ] && ok "the panel asks again at once, without the ten-second wait" \
                           || bad "the panel asks again at once" "slept: $(tr '\n' ' ' < "$d/sleep.calls")"
[ "$(nonascii "$d")" = 0 ] && ok "deaf: no request holds a byte above 0x7F" || bad "deaf: ASCII" ""

echo "== an agent that stays silent"
d=$(scene silent inactive ok active); : > "$d/deaf"; out=$(panel "$d")
has   "the address comes from ARP"                     "$out" "VMIP=[10.99.0.2]"
has   "the address says where it came from"            "$out" "address via ARP"
has   "the panel says the agent does not answer"       "$out" "guest agent does not answer"
lacks "silence is not read as a build"                 "$out" "STILL BUILDING"
lacks "silence raises no ka9q-web alarm"               "$out" "ka9q-web IS NOT RUNNING"
[ ! -e "$d/run/qga-reset" ] && ok "a reset that brought no answer leaves no record" \
                             || bad "a reset that brought no answer leaves no record" "$(cat "$d/run/qga-reset")"
[ "$(wc -l < "$d/sleep.calls")" = 6 ] && ok "the six tries keep their waits" || bad "the six tries keep their waits" "$(wc -l < "$d/sleep.calls")"

echo "== the RX888 notice"
d=$(scene rx inactive ok active); : > "$d/rxmark"; out=$(panel "$d")
has   "no SDR in the VM: the notice stands"            "$out" "RX888 NOT VISIBLE"
[ -e "$d/rxmark" ] && ok "the marker stays" || bad "the marker stays" "removed"
: > "$d/sdr"; out=$(panel "$d")
lacks "SDR in the VM: the notice clears"               "$out" "RX888 NOT VISIBLE"
[ ! -e "$d/rxmark" ] && ok "the marker goes" || bad "the marker goes" "still there"
grep -qx 25 "$d/timeout.calls" && ok "the lsusb request runs under a timeout" || bad "the lsusb request runs under a timeout" "$(sort -u "$d/timeout.calls" | tr '\n' ' ')"

echo "== every request firstboot-v3.sh sends, from any of its scripts"
# A request is a `qm guest exec` that stands as a command.  The scan follows
# each one to the end of its shell statement, through quotes and continued
# lines, and looks for a byte above 0x7F in it.  The two counts are pins: the
# requests, and the mentions in all (the rest stand in prose and comments).  A
# new request, or a mention this scan does not take for one, moves a count
# and stops here until someone has looked at it.
WANT_CALLS=6; WANT_MENTIONS=10
python3 - "$SRC" > "$T/guard.out" <<'GUARDPY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
CALL = re.compile(r"(?:^[ \t]*|\$\(|\bif\s+(?:!\s+)?|&&\s*|\|\|\s*|timeout\s+\d+\s+)qm guest exec\b", re.M)

def statement(text, start):
    stack, i = [], start
    while i < len(text):
        ch = text[i]
        top = stack[-1] if stack else None
        if top == "'":
            if ch == "'":
                stack.pop()
        elif ch == "\\":
            i += 1
        elif text.startswith("$(", i):
            stack.append("$(")
            i += 1
        elif top == '"':
            if ch == '"':
                stack.pop()
        elif ch in "'\"":
            stack.append(ch)
        elif ch == ")" and top == "$(":
            stack.pop()
        elif ch in "\n;|" and not stack:
            break
        elif ch == "&" and not stack and text[i - 1] != ">" and text[i + 1:i + 2] != ">":
            break
        i += 1
    return text[start:i]

calls = [statement(text, m.start()) for m in CALL.finditer(text)]
bad = [s for s in calls if not s.isascii()]
print("CALLS=%d" % len(calls))
print("NONASCII=%d" % len(bad))
print("MENTIONS=%d" % text.count("qm guest exec"))
for s in bad:
    print("BAD=" + s.splitlines()[0].strip()[:90])
GUARDPY
g(){ sed -n "s/^$1=//p" "$T/guard.out" | head -1; }
[ "$(g NONASCII)" = 0 ] && ok "no request holds a byte above 0x7F" || bad "no request holds a byte above 0x7F" "$(g BAD)"
[ "$(g CALLS)" = "$WANT_CALLS" ] && ok "$WANT_CALLS requests, as counted when this test was written" \
    || bad "$WANT_CALLS requests" "found $(g CALLS): look at the new one, then move this count"
[ "$(g MENTIONS)" = "$WANT_MENTIONS" ] && ok "$WANT_MENTIONS mentions of qm guest exec in all" \
    || bad "$WANT_MENTIONS mentions of qm guest exec" "found $(g MENTIONS): is the new one a request this scan missed?"

echo
echo "passed $pass, failed $fail"
[ "$fail" = 0 ]
