#!/bin/bash
# test-instructions-remote.sh — the three installation documents say how an
# operator turns remote access off and on, and none still describes the
# question the wizard no longer asks.  No VM, no root; under a second.
#
# Why: from v3.71 every install registers for remote access and brings the
# tunnel up, and the wizard asks nothing about it (sigmond
# tasks/plan-remote-access.md).  The operator then holds the switch, in the
# decoder VM: smd remote off, smd remote on.  An install guide that still
# lists "Enable remote access? Y" teaches a step that no longer exists, and
# one that never names the switch leaves the owner with standing access and
# no way known to them to end it.
#
# The documents: INSTALL.md, docs/install-page.html (both published beside
# every blessed image, bless-release.sh gate 7) and QUICKSTART.txt, which
# rides the stick.
#
#   usage: ./test-instructions-remote.sh
#          CONTROL_REF=<git ref> names the release whose documents must FAIL
#          these checks (default v3.70, the last one whose wizard asked).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
CONTROL_REF="${CONTROL_REF:-v3.70}"
DOCS="INSTALL.md docs/install-page.html QUICKSTART.txt"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0

# plain <file> <out>: the file as one line of plain text.  A sentence that a
# document wraps over two lines, or splits across two HTML cells, must still
# read as one sentence to the checks below.
plain(){
    sed -e 's/<[^>]*>/ /g' -e 's/&[A-Za-z]*;/ /g' "$1" | tr '\n\t' '  ' | tr -s ' ' > "$2"
}

# findings <file>: one line per thing wrong with it; nothing when it is right.
findings(){
    local f="$T/plain"
    plain "$1" "$f"
    grep -q 'smd remote off' "$f"    || echo "does not name the command that turns remote access off (smd remote off)"
    grep -q 'smd remote on' "$f"     || echo "does not name the command that turns it on (smd remote on)"
    grep -qi 'enable remote access' "$f" && echo "still lists the wizard's old question (Enable remote access?)"
    grep -Eq 'Remote access +Y' "$f"  && echo "still lists remote access as an answer to prepare"
    grep -Eqi 'remote.access[^.|<]*(says|shows) FAILED' "$f" && echo "still describes the old FAILED line"
    grep -q 'sigmond-setup --rac-o' "$f" && echo "sends the operator to the host for the switch (sigmond-setup --rac-on/--rac-off); the host has no keyboard"
    return 0
}

for d in $DOCS; do
    [ -f "$HERE/$d" ] || { echo "  FAIL $d: missing"; fail=1; continue; }
    out=$(findings "$HERE/$d")
    if [ -z "$out" ]; then echo "  ok   $d"
    else fail=1; printf '%s\n' "$out" | sed "s|^|  FAIL $d: |"; fi
done

# The two published documents also say what registration sends.  The words
# must stand in one sentence: "public" and "station's name" occur elsewhere.
for d in INSTALL.md docs/install-page.html; do
    plain "$HERE/$d" "$T/plain"
    if grep -Eq "station's name and the host's public key" "$T/plain" && grep -qi 'comes up by itself' "$T/plain"; then
        echo "  ok   $d says remote access comes up by itself, and what registering sends"
    else
        echo "  FAIL $d: does not say that remote access comes up by itself and sends the station's name and the host's public key"; fail=1
    fi
done

# Every document names the state `wanted on, not up`, the state that `smd
# remote status` prints.  Naming another state would send the operator after a
# line that no screen shows.
for d in $DOCS; do
    plain "$HERE/$d" "$T/plain"
    if grep -q 'wanted on, not up' "$T/plain"; then echo "  ok   $d names the state wanted on, not up"
    else echo "  FAIL $d: does not name the state 'wanted on, not up' (the state smd remote status prints)"; fail=1; fi
done

# The sigmond checkout beside this one prints those words and holds the timer
# the documents quote.  Without the checkout these checks say so and pass.
SMD_REMOTE="$HERE/../sigmond/lib/sigmond/commands/remote.py"
SMD_WIZARD="$HERE/../sigmond/scripts/proxmox/sigmond-wizard.sh"
if [ -f "$SMD_REMOTE" ]; then
    if grep -q "'Remote access: wanted on, not up'" "$SMD_REMOTE"; then
        echo "  ok   the state the documents quote (wanted on, not up) is one smd remote prints"
    else
        echo "  FAIL the documents quote the state 'wanted on, not up', and smd remote (sigmond lib/sigmond/commands/remote.py) does not print it"; fail=1
    fi
else
    echo "  skip the state the documents quote: no sigmond checkout beside this one"
fi
# "The host tries again every ten minutes" repeats the retry timer's interval.
if [ -f "$SMD_WIZARD" ]; then
    n=$(sed -n "/sigmond-rac-register.timer <<'RACREGTMREOF'/,/^RACREGTMREOF/s/^OnUnitInactiveSec=\([0-9]*\)min\$/\1/p" "$SMD_WIZARD" | head -1)
    case "$n" in 5) w=five;; 10) w=ten;; 15) w=fifteen;; 20) w=twenty;; 30) w=thirty;; *) w="${n:-no-timer}";; esac
    for d in $DOCS; do
        plain "$HERE/$d" "$T/plain"
        got=$(grep -oE 'tries again every [a-z0-9-]+ minutes' "$T/plain" | sort -u)
        if [ "$got" = "tries again every $w minutes" ]; then echo "  ok   $d: the retry interval ($w minutes) is the timer's"
        else echo "  FAIL $d: says [${got:-nothing}] about the retry interval; the host's retry timer reads ${n:-no value} minutes (sigmond-wizard.sh, sigmond-rac-register.timer)"; fail=1; fi
    done
else
    echo "  skip the retry interval: no sigmond checkout beside this one"
fi

# Positive control: the documents of the last release whose wizard asked must
# fail the same checks, or an 'ok' above proves nothing.
for d in $DOCS; do
    if ! git -C "$HERE" show "$CONTROL_REF:$d" > "$T/control" 2>/dev/null; then
        echo "  FAIL control: cannot read $d at $CONTROL_REF (no such ref in this checkout?), so the defect cannot be reproduced here"
        fail=1; continue
    fi
    if [ -n "$(findings "$T/control")" ]; then echo "  ok   control: $d at $CONTROL_REF fails these checks"
    else echo "  FAIL control: $d at $CONTROL_REF passes; these checks cannot tell old instructions from new"; fail=1; fi
done

[ "$fail" = 0 ] && echo "PASS: the installation documents name the remote-access switch" \
                || echo "FAILED: the installation documents and the remote-access switch"
exit "$fail"
