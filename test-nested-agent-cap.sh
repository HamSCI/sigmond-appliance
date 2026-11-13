#!/bin/bash
# test-nested-agent-cap.sh -- the nested rig's guest requests (gq) run in a
# transient unit of their own, outside the guest agent's 128 MB cap.  No VM,
# no root; well under a second.
#
# Why: sigmond caps qemu-guest-agent.service at MemoryMax=128M, and the cap
# covers every process a `qm guest exec` starts.  v3.91 attempt 4
# (2026-11-13 15:37Z): the kernel killed `smd remote on` (72 MB, with a 57 MB
# python3 beside it) under that cap, exit 137, and the nested test stopped at
# "remote access 3".  test-update-agent-cap.sh guards the update rig the same way.
#
#   usage: ./test-nested-agent-cap.sh [path/to/test-nested-v3.sh]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:-$HERE/test-nested-v3.sh}"
pass=0; fail=0
ok(){  printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad(){ printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# The body of gq(), from its opening line to the first line that closes it.
body="$(awk '/^[[:space:]]*gq\(\)\{/{on=1} on{print} on&&/^[[:space:]]*\}[[:space:]]*$/{exit}' "$SRC")"
if [ -z "$body" ]; then
    bad "gq() exists" "no gq(){ ... } in $SRC; did the rig move?"
else
    ok "gq() exists"
    sends="$(printf '%s\n' "$body" | grep -E 'qm guest exec' | grep -vE '^[[:space:]]*#')"
    n="$(printf '%s\n' "$sends" | grep -c 'qm guest exec')"
    [ "$n" -ge 1 ] && ok "gq sends through qm guest exec ($n line(s))" \
        || bad "gq sends through qm guest exec" "no qm guest exec line in gq()"
    while IFS= read -r l; do
        [ -z "$l" ] && continue
        case "$l" in
            *"systemd-run --quiet --wait --pipe --collect --unit="*) ok "the request runs in a transient unit" ;;
            *) bad "the request runs in a transient unit" "$l" ;;
        esac
    done <<< "$sends"
    printf '%s\n' "$body" | grep -q 'tr -c' \
        && ok "the unit name is sanitized from the tag" \
        || bad "the unit name is sanitized from the tag" "gq builds the unit name without tr -c"
fi

# Every remote-access request goes through gq, so the unit covers them.
direct="$(grep -nE 'qm guest exec[^|]*smd remote' "$SRC" | grep -v 'gq ' || true)"
[ -z "$direct" ] && ok "no smd remote request bypasses gq" \
    || bad "no smd remote request bypasses gq" "$direct"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
