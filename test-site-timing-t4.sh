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
# The settle-wait (180 s by default) is off for the rule cases below; the
# wait cases at the end turn it on with short constants.
export SITE_TIMING_T4_WAIT_S=0 SITE_TIMING_T4_POLL_S=1

# The step, verbatim, with only the hardcoded chrony path redirected.
awk '/^# ── 2b\. declare those LAN stratum-1/{f=1} /^# ── 2\.5 identity reconciliation/{f=0} f' \
    "$HERE/sigmond-site-timing" \
    | sed -e "s#/etc/chrony/conf.d/local-timeservers.conf#$T/lts.conf#g" \
          -e "s#/etc/chrony/conf.d/10-sigmond-ntp.conf#$T/wiz.conf#g" > "$T/step.sh"
grep -q 'T4OK' "$T/step.sh" || { echo "FAIL: step 2b not found in sigmond-site-timing"; exit 1; }
mkdir -p "$T/bin"
printf 'server 192.168.8.144 iburst minpoll 4 maxpoll 6\n' > "$T/lts.conf"

# systemctl logs every call; `is-active` answers per $PENDING (yes -> active).
# systemd-run logs to systemd-run.log.
stub_systemctl() {
    cat > "$T/bin/systemctl" <<STUBEND
#!/bin/bash
echo "\$*" >> $T/systemctl.log
[ "\$1" = is-active ] && [ "\${PENDING:-no}" = yes ] && exit 0
[ "\$1" = is-active ] && exit 3
exit 0
STUBEND
    printf '#!/bin/bash\necho "$*" >> %s/systemd-run.log\n' "$T" > "$T/bin/systemd-run"
    chmod +x "$T/bin/systemctl" "$T/bin/systemd-run"
}

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
    stub_systemctl
    chmod +x "$T/bin/chronyc"
    rm -f "$T/systemctl.log" "$T/say.log" "$T/systemd-run.log"
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

# ── the wizard's answer (10-sigmond-ntp.conf, v3.84 ask_ntp) ──────────────
# A server the operator named in the wizard reached chrony and never T4:
# 2b read only the subnet scan's file.  Same vetting; the operator's own
# address becomes the peer (a host name resolves first; the vetted address
# is declared, never the name).
rm -f "$T/lts.conf"
printf '# Written by the Sigmond first-boot wizard\nserver 192.168.8.144 iburst\n' > "$T/wiz.conf"
run_case "wizard-named IP, no scan file -> declared"      '^*' 1 Normal PPS  "$BASE" 192.168.8.144 yes
run_case "wizard-named IP, not vouched -> NOT declared"   '^?' 1 Normal PPS  "$BASE" -             no
printf '# Written by the Sigmond first-boot wizard\npool pool.ntp.org iburst maxsources 4\n' > "$T/wiz.conf"
run_case "wizard chose the public pool -> nothing"        '^*' 1 Normal PPS  "$BASE" -             no
printf 'server timeserver.pole iburst\n' > "$T/wiz.conf"
printf '#!/bin/bash\n[ "$1 $2" = "ahostsv4 timeserver.pole" ] && echo "192.168.8.144   STREAM timeserver.pole"\n' > "$T/bin/getent"; chmod +x "$T/bin/getent"
run_case "wizard-named host name -> its vetted address"  '^*' 1 Normal PPS  "$BASE" 192.168.8.144 yes
printf 'server nowhere.pole iburst\n' > "$T/wiz.conf"
run_case "host name that does not resolve -> nothing"     '^*' 1 Normal PPS  "$BASE" -             no
printf 'server 192.168.8.144 iburst minpoll 4 maxpoll 6\n' > "$T/lts.conf"
printf 'server 192.168.8.144 iburst\n' > "$T/wiz.conf"
run_case "same server in both files -> declared once"     '^*' 1 Normal PPS  "$BASE" 192.168.8.144 yes


# ── settle-wait: judge chrony AFTER it settles (N8UR 2026-11-14, SIGMA) ────
# A scripted chronyc: each `sources` call advances through $T/seq, one
# "state stratum leap refid" line per call (the last line repeats).
printf 'server 192.168.8.144 iburst\n' > "$T/lts.conf"; rm -f "$T/wiz.conf"
wait_case() {  # wait_case <name> <want-peers|-> <want-wait yes|no> <want-runs> <env...> ; sequence on stdin
    local name=$1 want=$2 wantw=$3 wantruns=$4; shift 4
    cat > "$T/seq"; echo 0 > "$T/cnt"
    cat > "$T/bin/chronyc" <<STUBEND
#!/bin/bash
n=\$(cat $T/cnt); L=\$(sed -n "\$((n+1))p" $T/seq); [ -n "\$L" ] || L=\$(tail -1 $T/seq)
case "\$*" in
 "-n sources") echo \$((n+1)) > $T/cnt
    set -- \$L
    echo "MS Name/IP address         Stratum Poll Reach LastRx Last sample"
    echo "\$1 192.168.8.144                 \$2   6   377    25    -25us[  -27us] +/-  160us" ;;
 "-n ntpdata 192.168.8.144") set -- \$(sed -n "\${n}p" $T/seq); [ -n "\$1" ] || set -- \$(tail -1 $T/seq)
    [ "\$3" = "?" ] && exit 0
    printf 'Leap status     : %s\nStratum         : %s\nReference ID    : 50505300 (%s)\n' "\$3" "\$2" "\$4" ;;
