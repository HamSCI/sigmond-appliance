#!/bin/bash
# test-update-upl-mig3.sh — the function in test-update-v3.sh that reads
# migration 3's facts out of the manifest step's printed lines: migrate's
# report ("watermarks.db: version N", "applied 3: ...", the column and table
# lines) and sigmond's features line.  Fed lines in the real format, with
# leading spaces as migrate prints them and the double-encoded warning sign as
# `qm guest exec` hands it back.  No VM, no root.
#
#   usage: ./test-update-upl-mig3.sh [path/to/test-update-v3.sh]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:-$HERE/test-update-v3.sh}"
eval "$(sed -n '/^# >>> mig3_facts/,/^# <<< mig3_facts/p' "$SRC")"
type mig3_facts >/dev/null 2>&1 || { echo "FAIL: mig3_facts not found between its markers in $SRC"; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
check(){ # <name> <want> <got>
    if [ "$2" = "$3" ]; then echo "  ok    $1"; else echo "  FAIL  $1: want '$2', got '$3'"; fail=1; fi
}
tok(){ sed -n "s/^$2:\([0-9][0-9]*\)\$/\1/p" "$1" | head -1; }

# A version-2 store moving to 3, then a v3.77 sigmond's features line.
cat > "$T/up.txt" <<'X'
watermarks.db: version 2
  applied 3: name the pipeline and client in the send log; add last_send
  added column attempts.pipeline (TEXT NOT NULL DEFAULT '')
  added column attempts.client (TEXT NOT NULL DEFAULT '')
  created table last_send (client, pipeline, outcome, ts, records)
uploader: hs-uploader features: pipelines.d send-log-v3 switch-files
  stopping hs-uploader.service
X
mig3_facts "$T/up.txt" > "$T/up.facts"
check "applied 3 found"        1 "$(tok "$T/up.facts" APPLIED3)"
check "applied line number"    2 "$(tok "$T/up.facts" APPLIED3_LN)"
check "pipeline column added"  1 "$(tok "$T/up.facts" COLPIPE)"
check "client column added"    1 "$(tok "$T/up.facts" COLCLIENT)"
check "last_send created"      1 "$(tok "$T/up.facts" TABLE)"
check "feature pipelines.d"    1 "$(tok "$T/up.facts" F_PIPELINESD)"
check "feature send-log-v3"    1 "$(tok "$T/up.facts" F_SENDLOGV3)"
check "feature switch-files"   1 "$(tok "$T/up.facts" F_SWITCHFILES)"
check "features not none"      0 "$(tok "$T/up.facts" F_NONE)"
check "features line seen"     1 "$(tok "$T/up.facts" F_LINE)"

# Through the channel: warning-sign bytes ahead of the features line.
printf 'watermarks.db: version 3\n  nothing to do\n  \303\242\302\232\302\240 uploader: hs-uploader features: pipelines.d send-log-v3\n' > "$T/mangled.txt"
mig3_facts "$T/mangled.txt" > "$T/m.facts"
check "no applied 3 on a v3 store" 0 "$(tok "$T/m.facts" APPLIED3)"
check "features line behind a prefix" 1 "$(tok "$T/m.facts" F_LINE)"
check "a missing word reads 0"  0 "$(tok "$T/m.facts" F_SWITCHFILES)"
check "a present word reads 1"  1 "$(tok "$T/m.facts" F_SENDLOGV3)"

# An older hs-uploader.
printf 'uploader: hs-uploader features: none\n' > "$T/none.txt"
mig3_facts "$T/none.txt" > "$T/n.facts"
check "none reads F_NONE"      1 "$(tok "$T/n.facts" F_NONE)"
check "none sets no word"      0 "$(tok "$T/n.facts" F_PIPELINESD)"

# Look-alikes that must not count: applied 2, a feature word in prose.
printf 'watermarks.db: version 2\n  applied 2: something older\n  applied 30: not three\nfeatures: pipelines.d\n' > "$T/lk.txt"
mig3_facts "$T/lk.txt" > "$T/l.facts"
check "applied 2 and 30 are not 3" 0 "$(tok "$T/l.facts" APPLIED3)"
check "a bare 'features:' is not the line" 0 "$(tok "$T/l.facts" F_LINE)"

: > "$T/empty.txt"
mig3_facts "$T/empty.txt" > "$T/e.facts"
check "empty input prints every key" 10 "$(wc -l < "$T/e.facts")"
if [ "$fail" = 0 ]; then echo "PASS: mig3_facts"; else exit 1; fi
