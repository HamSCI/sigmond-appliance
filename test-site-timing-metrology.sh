#!/bin/bash
# test-site-timing-metrology.sh — step 3 of sigmond-site-timing must RECORD
# without a PSWS identity, and must never skip in silence.
#
# WB6CXC-7, 2026-10-01/02, is what this is written against.  Its step 3 ran
# once, at 22:47:39, when /etc/hf-timestd/timestd-config.toml did not exist
# yet (bring-up installed hf-timestd at 23:28).  The gate
# `[ -f "$CFG" ] && [ ! -d "$MC" ]` was false, there was no else branch, and
# it said nothing.  The station then ran with ZERO timestd-metrology@
# instances while timestd-metrology.target still reported "active" — a target
# that pulls in nothing reaches active instantly, so every surface read green.
#
# And the generator's own guard was `if not s.get('callsign') or not
# s.get('id')`, where `id` is the PSWS STATION id.  rob, 2026-10-02:
# "metrology doesn't need PSWS info to record, only to upload."  A station
# with no PSWS registration was therefore recording nothing — the science was
# lost, not merely un-uploaded.
#
# Runs the real generator out of the real script: the embedded python is
# extracted verbatim, so these tests cannot drift from the shipped code.
set -u
SCRIPT="$(dirname "$(readlink -f "$0")")/sigmond-site-timing"
pass=0; fail=0
ok(){   printf '  ✓ %s\n' "$1"; pass=$((pass+1)); }
bad(){  printf '  ✗ %s\n     %s\n' "$1" "$2"; fail=$((fail+1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# The metrology generator is the python block that writes STATION_ID.
python3 - "$SCRIPT" "$TMP/gen.py" <<'PYEOF'
import re, sys, pathlib
s = pathlib.Path(sys.argv[1]).read_text()
for b in re.findall(r"python3 - .*?<<'PYEOF'\n(.*?)\nPYEOF", s, re.S):
    if 'STATION_ID=' in b and 'metrology' not in b.split('\n')[0]:
        pathlib.Path(sys.argv[2]).write_text(b)
        raise SystemExit(0)
raise SystemExit('could not extract the metrology generator')
PYEOF
[ -s "$TMP/gen.py" ] || { echo "FATAL: generator not extracted"; exit 1; }

mkcfg(){ # $1=dest  $2=callsign  $3=psws id  $4=instrument id
    cat > "$1" <<EOF
[station]
callsign = "$2"
grid_square = "CN88ll"
latitude = "47.6"
longitude = "-122.3"
id = "$3"
instrument_id = "$4"
[recorder]
tiered_storage = false
EOF
}

run(){ python3 "$TMP/gen.py" "$1" "$2" 2>&1; }

echo "── a station with NO PSWS identity must still record ──────────────"
mkcfg "$TMP/c1.toml" "WB6CXC/7" "" ""
out=$(run "$TMP/c1.toml" "$TMP/mc1")
n=$(ls -1 "$TMP/mc1"/*.env 2>/dev/null | wc -l)
[ "$out" = ok ] && [ "$n" -eq 6 ] \
    && ok "6 channels generated with no PSWS id (was: silently zero)" \
    || bad "no-PSWS station generated $n channels, generator said '$out'" \
           "this is the defect that left WB6CXC-7 measuring nothing"

echo "── placeholders must never be baked in ────────────────────────────"
mkcfg "$TMP/c2.toml" "WB6CXC/7" "<YOUR_STATION_ID>" "<YOUR_INSTRUMENT_ID>"
run "$TMP/c2.toml" "$TMP/mc2" >/dev/null
if grep -qs 'YOUR_STATION_ID' "$TMP/mc2"/*.env; then
    bad "literal <YOUR_STATION_ID> written into the env files" \
        "nothing regenerates them, so it would upload under that forever"
else
    ok "<YOUR_...> placeholders normalised to empty"
fi
grep -qs '^STATION_ID=$' "$TMP/mc2"/SHARED_2500.env \
    && ok "STATION_ID left empty rather than placeholder" \
    || bad "STATION_ID is not empty" "$(grep -s STATION_ID "$TMP/mc2"/SHARED_2500.env)"

echo "── a real identity is written through ─────────────────────────────"
mkcfg "$TMP/c3.toml" "AC0G/B4" "S000170" "171"
run "$TMP/c3.toml" "$TMP/mc3" >/dev/null
grep -qs '^STATION_ID=S000170' "$TMP/mc3"/WWV_20000.env \
    && ok "a real PSWS id is written (B4's S000170)" \
    || bad "real STATION_ID not written" "$(grep -s STATION_ID "$TMP/mc3"/WWV_20000.env)"

echo "── re-running is idempotent, but an identity CHANGE propagates ────"
out=$(run "$TMP/c3.toml" "$TMP/mc3")
[ "$out" = unchanged ] && ok "second run reports 'unchanged' (no churn)" \
    || bad "re-run reported '$out', expected 'unchanged'" "would rewrite every boot"

mkcfg "$TMP/c4.toml" "AC0G/B4" "S000999" "171"
out=$(run "$TMP/c4.toml" "$TMP/mc3")
if [ "$out" = ok ] && grep -qs '^STATION_ID=S000999' "$TMP/mc3"/WWV_20000.env; then
    ok "a later PSWS registration updates the existing env files"
else
    bad "identity change did NOT propagate (got '$out')" \
        "the old code keyed regeneration on grid/latitude only, so a station id could never update"
fi

echo "── the one thing that IS structural ───────────────────────────────"
mkcfg "$TMP/c5.toml" "" "S000170" "171"
out=$(run "$TMP/c5.toml" "$TMP/mc5")
[ "$out" = skip-callsign ] && ok "no callsign is refused, and says why" \
    || bad "missing callsign returned '$out'" "an unpersonalized host must not scaffold channels"

echo "── the silent skip is gone ────────────────────────────────────────"
# $CFG absent: the shell branch, not the generator.
out=$(CFG=/nonexistent/timestd-config.toml bash -c '
    CFG=/nonexistent/timestd-config.toml
    MC='"$TMP"'/mc6
    say(){ printf "%s\n" "$*"; }
    if [ -f "$CFG" ]; then echo UNREACHABLE; else
        say "⚠ metrology channels SKIPPED — $CFG absent (hf-timestd not configured"
    fi')
printf '%s' "$out" | grep -q 'SKIPPED' \
    && ok "an absent config SAYS so (it used to skip in total silence)" \
    || bad "absent config produced no message" "$out"
# and prove the shipped script carries that else branch, not just this test
grep -q 'metrology channels SKIPPED — $CFG absent' "$SCRIPT" \
    && ok "the shipped script contains the else branch" \
    || bad "shipped script has no else for an absent \$CFG" "the silence would return"

echo "── the one-shot gate must stay gone ───────────────────────────────"
# STRUCTURAL, not behavioural: the tests above drive the extracted generator
# directly, so they cannot see the shell gate that guards it.  Without this
# check, restoring `[ ! -d "$MC" ]` passes the whole suite — verified by
# mutation 2026-10-02.  The gate is one-shot in both directions: it skips
# forever once $MC exists, so a later PSWS registration could never
# propagate, and the content-compare inside the generator becomes dead code.
if grep -qE '^if \[ -f "\$CFG" \] && \[ ! -d "\$MC" \]; then' "$SCRIPT"; then
    bad "the one-shot [ ! -d \"\$MC\" ] gate is back" \
        "step 3 would never re-run, so an identity change can never propagate"
else
    ok "generation is gated on \$CFG alone, not on \$MC being absent"
fi

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
