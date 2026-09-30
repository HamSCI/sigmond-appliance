#!/bin/bash
# test-publish-lib.sh — publish-lib.sh against stub rclone/ssh/scp.  No network,
# no Drive, no wd30; ~1 s.  Covers the three targets' paths and the bless-time
# prune of superseded pending/ builds (mjh 2026-09-30).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
for c in rclone ssh scp; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\n' "$c" "$T" > "$T/bin/$c"; chmod +x "$T/bin/$c"
done
export PATH="$T/bin:$PATH"
. "$HERE/publish-lib.sh"

fail=0
check() { if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1"; fail=1; fi; }

B=sigmond-appliance-v3.61-20260930-release.img
L="sigmond-appliance-v3.57-20260929-release.img
sigmond-appliance-v3.57-20260929-release.sha256
sigmond-appliance-v3.60-20260930-release.manifest.txt
sigmond-appliance-v3.61-20260930-release.img
sigmond-appliance-v3.61-20260930-release.sha256
sigmond-appliance-v3.61-20260930-release.manifest.txt
sigmond-appliance-v3.61-20260929-release.img
sigmond-appliance-v3.62-20261001-release.img
sigmond-appliance-v3.100-20261101-release.img
sigmond-appliance-v3.9-20260801-release.img
notes.txt"
# shellcheck disable=SC2086
D="$(pub_superseded "$B" $L)"
echo "pub_superseded:"
check "deletes a lower version"             'grep -qx "sigmond-appliance-v3.57-20260929-release.img" <<<"$D"'
check "deletes every file of a lower build" 'grep -qx "sigmond-appliance-v3.57-20260929-release.sha256" <<<"$D"'
check "deletes 3.9 (numeric, not lexical)"  'grep -qx "sigmond-appliance-v3.9-20260801-release.img" <<<"$D"'
check "deletes another build of the same version" 'grep -qx "sigmond-appliance-v3.61-20260929-release.img" <<<"$D"'
check "keeps the blessed build's files"     '! grep -q "v3.61-20260930" <<<"$D"'
check "keeps a newer candidate"             '! grep -q "v3.62" <<<"$D"'
check "keeps 3.100 (numeric, not lexical)"  '! grep -q "v3.100" <<<"$D"'
check "leaves unversioned files alone"      '! grep -q "notes.txt" <<<"$D"'
check "exactly five deletions"              '[ "$(wc -l <<<"$D")" = 5 ]'

echo "transports:"
: > "$T/calls"
pub_delete_pending "ssh:wd30:" a.img b.sha256
check "ssh delete stays inside ~/pending" 'grep -q "wd30 cd '"'"'./pending'"'"' && rm -f  '"'"'a.img'"'"' '"'"'b.sha256'"'"'" "$T/calls"'
: > "$T/calls"
pub_delete_pending "gdrive,root_folder_id=X:" a.img
check "rclone delete joins a trailing-colon remote" 'grep -qx "rclone deletefile gdrive,root_folder_id=X:pending/a.img" "$T/calls"'
: > "$T/calls"
pub_delete_pending "ssh:wd30:"
check "no names, no command"               '[ ! -s "$T/calls" ]'

[ "$fail" = 0 ] && echo "ALL PASS" || { echo "FAILED"; exit 1; }
