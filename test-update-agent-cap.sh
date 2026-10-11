#!/bin/bash
# test-update-agent-cap.sh -- the update rig runs each heavy smd request in a
# transient unit of its own, outside the guest agent's 128 MB cap.  No VM, no
# root; well under a second.
#
# Why: sigmond caps qemu-guest-agent.service at MemoryMax=128M, and the cap
# covers every process a `qm guest exec` starts.  On 2026-10-08 23:46:26Z the
# kernel killed restore's child under that cap, and the agent restarted under
# the rig.  `smd update --apply` can run install.sh, uv sync and a native
# build; it passed on the rig only because those runs moved little.
#
#   usage: ./test-update-agent-cap.sh [path/to/test-update-v3.sh]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:-$HERE/test-update-v3.sh}"
pass=0; fail=0
ok(){  printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad(){ printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
UNIT='systemd-run --quiet --wait --pipe --collect --unit=rig-'

# check <label> <ERE>: every gx_ok line whose text matches runs inside a unit.
check(){
    local label="$1" re="$2" lines l
    lines="$(grep -E '^[[:space:]]*gx_ok [0-9]+ ' "$SRC" | grep -E -- "$re")"
    if [ -z "$lines" ]; then
        bad "$label: the rig sends it" "no gx_ok line matches /$re/ in $SRC; did the rig move?"
        return
    fi
    while IFS= read -r l; do
        case "$l" in
            *"$UNIT"*) ok "$label runs in a unit of its own ($(printf '%s' "$l" | awk '{print $3}'))" ;;
            *)         bad "$label runs in a unit of its own" "$l" ;;
        esac
    done <<< "$lines"
}
check 'smd update --apply' 'smd update --apply'
check 'manifest restore --apply' 'manifest restore [^"]*--apply'

# The dry run still goes straight through the agent: the rig keeps proving
# that the production channel answers smd.
dry="$(grep -E '^[[:space:]]*gx_ok [0-9]+ e4-update-dry ' "$SRC")"
case "$dry" in
    "")            bad "the dry smd update still goes straight through the agent" "no e4-update-dry line" ;;
    *systemd-run*) bad "the dry smd update still goes straight through the agent" "$dry" ;;
    *)             ok  "the dry smd update still goes straight through the agent" ;;
esac

# HELD (exit 3) must reach the rig: nothing on the line may swallow the exit.
apply="$(grep -E '^[[:space:]]*gx_ok [0-9]+ e3-update-apply ' "$SRC")"
case "$apply" in
    *'|| true'*|*'; true'*|*'exit 0'*) bad "nothing swallows smd update's exit" "$apply" ;;
    *)                                 ok  "nothing swallows smd update's exit" ;;
esac

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
