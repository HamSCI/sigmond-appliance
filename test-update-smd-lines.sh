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

[ "$fail" = 0 ] && echo "PASS: held_names, restore_moved, PANEL_DEFECT_RE" || echo "FAILED: held_names, restore_moved, PANEL_DEFECT_RE"
exit "$fail"
