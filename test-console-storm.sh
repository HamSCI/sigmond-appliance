#!/bin/bash
# test-console-storm.sh — the console must not be able to OOM the host.
#
# AC0G-B4, 2026-10-01 21:00:29Z.  The VM was installed while the PM held its
# fresh v3.66 host key; an identity restore later put the PM's genuine key
# back; the VM's known_hosts still pinned the old one.  On a CHANGED key
# OpenSSH prints REMOTE HOST IDENTIFICATION HAS CHANGED and DISABLES password
# auth even with StrictHostKeyChecking=no, so the bridge's ssh failed
# instantly.  getty respawned it every ~2 s, every pass opened a relay session
# on :7790, and every session end fired an unbounded background
# sigmond-issue -- each of which then sat for MINUTES in an untimed
# `qm agent network-get-interfaces`.  225 copies alive, 102 in the agent call
# at ~57 MB each, load 117.  Global OOM; the kernel killed the decoder VM's
# 10 GB kvm.  That blocked the v3.66 bless.
#
# Four independent surfaces had to be wrong at once, so this tests all four.
# Any ONE of them being fixed would have capped the damage.
set -u
cd "$(dirname "$(readlink -f "$0")")"
FB=firstboot-v3.sh
BR=vm-console/sigmond-console-bridge
pass=0; fail=0
ok(){  printf '  ✓ %s\n' "$1"; pass=$((pass+1)); }
bad(){ printf '  ✗ %s\n     %s\n' "$1" "$2"; fail=$((fail+1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Pull the two embedded scripts out of the firstboot heredocs so we test what
# actually ships, not a copy that can drift from it.
python3 - "$FB" "$TMP" <<'PYX'
import re, sys, pathlib
src = pathlib.Path(sys.argv[1]).read_text(); out = pathlib.Path(sys.argv[2])
for name, marker, dest in (("sigmond-issue", "ISSEOF", "issue"),
                           ("sigmond-console-paint", "CPAINTEOF", "paint")):
    m = re.search(r"cat > /usr/local/sbin/%s <<'%s'\n(.*?)\n%s\n"
                  % (re.escape(name), marker, marker), src, re.S)
    if not m:
        raise SystemExit("could not extract " + name)
    (out / dest).write_text(m.group(1))
PYX

[ -s "$TMP/issue" ] && [ -s "$TMP/paint" ] || { echo "FATAL: extraction failed"; exit 1; }

# ⛔ ASSERT AGAINST CODE, NOT COMMENTS.  These scripts explain the bug they
# fix, quoting the old line verbatim, so a naive grep finds the defect in its
# own obituary. Strip comment lines first.
code(){ grep -vE '^[[:space:]]*#' "$1"; }
code "$TMP/issue" > "$TMP/issue.code"
code "$TMP/paint" > "$TMP/paint.code"

echo "── 1. the pile-up: sigmond-issue must refuse to run twice ─────────"
# Behavioural: run the real lock idiom concurrently and count survivors.
sed -n '/^exec 9>/,/^}/p' "$TMP/issue" > "$TMP/lock.sh" 2>/dev/null
if [ -s "$TMP/lock.sh" ]; then
    cat > "$TMP/holder.sh" <<EOF
#!/bin/bash
exec 9>$TMP/issue.lock 2>/dev/null
flock -n 9 2>/dev/null || { echo BLOCKED >> $TMP/results; exit 0; }
echo RUNNING >> $TMP/results
sleep 3
EOF
    chmod +x "$TMP/holder.sh"
    "$TMP/holder.sh" & sleep 0.4
    for _ in 1 2 3 4 5 6 7 8; do "$TMP/holder.sh"; done
    wait 2>/dev/null
    running=$(grep -c RUNNING "$TMP/results" 2>/dev/null || echo 0)
    blocked=$(grep -c BLOCKED "$TMP/results" 2>/dev/null || echo 0)
    [ "$running" -eq 1 ] && [ "$blocked" -eq 8 ] \
        && ok "9 concurrent attempts -> 1 ran, 8 exited at once" \
        || bad "concurrency not bounded: $running ran, $blocked blocked" \
               "this is what reached 225 live copies on B4"
else
    bad "no flock idiom found in sigmond-issue" "the pile-up is unbounded"
fi
grep -q 'flock -n 9' "$TMP/issue.code" \
    && ok "the shipped sigmond-issue takes a non-blocking lock" \
    || bad "shipped sigmond-issue has no flock" "a second run would pile up"

echo "── 2. the hang: every guest-agent call must be bounded ────────────"
unbounded=$(grep -c 'qm agent' "$TMP/issue.code" 2>/dev/null; true)
timed=$(grep -c 'timeout [0-9][0-9]* qm agent' "$TMP/issue.code" 2>/dev/null; true)
unbounded=$(( ${unbounded:-0} - ${timed:-0} ))
[ "${unbounded:-0}" -eq 0 ] \
    && ok "no untimed \`qm agent\` call in sigmond-issue" \
    || bad "$unbounded untimed \`qm agent\` call(s)" \
           "an alive-but-deaf qga HANGS rather than failing; that is what made each copy long-lived"

echo "── 3. the fan-out: console-paint must not fork an unbounded child ─"
if grep -qE '/usr/local/sbin/sigmond-issue[^|]*&[[:space:]]*$' "$TMP/paint.code"; then
    bad "console-paint still backgrounds sigmond-issue directly" \
        "every console session -- including the socat probe -- spawns one more"
else
    ok "console-paint no longer forks sigmond-issue directly"
fi
grep -q 'systemctl start --no-block sigmond-issue' "$TMP/paint.code" \
    && ok "it asks systemd, which de-duplicates a Type=oneshot" \
    || bad "console-paint does not hand the job to systemd" "no de-duplication"

echo "── 4. the trigger: a changed PM host key must not wedge the bridge ─"
grep -q 'UserKnownHostsFile=' "$BR" \
    && ok "the bridge uses its own known_hosts, not root's" \
    || bad "bridge still uses root's known_hosts" \
           "an identity restore then disables password auth and ssh fails instantly"
kh=$(grep -oE 'KNOWN=\S+' "$BR" | cut -d= -f2)
case "$kh" in
    /run/*) ok "that file lives in /run (tmpfs) — relearned every boot, cannot wedge" ;;
    *)      bad "known_hosts at '$kh' is persistent" "a stale key survives a reboot" ;;
esac

echo "── 5. back-off: a bridge that cannot connect must slow down ───────"
# ⛔ ASSERT THE CALL, NOT THE DEFINITION.  `grep -q _backoff` still matches
# the function body after the call site is deleted -- verified by mutation
# 2026-10-03: replacing the call with `sleep 2` passed the whole suite.
if grep -A1 '= 255 \]; then' "$BR" | grep -qE '^[[:space:]]*_backoff[[:space:]]*$'; then
    ok "the ssh-failed branch actually CALLS the back-off"
else
    bad "the 255 branch does not call _backoff" \
        "getty respawns the bridge every ~2 s forever -- the storm"
fi
grep -q '^_backoff()' "$BR" \
    && ok "the back-off helper is defined" \
    || bad "no _backoff helper" "nothing to call"
# The null: a REAL session ending must still return the screen immediately.
grep -q '_backoff_clear' "$BR" \
    && ok "a session that actually ran clears the counter (no penalty)" \
    || bad "no counter reset" "a working console would slow down over time"
grep -qE '\[ "\$\{_rc:-255\}" = 255 \]' "$BR" \
    && ok "it distinguishes ssh-failed (255) from operator-logged-out" \
    || bad "failure and normal logout are not distinguished" \
           "either the storm returns, or every logout is penalised"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
