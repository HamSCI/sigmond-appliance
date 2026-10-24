#!/bin/bash
# test-update-smd-lines.sh — the two functions in test-update-v3.sh that read
# a fact out of smd's printed lines, fed the bytes a real nested run produced.
# No VM, no root; well under a second.
#
# held_names reads the names smd update reports as HELD out of the idempotence
# dry run, so PHASE E can tell "held at a pin that lies behind its upstream"
# from "the update left this component behind".  restore_moved reads the count
# out of restore's success line, which decides what PHASE G may assert.
# PANEL_DEFECT_RE tells the rig whether the base image's console panel sends
# the agent request that Proxmox truncates.
# doctor_pairs reads smd doctor's findings as (component, kind), so PHASE E
# sees a second component catch a kind a first one already had.
# manifest_drift names each installed checkout that bring-up left off the
# blessed manifest.  Those two read the v3.80 update run's own captures, in
# test-fixtures/update-v380/.
#
# Why: the first version passed every check I ran by hand and failed on the rig
# (2026-10-08 23:03Z, "components still behind their upstream: onion(1)").  It
# skipped the line's leading characters with [^[:alnum:]]*.  The warning sign
# reaches the rig double-encoded through `qm guest exec` (303 242 302 232 302
# 240, which reads as a-circumflex plus two controls), the rig runs in a UTF-8
# locale, and there a-circumflex IS alphanumeric.  So the skip stopped, no line
# matched, and no name counted as held.  In the C locale the same expression
# works, which is where I had tried it.
#
#   usage: ./test-update-smd-lines.sh [path/to/test-update-v3.sh]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:-$HERE/test-update-v3.sh}"
# Load ONLY the two functions, each from between its markers.
eval "$(sed -n '/^# >>> held_names/,/^# <<< held_names/p' "$SRC")"
eval "$(sed -n '/^# >>> restore_moved/,/^# <<< restore_moved/p' "$SRC")"
for f in held_names restore_moved; do
    type "$f" >/dev/null 2>&1 || { echo "FAIL: $f not found between its markers in $SRC"; exit 1; }
done

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
E=$'\033'

# The idempotence dry run of 2026-10-08 23:03Z, byte for byte: ANSI colour,
# then each non-ASCII character double-encoded.
RIG="$T/as-the-rig-saw-it.out"
{
    printf '  %s[33m\303\242\302\232\302\240%s[0m  ka9q-radio: cannot compare against upstream \303\242\302\200\302\224 fatal: HEAD does not point to a branch\n' "$E" "$E"
    printf '  %s[33m\303\242\302\232\302\240%s[0m  ft8_lib: HELD \303\242\302\200\302\224 pinned by smd align to 400e2363 \303\242\302\200\302\224 `smd update --unpin` releases it\n' "$E" "$E"
    printf '  %s[33m\303\242\302\232\302\240%s[0m  onion: HELD \303\242\302\200\302\224 pinned by sigmond'"'"'s native build to de8ea938 (docs/native-binaries.md)\n' "$E" "$E"
    printf '  %s[33m\303\242\302\232\302\240%s[0m  wsjtx: HELD \303\242\302\200\302\224 pinned by sigmond'"'"'s native build to ccdfaf3c (docs/native-binaries.md)\n' "$E" "$E"
    printf '  %s[32m\303\242\302\234\302\223%s[0m  host is current \303\242\302\200\302\224 nothing to do\n' "$E" "$E"
} > "$RIG"

# The same lines as smd prints them, should the channel ever stop mangling.
CLEAN="$T/as-smd-prints-it.out"
{
    printf '  %s[33m\342\232\240%s[0m  ft8_lib: HELD \342\200\224 pinned by smd align to 400e2363\n' "$E" "$E"
    printf '  %s[33m\342\232\240%s[0m  onion: HELD \342\200\224 pinned by sigmond'"'"'s native build to de8ea938\n' "$E" "$E"
    printf '  %s[33m\342\232\240%s[0m  wsjtx: HELD \342\200\224 pinned by sigmond'"'"'s native build to ccdfaf3c\n' "$E" "$E"
} > "$CLEAN"

