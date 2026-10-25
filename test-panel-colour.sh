#!/bin/bash
# test-panel-colour.sh — colour on the console panel (v3.82 row 2, Chris's
# request): addresses bold cyan, logins bold green, the default password bold
# yellow, on VT1 and /etc/issue.  /etc/motd stays plain.  Colour must change
# nothing visible: stripped of its codes the panel equals the colour-off
# panel byte for byte, so width and height stay what they were, and no escape
# sits before a sed range marker or inside a phrase the rig greps.
set -u
cd "$(dirname "$(readlink -f "$0")")"
FB=firstboot-v3.sh
pass=0; fail=0
ok(){  printf '  ✓ %s\n' "$1"; pass=$((pass+1)); }
bad(){ printf '  ✗ %s\n     %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
ESC=$(printf '\033')

sed -n '/^# >>> panel_colour/,/^# <<< panel_colour/p' "$FB" > "$TMP/block.sh"
if [ -s "$TMP/block.sh" ] && bash -n "$TMP/block.sh"; then
    got=$(bash -c ". '$TMP/block.sh'; _hl addr 10.0.0.5")
    [ "$got" = "${ESC}[1;36m10.0.0.5${ESC}[0m" ] \
        && ok "the panel_colour block loads; _hl addr 10.0.0.5 prints ESC[1;36m10.0.0.5ESC[0m" \
        || bad "_hl addr output wrong" "$(printf '%s' "$got" | od -c | head -2)"
    got=$(bash -c ". '$TMP/block.sh'; _hl login root; _hl pw x")
    [ "$got" = "${ESC}[1;32mroot${ESC}[0m${ESC}[1;33mx${ESC}[0m" ] \
        && ok "_hl login is bold green, _hl pw bold yellow, each closed with ESC[0m" \
        || bad "_hl login/pw output wrong"
    got=$(SIGMOND_PANEL_COLOUR=0 bash -c ". '$TMP/block.sh'; _hl addr 10.0.0.5")
    [ "$got" = "10.0.0.5" ] \
        && ok "SIGMOND_PANEL_COLOUR=0: _hl prints the bare text" \
        || bad "_hl is not bare with colour off"
else
    bad "could not extract the panel_colour block" "markers missing or the block does not parse"
    printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"; exit 1
fi

python3 - "$FB" "$TMP/issue.sh" <<'PYX'
import re, sys, pathlib
s = pathlib.Path(sys.argv[1]).read_text()
m = re.search(r"cat > /usr/local/sbin/sigmond-issue <<'ISSEOF'\n(.*?)\nISSEOF\n", s, re.S)
if not m: raise SystemExit("could not extract sigmond-issue")
pathlib.Path(sys.argv[2]).write_text(m.group(1))
PYX
[ -s "$TMP/issue.sh" ] || { echo "FATAL: extraction failed"; exit 1; }

mkdir -p "$TMP/bin" "$TMP/fakeroot/etc/sigmond-appliance"
: > "$TMP/fakeroot/etc/sigmond-appliance/.finalized"
cat > "$TMP/bin/qm" <<'QM'
#!/bin/bash
case "$*" in
  *network-get-interfaces*) echo '[{"name":"eth0","ip-addresses":[{"ip-address-type":"ipv4","ip-address":"192.168.1.50","prefix":24}]}]' ;;
