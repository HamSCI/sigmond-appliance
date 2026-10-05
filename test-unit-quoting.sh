#!/bin/bash
# test-unit-quoting.sh — every systemd unit firstboot-v3.sh writes from a
# heredoc must parse without "Unbalanced quoting".  No VM, no root; seconds.
#
# Why: sigmond-wizard.service shipped v3.65-v3.67 with an ExecStopPost= whose
# closing ' was missing.  systemd logs "Unbalanced quoting, ignoring" at every
# daemon-reload and DROPS the line, so the getty hand-back after the wizard
# never ran -- invisible on a completed install (the finalizer reboots) and a
# blank tty1 on an aborted one.  Nothing failed, so nothing caught it until the
# v3.67 nested test's PM journal happened to be read (2026-10-05).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/firstboot-v3.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0; n=0
# cat > /etc/systemd/system/<unit> <<'TAG'  ...  TAG
while IFS=$'\t' read -r unit tag; do
    n=$((n + 1))
    awk -v u="$unit" -v t="$tag" '
        index($0, "cat > /etc/systemd/system/" u " <<") == 1 { f = 1; next }
        f && $0 == t { exit }
        f { print }' "$SRC" > "$T/body"
    if [[ "$unit" == */* ]]; then
        # a drop-in (<unit>.d/<x>.conf) is not a unit: verify it as one by
        # appending it to a stub of its parent, which is how systemd reads it
        parent=${unit%%.d/*}
        { printf '[Unit]\nDescription=stub\n[Service]\nExecStart=/bin/true\n'; cat "$T/body"; } > "$T/${parent//@/-x@}"
        f="$T/${parent//@/-x@}"
    else
        cp "$T/body" "$T/$unit"; f="$T/$unit"
    fi
    [ -s "$T/body" ] || { echo "  FAIL $unit: extracted nothing"; fail=1; continue; }
    out=$(systemd-analyze verify "$f" 2>&1 | grep -i "unbalanced quot")
    if [ -n "$out" ]; then echo "  FAIL $unit: $out"; fail=1; else echo "  ok   $unit"; fi
done < <(grep -oE "^cat > /etc/systemd/system/[^ ]+ <<'?[A-Z_]+'?" "$SRC" \
         | sed -E "s#^cat > /etc/systemd/system/([^ ]+) <<'?([A-Z_]+)'?#\1\t\2#")
[ "$n" -gt 0 ] || { echo "FAIL: found no units in $SRC"; exit 1; }
[ "$fail" = 0 ] && echo "PASS: $n unit(s) parse cleanly" || { echo "FAILED"; exit 1; }