# No colour, no sign: a plain redirect of smd's output.
PLAIN="$T/plain.out"
printf 'onion: HELD - pinned\n  hs-uploader: HELD - uv.lock changed\nka9q_radio.v2+x: HELD - odd name\n' > "$PLAIN"

# Lines that name no held component.
NONE="$T/none.out"
{
    printf '  sigmond: pulled 3 commits\n'
    printf '  host is current, nothing to do (2 components HELD)\n'
    printf '  onion: held back\n'
    printf '  onion:HELD\n'
} > "$NONE"

LOCALES="C"
for l in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
    locale -a 2>/dev/null | grep -qx "$l" && LOCALES="$LOCALES $l"
done
UTF8=$(echo "$LOCALES" | tr ' ' '\n' | grep -i 'utf' | head -1)

expect() {  # expect <name> <locale> <file> <want>
    local got
    got=$(LC_ALL="$2" held_names "$3")
    if [ "$got" = "$4" ]; then echo "  ok   $1 [$2]"
    else echo "  FAIL $1 [$2]: got '$got', want '$4'"; fail=1; fi
}

for l in $LOCALES; do
    expect "the rig's own bytes"            "$l" "$RIG"   "ft8_lib onion wsjtx "
    expect "smd's lines, unmangled"         "$l" "$CLEAN" "ft8_lib onion wsjtx "
    expect "plain lines, odd names"         "$l" "$PLAIN" "hs-uploader ka9q_radio.v2+x onion "
    expect "lines that hold nothing"        "$l" "$NONE"  ""
done
expect "a missing file names nothing" C "$T/absent.out" ""

# Positive control: the fixture must reproduce the defect HERE, or the 'ok'
# lines above prove nothing about it.  The first version's expression, in a
# UTF-8 locale, must find no name in the rig's bytes.
if [ -n "$UTF8" ]; then
    old=$(LC_ALL="$UTF8" sed -E 's/\x1b\[[0-9;]*m//g' "$RIG" \
          | LC_ALL="$UTF8" sed -nE 's/^[^[:alnum:]]*([[:alnum:]_.+-]+): HELD .*/\1/p' | tr '\n' ' ')
    if [ -z "$old" ]; then echo "  ok   control: the first version finds no name in the rig's bytes [$UTF8]"
    else echo "  FAIL control: the first version found '$old' under $UTF8 — this fixture does not reproduce the defect"; fail=1; fi
else
    echo "  FAIL control: no UTF-8 locale on this machine, so the defect cannot be reproduced here"
    fail=1
fi

# ── restore_moved ───────────────────────────────────────────────────────
# Restore's success line.  The mangled form follows the same double-encoding
# the dry run above shows; no capture of this line survives (the rig clears
# its evidence directory at each start), so these bytes are built, not copied.
RM="$T/restore-mangled.out"
{
    printf '  %s[32m\303\242\302\234\302\223%s[0m  hs-uploader: checked out 3e97223\n' "$E" "$E"
    printf '  %s[32m\303\242\302\234\302\223%s[0m  restored to manifest \303\242\302\200\302\224 2 component(s) moved\n' "$E" "$E"
    printf '  %s[32m\303\242\302\234\302\223%s[0m  pipelines.toml re-rendered by the restored sigmond\n' "$E" "$E"
} > "$RM"
RC="$T/restore-clean.out"
printf '  %s[32m\342\234\223%s[0m  restored to manifest \342\200\224 12 component(s) moved\n' "$E" "$E" > "$RC"
RZ="$T/restore-zero.out"
printf '  restored to manifest - 0 component(s) moved\n' > "$RZ"
RN="$T/restore-none.out"
printf '  restore refused: 3 components could not be moved\n  2 component(s) moved earlier\n' > "$RN"

