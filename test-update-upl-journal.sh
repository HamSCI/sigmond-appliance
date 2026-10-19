#!/bin/bash
# test-update-upl-journal.sh — the awk in test-update-v3.sh's UPL_SPLIT probe
# that finds the hs-uploader stop and start in `journalctl -o short-unix`,
# fed lines in systemd's real format.  systemd logs the unit's Description
# ("HamSCI single-host uploader (hs-uploader serve)"), never "hs-uploader",
# so a match on the unit name finds nothing.  No VM, no root.
#
#   usage: ./test-update-upl-journal.sh [path/to/test-update-v3.sh]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:-$HERE/test-update-v3.sh}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
sed -n '/^# >>> upl_journal_awk/,/^# <<< upl_journal_awk/p' "$SRC" > "$T/prog.awk"
[ -s "$T/prog.awk" ] || { echo "FAIL: no upl_journal_awk block in $SRC"; exit 1; }
fail=0
check(){ # <name> <want> <got>
    if [ "$2" = "$3" ]; then echo "  ok    $1"; else echo "  FAIL  $1: want '$2', got '$3'"; fail=1; fi
}
cat > "$T/journal.txt" <<'J'
1760000100.111111 vm systemd[1]: Started HamSCI single-host uploader (hs-uploader serve).
1760000200.222222 vm systemd[1]: Stopping HamSCI single-host uploader (hs-uploader serve)...
1760000201.333333 vm hs-uploader[900]: Stopping hs-uploader
1760000202.444444 vm systemd[1]: hs-uploader.service: Deactivated successfully.
1760000202.555555 vm systemd[1]: Stopped HamSCI single-host uploader (hs-uploader serve).
1760000203.666666 vm systemd[1]: Starting HamSCI single-host uploader (hs-uploader serve)...
1760000205.777777 vm systemd[1]: Started HamSCI single-host uploader (hs-uploader serve).
1760000300.888888 vm systemd[1]: Stopping HamSCI single-host uploader (hs-uploader serve)...
J
out=$(awk -f "$T/prog.awk" "$T/journal.txt")
check "the first stop is found" "JSTOP:1760000200" "$(printf '%s\n' "$out" | grep JSTOP)"
check "the start after it is found, not the one before" "JSTART:1760000205" "$(printf '%s\n' "$out" | grep JSTART)"
check "nothing else printed" "2" "$(printf '%s\n' "$out" | wc -l)"
printf '1760000100.1 vm systemd[1]: Started HamSCI single-host uploader (hs-uploader serve).\n' > "$T/nostop.txt"
check "a start with no stop prints nothing" "" "$(awk -f "$T/prog.awk" "$T/nostop.txt")"
if [ "$fail" = 0 ]; then echo "PASS: upl_journal_awk"; else exit 1; fi
