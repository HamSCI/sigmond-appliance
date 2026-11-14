#!/bin/bash
# test-site-timing-t6.sh — sigmond-site-timing step 4.9 (arm T6 from a TS-1 the
# operator declared with `ts1 trust`, shared through a splitter), run against
# temp configs, a stubbed advertisement browse and a stubbed systemctl.  No
# root, no network; seconds.
#
# Why: one TS-1 feeds four RX888s through splitters at AC0G's site, but its
# USB plugs into B4 only, so SIGMA's bring-up left T6 off (2026-11-14).  The
# rules: the operator's declaration (the trust record) is the authority and
# arms by itself; a LAN advertisement may only object.  Never override an
# enabled T6 or a local TS-1.  Nothing unvalidated reaches the config.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SIGMOND_LIB="${SIGMOND_LIB:-$HERE/../sigmond/lib}"
[ -f "$SIGMOND_LIB/sigmond/sdr_map.py" ] || { echo "SKIP: no sigmond checkout at $SIGMOND_LIB (set SIGMOND_LIB)"; exit 0; }
export SIGMOND_LIB
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0

awk '/^# ── 4\.9 T6 from a TS-1 shared/{f=1} /^# ── 5\. full timing profile/{f=0} f' \
    "$HERE/sigmond-site-timing" > "$T/step.sh"
grep -q 'T6LAN' "$T/step.sh" || { echo "FAIL: step 4.9 not found in sigmond-site-timing"; exit 1; }
mkdir -p "$T/bin" "$T/radio" "$T/usb"
printf '#!/bin/bash\necho "$*" >> %s/systemctl.log\nexit 0\n' "$T" > "$T/bin/systemctl"
chmod +x "$T/bin/systemctl"

radiod_conf() {  # radiod_conf <file> <rx888 samprate line or empty>
    printf '[global]\nhardware  = rx888        # which front-end driver to load\nstatus = x-status.local\nsamprate  = 12000              # channel output rate\n\n[rx888]\ndevice      = "rx888"\n%s\n' "$2" > "$T/radio/$1"
}
NOW=$(date +%s)
rec() {  # rec <host> <board> <lock> [tx] [ts] [mode] [address] -- raw values, JSON-encoded here
    python3 -c 'import json,sys; h,b,l,tx,ts,mode,a=sys.argv[1:8]
print(json.dumps({"schema":"1","host":h,"present":"yes","mode":mode,"gps_lock":l,"tx_hz":tx,"ref_source":"external","firmware":"TimeSync v2.6, Board ID # "+b,"board_id":b,"ts":ts,"service_name":"TS-1 %s on %s"%(b,h),"addresses":[a],"address":a}))' \
        "$1" "$2" "$3" "${4-84225000}" "${5:-$NOW}" "${6:-GPS-PPS}" "${7:-192.168.1.176}"
}
browse_returns() {  # the stub's stdout (a JSON list) and exit code
    printf '%s\n' "$1" > "$T/browse.json"
    printf '#!/bin/bash\necho called >> %s/browse.log\ncat %s/browse.json\nexit %s\n' "$T" "$T" "${2:-0}" > "$T/bin/browse"
    chmod +x "$T/bin/browse"
}
trust() {  # trust <host> <board> [tx] [adc] [freq] [address|-]
    { printf '[trusted]\nhost = "%s"\nboard_id = "%s"\ntx_hz = %s\nadc_hz = %s\nfrequency_hz = %s\n' \
        "$1" "$2" "${3:-84225000}" "${4:-129600000}" "${5:-45375000}"
      [ "${6:-192.168.1.176}" = - ] || printf 'address = "%s"\n' "${6:-192.168.1.176}"; } > "$T/trust.toml"
}

T6_OFF='[station]\ncallsign = "AC0G"\n\n[timing]\nlb1421_enabled = true\n\n[timing.t6_pps]\nenabled = false\nfrequency_hz = 0                  # injected (aliased) frequency\nsample_rate = 96000\nlow_edge_hz = -25000\nhigh_edge_hz = 25000\n\n[gnss_vtec]\nenabled = false\n'

