#!/bin/bash
# test-panel-startup.sh — the console must say something true within seconds
# of power-up, not after the guest agent finally answers.
#
# AI6VN (DASI-009), first v3.71 boot, 2026-10-15. rob: "after the second power up the system
# comes up with just a standard Proxmox virtual environment prompt and it has an
# address ... it isn't meaningful ... it's prompting for the login prompt and of
# course the keyboard is USB, isn't there ... it sits there at the login prompt
# for minutes so a user could rightly wonder what's wrong, it looks like it's
# hung."
#
# It was not hung. getty paints /etc/issue ONCE, early, before sigmond-issue
# runs, and the console keyboard is dead so no keypress can force a redraw.
# Everything the operator sees comes from our own paint onto VT1 — and that
# paint sat BEHIND a guest-agent loop that retries six times at
# `timeout 10` + `sleep 10`. Up to ~2 minutes of stock Proxmox banner showing
# the HYPERVISOR's address and an unusable `login:`.
#
# This test runs the real extracted sigmond-issue with a guest agent that
# HANGS, and requires the screen to carry an honest panel anyway.
set -u
cd "$(dirname "$(readlink -f "$0")")"
FB=firstboot-v3.sh
pass=0; fail=0
ok(){  printf '  ✓ %s\n' "$1"; pass=$((pass+1)); }
bad(){ printf '  ✗ %s\n     %s\n' "$1" "$2"; fail=$((fail+1)); }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

python3 - "$FB" "$TMP/issue.sh" <<'PYX'
import re, sys, pathlib
s = pathlib.Path(sys.argv[1]).read_text()
m = re.search(r"cat > /usr/local/sbin/sigmond-issue <<'ISSEOF'\n(.*?)\nISSEOF\n", s, re.S)
if not m: raise SystemExit("could not extract sigmond-issue")
pathlib.Path(sys.argv[2]).write_text(m.group(1))
PYX
[ -s "$TMP/issue.sh" ] || { echo "FATAL: extraction failed"; exit 1; }

echo "── it paints BEFORE the guest-agent loop, not after ───────────────"
# Structural: the paint call must precede the loop in the file.
pa=$(grep -n '^_paint_vt1 "\$_STARTING"' "$TMP/issue.sh" | head -1 | cut -d: -f1)
lo=$(grep -n '^VMIP=""; VMNOTE=""' "$TMP/issue.sh" | head -1 | cut -d: -f1)
if [ -n "$pa" ] && [ -n "$lo" ] && [ "$pa" -lt "$lo" ]; then
    ok "the starting panel is painted at line $pa, before the loop at line $lo"
else
    bad "no paint before the guest-agent loop (paint=$pa loop=$lo)" \
        "the operator stares at the stock Proxmox banner until the agent answers"
fi

echo "── behavioural: a HANGING guest agent must not silence the screen ─"
# Real run. /dev/tty1 redirected to a file; qm hangs like a deaf qga.
sed -e "s#/dev/tty1#$TMP/vt1#g" -e "s#/etc/issue#$TMP/etc_issue#g" \
    -e "s#/etc/motd#$TMP/etc_motd#g" "$TMP/issue.sh" > "$TMP/run.sh"
