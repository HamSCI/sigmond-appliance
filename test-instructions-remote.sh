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
# The host has no keyboard of its own once the install ends, so the switch the
# documents teach is the VM's.  They may name the host's own switch
# (sigmond-setup --rac-off, --rac-on) in two forms only, the two in which a
# reader can type it: as a whole command for another computer (ssh root@<host>
# '...'), which is what the console panel prints on a station that has not
# paired; or after the document has said how a keyboard at the station reaches a
# login on the host.
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

# raw <file> <out>: the file as one line, tags and placeholders kept.  plain()
# takes `<VM address>` and `<host-ip>` for tags and drops them, so a check that
# reads an address reads this form.
raw(){
    tr '\n\t' '  ' < "$1" | tr -s ' ' > "$2"
}

# before <file> <needle> <n>: for every place the needle stands in the file's
# one line, the n characters ahead of it and the needle itself, one per line.
# (awk and index(), not `grep -Eo '.{0,n}needle'`: grep takes minutes over a
# bounded repeat that long on a line of this size.)
before(){
    awk -v needle="$2" -v n="$3" '{
        off = 0; s = $0
        while ((i = index(s, needle)) > 0) {
            pos = off + i
            start = pos - n; if (start < 1) start = 1
            print substr($0, start, pos - start + length(needle))
            off = pos + length(needle) - 1
            s = substr($0, off + 1)
        }
    }' "$1"
}