expect_moved() {  # expect_moved <name> <locale> <file> <want>
    local got
    got=$(LC_ALL="$2" restore_moved "$3")
    if [ "$got" = "$4" ]; then echo "  ok   $1 [$2]"
    else echo "  FAIL $1 [$2]: got '$got', want '$4'"; fail=1; fi
}
for l in $LOCALES; do
    expect_moved "restore's line, mangled"      "$l" "$RM" "2"
    expect_moved "restore's line, unmangled"    "$l" "$RC" "12"
    expect_moved "restore moved nothing"        "$l" "$RZ" "0"
    expect_moved "no success line, no count"    "$l" "$RN" ""
done
expect_moved "a missing file gives no count" C "$T/absent.out" ""
# Positive control, as above: the pattern that spelled the dash out must find
# no count in the mangled line.
oldm=$(sed -n 's/.*restored to manifest \xe2\x80\x94 \([0-9]\+\) component(s) moved.*/\1/p' "$RM" | head -1)
if [ -z "$oldm" ]; then echo "  ok   control: the pattern with the dash spelled out finds no count in the mangled line"
else echo "  FAIL control: the old pattern found '$oldm' — this fixture does not reproduce the defect"; fail=1; fi

# ── PANEL_DEFECT_RE ─────────────────────────────────────────────────────
# The signature test-update-v3.sh looks for in the nested host's console panel
# before it holds that panel off.  It must match the panel v3.69 and v3.70
# ship, and must not match a panel that builds the same bytes in the guest.
eval "$(sed -n '/^# >>> panel_defect_re/,/^# <<< panel_defect_re/p' "$SRC")"
[ -n "${PANEL_DEFECT_RE:-}" ] || { echo "FAIL: PANEL_DEFECT_RE not found between its markers in $SRC"; exit 1; }
PD="$T/panel-shipped.sh"
{
    printf '%s\n' '_bu=$(timeout 12 qm guest exec "$VMID" --timeout 8 -- /bin/bash -c \'
    printf '           | grep -E "^\342\224\200\342\224\200\342\224\200|\302\273 " | tail -1 | cut -c1-58 2>/dev/null\n'
} > "$PD"
PF="$T/panel-fixed.sh"
{
    printf '# the panel prints a rule of \342\224\200 and a \302\273 before each step\n'
    printf '%s\n' '         p=$(printf "\342\224\200\342\224\200\342\224\200|\302\273 "); \'
    printf '%s\n' '           | grep -E "^$p" | tail -1 | cut -c1-58 2>/dev/null'
} > "$PF"
if LC_ALL=C grep -q "$PANEL_DEFECT_RE" "$PD"; then echo "  ok   the shipped panel line carries the signature"
else echo "  FAIL the shipped panel line does not match PANEL_DEFECT_RE"; fail=1; fi
if LC_ALL=C grep -q "$PANEL_DEFECT_RE" "$PF"; then echo "  FAIL a panel that builds the bytes in the guest matches PANEL_DEFECT_RE"; fail=1
else echo "  ok   a panel that builds the bytes in the guest carries none"; fi
# The panel this checkout would ship, read from firstboot-v3.sh beside the rig.
# A note, not a verdict: once the panel changes, the hold stops by itself.
FB="$(dirname "$SRC")/firstboot-v3.sh"
if [ -r "$FB" ]; then
    if LC_ALL=C grep -q "$PANEL_DEFECT_RE" "$FB"; then echo "  note this checkout's panel still carries the signature (the rig will hold it off)"
    else echo "  note this checkout's panel carries no signature (the rig will leave it running)"; fi
fi

# ── doctor_pairs, new_pairs, manifest_drift ─────────────────────────────
# Fed the v3.80 update run's own captures (test-fixtures/update-v380/SOURCE).
# That run had hf-timestd "dirty" before the update; the update dirtied
# superdarn-sounder, and PHASE E, comparing bare kinds, passed it.  The same
# run's bring-up had pulled three checkouts past the blessed manifest, and
# nothing said so.
eval "$(sed -n '/^# >>> sha_equal/,/^# <<< sha_equal/p' "$SRC")"
eval "$(sed -n '/^# >>> doctor_pairs/,/^# <<< doctor_pairs/p' "$SRC")"
eval "$(sed -n '/^# >>> manifest_drift/,/^# <<< manifest_drift/p' "$SRC")"
for f in sha_equal sha_of doctor_pairs doctor_kinds new_pairs pairs_orphans manifest_drift; do
    type "$f" >/dev/null 2>&1 || { echo "  FAIL $f not found between its markers in $SRC"; fail=1; }
