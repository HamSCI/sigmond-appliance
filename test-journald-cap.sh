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
# The script must prove the cap took effect inside the build VM, and judge
# the EFFECTIVE value: the last SystemMaxUse= in the merged config.  A later
# drop-in that overrides the cap must fail the build.  Run the script's own
# journald_effective_max() against a scratch root, with and without one.
awk '/^journald_effective_max\(\) \{/ { f = 1 } f { print } f && /^\}/ { exit }' "$SRC" > "$T/fn.sh"
if ! grep -q 'journald_effective_max' "$T/fn.sh"; then
    echo "FAIL: provision-components.sh defines no journald_effective_max()"; fail=1
elif ! command -v systemd-analyze >/dev/null; then
    echo "FAIL: systemd-analyze not found — cannot verify the merged value"; fail=1
else
    # shellcheck disable=SC1091
    . "$T/fn.sh"
    R="$T/root"; mkdir -p "$R/etc/systemd/journald.conf.d"
    cp "$T/body" "$R/etc/systemd/journald.conf.d/50-sigmond-journal-size.conf"
    got=$(SYSTEMD_ANALYZE="systemd-analyze --root=$R" journald_effective_max)
    [ "$got" = 4G ] || { echo "FAIL: effective cap reads '$got' with our drop-in alone, want 4G"; fail=1; }
    printf '[Journal]\nSystemMaxUse=1G\n' > "$R/etc/systemd/journald.conf.d/90-later.conf"
    got=$(SYSTEMD_ANALYZE="systemd-analyze --root=$R" journald_effective_max)
    [ "$got" = 1G ] || { echo "FAIL: a later override reads '$got', want 1G (the check would pass a build it must fail)"; fail=1; }
    grep -q '"$(journald_effective_max)" = 4G\|"$_jmax" = 4G' "$SRC" \
        || { echo "FAIL: provision-components.sh does not gate the build on journald_effective_max"; fail=1; }
fi
[ "$fail" -eq 0 ] && echo "ok: golden VM ships SystemMaxUse=4G"
exit "$fail"