# findings <file>: one line per thing wrong with it; nothing when it is right.
findings(){
    local f="$T/plain" r="$T/raw" who where
    plain "$1" "$f"
    raw "$1" "$r"
    grep -q 'smd remote off' "$f"    || echo "does not name the command that turns remote access off (smd remote off)"
    grep -q 'smd remote on' "$f"     || echo "does not name the command that turns it on (smd remote on)"
    grep -qi 'enable remote access' "$f" && echo "still lists the wizard's old question (Enable remote access?)"
    grep -Eq 'Remote access +Y' "$f"  && echo "still lists remote access as an answer to prepare"
    grep -Eqi 'remote.access[^.|<]*(says|shows) FAILED' "$f" && echo "still describes the old FAILED line"
    # The host's own switch, only where the reader can type it (see the head of this file).
    # The context ends at the last sentence end before the command, so the
    # sentence that names the command must itself give the way to type it; a
    # "login on the host" two sentences earlier does not carry a bare command.
    before "$r" "sigmond-setup --rac-o" 400 \
        | sed -E 's/^.*[.!?] +//' \
        | grep -Evq "login on the host|ssh root@[^']{1,40}'sigmond-setup --rac-o\$" \
        && echo "names the host's own switch (sigmond-setup --rac-on/--rac-off) without a way to type it: neither as ssh root@<host> '...' nor after saying how to reach a login on the host"
    # The VM's own address reaches nothing from the operator's network on a
    # station with the private link.  It may stand as an ssh target only beside
    # the words "old layout".
    for who in sigmond hamsci; do
        for where in '<VM address>' '<vm-ip>' '&lt;recorder&gt;'; do
            before "$r" "$who@$where" 200
        done
    done | grep -vqi 'old layout' \
        && echo "gives the VM's own address as an ssh target without naming the old layout"
    # The keyboard: the documents once called the console read-only.  A keyboard
    # at the station types into the VM, and that reaches a login on the host.
    grep -qi 'console is read-only' "$f" && echo "still calls the console read-only"
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

# What a keyboard at the station still does, and what the panel prints on a
# station whose two machines have not paired.  Both read out of firstboot-v3.sh,
# which draws the panel and installs the split console.
FB="$HERE/firstboot-v3.sh"
grep -q 'KEYBOARD WORKS HERE — press Enter for a login to THIS host' "$FB" \
    && grep -q 'TYPE THE PROXMOX HOST ROOT PASSWORD' "$FB" \
    && echo "  ok   firstboot: the panel's first line offers a login on the host, and the screen asks for its root password" \
    || { echo "  FAIL firstboot-v3.sh no longer prints the keyboard line, or the password prompt, that the documents repeat"; fail=1; }
grep -qF "printf \"type on another computer:  ssh root@%s 'sigmond-setup --rac-%s'\"" "$FB" \
    && echo "  ok   firstboot: the panel prints the host's own switch as ssh root@<host> '...' on a station that has not paired" \
    || { echo "  FAIL firstboot-v3.sh no longer prints the unpaired instruction the documents repeat"; fail=1; }
for d in $DOCS; do
    plain "$HERE/$d" "$T/plain"; raw "$HERE/$d" "$T/raw"
    miss=""
    grep -q 'press Enter for a login to THIS host' "$T/plain" || miss="$miss; does not quote the panel's line (press Enter for a login to THIS host)"
    grep -q 'login on the host' "$T/plain"   || miss="$miss; does not say that the keyboard reaches a login on the host"
    grep -qi 'nothing shows while you type' "$T/plain" || miss="$miss; does not say that the password does not show"
    for c in 'sigmond-setup --rac-off' 'sigmond-setup --rac-on' 'sigmond-setup --pair-vm'; do
        grep -q -- "$c" "$T/plain" || miss="$miss; does not name $c"
    done
    grep -Eq "ssh root@[^']{1,40}'sigmond-setup --rac-off'" "$T/raw" || miss="$miss; does not give the line the panel prints on a station that has not paired"
    grep -qi 'not paired' "$T/plain" || miss="$miss; does not say when the panel prints that line (the two machines have not paired)"
    if [ -z "$miss" ]; then echo "  ok   $d says what a keyboard at the station does, and what an unpaired station's panel prints"
    else fail=1; echo "  FAIL $d${miss#;}"; fi
done

# The two panel lines the documents repeat for the bring-up and the guest
# agent.  Each is the first line of its BRINGUP="..." text in firstboot-v3.sh,
# cut to the words an operator can match: from the marker to the line's end or
# the first comma, colon or period.  A changed word in the panel fails here.
panel_words(){   # panel_words <fixed text that starts the line's words>
    sed -n 's/^ *BRINGUP=" [.!>]* *//p' "$FB" | grep -F -- "$1" | head -1 \
        | sed -E 's/[,:.].*$//; s/ +$//'
}
for need in 'bring-up ran WITHOUT the radio' "the decoder VM's guest agent does not answer"; do
    w=$(panel_words "$need" | grep -o -F -- "$need")
    if [ -z "$w" ]; then
        echo "  FAIL firstboot-v3.sh: no BRINGUP line holds [$need], which the documents quote"; fail=1; continue
    fi
    for d in $DOCS; do
        plain "$HERE/$d" "$T/plain"
        if grep -q -F -- "$w" "$T/plain"; then echo "  ok   $d quotes the panel's [$w]"
        else echo "  FAIL $d: does not quote the panel's line [$w]"; fail=1; fi
    done
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

# The two guards on what a reader can type must be able to fail.  Each mutant is
# INSTALL.md with one sentence added.
mutant(){   # mutant <name> <sentence> <words the finding must hold>
    { cat "$HERE/INSTALL.md"; printf '\n%s\n' "$2"; } > "$T/mutant.md"
    if findings "$T/mutant.md" | grep -q -- "$3"; then echo "  ok   control: $1"
    else echo "  FAIL control: $1: the checks passed a document that says: $2"; fail=1; fi
}
mutant "a bare ssh to the VM's own address is caught" \
       'Log in to the decoder VM with `ssh sigmond@<VM address>` from your laptop.' "without naming the old layout"
mutant "the host's own switch with no way to type it is caught" \
       'To turn remote access off, run `sigmond-setup --rac-off` on the Proxmox machine.' "without a way to type it"
mutant "the old words about the console are caught" \
       'The panel says the console is read-only.' "read-only"

[ "$fail" = 0 ] && echo "PASS: the installation documents name the remote-access switch" \
                || echo "FAILED: the installation documents and the remote-access switch"
exit "$fail"
