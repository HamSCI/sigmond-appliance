#!/bin/bash
# test-site-timing-t4.sh — sigmond-site-timing step 2b (declare LAN stratum-1
# servers to hf-timestd as T4 peers), run against stubbed chronyc/systemctl.
# No root, no network; seconds.
#
# Why: step 2 accepts ANY host whose NTP reply carries stratum 1, and T4
# outranks T3, so 2b must declare only a server chrony itself selected or
# combined at stratum 1 with leap Normal and a real refid (v3.68 review
# round 2, 2026-10-05).  The cases below are that rule, both opt-outs, and
# idempotency.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0

# The step, verbatim, with only the hardcoded chrony path redirected.
awk '/^# ── 2b\. declare those LAN stratum-1/{f=1} /^# ── 2\.5 identity reconciliation/{f=0} f' \
    "$HERE/sigmond-site-timing" \
    | sed "s#/etc/chrony/conf.d/local-timeservers.conf#$T/lts.conf#g" > "$T/step.sh"
grep -q 'T4OK' "$T/step.sh" || { echo "FAIL: step 2b not found in sigmond-site-timing"; exit 1; }
mkdir -p "$T/bin"
printf 'server 192.168.8.144 iburst minpoll 4 maxpoll 6\n' > "$T/lts.conf"

run_case() {  # run_case <name> <sources-state> <stratum> <leap> <refid> <config> <want-peers|-> <want-restart yes|no>
    local name=$1 st=$2 stratum=$3 leap=$4 refid=$5 cfg=$6 want=$7 wantr=$8
    cat > "$T/bin/chronyc" <<EOF
#!/bin/bash
case "\$*" in
  "-n sources") echo "MS Name/IP address         Stratum Poll Reach LastRx Last sample"
                echo "$st 192.168.8.144                 $stratum   6   377    25    -25us[  -27us] +/-  160us" ;;
  "-n ntpdata 192.168.8.144") printf 'Remote address  : 192.168.8.144 (C0A80890)\nLeap status     : %s\nStratum         : %s\nReference ID    : 50505300 (%s)\n' "$leap" "$stratum" "$refid" ;;
esac
EOF
    printf '#!/bin/bash\necho "$*" >> %s/systemctl.log\n' "$T" > "$T/bin/systemctl"
    chmod +x "$T/bin/chronyc" "$T/bin/systemctl"
    rm -f "$T/systemctl.log" "$T/say.log"
    printf '%b' "$cfg" > "$T/cfg.toml"
    PATH="$T/bin:$PATH" CFG="$T/cfg.toml" bash -c "say(){ echo \"\$*\" >> $T/say.log; }; source $T/step.sh"
    local got restarted=no
    got=$(python3 -c "import tomllib,sys; t=tomllib.load(open(sys.argv[1],'rb')).get('timing',{}).get('authority_manager',{}).get('t4',{}); print(','.join(t.get('peers',[])) or '-')" "$T/cfg.toml")
    grep -q 'try-restart timestd-fusion' "$T/systemctl.log" 2>/dev/null && restarted=yes
    if [ "$got" = "$want" ] && [ "$restarted" = "$wantr" ]; then echo "  ok   $name"
    else echo "  FAIL $name: peers=$got (want $want) restart=$restarted (want $wantr); say: $(cat "$T/say.log" 2>/dev/null)"; fail=1; fi
}

BASE='[timing]\nlb1421_enabled = false\n'
run_case "chrony selects it, stratum 1, PPS -> declared"   '^*' 1 Normal PPS  "$BASE" 192.168.8.144 yes
run_case "combined (^+) also qualifies"                   '^+' 1 Normal GPS  "$BASE" 192.168.8.144 yes
run_case "not selected (^?) -> NOT declared"              '^?' 1 Normal PPS  "$BASE" -             no
run_case "falseticker (^x) -> NOT declared"               '^x' 1 Normal PPS  "$BASE" -             no
run_case "refid LOCL -> NOT declared"                     '^*' 1 Normal LOCL "$BASE" -             no
run_case "leap unsynchronised -> NOT declared"            '^*' 1 'Not synchronised' PPS "$BASE" - no
run_case "stratum 2 -> NOT declared"                      '^*' 2 Normal PPS  "$BASE" -             no
run_case "opt-out auto_declare = false -> untouched"      '^*' 1 Normal PPS  "${BASE}\n[timing.authority_manager.t4]\nauto_declare = false\n" - no
run_case "opt-out explicit peers = [] -> untouched"       '^*' 1 Normal PPS  "${BASE}\n[timing.authority_manager.t4]\npeers = []\n" - no
run_case "operator peer kept, ours added"                 '^*' 1 Normal PPS  "${BASE}\n[timing.authority_manager.t4]\npeers = [\"timeserver.lan\"]\n" timeserver.lan,192.168.8.144 yes
run_case "already declared -> no restart"                 '^*' 1 Normal PPS  "${BASE}\n[timing.authority_manager.t4]\npeers = [\"192.168.8.144\"]\n" 192.168.8.144 no

[ "$fail" = 0 ] && echo "PASS: site-timing step 2b" || { echo "FAILED"; exit 1; }