done
V="$HERE/test-fixtures/update-v380"
same() {  # same <name> <want> <got>
    if [ "$2" = "$3" ]; then echo "  ok   $1"
    else echo "  FAIL $1: got '$3', want '$2'"; fail=1; fi
}
if type new_pairs >/dev/null 2>&1; then
    doctor_pairs "$V/doctor-pre.txt"  "$T/pairs-pre"
    doctor_pairs "$V/doctor-post.txt" "$T/pairs-post"
    same "pre-update pairs, one per finding line" 17 "$(awk 'END{print NR}' "$T/pairs-pre")"
    same "hf-timestd was dirty before the update" 1 "$(grep -cx 'hf-timestd dirty' "$T/pairs-pre")"
    same "the footer line is no finding" 0 "$(grep -c 'finding' "$T/pairs-pre")"
    same "the update's new pairs, nothing sanctioned" \
        "hamsci-dsp ownership|superdarn-sounder dirty|superdarn-sounder ownership" \
        "$(U2_ALLOW_NEW_KINDS='' new_pairs "$T/pairs-pre" "$T/pairs-post" | paste -sd'|')"
    same "U2_ALLOW_NEW_KINDS=ownership leaves the new dirt" \
        "superdarn-sounder dirty" \
        "$(U2_ALLOW_NEW_KINDS=ownership new_pairs "$T/pairs-pre" "$T/pairs-post" | paste -sd'|')"
    same "U2_ALLOW_NEW_KINDS='ownership, dirty' sanctions both" "" \
        "$(U2_ALLOW_NEW_KINDS='ownership, dirty' new_pairs "$T/pairs-pre" "$T/pairs-post" | paste -sd'|')"
    same "a pair that persists is not new" "" \
        "$(U2_ALLOW_NEW_KINDS='' new_pairs "$T/pairs-post" "$T/pairs-post" | paste -sd'|')"
    # doctor_kinds now reads its kinds off the same parser; PHASE G still
    # compares kinds, so its output must not have moved.
    doctor_kinds "$V/doctor-pre.txt" "$T/kinds-pre"
    doctor_kinds "$V/doctor-post.txt" "$T/kinds-post"
    same "doctor_kinds keeps its kinds" "detached dirty ownership untracked" "$(paste -sd' ' "$T/kinds-pre")"
    # Positive control: the bare-kind comparison must find NOTHING new in this
    # fixture, or it does not reproduce the defect.
    same "control: bare kinds see nothing new across the v3.80 update" "" "$(comm -13 "$T/kinds-pre" "$T/kinds-post" | paste -sd'|')"
    same "no orphan kinds in a real doctor report" "" "$(pairs_orphans "$T/pairs-pre" | paste -sd'|')"
    # A doctor whose component headers moved (here: indented) leaves every
    # kind without a component, and a pair check would degrade to a kind
    # check without a word.  pairs_orphans names those kinds.
    printf '  hf-timestd:\n    dirty: 1 modified file(s): x\n  superdarn-sounder:\n    dirty: 1 modified file(s): uv.lock\n' > "$T/doctor-moved.txt"
    doctor_pairs "$T/doctor-moved.txt" "$T/pairs-moved"
    same "a moved header shape leaves orphan kinds" "dirty" "$(pairs_orphans "$T/pairs-moved" | paste -sd'|')"
fi

if type manifest_drift >/dev/null 2>&1; then
    manifest_drift "$V/live-pre.rows" "$V/manifest.rows" > "$T/drift"
    same "the v3.80 drift, one WARN per component" \