run_case() {  # run_case <name> <cfg> <want-enabled> <want-freq> <want-restart yes|no> <want-say-regex> [<want-browsed yes|no>]
    local name=$1 cfg=$2 we=$3 wf=$4 wr=$5 wsay=$6 wb=${7:-}
    printf '%b' "$cfg" > "$T/cfg.toml"; cp "$T/cfg.toml" "$T/input.toml"
    rm -f "$T/systemctl.log" "$T/say.log" "$T/browse.log" "$T"/cfg.toml.bak-*
    PATH="$T/bin:$PATH" CFG="$T/cfg.toml" TS1_LOCAL_GLOB="$T/usb/usb-Adafruit_Trinket_M0_*" \
        TS1_BROWSE_CMD="$T/bin/browse" RADIOD_CONF_GLOB="$T/radio/radiod@*.conf" TS1_TRUST_FILE="$T/trust.toml" \
        bash -c "say(){ echo \"\$*\" >> $T/say.log; }; source $T/step.sh"
    local got restarted=no browsed=no nsay
    got=$(python3 -c "import tomllib,sys; t=tomllib.load(open(sys.argv[1],'rb')).get('timing',{}).get('t6_pps',{}); print(str(t.get('enabled')).lower(), t.get('frequency_hz'))" "$T/cfg.toml")
    grep -q 'try-restart timestd-core-recorder timestd-fusion' "$T/systemctl.log" 2>/dev/null && restarted=yes
    [ -f "$T/browse.log" ] && browsed=yes
    nsay=$(wc -l < "$T/say.log" 2>/dev/null || echo 0)
    local ok=1
    [ "$got" = "$we $wf" ] || ok=0
    [ "$restarted" = "$wr" ] || ok=0
    [ "$nsay" = 1 ] || ok=0
    grep -qE "$wsay" "$T/say.log" 2>/dev/null || ok=0
    [ -z "$wb" ] || [ "$browsed" = "$wb" ] || ok=0
    if [ "$wr" = no ] && ! cmp -s "$T/cfg.toml" "$T/input.toml"; then ok=0; fi    # not armed => byte-identical
    if grep -q '[[:cntrl:]]' "$T/say.log" 2>/dev/null; then ok=0; fi             # one clean journal line
    if [ "$ok" = 1 ]; then echo "  ok   $name"
    else echo "  FAIL $name: t6=$got (want $we $wf) restart=$restarted (want $wr) browsed=$browsed (want ${wb:-any}) say[$nsay]: $(cat -A "$T/say.log" 2>/dev/null)"; fail=1; fi
}

radiod_conf radiod@sigma.conf 'samprate    = 129600000'
trust AC0G-B4 9f1e37b5

# ── the declaration alone arms (SIGMA sees no mDNS from B4's VM) ─────────────
browse_returns "[]"
run_case "declared, no advert visible -> arms from the record" "$T6_OFF" true 45375000 yes 'T6 armed from the declared TS-1 board 9f1e37b5 on AC0G-B4: frequency_hz = 45375000.*not cross-checked \(no advertisement visible\)'
grep -q 'sigmond-site-timing from the declared TS-1 board 9f1e37b5 on AC0G-B4' "$T/cfg.toml" \
    && echo "  ok   the source is recorded in a comment" || { echo "  FAIL no source comment: $(cat "$T/cfg.toml")"; fail=1; }
grep -E '^# armed by sigmond-site-timing' "$T/cfg.toml" | grep -qxE '# armed by sigmond-site-timing from the declared TS-1 board 9f1e37b5 on AC0G-B4, TX 84225000 Hz at 129600000 sps, [0-9: -]+Z' \
    && echo "  ok   the comment line holds only checked values" || { echo "  FAIL comment: $(grep armed "$T/cfg.toml")"; fail=1; }
ls "$T"/cfg.toml.bak-* >/dev/null 2>&1 && echo "  ok   the config was backed up" || { echo "  FAIL no backup"; fail=1; }
python3 -c "import tomllib,sys; c=tomllib.load(open(sys.argv[1],'rb')); assert c['timing']['t6_pps']['sample_rate']==96000 and c['gnss_vtec']['enabled'] is False and c['timing']['lb1421_enabled'] is True" "$T/cfg.toml" \
    && echo "  ok   the rest of the config is untouched" || { echo "  FAIL other keys disturbed"; fail=1; }
! grep -q metrology "$T/systemctl.log" && echo "  ok   metrology is never restarted (it carries T6)" || { echo "  FAIL metrology touched"; fail=1; }
cp "$T/cfg.toml" "$T/armed.toml"