esac
exit 0
QM
printf '#!/bin/bash\nexit 1\n' > "$TMP/bin/systemctl"
printf '#!/bin/bash\nexit 0\n' > "$TMP/bin/who"
printf '#!/bin/bash\nexit 0\n' > "$TMP/bin/logger"
chmod +x "$TMP/bin"/*

# A shadow file whose root hash is the image default, so the default-password
# branch runs; and one whose hash is not.
perl -e 'print "root:".crypt("hamsci-sigmond","\$6\$saltsalt\$")."::::::\n"' > "$TMP/shadow.default"
echo 'root:$6$saltsalt$notthedefaultnotthedefaultnotthedefaultnotthedefaultnotthedefaultnotthedefaultnotthed:::::' > "$TMP/shadow.custom"

# run <tag> <colour 0|1> <shadow file>: a full sigmond-issue run into $TMP/<tag>.*
run(){
    local t="$1" col="$2" sh="$3"
    sed -e "s#/dev/tty1#$TMP/$t.vt1#g" -e "s#/etc/issue#$TMP/$t.issue#g" \
        -e "s#/etc/motd#$TMP/$t.motd#g" -e "s#/etc/shadow#$sh#g" \
        -e "s#/etc/sigmond-appliance#$TMP/fakeroot/etc/sigmond-appliance#g" \
        -e "s#/run/sigmond-issue.lock#$TMP/$t.lock#g" "$TMP/issue.sh" > "$TMP/$t.sh"
    : > "$TMP/$t.vt1"; : > "$TMP/$t.issue"; : > "$TMP/$t.motd"
    PATH="$TMP/bin:$PATH" SIGMOND_PANEL_COLOUR="$col" timeout 120 bash "$TMP/$t.sh" >/dev/null 2>&1
}
run col 1 "$TMP/shadow.default"
run plain 0 "$TMP/shadow.default"
run cust 1 "$TMP/shadow.custom"

echo "── a full run ─────────────────────────────────────────────────────"
if grep -q "${ESC}\[1;36m" "$TMP/col.issue" && grep -q "${ESC}\[1;36m" "$TMP/col.vt1"; then
    ok "a full run writes escape codes into /etc/issue and the VT1 capture"
else
    bad "no colour in /etc/issue or VT1" "$(head -c 600 "$TMP/col.issue")"
fi
grep -q "$ESC" "$TMP/col.motd" \
    && bad "/etc/motd holds an escape byte" "SSH, the RAC and pam_motd read it" \
    || { [ -s "$TMP/col.motd" ] && ok "/etc/motd holds no escape byte" || bad "/etc/motd is empty"; }

# the panel text between the markers, stripped of codes
panel_of(){ sed -n '/^════ Sigmond appliance /,/^════ end Sigmond panel/p' "$1" | sed 's/\x1b\[[0-9;]*m//g'; }
panel_of "$TMP/col.issue" > "$TMP/col.stripped"
panel_of "$TMP/plain.issue" > "$TMP/plain.text"
if [ -s "$TMP/col.stripped" ] && cmp -s "$TMP/col.stripped" "$TMP/plain.text"; then
    ok "/etc/issue with codes stripped == /etc/issue from a SIGMOND_PANEL_COLOUR=0 run (same text, so same fit)"
else
    bad "stripped panel differs from the colour-off panel" "$(diff "$TMP/col.stripped" "$TMP/plain.text" | head -6)"
fi
panel_of "$TMP/col.motd" | cmp -s - "$TMP/plain.text" \
    && ok "/etc/motd equals the colour-off panel" \
    || bad "/etc/motd differs from the colour-off panel"

echo "── the boundaries colour must not cross ───────────────────────────"
bad_marks=$(grep -n 'Sigmond appliance\|end Sigmond panel' "$TMP/col.issue" | grep -v -e '^[0-9]*:════ Sigmond appliance ' -e '^[0-9]*:════ end Sigmond panel' | grep -c .)
n_marks=$(grep -c -e '^════ Sigmond appliance ' -e '^════ end Sigmond panel' "$TMP/col.issue")
if [ "$bad_marks" -eq 0 ] && [ "$n_marks" -ge 2 ] && ! grep -e 'Sigmond appliance' -e 'end Sigmond panel' "$TMP/col.issue" | grep -q "$ESC"; then
    ok "markers carry no escape: every '════ Sigmond appliance' and '════ end Sigmond panel' line starts at column 0 with no ESC"
else
    bad "a marker line carries an escape or sits off column 0"
fi
cp "$TMP/col.issue" "$TMP/col.after"
sed -i '/^════ Sigmond appliance /,/^════ end Sigmond panel/d' "$TMP/col.after"
grep -q 'Sigmond appliance' "$TMP/col.after" \
    && bad "the sed range does not remove the coloured panel" \
    || ok "the sed range removes the coloured panel cleanly"
# every opened span is closed
opens=$(grep -o "${ESC}\[1;3[0-9]m" "$TMP/col.issue" | wc -l)
closes=$(grep -o "${ESC}\[0m" "$TMP/col.issue" | wc -l)
[ "$opens" -gt 0 ] && [ "$opens" -eq "$closes" ] \
    && ok "every colour span is closed with ESC[0m ($opens opened, $closes closed)" \
    || bad "spans opened=$opens closed=$closes"

echo "── the default password ───────────────────────────────────────────"
if grep -q "${ESC}\[1;33mhamsci-sigmond${ESC}\[0m   <-- image default, CHANGE IT" "$TMP/col.issue"; then
    ok "the default-password branch wraps hamsci-sigmond in _hl pw and keeps '<-- image default, CHANGE IT' outside it"
else
    bad "default password not wrapped as specified" "$(grep -n 'image default' "$TMP/col.issue")"
fi
grep -q "${ESC}\[1;33m" "$TMP/cust.issue" \
    && bad "a changed password was painted yellow" "yellow is the warning for the image default" \
    || ok "a station with its own password carries no yellow"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