esac
STUBEND
    chmod +x "$T/bin/chronyc"; stub_systemctl
    rm -f "$T/systemctl.log" "$T/say.log" "$T/systemd-run.log"; printf '%b' "$BASE" > "$T/cfg.toml"
    local t0=$SECONDS
    env "$@" PATH="$T/bin:$PATH" CFG="$T/cfg.toml" bash -c "say(){ echo \"\$*\" >> $T/say.log; }; source $T/step.sh"
    local el=$((SECONDS - t0)) got waited=no runs=0
    got=$(python3 -c "import tomllib,sys; t=tomllib.load(open(sys.argv[1],'rb')).get('timing',{}).get('authority_manager',{}).get('t4',{}); print(','.join(t.get('peers',[])) or '-')" "$T/cfg.toml")
    grep -q 'waiting up to' "$T/say.log" 2>/dev/null && waited=yes
    [ -f "$T/systemd-run.log" ] && runs=$(wc -l < "$T/systemd-run.log")
    if [ "$got" = "$want" ] && [ "$waited" = "$wantw" ] && [ "$runs" = "$wantruns" ]; then echo "  ok   $name (${el}s)"
    else echo "  FAIL $name: peers=$got (want $want) waited=$waited (want $wantw) retries=$runs (want $wantruns); say: $(cat "$T/say.log" 2>/dev/null)"; fail=1; fi
    echo "$el" > "$T/elapsed"
}
W="SITE_TIMING_T4_WAIT_S=6 SITE_TIMING_T4_POLL_S=1"
printf '^? 0 ? ?\n^? 0 ? ?\n^* 1 Normal PPS\n' | wait_case "SIGMA: ^? stratum 0 at restart, ^* later -> declared" 192.168.8.144 yes 0 $W
grep -q 'settled after' "$T/say.log" && echo "  ok   logs the end of the wait" || { echo "  FAIL no 'settled after' line"; fail=1; }
printf '^? 1 Normal F9T\n^* 1 Normal F9T\n' | wait_case "N8UR: ^? stratum 1 Normal, then ^* -> declared" 192.168.8.144 yes 0 $W
printf '^? 0 ? ?\n' | wait_case "never selected -> gives up, ONE retry scheduled" - yes 1 $W
grep -q 'gave up' "$T/say.log" && grep -q 'will retry once' "$T/say.log" && echo "  ok   logs the give-up and the retry" || { echo "  FAIL give-up/retry lines: $(cat "$T/say.log")"; fail=1; }
grep -q -- '--unit=sigmond-site-timing-retry' "$T/systemd-run.log" && grep -q -- '--on-active=' "$T/systemd-run.log" \
    && echo "  ok   fixed unit name, --on-active" || { echo "  FAIL systemd-run args: $(cat "$T/systemd-run.log")"; fail=1; }
printf '^? 0 ? ?\n' | wait_case "retry already pending -> not stacked" - yes 0 $W PENDING=yes
grep -q 'already pending' "$T/say.log" && echo "  ok   says so" || { echo "  FAIL pending line"; fail=1; }
printf '^? 0 ? ?\n' | wait_case "the retry run never re-arms" - yes 0 $W SITE_TIMING_NO_RETRY=1
printf '^* 3 Normal GPS\n' | wait_case "stratum 3 -> no wait" - no 0 $W
printf '^* 1 Alarm GPS\n' | wait_case "leap alarm -> no wait" - no 0 $W
printf '^? 1 Alarm PPS\n' | wait_case "unselected AND leap alarm -> no wait" - no 0 $W
printf '^? 1 Normal LOCL\n' | wait_case "unselected, refid LOCL -> no wait" - no 0 $W
printf '^x 1 Normal PPS\n' | wait_case "falseticker -> no wait" - no 0 $W
printf "^x 1 Normal PPS\n" | wait_case "falseticker again, timed" - no 0 $W; [ "$(cat "$T/elapsed")" -le 1 ] && echo "  ok   disqualified is judged at once" || { echo "  FAIL took $(cat "$T/elapsed")s"; fail=1; }
printf '^* 1 Normal PPS\n' | wait_case "already selected -> no wait, declared" 192.168.8.144 no 0 $W
# no LAN candidate (public pool only): the block never waits or retries
rm -f "$T/lts.conf"; printf 'pool pool.ntp.org iburst maxsources 4\n' > "$T/wiz.conf"
printf '^? 0 ? ?\n' | wait_case "public pool only -> no wait, no retry" - no 0 $W
rm -f "$T/wiz.conf"; printf 'server 192.168.8.144 iburst\n' > "$T/lts.conf"

[ "$fail" = 0 ] && echo "PASS: site-timing step 2b" || { echo "FAILED"; exit 1; }