"WARN: installed hf-timestd e5009c2 differs from the manifest 55c9670 (bring-up pulls; ruling: fix deferred to v3.82)|WARN: installed psk-recorder 84e81aa differs from the manifest 0bb62df (bring-up pulls; ruling: fix deferred to v3.82)|WARN: installed wspr-recorder b523524 differs from the manifest d171d24 (bring-up pulls; ruling: fix deferred to v3.82)|WARN: 3 of 25 installed component(s) differ from the blessed manifest (bring-up pulls; ruling: fix deferred to v3.82)" \
        "$(paste -sd'|' "$T/drift")"
    manifest_drift "$V/manifest.rows" "$V/manifest.rows" > "$T/drift-none"
    same "a manifest against itself drifts nowhere" \
        "installed components match the blessed manifest (25 compared) ✓" "$(paste -sd'|' "$T/drift-none")"
    # The same commit, abbreviated to different lengths, is no drift; a row
    # on one side only is no sha difference.
    printf 'sigmond f362461\nwsjtx ccdfaf3c1\nonly-live 1234567\n' > "$T/live-abbr.rows"
    printf 'sigmond f362461a\nwsjtx ccdfaf3\nonly-manifest 89abcde\n' > "$T/man-abbr.rows"
    same "abbreviation length is no drift" \
        "installed components match the blessed manifest (2 compared) ✓" \
        "$(manifest_drift "$T/live-abbr.rows" "$T/man-abbr.rows" | paste -sd'|')"
fi

# Every name these blocks define must first be used after its block ends: the
# rig runs top to bottom, while this test evals each block up front and so can
# never see a use that comes too early.
lnum(){ grep -nF -- "$1" "$SRC" | head -1 | cut -d: -f1; }
for blk in sha_equal doctor_pairs manifest_drift; do
    BS="$(lnum "# >>> $blk")"; BE="$(lnum "# <<< $blk")"
    [ -n "$BS" ] && [ -n "$BE" ] || { echo "  FAIL no $blk markers in $SRC"; fail=1; continue; }
    early=""
    for nm in $(sed -n "${BS},${BE}p" "$SRC" | sed -nE 's/^([A-Za-z_][A-Za-z0-9_]*)\(\) *\{.*/\1/p' | sort -u); do
        first="$(awk -v s="$BS" -v e="$BE" -v n="$nm" '(NR < s || NR > e) && $0 !~ /^[[:space:]]*#/ && $0 ~ ("(^|[^A-Za-z0-9_])" n "([^A-Za-z0-9_=]|$)") {print NR; exit}' "$SRC")"
        [ -n "$first" ] && [ "$first" -lt "$BS" ] && early="$early $nm@$first"
    done
    [ -z "$early" ] && echo "  ok   nothing the $blk block defines is used before it" \
        || { echo "  FAIL used before the $blk block defines it:$early"; fail=1; }
done
# PHASE E's order: the drift check reads live-pre.rows after smd version
# writes it and before the update applies; the pair check reads doctor-post.
[ -n "$(lnum 'manifest_drift "$WORK/live-pre.rows"')" ] \
  && [ "$(lnum 'components_rows "$GX_OUT" "$WORK/live-pre.rows"')" -lt "$(lnum 'manifest_drift "$WORK/live-pre.rows"')" ] \
  && [ "$(lnum 'manifest_drift "$WORK/live-pre.rows"')" -lt "$(lnum 'gx_ok 3600 e3-update-apply')" ] \
    && echo "  ok   the manifest drift check runs after install, before the update" \
    || { echo "  FAIL the manifest drift check is missing or out of order"; fail=1; }
[ -n "$(lnum 'new_pairs "$WORK/pairs-pre.txt" "$WORK/pairs-post.txt"')" ] \
  && [ "$(lnum 'doctor_pairs "$WORK/doctor-post.txt"')" -lt "$(lnum 'new_pairs "$WORK/pairs-pre.txt" "$WORK/pairs-post.txt"')" ] \
    && echo "  ok   PHASE E compares (component, kind) pairs" \
    || { echo "  FAIL PHASE E does not compare (component, kind) pairs"; fail=1; }

[ "$fail" = 0 ] && echo "PASS: held_names, restore_moved, PANEL_DEFECT_RE, doctor_pairs, manifest_drift" || echo "FAILED: held_names, restore_moved, PANEL_DEFECT_RE, doctor_pairs, manifest_drift"
exit "$fail"