# ── never override ───────────────────────────────────────────────────────────
browse_returns "[$(rec AC0G-B4 9f1e37b5 yes 99000000)]"
run_case "armed station + a new advert (other TX) -> untouched, LAN not read" "$(sed 's/\\/\\\\/g' "$T/armed.toml")" true 45375000 no 'already enabled' no
run_case "operator already enabled T6 -> untouched" "${T6_OFF/enabled = false/enabled = true}" true 0 no 'already enabled' no
run_case "operator enabled the legacy [timing.l6_pps] -> untouched" \
    '[timing]\n\n[timing.l6_pps]\nenabled = true\nfrequency_hz = 45375000\n' none None no 'already enabled' no
touch "$T/usb/usb-Adafruit_Trinket_M0_X-if00"
run_case "a TS-1 on this host's own USB -> nothing done here" "$T6_OFF" false 0 no 'own USB' no
rm -f "$T/usb/"*

# ── the advertisement may object, never supply ───────────────────────────────
browse_returns "[]" 2
run_case "LAN unreadable -> arms, says not cross-checked" "$T6_OFF" true 45375000 yes 'not cross-checked \(LAN not readable\)'
browse_returns "[$(rec AC0G-B4 9f1e37b5 yes)]"
run_case "matching locked advert -> arms, cross-checked" "$T6_OFF" true 45375000 yes 'cross-checked against its advertisement \(GPS locked\) - restarting'
browse_returns "[$(rec AC0G-B4 9f1e37b5 no)]"
run_case "matching advert, no GPS lock -> not armed this run" "$T6_OFF" false 0 no 'NOT armed this run.*no GPS lock'
browse_returns "[$(rec AC0G-B4 9f1e37b5 yes 84000000)]"
run_case "advert with another TX -> refused" "$T6_OFF" false 0 no 'contradicts the declared TS-1.*tx_hz 84000000'
browse_returns "[$(rec EVIL 9f1e37b5 yes 84225000 $NOW GPS-PPS 192.168.1.66)]"
run_case "the board advertised under another host -> refused" "$T6_OFF" false 0 no 'contradicts.*from 192.168.1.66 host EVIL'
browse_returns "[$(rec AC0G-B4 deadbeef yes)]"
run_case "the host advertising another board -> refused" "$T6_OFF" false 0 no 'contradicts'
browse_returns "[$(rec AC0G-B4 9f1e37b5 yes),$(rec EVIL 9f1e37b5 yes 84225000 $NOW GPS-PPS 192.168.1.66)]"
run_case "two adverts claim the board -> refused, both shown" "$T6_OFF" false 0 no '2 advertisements claim.*192.168.1.176.*192.168.1.66'
browse_returns "[$(rec AC0G-B4 9f1e37b5 yes 84225000 $((NOW - 7200)))]"
run_case "stale advert (2 h) -> refused" "$T6_OFF" false 0 no 'stale'
browse_returns "[$(rec AC0G-B4 9f1e37b5 yes 84225000 $((NOW + 3600)))]"
run_case "advert dated in the future -> refused" "$T6_OFF" false 0 no 'future'
browse_returns "[$(rec AC0G-B4 9f1e37b5 yes 84225000 $NOW CW)]"
run_case "advert in a non-PPS mode -> refused" "$T6_OFF" false 0 no 'not a PPS mode'
browse_returns "[$(rec AC0G-B4 9f1e37b5 yes 84225000 $NOW GPS-PPS 192.168.1.9)]"
run_case "advert from a new address -> arms, warns" "$T6_OFF" true 45375000 yes 'WARNING: advertised from 192.168.1.9, declared at 192.168.1.176'
browse_returns "[$(rec FAR 1234abcd yes 70000000)]"
run_case "an unrelated TS-1 on the LAN -> arms, not cross-checked" "$T6_OFF" true 45375000 yes 'no advertisement visible'

