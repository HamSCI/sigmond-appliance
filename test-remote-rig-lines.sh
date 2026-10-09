#!/bin/bash
# test-remote-rig-lines.sh — the two readers test-nested-v3.sh uses for its
# remote-access checks, fed the bytes they meet.  No VM, no root; under a
# second.
#
# wizard_answers builds the answers the rig pipes into the wizard.  From v3.71
# the wizard asks nothing about remote access, and the update rig still runs
# these phases on a v3.70 image whose wizard asks.  One answer too many or too
# few shifts every later answer: on 2026-09-23 that made the wizard read a
# station designator as a heartbeat host, and Phase D failed with a message
# that named no prompt.
#
# rr_state reads the state out of `smd remote ...`'s answer.  `smd remote on`
# prints the registration's lines before the state line, so a reader that
# trusts the first line reads nothing.
#
# rr_tok reads one KEY:value line out of a probe's answer.  The probes that run
# on the nested host print their facts as such lines and end with END:1; a
# value may hold colons and spaces ("root:root 755").
#
#   usage: ./test-remote-rig-lines.sh [path/to/test-nested-v3.sh]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:-$HERE/test-nested-v3.sh}"
eval "$(sed -n '/^# >>> remote_rig/,/^# <<< remote_rig/p' "$SRC")"
for f in wizard_answers rr_state rr_tok; do
    type "$f" >/dev/null 2>&1 || { echo "FAIL: $f not found between the remote_rig markers in $SRC"; exit 1; }
done
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
chk(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1: got '$2', want '$3'"; fail=1; fi; }

# ── wizard_answers ──────────────────────────────────────────────────────
mapfile -t OLD < <(wizard_answers 1)
mapfile -t NEW < <(wizard_answers 0)
chk "a wizard that asks gets thirteen answers"      "${#OLD[@]}" 13
chk "a wizard that does not ask gets twelve"        "${#NEW[@]}" 12
chk "the old wizard's fifth answer declines"        "${OLD[4]}" n
chk "the old wizard's PSWS id follows it"           "${OLD[5]}" S000999
chk "the new wizard's PSWS id follows the class"    "${NEW[3]}/${NEW[4]}" n/S000999
chk "both end with apply"                           "${OLD[12]}/${NEW[11]}" Y/Y
chk "the four blank answers stay blank lines"       "$(wizard_answers 0 | grep -c '^$')" 4
# Drop the fifth answer from the old list and the new list must result.
chk "the two lists differ by that one answer alone" \
    "$(printf '%s|' "${OLD[@]:0:4}" "${OLD[@]:5}")" "$(printf '%s|' "${NEW[@]}")"

# ── rr_state ────────────────────────────────────────────────────────────
ans(){ printf '%s\n' "$@" > "$T/a"; rr_state "$T/a"; }
chk "status, on"   "$(ans 'Remote access: on' '  The gateway accepted 6 of 6 channels (RAC 507 on gw2.wsprdaemon.org).')" on
chk "status, off"  "$(ans 'Remote access: off' '  The operator holds it off.')" off
chk "status, down" "$(ans 'Remote access: wanted on, not up' '  The tunnel service does not run.')" down
# `smd remote on` on a station that registers first: the state line comes
# sixth, after smd's own line and the registration's.
ON_AFTER_REGISTERING=(
    '     asking the Proxmox host; this can take a minute while the tunnel comes up'
    'This station has not registered for remote access yet. Registering now.'
    '[wizard] registering with the gateway: this sends the station'"'"'s name (N0CALL_T1) and this host'"'"'s public key'
    '[wizard] trying pinned — 127.0.0.1:35735 (registrar http://127.0.0.1:35737/register)'
    '[wizard] registered: RAC #599 via pinned'
    'Waiting up to 60s for the gateway to accept the channels.'
    'Remote access: wanted on, not up'
    '  The tunnel service runs, and the gateway has accepted none of its 6 channels (RAC 599 on 127.0.0.1, pinned).'
)
chk "on, after the registration's lines" "$(ans "${ON_AFTER_REGISTERING[@]}")" down
chk "an indented state line names no state"        "$(ans '  Remote access: on')" ""
chk "a longer line names no state"                 "$(ans 'Remote access: online')" ""
# Each of the three lines is matched whole, not only the first one.
chk "a longer off line names no state"             "$(ans 'Remote access: offline')" ""
chk "a longer down line names no state"            "$(ans 'Remote access: wanted on, not up yet')" ""
chk "a refusal names no state"                     "$(ans 'sigmond-rac-switch: refused. It takes exactly one word: on, off or status.')" ""
chk "smd's not-paired message names no state"      "$(ans '  x  this VM holds no pairing with its Proxmox host')" ""
chk "an empty answer names no state"               "$(: > "$T/a"; rr_state "$T/a")" ""
chk "a missing file names no state"                "$(rr_state "$T/absent")" ""

# ── rr_tok ──────────────────────────────────────────────────────────────
PROBE='WISH:on
HOMEOWN:root:root 755
AKLINES:1
EMPTY:
 INDENTED:9
AKLINES2:2
SUDOPATHS:/usr/local/sbin/sigmond-rac-switch
AKLINES:7
END:1'
chk "a value that holds colons and spaces"          "$(rr_tok HOMEOWN "$PROBE")" "root:root 755"
chk "a plain number"                                "$(rr_tok AKLINES "$PROBE")" 1
chk "the first line of a repeated key wins"         "$(rr_tok AKLINES "$PROBE")" 1
chk "a key is not a prefix of a longer key"         "$(rr_tok AKLINES2 "$PROBE")" 2
chk "a longer key does not answer for a shorter"    "$(rr_tok AKLINE "$PROBE")" ""
chk "an empty value reads empty"                    "$(rr_tok EMPTY "$PROBE")" ""
chk "an indented line names no key"                 "$(rr_tok INDENTED "$PROBE")" ""
chk "a missing key reads empty"                     "$(rr_tok NOSUCH "$PROBE")" ""
chk "a path value"                                  "$(rr_tok SUDOPATHS "$PROBE")" /usr/local/sbin/sigmond-rac-switch
chk "the end token reads 1"                         "$(rr_tok END "$PROBE")" 1
chk "no text at all reads empty"                    "$(rr_tok END "")" ""
# A key with a regex metacharacter must be taken literally.
chk "a dot in the key is not a wildcard"            "$(rr_tok 'A.LINES' "$PROBE")" ""

# Positive control: the fixture must defeat the reader this one replaced, or
# the 'ok' above proves nothing.  A reader that trusts the first line finds no
# state in the answer of an `on` that registered first.
printf '%s\n' "${ON_AFTER_REGISTERING[@]}" > "$T/a"
case "$(head -1 "$T/a")" in
    "Remote access: "*) echo "  FAIL control: the first line of the fixture already names the state"; fail=1 ;;
    *) echo "  ok   control: a first-line reader finds no state in the same answer" ;;
esac

[ "$fail" = 0 ] && echo "PASS: wizard_answers, rr_state" || echo "FAILED: wizard_answers, rr_state"
exit "$fail"