mkdir -p "$TMP/bin" "$TMP/etc"
: > "$TMP/vt1"; : > "$TMP/etc_issue"; : > "$TMP/etc_motd"
cat > "$TMP/bin/qm" <<EOF
#!/bin/bash
sleep 300            # a guest agent that is alive but deaf
EOF
printf '#!/bin/bash\nexit 1\n'  > "$TMP/bin/systemctl"   # no wizard/finalizer active
printf '#!/bin/bash\nexit 0\n'  > "$TMP/bin/who"
printf '#!/bin/bash\nexit 0\n'  > "$TMP/bin/logger"
chmod +x "$TMP/bin"/*
sudo_n(){ :; }

# the paint is gated on the host being finalized
mkdir -p "$TMP/fakeroot/etc/sigmond-appliance"
: > "$TMP/fakeroot/etc/sigmond-appliance/.finalized"
sed -i "s#/etc/sigmond-appliance#$TMP/fakeroot/etc/sigmond-appliance#g" "$TMP/run.sh"

PATH="$TMP/bin:$PATH" timeout 25 bash "$TMP/run.sh" >/dev/null 2>&1 &
runpid=$!
sleep 8          # well inside the agent's hang, nowhere near 120 s
painted=$(wc -c < "$TMP/vt1" 2>/dev/null || echo 0)
kill "$runpid" 2>/dev/null; wait "$runpid" 2>/dev/null

if [ "${painted:-0}" -gt 0 ]; then
    ok "VT1 carried $painted bytes 8 s in, while the agent was still hanging"
else
    bad "VT1 was still EMPTY 8 s in" \
        "this is exactly what AI6VN showed: a stale screen for minutes"
fi

echo "── and what it says is true and useful ────────────────────────────"
for want in "NO KEYBOARD ON THIS HOST" "refreshes BY ITSELF" "Nothing is hung" "decoder VM"; do
    grep -qi "$want" "$TMP/vt1" 2>/dev/null \
        && ok "says: $want" \
        || bad "the starting panel never says: $want" "$(head -3 "$TMP/vt1" 2>/dev/null)"
done
grep -q "hypervisor" "$TMP/vt1" 2>/dev/null \
    && ok "names this machine as the hypervisor, not the station" \
    || bad "does not distinguish hypervisor from station" "rob: the address 'isn't meaningful'"

echo "── the final panel must REPLACE it, not stack under it ────────────"
# ⛔ CHECK /etc/issue, NOT THE SCREEN.  The VT1 paint prefixes a clear-screen
# escape, so the opening marker is not at column 0 there -- but the markers
# only have to be line-anchored in the FILE, which is what the final panel's
# `sed '/^════ Sigmond appliance /,/^════ end Sigmond panel/d'` deletes. Testing
# the screen for this was testing the wrong artefact.
grep -q '^════ Sigmond appliance ' "$TMP/etc_issue" \
    && ok "/etc/issue carries the line-anchored opening marker" \
    || bad "no line-anchored opening marker in /etc/issue" \
           "the final panel's sed range never opens, so the starting panel is never removed"
grep -q '^════ end Sigmond panel' "$TMP/etc_issue" \
    && ok "...and the closing marker" \
    || bad "no closing marker" "the sed range never closes — /etc/issue grows a panel per refresh"
# and prove the real deletion actually works on what we wrote
cp "$TMP/etc_issue" "$TMP/issue_after"
sed -i '/^════ Sigmond appliance /,/^════ end Sigmond panel/d' "$TMP/issue_after"
grep -q 'Sigmond appliance' "$TMP/issue_after" \
    && bad "the final panel's sed does NOT remove the starting panel" \
           "two panels would stack in /etc/issue on every refresh" \
    || ok "the final panel's own sed removes the starting panel cleanly"

echo "── one copy of the standoff rule, not two ─────────────────────────"
n=$(grep -c 'is-active --quiet sigmond-wizard.service' "$TMP/issue.sh")
[ "$n" -eq 1 ] \
    && ok "the wizard/finalizer/session standoff exists once (in _paint_vt1)" \
    || bad "the standoff rule appears $n times" \
           "two copies drift; that is how half of this file's bugs started"

echo "── the FIRST paint must be ours, not the stock PVE banner ─────────"
# getty paints /etc/issue once at boot and sigmond-issue cannot run until
# multi-user.target. AI6VN v3.72: booted 13:44:28, sigmond-issue started
# 13:46:17 — 110 s of the hypervisor's address beside an unusable login prompt.
# Masking pvebanner leaves /etc/issue holding OUR panel across the reboot.
grep -q 'systemctl mask pvebanner.service' "$FB" \
    && ok "pvebanner is masked, so /etc/issue keeps the Sigmond panel" \
    || bad "pvebanner still rewrites /etc/issue every boot" \
           "getty paints the hypervisor address + an unusable login prompt first"
grep -q 'Sigmond appliance ════ starting' "$FB" \
    && ok "/etc/issue is seeded at install, so even boot #1 paints ours" \
    || bad "no seeded panel" "the very first boot has nothing of ours to paint"
# the seed must carry the same markers the live panel replaces
awk '/cat >> \/etc\/issue <<.SEEDEOF/,/^SEEDEOF$/' "$FB" > /tmp/seed.$$ 2>/dev/null
grep -q '^════ Sigmond appliance ' /tmp/seed.$$ && grep -q '^════ end Sigmond panel' /tmp/seed.$$ \
    && ok "the seed carries both markers, so the live panel replaces it" \
    || bad "seeded panel lacks the markers" "it would never be removed and panels would stack"
rm -f /tmp/seed.$$

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