# ── hostile advertisements: nothing reaches the config or the journal raw ────
hostile() {  # hostile <name> <host> <board> [tx]
    browse_returns "[$(rec "$2" "$3" yes "${4-84225000}")]"
    run_case "$1" "$T6_OFF" false 0 no 'NOT armed'
}
hostile "host with a newline and a table header" $'AC0G-B4\n[timing.t6_pps]\nenabled = true' 9f1e37b5
hostile "board id with a quote and a newline"   AC0G-B4 $'9f1e37b5"\nfrequency_hz = 1'
hostile "host with control characters"          $'AC0G\x1b[2J-B4' 9f1e37b5
hostile "board claimed by an oversize host"     "$(printf 'a%.0s' $(seq 300))" 9f1e37b5
hostile "tx_hz carrying a second line"          AC0G-B4 9f1e37b5 $'84225000\nenabled = true'
browse_returns '{"not": "a list"}'
run_case "browse returns a non-list -> arms, not cross-checked" "$T6_OFF" true 45375000 yes 'LAN not readable'

# ── no declaration: nothing armed; one advert is offered ─────────────────────
rm -f "$T/trust.toml"
browse_returns "[$(rec AC0G-B4 9f1e37b5 yes)]"
run_case "no declaration, one advert -> OFFER, config untouched" "$T6_OFF" false 0 no 'OFFER.*sudo ts1 trust AC0G-B4 9f1e37b5 <tx_hz>'
browse_returns "[]"
run_case "no declaration, no advert -> stays off" "$T6_OFF" false 0 no 'no TS-1 declared here \(0 advertised'
browse_returns "[$(rec AC0G-B4 9f1e37b5 yes),$(rec FAR 1234abcd yes)]"
run_case "no declaration, two adverts -> no offer" "$T6_OFF" false 0 no 'no TS-1 declared here \(2 advertised'
browse_returns "[$(rec $'AC0G-B4\nx' 9f1e37b5 yes)]"
run_case "no declaration, hostile advert -> no offer, clean line" "$T6_OFF" false 0 no 'no TS-1 declared here \(1 advertised'

# ── the record itself ───────────────────────────────────────────────────────
browse_returns "[]"
printf '[trusted]\nhost = "AC0G-B4"\n' > "$T/trust.toml"
run_case "record missing keys -> refused" "$T6_OFF" false 0 no 'malformed'
printf 'not toml [[[\n' > "$T/trust.toml"
run_case "record unreadable -> refused" "$T6_OFF" false 0 no 'unreadable'
printf '[trusted]\nhost = "AC0G-B4\\n[timing]"\nboard_id = "9f1e37b5"\ntx_hz = 84225000\nadc_hz = 129600000\nfrequency_hz = 45375000\n' > "$T/trust.toml"
run_case "record with a hostile host -> refused" "$T6_OFF" false 0 no 'malformed'
trust AC0G-B4 9f1e37b5 84225000 129600000 45375001
run_case "record whose frequency is not the fold -> refused" "$T6_OFF" false 0 no 'inconsistent'
trust AC0G-B4 9f1e37b5 84225000 64800000 19425000
run_case "declared at 64.8 Msps, radiod now 129.6 -> refused" "$T6_OFF" false 0 no 'ADC rate is 129600000'
trust AC0G-B4 9f1e37b5 129590000 129600000 10000 -
run_case "alias within the channel edge of DC -> refused" "$T6_OFF" false 0 no 'outside'

# ── the ADC rate ────────────────────────────────────────────────────────────
radiod_conf radiod@sigma.conf 'samprate    = 64.8M'
trust AC0G-B4 9f1e37b5 84225000 64800000 19425000
run_case "64.8 Msps -> 19425000 (folded, never negative)" "$T6_OFF" true 19425000 yes 'frequency_hz = 19425000'
trust AC0G-B4 9f1e37b5
radiod_conf radiod@sigma.conf ''
run_case "no samprate in [rx888] -> refused" "$T6_OFF" false 0 no 'samprate'
rm -f "$T/radio/"*
run_case "no radiod config on this host -> refused" "$T6_OFF" false 0 no 'radiod'
radiod_conf radiod@a.conf 'samprate = 129600000'; radiod_conf radiod@b.conf 'samprate = 64800000'
run_case "two radiods at different rates -> refused" "$T6_OFF" false 0 no 'disagree'
rm -f "$T/radio/"*; radiod_conf radiod@sigma.conf 'samprate    = 129600000'
run_case "no [timing.t6_pps] section -> one is added" '[timing]\nlb1421_enabled = false\n' true 45375000 yes 'T6 armed'

[ "$fail" = 0 ] && echo "PASS: site-timing step 4.9" || { echo "FAILED"; exit 1; }
