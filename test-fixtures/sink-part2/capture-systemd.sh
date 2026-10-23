#!/bin/bash
# Capture the shapes of the systemd output sp2_state_script reads, from any
# systemd host, read-only (no unit starts, stops or reloads):
#   systemd_show_blocks.txt   systemctl show -p Id -p ActiveState
#                             -p ActiveEnterTimestampMonotonic, for a glob that
#                             matches nothing, a unit that does not exist, and
#                             a running unit (the radiod reader's input)
#   systemd_show_one.txt      systemctl show -p ActiveState
#                             -p ActiveEnterTimestampMonotonic <running unit>
#   systemd_list_units.txt    systemctl list-units --type=service
#                             --state=active --plain --no-legend, the same
#   journal_cat.txt           journalctl -u <unit> -o cat, for a unit whose
#                             journal holds "Started" lines
#   SYSTEMD_SOURCE            the host, systemd's version and the two units
# test-nested-sink-part2.sh checks its stub systemctl and journalctl against
# these, then serves the guest's units in the same shape.
#
#   test-fixtures/sink-part2/capture-systemd.sh [RUNNING_UNIT] [JOURNAL_UNIT]
# RUNNING_UNIT defaults to ssh.service; JOURNAL_UNIT to the first service the
# journal's recent PID 1 lines show starting.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
run="${1:-ssh.service}"
[ "$(systemctl show -p ActiveState --value "$run")" = active ] \
    || { echo "capture-systemd: $run is not running; name a running unit" >&2; exit 1; }
jun="${2:-$(journalctl -o json --no-pager -n 2000 _PID=1 | python3 -c '
import json, sys
found = []
for l in sys.stdin:    # read it all: an early exit would kill journalctl (pipefail)
    d = json.loads(l)
    if d.get("MESSAGE", "").startswith("Started ") and d.get("UNIT", "").endswith(".service"):
        found.append(d["UNIT"])
print(found[0] if found else "")')}"
[ -n "$jun" ] || { echo "capture-systemd: no service with a Started line in the journal; name one" >&2; exit 1; }
systemctl show -p Id -p ActiveState -p ActiveEnterTimestampMonotonic \
    'sp2nosuchunit@*' sp2nosuchunit.service "$run" > "$here/systemd_show_blocks.txt"
systemctl show -p ActiveState -p ActiveEnterTimestampMonotonic "$run" > "$here/systemd_show_one.txt"
systemctl list-units --type=service --state=active --plain --no-legend \
    "$run" 'sp2nosuchunit@*' > "$here/systemd_list_units.txt"
journalctl -u "$jun" -o cat --no-pager -n 60 > "$here/journal_cat.txt"
grep -q '^Started ' "$here/journal_cat.txt" \
    || { echo "capture-systemd: $jun's last 60 journal lines hold no Started line" >&2; exit 1; }
{
    echo "host $(hostname)"
    echo "systemd $(systemctl --version | head -1)"
    echo "running $run"
    echo "journal $jun"
} > "$here/SYSTEMD_SOURCE"
echo "capture-systemd: wrote $here (running $run, journal $jun)"
