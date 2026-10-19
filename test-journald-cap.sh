#!/bin/bash
# test-journald-cap.sh — the golden VM must ship an explicit journald size
# cap.  No VM, no root; seconds.
#
# Why (v3.73 row 18): with no cap, journald takes 10% of the filesystem up to
# 4G.  On AC0G-B4 one noisy unit (timestd-fusion, 124,000 lines an hour)
# filled that, and journald dropped 10-15 13:33Z..10-16 23:41Z, the first day
# of the RX888 stall storm.  The producers now log far less; the cap makes the
# journal's size a stated choice rather than a default.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/provision-components.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# The drop-in body: the heredoc after `tee /etc/systemd/journald.conf.d/...`.
awk '
    index($0, "/etc/systemd/journald.conf.d/50-sigmond-journal-size.conf") && index($0, "<<") { f = 1; next }
    f && $0 == "JOURNALD_EOF" { exit }
    f { print }' "$SRC" > "$T/body"
fail=0
grep -qx '\[Journal\]' "$T/body" || { echo "FAIL: no [Journal] section in the drop-in"; fail=1; }
grep -qx 'SystemMaxUse=4G' "$T/body" || { echo "FAIL: no SystemMaxUse=4G in the drop-in"; fail=1; }
# The script must also prove the cap took effect inside the build VM.
grep -q 'systemd-analyze cat-config systemd/journald.conf' "$SRC" \
    || { echo "FAIL: provision-components.sh never checks the merged journald config"; fail=1; }
[ "$fail" -eq 0 ] && echo "ok: golden VM ships SystemMaxUse=4G"
exit "$fail"
