#!/bin/bash
# test-phase-d-verdict.sh — the Phase D metrology verdict in test-nested-v3.sh,
# fed synthetic guest replies.  No VM, no root; well under a second.
#
# The verdict decides whether a completed bring-up with ZERO metrology units is
# a FATAL (a station that installs cleanly and measures nothing, ad154d3) or the
# one honest exception: a guest with no SDR on its bus, whose bring-up stopped
# at 'radiod configured' for exactly that reason and for no other.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# Load ONLY the verdict function, from between its markers, so the test runs
# the real decision logic without executing the nested test itself.
eval "$(sed -n '/^# >>> phase_d_verdict/,/^# <<< phase_d_verdict/p' "$HERE/test-nested-v3.sh")"
type phase_d_verdict >/dev/null 2>&1 || { echo "FAIL: phase_d_verdict not found"; exit 1; }

fail=0
expect() {  # expect <name> <want-verdict> <want-rc> <reply>
    local got rc
    got=$(phase_d_verdict "$4"); rc=$?
    if [ "$got" = "$2" ] && [ "$rc" = "$3" ]; then echo "  ok   $1"
    else echo "  FAIL $1: got '$got' rc=$rc, want '$2' rc=$3"; fail=1; fi
}

# The reply v3.64 really produced in the nest (2026-10-01 00:46Z).
NEST_NO_SDR='COUNT:0
SDRDEV:0
RADIODSTEP:1
RADIODCHK:1
OTHERCHK:0
OTHERSTEP:0
NOSDRMSG:1'

expect "healthy station with a card -> metrology ok" METROLOGY_OK 0 'COUNT:6
SDRDEV:1
RADIODSTEP:0
RADIODCHK:0
OTHERCHK:0
OTHERSTEP:0
NOSDRMSG:0'

expect "no SDR, stopped at radiod for that reason -> expected" NO_SDR_EXPECTED 0 "$NEST_NO_SDR"

expect "no SDR, but the 'no SDR' message is missing (stderr not logged) -> still expected" \
    NO_SDR_EXPECTED 0 "${NEST_NO_SDR/NOSDRMSG:1/NOSDRMSG:0}"

# The original defect: a card IS present and nothing measures.
expect "card present, zero metrology -> FATAL" FATAL_NO_METROLOGY 1 "${NEST_NO_SDR/SDRDEV:0/SDRDEV:1}"

# No card, but bring-up ALSO failed somewhere else: not the honest exception.
expect "no SDR, another checkpoint failed too -> FATAL" FATAL_NO_METROLOGY 1 "${NEST_NO_SDR/OTHERCHK:0/OTHERCHK:1}"
expect "no SDR, another step failed too -> FATAL" FATAL_NO_METROLOGY 1 "${NEST_NO_SDR/OTHERSTEP:0/OTHERSTEP:2}"

# No card, but radiod did not fail the way a missing card makes it fail.
expect "no SDR, radiod checkpoint passed yet zero metrology -> FATAL" FATAL_NO_METROLOGY 1 "${NEST_NO_SDR/RADIODCHK:1/RADIODCHK:0}"
expect "no SDR, config init radiod never failed -> FATAL" FATAL_NO_METROLOGY 1 "${NEST_NO_SDR/RADIODSTEP:1/RADIODSTEP:0}"

# Any probe line missing from the reply: the claim it backs is unproven, so the
# exception cannot apply.  (NOSDRMSG alone is advisory -- see above.)
for key in COUNT SDRDEV RADIODSTEP RADIODCHK OTHERCHK OTHERSTEP; do
    reply=$(echo "$NEST_NO_SDR" | grep -v "^$key:")
    expect "no $key line in the reply -> FATAL" FATAL_NO_METROLOGY 1 "$reply"
done

# What the probe REALLY returns: qm guest exec wraps stdout in JSON, so the
# KEY:N lines arrive inside one "out-data" string joined by a literal \n.
QM_JSON='{
   "exitcode" : 0,
   "exited" : 1,
   "out-data" : "WIRED:0\nCOUNT:0\nENVS:0\nSDRDEV:0\nRADIODSTEP:1\nRADIODCHK:1\nOTHERCHK:0\nOTHERSTEP:0\nNOSDRMSG:1\n"
}'
expect "real qm-guest-exec JSON shape, no SDR -> expected" NO_SDR_EXPECTED 0 "$QM_JSON"
expect "real qm-guest-exec JSON shape, card present -> FATAL" FATAL_NO_METROLOGY 1 "${QM_JSON/SDRDEV:0/SDRDEV:1}"
expect "real qm-guest-exec JSON shape, healthy -> ok" METROLOGY_OK 0 "${QM_JSON/COUNT:0/COUNT:6}"

# sigmond 7966e69 on: no card -> the radio half is DEFERRED, radiod is never
# configured, and firstrun's marker reads result=awaiting-sdr.  This is the
# reply v3.67 + sigmond 088ffa1 should produce in the nest.
NEST_DEFERRED='COUNT:0
SDRDEV:0
RADIODSTEP:0
RADIODCHK:0
OTHERCHK:0
OTHERSTEP:0
NOSDRMSG:0
AWAITSDR:1'
expect "no SDR, radio half deferred, marker awaiting-sdr -> expected" NO_SDR_EXPECTED 0 "$NEST_DEFERRED"
# What v3.67 (before 088ffa1) really produced: the catch-all smd start failed.
expect "deferred, but a step failed (v3.67 smd start) -> FATAL" FATAL_NO_METROLOGY 1 "${NEST_DEFERRED/OTHERSTEP:0/OTHERSTEP:1}"
expect "deferred, but a checkpoint failed -> FATAL" FATAL_NO_METROLOGY 1 "${NEST_DEFERRED/OTHERCHK:0/OTHERCHK:1}"
expect "awaiting-sdr marker with a card ON the bus -> FATAL" FATAL_NO_METROLOGY 1 "${NEST_DEFERRED/SDRDEV:0/SDRDEV:1}"
expect "deferred, marker NOT awaiting-sdr (claims done) -> FATAL" FATAL_NO_METROLOGY 1 "${NEST_DEFERRED/AWAITSDR:1/AWAITSDR:0}"
for key in COUNT SDRDEV OTHERCHK OTHERSTEP AWAITSDR; do
    reply=$(echo "$NEST_DEFERRED" | grep -v "^$key:")
    expect "deferred reply without $key -> FATAL" FATAL_NO_METROLOGY 1 "$reply"
done

# A garbled or empty reply must never read as a pass.
expect "empty guest reply -> FATAL" FATAL_NO_METROLOGY 1 ''

[ "$fail" = 0 ] && echo "PASS: phase_d_verdict" || { echo "FAILED"; exit 1; }
